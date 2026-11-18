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
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import engine "../engine"

SQLITE_OK :: c.int(0)
SQLITE_ERROR :: c.int(1)
// The primary result codes a caller switches on. They are SQLite's numbers, so a
// program written against the classic API reads the same reason it always did
// (D25): a duplicate key is SQLITE_CONSTRAINT, an interrupted statement is
// SQLITE_INTERRUPT, and so on.
SQLITE_ABORT :: c.int(4)
SQLITE_BUSY :: c.int(5)
SQLITE_NOMEM :: c.int(7)
SQLITE_READONLY :: c.int(8)
SQLITE_INTERRUPT :: c.int(9)
SQLITE_IOERR :: c.int(10)
SQLITE_CORRUPT :: c.int(11)
SQLITE_TOOBIG :: c.int(18)
SQLITE_CONSTRAINT :: c.int(19)
// The extended constraint codes, which SQLite reports only when a caller turns
// sqlite3_extended_result_codes on. Each is SQLITE_CONSTRAINT plus a small
// ordinal, as in SQLite, so a program that masks the low byte still sees 19.
SQLITE_CONSTRAINT_CHECK :: c.int(19 | 1 << 8)
SQLITE_CONSTRAINT_FOREIGNKEY :: c.int(19 | 3 << 8)
SQLITE_CONSTRAINT_NOTNULL :: c.int(19 | 5 << 8)
SQLITE_CONSTRAINT_PRIMARYKEY :: c.int(19 | 6 << 8)
SQLITE_CONSTRAINT_UNIQUE :: c.int(19 | 8 << 8)
SQLITE_MISMATCH :: c.int(20)
SQLITE_MISUSE :: c.int(21)
SQLITE_AUTH :: c.int(23)
SQLITE_RANGE :: c.int(25)
SQLITE_NOTADB :: c.int(26)
SQLITE_ROW :: c.int(100)
SQLITE_DONE :: c.int(101)

SQLITE_INTEGER :: c.int(1)
SQLITE_FLOAT :: c.int(2)
SQLITE_TEXT :: c.int(3)
SQLITE_BLOB :: c.int(4)
SQLITE_NULL :: c.int(5)

Database :: struct {
	conn:         ^engine.Embed_Conn,
	// clientdata is what sqlite3_set_clientdata keeps, by name; the strings
	// are sqlite3_table_column_metadata's last answer (shell_api.odin).
	clientdata:         map[string]Client_Data,
	metadata_decltype:  cstring,
	metadata_collation: cstring,
	last_code:    c.int,  // what sqlite3_errcode answers
	last_extended: c.int, // what sqlite3_extended_errcode answers
	// extended is set by sqlite3_extended_result_codes: with it, sqlite3_errcode
	// answers the extended code too, the way SQLite does.
	extended:     bool,
	last_error:   string, // owned, NUL-terminated
	// error_offset is the byte offset in the SQL text of the last prepare error,
	// or -1: what sqlite3_error_offset answers.
	error_offset: c.int,
	in_memory:    bool,
	// statements is what this connection handed out and has not finalized, so a
	// close can make them misuse rather than leave them dangling (D29).
	statements: map[rawptr]^Statement,
	// functions are the application-defined functions registered on this
	// connection; function_code is the code the last failing one answered, so
	// the statement it failed reports it.
	functions:     [dynamic]^Function,
	function_code: c.int,
	// The hooks a program installed, with the argument each one gets.
	commit_hook:     Commit_Callback,
	commit_arg:      rawptr,
	rollback_hook:   Destroy_Callback,
	rollback_arg:    rawptr,
	update_hook:     Update_Callback,
	update_arg:      rawptr,
	progress_hook:   Progress_Callback,
	progress_arg:    rawptr,
	// trace_mask is which events sqlite3_trace_v2 asked for.
	trace_mask:      c.uint,
	trace_hook:      Trace_Callback,
	trace_arg:       rawptr,
	authorizer:      Authorizer_Callback,
	authorizer_arg:  rawptr,
	// last_error16 is the message sqlite3_errmsg16 handed out last.
	last_error16:    []u16,
	// collations are the comparisons registered on this connection
	// (collation.odin), and collation_needed the callback that may add one.
	collations:           [dynamic]^Collation,
	collation_needed:     Collation_Needed_Callback,
	collation_needed16:   Collation_Needed16_Callback,
	collation_needed_arg: rawptr,
	// pending_declaration is what sqlite3_declare_vtab received during the
	// xCreate or xConnect running now (vtab.odin).
	pending_declaration:  string,
	in_vtab_constructor:  bool,
	// filename is what sqlite3_db_filename answers for main: the absolute
	// path of the file, "" in memory. attached_name holds the last name
	// sqlite3_db_name answered for an attached database.
	filename:      cstring,
	attached_name: cstring,
	// zombie is a connection sqlite3_close_v2 closed while statements were
	// still open: it closes when the last one is finalized.
	zombie: bool,
	// not_a_database is set by sqlite3_deserialize of bytes that are not a
	// SQLite database (backup.odin).
	not_a_database: bool,
	// The per-connection limits and configuration flags, and whether
	// extension loading was enabled (library.odin).
	limits:             [SQLITE_LIMIT_COUNT]c.int,
	limits_set:         bool,
	config:             [SQLITE_DBCONFIG_LAST_FLAG - SQLITE_DBCONFIG_FIRST_FLAG + 1]c.int,
	config_set:         bool,
	extensions_enabled: bool,
}

Statement :: struct {
	db:   ^Database,
	stmt: ^engine.Embed_Statement,
	// finished is set when step answered SQLITE_DONE, so stepping again is
	// SQLITE_MISUSE until reset, which is SQLite's contract (F7).
	finished: bool,
	// text_cache owns every C string this statement handed to the caller:
	// sqlite3_column_text and sqlite3_column_name return a pointer that is valid
	// until the next step, reset or finalize, and the engine's own strings are
	// not NUL-terminated, so each answer is cloned here and freed then.
	text_cache: [dynamic]cstring,
	// sql_text is the statement's own text as a C string, for sqlite3_sql: it
	// lives until finalize, unlike the column answers in text_cache.
	sql_text: cstring,
	// param_names holds the parameter names as C strings, made on the first
	// sqlite3_bind_parameter_name and kept until finalize.
	param_names: []cstring,
	// origins holds each result column's database, table, column and declared
	// type as C strings, described on the first metadata call and kept until
	// finalize; described says the description ran.
	origins:   []Column_Origin_C,
	described: bool,
	// traced is set when the trace saw the statement start and has not yet
	// seen it end; started is when, in nanoseconds.
	traced:  bool,
	started: i64,
	// pointers are the parameters bound with sqlite3_bind_pointer (pointer.odin).
	pointers: [dynamic]Pointer_Binding,
	// wide_cache holds the UTF-16 column texts, freed with text_cache;
	// wide_names the UTF-16 names and origins, kept until finalize.
	wide_cache: [dynamic][]u16,
	wide_names: [dynamic][]u16,
	// value_cache holds the values sqlite3_column_value handed out, freed with
	// text_cache (shell_api.odin).
	value_cache: [dynamic]^Value_Box,
	// error_code is what the last step failed with, which sqlite3_reset
	// answers and leaves on the connection, as SQLite does.
	error_code:     c.int,
	error_extended: c.int,
}

// Column_Origin_C is one column's origin as the C strings the metadata calls
// return: NULL where the column is an expression.
Column_Origin_C :: struct {
	database: cstring,
	table:    cstring,
	column:   cstring,
	decltype: cstring,
}

@(private)
db_of :: proc(handle: rawptr) -> ^Database {
	if !engine.handle_is_live(handle) do return nil
	return cast(^Database)handle
}

@(private)
stmt_of :: proc(handle: rawptr) -> ^Statement {
	if !engine.handle_is_live(handle) do return nil
	return cast(^Statement)handle
}

// statement_end returns the index just past the first statement: its terminating
// semicolon, or the end of the text, as the engine cuts a script (a `;` inside
// a quote, a comment or a trigger body ends nothing). SQLite exposes the same
// boundary through pzTail (F5).
@(private)
statement_end :: proc(sql: string) -> int {
	return min(engine.sql_statement_end(sql), len(sql))
}

// only_space_or_comments reports text that holds no statement: whitespace,
// semicolons and comments only. SQLite prepares nothing from it and answers OK.
@(private)
only_space_or_comments :: proc(text: string) -> bool {
	i := 0
	for i < len(text) {
		ch := text[i]
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ';' {
			i += 1
			continue
		}
		if ch == '-' && i + 1 < len(text) && text[i + 1] == '-' {
			i += 2
			for i < len(text) && text[i] != '\n' do i += 1
			continue
		}
		if ch == '/' && i + 1 < len(text) && text[i + 1] == '*' {
			i += 2
			for i + 1 < len(text) && !(text[i] == '*' && text[i + 1] == '/') do i += 1
			if i + 1 < len(text) do i += 2
			else do i = len(text)
			continue
		}
		return false
	}
	return true
}

// c_text is the text a caller handed us, honouring nByte: a non-negative count
// is the byte count, a negative one means "up to the terminator".
@(private)
c_text :: proc(sql: cstring, nByte: c.int) -> string {
	if nByte < 0 do return string(sql)
	if nByte == 0 do return ""
	bytes := ([^]u8)(rawptr(sql))
	// The text ends at a NUL inside nByte too, as SQLite reads it: a caller
	// may count the terminator (Python's sqlite3 module does).
	for i in 0 ..< int(nByte) {
		if bytes[i] == 0 do return string(bytes[:i])
	}
	return string(bytes[:int(nByte)])
}

// fail_connection reports the connection's last error with the message it holds,
// for the paths that call the engine without an Error value of their own.
@(private)
fail_connection :: proc(db: ^Database) -> c.int {
	if db == nil do return SQLITE_ERROR
	// The code follows the kind, so a prepare the authorizer refused answers
	// SQLITE_AUTH, as in SQLite.
	code := sqlite_code(engine.Error{kind = engine.embed_error_kind(db.conn)})
	set_error(db, engine.embed_error(db.conn))
	db.last_code = code
	db.last_extended = code
	return code
}

@(private)
stmt_clear_text_cache :: proc(stmt: ^Statement) {
	if stmt == nil do return
	for text in stmt.text_cache do delete(text)
	clear(&stmt.text_cache)
	for units in stmt.wide_cache do delete(units)
	clear(&stmt.wide_cache)
	stmt_clear_value_cache(stmt)
}

// column_text renders a column as the C string SQLite would hand out: every
// value kind has a text form, NULL is a NULL pointer, and the answer lives until
// the statement moves or closes. The engine's strings are not NUL-terminated, so
// each answer is a clone.
@(private)
column_text :: proc(stmt: ^Statement, index: int) -> (text: cstring, is_null: bool) {
	value, ok := engine.embed_column_value(stmt.stmt, index)
	if !ok || value.kind == .Null do return nil, true
	rendered := engine.sqlite_value_text(value, context.allocator)
	defer delete(rendered)
	clone := strings.clone_to_cstring(rendered, context.allocator)
	append(&stmt.text_cache, clone)
	return clone, false
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
	// is_text says the value is text, which a write keeps; writable is the
	// flag it was opened with; expired says its row changed under it.
	is_text:  bool,
	writable: bool,
	expired:  bool,
}

@(private)
blob_of :: proc(handle: rawptr) -> ^Blob {
	return cast(^Blob)handle
}


@(private)
set_error :: proc(db: ^Database, text: string) {
	if db == nil do return
	copy := strings.clone(text)
	delete(db.last_error)
	db.last_error = copy
	// sqlite3_errmsg reads the connection, so a refusal this layer makes on its
	// own (a busy close, a spent statement) has to land there too, or errmsg
	// answers the message of an older failure.
	engine.embed_note_error(db.conn, .Invalid_Argument, text)
}

// set_error_from records an engine error's message and frees the error, which
// the engine handed over to this layer.
@(private)
set_error_from :: proc(db: ^Database, err: engine.Error) {
	set_error(db, err.message)
	dropped := err
	engine.error_free(&dropped)
}

// sqlite_code names an engine error with the result code SQLite reports for the
// same condition. The names are the contract: a caller that tests for
// SQLITE_CONSTRAINT after an INSERT keeps working (D25).
@(private)
sqlite_code :: proc(err: engine.Error) -> c.int {
	switch err.kind {
	case .None:
		return SQLITE_OK
	case .Duplicate_Primary_Key, .Duplicate_Unique, .Not_Null_Violation, .Check_Violation, .Foreign_Key_Violation:
		return SQLITE_CONSTRAINT
	case .Invalid_Type:
		return SQLITE_MISMATCH
	case .Out_Of_Memory:
		return SQLITE_NOMEM
	case .Quota_Exceeded:
		return SQLITE_TOOBIG
	case .Cancelled:
		return SQLITE_INTERRUPT
	case .Locked:
		return SQLITE_BUSY
	case .Transaction_Read_Only:
		return SQLITE_READONLY
	case .Permission_Denied:
		return SQLITE_AUTH
	case .Io:
		return SQLITE_IOERR
	case .Corrupt_Log:
		return SQLITE_CORRUPT
	case .Format_Too_New:
		return SQLITE_NOTADB
	case .Invalid_Argument, .Table_Not_Found, .Table_Exists, .Column_Not_Found,
	     .Index_Exists, .Index_Not_Found, .No_Primary_Key, .Auto_Increment_Requires_Integer,
	     .Sql_Syntax, .Sql_Unsupported, .Sql_Not_A_Query, .Transaction_Closed,
	     .Internal, .Incomplete:
		// SQLite reports these as a plain error with the message saying which, and
		// so do we: inventing a code would be a difference nobody asked for.
		return SQLITE_ERROR
	}
	return SQLITE_ERROR
}

// sqlite_extended_code is sqlite_code with the constraint narrowed to which
// constraint failed, which is what a caller that turned extended codes on reads.
@(private)
sqlite_extended_code :: proc(err: engine.Error) -> c.int {
	// The narrow code only exists to say which constraint failed; everything else
	// keeps the primary code sqlite_code names.
	#partial switch err.kind {
	case .Duplicate_Primary_Key:
		return SQLITE_CONSTRAINT_PRIMARYKEY
	case .Duplicate_Unique:
		return SQLITE_CONSTRAINT_UNIQUE
	case .Not_Null_Violation:
		return SQLITE_CONSTRAINT_NOTNULL
	case .Check_Violation:
		return SQLITE_CONSTRAINT_CHECK
	case .Foreign_Key_Violation:
		return SQLITE_CONSTRAINT_FOREIGNKEY
	}
	return sqlite_code(err)
}

// fail records the message and the code together, so sqlite3_errcode answers
// what the last step or exec returned. The error is this layer's: its message
// is copied and the error is freed.
@(private)
fail :: proc(db: ^Database, err: engine.Error) -> c.int {
	defer {
		dropped := err
		engine.error_free(&dropped)
	}
	// An interrupted statement says so in SQLite's word, and so does a write to
	// a database that is read-only.
	message := err.message
	if err.kind == .Cancelled do message = "interrupted"
	if err.kind == .Transaction_Read_Only && db != nil && db.conn.store.read_only do message = "attempt to write a readonly database"
	set_error(db, message)
	code := sqlite_code(err)
	extended := sqlite_extended_code(err)
	// A function that failed with its own code (sqlite3_result_error_code) is
	// the statement's answer, as in SQLite.
	if db != nil && db.function_code != 0 {
		code = db.function_code & 0xff
		extended = db.function_code
		db.function_code = 0
	}
	if db != nil {
		db.last_code = code
		db.last_extended = extended
	}
	// A caller in extended mode reads the narrow code from the return value as
	// well, so the check it wrote next to sqlite3_step keeps working.
	if db != nil && db.extended && db.last_extended != code do return db.last_extended
	return code
}

SQLITE_OPEN_READONLY :: c.int(0x01)
SQLITE_OPEN_READWRITE :: c.int(0x02)
SQLITE_OPEN_CREATE :: c.int(0x04)
SQLITE_OPEN_URI :: c.int(0x40)
SQLITE_OPEN_MEMORY :: c.int(0x80)
SQLITE_CANTOPEN :: c.int(14)
SQLITE_CANTOPEN_ISDIR :: c.int(14 | (2 << 8))

// open_uri reads a `file:` URI as SQLite does: the path after an empty or
// `localhost` authority, percent-decoded, and the mode its query asks for.
@(private)
open_uri :: proc(uri: string, flags: c.int) -> (path: string, out_flags: c.int, ok: bool) {
	out_flags = flags
	rest := uri[len("file:"):]
	query := ""
	if at := strings.index_any(rest, "?#"); at >= 0 {
		if rest[at] == '?' {
			query = rest[at + 1:]
			if hash := strings.index_byte(query, '#'); hash >= 0 do query = query[:hash]
		}
		rest = rest[:at]
	}
	if strings.has_prefix(rest, "//") {
		authority_end := strings.index_byte(rest[2:], '/')
		authority := authority_end < 0 ? rest[2:] : rest[2:2 + authority_end]
		if authority != "" && !strings.equal_fold(authority, "localhost") do return "", flags, false
		rest = authority_end < 0 ? "" : rest[2 + authority_end:]
	}
	decoded := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(rest); i += 1 {
		if rest[i] == '%' && i + 2 < len(rest) {
			if value, parsed := strconv.parse_int(rest[i + 1:i + 3], 16); parsed {
				strings.write_byte(&decoded, u8(value))
				i += 2
				continue
			}
		}
		strings.write_byte(&decoded, rest[i])
	}
	path = strings.to_string(decoded)
	// "/C:/x" names the drive path C:/x.
	when ODIN_OS == .Windows {
		if len(path) >= 3 && path[0] == '/' && path[2] == ':' do path = path[1:]
	}
	for pair in strings.split(query, "&", context.temp_allocator) {
		key, _, value := strings.partition(pair, "=")
		if key != "mode" do continue
		mode := flags &~ (SQLITE_OPEN_READONLY | SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
		switch value {
		case "ro":
			out_flags = mode | SQLITE_OPEN_READONLY
		case "rw":
			out_flags = mode | SQLITE_OPEN_READWRITE
		case "rwc":
			out_flags = mode | SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
		case "memory":
			out_flags = flags | SQLITE_OPEN_MEMORY
		case:
			return "", flags, false
		}
	}
	return path, out_flags, true
}

// open_failed answers a failed open as SQLite does: a handle all the same,
// which carries the error for sqlite3_errmsg and closes with sqlite3_close.
@(private)
open_failed :: proc(ppDb: ^rawptr, code: c.int, message: string) -> c.int {
	db := new(Database)
	db.error_offset = -1
	db.last_code = code & 0xff
	db.last_extended = code
	db.last_error = string(strings.clone_to_cstring(message))
	db.filename = strings.clone_to_cstring("")
	db.statements = make(map[rawptr]^Statement)
	engine.handle_register(rawptr(db))
	ppDb^ = rawptr(db)
	return code & 0xff
}

@(export)
sqlite3_open :: proc "c" (filename: cstring, ppDb: ^rawptr) -> c.int {
	context = runtime.default_context()
	return open_database(filename, ppDb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
}

// open_database opens a database the way SQLite's open does: an in-memory
// spelling in memory, a SQLite file as one (a path that does not exist yet
// becomes an empty one when the flags allow creating it), and a directory
// only when it is an engine database.
@(private)
open_database :: proc(filename: cstring, ppDb: ^rawptr, open_flags: c.int) -> c.int {
	if ppDb == nil do return SQLITE_MISUSE
	if filename == nil {
		ppDb^ = nil
		return SQLITE_MISUSE
	}
	path := string(filename)
	flags := open_flags
	if !engine.store_path_is_memory(path) && flags & SQLITE_OPEN_URI != 0 && strings.has_prefix(path, "file:") {
		decoded, uri_flags, uri_ok := open_uri(path, flags)
		if !uri_ok do return open_failed(ppDb, SQLITE_ERROR, "invalid uri")
		path, flags = decoded, uri_flags
		if flags & SQLITE_OPEN_MEMORY != 0 do path = ":memory:"
	}
	unable :: "unable to open database file"
	if !engine.store_path_is_memory(path) {
		switch engine.path_kind(path) {
		case .Missing:
			if flags & SQLITE_OPEN_CREATE == 0 || flags & SQLITE_OPEN_READONLY != 0 do return open_failed(ppDb, SQLITE_CANTOPEN, unable)
			if !engine.sqlite_create_empty_file(path) do return open_failed(ppDb, SQLITE_CANTOPEN, unable)
		case .Directory:
			// A directory is an engine database or nothing SQLite can open.
			if !engine.store_is_database_directory(path) do return open_failed(ppDb, SQLITE_CANTOPEN_ISDIR, unable)
		case .File:
		}
	}
	in_memory := engine.sqlite_is_file(path)
	conn, err := engine.embed_open(path)
	if err.kind != .None {
		message := strings.clone(err.message, context.temp_allocator)
		engine.error_free(&err)
		return open_failed(ppDb, SQLITE_CANTOPEN, len(message) > 0 ? message : unable)
	}
	db := new(Database)
	if flags & SQLITE_OPEN_READONLY != 0 do conn.store.read_only = true
	db.conn = conn
	db.error_offset = -1
	// An expression column is named by its text, as SQLite names it.
	conn.store.sqlite_names = true
	// Foreign keys are off until PRAGMA foreign_keys = ON, and a statement
	// answers with SQLite's rules, as in SQLite (docs/sqlite-semantics.md).
	conn.store.foreign_keys_off = true
	conn.store.sqlite_rules = true
	db.in_memory = in_memory
	db.filename = strings.clone_to_cstring("")
	if !engine.store_path_is_memory(path) {
		if absolute, abs_err := filepath.abs(path, context.temp_allocator); abs_err == nil {
			delete(db.filename)
			db.filename = strings.clone_to_cstring(absolute)
		}
	}
	db.statements = make(map[rawptr]^Statement)
	engine.handle_register(rawptr(db))
	ppDb^ = rawptr(db)
	return SQLITE_OK
}

@(export)
sqlite3_open_v2 :: proc "c" (filename: cstring, ppDb: ^rawptr, flags: c.int, vfs: cstring) -> c.int {
	context = runtime.default_context()
	_ = vfs
	return open_database(filename, ppDb, flags)
}

@(export)
sqlite3_close :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_OK
	// A handle from a failed open holds only its error.
	if db.conn == nil {
		engine.handle_forget(rawptr(db))
		delete(db.statements)
		delete(db.filename)
		delete(db.last_error)
		free(db)
		return SQLITE_OK
	}
	// SQLite answers SQLITE_BUSY while a statement is not finalized, and frees
	// nothing: the caller finalizes and closes again (F6). Freeing them here, as
	// this used to, told a caller that checked for BUSY that everything was gone.
	if len(db.statements) > 0 {
		set_error(db, "the connection has statements that are not finalized")
		return SQLITE_BUSY
	}
	keys := make([dynamic]rawptr, 0, len(db.statements))
	for key, _ in db.statements do append(&keys, key)
	for key in keys {
		if stmt, found := db.statements[key]; found {
			engine.embed_finalize(stmt.stmt)
			engine.handle_forget(key)
			free(stmt)
		}
	}
	delete(db.statements)
	delete(keys)
	engine.handle_forget(rawptr(db))
	trace_close(db)
	functions_close(db)
	collations_close(db)
	clientdata_close(db)
	delete(db.metadata_decltype)
	delete(db.metadata_collation)
	// Every virtual table disconnects while the connection can still be named.
	engine.store_vtab_close(db.conn.store)
	delete(db.pending_declaration)
	delete(db.filename)
	delete(db.attached_name)
	engine.embed_close(db.conn)
	delete(db.last_error)
	delete(db.last_error16)
	free(db)
	return SQLITE_OK
}

// sqlite3_close_v2 closes the connection, or, while statements are still
// open, makes it a zombie that closes when the last one is finalized, as
// SQLite does: the call answers OK either way.
@(export)
sqlite3_close_v2 :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_OK
	if len(db.statements) > 0 {
		db.zombie = true
		return SQLITE_OK
	}
	return sqlite3_close(handle)
}

@(export)
sqlite3_errmsg :: proc "c" (handle: rawptr) -> cstring {
	context = runtime.default_context()
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return "out of memory"
	if db.conn == nil do return cstring(raw_data(db.last_error))
	delete(db.last_error)
	db.last_error = strings.clone(engine.embed_error(db.conn))
	// SQLite names success too: errmsg after a call that worked is "not an error".
	if len(db.last_error) == 0 do return "not an error"
	return cstring(raw_data(db.last_error))
}

@(export)
sqlite3_errcode :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_ERROR
	// The code the last exec or step answered, so a caller can tell a duplicate
	// key (19) from a syntax error (1) without parsing the message (D25). In
	// extended mode the narrow code is the answer, as in SQLite.
	if db.extended do return db.last_extended
	return db.last_code
}

// sqlite3_extended_errcode answers the narrow code regardless of the mode, the way
// SQLite's own does: a caller can ask "which constraint" without changing what
// every other call returns.
@(export)
sqlite3_extended_errcode :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_ERROR
	return db.last_extended
}

// sqlite3_interrupt asks the statement that is running, on any thread, to stop.
// The next statement starts with a clean flag, so interrupting a connection does
// not poison it, which is what SQLite documents (D25).
@(export)
sqlite3_interrupt :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return
	engine.store_cancel(db.conn.store)
}

@(export)
sqlite3_changes :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return 0
	// The counter belongs to the connection and is set by whichever statement ran
	// last, through exec or through a step that reached its end (F3).
	return c.int(engine.embed_last_changes(db.conn))
}

@(export)
sqlite3_total_changes :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	return c.int(sqlite3_total_changes64(handle))
}

// Exec_Callback is the function sqlite3_exec calls once per row: the values in
// their text form, NULL as a NULL pointer, and the column names.
Exec_Callback :: #type proc "c" (
	arg: rawptr,
	count: c.int,
	values: [^]cstring,
	names: [^]cstring,
) -> c.int

// sqlite3_exec runs every statement of a text the way a program would: each
// one is prepared, stepped to its end and finalized, so the hooks, the trace
// and the progress handler see exec's statements exactly as they see a
// program's. The callback gets each row's values as text (NULL for SQL NULL)
// and the column names; a non-zero answer stops with SQLITE_ABORT, as in
// SQLite. The error message, when asked for, is the caller's to free with
// sqlite3_free.
@(export)
sqlite3_exec :: proc "c" (handle: rawptr, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int {
	context = runtime.default_context()
	if errmsg != nil do errmsg^ = nil
	db := db_of(handle)
	if db == nil || sql == nil do return SQLITE_MISUSE
	row_callback := cast(Exec_Callback)callback
	current := sql
	for current != nil && len(string(current)) > 0 {
		statement: rawptr
		tail: cstring
		if code := prepare(handle, current, -1, &statement, &tail); code != SQLITE_OK {
			return exec_failed(db, code, errmsg)
		}
		if statement != nil {
			for {
				code := sqlite3_step(statement)
				if code == SQLITE_DONE do break
				if code != SQLITE_ROW {
					sqlite3_finalize(statement)
					return exec_failed(db, code, errmsg)
				}
				if row_callback == nil do continue
				count := int(sqlite3_column_count(statement))
				values := make([]cstring, count, context.temp_allocator)
				names := make([]cstring, count, context.temp_allocator)
				for i in 0 ..< count {
					values[i] = sqlite3_column_text(statement, c.int(i))
					names[i] = sqlite3_column_name(statement, c.int(i))
				}
				if row_callback(arg, c.int(count), raw_data(values), raw_data(names)) != 0 {
					sqlite3_finalize(statement)
					set_error(db, "query aborted")
					db.last_code = SQLITE_ABORT
					db.last_extended = SQLITE_ABORT
					return exec_failed(db, SQLITE_ABORT, errmsg)
				}
			}
			sqlite3_finalize(statement)
		}
		// A text that ends in spaces or a comment leaves nothing to prepare.
		if tail == current do break
		current = tail
	}
	db.last_code = SQLITE_OK
	db.last_extended = SQLITE_OK
	return SQLITE_OK
}

@(private)
exec_failed :: proc(db: ^Database, code: c.int, errmsg: ^cstring) -> c.int {
	if errmsg != nil && len(db.last_error) > 0 do errmsg^ = sqlite_strdup(db.last_error)
	return code
}

@(export)
sqlite3_prepare_v2 :: proc "c" (handle: rawptr, sql: cstring, nByte: c.int, ppStmt: ^rawptr, pzTail: ^cstring) -> c.int {
	context = runtime.default_context()
	return prepare(handle, sql, nByte, ppStmt, pzTail)
}

// sqlite3_prepare_v3 takes flags that are hints to SQLite's own cache
// (PERSISTENT, NORMALIZE, NO_VTAB); a statement here is prepared the same way
// whichever is set.
@(export)
sqlite3_prepare_v3 :: proc "c" (handle: rawptr, sql: cstring, nByte: c.int, flags: c.uint, ppStmt: ^rawptr, pzTail: ^cstring) -> c.int {
	context = runtime.default_context()
	_ = flags
	return prepare(handle, sql, nByte, ppStmt, pzTail)
}

// sqlite3_prepare is the legacy entry point. SQLite's version re-prepares less
// eagerly after a schema change; this engine never needs to.
@(export)
sqlite3_prepare :: proc "c" (handle: rawptr, sql: cstring, nByte: c.int, ppStmt: ^rawptr, pzTail: ^cstring) -> c.int {
	context = runtime.default_context()
	return prepare(handle, sql, nByte, ppStmt, pzTail)
}

// sqlite_token_at is the token that starts at `offset`, as SQLite's tokenizer
// would cut it, for a syntax error's "near" text.
@(private)
sqlite_token_at :: proc(text: string, offset: int) -> string {
	rest := text[offset:]
	if len(rest) == 0 do return ""
	is_word :: proc(b: u8) -> bool {
		return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b == '$' || b >= 0x80
	}
	first := rest[0]
	switch {
	case is_word(first):
		n := 1
		for n < len(rest) && is_word(rest[n]) do n += 1
		return rest[:n]
	case first == '\'' || first == '"' || first == '`' || first == '[':
		closing := first == '[' ? u8(']') : first
		n := 1
		for n < len(rest) {
			if rest[n] == closing {
				if closing != ']' && n + 1 < len(rest) && rest[n + 1] == closing {
					n += 2
					continue
				}
				return rest[:n + 1]
			}
			n += 1
		}
		return rest
	}
	for operator in ([]string{"->>", "||", "<=", ">=", "==", "!=", "<>", "<<", ">>", "->"}) {
		if strings.has_prefix(rest, operator) do return rest[:len(operator)]
	}
	return rest[:1]
}

// error_offset_of reads "line L, column C" from a parse error and turns it into a
// byte offset in `text`, or -1 when the message carries no position.
@(private)
error_offset_of :: proc(message: string, text: string) -> c.int {
	at := strings.index(message, "line ")
	if at < 0 do return -1
	rest := message[at + 5:]
	comma := strings.index(rest, ", column ")
	if comma < 0 do return -1
	line, line_ok := strconv.parse_int(rest[:comma], 10)
	tail := rest[comma + 9:]
	end := strings.index_any(tail, ":, ")
	if end < 0 do end = len(tail)
	column, column_ok := strconv.parse_int(tail[:end], 10)
	if !line_ok || !column_ok || line < 1 || column < 1 do return -1
	offset := 0
	for current := 1; current < line; current += 1 {
		newline := strings.index_byte(text[offset:], '\n')
		if newline < 0 do return -1
		offset += newline + 1
	}
	offset += column - 1
	if offset > len(text) do return -1
	return c.int(offset)
}

@(private)
prepare :: proc(handle: rawptr, sql: cstring, nByte: c.int, ppStmt: ^rawptr, pzTail: ^cstring) -> c.int {
	if pzTail != nil do pzTail^ = nil
	if ppStmt != nil do ppStmt^ = nil
	db := db_of(handle)
	if db == nil || sql == nil || ppStmt == nil do return SQLITE_MISUSE
	text := c_text(sql, nByte)
	// One statement per call, and the tail says where the next one starts, which
	// is the contract a caller that loops over a script depends on.
	end := statement_end(text)
	if pzTail != nil {
		base := uintptr(rawptr(sql))
		pzTail^ = transmute(cstring)(base + uintptr(end))
	}
	head := strings.trim_space(text[:end])
	db.error_offset = -1
	// Whitespace, semicolons or a comment and nothing else is not an error in
	// SQLite: there is no statement to prepare, and *ppStmt stays NULL.
	if only_space_or_comments(text[:end]) do return SQLITE_OK
	// A damaged image handed to sqlite3_deserialize: every statement says so,
	// as SQLite's does, until another image replaces it.
	if db.not_a_database {
		set_error(db, "file is not a database")
		db.last_code, db.last_extended = SQLITE_NOTADB, SQLITE_NOTADB
		return SQLITE_NOTADB
	}
	statement := engine.embed_prepare(db.conn, head)
	if statement == nil {
		// The engine reports where in `head` it stopped; SQLite reports where in
		// the caller's text, so the leading whitespace trimmed off counts.
		leading := strings.index(text, head)
		// An error at the very end is SQLite's "incomplete input", which carries no
		// offset.
		offset := error_offset_of(engine.embed_error(db.conn), head)
		if offset >= 0 && int(offset) < len(head) && leading >= 0 {
			db.error_offset = offset + c.int(leading)
		}
		// fail_connection records the message again, under another kind: the
		// kind is read first.
		syntax := engine.embed_error_kind(db.conn) == .Sql_Syntax
		code := fail_connection(db)
		// A syntax error reads as SQLite's: the token it stopped at, or
		// "incomplete input" when the text ended first.
		if syntax && db.conn.store.sqlite_rules && offset >= 0 {
			if int(offset) >= len(head) {
				engine.embed_note_error(db.conn, .Sql_Syntax, "incomplete input")
			} else {
				token := sqlite_token_at(head, int(offset))
				quote := token[0]
				closed := quote != '\'' && quote != '"' && quote != '`' && quote != '['
				if !closed {
					closing := quote == '[' ? u8(']') : quote
					closed = len(token) > 1 && token[len(token) - 1] == closing
				}
				if closed {
					engine.embed_note_error(db.conn, .Sql_Syntax, fmt.tprintf("near \"%s\": syntax error", token))
				} else {
					// A quote that never closes is a token SQLite cannot read: it
					// names the rest of the text.
					engine.embed_note_error(db.conn, .Sql_Syntax, fmt.tprintf("unrecognized token: \"%s\"", head[offset:]))
				}
			}
			set_error(db, engine.embed_error(db.conn))
		}
		return code
	}
	// A statement numbers its parameters up to the connection's limit.
	if c.int(engine.Embed_Parameter_Count(statement)) > connection_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER) {
		engine.embed_finalize(statement)
		return set_error_code(db, SQLITE_ERROR, "too many SQL variables")
	}
	stmt := new(Statement)
	stmt.db = db
	stmt.stmt = statement
	stmt.sql_text = strings.clone_to_cstring(text[:end])
	db.statements[rawptr(stmt)] = stmt
	engine.handle_register(rawptr(stmt))
	ppStmt^ = rawptr(stmt)
	return SQLITE_OK
}

@(export)
sqlite3_finalize :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	// Finalizing NULL is a harmless no-op in SQLite: a script loop finalizes
	// the NULL statement its last, empty, prepare gave.
	if handle == nil do return SQLITE_OK
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if stmt.db != nil do delete_key(&stmt.db.statements, handle)
	// The last statement of a connection sqlite3_close_v2 left open closes it.
	zombie := stmt.db != nil && stmt.db.zombie && len(stmt.db.statements) == 0 ? stmt.db : nil
	defer if zombie != nil do sqlite3_close(rawptr(zombie))
	engine.handle_forget(handle)
	stmt_clear_text_cache(stmt)
	delete(stmt.text_cache)
	delete(stmt.wide_cache)
	delete(stmt.value_cache)
	for units in stmt.wide_names do delete(units)
	delete(stmt.wide_names)
	delete(stmt.sql_text)
	for name in stmt.param_names do delete(name)
	delete(stmt.param_names)
	for origin in stmt.origins {
		delete(origin.database)
		delete(origin.table)
		delete(origin.column)
		delete(origin.decltype)
	}
	delete(stmt.origins)
	engine.embed_finalize(stmt.stmt)
	// The pointers go after the statement that could still read them.
	stmt_pointers_release(stmt)
	delete(stmt.pointers)
	free(stmt)
	return SQLITE_OK
}

@(export)
sqlite3_reset :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	stmt_clear_text_cache(stmt)
	trace_end(stmt)
	stmt.finished = false
	// A step that failed: reset answers its code and the connection keeps its
	// message, which a caller reads after resetting (Python's sqlite3 does).
	if stmt.error_code != SQLITE_OK {
		db := stmt.db
		message := strings.clone(engine.embed_error(db.conn), context.temp_allocator)
		kind := engine.embed_error_kind(db.conn)
		engine.embed_reset(stmt.stmt)
		engine.embed_note_error(db.conn, kind, message)
		db.last_code, db.last_extended = stmt.error_code, stmt.error_extended
		code := db.extended ? stmt.error_extended : stmt.error_code
		stmt.error_code, stmt.error_extended = SQLITE_OK, SQLITE_OK
		return code
	}
	engine.embed_reset(stmt.stmt)
	return SQLITE_OK
}

@(export)
sqlite3_clear_bindings :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	engine.embed_clear_bindings(stmt.stmt)
	stmt_pointers_release(stmt)
	return SQLITE_OK
}

@(export)
sqlite3_bind_null :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
	stmt_pointer_drop(stmt, int(index) - 1)
	if engine.error_drop(engine.embed_bind_null(stmt.stmt, int(index) - 1)) do return SQLITE_OK
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
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
	stmt_pointer_drop(stmt, int(index) - 1)
	if engine.error_drop(engine.embed_bind_int(stmt.stmt, int(index) - 1, i64(value))) do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_double :: proc "c" (handle: rawptr, index: c.int, value: c.double) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
	stmt_pointer_drop(stmt, int(index) - 1)
	// SQLite has no NaN: it binds NULL.
	if value != value {
		if engine.error_drop(engine.embed_bind_null(stmt.stmt, int(index) - 1)) do return SQLITE_OK
		return SQLITE_ERROR
	}
	if engine.error_drop(engine.embed_bind_float(stmt.stmt, int(index) - 1, f64(value))) do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_text :: proc "c" (handle: rawptr, index: c.int, value: cstring, length: c.int, destructor: rawptr) -> c.int {
	context = runtime.default_context()
	// SQLite runs the destructor once it no longer needs the text: the text is
	// copied, so that is when this returns, whatever the answer.
	defer release_with(rawptr(value), destructor)
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
	stmt_pointer_drop(stmt, int(index) - 1)
	// A NULL text binds NULL, as in SQLite.
	if value == nil {
		if engine.error_drop(engine.embed_bind_null(stmt.stmt, int(index) - 1)) do return SQLITE_OK
		return SQLITE_ERROR
	}
	// SQLite's contract: a non-negative length is the byte count, and only a
	// negative one means "up to the terminator". `string(value)` always stops at
	// the first NUL, so a text with one embedded used to arrive as zero bytes.
	text: string
	if length >= 0 {
		bytes := ([^]u8)(rawptr(value))
		text = string(bytes[:int(length)])
	} else {
		text = string(value)
	}
	if engine.error_drop(engine.embed_bind_text(stmt.stmt, int(index) - 1, text)) do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_blob :: proc "c" (handle: rawptr, index: c.int, data: rawptr, length: c.int, destructor: rawptr) -> c.int {
	context = runtime.default_context()
	defer release_with(data, destructor)
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
	stmt_pointer_drop(stmt, int(index) - 1)
	// A NULL pointer binds NULL; any other pointer binds a blob, an empty one
	// when the length is 0, as in SQLite.
	if data == nil {
		if engine.error_drop(engine.embed_bind_null(stmt.stmt, int(index) - 1)) do return SQLITE_OK
		return SQLITE_ERROR
	}
	bytes := ([^]u8)(data)[:max(int(length), 0)]
	if engine.error_drop(engine.embed_bind_blob(stmt.stmt, int(index) - 1, bytes)) do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_step :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if stmt.finished {
		set_error(stmt.db, "the statement already returned SQLITE_DONE; reset it first")
		return SQLITE_MISUSE
	}
	stmt_clear_text_cache(stmt)
	trace_start(stmt)
	mark := step_pointers_mark()
	has_row, err := engine.embed_step(stmt.stmt)
	step_pointers_end(mark)
	if err.kind != .None {
		code := fail(stmt.db, err)
		stmt.error_code, stmt.error_extended = stmt.db.last_code, stmt.db.last_extended
		trace_end(stmt)
		return code
	}
	stmt.error_code, stmt.error_extended = SQLITE_OK, SQLITE_OK
	if has_row {
		trace_row(stmt)
		return SQLITE_ROW
	}
	stmt.finished = true
	trace_end(stmt)
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
	if stmt == nil do return nil
	name := engine.embed_column_name(stmt.stmt, int(index))
	clone := strings.clone_to_cstring(name, context.allocator)
	append(&stmt.text_cache, clone)
	return clone
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
	// SQLite's conversion: text is read for its numeric prefix ('42' is 42).
	value, ok := engine.embed_column_value(stmt.stmt, int(index))
	if !ok do return 0
	return c.longlong(sqlite_to_i64(value))
}

@(export)
sqlite3_column_double :: proc "c" (handle: rawptr, index: c.int) -> c.double {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	value, ok := engine.embed_column_value(stmt.stmt, int(index))
	if !ok do return 0
	return c.double(sqlite_to_f64(value))
}

@(export)
sqlite3_column_text :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	text, is_null := column_text(stmt, int(index))
	if is_null do return nil
	return text
}

@(export)
sqlite3_column_blob :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	// Any value has a blob form, as in SQLite: a text's bytes, a number's
	// rendering. An empty one is NULL.
	value, ok := engine.embed_column_value(stmt.stmt, int(index))
	if !ok || value.kind == .Null do return nil
	#partial switch value.kind {
	case .Bytes:
		if len(value.bytes) == 0 do return nil
		return raw_data(value.bytes)
	case .String:
		if len(value.s) == 0 do return nil
		return raw_data(value.s)
	}
	text, _ := column_text(stmt, int(index))
	if text == nil || len(string(text)) == 0 do return nil
	return rawptr(text)
}

@(export)
sqlite3_column_bytes :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	// SQLite answers the size of the text or blob form of the value, which for a
	// number is the length of its rendering, not zero. The value is measured
	// before it becomes a C string: `len(string(cstring))` stops at an embedded
	// NUL, which is exactly the case a byte count exists for.
	value, ok := engine.embed_column_value(stmt.stmt, int(index))
	if !ok || value.kind == .Null do return 0
	#partial switch value.kind {
	case .String:
		return c.int(len(value.s))
	case .Bytes:
		return c.int(len(value.bytes))
	}
	rendered := engine.sqlite_value_text(value, context.allocator)
	defer delete(rendered)
	return c.int(len(rendered))
}

// --- Memory ----------------------------------------------------------------
//
// What the library hands a caller to free (an exec error message, an expanded
// statement) comes from sqlite3_malloc and goes back through sqlite3_free, as in
// SQLite. Each block carries its size in a header in front of it, which is what
// sqlite3_msize and sqlite3_realloc read.

SQLITE_ALLOC_HEADER :: 16

@(private)
sqlite_alloc :: proc(size: int) -> rawptr {
	if size <= 0 do return nil
	block, err := runtime.mem_alloc(size + SQLITE_ALLOC_HEADER, SQLITE_ALLOC_HEADER, runtime.heap_allocator())
	if err != nil || block == nil do return nil
	(^int)(raw_data(block))^ = size
	return rawptr(uintptr(raw_data(block)) + SQLITE_ALLOC_HEADER)
}

@(private)
sqlite_alloc_size :: proc(pointer: rawptr) -> int {
	if pointer == nil do return 0
	return (^int)(rawptr(uintptr(pointer) - SQLITE_ALLOC_HEADER))^
}

@(private)
sqlite_strdup :: proc(text: string) -> cstring {
	block := sqlite_alloc(len(text) + 1)
	if block == nil do return nil
	bytes := ([^]u8)(block)
	for i in 0 ..< len(text) do bytes[i] = text[i]
	bytes[len(text)] = 0
	return cstring(block)
}

@(export)
sqlite3_malloc :: proc "c" (size: c.int) -> rawptr {
	context = runtime.default_context()
	return sqlite_alloc(int(size))
}

@(export)
sqlite3_malloc64 :: proc "c" (size: u64) -> rawptr {
	context = runtime.default_context()
	if size > u64(max(int) - SQLITE_ALLOC_HEADER) do return nil
	return sqlite_alloc(int(size))
}

@(export)
sqlite3_realloc :: proc "c" (pointer: rawptr, size: c.int) -> rawptr {
	context = runtime.default_context()
	return sqlite3_realloc64(pointer, u64(max(size, 0)))
}

// sqlite3_realloc64 follows SQLite: a NULL pointer allocates, a zero size frees
// and answers NULL, and anything else keeps the bytes that fit.
@(export)
sqlite3_realloc64 :: proc "c" (pointer: rawptr, size: u64) -> rawptr {
	context = runtime.default_context()
	if pointer == nil do return sqlite3_malloc64(size)
	if size == 0 {
		sqlite3_free(pointer)
		return nil
	}
	grown := sqlite3_malloc64(size)
	if grown == nil do return nil
	keep := min(sqlite_alloc_size(pointer), int(size))
	runtime.mem_copy(grown, pointer, keep)
	sqlite3_free(pointer)
	return grown
}

@(export)
sqlite3_msize :: proc "c" (pointer: rawptr) -> u64 {
	context = runtime.default_context()
	return u64(sqlite_alloc_size(pointer))
}

@(export)
sqlite3_free :: proc "c" (pointer: rawptr) {
	context = runtime.default_context()
	if pointer == nil do return
	block := rawptr(uintptr(pointer) - SQLITE_ALLOC_HEADER)
	runtime.mem_free(block, runtime.heap_allocator())
}

// sqlite3_libversion is the SQLite release this facade answers as: the one
// its surface is measured against (docs/sqlite-roadmap.md), the same
// sqlite_version() answers in SQL. A program reads it as numbers; the
// facade's own name follows SQLite's source id in sqlite3_sourceid.
@(export)
sqlite3_libversion :: proc "c" () -> cstring {
	context = runtime.default_context()
	return "3.54.1"
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
	db := db_of(handle)
	if db == nil || db.conn == nil do return SQLITE_MISUSE
	// A write waits this long for another connection on the same file.
	engine.embed_set_busy_timeout(db.conn, int(milliseconds))
	return SQLITE_OK
}

@(export)
sqlite3_extended_result_codes :: proc "c" (handle: rawptr, onoff: c.int) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	db.extended = onoff != 0
	// The mode is a preference of the caller, not a state of the database, so
	// turning it off falls back to the primary code the last call answered.
	if !db.extended && db.last_extended != 0 do db.last_extended = db.last_code
	return SQLITE_OK
}


// --- What a query asks about its connection and statement -----------------

@(export)
sqlite3_last_insert_rowid :: proc "c" (handle: rawptr) -> c.longlong {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return 0
	return c.longlong(db.conn.store.last_row_id)
}

@(export)
sqlite3_set_last_insert_rowid :: proc "c" (handle: rawptr, rowid: c.longlong) {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return
	db.conn.store.last_row_id = i64(rowid)
}

@(export)
sqlite3_changes64 :: proc "c" (handle: rawptr) -> c.longlong {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return 0
	return c.longlong(engine.embed_last_changes(db.conn))
}

// sqlite3_total_changes64 counts every row INSERT, UPDATE and DELETE changed
// since the connection opened; it used to answer the last statement's count.
@(export)
sqlite3_total_changes64 :: proc "c" (handle: rawptr) -> c.longlong {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return 0
	return c.longlong(db.conn.store.total_changes)
}

// sqlite3_get_autocommit is 0 while a BEGIN or a SAVEPOINT holds a transaction
// open on the connection, and 1 otherwise.
@(export)
sqlite3_get_autocommit :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return 1
	return engine.embed_in_transaction(db.conn) ? 0 : 1
}

@(export)
sqlite3_db_handle :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	return rawptr(stmt.db)
}

// sqlite3_errstr is SQLite's English text for a result code. The codes this
// library never answers keep SQLite's text as well, so a caller that prints one
// reads the same words.
@(export)
sqlite3_errstr :: proc "c" (code: c.int) -> cstring {
	context = runtime.default_context()
	switch code {
	case 516:
		return "abort due to ROLLBACK"
	case SQLITE_ROW:
		return "another row available"
	case SQLITE_DONE:
		return "no more rows available"
	}
	switch code & 0xff {
	case 0:
		return "not an error"
	case 1:
		return "SQL logic error"
	case 3:
		return "access permission denied"
	case 4:
		return "query aborted"
	case 5:
		return "database is locked"
	case 6:
		return "database table is locked"
	case 7:
		return "out of memory"
	case 8:
		return "attempt to write a readonly database"
	case 9:
		return "interrupted"
	case 10:
		return "disk I/O error"
	case 11:
		return "database disk image is malformed"
	case 12:
		return "unknown operation"
	case 13:
		return "database or disk is full"
	case 14:
		return "unable to open database file"
	case 15:
		return "locking protocol"
	case 17:
		return "database schema has changed"
	case 18:
		return "string or blob too big"
	case 19:
		return "constraint failed"
	case 20:
		return "datatype mismatch"
	case 21:
		return "bad parameter or other API misuse"
	case 23:
		return "authorization denied"
	case 25:
		return "column index out of range"
	case 26:
		return "file is not a database"
	case 27:
		return "notification message"
	case 28:
		return "warning message"
	}
	return "unknown error"
}

// sqlite3_error_offset is the byte offset in the SQL text where the last
// prepare stopped, or -1 when the last error carries no position.
@(export)
sqlite3_error_offset :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return -1
	return db.error_offset
}

// sqlite3_sql is the text the statement was prepared from, as the caller wrote
// it, up to the end of the statement.
@(export)
sqlite3_sql :: proc "c" (handle: rawptr) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	return stmt.sql_text
}

@(export)
sqlite3_stmt_readonly :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return engine.embed_read_only(stmt.stmt) ? 1 : 0
}

// sqlite3_stmt_busy is 1 between the first step and the end of the statement
// (or a reset).
@(export)
sqlite3_stmt_busy :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return engine.embed_busy(stmt.stmt) && !stmt.finished ? 1 : 0
}

@(export)
sqlite3_stmt_isexplain :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return c.int(engine.embed_explain_mode(stmt.stmt))
}

// sqlite3_data_count is the column count while a row is available and 0
// otherwise: before the first step, after the last, and for a statement that
// returns no rows.
@(export)
sqlite3_data_count :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil || !engine.embed_has_row(stmt.stmt) do return 0
	return c.int(engine.embed_column_count(stmt.stmt))
}

SQLITE_STMTSTATUS_VM_STEP :: c.int(4)
SQLITE_STMTSTATUS_RUN :: c.int(6)

// sqlite3_stmt_status answers RUN (executions since prepare) and VM_STEP (one
// per step here, where SQLite counts bytecode instructions). The counters of a
// bytecode engine (full-scan steps, sorts, automatic indexes, bloom filters,
// re-prepares) have no meaning in this engine and answer 0.
@(export)
sqlite3_stmt_status :: proc "c" (handle: rawptr, op: c.int, reset: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	value := 0
	switch op {
	case SQLITE_STMTSTATUS_RUN:
		value = stmt.stmt.runs
		if reset != 0 do stmt.stmt.runs = 0
	case SQLITE_STMTSTATUS_VM_STEP:
		value = stmt.stmt.steps
		if reset != 0 do stmt.stmt.steps = 0
	}
	return c.int(value)
}

// sqlite3_bind_zeroblob binds a blob of n zero bytes, the placeholder a program
// fills afterwards with incremental blob I/O.
@(export)
sqlite3_bind_zeroblob :: proc "c" (handle: rawptr, index: c.int, n: c.int) -> c.int {
	context = runtime.default_context()
	return sqlite3_bind_zeroblob64(handle, index, u64(max(n, 0)))
}

@(export)
sqlite3_bind_zeroblob64 :: proc "c" (handle: rawptr, index: c.int, n: u64) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
	if n > 1 << 30 do return SQLITE_TOOBIG
	stmt_pointer_drop(stmt, int(index) - 1)
	zeros := make([]u8, int(n))
	defer delete(zeros)
	if engine.error_drop(engine.embed_bind_blob(stmt.stmt, int(index) - 1, zeros)) do return SQLITE_OK
	return SQLITE_ERROR
}

// sqlite3_libversion_number is libversion in SQLite's encoding: a program
// that checks it at start-up (Python's sqlite3 module does) reads the same
// release.
@(export)
sqlite3_libversion_number :: proc "c" () -> c.int {
	context = runtime.default_context()
	return 3054001
}

// SQLITE_SOURCE_ID is SQLite 3.54.1's: the check-in date and hash. A program
// built against SQLite's header compares the first 60 characters with its own
// SQLITE_SOURCE_ID (the command-line shell refuses to start on a mismatch),
// so they are SQLite's, and the facade's name follows them, the way SQLite
// marks a modified build at the end of the id.
SQLITE_SOURCE_ID :: "2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76 miraidb"

@(export)
sqlite3_sourceid :: proc "c" () -> cstring {
	return SQLITE_SOURCE_ID
}

// --- Where a result column comes from ----------------------------------------
//
// These answer for a column that names a table's column directly, and NULL for
// an expression, as SQLite does; see src/engine/describe.odin for what the
// description reads. They work right after prepare.

@(private)
column_origin :: proc(stmt: ^Statement, index: c.int) -> ^Column_Origin_C {
	if !stmt.described {
		stmt.described = true
		origins := engine.embed_column_origins(stmt.stmt)
		defer engine.embed_column_origins_destroy(origins)
		stmt.origins = make([]Column_Origin_C, len(origins))
		for origin, i in origins {
			if len(origin.table) == 0 do continue
			stmt.origins[i] = Column_Origin_C {
				database = strings.clone_to_cstring(origin.database),
				table    = strings.clone_to_cstring(origin.table),
				column   = strings.clone_to_cstring(origin.column),
				// A column declared without a type has none: NULL, as in SQLite.
				decltype = len(origin.decltype) > 0 ? strings.clone_to_cstring(origin.decltype) : nil,
			}
		}
	}
	if index < 0 || int(index) >= len(stmt.origins) do return nil
	return &stmt.origins[index]
}

@(export)
sqlite3_column_decltype :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	origin := column_origin(stmt, index)
	return origin == nil ? nil : origin.decltype
}

@(export)
sqlite3_column_table_name :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	origin := column_origin(stmt, index)
	return origin == nil ? nil : origin.table
}

@(export)
sqlite3_column_origin_name :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	origin := column_origin(stmt, index)
	return origin == nil ? nil : origin.column
}

@(export)
sqlite3_column_database_name :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	origin := column_origin(stmt, index)
	return origin == nil ? nil : origin.database
}

// --- Parameters by number and by name --------------------------------------

@(export)
sqlite3_bind_parameter_count :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return c.int(engine.Embed_Parameter_Count(stmt.stmt))
}

// sqlite3_bind_parameter_name is the parameter's name as written, prefix
// included (":id", "@id", "$id", "?3"), and NULL for a bare `?` or an index out
// of range. The string lives until the statement is finalized.
@(export)
sqlite3_bind_parameter_name :: proc "c" (handle: rawptr, index: c.int) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	count := engine.Embed_Parameter_Count(stmt.stmt)
	if int(index) < 1 || int(index) > count do return nil
	if stmt.param_names == nil {
		stmt.param_names = make([]cstring, count)
		for i in 0 ..< count {
			name := engine.embed_parameter_name(stmt.stmt, i)
			if len(name) > 0 do stmt.param_names[i] = strings.clone_to_cstring(name)
		}
	}
	return stmt.param_names[int(index) - 1]
}

// sqlite3_bind_parameter_index finds a parameter by its name, prefix included,
// and answers its 1-based index, or 0.
@(export)
sqlite3_bind_parameter_index :: proc "c" (handle: rawptr, name: cstring) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil || name == nil do return 0
	return c.int(engine.embed_parameter_index(stmt.stmt, string(name)) + 1)
}

// sql_literal writes a bound value the way SQLite's expanded SQL spells it:
// NULL, a number in its text form, a quoted string with its quotes doubled, a
// blob as x'..' in lower-case hex.
@(private)
sql_literal :: proc(b: ^strings.Builder, value: engine.Value) {
	#partial switch value.kind {
	case .Null, .Default:
		strings.write_string(b, "NULL")
	case .String:
		strings.write_byte(b, '\'')
		for i in 0 ..< len(value.s) {
			if value.s[i] == '\'' do strings.write_byte(b, '\'')
			strings.write_byte(b, value.s[i])
		}
		strings.write_byte(b, '\'')
	case .Bytes:
		strings.write_string(b, "x'")
		hex := "0123456789abcdef"
		for byte_value in value.bytes {
			strings.write_byte(b, hex[byte_value >> 4])
			strings.write_byte(b, hex[byte_value & 0xf])
		}
		strings.write_byte(b, '\'')
	case:
		rendered := engine.sqlite_value_text(value, context.allocator)
		defer delete(rendered)
		strings.write_string(b, rendered)
	}
}

@(private)
expand_is_ident_start :: proc(ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch >= 0x80
}

@(private)
expand_is_ident_char :: proc(ch: u8) -> bool {
	return expand_is_ident_start(ch) || (ch >= '0' && ch <= '9') || ch == '$'
}

// expand_sql is the statement's text with every parameter replaced by the value
// bound to it now. Strings, quoted names, comments and identifiers are copied
// as they are, so a `?` or a `:x` inside one is left alone.
@(private)
expand_sql :: proc(stmt: ^Statement) -> string {
	text := string(stmt.sql_text)
	b := strings.builder_make()
	next := 0 // the index a bare `?` takes: one past the largest seen so far
	i := 0
	for i < len(text) {
		ch := text[i]
		start := i
		switch {
		case ch == '\'' || ch == '"' || ch == '`':
			i += 1
			for i < len(text) {
				if text[i] == ch {
					if i + 1 < len(text) && text[i + 1] == ch {
						i += 2
						continue
					}
					i += 1
					break
				}
				i += 1
			}
			strings.write_string(&b, text[start:i])
		case ch == '[':
			for i < len(text) && text[i] != ']' do i += 1
			if i < len(text) do i += 1
			strings.write_string(&b, text[start:i])
		case ch == '-' && i + 1 < len(text) && text[i + 1] == '-':
			for i < len(text) && text[i] != '\n' do i += 1
			strings.write_string(&b, text[start:i])
		case ch == '/' && i + 1 < len(text) && text[i + 1] == '*':
			i += 2
			for i + 1 < len(text) && !(text[i] == '*' && text[i + 1] == '/') do i += 1
			i = min(i + 2, len(text))
			strings.write_string(&b, text[start:i])
		case expand_is_ident_start(ch):
			for i < len(text) && expand_is_ident_char(text[i]) do i += 1
			strings.write_string(&b, text[start:i])
		case ch == '?':
			i += 1
			for i < len(text) && text[i] >= '0' && text[i] <= '9' do i += 1
			index := next
			if i > start + 1 {
				number, _ := strconv.parse_int(text[start + 1:i], 10)
				index = number - 1
			}
			next = max(next, index + 1)
			sql_literal(&b, engine.embed_parameter_value(stmt.stmt, index))
		case (ch == ':' || ch == '@' || ch == '$') && i + 1 < len(text) && (expand_is_ident_start(text[i + 1]) || (ch == '$' && text[i + 1] >= '0' && text[i + 1] <= '9')) && !(ch == ':' && i > 0 && text[i - 1] == ':'):
			i += 1
			for i < len(text) && expand_is_ident_char(text[i]) do i += 1
			index := engine.embed_parameter_index(stmt.stmt, text[start:i])
			if index < 0 {
				strings.write_string(&b, text[start:i])
			} else {
				next = max(next, index + 1)
				sql_literal(&b, engine.embed_parameter_value(stmt.stmt, index))
			}
		case:
			i += 1
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b)
}

// sqlite3_expanded_sql is the statement's text with its bound values in place
// of its parameters, allocated with sqlite3_malloc for the caller to free.
@(export)
sqlite3_expanded_sql :: proc "c" (handle: rawptr) -> cstring {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	expanded := expand_sql(stmt)
	defer delete(expanded)
	// A text longer than SQLITE_LIMIT_LENGTH is not made: NULL, as in SQLite.
	if len(expanded) > int(connection_limit(stmt.db, SQLITE_LIMIT_LENGTH)) do return nil
	return sqlite_strdup(expanded)
}

// --- Incremental BLOB I/O --------------------------------------------------

// The handle reads and writes the row as SQLite's does: a write goes to the
// row at once, so a query sees it, and a change the handle did not make to its
// row (an UPDATE, a DELETE) expires it, after which reads and writes answer
// SQLITE_ABORT.

// blob_locate checks what sqlite3_blob_open names, with SQLite's messages,
// and answers the column that keys the row.
@(private)
blob_locate :: proc(db: ^Database, schema_name, table_name, column_name: string) -> (key: string, code: c.int) {
	if schema_name != "" && !strings.equal_fold(schema_name, "main") && !strings.equal_fold(schema_name, "temp") {
		return "", set_error_code(db, SQLITE_ERROR, fmt.tprintf("no such table: %s.%s", schema_name, table_name))
	}
	store := db.conn.store
	tx := db.conn.tx
	own := tx == nil
	if own do tx = engine.tx_begin_read(store)
	defer if own do engine.tx_end(tx)
	table, table_err := engine.tx_table(tx, table_name)
	if !engine.error_drop(table_err) || strings.has_prefix(table_name, "_") {
		return "", set_error_code(db, SQLITE_ERROR, fmt.tprintf("no such table: main.%s", table_name))
	}
	if table.schema.without_rowid {
		return "", set_error_code(db, SQLITE_ERROR, fmt.tprintf("cannot open table without rowid: %s", table_name))
	}
	found := false
	for column in table.schema.columns {
		if strings.equal_fold(column.name, column_name) do found = true
	}
	if !found do return "", set_error_code(db, SQLITE_ERROR, fmt.tprintf("no such column: \"%s\"", column_name))
	// A single-column integer primary key is the rowid, so it names the row; any
	// other table is named by its rowid, which every stored row has (F8).
	key = "rowid"
	if len(table.schema.primary_key) == 1 {
		position := table.schema.primary_key[0]
		if position >= 0 && position < len(table.schema.columns) && table.schema.columns[position].type.kind == .Int {
			key = table.schema.columns[position].name
		}
	}
	return key, SQLITE_OK
}

// blob_fetch reads the row's value: its bytes, whether it is text, whether
// the row is there.
@(private)
blob_fetch :: proc(db: ^Database, table, column, key: string, row: i64) -> (data: []u8, is_text: bool, has_row: bool, code: c.int) {
	query := strings.concatenate({"SELECT \"", column, "\" FROM \"", table, "\" WHERE ", key, " = ?"}, context.temp_allocator)
	stmt := engine.embed_prepare(db.conn, query)
	if stmt == nil do return nil, false, false, set_error_code(db, SQLITE_ERROR, "no such table")
	defer engine.embed_finalize(stmt)
	if err := engine.embed_bind_int(stmt, 0, row); err.kind != .None {
		set_error_from(db, err)
		return nil, false, false, SQLITE_ERROR
	}
	found, step_err := engine.embed_step(stmt)
	if step_err.kind != .None {
		set_error_from(db, step_err)
		return nil, false, false, SQLITE_ERROR
	}
	if !found do return nil, false, false, SQLITE_OK
	value, column_ok := engine.embed_column_value(stmt, 0)
	if !column_ok do return nil, false, true, SQLITE_ERROR
	#partial switch value.kind {
	case .Bytes:
		data = make([]u8, len(value.bytes))
		copy(data, value.bytes)
	case .String:
		data = make([]u8, len(value.s))
		copy(data, value.s)
		is_text = true
	case .Null:
		return nil, false, true, set_error_code(db, SQLITE_ERROR, "cannot open value of type null")
	case .Int, .Uint:
		return nil, false, true, set_error_code(db, SQLITE_ERROR, "cannot open value of type integer")
	case .Float:
		return nil, false, true, set_error_code(db, SQLITE_ERROR, "cannot open value of type real")
	}
	return data, is_text, true, SQLITE_OK
}

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
	key, locate_code := blob_locate(db, zDb == nil ? "" : string(zDb), table_name, column_name)
	if locate_code != SQLITE_OK do return locate_code
	data, is_text, has_row, code := blob_fetch(db, table_name, column_name, key, i64(iRow))
	if code != SQLITE_OK do return code
	if !has_row do return set_error_code(db, SQLITE_ERROR, "no such row")
	blob := new(Blob)
	blob.db = db
	blob.table = strings.clone(table_name)
	blob.column = strings.clone(column_name)
	blob.key = strings.clone(key)
	blob.row_id = i64(iRow)
	blob.data = data
	blob.is_text = is_text
	blob.writable = flags != 0
	ppBlob^ = rawptr(blob)
	return SQLITE_OK
}

// blob_current checks that the row still holds what the handle read or wrote;
// otherwise the handle expires, as SQLite expires it when the row changes.
@(private)
blob_current :: proc(blob: ^Blob) -> c.int {
	if !blob.expired {
		data, _, has_row, code := blob_fetch(blob.db, blob.table, blob.column, blob.key, blob.row_id)
		defer delete(data)
		if code != SQLITE_OK || !has_row || len(data) != len(blob.data) || string(data) != string(blob.data) {
			blob.expired = true
		}
	}
	if blob.expired do return set_error_code(blob.db, SQLITE_ABORT, "query aborted")
	return SQLITE_OK
}

@(export)
sqlite3_blob_bytes :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil || blob.expired do return 0
	return c.int(len(blob.data))
}

@(export)
sqlite3_blob_read :: proc "c" (handle: rawptr, buffer: rawptr, count: c.int, offset: c.int) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil || buffer == nil do return SQLITE_MISUSE
	if count < 0 || offset < 0 || int(offset) + int(count) > len(blob.data) {
		return set_error_code(blob.db, SQLITE_ERROR, "SQL logic error")
	}
	if code := blob_current(blob); code != SQLITE_OK do return code
	target := ([^]u8)(buffer)
	for i in 0 ..< int(count) do target[i] = blob.data[int(offset) + i]
	return SQLITE_OK
}

@(export)
sqlite3_blob_write :: proc "c" (handle: rawptr, buffer: rawptr, count: c.int, offset: c.int) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil || buffer == nil do return SQLITE_MISUSE
	if !blob.writable do return set_error_code(blob.db, SQLITE_READONLY, "attempt to write a readonly database")
	// The size comes from the row: a write cannot grow the blob, matching
	// SQLite's contract that growth goes through zeroblob and a full rewrite.
	if count < 0 || offset < 0 || int(offset) + int(count) > len(blob.data) {
		return set_error_code(blob.db, SQLITE_ERROR, "SQL logic error")
	}
	if code := blob_current(blob); code != SQLITE_OK do return code
	source := ([^]u8)(buffer)
	for i in 0 ..< int(count) do blob.data[int(offset) + i] = source[i]
	update := strings.concatenate({"UPDATE \"", blob.table, "\" SET \"", blob.column, "\" = ? WHERE ", blob.key, " = ?"}, context.temp_allocator)
	stmt := engine.embed_prepare(blob.db.conn, update)
	if stmt == nil {
		blob.expired = true
		return set_error_code(blob.db, SQLITE_ERROR, "SQL logic error")
	}
	defer engine.embed_finalize(stmt)
	// Text stays text, as SQLite writes a text value's bytes in place.
	if blob.is_text {
		_ = engine.error_drop(engine.embed_bind_text(stmt, 0, string(blob.data)))
	} else {
		_ = engine.error_drop(engine.embed_bind_blob(stmt, 0, blob.data))
	}
	_ = engine.error_drop(engine.embed_bind_int(stmt, 1, blob.row_id))
	if _, step_err := engine.embed_step(stmt); step_err.kind != .None {
		blob.expired = true
		set_error_from(blob.db, step_err)
		return SQLITE_ERROR
	}
	return SQLITE_OK
}

@(export)
sqlite3_blob_close :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil do return SQLITE_OK
	delete(blob.data)
	delete(blob.table)
	delete(blob.column)
	delete(blob.key)
	free(blob)
	return SQLITE_OK
}

@(export)
sqlite3_blob_reopen :: proc "c" (handle: rawptr, iRow: c.longlong) -> c.int {
	context = runtime.default_context()
	blob := blob_of(handle)
	if blob == nil do return SQLITE_MISUSE
	data, is_text, has_row, code := blob_fetch(blob.db, blob.table, blob.column, blob.key, i64(iRow))
	if code == SQLITE_OK && !has_row do code = set_error_code(blob.db, SQLITE_ERROR, "no such row")
	if code != SQLITE_OK {
		// A failed reopen leaves the handle expired, as SQLite's does.
		blob.expired = true
		return code
	}
	delete(blob.data)
	blob.data = data
	blob.is_text = is_text
	blob.row_id = i64(iRow)
	blob.expired = false
	return SQLITE_OK
}
