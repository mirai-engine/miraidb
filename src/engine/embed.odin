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
//
// Every Error an embed_* procedure returns is the caller's, like every other
// Error the engine returns: free it with error_free or pass it on. The
// connection keeps its own copy for embed_error, so a caller that frees the
// returned error can still ask the connection what went wrong.

import "core:mem/virtual"
import "core:strings"
import "core:time"

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
	// runs and steps count the executions and the step calls since prepare: what
	// sqlite3_stmt_status answers for RUN and VM_STEP.
	runs:  int,
	steps: int,
	// pending is the error the statement met when a program asked for its
	// columns before the first step and it ran then: that first step answers
	// it, as SQLite's step is where a runtime error is reported.
	pending: Error,
}

Embed_Conn :: struct {
	store:      ^Store,
	owns_store: bool,
	last_error: Error,
	// changes is the rows the most recent statement affected, whichever way it
	// ran: through embed_exec or through a statement that reached its end. SQLite
	// keeps one counter per connection for the same reason, so a caller can ask
	// after an exec as well as after a step (F3).
	changes:    int,
	// tx is the transaction a BEGIN (or an outermost SAVEPOINT) opened. While it
	// is set every statement of the connection runs inside it, and COMMIT,
	// ROLLBACK and RELEASE close it: the classic embedded API keeps one open
	// transaction per connection, and a program that writes `BEGIN; ...; COMMIT`
	// depends on it.
	tx:              ^Tx,
	// savepoint_began says the open transaction started with a SAVEPOINT, so
	// releasing the last savepoint commits it, as SQLite does.
	savepoint_began: bool,
	// share is the SQLite file this connection shares with the others open on
	// it in the process, and share_generation the commit of it the store
	// holds (sqlite_share.odin).
	share:            ^Sqlite_Share,
	share_generation: u64,
	// share_counter is the file's change counter as this connection last read
	// or wrote the file: another process's commit moves it.
	share_counter:    u32,
	// busy_timeout_ms is how long a write waits for another connection's write
	// lock before it fails with "database is locked" (sqlite3_busy_timeout).
	busy_timeout_ms:  int,
	// busy_handler, when set, decides instead of the timeout whether a
	// connection kept waiting tries again (sqlite3_busy_handler): it is
	// asked with how many times it has been asked for this wait.
	busy_handler:     Busy_Handler,
	busy_user:        rawptr,
	// share_depth counts the statements of this connection running on its
	// shared file: one a function runs inside another (`eval()`) runs under
	// the locks the outer one took.
	share_depth:      int,
}

// Busy_Handler answers whether to try again; `count` starts at 0.
Busy_Handler :: #type proc(user: rawptr, count: int) -> bool

// embed_open opens the engine format, or imports a SQLite file into memory.
embed_open :: proc(path: string, options := Store_Options{persistent = true, create = true, durable = true}) -> (^Embed_Conn, Error) {
	conn := new(Embed_Conn)
	store: ^Store
	// An existing file of zero bytes is an empty SQLite database, as SQLite
	// reads it (what `sqlite3.connect` or `touch` leaves): the first commit
	// writes the file.
	if len(path) > 0 && sqlite_is_empty_file(path) {
		opened, open_err := store_open("", {persistent = false})
		if open_err.kind != .None {
			free(conn)
			return nil, open_err
		}
		store_set_sqlite_mirror(opened, path)
		conn.store = opened
		conn.owns_store = true
		sqlite_share_join(conn, path)
		return conn, ERROR_NONE
	}
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
	if len(store.sqlite_mirror) > 0 do sqlite_share_join(conn, path)
	return conn, ERROR_NONE
}

// embed_set_busy_timeout sets how long a write waits for another connection
// on the same file (sqlite3_busy_timeout); zero fails at once.
embed_set_busy_timeout :: proc(conn: ^Embed_Conn, milliseconds: int) {
	if conn == nil do return
	conn.busy_timeout_ms = max(milliseconds, 0)
	conn.busy_handler, conn.busy_user = nil, nil
}

// embed_set_busy_handler makes `handler` decide whether a wait goes on, in
// place of the timeout: a connection has one or the other, as in SQLite.
embed_set_busy_handler :: proc(conn: ^Embed_Conn, handler: Busy_Handler, user: rawptr) {
	if conn == nil do return
	conn.busy_handler, conn.busy_user = handler, user
	conn.busy_timeout_ms = 0
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
	// A transaction still open at close is rolled back, as SQLite does.
	if conn.tx != nil {
		tx_rollback(conn.tx)
		conn.tx = nil
	}
	sqlite_share_leave(conn)
	if conn.owns_store && conn.store != nil {
		store_close(conn.store)
	}
	error_free(&conn.last_error)
	free(conn)
}

// embed_statement_active reports a statement that stepped and has neither
// reached its end nor been reset: what SQLite calls an active statement.
embed_statement_active :: proc(stmt: ^Embed_Statement) -> bool {
	return stmt != nil && stmt.started && !stmt.done
}

embed_error :: proc(conn: ^Embed_Conn) -> string {
	if conn == nil do return "no connection"
	if conn.last_error.kind == .None do return ""
	return conn.last_error.message
}

// embed_fail records a copy of `err` as the connection's last error and returns
// `err` itself, which stays the caller's.
@(private)
embed_fail :: proc(conn: ^Embed_Conn, err: Error) -> Error {
	if conn != nil {
		delete(conn.last_error.message)
		conn.last_error = Error {
			kind    = err.kind,
			message = strings.clone(err.message),
		}
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
	return embed_exec_params(conn, sql, nil)
}

// embed_error_kind is the kind of the connection's last error.
embed_error_kind :: proc(conn: ^Embed_Conn) -> Error_Kind {
	if conn == nil do return .Invalid_Argument
	return conn.last_error.kind
}

// embed_note_error records a failure the embedding layer found on its own (a
// misuse, a refused close), so embed_error answers it like an engine error.
embed_note_error :: proc(conn: ^Embed_Conn, kind: Error_Kind, message: string) {
	if conn == nil do return
	// `message` may be the connection's own message (a caller that re-records
	// what embed_error answered), so the copy is made before the old one goes.
	copy := strings.clone(message)
	delete(conn.last_error.message)
	conn.last_error = Error{kind = kind, message = copy}
}

// embed_sql is the text the statement was prepared from.
embed_sql :: proc(stmt: ^Embed_Statement) -> string {
	if stmt == nil do return ""
	return stmt.sql
}

// embed_busy reports a statement that has started and not reached its end: the
// state sqlite3_stmt_busy names.
embed_busy :: proc(stmt: ^Embed_Statement) -> bool {
	return stmt != nil && stmt.started && !stmt.done
}

// embed_has_row reports whether the last step produced a row the column calls
// can read.
embed_has_row :: proc(stmt: ^Embed_Statement) -> bool {
	if stmt == nil || !stmt.started || stmt.done do return false
	return stmt.result.kind == .Rows && stmt.row > 0 && stmt.row <= len(stmt.result.rows)
}

// embed_explain_mode is 0 for an ordinary statement, 1 for EXPLAIN and 2 for
// EXPLAIN QUERY PLAN, the numbers sqlite3_stmt_isexplain answers.
embed_explain_mode :: proc(stmt: ^Embed_Statement) -> int {
	if stmt == nil || stmt.prepared == nil || stmt.prepared.is_pragma do return 0
	if explain, is_explain := stmt.prepared.query.statement.(Explain_Stmt); is_explain {
		return explain.query_plan ? 2 : 1
	}
	return 0
}

// embed_read_only reports a statement that cannot change the database file.
// Transaction control counts as read-only, as SQLite documents for
// sqlite3_stmt_readonly; a pragma is read-only unless it assigns a value.
// prepared_counts_changes reports a statement whose rows sqlite3_changes
// counts: INSERT, UPDATE, DELETE and MERGE. A query or DDL leaves the count
// where the last write put it, as in SQLite.
@(private)
prepared_counts_changes :: proc(prepared: ^Stmt_Prepared) -> bool {
	if prepared == nil || prepared.is_pragma do return false
	#partial switch _ in prepared.query.statement {
	case Insert_Stmt, Update_Stmt, Delete_Stmt, Merge_Stmt:
		return true
	}
	return false
}

embed_read_only :: proc(stmt: ^Embed_Statement) -> bool {
	if stmt == nil || stmt.prepared == nil do return true
	if stmt.prepared.is_pragma do return !strings.contains(stmt.prepared.pragma_body, "=")
	#partial switch _ in stmt.prepared.query.statement {
	case Select_Stmt, With_Stmt, Explain_Stmt, Show_Stmt, Describe_Stmt, Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt, Attach_Stmt, Detach_Stmt:
		return true
	}
	return false
}

// embed_in_transaction reports whether a BEGIN or a SAVEPOINT left a transaction
// open on the connection: what sqlite3_get_autocommit answers, inverted.
embed_in_transaction :: proc(conn: ^Embed_Conn) -> bool {
	return conn != nil && conn.tx != nil
}

// embed_authorize checks the names a statement just prepared uses (D37) and
// asks the store's authorizer about it, reading the catalog the connection
// sees.
@(private)
embed_authorize :: proc(conn: ^Embed_Conn, prepared: ^Stmt_Prepared) -> Error {
	if prepared.is_pragma do return embed_authorize_only(conn, prepared)
	tx := conn.tx
	own := tx == nil
	if own do tx = tx_begin_read(conn.store)
	defer if own do tx_end(tx)
	if resolve_err := sql_resolve_names(tx, &prepared.query.statement, virtual.arena_allocator(&prepared.query.arena)); resolve_err.kind != .None do return resolve_err
	if conn.store.hooks.authorizer == nil do return ERROR_NONE
	ignored, err := sql_authorize(conn.store, tx, prepared)
	prepared.ignored = ignored
	return err
}

@(private)
embed_authorize_only :: proc(conn: ^Embed_Conn, prepared: ^Stmt_Prepared) -> Error {
	if conn.store.hooks.authorizer == nil do return ERROR_NONE
	tx := conn.tx
	own := tx == nil
	if own do tx = tx_begin_read(conn.store)
	defer if own do tx_end(tx)
	ignored, err := sql_authorize(conn.store, tx, prepared)
	prepared.ignored = ignored
	return err
}

// embed_run executes a prepared statement on the connection: transaction
// control against the connection's own transaction, anything else inside that
// transaction when one is open and on its own otherwise. The messages are
// SQLite's, so a caller that matches them keeps working.
@(private)
embed_run :: proc(conn: ^Embed_Conn, prepared: ^Stmt_Prepared, params: []Value) -> (Sql_Result, Error) {
	if conn.share != nil do return embed_run_shared(conn, prepared, params)
	return embed_run_statement(conn, prepared, params)
}

@(private)
embed_run_statement :: proc(conn: ^Embed_Conn, prepared: ^Stmt_Prepared, params: []Value) -> (Sql_Result, Error) {
	ack :: proc(conn: ^Embed_Conn) -> (Sql_Result, Error) {
		return Sql_Result{kind = .Ack, commit_seq = conn.store.commit_seq}, ERROR_NONE
	}
	// A statement the authorizer told to ignore prepares and does nothing.
	if prepared.ignored do return ack(conn)
	if !prepared.is_pragma {
		#partial switch stmt in prepared.query.statement {
		case Begin_Stmt:
			if conn.tx != nil do return {}, errf(.Sql_Not_A_Query, "cannot start a transaction within a transaction")
			conn.tx = tx_begin_write(conn.store)
			conn.savepoint_began = false
			return ack(conn)
		case Commit_Stmt:
			if conn.tx == nil do return {}, errf(.Sql_Not_A_Query, "cannot commit - no transaction is active")
			tx := conn.tx
			conn.tx = nil
			if err := tx_commit(tx); err.kind != .None do return {}, err
			return ack(conn)
		case Rollback_Stmt:
			if conn.tx == nil do return {}, errf(.Sql_Not_A_Query, "cannot rollback - no transaction is active")
			tx_rollback(conn.tx)
			conn.tx = nil
			store_fire_rollback(conn.store)
			return ack(conn)
		case Savepoint_Stmt:
			switch stmt.kind {
			case .Set:
				if conn.tx == nil {
					conn.tx = tx_begin_write(conn.store)
					conn.savepoint_began = true
				}
				if err := tx_savepoint(conn.tx, stmt.name); err.kind != .None do return {}, err
			case .Release:
				if conn.tx == nil do return {}, errf(.Sql_Not_A_Query, "no such savepoint: %s", stmt.name)
				if err := tx_release_savepoint(conn.tx, stmt.name); err.kind != .None do return {}, err
				if conn.savepoint_began && len(conn.tx.savepoints) == 0 {
					tx := conn.tx
					conn.tx = nil
					if err := tx_commit(tx); err.kind != .None do return {}, err
				}
			case .Rollback_To:
				if conn.tx == nil do return {}, errf(.Sql_Not_A_Query, "no such savepoint: %s", stmt.name)
				if err := tx_rollback_to_savepoint(conn.tx, stmt.name); err.kind != .None do return {}, err
			}
			return ack(conn)
		}
	}
	// The triggers it fires give again the Ignore answers kept about them.
	saved := auth_replay_begin(prepared)
	defer auth_replay_end(saved)
	if conn.tx != nil {
		result, err := prepared_execute_in_tx(conn.tx, prepared, params)
		// A constraint's ON CONFLICT ROLLBACK ends the transaction it broke in.
		if err.kind != .None && conn.tx.rollback_requested {
			tx_rollback(conn.tx)
			conn.tx = nil
			store_fire_rollback(conn.store)
		}
		return result, err
	}
	return prepared_execute(conn.store, prepared, params)
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

// --- Identity and tokens ---------------------------------------------------
//
// An embedded caller is sometimes the host and sometimes a guest of one: a
// program that embeds the engine still has row policies, and they filter by the
// identity the store carries, which starts as the all-zero identity - the same
// state a server connection is in before it authenticates. These four calls are
// what a C caller needs to make that choice, and they work without a Host because
// a token is a row in the database, not a piece of the reducer catalog.

// embed_set_identity makes `identity` the caller the policies see.
embed_set_identity :: proc(conn: ^Embed_Conn, identity: Identity) -> Error {
	if conn == nil do return errf(.Invalid_Argument, "no connection")
	store_set_identity(conn.store, identity)
	embed_succeed(conn)
	return ERROR_NONE
}

// embed_identity reports the identity the policies see.
embed_identity :: proc(conn: ^Embed_Conn) -> Identity {
	if conn == nil do return {}
	return store_identity(conn.store)
}

// embed_authenticate resolves a token and, if it is live, installs the identity it
// names. The identity is left alone when the token is unknown or expired, so a
// caller that ignores the error cannot become somebody else by accident.
embed_authenticate :: proc(conn: ^Embed_Conn, token: string) -> Error {
	if conn == nil do return errf(.Invalid_Argument, "no connection")
	identity, valid := store_authenticate(conn.store, token, time.now()._nsec / 1000)
	if !valid {
		return embed_fail(conn, errf(.Permission_Denied, "invalid or expired token"))
	}
	store_set_identity(conn.store, identity)
	embed_succeed(conn)
	return ERROR_NONE
}

// embed_issue_token creates a credential for `identity`. Zero `ttl_us` means it
// never expires. The returned string is owned by the caller.
embed_issue_token :: proc(conn: ^Embed_Conn, identity: Identity, ttl_us: i64) -> (string, Error) {
	if conn == nil do return "", errf(.Invalid_Argument, "no connection")
	token, issue_err := store_issue_token(conn.store, identity, ttl_us, time.now()._nsec / 1000)
	if issue_err.kind != .None do return "", embed_fail(conn, issue_err)
	embed_succeed(conn)
	return token, ERROR_NONE
}

// embed_exec_params runs one statement with positional parameters.
embed_exec_params :: proc(conn: ^Embed_Conn, sql: string, params: []Value) -> Error {
	if conn == nil do return errf(.Invalid_Argument, "no connection")
	// A cancellation belongs to the statement it interrupted: the next one starts
	// with a clean flag, so an interrupted connection is still usable (D25).
	store_clear_cancel(conn.store)
	// The names a statement uses are checked against the file as it is now, as
	// embed_prepare checks them.
	if conn.share != nil && conn.tx == nil {
		if refresh_err := sqlite_share_refresh(conn); refresh_err.kind != .None do return embed_fail(conn, refresh_err)
	}
	prepared, prepare_err := sql_prepare(conn.store, sql)
	if prepare_err.kind != .None do return embed_fail(conn, prepare_err)
	defer stmt_prepared_destroy(prepared)
	if auth_err := embed_authorize(conn, prepared); auth_err.kind != .None do return embed_fail(conn, auth_err)
	started := now_microseconds()
	result, exec_err := embed_run(conn, prepared, params)
	store_record_query_latency(conn.store, now_microseconds() - started)
	counts := prepared_counts_changes(prepared)
	if exec_err.kind != .None {
		if counts do conn.changes = 0
		return embed_fail(conn, exec_err)
	}
	if counts do conn.changes = result.affected
	sql_result_destroy(&result)
	embed_succeed(conn)
	return ERROR_NONE
}

embed_prepare :: proc(conn: ^Embed_Conn, sql: string) -> ^Embed_Statement {
	if conn == nil do return nil
	// The names a statement uses are checked against the file as it is now;
	// a file it cannot read yet is read again when the statement runs.
	if conn.share != nil && conn.tx == nil {
		if refresh_err := sqlite_share_refresh(conn); refresh_err.kind != .None do error_free(&refresh_err)
	}
	// Parse now rather than at the first step: it is the same work, it reports a
	// syntax error where a caller expects one, and it is what makes the parameter
	// count known before the first bind, so index 99 can be refused (D29).
	prepared, prepare_err := sql_prepare(conn.store, sql)
	if prepare_err.kind != .None {
		embed_fail(conn, prepare_err)
		return nil
	}
	if auth_err := embed_authorize(conn, prepared); auth_err.kind != .None {
		stmt_prepared_destroy(prepared)
		embed_fail(conn, auth_err)
		error_free(&auth_err)
		return nil
	}
	stmt := new(Embed_Statement)
	stmt.conn = conn
	stmt.sql = strings.clone(sql)
	stmt.prepared = prepared
	// A prepare that works clears the last error, as SQLite's does: errmsg after
	// it must not repeat an older failure.
	embed_succeed(conn)
	return stmt
}

embed_finalize :: proc(stmt: ^Embed_Statement) {
	if stmt == nil do return
	delete(stmt.sql)
	stmt_prepared_destroy(stmt.prepared)
	embed_clear_bindings(stmt)
	sql_result_destroy(&stmt.result)
	error_free(&stmt.pending)
	free(stmt)
}

// embed_clear_bindings sets every bound parameter back to NULL and keeps the
// list's length, which is what SQLite's sqlite3_clear_bindings does: a statement
// whose parameters were cleared still runs, with NULLs, instead of failing for
// a count it never had.
embed_clear_bindings :: proc(stmt: ^Embed_Statement) {
	if stmt == nil do return
	for &value in stmt.params {
		if value.kind == .Null do continue
		value_deep_free(value, context.allocator)
		value = value_null()
	}
}

// Embed_Parameter_Count reports how many positional parameters the statement
// binds, which is what an embedding layer checks an index against.
Embed_Parameter_Count :: proc(stmt: ^Embed_Statement) -> int {
	if stmt == nil || stmt.prepared == nil do return 0
	return stmt.prepared.param_count
}

// embed_column_origins describes where each result column comes from (see
// describe.odin), reading the catalog the connection sees: its open
// transaction's when there is one. The slice and its strings are copied before
// that transaction ends and belong to the caller, who frees them with
// embed_column_origins_destroy. Nil when the statement is not one the
// description can answer.
embed_column_origins :: proc(stmt: ^Embed_Statement, alloc := context.allocator) -> []Column_Origin {
	if stmt == nil || stmt.prepared == nil || stmt.prepared.is_pragma do return nil
	tx := stmt.conn.tx
	own := tx == nil
	if own do tx = tx_begin_read(stmt.conn.store)
	defer if own do tx_end(tx)
	origins, ok := sql_describe_origins(tx, stmt.prepared.query.statement, alloc)
	if !ok do return nil
	for &origin in origins {
		if len(origin.table) == 0 do continue
		origin.database = strings.clone(origin.database, alloc)
		origin.table = strings.clone(origin.table, alloc)
		origin.column = strings.clone(origin.column, alloc)
		origin.decltype = strings.clone(origin.decltype, alloc)
	}
	return origins
}

embed_column_origins_destroy :: proc(origins: []Column_Origin, alloc := context.allocator) {
	for origin in origins {
		if len(origin.table) == 0 do continue
		delete(origin.database, alloc)
		delete(origin.table, alloc)
		delete(origin.column, alloc)
		delete(origin.decltype, alloc)
	}
	delete(origins, alloc)
}

// embed_parameter_name is the name parameter `index` (0-based) was written with:
// "?3", ":id", "@id", "$id", or "" for a bare `?` and for an index out of range.
embed_parameter_name :: proc(stmt: ^Embed_Statement, index: int) -> string {
	if stmt == nil || stmt.prepared == nil || stmt.prepared.is_pragma do return ""
	names := stmt.prepared.query.param_names
	if index < 0 || index >= len(names) do return ""
	return names[index]
}

// embed_parameter_index finds the parameter written as `name` (with its prefix)
// and answers its 0-based index, or -1.
embed_parameter_index :: proc(stmt: ^Embed_Statement, name: string) -> int {
	if stmt == nil || stmt.prepared == nil || stmt.prepared.is_pragma || len(name) == 0 do return -1
	for candidate, index in stmt.prepared.query.param_names {
		if candidate == name do return index
	}
	return -1
}

// embed_parameter_value is what parameter `index` (0-based) is bound to now;
// NULL when nothing is.
embed_parameter_value :: proc(stmt: ^Embed_Statement, index: int) -> Value {
	if stmt == nil || index < 0 || index >= len(stmt.params) do return value_null()
	return stmt.params[index]
}

embed_bind :: proc(stmt: ^Embed_Statement, index: int, value: Value) -> Error {
	if stmt == nil do return errf(.Invalid_Argument, "no statement")
	if index < 0 do return errf(.Invalid_Argument, "parameter index cannot be negative")
	// A bind outside the statement's parameters is a range error, not permission to
	// grow the list: index 99 used to succeed and leave a parameter nobody reads.
	if stmt.prepared != nil && index >= stmt.prepared.param_count {
		return errf(
			.Invalid_Argument,
			"parameter index %d is out of range: the statement binds %d",
			index + 1,
			stmt.prepared.param_count,
		)
	}
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

// embed_reset discards the current result so the statement can run again. The
// bound values stay: SQLite's sqlite3_reset keeps them, and the call a caller
// makes to drop them is sqlite3_clear_bindings (F2).
embed_reset :: proc(stmt: ^Embed_Statement) {
	if stmt == nil do return
	sql_result_destroy(&stmt.result)
	error_free(&stmt.pending)
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
	// A PRAGMA that reads (no `=`) answers rows whose columns a program asks
	// for before the first step, as SQLite knows them at prepare: the shell
	// sizes its output that way. It runs once, here, and the steps read that
	// result.
	if strings.has_prefix(upper, "PRAGMA") && (!strings.contains(upper, "=") || pragma_reads_with_argument(upper)) do return true
	return false
}

// pragma_reads_with_argument reports a PRAGMA whose `= x` names what to read
// rather than a setting: `PRAGMA table_info = t` is `PRAGMA table_info(t)`.
@(private)
pragma_reads_with_argument :: proc(upper: string) -> bool {
	for name in ([]string{"TABLE_INFO", "TABLE_XINFO", "INDEX_LIST", "INDEX_INFO", "INDEX_XINFO", "FOREIGN_KEY_LIST", "FOREIGN_KEY_CHECK", "INTEGRITY_CHECK", "QUICK_CHECK"}) {
		if strings.contains(upper, name) do return true
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
	store_clear_cancel(stmt.conn.store)
	// A statement's start counts as a step of the progress handler too, as
	// SQLite's first instructions do: a statement that visits no row still
	// gives it its chance to stop it.
	if store_cancelled(stmt.conn.store) {
		stmt.done = true
		return embed_fail(stmt.conn, errf(.Cancelled, "interrupted"))
	}
	result, exec_err := embed_run(stmt.conn, stmt.prepared, stmt.params[:])
	if exec_err.kind != .None {
		stmt.done = true
		return embed_fail(stmt.conn, exec_err)
	}
	stmt.result = result
	stmt.started = true
	stmt.runs += 1
	stmt.row = 0
	embed_succeed(stmt.conn)
	return ERROR_NONE
}

// embed_step executes on the first call and then advances one row. It returns
// true while a row is available.
embed_step :: proc(stmt: ^Embed_Statement) -> (has_row: bool, err: Error) {
	if stmt == nil do return false, errf(.Invalid_Argument, "no statement")
	stmt.steps += 1
	counts := prepared_counts_changes(stmt.prepared)
	if stmt.pending.kind != .None {
		// The error the early run met is this step's, and the caller's.
		pending := stmt.pending
		stmt.pending = ERROR_NONE
		if counts do stmt.conn.changes = 0
		return false, embed_fail(stmt.conn, pending)
	}
	if stmt.done do return false, ERROR_NONE
	if !stmt.started {
		if start_err := embed_start(stmt); start_err.kind != .None {
			// A write that failed changed nothing, as SQLite counts it.
			if counts do stmt.conn.changes = 0
			return false, start_err
		}
	}
	if stmt.result.kind != .Rows || stmt.row >= len(stmt.result.rows) {
		stmt.done = true
		if counts do stmt.conn.changes = stmt.result.affected
		return false, ERROR_NONE
	}
	stmt.row += 1
	return true, ERROR_NONE
}

embed_column_count :: proc(stmt: ^Embed_Statement) -> int {
	if stmt == nil do return 0
	if !stmt.started && embed_is_query(stmt.sql) {
		if start_err := embed_start(stmt); start_err.kind != .None {
			error_free(&stmt.pending)
			stmt.pending = start_err
			return 0
		}
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
		if start_err := embed_start(stmt); start_err.kind != .None {
			error_free(&stmt.pending)
			stmt.pending = start_err
			return ""
		}
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

// embed_last_changes reports the rows the connection's most recent statement
// affected, whether it ran through embed_exec or through a step that reached its
// end. A statement's own count is embed_changes.
embed_last_changes :: proc(conn: ^Embed_Conn) -> int {
	if conn == nil do return 0
	return conn.changes
}

