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

// Open flags for miraidb_open_ex. They are bits so a caller can ask for more than
// one, and the plain miraidb_open is miraidb_open_ex(path, 0).
MIRAIDB_OPEN_READ_ONLY :: c.int(1 << 0)
MIRAIDB_OPEN_IN_MEMORY :: c.int(1 << 1)
MIRAIDB_OPEN_NO_SYNC :: c.int(1 << 2)
MIRAIDB_OPEN_PAGED :: c.int(1 << 3)

MIRAIDB_OK :: c.int(0)
MIRAIDB_ERROR :: c.int(1)
// MIRAIDB_MISUSE is the answer to a handle that is not live: a statement used
// after finalize, or anything used through a connection already closed. The call
// does nothing and the process keeps running (D29).
MIRAIDB_MISUSE :: c.int(2)
// MIRAIDB_DENIED is the answer to a token that is unknown or expired. The
// identity of the connection is left unchanged, so a caller that ignores the code
// still cannot become somebody else by accident.
MIRAIDB_DENIED :: c.int(3)
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

// Capi_Value is one value crossing the C boundary: a tag, an integer, a real and a
// borrowed buffer. It matches `miraidb_value` in include/miraidb.h field by field.
Capi_Value :: struct {
	type:   c.int,
	i:      c.longlong,
	f:      c.double,
	bytes:  rawptr,
	nbytes: c.int,
}

Capi_Function_Callback :: #type proc "c" (
	user:   rawptr,
	args:   [^]Capi_Value,
	argc:   c.int,
	result: ^Capi_Value,
) -> c.int

@(private)
Capi_Function :: struct {
	callback: Capi_Function_Callback,
	user:     rawptr,
}

// Capi_Collation_Callback compares two texts and answers negative, zero or
// positive. The byte ranges are valid for the duration of the call only.
Capi_Collation_Callback :: #type proc "c" (
	user:    rawptr,
	a:       [^]u8,
	a_length: c.int,
	b:       [^]u8,
	b_length: c.int,
) -> c.int

// Capi_Collation is one registered comparison. `block` is the heap block the two
// slices point into, so the name the store cloned is independent of it.
@(private)
Capi_Collation :: struct {
	callback: Capi_Collation_Callback,
	user:     rawptr,
	// name is the registration's key, owned here so a close can drop the entry
	// before the trampoline it points at goes away.
	name:     string,
}

Capi_Connection :: struct {
	embed:   ^engine.Embed_Conn,
	last:    string, // owned, NUL-terminated
	changes: c.int,
	// statements is what this connection handed out and has not finalized, so a
	// close can make every one of them misuse instead of leaving them dangling.
	statements: map[rawptr]^Capi_Statement,
	// functions are the per-registration trampolines, freed with the connection:
	// the store holds the user pointer they carry, not their lifetime. The same is
	// true of `collations`, and closing the connection unregisters both.
	functions:  [dynamic]^Capi_Function,
	collations: [dynamic]^Capi_Collation,
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
	return miraidb_open_ex(path, 0)
}

// miraidb_open_ex opens with flags: a reader instead of a writer, an in-memory
// database that leaves nothing behind, a log that never fsyncs, or page files for
// new tables. A path that is already a SQLite file is imported into memory and
// mirrored back on every commit, whatever the flags say; that is stated in
// include/miraidb.h because it is the one surprising part of opening.
@(export)
miraidb_open_ex :: proc "c" (path: cstring, flags: c.int) -> rawptr {
	context = runtime.default_context()
	if path == nil do return nil
	options := engine.Store_Options {
		persistent = flags & MIRAIDB_OPEN_IN_MEMORY == 0,
		create     = flags & MIRAIDB_OPEN_READ_ONLY == 0,
		durable    = flags & MIRAIDB_OPEN_NO_SYNC == 0,
		read_only  = flags & MIRAIDB_OPEN_READ_ONLY != 0,
		paged_tables = flags & MIRAIDB_OPEN_PAGED != 0,
	}
	conn, err := engine.embed_open(string(path), options)
	if err.kind != .None {
		if conn != nil do engine.embed_close(conn)
		// The message moves into last_open_error: the error is ours to keep.
		delete(last_open_error)
		last_open_error = err.message
		return nil
	}
	delete(last_open_error)
	last_open_error = ""
	handle := new(Capi_Connection)
	handle.embed = conn
	handle.statements = make(map[rawptr]^Capi_Statement)
	handle.functions = make([dynamic]^Capi_Function)
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
	for function in conn.functions do free(function)
	delete(conn.functions)
	// A comparison is dropped before its trampoline: the store would otherwise hold
	// a user pointer into memory this close is about to free.
	for collation in conn.collations {
		engine.store_unregister_collation(conn.embed.store, collation.name)
		delete(collation.name)
		free(collation)
	}
	delete(conn.collations)
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
	defer engine.error_free(&err)
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
	defer engine.error_free(&err)
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
	if !engine.error_drop(engine.embed_bind_null(stmt.embed, int(index))) do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_int :: proc "c" (handle: rawptr, index: c.int, value: c.longlong) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	if !engine.error_drop(engine.embed_bind_int(stmt.embed, int(index), i64(value))) do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_double :: proc "c" (handle: rawptr, index: c.int, value: c.double) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	if !engine.error_drop(engine.embed_bind_float(stmt.embed, int(index), f64(value))) do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_bind_text :: proc "c" (handle: rawptr, index: c.int, value: cstring) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	if value == nil do return MIRAIDB_ERROR
	if !engine.error_drop(engine.embed_bind_text(stmt.embed, int(index), string(value))) do return MIRAIDB_ERROR
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
	if !engine.error_drop(engine.embed_bind_blob(stmt.embed, int(index), bytes)) do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

@(export)
miraidb_step :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := capi_stmt(handle)
	if stmt == nil do return MIRAIDB_MISUSE
	has_row, err := engine.embed_step(stmt.embed)
	defer engine.error_free(&err)
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

// capi_value_of lays an engine value out for a callback. Text and blobs are
// borrowed: they live until the statement moves on, which is after the callback.
@(private)
capi_value_of :: proc(value: engine.Value) -> Capi_Value {
	out := Capi_Value{}
	#partial switch value.kind {
	case .Null:
		out.type = CAPI_NULL
	case .Bool:
		out.type = CAPI_BOOL
		out.i = value.b ? 1 : 0
	case .Int, .Uint, .Timestamp, .Duration, .Connection:
		out.type = CAPI_INT
		if number, ok := engine.value_to_i64(value); ok do out.i = c.longlong(number)
	case .Float:
		out.type = CAPI_FLOAT
		out.f = c.double(value.f)
	case .String:
		out.type = CAPI_TEXT
		out.bytes = rawptr(raw_data(value.s))
		out.nbytes = c.int(len(value.s))
	case .Bytes:
		out.type = CAPI_BLOB
		out.bytes = rawptr(raw_data(value.bytes))
		out.nbytes = c.int(len(value.bytes))
	case:
		// An IDENTITY, a UUID or a product has no C shape here; the callback sees
		// MIRAIDB_OTHER and can refuse or ignore it.
		out.type = CAPI_OTHER
	}
	return out
}

// engine_value_of is the other direction: what a callback returned, copied so the
// value outlives the callback's own buffer.
@(private)
engine_value_of :: proc(value: Capi_Value) -> (engine.Value, engine.Error) {
	switch value.type {
	case CAPI_NULL:
		return engine.value_null(), engine.ERROR_NONE
	case CAPI_BOOL:
		return engine.value_bool(value.i != 0), engine.ERROR_NONE
	case CAPI_INT:
		return engine.value_int(i64(value.i)), engine.ERROR_NONE
	case CAPI_FLOAT:
		return engine.value_float(f64(value.f)), engine.ERROR_NONE
	case CAPI_TEXT:
		if value.bytes == nil || value.nbytes <= 0 do return engine.value_string(""), engine.ERROR_NONE
		text := make([]u8, int(value.nbytes))
		copy(text, (cast([^]u8)value.bytes)[:int(value.nbytes)])
		return engine.value_string(string(text)), engine.ERROR_NONE
	case CAPI_BLOB:
		if value.bytes == nil || value.nbytes <= 0 do return engine.value_bytes(nil), engine.ERROR_NONE
		data := make([]u8, int(value.nbytes))
		copy(data, (cast([^]u8)value.bytes)[:int(value.nbytes)])
		return engine.value_bytes(data), engine.ERROR_NONE
	}
	return {}, engine.errf(engine.Error_Kind.Invalid_Type, "a host function cannot return MIRAIDB_OTHER")
}

@(private)
capi_function_call :: proc(args: []engine.Value, user: rawptr) -> (engine.Value, engine.Error) {
	entry := cast(^Capi_Function)user
	if entry == nil do return {}, engine.errf(engine.Error_Kind.Internal, "host function has no entry")
	cvalues := make([]Capi_Value, len(args))
	defer delete(cvalues)
	for value, i in args do cvalues[i] = capi_value_of(value)
	result := Capi_Value{type = CAPI_NULL}
	status := entry.callback(entry.user, raw_data(cvalues), c.int(len(cvalues)), &result)
	if status != MIRAIDB_OK {
		return {}, engine.errf(engine.Error_Kind.Invalid_Argument, "host function returned %d", status)
	}
	return engine_value_of(result)
}

// miraidb_create_function makes a C callback callable from SQL. The name is
// registered case-insensitively and cannot replace a builtin, because the builtins
// answer first. Registrations last until the connection closes and are not part of
// the database.
@(export)
miraidb_create_function :: proc "c" (
	handle: rawptr,
	name: cstring,
	arity: c.int,
	callback: Capi_Function_Callback,
	user: rawptr,
) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if name == nil || callback == nil do return MIRAIDB_ERROR
	if arity < -1 do return MIRAIDB_ERROR
	entry := new(Capi_Function)
	entry.callback = callback
	entry.user = user
	err := engine.store_register_function(
		conn.embed.store,
		string(name),
		int(arity),
		capi_function_call,
		rawptr(entry),
	)
	defer engine.error_free(&err)
	if err.kind != .None {
		free(entry)
		return MIRAIDB_ERROR
	}
	append(&conn.functions, entry)
	return MIRAIDB_OK
}

// capi_collation_call adapts a C comparison to the engine's. The engine hands it
// two strings, which are valid while it compares them: the callback gets the bytes
// and lengths, and a nil pointer for an empty text, which is what a C callback
// expects for a zero length.
@(private)
capi_collation_call :: proc(a: string, b: string, user: rawptr) -> int {
	collation := (^Capi_Collation)(user)
	if collation == nil || collation.callback == nil do return 0
	a_bytes: [^]u8
	b_bytes: [^]u8
	if len(a) > 0 do a_bytes = raw_data(a)
	if len(b) > 0 do b_bytes = raw_data(b)
	return int(
		collation.callback(
			collation.user,
			a_bytes,
			c.int(len(a)),
			b_bytes,
			c.int(len(b)),
		),
	)
}

// miraidb_create_collation registers a comparison SQL can name: `WHERE name =
// 'x' COLLATE spanish`. The name is case-insensitive and cannot be one of the three
// built in (BINARY, NOCASE, RTRIM), and registering the same name again replaces
// it. A host comparison cannot fold a text into an index key, so a column
// declaration, an index, an ORDER BY, GROUP BY or DISTINCT that names it is
// refused with a message rather than answered in the wrong order. Registrations
// last until the connection closes and are not part of the database.
@(export)
miraidb_create_collation :: proc "c" (
	handle: rawptr,
	name: cstring,
	callback: Capi_Collation_Callback,
	user: rawptr,
) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if name == nil || callback == nil do return MIRAIDB_ERROR
	entry := new(Capi_Collation)
	entry.callback = callback
	entry.user = user
	entry.name = strings.clone(string(name))
	err := engine.store_register_collation(conn.embed.store, string(name), capi_collation_call, rawptr(entry))
	defer engine.error_free(&err)
	if err.kind != .None {
		free(entry)
		return MIRAIDB_ERROR
	}
	append(&conn.collations, entry)
	return MIRAIDB_OK
}

// miraidb_unregister_collation drops one. It answers MIRAIDB_OK when one was
// there and MIRAIDB_ERROR when the name was not registered.
@(export)
miraidb_unregister_collation :: proc "c" (handle: rawptr, name: cstring) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if name == nil do return MIRAIDB_ERROR
	if !engine.store_unregister_collation(conn.embed.store, string(name)) do return MIRAIDB_ERROR
	// The trampoline this name pointed at is ours to free, and dropping it twice
	// would leak it: forget it here.
	for collation, i in conn.collations {
		if strings.equal_fold(collation.name, string(name)) {
			unordered_remove(&conn.collations, i)
			delete(collation.name)
			free(collation)
			break
		}
	}
	return MIRAIDB_OK
}

// miraidb_set_identity makes `identity` the caller row policies see. The bytes are
// the 32 of an IDENTITY column value, the same shape a token names; a NULL pointer
// is an error. A connection that never calls this carries the all-zero identity,
// so a policy comparing against current_identity() matches nothing: that is what
// the server does before a client authenticates, and the embedded path is the same
// path, not a privileged one.
@(export)
miraidb_set_identity :: proc "c" (handle: rawptr, identity: rawptr) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if identity == nil do return MIRAIDB_ERROR
	bytes := cast(^[32]u8)identity
	engine.embed_set_identity(conn.embed, engine.Identity(bytes^))
	return MIRAIDB_OK
}

// miraidb_identity copies the identity the policies see into `out` (32 bytes) and
// returns the number of bytes written, or MIRAIDB_MISUSE for a dead handle.
@(export)
miraidb_identity :: proc "c" (handle: rawptr, out: rawptr) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if out == nil do return MIRAIDB_ERROR
	identity := engine.embed_identity(conn.embed)
	bytes := cast(^[32]u8)out
	bytes^ = cast([32]u8)identity
	return 32
}

// miraidb_authenticate resolves a token and, when it is live, makes its identity
// the caller's. It answers MIRAIDB_OK, MIRAIDB_DENIED for an unknown or expired
// token (miraidb_errmsg says which), or MIRAIDB_MISUSE for a dead handle.
@(export)
miraidb_authenticate :: proc "c" (handle: rawptr, token: cstring) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if token == nil do return MIRAIDB_ERROR
	err := engine.embed_authenticate(conn.embed, string(token))
	defer engine.error_free(&err)
	if err.kind == .Permission_Denied do return MIRAIDB_DENIED
	if err.kind != .None do return MIRAIDB_ERROR
	return MIRAIDB_OK
}

// miraidb_issue_token writes a credential for `identity` into `out` as text, never
// more than `out_len` bytes including the NUL, and returns its length or -1 when
// the buffer is too small. A token is 67 characters; a caller that passes 68 or
// more always succeeds. TTL is in microseconds and zero means it never expires.
@(export)
miraidb_issue_token :: proc "c" (handle: rawptr, identity: rawptr, ttl_us: c.longlong, out: cstring, out_len: c.ulonglong) -> c.int {
	context = runtime.default_context()
	conn := capi_conn(handle)
	if conn == nil do return MIRAIDB_MISUSE
	if identity == nil || out == nil do return MIRAIDB_ERROR
	bytes := cast(^[32]u8)identity
	token, err := engine.embed_issue_token(conn.embed, engine.Identity(bytes^), i64(ttl_us))
	defer delete(token)
	defer engine.error_free(&err)
	if err.kind != .None do return MIRAIDB_ERROR
	needed := u64(len(token)) + 1
	if out_len < needed do return -1
	buffer := cast([^]u8)out
	for i in 0 ..< len(token) do buffer[i] = token[i]
	buffer[len(token)] = 0
	return c.int(len(token))
}

@(export)
miraidb_version :: proc "c" () -> cstring {
	context = runtime.default_context()
	return engine.ENGINE_VERSION_TEXT
}
