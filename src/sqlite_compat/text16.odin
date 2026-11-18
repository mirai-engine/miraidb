package sqlite_compat

// The UTF-16 face of the API. A program on Windows, or one that keeps its
// strings in UTF-16, opens, prepares, binds, reads and reports errors through
// the `16` variants: SQLite converts at the boundary, and so does this. Every
// text is UTF-8 inside; a UTF-16 answer is converted when asked and lives as
// long as SQLite promises its own does: a column's text until the statement
// moves, a column's name until finalize, a value's text as long as the value,
// the error message until the next call that changes it.
//
// "16" alone is the machine's byte order; LE and BE name one.

import "base:runtime"
import "core:c"
import "core:strings"

import engine "../engine"

SQLITE_UTF16LE :: c.int(2)
SQLITE_UTF16BE :: c.int(3)
SQLITE_UTF16 :: c.int(4)

NATIVE_BIG_ENDIAN :: ODIN_ENDIAN == .Big

// utf16_encode turns UTF-8 text into NUL-terminated UTF-16 in the given byte
// order. A byte that is not UTF-8 becomes U+FFFD.
@(private)
utf16_encode :: proc(text: string, big_endian: bool, allocator := context.allocator) -> []u16 {
	units := make([dynamic]u16, 0, len(text) + 1, allocator)
	for r in text {
		if r >= 0x10000 {
			rest := u32(r) - 0x10000
			append(&units, u16(0xD800 + (rest >> 10)), u16(0xDC00 + (rest & 0x3FF)))
		} else {
			append(&units, u16(r))
		}
	}
	append(&units, 0)
	if big_endian != NATIVE_BIG_ENDIAN {
		for &unit in units do unit = (unit >> 8) | (unit << 8)
	}
	return units[:]
}

// utf16_decode turns UTF-16 in the given byte order into UTF-8: `n` bytes, or
// up to the NUL unit when `n` is negative. A lone surrogate becomes U+FFFD.
@(private)
utf16_decode :: proc(data: rawptr, n: i64, big_endian: bool, allocator := context.allocator) -> string {
	if data == nil do return ""
	units := ([^]u16)(data)
	count := 0
	if n < 0 {
		for units[count] != 0 do count += 1
	} else {
		count = int(n / 2)
	}
	unit_at :: proc(units: [^]u16, i: int, big_endian: bool) -> u32 {
		unit := units[i]
		if big_endian != NATIVE_BIG_ENDIAN do unit = (unit >> 8) | (unit << 8)
		return u32(unit)
	}
	builder := strings.builder_make(0, count + count / 2, allocator)
	for i := 0; i < count; i += 1 {
		unit := unit_at(units, i, big_endian)
		r := rune(unit)
		if unit >= 0xD800 && unit < 0xDC00 && i + 1 < count {
			low := unit_at(units, i + 1, big_endian)
			if low >= 0xDC00 && low < 0xE000 {
				r = rune(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
				i += 1
			} else {
				r = 0xFFFD
			}
		} else if unit >= 0xD800 && unit < 0xE000 {
			r = 0xFFFD
		}
		strings.write_rune(&builder, r)
	}
	return strings.to_string(builder)
}

// utf16_bytes is the byte length of a NUL-terminated UTF-16 answer, without
// the terminator.
@(private)
utf16_bytes :: proc(units: []u16) -> c.int {
	if len(units) == 0 do return 0
	return c.int((len(units) - 1) * 2)
}

// text_encoding_order tells whether a text encoding code is UTF-16, and in
// which byte order.
@(private)
text_encoding_order :: proc(encoding: c.int) -> (utf16: bool, big_endian: bool) {
	switch encoding & 0x7 {
	case SQLITE_UTF16LE:
		return true, false
	case SQLITE_UTF16BE:
		return true, true
	case SQLITE_UTF16:
		return true, NATIVE_BIG_ENDIAN
	}
	return false, false
}

// --- Connections -------------------------------------------------------------

@(export)
sqlite3_open16 :: proc "c" (filename: rawptr, ppDb: ^rawptr) -> c.int {
	context = runtime.default_context()
	if filename == nil {
		if ppDb != nil do ppDb^ = nil
		return SQLITE_MISUSE
	}
	name := utf16_decode(filename, -1, NATIVE_BIG_ENDIAN)
	defer delete(name)
	path := strings.clone_to_cstring(name)
	defer delete(path)
	return sqlite3_open(path, ppDb)
}

@(export)
sqlite3_errmsg16 :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	message := sqlite3_errmsg(handle)
	db := db_of(handle)
	if db == nil {
		@(static) out_of_memory := [?]u16{'o', 'u', 't', ' ', 'o', 'f', ' ', 'm', 'e', 'm', 'o', 'r', 'y', 0}
		return raw_data(out_of_memory[:])
	}
	delete(db.last_error16)
	db.last_error16 = utf16_encode(string(message), NATIVE_BIG_ENDIAN)
	return raw_data(db.last_error16)
}

// prepare16 converts the text, prepares it, and reports the tail as a place
// in the caller's UTF-16 text.
@(private)
prepare16 :: proc(handle: rawptr, sql: rawptr, nByte: c.int, ppStmt: ^rawptr, pzTail: ^rawptr) -> c.int {
	if pzTail != nil do pzTail^ = nil
	if sql == nil {
		if ppStmt != nil do ppStmt^ = nil
		return SQLITE_MISUSE
	}
	text := utf16_decode(sql, i64(nByte), NATIVE_BIG_ENDIAN)
	defer delete(text)
	utf8 := strings.clone_to_cstring(text)
	defer delete(utf8)
	tail: cstring
	code := prepare(handle, utf8, -1, ppStmt, &tail)
	if pzTail != nil && tail != nil {
		consumed := int(uintptr(rawptr(tail)) - uintptr(rawptr(utf8)))
		units := 0
		for r in text[:consumed] do units += r >= 0x10000 ? 2 : 1
		pzTail^ = rawptr(uintptr(sql) + uintptr(units * 2))
	}
	return code
}

@(export)
sqlite3_prepare16 :: proc "c" (handle: rawptr, sql: rawptr, nByte: c.int, ppStmt: ^rawptr, pzTail: ^rawptr) -> c.int {
	context = runtime.default_context()
	return prepare16(handle, sql, nByte, ppStmt, pzTail)
}

@(export)
sqlite3_prepare16_v2 :: proc "c" (handle: rawptr, sql: rawptr, nByte: c.int, ppStmt: ^rawptr, pzTail: ^rawptr) -> c.int {
	context = runtime.default_context()
	return prepare16(handle, sql, nByte, ppStmt, pzTail)
}

@(export)
sqlite3_prepare16_v3 :: proc "c" (handle: rawptr, sql: rawptr, nByte: c.int, flags: c.uint, ppStmt: ^rawptr, pzTail: ^rawptr) -> c.int {
	context = runtime.default_context()
	_ = flags
	return prepare16(handle, sql, nByte, ppStmt, pzTail)
}

@(export)
sqlite3_create_function16 :: proc "c" (
	handle: rawptr,
	name: rawptr,
	arity: c.int,
	text_rep: c.int,
	user: rawptr,
	func: Function_Callback,
	step: Function_Callback,
	final: Final_Callback,
) -> c.int {
	context = runtime.default_context()
	if name == nil do return create_function(handle, nil, arity, user, func, step, final, nil, text_rep)
	decoded := utf16_decode(name, -1, NATIVE_BIG_ENDIAN)
	defer delete(decoded)
	utf8 := strings.clone_to_cstring(decoded)
	defer delete(utf8)
	return create_function(handle, utf8, arity, user, func, step, final, nil, text_rep)
}

// --- Statements --------------------------------------------------------------

// bind_text_utf16 binds UTF-16 text: `n` bytes, or up to the NUL when negative.
@(private)
bind_text_utf16 :: proc(handle: rawptr, index: c.int, data: rawptr, n: i64, destructor: rawptr, big_endian: bool) -> c.int {
	defer release_with(data, destructor)
	stmt := stmt_of(handle)
	if stmt == nil do return SQLITE_MISUSE
	if int(index) < 1 || int(index) > engine.Embed_Parameter_Count(stmt.stmt) do return SQLITE_RANGE
	stmt_pointer_drop(stmt, int(index) - 1)
	if data == nil {
		if engine.error_drop(engine.embed_bind_null(stmt.stmt, int(index) - 1)) do return SQLITE_OK
		return SQLITE_ERROR
	}
	text := utf16_decode(data, n, big_endian)
	defer delete(text)
	if engine.error_drop(engine.embed_bind_text(stmt.stmt, int(index) - 1, text)) do return SQLITE_OK
	return SQLITE_ERROR
}

@(export)
sqlite3_bind_text16 :: proc "c" (handle: rawptr, index: c.int, data: rawptr, n: c.int, destructor: rawptr) -> c.int {
	context = runtime.default_context()
	return bind_text_utf16(handle, index, data, i64(n), destructor, NATIVE_BIG_ENDIAN)
}

// sqlite3_bind_text64 binds text in any of SQLite's encodings.
@(export)
sqlite3_bind_text64 :: proc "c" (handle: rawptr, index: c.int, data: cstring, n: u64, destructor: rawptr, encoding: u8) -> c.int {
	context = runtime.default_context()
	length := n > u64(max(i64)) ? -1 : i64(n)
	if is_utf16, big_endian := text_encoding_order(c.int(encoding)); is_utf16 {
		return bind_text_utf16(handle, index, rawptr(data), length, destructor, big_endian)
	}
	if length > i64(max(c.int)) {
		release_with(rawptr(data), destructor)
		return SQLITE_TOOBIG
	}
	return sqlite3_bind_text(handle, index, data, c.int(length), destructor)
}

// column_text16 is the column's text in UTF-16, living until the statement
// moves; nil for NULL.
@(private)
column_text16 :: proc(stmt: ^Statement, index: int) -> []u16 {
	value, ok := engine.embed_column_value(stmt.stmt, index)
	if !ok || value.kind == .Null do return nil
	rendered := engine.sqlite_value_text(value, context.allocator)
	defer delete(rendered)
	units := utf16_encode(rendered, NATIVE_BIG_ENDIAN)
	append(&stmt.wide_cache, units)
	return units
}

@(export)
sqlite3_column_text16 :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return nil
	units := column_text16(stmt, int(index))
	if units == nil do return nil
	return raw_data(units)
}

// sqlite3_column_bytes16 is the size of the column's UTF-16 text in bytes,
// without the terminator.
@(export)
sqlite3_column_bytes16 :: proc "c" (handle: rawptr, index: c.int) -> c.int {
	context = runtime.default_context()
	stmt := stmt_of(handle)
	if stmt == nil do return 0
	return utf16_bytes(column_text16(stmt, int(index)))
}

// name16 keeps a UTF-16 copy of a name until the statement is finalized.
@(private)
name16 :: proc(stmt: ^Statement, name: cstring) -> rawptr {
	if stmt == nil || name == nil do return nil
	units := utf16_encode(string(name), NATIVE_BIG_ENDIAN)
	append(&stmt.wide_names, units)
	return raw_data(units)
}

@(export)
sqlite3_column_name16 :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	return name16(stmt_of(handle), sqlite3_column_name(handle, index))
}

@(export)
sqlite3_column_decltype16 :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	return name16(stmt_of(handle), sqlite3_column_decltype(handle, index))
}

@(export)
sqlite3_column_database_name16 :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	return name16(stmt_of(handle), sqlite3_column_database_name(handle, index))
}

@(export)
sqlite3_column_table_name16 :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	return name16(stmt_of(handle), sqlite3_column_table_name(handle, index))
}

@(export)
sqlite3_column_origin_name16 :: proc "c" (handle: rawptr, index: c.int) -> rawptr {
	context = runtime.default_context()
	return name16(stmt_of(handle), sqlite3_column_origin_name(handle, index))
}

// --- Values and results --------------------------------------------------------

// value_text16 is a value's text in UTF-16, living as long as the value; nil
// for NULL. Asking in the other byte order converts again, as SQLite does.
@(private)
value_text16 :: proc(handle: rawptr, big_endian: bool) -> rawptr {
	box := box_of(handle)
	if box == nil || sqlite_type_of(box.value) == SQLITE_NULL do return nil
	if box.text16 == nil || box.text16_big != big_endian {
		rendered := engine.sqlite_value_text(box.value, context.allocator)
		defer delete(rendered)
		delete(box.text16)
		box.text16 = utf16_encode(rendered, big_endian)
		box.text16_big = big_endian
	}
	return raw_data(box.text16)
}

@(export)
sqlite3_value_text16 :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	return value_text16(handle, NATIVE_BIG_ENDIAN)
}

@(export)
sqlite3_value_text16le :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	return value_text16(handle, false)
}

@(export)
sqlite3_value_text16be :: proc "c" (handle: rawptr) -> rawptr {
	context = runtime.default_context()
	return value_text16(handle, true)
}

@(export)
sqlite3_value_bytes16 :: proc "c" (handle: rawptr) -> c.int {
	context = runtime.default_context()
	box := box_of(handle)
	if box == nil || value_text16(handle, box.text16_big if box.text16 != nil else NATIVE_BIG_ENDIAN) == nil do return 0
	return utf16_bytes(box.text16)
}

@(private)
result_text16 :: proc(handle: rawptr, data: rawptr, n: i64, destructor: rawptr, big_endian: bool) {
	defer release_with(data, destructor)
	ctx := context_of(handle)
	if ctx == nil do return
	if data == nil {
		context_set(ctx, engine.value_null())
		return
	}
	context_set(ctx, engine.value_string(utf16_decode(data, n, big_endian)))
}

@(export)
sqlite3_result_text16 :: proc "c" (handle: rawptr, data: rawptr, n: c.int, destructor: rawptr) {
	context = runtime.default_context()
	result_text16(handle, data, i64(n), destructor, NATIVE_BIG_ENDIAN)
}

@(export)
sqlite3_result_text16le :: proc "c" (handle: rawptr, data: rawptr, n: c.int, destructor: rawptr) {
	context = runtime.default_context()
	result_text16(handle, data, i64(n), destructor, false)
}

@(export)
sqlite3_result_text16be :: proc "c" (handle: rawptr, data: rawptr, n: c.int, destructor: rawptr) {
	context = runtime.default_context()
	result_text16(handle, data, i64(n), destructor, true)
}

@(export)
sqlite3_result_error16 :: proc "c" (handle: rawptr, message: rawptr, n: c.int) {
	context = runtime.default_context()
	ctx := context_of(handle)
	if ctx == nil do return
	text := utf16_decode(message, i64(n), NATIVE_BIG_ENDIAN)
	defer delete(text)
	utf8 := strings.clone_to_cstring(text)
	defer delete(utf8)
	sqlite3_result_error(handle, utf8, -1)
}
