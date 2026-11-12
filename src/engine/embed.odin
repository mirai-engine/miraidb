package engine

// Embedding API.
//
// The CLI and the server are clients of the engine; embedders call these
// functions directly. The shape is deliberately close to the classic embedded
// database C API so ports and examples translate line by line:
//
//	conn := embed_open("app.db", {persistent = true, create = true, durable = true})
//	defer embed_close(conn)
//	embed_exec(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
//	stmt := embed_prepare(conn, "INSERT INTO t (name) VALUES (?)")
//	embed_bind_text(stmt, 0, "Ada")
//	embed_step(stmt) // false: the statement wrote instead of reading
//	embed_finalize(stmt)
//	stmt = embed_prepare(conn, "SELECT id, name FROM t")
//	for embed_step(stmt) {
//		id := embed_column_int(stmt, 0)
//		name := embed_column_text(stmt, 1)
//	}
//
// A connection owns its store. Opening a .sqlite/.db file imports it into an
// in-memory store, so statements answer against the file without converting it.

import "core:strings"

EMBED_OK :: Error_Kind.None

Embed_Statement :: struct {
	conn:   ^Embed_Conn,
	sql:    string,
	params: [dynamic]Value,
	result: Sql_Result,
	// prepared caches the parsed statement, so reset+step does not parse again.
	prepared: ^Stmt_Prepared,
	// started is set after the first step; rows walk result.rows from position.
	started: bool,
	done:    bool,
	row:     int,
}

Embed_Conn :: struct {
	store:      ^Store,
	owns_store: bool,
	last_error: Error,
}

// embed_open opens the engine format, or imports a SQLite file into memory.
embed_open :: proc(path: string, options := Store_Options{persistent = true, create = true, durable = true}) -> (^Embed_Conn, Error) {
	conn := new(Embed_Conn)
	store: ^Store
	if len(path) > 0 && sqlite_is_file(path) {
		file, file_err := sqlite_file_open(path)
		if file_err.kind != .None {
			free(conn)
			return nil, file_err
		}
		defer sqlite_file_destroy(&file)
		opened, open_err := store_open("", {persistent = false})
		if open_err.kind != .None {
			free(conn)
			return nil, open_err
		}
		if _, _, import_err := sqlite_import(&file, opened); import_err.kind != .None {
			store_close(opened)
			free(conn)
			return nil, import_err
		}
		store = opened
		// The file stays the user's database: every commit mirrors back to it.
		store_set_sqlite_mirror(store, path)
	} else {
		opened, open_err := store_open(path, options)
		if open_err.kind != .None {
			free(conn)
			return nil, open_err
		}
		store = opened
	}
	conn.store = store
	conn.owns_store = true
	return conn, ERROR_NONE
}

// embed_wrap builds a connection over an existing store without taking
// ownership: the caller keeps managing the store's lifetime.
embed_wrap :: proc(store: ^Store) -> ^Embed_Conn {
	conn := new(Embed_Conn)
	conn.store = store
	return conn
}

embed_close :: proc(conn: ^Embed_Conn) {
	if conn == nil do return
	if conn.owns_store && conn.store != nil {
		store_close(conn.store)
	}
	free(conn)
}

embed_error :: proc(conn: ^Embed_Conn) -> string {
	if conn == nil do return "no connection"
	if conn.last_error.kind == .None do return ""
	return conn.last_error.message
}

@(private)
embed_fail :: proc(conn: ^Embed_Conn, err: Error) -> Error {
	if conn != nil {
		delete(conn.last_error.message)
		conn.last_error = err
	}
	return err
}

@(private)
embed_succeed :: proc(conn: ^Embed_Conn) {
	if conn == nil do return
	delete(conn.last_error.message)
	conn.last_error = ERROR_NONE
}

// embed_exec runs one statement without parameters.
embed_exec :: proc(conn: ^Embed_Conn, sql: string) -> Error {
	if conn == nil do return errf(.Invalid_Argument, "no connection")
	result, exec_err := sql_execute(conn.store, sql)
	if exec_err.kind != .None do return embed_fail(conn, exec_err)
	sql_result_destroy(&result)
	embed_succeed(conn)
	return ERROR_NONE
}

// embed_backup writes a compacted copy of the database at path. The copy is a
// database of its own: it opens, reads and takes new commits.
embed_backup :: proc(conn: ^Embed_Conn, path: string) -> Error {
	if conn == nil do return errf(.Invalid_Argument, "no connection")
	if backup_err := store_vacuum_into(conn.store, path); backup_err.kind != .None {
		return embed_fail(conn, backup_err)
	}
	embed_succeed(conn)
	return ERROR_NONE
}

// embed_exec_params runs one statement with positional parameters.
embed_exec_params :: proc(conn: ^Embed_Conn, sql: string, params: []Value) -> Error {
	if conn == nil do return errf(.Invalid_Argument, "no connection")
	result, exec_err := sql_execute_params(conn.store, sql, params)
	if exec_err.kind != .None do return embed_fail(conn, exec_err)
	sql_result_destroy(&result)
	embed_succeed(conn)
	return ERROR_NONE
}

embed_prepare :: proc(conn: ^Embed_Conn, sql: string) -> ^Embed_Statement {
	if conn == nil do return nil
	stmt := new(Embed_Statement)
	stmt.conn = conn
	stmt.sql = strings.clone(sql)
	return stmt
}

embed_finalize :: proc(stmt: ^Embed_Statement) {
	if stmt == nil do return
	delete(stmt.sql)
	stmt_prepared_destroy(stmt.prepared)
	embed_clear_bindings(stmt)
	sql_result_destroy(&stmt.result)
	free(stmt)
}

embed_clear_bindings :: proc(stmt: ^Embed_Statement) {
	for value in stmt.params do value_deep_free(value, context.allocator)
	clear(&stmt.params)
}

@(private)
embed_bind :: proc(stmt: ^Embed_Statement, index: int, value: Value) -> Error {
	if stmt == nil do return errf(.Invalid_Argument, "no statement")
	if index < 0 do return errf(.Invalid_Argument, "parameter index cannot be negative")
	for len(stmt.params) <= index do append(&stmt.params, value_null())
	value_deep_free(stmt.params[index], context.allocator)
	stmt.params[index] = value_clone(value, context.allocator)
	embed_succeed(stmt.conn)
	return ERROR_NONE
}

embed_bind_null :: proc(stmt: ^Embed_Statement, index: int) -> Error {
	return embed_bind(stmt, index, value_null())
}

embed_bind_int :: proc(stmt: ^Embed_Statement, index: int, value: i64) -> Error {
	return embed_bind(stmt, index, value_int(value))
}

embed_bind_float :: proc(stmt: ^Embed_Statement, index: int, value: f64) -> Error {
	return embed_bind(stmt, index, value_float(value))
}

embed_bind_bool :: proc(stmt: ^Embed_Statement, index: int, value: bool) -> Error {
	return embed_bind(stmt, index, value_bool(value))
}

// embed_bind_text clones the text, so the caller keeps ownership of `value`.
embed_bind_text :: proc(stmt: ^Embed_Statement, index: int, value: string) -> Error {
	return embed_bind(stmt, index, value_string(strings.clone(value)))
}

// embed_bind_blob clones the bytes, so the caller keeps ownership of `value`.
embed_bind_blob :: proc(stmt: ^Embed_Statement, index: int, value: []u8) -> Error {
	bytes := make([]u8, len(value))
	copy(bytes, value)
	return embed_bind(stmt, index, value_bytes(bytes))
}

// embed_reset discards the current result and bindings so the statement can run
// again.
embed_reset :: proc(stmt: ^Embed_Statement) {
	if stmt == nil do return
	sql_result_destroy(&stmt.result)
	embed_clear_bindings(stmt)
	stmt.started = false
	stmt.done = false
	stmt.row = 0
	embed_succeed(stmt.conn)
}

// embed_is_query reports whether the statement can produce rows, so metadata
// accessors can execute it early without running a mutation.
@(private)
embed_is_query :: proc(sql: string) -> bool {
	trimmed := strings.trim_space(sql)
	upper := strings.to_upper(trimmed, context.temp_allocator)
	for prefix in ([]string{"SELECT", "WITH", "VALUES", "EXPLAIN", "SHOW", "DESCRIBE"}) {
		if strings.has_prefix(upper, prefix) do return true
	}
	return false
}

// embed_start executes the statement once, before the first step, so column
// metadata is available right after prepare (as SQLite clients expect).
@(private)
embed_start :: proc(stmt: ^Embed_Statement) -> Error {
	if stmt.started do return ERROR_NONE
	if stmt.prepared == nil {
		prepared, prepare_err := sql_prepare(stmt.conn.store, stmt.sql)
		if prepare_err.kind != .None {
			stmt.done = true
			return embed_fail(stmt.conn, prepare_err)
		}
		stmt.prepared = prepared
	}
	result, exec_err := prepared_execute(stmt.conn.store, stmt.prepared, stmt.params[:])
	if exec_err.kind != .None {
		stmt.done = true
		return embed_fail(stmt.conn, exec_err)
	}
	stmt.result = result
	stmt.started = true
	stmt.row = 0
	embed_succeed(stmt.conn)
	return ERROR_NONE
}

// embed_step executes on the first call and then advances one row. It returns
// true while a row is available.
embed_step :: proc(stmt: ^Embed_Statement) -> (has_row: bool, err: Error) {
	if stmt == nil do return false, errf(.Invalid_Argument, "no statement")
	if stmt.done do return false, ERROR_NONE
	if !stmt.started {
		if start_err := embed_start(stmt); start_err.kind != .None do return false, start_err
	}
	if stmt.result.kind != .Rows {
		stmt.done = true
		return false, ERROR_NONE
	}
	if stmt.row >= len(stmt.result.rows) {
		stmt.done = true
		return false, ERROR_NONE
	}
	stmt.row += 1
	return true, ERROR_NONE
}

embed_column_count :: proc(stmt: ^Embed_Statement) -> int {
	if stmt == nil do return 0
	if !stmt.started && embed_is_query(stmt.sql) {
		if embed_start(stmt).kind != .None do return 0
	}
	return len(stmt.result.columns)
}

// embed_column_value returns the whole typed value of a column, which blob
// handles need to tell text from bytes.
embed_column_value :: proc(stmt: ^Embed_Statement, index: int) -> (Value, bool) {
	return embed_column(stmt, index)
}

embed_column_name :: proc(stmt: ^Embed_Statement, index: int) -> string {
	if stmt == nil || index < 0 do return ""
	if !stmt.started && embed_is_query(stmt.sql) {
		if embed_start(stmt).kind != .None do return ""
	}
	if index >= len(stmt.result.columns) do return ""
	return stmt.result.columns[index]
}

@(private)
embed_column :: proc(stmt: ^Embed_Statement, index: int) -> (Value, bool) {
	if stmt == nil || stmt.row <= 0 || stmt.row > len(stmt.result.rows) do return {}, false
	row := stmt.result.rows[stmt.row - 1]
	if index < 0 || index >= len(row) do return {}, false
	return row[index], true
}

embed_column_type :: proc(stmt: ^Embed_Statement, index: int) -> Value_Kind {
	value, ok := embed_column(stmt, index)
	if !ok do return .Null
	return value.kind
}

embed_column_int :: proc(stmt: ^Embed_Statement, index: int) -> i64 {
	value, ok := embed_column(stmt, index)
	if !ok do return 0
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

embed_column_float :: proc(stmt: ^Embed_Statement, index: int) -> f64 {
	value, ok := embed_column(stmt, index)
	if !ok do return 0
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

embed_column_bool :: proc(stmt: ^Embed_Statement, index: int) -> bool {
	value, ok := embed_column(stmt, index)
	if !ok do return false
	#partial switch value.kind {
	case .Bool:
		return value.b
	case .Int:
		return value.i != 0
	}
	return false
}

// embed_column_text borrows the value: it stays valid until the next step or
// until the statement is reset or finalized.
embed_column_text :: proc(stmt: ^Embed_Statement, index: int) -> string {
	value, ok := embed_column(stmt, index)
	if !ok do return ""
	#partial switch value.kind {
	case .String:
		return value.s
	case .Bytes:
		return string(value.bytes)
	}
	return ""
}

embed_column_blob :: proc(stmt: ^Embed_Statement, index: int) -> []u8 {
	value, ok := embed_column(stmt, index)
	if !ok do return nil
	if value.kind == .Bytes do return value.bytes
	return nil
}

embed_column_is_null :: proc(stmt: ^Embed_Statement, index: int) -> bool {
	value, ok := embed_column(stmt, index)
	if !ok do return true
	return value.kind == .Null
}

// embed_changes reports the rows the last executed statement affected.
embed_changes :: proc(stmt: ^Embed_Statement) -> int {
	if stmt == nil do return 0
	return stmt.result.affected
}

