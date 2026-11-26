package engine

import "core:strings"
import "core:sync"

// --- INSERT / UPDATE / DELETE ----------------------------------------------

// find_conflict_row locates the row an UPSERT collided with: the primary key
// columns compared against the incoming values.
@(private)
find_conflict_row :: proc(tx: ^Tx, name: string, table: ^Table, values: []Value) -> (Row, bool) {
	if len(table.schema.primary_key) == 0 do return {}, false
	// The rows are the ones the transaction sees: a row it staged collides as
	// much as a committed one.
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := tx_collect(tx, name, &rows); collect_err.kind != .None {
		error_free(&collect_err)
		return {}, false
	}
	for row in rows {
		matches := true
		for position in table.schema.primary_key {
			if position >= len(row.values) || position >= len(values) {
				matches = false
				break
			}
			if !value_equal(row.values[position], values[position]) {
				matches = false
				break
			}
		}
		if matches do return row, true
	}
	return {}, false
}


// unique_conflicts collects the rows an INSERT OR REPLACE deletes: every row
// the transaction sees that shares a key with the proposed values in a unique
// index, a row it staged as much as a committed one. One row can collide under
// two indexes, so it is listed once.
@(private)
unique_conflicts :: proc(tx: ^Tx, name: string, table: ^Table, values: []Value) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id, 0, 2, tx.alloc)
	add :: proc(ids: ^[dynamic]Row_Id, id: Row_Id) {
		for existing in ids do if existing == id do return
		append(ids, id)
	}
	writes := tx.state.writes[name]
	committed := tx.store.tables[name]
	for idx, i in table.indexes {
		if !idx.unique do continue
		// The rules tx_check_unique keeps: a row outside a partial index, or a
		// key with a NULL, constrains nothing.
		if !index_row_included(table, i, values) do continue
		if index_key_has_null(table, i, values) do continue
		if index_host_collated(tx.store, table, i) {
			for id in tx_host_key_holders(tx, name, table, i, values) do add(&ids, id)
			continue
		}
		if writes != nil {
			if holder, taken := staged_holder(writes, staged_key(tx, table, i, values)); taken do add(&ids, holder)
		}
		if committed != nil && i < len(committed.indexes) {
			found := table_index_lookup(committed, i, values)
			defer delete(found)
			for id in found {
				// A committed row the transaction deleted no longer holds its
				// committed key, and one it rewrote holds it only if the new
				// values keep it.
				if writes != nil {
					if writes.deletes[id] do continue
					if staged, changed := writes.updates[id]; changed && !tx_rewrite_keeps_key(tx, table, i, staged, values) do continue
				}
				add(&ids, id)
			}
		}
	}
	return ids
}

// row_with_defaults gives a row with every DEFAULT the statement left implicit
// filled in, coerced to the column's type, as tx_insert would store it.
@(private)
row_with_defaults :: proc(tx: ^Tx, table: ^Table, values: []Value) -> []Value {
	out := make([]Value, len(values), tx.alloc)
	for value, i in values {
		out[i] = value
		if i >= len(table.schema.columns) do continue
		if value.kind != .Default {
			// A supplied value is looked up as the column stores it, after its
			// affinity: `22` into a TEXT key is the `'22'` a REPLACE replaces.
			if value.kind == .Null do continue
			if coerced, coerce_err := value_coerce_into(value, &table.schema, i); coerce_err.kind == .None {
				out[i] = coerced
			} else {
				error_free(&coerce_err)
			}
			continue
		}
		column := table.schema.columns[i]
		filled, fill_err := column_default_for_row(tx, column)
		if fill_err.kind != .None {
			error_free(&fill_err)
			out[i] = value_null()
			continue
		}
		coerced, coerce_err := value_coerce(filled, column.type)
		if coerce_err.kind != .None {
			error_free(&coerce_err)
			out[i] = filled
			continue
		}
		out[i] = coerced
	}
	return out
}

@(private)
returning_append :: proc(
	tx: ^Tx,
	result: ^Sql_Result,
	rows: ^[dynamic][]Value,
	returning: ^Returning,
	table: ^Table,
	row: Row,
) -> Error {
	if returning == nil do return ERROR_NONE
	if prepare_err := returning_prepare(result, returning, table); prepare_err.kind != .None do return prepare_err
	values := make([dynamic]Value, 0, len(result.columns))
	sources := [1]Source{Source{table = table, row = row}}
	ctx := Eval_Ctx{tx = tx, sources = sources[:], now_us = now_microseconds()}
	for item in returning.items {
		if item.star {
			for column in 0 ..< len(table.schema.columns) {
				value := column < len(row.values) ? row.values[column] : value_null()
				append(&values, value_clone(value, context.allocator))
			}
			continue
		}
		value, eval_err := eval_expr(&ctx, item.expr)
		if eval_err.kind != .None {
			for v in values do value_deep_free(v, context.allocator)
			delete(values)
			return eval_err
		}
		append(&values, value_clone(value, context.allocator))
	}
	append(rows, values[:])
	return ERROR_NONE
}

// returning_prepare makes `result` the rows of a RETURNING, with its columns,
// even when no row comes back: a statement that wrote nothing still answers
// an empty set of rows. A column is named as SQLite names it: its alias, the
// column a bare name reads, or the expression as written.
@(private)
returning_prepare :: proc(result: ^Sql_Result, returning: ^Returning, table: ^Table) -> Error {
	if returning == nil do return ERROR_NONE
	if result.kind != .Rows {
		names := make([dynamic]string, 0, len(returning.items))
		for item in returning.items {
			if item.star {
				for column in table.schema.columns do append(&names, strings.clone(column.name))
				continue
			}
			if column, is_column := item.expr^.(Column_Expr); is_column && column.table == "" {
				if _, found := schema_column_index(&table.schema, column.name); !found && !rowid_alias_name(column.name) {
					for name in names do delete(name)
					delete(names)
					return errf(.Column_Not_Found, "no such column: %s", column.name)
				}
			}
			name := item.alias
			if name == "" {
				if column, is_column := item.expr^.(Column_Expr); is_column {
					name = column.name
				} else {
					name = item.text
				}
			}
			append(&names, strings.clone(name))
		}
		result.kind = .Rows
		result.columns = names[:]
	}
	return ERROR_NONE
}


// sqlite_key_takes_null says whether a PRIMARY KEY column may hold NULL: under
// SQLite's rules it may in a rowid table, unless it is the INTEGER PRIMARY KEY
// that is the rowid, since SQLite kept the bug that allowed it (each NULL a
// distinct key). A WITHOUT ROWID table's key, and the engine's own, refuse it.
@(private)
sqlite_key_takes_null :: proc(store: ^Store, without_rowid: bool, declared: string, compound := false) -> bool {
	if store == nil || !store.sqlite_rules || without_rowid do return false
	if !compound && strings.equal_fold(strings.trim_space(declared), "integer") do return false
	return true
}

// ROWID_POSITION marks the INSERT column that names the rowid of a table with
// no INTEGER PRIMARY KEY.
@(private)
ROWID_POSITION :: -1

// rowid_alias_column is the INTEGER PRIMARY KEY that is a table's rowid.
@(private)
rowid_alias_column :: proc(schema: ^Table_Schema) -> (int, bool) {
	if schema.without_rowid || len(schema.primary_key) != 1 do return -1, false
	key := schema.primary_key[0]
	if key < 0 || key >= len(schema.columns) || schema.columns[key].type.kind != .Int do return -1, false
	return key, true
}

// insert_named_rowid reads the rowid an INSERT names: NULL leaves it to the
// table, an integer (or text or real that is one) is the row's id.
@(private)
insert_named_rowid :: proc(value: Value) -> (Row_Id, bool, Error) {
	if value.kind == .Null || value.kind == .Default do return 0, false, ERROR_NONE
	number, ok := value_to_i64(value)
	if !ok || (value.kind == .Float && f64(number) != value.f) {
		return 0, false, errf(.Invalid_Type, "datatype mismatch")
	}
	// Row ids here count from 1; SQLite's zero and negative rowids are not kept.
	if number < 1 do return 0, false, errf(.Sql_Unsupported, "a rowid below 1 is not supported")
	return Row_Id(number), true, ERROR_NONE
}

sql_exec_insert :: proc(tx: ^Tx, stmt: Insert_Stmt, params: []Value) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	column_count := len(table.schema.columns)
	positions: []int
	if len(stmt.columns) == 0 {
		positions = make([]int, column_count, tx.alloc)
		for i in 0 ..< column_count do positions[i] = i
	} else {
		positions = make([]int, len(stmt.columns), tx.alloc)
		for name, i in stmt.columns {
			index, found := schema_column_index(&table.schema, name)
			if !found && rowid_alias_name(name) && !table.schema.without_rowid {
				// The rowid: an INTEGER PRIMARY KEY is it, any other rowid
				// table stores it beside the row (ROWID_POSITION).
				if alias, has_alias := rowid_alias_column(&table.schema); has_alias {
					index, found = alias, true
				} else {
					positions[i] = ROWID_POSITION
					continue
				}
			}
			if !found {
				return {}, errf(.Column_Not_Found, "column %s does not exist in %s", name, stmt.table)
			}
			if table.schema.columns[index].generated {
				return {}, errf(
					.Invalid_Argument,
					"column %s is generated: it cannot be written directly",
					name,
				)
			}
			positions[i] = index
		}
	}
	ctx := Eval_Ctx {
		tx     = tx,
		params = params,
		now_us = now_microseconds(),
	}
	policies, policy_err := policy_load(tx, stmt.table)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	generated, generated_err := generated_plan_make(tx, table)
	if generated_err.kind != .None do return {}, generated_err
	defer generated_plan_destroy(&generated)
	insert_rows := stmt.rows
	// The query's result holds the values its literals point at, so it lives
	// until the statement ends; it was never freed, and every INSERT ... SELECT
	// left the whole result behind.
	query: Sql_Result
	defer sql_result_destroy(&query)
	if stmt.has_select {
		// The VALUES path is reused: each row the query produces becomes a row
		// of literals, so coercion, policies, UPSERT and RETURNING are shared.
		query_err: Error
		query, query_err = sql_exec_select(tx, stmt.select_stmt, params)
		if query_err.kind != .None do return {}, query_err
		rows := make([dynamic][]^Expr, 0, len(query.rows), tx.alloc)
		for row in query.rows {
			if len(row) != len(positions) {
				return {}, errf(
					.Invalid_Argument,
					"INSERT has %d columns but SELECT produced %d",
					len(positions),
					len(row),
				)
			}
			exprs := make([]^Expr, len(row), tx.alloc)
			for value, i in row {
				literal := new(Expr, tx.alloc)
				literal^ = Literal_Expr{value = value}
				exprs[i] = literal
			}
			append(&rows, exprs)
		}
		insert_rows = rows[:]
	}
	result := Sql_Result{kind = .Affected}
	returned := make([dynamic][]Value, 0, len(insert_rows))
	// A statement without RETURNING builds this and never fills it: the array is the
	// statement's, not the result's, unless the result takes it at the end.
	if stmt.returning == nil do defer delete(returned)
	for values_expr in insert_rows {
		if len(values_expr) != len(positions) {
			return {}, errf(
				.Invalid_Argument,
				"INSERT has %d columns but %d values",
				len(positions),
				len(values_expr),
			)
		}
		values := make([]Value, column_count, tx.alloc)
		for i in 0 ..< column_count do values[i] = value_default()
		named_row_id: Maybe(Row_Id)
		for expr, i in values_expr {
			value, eval_err := eval_expr(&ctx, expr)
			if eval_err.kind != .None do return {}, eval_err
			if positions[i] == ROWID_POSITION {
				row_id, named, row_id_err := insert_named_rowid(value)
				if row_id_err.kind != .None do return {}, row_id_err
				if named do named_row_id = row_id
				continue
			}
			values[positions[i]] = value
		}
		// Generated columns are computed from the row about to be stored, so a
		// caller never supplies them and CHECK sees the final values.
		if apply_err := generated_plan_apply(&ctx, &generated, table, values); apply_err.kind != .None {
			return {}, apply_err
		}
		// The stored row is already coerced, so the CHECK predicate sees the
		// values the table would hold. Under OR FAIL a row is its own unit: if it
		// fails, what it staged (a trigger's work included) is taken back and the
		// rows before it stay.
		// Without an OR of its own, the statement takes the ON CONFLICT of the
		// constraint the row breaks, so such a row is its own unit too.
		declares := !stmt.conflict_explicit && table_declares_resolution(table)
		row_fail, row_ignore, row_replace := stmt.conflict_fail, stmt.conflict_ignore, stmt.conflict_replace
		row_mark := row_fail || declares ? tx_statement_begin(tx) : 0
		tx.explicit_row_id, tx.has_explicit_row_id = named_row_id.? or_else 0, named_row_id != nil
		row_id, insert_err := tx_insert(tx, stmt.table, values)
		tx.has_explicit_row_id = false
		if declares && insert_err.kind != .None && conflict_skippable(insert_err.kind) {
			switch declared_resolution(tx, table, row_with_defaults(tx, table, values), insert_err) {
			case .Fail:
				row_fail = true
				tx.keep_partial = true
			case .Ignore:
				row_ignore = true
			case .Replace:
				if insert_err.kind == .Not_Null_Violation {
					// REPLACE on NOT NULL stores the column's default instead.
					if filled, ok := not_null_defaults(tx, table, values); ok {
						tx_statement_end(tx, row_mark, true)
						row_mark = tx_statement_begin(tx)
						error_free(&insert_err)
						tx.explicit_row_id, tx.has_explicit_row_id = named_row_id.? or_else 0, named_row_id != nil
						row_id, insert_err = tx_insert(tx, stmt.table, filled)
						tx.has_explicit_row_id = false
						values = filled
					}
				} else {
					row_replace = true
				}
			case .Rollback:
				tx.rollback_requested = true
			case .Abort:
			}
		}
		if row_fail || declares do tx_statement_end(tx, row_mark, insert_err.kind != .None)
		// A BEFORE trigger's RAISE(IGNORE): the row is skipped, the rest go on.
		if insert_err.kind == .Trigger_Ignore do continue
		if insert_err.kind != .None && row_ignore && conflict_skippable(insert_err.kind) {
			// INSERT OR IGNORE: the row breaks a constraint by itself and is skipped;
			// nothing of it was staged.
			error_free(&insert_err)
			continue
		}
		if insert_err.kind == .None {
			if fts_err := fts_index_if_virtual(tx, stmt.table, row_id, values, true); fts_err.kind != .None {
				return {}, fts_err
			}
			// A row that needed the ballast is the statement's last (D23).
			if oom_short() do return {}, oom_error()
		}
		if insert_err.kind != .None && row_replace {
			// INSERT OR REPLACE: delete what the new row collides with, on any
			// unique index, and insert again. SQLite counts one affected row and
			// fires no delete trigger, which is what happens here: the deletes go
			// through the staging layer, not through the DELETE statement.
			//
			// The duplicate-key answer explained the first attempt, and this branch
			// answers the statement instead: its message is freed here.
			// The conflicts are looked up with the row as it would be stored: a
			// column the statement left out holds its default, which a key or a
			// partial index's WHERE may read.
			conflicts := unique_conflicts(tx, stmt.table, table, row_with_defaults(tx, table, values))
			defer delete(conflicts)
			// Without a row to replace the failure stands; it used to be freed first
			// and the statement reported a row it never inserted.
			if len(conflicts) > 0 do error_free(&insert_err)
			// An omitted INTEGER PRIMARY KEY is chosen before the rows it
			// replaces go, as SQLite chooses it: one past the largest there was.
			if key, has_key := rowid_alias_column(&table.schema); has_key && len(conflicts) > 0 && !table.schema.columns[key].auto_increment {
				if values[key].kind == .Default || values[key].kind == .Null {
					values[key] = value_int(tx_next_int_key(table, tx.state.writes[stmt.table], key))
				}
			}
			for id in conflicts {
				if fts_err := fts_delete_if_virtual(tx, stmt.table, id); fts_err.kind != .None {
					return {}, fts_err
				}
				if delete_err := tx_delete_without_triggers(tx, stmt.table, id); delete_err.kind != .None {
					return {}, delete_err
				}
			}
			if len(conflicts) > 0 {
				row_id, insert_err = tx_insert(tx, stmt.table, values)
				if insert_err.kind == .None {
					if fts_err := fts_index_if_virtual(tx, stmt.table, row_id, values, true); fts_err.kind != .None {
						return {}, fts_err
					}
				}
			}
		}
		if insert_err.kind != .None {
			// UPSERT: a collision on the target columns is not an error.
			conflict, found := find_conflict_row(tx, stmt.table, table, row_with_defaults(tx, table, values))
			if !found do return {}, insert_err
			if stmt.conflict_do_nothing {
				error_free(&insert_err)
				continue
			}
			if len(stmt.conflict_assignments) == 0 do return {}, insert_err
			// DO UPDATE answers the statement: the collision is not its error.
			error_free(&insert_err)
			new_values := make([]Value, len(table.schema.columns), tx.alloc)
			for value, i in conflict.values do new_values[i] = value
			// Expressions see the stored row; `excluded` is the proposed row. The
			// excluded source is hidden from bare column names so `col` keeps
			// meaning the stored value, as SQLite does.
			conflict_source: [2]Source
			conflict_source[0] = Source{table = table, row = conflict}
			conflict_source[1] = Source{table = table, row = Row{values = values}, alias = "excluded", hidden_unqualified = true}
			ctx.sources = conflict_source[:]
			for assignment in stmt.conflict_assignments {
				index, found_column := schema_column_index(&table.schema, assignment.column)
				if !found_column {
					return {}, errf(.Column_Not_Found, "column %s does not exist in %s", assignment.column, stmt.table)
				}
				value, eval_err := eval_expr(&ctx, assignment.value)
				if eval_err.kind != .None do return {}, eval_err
				coerced, coerce_err := value_coerce_into(value, &table.schema, index)
				if coerce_err.kind != .None do return {}, coerce_err
				new_values[index] = coerced
			}
			saved_set := tx.update_set
			tx.update_set = assignment_columns(tx, stmt.conflict_assignments)
			update_err := tx_update(tx, stmt.table, conflict.id, new_values)
			tx.update_set = saved_set
			if update_err.kind != .None do return {}, update_err
			if fts_err := fts_index_if_virtual(tx, stmt.table, conflict.id, new_values, false); fts_err.kind != .None {
				return {}, fts_err
			}
			if returning := stmt.returning; returning != nil {
				if returning_err := returning_append(tx, &result, &returned, returning, table, Row{values = new_values}); returning_err.kind != .None {
					return {}, returning_err
				}
			}
			result.affected += 1
			continue
		}
		// last_insert_rowid reports the INTEGER PRIMARY KEY when there is one,
		// and the internal row id otherwise. The staged row carries the key the
		// engine assigned, which the proposed values may not.
		tx.store.last_row_id = i64(row_id)
		if len(table.schema.primary_key) == 1 {
			pk := table.schema.primary_key[0]
			if staged, exists := tx_get(tx, stmt.table, row_id); exists {
				if pk < len(staged.values) && table.schema.columns[pk].type.kind == .Int {
					if pk_value, pk_ok := value_to_i64(staged.values[pk]); pk_ok {
						tx.store.last_row_id = pk_value
					}
				}
			}
		}
		if len(policies.check_exprs) > 0 {
			if staged, exists := tx_get(tx, stmt.table, row_id); exists {
				check_source: [1]Source
				check_source[0] = Source{table = table, row = staged}
				ctx.sources = check_source[:]
				allowed, allow_err := policy_allows(&policies, &ctx, true)
				if allow_err.kind != .None do return {}, allow_err
				if !allowed {
					return {}, errf(.Permission_Denied, "insert into %s violates a policy", stmt.table)
				}
			}
		}
		if returning := stmt.returning; returning != nil {
			if staged, exists := tx_get(tx, stmt.table, row_id); exists {
				if returning_err := returning_append(tx, &result, &returned, returning, table, staged); returning_err.kind != .None {
					return {}, returning_err
				}
			}
		}
		result.affected += 1
	}
	if stmt.returning != nil {
		if prepare_err := returning_prepare(&result, stmt.returning, table); prepare_err.kind != .None do return {}, prepare_err
		result.rows = returned[:]
	}
	if counts_changes(stmt.table) {
		tx.store.last_changes = i64(result.affected)
		tx.store.total_changes += i64(result.affected)
	}
	return result, ERROR_NONE
}

// Merge_Change is one row a MERGE will write, kept until the scan is done: a
// mutation during the scan would move the rows the scan is reading.
@(private)
Merge_Change :: struct {
	delete: bool,
	id:     Row_Id,
	values: []Value,
}

// sql_exec_merge runs a MERGE: one row per target that the source matches (the
// first WHEN MATCHED clause whose condition holds updates or deletes it) and one
// per source row that matches no target (the first WHEN NOT MATCHED clause
// inserts it). A target row that two source rows would change is refused, as
// PostgreSQL refuses it: the same row cannot be affected twice by one statement.
@(private)
sql_exec_merge :: proc(tx: ^Tx, stmt: Merge_Stmt, params: []Value) -> (Sql_Result, Error) {
	target, target_err := tx_table(tx, stmt.target)
	if target_err.kind != .None do return {}, target_err
	source_table, source_is_view, source_err := tx_source_table(tx, stmt.source, nil)
	if source_err.kind != .None do return {}, source_err
	target_rows := make([dynamic]Row)
	defer delete(target_rows)
	if collect_err := tx_collect(tx, stmt.target, &target_rows); collect_err.kind != .None {
		return {}, collect_err
	}
	source_rows := make([dynamic]Row)
	defer delete(source_rows)
	if source_is_view {
		table_collect(source_table, &source_rows, tx.read_seq)
	} else if collect_err := tx_collect(tx, stmt.source, &source_rows); collect_err.kind != .None {
		return {}, collect_err
	}
	ctx := Eval_Ctx {
		tx     = tx,
		params = params,
		now_us = now_microseconds(),
	}
	policies, policy_err := policy_load(tx, stmt.target)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	generated, generated_err := generated_plan_make(tx, target)
	if generated_err.kind != .None do return {}, generated_err
	defer generated_plan_destroy(&generated)
	// The two rows are bound under the names the statement gave them.
	target_source := Source{table = target, alias = stmt.target_alias}
	source_source := Source{table = source_table, alias = stmt.source_alias}
	pair: [2]Source
	source_matched := make([]bool, len(source_rows), tx.alloc)
	changes := make([dynamic]Merge_Change, 0, len(target_rows), tx.alloc)
	inserts := make([dynamic][]Value, 0, len(source_rows), tx.alloc)
	affected := 0
	touched := make(map[Row_Id]bool, len(target_rows), tx.alloc)
	for target_row in target_rows {
		if store_cancelled(tx.store) do return {}, errf(.Cancelled, "statement cancelled")
		pair[0] = target_source
		pair[0].row = target_row
		for source_row, source_index in source_rows {
			pair[1] = source_source
			pair[1].row = source_row
			ctx.sources = pair[:]
			matches, match_err := eval_expr(&ctx, stmt.on)
			if match_err.kind != .None do return {}, match_err
			if !value_is_truthy(matches) do continue
			source_matched[source_index] = true
			for clause in stmt.clauses {
				if clause.kind == .Not_Matched_Insert do continue
				if clause.condition != nil {
					holds, holds_err := eval_expr(&ctx, clause.condition)
					if holds_err.kind != .None do return {}, holds_err
					if !value_is_truthy(holds) do continue
				}
				if clause.kind == .Matched_Delete {
					allowed, allow_err := policy_allows(&policies, &ctx, false)
					if allow_err.kind != .None do return {}, allow_err
					if !allowed {
						return {}, errf(.Permission_Denied, "delete from %s violates a policy", stmt.target)
					}
					if touched[target_row.id] {
						return {}, errf(
							.Invalid_Argument,
							"MERGE cannot affect row %d twice",
							target_row.id,
						)
					}
					touched[target_row.id] = true
					append(&changes, Merge_Change{delete = true, id = target_row.id})
					break
				}
				new_values := make([]Value, len(target.schema.columns), tx.alloc)
				for _, i in target.schema.columns do new_values[i] = target_row.values[i]
				for assignment in clause.assignments {
					index, found := schema_column_index(&target.schema, assignment.column)
					if !found {
						return {}, errf(
							.Column_Not_Found,
							"column %s does not exist in %s",
							assignment.column,
							stmt.target,
						)
					}
					value, value_err := eval_expr(&ctx, assignment.value)
					if value_err.kind != .None do return {}, value_err
					coerced, coerce_err := value_coerce_into(value, &target.schema, index)
					if coerce_err.kind != .None do return {}, coerce_err
					new_values[index] = coerced
				}
				if apply_err := generated_plan_apply(&ctx, &generated, target, new_values); apply_err.kind != .None {
					return {}, apply_err
				}
				checked: [1]Source
				checked[0] = Source{table = target, row = Row{values = new_values}}
				ctx.sources = checked[:]
				allowed, allow_err := policy_allows(&policies, &ctx, true)
				ctx.sources = pair[:]
				if allow_err.kind != .None do return {}, allow_err
				if !allowed {
					return {}, errf(.Permission_Denied, "update of %s violates a policy", stmt.target)
				}
				if touched[target_row.id] {
					return {}, errf(
						.Invalid_Argument,
						"MERGE cannot affect row %d twice",
						target_row.id,
					)
				}
				touched[target_row.id] = true
				append(&changes, Merge_Change{id = target_row.id, values = new_values})
				break
			}
		}
	}
	for source_row, source_index in source_rows {
		if source_matched[source_index] do continue
		// No target matched this source row: the NOT MATCHED clauses see it alone.
		pair[0] = Source{}
		pair[1] = source_source
		pair[1].row = source_row
		ctx.sources = pair[1:]
		for clause in stmt.clauses {
			if clause.kind != .Not_Matched_Insert do continue
			if clause.condition != nil {
				holds, holds_err := eval_expr(&ctx, clause.condition)
				if holds_err.kind != .None do return {}, holds_err
				if !value_is_truthy(holds) do continue
			}
			values := make([]Value, len(target.schema.columns), tx.alloc)
			for _, i in target.schema.columns do values[i] = value_default()
			if len(clause.columns) == 0 {
				if len(clause.values) != len(target.schema.columns) {
					return {}, errf(
						.Invalid_Argument,
						"MERGE inserts %d values into %s, which has %d columns",
						len(clause.values),
						stmt.target,
						len(target.schema.columns),
					)
				}
				for expression, i in clause.values {
					value, value_err := eval_expr(&ctx, expression)
					if value_err.kind != .None do return {}, value_err
					coerced, coerce_err := value_coerce_into(value, &target.schema, i)
					if coerce_err.kind != .None do return {}, coerce_err
					values[i] = coerced
				}
			} else {
				if len(clause.columns) != len(clause.values) {
					return {}, errf(
						.Invalid_Argument,
						"MERGE INSERT names %d columns but gives %d values",
						len(clause.columns),
						len(clause.values),
					)
				}
				for column, i in clause.columns {
					index, found := schema_column_index(&target.schema, column)
					if !found {
						return {}, errf(
							.Column_Not_Found,
							"column %s does not exist in %s",
							column,
							stmt.target,
						)
					}
					value, value_err := eval_expr(&ctx, clause.values[i])
					if value_err.kind != .None do return {}, value_err
					coerced, coerce_err := value_coerce_into(value, &target.schema, index)
					if coerce_err.kind != .None do return {}, coerce_err
					values[index] = coerced
				}
			}
			checked: [1]Source
			checked[0] = Source{table = target, row = Row{values = values}}
			ctx.sources = checked[:]
			allowed, allow_err := policy_allows(&policies, &ctx, true)
			ctx.sources = pair[1:]
			if allow_err.kind != .None do return {}, allow_err
			if !allowed {
				return {}, errf(.Permission_Denied, "insert into %s violates a policy", stmt.target)
			}
			append(&inserts, values)
			break
		}
	}
	// The changes land now, with the table no longer being scanned.
	for change in changes {
		if change.delete {
			if delete_err := tx_delete(tx, stmt.target, change.id); delete_err.kind != .None {
				return {}, delete_err
			}
			affected += 1
			continue
		}
		saved_set := tx.update_set
		tx.update_set = nil
		update_err := tx_update(tx, stmt.target, change.id, change.values)
		tx.update_set = saved_set
		if update_err.kind != .None do return {}, update_err
		if fts_err := fts_index_if_virtual(tx, stmt.target, change.id, change.values, false); fts_err.kind != .None {
			return {}, fts_err
		}
		affected += 1
	}
	for values in inserts {
		if _, insert_err := tx_insert(tx, stmt.target, values); insert_err.kind != .None {
			return {}, insert_err
		}
		affected += 1
	}
	if counts_changes(stmt.target) {
		tx.store.last_changes = i64(affected)
		tx.store.total_changes += i64(affected)
	}
	return Sql_Result{kind = .Affected, affected = affected, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

// assignment_columns names the columns a SET writes.
@(private)
assignment_columns :: proc(tx: ^Tx, assignments: []Assignment) -> []string {
	columns := make([]string, len(assignments), tx.alloc)
	for assignment, i in assignments do columns[i] = assignment.column
	return columns
}

sql_exec_update :: proc(tx: ^Tx, stmt: Update_Stmt, params: []Value) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	// With FROM, every target row is a candidate and the join decides.
	collect_where := stmt.where_clause
	if len(stmt.from.name) > 0 do collect_where = nil
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := collect_target_rows(tx, table, stmt.table, collect_where, params, &rows); collect_err.kind != .None {
		return {}, collect_err
	}
	join_table: ^Table = nil
	join_rows := make([dynamic]Row)
	defer delete(join_rows)
	update_generated, update_generated_err := generated_plan_make(tx, table)
	if update_generated_err.kind != .None do return {}, update_generated_err
	defer generated_plan_destroy(&update_generated)
	if len(stmt.from.name) > 0 {
		resolved, is_view, join_err := tx_source_table(tx, stmt.from.name, nil)
		if join_err.kind != .None do return {}, join_err
		join_table = resolved
		if is_view {
			table_collect(join_table, &join_rows, tx.read_seq)
		} else if collect_join_err := tx_collect(tx, stmt.from.name, &join_rows); collect_join_err.kind != .None {
			return {}, collect_join_err
		}
	}
	ctx := Eval_Ctx{tx = tx, params = params, now_us = now_microseconds(), column_memo = column_memo_make(tx)}
	policies, policy_err := policy_load(tx, stmt.table)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	affected := 0
	returned := make([dynamic][]Value, 0, len(rows))
	if stmt.returning == nil do defer delete(returned)
	result := Sql_Result{kind = .Affected}
	// The UPDATE OF triggers it fires read which columns the SET writes.
	saved_set := tx.update_set
	tx.update_set = assignment_columns(tx, stmt.assignments)
	defer tx.update_set = saved_set
	for row in rows {
		if store_cancelled(tx.store) {
			return {}, errf(.Cancelled, "statement cancelled")
		}
		source: [2]Source
		source[0] = Source{table = table, row = row}
		if join_table != nil {
			// The first join row that satisfies the WHERE updates the target row.
			matched := false
			for join_row in join_rows {
				source[1] = Source{table = join_table, row = join_row, alias = stmt.from.alias}
				ctx.sources = source[:]
				if stmt.where_clause != nil {
					value, eval_err := eval_expr(&ctx, stmt.where_clause)
					if eval_err.kind != .None do return {}, eval_err
					if !value_is_truthy(value) do continue
				}
				matched = true
				break
			}
			if !matched do continue
		} else {
			ctx.sources = source[:1]
			matched := true
			if stmt.where_clause != nil {
				value, eval_err := eval_expr(&ctx, stmt.where_clause)
				if eval_err.kind != .None do return {}, eval_err
				matched = value_is_truthy(value)
			}
			if !matched do continue
		}
		allowed, allow_err := policy_allows(&policies, &ctx, false)
		if allow_err.kind != .None do return {}, allow_err
		if !allowed do continue
		new_values := make([]Value, len(table.schema.columns), tx.alloc)
		for _, i in table.schema.columns {
			new_values[i] = row.values[i]
		}
		for assignment in stmt.assignments {
			index, found := schema_column_index(&table.schema, assignment.column)
			if !found {
				return {}, errf(
					.Column_Not_Found,
					"column %s does not exist in %s",
					assignment.column,
					stmt.table,
				)
			}
			if table.schema.columns[index].generated {
				return {}, errf(
					.Invalid_Argument,
					"column %s is generated: it cannot be written directly",
					assignment.column,
				)
			}
			value, eval_err := eval_expr(&ctx, assignment.value)
			if eval_err.kind != .None do return {}, eval_err
			coerced, coerce_err := value_coerce_into(value, &table.schema, index)
			if coerce_err.kind != .None do return {}, coerce_err
			new_values[index] = coerced
		}
		if apply_err := generated_plan_apply(&ctx, &update_generated, table, new_values); apply_err.kind != .None {
			return {}, apply_err
		}
		check_source: [1]Source
		check_source[0] = Source{table = table, row = Row{values = new_values}}
		ctx.sources = check_source[:]
		allowed, allow_err = policy_allows(&policies, &ctx, true)
		if allow_err.kind != .None do return {}, allow_err
		if !allowed {
			return {}, errf(.Permission_Denied, "update of %s violates a policy", stmt.table)
		}
		// Under OR FAIL and OR IGNORE a row is its own unit: if it breaks a
		// constraint, what it staged (a trigger's work included) is taken back.
		resolution := stmt.conflict
		declares := !stmt.conflict_explicit && table_declares_resolution(table)
		per_row := resolution == .Fail || resolution == .Ignore || resolution == .Replace || declares
		row_mark := per_row ? tx_statement_begin(tx) : 0
		update_err := tx_update(tx, stmt.table, row.id, new_values)
		if declares && update_err.kind != .None && conflict_skippable(update_err.kind) {
			resolution = declared_resolution(tx, table, new_values, update_err, row.id)
			if resolution == .Fail do tx.keep_partial = true
			if resolution == .Rollback do tx.rollback_requested = true
			if resolution == .Replace && update_err.kind == .Not_Null_Violation {
				if filled, ok := not_null_defaults(tx, table, new_values); ok {
					tx_statement_end(tx, row_mark, true)
					row_mark = tx_statement_begin(tx)
					error_free(&update_err)
					new_values = filled
					update_err = tx_update(tx, stmt.table, row.id, new_values)
				}
			}
		}
		if update_err.kind != .None && resolution == .Replace && (update_err.kind == .Duplicate_Unique || update_err.kind == .Duplicate_Primary_Key) {
			// UPDATE OR REPLACE: the rows the new values collide with go, without
			// delete triggers, and the row is written again.
			tx_statement_end(tx, row_mark, true)
			row_mark = tx_statement_begin(tx)
			conflicts := unique_conflicts(tx, stmt.table, table, new_values)
			replaced := false
			for id in conflicts {
				if id == row.id do continue
				if fts_err := fts_delete_if_virtual(tx, stmt.table, id); fts_err.kind != .None do return {}, fts_err
				if delete_err := tx_delete_without_triggers(tx, stmt.table, id); delete_err.kind != .None do return {}, delete_err
				replaced = true
			}
			delete(conflicts)
			if replaced {
				error_free(&update_err)
				update_err = tx_update(tx, stmt.table, row.id, new_values)
			}
		}
		if per_row do tx_statement_end(tx, row_mark, update_err.kind != .None)
		// A BEFORE trigger's RAISE(IGNORE): the row keeps its values.
		if update_err.kind == .Trigger_Ignore do continue
		if update_err.kind != .None && resolution == .Ignore && conflict_skippable(update_err.kind) {
			// UPDATE OR IGNORE: the row keeps its values and the statement goes on.
			error_free(&update_err)
			continue
		}
		if update_err.kind != .None {
			return {}, update_err
		}
		if oom_short() do return {}, oom_error()
		if fts_err := fts_index_if_virtual(tx, stmt.table, row.id, new_values, false); fts_err.kind != .None {
			return {}, fts_err
		}
		if returning_err := returning_append(tx, &result, &returned, stmt.returning, table, Row{values = new_values}); returning_err.kind != .None {
			return {}, returning_err
		}
		affected += 1
	}
	result.affected = affected
	if counts_changes(stmt.table) {
		tx.store.last_changes = i64(affected)
		tx.store.total_changes += i64(affected)
	}
	if stmt.returning != nil {
		if prepare_err := returning_prepare(&result, stmt.returning, table); prepare_err.kind != .None do return {}, prepare_err
		result.rows = returned[:]
	}
	return result, ERROR_NONE
}

sql_exec_delete :: proc(tx: ^Tx, stmt: Delete_Stmt, params: []Value) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	// With USING, every target row is a candidate and the join decides.
	collect_where := stmt.where_clause
	if len(stmt.using_ref.name) > 0 do collect_where = nil
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := collect_target_rows(tx, table, stmt.table, collect_where, params, &rows); collect_err.kind != .None {
		return {}, collect_err
	}
	using_table: ^Table = nil
	using_rows := make([dynamic]Row)
	defer delete(using_rows)
	if len(stmt.using_ref.name) > 0 {
		resolved, is_view, using_err := tx_source_table(tx, stmt.using_ref.name, nil)
		if using_err.kind != .None do return {}, using_err
		using_table = resolved
		if is_view {
			table_collect(using_table, &using_rows, tx.read_seq)
		} else if collect_using_err := tx_collect(tx, stmt.using_ref.name, &using_rows); collect_using_err.kind != .None {
			return {}, collect_using_err
		}
	}
	ctx := Eval_Ctx{tx = tx, params = params, now_us = now_microseconds(), column_memo = column_memo_make(tx)}
	policies, policy_err := policy_load(tx, stmt.table)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	affected := 0
	returned := make([dynamic][]Value, 0, len(rows))
	if stmt.returning == nil do defer delete(returned)
	result := Sql_Result{kind = .Affected}
	for row in rows {
		if store_cancelled(tx.store) {
			return {}, errf(.Cancelled, "statement cancelled")
		}
		source: [2]Source
		source[0] = Source{table = table, row = row}
		if using_table != nil {
			matched := false
			for using_row in using_rows {
				source[1] = Source{table = using_table, row = using_row, alias = stmt.using_ref.alias}
				ctx.sources = source[:]
				if stmt.where_clause != nil {
					value, eval_err := eval_expr(&ctx, stmt.where_clause)
					if eval_err.kind != .None do return {}, eval_err
					if !value_is_truthy(value) do continue
				}
				matched = true
				break
			}
			if !matched do continue
		} else {
			ctx.sources = source[:1]
			matched := true
			if stmt.where_clause != nil {
				value, eval_err := eval_expr(&ctx, stmt.where_clause)
				if eval_err.kind != .None do return {}, eval_err
				matched = value_is_truthy(value)
			}
			if !matched do continue
		}
		allowed, allow_err := policy_allows(&policies, &ctx, false)
		if allow_err.kind != .None do return {}, allow_err
		if !allowed do continue
		if returning_err := returning_append(tx, &result, &returned, stmt.returning, table, row); returning_err.kind != .None {
			return {}, returning_err
		}
		if fts_err := fts_delete_if_virtual(tx, stmt.table, row.id); fts_err.kind != .None {
			return {}, fts_err
		}
		if delete_err := tx_delete(tx, stmt.table, row.id); delete_err.kind != .None {
			// A BEFORE trigger's RAISE(IGNORE): the row stays.
			if delete_err.kind == .Trigger_Ignore do continue
			return {}, delete_err
		}
		if oom_short() do return {}, oom_error()
		affected += 1
	}
	result.affected = affected
	if counts_changes(stmt.table) {
		tx.store.last_changes = i64(affected)
		tx.store.total_changes += i64(affected)
	}
	if stmt.returning != nil {
		if prepare_err := returning_prepare(&result, stmt.returning, table); prepare_err.kind != .None do return {}, prepare_err
		result.rows = returned[:]
	}
	return result, ERROR_NONE
}

// collect_target_rows gathers the rows an UPDATE or DELETE must consider. It
// narrows the scan through an index when the WHERE clause allows it.
@(private)
collect_target_rows :: proc(
	tx: ^Tx,
	table: ^Table,
	table_name: string,
	predicate: ^Expr,
	params: []Value,
	out: ^[dynamic]Row,
) -> Error {
	if candidate_ids, used := index_candidates(tx, table, table_name, "", predicate, params); used {
		defer delete(candidate_ids)
		for id in candidate_ids {
			if row, exists := tx_get(tx, table_name, id); exists {
				append(out, row)
			}
		}
		rows_sort_by_id(out[:])
		return ERROR_NONE
	}
	return tx_collect(tx, table_name, out)
}

// --- DDL -------------------------------------------------------------------

TYPE_TABLE :: "_type"
TYPE_SCHEMA_SQL :: "CREATE TABLE IF NOT EXISTS _type (name TEXT PRIMARY KEY, base TEXT NOT NULL)"

// --- Generated columns -----------------------------------------------------

// Generated_Plan holds the parsed expressions of a table's generated columns.
// It is built once per statement so a row only evaluates them.
// expr_calls_a_function reports whether an expression contains a function call,
// which makes a DEFAULT per-row rather than constant.
@(private)
expr_calls_a_function :: proc(e: ^Expr) -> bool {
	found := false
	expr_walk(e, proc(node: ^Expr, user: rawptr) -> bool {
		if _, is_call := node^.(Call_Expr); is_call do (^bool)(user)^ = true
		return true
	}, &found)
	return found
}

// store_expression parses an expression the engine evaluates per row (a CHECK,
// a per-row DEFAULT) once and keeps it for the life of the store: text that
// arrived with the schema is re-read on every write otherwise.
@(private)
store_expression :: proc(store: ^Store, text: string) -> (^Expr, Error) {
	sync.mutex_lock(&store.expr_cache_mutex)
	defer sync.mutex_unlock(&store.expr_cache_mutex)
	if cached, ok := store.expr_cache[text]; ok do return cached.expr, ERROR_NONE
	query, expr, err := sql_parse_expression(text)
	if err.kind != .None do return nil, err
	entry := new(Cached_Expression)
	entry.query = query
	entry.expr = expr
	store.expr_cache[strings.clone(text)] = entry
	return expr, ERROR_NONE
}

// checks_enforce evaluates a table's CHECK constraints against a row about to be
// written. NULL passes and false refuses, as in SQL.
checks_enforce :: proc(tx: ^Tx, table: ^Table, values: []Value) -> Error {
	if len(table.schema.checks) == 0 do return ERROR_NONE
	sources: [1]Source
	sources[0] = Source{table = table, row = Row{values = values}}
	ctx := Eval_Ctx{tx = tx, sources = sources[:], now_us = now_microseconds()}
	for check in table.schema.checks {
		expr, parse_err := store_expression(tx.store, check.sql)
		if parse_err.kind != .None do return parse_err
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None do return eval_err
		if value.kind == .Null || value_is_truthy(value) do continue
		label := len(check.name) > 0 ? check.name : check.sql
		return errf(.Check_Violation, "CHECK constraint failed: %s", label)
	}
	return ERROR_NONE
}

// checks_use_column reports whether a CHECK constraint of the schema names the
// column, which an ALTER that drops or renames it has to respect.
checks_use_column :: proc(schema: ^Table_Schema, column: string, skip_own := false) -> bool {
	Probe :: struct {
		column: string,
		found:  bool,
	}
	for check in schema.checks {
		// A column's own CHECK goes with it when the column is dropped.
		if skip_own && strings.equal_fold(check.column, column) do continue
		query, expr, err := sql_parse_expression(check.sql)
		if err.kind != .None {
			error_free(&err)
			continue
		}
		probe := Probe{column = column}
		expr_walk(expr, proc(node: ^Expr, user: rawptr) -> bool {
			probe := (^Probe)(user)
			if reference, ok := node^.(Column_Expr); ok && strings.equal_fold(reference.name, probe.column) {
				probe.found = true
			}
			return true
		}, &probe)
		query_destroy(&query)
		if probe.found do return true
	}
	return false
}

// column_default_for_row gives a column's default for one row: a per-row DEFAULT
// is evaluated now, a constant one is the stored value.
column_default_for_row :: proc(tx: ^Tx, column: Column) -> (Value, Error) {
	if len(column.default_sql) == 0 do return column_default(column), ERROR_NONE
	expr, parse_err := store_expression(tx.store, column.default_sql)
	if parse_err.kind != .None do return {}, parse_err
	ctx := Eval_Ctx{tx = tx, now_us = now_microseconds()}
	value, eval_err := eval_expr(&ctx, expr)
	if eval_err.kind != .None do return {}, eval_err
	return value_clone(value, tx.alloc), ERROR_NONE
}

Generated_Plan :: struct {
	columns: [dynamic]int,
	queries: [dynamic]Query,
	exprs:   [dynamic]^Expr,
}

generated_plan_make :: proc(tx: ^Tx, table: ^Table) -> (plan: Generated_Plan, err: Error) {
	for column, i in table.schema.columns {
		if !column.generated do continue
		if len(column.generated_sql) == 0 {
			generated_plan_destroy(&plan)
			return plan, errf(.Corrupt_Log, "generated column %s has no expression", column.name)
		}
		query, expr, parse_err := sql_parse_expression(column.generated_sql)
		if parse_err.kind != .None {
			generated_plan_destroy(&plan)
			return plan, error_wrap(parse_err, .Corrupt_Log, "generated column %s: %s", column.name, parse_err.message)
		}
		append(&plan.columns, i)
		append(&plan.queries, query)
		append(&plan.exprs, expr)
	}
	return plan, ERROR_NONE
}

generated_plan_destroy :: proc(plan: ^Generated_Plan) {
	for &query in plan.queries do query_destroy(&query)
	delete(plan.queries)
	delete(plan.columns)
	delete(plan.exprs)
	plan^ = {}
}

// generated_plan_apply evaluates every generated expression against the row
// about to be stored and writes the result into its column.
generated_plan_apply :: proc(
	ctx: ^Eval_Ctx,
	plan: ^Generated_Plan,
	table: ^Table,
	values: []Value,
) -> Error {
	if len(plan.exprs) == 0 do return ERROR_NONE
	saved := ctx.sources
	synthetic: [1]Source
	synthetic[0] = Source{table = table, row = Row{values = values}}
	ctx.sources = synthetic[:]
	defer ctx.sources = saved
	for expr, i in plan.exprs {
		value, eval_err := eval_expr(ctx, expr)
		if eval_err.kind != .None do return eval_err
		target := plan.columns[i]
		coerced, coerce_err := value_coerce_into(value, &table.schema, target)
		if coerce_err.kind != .None {
			return errf(
				.Invalid_Type,
				"generated column %s: %s",
				table.schema.columns[target].name,
				coerce_err.message,
			)
		}
		values[target] = coerced
	}
	return ERROR_NONE
}

// declared_resolution is the ON CONFLICT of the constraint a row broke, for a
// statement that named no resolution of its own: the first NOT NULL column
// the row leaves NULL, or the first unique key another row already holds.
@(private)
declared_resolution :: proc(tx: ^Tx, table: ^Table, values: []Value, err: Error, row: Row_Id = NO_ROW_ID) -> Conflict_Resolution {
	#partial switch err.kind {
	case .Not_Null_Violation:
		for column, i in table.schema.columns {
			if i >= len(values) || !column.not_null do continue
			if values[i].kind == .Null do return column.not_null_conflict
		}
	case .Duplicate_Unique, .Duplicate_Primary_Key:
		for idx, i in table.indexes {
			if !idx.unique || !index_row_included(table, i, values) do continue
			// The row an UPDATE rewrites holds its own keys: only another row's count.
			found := table_index_lookup(table, i, values)
			taken := false
			for id in found do if id != row do taken = true
			delete(found)
			if taken do return idx.schema.on_conflict
		}
		// A key this statement staged is not in the committed index: the
		// message names the index.
		for idx in table.indexes {
			if idx.unique && strings.contains(err.message, idx.schema.name) do return idx.schema.on_conflict
		}
	}
	return .Abort
}

// not_null_defaults gives the row with each NULL of a NOT NULL ... ON CONFLICT
// REPLACE column replaced by the column's default; false when one has none.
@(private)
not_null_defaults :: proc(tx: ^Tx, table: ^Table, values: []Value) -> ([]Value, bool) {
	out := make([]Value, len(values), tx.alloc)
	copy(out, values)
	changed := false
	for column, i in table.schema.columns {
		if i >= len(out) || !column.not_null || out[i].kind != .Null do continue
		if column.not_null_conflict != .Replace || !column.has_default do return nil, false
		filled, fill_err := column_default_for_row(tx, column)
		if fill_err.kind != .None {
			error_free(&fill_err)
			return nil, false
		}
		out[i] = filled
		changed = true
	}
	return out, changed
}

// table_declares_resolution reports a table with a constraint whose ON
// CONFLICT is not ABORT, which makes every row of a write its own unit.
@(private)
table_declares_resolution :: proc(table: ^Table) -> bool {
	for column in table.schema.columns do if column.not_null_conflict != .Abort do return true
	for idx in table.indexes do if idx.schema.on_conflict != .Abort do return true
	return false
}

// counts_changes says whether a write to `table` is one changes() and
// total_changes() count: the engine's own catalogs (the tables named with a
// leading underscore) are not, as SQLite does not count the rows it writes to
// sqlite_schema when a view or a trigger is made.
@(private)
counts_changes :: proc(table: string) -> bool {
	return !strings.has_prefix(table, "_")
}
