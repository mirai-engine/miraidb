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
import "core:strconv"
import "core:strings"

import engine "../engine"

SQLITE_OK :: c.int(0)
SQLITE_ERROR :: c.int(1)
// The primary result codes a caller switches on. They are SQLite's numbers, so a
// program written against the classic API reads the same reason it always did
// (D25): a duplicate key is SQLITE_CONSTRAINT, an interrupted statement is
// SQLITE_INTERRUPT, and so on.
SQLITE_BUSY :: c.int(5)
SQLITE_NOMEM :: c.int(7)
SQLITE_READONLY :: c.int(8)
SQLITE_INTERRUPT :: c.int(9)
SQLITE_IOERR :: c.int(10)
SQLITE_CORRUPT :: c.int(11)
SQLITE_TOOBIG :: c.int(13)
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
// semicolon, or the end of the text. Quotes, comments and blob literals are
// walked, so a semicolon inside one does not end a statement. SQLite exposes the
// same boundary through pzTail (F5).
@(private)
statement_end :: proc(sql: string) -> int {
	i := 0
	for i < len(sql) {
		ch := sql[i]
		if ch == '\'' || ch == '"' || ch == '`' {
			quote := ch
			i += 1
			for i < len(sql) {
				if sql[i] == quote {
					if i + 1 < len(sql) && sql[i + 1] == quote {
						i += 2
						continue
					}
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		if ch == '[' {
			i += 1
			for i < len(sql) && sql[i] != ']' do i += 1
			if i < len(sql) do i += 1
			continue
		}
		if ch == '-' && i + 1 < len(sql) && sql[i + 1] == '-' {
			i += 2
			for i < len(sql) && sql[i] != '\n' do i += 1
			continue
		}
		if ch == '/' && i + 1 < len(sql) && sql[i + 1] == '*' {
			i += 2
			for i + 1 < len(sql) && !(sql[i] == '*' && sql[i + 1] == '/') do i += 1
			if i + 1 < len(sql) do i += 2
			else do i = len(sql)
			continue
		}
		if ch == ';' do return i + 1
		i += 1
	}
	return len(sql)
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
	return string(bytes[:int(nByte)])
}

// fail_connection reports the connection's last error with the message it holds,
// for the paths that call the engine without an Error value of their own.
@(private)
fail_connection :: proc(db: ^Database) -> c.int {
	if db == nil do return SQLITE_ERROR
	set_error(db, engine.embed_error(db.conn))
	db.last_code = SQLITE_ERROR
	db.last_extended = SQLITE_ERROR
	return SQLITE_ERROR
}

@(private)
stmt_clear_text_cache :: proc(stmt: ^Statement) {
	if stmt == nil do return
	for text in stmt.text_cache do delete(text)
	clear(&stmt.text_cache)
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
	if !engine.error_drop(table_err) do return "", false
	if len(table.schema.primary_key) != 1 do return "", false
	position := table.schema.primary_key[0]
	if position < 0 || position >= len(table.schema.columns) do return "", false
	return table.schema.columns[position].name, true
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
	case .Duplicate_Primary_Key, .Duplicate_Unique, .Not_Null_Violation, .Check_Violation:
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
	set_error(db, err.message)
	code := sqlite_code(err)
	if db != nil {
		db.last_code = code
		db.last_extended = sqlite_extended_code(err)
	}
	// A caller in extended mode reads the narrow code from the return value as
	// well, so the check it wrote next to sqlite3_step keeps working.
	if db != nil && db.extended && db.last_extended != code do return db.last_extended
	return code
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
	if !engine.error_drop(err) {
		ppDb^ = nil
		return SQLITE_ERROR
	}
	db := new(Database)
	db.conn = conn
	db.error_offset = -1
	db.in_memory = in_memory
	db.statements = make(map[rawptr]^Statement)
	engine.handle_register(rawptr(db))
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

// exec_with_callback runs one statement and calls back once per row. This is the
// contract sqlite3_exec exists for: the shell's .dump, a bulk loader, anything
// that reads rows without preparing a statement. A non-zero answer from the
// callback stops the statement, as SQLite documents.
@(private)
exec_with_callback :: proc(db: ^Database, sql: string, callback: Exec_Callback, arg: rawptr) -> c.int {
	stmt := engine.embed_prepare(db.conn, sql)
	if stmt == nil do return fail_connection(db)
	defer engine.embed_finalize(stmt)
	count := engine.embed_column_count(stmt)
	names := make([]cstring, count, context.allocator)
	defer {
		for name in names do if name != nil do delete(name)
		delete(names)
	}
	for i in 0 ..< count {
		names[i] = strings.clone_to_cstring(engine.embed_column_name(stmt, i), context.allocator)
	}
	values := make([]cstring, count, context.allocator)
	defer delete(values)
	for {
		for i in 0 ..< count {
			if values[i] != nil {
				delete(values[i])
				values[i] = nil
			}
		}
		has_row, step_err := engine.embed_step(stmt)
		if step_err.kind != .None do return fail(db, step_err)
		if !has_row do break
		for i in 0 ..< count {
			value, ok := engine.embed_column_value(stmt, i)
			if !ok || value.kind == .Null do continue
			rendered := engine.sqlite_value_text(value, context.allocator)
			values[i] = strings.clone_to_cstring(rendered, context.allocator)
			delete(rendered)
		}
		if callback(arg, c.int(count), raw_data(values), raw_data(names)) != 0 do break
	}
	return SQLITE_OK
}

@(export)
sqlite3_exec :: proc "c" (handle: rawptr, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int {
	context = runtime.default_context()
	if errmsg != nil do errmsg^ = nil
	db := db_of(handle)
	if db == nil || sql == nil do return SQLITE_MISUSE
	// The text may hold several statements, which is what every caller of exec
	// passes: each one runs, and the first failure stops the rest.
	remaining := string(sql)
	for len(remaining) > 0 {
		end := statement_end(remaining)
		if end <= 0 do break
		statement := strings.trim_space(remaining[:end])
		remaining = remaining[end:]
		if !only_space_or_comments(statement) {
			code: c.int
			if callback != nil {
				code = exec_with_callback(db, statement, cast(Exec_Callback)callback, arg)
			} else if err := engine.embed_exec(db.conn, statement); err.kind != .None {
				code = fail(db, err)
			}
			if code != SQLITE_OK {
				// The message is the caller's, freed with sqlite3_free as in SQLite.
				if errmsg != nil && len(db.last_error) > 0 do errmsg^ = sqlite_strdup(db.last_error)
				return code
			}
			db.last_code = SQLITE_OK
			db.last_extended = SQLITE_OK
		}
	}
	return SQLITE_OK
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
	statement := engine.embed_prepare(db.conn, head)
	if statement == nil {
		// The engine reports where in `head` it stopped; SQLite reports where in
		// the caller's text, so the leading whitespace trimmed off counts.
		leading := strings.index(text, head)
		// An error at the very end is SQLite's "incomplete input", which carries no
		// offset.
		if offset := error_offset_of(engine.embed_error(db.conn), head); offset >= 0 && int(offset) < len(head) && leading >= 0 {
			db.error_offset = offset + c.int(leading)
		}
		return fail_connection(db)
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
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if stmt.db != nil do delete_key(&stmt.db.statements, handle)
	engine.handle_forget(handle)
	stmt_clear_text_cache(stmt)
	delete(stmt.text_cache)
	delete(stmt.sql_text)
	for name in stmt.param_names do delete(name)
	delete(stmt.param_names)
	engine.embed_finalize(stmt.stmt)
	free(stmt)
	return SQLITE_OK
}

@(export)
sqlite3_reset :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	stmt_clear_text_cache(stmt)
	stmt.finished = false
	engine.embed_reset(stmt.stmt)
	return SQLITE_OK
}

@(export)
sqlite3_clear_bindings :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	engine.embed_clear_bindings(stmt.stmt)
	return SQLITE_OK
}

@(export)
sqlite3_bind_null :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
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
	if engine.error_drop(engine.embed_bind_int(stmt.stmt, int(index) - 1, i64(value))) do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_double :: proc "c" (handle: rawptr, index: c.int, value: c.double) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
	if engine.error_drop(engine.embed_bind_float(stmt.stmt, int(index) - 1, f64(value))) do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_text :: proc "c" (handle: rawptr, index: c.int, value: cstring, length: c.int, destructor: rawptr) -> c.int {
	context = runtime.default_context()
	_ = destructor
	stmt := stmt_of(handle)
	if stmt == nil || value == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
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
	context = runtime.default_context()
	_ = destructor
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if data == nil || length <= 0 {
		if engine.error_drop(engine.embed_bind_null(stmt.stmt, int(index) - 1)) do return SQLITE_OK
		return SQLITE_ERROR
	}
	bytes := make([]u8, int(length))
	defer delete(bytes)
	source := ([^]u8)(data)
	for i in 0 ..< int(length) do bytes[i] = source[i]
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
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
	has_row, err := engine.embed_step(stmt.stmt)
	if err.kind != .None {
		return fail(stmt.db, err)
	}
	if has_row do return SQLITE_ROW
	stmt.finished = true
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
	bytes := engine.embed_column_blob(stmt.stmt, int(index))
	if len(bytes) == 0 do return nil
	return raw_data(bytes)
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

@(export)
sqlite3_column_bytes16 :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	return sqlite3_column_bytes(handle, index)
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
	zeros := make([]u8, int(n))
	defer delete(zeros)
	if engine.error_drop(engine.embed_bind_blob(stmt.stmt, int(index) - 1, zeros)) do return SQLITE_OK
	return SQLITE_ERROR
}

// sqlite3_libversion_number is the SQLite release this facade answers as,
// 3.45.0, in SQLite's encoding: a program that checks it at start-up (Python's
// sqlite3 module does) reads the version libversion names.
@(export)
sqlite3_libversion_number :: proc "c" () -> c.int {
	context = runtime.default_context()
	return 3045000
}

@(export)
sqlite3_sourceid :: proc "c" () -> cstring {
	context = runtime.default_context()
	return "miraidb sqlite3 facade"
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
	return sqlite_strdup(expanded)
}

// --- Incremental BLOB I/O --------------------------------------------------

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
	// A single-column integer primary key is the rowid, so it names the row; any
	// other table is named by its rowid, which every stored row has (F8).
	key_column, key_ok := blob_key_column(db, table_name)
	if !key_ok do key_column = "rowid"
	query := strings.concatenate({"SELECT ", column_name, " FROM ", table_name, " WHERE ", key_column, " = ?"})
	defer delete(query)
	stmt := engine.embed_prepare(db.conn, query)
	if stmt == nil do return SQLITE_ERROR
	defer engine.embed_finalize(stmt)
	if err := engine.embed_bind_int(stmt, 0, i64(iRow)); err.kind != .None {
		set_error_from(db, err)
		return SQLITE_ERROR
	}
	has_row, step_err := engine.embed_step(stmt)
	if step_err.kind != .None {
		set_error_from(db, step_err)
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
			_ = engine.error_drop(engine.embed_bind_blob(stmt, 0, blob.data))
			_ = engine.error_drop(engine.embed_bind_int(stmt, 1, blob.row_id))
			if _, step_err := engine.embed_step(stmt); step_err.kind != .None {
				set_error_from(blob.db, step_err)
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
	_ = engine.error_drop(engine.embed_bind_int(stmt, 0, i64(iRow)))
	has_row, step_err := engine.embed_step(stmt)
	if step_err.kind != .None || !has_row {
		if step_err.kind != .None do set_error_from(blob.db, step_err)
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
