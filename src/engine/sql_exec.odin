package engine

import "core:fmt"
import "core:slice"
import "core:mem"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

// --- Results ---------------------------------------------------------------

Sql_Result_Kind :: enum u8 {
	Rows,
	Affected,
	Ack,
}

Sql_Result :: struct {
	kind:       Sql_Result_Kind,
	columns:    []string,
	rows:       [][]Value,
	affected:   int,
	message:    string,
	commit_seq: u64,
	// row_bytes is the sum of the value sizes in `rows`: a hint for buffers and
	// quotas.
	row_bytes:  u64,
	// work prices the work the statement did: rows touched plus a fraction of
	// the payload. The store meters it and enforces a per-call budget.
	work:     u64,
	// row_ids parallels rows for a single-table projection: it identifies the
	// stored row each output row came from, which incremental consumers use.
	row_ids:    []Row_Id,
}

sql_result_destroy :: proc(result: ^Sql_Result) {
	for column in result.columns do delete(column)
	delete(result.columns)
	for row in result.rows do free_values(row)
	delete(result.rows)
	delete(result.row_ids)
	delete(result.message)
	result^ = {}
}

// sql_execute parses and runs one statement in its own transaction. SELECT runs
// in a read transaction; everything else in a write transaction that commits on
// success. BEGIN/COMMIT/ROLLBACK need a session and are rejected here.
// sql_execute runs one statement and feeds the query latency histogram. Every
// public entry point funnels through here, so the count matches the statements
// a host issued.
sql_execute :: proc(store: ^Store, sql: string) -> (Sql_Result, Error) {
	started := now_microseconds()
	result, err := sql_execute_params(store, sql, nil)
	store_record_query_latency(store, now_microseconds() - started)
	return result, err
}

// sql_execute_params runs one statement with positional bind parameters for its
// `?` placeholders. It prices the statement, accumulates the store's work
// total and enforces the per-call budget. The budget is a post-condition: a
// statement that overspends is refused rather than truncated.
sql_execute_params :: proc(store: ^Store, sql: string, params: []Value) -> (Sql_Result, Error) {
	result, exec_err := sql_execute_priced(store, sql, params)
	if exec_err.kind != .None do return {}, exec_err
	sync.lock(&store.mutex)
	result.work = statement_work(&result)
	store.work_used += result.work
	budget := store.max_work_per_call
	sync.unlock(&store.mutex)
	if budget > 0 && result.work > budget {
		sql_result_destroy(&result)
		return {}, errf(.Quota_Exceeded, "statement spends %d work, budget is %d", result.work, budget)
	}
	return result, ERROR_NONE
}

@(private)
sql_execute_priced :: proc(store: ^Store, sql: string, params: []Value) -> (Sql_Result, Error) {
	if body, is_pragma := sqlite_pragma_statement(sql); is_pragma {
		return sql_exec_pragma(store, body, false)
	}
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None do return {}, parse_err
	defer query_destroy(&query)
	return sql_run_statement(store, query.statement, params)
}

// sql_run_statement dispatches an already parsed statement; prepared statements
// reuse it to avoid parsing on every execution.
@(private)
sql_run_statement :: proc(store: ^Store, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	switch stmt in statement {
	case Select_Stmt, With_Stmt:
		tx := tx_begin_read(store)
		result, exec_err := sql_run_query(tx, stmt, params)
		tx_end(tx)
		result.commit_seq = store.commit_seq
		return result, exec_err
	case Insert_Stmt, Update_Stmt, Delete_Stmt, Create_Table_Stmt, Alter_Table_Stmt, Create_Type_Stmt, Drop_Table_Stmt, Create_Index_Stmt, Drop_Index_Stmt, Create_View_Stmt, Drop_View_Stmt, Create_Policy_Stmt, Drop_Policy_Stmt, Truncate_Stmt, Create_Trigger_Stmt, Drop_Trigger_Stmt, Grant_Stmt, Create_Virtual_Table_Stmt, Load_Extension_Stmt:
		tx := tx_begin_write(store)
		result, exec_err := sql_exec_mutation(tx, stmt, params)
		if exec_err.kind != .None {
			tx_rollback(tx)
			return {}, exec_err
		}
		if commit_err := tx_commit(tx); commit_err.kind != .None {
			return {}, commit_err
		}
		result.commit_seq = store.commit_seq
		return result, ERROR_NONE
	case Set_Stmt:
		return sql_exec_set(store, stmt, params)
	case Show_Stmt:
		return sql_exec_show(store, stmt)
	case Explain_Stmt:
		tx := tx_begin_read(store)
		result, explain_err := sql_exec_explain(tx.store, stmt, params)
		tx_end(tx)
		return result, explain_err
	case Describe_Stmt:
		tx := tx_begin_read(store)
		result, describe_err := sql_exec_describe(tx, stmt)
		tx_end(tx)
		return result, describe_err
	case Vacuum_Stmt:
		return sql_exec_vacuum(store, stmt)
	case Attach_Stmt:
		return sql_exec_attach(store, stmt)
	case Detach_Stmt:
		return sql_exec_detach(store, stmt)
	case Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
		return {}, errf(
			.Sql_Not_A_Query,
			"%s only makes sense in a session that keeps a transaction open",
			statement_name(stmt),
		)
	}
	return {}, errf(.Sql_Unsupported, "unsupported statement")
}

// sql_execute_in_tx runs a data statement inside an existing transaction. It is
// what reducers use to mutate the database atomically.
sql_execute_in_tx :: proc(tx: ^Tx, sql: string) -> (Sql_Result, Error) {
	return sql_execute_in_tx_params(tx, sql, nil)
}

sql_execute_in_tx_params :: proc(tx: ^Tx, sql: string, params: []Value) -> (Sql_Result, Error) {
	if body, is_pragma := sqlite_pragma_statement(sql); is_pragma {
		return sql_exec_pragma(tx.store, body, tx.locked)
	}
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None do return {}, parse_err
	defer query_destroy(&query)
	result, exec_err := sql_run_statement_in_tx(tx, query.statement, params)
	if exec_err.kind != .None do return {}, exec_err
	// Price the statement inside the transaction too: the transaction owns the
	// store lock here, so this uses the same units without touching the mutex.
	result.work = statement_work(&result)
	if tx != nil do tx.work_units += result.work
	budget := tx.store.max_work_per_call
	if budget > 0 && result.work > budget {
		sql_result_destroy(&result)
		return {}, errf(.Quota_Exceeded, "statement spends %d work, budget is %d", result.work, budget)
	}
	return result, ERROR_NONE
}

// sql_run_statement_in_tx dispatches an already parsed statement inside a
// transaction.
@(private)
sql_run_statement_in_tx :: proc(tx: ^Tx, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	switch stmt in statement {
	case Select_Stmt, With_Stmt:
		return sql_run_query(tx, stmt, params)
	case Insert_Stmt, Update_Stmt, Delete_Stmt, Create_Table_Stmt, Alter_Table_Stmt, Create_Type_Stmt, Drop_Table_Stmt, Create_Index_Stmt, Drop_Index_Stmt, Create_View_Stmt, Drop_View_Stmt, Create_Policy_Stmt, Drop_Policy_Stmt, Truncate_Stmt, Create_Trigger_Stmt, Drop_Trigger_Stmt, Grant_Stmt, Create_Virtual_Table_Stmt, Load_Extension_Stmt:
		return sql_exec_mutation(tx, stmt, params)
	case Set_Stmt:
		return sql_exec_set(tx.store, stmt, params, tx.locked)
	case Show_Stmt:
		return sql_exec_show(tx.store, stmt, tx.locked)
	case Explain_Stmt:
		return sql_exec_explain(tx.store, stmt, params, tx.locked)
	case Describe_Stmt:
		return sql_exec_describe(tx, stmt)
	case Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
		return {}, errf(.Sql_Not_A_Query, "transaction control is not allowed inside a transaction")
	case Vacuum_Stmt:
		return {}, errf(.Sql_Not_A_Query, "VACUUM is not allowed inside a transaction")
	case Attach_Stmt, Detach_Stmt:
		return {}, errf(
			.Sql_Not_A_Query,
			"%s is not allowed inside a transaction",
			statement_name(statement),
		)
	}
	return {}, errf(.Sql_Unsupported, "unsupported statement")
}

// sql_exec_vacuum compacts the live log, or writes a compacted copy.
@(private)
sql_exec_vacuum :: proc(store: ^Store, stmt: Vacuum_Stmt) -> (Sql_Result, Error) {
	if len(stmt.path) == 0 {
		if compact_err := store_compact(store); compact_err.kind != .None {
			return {}, compact_err
		}
		return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
	}
	if write_err := store_vacuum_into(store, stmt.path); write_err.kind != .None {
		return {}, write_err
	}
	return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
}

sql_exec_mutation :: proc(tx: ^Tx, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	switch stmt in statement {
	case Load_Extension_Stmt:
		if stmt.unload {
			if unload_err := extension_unload(tx, stmt.name, stmt.if_exists); unload_err.kind != .None {
				return {}, unload_err
			}
		} else {
			if load_err := extension_load(tx, stmt.name, stmt.address, stmt.reducers); load_err.kind != .None {
				return {}, load_err
			}
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Insert_Stmt:
		return sql_exec_insert(tx, stmt, params)
	case Update_Stmt:
		return sql_exec_update(tx, stmt, params)
	case Delete_Stmt:
		return sql_exec_delete(tx, stmt, params)
	case Create_Table_Stmt:
		return sql_exec_create_table(tx, stmt, params)
	case Alter_Table_Stmt:
		return sql_exec_alter_table(tx, stmt)
	case Create_Type_Stmt:
		return sql_exec_create_type(tx, stmt)
	case Drop_Table_Stmt:
		return sql_exec_drop_table(tx, stmt)
	case Create_Index_Stmt:
		return sql_exec_create_index(tx, stmt)
	case Drop_Index_Stmt:
		return sql_exec_drop_index(tx, stmt)
	case Create_View_Stmt:
		return sql_exec_create_view(tx, stmt)
	case Drop_View_Stmt:
		return sql_exec_drop_view(tx, stmt)
	case Create_Policy_Stmt:
		return sql_exec_create_policy(tx, stmt)
	case Drop_Policy_Stmt:
		return sql_exec_drop_policy(tx, stmt)
	case Truncate_Stmt:
		if truncate_err := tx_truncate(tx, stmt.name); truncate_err.kind != .None {
			return {}, truncate_err
		}
		return Sql_Result{kind = .Affected, affected = 1, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Create_Trigger_Stmt:
		if trigger_err := trigger_create(tx, stmt); trigger_err.kind != .None {
			return {}, trigger_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Drop_Trigger_Stmt:
		if trigger_err := trigger_drop(tx, stmt.name, stmt.if_exists); trigger_err.kind != .None {
			return {}, trigger_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Grant_Stmt:
		return sql_exec_grant(tx, stmt)
	case Create_Virtual_Table_Stmt:
		if stmt.if_not_exists {
			if _, found := fts_virtual_lookup(tx, stmt.name); found {
				return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
			}
		}
		if fts_err := fts_create(tx, stmt.name, stmt.module, stmt.columns); fts_err.kind != .None {
			return {}, fts_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Select_Stmt, With_Stmt, Set_Stmt, Show_Stmt, Explain_Stmt, Describe_Stmt, Vacuum_Stmt, Attach_Stmt, Detach_Stmt, Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
	}
	return {}, errf(.Sql_Unsupported, "statement does not modify data")
}


// --- Prepared statements ---------------------------------------------------

// Prepared keeps the parsed statement so repeated executions do not parse
// again. It is immutable after `sql_prepare` and safe to reuse with new params.
Stmt_Prepared :: struct {
	query:       Query,
	is_pragma:   bool,
	pragma_body: string,
}

sql_prepare :: proc(store: ^Store, sql: string) -> (^Stmt_Prepared, Error) {
	prepared := new(Stmt_Prepared)
	if body, is_pragma := sqlite_pragma_statement(sql); is_pragma {
		prepared.is_pragma = true
		prepared.pragma_body = strings.clone(body)
		return prepared, ERROR_NONE
	}
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None {
		free(prepared)
		return nil, parse_err
	}
	prepared.query = query
	return prepared, ERROR_NONE
}

stmt_prepared_destroy :: proc(prepared: ^Stmt_Prepared) {
	if prepared == nil do return
	if prepared.is_pragma {
		delete(prepared.pragma_body)
	} else {
		query_destroy(&prepared.query)
	}
	free(prepared)
}

@(private)
sql_price :: proc(store: ^Store, result: ^Sql_Result) -> Error {
	sync.lock(&store.mutex)
	result.work = statement_work(result)
	store.work_used += result.work
	budget := store.max_work_per_call
	sync.unlock(&store.mutex)
	if budget > 0 && result.work > budget {
		sql_result_destroy(result)
		return errf(.Quota_Exceeded, "statement spends %d work, budget is %d", result.work, budget)
	}
	return ERROR_NONE
}

// prepared_execute runs a prepared statement against the store, pricing it like
// sql_execute does.
prepared_execute :: proc(store: ^Store, prepared: ^Stmt_Prepared, params: []Value) -> (Sql_Result, Error) {
	if prepared == nil do return {}, errf(.Invalid_Argument, "no prepared statement")
	if prepared.is_pragma do return sql_exec_pragma(store, prepared.pragma_body, false)
	result, exec_err := sql_run_statement(store, prepared.query.statement, params)
	if exec_err.kind != .None do return {}, exec_err
	if price_err := sql_price(store, &result); price_err.kind != .None do return {}, price_err
	return result, ERROR_NONE
}

// prepared_execute_in_tx runs a prepared statement inside an existing
// transaction (the path benchmarks and reducers use).
prepared_execute_in_tx :: proc(tx: ^Tx, prepared: ^Stmt_Prepared, params: []Value) -> (Sql_Result, Error) {
	if prepared == nil do return {}, errf(.Invalid_Argument, "no prepared statement")
	if prepared.is_pragma do return sql_exec_pragma(tx.store, prepared.pragma_body, tx.locked)
	return sql_run_statement_in_tx(tx, prepared.query.statement, params)
}

// --- DESCRIBE --------------------------------------------------------------

// sql_exec_describe lists one table's columns and indexes as rows, so clients and
// the CLI can inspect the catalog without reading internal structures.
sql_exec_describe :: proc(tx: ^Tx, stmt: Describe_Stmt) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.name)
	if table_err.kind != .None do return {}, table_err
	result := Sql_Result{kind = .Rows, commit_seq = tx.store.commit_seq}
	result.columns = make([]string, 6)
	result.columns[0] = strings.clone("kind")
	result.columns[1] = strings.clone("name")
	result.columns[2] = strings.clone("type")
	result.columns[3] = strings.clone("not_null")
	result.columns[4] = strings.clone("unique")
	result.columns[5] = strings.clone("default")
	rows := make([dynamic][]Value)
	for column in table.schema.columns {
		row := make([]Value, 6)
		row[0] = value_string(strings.clone("column"))
		row[1] = value_string(strings.clone(column.name))
		row[2] = value_string(strings.clone(column_type_name(column.type)))
		row[3] = value_bool(column.not_null)
		row[4] = value_bool(column.unique)
		if column.has_default {
			row[5] = value_string(strings.clone(value_format(column.default_value, context.temp_allocator)))
		} else {
			row[5] = value_null()
		}
		append(&rows, row)
	}
	for index in table.schema.indexes {
		names := strings.builder_make()
		defer strings.builder_destroy(&names)
		for position, i in index.columns {
			if i > 0 do strings.write_string(&names, ", ")
			if position >= 0 && position < len(table.schema.columns) {
				strings.write_string(&names, table.schema.columns[position].name)
			}
		}
		row := make([]Value, 6)
		row[0] = value_string(strings.clone("index"))
		row[1] = value_string(strings.clone(index.name))
		row[2] = value_string(strings.clone(strings.to_string(names)))
		row[3] = value_bool(false)
		row[4] = value_bool(index.unique)
		row[5] = value_null()
		append(&rows, row)
	}
	result.rows = make([][]Value, len(rows))
	copy(result.rows, rows[:])
	delete(rows)
	return result, ERROR_NONE
}

// --- SET, SHOW and EXPLAIN -------------------------------------------------

sql_exec_set :: proc(store: ^Store, stmt: Set_Stmt, params: []Value, locked := false) -> (Sql_Result, Error) {
	// SET writes the session variable map, so it takes the exclusive lock and
	// uses the unlocked store helpers (the lock is not re-entrant).
	if !locked {
		sync.lock(&store.mutex)
		defer sync.unlock(&store.mutex)
	}
	value, eval_err := eval_expr(
		&Eval_Ctx{params = params, now_us = now_microseconds()},
		stmt.value,
	)
	if eval_err.kind != .None do return {}, eval_err
	if strings.equal_fold(stmt.name, "identity") {
		coerced, coerce_err := value_coerce(value, Column_Type{kind = .Identity})
		if coerce_err.kind != .None {
			return {}, errf(.Invalid_Type, "SET identity needs a 32-byte hex string")
		}
		store_set_identity(store, value_identity_of(coerced))
		return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
	}
	if set_err := store_set_variable_locked(store, stmt.name, value); set_err.kind != .None {
		return {}, set_err
	}
	return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
}

sql_exec_show :: proc(store: ^Store, stmt: Show_Stmt, locked := false) -> (Sql_Result, Error) {
	if !locked {
		sync.shared_lock(&store.mutex)
		defer sync.shared_unlock(&store.mutex)
	}
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = make([]string, 2)
	result.columns[0] = strings.clone("name")
	result.columns[1] = strings.clone("value")
	rows := make([dynamic][]Value)
	if len(stmt.name) > 0 && strings.equal_fold(stmt.name, "tables") {
		names := store_table_names(store, context.allocator)
		defer delete(names)
		rows_out := make([dynamic][]Value)
		for name in names {
			if strings.has_prefix(name, "_") do continue
			row := make([]Value, 1)
			row[0] = value_string(strings.clone(name))
			append(&rows_out, row)
		}
		result.columns[0] = strings.clone("table")
		delete(result.columns[1])
		result.columns = result.columns[:1]
		result.rows = make([][]Value, len(rows_out))
		copy(result.rows, rows_out[:])
		delete(rows_out)
		return result, ERROR_NONE
	}
	if len(stmt.name) > 0 && strings.equal_fold(stmt.name, "types") {
		sql_result_destroy(&result)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		if _, exists := store.tables[TYPE_TABLE]; !exists {
			out.columns = []string{strings.clone("name"), strings.clone("base")}
			return out, ERROR_NONE
		}
		catalog := store.tables[TYPE_TABLE]
		entries := make([dynamic]Row)
		defer delete(entries)
		table_collect(catalog, &entries, max(u64))
		slice.sort_by(entries[:], proc(a, b: Row) -> bool {
			return strings.compare(a.values[0].s, b.values[0].s) < 0
		})
		out.columns = []string{strings.clone("name"), strings.clone("base")}
		out.rows = make([][]Value, len(entries))
		for entry, i in entries {
			row := make([]Value, 2)
			row[0] = value_string(strings.clone(entry.values[0].s))
			row[1] = value_string(strings.clone(entry.values[1].s))
			out.rows[i] = row
		}
		return out, ERROR_NONE
	}
	if len(stmt.name) > 0 && strings.equal_fold(stmt.name, "events") {
		sql_result_destroy(&result)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		out.columns = []string{strings.clone("table")}
		names := event_tables(store, context.allocator)
		rows_out := make([][]Value, len(names))
		for name, i in names {
			row := make([]Value, 1)
			row[0] = value_string(strings.clone(name))
			rows_out[i] = row
		}
		out.rows = rows_out
		return out, ERROR_NONE
	}
	if len(stmt.name) > 0 && strings.equal_fold(stmt.name, "indexes") {
		sql_result_destroy(&result)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		out.columns = []string{strings.clone("table"), strings.clone("index"), strings.clone("columns")}
		rows_out := make([dynamic][]Value)
		names := store_table_names(store, context.allocator)
		defer delete(names)
		for table_name in names {
			table, exists := store.tables[table_name]
			if !exists || strings.has_prefix(table_name, "_") do continue
			for idx in table.schema.indexes {
				row := make([]Value, 3)
				row[0] = value_string(strings.clone(table_name))
				row[1] = value_string(strings.clone(idx.name))
				column_list := ""
				for col, i in idx.columns {
					if i > 0 do column_list = strings.concatenate({column_list, ", "})
					column_list = strings.concatenate({column_list, table.schema.columns[col].name})
				}
				row[2] = value_string(column_list)
				append(&rows_out, row)
			}
		}
		out.rows = make([][]Value, len(rows_out))
		copy(out.rows, rows_out[:])
		delete(rows_out)
		return out, ERROR_NONE
	}
	if len(stmt.name) > 0 {
		if strings.equal_fold(stmt.name, "identity") {
			row := make([]Value, 2)
			row[0] = value_string(strings.clone("identity"))
			row[1] = value_identity(store_identity(store))
			append(&rows, row)
			result.rows = make([][]Value, len(rows))
			copy(result.rows, rows[:])
			delete(rows)
			return result, ERROR_NONE
		}
		value, found := store_get_variable_locked(store, stmt.name)
		if !found {
			sql_result_destroy(&result)
			return {}, errf(.Invalid_Argument, "variable %s is not set", stmt.name)
		}
		row := make([]Value, 2)
		row[0] = value_string(strings.clone(stmt.name))
		row[1] = value
		append(&rows, row)
	} else {
		names := store_variable_names_locked(store, context.allocator)
		defer delete(names)
		for name in names {
			if value, found := store_get_variable_locked(store, name); found {
				row := make([]Value, 2)
				row[0] = value_string(strings.clone(name))
				row[1] = value
				append(&rows, row)
			}
		}
	}
	result.rows = make([][]Value, len(rows))
	copy(result.rows, rows[:])
	delete(rows)
	return result, ERROR_NONE
}

sql_exec_explain :: proc(
	store: ^Store,
	stmt: Explain_Stmt,
	params: []Value,
	locked := false,
) -> (Sql_Result, Error) {
	if !locked {
		sync.shared_lock(&store.mutex)
		defer sync.shared_unlock(&store.mutex)
	}
	if stmt.inner == nil do return {}, errf(.Invalid_Argument, "EXPLAIN needs a statement")
	lines := make([dynamic]string)
	defer delete(lines)
	switch inner in stmt.inner^ {
	case Select_Stmt:
		append(&lines, strings.concatenate({"scan ", inner.from.name, explain_index_suffix(store, inner.from, inner.where_clause, params)}))
		for join in inner.joins {
			append(&lines, strings.concatenate({"join ", join.table.name, " (nested loop)"}))
		}
		if inner.where_clause != nil do append(&lines, strings.clone("filter"))
		if len(inner.group_by) > 0 do append(&lines, strings.clone("group by"))
		if inner.having != nil do append(&lines, strings.clone("having"))
		if len(inner.order_by) > 0 do append(&lines, strings.clone("order by (sort)"))
		if inner.limit != nil || inner.offset != nil do append(&lines, strings.clone("limit/offset"))
	case Update_Stmt:
		append(&lines, strings.concatenate({"update ", inner.table, explain_index_suffix(store, Table_Ref{name = inner.table}, inner.where_clause, params)}))
	case Delete_Stmt:
		append(&lines, strings.concatenate({"delete ", inner.table, explain_index_suffix(store, Table_Ref{name = inner.table}, inner.where_clause, params)}))
	case Insert_Stmt:
		append(&lines, strings.concatenate({"insert into ", inner.table}))
	case Create_Table_Stmt:
		append(&lines, strings.concatenate({"create table ", inner.name}))
	case Alter_Table_Stmt:
		append(&lines, strings.concatenate({"alter table ", inner.table}))
	case Create_Type_Stmt:
		append(&lines, strings.concatenate({"create type ", inner.name}))
	case Drop_Table_Stmt:
		append(&lines, strings.concatenate({"drop table ", inner.name}))
	case Create_Index_Stmt:
		append(&lines, strings.concatenate({"create index ", inner.name, " on ", inner.table}))
	case Drop_Index_Stmt:
		append(&lines, strings.concatenate({"drop index ", inner.name}))
	case Set_Stmt:
		append(&lines, strings.concatenate({"set ", inner.name}))
	case Show_Stmt:
		append(&lines, strings.concatenate({"show ", inner.name}))
	case Create_View_Stmt:
		append(&lines, strings.concatenate({"create view ", inner.name}))
	case Drop_View_Stmt:
		append(&lines, strings.concatenate({"drop view ", inner.name}))
	case Create_Policy_Stmt:
		append(&lines, strings.concatenate({"create policy ", inner.name, " on ", inner.table}))
	case Drop_Policy_Stmt:
		append(&lines, strings.concatenate({"drop policy ", inner.name}))
	case Describe_Stmt:
		append(&lines, strings.concatenate({"describe ", inner.name}))
	case Truncate_Stmt:
		append(&lines, strings.concatenate({"truncate ", inner.name}))
	case Vacuum_Stmt:
		append(&lines, strings.clone(len(inner.path) > 0 ? "write a compacted copy" : "compact the log"))
	case Create_Trigger_Stmt:
		append(&lines, strings.concatenate({"create trigger ", inner.name, " on ", inner.table}))
	case Drop_Trigger_Stmt:
		append(&lines, strings.concatenate({"drop trigger ", inner.name}))
	case Grant_Stmt:
		append(&lines, strings.clone(inner.revoke ? "revoke" : "grant"))
	case Create_Virtual_Table_Stmt:
		append(&lines, strings.concatenate({"create virtual table ", inner.name, " using ", inner.module}))
	case Load_Extension_Stmt:
		append(&lines, strings.concatenate({inner.unload ? "unload extension " : "load extension ", inner.name}))
	case Attach_Stmt:
		append(&lines, strings.concatenate({"attach ", inner.path, " as ", inner.name}))
	case Detach_Stmt:
		append(&lines, strings.concatenate({"detach ", inner.name}))
	case Explain_Stmt, With_Stmt, Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
		append(&lines, strings.clone("no plan"))
	}
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = make([]string, 1)
	result.columns[0] = strings.clone("plan")
	rows := make([][]Value, len(lines))
	for line, i in lines {
		rows[i] = make([]Value, 1)
		rows[i][0] = value_string(line)
	}
	result.rows = rows
	return result, ERROR_NONE
}

@(private)
explain_index_suffix :: proc(store: ^Store, ref: Table_Ref, predicate: ^Expr, params: []Value) -> string {
	if predicate == nil do return " (full scan)"
	table, table_err := store_table(store, ref.name)
	if table_err.kind != .None do return ""
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		qualifier, column_name, _, ok := comparison_details(expr)
		if !ok do continue
		if len(qualifier) > 0 &&
		   !strings.equal_fold(qualifier, table.schema.name) &&
		   !(len(ref.alias) > 0 && strings.equal_fold(qualifier, ref.alias)) {
			continue
		}
		column_index, found := schema_column_index(&table.schema, column_name)
		if !found do continue
		index_position, has_index := index_for_single_column(table, column_index)
		if !has_index do continue
		return strings.concatenate({" using index ", table.indexes[index_position].schema.name})
	}
	return " (full scan)"
}

@(private)
comparison_details :: proc(expr: ^Expr) -> (qualifier: string, column: string, op: Binary_Op, ok: bool) {
	if binary, is_binary := expr^.(Binary_Expr); is_binary {
		#partial switch binary.op {
		case .Eq, .Lt, .Le, .Gt, .Ge:
			side_qualifier, side_column, _, _, sides_ok := comparison_sides(binary)
			return side_qualifier, side_column, binary.op, sides_ok
		}
	}
	if between, is_between := expr^.(Between_Expr); is_between && !between.negated {
		if column_ref, is_column := between.operand^.(Column_Expr); is_column {
			return column_ref.table, column_ref.name, .Ge, true
		}
	}
	return "", "", .Eq, false
}

// --- SELECT ----------------------------------------------------------------

Source :: struct {
	table: ^Table,
	row:   Row,
	alias: string,
	// hidden_unqualified sources only answer qualified references. UPSERT uses
	// it for `excluded`, so a bare column still means the stored row.
	hidden_unqualified: bool,
}

Eval_Ctx :: struct {
	tx:      ^Tx,
	sources: []Source,
	group:   [][]Source,
	grouped: bool,
	params:  []Value,
	now_us:  i64,
	// stream is set only while a streaming scan evaluates its final projection:
	// an aggregate then answers from its running accumulator instead of walking
	// a materialized group.
	stream: ^Agg_Stream,
}

@(private)
free_partials :: proc(items: ^[dynamic][]Source) {
	for item in items do delete(item)
	delete(items^)
}

// sql_run_query executes a plain query or one prefixed with common table
// expressions, which are materialized for the life of the statement.
sql_run_query :: proc(tx: ^Tx, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	if select_stmt, ok := statement.(Select_Stmt); ok {
		return sql_exec_select(tx, select_stmt, params)
	}
	with_stmt, is_with := statement.(With_Stmt)
	if !is_with do return {}, errf(.Sql_Unsupported, "not a query")
	for cte in with_stmt.ctes {
		table, cte_err := tx_materialize_cte(tx, cte, params, with_stmt.recursive)
		if cte_err.kind != .None do return {}, cte_err
		tx.cte_tables[strings.clone(cte.name, tx.alloc)] = table
	}
	return sql_exec_select(tx, with_stmt.select_stmt, params)
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
	columns := make([]Column, len(result.columns), tx.alloc)
	for column_name, i in result.columns {
		name := column_name
		if i < len(cte.columns) do name = cte.columns[i]
		columns[i] = Column {
			name = strings.clone(name, tx.alloc),
			type = view_column_type(result.rows, i),
		}
	}
	schema := Table_Schema {
		name    = strings.clone(cte.name, tx.alloc),
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

// clone_row_values copies a row onto the caller's allocator.
@(private)
clone_row_values :: proc(values: []Value, alloc: mem.Allocator) -> []Value {
	out := make([]Value, len(values), alloc)
	for value, i in values do out[i] = value_clone(value, alloc)
	return out
}

@(private)
compound_admit :: proc(rows: ^[dynamic][]Value, seen: ^map[string]bool, values: []Value, dedup: bool) {
	if !dedup {
		append(rows, clone_row_values(values, context.allocator))
		return
	}
	key := encode_output_key(values)
	if key in seen^ {
		delete(key)
		return
	}
	seen^[key] = true
	append(rows, clone_row_values(values, context.allocator))
}

// sql_exec_compound evaluates a UNION chain: every term runs, duplicates are
// dropped unless the term is UNION ALL, and the tail clauses (ORDER BY, LIMIT,
// OFFSET) apply to the merged result. When a tail exists the rows pass through
// a temporary table, which lets the ordinary select path order them.
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

	seen := make(map[string]bool)
	rows := make([dynamic][]Value, 0, len(first.rows))
	defer {
		for row in rows do free_values(row)
		delete(rows)
		for key in seen do delete(key)
		delete(seen)
	}
	// UNION drops duplicates; a chain of UNION ALL terms keeps everything.
	dedup := true
	for part in stmt.compound {
		if !part.all do continue
		dedup = false
	}
	for part in stmt.compound {
		if !part.all do dedup = true
	}
	for row in first.rows do compound_admit(&rows, &seen, row, dedup)

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
				"each UNION term must return %d columns",
				len(first.columns),
			)
		}
		for row in result.rows do compound_admit(&rows, &seen, row, dedup)
		sql_result_destroy(&result)
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
		columns[i] = Column {
			name = strings.clone(column_name, tx.alloc),
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
	return sql_exec_select(tx, outer, params)
}

// recursion_limit bounds WITH RECURSIVE: a query that never stops adding rows
// fails instead of running forever. It is a variable so tests can lower it.
recursion_limit: int = 10000

@(private)
recursive_insert :: proc(table: ^Table, seen: ^map[string]bool, values: []Value, next_id: ^Row_Id) -> (bool, Error) {
	key := encode_output_key(values)
	if key in seen^ {
		delete(key)
		return false, ERROR_NONE
	}
	seen^[key] = true
	if err := table_insert(table, next_id^, values); err.kind != .None do return false, err
	next_id^ += 1
	return true, ERROR_NONE
}

// tx_materialize_recursive_cte evaluates `base UNION [ALL] step`: the base fills
// the table, then the step runs against the accumulated rows until it adds
// nothing. Rows are deduplicated, which also makes UNION ALL terminate.
@(private)
tx_materialize_recursive_cte :: proc(tx: ^Tx, cte: Cte, params: []Value) -> (^Table, Error) {
	base := cte.select_stmt
	parts := base.compound
	base.compound = nil
	base.order_by = nil
	base.limit = nil
	base.offset = nil
	first, first_err := sql_exec_select(tx, base, params)
	if first_err.kind != .None do return nil, first_err
	defer sql_result_destroy(&first)
	if len(first.columns) == 0 do return nil, errf(.Internal, "recursive query without columns")

	columns := make([]Column, len(first.columns), tx.alloc)
	for column_name, i in first.columns {
		name := column_name
		if i < len(cte.columns) do name = cte.columns[i]
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
	tx.cte_tables[strings.clone(cte.name, tx.alloc)] = table

	seen := make(map[string]bool)
	defer {
		for key in seen do delete(key)
		delete(seen)
	}
	next_id := Row_Id(1)
	for row in first.rows {
		if _, insert_err := recursive_insert(table, &seen, row, &next_id); insert_err.kind != .None {
			return nil, insert_err
		}
	}

	steps := 0
	for steps < recursion_limit {
		term := parts[0].select_stmt
		term.compound = nil
		term.order_by = nil
		term.limit = nil
		term.offset = nil
		result, term_err := sql_exec_select(tx, term, params)
		if term_err.kind != .None do return nil, term_err
		added := 0
		for row in result.rows {
			inserted, insert_err := recursive_insert(table, &seen, row, &next_id)
			if insert_err.kind != .None {
				sql_result_destroy(&result)
				return nil, insert_err
			}
			if inserted do added += 1
		}
		sql_result_destroy(&result)
		if added == 0 do break
		steps += 1
	}
	if steps >= recursion_limit {
		return nil, errf(.Cancelled, "WITH RECURSIVE %s exceeded %d steps", cte.name, recursion_limit)
	}
	return table, ERROR_NONE
}


// --- Window functions ------------------------------------------------------

// Window_Cell holds what one output row needs for one window expression: the
// keys that decide its partition and its position, and the evaluated arguments
// that lag/lead/first_value read from other rows.
Window_Cell :: struct {
	partition: []u8,
	order:     []u8,
	args:      []Value,
}

// window_partition_key encodes the PARTITION BY values of the current row.
window_partition_key :: proc(ctx: ^Eval_Ctx, window: Window_Expr) -> ([]u8, Error) {
	if len(window.partition) == 0 do return nil, ERROR_NONE
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for expr in window.partition {
		value, eval_err := eval_expr(ctx, expr)
		if eval_err.kind != .None do return nil, eval_err
		value_encode_key(&w, value)
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	return out, ERROR_NONE
}

// window_order_key encodes the ORDER BY clause inside OVER ().
window_order_key :: proc(ctx: ^Eval_Ctx, window: Window_Expr) -> ([]u8, Error) {
	if len(window.order_by) == 0 do return nil, ERROR_NONE
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for item in window.order_by {
		value, eval_err := eval_expr(ctx, item.expr)
		if eval_err.kind != .None do return nil, eval_err
		collation, has := collate_name(item.expr)
		if !has {
			collation, has = column_collation(ctx, item.expr)
		}
		if has && len(collation) > 0 {
			value = collate_ordered_value(value, collation)
		}
		start := len(w.data)
		value_encode_key(&w, value)
		if item.descending {
			for i in start ..< len(w.data) do w.data[i] = ~w.data[i]
		}
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	return out, ERROR_NONE
}

// window_is_known tells whether a function name has a window implementation.
window_is_known :: proc(name: string) -> bool {
	return strings.equal_fold(name, "row_number") ||
		strings.equal_fold(name, "rank") ||
		strings.equal_fold(name, "dense_rank") ||
		strings.equal_fold(name, "percent_rank") ||
		strings.equal_fold(name, "cume_dist") ||
		strings.equal_fold(name, "ntile") ||
		strings.equal_fold(name, "lag") ||
		strings.equal_fold(name, "lead") ||
		strings.equal_fold(name, "first_value") ||
		strings.equal_fold(name, "last_value") ||
		strings.equal_fold(name, "nth_value") ||
		is_aggregate_name(name)
}

// window_fill computes one window expression over the rows of one partition.
// `order_keys` is already sorted alongside `indexes`; with an ORDER BY clause
// the frame runs from the partition start to the last peer of each row.
window_fill :: proc(
	ctx: ^Eval_Ctx,
	window: Window_Expr,
	position: int,
	indexes: []int,
	order_keys: []string,
	rows: []Output_Row,
	cells: [][dynamic]Window_Cell,
	cell_index: int,
	sources: [][]Source,
) -> Error {
	running := len(window.order_by) > 0
	name := window.name
	assign :: proc(rows: []Output_Row, row: int, position: int, value: Value) {
		rows[row].values[position] = value_clone(value, context.allocator)
	}
	arg_of :: proc(cells: [][dynamic]Window_Cell, row, cell_index, arg: int) -> Value {
		cell_values := cells[row][cell_index].args
		if arg < 0 || arg >= len(cell_values) do return value_null()
		return cell_values[arg]
	}
	if strings.equal_fold(name, "row_number") {
		for index, j in indexes do assign(rows, index, position, value_int(i64(j + 1)))
		return ERROR_NONE
	}
	if strings.equal_fold(name, "lag") || strings.equal_fold(name, "lead") {
		forward := strings.equal_fold(name, "lead")
		for index, j in indexes {
			offset := i64(1)
			if offset_value := arg_of(cells, index, cell_index, 1); offset_value.kind != .Null {
				if parsed, ok := value_to_i64(offset_value); ok do offset = parsed
			}
			target := i64(j) + (forward ? offset : -offset)
			if target < 0 || target >= i64(len(indexes)) {
				fallback := arg_of(cells, index, cell_index, 2)
				assign(rows, index, position, fallback)
				continue
			}
			assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
		}
		return ERROR_NONE
	}
	// Rank family: walk peer groups, which need the ORDER BY keys.
	peer_end :: proc(order_keys: []string, j: int) -> int {
		end := j
		for end + 1 < len(order_keys) && order_keys[end + 1] == order_keys[j] do end += 1
		return end
	}
	if strings.equal_fold(name, "rank") || strings.equal_fold(name, "dense_rank") ||
	   strings.equal_fold(name, "percent_rank") || strings.equal_fold(name, "cume_dist") {
		group := 0
		j := 0
		for j < len(indexes) {
			end := running ? peer_end(order_keys, j) : len(indexes) - 1
			group += 1
			for f in j ..= end {
				index := indexes[f]
				switch {
				case strings.equal_fold(name, "rank"):
					assign(rows, index, position, value_int(i64(j + 1)))
				case strings.equal_fold(name, "dense_rank"):
					assign(rows, index, position, value_int(i64(group)))
				case strings.equal_fold(name, "percent_rank"):
					denominator := len(indexes) - 1
					percent := denominator <= 0 ? 0.0 : f64(j) / f64(denominator)
					assign(rows, index, position, value_float(percent))
				case:
					assign(rows, index, position, value_float(f64(end + 1) / f64(len(indexes))))
				}
			}
			j = end + 1
		}
		return ERROR_NONE
	}
	if strings.equal_fold(name, "ntile") {
		buckets := i64(1)
		if len(indexes) > 0 {
			if value := arg_of(cells, indexes[0], cell_index, 0); value.kind != .Null {
				if parsed, ok := value_to_i64(value); ok && parsed > 0 do buckets = parsed
			}
		}
		for index, j in indexes {
			bucket := i64(j) * buckets / i64(len(indexes)) + 1
			assign(rows, index, position, value_int(bucket))
		}
		return ERROR_NONE
	}
	if strings.equal_fold(name, "first_value") || strings.equal_fold(name, "last_value") ||
	   strings.equal_fold(name, "nth_value") {
		if window.frame.has {
			for index, j in indexes {
				lo, hi, frame_err := window_frame_bounds(window.frame, j, len(indexes), ctx.params)
				if frame_err.kind != .None do return frame_err
				target := lo
				switch {
				case strings.equal_fold(name, "last_value"):
					target = hi
				case strings.equal_fold(name, "nth_value"):
					wanted := i64(1)
					if value := arg_of(cells, index, cell_index, 1); value.kind != .Null {
						if parsed, ok := value_to_i64(value); ok do wanted = parsed
					}
					if wanted < 1 || lo > hi || int(wanted) > hi - lo + 1 {
						assign(rows, index, position, value_null())
						continue
					}
					target = lo + int(wanted) - 1
				}
				if lo > hi {
					assign(rows, index, position, value_null())
					continue
				}
				assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
			}
			return ERROR_NONE
		}
		for index, j in indexes {
			target := 0
			switch {
			case strings.equal_fold(name, "last_value"):
				target = running ? peer_end(order_keys, j) : len(indexes) - 1
			case strings.equal_fold(name, "nth_value"):
				wanted := i64(1)
				if value := arg_of(cells, index, cell_index, 1); value.kind != .Null {
					if parsed, ok := value_to_i64(value); ok do wanted = parsed
				}
				if wanted < 1 || wanted > i64(len(indexes)) do continue
				target = int(wanted - 1)
			}
			assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
		}
		return ERROR_NONE
	}
	// Aggregate windows reuse the group aggregate: the frame is a group.
	call := Call_Expr{name = window.name, args = window.args, star = window.star}
	if window.frame.has {
		for j in 0 ..< len(indexes) {
			lo, hi, frame_err := window_frame_bounds(window.frame, j, len(indexes), ctx.params)
			if frame_err.kind != .None do return frame_err
			value, agg_err := window_aggregate_over(ctx, call, sources, indexes, lo, hi)
			if agg_err.kind != .None do return agg_err
			assign(rows, indexes[j], position, value)
		}
		return ERROR_NONE
	}
	j := 0
	for j < len(indexes) {
		end := running ? peer_end(order_keys, j) : len(indexes) - 1
		frame := make([][]Source, end + 1)
		for f in 0 ..= end do frame[f] = sources[indexes[f]]
		ctx.group = frame
		ctx.grouped = true
		value, agg_err := eval_aggregate(ctx, call)
		ctx.group = nil
		ctx.grouped = false
		delete(frame)
		if agg_err.kind != .None do return agg_err
		for f in j ..= end do assign(rows, indexes[f], position, value)
		j = end + 1
	}
	return ERROR_NONE
}

// window_frame_bounds turns a ROWS frame into the inclusive range of partition
// positions it covers for row `j`. An empty frame (lo > hi) is legal: the
// aggregate over no rows still has a value (count 0, sum NULL).
@(private)
window_frame_bounds :: proc(
	frame: Window_Frame,
	j: int,
	count: int,
	params: []Value,
) -> (lo: int, hi: int, err: Error) {
	bound_position :: proc(bound: Frame_Bound, j: int, is_start: bool, count: int, params: []Value) -> (int, Error) {
		switch bound.kind {
		case .Unbounded_Preceding:
			if !is_start do return 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
			return 0, ERROR_NONE
		case .Unbounded_Following:
			if is_start do return 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
			return count, ERROR_NONE
		case .Current_Row:
			return j, ERROR_NONE
		case .Preceding, .Following:
			offset := i64(1)
			if bound.offset != nil {
				value, constant := eval_constant(bound.offset, params)
				if !constant {
					return 0, errf(.Invalid_Argument, "a frame offset must be a constant")
				}
				parsed, ok := value_to_i64(value)
				if !ok || parsed < 0 {
					return 0, errf(.Invalid_Argument, "a frame offset must be a non-negative integer")
				}
				offset = parsed
			}
			if bound.kind == .Preceding do return j - int(offset), ERROR_NONE
			return j + int(offset), ERROR_NONE
		}
		return 0, ERROR_NONE
	}
	start, lo_err := bound_position(frame.start, j, true, count, params)
	if lo_err.kind != .None do return 0, 0, lo_err
	end, hi_err := bound_position(frame.end, j, false, count, params)
	if hi_err.kind != .None do return 0, 0, hi_err
	lo = start
	hi = end
	if lo < 0 do lo = 0
	if hi > count - 1 do hi = count - 1
	return lo, hi, ERROR_NONE
}

// window_aggregate_over evaluates an aggregate over positions [lo, hi] of the
// partition. An empty range is an empty group, not an error.
@(private)
window_aggregate_over :: proc(
	ctx: ^Eval_Ctx,
	call: Call_Expr,
	sources: [][]Source,
	indexes: []int,
	lo: int,
	hi: int,
) -> (Value, Error) {
	if lo > hi {
		ctx.group = nil
		ctx.grouped = true
		defer ctx.grouped = false
		return eval_aggregate(ctx, call)
	}
	frame := make([][]Source, hi - lo + 1)
	defer delete(frame)
	for f in lo ..= hi do frame[f - lo] = sources[indexes[f]]
	ctx.group = frame
	ctx.grouped = true
	value, agg_err := eval_aggregate(ctx, call)
	ctx.group = nil
	ctx.grouped = false
	return value, agg_err
}

// window_sort orders the row indexes of a partition by their ORDER BY keys.
// Insertion sort keeps equal keys in row order, which the peer logic relies on.
window_sort :: proc(indexes: []int, order_keys: []string) {
	for j in 1 ..< len(indexes) {
		current := indexes[j]
		current_key := order_keys[j]
		at := j
		for at > 0 && order_keys[at - 1] > current_key {
			indexes[at] = indexes[at - 1]
			order_keys[at] = order_keys[at - 1]
			at -= 1
		}
		indexes[at] = current
		order_keys[at] = current_key
	}
}

// apply_windows fills every window projection once all output rows exist.
apply_windows :: proc(
	ctx: ^Eval_Ctx,
	expanded: []^Expr,
	positions: []int,
	cells: [][dynamic]Window_Cell,
	rows: []Output_Row,
	sources: [][]Source,
) -> Error {
	for position, cell_index in positions {
		window := expanded[position]^.(Window_Expr)
		if !window_is_known(window.name) {
			return errf(.Sql_Unsupported, "unknown window function %s()", window.name)
		}
		if len(window.partition) == 0 {
			indexes := make([]int, len(rows))
			order_keys := make([]string, len(rows))
			for _, i in rows {
				indexes[i] = i
				order_keys[i] = string(cells[i][cell_index].order)
			}
			window_sort(indexes, order_keys)
			if fill_err := window_fill(ctx, window, position, indexes, order_keys, rows, cells, cell_index, sources); fill_err.kind != .None {
				delete(indexes)
				delete(order_keys)
				return fill_err
			}
			delete(indexes)
			delete(order_keys)
			continue
		}
		buckets := make(map[string][dynamic]int)
		keys := make([dynamic]string)
		for _, i in rows {
			key := string(cells[i][cell_index].partition)
			bucket, exists := buckets[key]
			if !exists do append(&keys, strings.clone(key))
			append(&bucket, i)
			buckets[key] = bucket
		}
		for key in keys {
			indexes := buckets[key]
			order_keys := make([]string, len(indexes))
			for index, j in indexes do order_keys[j] = string(cells[index][cell_index].order)
			window_sort(indexes[:], order_keys)
			fill_err := window_fill(ctx, window, position, indexes[:], order_keys, rows, cells, cell_index, sources)
			delete(order_keys)
			delete(indexes)
			delete(key)
			if fill_err.kind != .None {
				for other in keys {
					if other == key do continue
					delete(other)
				}
				return fill_err
			}
		}
		delete(keys)
		delete(buckets)
	}
	return ERROR_NONE
}

// window_positions lists the projection indexes that hold a window expression.
window_positions_of :: proc(expanded: []^Expr) -> []int {
	positions := make([dynamic]int)
	for expr, i in expanded {
		if _, is_window := expr^.(Window_Expr); is_window do append(&positions, i)
	}
	return positions[:]
}

// window_cell_for reports whether a projection index holds a window expression.
window_cell_for :: proc(positions: []int, index: int) -> int {
	for position, at in positions {
		if position == index do return at
	}
	return -1
}

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
	has_text:   bool,
	separator:  string,
	sep_owned:  bool,
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
		if acc.builder.buf != nil do strings.builder_destroy(&acc.builder)
		if acc.sep_owned do delete(acc.separator)
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
		if value.kind == .Null do continue
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
			if !value_is_numeric(value) {
				return errf(.Invalid_Type, "%s() expects numbers", acc.name)
			}
			if value.kind == .Float {
				acc.uses_float = true
				number, _ := value_to_f64(value)
				acc.sum_float += number
			} else if value.kind == .Int128 || value.kind == .Uint128 {
				if !acc.uses_128 {
					acc.uses_128 = true
					acc.sum_128 = i128(acc.sum_int)
				}
				acc.sum_128 += value_as_i128(value)
			} else if acc.uses_float {
				number, _ := value_to_f64(value)
				acc.sum_float += number
			} else if acc.uses_128 {
				number, _ := value_to_i64(value)
				acc.sum_128 += i128(number)
			} else {
				number, _ := value_to_i64(value)
				acc.sum_int += number
			}
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
	case "sum", "total":
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
}

@(private)
stream_row_visit :: proc(raw: rawptr, row: Row) -> bool {
	scan := cast(^Stream_Scan_Ctx)raw
	if scan.err.kind != .None do return false
	// The slice lives on this frame: one allocation per row in the transaction
	// arena would make a streamed scan cost the table again in memory.
	one: [1]Source
	one[0] = Source{table = scan.base, row = row, alias = scan.alias}
	ctx := Eval_Ctx {
		tx      = scan.tx,
		sources = one[:],
		params  = scan.params,
		now_us  = scan.now_us,
	}
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
	if len(stmt.joins) != 0 || len(stmt.group_by) != 0 || len(stmt.order_by) != 0 do return {}, false, ERROR_NONE
	if stmt.is_distinct || stmt.having != nil || stmt.from.as_of != nil do return {}, false, ERROR_NONE
	if tx.state.dropped[stmt.from.name] do return {}, false, ERROR_NONE
	if writes, has := tx.state.writes[stmt.from.name]; has {
		if writes.truncated ||
		   len(writes.inserts) > 0 ||
		   len(writes.updates) > 0 ||
		   len(writes.deletes) > 0 {
			return {}, false, ERROR_NONE
		}
	}
	// An index answers a point or range query with a handful of rows, which is
	// cheaper than walking every page. The probe is the same one the main path
	// runs; only the answer is used here.
	if _, indexed := index_candidates(tx, base, stmt.from.name, stmt.from.alias, stmt.where_clause, params); indexed {
		return {}, false, ERROR_NONE
	}

	now_us := now_microseconds()
	statement := stmt
	stream := Agg_Stream{}
	defer agg_stream_destroy(&stream)
	probe := make([]Source, 1, tx.alloc)
	probe[0] = Source{table = base, alias = stmt.from.alias}
	columns := make([dynamic]string, 0, len(stmt.projections), tx.alloc)
	expanded := expand_projections(probe, stmt.projections, &columns, tx.alloc)
	if len(expanded) == 0 do return {}, false, ERROR_NONE
	aggregate := false
	for expr in expanded {
		if _, is_window := expr^.(Window_Expr); is_window do return {}, false, ERROR_NONE
		if !expr_is_aggregate(expr) do continue
		call, direct := expr^.(Call_Expr)
		if !direct || !is_aggregate_name(call.name) || call.is_distinct {
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
		aggregate = true
		append(&stream.accs, Agg_Acc{call = call, name = strings.to_lower(call.name)})
	}

	limit := -1
	offset := 0
	if stmt.offset != nil {
		value, value_err := eval_expr(&Eval_Ctx{tx = tx, params = params, now_us = now_us}, stmt.offset)
		if value_err.kind != .None do return {}, false, value_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 do return {}, false, errf(.Invalid_Argument, "OFFSET must be a non-negative integer")
		offset = int(parsed)
	}
	if stmt.limit != nil {
		value, value_err := eval_expr(&Eval_Ctx{tx = tx, params = params, now_us = now_us}, stmt.limit)
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
	}
	if scan_err := tx_scan_visit(tx, stmt.from.name, &scan_ctx, stream_row_visit); scan_err.kind != .None {
		return {}, false, scan_err
	}
	if scan_ctx.err.kind != .None do return {}, false, scan_ctx.err

	if aggregate {
		final := Eval_Ctx{tx = tx, params = params, now_us = now_us, stream = &stream}
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
	if len(stmt.compound) > 0 do return sql_exec_compound(tx, stmt, params)
	// A SELECT without FROM evaluates its projections once against an empty row.
	// System tables are synthesized from the catalog instead of being scanned.
	empty_row := len(stmt.from.name) == 0
	system_name := is_system_table(stmt.from.name)
	synthetic: Table
	base: ^Table
	base_is_view := false
	if !empty_row && !system_name {
		base_args, args_err := view_args(tx, stmt.from, params)
		if args_err.kind != .None do return {}, args_err
		source_table, source_view, table_err := tx_source_table(
			tx,
			stmt.from.name,
			base_args,
			stmt.from.schema,
		)
		if table_err.kind != .None do return {}, table_err
		base = source_table
		base_is_view = source_view
	}
	if system_name do base = &synthetic
	ctx := Eval_Ctx {
		tx     = tx,
		params = params,
		now_us = now_microseconds(),
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

	// Base rows. A usable index narrows the scan; the WHERE clause is still
	// re-checked below.
	partials := make([dynamic][]Source)
	used_index := false
	if system_name {
		synthetic.schema = system_table_schema(stmt.from.name, tx.alloc)
		catalog_rows := system_table_rows(tx, stmt.from.name, tx.alloc)
		for row in catalog_rows {
			// The source slice is freed by the filter below, so it cannot come
			// from the transaction arena (the row values inside still do: they
			// are only read, never freed here).
			one := make([]Source, 1)
			one[0] = Source{table = base, row = row, alias = stmt.from.alias}
			append(&partials, one)
		}
		used_index = true
	}
	if empty_row {
		append(&partials, make([]Source, 0))
		used_index = true
	}
	// A historical read asks for the rows as they were at one commit. It cannot
	// use an index (the keys of that commit are not the live ones) and it ignores
	// the staged writes: it reads what committed.
	as_of_seq: u64 = 0
	if stmt.from.as_of != nil {
		if base_is_view {
			return {}, errf(.Sql_Unsupported, "AS OF reads a table, not a view")
		}
		moment, constant := eval_constant(stmt.from.as_of, params)
		if !constant {
			return {}, errf(.Invalid_Argument, "AS OF needs a constant commit sequence")
		}
		sequence, ok := value_to_i64(moment)
		if !ok || sequence < 0 {
			return {}, errf(.Invalid_Argument, "AS OF needs a non-negative commit sequence")
		}
		as_of_seq = u64(sequence)
		if as_of_seq > tx.store.commit_seq do as_of_seq = tx.store.commit_seq
	}
	// A view already holds a materialized table: scan it directly.
	if !base_is_view && !empty_row && as_of_seq == 0 {
		if candidate_ids, used, fts_err := fts_scan_candidates(
			tx,
			stmt.from.name,
			stmt.from.alias,
			stmt.where_clause,
			params,
		); used {
			if fts_err.kind != .None {
				free_partials(&partials)
				return {}, fts_err
			}
			defer delete(candidate_ids)
			for id in candidate_ids {
				tx.rows_scanned += 1
				if row, exists := tx_get(tx, stmt.from.name, id); exists {
					one := make([]Source, 1)
					one[0] = Source{table = base, row = row, alias = stmt.from.alias}
					append(&partials, one)
				}
			}
			used_index = true
		} else if indexed_ids, indexed := index_candidates(tx, base, stmt.from.name, stmt.from.alias, stmt.where_clause, params); indexed {
			defer delete(indexed_ids)
			for id in indexed_ids {
				tx.rows_scanned += 1
				if row, exists := tx_get(tx, stmt.from.name, id); exists {
					one := make([]Source, 1)
					one[0] = Source{table = base, row = row, alias = stmt.from.alias}
					append(&partials, one)
				}
			}
			used_index = true
		}
	}
	if !used_index {
		rows := make([dynamic]Row)
		if base_is_view {
			table_collect(base, &rows, tx.read_seq)
		} else if as_of_seq > 0 {
			if collect_err := tx_collect_at(tx, stmt.from.name, &rows, as_of_seq); collect_err.kind != .None {
				return {}, collect_err
			}
		} else if collect_err := tx_collect(tx, stmt.from.name, &rows); collect_err.kind != .None {
			return {}, collect_err
		}
		for row in rows {
			tx.rows_scanned += 1
			one := make([]Source, 1)
			one[0] = Source{table = base, row = row, alias = stmt.from.alias}
			append(&partials, one)
		}
		delete(rows)
	}
	if !empty_row {
		slice.sort_by(partials[:], proc(a, b: []Source) -> bool {
			return u64(a[0].row.id) < u64(b[0].row.id)
		})
	}

	// Nested-loop joins. Each partial is one bound combination of rows.
	for join in stmt.joins {
		if join.table.as_of != nil {
			free_partials(&partials)
			return {}, errf(.Sql_Unsupported, "AS OF is only supported on the first table of a join")
		}
		// A JSON table function may take a column of the table before it, so it
		// is materialized once per outer row (a lateral join). Everything else is
		// collected once. The materialized tables stay in tx.temp_tables until the
		// statement ends, because the rows the join reads point into them.
		lateral := is_json_table_function(join.table.name)
		table: ^Table
		join_is_view: bool
		rows := make([dynamic]Row)
		if !lateral {
			join_args, join_args_err := view_args(tx, join.table, params)
			if join_args_err.kind != .None {
				free_partials(&partials)
				return {}, join_args_err
			}
			resolved, resolved_is_view, join_err := tx_source_table(
				tx,
				join.table.name,
				join_args,
				join.table.schema,
			)
			if join_err.kind != .None {
				free_partials(&partials)
				return {}, join_err
			}
			table = resolved
			join_is_view = resolved_is_view
			if join_is_view {
				table_collect(table, &rows, tx.read_seq)
			} else if collect_err := tx_collect(tx, join.table.name, &rows); collect_err.kind != .None {
				free_partials(&partials)
				return {}, collect_err
			}
		}
		next := make([dynamic][]Source)
		for partial in partials {
			if tx.store.cancelled {
				delete(rows)
				free_partials(&partials)
				free_partials(&next)
				return {}, errf(.Cancelled, "query cancelled")
			}
			lateral_rows := rows
			if lateral {
				lateral_args, lateral_args_err := view_args(tx, join.table, params, partial)
				if lateral_args_err.kind != .None {
					free_partials(&partials)
					free_partials(&next)
					return {}, lateral_args_err
				}
				lateral_table, _, lateral_err := tx_source_table(
					tx,
					join.table.name,
					lateral_args,
					join.table.schema,
				)
				if lateral_err.kind != .None {
					free_partials(&partials)
					free_partials(&next)
					return {}, lateral_err
				}
				table = lateral_table
				lateral_rows = make([dynamic]Row)
				table_collect(lateral_table, &lateral_rows, tx.read_seq)
			}
			matched := false
			for row in lateral_rows {
				tx.rows_scanned += 1
				candidate := make([]Source, len(partial) + 1)
				copy(candidate, partial)
				candidate[len(partial)] = Source{table = table, row = row, alias = join.table.alias}
				if join.on != nil {
					ctx.sources = candidate
					value, eval_err := eval_expr(&ctx, join.on)
					if eval_err.kind != .None {
						delete(candidate)
						delete(rows)
						free_partials(&partials)
						free_partials(&next)
						return {}, eval_err
					}
					if !value_is_truthy(value) {
						delete(candidate)
						continue
					}
				}
				append(&next, candidate)
				matched = true
			}
			if join.left && !matched {
				candidate := make([]Source, len(partial) + 1)
				copy(candidate, partial)
				candidate[len(partial)] = Source{table = table, row = Row{}, alias = join.table.alias}
				append(&next, candidate)
			}
			if lateral do delete(lateral_rows)
		}
		delete(rows)
		free_partials(&partials)
		partials = next
	}

	// Row-level policies load once per statement. A denied row never reaches
	// the projection, an aggregate or the join output.
	policies := make([dynamic]Policy_Set)
	defer policy_sets_destroy(&policies)
	policy_tables := make([dynamic]string)
	defer delete(policy_tables)
	append(&policy_tables, stmt.from.name)
	for join in stmt.joins do append(&policy_tables, join.table.name)
	for name in policy_tables {
		if len(name) == 0 || is_system_table(name) do continue
		set, policy_err := policy_load(tx, name)
		if policy_err.kind != .None {
			free_partials(&partials)
			return {}, policy_err
		}
		append(&policies, set)
	}

	// WHERE
	filtered := make([dynamic][]Source)
	for partial, index in partials {
		if tx.store.cancelled {
			// The rows before this one were either kept (and freed through
			// filtered) or freed in place, so only the pending ones are left.
			for pending in partials[index:] do delete(pending)
			for kept in filtered do delete(kept)
			delete(partials)
			delete(filtered)
			return {}, errf(.Cancelled, "query cancelled")
		}
		keep := true
		ctx.sources = partial
		for &set in policies {
			allowed, policy_err := policy_allows(&set, &ctx, false)
			if policy_err.kind != .None {
				for pending in partials[index:] do delete(pending)
				for kept in filtered do delete(kept)
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
				// A rejected row frees its sources in place, so the pending
				// ones and the kept ones are all that is left.
				for pending in partials[index:] do delete(pending)
				for kept in filtered do delete(kept)
				delete(partials)
				delete(filtered)
				return {}, eval_err
			}
			keep = value_is_truthy(value)
		}
		if keep {
			append(&filtered, partial)
		} else {
			delete(partial)
		}
	}
	delete(partials)

	star_sources := make([dynamic]Source)
	if !empty_row {
		append(&star_sources, Source{table = base, alias = stmt.from.alias})
	}
	for join in stmt.joins {
		if table, ok := tx_table(tx, join.table.name); ok.kind == .None {
			append(&star_sources, Source{table = table, alias = join.table.alias})
		}
	}
	columns := make([dynamic]string, 0, len(stmt.projections))
	expanded := expand_projections(star_sources[:], stmt.projections, &columns, tx.alloc)
	delete(star_sources)
	if len(expanded) == 0 {
		free_partials(&filtered)
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
		free_partials(&filtered)
		return {}, errf(.Sql_Unsupported, "HAVING needs GROUP BY or an aggregate")
	}
	window_positions := window_positions_of(expanded)
	defer delete(window_positions)
	if len(window_positions) > 0 && aggregate {
		free_partials(&filtered)
		return {}, errf(
			.Sql_Unsupported,
			"window functions next to GROUP BY are not supported",
		)
	}
	has_windows := len(window_positions) > 0
	window_cells := make([dynamic][dynamic]Window_Cell, 0, len(filtered))
	window_sources := make([dynamic][]Source, 0, len(filtered))

	output := make([dynamic]Output_Row, 0, len(filtered))
	if aggregate {
		groups := make([dynamic][dynamic][]Source)
		if len(stmt.group_by) == 0 {
			group := make([dynamic][]Source, 0, len(filtered))
			for partial in filtered do append(&group, partial)
			append(&groups, group)
		} else {
			buckets := make(map[string][dynamic][]Source)
			keys := make([dynamic]string)
			for partial in filtered {
				ctx.sources = partial
				w: Byte_Writer
				bw_init(&w)
				group_ok := true
				for expr in stmt.group_by {
					value, eval_err := eval_expr(&ctx, expr)
					if eval_err.kind != .None {
						bw_destroy(&w)
						group_ok = false
						break
					}
					value_encode_key(&w, value)
				}
				if !group_ok {
					for key in keys do delete(key)
					delete(keys)
					delete(buckets)
					free_partials(&filtered)
					return {}, errf(.Invalid_Type, "GROUP BY expression failed")
				}
				key := strings.clone(string(bw_bytes(&w)))
				bw_destroy(&w)
				bucket, exists := buckets[key]
				if !exists do append(&keys, key)
				append(&bucket, partial)
				buckets[key] = bucket
			}
			slice.sort_by(keys[:], proc(a, b: string) -> bool {
				return strings.compare(a, b) < 0
			})
			for key in keys {
				append(&groups, buckets[key])
				delete(key)
			}
			delete(keys)
			delete(buckets)
		}
		for group in groups {
			ctx.group = group[:]
			ctx.grouped = true
			if len(group) > 0 {
				ctx.sources = group[0]
			} else {
				ctx.sources = nil
			}
			values := make([]Value, len(expanded))
			for expr, i in expanded {
				value, eval_err := eval_expr(&ctx, expr)
				if eval_err.kind != .None {
					free_values(values)
					free_partials(&filtered)
					return {}, eval_err
				}
				values[i] = value_clone(value, context.allocator)
			}
			if stmt.having != nil {
				having, having_err := eval_expr(&ctx, stmt.having)
				if having_err.kind != .None {
					free_values(values)
					free_partials(&filtered)
					return {}, having_err
				}
				if !value_is_truthy(having) {
					free_values(values)
					continue
				}
			}
			sort_key := build_order_key(&ctx, stmt.order_by, expanded, values, columns[:])
			append(
				&output,
				Output_Row{values = values, sort_key = sort_key, row_id = NO_ROW_ID},
			)
			ctx.grouped = false
			delete(group)
		}
		delete(groups)
		ctx.group = nil
		for partial in filtered do delete(partial)
	} else {
		for partial, index in filtered {
			ctx.sources = partial
			values := make([]Value, len(expanded))
			cells := make([dynamic]Window_Cell, 0, len(window_positions))
			for expr, i in expanded {
				if has_windows {
					if cell_index := window_cell_for(window_positions, i); cell_index >= 0 {
						window := expr^.(Window_Expr)
						partition_key, partition_err := window_partition_key(&ctx, window)
						if partition_err.kind != .None {
							free_values(values)
							free_partials(&filtered)
							return {}, partition_err
						}
						order_key, order_err := window_order_key(&ctx, window)
						if order_err.kind != .None {
							delete(partition_key)
							free_values(values)
							free_partials(&filtered)
							return {}, order_err
						}
						args := make([]Value, len(window.args))
						for arg, a in window.args {
							arg_value, arg_err := eval_expr(&ctx, arg)
							if arg_err.kind != .None {
								delete(partition_key)
								delete(order_key)
								free_values(values)
								free_partials(&filtered)
								return {}, arg_err
							}
							args[a] = value_clone(arg_value, context.allocator)
						}
						append(&cells, Window_Cell{partition = partition_key, order = order_key, args = args})
						values[i] = value_null()
						continue
					}
				}
				value, eval_err := eval_expr(&ctx, expr)
				if eval_err.kind != .None {
					free_values(values)
					// Earlier rows already released their sources, so only the
					// pending ones are freed here.
					for pending in filtered[index:] do delete(pending)
					delete(filtered)
					return {}, eval_err
				}
				values[i] = value_clone(value, context.allocator)
			}
			// The row id comes from the sources, which the non-window branch
			// frees below: read it first, never after the delete.
			row_id := len(partial) == 1 ? partial[0].row.id : NO_ROW_ID
			sort_key := build_order_key(&ctx, stmt.order_by, expanded, values, columns[:])
			if has_windows {
				// The keys are rebuilt once the window values exist, so the
				// sources have to outlive the loop.
				sort_key = nil
				append(&window_cells, cells)
				append(&window_sources, partial)
			} else {
				delete(cells)
				delete(partial)
			}
			append(&output, Output_Row{values = values, sort_key = sort_key, row_id = row_id})
		}
	}
	delete(filtered)

	if has_windows {
		if window_err := apply_windows(&ctx, expanded, window_positions, window_cells[:], output[:], window_sources[:]); window_err.kind != .None {
			for row in output do free_values(row.values)
			for cells in window_cells do delete(cells)
			for sources in window_sources do delete(sources)
			delete(output)
			return {}, window_err
		}
		// ORDER BY runs on the completed rows, so an alias that names a window
		// projection sorts on its value.
		for &row, i in output {
			ctx.sources = window_sources[i]
			row.sort_key = build_order_key(&ctx, stmt.order_by, expanded, row.values, columns[:])
		}
		ctx.sources = nil
		for cells in window_cells {
			for cell in cells {
				delete(cell.partition)
				delete(cell.order)
				free_values(cell.args)
			}
			delete(cells)
		}
		delete(window_cells)
		for sources in window_sources do delete(sources)
		delete(window_sources)
	}

	if len(stmt.order_by) > 0 {
		slice.sort_by(output[:], proc(a, b: Output_Row) -> bool {
			return string(sort_key_bytes(a.sort_key)) < string(sort_key_bytes(b.sort_key))
		})
	}

	if stmt.is_distinct {
		seen := make(map[string]bool)
		defer delete(seen)
		kept := make([dynamic]Output_Row, 0, len(output))
		for row in output {
			key := encode_output_key(row.values)
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
	result.columns = make([]string, len(columns))
	for column, i in columns do result.columns[i] = strings.clone(column)
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
			for source in sources {
				qualifier := len(source.alias) > 0 ? source.alias : source.table.schema.name
				if len(star_qualifier) > 0 {
					matches := strings.equal_fold(star_qualifier, source.table.schema.name) ||
						(len(source.alias) > 0 && strings.equal_fold(star_qualifier, source.alias))
					if !matches do continue
				}
				for column in source.table.schema.columns {
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

@(private)
projection_name :: proc(item: Select_Item) -> string {
	if len(item.alias) > 0 do return strings.clone(item.alias)
	if item.expr != nil {
		if column, ok := item.expr^.(Column_Expr); ok {
			return strings.clone(column.name)
		}
	}
	return strings.clone("?column?")
}

// build_order_key turns the ORDER BY clause of one output row into one byte
// string: ascending parts keep their order-preserving encoding, descending parts
// get every byte inverted. Comparing the strings then gives the requested order.
@(private)
build_order_key :: proc(
	ctx: ^Eval_Ctx,
	order_by: []Order_Item,
	projections: []^Expr,
	values: []Value,
	names: []string,
) -> []u8 {
	if len(order_by) == 0 do return nil
	w: Byte_Writer
	bw_init(&w)
	for item in order_by {
		value := eval_order_value(ctx, item.expr, projections, values, names)
		// ORDER BY x COLLATE NOCASE sorts on the folded key.
		collation, has := collate_name(item.expr)
		if !has {
			collation, has = column_collation(ctx, item.expr)
		}
		if has && len(collation) > 0 {
			value = collate_ordered_value(value, collation)
		}
		start := len(w.data)
		value_encode_key(&w, value)
		if item.descending {
			for i in start ..< len(w.data) {
				w.data[i] = ~w.data[i]
			}
		}
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	bw_destroy(&w)
	return out
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
	if eval_err.kind != .None do return value_null()
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

// --- Expressions -----------------------------------------------------------

eval_expr :: proc(ctx: ^Eval_Ctx, expr: ^Expr) -> (Value, Error) {
	if expr == nil do return value_null(), ERROR_NONE
	switch e in expr^ {
	case Literal_Expr:
		return e.value, ERROR_NONE
	case Column_Expr:
		if len(e.table) > 0 {
			// Inside a trigger body NEW and OLD name the rows of the event.
			if ctx.tx != nil && ctx.tx.trigger_active {
				is_new := strings.equal_fold(e.table, "new")
				if is_new || strings.equal_fold(e.table, "old") {
					index, found := schema_column_index(&ctx.tx.trigger_schema, e.name)
					if !found {
						return {}, errf(
							.Column_Not_Found,
							"column %s does not exist in %s",
							e.name,
							is_new ? "NEW" : "OLD",
						)
					}
					present := is_new ? ctx.tx.trigger_new_present : ctx.tx.trigger_old_present
					if !present do return value_null(), ERROR_NONE
					row := is_new ? ctx.tx.trigger_new : ctx.tx.trigger_old
					if index >= len(row.values) do return value_null(), ERROR_NONE
					return row.values[index], ERROR_NONE
				}
			}
			for source in ctx.sources {
				matches := strings.equal_fold(e.table, source.table.schema.name) ||
					(len(source.alias) > 0 && strings.equal_fold(e.table, source.alias))
				if !matches do continue
				index, found := schema_column_index(&source.table.schema, e.name)
				if !found {
					// rank is a hidden column of a full-text table: it is the
					// score of the MATCH that this query ran.
					if strings.equal_fold(e.name, "rank") {
						if score, scored := fts_rank_value(ctx.tx, source.table.schema.name, source.row.id); scored {
							return value_float(score), ERROR_NONE
						}
					}
					return {}, errf(
						.Column_Not_Found,
						"column %s does not exist in %s",
						e.name,
						source.table.schema.name,
					)
				}
				if index >= len(source.row.values) do return value_null(), ERROR_NONE
				return source.row.values[index], ERROR_NONE
			}
			return {}, errf(.Column_Not_Found, "table %s is not in the query", e.table)
		}
		found_value: Value
		found := false
		for source in ctx.sources {
			if source.hidden_unqualified do continue
			index, exists := schema_column_index(&source.table.schema, e.name)
			if !exists do continue
			if found {
				return {}, errf(.Column_Not_Found, "column %s is ambiguous; qualify it with a table", e.name)
			}
			found = true
			if index < len(source.row.values) {
				found_value = source.row.values[index]
			} else {
				found_value = value_null()
			}
		}
		if !found && strings.equal_fold(e.name, "rank") {
			for source in ctx.sources {
				if score, scored := fts_rank_value(ctx.tx, source.table.schema.name, source.row.id); scored {
					return value_float(score), ERROR_NONE
				}
			}
		}
		if !found {
			return {}, errf(.Column_Not_Found, "column %s does not exist", e.name)
		}
		return found_value, ERROR_NONE
	case Star_Expr:
		return {}, errf(.Sql_Syntax, "* is only allowed in a projection")
	case Collate_Expr:
		return eval_expr(ctx, e.operand)
	case Binary_Expr:
		// A COLLATE on either side decides how the comparison treats text.
		collation := ""
		if collate, ok := collate_name(e.left); ok do collation = collate
		if collate, ok := collate_name(e.right); ok do collation = collate
		if len(collation) == 0 {
			if declared, ok := column_collation(ctx, e.left); ok do collation = declared
			if len(collation) == 0 {
				if declared, ok := column_collation(ctx, e.right); ok do collation = declared
			}
		}
		left, left_err := eval_expr(ctx, e.left)
		if left_err.kind != .None do return {}, left_err
		right, right_err := eval_expr(ctx, e.right)
		if right_err.kind != .None do return {}, right_err
		return eval_binary(e.op, left, right, collation)
	case Unary_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		return eval_unary(e.op, operand)
	case Is_Null_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		is_null := operand.kind == .Null
		return value_bool(e.negated ? !is_null : is_null), ERROR_NONE
	case Between_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		low, low_err := eval_expr(ctx, e.low)
		if low_err.kind != .None do return {}, low_err
		high, high_err := eval_expr(ctx, e.high)
		if high_err.kind != .None do return {}, high_err
		if operand.kind == .Null || low.kind == .Null || high.kind == .Null {
			return value_null(), ERROR_NONE
		}
		low_order, low_ok := value_compare(operand, low)
		high_order, high_ok := value_compare(operand, high)
		if !low_ok || !high_ok {
			return {}, errf(.Invalid_Type, "BETWEEN mixes incompatible types")
		}
		inside := low_order != .Less && high_order != .Greater
		return value_bool(e.negated ? !inside : inside), ERROR_NONE
	case Subquery_Expr:
		if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
		if e.select == nil do return value_null(), ERROR_NONE
		sub, sub_err := sql_exec_select(ctx.tx, e.select^, ctx.params)
		if sub_err.kind != .None do return {}, sub_err
		defer sql_result_destroy(&sub)
		if e.exists do return value_bool(len(sub.rows) > 0), ERROR_NONE
		if len(sub.rows) == 0 || len(sub.rows[0]) == 0 do return value_null(), ERROR_NONE
		return sub.rows[0][0], ERROR_NONE
	case In_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		if operand.kind == .Null do return value_null(), ERROR_NONE
		if e.subquery != nil {
			if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
			sub, sub_err := sql_exec_select(ctx.tx, e.subquery^, ctx.params)
			if sub_err.kind != .None do return {}, sub_err
			defer sql_result_destroy(&sub)
			found := false
			for row in sub.rows {
				if len(row) == 0 do continue
				if row[0].kind == .Null do continue
				if value_equal(operand, row[0]) {
					found = true
					break
				}
			}
			return value_bool(e.negated ? !found : found), ERROR_NONE
		}
		found := false
		for item in e.items {
			value, item_err := eval_expr(ctx, item)
			if item_err.kind != .None do return {}, item_err
			if value.kind == .Null do continue
			if value_equal(operand, value) {
				found = true
				break
			}
		}
		return value_bool(e.negated ? !found : found), ERROR_NONE
	case Call_Expr:
		return eval_call(ctx, e)
	case Window_Expr:
		return {}, errf(
			.Sql_Unsupported,
			"window function %s() cannot be evaluated here",
			e.name,
		)
	case Match_Expr:
		pattern, pattern_err := eval_expr(ctx, e.pattern)
		if pattern_err.kind != .None do return {}, pattern_err
		if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "MATCH needs a transaction")
		return fts_match_eval(ctx.tx, ctx, e.operand, pattern)
	case Like_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		pattern, pattern_err := eval_expr(ctx, e.pattern)
		if pattern_err.kind != .None do return {}, pattern_err
		if operand.kind == .Null || pattern.kind == .Null do return value_null(), ERROR_NONE
		if operand.kind != .String || pattern.kind != .String {
			return {}, errf(.Invalid_Type, "LIKE needs text on both sides")
		}
		// SQLite's LIKE ignores ASCII case; GLOB does not.
		matched := e.glob ? glob_match(operand.s, pattern.s) : like_match(operand.s, pattern.s, true, e.escape)
		return value_bool(e.negated ? !matched : matched), ERROR_NONE
	case Cast_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		return value_cast(operand, e.target)
	case Param_Expr:
		if e.index < 0 || e.index >= len(ctx.params) {
			return {}, errf(
				.Invalid_Argument,
				"bind parameter %d was not supplied (the statement has %d)",
				e.index + 1,
				len(ctx.params),
			)
		}
		return ctx.params[e.index], ERROR_NONE
	}
	return {}, errf(.Internal, "unknown expression")
}

eval_binary :: proc(op: Binary_Op, left, right: Value, collation: string = "") -> (Value, Error) {
	#partial switch op {
	case .And:
		if !value_is_null(left) && !value_is_truthy(left) do return value_bool(false), ERROR_NONE
		if !value_is_null(right) && !value_is_truthy(right) do return value_bool(false), ERROR_NONE
		if value_is_null(left) || value_is_null(right) do return value_null(), ERROR_NONE
		return value_bool(true), ERROR_NONE
	case .Or:
		if value_is_truthy(left) do return value_bool(true), ERROR_NONE
		if value_is_truthy(right) do return value_bool(true), ERROR_NONE
		if value_is_null(left) || value_is_null(right) do return value_null(), ERROR_NONE
		return value_bool(false), ERROR_NONE
	case:
	}
	if value_is_null(left) || value_is_null(right) {
		return value_null(), ERROR_NONE
	}
	switch op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		order, ok := value_compare_collated(left, right, collation)
		if !ok {
			return {}, errf(
				.Invalid_Type,
				"cannot compare %s with %s",
				value_kind_name(left.kind),
				value_kind_name(right.kind),
			)
		}
		result := false
		#partial switch op {
		case .Eq:
			result = order == .Equal
		case .Ne:
			result = order != .Equal
		case .Lt:
			result = order == .Less
		case .Le:
			result = order != .Greater
		case .Gt:
			result = order == .Greater
		case .Ge:
			result = order != .Less
		}
		return value_bool(result), ERROR_NONE
	case .Concat:
		left_text := value_to_text(left)
		right_text := value_to_text(right)
		return value_string(strings.concatenate({left_text, right_text})), ERROR_NONE
	case .Add, .Sub, .Mul, .Div, .Mod:
		return eval_arithmetic(op, left, right)
	case .And, .Or:
	}
	return {}, errf(.Internal, "unknown binary operator")
}

@(private)
eval_arithmetic :: proc(op: Binary_Op, left, right: Value) -> (Value, Error) {
	if !value_is_numeric(left) || !value_is_numeric(right) {
		return {}, errf(.Invalid_Type, "arithmetic needs numbers")
	}
	if left.kind == .Int128 ||
	   left.kind == .Uint128 ||
	   right.kind == .Int128 ||
	   right.kind == .Uint128 {
		return eval_arithmetic_128(op, left, right)
	}
	if left.kind == .Float || right.kind == .Float {
		a, _ := value_to_f64(left)
		b, _ := value_to_f64(right)
		if (op == .Div || op == .Mod) && b == 0 {
			return {}, errf(.Invalid_Argument, "division by zero")
		}
		#partial switch op {
		case .Add:
			return value_float(a + b), ERROR_NONE
		case .Sub:
			return value_float(a - b), ERROR_NONE
		case .Mul:
			return value_float(a * b), ERROR_NONE
		case .Div:
			return value_float(a / b), ERROR_NONE
		case .Mod:
			return value_float(fmod(a, b)), ERROR_NONE
		case:
		}
	}
	if left.kind == .Uint || right.kind == .Uint {
		a, a_ok := value_to_u64(left)
		b, b_ok := value_to_u64(right)
		if !a_ok || !b_ok {
			return {}, errf(.Invalid_Type, "unsigned arithmetic needs non-negative values")
		}
		#partial switch op {
		case .Add:
			return value_uint(a + b), ERROR_NONE
		case .Sub:
			if b > a do return {}, errf(.Invalid_Argument, "unsigned subtraction underflows")
			return value_uint(a - b), ERROR_NONE
		case .Mul:
			return value_uint(a * b), ERROR_NONE
		case .Div:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint(a / b), ERROR_NONE
		case .Mod:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint(a % b), ERROR_NONE
		case:
		}
	}
	a, _ := value_to_i64(left)
	b, _ := value_to_i64(right)
	#partial switch op {
	case .Add:
		return value_int(a + b), ERROR_NONE
	case .Sub:
		return value_int(a - b), ERROR_NONE
	case .Mul:
		return value_int(a * b), ERROR_NONE
	case .Div:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		return value_int(a / b), ERROR_NONE
	case .Mod:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		return value_int(a % b), ERROR_NONE
	case:
	}
	return {}, errf(.Internal, "unknown arithmetic operator")
}

@(private)
eval_arithmetic_128 :: proc(op: Binary_Op, left, right: Value) -> (Value, Error) {
	unsigned := is_unsigned_kind(left.kind) || is_unsigned_kind(right.kind)
	if unsigned {
		for operand in ([]Value{left, right}) {
			if !is_unsigned_kind(operand.kind) && value_as_i128(operand) < 0 {
				return {}, errf(.Invalid_Argument, "negative value in unsigned arithmetic")
			}
		}
		a := value_as_u128(left)
		b := value_as_u128(right)
		#partial switch op {
		case .Add:
			return value_uint128(a + b), ERROR_NONE
		case .Sub:
			if b > a do return {}, errf(.Invalid_Argument, "unsigned subtraction underflows")
			return value_uint128(a - b), ERROR_NONE
		case .Mul:
			return value_uint128(a * b), ERROR_NONE
		case .Div:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint128(a / b), ERROR_NONE
		case .Mod:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint128(a % b), ERROR_NONE
		}
		return {}, errf(.Internal, "unknown arithmetic operator")
	}
	a := value_as_i128(left)
	b := value_as_i128(right)
	#partial switch op {
	case .Add:
		return value_int128(a + b), ERROR_NONE
	case .Sub:
		return value_int128(a - b), ERROR_NONE
	case .Mul:
		return value_int128(a * b), ERROR_NONE
	case .Div:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		return value_int128(a / b), ERROR_NONE
	case .Mod:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		return value_int128(a % b), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown arithmetic operator")
}

@(private)
fmod :: proc(a, b: f64) -> f64 {
	return a - b * f64(i64(a / b))
}

@(private)
eval_unary :: proc(op: Unary_Op, operand: Value) -> (Value, Error) {
	switch op {
	case .Neg:
		if operand.kind == .Null do return value_null(), ERROR_NONE
		if operand.kind == .Float do return value_float(-operand.f), ERROR_NONE
		if operand.kind == .Uint128 {
			if value_big(operand) > u128(max(i128)) + 1 {
				return {}, errf(.Invalid_Argument, "cannot negate this uint128")
			}
			return value_int128(0 - i128(value_big(operand))), ERROR_NONE
		}
		if operand.kind == .Int128 {
			if i128(value_big(operand)) == min(i128) {
				return {}, errf(.Invalid_Argument, "integer overflow negating int128")
			}
			return value_int128(0 - i128(value_big(operand))), ERROR_NONE
		}
		if operand.kind == .Uint {
			if operand.u > u64(max(i64)) + 1 {
				return {}, errf(.Invalid_Argument, "cannot negate this uint")
			}
			big := i128(0) - i128(operand.u)
			if big >= i128(min(i64)) && big <= i128(max(i64)) {
				return value_int(i64(big)), ERROR_NONE
			}
			return value_int128(big), ERROR_NONE
		}
		value, ok := value_to_i64(operand)
		if !ok do return {}, errf(.Invalid_Type, "cannot negate a %s", value_kind_name(operand.kind))
		if value == min(i64) {
			return value_int128(0 - i128(value)), ERROR_NONE
		}
		return value_int(-value), ERROR_NONE
	case .Plus:
		if !value_is_numeric(operand) && operand.kind != .Null {
			return {}, errf(.Invalid_Type, "cannot apply + to a %s", value_kind_name(operand.kind))
		}
		return operand, ERROR_NONE
	case .Not:
		if operand.kind == .Null do return value_null(), ERROR_NONE
		return value_bool(!value_is_truthy(operand)), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown unary operator")
}

@(private)
value_to_text :: proc(v: Value) -> string {
	#partial switch v.kind {
	case .String:
		return v.s
	case .Null:
		return ""
	}
	return value_format(v, context.temp_allocator)
}

// value_cast implements CAST and the implicit conversions SQL expressions need.
value_cast :: proc(v: Value, target: Column_Type) -> (Value, Error) {
	if v.kind == .Null do return value_null(), ERROR_NONE
	if target.kind == .String {
		if v.kind == .String do return v, ERROR_NONE
		return value_string(value_format(v, context.allocator)), ERROR_NONE
	}
	if coerced, coerce_err := value_coerce(v, target); coerce_err.kind == .None {
		return coerced, ERROR_NONE
	}
	if v.kind == .String {
		if parsed, ok := value_parse_number(v.s); ok {
			return value_coerce(parsed, target)
		}
		if target.kind == .Bool {
			if strings.equal_fold(v.s, "true") || v.s == "1" do return value_bool(true), ERROR_NONE
			if strings.equal_fold(v.s, "false") || v.s == "0" do return value_bool(false), ERROR_NONE
		}
	}
	return {}, errf(
		.Invalid_Type,
		"cannot cast a %s to %s",
		value_kind_name(v.kind),
		type_kind_name(target.kind),
	)
}

@(private)
expr_is_aggregate :: proc(expr: ^Expr) -> bool {
	if expr == nil do return false
	switch e in expr^ {
	case Window_Expr:
		// A window aggregate is not a group aggregate: it is computed once every
		// row is known, not while scanning.
		return false
	case Call_Expr:
		if is_aggregate_name(e.name) do return true
		for arg in e.args {
			if expr_is_aggregate(arg) do return true
		}
	case Binary_Expr:
		return expr_is_aggregate(e.left) || expr_is_aggregate(e.right)
	case Unary_Expr:
		return expr_is_aggregate(e.operand)
	case Is_Null_Expr:
		return expr_is_aggregate(e.operand)
	case Between_Expr:
		return expr_is_aggregate(e.operand) || expr_is_aggregate(e.low) || expr_is_aggregate(e.high)
	case In_Expr:
		if expr_is_aggregate(e.operand) do return true
		for item in e.items {
			if expr_is_aggregate(item) do return true
		}
	case Match_Expr:
		return false
	case Like_Expr:
		return expr_is_aggregate(e.operand) || expr_is_aggregate(e.pattern)
	case Cast_Expr:
		return expr_is_aggregate(e.operand)
	case Collate_Expr:
		return expr_is_aggregate(e.operand)
	case Subquery_Expr:
		return false
	case Literal_Expr, Column_Expr, Star_Expr, Param_Expr:
	}
	return false
}

// sq_literal renders a value as SQLite's quote() does.
@(private)
sq_literal :: proc(value: Value) -> string {
	#partial switch value.kind {
	case .Null:
		return "NULL"
	case .Int:
		return fmt.aprintf("%d", value.i)
	case .Uint:
		return fmt.aprintf("%d", value.u)
	case .Float:
		return fmt.aprintf("%.15g", value.f)
	case .Bool:
		return value.b ? "1" : "0"
	case .Bytes:
		builder := strings.builder_make()
		strings.write_string(&builder, "X'")
		for byte in value.bytes do strings.write_string(&builder, fmt.aprintf("%02X", byte, allocator = context.temp_allocator))
		strings.write_byte(&builder, '\'')
		return strings.to_string(builder)
	case .String:
		escaped, _ := strings.replace_all(value.s, "'", "''", context.temp_allocator)
		return fmt.aprintf("'%s'", escaped)
	}
	return value_format(value, context.allocator)
}

@(private)
sq_hex :: proc(value: Value) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	#partial switch value.kind {
	case .Bytes:
		for byte in value.bytes do fmt.sbprintf(&builder, "%02X", byte)
	case .String:
		for byte in value.s do fmt.sbprintf(&builder, "%02X", byte)
	}
	return strings.clone(strings.to_string(builder))
}

// sq_format implements the printf subset SQLite's format() exposes.
@(private)
sq_format :: proc(pattern: string, args: []Value) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	next := 0
	for i := 0; i < len(pattern); i += 1 {
		if pattern[i] != '%' || i + 1 >= len(pattern) {
			strings.write_byte(&builder, pattern[i])
			continue
		}
		i += 1
		switch pattern[i] {
		case '%':
			strings.write_byte(&builder, '%')
		case 'd', 'i':
			if next < len(args) {
				strings.write_string(&builder, fmt.aprintf("%d", sq_int(args[next]), allocator = context.temp_allocator))
				next += 1
			}
		case 's':
			if next < len(args) {
				strings.write_string(&builder, value_format(args[next], context.temp_allocator))
				next += 1
			}
		case 'f':
			if next < len(args) {
				strings.write_string(&builder, fmt.aprintf("%f", sq_float(args[next]), allocator = context.temp_allocator))
				next += 1
			}
		case 'q':
			if next < len(args) {
				strings.write_string(&builder, sq_literal(args[next]))
				next += 1
			}
		case:
			strings.write_byte(&builder, pattern[i])
		}
	}
	return strings.clone(strings.to_string(builder))
}

@(private)
sq_int :: proc(value: Value) -> i64 {
	#partial switch value.kind {
	case .Int:
		return value.i
	case .Uint:
		return i64(value.u)
	case .Float:
		return i64(value.f)
	case .Bool:
		return value.b ? 1 : 0
	}
	return 0
}

@(private)
sq_float :: proc(value: Value) -> f64 {
	#partial switch value.kind {
	case .Float:
		return value.f
	case .Int:
		return f64(value.i)
	case .Uint:
		return f64(value.u)
	}
	return 0
}

@(private)
sq_truthy :: proc(value: Value) -> (bool, Error) {
	#partial switch value.kind {
	case .Null:
		return false, ERROR_NONE
	case .Bool:
		return value.b, ERROR_NONE
	case .Int:
		return value.i != 0, ERROR_NONE
	case .Uint:
		return value.u != 0, ERROR_NONE
	case .Float:
		return value.f != 0, ERROR_NONE
	case .String:
		return len(value.s) > 0, ERROR_NONE
	}
	return true, ERROR_NONE
}

@(private)
is_aggregate_name :: proc(name: string) -> bool {
	for candidate in ([]string{"count", "sum", "avg", "min", "max", "total", "group_concat", "string_agg"}) {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}

@(private)
eval_call :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {

	if is_aggregate_name(call.name) {
		return eval_aggregate(ctx, call)
	}
	args := make([dynamic]Value, 0, len(call.args))
	defer delete(args)
	for arg in call.args {
		value, arg_err := eval_expr(ctx, arg)
		if arg_err.kind != .None do return {}, arg_err
		append(&args, value)
	}

	// JSON functions parse the document in json.odin.
	if json_call_name(call.name) {
		value, handled, json_err := json_call(call.name, args[:])
		if !handled do return {}, errf(.Internal, "unhandled JSON function %s", call.name)
		return value, json_err
	}
	// Date and time functions share the argument parsing in datetime.odin.
	if db_time_has_functions(call.name) {
		if strings.equal_fold(call.name, "strftime") {
			if len(args) < 2 {
				return {}, errf(.Invalid_Argument, "strftime() takes a format and a time")
			}
			if args[0].kind != .String {
				return {}, errf(.Invalid_Type, "strftime() expects a text format")
			}
			moment, ok := db_time_parse(args[1:])
			if !ok do return value_null(), ERROR_NONE
			return value_string(db_time_strftime(args[0].s, moment)), ERROR_NONE
		}
		value, _ := db_time_call(call.name, args[:])
		return value, ERROR_NONE
	}
	switch strings.to_lower(call.name) {
	case "snippet", "highlight":
		if len(args) != 2 {
			return {}, errf(.Invalid_Argument, "%s() takes text and a pattern", call.name)
		}
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "%s() expects text for both arguments", call.name)
		}
		window := strings.equal_fold(call.name, "snippet")
		return value_string(fts_mark(args[0].s, args[1].s, window)), ERROR_NONE
	case "lower":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "lower() takes one argument")
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "lower() expects text")
		return value_string(strings.to_lower(args[0].s)), ERROR_NONE
	case "upper":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "upper() takes one argument")
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "upper() expects text")
		return value_string(strings.to_upper(args[0].s)), ERROR_NONE
	case "length", "char_length":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "length() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .String do return value_int(i64(len(args[0].s))), ERROR_NONE
		if args[0].kind == .Bytes do return value_int(i64(len(args[0].bytes))), ERROR_NONE
		return {}, errf(.Invalid_Type, "length() expects text or bytes")
	case "abs":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "abs() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .Float {
			return value_float(abs_f64(args[0].f)), ERROR_NONE
		}
		number, ok := value_to_i64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "abs() expects a number")
		return value_int(number < 0 ? -number : number), ERROR_NONE
	case "substr", "substring":
		if len(args) < 2 || len(args) > 3 {
			return {}, errf(.Invalid_Argument, "substr() takes two or three arguments")
		}
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "substr() expects text")
		text := args[0].s
		start_value, ok := value_to_i64(args[1])
		if !ok do return {}, errf(.Invalid_Type, "substr() expects an integer start")
		begin := int(start_value - 1)
		if begin < 0 do begin = 0
		if begin > len(text) do begin = len(text)
		end := len(text)
		if len(args) == 3 {
			count, count_ok := value_to_i64(args[2])
			if !count_ok do return {}, errf(.Invalid_Type, "substr() expects an integer length")
			if count < 0 do count = 0
			if begin + int(count) < end do end = begin + int(count)
		}
		return value_string(text[begin:end]), ERROR_NONE
	case "trim", "ltrim", "rtrim":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "%s() expects text", call.name)
		switch strings.to_lower(call.name) {
		case "ltrim":
			return value_string(strings.trim_left_space(args[0].s)), ERROR_NONE
		case "rtrim":
			return value_string(strings.trim_right_space(args[0].s)), ERROR_NONE
		}
		return value_string(strings.trim_space(args[0].s)), ERROR_NONE
	case "replace":
		if len(args) != 3 do return {}, errf(.Invalid_Argument, "replace() takes three arguments")
		for arg in args {
			if arg.kind != .String do return {}, errf(.Invalid_Type, "replace() expects text")
		}
		replaced, _ := strings.replace_all(args[0].s, args[1].s, args[2].s)
		return value_string(replaced), ERROR_NONE
	case "concat":
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		for arg in args {
			if arg.kind == .Null do continue
			strings.write_string(&builder, value_format(arg, context.temp_allocator))
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "sign":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sign() takes one argument")
		if number, ok := value_to_f64(args[0]); ok {
			if number > 0 do return value_int(1), ERROR_NONE
			if number < 0 do return value_int(-1), ERROR_NONE
			return value_int(0), ERROR_NONE
		}
		return {}, errf(.Invalid_Type, "sign() expects a number")
	case "round":
		if len(args) < 1 || len(args) > 2 do return {}, errf(.Invalid_Argument, "round() takes one or two arguments")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "round() expects a number")
		digits := i64(0)
		if len(args) == 2 {
			parsed, digits_ok := value_to_i64(args[1])
			if !digits_ok do return {}, errf(.Invalid_Type, "round() expects an integer digit count")
			digits = parsed
		}
		scale := math.pow(10, f64(digits))
		return value_float(math.round(number * scale) / scale), ERROR_NONE
	case "floor", "ceil":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects a number", call.name)
		if strings.equal_fold(call.name, "floor") do return value_float(math.floor(number)), ERROR_NONE
		return value_float(math.ceil(number)), ERROR_NONE
	case "sqrt":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sqrt() takes one argument")
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "sqrt() expects a number")
		if number < 0 do return {}, errf(.Invalid_Argument, "sqrt() needs a non-negative number")
		return value_float(math.sqrt(number)), ERROR_NONE
	case "pow":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "pow() takes two arguments")
		base, base_ok := value_to_f64(args[0])
		exponent, exponent_ok := value_to_f64(args[1])
		if !base_ok || !exponent_ok do return {}, errf(.Invalid_Type, "pow() expects numbers")
		return value_float(math.pow(base, exponent)), ERROR_NONE
	case "mod":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "mod() takes two arguments")
		left, left_ok := value_to_i64(args[0])
		right, right_ok := value_to_i64(args[1])
		if !left_ok || !right_ok do return {}, errf(.Invalid_Type, "mod() expects integers")
		if right == 0 do return {}, errf(.Invalid_Argument, "mod() by zero")
		return value_int(left % right), ERROR_NONE
	case "nullif":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "nullif() takes two arguments")
		if value_equal(args[0], args[1]) do return value_null(), ERROR_NONE
		return args[0], ERROR_NONE
	case "coalesce", "ifnull":
		for value in args {
			if value.kind != .Null do return value, ERROR_NONE
		}
		return value_null(), ERROR_NONE
	case "now", "current_timestamp":
		if len(args) != 0 {
			return {}, errf(.Invalid_Argument, "now() takes no arguments")
		}
		return value_timestamp(Timestamp(ctx.now_us)), ERROR_NONE
	case "has_role":
		if len(args) != 1 {
			return {}, errf(.Invalid_Argument, "has_role() takes one argument")
		}
		if args[0].kind != .String {
			return {}, errf(.Invalid_Type, "has_role() expects a role name")
		}
		if ctx.tx == nil do return value_bool(false), ERROR_NONE
		holds, role_err := has_role(ctx.tx, args[0].s)
		if role_err.kind != .None do return {}, role_err
		return value_bool(holds), ERROR_NONE
	case "current_identity", "sender":
		if len(args) != 0 {
			return {}, errf(.Invalid_Argument, "current_identity() takes no arguments")
		}
		if ctx.tx == nil do return value_identity(Identity{}), ERROR_NONE
		return value_identity(ctx.tx.store.identity), ERROR_NONE
	case "uuid":
		return {}, errf(.Sql_Unsupported, "uuid() needs a randomness source the engine does not have")
	case "typeof":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "typeof() takes one argument")
		#partial switch args[0].kind {
		case .Null:
			return value_string("null"), ERROR_NONE
		case .Int, .Uint, .Bool, .Int128, .Uint128:
			return value_string("integer"), ERROR_NONE
		case .Float:
			return value_string("real"), ERROR_NONE
		case .Bytes:
			return value_string("blob"), ERROR_NONE
		}
		return value_string("text"), ERROR_NONE
	case "quote":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "quote() takes one argument")
		return value_string(sq_literal(args[0])), ERROR_NONE
	case "hex":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "hex() takes one argument")
		return value_string(sq_hex(args[0])), ERROR_NONE
	case "iif":
		if len(args) != 3 do return {}, errf(.Invalid_Argument, "iif() takes three arguments")
		truth, truth_err := sq_truthy(args[0])
		if truth_err.kind != .None do return {}, truth_err
		return args[1] if truth else args[2], ERROR_NONE
	case "sqlite_version":
		return value_string("3.54.1"), ERROR_NONE
	case "instr":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "instr() takes two arguments")
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "instr() expects text")
		}
		at := strings.index(args[0].s, args[1].s)
		return value_int(at < 0 ? 0 : i64(at) + 1), ERROR_NONE
	case "char":
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		for arg in args {
			if arg.kind != .Int do return {}, errf(.Invalid_Type, "char() expects integers")
			strings.write_rune(&builder, rune(arg.i))
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "changes":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "changes() takes no arguments")
		return value_int(ctx.tx.store.last_changes), ERROR_NONE
	case "last_insert_rowid":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "last_insert_rowid() takes no arguments")
		return value_int(ctx.tx.store.last_row_id), ERROR_NONE
	case "total_changes":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "total_changes() takes no arguments")
		return value_int(ctx.tx.store.total_changes), ERROR_NONE
	case "log", "log10", "log2", "exp", "sin", "cos", "tan", "asin", "acos", "atan", "degrees", "radians", "trunc":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects a number", call.name)
		switch strings.to_lower(call.name) {
		case "log", "log10":
			if number <= 0 do return value_null(), ERROR_NONE
			return value_float(math.log10(number)), ERROR_NONE
		case "log2":
			if number <= 0 do return value_null(), ERROR_NONE
			return value_float(math.log2(number)), ERROR_NONE
		case "exp":
			return value_float(math.exp(number)), ERROR_NONE
		case "sin":
			return value_float(math.sin(number)), ERROR_NONE
		case "cos":
			return value_float(math.cos(number)), ERROR_NONE
		case "tan":
			return value_float(math.tan(number)), ERROR_NONE
		case "asin":
			return value_float(math.asin(number)), ERROR_NONE
		case "acos":
			return value_float(math.acos(number)), ERROR_NONE
		case "atan":
			return value_float(math.atan(number)), ERROR_NONE
		case "degrees":
			return value_float(number * 180 / math.PI), ERROR_NONE
		case "radians":
			return value_float(number * math.PI / 180), ERROR_NONE
		case "trunc":
			return value_float(math.trunc(number)), ERROR_NONE
		case:
		}
		return {}, errf(.Internal, "unknown math function %s", call.name)
	case "atan2":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "atan2() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		y, y_ok := value_to_f64(args[0])
		x, x_ok := value_to_f64(args[1])
		if !y_ok || !x_ok do return {}, errf(.Invalid_Type, "atan2() expects numbers")
		return value_float(math.atan2(y, x)), ERROR_NONE
	case "pi":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "pi() takes no arguments")
		return value_float(math.PI), ERROR_NONE
	case "octet_length":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "octet_length() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .String do return value_int(i64(len(args[0].s))), ERROR_NONE
		if args[0].kind == .Bytes do return value_int(i64(len(args[0].bytes))), ERROR_NONE
		text := value_format(args[0], context.allocator)
		defer delete(text)
		return value_int(i64(len(text))), ERROR_NONE
	case "unicode":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unicode() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		text := args[0].kind == .String ? strings.clone(args[0].s) : value_format(args[0], context.allocator)
		defer delete(text)
		if len(text) == 0 do return value_null(), ERROR_NONE
		char, _ := utf8.decode_rune_in_string(text)
		return value_int(i64(char)), ERROR_NONE
	case "unhex":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unhex() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		text := args[0].kind == .String ? args[0].s : value_format(args[0], context.allocator)
		cloned := args[0].kind != .String
		defer if cloned do delete(text)
		if len(text) % 2 != 0 do return value_null(), ERROR_NONE
		out := make([]u8, len(text) / 2, context.allocator)
		for i in 0 ..< len(out) {
			high, high_ok := sql_hex_digit(text[i * 2])
			low, low_ok := sql_hex_digit(text[i * 2 + 1])
			if !high_ok || !low_ok do return value_null(), ERROR_NONE
			out[i] = u8(high << 4 | low)
		}
		return value_bytes(out), ERROR_NONE
	case "zeroblob", "randomblob":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		size, ok := value_to_i64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects an integer", call.name)
		if size < 0 do return value_null(), ERROR_NONE
		if size > 1 << 20 do size = 1 << 20
		buffer := make([]u8, int(size), context.allocator)
		if strings.equal_fold(call.name, "randomblob") {
			for i in 0 ..< len(buffer) do buffer[i] = u8(rng_next())
		}
		return value_bytes(buffer), ERROR_NONE
	case "random":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "random() takes no arguments")
		return value_int(i64(rng_next())), ERROR_NONE
	case "concat_ws":
		if len(args) < 2 do return {}, errf(.Invalid_Argument, "concat_ws() takes a separator and values")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		separator := value_format(args[0], context.allocator)
		defer delete(separator)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		first := true
		for arg in args[1:] {
			if arg.kind == .Null do continue
			if !first do strings.write_string(&builder, separator)
			piece := value_format(arg, context.allocator)
			strings.write_string(&builder, piece)
			delete(piece)
			first = false
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "like":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "like() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "like() expects text")
		}
		return value_bool(like_match(args[1].s, args[0].s, true, 0)), ERROR_NONE
	case "glob":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "glob() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "glob() expects text")
		}
		return value_bool(glob_match(args[1].s, args[0].s)), ERROR_NONE
	case "format", "printf":
		if len(args) == 0 do return {}, errf(.Invalid_Argument, "format() needs a pattern")
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "format() expects a text pattern")
		return value_string(sq_format(args[0].s, args[1:])), ERROR_NONE
	}
	return {}, errf(.Sql_Unsupported, "unknown function %s", call.name)
}

@(private)
abs_f64 :: proc(f: f64) -> f64 {
	return f < 0 ? -f : f
}

@(private)
eval_aggregate :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	if ctx.stream != nil {
		acc := agg_stream_lookup(ctx.stream, call)
		if acc == nil {
			return {}, errf(.Internal, "aggregate %s was not accumulated by the scan", call.name)
		}
		return agg_stream_value(acc)
	}
	name := strings.to_lower(call.name)
	rows := ctx.group
	single_rows: [1][]Source
	if !ctx.grouped {
		single_rows[0] = ctx.sources
		rows = single_rows[:]
	}

	if name == "count" {
		if call.star || len(call.args) == 0 {
			return value_int(i64(len(rows))), ERROR_NONE
		}
		count := 0
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, eval_err := eval_expr(&sub, call.args[0])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind != .Null do count += 1
		}
		return value_int(i64(count)), ERROR_NONE
	}

	if name == "group_concat" || name == "string_agg" {
		if call.star || len(call.args) < 1 || len(call.args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes one or two arguments", name)
		}
		separator := ","
		separator_text: string
		if len(call.args) == 2 {
			value, eval_err := eval_expr(ctx, call.args[1])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind != .Null {
				separator_text = value_format(value, context.allocator)
				separator = separator_text
			}
		}
		defer if len(separator_text) > 0 do delete(separator_text)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		seen_any := false
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, eval_err := eval_expr(&sub, call.args[0])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind == .Null do continue
			if seen_any do strings.write_string(&builder, separator)
			piece := value_format(value, context.allocator)
			strings.write_string(&builder, piece)
			delete(piece)
			seen_any = true
		}
		if !seen_any do return value_null(), ERROR_NONE
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	}

	accumulator: Value = value_null()
	seen := 0
	sum_float := f64(0)
	sum_int := i64(0)
	sum_128 := i128(0)
	uses_float := false
	uses_128 := false
	for sources in rows {
		sub := ctx^
		sub.sources = sources
		if len(call.args) != 1 {
			return {}, errf(.Invalid_Argument, "%s() takes exactly one argument", name)
		}
		value, eval_err := eval_expr(&sub, call.args[0])
		if eval_err.kind != .None do return {}, eval_err
		if value.kind == .Null do continue
		seen += 1
		switch name {
		case "min":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "min() mixes incompatible types")
				if order == .Less do accumulator = value
			}
		case "max":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "max() mixes incompatible types")
				if order == .Greater do accumulator = value
			}
		case "sum", "total", "avg":
			if !value_is_numeric(value) {
				return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			}
			if value.kind == .Float {
				uses_float = true
				number, _ := value_to_f64(value)
				sum_float += number
			} else if value.kind == .Int128 || value.kind == .Uint128 {
				if !uses_128 {
					uses_128 = true
					sum_128 = i128(sum_int)
				}
				sum_128 += value_as_i128(value)
			} else if uses_float {
				number, _ := value_to_f64(value)
				sum_float += number
			} else if uses_128 {
				number, _ := value_to_i64(value)
				sum_128 += i128(number)
			} else {
				number, _ := value_to_i64(value)
				sum_int += number
			}
		}
	}
	switch name {
	case "min", "max":
		return value_clone(accumulator, context.allocator), ERROR_NONE
	case "sum", "total":
		if seen == 0 do return value_null(), ERROR_NONE
		if uses_float do return value_float(sum_float), ERROR_NONE
		if uses_128 do return value_int128(sum_128), ERROR_NONE
		return value_int(sum_int), ERROR_NONE
	case "avg":
		if seen == 0 do return value_null(), ERROR_NONE
		total := uses_float ? sum_float : (uses_128 ? f64(sum_128) : f64(sum_int))
		return value_float(total / f64(seen)), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown aggregate %s", name)
}

// glob_match implements SQLite's GLOB: case sensitive, * matches any run, ?
// matches one character and [...] is a character class (^ negates it).
glob_match :: proc(text, pattern: string) -> bool {
	return glob_here(text, pattern)
}

@(private)
glob_here :: proc(text_in, pattern_in: string) -> bool {
	text := text_in
	pattern := pattern_in
	for len(pattern) > 0 {
		switch pattern[0] {
		case '*':
			for len(pattern) > 0 && pattern[0] == '*' {
				pattern = pattern[1:]
			}
			if len(pattern) == 0 do return true
			for i in 0 ..= len(text) {
				if glob_here(text[i:], pattern) do return true
			}
			return false
		case '?':
			if len(text) == 0 do return false
			text = text[1:]
			pattern = pattern[1:]
		case '[':
			if len(text) == 0 do return false
			closing := strings.index_byte(pattern, ']')
			if closing < 0 {
				if text[0] != '[' do return false
				text = text[1:]
				pattern = pattern[1:]
				continue
			}
			body := pattern[1:closing]
			negate := len(body) > 0 && body[0] == '^'
			if negate do body = body[1:]
			member := false
			i := 0
			for i < len(body) {
				if i + 2 < len(body) && body[i + 1] == '-' {
					if text[0] >= body[i] && text[0] <= body[i + 2] do member = true
					i += 3
				} else {
					if text[0] == body[i] do member = true
					i += 1
				}
			}
			if member == negate do return false
			text = text[1:]
			pattern = pattern[closing + 1:]
		case:
			if len(text) == 0 || text[0] != pattern[0] do return false
			text = text[1:]
			pattern = pattern[1:]
		}
	}
	return len(text) == 0
}

// like_match implements SQL LIKE with % and _, an optional escape character,
// and case folding. The pattern is tokenized first so an escaped wildcard is a
// literal even when the matcher backtracks.
like_match :: proc(text, pattern: string, case_insensitive: bool, escape: u8 = 0) -> bool {
	t := text
	p := pattern
	if case_insensitive {
		t = strings.to_lower(text)
		p = strings.to_lower(pattern)
	}
	Like_Token_Kind :: enum u8 {
		Literal,
		Any,
		Star,
	}
	Like_Token :: struct {
		kind: Like_Token_Kind,
		ch:   u8,
	}
	tokens := make([dynamic]Like_Token, 0, len(p))
	defer delete(tokens)
	for i := 0; i < len(p); i += 1 {
		ch := p[i]
		if escape != 0 && ch == escape && i + 1 < len(p) {
			i += 1
			append(&tokens, Like_Token{kind = .Literal, ch = p[i]})
			continue
		}
		switch ch {
		case '%':
			append(&tokens, Like_Token{kind = .Star})
		case '_':
			append(&tokens, Like_Token{kind = .Any})
		case:
			append(&tokens, Like_Token{kind = .Literal, ch = ch})
		}
	}
	ti := 0
	pi := 0
	star := -1
	match := 0
	for ti < len(t) {
		if pi < len(tokens) {
			token := tokens[pi]
			if token.kind == .Any || (token.kind == .Literal && token.ch == t[ti]) {
				ti += 1
				pi += 1
				continue
			}
			if token.kind == .Star {
				star = pi
				match = ti
				pi += 1
				continue
			}
		}
		if star != -1 {
			pi = star + 1
			match += 1
			ti = match
			continue
		}
		return false
	}
	for pi < len(tokens) && tokens[pi].kind == .Star do pi += 1
	return pi == len(tokens)
}

// --- INSERT / UPDATE / DELETE ----------------------------------------------

// find_conflict_row locates the row an UPSERT collided with: the primary key
// columns compared against the incoming values.
@(private)
find_conflict_row :: proc(tx: ^Tx, table: ^Table, values: []Value) -> (Row, bool) {
	if len(table.schema.primary_key) == 0 do return {}, false
	// A paged table has no row map, so both backends answer through a collect.
	// The values live in the transaction arena and stay valid for the statement.
	rows := make([dynamic]Row)
	defer delete(rows)
	table_collect(table, &rows, max(u64), tx.alloc)
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


@(private)
returning_append :: proc(
	result: ^Sql_Result,
	rows: ^[dynamic][]Value,
	returning: ^Returning,
	table: ^Table,
	row: Row,
) -> Error {
	if returning == nil do return ERROR_NONE
	if result.kind != .Rows {
		result.kind = .Rows
		if returning.star {
			result.columns = make([]string, len(table.schema.columns))
			for column, i in table.schema.columns {
				result.columns[i] = strings.clone(column.name)
			}
		} else {
			result.columns = make([]string, len(returning.columns))
			for name, i in returning.columns {
				if _, found := schema_column_index(&table.schema, name); !found {
					return errf(.Column_Not_Found, "column %s does not exist in %s", name, table.schema.name)
				}
				result.columns[i] = strings.clone(name)
			}
		}
	}
	values := make([]Value, len(result.columns))
	if returning.star {
		for value, i in row.values {
			if i >= len(values) do break
			values[i] = value_clone(value, context.allocator)
		}
	} else {
		for name, i in returning.columns {
			index, _ := schema_column_index(&table.schema, name)
			values[i] = value_clone(row.values[index], context.allocator)
		}
	}
	append(rows, values)
	return ERROR_NONE
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
	if stmt.has_select {
		// The VALUES path is reused: each row the query produces becomes a row
		// of literals, so coercion, policies, UPSERT and RETURNING are shared.
		query, query_err := sql_exec_select(tx, stmt.select_stmt, params)
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
		for expr, i in values_expr {
			value, eval_err := eval_expr(&ctx, expr)
			if eval_err.kind != .None do return {}, eval_err
			values[positions[i]] = value
		}
		// Generated columns are computed from the row about to be stored, so a
		// caller never supplies them and CHECK sees the final values.
		if apply_err := generated_plan_apply(&ctx, &generated, table, values); apply_err.kind != .None {
			return {}, apply_err
		}
		// The stored row is already coerced, so the CHECK predicate sees the
		// values the table would hold.
		row_id, insert_err := tx_insert(tx, stmt.table, values)
		if insert_err.kind == .None {
			if fts_err := fts_index_if_virtual(tx, stmt.table, row_id, values, true); fts_err.kind != .None {
				return {}, fts_err
			}
		}
		if insert_err.kind != .None {
			// UPSERT: a collision on the target columns is not an error.
			conflict, found := find_conflict_row(tx, table, values)
			if !found do return {}, insert_err
			if stmt.conflict_do_nothing {
				continue
			}
			if len(stmt.conflict_assignments) == 0 do return {}, insert_err
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
				coerced, coerce_err := value_coerce(value, table.schema.columns[index].type)
				if coerce_err.kind != .None do return {}, coerce_err
				new_values[index] = coerced
			}
			if update_err := tx_update(tx, stmt.table, conflict.id, new_values); update_err.kind != .None {
				return {}, update_err
			}
			if fts_err := fts_index_if_virtual(tx, stmt.table, conflict.id, new_values, false); fts_err.kind != .None {
				return {}, fts_err
			}
			if returning := stmt.returning; returning != nil {
				if returning_err := returning_append(&result, &returned, returning, table, Row{values = new_values}); returning_err.kind != .None {
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
				if returning_err := returning_append(&result, &returned, returning, table, staged); returning_err.kind != .None {
					return {}, returning_err
				}
			}
		}
		result.affected += 1
	}
	if stmt.returning != nil do result.rows = returned[:]
	tx.store.last_changes = i64(result.affected)
	tx.store.total_changes += i64(result.affected)
	return result, ERROR_NONE
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
	ctx := Eval_Ctx{tx = tx, params = params, now_us = now_microseconds()}
	policies, policy_err := policy_load(tx, stmt.table)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	affected := 0
	returned := make([dynamic][]Value, 0, len(rows))
	result := Sql_Result{kind = .Affected}
	for row in rows {
		if tx.store.cancelled {
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
			coerced, coerce_err := value_coerce(value, table.schema.columns[index].type)
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
		if update_err := tx_update(tx, stmt.table, row.id, new_values); update_err.kind != .None {
			return {}, update_err
		}
		if fts_err := fts_index_if_virtual(tx, stmt.table, row.id, new_values, false); fts_err.kind != .None {
			return {}, fts_err
		}
		if returning_err := returning_append(&result, &returned, stmt.returning, table, Row{values = new_values}); returning_err.kind != .None {
			return {}, returning_err
		}
		affected += 1
	}
	result.affected = affected
	tx.store.last_changes = i64(affected)
	tx.store.total_changes += i64(affected)
	if stmt.returning != nil {
		result.kind = .Rows
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
	ctx := Eval_Ctx{tx = tx, params = params, now_us = now_microseconds()}
	policies, policy_err := policy_load(tx, stmt.table)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	affected := 0
	returned := make([dynamic][]Value, 0, len(rows))
	result := Sql_Result{kind = .Affected}
	for row in rows {
		if tx.store.cancelled {
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
		if returning_err := returning_append(&result, &returned, stmt.returning, table, row); returning_err.kind != .None {
			return {}, returning_err
		}
		if fts_err := fts_delete_if_virtual(tx, stmt.table, row.id); fts_err.kind != .None {
			return {}, fts_err
		}
		if delete_err := tx_delete(tx, stmt.table, row.id); delete_err.kind != .None {
			return {}, delete_err
		}
		affected += 1
	}
	result.affected = affected
	tx.store.last_changes = i64(affected)
	tx.store.total_changes += i64(affected)
	if stmt.returning != nil {
		result.kind = .Rows
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
		slice.sort_by(out[:], proc(a, b: Row) -> bool {
			return u64(a.id) < u64(b.id)
		})
		return ERROR_NONE
	}
	return tx_collect(tx, table_name, out)
}

// --- DDL -------------------------------------------------------------------

TYPE_TABLE :: "_type"
TYPE_SCHEMA_SQL :: "CREATE TABLE IF NOT EXISTS _type (name TEXT PRIMARY KEY, base TEXT NOT NULL)"

@(private)
types_ensure_table :: proc(tx: ^Tx) -> Error {
	if _, table_err := tx_table(tx, TYPE_TABLE); table_err.kind == .None do return ERROR_NONE
	result, create_err := sql_execute_in_tx(tx, TYPE_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// resolve_named_type looks a named type up in the catalog and returns its base.
@(private)
resolve_named_type :: proc(tx: ^Tx, name: string) -> (Column_Type, Error) {
	if _, table_err := tx_table(tx, TYPE_TABLE); table_err.kind != .None {
		return {}, errf(.Invalid_Type, "type %s is not defined", name)
	}
	result, query_err := sql_execute_in_tx_params(
		tx,
		"SELECT base FROM _type WHERE name = ?",
		[]Value{value_string(name)},
	)
	if query_err.kind != .None do return {}, query_err
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return {}, errf(.Invalid_Type, "type %s is not defined", name)
	base, base_ok := type_parse_text(result.rows[0][0].s)
	if !base_ok do return {}, errf(.Invalid_Type, "type %s has an invalid base", name)
	return base, ERROR_NONE
}

sql_exec_create_type :: proc(tx: ^Tx, stmt: Create_Type_Stmt) -> (Sql_Result, Error) {
	if err := types_ensure_table(tx); err.kind != .None do return {}, err
	existing, query_err := sql_execute_in_tx_params(
		tx,
		"SELECT 1 FROM _type WHERE name = ?",
		[]Value{value_string(stmt.name)},
	)
	if query_err.kind != .None do return {}, query_err
	found := len(existing.rows) > 0
	sql_result_destroy(&existing)
	if found {
		if stmt.if_not_exists do return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
		return {}, errf(.Table_Exists, "type %s already exists", stmt.name)
	}
	base_text := column_type_name(stmt.base)
	_, insert_err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _type (name, base) VALUES (?, ?)",
		[]Value{value_string(stmt.name), value_string(base_text)},
	)
	if insert_err.kind != .None do return {}, insert_err
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

sql_exec_alter_table :: proc(tx: ^Tx, stmt: Alter_Table_Stmt) -> (Sql_Result, Error) {
	if len(stmt.drop_column) > 0 {
		if drop_err := tx_drop_column(tx, stmt.table, stmt.drop_column); drop_err.kind != .None {
			return {}, drop_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	if len(stmt.rename_to) > 0 && len(stmt.rename_column) > 0 {
		if rename_err := tx_rename_column(tx, stmt.table, stmt.rename_column, stmt.rename_to); rename_err.kind != .None {
			return {}, rename_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	if len(stmt.rename_to) > 0 {
		if rename_err := tx_rename_table(tx, stmt.table, stmt.rename_to); rename_err.kind != .None {
			return {}, rename_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	for existing in table.schema.columns {
		if strings.equal_fold(existing.name, stmt.column.name) {
			return {}, errf(
				.Invalid_Argument,
				"column %s already exists in %s",
				stmt.column.name,
				stmt.table,
			)
		}
	}
	columns := make([]Column, len(table.schema.columns) + 1, tx.alloc)
	copy(columns, table.schema.columns)
	columns[len(columns) - 1] = stmt.column
	next_schema := table.schema
	next_schema.columns = columns
	if validate_err := schema_validate(&next_schema); validate_err.kind != .None {
		return {}, validate_err
	}
	if alter_err := tx_alter_table(tx, stmt.table, next_schema); alter_err.kind != .None {
		return {}, alter_err
	}
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

sql_exec_create_table :: proc(tx: ^Tx, stmt: Create_Table_Stmt, params: []Value) -> (Sql_Result, Error) {
	schema := Table_Schema{}
	schema.name = strings.clone(stmt.name, tx.alloc)
	schema.auto_increment_column = NO_COLUMN
	schema.ephemeral = stmt.ephemeral
	schema.event = stmt.event
	columns := make([]Column, len(stmt.columns), tx.alloc)
	inline_primary := NO_COLUMN
	for definition, i in stmt.columns {
		column_type := definition.type
		if len(definition.type_name) > 0 {
			resolved, resolve_err := resolve_named_type(tx, definition.type_name)
			if resolve_err.kind != .None do return {}, resolve_err
			column_type = resolved
		}
		collation := ""
		if len(definition.collation) > 0 {
			if !collation_known(definition.collation) {
				return {}, errf(
					.Sql_Unsupported,
					"unknown collation %s on column %s",
					definition.collation,
					definition.name,
				)
			}
			collation = strings.clone(definition.collation, tx.alloc)
		}
		if definition.generated && definition.default != nil {
			return {}, errf(.Invalid_Argument, "generated column %s cannot have a DEFAULT", definition.name)
		}
		column := Column {
			name           = strings.clone(definition.name, tx.alloc),
			type           = column_type,
			named_type     = definition.type_name,
			unique         = definition.unique,
			not_null       = definition.not_null || definition.primary,
			auto_increment = definition.autoinc,
			sequence       = definition.sequence,
			collation      = collation,
			generated      = definition.generated,
			generated_sql  = strings.clone(definition.generated_sql, tx.alloc),
		}
		if definition.primary {
			if inline_primary != NO_COLUMN {
				return {}, errf(.Invalid_Argument, "table %s declares more than one primary key", stmt.name)
			}
			inline_primary = i
		}
		if column.auto_increment {
			schema.auto_increment_column = i
		}
		if definition.default != nil {
			value, eval_err := eval_expr(
				&Eval_Ctx{params = params, now_us = now_microseconds()},
				definition.default,
			)
			if eval_err.kind != .None do return {}, eval_err
			coerced, coerce_err := value_coerce(value, column.type)
			if coerce_err.kind != .None do return {}, coerce_err
			column.has_default = true
			column.default_value = value_clone(coerced, tx.alloc)
		}
		columns[i] = column
	}
	schema.columns = columns
	if inline_primary != NO_COLUMN {
		pk := make([]int, 1, tx.alloc)
		pk[0] = inline_primary
		schema.primary_key = pk
	}

	indexes := make([dynamic]Index_Schema, 0, len(stmt.constraints), tx.alloc)
	foreign_keys := make([dynamic]Foreign_Key, 0, len(stmt.constraints), tx.alloc)
	for constraint in stmt.constraints {
		positions := make([]int, len(constraint.columns), tx.alloc)
		for name, i in constraint.columns {
			position, found := schema_column_index(&schema, name)
			if !found {
				return {}, errf(.Column_Not_Found, "column %s does not exist in %s", name, stmt.name)
			}
			positions[i] = position
		}
		if constraint.is_foreign {
			// Resolve the referenced columns against the parent schema, which
			// must already exist and key the columns uniquely.
			parent, parent_err := tx_table(tx, constraint.ref_table)
			if parent_err.kind != .None {
				return {}, errf(
					.Table_Not_Found,
					"foreign key %s references missing table %s",
					stmt.name,
					constraint.ref_table,
				)
			}
			if len(constraint.ref_columns) != len(positions) {
				return {}, errf(
					.Invalid_Argument,
					"foreign key on %s lists %d columns but references %d",
					stmt.name,
					len(positions),
					len(constraint.ref_columns),
				)
			}
			ref_positions := make([]int, len(constraint.ref_columns), tx.alloc)
			for name, i in constraint.ref_columns {
				position, found := schema_column_index(&parent.schema, name)
				if !found {
					return {}, errf(
						.Column_Not_Found,
						"column %s does not exist in %s",
						name,
						constraint.ref_table,
					)
				}
				ref_positions[i] = position
			}
			if !schema_columns_unique(&parent.schema, ref_positions) {
				return {}, errf(
					.Invalid_Argument,
					"foreign key on %s must reference a unique key of %s",
					stmt.name,
					constraint.ref_table,
				)
			}
			name := constraint.name
			if len(name) == 0 {
				name = strings.concatenate({stmt.name, "_fkey"}, tx.alloc)
			} else {
				name = strings.clone(name, tx.alloc)
			}
			append(
				&foreign_keys,
				Foreign_Key {
					name = name,
					columns = positions,
					ref_table = strings.clone(constraint.ref_table, tx.alloc),
					ref_columns = ref_positions,
					on_delete = constraint.on_delete,
					on_update = constraint.on_update,
				},
			)
			continue
		}
		if constraint.primary {
			if len(schema.primary_key) > 0 {
				return {}, errf(.Invalid_Argument, "table %s declares more than one primary key", stmt.name)
			}
			schema.primary_key = positions
			for position in positions {
				schema.columns[position].not_null = true
			}
			continue
		}
		name := constraint.name
		if len(name) == 0 {
			name = strings.concatenate({stmt.name, "_key"}, tx.alloc)
			for position in positions {
				name = strings.concatenate({name, "_", stmt.columns[position].name}, tx.alloc)
			}
		} else {
			name = strings.clone(name, tx.alloc)
		}
		append(
			&indexes,
			Index_Schema{name = name, columns = positions, unique = true, implicit = false},
		)
	}
	if len(indexes) > 0 {
		schema.indexes = make([]Index_Schema, len(indexes), tx.alloc)
		copy(schema.indexes, indexes[:])
	}
	delete(indexes)
	if len(foreign_keys) > 0 {
		schema.foreign_keys = make([]Foreign_Key, len(foreign_keys), tx.alloc)
		copy(schema.foreign_keys, foreign_keys[:])
	}
	delete(foreign_keys)

	if create_err := tx_create_table(tx, &schema); create_err.kind != .None {
		if create_err.kind == .Table_Exists && stmt.if_not_exists {
			// The result outlives the transaction: its arena is gone by the time
			// the caller prints the message.
			return Sql_Result{
				kind = .Ack,
				message = strings.clone("table already exists"),
			}, ERROR_NONE
		}
		return {}, create_err
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}

sql_exec_drop_table :: proc(tx: ^Tx, stmt: Drop_Table_Stmt) -> (Sql_Result, Error) {
	// A virtual table owns a shadow table and a catalog row: dropping it drops all
	// three, so nothing is left behind to be reindexed later.
	if virtual, virtual_err := fts_drop_if_virtual(tx, stmt.name, stmt.if_exists); virtual {
		if virtual_err.kind != .None do return {}, virtual_err
		return Sql_Result{kind = .Ack}, ERROR_NONE
	}
	if drop_err := tx_drop_table(tx, stmt.name); drop_err.kind != .None {
		if drop_err.kind == .Table_Not_Found && stmt.if_exists {
			return Sql_Result{kind = .Ack}, ERROR_NONE
		}
		return {}, drop_err
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}

sql_exec_create_index :: proc(tx: ^Tx, stmt: Create_Index_Stmt) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	columns := make([]int, len(stmt.columns), tx.alloc)
	for name, i in stmt.columns {
		index, found := schema_column_index(&table.schema, name)
		if !found {
			return {}, errf(.Column_Not_Found, "column %s does not exist in %s", name, stmt.table)
		}
		columns[i] = index
		for prior in columns[:i] {
			if prior == index {
				return {}, errf(.Invalid_Argument, "index %s repeats column %s", stmt.name, name)
			}
		}
	}
	for existing in table.schema.indexes {
		if !strings.equal_fold(existing.name, stmt.name) do continue
		if stmt.if_not_exists do return Sql_Result{kind = .Ack}, ERROR_NONE
		return {}, errf(.Index_Exists, "index %s already exists", stmt.name)
	}
	// The schema does not carry an index staged earlier in this transaction.
	for op in tx.state.index_ops {
		if op.drop || !strings.equal_fold(op.table, stmt.table) do continue
		if !strings.equal_fold(op.index.name, stmt.name) do continue
		if stmt.if_not_exists do return Sql_Result{kind = .Ack}, ERROR_NONE
		return {}, errf(.Index_Exists, "index %s already exists", stmt.name)
	}
	if stmt.algorithm == .Direct && (!stmt.unique || len(columns) != 1) {
		return {}, errf(.Invalid_Argument, "a DIRECT index must be unique on one column")
	}
	index := Index_Schema {
		name      = stmt.name,
		columns   = columns,
		unique    = stmt.unique,
		algorithm = stmt.algorithm,
	}
	if add_err := tx_create_index(tx, stmt.table, index); add_err.kind != .None {
		return {}, add_err
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}

sql_exec_drop_index :: proc(tx: ^Tx, stmt: Drop_Index_Stmt) -> (Sql_Result, Error) {
	table_name := stmt.table
	if len(table_name) == 0 {
		for name in tx.store.tables {
			table := tx.store.tables[name]
			for existing in table.schema.indexes {
				if strings.equal_fold(existing.name, stmt.name) {
					table_name = name
					break
				}
			}
			if len(table_name) > 0 do break
		}
	}
	// An index created earlier in this transaction is not in the schema yet, so
	// DROP INDEX without ON has to look at the staged operations too.
	if len(table_name) == 0 {
		for op in tx.state.index_ops {
			if op.drop do continue
			if strings.equal_fold(op.index.name, stmt.name) {
				table_name = op.table
				break
			}
		}
	}
	if len(table_name) == 0 {
		if stmt.if_exists do return Sql_Result{kind = .Ack}, ERROR_NONE
		return {}, errf(.Index_Not_Found, "index %s does not exist", stmt.name)
	}
	if drop_err := tx_drop_index(tx, table_name, stmt.name); drop_err.kind != .None {
		if drop_err.kind == .Index_Not_Found && stmt.if_exists {
			return Sql_Result{kind = .Ack}, ERROR_NONE
		}
		return {}, drop_err
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}

// --- Index-assisted filtering ----------------------------------------------

// index_candidates tries to turn the WHERE clause into a small set of row ids
// using a single-column index. The caller still re-checks the whole predicate,
// so the result only has to be a superset of the matching rows.
@(private)
// fts_scan_candidates narrows a scan to the documents a MATCH selects. Without
// it the predicate would be evaluated on every row of the table; with it the scan
// visits the matches only, which is what makes the cost follow the answer instead
// of the corpus. The pattern has to be a constant (or a parameter), because a
// row-dependent pattern cannot be answered from one lookup.
fts_scan_candidates :: proc(
	tx: ^Tx,
	table_name: string,
	table_alias: string,
	predicate: ^Expr,
	params: []Value,
) -> (ids: [dynamic]Row_Id, used: bool, err: Error) {
	if predicate == nil do return nil, false, ERROR_NONE
	virtual, is_virtual := fts_virtual_lookup(tx, table_name)
	if !is_virtual || !fts_is_full_text(virtual) do return nil, false, ERROR_NONE
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		match, is_match := expr^.(Match_Expr)
		if !is_match do continue
		column, is_column := match.operand^.(Column_Expr)
		if !is_column do continue
		names_table := len(column.table) > 0 ? column.table : column.name
		named := strings.equal_fold(names_table, table_name) ||
			(len(table_alias) > 0 && strings.equal_fold(names_table, table_alias))
		if !named do continue
		pattern, constant := eval_constant(match.pattern, params)
		if !constant || pattern.kind != .String do continue
		result, match_err := fts_match_docs(tx, virtual, pattern.s)
		if match_err.kind != .None do return nil, true, match_err
		for doc in result.docs do append(&ids, doc)
		slice.sort_by(ids[:], proc(a, b: Row_Id) -> bool {
			return a < b
		})
		return ids, true, ERROR_NONE
	}
	return nil, false, ERROR_NONE
}

index_candidates :: proc(
	tx: ^Tx,
	table: ^Table,
	table_name: string,
	table_alias: string,
	predicate: ^Expr,
	params: []Value,
) -> (ids: [dynamic]Row_Id, used: bool) {
	if predicate == nil do return nil, false
	// Staged writes are not in the index yet, so the scan would miss them.
	if _, staged := tx.state.writes[table_name]; staged do return nil, false
	if _, created := tx.state.created[table_name]; created do return nil, false
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		if candidates, ok := candidates_from_conjunct(table, table_alias, expr, params); ok {
			return candidates, true
		}
	}
	return nil, false
}

@(private)
split_and :: proc(expr: ^Expr, out: ^[dynamic]^Expr) {
	if expr == nil do return
	if binary, ok := expr^.(Binary_Expr); ok && binary.op == .And {
		split_and(binary.left, out)
		split_and(binary.right, out)
		return
	}
	append(out, expr)
}

@(private)
candidates_from_conjunct :: proc(
	table: ^Table,
	table_alias: string,
	expr: ^Expr,
	params: []Value,
) -> ([dynamic]Row_Id, bool) {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary do return nil, false
	if binary.op == .Eq || binary.op == .Lt || binary.op == .Le || binary.op == .Gt || binary.op == .Ge {
		qualifier, column_name, value_expr, reversed, ok := comparison_sides(binary)
		if !ok do return nil, false
		// A column of a joined table has its own index (and its own scan); only
		// the base table can use this shortcut.
		if len(qualifier) > 0 &&
		   !strings.equal_fold(qualifier, table.schema.name) &&
		   !(len(table_alias) > 0 && strings.equal_fold(qualifier, table_alias)) {
			return nil, false
		}
		column_index, found := schema_column_index(&table.schema, column_name)
		if !found do return nil, false
		index_position, has_index := index_for_single_column(table, column_index)
		if !has_index do return nil, false
		value, constant := eval_constant(value_expr, params)
		if !constant do return nil, false
		coerced, coerce_err := value_coerce(value, table.schema.columns[column_index].type)
		if coerce_err.kind != .None do return nil, false
		// The index folded the text, so the probe must fold it the same way.
		if len(table.schema.columns[column_index].collation) > 0 {
			coerced = collate_ordered_value(coerced, table.schema.columns[column_index].collation)
		}
		key := value_key_bytes(coerced)
		defer delete(key)
		op := binary.op
		if reversed {
			#partial switch op {
			case .Lt:
				op = .Gt
			case .Le:
				op = .Ge
			case .Gt:
				op = .Lt
			case .Ge:
				op = .Le
			}
		}
		#partial switch op {
		case .Eq:
			return table_index_scan_prefix(table, index_position, string(key)), true
		case .Lt:
			return table_index_scan(table, index_position, "", string(key), false), true
		case .Le:
			return table_index_scan(table, index_position, "", string(key), true), true
		case .Gt, .Ge:
			// Include the boundary; the WHERE re-check drops it when needed.
			return table_index_scan(table, index_position, string(key), "", true), true
		case:
		}
		return nil, false
	}
	between, is_between := expr^.(Between_Expr)
	if is_between && !between.negated {
		column, ok := between.operand^.(Column_Expr)
		if !ok do return nil, false
		if len(column.table) > 0 &&
		   !strings.equal_fold(column.table, table.schema.name) &&
		   !(len(table_alias) > 0 && strings.equal_fold(column.table, table_alias)) {
			return nil, false
		}
		column_index, found := schema_column_index(&table.schema, column.name)
		if !found do return nil, false
		index_position, has_index := index_for_single_column(table, column_index)
		if !has_index do return nil, false
		low, low_ok := eval_constant(between.low, params)
		high, high_ok := eval_constant(between.high, params)
		if !low_ok || !high_ok do return nil, false
		low_value, low_err := value_coerce(low, table.schema.columns[column_index].type)
		high_value, high_err := value_coerce(high, table.schema.columns[column_index].type)
		if low_err.kind != .None || high_err.kind != .None do return nil, false
		low_key := value_key_bytes(low_value)
		defer delete(low_key)
		high_key := value_key_bytes(high_value)
		defer delete(high_key)
		return table_index_scan(table, index_position, string(low_key), string(high_key), true), true
	}
	return nil, false
}

@(private)
comparison_sides :: proc(
	binary: Binary_Expr,
) -> (qualifier: string, column: string, value: ^Expr, reversed: bool, ok: bool) {
	if ref, is_column := binary.left^.(Column_Expr); is_column {
		return ref.table, ref.name, binary.right, false, true
	}
	if ref, is_column := binary.right^.(Column_Expr); is_column {
		return ref.table, ref.name, binary.left, true, true
	}
	return "", "", nil, false, false
}

@(private)
index_for_single_column :: proc(table: ^Table, column: int) -> (int, bool) {
	for index, i in table.indexes {
		if len(index.schema.columns) == 1 && index.schema.columns[0] == column {
			return i, true
		}
	}
	return -1, false
}

// eval_constant evaluates an expression that does not depend on a row.
@(private)
eval_constant :: proc(expr: ^Expr, params: []Value) -> (Value, bool) {
	if expr == nil do return {}, false
	switch e in expr^ {
	case Literal_Expr:
		return e.value, true
	case Param_Expr:
		if e.index >= 0 && e.index < len(params) do return params[e.index], true
	case Collate_Expr:
		return eval_constant(e.operand, params)
	case Window_Expr:
		return {}, false
	case Unary_Expr:
		value, ok := eval_constant(e.operand, params)
		if !ok do return {}, false
		result, eval_err := eval_unary(e.op, value)
		return result, eval_err.kind == .None
	case Cast_Expr:
		value, ok := eval_constant(e.operand, params)
		if !ok do return {}, false
		result, cast_err := value_cast(value, e.target)
		return result, cast_err.kind == .None
	case Match_Expr:
		// MATCH reads the shadow table, so it is never a constant.
		return {}, false
	case Column_Expr, Star_Expr, Binary_Expr, Is_Null_Expr, Between_Expr, In_Expr, Call_Expr, Like_Expr, Subquery_Expr:
	}
	return {}, false
}

@(private)
now_microseconds :: proc() -> i64 {
	return time.now()._nsec / 1000
}

// sql_hex_digit decodes one hexadecimal character.
@(private)
sql_hex_digit :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9': return int(c - '0'), true
	case 'a' ..= 'f': return int(c - 'a') + 10, true
	case 'A' ..= 'F': return int(c - 'A') + 10, true
	}
	return 0, false
}

// rng_state backs random() and randomblob(); it starts from the clock and
// advances with xorshift64, so no global initialisation is required.
rng_state: u64 = 0

@(private)
rng_next :: proc() -> u64 {
	state := rng_state
	if state == 0 do state = u64(now_microseconds()) | 1
	state ~= state << 13
	state ~= state >> 7
	state ~= state << 17
	rng_state = state
	return state
}

// collate_name reports the collation an expression attaches, if any.
@(private)
collate_name :: proc(expr: ^Expr) -> (string, bool) {
	if expr == nil do return "", false
	if collate, ok := expr^.(Collate_Expr); ok do return collate.name, true
	return "", false
}

// value_compare_collated applies an expression-level collation to text keys.
// BINARY (the default) and unknown names fall back to the plain comparison.
@(private)
value_compare_collated :: proc(a, b: Value, collation: string) -> (order: slice.Ordering, ok: bool) {
	if len(collation) > 0 && a.kind == .String && b.kind == .String {
		if strings.equal_fold(collation, "nocase") {
			left := strings.to_lower(a.s, context.temp_allocator)
			right := strings.to_lower(b.s, context.temp_allocator)
			return string_ordering(strings.compare(left, right)), true
		}
		if strings.equal_fold(collation, "rtrim") {
			left := strings.trim_right(a.s, " ")
			right := strings.trim_right(b.s, " ")
			return string_ordering(strings.compare(left, right)), true
		}
	}
	return value_compare(a, b)
}

// --- Generated columns -----------------------------------------------------

// Generated_Plan holds the parsed expressions of a table's generated columns.
// It is built once per statement so a row only evaluates them.
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
			return plan, errf(.Corrupt_Log, "generated column %s: %s", column.name, parse_err.message)
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
		coerced, coerce_err := value_coerce(value, table.schema.columns[target].type)
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

// --- Collations ------------------------------------------------------------

// collation_known reports whether a column may be declared with this collation.
collation_known :: proc(name: string) -> bool {
	return strings.equal_fold(name, "binary") ||
		strings.equal_fold(name, "nocase") ||
		strings.equal_fold(name, "rtrim")
}

// column_collation resolves a column expression to the collation its column
// declares, so a comparison or a sort without an explicit COLLATE still honours
// it. An unqualified name reads the first source that has the column.
column_collation :: proc(ctx: ^Eval_Ctx, expr: ^Expr) -> (string, bool) {
	if expr == nil do return "", false
	operand := expr
	if collate, ok := operand^.(Collate_Expr); ok do operand = collate.operand
	column, ok := operand^.(Column_Expr)
	if !ok do return "", false
	for source in ctx.sources {
		if len(column.table) > 0 {
			matches := strings.equal_fold(column.table, source.table.schema.name) ||
				(len(source.alias) > 0 && strings.equal_fold(column.table, source.alias))
			if !matches do continue
		}
		index, found := schema_column_index(&source.table.schema, column.name)
		if !found do continue
		if len(source.table.schema.columns[index].collation) > 0 {
			return source.table.schema.columns[index].collation, true
		}
		return "", false
	}
	return "", false
}
