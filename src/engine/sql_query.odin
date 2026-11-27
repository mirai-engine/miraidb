package engine

import "core:fmt"
import "core:slice"
import "core:mem"
import "core:strings"

// Column_Memo is the column a reference names in a table's schema.
Column_Memo :: struct {
	schema: ^Table_Schema,
	index:  int,
}

// qualifier_names says whether a qualifier names a source: by its alias when it
// has one, by its table's name otherwise. A table given an alias is known by
// the alias alone, in SQLite and in PostgreSQL: `FROM q AS r` hides q, so a
// subquery that reads q under another name still reaches the enclosing query's
// q by that name. Every place that matches a qualifier asks this.
qualifier_names :: proc(qualifier, name, alias: string) -> bool {
	if len(alias) > 0 do return strings.equal_fold(qualifier, alias)
	return strings.equal_fold(qualifier, name)
}

// single_source_column finds the column a reference names when the context has
// one source, which is what a single-table statement evaluates its WHERE and
// projection with: there is no ambiguity to settle and no USING to share, so
// the name is looked up once per statement and remembered (column_memo, keyed
// by the reference and checked against the source's schema). Anything else
// answers false and the caller looks the name up as before. The memo is the
// statement's, made once where the statement starts (column_memo_make): a
// context made per row shares it and never makes its own, which would cost an
// allocation per row that lives as long as the transaction.
@(private)
single_source_column :: proc(ctx: ^Eval_Ctx, key: ^Expr, column: Column_Expr) -> (source: ^Source, index: int, ok: bool) {
	if len(ctx.sources) != 1 || ctx.tx == nil do return nil, -1, false
	source = &ctx.sources[0]
	if source.table == nil || source.hidden_unqualified do return nil, -1, false
	schema := &source.table.schema
	if ctx.column_memo != nil {
		if memo, found := ctx.column_memo[key]; found && memo.schema == schema do return source, memo.index, true
	}
	if len(column.table) > 0 {
		matches := qualifier_names(column.table, schema.name, source.alias)
		if !matches do return nil, -1, false
	}
	found: bool
	index, found = schema_column_index(schema, column.name)
	if !found do return nil, -1, false
	if ctx.column_memo != nil do ctx.column_memo[key] = Column_Memo{schema = schema, index = index}
	return source, index, true
}

// column_memo_make is a statement's column memo, in the transaction's arena.
@(private)
column_memo_make :: proc(tx: ^Tx) -> ^map[^Expr]Column_Memo {
	memo := new(map[^Expr]Column_Memo, tx.alloc)
	memo^ = make(map[^Expr]Column_Memo, 8, tx.alloc)
	return memo
}

// quota_reached reports whether `produced` rows are already past the store's row
// quota. It is checked where rows are produced, not when the result is finished,
// because a quota read after the fact cannot prevent the spike it exists to cap.
@(private)
quota_reached :: proc(tx: ^Tx, produced: int) -> bool {
	if tx == nil do return false
	quota := tx.store.max_rows_per_query
	return quota > 0 && u64(produced) > quota
}

// select_output_may_shrink reports whether the projection can emit fewer rows
// than the rows it reads: DISTINCT, GROUP BY/HAVING, an aggregate and a window
// all decide rows after the join. When none of them is present every kept row is
// an output row, so the row quota may fire while the join is still building,
// which is where the memory spike is (D23).
select_output_may_shrink :: proc(stmt: Select_Stmt) -> bool {
	if stmt.is_distinct || len(stmt.group_by) > 0 || stmt.having != nil do return true
	for item in stmt.projections {
		if item.star || item.expr == nil do continue
		if expr_is_aggregate(item.expr) do return true
		// Anywhere, not only at the top: `sum(v) OVER () + 1` needs every row just
		// as `sum(v) OVER ()` does, and a pushed-down LIMIT would stop the scan and
		// let the window answer from the rows it was allowed to read.
		if expr_has_window(item.expr) do return true
	}
	return false
}

// Outer_Frame is one level of a query written inside another: the sources of the
// statement the subquery belongs to. A correlated subquery, and a LATERAL
// subquery, read a column there when its own sources do not have it.
Outer_Frame :: struct {
	sources: []Source,
	next:    ^Outer_Frame,
}

// eval_context is how every evaluation context is made: it is given the
// fields its caller sets and takes the time from the statement, so one
// statement has one now however many contexts it makes (one per row in some
// paths). It is the one place that builds an Eval_Ctx.
eval_context :: proc(fields: Eval_Ctx) -> Eval_Ctx {
	ctx := fields
	ctx.now_us = statement_now(fields.tx)
	return ctx
}

// statement_now is the time of the statement `tx` runs: read once, then kept.
// Without a transaction (an index's expression, a SET) it is the clock's.
statement_now :: proc(tx: ^Tx) -> i64 {
	if tx == nil do return now_microseconds()
	if tx.statement_now_us == 0 do tx.statement_now_us = now_microseconds()
	return tx.statement_now_us
}

Eval_Ctx :: struct {
	// column_memo remembers, for a column reference, which column of the one
	// source it names (single_source_column), so a row does not look the name
	// up again: comparing every column's name, for every reference of every row,
	// was most of a filtered scan.
	column_memo: ^map[^Expr]Column_Memo,
	// using_names are the columns the query's JOIN ... USING (or NATURAL
	// JOIN) shares: an unqualified one is the join's, not ambiguous.
	using_names: []string,
	// having_aliases are the projections a HAVING may name by their alias,
	// as SQLite allows: a name no source has is looked up there.
	having_aliases: []Select_Item,
	// order_err is the first error an ORDER BY expression raised while the sort
	// keys were built; the statement returns it instead of sorting.
	order_err: Error,
	tx:      ^Tx,
	sources: []Source,
	group:   [][]Source,
	grouped: bool,
	// grouping_missing marks the GROUP BY entries the current grouping set left
	// out, in the order of `group_by`, and grouping_exprs are those entries. A
	// projection column that is one of them reads NULL, and GROUPING() answers the
	// mask; both are empty outside a grouped row.
	grouping_missing: []bool,
	grouping_exprs:   []^Expr,
	params:  []Value,
	now_us:  i64,
	// stream is set only while a streaming scan evaluates its final projection:
	// an aggregate then answers from its running accumulator instead of walking
	// a materialized group.
	stream: ^Agg_Stream,
	// window_values and window_slots are set while a projection that contains a
	// window is evaluated after the windows were filled: the node maps to the slot
	// that holds its answer, so `sum(n) OVER () + 1` reads the answer instead of
	// refusing. Both are nil everywhere else.
	window_values: []Value,
	window_slots:  map[^Expr]int,
	// outer is the stack of frames the query is written inside, innermost first.
	outer: ^Outer_Frame,
	// depth is how deep the evaluation is. The parser refuses a tree deeper than
	// MAX_EXPRESSION_DEPTH, so this only fires for a tree that arrived another way
	// (a stored view, a generated column, a policy); it is here so the failure is
	// an error instead of an overflow.
	depth:  int,
	// host_slots are the order key slots a host collation leaves to fill once
	// every row is known (collations.odin).
	host_slots: ^[dynamic]Host_Order_Slot,
	// index_store is the store an index expression evaluated outside a
	// transaction (index_eval) takes the program's functions from.
	index_store: ^Store,
}

// eval_function_store is the store whose program functions a call may reach.
@(private)
eval_function_store :: proc(ctx: ^Eval_Ctx) -> ^Store {
	if ctx.tx != nil do return ctx.tx.store
	return ctx.index_store
}

// rowid_alias_name reports SQLite's three spellings of a rowid, none of which is
// a column of the table unless the schema says so.
@(private)
rowid_alias_name :: proc(name: string) -> bool {
	return strings.equal_fold(name, "rowid") ||
		strings.equal_fold(name, "_rowid_") ||
		strings.equal_fold(name, "oid")
}

// rowid_value answers a rowid alias for one source. A single-column INTEGER
// PRIMARY KEY is the rowid in SQLite, and `last_insert_rowid` already makes that
// choice here, so `rowid` answers that column's value when there is one.
// Otherwise it is the engine's row id, which starts at zero where SQLite starts
// at one (docs/sqlite.md declares the difference). A source with no stored row
// behind it -- a join, an aggregate, SELECT without FROM -- has no rowid.
@(private)
rowid_value :: proc(source: Source) -> (Value, bool) {
	if source.table == nil do return {}, false
	if source.row.id == NO_ROW_ID do return {}, false
	// A WITHOUT ROWID table has no row id to name.
	if source.table.schema.without_rowid do return {}, false
	schema := &source.table.schema
	if len(schema.primary_key) == 1 {
		key := schema.primary_key[0]
		if key >= 0 && key < len(schema.columns) && schema.columns[key].type.kind == .Int {
			if key < len(source.row.values) {
				if key_value, ok := value_to_i64(source.row.values[key]); ok {
					return value_int(key_value), true
				}
			}
		}
	}
	return value_int(i64(source.row.id)), true
}


// sql_run_query executes a plain query or one prefixed with common table
// expressions, which are materialized for the life of the statement.
sql_run_query :: proc(tx: ^Tx, statement: Statement, params: []Value, names: mem.Allocator = {}) -> (Sql_Result, Error) {
	// A name that is not there is refused before a row is read (D37).
	statement := statement
	resolve_alloc := names.procedure != nil ? names : tx.alloc
	if resolve_err := sql_resolve_names(tx, &statement, resolve_alloc); resolve_err.kind != .None do return {}, resolve_err
	if select_stmt, ok := statement.(Select_Stmt); ok {
		return sql_exec_select(tx, select_stmt, params)
	}
	with_stmt, is_with := statement.(With_Stmt)
	if !is_with do return {}, errf(.Sql_Unsupported, "not a query")
	// A CTE's name lasts for its statement: inside a transaction the next
	// statement must see the table of that name again, not this query.
	scope := cte_scope_begin(tx)
	defer cte_scope_end(tx, &scope)
	for cte in with_stmt.ctes {
		table, cte_err := tx_materialize_cte(tx, cte, params, with_stmt.recursive)
		if cte_err.kind != .None do return {}, cte_err
		cte_scope_bind(tx, &scope, cte.name, table)
	}
	return sql_exec_select(tx, with_stmt.select_stmt, params)
}

@(private)
select_has_derived_join :: proc(stmt: Select_Stmt) -> bool {
	for join in stmt.joins {
		if join.table.subquery != nil && !join.table.lateral do return true
	}
	return false
}

// Cte_Scope remembers what each name a statement bound in `cte_tables` meant
// before, so the end of the statement puts it back.
Cte_Scope :: struct {
	names:    [dynamic]string,
	previous: [dynamic]^Table,
}

@(private)
cte_scope_begin :: proc(tx: ^Tx) -> Cte_Scope {
	return Cte_Scope{names = make([dynamic]string, 0, 2, tx.alloc), previous = make([dynamic]^Table, 0, 2, tx.alloc)}
}

@(private)
cte_scope_bind :: proc(tx: ^Tx, scope: ^Cte_Scope, name: string, table: ^Table) {
	key := strings.clone(name, tx.alloc)
	append(&scope.names, key)
	append(&scope.previous, tx.cte_tables[key] or_else nil)
	tx.cte_tables[key] = table
}

@(private)
cte_scope_end :: proc(tx: ^Tx, scope: ^Cte_Scope) {
	for i := len(scope.names) - 1; i >= 0; i -= 1 {
		if scope.previous[i] != nil {
			tx.cte_tables[scope.names[i]] = scope.previous[i]
		} else {
			delete_key(&tx.cte_tables, scope.names[i])
		}
	}
}

// tx_materialize_cte evaluates a common table expression into a temporary table
// the statement can read, the same way a view is materialized.
@(private)
tx_materialize_cte :: proc(tx: ^Tx, cte: Cte, params: []Value, recursive: bool) -> (^Table, Error) {
	if recursive && len(cte.select_stmt.compound) == 1 {
		return tx_materialize_recursive_cte(tx, cte, params)
	}
	result, exec_err := sql_exec_select(tx, cte.select_stmt, params)
	if exec_err.kind != .None do return nil, exec_err
	defer sql_result_destroy(&result)
	return materialize_result_table(tx, cte.name, cte.columns, &result)
}

// materialize_result_table turns a query result into a temporary table the rest of
// the statement can read, with the column names the statement gave it.
@(private)
materialize_result_table :: proc(
	tx: ^Tx,
	name: string,
	override: []string,
	result: ^Sql_Result,
) -> (^Table, Error) {
	columns := make([]Column, len(result.columns), tx.alloc)
	for column_name, i in result.columns {
		column := column_name
		if i < len(override) do column = override[i]
		columns[i] = Column {
			name = strings.clone(column, tx.alloc),
			type = view_column_type(result.rows, i),
		}
	}
	schema := Table_Schema {
		name    = strings.clone(name, tx.alloc),
		columns = columns,
	}
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	for row, i in result.rows {
		if insert_err := table_insert(table, Row_Id(i + 1), row); insert_err.kind != .None {
			table_destroy(table)
			return nil, insert_err
		}
	}
	append(&tx.temp_tables, table)
	return table, ERROR_NONE
}

// tx_materialize_lateral runs a LATERAL subquery with one row of the sources to
// its left bound, and answers it as a table.
@(private)
tx_materialize_lateral :: proc(
	tx: ^Tx,
	ref: Table_Ref,
	params: []Value,
	partial: []Source,
) -> (^Table, Error) {
	frame := Outer_Frame{sources = partial, next = tx.outer}
	saved := tx.outer
	tx.outer = &frame
	result, exec_err := sql_exec_select(tx, ref.subquery^, params)
	tx.outer = saved
	if exec_err.kind != .None do return nil, exec_err
	defer sql_result_destroy(&result)
	return materialize_result_table(tx, ref.name, nil, &result)
}

// clone_row_values copies a row onto the caller's allocator.
@(private)
clone_row_values :: proc(values: []Value, alloc: mem.Allocator) -> []Value {
	out := make([]Value, len(values), alloc)
	for value, i in values do out[i] = value_clone(value, alloc)
	return out
}

// compound_apply joins the rows of one more term to the result so far. Every
// operator but UNION ALL answers distinct rows; the result keeps the order in
// which its rows first appeared.
@(private)
compound_apply :: proc(rows: ^[dynamic][]Value, term: [][]Value, op: Compound_Op) {
	if op == .Union_All {
		for row in term do append(rows, clone_row_values(row, context.allocator))
		return
	}
	in_term := make(map[string]bool)
	defer {
		for key in in_term do delete(key)
		delete(in_term)
	}
	if op != .Union {
		for row in term {
			key := encode_output_key(row)
			if key in in_term {
				delete(key)
				continue
			}
			in_term[key] = true
		}
	}
	seen := make(map[string]bool)
	defer {
		for key in seen do delete(key)
		delete(seen)
	}
	kept := make([dynamic][]Value, 0, len(rows))
	for row in rows {
		key := encode_output_key(row)
		keep := !(key in seen)
		switch op {
		case .Intersect:
			keep = keep && key in in_term
		case .Except:
			keep = keep && !(key in in_term)
		case .Union, .Union_All:
		}
		if keep {
			seen[key] = true
			append(&kept, row)
		} else {
			delete(key)
			free_values(row)
		}
	}
	if op == .Union {
		for row in term {
			key := encode_output_key(row)
			if key in seen {
				delete(key)
				continue
			}
			seen[key] = true
			append(&kept, clone_row_values(row, context.allocator))
		}
	}
	delete(rows^)
	rows^ = kept
}

// sqlite_compound_sort puts distinct compound rows in the order SQLite's
// temporary index holds them: column by column, NULL first, then numbers by
// value, texts by the column's collation (the first COLLATE a term writes),
// then blobs by their bytes.
@(private)
sqlite_compound_sort :: proc(store: ^Store, rows: [][]Value, stmt: Select_Stmt) {
	Ctx :: struct {
		store:      ^Store,
		collations: []string,
	}
	// A column's collation is the first term's that writes one, left to
	// right, as SQLite picks it (multiSelectCollSeq).
	collations := make([]string, len(stmt.projections), context.temp_allocator)
	take :: proc(collations: []string, items: []Select_Item) {
		for item, i in items {
			if i >= len(collations) || len(collations[i]) > 0 || item.expr == nil do continue
			if name, ok := collate_name(item.expr); ok do collations[i] = name
		}
	}
	take(collations, stmt.projections)
	for part in stmt.compound do take(collations, part.select_stmt.projections)
	class :: proc(v: Value) -> int {
		#partial switch v.kind {
		case .Null:
			return 0
		case .Int, .Uint, .Float, .Bool, .Int128, .Uint128:
			return 1
		case .Bytes:
			return 3
		}
		return 2
	}
	compare :: proc(a, b: []Value, ctx: ^Ctx) -> int {
		for i in 0 ..< min(len(a), len(b)) {
			left, right := a[i], b[i]
			left_class, right_class := class(left), class(right)
			if left_class != right_class do return left_class < right_class ? -1 : 1
			switch left_class {
			case 1:
				if left.kind == .Int && right.kind == .Int {
					if left.i != right.i do return left.i < right.i ? -1 : 1
					continue
				}
				x, _ := value_to_f64(left)
				y, _ := value_to_f64(right)
				if x != y do return x < y ? -1 : 1
			case 2:
				if left.kind != .String || right.kind != .String {
					order, _ := value_compare(left, right)
					if order != .Equal do return order == .Less ? -1 : 1
					continue
				}
				collation := i < len(ctx.collations) ? ctx.collations[i] : ""
				if len(collation) > 0 {
					if compared, known := collation_compare(ctx.store, collation, left.s, right.s); known {
						if compared != 0 do return compared
						continue
					}
				}
				if order := text_compare(left.s, right.s); order != 0 do return order
			case 3:
				if order := text_compare(string(left.bytes), string(right.bytes)); order != 0 do return order
			}
		}
		return 0
	}
	ctx := Ctx{store = store, collations = collations}
	context.user_ptr = &ctx
	slice.stable_sort_by(rows, proc(a, b: []Value) -> bool {
		return compare(a, b, (^Ctx)(context.user_ptr)) < 0
	})
}

// sql_exec_compound evaluates a compound query left to right, as SQLite does:
// `a UNION b` keeps the distinct rows of both, `a UNION ALL b` appends b,
// `a INTERSECT b` keeps the distinct rows of a that b has, and `a EXCEPT b` the
// distinct rows of a that b lacks. The tail clauses (ORDER BY, LIMIT, OFFSET)
// apply to the result. When a tail exists the rows pass through a temporary
// table, which lets the ordinary select path order them.
@(private)
sql_exec_compound :: proc(tx: ^Tx, stmt: Select_Stmt, params: []Value) -> (Sql_Result, Error) {
	base := stmt
	base.compound = nil
	base.order_by = nil
	base.limit = nil
	base.offset = nil
	base.is_distinct = false
	first, first_err := sql_exec_select(tx, base, params)
	if first_err.kind != .None do return {}, first_err
	defer sql_result_destroy(&first)
	if len(first.columns) == 0 do return {}, errf(.Internal, "compound query without columns")

	rows := make([dynamic][]Value, 0, len(first.rows))
	defer {
		for row in rows do free_values(row)
		delete(rows)
	}
	for row in first.rows do append(&rows, clone_row_values(row, context.allocator))

	for part in stmt.compound {
		term := part.select_stmt
		term.compound = nil
		term.order_by = nil
		term.limit = nil
		term.offset = nil
		term.is_distinct = false
		result, term_err := sql_exec_select(tx, term, params)
		if term_err.kind != .None do return {}, term_err
		if len(result.columns) != len(first.columns) {
			sql_result_destroy(&result)
			return {}, errf(
				.Invalid_Argument,
				"each term of a compound query must return %d columns",
				len(first.columns),
			)
		}
		compound_apply(&rows, result.rows, part.op)
		sql_result_destroy(&result)
		// SQLite answers a UNION, INTERSECT or EXCEPT from the temporary index
		// it builds, so in that index's order; a UNION ALL after it appends.
		if part.op != .Union_All && sqlite_rules_on() do sqlite_compound_sort(tx.store, rows[:], stmt)
	}

	if len(stmt.order_by) == 0 && stmt.limit == nil && stmt.offset == nil {
		result := Sql_Result{kind = .Rows}
		result.columns = make([]string, len(first.columns))
		for name, i in first.columns do result.columns[i] = strings.clone(name, context.allocator)
		result.rows = make([][]Value, len(rows))
		copy(result.rows, rows[:])
		resize(&rows, 0)
		return result, ERROR_NONE
	}

	// Tail clauses: materialize the merged rows, then let the select path order
	// and cut them by reading the temporary table.
	name := fmt.aprintf("_union_%d", len(tx.temp_tables), allocator = tx.alloc)
	columns := make([]Column, len(first.columns), tx.alloc)
	for column_name, i in first.columns {
		// Two columns may share a name (`SELECT NULL, NULL`): the table's
		// columns are kept apart, and the answer takes the names back below.
		unique := column_name
		for other in first.columns[:i] {
			if strings.equal_fold(other, column_name) {
				unique = fmt.aprintf("%s:%d", column_name, i + 1, allocator = tx.alloc)
				break
			}
		}
		columns[i] = Column {
			name = strings.clone(unique, tx.alloc),
			type = view_column_type(rows[:], i),
		}
	}
	table, table_err := table_create(&Table_Schema{name = name, columns = columns})
	if table_err.kind != .None do return {}, table_err
	for row, i in rows {
		if insert_err := table_insert(table, Row_Id(i + 1), row); insert_err.kind != .None {
			table_destroy(table)
			return {}, insert_err
		}
	}
	append(&tx.temp_tables, table)
	tx.cte_tables[name] = table
	outer := Select_Stmt {
		projections = make([]Select_Item, 1, tx.alloc),
		from        = Table_Ref{name = name},
		order_by    = stmt.order_by,
		limit       = stmt.limit,
		offset      = stmt.offset,
	}
	outer.projections[0] = Select_Item{star = true}
	result, outer_err := sql_exec_select(tx, outer, params)
	if outer_err.kind != .None do return result, outer_err
	for column, i in first.columns {
		if i >= len(result.columns) || result.columns[i] == column do continue
		delete(result.columns[i])
		result.columns[i] = strings.clone(column)
	}
	return result, ERROR_NONE
}

// RECURSION_LIMIT bounds WITH RECURSIVE: a query that never stops adding rows
// fails after taking that many rows from its queue instead of running forever.
// SQLite has no bound. A store can lower it (Store.recursion_limit). It was a
// variable of the package that a test lowered to 25 for a moment, and a
// recursive query of another test on another thread failed at 25 steps.
RECURSION_LIMIT :: 1_000_000

// Recursive_Queued is a row waiting in a recursive query's queue, with its
// ORDER BY key when the query has one.
@(private)
Recursive_Queued :: struct {
	values: []Value,
	key:    []u8,
}

// tx_materialize_recursive_cte evaluates `base UNION [ALL] step` as SQLite does
// (https://sqlite.org/lang_with.html): the base's rows go into a queue; each
// row taken from it is added to the answer, and the step runs with the CTE's
// name reading that one row, its rows going into the queue. UNION queues a row
// only once; UNION ALL keeps every row. An ORDER BY makes the queue take the
// smallest row first, and LIMIT and OFFSET count the rows taken, so a LIMIT
// stops a recursion that would not end. The step used to read every row
// accumulated so far, at every step: counting to 3000 read 4.5 million rows
// (50 s), and UNION ALL dropped its duplicates.
@(private)
tx_materialize_recursive_cte :: proc(tx: ^Tx, cte: Cte, params: []Value) -> (^Table, Error) {
	base := cte.select_stmt
	parts := base.compound
	order_by := base.order_by
	limit_expr := base.limit
	offset_expr := base.offset
	base.compound = nil
	base.order_by = nil
	base.limit = nil
	base.offset = nil
	union_all := parts[0].op == .Union_All || parts[0].all
	limit, offset := -1, 0
	ctx := eval_context(Eval_Ctx{tx = tx, params = params})
	if limit_expr != nil {
		value, value_err := eval_expr(&ctx, limit_expr)
		if value_err.kind != .None do return nil, value_err
		parsed, ok := value_to_i64(value)
		if !ok do return nil, errf(.Invalid_Argument, "LIMIT must be an integer")
		// A negative LIMIT is no limit, as in SQLite.
		if parsed >= 0 do limit = int(parsed)
	}
	if offset_expr != nil {
		value, value_err := eval_expr(&ctx, offset_expr)
		if value_err.kind != .None do return nil, value_err
		parsed, ok := value_to_i64(value)
		if !ok do return nil, errf(.Invalid_Argument, "OFFSET must be an integer")
		if parsed > 0 do offset = int(parsed)
	}

	first, first_err := sql_exec_select(tx, base, params)
	if first_err.kind != .None do return nil, first_err
	defer sql_result_destroy(&first)
	if len(first.columns) == 0 do return nil, errf(.Internal, "recursive query without columns")

	columns := make([]Column, len(first.columns), tx.alloc)
	names := make([]string, len(first.columns), tx.alloc)
	for column_name, i in first.columns {
		name := column_name
		if i < len(cte.columns) do name = cte.columns[i]
		names[i] = name
		columns[i] = Column {
			name = strings.clone(name, tx.alloc),
			type = view_column_type(first.rows, i),
		}
	}
	table, table_err := table_create(&Table_Schema {
		name    = strings.clone(cte.name, tx.alloc),
		columns = columns,
	})
	if table_err.kind != .None do return nil, table_err
	append(&tx.temp_tables, table)
	// The step reads the row taken from the queue through the CTE's name: a
	// table of one row, emptied for each.
	current, current_err := table_create(&Table_Schema {
		name    = strings.clone(cte.name, tx.alloc),
		columns = columns,
	})
	if current_err.kind != .None do return nil, current_err
	append(&tx.temp_tables, current)
	key := strings.clone(cte.name, tx.alloc)
	tx.cte_tables[key] = current
	defer tx.cte_tables[key] = table

	seen := make(map[string]bool)
	queue := make([dynamic]Recursive_Queued)
	head := 0
	defer {
		for k in seen do delete(k)
		delete(seen)
		for queued in queue[head:] {
			free_values(queued.values)
			delete(queued.key)
		}
		delete(queue)
	}
	sequence := Row_Id(0)
	enqueue :: proc(
		ctx: ^Eval_Ctx,
		queue: ^[dynamic]Recursive_Queued,
		seen: ^map[string]bool,
		union_all: bool,
		order_by: []Order_Item,
		names: []string,
		sequence: ^Row_Id,
		values: []Value,
	) {
		if !union_all {
			row_key := encode_output_key(values)
			if row_key in seen^ {
				delete(row_key)
				return
			}
			seen^[row_key] = true
		}
		sequence^ += 1
		queued := Recursive_Queued{values = clone_values(values)}
		// Rows of the same key leave in the order they came: the sequence is
		// the key's last part.
		if len(order_by) > 0 do queued.key = build_order_key(ctx, order_by, nil, queued.values, names, sequence^)
		append(queue, queued)
	}
	for row in first.rows do enqueue(&ctx, &queue, &seen, union_all, order_by, names, &sequence, row)
	if ctx.order_err.kind != .None do return nil, ctx.order_err

	term := parts[0].select_stmt
	term.compound = nil
	term.order_by = nil
	term.limit = nil
	term.offset = nil
	recursion_limit := tx.store != nil && tx.store.recursion_limit > 0 ? tx.store.recursion_limit : RECURSION_LIMIT
	taken, added := 0, 0
	for head < len(queue) {
		if limit >= 0 && added >= limit do break
		if taken >= recursion_limit {
			return nil, errf(.Cancelled, "WITH RECURSIVE %s exceeded %d rows", cte.name, recursion_limit)
		}
		if len(order_by) > 0 {
			// The smallest key goes first; it trades places with the head.
			least := head
			for i in head + 1 ..< len(queue) {
				if string(queue[i].key) < string(queue[least].key) do least = i
			}
			queue[head], queue[least] = queue[least], queue[head]
		}
		row := queue[head]
		head += 1
		taken += 1
		defer {
			free_values(row.values)
			delete(row.key)
		}
		if taken > offset {
			if insert_err := table_insert(table, Row_Id(added + 1), row.values); insert_err.kind != .None {
				return nil, insert_err
			}
			added += 1
		}
		table_truncate(current)
		if insert_err := table_insert(current, 1, row.values); insert_err.kind != .None do return nil, insert_err
		result, term_err := sql_exec_select(tx, term, params)
		if term_err.kind != .None do return nil, term_err
		for produced in result.rows do enqueue(&ctx, &queue, &seen, union_all, order_by, names, &sequence, produced)
		sql_result_destroy(&result)
		if ctx.order_err.kind != .None do return nil, ctx.order_err
		// The rows already taken are dropped from the front now and then, so a
		// long recursion does not hold its whole history.
		if head >= 1024 && head * 2 >= len(queue) {
			remove_range(&queue, 0, head)
			head = 0
		}
	}
	return table, ERROR_NONE
}


@(private)
select_has_natural_join :: proc(stmt: Select_Stmt) -> bool {
	for join in stmt.joins do if join.natural do return true
	return false
}

// natural_joins_resolve gives `stmt` with each NATURAL join written as the
// USING over the names the table before it and the joined one share (none
// makes it a cross join), as SQLite reads it.
@(private)
natural_joins_resolve :: proc(tx: ^Tx, stmt: Select_Stmt) -> (Select_Stmt, Error) {
	out := stmt
	out.joins = make([]Join_Clause, len(stmt.joins), tx.alloc)
	copy(out.joins, stmt.joins)
	for &join, i in out.joins {
		if !join.natural do continue
		join.natural = false
		left := i == 0 ? out.from : out.joins[i - 1].table
		left_columns, left_known := relation_columns(tx, &left)
		right_columns, right_known := relation_columns(tx, &join.table)
		if !left_known || !right_known {
			return {}, errf(.Sql_Unsupported, "a NATURAL join needs the columns of both sides")
		}
		shared := make([dynamic]string, 0, 2, tx.alloc)
		for name in left_columns {
			for other in right_columns {
				if strings.equal_fold(name, other) {
					append(&shared, strings.clone(name, tx.alloc))
					break
				}
			}
		}
		join.using_columns = shared[:]
		left_name := len(left.alias) > 0 ? left.alias : left.name
		right_name := len(join.table.alias) > 0 ? join.table.alias : join.table.name
		condition: ^Expr
		for name in shared {
			l := new(Expr, tx.alloc)
			l^ = Column_Expr{table = left_name, name = name}
			r := new(Expr, tx.alloc)
			r^ = Column_Expr{table = right_name, name = name}
			equality := new(Expr, tx.alloc)
			equality^ = Binary_Expr{op = .Eq, left = l, right = r}
			if condition == nil {
				condition = equality
			} else {
				both := new(Expr, tx.alloc)
				both^ = Binary_Expr{op = .And, left = condition, right = equality}
				condition = both
			}
		}
		join.on = condition
		if len(shared) == 0 && join.kind == .Inner do join.kind = .Cross
	}
	return out, ERROR_NONE
}
