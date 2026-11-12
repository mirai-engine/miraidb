package sqlite_compat

// A `sqlite3_*` facade over the engine's embedding API.
//
// Build it as a shared library and link a program that expects SQLite:
//
//	odin build src/sqlite_compat -build-mode:shared -out:libsqlite3_miraidb.dll
//
// Opening a SQLite file imports it into memory (writes do not reach the file);
// opening any other path creates an engine database directory, which persists.
// The covered subset is the classic prepare/bind/step/column loop plus exec,
// errmsg, changes and libversion.

import "base:runtime"
import "core:c"
import "core:strings"

import engine "../engine"

SQLITE_OK :: c.int(0)
SQLITE_ERROR :: c.int(1)
SQLITE_MISUSE :: c.int(21)
SQLITE_ROW :: c.int(100)
SQLITE_DONE :: c.int(101)

SQLITE_INTEGER :: c.int(1)
SQLITE_FLOAT :: c.int(2)
SQLITE_TEXT :: c.int(3)
SQLITE_BLOB :: c.int(4)
SQLITE_NULL :: c.int(5)

Database :: struct {
	conn:         ^engine.Embed_Conn,
	last_changes: c.int,
	last_error:   string, // owned, NUL-terminated
	in_memory:    bool,
}

Statement :: struct {
	db:   ^Database,
	stmt: ^engine.Embed_Statement,
}

@(private)
db_of :: proc(handle: rawptr) -> ^Database {
	return cast(^Database)handle
}

@(private)
stmt_of :: proc(handle: rawptr) -> ^Statement {
	return cast(^Statement)handle
}

// Blob is an open handle on one BLOB column of one row. Reads and writes touch
// a copy; a dirty handle writes it back when it closes, the way SQLite does.
Blob :: struct {
	db:     ^Database,
	table:  string,
	column: string,
	key:    string,
	row_id: i64,
	data:   []u8,
	dirty:  bool,
}

@(private)
blob_of :: proc(handle: rawptr) -> ^Blob {
	return cast(^Blob)handle
}

// blob_key_column resolves the column that names a row: a single-column
// primary key plays the part of SQLite's rowid, which is what iRow carries.
@(private)
blob_key_column :: proc(db: ^Database, table_name: string) -> (column: string, ok: bool) {
	store := db.conn.store
	if store == nil do return "", false
	tx := engine.tx_begin_read(store)
	defer engine.tx_end(tx)
	table, table_err := engine.tx_table(tx, table_name)
	if table_err.kind != .None do return "", false
	if len(table.schema.primary_key) != 1 do return "", false
	position := table.schema.primary_key[0]
	if position < 0 || position >= len(table.schema.columns) do return "", false
	return table.schema.columns[position].name, true
}

@(private)
set_error :: proc(db: ^Database, text: string) {
	if db == nil do return
	delete(db.last_error)
	db.last_error = strings.clone(text)
}

@(export)
sqlite3_open :: proc "c" (filename: cstring, ppDb: ^rawptr) -> c.int {
	context = runtime.default_context()
	context = runtime.default_context()
	if ppDb == nil do return SQLITE_MISUSE
	if filename == nil {
		ppDb^ = nil
		return SQLITE_MISUSE
	}
	path := string(filename)
	in_memory := engine.sqlite_is_file(path)
	conn, err := engine.embed_open(path)
	if err.kind != .None {
		ppDb^ = nil
		return SQLITE_ERROR
	}
	db := new(Database)
	db.conn = conn
	db.in_memory = in_memory
	ppDb^ = rawptr(db)
	return SQLITE_OK
}

@(export)
sqlite3_open_v2 :: proc "c" (filename: cstring, ppDb: ^rawptr, flags: c.int, vfs: cstring) -> c.int {
	context = runtime.default_context()
	_ = flags
	_ = vfs
	return sqlite3_open(filename, ppDb)
}

@(export)
sqlite3_close :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_OK
	engine.embed_close(db.conn)
	delete(db.last_error)
	free(db)
	return SQLITE_OK
}

@(export)
sqlite3_errmsg :: proc "c" (handle: rawptr) -> cstring {
	context = runtime.default_context()
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return "no connection"
	delete(db.last_error)
	db.last_error = strings.clone(engine.embed_error(db.conn))
	if len(db.last_error) == 0 do return ""
	return cstring(raw_data(db.last_error))
}

@(export)
sqlite3_errcode :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_ERROR
	return len(engine.embed_error(db.conn)) > 0 ? SQLITE_ERROR : SQLITE_OK
}

@(export)
sqlite3_changes :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return 0
	return db.last_changes
}

@(export)
sqlite3_total_changes :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	return sqlite3_changes(handle)
}

@(export)
sqlite3_exec :: proc "c" (handle: rawptr, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int {
	context = runtime.default_context()
	context = runtime.default_context()
	_ = callback
	_ = arg
	if errmsg != nil do errmsg^ = nil
	db := db_of(handle)
	if db == nil || sql == nil do return SQLITE_MISUSE
	if err := engine.embed_exec(db.conn, string(sql)); err.kind != .None {
		set_error(db, err.message)
		return SQLITE_ERROR
	}
	return SQLITE_OK
}

@(export)
sqlite3_prepare_v2 :: proc "c" (handle: rawptr, sql: cstring, nByte: c.int, ppStmt: ^rawptr, pzTail: ^cstring) -> c.int {
	context = runtime.default_context()
	context = runtime.default_context()
	_ = nByte
	if pzTail != nil do pzTail^ = nil
	if ppStmt != nil do ppStmt^ = nil
	db := db_of(handle)
	if db == nil || sql == nil || ppStmt == nil do return SQLITE_MISUSE
	statement := engine.embed_prepare(db.conn, string(sql))
	if statement == nil do return SQLITE_ERROR
	stmt := new(Statement)
	stmt.db = db
	stmt.stmt = statement
	ppStmt^ = rawptr(stmt)
	return SQLITE_OK
}

@(export)
sqlite3_finalize :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_OK
	if stmt.db != nil do stmt.db.last_changes = c.int(engine.embed_changes(stmt.stmt))
	engine.embed_finalize(stmt.stmt)
	free(stmt)
	return SQLITE_OK
}

@(export)
sqlite3_reset :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_OK
	engine.embed_reset(stmt.stmt)
	return SQLITE_OK
}

@(export)
sqlite3_clear_bindings :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_OK
	engine.embed_clear_bindings(stmt.stmt)
	return SQLITE_OK
}

@(export)
sqlite3_bind_null :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if engine.embed_bind_null(stmt.stmt, int(index) - 1).kind == .None do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_int :: proc "c" (handle: rawptr, index: c.int, value: c.int) -> c.int {
	context = runtime.default_context()
	return sqlite3_bind_int64(handle, index, c.longlong(value))
}

@(export)
sqlite3_bind_int64 :: proc "c" (handle: rawptr, index: c.int, value: c.longlong) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if engine.embed_bind_int(stmt.stmt, int(index) - 1, i64(value)).kind == .None do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_double :: proc "c" (handle: rawptr, index: c.int, value: c.double) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if engine.embed_bind_float(stmt.stmt, int(index) - 1, f64(value)).kind == .None do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_text :: proc "c" (handle: rawptr, index: c.int, value: cstring, length: c.int, destructor: rawptr) -> c.int {
	context = runtime.default_context()
	context = runtime.default_context()
	_ = length
	_ = destructor
	stmt := stmt_of(handle)
	if stmt == nil || value == nil do return SQLITE_MISUSE
	if engine.embed_bind_text(stmt.stmt, int(index) - 1, string(value)).kind == .None do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_blob :: proc "c" (handle: rawptr, index: c.int, data: rawptr, length: c.int, destructor: rawptr) -> c.int {
	context = runtime.default_context()
	context = runtime.default_context()
	_ = destructor
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if data == nil || length <= 0 {
		if engine.embed_bind_null(stmt.stmt, int(index) - 1).kind == .None do return SQLITE_OK
		return SQLITE_ERROR
	}
	bytes := make([]u8, int(length))
	defer delete(bytes)
	source := ([^]u8)(data)
	for i in 0 ..< int(length) do bytes[i] = source[i]
	if engine.embed_bind_blob(stmt.stmt, int(index) - 1, bytes).kind == .None do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_step :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	has_row, err := engine.embed_step(stmt.stmt)
	if err.kind != .None {
		set_error(stmt.db, err.message)
		return SQLITE_ERROR
	}
	if has_row do return SQLITE_ROW
	if stmt.db != nil do stmt.db.last_changes = c.int(engine.embed_changes(stmt.stmt))
	return SQLITE_DONE
}

@(export)
sqlite3_column_count :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return c.int(engine.embed_column_count(stmt.stmt))
}

@(export)
sqlite3_column_name :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return ""
	name := engine.embed_column_name(stmt.stmt, int(index))
	if len(name) == 0 do return ""
	return cstring(raw_data(name))
}

@(export)
sqlite3_column_type :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_NULL
	#partial switch engine.embed_column_type(stmt.stmt, int(index)) {
	case .Null:
		return SQLITE_NULL
	case .Int, .Uint, .Int128, .Uint128, .Bool:
		return SQLITE_INTEGER
	case .Float:
		return SQLITE_FLOAT
	case .Bytes:
		return SQLITE_BLOB
	}
	return SQLITE_TEXT
}

@(export)
sqlite3_column_int :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	return c.int(sqlite3_column_int64(handle, index))
}

@(export)
sqlite3_column_int64 :: proc "c" (handle: rawptr, index: c.int) -> c.longlong {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return c.longlong(engine.embed_column_int(stmt.stmt, int(index)))
}

@(export)
sqlite3_column_double :: proc "c" (handle: rawptr, index: c.int) -> c.double {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return c.double(engine.embed_column_float(stmt.stmt, int(index)))
}

@(export)
sqlite3_column_text :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return ""
	text := engine.embed_column_text(stmt.stmt, int(index))
	if len(text) == 0 do return ""
	return cstring(raw_data(text))
}

@(export)
sqlite3_column_blob :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	bytes := engine.embed_column_blob(stmt.stmt, int(index))
	if len(bytes) == 0 do return nil
	return raw_data(bytes)
}

@(export)
sqlite3_column_bytes :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return c.int(len(engine.embed_column_blob(stmt.stmt, int(index))))
}

@(export)
sqlite3_column_bytes16 :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	return sqlite3_column_bytes(handle, index)
}

@(export)
sqlite3_free :: proc "c" (pointer: rawptr) {
	context = runtime.default_context()
	_ = pointer
}

@(export)
sqlite3_libversion :: proc "c" () -> cstring {
	context = runtime.default_context()
	return "3.45.0-miraidb"
}

@(export)
sqlite3_initialize :: proc "c" () -> c.int {
	context = runtime.default_context()
	return SQLITE_OK
}

@(export)
sqlite3_shutdown :: proc "c" () -> c.int {
	context = runtime.default_context()
	return SQLITE_OK
}

@(export)
sqlite3_busy_timeout :: proc "c" (handle: rawptr, milliseconds: c.int) -> c.int {
	context = runtime.default_context()
	_ = handle
	_ = milliseconds
	return SQLITE_OK
}

@(export)
sqlite3_extended_result_codes :: proc "c" (handle: rawptr, onoff: c.int) -> c.int {
	context = runtime.default_context()
	_ = handle
	_ = onoff
	return SQLITE_OK
}


// --- Incremental BLOB I/O --------------------------------------------------

SQLITE_READONLY :: c.int(8)

@(export)
sqlite3_blob_open :: proc "c" (
	handle: rawptr,
	zDb: cstring,
	zTable: cstring,
	zColumn: cstring,
	iRow: c.longlong,
	flags: c.int,
	ppBlob: ^rawptr,
) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil || ppBlob == nil || zTable == nil || zColumn == nil do return SQLITE_MISUSE
	ppBlob^ = nil
	table_name := string(zTable)
	column_name := string(zColumn)
	key_column, key_ok := blob_key_column(db, table_name)
	if !key_ok {
		set_error(db, "sqlite3_blob_open needs a table with a single-column primary key")
		return SQLITE_ERROR
	}
	query := strings.concatenate({"SELECT ", column_name, " FROM ", table_name, " WHERE ", key_column, " = ?"})
	defer delete(query)
	stmt := engine.embed_prepare(db.conn, query)
	if stmt == nil do return SQLITE_ERROR
	defer engine.embed_finalize(stmt)
	if err := engine.embed_bind_int(stmt, 0, i64(iRow)); err.kind != .None {
		set_error(db, err.message)
		return SQLITE_ERROR
	}
	has_row, step_err := engine.embed_step(stmt)
	if step_err.kind != .None {
		set_error(db, step_err.message)
		return SQLITE_ERROR
	}
	if !has_row {
		set_error(db, "no such row")
		return SQLITE_ERROR
	}
	value, column_ok := engine.embed_column_value(stmt, 0)
	if !column_ok do return SQLITE_ERROR
	blob := new(Blob)
	blob.db = db
	blob.table = strings.clone(table_name)
	blob.column = strings.clone(column_name)
	blob.key = strings.clone(key_column)
	blob.row_id = i64(iRow)
	switch value.kind {
	case .Bytes:
		blob.data = make([]u8, len(value.bytes))
		copy(blob.data, value.bytes)
	case .String:
		blob.data = make([]u8, len(value.s))
		copy(blob.data, value.s)
	case .Null, .Default, .Bool, .Int, .Uint, .Float, .Timestamp, .Uuid, .Array, .Product, .Int128, .Uint128, .Duration, .Identity, .Connection:
	}
	ppBlob^ = rawptr(blob)
	return SQLITE_OK
}

@(export)
sqlite3_blob_bytes :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil do return 0
	return c.int(len(blob.data))
}

@(export)
sqlite3_blob_read :: proc "c" (handle: rawptr, buffer: rawptr, count: c.int, offset: c.int) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil || buffer == nil do return SQLITE_MISUSE
	if count < 0 || offset < 0 do return SQLITE_ERROR
	if int(offset) + int(count) > len(blob.data) {
		set_error(blob.db, "read past the end of the blob")
		return SQLITE_ERROR
	}
	target := ([^]u8)(buffer)
	for i in 0 ..< int(count) do target[i] = blob.data[int(offset) + i]
	return SQLITE_OK
}

@(export)
sqlite3_blob_write :: proc "c" (handle: rawptr, buffer: rawptr, count: c.int, offset: c.int) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil || buffer == nil do return SQLITE_MISUSE
	if count < 0 || offset < 0 do return SQLITE_ERROR
	// The size comes from the row: a write cannot grow the blob, matching
	// SQLite's contract that growth goes through zeroblob and a full rewrite.
	if int(offset) + int(count) > len(blob.data) {
		set_error(blob.db, "write past the end of the blob")
		return SQLITE_ERROR
	}
	source := ([^]u8)(buffer)
	for i in 0 ..< int(count) do blob.data[int(offset) + i] = source[i]
	blob.dirty = true
	return SQLITE_OK
}

@(export)
sqlite3_blob_close :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil do return SQLITE_MISUSE
	result := SQLITE_OK
	if blob.dirty {
		update := strings.concatenate({"UPDATE ", blob.table, " SET ", blob.column, " = ? WHERE ", blob.key, " = ?"})
		defer delete(update)
		stmt := engine.embed_prepare(blob.db.conn, update)
		if stmt == nil {
			result = SQLITE_ERROR
		} else {
			defer engine.embed_finalize(stmt)
			_ = engine.embed_bind_blob(stmt, 0, blob.data)
			_ = engine.embed_bind_int(stmt, 1, blob.row_id)
			if _, step_err := engine.embed_step(stmt); step_err.kind != .None {
				set_error(blob.db, step_err.message)
				result = SQLITE_ERROR
			}
		}
	}
	delete(blob.data)
	delete(blob.table)
	delete(blob.column)
	delete(blob.key)
	free(blob)
	return result
}

@(export)
sqlite3_blob_reopen :: proc "c" (handle: rawptr, iRow: c.longlong) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil do return SQLITE_MISUSE
	query := strings.concatenate({"SELECT ", blob.column, " FROM ", blob.table, " WHERE ", blob.key, " = ?"})
	defer delete(query)
	stmt := engine.embed_prepare(blob.db.conn, query)
	if stmt == nil do return SQLITE_ERROR
	defer engine.embed_finalize(stmt)
	_ = engine.embed_bind_int(stmt, 0, i64(iRow))
	has_row, step_err := engine.embed_step(stmt)
	if step_err.kind != .None || !has_row {
		if step_err.kind != .None do set_error(blob.db, step_err.message)
		return SQLITE_ERROR
	}
	value, column_ok := engine.embed_column_value(stmt, 0)
	if !column_ok do return SQLITE_ERROR
	delete(blob.data)
	blob.data = nil
	switch value.kind {
	case .Bytes:
		blob.data = make([]u8, len(value.bytes))
		copy(blob.data, value.bytes)
	case .String:
		blob.data = make([]u8, len(value.s))
		copy(blob.data, value.s)
	case .Null, .Default, .Bool, .Int, .Uint, .Float, .Timestamp, .Uuid, .Array, .Product, .Int128, .Uint128, .Duration, .Identity, .Connection:
	}
	blob.row_id = i64(iRow)
	blob.dirty = false
	return SQLITE_OK
}
