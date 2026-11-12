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

import engine "../engine"

MIRAIDB_OK :: c.int(0)
MIRAIDB_ERROR :: c.int(1)
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
}

Capi_Statement :: struct {
	conn:  ^Capi_Connection,
	embed: ^engine.Embed_Statement,
}

@(export)
miraidb_open :: proc "c" (path: cstring) -> rawptr {
	context = runtime.default_context()
	if path == nil do return nil
	conn, err := engine.embed_open(string(path))
	if err.kind != .None {
		if conn != nil do engine.embed_close(conn)
		return nil
	}
	handle := new(Capi_Connection)
	handle.embed = conn
	return rawptr(handle)
}

@(private)
capi_conn :: proc(handle: rawptr) -> ^Capi_Connection {
	return cast(^Capi_Connection)handle
}

@(export)
miraidb_close :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return
	engine.embed_close(conn.embed)
	delete(conn.last)
	free(conn)
}

@(export)
miraidb_errmsg :: proc "c" (handle: rawptr) -> cstring {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return "no connection"
	delete(conn.last)
	conn.last = strings.clone(engine.embed_error(conn.embed))
	if len(conn.last) == 0 do return ""
	return cstring(raw_data(conn.last))
}

@(export)
miraidb_exec :: proc "c" (handle: rawptr, sql: cstring) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil || sql == nil do return MIRAIDB_ERROR
	err := engine.embed_exec(conn.embed, string(sql))
	if err.kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_backup :: proc "c" (handle: rawptr, path: cstring) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil || path == nil do return MIRAIDB_ERROR
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
	return rawptr(stmt)
}

@(private)
capi_stmt :: proc(handle: rawptr) -> ^Capi_Statement {
	return cast(^Capi_Statement)handle
}

@(export)
miraidb_finalize :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return
	engine.embed_finalize(stmt.embed)
	free(stmt)
}

@(export)
miraidb_reset :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return
	engine.embed_reset(stmt.embed)
}

@(export)
miraidb_bind_null :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_ERROR
	if engine.embed_bind_null(stmt.embed, int(index)).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_int :: proc "c" (handle: rawptr, index: c.int, value: c.longlong) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_ERROR
	if engine.embed_bind_int(stmt.embed, int(index), i64(value)).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_double :: proc "c" (handle: rawptr, index: c.int, value: c.double) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_ERROR
	if engine.embed_bind_float(stmt.embed, int(index), f64(value)).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_text :: proc "c" (handle: rawptr, index: c.int, value: cstring) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil || value == nil do return MIRAIDB_ERROR
	if engine.embed_bind_text(stmt.embed, int(index), string(value)).kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_blob :: proc "c" (handle: rawptr, index: c.int, data: rawptr, length: c.int) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil || (data == nil && length > 0) do return MIRAIDB_ERROR
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
	if stmt == nil do return MIRAIDB_ERROR
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

@(export)
miraidb_version :: proc "c" () -> cstring {
	context = runtime.default_context()
	return "miraidb 0.15"
}
