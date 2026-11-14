package engine

import "core:mem"
import "core:strings"

// The planner prices the ways one table can be read and the order a join runs
// in. It answers a question the executor already had to answer — index or scan,
// and which table goes first — with the numbers ANALYZE measured instead of with
// "an index exists, so use it".
//
// The units are these constants: one unit is one row read in place, which is the
// cheapest thing a plan can spend. A scan reads every row of the table in order; a
// probe walks a tree to one key, and every row it keeps costs a fetch by id, which
// jumps around the map instead of streaming it.
//
// Measured rather than assumed, on a 200 000-row table of two integers with one
// index (Windows/WSL, release build, the fastest of five runs):
//
//	scan row              100.8 ns   PLAN_SCAN_ROW   1.0
//	row fetched by id     456.3 ns   PLAN_INDEX_ROW  4.5   (4.5x)
//	one descent           600.0 ns   PLAN_PROBE      6.0   (6 scan rows)
//	row a join produces   5.1 µs     PLAN_JOIN_ROW   50.0  (50x)
//
// A row a join step produces costs eleven times a plain fetch: it also pays the
// ON condition again and the row it hands to the next step. Measured on 200 000
// books joined to 10 000 authors, 5.1 µs per output row through the index and
// 8.6 µs when the inner side had to be scanned; the order is chosen on this
// number because these are the rows every later step multiplies.
//
// With these numbers an index wins while it keeps less than about a fifth of the
// table, which is the classic threshold. The measurement is written down here so a
// later change to it is a decision rather than a shrug; `PLAN_INDEX_ROW` is the
// ratio the two access paths actually cost and `PLAN_PROBE` is what a lookup pays
// before it fetches anything.
PLAN_PROBE :: 6.0      // one descent through an index tree
PLAN_INDEX_ROW :: 4.5  // fetching one row through an id: read plus bookkeeping
PLAN_SCAN_ROW :: 1.0   // reading one row of a scan and evaluating the filter
PLAN_JOIN_ROW :: 50.0  // one row a join step produces: ON again plus projection

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
	// conjunct2 is the other end of a range: `v >= 5 AND v < 9` is one scan over
	// [5, 9) rather than two filters that each keep a third of the table.
	conjunct2: ^Expr,
	rows:      u64,    // rows the relation keeps
	cost:      f64,
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
	rows := stats_estimate_rows(store, table, predicate, params)
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
		kept := stats_estimate_rows(store, table, expr, params)
		companion: ^Expr = nil
		if !is_equality(expr) {
			if other, found := plan_range_companion(table, ref, expr, conjuncts[:]); found {
				companion = other
				kept = plan_range_rows(store, table, ref, expr, other, params, kept)
			}
		}
		cost := PLAN_PROBE + f64(kept) * PLAN_INDEX_ROW
		if cost >= best.cost do continue
		best = Plan_Access {
			kind      = .Index,
			index     = index_position,
			conjunct  = expr,
			conjunct2 = companion,
			rows      = rows,
			cost      = cost,
		}
	}
	return best
}

// is_equality reports whether a conjunct is an equality, which no second end can
// narrow.
@(private)
is_equality :: proc(expr: ^Expr) -> bool {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary do return false
	return binary.op == .Eq
}

// plan_range_companion finds the other end of a range among the conjuncts: the
// same column, the opposite direction. `v >= 5 AND v < 9` becomes one range scan
// instead of two filters that each keep a third of the table.
@(private)
plan_range_companion :: proc(
	table: ^Table,
	ref: Table_Ref,
	expr: ^Expr,
	conjuncts: []^Expr,
) -> (^Expr, bool) {
	bound, ok := plan_range_bound(table, ref, expr)
	if !ok do return nil, false
	for other in conjuncts {
		if other == expr do continue
		theirs, theirs_ok := plan_range_bound(table, ref, other)
		if !theirs_ok || theirs.column != bound.column do continue
		if theirs.lower == bound.lower do continue
		return other, true
	}
	return nil, false
}

// Range_Bound is one comparison a plan can read: which column, and whether it
// holds the rows below or above its value.
@(private)
Range_Bound :: struct {
	column: int,
	lower:  bool,
}

@(private)
plan_range_bound :: proc(table: ^Table, ref: Table_Ref, expr: ^Expr) -> (Range_Bound, bool) {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary do return {}, false
	lower: bool
	#partial switch binary.op {
	case .Gt, .Ge:
		lower = true
	case .Lt, .Le:
		lower = false
	case:
		return {}, false
	}
	qualifier, column_name, _, reversed, sides_ok := comparison_sides(binary)
	if !sides_ok do return {}, false
	if !plan_names_relation(qualifier, ref) do return {}, false
	column_index, found := schema_column_index(&table.schema, column_name)
	if !found do return {}, false
	// `5 < v` is a lower bound written the other way round.
	if reversed do lower = !lower
	return Range_Bound{column = column_index, lower = lower}, true
}

// plan_range_rows estimates what both ends of a range keep, through the same
// histogram the single comparison used.
@(private)
plan_range_rows :: proc(
	store: ^Store,
	table: ^Table,
	ref: Table_Ref,
	first: ^Expr,
	second: ^Expr,
	params: []Value,
	fallback: u64,
) -> u64 {
	stats, has_stats := stats_get(store, table.schema.name)
	if !has_stats || stats.rows == 0 do return fallback
	low: f64
	high: f64
	high_inclusive := true
	column := -1
	have_low := false
	have_high := false
	for expr in ([]^Expr{first, second}) {
		binary, is_binary := expr^.(Binary_Expr)
		if !is_binary do continue
		qualifier, column_name, value_expr, reversed, sides_ok := comparison_sides(binary)
		if !sides_ok || !plan_names_relation(qualifier, ref) do continue
		column_index, found := schema_column_index(&table.schema, column_name)
		if !found || column_index >= len(stats.columns) do continue
		if !stats.columns[column_index].numeric do return fallback
		value, constant := eval_constant(value_expr, params)
		number, is_number := value_as_f64(value)
		if !constant || !is_number do return fallback
		lower: bool
		#partial switch binary.op {
		case .Gt, .Ge:
			lower = true
		case .Lt, .Le:
			lower = false
		case:
			return fallback
		}
		if reversed do lower = !lower
		column = column_index
		if lower {
			low = number
			have_low = true
		} else {
			high = number
			have_high = true
			high_inclusive = binary.op == .Le
		}
	}
	if column < 0 || !have_low || !have_high do return fallback
	fraction := stats_range_fraction(stats, column, low, high, high_inclusive)
	return u64(max(fraction * f64(stats.rows), 1))
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
	append(&relations, plan_relation(store, tx, stmt.from, stmt.where_clause, nil, params))
	for join in stmt.joins {
		append(&relations, plan_relation(store, tx, join.table, stmt.where_clause, join.on, params))
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
			return plan_ordered_join(tx, stmt, relations[:], dependencies, tx.alloc)
		}
	}
	steps := make([]Plan_Step, len(relations))
	bound_names := make(map[string]bool)
	defer delete(bound_names)
	partials: f64 = 1
	for relation, i in relations {
		// Written order: every ON is answerable where it is written, so the step
		// pays a probe when the inner side has an index for it.
		on: ^Expr
		if i > 0 do on = stmt.joins[i - 1].on
		probed := i > 0 && plan_probe_ready(tx, relation, on, bound_names)
		steps[i] = Plan_Step {
			name  = relation.ref.name,
			alias = relation.ref.alias,
			rows  = relation.rows,
			cost  = partials * plan_step_cost(relation, relation.matches, probed),
			ref   = relation.ref,
		}
		plan_bind_relation(&bound_names, relation)
		partials *= f64(max(relation.matches, 1))
		if i > 0 {
			steps[i].predicate = stmt.joins[i - 1].on
			steps[i].left = stmt.joins[i - 1].left
		}
	}
	return Plan_Order{from = stmt.from, joins = stmt.joins, steps = steps}
}

// plan_ordered_join runs the cheapest order the search finds, then hands every
// ON condition to the step that can answer it.
//
// The order is searched rather than guessed because the local choice is not the
// global one: a step that keeps fewer rows may still be the wrong step if it
// cannot be filtered yet. A join of up to PLAN_SEARCH_LIMIT relations is
// enumerated with pruning on the best cost so far; a larger one falls back to a
// greedy from every possible start, which is the same cost function without the
// lookahead.
@(private)
plan_ordered_join :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	relations: []Plan_Relation,
	dependencies: [][]int,
	alloc: mem.Allocator,
) -> Plan_Order {
	best_order, _ := plan_best_order(tx, relations, dependencies)
	defer delete(best_order)
	if len(best_order) == 0 do return Plan_Order{from = stmt.from, joins = stmt.joins}
	// The step at which each ON becomes answerable: the last of the relations it
	// names.
	// `for value, index in slice` is value-first in Odin: the loop names the
	// relation and where it runs.
	position_of := make([]int, len(relations))
	for index, position in best_order do position_of[index] = position
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
	steps := make([]Plan_Step, len(best_order))
	partials: f64 = 1
	bound_names := make(map[string]bool)
	defer delete(bound_names)
	bound := make([]bool, len(relations))
	defer delete(bound)
	for index, position in best_order {
		relation := relations[index]
		// A step whose ON cannot be answered yet keeps every inner row, so the
		// cost it hands the next step is the whole relation.
		answerable := plan_relation_answerable(index, dependencies, bound)
		probed := plan_probe_ready(tx, relation, predicates[position], bound_names)
		kept := relation.matches
		if !answerable do kept = relation.scan_rows
		steps[position] = Plan_Step {
			name      = relation.ref.name,
			alias     = relation.ref.alias,
			rows      = relation.rows,
			cost      = partials * plan_step_cost(relation, kept, probed),
			ref       = relation.ref,
			predicate = predicates[position],
		}
		bound[index] = true
		plan_bind_relation(&bound_names, relation)
		partials *= f64(max(answerable ? relation.matches : relation.scan_rows, 1))
	}
	reordered := false
	for index, position in best_order {
		if position != index do reordered = true
	}
	return Plan_Order {
		from = relations[best_order[0]].ref,
		joins = stmt.joins,
		steps = steps,
		reordered = reordered,
	}
}

// PLAN_SEARCH_LIMIT is how many relations are enumerated rather than greedily
// ordered. Six relations are 720 orders at most, which is nothing beside the
// statement they describe, and every one of them is pruned as soon as it costs
// more than the best complete order found.
PLAN_SEARCH_LIMIT :: 6

@(private)
Plan_Search :: struct {
	cost:  f64,
	order: [dynamic]int,
}

// plan_best_order returns the cheapest order it can find and what it costs.
@(private)
plan_best_order :: proc(
	tx: ^Tx,
	relations: []Plan_Relation,
	dependencies: [][]int,
) -> (order: [dynamic]int, cost: f64) {
	if len(relations) <= PLAN_SEARCH_LIMIT {
		best := Plan_Search{cost = -1}
		current := make([dynamic]int, 0, len(relations))
		defer delete(current)
		bound := make([]bool, len(relations))
		defer delete(bound)
		bound_names := make(map[string]bool)
		defer delete(bound_names)
		plan_search_step(
			tx,
			relations,
			dependencies,
			&current,
			bound,
			&bound_names,
			1,
			0,
			&best,
		)
		if len(best.order) > 0 do return best.order, best.cost
		return current, -1
	}
	// Too many relations to enumerate: a greedy from every start.
	best_cost: f64
	for start in 0 ..< len(relations) {
		candidate, candidate_cost := plan_greedy_order(tx, relations, dependencies, start)
		if candidate_cost < 0 {
			delete(candidate)
			continue
		}
		if len(order) == 0 || candidate_cost < best_cost {
			delete(order)
			order = candidate
			best_cost = candidate_cost
			continue
		}
		delete(candidate)
	}
	return order, best_cost
}

// plan_search_step extends the order one relation at a time and keeps the
// cheapest complete order it reaches. It stops a branch as soon as what it has
// spent is already more than the best complete order.
@(private)
plan_search_step :: proc(
	tx: ^Tx,
	relations: []Plan_Relation,
	dependencies: [][]int,
	order: ^[dynamic]int,
	bound: []bool,
	bound_names: ^map[string]bool,
	partials: f64,
	cost: f64,
	best: ^Plan_Search,
) {
	if best.cost >= 0 && cost >= best.cost do return
	if len(order) == len(relations) {
		if len(best.order) > 0 do delete(best.order)
		best.order = make([dynamic]int, len(order))
		copy(best.order[:], order[:])
		best.cost = cost
		return
	}
	for relation, i in relations {
		if bound[i] do continue
		kept, probed := plan_candidate(tx, relations, dependencies, bound, bound_names^, i)
		step := plan_step_cost(relation, kept, probed)
		if len(order) == 0 {
			// Nothing can filter the first step, so it hands over every row it
			// scans whatever its own ON says.
			kept = relation.scan_rows
			step = f64(relation.scan_rows) * PLAN_SCAN_ROW
		}
		bound[i] = true
		plan_bind_relation(bound_names, relation)
		append(order, i)
		plan_search_step(
			tx,
			relations,
			dependencies,
			order,
			bound,
			bound_names,
			partials * f64(max(kept, 1)),
			cost + partials * step,
			best,
		)
		pop(order)
		plan_unbind_relation(bound_names, relation)
		bound[i] = false
	}
}

// plan_unbind_relation takes a relation back out of the bound set.
@(private)
plan_unbind_relation :: proc(bound_names: ^map[string]bool, relation: Plan_Relation) {
	delete_key(bound_names, relation.ref.name)
	if len(relation.ref.alias) > 0 do delete_key(bound_names, relation.ref.alias)
}

// plan_greedy_order completes an order that starts at `start` and reports what
// it expects to cost. It returns cost < 0 when the start cannot be extended,
// which only happens when the caller's order is inconsistent.
@(private)
plan_greedy_order :: proc(
	tx: ^Tx,
	relations: []Plan_Relation,
	dependencies: [][]int,
	start: int,
) -> (order: [dynamic]int, cost: f64) {
	order = make([dynamic]int, 0, len(relations))
	if start < 0 || start >= len(relations) do return order, -1
	bound := make([]bool, len(relations))
	bound_names := make(map[string]bool)
	defer delete(bound_names)
	partials: f64 = 1
	for len(order) < len(relations) {
		chosen := -1
		chosen_cost: f64
		chosen_kept: u64 = 1
		for relation, i in relations {
			if bound[i] do continue
			kept, probed := plan_candidate(tx, relations, dependencies, bound, bound_names, i)
			step := plan_step_cost(relation, kept, probed)
			if len(order) == 0 {
				// The first step has nothing to be filtered by: its ON, and every
				// other, waits for a relation it names.
				kept = relation.scan_rows
				step = f64(relation.scan_rows) * PLAN_SCAN_ROW
			}
			// What this step costs the plan as a whole is what one outer row
			// pays, times the rows reaching it.
			step = partials * step
			// Cheapest wins; the smaller relation breaks a tie so the same schema
			// always produces the same plan.
			if chosen < 0 || step < chosen_cost ||
			   (step == chosen_cost && relation.scan_rows < relations[chosen].scan_rows) {
				chosen = i
				chosen_cost = step
				chosen_kept = kept
			}
		}
		if chosen < 0 do return order, -1
		relation := relations[chosen]
		cost += chosen_cost
		bound[chosen] = true
		append(&order, chosen)
		plan_bind_relation(&bound_names, relation)
		// The rows this step hands the next one: what its filters keep, or the
		// whole relation when nothing can filter it yet.
		partials *= f64(max(chosen_kept, 1))
	}
	return order, cost
}

// plan_candidate estimates one relation as the next step: the rows it keeps and
// whether the executor can probe it. It looks at every ON condition that becomes
// answerable when this relation binds, not only its own — the executor probes
// with the condition the step carries, and the planner attaches conditions of
// other relations to the step that completes them.
@(private)
plan_candidate :: proc(
	tx: ^Tx,
	relations: []Plan_Relation,
	dependencies: [][]int,
	bound: []bool,
	bound_names: map[string]bool,
	candidate: int,
) -> (kept: u64, probed: bool) {
	relation := relations[candidate]
	kept = relation.scan_rows
	table, table_err := tx_table(tx, relation.ref.name)
	bound[candidate] = true
	step_ons := make([dynamic]^Expr)
	defer delete(step_ons)
	if relation.on != nil && plan_relation_answerable(candidate, dependencies, bound) {
		append(&step_ons, relation.on)
		kept = relation.matches
	}
	for other in 0 ..< len(relations) {
		if other == candidate || relations[other].on == nil do continue
		if !plan_relation_answerable(other, dependencies, bound) do continue
		append(&step_ons, relations[other].on)
		// A condition of another relation filters this one too: price it with the
		// same estimate the planner would give that condition on its own.
		if table_err.kind == .None && kept == relation.scan_rows {
			if estimated := plan_join_matches(tx.store, table, relations[other].on); estimated < kept {
				kept = estimated
			}
		}
	}
	bound[candidate] = false
	for on in step_ons {
		if plan_probe_ready(tx, relation, on, bound_names) do return kept, true
	}
	return kept, false
}

// plan_relation_answerable reports whether the ON condition of one relation can
// be evaluated at this point: every relation it names is already bound.
@(private)
plan_relation_answerable :: proc(index: int, dependencies: [][]int, bound: []bool) -> bool {
	if index >= len(dependencies) do return true
	for dependency in dependencies[index] {
		if dependency < 0 || dependency >= len(bound) do continue
		if !bound[dependency] do return false
	}
	return true
}

// plan_bind_relation records a relation as bound, under both its name and its
// alias, which is what a qualified column may spell.
@(private)
plan_bind_relation :: proc(bound_names: ^map[string]bool, relation: Plan_Relation) {
	bound_names[relation.ref.name] = true
	if len(relation.ref.alias) > 0 do bound_names[relation.ref.alias] = true
}

// plan_step_cost is what one outer row pays to take this step. A scan reads every
// row of the relation; a probe walks the tree to the key and reads only the rows
// it names. A relation whose ON cannot be answered yet is a cross join: it keeps
// every inner row, and it pays the scan either way.
@(private)
plan_step_cost :: proc(relation: Plan_Relation, kept: u64, probed: bool) -> f64 {
	rows := f64(max(kept, 1))
	if probed do return PLAN_PROBE + rows * PLAN_JOIN_ROW
	return f64(relation.scan_rows) * PLAN_SCAN_ROW + rows * PLAN_JOIN_ROW
}

// plan_probe_ready reports whether the executor will probe the inner side of this
// step: one equality in the ON names a column of this relation that leads an
// index, and the other side of it can be evaluated from the relations already
// bound. It is the plan's copy of what join_index_probe and join_probe_rows check
// before they stop scanning. The value side may still fail to coerce at run time,
// which only costs the scan the plan already paid for.
@(private)
plan_probe_ready :: proc(
	tx: ^Tx,
	relation: Plan_Relation,
	on: ^Expr,
	bound_names: map[string]bool,
) -> bool {
	if on == nil do return false
	table, table_err := tx_table(tx, relation.ref.name)
	if table_err.kind != .None || table == nil || table.paged != nil do return false
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(on, &conjuncts)
	for expr in conjuncts {
		binary, is_binary := expr^.(Binary_Expr)
		if !is_binary || binary.op != .Eq do continue
		// Either side may be the inner column; the other is the value to probe.
		sides := [2][2]^Expr{{binary.left, binary.right}, {binary.right, binary.left}}
		for side in sides {
			reference, is_column := side[0]^.(Column_Expr)
			if !is_column do continue
			if len(reference.table) > 0 && !plan_names_relation(reference.table, relation.ref) do continue
			column_index, found := schema_column_index(&table.schema, reference.name)
			if !found do continue
			leads := false
			for &index in table.indexes {
				if len(index.schema.columns) > 0 && index.schema.columns[0] == column_index {
					leads = true
					break
				}
			}
			if !leads do continue
			// The value side has to be readable from what is bound already, and it
			// must not be this relation's own row.
			if plan_names_self(side[1], relation.ref) do continue
			if plan_value_ready(side[1], bound_names) do return true
		}
	}
	return false
}

// plan_names_self reports whether an expression names the given relation.
@(private)
plan_names_self :: proc(expr: ^Expr, ref: Table_Ref) -> bool {
	qualifiers := make(map[string]bool)
	defer delete(qualifiers)
	if !plan_expr_qualifiers(expr, &qualifiers) do return false
	for name, _ in qualifiers {
		if plan_names_relation(name, ref) do return true
	}
	return false
}

// plan_value_ready reports whether an expression can be evaluated from the
// relations bound so far. An unqualified column is assumed to resolve: the
// engine rejects an ambiguous one, and a probe that fails to evaluate falls back
// to the scan.
@(private)
plan_value_ready :: proc(expr: ^Expr, bound_names: map[string]bool) -> bool {
	qualifiers := make(map[string]bool)
	defer delete(qualifiers)
	if !plan_expr_qualifiers(expr, &qualifiers) do return false
	for name, _ in qualifiers {
		if !bound_names[name] do return false
	}
	return true
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

// plan_view_relation prices a view by the relation its own query reads: a view is
// materialized when the statement runs, and a plan that estimated nothing would
// put it first in every join order. It gives up (ok = false) on a view it cannot
// read -- another view in its FROM is followed, a self-reference or an unreadable
// definition is not -- and the caller then keeps the default.
@(private)
plan_view_relation :: proc(
	store: ^Store,
	tx: ^Tx,
	ref: Table_Ref,
	on: ^Expr,
	params: []Value,
	depth: int,
) -> (relation: Plan_Relation, ok: bool) {
	if depth >= VIEW_MAX_DEPTH do return {}, false
	if len(ref.args) > 0 do return {}, false
	sql, found := view_sql(tx, ref.name)
	if !found do return {}, false
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None do return {}, false
	defer query_destroy(&query)
	inner, is_select := query.statement.(Select_Stmt)
	if !is_select do return {}, false
	base, base_err := tx_table(tx, inner.from.name)
	if base_err.kind != .None {
		nested, nested_ok := plan_view_relation(store, tx, inner.from, nil, params, depth + 1)
		if !nested_ok do return {}, false
		nested.ref = ref
		nested.on = on
		return nested, true
	}
	rows := stats_estimate_rows(store, base, inner.where_clause, params)
	scan_rows := u64(table_row_count(base))
	if stats, has_stats := stats_get(store, base.schema.name); has_stats do scan_rows = stats.rows
	matches := rows
	if on != nil do matches = plan_join_matches(store, base, on)
	if matches == 0 do matches = 1
	return Plan_Relation{ref = ref, on = on, rows = rows, scan_rows = scan_rows, matches = matches}, true
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
	params: []Value,
) -> Plan_Relation {
	table, table_err := tx_table(tx, ref.name)
	if table_err.kind != .None {
		// A view has no rows of its own until the statement runs. Its own FROM is
		// the one number that exists before that, so the plan borrows it.
		if estimated, priced := plan_view_relation(store, tx, ref, on, params, 0); priced {
			return estimated
		}
		return Plan_Relation{ref = ref, on = on}
	}
	predicate := filter
	if on != nil do predicate = on
	rows := stats_estimate_rows(store, table, predicate, params)
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
		column_index, ok := plan_conjunct_column_either(table, Table_Ref{name = table.schema.name}, expr)
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

// plan_conjunct_column_either is plan_conjunct_column for a condition that may
// name the relation on either side of the comparison: `b.x = a.id` divides by
// the distinct values of `a.id` whether it is written on the left or the right.
@(private)
plan_conjunct_column_either :: proc(table: ^Table, ref: Table_Ref, expr: ^Expr) -> (int, bool) {
	if binary, is_binary := expr^.(Binary_Expr); is_binary {
		#partial switch binary.op {
		case .Eq, .Lt, .Le, .Gt, .Ge:
		case:
			return -1, false
		}
		sides := [2]^Expr{binary.left, binary.right}
		for side in sides {
			column, is_column := side^.(Column_Expr)
			if !is_column do continue
			if !plan_names_relation(column.table, ref) do continue
			if index, found := schema_column_index(&table.schema, column.name); found {
				return index, true
			}
		}
		return -1, false
	}
	if between, is_between := expr^.(Between_Expr); is_between && !between.negated {
		column, is_column := between.operand^.(Column_Expr)
		if !is_column do return -1, false
		if !plan_names_relation(column.table, ref) do return -1, false
		return schema_column_index(&table.schema, column.name)
	}
	return -1, false
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
	case Case_Expr:
		if !plan_expr_qualifiers(e.operand, out) do return false
		for branch in e.branches {
			if !plan_expr_qualifiers(branch.condition, out) do return false
			if !plan_expr_qualifiers(branch.result, out) do return false
		}
		return plan_expr_qualifiers(e.fallback, out)
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
