package capi

// C ABI for embedding the engine in other languages.
//
// Build a shared library with:
//
//	odin build src/capi -build-mode:shared -out:libmiraidb.so
//
// Every exported function uses the C calling convention and plain C types, so
// include/miraidb.h is the whole contract. Strings are UTF-8 and NUL-terminated;
// blobs are length-delimited. Handles are opaque pointers, like the classic
// embedded database API.

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"

import engine "../engine"

MIRAIDB_OK :: c.int(0)
MIRAIDB_ERROR :: c.int(1)
// MIRAIDB_MISUSE is the answer to a handle that is not live: a statement used
// after finalize, or anything used through a connection already closed. The call
// does nothing and the process keeps running (D29).
MIRAIDB_MISUSE :: c.int(2)
MIRAIDB_ROW :: c.int(100)
MIRAIDB_DONE :: c.int(101)

// Column types exposed to C. Keep in sync with include/miraidb.h.
CAPI_NULL :: c.int(0)
CAPI_BOOL :: c.int(1)
CAPI_INT :: c.int(2)
CAPI_FLOAT :: c.int(3)
CAPI_TEXT :: c.int(4)
CAPI_BLOB :: c.int(5)
CAPI_OTHER :: c.int(6)

Capi_Connection :: struct {
	embed:   ^engine.Embed_Conn,
	last:    string, // owned, NUL-terminated
	changes: c.int,
	// statements is what this connection handed out and has not finalized, so a
	// close can make every one of them misuse instead of leaving them dangling.
	statements: map[rawptr]^Capi_Statement,
}

Capi_Statement :: struct {
	conn:  ^Capi_Connection,
	embed: ^engine.Embed_Statement,
}

// last_open_error is the reason the last miraidb_open failed. The connection
// does not exist when an open fails, so miraidb_errmsg(NULL) reports it; that is
// the only place in the API where a failed call has no handle to explain itself.
@(private)
last_open_error: string

// last_misuse explains a dead handle. When the handle is dead its connection
// cannot be found, so the reason is kept here and miraidb_errmsg falls back to it.
@(private)
last_misuse: string

@(private)
misuse_mutex: sync.Mutex

@(private)
set_misuse :: proc(message: string) {
	sync.lock(&misuse_mutex)
	defer sync.unlock(&misuse_mutex)
	delete(last_misuse)
	last_misuse = strings.clone(message)
}

@(export)
miraidb_open :: proc "c" (path: cstring) -> rawptr {
	context = runtime.default_context()
	if path == nil do return nil
	conn, err := engine.embed_open(string(path))
	if err.kind != .None {
		if conn != nil do engine.embed_close(conn)
		delete(last_open_error)
		last_open_error = strings.clone(err.message)
		return nil
	}
	delete(last_open_error)
	last_open_error = ""
	handle := new(Capi_Connection)
	handle.embed = conn
	handle.statements = make(map[rawptr]^Capi_Statement)
	engine.handle_register(rawptr(handle))
	return rawptr(handle)
}

@(private)
capi_conn :: proc(handle: rawptr) -> ^Capi_Connection {
	// The pointer is checked by value; casting it first and reading a field would
	// be the access violation this guard exists to stop.
	if !engine.handle_is_live(handle) do return nil
	return cast(^Capi_Connection)handle
}

@(export)
miraidb_close :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil {
		set_misuse("connection handle is closed")
		return
	}
	// A statement this connection handed out is not left dangling: it is finalized
	// here and its handle forgotten, so a later call answers misuse (D29).
	keys := make([dynamic]rawptr, 0, len(conn.statements))
	for key, _ in conn.statements do append(&keys, key)
	for key in keys {
		if stmt, found := conn.statements[key]; found {
			engine.embed_finalize(stmt.embed)
			engine.handle_forget(key)
			free(stmt)
		}
	}
	delete(conn.statements)
	delete(keys)
	engine.handle_forget(rawptr(conn))
	engine.embed_close(conn.embed)
	delete(conn.last)
	free(conn)
}

@(export)
miraidb_errmsg :: proc "c" (handle: rawptr) -> cstring {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil {
		sync.lock(&misuse_mutex)
		reason := last_misuse
		sync.unlock(&misuse_mutex)
		if len(reason) > 0 do return cstring(raw_data(reason))
		if len(last_open_error) == 0 do return ""
		return cstring(raw_data(last_open_error))
	}
	delete(conn.last)
	conn.last = strings.clone(engine.embed_error(conn.embed))
	if len(conn.last) > 0 do return cstring(raw_data(conn.last))
	// A dead handle has no connection to explain itself, so the reason is the one
	// the misuse path kept.
	sync.lock(&misuse_mutex)
	message := last_misuse
	sync.unlock(&misuse_mutex)
	if len(message) == 0 do return ""
	return cstring(raw_data(message))
}

@(export)
miraidb_exec :: proc "c" (handle: rawptr, sql: cstring) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if sql == nil do return MIRAIDB_ERROR
	err := engine.embed_exec(conn.embed, string(sql))
	if err.kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_backup :: proc "c" (handle: rawptr, path: cstring) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if path == nil do return MIRAIDB_ERROR
	err := engine.embed_backup(conn.embed, string(path))
	if err.kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_prepare :: proc "c" (handle: rawptr, sql: cstring) -> rawptr {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil || sql == nil do return nil
	statement := engine.embed_prepare(conn.embed, string(sql))
	if statement == nil do return nil
	stmt := new(Capi_Statement)
	stmt.conn = conn
	stmt.embed = statement
	conn.statements[rawptr(stmt)] = stmt
	engine.handle_register(rawptr(stmt))
	return rawptr(stmt)
}

@(private)
capi_stmt :: proc(handle: rawptr) -> ^Capi_Statement {
	if !engine.handle_is_live(handle) do return nil
	return cast(^Capi_Statement)handle
}

@(export)
miraidb_finalize :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil {
		set_misuse("statement handle is closed")
		return
	}
	if stmt.conn != nil do delete_key(&stmt.conn.statements, handle)
	engine.handle_forget(handle)
	engine.embed_finalize(stmt.embed)
	free(stmt)
}

@(export)
miraidb_reset :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil {
		set_misuse("statement handle is closed")
		return
	}
	engine.embed_reset(stmt.embed)
}

@(export)
miraidb_bind_null :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	if engine.embed_bind_null(stmt.embed, int(index)).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_int :: proc "c" (handle: rawptr, index: c.int, value: c.longlong) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	if engine.embed_bind_int(stmt.embed, int(index), i64(value)).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_double :: proc "c" (handle: rawptr, index: c.int, value: c.double) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	if engine.embed_bind_float(stmt.embed, int(index), f64(value)).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_text :: proc "c" (handle: rawptr, index: c.int, value: cstring) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	if value == nil do return MIRAIDB_ERROR
	if engine.embed_bind_text(stmt.embed, int(index), string(value)).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_blob :: proc "c" (handle: rawptr, index: c.int, data: rawptr, length: c.int) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	if data == nil && length > 0 do return MIRAIDB_ERROR
	bytes := make([]u8, int(length))
	defer delete(bytes)
	if length > 0 {
		source := ([^]u8)(data)
		for i in 0 ..< int(length) do bytes[i] = source[i]
	}
	if engine.embed_bind_blob(stmt.embed, int(index), bytes).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_step :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	has_row, err := engine.embed_step(stmt.embed)
	if err.kind != .None do return MIRAIDB_ERROR
	return has_row ? MIRAIDB_ROW : MIRAIDB_DONE
}

@(export)
miraidb_changes :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return 0
	return c.int(engine.embed_changes(stmt.embed))
}

@(export)
miraidb_column_count :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return 0
	return c.int(engine.embed_column_count(stmt.embed))
}

@(export)
miraidb_column_name :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return ""
	name := engine.embed_column_name(stmt.embed, int(index))
	if len(name) == 0 do return ""
	return cstring(raw_data(name))
}

@(export)
miraidb_column_type :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return CAPI_NULL
	#partial switch engine.embed_column_type(stmt.embed, int(index)) {
	case .Null:
		return CAPI_NULL
	case .Bool:
		return CAPI_BOOL
	case .Int, .Uint, .Int128, .Uint128:
		return CAPI_INT
	case .Float:
		return CAPI_FLOAT
	case .String:
		return CAPI_TEXT
	case .Bytes:
		return CAPI_BLOB
	}
	return CAPI_OTHER
}

@(export)
miraidb_column_int :: proc "c" (handle: rawptr, index: c.int) -> c.longlong {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return 0
	return c.longlong(engine.embed_column_int(stmt.embed, int(index)))
}

@(export)
miraidb_column_double :: proc "c" (handle: rawptr, index: c.int) -> c.double {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return 0
	return c.double(engine.embed_column_float(stmt.embed, int(index)))
}

@(export)
miraidb_column_text :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return ""
	text := engine.embed_column_text(stmt.embed, int(index))
	if len(text) == 0 do return ""
	return cstring(raw_data(text))
}

@(export)
miraidb_column_bytes :: proc "c" (handle: rawptr, index: c.int, length: ^c.int) -> rawptr {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil {
		if length != nil do length^ = 0
		return nil
	}
	bytes := engine.embed_column_blob(stmt.embed, int(index))
	if length != nil do length^ = c.int(len(bytes))
	if len(bytes) == 0 do return nil
	return raw_data(bytes)
}

@(export)
miraidb_column_is_null :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return 1
	return engine.embed_column_is_null(stmt.embed, int(index)) ? 1 : 0
}

// miraidb_set_row_quota caps how many rows one statement may produce (zero
// removes the cap). It is a property of the connection's session, like SQLite's
// limit API, and nothing about it reaches the log (D23).
@(export)
miraidb_set_row_quota :: proc "c" (handle: rawptr, rows: c.ulonglong) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	engine.store_set_row_quota(conn.embed.store, u64(rows))
	return MIRAIDB_OK
}

// miraidb_set_work_budget caps the work one statement may spend, in the same
// units miraidb_work_used reports (zero removes the cap).
@(export)
miraidb_set_work_budget :: proc "c" (handle: rawptr, units: c.ulonglong) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	engine.store_set_work_budget(conn.embed.store, u64(units))
	return MIRAIDB_OK
}

// miraidb_work_used is what the statements on this connection have spent so far.
@(export)
miraidb_work_used :: proc "c" (handle: rawptr) -> c.ulonglong {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return 0
	return c.ulonglong(engine.store_work_used(conn.embed.store))
}

// miraidb_interrupt asks the statement that is running - on any thread - to stop.
// The next statement starts with a clean flag, the way SQLite's interrupt works,
// so a cancelled statement does not poison the connection (SQLITE_INTERRUPT in
// the sqlite3 face). A call with a dead handle is misuse and does nothing.
@(export)
miraidb_interrupt :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	engine.store_cancel(conn.embed.store)
	return MIRAIDB_OK
}

@(export)
miraidb_version :: proc "c" () -> cstring {
	context = runtime.default_context()
	return "miraidb 0.15"
}
