package engine

import "core:mem"
import "core:strings"

// Views are stored, not compiled: `CREATE VIEW` writes the body SQL into the
// internal `_view` table, so the commit log, snapshots and replay need no new
// record type. Reading a view runs its SELECT in the same transaction and
// materializes the result into a temporary table, which then behaves like any
// other source.
//
// Limitations: views are read-only, they cannot take parameters, and they
// materialize once per reference (the planner does not push predicates into
// them).

VIEW_TABLE :: "_view"
VIEW_MAX_DEPTH :: 8
VIEW_SCHEMA_SQL :: "CREATE TABLE IF NOT EXISTS _view (name TEXT PRIMARY KEY, sql TEXT NOT NULL)"

sql_exec_create_view :: proc(tx: ^Tx, stmt: Create_View_Stmt) -> (Sql_Result, Error) {
	if len(stmt.sql) == 0 {
		return {}, errf(.Sql_Syntax, "a view needs a SELECT body")
	}
	if err := views_ensure_table(tx); err.kind != .None do return {}, err
	params := []Value{value_string(stmt.name)}
	existing, check_err := sql_execute_in_tx_params(tx, "SELECT 1 FROM _view WHERE name = ?", params)
	if check_err.kind != .None do return {}, check_err
	exists := len(existing.rows) > 0
	sql_result_destroy(&existing)
	if exists {
		if stmt.if_not_exists do return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
		if !stmt.or_replace do return {}, errf(.Table_Exists, "view %s already exists", stmt.name)
		update, update_err := sql_execute_in_tx_params(
			tx,
			"UPDATE _view SET sql = ? WHERE name = ?",
			[]Value{value_string(stmt.sql), value_string(stmt.name)},
		)
		if update_err.kind != .None do return {}, update_err
		sql_result_destroy(&update)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	insert_params := []Value{value_string(stmt.name), value_string(stmt.sql)}
	_, insert_err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _view (name, sql) VALUES (?, ?)",
		insert_params,
	)
	if insert_err.kind != .None do return {}, insert_err
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

sql_exec_drop_view :: proc(tx: ^Tx, stmt: Drop_View_Stmt) -> (Sql_Result, Error) {
	if _, err := tx_table(tx, VIEW_TABLE); err.kind != .None {
		if stmt.if_exists do return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
		return {}, errf(.Table_Not_Found, "view %s does not exist", stmt.name)
	}
	params := []Value{value_string(stmt.name)}
	result, delete_err := sql_execute_in_tx_params(tx, "DELETE FROM _view WHERE name = ?", params)
	if delete_err.kind != .None do return {}, delete_err
	affected := result.affected
	sql_result_destroy(&result)
	if affected == 0 && !stmt.if_exists {
		return {}, errf(.Table_Not_Found, "view %s does not exist", stmt.name)
	}
	return Sql_Result{kind = .Ack, affected = affected, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

@(private)
views_ensure_table :: proc(tx: ^Tx) -> Error {
	if _, err := tx_table(tx, VIEW_TABLE); err.kind == .None do return ERROR_NONE
	result, create_err := sql_execute_in_tx(tx, VIEW_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// view_names lists the defined views, sorted.
view_names :: proc(tx: ^Tx, alloc: mem.Allocator) -> ([]string, Error) {
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := tx_collect(tx, VIEW_TABLE, &rows); collect_err.kind != .None {
		if collect_err.kind == .Table_Not_Found do return nil, ERROR_NONE
		return nil, collect_err
	}
	names := make([dynamic]string, 0, len(rows), alloc)
	for row in rows do append(&names, row.values[0].s)
	slice_sort_strings(names[:])
	return names[:], ERROR_NONE
}

@(private)
view_sql :: proc(tx: ^Tx, name: string) -> (string, bool) {
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := tx_collect(tx, VIEW_TABLE, &rows); collect_err.kind != .None do return "", false
	for row in rows {
		if row.values[0].kind == .String && row.values[0].s == name {
			if row.values[1].kind == .String do return row.values[1].s, true
			return "", false
		}
	}
	return "", false
}

// tx_source_table resolves a FROM or JOIN name. A real table wins; a view is
// materialized into a temporary table owned by the transaction.
tx_source_table :: proc(
	tx: ^Tx,
	name: string,
	args: []Value,
	schema: string = "",
) -> (table: ^Table, is_view: bool, err: Error) {
	if len(schema) > 0 {
		// `schema.table` names an attached database, which is read-only: the
		// table is copied under its lock and scanned like a view.
		materialized, attach_err := tx_materialize_attached(tx, schema, name)
		return materialized, true, attach_err
	}
	// Table-valued functions materialize into a temporary table, so the rest of
	// the executor sees an ordinary (view-like) relation.
	if is_json_table_function(name) {
		materialized, json_err := tx_materialize_json_table(tx, name, args)
		return materialized, true, json_err
	}
	resolved, table_err := tx_table(tx, name)
	if table_err.kind == .None {
		if len(args) > 0 {
			return nil, false, errf(.Sql_Unsupported, "table %s does not take parameters", name)
		}
		return resolved, false, ERROR_NONE
	}
	if table_err.kind != .Table_Not_Found do return nil, false, table_err
	sql, found := view_sql(tx, name)
	if !found {
		return nil, false, table_err
	}
	materialized, view_err := tx_materialize_view(tx, name, sql, args)
	return materialized, true, view_err
}

// view_args evaluates the parameters of one view reference. They are constants
// with respect to the outer row, so no sources are bound — except for a lateral
// table function, which passes the sources bound so far.
view_args :: proc(
	tx: ^Tx,
	ref: Table_Ref,
	params: []Value,
	sources: []Source = nil,
) -> ([]Value, Error) {
	if len(ref.args) == 0 do return nil, ERROR_NONE
	ctx := Eval_Ctx{tx = tx, params = params, sources = sources, now_us = now_microseconds()}
	out := make([]Value, len(ref.args))
	for expr, i in ref.args {
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None do return nil, eval_err
		out[i] = value
	}
	return out, ERROR_NONE
}

@(private)
tx_materialize_view :: proc(tx: ^Tx, name, sql: string, args: []Value) -> (^Table, Error) {
	if tx.view_depth >= VIEW_MAX_DEPTH {
		return nil, errf(.Sql_Unsupported, "view %s nests deeper than %d levels", name, VIEW_MAX_DEPTH)
	}
	for i in 0 ..< tx.view_depth {
		if tx.view_stack[i] == name {
			return nil, errf(.Sql_Unsupported, "view %s refers to itself", name)
		}
	}
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None {
		return nil, errf(.Corrupt_Log, "view %s holds invalid SQL: %s", name, parse_err.message)
	}
	defer query_destroy(&query)
	select_stmt, is_select := query.statement.(Select_Stmt)
	if !is_select {
		return nil, errf(.Corrupt_Log, "view %s does not hold a SELECT", name)
	}
	// The stack holds the requested names, not the SQL, so a cycle through two
	// views is caught as well.
	tx.view_stack[tx.view_depth] = name
	tx.view_depth += 1
	result, exec_err := sql_exec_select(tx, select_stmt, args)
	tx.view_depth -= 1
	if exec_err.kind != .None do return nil, exec_err
	defer sql_result_destroy(&result)

	columns := make([]Column, len(result.columns), tx.alloc)
	for column_name, i in result.columns {
		columns[i] = Column {
			name = strings.clone(column_name, tx.alloc),
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

// view_column_type picks a static type from the rows a view produced. A column
// with only NULLs becomes text.
@(private)
view_column_type :: proc(rows: [][]Value, position: int) -> Column_Type {
	for row in rows {
		if position >= len(row) do break
		#partial switch row[position].kind {
		case .Bool:
			return type_bool
		case .Int:
			return type_int
		case .Uint:
			return type_uint
		case .Float:
			return type_float
		case .String:
			return type_string
		case .Bytes:
			return type_bytes
		case .Timestamp:
			return type_timestamp
		case .Uuid:
			return type_uuid
		case .Int128:
			return Column_Type{kind = .Int, width = 16}
		case .Uint128:
			return Column_Type{kind = .Uint, width = 16}
		case .Duration:
			return Column_Type{kind = .Duration, width = 8}
		case .Identity:
			return Column_Type{kind = .Identity, width = 32}
		case .Connection:
			return Column_Type{kind = .Connection, width = 8}
		}
	}
	return type_string
}
