package sqlite_compat

// The rest of what SQLite's own command-line shell (shell.c, 3.54) links:
// values handed between statements and functions, the library and connection
// status and control entry points, the keyword list, the VFS registry, a
// connection's client data, sqlite3_stmt_explain, the column metadata, random
// bytes and the Windows text helper. Each answers as SQLite does where the
// engine has the answer, and where it has none (a VFS's files, page-cache
// statistics) it answers what SQLite answers for a library that does not keep
// them: zero counters, SQLITE_NOTFOUND for a file control it does not know.

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:crypto"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import engine "../engine"


// --- Values ----------------------------------------------------------------

// sqlite3_bind_value binds a copy of a value, by its type, as SQLite does.
@(export)
sqlite3_bind_value :: proc "c" (handle: rawptr, index: c.int, value: rawptr) -> c.int {
	context = runtime.default_context()
	switch sqlite3_value_type(value) {
	case SQLITE_INTEGER:
		return sqlite3_bind_int64(handle, index, sqlite3_value_int64(value))
	case SQLITE_FLOAT:
		return sqlite3_bind_double(handle, index, sqlite3_value_double(value))
	case SQLITE_TEXT:
		return sqlite3_bind_text(handle, index, sqlite3_value_text(value), sqlite3_value_bytes(value), SQLITE_TRANSIENT_POINTER)
	case SQLITE_BLOB:
		return sqlite3_bind_blob(handle, index, sqlite3_value_blob(value), sqlite3_value_bytes(value), SQLITE_TRANSIENT_POINTER)
	}
	return sqlite3_bind_null(handle, index)
}

// SQLITE_TRANSIENT is the destructor (void(*)(void*))-1: copy now.
@(private)
SQLITE_TRANSIENT_POINTER :: rawptr(~uintptr(0))

// sqlite3_column_value is the column as a value object, valid until the
// statement steps, resets or is finalized (an unprotected value).
@(export)
sqlite3_column_value :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	value, ok := engine.embed_column_value(stmt.stmt, int(index))
	if !ok do return nil
	box := new(Value_Box)
	box.value = engine.value_clone(value, context.allocator)
	append(&stmt.value_cache, box)
	return rawptr(box)
}

@(private)
stmt_clear_value_cache :: proc(stmt: ^Statement) {
	for box in stmt.value_cache {
		engine.value_deep_free(box.value, context.allocator)
		delete(box.text)
		delete(box.text16)
		free(box)
	}
	clear(&stmt.value_cache)
}

SQLITE_COPY :: c.int(0)
SQLITE_XFER :: c.int(1)
SQLITE_FINISH :: c.int(2)

// sqlite3_result_str makes a builder's text the function's result: copied
// (SQLITE_COPY), taken with the builder emptied (SQLITE_XFER), or taken with
// the builder freed (SQLITE_FINISH). A builder in error passes its error on.
@(export)
sqlite3_result_str :: proc "c" (handle: rawptr, s: ^Sqlite_Str, own: c.int) {
	context = runtime.default_context()
	if handle == nil || s == nil do return
	switch s.error {
	case SQLITE_NOMEM:
		sqlite3_result_error_nomem(handle)
	case SQLITE_TOOBIG:
		sqlite3_result_error_toobig(handle)
	case:
		append(&s.text, 0)
		sqlite3_result_text(handle, cstring(raw_data(s.text)), c.int(len(s.text) - 1), SQLITE_TRANSIENT_POINTER)
		pop(&s.text)
		if own != SQLITE_COPY do clear(&s.text)
	}
	if own == SQLITE_FINISH do sqlite3_str_free(s)
}

// --- Library and connection status ------------------------------------------

// sqlite3_config takes the global options a program sets before the library
// starts. The engine has no page cache, lookaside or allocator to configure,
// so each known option is accepted and has nothing to change; one it does not
// know is SQLITE_ERROR, as in SQLite.
@(export)
sqlite3_config :: proc "c" (op: c.int, #c_vararg args: ..any) -> c.int {
	switch op {
	case 1 ..= 30, 1000:
		return SQLITE_OK
	}
	return SQLITE_ERROR
}

// sqlite3_status64 reports the library's memory and page-cache counters:
// the engine keeps none of SQLite's, so each is zero.
@(export)
sqlite3_status64 :: proc "c" (op: c.int, current: ^i64, highwater: ^i64, reset: c.int) -> c.int {
	if op < 0 || op > 9 do return SQLITE_MISUSE
	if current != nil do current^ = 0
	if highwater != nil do highwater^ = 0
	return SQLITE_OK
}

@(export)
sqlite3_status :: proc "c" (op: c.int, current: ^c.int, highwater: ^c.int, reset: c.int) -> c.int {
	if op < 0 || op > 9 do return SQLITE_MISUSE
	if current != nil do current^ = 0
	if highwater != nil do highwater^ = 0
	return SQLITE_OK
}

// sqlite3_db_status reports a connection's lookaside, cache and statement
// counters, which SQLite keeps and the engine does not: zero, SQLITE_OK.
@(export)
sqlite3_db_status64 :: proc "c" (handle: rawptr, op: c.int, current: ^i64, highwater: ^i64, reset: c.int) -> c.int {
	context = runtime.default_context()
	if db_of(handle) == nil do return SQLITE_MISUSE
	if op < 0 || op > 13 do return SQLITE_ERROR
	if current != nil do current^ = 0
	if highwater != nil do highwater^ = 0
	return SQLITE_OK
}

@(export)
sqlite3_db_status :: proc "c" (handle: rawptr, op: c.int, current: ^c.int, highwater: ^c.int, reset: c.int) -> c.int {
	context = runtime.default_context()
	if db_of(handle) == nil do return SQLITE_MISUSE
	if op < 0 || op > 13 do return SQLITE_ERROR
	if current != nil do current^ = 0
	if highwater != nil do highwater^ = 0
	return SQLITE_OK
}

SQLITE_FCNTL_DATA_VERSION :: c.int(35)

// sqlite3_file_control reaches a database's VFS file. The engine's files are
// not VFS files: SQLITE_FCNTL_DATA_VERSION answers the commit counter, which is
// what it means, and every other operation is SQLITE_NOTFOUND, which SQLite
// answers for an operation the file does not understand.
@(export)
sqlite3_file_control :: proc "c" (handle: rawptr, schema: cstring, op: c.int, argument: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	if op == SQLITE_FCNTL_DATA_VERSION && argument != nil {
		(^u32)(argument)^ = u32(db.conn.store.commit_seq)
		return SQLITE_OK
	}
	return SQLITE_NOTFOUND
}

// sqlite3_test_control drives SQLite's own test hooks; none of them exist
// here, and SQLite answers 0 for one it was built without.
@(export)
sqlite3_test_control :: proc "c" (op: c.int, #c_vararg args: ..any) -> c.int {
	return 0
}

// sqlite3_reset_auto_extension forgets the automatic extensions; the facade
// keeps none.
@(export)
sqlite3_reset_auto_extension :: proc "c" () {}

// --- Keywords ----------------------------------------------------------------

// The keyword list is the engine's (engine.SQLITE_KEYWORDS), in SQLite's order.
SQLITE_KEYWORDS := &engine.SQLITE_KEYWORDS

@(export)
sqlite3_keyword_count :: proc "c" () -> c.int {
	return c.int(len(SQLITE_KEYWORDS))
}

@(export)
sqlite3_keyword_name :: proc "c" (index: c.int, name: ^cstring, length: ^c.int) -> c.int {
	if index < 0 || int(index) >= len(SQLITE_KEYWORDS) do return SQLITE_ERROR
	word := SQLITE_KEYWORDS[index]
	if name != nil do name^ = cstring(raw_data(word))
	if length != nil do length^ = c.int(len(word))
	return SQLITE_OK
}

@(export)
sqlite3_keyword_check :: proc "c" (text: [^]u8, n: c.int) -> c.int {
	if text == nil || n <= 0 do return 0
	word := string(text[:n])
	for keyword in SQLITE_KEYWORDS {
		if len(keyword) != len(word) do continue
		same := true
		for k in 0 ..< len(word) {
			a, b := word[k], keyword[k]
			if a >= 'a' && a <= 'z' do a -= 32
			if a != b {
				same = false
				break
			}
		}
		if same do return 1
	}
	return 0
}

// --- Random bytes and time --------------------------------------------------

// sqlite3_randomness fills the buffer from the operating system's random
// source; a count of zero or less does nothing.
@(export)
sqlite3_randomness :: proc "c" (n: c.int, buffer: rawptr) {
	context = runtime.default_context()
	if n <= 0 || buffer == nil do return
	crypto.rand_bytes(([^]u8)(buffer)[:n])
}

// --- The VFS registry ---------------------------------------------------------

// Sqlite_Vfs is SQLite's sqlite3_vfs, version 2.
Sqlite_Vfs :: struct {
	version:           c.int,
	os_file_size:      c.int,
	max_pathname:      c.int,
	next:              ^Sqlite_Vfs,
	name:              cstring,
	app_data:          rawptr,
	open:              proc "c" (vfs: ^Sqlite_Vfs, name: cstring, file: rawptr, flags: c.int, out_flags: ^c.int) -> c.int,
	delete:            proc "c" (vfs: ^Sqlite_Vfs, name: cstring, sync_dir: c.int) -> c.int,
	access:            proc "c" (vfs: ^Sqlite_Vfs, name: cstring, flags: c.int, result: ^c.int) -> c.int,
	full_pathname:     proc "c" (vfs: ^Sqlite_Vfs, name: cstring, n: c.int, out: [^]u8) -> c.int,
	dl_open:           proc "c" (vfs: ^Sqlite_Vfs, name: cstring) -> rawptr,
	dl_error:          proc "c" (vfs: ^Sqlite_Vfs, n: c.int, out: [^]u8),
	dl_sym:            proc "c" (vfs: ^Sqlite_Vfs, handle: rawptr, symbol: cstring) -> rawptr,
	dl_close:          proc "c" (vfs: ^Sqlite_Vfs, handle: rawptr),
	randomness:        proc "c" (vfs: ^Sqlite_Vfs, n: c.int, out: [^]u8) -> c.int,
	sleep:             proc "c" (vfs: ^Sqlite_Vfs, microseconds: c.int) -> c.int,
	current_time:      proc "c" (vfs: ^Sqlite_Vfs, out: ^f64) -> c.int,
	get_last_error:    proc "c" (vfs: ^Sqlite_Vfs, n: c.int, out: [^]u8) -> c.int,
	current_time_i64:  proc "c" (vfs: ^Sqlite_Vfs, out: ^i64) -> c.int,
}

// The default VFS describes the operating system as SQLite's does: names,
// randomness, sleep and time work. Its files are the engine's own, not VFS
// files, so xOpen answers SQLITE_CANTOPEN; a program that registers its own
// VFS over this one (the shell's appendvfs) is accepted and kept in the list.
@(private)
vfs_default := Sqlite_Vfs {
	version          = 2,
	os_file_size     = 8,
	max_pathname     = 1024,
	name             = ODIN_OS == .Windows ? "win32" : "unix",
	open             = vfs_open,
	delete           = vfs_delete,
	access           = vfs_access,
	full_pathname    = vfs_full_pathname,
	dl_open          = vfs_dl_open,
	dl_error         = vfs_dl_error,
	dl_sym           = vfs_dl_sym,
	dl_close         = vfs_dl_close,
	randomness       = vfs_randomness,
	sleep            = vfs_sleep,
	current_time     = vfs_current_time,
	get_last_error   = vfs_get_last_error,
	current_time_i64 = vfs_current_time_i64,
}

@(private)
vfs_list: ^Sqlite_Vfs = &vfs_default

@(private)
vfs_open :: proc "c" (vfs: ^Sqlite_Vfs, name: cstring, file: rawptr, flags: c.int, out_flags: ^c.int) -> c.int {
	return SQLITE_CANTOPEN
}

@(private)
vfs_delete :: proc "c" (vfs: ^Sqlite_Vfs, name: cstring, sync_dir: c.int) -> c.int {
	context = runtime.default_context()
	if name == nil do return SQLITE_OK
	if os.exists(string(name)) && os.remove(string(name)) != nil do return SQLITE_IOERR
	return SQLITE_OK
}

@(private)
vfs_access :: proc "c" (vfs: ^Sqlite_Vfs, name: cstring, flags: c.int, result: ^c.int) -> c.int {
	context = runtime.default_context()
	if result != nil do result^ = name != nil && os.exists(string(name)) ? 1 : 0
	return SQLITE_OK
}

@(private)
vfs_full_pathname :: proc "c" (vfs: ^Sqlite_Vfs, name: cstring, n: c.int, out: [^]u8) -> c.int {
	context = runtime.default_context()
	if name == nil || out == nil || n <= 0 do return SQLITE_ERROR
	absolute, abs_err := filepath.abs(string(name), context.temp_allocator)
	if abs_err != nil do absolute = string(name)
	if len(absolute) >= int(n) do return SQLITE_CANTOPEN
	copy(out[:len(absolute)], absolute)
	out[len(absolute)] = 0
	return SQLITE_OK
}

@(private)
vfs_dl_open :: proc "c" (vfs: ^Sqlite_Vfs, name: cstring) -> rawptr {return nil}

@(private)
vfs_dl_error :: proc "c" (vfs: ^Sqlite_Vfs, n: c.int, out: [^]u8) {
	message := "loadable extensions are not supported"
	if out == nil || n <= 0 do return
	count := min(len(message), int(n) - 1)
	for k in 0 ..< count do out[k] = message[k]
	out[count] = 0
}

@(private)
vfs_dl_sym :: proc "c" (vfs: ^Sqlite_Vfs, handle: rawptr, symbol: cstring) -> rawptr {return nil}

@(private)
vfs_dl_close :: proc "c" (vfs: ^Sqlite_Vfs, handle: rawptr) {}

@(private)
vfs_randomness :: proc "c" (vfs: ^Sqlite_Vfs, n: c.int, out: [^]u8) -> c.int {
	sqlite3_randomness(n, rawptr(out))
	return n
}

@(private)
vfs_sleep :: proc "c" (vfs: ^Sqlite_Vfs, microseconds: c.int) -> c.int {
	context = runtime.default_context()
	time.sleep(time.Duration(max(microseconds, 0)) * time.Microsecond)
	return microseconds
}

// Julian day numbers, as SQLite's VFS reports the time.
@(private)
vfs_current_time_i64 :: proc "c" (vfs: ^Sqlite_Vfs, out: ^i64) -> c.int {
	context = runtime.default_context()
	unix_ms := time.time_to_unix_nano(time.now()) / 1_000_000
	if out != nil do out^ = unix_ms + 210866760000000
	return SQLITE_OK
}

@(private)
vfs_current_time :: proc "c" (vfs: ^Sqlite_Vfs, out: ^f64) -> c.int {
	ms: i64
	vfs_current_time_i64(vfs, &ms)
	if out != nil do out^ = f64(ms) / 86400000.0
	return SQLITE_OK
}

@(private)
vfs_get_last_error :: proc "c" (vfs: ^Sqlite_Vfs, n: c.int, out: [^]u8) -> c.int {
	if out != nil && n > 0 do out[0] = 0
	return 0
}

// sqlite3_vfs_find names a registered VFS; NULL asks for the default.
@(export)
sqlite3_vfs_find :: proc "c" (name: cstring) -> ^Sqlite_Vfs {
	context = runtime.default_context()
	if name == nil do return vfs_list
	for vfs := vfs_list; vfs != nil; vfs = vfs.next {
		if vfs.name != nil && string(vfs.name) == string(name) do return vfs
	}
	return nil
}

@(private)
vfs_unlink :: proc "contextless" (target: ^Sqlite_Vfs) {
	if target == nil do return
	if vfs_list == target {
		vfs_list = target.next
		return
	}
	for vfs := vfs_list; vfs != nil; vfs = vfs.next {
		if vfs.next == target {
			vfs.next = target.next
			return
		}
	}
}

// sqlite3_vfs_register adds a VFS, as the default when asked; registering
// one twice moves it.
@(export)
sqlite3_vfs_register :: proc "c" (vfs: ^Sqlite_Vfs, make_default: c.int) -> c.int {
	if vfs == nil do return SQLITE_MISUSE
	vfs_unlink(vfs)
	if make_default != 0 || vfs_list == nil {
		vfs.next = vfs_list
		vfs_list = vfs
	} else {
		vfs.next = vfs_list.next
		vfs_list.next = vfs
	}
	return SQLITE_OK
}

@(export)
sqlite3_vfs_unregister :: proc "c" (vfs: ^Sqlite_Vfs) -> c.int {
	vfs_unlink(vfs)
	return SQLITE_OK
}

// --- A connection's client data ---------------------------------------------

Client_Data :: struct {
	data:    rawptr,
	destroy: proc "c" (data: rawptr),
}

// sqlite3_set_clientdata keeps a pointer under a name on the connection,
// calling the destructor of the one it replaces; NULL removes it. The
// destructors run when the connection closes.
@(export)
sqlite3_set_clientdata :: proc "c" (handle: rawptr, name: cstring, data: rawptr, destroy: proc "c" (data: rawptr)) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil || name == nil do return SQLITE_MISUSE
	key := string(name)
	if old, found := db.clientdata[key]; found {
		if old.destroy != nil && old.data != nil do old.destroy(old.data)
		if data == nil {
			stored_key := key
			for k in db.clientdata do if k == key do stored_key = k
			delete_key(&db.clientdata, key)
			delete(stored_key)
			return SQLITE_OK
		}
		db.clientdata[key] = Client_Data{data = data, destroy = destroy}
		return SQLITE_OK
	}
	if data == nil do return SQLITE_OK
	db.clientdata[strings.clone(key)] = Client_Data{data = data, destroy = destroy}
	return SQLITE_OK
}

@(export)
sqlite3_get_clientdata :: proc "c" (handle: rawptr, name: cstring) -> rawptr {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil || name == nil do return nil
	if entry, found := db.clientdata[string(name)]; found do return entry.data
	return nil
}

@(private)
clientdata_close :: proc(db: ^Database) {
	for key, entry in db.clientdata {
		if entry.destroy != nil && entry.data != nil do entry.destroy(entry.data)
		delete(key)
	}
	delete(db.clientdata)
}

// --- Statements and files -----------------------------------------------------

// sqlite3_stmt_explain switches a statement between running (0), EXPLAIN (1)
// and EXPLAIN QUERY PLAN (2). The engine prepares the explanation as its own
// statement: a statement that has not started is prepared again with the
// prefix it asks for; one that has started is SQLITE_BUSY, as in SQLite.
@(export)
sqlite3_stmt_explain :: proc "c" (handle: rawptr, mode: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if mode < 0 || mode > 2 do return SQLITE_ERROR
	if sqlite3_stmt_isexplain(handle) == mode do return SQLITE_OK
	if engine.embed_busy(stmt.stmt) do return SQLITE_BUSY
	text := strings.trim_space(engine.embed_sql(stmt.stmt))
	upper := strings.to_upper(text, context.temp_allocator)
	switch {
	case strings.has_prefix(upper, "EXPLAIN QUERY PLAN"):
		text = strings.trim_space(text[len("EXPLAIN QUERY PLAN"):])
	case strings.has_prefix(upper, "EXPLAIN"):
		text = strings.trim_space(text[len("EXPLAIN"):])
	}
	prefix := mode == 1 ? "EXPLAIN " : mode == 2 ? "EXPLAIN QUERY PLAN " : ""
	sql := strings.concatenate({prefix, text}, context.temp_allocator)
	replacement := engine.embed_prepare(stmt.db.conn, sql)
	if replacement == nil do return SQLITE_ERROR
	engine.embed_finalize(stmt.stmt)
	stmt.stmt = replacement
	stmt_clear_text_cache(stmt)
	stmt.finished = false
	stmt.described = false
	return SQLITE_OK
}

// sqlite3_table_column_metadata answers a column's declared type, collation,
// NOT NULL, primary key and AUTOINCREMENT. A NULL column only asks whether the
// table exists.
@(export)
sqlite3_table_column_metadata :: proc "c" (
	handle: rawptr,
	schema: cstring,
	table: cstring,
	column: cstring,
	decltype: ^cstring,
	collation: ^cstring,
	not_null: ^c.int,
	primary_key: ^c.int,
	auto_increment: ^c.int,
) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil || table == nil do return SQLITE_MISUSE
	column_name := column == nil ? "" : string(column)
	meta, has_table, has_column := engine.embed_column_metadata(db.conn, schema == nil ? "" : string(schema), string(table), column_name)
	if has_table && column == nil do return SQLITE_OK
	if !has_column {
		set_error(db, strings.concatenate({"no such table column: ", string(table), ".", column_name}, context.temp_allocator))
		db.last_code = SQLITE_ERROR
		return SQLITE_ERROR
	}
	// The strings live as long as the connection's last answer, as SQLite's
	// live as long as the schema.
	delete(db.metadata_decltype)
	delete(db.metadata_collation)
	db.metadata_decltype = strings.clone_to_cstring(meta.decltype)
	db.metadata_collation = strings.clone_to_cstring(meta.collation)
	if decltype != nil do decltype^ = len(meta.decltype) > 0 ? db.metadata_decltype : nil
	if collation != nil do collation^ = db.metadata_collation
	if not_null != nil do not_null^ = meta.not_null ? 1 : 0
	if primary_key != nil do primary_key^ = meta.primary_key ? 1 : 0
	if auto_increment != nil do auto_increment^ = meta.auto_increment ? 1 : 0
	return SQLITE_OK
}

// sqlite3_filename_database is the database file a filename names. The
// filenames the facade hands to a VFS are plain paths, so it is the path.
@(export)
sqlite3_filename_database :: proc "c" (filename: cstring) -> cstring {
	return filename
}

// --- Windows text ---------------------------------------------------------------

// sqlite3_win32_utf8_to_unicode converts UTF-8 to a UTF-16 string from
// sqlite3_malloc, which the caller frees with sqlite3_free.
@(export)
sqlite3_win32_utf8_to_unicode :: proc "c" (text: cstring) -> [^]u16 {
	context = runtime.default_context()
	if text == nil do return nil
	bytes := cstring_bytes(text)
	units := make([dynamic]u16, 0, len(bytes) + 1, context.temp_allocator)
	for r in string(bytes) {
		if r >= 0x10000 {
			v := u32(r) - 0x10000
			append(&units, u16(0xd800 + (v >> 10)), u16(0xdc00 + (v & 0x3ff)))
		} else {
			append(&units, u16(r))
		}
	}
	append(&units, 0)
	out := ([^]u16)(sqlite_alloc(len(units) * 2))
	if out == nil do return nil
	intrinsics.mem_copy_non_overlapping(out, raw_data(units), len(units) * 2)
	return out
}
