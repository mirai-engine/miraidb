package engine

import "core:mem"
import "core:strings"

// The planner prices the ways one table can be read and the order a join runs
// in. It answers a question the executor already had to answer — index or scan,
// and which table goes first — with the numbers ANALYZE measured instead of with
// "an index exists, so use it".
//
// The units are abstract: one unit is about one sequential row read, and the
// constants below are the whole tuning surface. A scan reads every row of the
// table in order; a probe walks a tree, collects ids and then fetches each row at
// random, which is why a row reached through an index costs four times a row read
// in place. With these numbers an index wins while it keeps less than a quarter
// of the table, which is the classic threshold, and it is measured rather than
// assumed.
PLAN_PROBE :: 1.0      // one descent through an index tree
PLAN_INDEX_ROW :: 2.0  // fetching one row through an id: read plus bookkeeping
PLAN_SCAN_ROW :: 0.5   // reading one row of a scan and evaluating the filter

// Plan_Kind is how one relation is read.
Plan_Kind :: enum u8 {
	Scan,
	Index,
}

// Plan_Access is the chosen way to read one relation, with the rows it is
// expected to keep and what that costs.
Plan_Access :: struct {
	kind:     Plan_Kind,
	index:    int,     // position in table.indexes, -1 for a scan
	conjunct: ^Expr,   // the predicate the index answers, nil for a scan
	rows:     u64,     // rows the relation keeps
	cost:     f64,
}

// plan_access picks between scanning a table and probing one of its indexes.
// `predicate` is what the caller will filter with; the estimate of how many rows
// survive it is what both sides are priced with.
plan_access :: proc(
	store: ^Store,
	table: ^Table,
	ref: Table_Ref,
	predicate: ^Expr,
	params: []Value,
) -> Plan_Access {
	rows := stats_estimate_rows(store, table, predicate)
	// A scan pays for every row it reads, not for the rows that survive the
	// filter: the filter runs on all of them.
	scan_rows := u64(table_row_count(table))
	if stats, has_stats := stats_get(store, table.schema.name); has_stats do scan_rows = stats.rows
	best := Plan_Access {
		kind  = .Scan,
		index = -1,
		rows  = rows,
		cost  = f64(scan_rows) * PLAN_SCAN_ROW,
	}
	if predicate == nil || table == nil do return best
	_, has_stats := stats_get(store, table.schema.name)
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		column_index, ok := plan_conjunct_column(table, ref, expr)
		if !ok do continue
		index_position, has_index := index_for_single_column(table, column_index)
		if !has_index do continue
		// Without statistics every estimate is the full row count, so a probe
		// would look as expensive as the scan it replaces and the engine would
		// stop using indexes nobody measured. A table nobody ran ANALYZE on keeps
		// the old behaviour: the index answers.
		if !has_stats {
			return Plan_Access {
				kind     = .Index,
				index    = index_position,
				conjunct = expr,
				rows     = rows,
				cost     = PLAN_PROBE,
			}
		}
		// What this index hands over, not what the whole predicate keeps: the
		// filter that is left runs anyway.
		kept := stats_estimate_rows(store, table, expr)
		cost := PLAN_PROBE + f64(kept) * PLAN_INDEX_ROW
		if cost >= best.cost do continue
		best = Plan_Access {
			kind     = .Index,
			index    = index_position,
			conjunct = expr,
			rows     = rows,
			cost     = cost,
		}
	}
	return best
}

// plan_conjunct_column returns the column a conjunct filters on, when the
// conjunct is one an index can answer and it names this relation.
@(private)
plan_conjunct_column :: proc(table: ^Table, ref: Table_Ref, expr: ^Expr) -> (int, bool) {
	if binary, is_binary := expr^.(Binary_Expr); is_binary {
		#partial switch binary.op {
		case .Eq, .Lt, .Le, .Gt, .Ge:
		case:
			return -1, false
		}
		qualifier, column_name, _, _, ok := comparison_sides(binary)
		if !ok do return -1, false
		if !plan_names_relation(qualifier, ref) do return -1, false
		column_index, found := schema_column_index(&table.schema, column_name)
		if !found do return -1, false
		return column_index, true
	}
	if between, is_between := expr^.(Between_Expr); is_between && !between.negated {
		column, is_column := between.operand^.(Column_Expr)
		if !is_column do return -1, false
		if !plan_names_relation(column.table, ref) do return -1, false
		column_index, found := schema_column_index(&table.schema, column.name)
		if !found do return -1, false
		return column_index, true
	}
	return -1, false
}

// plan_names_relation says whether a qualifier can only mean this relation: an
// empty qualifier passes, which is how an unqualified column of a single-table
// statement is written.
@(private)
plan_names_relation :: proc(qualifier: string, ref: Table_Ref) -> bool {
	if len(qualifier) == 0 do return true
	if strings.equal_fold(qualifier, ref.name) do return true
	return len(ref.alias) > 0 && strings.equal_fold(qualifier, ref.alias)
}

// --- Join order ------------------------------------------------------------

// Plan_Step is one relation of a join, in execution order, with what the plan
// expects it to cost. EXPLAIN prints the name and the rows; the executor runs the
// step: it reads `ref` and keeps the combinations that satisfy `predicate`.
//
// `predicate` is every ON condition that becomes answerable at this step — not
// necessarily the one written on this join, because reordering moves a relation
// ahead of the join it was written with, and its condition has to wait until the
// relation it names has a row.
Plan_Step :: struct {
	name:      string, // as written, for the plan output
	alias:     string,
	rows:      u64,    // rows the relation keeps
	cost:      f64,    // reads this step is expected to spend
	ref:       Table_Ref,
	predicate: ^Expr,
	left:      bool,   // a LEFT join keeps an unmatched outer row
}

// Plan_Order is the execution order of a join, and the fingerprint of how
// expensive each step is.
Plan_Order :: struct {
	from:      Table_Ref,
	joins:     []Join_Clause, // in execution order
	steps:     []Plan_Step,
	reordered: bool,
	cost:      f64,
}

// plan_join_order decides in which order the relations of a join run. A nested
// loop reads the whole inner relation once per outer row, so the order decides
// how many rows are read: a relation that keeps few rows shrinks everything
// after it.
//
// It declines to reorder when the statement's meaning depends on the order:
// a LEFT join, an AS OF pin, a table function (a view or a JSON table reads a
// column of the relation before it), or an ON condition it cannot read.
plan_join_order :: proc(
	store: ^Store,
	tx: ^Tx,
	stmt: Select_Stmt,
	params: []Value,
) -> Plan_Order {
	relations := make([dynamic]Plan_Relation, 0, len(stmt.joins) + 1)
	defer delete(relations)
	append(&relations, plan_relation(store, tx, stmt.from, stmt.where_clause, nil))
	for join in stmt.joins {
		append(&relations, plan_relation(store, tx, join.table, stmt.where_clause, join.on))
	}
	// The plan is computed either way: EXPLAIN prints the rows it expects from
	// every step, and only the order itself changes when reordering is allowed.
	identity := len(stmt.joins) == 0 || !plan_can_reorder(tx, stmt)
	if !identity {
		dependencies, ok := plan_join_dependencies(stmt, relations[:], tx.alloc)
		if !ok {
			identity = true
		} else {
			defer delete(dependencies)
			return plan_ordered_join(store, stmt, relations[:], dependencies, tx.alloc)
		}
	}
	steps := make([]Plan_Step, len(relations))
	for relation, i in relations {
		steps[i] = Plan_Step {
			name  = relation.ref.name,
			alias = relation.ref.alias,
			rows  = relation.rows,
			cost  = f64(relation.scan_rows) * PLAN_SCAN_ROW,
			ref   = relation.ref,
		}
		if i > 0 {
			steps[i].predicate = stmt.joins[i - 1].on
			steps[i].left = stmt.joins[i - 1].left
		}
	}
	return Plan_Order{from = stmt.from, joins = stmt.joins, steps = steps}
}

// plan_ordered_join runs the greedy order over relations whose dependencies are
// known, and hands every ON condition to the step that can answer it.
@(private)
plan_ordered_join :: proc(
	store: ^Store,
	stmt: Select_Stmt,
	relations: []Plan_Relation,
	dependencies: [][]int,
	alloc: mem.Allocator,
) -> Plan_Order {
	_ = store
	bound := make([]bool, len(relations))
	order := make([dynamic]int, 0, len(relations))  // relation indices, in run order
	for len(order) < len(relations) {
		best := -1
		best_growth: f64 = 0
		for relation, i in relations {
			if bound[i] do continue
			// Fewest rows per outer row first: that is what shrinks everything
			// after it. Any relation may run early; its ON condition waits for the
			// step that completes it, so there is nothing to wait for here.
			growth := f64(max(relation.matches, 1))
			if best < 0 || growth < best_growth {
				best = i
				best_growth = growth
			}
		}
		if best < 0 do break
		bound[best] = true
		append(&order, best)
	}
	if len(order) != len(relations) do return Plan_Order{from = stmt.from, joins = stmt.joins}
	// The step at which each ON becomes answerable: the last of the relations it
	// names.
	// `for value, index in slice` is value-first in Odin: the loop names the
	// relation and where it runs.
	position_of := make([]int, len(relations))
	for index, position in order do position_of[index] = position
	predicates := make([]^Expr, len(relations))
	for i in 1 ..< len(relations) {
		if relations[i].on == nil do continue
		// The condition needs this relation's row too, so it completes at the
		// later of its own position and the last relation it names.
		latest := position_of[i]
		for dependency in dependencies[i] {
			if position_of[dependency] > latest do latest = position_of[dependency]
		}
		predicates[latest] = plan_and(predicates[latest], relations[i].on, alloc)
	}
	steps := make([]Plan_Step, len(order))
	partials: f64 = 1
	for index, position in order {
		relation := relations[index]
		steps[position] = Plan_Step {
			name      = relation.ref.name,
			alias     = relation.ref.alias,
			rows      = relation.rows,
			cost      = partials * f64(relation.scan_rows) * PLAN_SCAN_ROW,
			ref       = relation.ref,
			predicate = predicates[position],
		}
		partials *= f64(max(relation.matches, 1))
	}
	reordered := false
	for index, position in order {
		if position != index do reordered = true
	}
	return Plan_Order {
		from = relations[order[0]].ref,
		joins = stmt.joins,
		steps = steps,
		reordered = reordered,
	}
}

// plan_join_dependencies says, for every relation, which relations its ON
// condition names. It reports ok = false when the statement uses a shape the
// planner does not read (a subquery in an ON), because guessing there would move
// a condition to a step that cannot answer it.
@(private)
plan_join_dependencies :: proc(
	stmt: Select_Stmt,
	relations: []Plan_Relation,
	alloc: mem.Allocator,
) -> (dependencies: [][]int, ok: bool) {
	_, _ = stmt, alloc
	dependencies = make([][]int, len(relations))
	for i in 1 ..< len(relations) {
		if relations[i].on == nil do continue
		qualifiers: map[string]bool
		if !plan_expr_qualifiers(relations[i].on, &qualifiers) {
			give_up_dependencies(dependencies)
			return nil, false
		}
		list := make([dynamic]int, 0, len(qualifiers))
		for qualifier in qualifiers {
			matched := -1
			for relation in 0 ..< len(relations) {
				if plan_names_relation(qualifier, relations[relation].ref) {
					matched = relation
					break
				}
			}
			if matched < 0 {
				delete(qualifiers)
				delete(list)
				give_up_dependencies(dependencies)
				return nil, false
			}
			if matched != i do append(&list, matched)
		}
		delete(qualifiers)
		dependencies[i] = list[:]
	}
	return dependencies, true
}

@(private)
give_up_dependencies :: proc(dependencies: [][]int) {
	for filled in dependencies do delete(filled)
	delete(dependencies)
}

// Plan_Relation is one relation of a join while the order is being chosen.
@(private)
Plan_Relation :: struct {
	ref:       Table_Ref,
	on:        ^Expr,
	rows:      u64, // rows the relation keeps after its own filters
	scan_rows: u64, // rows a nested loop has to read
	matches:   u64, // rows one outer row matches
}

@(private)
plan_relation :: proc(
	store: ^Store,
	tx: ^Tx,
	ref: Table_Ref,
	filter: ^Expr,
	on: ^Expr,
) -> Plan_Relation {
	table, table_err := tx_table(tx, ref.name)
	if table_err.kind != .None do return Plan_Relation{ref = ref, on = on}
	predicate := filter
	if on != nil do predicate = on
	rows := stats_estimate_rows(store, table, predicate)
	scan_rows := u64(table_row_count(table))
	if stats, has_stats := stats_get(store, table.schema.name); has_stats {
		scan_rows = stats.rows
	}
	matches := rows
	if on != nil do matches = plan_join_matches(store, table, on)
	if matches == 0 do matches = 1
	return Plan_Relation {
		ref = ref,
		on = on,
		rows = rows,
		scan_rows = scan_rows,
		matches = matches,
	}
}

// plan_join_matches estimates how many inner rows one outer row matches, which
// is what decides whether a join shrinks the intermediate result or grows it.
// An equality on a column with N distinct values matches about rows/N.
@(private)
plan_join_matches :: proc(store: ^Store, table: ^Table, on: ^Expr) -> u64 {
	stats, has_stats := stats_get(store, table.schema.name)
	rows := u64(table_row_count(table))
	if has_stats do rows = stats.rows
	if on == nil || rows == 0 do return rows
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(on, &conjuncts)
	matches: f64 = f64(rows)
	for expr in conjuncts {
		column_index, ok := plan_conjunct_column(table, Table_Ref{name = table.schema.name}, expr)
		if !ok do continue
		distinct_count: u64 = 1
		if has_stats && column_index < len(stats.columns) {
			distinct_count = max(stats.columns[column_index].distinct_count, 1)
		}
		matches *= 1 / f64(distinct_count)
	}
	if matches < 1 do matches = 1
	return u64(matches)
}

// plan_and joins two conditions into one AND, allocating the node with the
// statement's allocator.
@(private)
plan_and :: proc(left: ^Expr, right: ^Expr, alloc: mem.Allocator) -> ^Expr {
	if left == nil do return right
	if right == nil do return left
	node := new(Expr, alloc)
	node^ = Binary_Expr{op = .And, left = left, right = right}
	return node
}

// plan_expr_qualifiers collects the relation qualifiers an expression names. It
// reports ok = false for a shape the planner does not read, which keeps the
// written order.
@(private)
plan_expr_qualifiers :: proc(expr: ^Expr, out: ^map[string]bool) -> bool {
	if expr == nil do return true
	switch e in expr^ {
	case Column_Expr:
		if len(e.table) > 0 do out[e.table] = true
		return true
	case Literal_Expr, Param_Expr, Star_Expr:
		return true
	case Binary_Expr:
		return plan_expr_qualifiers(e.left, out) && plan_expr_qualifiers(e.right, out)
	case Unary_Expr:
		return plan_expr_qualifiers(e.operand, out)
	case Is_Null_Expr:
		return plan_expr_qualifiers(e.operand, out)
	case Between_Expr:
		return plan_expr_qualifiers(e.operand, out) &&
		plan_expr_qualifiers(e.low, out) &&
		plan_expr_qualifiers(e.high, out)
	case In_Expr:
		if !plan_expr_qualifiers(e.operand, out) do return false
		for item in e.items do if !plan_expr_qualifiers(item, out) do return false
		return e.subquery == nil
	case Like_Expr:
		return plan_expr_qualifiers(e.operand, out) && plan_expr_qualifiers(e.pattern, out)
	case Match_Expr:
		return plan_expr_qualifiers(e.operand, out) && plan_expr_qualifiers(e.pattern, out)
	case Cast_Expr:
		return plan_expr_qualifiers(e.operand, out)
	case Collate_Expr:
		return plan_expr_qualifiers(e.operand, out)
	case Call_Expr:
		for arg in e.args do if !plan_expr_qualifiers(arg, out) do return false
		return true
	case Subquery_Expr, Window_Expr:
		return false
	}
	return false
}

// plan_can_reorder declines the cases where the order is part of the meaning or
// the relation cannot be read on its own.
@(private)
plan_can_reorder :: proc(tx: ^Tx, stmt: Select_Stmt) -> bool {
	if stmt.from.as_of != nil do return false
	if len(stmt.from.args) > 0 do return false
	if is_json_table_function(stmt.from.name) do return false
	if _, base_table := tx.store.tables[stmt.from.name]; !base_table do return false
	for join in stmt.joins {
		if join.left do return false
		if join.table.as_of != nil do return false
		if len(join.table.args) > 0 do return false
		if is_json_table_function(join.table.name) do return false
		if _, table := tx.store.tables[join.table.name]; !table do return false
	}
	return true
}
