package engine

import "core:slice"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

import "base:intrinsics"

// --- Streaming scan ---------------------------------------------------------

// Agg_Acc is one aggregate accumulated as rows stream past. It mirrors what
// eval_aggregate does over a materialized group, with the group replaced by a
// running value: count, sum, total, avg, min, max and group_concat.
Agg_Acc :: struct {
	call:       Call_Expr,
	name:       string,
	seen:       int,
	best:       Value,
	sum_int:    i64,
	sum_float:  f64,
	sum_128:    i128,
	uses_float: bool,
	uses_128:   bool,
	builder:    strings.Builder,
	list:       [dynamic]Value,
	has_text:   bool,
	separator:  string,
	sep_owned:  bool,
	// keys remembers the values a DISTINCT aggregate has already seen, so a
	// repeated one is skipped instead of folded twice. `fold_distinct` is a
	// separate flag because a map value cannot be compared against nil in Odin.
	keys:          map[string]bool,
	fold_distinct: bool,
}

// Agg_Stream is the set of aggregates a streaming scan is accumulating, plus the
// first row that passed the filter: a projection that mixes an aggregate with a
// plain column reads that row, the way a group aggregate reads the group.
Agg_Stream :: struct {
	accs:         [dynamic]Agg_Acc,
	first_values: []Value,
	first_id:     Row_Id,
	have_first:   bool,
}

@(private)
agg_stream_destroy :: proc(stream: ^Agg_Stream) {
	for &acc in stream.accs {
		value_deep_free(acc.best, context.allocator)
		for item in acc.list do value_deep_free(item, context.allocator)
		delete(acc.list)
		if acc.builder.buf != nil do strings.builder_destroy(&acc.builder)
		if acc.sep_owned do delete(acc.separator)
		agg_distinct_destroy(&acc.keys)
		// The lowered name the stream made for it.
		delete(acc.name)
	}
	delete(stream.accs)
	free_values(stream.first_values)
}

@(private)
agg_stream_lookup :: proc(stream: ^Agg_Stream, call: Call_Expr) -> ^Agg_Acc {
	for &acc in stream.accs {
		if !strings.equal_fold(acc.name, call.name) do continue
		if acc.call.star != call.star do continue
		if len(acc.call.args) != len(call.args) do continue
		if len(call.args) == 0 do return &acc
		if acc.call.args[0] == call.args[0] do return &acc
	}
	return nil
}

// agg_stream_add folds one row into every accumulator. The row context is the
// one the WHERE clause just used, so the aggregate argument sees the same values.
@(private)
agg_stream_add :: proc(row_ctx: ^Eval_Ctx, stream: ^Agg_Stream) -> Error {
	for &acc in stream.accs {
		if acc.call.star || len(acc.call.args) == 0 {
			acc.seen += 1
			continue
		}
		value, value_err := eval_expr(row_ctx, acc.call.args[0])
		if value_err.kind != .None do return value_err
		// array_agg keeps NULLs: they are elements of the array, as in
		// PostgreSQL. Every other aggregate skips them.
		if value.kind == .Null && acc.name != "array_agg" do continue
		if acc.fold_distinct {
			key := agg_distinct_key(collation_key_value(row_ctx, acc.call.args[0], value))
			_, repeated := acc.keys[key]
			if repeated {
				delete(key)
			} else {
				acc.keys[key] = true
			}
			if repeated do continue
		}
		acc.seen += 1
		switch acc.name {
		case "count":
		// counted above
		case "min", "max":
			if acc.best.kind == .Null {
				acc.best = value_clone(value, context.allocator)
			} else {
				order, comparable := value_compare(value, acc.best)
				if !comparable do return errf(.Invalid_Type, "%s() mixes incompatible types", acc.name)
				if (acc.name == "min" && order == .Less) || (acc.name == "max" && order == .Greater) {
					value_deep_free(acc.best, context.allocator)
					acc.best = value_clone(value, context.allocator)
				}
			}
		case "sum", "total", "avg":
			// SQLite adds a boolean as its integer and a text by its number.
			operand := sqlite_rules_on() ? sqlite_sum_operand(value) : value
			if !value_is_numeric(operand) {
				return errf(.Invalid_Type, "%s() expects numbers", acc.name)
			}
			if operand.kind == .Float {
				acc.uses_float = true
				number, _ := value_to_f64(operand)
				acc.sum_float += number
			} else if operand.kind == .Int128 || operand.kind == .Uint128 {
				if !acc.uses_128 {
					acc.uses_128 = true
					acc.sum_128 = i128(acc.sum_int)
				}
				acc.sum_128 += value_as_i128(operand)
			} else if acc.uses_float {
				number, _ := value_to_f64(operand)
				acc.sum_float += number
			} else if acc.uses_128 {
				number, _ := value_to_i64(operand)
				acc.sum_128 += i128(number)
			} else {
				number, _ := value_to_i64(operand)
				total, overflow := intrinsics.overflow_add(acc.sum_int, number)
				if overflow do return integer_overflow_error()
				acc.sum_int = total
			}
		case "array_agg":
			append(&acc.list, value_clone(value, context.allocator))
		case "group_concat", "string_agg":
			if !acc.has_text {
				if acc.builder.buf == nil do strings.builder_init(&acc.builder, context.allocator)
				acc.separator = ","
				if len(acc.call.args) == 2 {
					separator_value, sep_err := eval_expr(row_ctx, acc.call.args[1])
					if sep_err.kind != .None do return sep_err
					if separator_value.kind != .Null {
						acc.separator = value_format(separator_value, context.allocator)
						acc.sep_owned = true
					}
				}
				acc.has_text = true
			} else if len(acc.separator) > 0 {
				strings.write_string(&acc.builder, acc.separator)
			}
			piece := value_format(value, context.allocator)
			strings.write_string(&acc.builder, piece)
			delete(piece)
		}
	}
	return ERROR_NONE
}

@(private)
agg_stream_value :: proc(acc: ^Agg_Acc) -> (Value, Error) {
	switch acc.name {
	case "count":
		return value_int(i64(acc.seen)), ERROR_NONE
	case "min", "max":
		return value_clone(acc.best, context.allocator), ERROR_NONE
	case "total":
		return value_float(acc.sum_float), ERROR_NONE
	case "sum":
		if acc.seen == 0 do return value_null(), ERROR_NONE
		if acc.uses_float do return value_float(acc.sum_float), ERROR_NONE
		if acc.uses_128 do return value_int128(acc.sum_128), ERROR_NONE
		return value_int(acc.sum_int), ERROR_NONE
	case "avg":
		if acc.seen == 0 do return value_null(), ERROR_NONE
		total := acc.uses_float ? acc.sum_float : (acc.uses_128 ? f64(acc.sum_128) : f64(acc.sum_int))
		return value_float(total / f64(acc.seen)), ERROR_NONE
	case "group_concat", "string_agg":
		if !acc.has_text do return value_null(), ERROR_NONE
		return value_string(strings.clone(strings.to_string(acc.builder))), ERROR_NONE
	case "array_agg":
		if len(acc.list) == 0 do return value_null(), ERROR_NONE
		items := make([]Value, len(acc.list))
		for item, i in acc.list do items[i] = value_clone(item, context.allocator)
		return Value{kind = .Array, list = items}, ERROR_NONE
	}
	return {}, errf(.Internal, "unknown aggregate %s", acc.name)
}

Stream_Scan_Ctx :: struct {
	tx:       ^Tx,
	stmt:     ^Select_Stmt,
	params:   []Value,
	expanded: []^Expr,
	policies: ^[dynamic]Policy_Set,
	stream:   ^Agg_Stream,
	aggregate: bool,
	limit:    int,
	offset:   int,
	skipped:  int,
	rows:     ^[dynamic][]Value,
	base:     ^Table,
	alias:    string,
	err:      Error,
	now_us:   i64,
	// column_memo is the statement's, which every row's context shares.
	column_memo: ^map[^Expr]Column_Memo,
}

@(private)
stream_row_visit :: proc(raw: rawptr, row: Row) -> bool {
	scan := cast(^Stream_Scan_Ctx)raw
	if scan.err.kind != .None do return false
	// A streamed scan is a loop over rows like any other, so it answers an
	// interrupt (and a progress handler) between rows; it used to run to the end.
	if store_cancelled(scan.tx.store) {
		scan.err = errf(.Cancelled, "query cancelled")
		return false
	}
	// The slice lives on this frame: one allocation per row in the transaction
	// arena would make a streamed scan cost the table again in memory.
	one: [1]Source
	one[0] = Source{table = scan.base, row = row, alias = scan.alias}
	ctx := eval_context(Eval_Ctx {
		tx          = scan.tx,
		sources     = one[:],
		params      = scan.params,
		column_memo = scan.column_memo,
	})
	for &set in scan.policies^ {
		allowed, policy_err := policy_allows(&set, &ctx, false)
		if policy_err.kind != .None {
			scan.err = policy_err
			return false
		}
		if !allowed do return true
	}
	if scan.stmt.where_clause != nil {
		value, where_err := eval_expr(&ctx, scan.stmt.where_clause)
		if where_err.kind != .None {
			scan.err = where_err
			return false
		}
		if !value_is_truthy(value) do return true
	}
	scan.tx.rows_scanned += 1
	if scan.aggregate {
		if !scan.stream.have_first {
			// The accumulator outlives the row arena, so the row is cloned with
			// the same allocator the stream is destroyed with.
			clones := make([]Value, len(row.values))
			for value, i in row.values do clones[i] = value_clone(value, context.allocator)
			scan.stream.first_values = clones
			scan.stream.first_id = row.id
			scan.stream.have_first = true
		}
		if add_err := agg_stream_add(&ctx, scan.stream); add_err.kind != .None {
			scan.err = add_err
			return false
		}
		return true
	}
	if scan.limit == 0 do return false
	values := make([]Value, len(scan.expanded))
	for expr, i in scan.expanded {
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None {
			free_values(values[:i])
			scan.err = eval_err
			return false
		}
		values[i] = value_clone(value, context.allocator)
	}
	if scan.skipped < scan.offset {
		scan.skipped += 1
		free_values(values)
		return true
	}
	append(scan.rows, values)
	return !(scan.limit >= 0 && len(scan.rows^) >= scan.limit)
}

// sql_exec_stream_select answers the shapes a page scan can stream: one paged
// table, no join, no ORDER BY, no GROUP BY, no DISTINCT, no window and nothing
// staged in the transaction. Rows are filtered and projected as they leave the
// pages, so the table never sits in memory; LIMIT stops the scan early. When the
// first aggregate is not a plain projection call the query falls back to the
// materializing path (handled is false).

// select_count_only answers `SELECT count(*) FROM t` from the table's row count
// when nothing else can change it: one memory table, no WHERE, GROUP BY,
// HAVING, DISTINCT, ORDER BY, LIMIT or OFFSET, no row policy, no program
// function that could be called count, and nothing the transaction staged for
// the table. Anything else answers false and the statement runs as before.
@(private)
select_count_only :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	exec: Select_Stmt,
	base: ^Table,
	base_is_view: bool,
	system_name: bool,
	empty_row: bool,
	has_policies: bool,
) -> (Sql_Result, bool) {
	if base == nil || base.paged != nil || base_is_view || system_name || empty_row || has_policies do return {}, false
	if base.schema.without_rowid || exec.from.as_of != nil || exec.from.subquery != nil do return {}, false
	if len(stmt.joins) > 0 || len(stmt.compound) > 0 || stmt.where_clause != nil || len(stmt.group_by) > 0 do return {}, false
	if stmt.having != nil || stmt.is_distinct || len(stmt.order_by) > 0 || stmt.limit != nil || stmt.offset != nil do return {}, false
	if len(stmt.projections) != 1 || stmt.projections[0].star do return {}, false
	call, is_call := stmt.projections[0].expr^.(Call_Expr)
	if !is_call || !call.star || call.is_distinct || call.filter != nil || len(call.order_by) > 0 || len(call.args) > 0 do return {}, false
	if !strings.equal_fold(call.name, "count") do return {}, false
	if len(tx.store.functions) > 0 || len(tx.store.aggregates) > 0 do return {}, false
	if tx.state.dropped[exec.from.name] do return {}, false
	if _, staged := tx.state.writes[exec.from.name]; staged do return {}, false
	if _, created := tx.state.created[exec.from.name]; created do return {}, false
	if _, altered := tx.state.altered[exec.from.name]; altered do return {}, false
	count := 0
	it := rows_iter(&base.rows)
	for row in rows_next(&it) {
		if _, visible := row_values_at(row^, tx.read_seq); visible do count += 1
	}
	tx.rows_scanned += u64(count)
	// The column is named as the materializing path names it.
	probe := make([]Source, 1, tx.alloc)
	probe[0] = Source{table = base, alias = exec.from.alias}
	names := make([dynamic]string, 0, 1, tx.alloc)
	_ = expand_projections(probe, stmt.joins, stmt.projections, &names, tx.alloc)
	if len(names) != 1 {
		for name in names do delete(name)
		return {}, false
	}
	result := Sql_Result{kind = .Rows}
	result.columns = make([]string, 1)
	result.columns[0] = strings.clone(names[0])
	delete(names[0])
	result.rows = make([][]Value, 1)
	result.rows[0] = make([]Value, 1)
	result.rows[0][0] = value_int(i64(count))
	result.row_ids = make([]Row_Id, 1)
	result.row_ids[0] = NO_ROW_ID
	return result, true
}

@(private)
sql_exec_stream_select :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	params: []Value,
	base: ^Table,
	base_is_view: bool,
	system_name: bool,
) -> (result: Sql_Result, handled: bool, err: Error) {
	if base == nil || base.paged == nil || base_is_view || system_name do return {}, false, ERROR_NONE
	// A WITHOUT ROWID table is read in its key's order, which pages do not keep.
	if base.schema.without_rowid do return {}, false, ERROR_NONE
	if len(stmt.joins) != 0 || len(stmt.group_by) != 0 || len(stmt.order_by) != 0 do return {}, false, ERROR_NONE
	if stmt.is_distinct || stmt.having != nil || stmt.from.as_of != nil do return {}, false, ERROR_NONE
	if tx.state.dropped[stmt.from.name] do return {}, false, ERROR_NONE
	if writes, has := tx.state.writes[stmt.from.name]; has {
		if writes.truncated ||
		   srows_len(&writes.inserts) > 0 ||
		   len(writes.updates) > 0 ||
		   len(writes.deletes) > 0 {
			return {}, false, ERROR_NONE
		}
	}
	// An index answers a point or range query with a handful of rows, which is
	// cheaper than walking every page. The probe is the same one the main path
	// runs; only the answer is used here.
	if ids, indexed := index_candidates(tx, base, stmt.from.name, stmt.from.alias, stmt.where_clause, params); indexed {
		delete(ids)
		return {}, false, ERROR_NONE
	}

	now_us := statement_now(tx)
	statement := stmt
	stream := Agg_Stream{}
	defer agg_stream_destroy(&stream)
	probe := make([]Source, 1, tx.alloc)
	probe[0] = Source{table = base, alias = stmt.from.alias}
	columns := make([dynamic]string, 0, len(stmt.projections), tx.alloc)
	expanded := expand_projections(probe, stmt.joins, stmt.projections, &columns, tx.alloc)
	// The names are cloned in the heap and the result clones them again.
	defer for column in columns do delete(column)
	if len(expanded) == 0 do return {}, false, ERROR_NONE
	aggregate := false
	for expr in expanded {
		if _, is_window := expr^.(Window_Expr); is_window do return {}, false, ERROR_NONE
		if !expr_is_aggregate(expr) do continue
		call, direct := expr^.(Call_Expr)
		if !direct || !builtin_aggregate_name(call.name) || call.is_distinct {
			return {}, false, ERROR_NONE
		}
		if len(call.args) > 2 {
			return {}, false, ERROR_NONE
		}
		if len(call.args) == 2 {
			// Only group_concat/string_agg take a second argument.
			if !strings.equal_fold(call.name, "group_concat") &&
			   !strings.equal_fold(call.name, "string_agg") {
				return {}, false, ERROR_NONE
			}
		}
		// FILTER and an aggregate's ORDER BY choose and order the group's rows,
		// which the materializing path does.
		if call.filter != nil || len(call.order_by) > 0 do return {}, false, ERROR_NONE
		if strings.equal_fold(call.name, "json_group_array") ||
		   strings.equal_fold(call.name, "json_group_object") ||
		   strings.equal_fold(call.name, "jsonb_group_array") ||
		   strings.equal_fold(call.name, "jsonb_group_object") ||
		   strings.equal_fold(call.name, "median") ||
		   strings.equal_fold(call.name, "percentile") ||
		   strings.equal_fold(call.name, "percentile_cont") ||
		   strings.equal_fold(call.name, "percentile_disc") {
			// The streaming path folds one value per row; these build a document
			// from the whole group, so the materializing path answers them.
			return {}, false, ERROR_NONE
		}
		aggregate = true
		acc := Agg_Acc{call = call, name = strings.to_lower(call.name), fold_distinct = call.is_distinct}
		acc.uses_float = acc.name == "total"
		if acc.fold_distinct do acc.keys = make(map[string]bool)
		append(&stream.accs, acc)
	}

	limit := -1
	offset := 0
	if stmt.offset != nil {
		offset_ctx := eval_context(Eval_Ctx{tx = tx, params = params})
		value, value_err := eval_expr(&offset_ctx, stmt.offset)
		if value_err.kind != .None do return {}, false, value_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 do return {}, false, errf(.Invalid_Argument, "OFFSET must be a non-negative integer")
		offset = int(parsed)
	}
	if stmt.limit != nil {
		limit_ctx := eval_context(Eval_Ctx{tx = tx, params = params})
		value, value_err := eval_expr(&limit_ctx, stmt.limit)
		if value_err.kind != .None do return {}, false, value_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 do return {}, false, errf(.Invalid_Argument, "LIMIT must be a non-negative integer")
		limit = int(parsed)
	}

	policies := make([dynamic]Policy_Set)
	defer policy_sets_destroy(&policies)
	if !is_system_table(stmt.from.name) {
		set, policy_err := policy_load(tx, stmt.from.name)
		if policy_err.kind != .None do return {}, false, policy_err
		append(&policies, set)
	}

	rows := make([dynamic][]Value)
	defer {
		if err.kind != .None {
			for row in rows do free_values(row)
		}
		delete(rows)
	}
	scan_ctx := Stream_Scan_Ctx {
		tx        = tx,
		stmt      = &statement,
		params    = params,
		expanded  = expanded,
		policies  = &policies,
		stream    = &stream,
		aggregate = aggregate,
		limit     = limit,
		offset    = offset,
		rows      = &rows,
		base      = base,
		alias     = stmt.from.alias,
		now_us    = now_us,
		column_memo = column_memo_make(tx),
	}
	if scan_err := tx_scan_visit(tx, stmt.from.name, &scan_ctx, stream_row_visit); scan_err.kind != .None {
		return {}, false, scan_err
	}
	if scan_ctx.err.kind != .None do return {}, false, scan_ctx.err

	// One aggregate row is still subject to OFFSET and LIMIT, the same way the
	// materializing path cuts the single row it built.
	if aggregate && offset == 0 && limit != 0 {
		final := eval_context(Eval_Ctx{tx = tx, params = params, stream = &stream})
		if stream.have_first {
			final.sources = make([]Source, 1, tx.alloc)
			final.sources[0] = Source {
				table = base,
				row   = Row{id = stream.first_id, values = stream.first_values},
				alias = stmt.from.alias,
			}
		}
		values := make([]Value, len(expanded))
		for expr, i in expanded {
			value, eval_err := eval_expr(&final, expr)
			if eval_err.kind != .None {
				free_values(values[:i])
				return {}, false, eval_err
			}
			values[i] = value_clone(value, context.allocator)
		}
		append(&rows, values)
	}

	out := Sql_Result{kind = .Rows}
	out.columns = make([]string, len(columns))
	for column, i in columns do out.columns[i] = strings.clone(column)
	out.rows = make([][]Value, len(rows))
	copy(out.rows, rows[:])
	resize(&rows, 0)
	out.row_ids = make([]Row_Id, len(out.rows))
	for row in out.rows {
		for value in row do out.row_bytes += value_wire_size(value)
	}
	if quota := tx.store.max_rows_per_query; quota > 0 && u64(len(out.rows)) > quota {
		sql_result_destroy(&out)
		return {}, false, errf(.Quota_Exceeded, "query returns more than %d rows", quota)
	}
	// A statement is a unit of work: the host budget and the statement counter
	// see the same row count the materializing path reports.
	tx.store.stream_scans += 1
	return out, true, ERROR_NONE
}

sql_exec_select :: proc(tx: ^Tx, stmt: Select_Stmt, params: []Value) -> (Sql_Result, Error) {
	// A NATURAL join becomes the USING it stands for, now the tables are known.
	if select_has_natural_join(stmt) {
		resolved, natural_err := natural_joins_resolve(tx, stmt)
		if natural_err.kind != .None do return {}, natural_err
		return sql_exec_select(tx, resolved, params)
	}
	// A virtual table a program implements is offered this query's WHERE.
	saved_where, saved_params, saved_order := tx.vtab_where, tx.vtab_params, tx.vtab_order
	tx.vtab_where, tx.vtab_params = stmt.where_clause, params
	// The ORDER BY is offered when the query reads one relation.
	tx.vtab_order = len(stmt.joins) == 0 && len(stmt.compound) == 0 ? stmt.order_by : nil
	defer tx.vtab_where, tx.vtab_params, tx.vtab_order = saved_where, saved_params, saved_order
	// Derived tables are materialized first, under their names, for this select.
	if stmt.from.subquery != nil || select_has_derived_join(stmt) {
		scope := cte_scope_begin(tx)
		defer cte_scope_end(tx, &scope)
		refs := make([dynamic]Table_Ref, 0, 1 + len(stmt.joins), tx.alloc)
		append(&refs, stmt.from)
		for join in stmt.joins do append(&refs, join.table)
		for ref in refs {
			// A LATERAL derived table is not materialized here: it is evaluated
			// once per row of the sources to its left, in the join loop.
			if ref.subquery == nil || ref.lateral do continue
			table, derived_err := tx_materialize_cte(tx, Cte{name = ref.name, select_stmt = ref.subquery^}, params, false)
			if derived_err.kind != .None do return {}, derived_err
			cte_scope_bind(tx, &scope, ref.name, table)
		}
		inner := stmt
		inner.from.subquery = nil
		inner.joins = make([]Join_Clause, len(stmt.joins), tx.alloc)
		for join, i in stmt.joins {
			inner.joins[i] = join
			inner.joins[i].table.subquery = nil
		}
		return sql_exec_select(tx, inner, params)
	}
	if len(stmt.compound) > 0 do return sql_exec_compound(tx, stmt, params)
	// A collation the statement cannot honour is refused before a row exists: an
	// unknown name, or a host comparison where a folded key is required.
	if guard_err := select_collation_guard(tx, stmt); guard_err.kind != .None do return {}, guard_err
	// The planner may run the relations of a join in another order. The output
	// order of `SELECT *` stays the written one (star_sources below reads the
	// statement), so only what is executed moves.
	exec := stmt
	// A select's plan is kept for its statement: a subquery run for every row
	// of the query around it plans once.
	order: Plan_Order
	if planned, kept := tx.select_plans[stmt.id]; kept && stmt.id != 0 {
		order = planned
	} else {
		order = plan_join_order(tx.store, tx, stmt, params)
		if stmt.id != 0 {
			if tx.select_plans == nil do tx.select_plans = make(map[Node_Id]Plan_Order, 4, tx.alloc)
			tx.select_plans[stmt.id] = order
		}
	}
	if order.reordered {
		exec.from = order.from
		exec.joins = order.joins
	}
	// A SELECT without FROM evaluates its projections once against an empty row.
	// System tables are synthesized from the catalog instead of being scanned.
	empty_row := len(exec.from.name) == 0
	system_name := is_system_table(exec.from.name)
	synthetic: Table
	base: ^Table
	base_is_view := false
	if !empty_row && !system_name {
		base_args, args_err := view_args(tx, exec.from, params)
		if args_err.kind != .None do return {}, args_err
		source_table, source_view, table_err := tx_source_table(
			tx,
			exec.from.name,
			base_args,
			exec.from.schema,
		)
		if table_err.kind != .None do return {}, table_err
		base = source_table
		base_is_view = source_view
	}
	if system_name do base = &synthetic
	ctx := eval_context(Eval_Ctx {
		tx          = tx,
		params      = params,
		outer       = tx.outer,
		column_memo = column_memo_make(tx),
		// A row's sources are in the order the plan runs them.
		positions   = order.positions,
	})
	for join in stmt.joins {
		if len(join.using_columns) == 0 do continue
		shared := make([dynamic]string, 0, len(ctx.using_names) + len(join.using_columns), tx.alloc)
		for name in ctx.using_names do append(&shared, name)
		for name in join.using_columns do append(&shared, name)
		ctx.using_names = shared[:]
	}

	// A page-backed table can answer a simple single-table query without ever
	// holding it in memory: the scan streams, the projection runs per row and
	// LIMIT stops the scan. Anything the stream cannot answer exactly falls
	// through to the materializing path below.
	if stream_result, streamed, stream_err := sql_exec_stream_select(
		tx,
		stmt,
		params,
		base,
		base_is_view,
		system_name,
	); streamed {
		return stream_result, stream_err
	}

	// Row-level policies load once per statement. A denied row never reaches the
	// projection, an aggregate or the join output. They load before the join
	// because they also decide whether LIMIT can stop the scan (D23).
	policies := make([dynamic]Policy_Set)
	defer policy_sets_destroy(&policies)
	policy_tables := make([dynamic]string)
	defer delete(policy_tables)
	append(&policy_tables, stmt.from.name)
	for join in stmt.joins do append(&policy_tables, join.table.name)
	has_policies := false
	for name in policy_tables {
		if len(name) == 0 || is_system_table(name) do continue
		set, policy_err := policy_load(tx, name)
		if policy_err.kind != .None do return {}, policy_err
		if len(set.using_exprs) > 0 do has_policies = true
		append(&policies, set)
	}

	// `SELECT count(*) FROM t` counts the rows the transaction sees, as SQLite's
	// OP_Count counts the b-tree: building a source and folding an aggregate per
	// row cost 32 µs over 256 rows (28× SQLite).
	if counted, count_ok := select_count_only(tx, stmt, exec, base, base_is_view, system_name, empty_row, has_policies); count_ok {
		return counted, ERROR_NONE
	}

	// LIMIT n, on a statement that neither filters nor shrinks, means the scan can
	// stop as soon as it has n rows: nothing later in the scan can appear in the
	// answer. Zero means no pushdown (D23).
	limit_rows := 0
	if stmt.where_clause == nil && !has_policies && len(stmt.order_by) == 0 &&
	   !select_output_may_shrink(stmt) {
		limit_rows = select_row_limit(stmt, params)
	}

	// Base rows. A usable index narrows the scan; the WHERE clause is still
	// re-checked below.
	// The row sources of the statement, one list per combination of rows, live
	// in one arena that goes back to the pool when the statement ends: a scan
	// made and freed one small list per row, and the lists move between the
	// filter, the groups and the windows, so freeing each in the right place was
	// where the double frees and the leaks of this function came from.
	sources_arena: virtual.Arena
	if !query_arena_take(&sources_arena) do return {}, errf(.Out_Of_Memory, "cannot reserve the statement's row sources")
	defer query_arena_give(&sources_arena)
	sources_alloc := arena_allocator_guarded(&sources_arena)
	join_scratch := make([dynamic]Source)
	defer delete(join_scratch)
	partials := make([dynamic][]Source)
	used_index := false
	if system_name {
		synthetic.schema = system_table_schema(exec.from.name, tx.alloc)
		catalog_rows := system_table_rows(tx, exec.from.name, tx.alloc)
		for row in catalog_rows {
			one := make([]Source, 1, sources_alloc)
			one[0] = Source{table = base, row = row, alias = exec.from.alias}
			append(&partials, one)
		}
		used_index = true
	}
	if empty_row {
		append(&partials, make([]Source, 0, sources_alloc))
		used_index = true
	}
	// A historical read asks for the rows as they were at one commit. It cannot
	// use an index (the keys of that commit are not the live ones) and it ignores
	// the staged writes: it reads what committed.
	as_of_seq: u64 = 0
	if exec.from.as_of != nil {
		if base_is_view {
			return {}, errf(.Sql_Unsupported, "AS OF reads a table, not a view")
		}
		sequence, sequence_err := as_of_sequence(tx, exec.from.as_of, params)
		if sequence_err.kind != .None do return {}, sequence_err
		as_of_seq = sequence
	}
	// An index that matches the ORDER BY hands the rows over in order, so the sort
	// that follows has nothing to do.
	ordered_ids: [dynamic]Row_Id
	ordered := false
	if !base_is_view && !empty_row && as_of_seq == 0 && !system_name {
		if index, descending, ordered_ok := index_order_for(tx, base, exec.from, stmt); ordered_ok {
			// LIMIT lets the walk stop as soon as it has the rows the statement can
			// use, but only when nothing else can drop one: a filter or a policy is
			// applied after the walk, so it would leave the answer short.
			stop := 0
			if stmt.where_clause == nil && !select_filters_rows(tx, exec.from.name) {
				stop = select_row_limit(stmt, params)
			}
			ordered_ids = index_order_ids(base, index, descending, stop)
			ordered = true
			exec.order_by = nil
		}
	}
	if ordered {
		defer delete(ordered_ids)
		for id in ordered_ids {
			tx.rows_scanned += 1
			if row, exists := tx_get(tx, exec.from.name, id); exists {
				one := make([]Source, 1, sources_alloc)
				one[0] = Source{table = base, row = row, alias = exec.from.alias}
				append(&partials, one)
			}
		}
		used_index = true
	}
	// A view already holds a materialized table: scan it directly.
	if !base_is_view && !empty_row && as_of_seq == 0 && !ordered {
		if candidate_ids, used, fts_err := fts_scan_candidates(
			tx,
			exec.from.name,
			exec.from.alias,
			stmt.where_clause,
			params,
		); used {
			if fts_err.kind != .None {
				delete(partials)
				return {}, fts_err
			}
			defer delete(candidate_ids)
			for id in candidate_ids {
				tx.rows_scanned += 1
				if row, exists := tx_get(tx, exec.from.name, id); exists {
					one := make([]Source, 1, sources_alloc)
					one[0] = Source{table = base, row = row, alias = exec.from.alias}
					append(&partials, one)
				}
			}
			used_index = true
		} else if rowid_ids, by_rowid := rowid_candidates(tx, base, exec.from.name, exec.from.alias, stmt.where_clause, params, len(stmt.joins) > 0); by_rowid {
			defer delete(rowid_ids)
			for id in rowid_ids {
				tx.rows_scanned += 1
				if row, exists := tx_get(tx, exec.from.name, id); exists {
					one := make([]Source, 1, sources_alloc)
					one[0] = Source{table = base, row = row, alias = exec.from.alias}
					append(&partials, one)
				}
			}
			used_index = true
		} else if indexed_ids, indexed := index_candidates(tx, base, exec.from.name, exec.from.alias, stmt.where_clause, params); indexed {
			defer delete(indexed_ids)
			for id in indexed_ids {
				tx.rows_scanned += 1
				if row, exists := tx_get(tx, exec.from.name, id); exists {
					one := make([]Source, 1, sources_alloc)
					one[0] = Source{table = base, row = row, alias = exec.from.alias}
					append(&partials, one)
				}
			}
			used_index = true
		}
	}
	key_ordered := false
	if !used_index {
		rows := make([dynamic]Row)
		if base_is_view {
			table_collect(base, &rows, tx.read_seq)
		} else if as_of_seq > 0 {
			if collect_err := tx_collect_at(tx, exec.from.name, &rows, as_of_seq); collect_err.kind != .None {
				return {}, collect_err
			}
		} else if collect_err := tx_collect(tx, exec.from.name, &rows); collect_err.kind != .None {
			return {}, collect_err
		}
		// SQLite walks a WITHOUT ROWID table in its key's order.
		if !base_is_view && base != nil && base.schema.without_rowid {
			rows_sort_by_key(rows[:], base.schema.primary_key[:])
			key_ordered = true
		}
		for row in rows {
			tx.rows_scanned += 1
			one := make([]Source, 1, sources_alloc)
			one[0] = Source{table = base, row = row, alias = exec.from.alias}
			append(&partials, one)
			if limit_rows > 0 && len(partials) >= limit_rows do break
		}
		delete(rows)
	}
	if !empty_row && !ordered && !key_ordered {
		// A scan hands the rows over in id order already, and so does a single
		// rowid or a unique key: checking is one pass, sorting is many.
		sorted := true
		for i in 1 ..< len(partials) {
			if u64(partials[i - 1][0].row.id) > u64(partials[i][0].row.id) {
				sorted = false
				break
			}
		}
		if !sorted {
			slice.sort_by(partials[:], proc(a, b: []Source) -> bool {
				return u64(a[0].row.id) < u64(b[0].row.id)
			})
		}
	}

	// Nested-loop joins. Each partial is one bound combination of rows, and each
	// step carries the ON conditions that become answerable when it runs (which is
	// what lets the planner move a relation ahead of the join it was written in).
	join_counts_quota := !select_output_may_shrink(stmt)
	// The tables and aliases bound so far, so a RIGHT or FULL join can build a
	// row whose left side is NULL: every column of those sources is absent,
	// which is what the outer side of a join means.
	bound_tables := make([dynamic]^Table, 0, len(order.steps))
	bound_aliases := make([dynamic]string, 0, len(order.steps))
	defer {
		delete(bound_tables)
		delete(bound_aliases)
	}
	append(&bound_tables, base)
	append(&bound_aliases, exec.from.alias)
	for step, step_index in order.steps[1:] {
		// Only the last step can stop early: the rows it drops are rows later
		// steps would have joined.
		stop_at_limit := limit_rows > 0 && step_index == len(order.steps) - 2
		// Each table of a join may name its own commit (D3).
		step_as_of: u64 = 0
		if step.ref.as_of != nil {
			sequence, sequence_err := as_of_sequence(tx, step.ref.as_of, params)
			if sequence_err.kind != .None {
				delete(partials)
				return {}, sequence_err
			}
			step_as_of = sequence
		}
		// A JSON table function may take a column of the table before it, so it
		// is materialized once per outer row (a lateral join). Everything else is
		// collected once. The materialized tables stay in tx.temp_tables until the
		// statement ends, because the rows the join reads point into them.
		// A program's virtual table is read once per outer row too: its
		// arguments and its ON terms may read the row before it.
		lateral := is_json_table_function(step.ref.name) || is_pragma_function(step.ref.name) ||
			(step.ref.lateral && step.ref.subquery != nil) ||
			(len(step.ref.schema) == 0 && tx_table_probe(tx, step.ref.name) == nil && vtab_is_named(tx, step.ref.name))
		if lateral && (step.kind == .Right || step.kind == .Full) {
			delete(partials)
			return {}, errf(
				.Sql_Unsupported,
				"a RIGHT or FULL join cannot take a table function that depends on the row before it",
			)
		}
		table: ^Table
		join_is_view: bool
		rows := make([dynamic]Row)
		if !lateral {
			join_args, join_args_err := view_args(tx, step.ref, params)
			if join_args_err.kind != .None {
				delete(partials)
				return {}, join_args_err
			}
			resolved, resolved_is_view, join_err := tx_source_table(
				tx,
				step.ref.name,
				join_args,
				step.ref.schema,
			)
			if join_err.kind != .None {
				delete(partials)
				return {}, join_err
			}
			table = resolved
			join_is_view = resolved_is_view
			if join_is_view && step_as_of > 0 {
				delete(rows)
				delete(partials)
				return {}, errf(.Sql_Unsupported, "AS OF reads a table, not a view")
			}
			if join_is_view {
				table_collect(table, &rows, tx.read_seq)
			} else if step_as_of > 0 {
				if collect_err := tx_collect_at(tx, step.ref.name, &rows, step_as_of); collect_err.kind != .None {
					delete(rows)
					delete(partials)
					return {}, collect_err
				}
			} else if collect_err := tx_collect(tx, step.ref.name, &rows); collect_err.kind != .None {
				delete(partials)
				return {}, collect_err
			}
			if !join_is_view && table != nil && table.schema.without_rowid do rows_sort_by_key(rows[:], table.schema.primary_key[:])
		}
		// The inner side is probed when its ON clause binds a column that leads an
		// index: a nested loop then reads the rows the outer row matches instead
		// of the whole relation, once per outer row.
		probe: Index_Probe
		probe.index = -1
		// A historical step cannot probe: the index holds the live keys.
		if !lateral && !join_is_view && step_as_of == 0 {
			_, staged := tx.state.writes[step.ref.name]
			_, created := tx.state.created[step.ref.name]
			if !staged && !created {
				probe, _ = join_index_probe(table, step.ref.alias, step.predicate)
			}
		}
		next := make([dynamic][]Source)
		// A RIGHT or FULL join keeps a row of the inner side that nothing
		// matched, so the step remembers which rows those were.
		kept_inner: []bool
		if step.kind == .Right || step.kind == .Full {
			kept_inner = make([]bool, len(rows))
		}
		defer delete(kept_inner)
		for partial in partials {
			if store_cancelled(tx.store) {
				delete(rows)
				delete(partials)
				delete(next)
				return {}, errf(.Cancelled, "query cancelled")
			}
			lateral_rows := rows
			probe_rows: [dynamic]Row
			using_probe := false
			if probe.index >= 0 && step.kind != .Right && step.kind != .Full {
				if candidates, probed := join_probe_rows(
					tx,
					table,
					step.ref.name,
					probe,
					partial,
					&ctx,
				); probed {
					probe_rows = candidates
					lateral_rows = probe_rows
					using_probe = true
				}
			}
			if lateral && step.ref.subquery != nil {
				lateral_table, lateral_err := tx_materialize_lateral(tx, step.ref, params, partial)
				if lateral_err.kind != .None {
					delete(partials)
					delete(next)
					return {}, lateral_err
				}
				table = lateral_table
				lateral_rows = make([dynamic]Row)
				table_collect(lateral_table, &lateral_rows, tx.read_seq)
			} else if lateral {
				lateral_args, lateral_args_err := view_args(tx, step.ref, params, partial)
				if lateral_args_err.kind != .None {
					delete(partials)
					delete(next)
					return {}, lateral_args_err
				}
				saved_join, saved_sources, saved_alias := tx.vtab_join, tx.vtab_sources, tx.vtab_alias
				tx.vtab_join, tx.vtab_sources, tx.vtab_alias = step.predicate, partial, step.ref.alias
				lateral_table, _, lateral_err := tx_source_table(
					tx,
					step.ref.name,
					lateral_args,
					step.ref.schema,
				)
				tx.vtab_join, tx.vtab_sources, tx.vtab_alias = saved_join, saved_sources, saved_alias
				if lateral_err.kind != .None {
					delete(partials)
					delete(next)
					return {}, lateral_err
				}
				table = lateral_table
				lateral_rows = make([dynamic]Row)
				table_collect(lateral_table, &lateral_rows, tx.read_seq)
			}
			matched := false
			for row, row_index in lateral_rows {
				tx.rows_scanned += 1
				resize(&join_scratch, len(partial) + 1)
				candidate := join_scratch[:]
				copy(candidate, partial)
				candidate[len(partial)] = Source{table = table, row = row, alias = step.ref.alias}
				if step.predicate != nil {
					ctx.sources = candidate
					value, eval_err := eval_expr(&ctx, step.predicate)
					if eval_err.kind != .None {
						delete(rows)
						delete(partials)
						delete(next)
						return {}, eval_err
					}
					if !value_is_truthy(value) do continue
				}
				append(&next, slice.clone(candidate, sources_alloc))
				matched = true
				if kept_inner != nil do kept_inner[row_index] = true
				if stop_at_limit && len(next) >= limit_rows do break
				if join_counts_quota && quota_reached(tx, len(next)) {
					// A cross join materialises its intermediate before the
					// projection can count anything, so the quota has to fire
					// here: the rows being produced are the rows the query asked
					// for (D23).
					if lateral do delete(lateral_rows)
					if using_probe do delete(probe_rows)
					delete(rows)
					delete(partials)
					delete(next)
					return {}, errf(
						.Quota_Exceeded,
						"query builds more than %d rows",
						tx.store.max_rows_per_query,
					)
				}
			}
			if (step.kind == .Left || step.kind == .Full) && !matched {
				candidate := make([]Source, len(partial) + 1, sources_alloc)
				copy(candidate, partial)
				candidate[len(partial)] = Source{table = table, row = Row{}, alias = step.ref.alias}
				append(&next, candidate)
			}
			if lateral do delete(lateral_rows)
			if using_probe do delete(probe_rows)
			if stop_at_limit && len(next) >= limit_rows do break
		}
		// The other half of an outer join: every row of the inner side that no
		// left row matched answers with the left columns NULL.
		if step.kind == .Right || step.kind == .Full {
			for row, row_index in rows {
				if kept_inner[row_index] do continue
				candidate := make([]Source, len(bound_tables) + 1, sources_alloc)
				for bound, i in bound_tables {
					candidate[i] = Source{table = bound, row = Row{}, alias = bound_aliases[i]}
				}
				candidate[len(bound_tables)] = Source{table = table, row = row, alias = step.ref.alias}
				append(&next, candidate)
				if stop_at_limit && len(next) >= limit_rows do break
				if join_counts_quota && quota_reached(tx, len(next)) {
					delete(rows)
					delete(partials)
					delete(next)
					return {}, errf(
						.Quota_Exceeded,
						"query builds more than %d rows",
						tx.store.max_rows_per_query,
					)
				}
			}
		}
		append(&bound_tables, table)
		append(&bound_aliases, step.ref.alias)
		delete(rows)
		delete(partials)
		partials = next
	}

	// WHERE
	filtered := make([dynamic][]Source)
	for partial in partials {
		if store_cancelled(tx.store) {
			delete(partials)
			delete(filtered)
			return {}, errf(.Cancelled, "query cancelled")
		}
		keep := true
		ctx.sources = partial
		for &set in policies {
			allowed, policy_err := policy_allows(&set, &ctx, false)
			if policy_err.kind != .None {
				delete(partials)
				delete(filtered)
				return {}, policy_err
			}
			if !allowed {
				keep = false
				break
			}
		}
		if keep && stmt.where_clause != nil {
			value, eval_err := eval_expr(&ctx, stmt.where_clause)
			if eval_err.kind != .None {
				delete(partials)
				delete(filtered)
				return {}, eval_err
			}
			keep = value_is_truthy(value)
		}
		if keep do append(&filtered, partial)
	}
	delete(partials)

	// The written order, not the execution order: `SELECT *` must emit columns in
	// the order the query asked for, and a projection resolves names, not slots. The
	// first source is therefore resolved from the statement: `base` follows the
	// plan, which may have started at a different relation.
	star_sources := make([dynamic]Source)
	if !empty_row {
		from_table := base
		if !system_name && !strings.equal_fold(stmt.from.name, exec.from.name) {
			from_args, from_args_err := view_args(tx, stmt.from, params)
			if from_args_err.kind == .None {
				resolved, _, resolve_err := tx_source_table(
					tx,
					stmt.from.name,
					from_args,
					stmt.from.schema,
				)
				if resolve_err.kind == .None do from_table = resolved
			}
		}
		append(&star_sources, Source{table = from_table, alias = stmt.from.alias})
	}
	for join in stmt.joins {
		// A probe: a join on a table function or a view has no table here, and
		// building the error that says so would only be dropped.
		if table := tx_table_probe(tx, join.table.name); table != nil {
			append(&star_sources, Source{table = table, alias = join.table.alias})
		}
	}
	columns := make([dynamic]string, 0, len(stmt.projections))
	// The names are the statement's until the result copies them: a statement
	// that fails on the way frees them here.
	columns_kept := true
	defer if columns_kept {
		for column in columns do delete(column)
		delete(columns)
	}
	expanded := expand_projections(star_sources[:], stmt.joins, stmt.projections, &columns, tx.alloc)
	// The GROUP BY list is resolved here, while the sources are still around: it
	// may name a projection alias, and telling an alias from a column needs them.
	group_exprs := group_by_expressions(stmt, star_sources[:], tx.alloc)
	delete(star_sources)
	if len(expanded) == 0 {
		delete(filtered)
		return {}, errf(.Invalid_Argument, "SELECT has no projection")
	}

	aggregate := len(stmt.group_by) > 0
	if !aggregate {
		for expr in expanded {
			if expr_is_aggregate(expr) {
				aggregate = true
				break
			}
		}
	}
	if stmt.having != nil && !aggregate {
		delete(filtered)
		return {}, errf(.Sql_Unsupported, "HAVING needs GROUP BY or an aggregate")
	}
	window_positions := window_positions_of(expanded)
	defer delete(window_positions)
	// A window can also sit inside a larger projection, `sum(n) OVER () + 1`: its
	// answer then needs a slot of its own, behind the visible columns, and the
	// projection is evaluated after the windows are filled.
	nested_windows := make([dynamic]^Expr)
	for expr in expanded {
		if _, top := expr^.(Window_Expr); top do continue
		expr_collect_windows(expr, &nested_windows)
	}
	defer delete(nested_windows)
	has_windows := len(window_positions) > 0 || len(nested_windows) > 0
	// window_nodes is every window that needs filling, in cell order: the top-level
	// ones first (their slot is the projection index), then the nested ones (their
	// slot is behind the visible columns).
	window_nodes := make([dynamic]^Expr, 0, len(window_positions) + len(nested_windows))
	window_slot_list := make([dynamic]int, 0, len(window_positions) + len(nested_windows))
	window_slots := make(map[^Expr]int)
	defer {
		delete(window_nodes)
		delete(window_slot_list)
		delete(window_slots)
	}
	// needs_outer marks a projection that has to be evaluated once its windows are
	// filled, because evaluating it earlier would reach an unfilled window.
	needs_outer := make([]bool, len(expanded))
	defer delete(needs_outer)
	// Two passes, so a slot does not depend on the order the projections are walked:
	// every nested window is numbered behind the visible columns first, then the
	// list is built top-level windows first, nested ones after.
	for expr, position in expanded {
		if _, top := expr^.(Window_Expr); top {
			append(&window_nodes, expr)
			append(&window_slot_list, position)
			window_slots[expr] = position
			continue
		}
		inner := make([dynamic]^Expr)
		expr_collect_windows(expr, &inner)
		if len(inner) == 0 {
			delete(inner)
			continue
		}
		needs_outer[position] = true
		for node in inner {
			slot := len(expanded) + len(nested_windows)
			append(&nested_windows, node)
			append(&window_nodes, node)
			append(&window_slot_list, slot)
			window_slots[node] = slot
		}
		delete(inner)
	}
	if has_windows && aggregate {
		// A window reads its ORDER BY value once per partition to place a RANGE
		// frame, and beside GROUP BY that value may be an aggregate, which needs the
		// group rather than a row: the group is gone by the time a window is filled.
		// Every other frame shape reads keys that were captured per group.
		for node in window_nodes {
			window := node^.(Window_Expr)
			if window_frame_reads_values(window.frame) {
				delete(filtered)
				return {}, errf(
					.Sql_Unsupported,
					"a RANGE frame with an offset beside GROUP BY is not supported",
				)
			}
		}
	}
	window_cells := make([dynamic][dynamic]Window_Cell, 0, len(filtered))
	window_sources := make([dynamic][]Source, 0, len(filtered))
	// group_keep holds the groups whose windows are still pending: a grouped row
	// has no source behind it, and rebuilding its ORDER BY key after the windows
	// need the group the row came from.
	group_keep := make([dynamic][dynamic][]Source, 0, len(filtered))
	// kept_partials holds a grouped query's rows while its windows are pending:
	// the groups point at them (one row may sit in several, under GROUPING
	// SETS). The rows are the statement arena's; only the list is freed here.
	kept_partials: [dynamic][]Source
	defer delete(kept_partials)

	output := make([dynamic]Output_Row, 0, len(filtered))
	if aggregate {
		groups := make([dynamic][dynamic][]Source)
		// group_set_of says which set each group came from, so its row knows which
		// columns the set left out.
		group_set_of := make([dynamic]int)
		sets := select_group_sets(stmt, tx.alloc)
		if len(stmt.group_by) == 0 {
			group := make([dynamic][]Source, 0, len(filtered))
			for partial in filtered do append(&group, partial)
			append(&groups, group)
			append(&group_set_of, -1)
		} else {
			for set, set_index in sets {
				buckets := make(map[string][dynamic][]Source)
				keys := make([dynamic]string)
				// `SELECT dept AS d ... GROUP BY d` groups by what the projection
				// names; a name that is a column of a source still means the column.
				for partial in filtered {
					ctx.sources = partial
					w: Byte_Writer
					bw_init(&w)
					group_ok := true
					for expr_index in set {
						value, eval_err := eval_expr(&ctx, group_exprs[expr_index])
						if eval_err.kind != .None {
							bw_destroy(&w)
							group_ok = false
							break
						}
						// Texts a collation calls equal are one group.
						value_encode_key(&w, collation_key_value(&ctx, group_exprs[expr_index], value))
					}
					if !group_ok {
						for key in keys do delete(key)
						delete(keys)
						delete(buckets)
						delete(filtered)
						return {}, errf(.Invalid_Type, "GROUP BY expression failed")
					}
					// The key is cloned once, for a new group: the map keeps the first.
					if bucket, exists := &buckets[string(bw_bytes(&w))]; exists {
						append(bucket, partial)
					} else {
						key := strings.clone(string(bw_bytes(&w)))
						append(&keys, key)
						fresh: [dynamic][]Source
						append(&fresh, partial)
						buckets[key] = fresh
					}
					bw_destroy(&w)
				}
				slice.sort_by(keys[:], proc(a, b: string) -> bool {
					return text_compare(a, b) < 0
				})
				for key in keys {
					append(&groups, buckets[key])
					append(&group_set_of, set_index)
					delete(key)
				}
				delete(keys)
				delete(buckets)
			}
		}
		// Beside min() or max(), a bare column takes its value from a row they
		// chose, as in SQLite; otherwise from the group's first row.
		minmax := select_minmax_calls(expanded, stmt.having, context.temp_allocator)
		for group, group_number in groups {
			ctx.group = group[:]
			ctx.grouped = true
			ctx.grouping_exprs = group_exprs
			if set_index := group_set_of[group_number]; set_index >= 0 {
				ctx.grouping_missing = grouping_missing_for(sets[set_index], len(stmt.group_by), tx.alloc)
			} else {
				ctx.grouping_missing = nil
			}
			if len(group) > 0 {
				ctx.sources = group[0]
				if len(minmax) > 0 do ctx.sources = group[minmax_row(&ctx, minmax, group[:])]
			} else {
				ctx.sources = nil
			}
			cells, cells_err := window_row_cells(&ctx, window_nodes[:], has_windows)
			if cells_err.kind != .None {
				select_drop_groups(&output, &window_cells, &window_sources, &group_keep, &groups, &group_set_of, group_number)
				delete(filtered)
				return {}, cells_err
			}
			values := make([]Value, len(expanded) + len(nested_windows))
			for expr, i in expanded {
				// A top-level window, or a projection whose windows are still
				// unfilled, is a null here and is written after apply_windows.
				if needs_outer[i] || (has_windows && window_cell_for(window_positions, i) >= 0) {
					values[i] = value_null()
					continue
				}
				value, eval_err := eval_expr(&ctx, expr)
				if eval_err.kind != .None {
					free_values(values)
					window_cells_destroy(cells)
					select_drop_groups(&output, &window_cells, &window_sources, &group_keep, &groups, &group_set_of, group_number)
					delete(filtered)
					return {}, eval_err
				}
				values[i] = value_clone(value, context.allocator)
			}
			if stmt.having != nil {
				ctx.having_aliases = stmt.projections
				having, having_err := eval_expr(&ctx, stmt.having)
				ctx.having_aliases = nil
				if having_err.kind != .None {
					free_values(values)
					window_cells_destroy(cells)
					select_drop_groups(&output, &window_cells, &window_sources, &group_keep, &groups, &group_set_of, group_number)
					delete(filtered)
					return {}, having_err
				}
				if !value_is_truthy(having) {
					free_values(values)
					window_cells_destroy(cells)
					delete(group)
					continue
				}
			}
			// A group has no row behind it: every group key answers the same
			// tiebreak, which is what "unspecified order among equal groups" means.
			// With a window in the projection the keys are rebuilt once the window
			// values exist, which is why the group is kept.
			sort_key: []u8
			if !has_windows {
				sort_key = build_order_key(&ctx, stmt.order_by, expanded, values, columns[:], NO_ROW_ID)
			}
			append(
				&output,
				Output_Row{values = values, sort_key = sort_key, row_id = NO_ROW_ID},
			)
			if has_windows {
				append(&window_cells, cells)
				append(&group_keep, group)
			} else {
				ctx.grouped = false
				delete(group)
			}
		}
		delete(groups)
		delete(group_set_of)
		ctx.group = nil
		// A pending window needs the rows its groups point at until it is done.
		if has_windows {
			kept_partials = filtered
			filtered = nil
		}
	} else {
		for partial in filtered {
			ctx.sources = partial
			values := make([]Value, len(expanded) + len(nested_windows))
			cells, cells_err := window_row_cells(&ctx, window_nodes[:], has_windows)
			if cells_err.kind != .None {
				free_values(values)
				delete(filtered)
				select_drop_rows(&output, &window_cells, &window_sources, &group_keep)
				return {}, cells_err
			}
			for expr, i in expanded {
				// A top-level window, or a projection whose windows are still
				// unfilled, is a null here and is written after apply_windows.
				if needs_outer[i] || (has_windows && window_cell_for(window_positions, i) >= 0) {
					values[i] = value_null()
					continue
				}
				value, eval_err := eval_expr(&ctx, expr)
				if eval_err.kind != .None {
					free_values(values)
					delete(filtered)
					delete(cells)
					select_drop_rows(&output, &window_cells, &window_sources, &group_keep)
					return {}, eval_err
				}
				values[i] = value_clone(value, context.allocator)
			}
			row_id := len(partial) == 1 ? partial[0].row.id : NO_ROW_ID
			sort_key: []u8
			if has_windows {
				// The keys are built once the window values exist, so the sources
				// have to outlive the loop. A key built here as well was dropped
				// without being freed, one per row.
				append(&window_cells, cells)
				append(&window_sources, partial)
			} else {
				sort_key = build_order_key(&ctx, stmt.order_by, expanded, values, columns[:], row_id)
				delete(cells)
			}
			append(&output, Output_Row{values = values, sort_key = sort_key, row_id = row_id})
			// A statement with LIMIT or OFFSET bounds its own rows, and it asks
			// for fewer than it produces, so the quota cannot judge it here: the
			// post-check after the projection is the one that applies. Without
			// either, the rows being produced are the answer.
			if stmt.limit == nil && stmt.offset == nil && quota_reached(tx, len(output)) {
				// Stop where the rows appear: the rest of the scan is work the
				// caller has already said it does not want. `values` is not freed
				// here: the row was already appended to `output`, and the call
				// below frees what output holds. Freeing it a second time corrupts
				// the heap, which a release build reports as exit 116 with no
				// message at all.
				free_values_over_rows(&output)
				window_cell_rows_destroy(&window_cells)
				delete(window_sources)
				for kept in group_keep do delete(kept)
				delete(group_keep)
				delete(output)
				delete(filtered)
				return {}, errf(
					.Quota_Exceeded,
					"query returns more than %d rows",
					tx.store.max_rows_per_query,
				)
			}
		}
	}
	delete(filtered)

	if has_windows {
		// The window keys a host collation left open are filled before the
		// windows sort, and forgotten: those keys go with the cells.
		if ctx.host_slots != nil {
			host_order_resolve(tx.store, ctx.host_slots^[:])
			clear(ctx.host_slots)
		}
		if window_err := apply_windows(&ctx, window_nodes[:], window_slot_list[:], window_cells[:], output[:], window_sources[:]); window_err.kind != .None {
			free_values_over_rows(&output)
			window_cell_rows_destroy(&window_cells)
			delete(window_sources)
			for kept in group_keep do delete(kept)
			delete(group_keep)
			delete(output)
			return {}, window_err
		}
		// A projection that carried a window inside it is evaluated now, with the
		// answers in place: `sum(n) OVER () + 1` reads the slot instead of refusing.
		has_outer := false
		for needed in needs_outer do if needed do has_outer = true
		if has_outer {
			for &row, i in output {
				if aggregate {
					ctx.group = group_keep[i][:]
					ctx.grouped = true
					ctx.sources = len(group_keep[i]) > 0 ? group_keep[i][0] : nil
				} else {
					ctx.sources = window_sources[i]
				}
				ctx.window_slots = window_slots
				ctx.window_values = row.values
				for expr, position in expanded {
					if !needs_outer[position] do continue
					value, eval_err := eval_expr(&ctx, expr)
					if eval_err.kind != .None {
						ctx.window_values = nil
						ctx.window_slots = nil
						ctx.group = nil
						ctx.grouped = false
						ctx.sources = nil
						free_values_over_rows(&output)
						window_cell_rows_destroy(&window_cells)
						delete(window_sources)
						for kept in group_keep do delete(kept)
						delete(group_keep)
						delete(output)
						return {}, eval_err
					}
					row.values[position] = value_clone(value, context.allocator)
				}
				ctx.window_values = nil
				ctx.window_slots = nil
			}
			ctx.group = nil
			ctx.grouped = false
			ctx.sources = nil
		}
		// The slots behind the visible columns held the windows' answers for the
		// projections that read them. They are not columns of the result: free
		// them and cut the row back to what the statement projects, before ORDER
		// BY, DISTINCT and the answer are built. `--json` publishes every value a
		// row holds, so leaving them in made `sum(v) OVER () + 1` answer three
		// columns; the table renderer masked the extras with the column count.
		if len(nested_windows) > 0 {
			for &row in output {
				for i := len(expanded); i < len(row.values); i += 1 {
					value_deep_free(row.values[i], context.allocator)
				}
				row.values = row.values[:len(expanded)]
			}
		}
		// ORDER BY runs on the completed rows, so an alias that names a window
		// projection sorts on its value. A grouped row has no source behind it: its
		// group answers, which is what lets `ORDER BY count(*)` beside a window read
		// the aggregate rather than one row of the group.
		for &row, i in output {
			if aggregate {
				ctx.group = group_keep[i][:]
				ctx.grouped = true
				ctx.sources = len(group_keep[i]) > 0 ? group_keep[i][0] : nil
			} else {
				ctx.sources = window_sources[i]
			}
			row.sort_key = build_order_key(&ctx, stmt.order_by, expanded, row.values, columns[:], row.row_id)
		}
		ctx.group = nil
		ctx.grouped = false
		ctx.sources = nil
		window_cell_rows_destroy(&window_cells)
		delete(window_sources)
		for kept in group_keep do delete(kept)
		delete(group_keep)
	} else {
		// No window was filled, so none of these took an element: their headers are
		// the only thing left, and they were allocated with the statement.
		delete(window_cells)
		delete(window_sources)
		delete(group_keep)
	}

	if ctx.order_err.kind != .None {
		for row in output {
			free_values(row.values)
			delete(row.sort_key)
		}
		delete(output)
		return {}, ctx.order_err
	}
	if len(stmt.order_by) > 0 {
		if ctx.host_slots != nil do host_order_resolve(tx.store, ctx.host_slots^[:])
		slice.sort_by(output[:], proc(a, b: Output_Row) -> bool {
			return string(sort_key_bytes(a.sort_key)) < string(sort_key_bytes(b.sort_key))
		})
	}

	if stmt.is_distinct {
		seen := make(map[string]bool)
		// The map owns the first row's key of each group.
		defer {
			for key in seen do delete(key)
			delete(seen)
		}
		kept := make([dynamic]Output_Row, 0, len(output))
		for row in output {
			key := encode_output_key(distinct_key_values(&ctx, expanded, row.values))
			if key in seen {
				delete(key)
				free_values(row.values)
				delete(row.sort_key)
				continue
			}
			seen[key] = true
			append(&kept, row)
		}
		delete(output)
		output = kept
	}

	offset := 0
	limit := -1
	if stmt.offset != nil {
		value, eval_err := eval_expr(&ctx, stmt.offset)
		if eval_err.kind != .None do return {}, eval_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 {
			return {}, errf(.Invalid_Argument, "OFFSET must be a non-negative integer")
		}
		offset = int(parsed)
	}
	if stmt.limit != nil {
		value, eval_err := eval_expr(&ctx, stmt.limit)
		if eval_err.kind != .None do return {}, eval_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 {
			return {}, errf(.Invalid_Argument, "LIMIT must be a non-negative integer")
		}
		limit = int(parsed)
	}

	result := Sql_Result{kind = .Rows}
	// The projection names live in the transaction arena, and the result
	// outlives the transaction: clone them or the caller prints freed bytes.
	// The names in `columns` are owned by the statement - projection_name clones a
	// name or hands back an allocation - and the result keeps its own copy of each,
	// so both the strings and the array are freed here.
	result.columns = make([]string, len(columns))
	for column, i in columns {
		result.columns[i] = strings.clone(column)
		delete(column)
	}
	delete(columns)
	columns_kept = false
	rows_out := make([dynamic][]Value, 0, len(output))
	ids_out := make([dynamic]Row_Id, 0, len(output))
	for row, i in output {
		delete(row.sort_key)
		if i < offset {
			free_values(row.values)
			continue
		}
		if limit >= 0 && len(rows_out) >= limit {
			free_values(row.values)
			continue
		}
		append(&rows_out, row.values)
		append(&ids_out, row.row_id)
	}
	result.rows = make([][]Value, len(rows_out))
	copy(result.rows, rows_out[:])
	result.row_ids = make([]Row_Id, len(ids_out))
	copy(result.row_ids, ids_out[:])
	delete(rows_out)
	delete(ids_out)
	delete(output)
	for row in result.rows {
		for value in row do result.row_bytes += value_wire_size(value)
	}
	if quota := tx.store.max_rows_per_query; quota > 0 && u64(len(result.rows)) > quota {
		sql_result_destroy(&result)
		return {}, errf(.Quota_Exceeded, "query returns more than %d rows", quota)
	}
	return result, ERROR_NONE
}

Output_Row :: struct {
	values:   []Value,
	sort_key: []u8,
	// row_id is the stored row behind this output row (zero for joins,
	// aggregates and SELECT without FROM).
	row_id:   Row_Id,
}

@(private)
sort_key_bytes :: proc(key: []u8) -> []u8 {
	return key
}

expand_projections :: proc(
	sources: []Source,
	joins: []Join_Clause,
	projections: []Select_Item,
	columns: ^[dynamic]string,
	alloc: mem.Allocator,
) -> []^Expr {
	expanded := make([dynamic]^Expr, 0, len(projections), alloc)
	for item in projections {
		star_qualifier := ""
		is_star := item.star
		if !is_star && item.expr != nil {
			if star, ok := item.expr^.(Star_Expr); ok {
				is_star = true
				star_qualifier = star.table
			}
		}
		if is_star {
			for source, index in sources {
				qualifier := len(source.alias) > 0 ? source.alias : source.table.schema.name
				if len(star_qualifier) > 0 {
					if !qualifier_names(star_qualifier, source.table.schema.name, source.alias) do continue
				}
				// A `JOIN ... USING (c)` merges c: the right side does not repeat
				// it in `SELECT *`. A qualified `b.*` still lists every column of b.
				merged: []string
				if len(star_qualifier) == 0 && index > 0 && index - 1 < len(joins) {
					merged = joins[index - 1].using_columns
				}
				for column in source.table.schema.columns {
					if column.hidden || column_in_names(column.name, merged) do continue
					expr := new(Expr, alloc)
					expr^ = Column_Expr{table = qualifier, name = column.name}
					append(&expanded, expr)
					append(columns, strings.clone(column.name))
				}
			}
			continue
		}
		append(&expanded, item.expr)
		append(columns, projection_name(item))
	}
	return expanded[:]
}

// column_in_names reports whether a column appears in a list of names, the way
// SQL compares them: without case.
@(private)
column_in_names :: proc(name: string, names: []string) -> bool {
	for candidate in names {
		if strings.equal_fold(candidate, name) do return true
	}
	return false
}

@(private)
projection_name :: proc(item: Select_Item) -> string {
	if len(item.alias) > 0 do return strings.clone(item.alias)
	if item.expr != nil {
		if column, ok := item.expr^.(Column_Expr); ok {
			return strings.clone(column.name)
		}
	}
	// SQLite names an expression by its text; PostgreSQL, which the engine
	// follows unless the store asks otherwise, calls it ?column?.
	if store := statement_store(); store != nil && store.sqlite_names && len(item.text) > 0 {
		return strings.clone(item.text)
	}
	return result_own("?column?")
}

// build_order_key turns the ORDER BY clause of one output row into one byte
// string: ascending parts keep their order-preserving encoding, descending parts
// get every byte inverted. Comparing the strings then gives the requested order.
// The row id comes last as a tiebreaker, so rows that compare equal come back in
// the order they are stored -- the same row every run, which is what SQLite does
// and what a test needs.
@(private)
build_order_key :: proc(
	ctx: ^Eval_Ctx,
	order_by: []Order_Item,
	projections: []^Expr,
	values: []Value,
	names: []string,
	row_id: Row_Id,
) -> []u8 {
	if len(order_by) == 0 do return nil
	w: Byte_Writer
	bw_init(&w)
	first_slot := ctx.host_slots != nil ? len(ctx.host_slots^) : 0
	for item, term in order_by {
		value := eval_order_value(ctx, item.expr, projections, values, names)
		// An ordinal or an alias sorts under its projection's collation.
		target := order_target_expr(item.expr, projections, names)
		// A host collation cannot fold: the key keeps a slot for the value's rank.
		if host, is_host := host_order_collation(ctx, target); is_host {
			host_slot_append(ctx, &w, item, term, value, host)
			continue
		}
		// ORDER BY x COLLATE NOCASE sorts on the folded key.
		collation, has := collate_name(target)
		if !has {
			collation, has = column_collation(ctx, target)
		}
		if has && len(collation) > 0 {
			value = collate_ordered_value(value, collation)
		}
		order_key_append(&w, value, item)
	}
	write_be_u64(&w, u64(row_id))
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	bw_destroy(&w)
	if ctx.host_slots != nil {
		for &slot in ctx.host_slots^[first_slot:] do slot.key = out
	}
	return out
}

// order_key_append encodes one ORDER BY value so that comparing keys byte by
// byte gives the requested order: descending inverts the value's bytes, and an
// explicit NULLS FIRST/LAST puts a leading byte that decides where NULL goes,
// whatever the direction.
@(private)
order_key_append :: proc(w: ^Byte_Writer, value: Value, item: Order_Item) {
	if item.nulls != .Default {
		is_null := value.kind == .Null
		marker: u8 = 1
		if is_null do marker = item.nulls == .First ? 0 : 2
		append(&w.data, marker)
	}
	start := len(w.data)
	value_encode_key(w, value)
	if item.descending {
		for i in start ..< len(w.data) do w.data[i] = ~w.data[i]
	}
}

// collate_ordered_value folds a text value the way a collation sorts it.
@(private)
collate_ordered_value :: proc(v: Value, collation: string) -> Value {
	if v.kind != .String do return v
	if strings.equal_fold(collation, "nocase") {
		return value_string(strings.to_lower(v.s, context.temp_allocator))
	}
	if strings.equal_fold(collation, "rtrim") {
		return value_string(strings.trim_right(v.s, " "))
	}
	return v
}

// order_target_expr is the expression an ORDER BY term stands for: the
// projection an ordinal or an output name refers to, or the term itself.
@(private)
order_target_expr :: proc(expr: ^Expr, projections: []^Expr, names: []string) -> ^Expr {
	if literal, ok := expr^.(Literal_Expr); ok {
		if index, int_ok := value_to_i64(literal.value); int_ok && index >= 1 && index <= i64(len(projections)) {
			return projections[index - 1]
		}
	}
	if column, ok := expr^.(Column_Expr); ok && len(column.table) == 0 {
		for name, i in names {
			if i < len(projections) && strings.equal_fold(name, column.name) do return projections[i]
		}
	}
	return expr
}

@(private)
eval_order_value :: proc(
	ctx: ^Eval_Ctx,
	expr: ^Expr,
	projections: []^Expr,
	values: []Value,
	names: []string,
) -> Value {
	// An ordinal (ORDER BY 1) or an alias refers to the projection.
	if literal, ok := expr^.(Literal_Expr); ok {
		if index, int_ok := value_to_i64(literal.value); int_ok && index >= 1 && index <= i64(len(values)) {
			return values[index - 1]
		}
	}
	if column, ok := expr^.(Column_Expr); ok && len(column.table) == 0 {
		// The output name first: it is the alias when the projection has one,
		// and the column name otherwise.
		for name, i in names {
			if strings.equal_fold(name, column.name) {
				return values[i]
			}
		}
		for projected, i in projections {
			if other, other_ok := projected^.(Column_Expr); other_ok {
				if strings.equal_fold(other.name, column.name) {
					return values[i]
				}
			}
		}
	}
	value, eval_err := eval_expr(ctx, expr)
	if eval_err.kind != .None {
		// The statement answers this error once the keys are built. Sorting the
		// row as NULL instead made `ORDER BY no_such_column` (or a window function
		// in ORDER BY) return the rows unsorted with no word of why.
		if ctx.order_err.kind == .None {
			ctx.order_err = eval_err
		} else {
			error_free(&eval_err)
		}
		return value_null()
	}
	return value
}

// Output_Key is the exported form of the row identity used by diffs.
Output_Key :: proc(values: []Value) -> string {
	return encode_output_key(values)
}

@(private)
encode_output_key :: proc(values: []Value) -> string {
	return encode_output_key_alloc(values, context.allocator)
}

// agg_distinct_key encodes one aggregate argument so a value a DISTINCT
// aggregate already folded can be skipped. Numbers that compare equal key the
// same even across kinds: an integral float keys as its integer, the way SQLite
// compares them, so count(DISTINCT x) over 1 and 1.0 answers one.
@(private)
agg_distinct_key :: proc(value: Value) -> string {
	INTEGRAL_LIMIT :: f64(9.0e18)
	switch value.kind {
	case .Float:
		if value.f >= -INTEGRAL_LIMIT && value.f <= INTEGRAL_LIMIT {
			whole := i64(value.f)
			if f64(whole) == value.f do return encode_output_key([]Value{value_int(whole)})
		}
	case .Uint:
		if value.u <= u64(0x7fff_ffff_ffff_ffff) do return encode_output_key([]Value{value_int(i64(value.u))})
	case .Null, .Default, .Int, .Int128, .Uint128, .Bool, .String, .Bytes, .Timestamp, .Duration, .Uuid, .Identity, .Connection, .Array, .Product:
	}
	return encode_output_key([]Value{value})
}

// agg_distinct_destroy frees what a DISTINCT aggregate's key map owns. The map
// stores the string header only, so the bytes handed to it must outlive every
// lookup: freeing a key right after inserting it leaves the map pointing at freed
// memory, and a later comparison reads it.
@(private)
agg_distinct_destroy :: proc(keys: ^map[string]bool) {
	if keys^ == nil do return
	for key in keys do delete(key)
	delete(keys^)
}

// encode_output_key_alloc is encode_output_key with an explicit allocator, so a
// subscription can keep the key of a cached row next to its arena.
encode_output_key_alloc :: proc(values: []Value, alloc: mem.Allocator) -> string {
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for value in values {
		value_encode_key(&w, value)
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw), alloc)
	copy(out, raw)
	return string(out)
}

// group_by_expressions resolves the GROUP BY list, replacing a name that is only a
// projection alias with the expression it stands for. A name that is a column of a
// source keeps meaning the column, which is what SQL says and what a reader
// expects from `GROUP BY dept` once a projection happens to alias itself `dept`.
@(private)
group_by_expressions :: proc(
	stmt: Select_Stmt,
	sources: []Source,
	alloc: mem.Allocator,
) -> []^Expr {
	out := make([]^Expr, len(stmt.group_by), alloc)
	for expr, i in stmt.group_by {
		out[i] = expr
		reference, is_column := expr^.(Column_Expr)
		if !is_column do continue
		if len(reference.table) > 0 do continue
		// A column of a source wins over an alias of the same name.
		named_by_a_column := false
		for source in sources {
			if source.table == nil do continue
			if _, found := schema_column_index(&source.table.schema, reference.name); found {
				named_by_a_column = true
				break
			}
		}
		if named_by_a_column do continue
		for projection in stmt.projections {
			if len(projection.alias) > 0 {
				if strings.equal_fold(projection.alias, reference.name) {
					out[i] = projection.expr
					break
				}
			}
			// An unaliased projection names its column after the expression, so
			// `SELECT dept ... GROUP BY dept` needs no substitution.
		}
	}
	return out
}

// outer_column answers a column the inner sources do not have, by looking in the
// frames of the statement the query is written inside. The nearest frame wins, as
// SQL scoping says.
@(private)
outer_column :: proc(ctx: ^Eval_Ctx, name, table: string) -> (Value, bool) {
	frame := ctx.outer
	for frame != nil {
		found_value: Value
		found := false
		for source in frame.sources {
			if source.table == nil do continue
			if len(table) > 0 {
				if !qualifier_names(table, source.table.schema.name, source.alias) do continue
			} else if source.hidden_unqualified {
				continue
			}
			index, exists := schema_column_index(&source.table.schema, name)
			if !exists {
				// `alias.rowid` of an enclosing query is that row's rowid, as it
				// is in the query itself.
				if len(table) > 0 && rowid_alias_name(name) {
					if rowid, has_rowid := rowid_value(source); has_rowid do return rowid, true
				}
				continue
			}
			if found {
				// Ambiguous in this frame: the caller answers with its own error.
				return {}, false
			}
			found = true
			if index < len(source.row.values) {
				found_value = source.row.values[index]
			} else {
				found_value = value_null()
			}
		}
		if found do return found_value, true
		frame = frame.next
	}
	return {}, false
}

// subquery_run runs a subquery with the caller's row as an outer frame.
@(private)
subquery_run :: proc(ctx: ^Eval_Ctx, stmt: Select_Stmt) -> (Sql_Result, Error) {
	if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
	frame := Outer_Frame{sources = ctx.sources, next = ctx.outer}
	saved := ctx.tx.outer
	ctx.tx.outer = &frame
	result, err := sql_exec_select(ctx.tx, stmt, ctx.params)
	ctx.tx.outer = saved
	return result, err
}
