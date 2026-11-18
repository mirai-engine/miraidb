package sqlite_compat

// What a program or a binding links against besides the statement loop: the
// window functions, sqlite3_complete, the per-connection limits and
// configuration, extension loading, and the small string helpers. Python's own
// sqlite3 module links every one of them (scripts/python_sqlite3.py).

import "base:runtime"
import "core:c"
import "core:strings"
import "core:time"
import "core:unicode/utf16"

import engine "../engine"

// sqlite3_create_window_function registers an aggregate that is also a window
// function: over a window, rows enter its context with xStep and leave it with
// xInverse, and xValue answers for each row, as SQLite calls them.
@(export)
sqlite3_create_window_function :: proc "c" (
	handle: rawptr,
	name: cstring,
	arity: c.int,
	text_rep: c.int,
	user: rawptr,
	step: Function_Callback,
	final: Final_Callback,
	value: Final_Callback,
	inverse: Function_Callback,
	destroy: Destroy_Callback,
) -> c.int {
	context = runtime.default_context()
	// All four or none, as SQLite asks.
	given := int(step != nil) + int(final != nil) + int(value != nil) + int(inverse != nil)
	if given != 0 && given != 4 {
		if destroy != nil do destroy(user)
		return SQLITE_MISUSE
	}
	code := create_function(handle, name, arity, user, nil, step, final, destroy, text_rep)
	if code != SQLITE_OK || given == 0 do return code
	db := db_of(handle)
	for fn in db.functions {
		if fn.arity == int(arity) && strings.equal_fold(fn.name, string(name)) {
			fn.value = value
			fn.inverse = inverse
		}
	}
	engine.store_set_aggregate_window(db.conn.store, string(name), int(arity), facade_value, facade_inverse)
	return SQLITE_OK
}

// sqlite3_complete answers 1 when the text ends a statement: its last
// semicolon closes one (not inside a quote, a comment or a trigger body) and
// only spaces or comments follow.
@(export)
sqlite3_complete :: proc "c" (sql: cstring) -> c.int {
	context = runtime.default_context()
	if sql == nil do return 0
	return sql_complete(string(sql)) ? 1 : 0
}

@(export)
sqlite3_complete16 :: proc "c" (sql: rawptr) -> c.int {
	context = runtime.default_context()
	if sql == nil do return 0
	units := ([^]u16)(sql)
	n := 0
	for units[n] != 0 do n += 1
	buffer := make([]u8, n * 4 + 1, context.temp_allocator)
	written := utf16.decode_to_utf8(buffer, units[:n])
	return sql_complete(string(buffer[:written])) ? 1 : 0
}

// SQLITE_EMPTY is what sqlite3_incomplete answers for text that holds no
// statement.
SQLITE_EMPTY :: 16

// sql_incomplete is SQLite 3.54's sqlite3_incomplete (complete.c): 0 when the
// text is complete (every comment, literal and quoted name closed, and it ends
// with ";", or ";END;" for CREATE TRIGGER), SQLITE_EMPTY when it is only
// spaces and comments, and otherwise a value that says what is missing: the
// low byte SQLITE_ERROR, the next 1 for a semicolon, 2 for "END;", 3 for both,
// the third the quote or comment left open, and the upper half the "(" left
// unmatched.
@(private)
sql_incomplete :: proc(text: string) -> i64 {
	SEMI, WS, OTHER, EXPLAIN, CREATE, TEMP, TRIGGER, END :: 0, 1, 2, 3, 4, 5, 6, 7
	trans := [8][8]u8 {
		{1, 0, 2, 3, 4, 2, 2, 2},
		{1, 1, 2, 3, 4, 2, 2, 2},
		{1, 2, 2, 2, 2, 2, 2, 2},
		{1, 3, 3, 2, 4, 2, 2, 2},
		{1, 4, 2, 2, 2, 4, 5, 2},
		{6, 5, 5, 5, 5, 5, 5, 5},
		{6, 6, 5, 5, 5, 5, 5, 7},
		{1, 7, 5, 5, 5, 5, 5, 5},
	}
	statemap := [8]u8{0, 0, 1, 1, 1, 3, 2, 1}
	id_char :: proc(b: u8) -> bool {
		return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b == '$' || b >= 0x80
	}
	state: u8 = 0
	pending: u8 = 0
	parens: i32 = 0
	i := 0
	scan: for i < len(text) {
		token := OTHER
		switch text[i] {
		case ';':
			token = SEMI
		case ' ', '\r', '\t', '\n', '\f':
			token = WS
		case '/':
			if i + 1 >= len(text) || text[i + 1] != '*' do break
			i += 2
			for i < len(text) && !(text[i] == '*' && i + 1 < len(text) && text[i + 1] == '/') do i += 1
			if i >= len(text) {
				pending = '/'
				break scan
			}
			i += 1
			token = WS
		case '-':
			if i + 1 >= len(text) || text[i + 1] != '-' do break
			for i < len(text) && text[i] != '\n' do i += 1
			if i >= len(text) {
				pending = '-'
				break scan
			}
			token = WS
		case '[':
			i += 1
			for i < len(text) && text[i] != ']' do i += 1
			if i >= len(text) {
				pending = ']'
				break scan
			}
		case '`', '"', '\'':
			quote := text[i]
			i += 1
			for i < len(text) && text[i] != quote do i += 1
			if i >= len(text) {
				pending = quote
				break scan
			}
		case '(':
			parens += 1
		case ')':
			parens -= 1
		case:
			if !id_char(text[i]) do break
			n := 1
			for i + n < len(text) && id_char(text[i + n]) do n += 1
			word := text[i:i + n]
			switch {
			case strings.equal_fold(word, "create"):
				token = CREATE
			case strings.equal_fold(word, "trigger"):
				token = TRIGGER
			case strings.equal_fold(word, "temp"), strings.equal_fold(word, "temporary"):
				token = TEMP
			case strings.equal_fold(word, "end"):
				token = END
			case strings.equal_fold(word, "explain"):
				token = EXPLAIN
			}
			i += n - 1
		}
		state = trans[state][token]
		i += 1
	}
	if state == 0 && pending == 0 do return SQLITE_EMPTY
	if state == 1 do parens = 0
	incomplete: u64 = (state > 1 || pending != 0) ? 1 : 0
	return i64(u64(u32(parens)) << 32 | u64(pending) << 16 | u64(statemap[state]) << 8 | incomplete)
}

@(private)
sql_complete :: proc(text: string) -> bool {
	return sql_incomplete(text) == 0
}

// sqlite3_incomplete is sql_incomplete for a C string; NULL is SQLITE_MISUSE.
@(export)
sqlite3_incomplete :: proc "c" (sql: cstring) -> i64 {
	context = runtime.default_context()
	if sql == nil do return i64(SQLITE_MISUSE)
	return sql_incomplete(string(sql))
}

// Limits: SQLite's defaults, kept per connection. A program may lower one;
// the engine enforces SQLITE_LIMIT_SQL_LENGTH and SQLITE_LIMIT_LENGTH here,
// and the rest are answered as set.
SQLITE_LIMIT_LENGTH :: 0
SQLITE_LIMIT_SQL_LENGTH :: 1
SQLITE_LIMIT_FUNCTION_ARG :: 6
SQLITE_LIMIT_VARIABLE_NUMBER :: 9
SQLITE_LIMIT_COUNT :: 12

@(private)
LIMIT_DEFAULTS := [SQLITE_LIMIT_COUNT]c.int {
	1_000_000_000, // LENGTH
	1_000_000_000, // SQL_LENGTH
	2000,          // COLUMN
	1000,          // EXPR_DEPTH
	500,           // COMPOUND_SELECT
	250_000_000,   // VDBE_OP
	1000,          // FUNCTION_ARG
	10,            // ATTACHED
	50_000,        // LIKE_PATTERN_LENGTH
	32766,         // VARIABLE_NUMBER
	1000,          // TRIGGER_DEPTH
	0,             // WORKER_THREADS
}

// connection_limit is one limit of a connection.
@(private)
connection_limit :: proc(db: ^Database, id: int) -> c.int {
	if !db.limits_set do return LIMIT_DEFAULTS[id]
	return db.limits[id]
}

@(export)
sqlite3_limit :: proc "c" (handle: rawptr, id: c.int, value: c.int) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil || id < 0 || id >= SQLITE_LIMIT_COUNT do return -1
	if !db.limits_set {
		db.limits = LIMIT_DEFAULTS
		db.limits_set = true
	}
	previous := db.limits[id]
	// A new value is clamped to the default, which is also the hard limit.
	if value >= 0 do db.limits[id] = min(value, LIMIT_DEFAULTS[id])
	if id == SQLITE_LIMIT_FUNCTION_ARG do db.conn.store.function_arg_limit = int(db.limits[id])
	return previous
}

// The configuration options a connection answers, with SQLite's defaults.
// SQLITE_DBCONFIG_ENABLE_FKEY is PRAGMA foreign_keys.
SQLITE_DBCONFIG_MAINDBNAME :: 1000
SQLITE_DBCONFIG_LOOKASIDE :: 1001
SQLITE_DBCONFIG_ENABLE_FKEY :: 1002
SQLITE_DBCONFIG_FIRST_FLAG :: 1002
SQLITE_DBCONFIG_LAST_FLAG :: 1022

@(private)
dbconfig_default :: proc(op: int) -> c.int {
	switch op {
	case 1003, 1013, 1014, 1015, 1017, 1020, 1021, 1022:
		// ENABLE_TRIGGER, DQS_DML, DQS_DDL, ENABLE_VIEW, TRUSTED_SCHEMA,
		// ATTACH_CREATE, ATTACH_WRITE, COMMENTS are on.
		return 1
	}
	return 0
}

// sqlite3_db_config takes the option and, for a flag, an int (negative to
// only ask) and an int* that receives the setting. It is variadic in C; the
// arguments arrive where fixed ones would on the platforms this builds for.
@(export)
sqlite3_db_config :: proc "c" (handle: rawptr, op: c.int, first: uintptr, second: uintptr, third: uintptr) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	switch {
	case op == SQLITE_DBCONFIG_MAINDBNAME, op == SQLITE_DBCONFIG_LOOKASIDE:
		return SQLITE_OK
	case op >= SQLITE_DBCONFIG_FIRST_FLAG && op <= SQLITE_DBCONFIG_LAST_FLAG:
		onoff := c.int(i32(u32(first)))
		out := (^c.int)(rawptr(second))
		index := int(op) - SQLITE_DBCONFIG_FIRST_FLAG
		if !db.config_set {
			for i in 0 ..< len(db.config) do db.config[i] = dbconfig_default(SQLITE_DBCONFIG_FIRST_FLAG + i)
			db.config_set = true
		}
		if op == SQLITE_DBCONFIG_ENABLE_FKEY {
			db.config[index] = db.conn.store.foreign_keys_off ? 0 : 1
			if onoff >= 0 && db.conn.tx == nil do db.conn.store.foreign_keys_off = onoff == 0
			db.config[index] = db.conn.store.foreign_keys_off ? 0 : 1
		} else if onoff >= 0 {
			db.config[index] = onoff != 0 ? 1 : 0
		}
		if op == 1005 do db.extensions_enabled = db.config[index] != 0
		if out != nil do out^ = db.config[index]
		return SQLITE_OK
	}
	return SQLITE_ERROR
}

// Extensions: a SQLite extension is a shared library built against SQLite's
// own internals, which this library is not, so loading one is refused with
// a reason. Enabling the call is accepted.
@(export)
sqlite3_enable_load_extension :: proc "c" (handle: rawptr, onoff: c.int) -> c.int {
	context = runtime.default_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	db.extensions_enabled = onoff != 0
	return SQLITE_OK
}

@(export)
sqlite3_load_extension :: proc "c" (handle: rawptr, file: cstring, entry: cstring, errmsg: ^cstring) -> c.int {
	context = runtime.default_context()
	if errmsg != nil do errmsg^ = nil
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	message := "not authorized"
	if db.extensions_enabled do message = "loading a SQLite extension is not supported by this library"
	set_error(db, message)
	db.last_code, db.last_extended = SQLITE_ERROR, SQLITE_ERROR
	if errmsg != nil {
		block := ([^]u8)(sqlite_alloc(len(message) + 1))
		if block != nil {
			copy(block[:len(message)], message)
			block[len(message)] = 0
			errmsg^ = cstring(block)
		}
	}
	return SQLITE_ERROR
}

@(export)
sqlite3_enable_shared_cache :: proc "c" (onoff: c.int) -> c.int {
	return SQLITE_OK
}

// The library is safe to use from several threads, each connection from one
// at a time.
@(export)
sqlite3_threadsafe :: proc "c" () -> c.int {
	return 1
}

@(export)
sqlite3_sleep :: proc "c" (milliseconds: c.int) -> c.int {
	context = runtime.default_context()
	if milliseconds > 0 do time.sleep(time.Duration(milliseconds) * time.Millisecond)
	return max(milliseconds, 0)
}

@(private)
ascii_lower :: proc "contextless" (c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

// sqlite3_stricmp and sqlite3_strnicmp compare ignoring ASCII case; a NULL
// sorts first.
@(export)
sqlite3_stricmp :: proc "c" (a: cstring, b: cstring) -> c.int {
	return sqlite3_strnicmp(a, b, max(c.int))
}

@(export)
sqlite3_strnicmp :: proc "c" (a: cstring, b: cstring, n: c.int) -> c.int {
	if a == nil do return b == nil ? 0 : -1
	if b == nil do return 1
	left := ([^]u8)(a)
	right := ([^]u8)(b)
	for i in 0 ..< int(n) {
		x, y := ascii_lower(left[i]), ascii_lower(right[i])
		if x != y do return c.int(x) - c.int(y)
		if x == 0 do return 0
	}
	return 0
}

// sqlite3_strglob and sqlite3_strlike answer 0 for a match, as SQLite does.
@(export)
sqlite3_strglob :: proc "c" (pattern: cstring, text: cstring) -> c.int {
	context = runtime.default_context()
	if pattern == nil || text == nil do return 1
	return engine.glob_match(string(text), string(pattern)) ? 0 : 1
}

@(export)
sqlite3_strlike :: proc "c" (pattern: cstring, text: cstring, escape: c.uint) -> c.int {
	context = runtime.default_context()
	if pattern == nil || text == nil do return 1
	return engine.like_match(string(text), string(pattern), true, u8(escape)) ? 0 : 1
}
