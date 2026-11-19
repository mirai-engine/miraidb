package sqlite_compat

import "base:intrinsics"
import "base:runtime"
import "core:c"

import engine "../engine"

// SQLite's own printf for a program: sqlite3_mprintf, sqlite3_snprintf, the
// sqlite3_str builder and their va_list forms. The formatter is the engine's
// (sqlite_printf.odin), which SQL's printf() shares; this file reads the C
// arguments it asks for, with Odin's C va_list intrinsics, so the variadic
// entry points are Odin procedures with the C ABI: no C code is involved.

// The longest text a builder holds (SQLITE_MAX_LENGTH).
SQLITE_STR_LIMIT :: engine.PRINTF_LIMIT

// Sqlite_Str is the sqlite3_str object: the engine's text, and the error
// sqlite3_str_errcode answers.
Sqlite_Str :: struct {
	using out: engine.Printf_Out,
	error:     c.int,
}

// Va_Source reads the arguments of one formatting call.
@(private)
Va_Source :: struct {
	list: ^intrinsics.c_va_list,
}

@(private)
str_sync :: proc(s: ^Sqlite_Str) {
	if s.too_big && s.error == 0 do s.error = SQLITE_TOOBIG
}

@(private)
str_put :: proc(s: ^Sqlite_Str, bytes: []u8) {
	if s.error != 0 do return
	engine.printf_put(&s.out, bytes)
	str_sync(s)
}

@(private)
str_put_char :: proc(s: ^Sqlite_Str, n: int, ch: u8) {
	if s.error != 0 do return
	engine.printf_put_char(&s.out, n, ch)
	str_sync(s)
}

@(private)
cstring_bytes :: proc(z: cstring) -> []u8 {
	if z == nil do return nil
	p := ([^]u8)(z)
	n := 0
	for p[n] != 0 do n += 1
	return p[:n]
}

// The C arguments, as the formatter asks for them.

@(private)
va_int :: proc(user: rawptr) -> i64 {
	return i64(intrinsics.c_va_arg((^Va_Source)(user).list, c.int))
}

@(private)
va_integer :: proc(user: rawptr, long_flag: int, signed: bool) -> u64 {
	list := (^Va_Source)(user).list
	if signed {
		switch long_flag {
		case 2:
			return u64(intrinsics.c_va_arg(list, i64))
		case 1:
			return u64(i64(intrinsics.c_va_arg(list, c.long)))
		}
		return u64(i64(intrinsics.c_va_arg(list, c.int)))
	}
	switch long_flag {
	case 2:
		return intrinsics.c_va_arg(list, u64)
	case 1:
		return u64(intrinsics.c_va_arg(list, c.ulong))
	}
	return u64(intrinsics.c_va_arg(list, c.uint))
}

@(private)
va_double :: proc(user: rawptr) -> f64 {
	return intrinsics.c_va_arg((^Va_Source)(user).list, f64)
}

@(private)
va_text :: proc(user: rawptr) -> (text: []u8, present: bool, pointer: rawptr) {
	z := intrinsics.c_va_arg((^Va_Source)(user).list, cstring)
	return cstring_bytes(z), z != nil, rawptr(z)
}

@(private)
va_free :: proc(pointer: rawptr) {
	sqlite3_free(pointer)
}

@(private)
va_counter :: proc(user: rawptr) -> ^i32 {
	return (^i32)(intrinsics.c_va_arg((^Va_Source)(user).list, ^c.int))
}

// str_vappendf appends `format` with the arguments `args` reads, as
// sqlite3_str_vappendf does.
@(private)
str_vappendf :: proc(s: ^Sqlite_Str, format: cstring, args: Va_Source) {
	if format == nil || s.error != 0 do return
	source := args
	reader := engine.Printf_Args {
		user      = &source,
		c_int     = va_int,
		c_integer = va_integer,
		c_double  = va_double,
		c_text    = va_text,
		c_free    = va_free,
		c_counter = va_counter,
	}
	engine.printf_append(&s.out, cstring_bytes(format), &reader)
	str_sync(s)
}

// ---------------------------------------------------------------------------
// The C entry points.

@(private)
str_finish_text :: proc(s: ^Sqlite_Str, empty_is_null: bool) -> cstring {
	if s.error != 0 do return nil
	if len(s.text) == 0 && empty_is_null do return nil
	block := ([^]u8)(sqlite_alloc(len(s.text) + 1))
	if block == nil do return nil
	copy(block[:len(s.text)], s.text[:])
	block[len(s.text)] = 0
	return cstring(block)
}

when ODIN_OS == .Windows {
	// A C va_list is a char* passed by value on Windows.
	C_Va_List :: intrinsics.c_va_list
	@(private)
	va_source :: #force_inline proc "contextless" (list: ^C_Va_List) -> Va_Source {
		return Va_Source{list = list}
	}
} else {
	// On the System V ABI a va_list is an array of one struct: it arrives as a
	// pointer to it.
	C_Va_List :: ^intrinsics.c_va_list
	@(private)
	va_source :: #force_inline proc "contextless" (list: ^C_Va_List) -> Va_Source {
		return Va_Source{list = list^}
	}
}

@(export)
sqlite3_mprintf :: proc "c" (format: cstring, #c_vararg args: ..any) -> cstring {
	context = runtime.default_context()
	list: intrinsics.c_va_list
	intrinsics.c_va_start(&list, args)
	defer intrinsics.c_va_end(&list)
	s: Sqlite_Str
	defer delete(s.text)
	str_vappendf(&s, format, Va_Source{list = &list})
	return str_finish_text(&s, false)
}

@(export)
sqlite3_vmprintf :: proc "c" (format: cstring, list: C_Va_List) -> cstring {
	context = runtime.default_context()
	list := list
	s: Sqlite_Str
	defer delete(s.text)
	str_vappendf(&s, format, va_source(&list))
	return str_finish_text(&s, false)
}

@(private)
snprintf_into :: proc(n: c.int, buffer: [^]u8, s: ^Sqlite_Str) {
	if n <= 0 || buffer == nil do return
	count := min(len(s.text), int(n) - 1)
	if s.error != 0 do count = 0
	copy(buffer[:count], s.text[:count])
	buffer[count] = 0
}

@(export)
sqlite3_snprintf :: proc "c" (n: c.int, buffer: [^]u8, format: cstring, #c_vararg args: ..any) -> cstring {
	context = runtime.default_context()
	if n <= 0 do return cstring(buffer)
	list: intrinsics.c_va_list
	intrinsics.c_va_start(&list, args)
	defer intrinsics.c_va_end(&list)
	s: Sqlite_Str
	defer delete(s.text)
	str_vappendf(&s, format, Va_Source{list = &list})
	snprintf_into(n, buffer, &s)
	return cstring(buffer)
}

@(export)
sqlite3_vsnprintf :: proc "c" (n: c.int, buffer: [^]u8, format: cstring, list: C_Va_List) -> cstring {
	context = runtime.default_context()
	if n <= 0 do return cstring(buffer)
	list := list
	s: Sqlite_Str
	defer delete(s.text)
	str_vappendf(&s, format, va_source(&list))
	snprintf_into(n, buffer, &s)
	return cstring(buffer)
}

@(export)
sqlite3_str_new :: proc "c" (db: rawptr) -> ^Sqlite_Str {
	context = runtime.default_context()
	s := new(Sqlite_Str, runtime.heap_allocator())
	s.text = make([dynamic]u8, runtime.heap_allocator())
	return s
}

@(export)
sqlite3_str_finish :: proc "c" (s: ^Sqlite_Str) -> cstring {
	context = runtime.default_context()
	if s == nil do return nil
	text := str_finish_text(s, true)
	delete(s.text)
	free(s, runtime.heap_allocator())
	return text
}

@(export)
sqlite3_str_free :: proc "c" (s: ^Sqlite_Str) {
	context = runtime.default_context()
	if s == nil do return
	delete(s.text)
	free(s, runtime.heap_allocator())
}

@(export)
sqlite3_str_appendf :: proc "c" (s: ^Sqlite_Str, format: cstring, #c_vararg args: ..any) {
	context = runtime.default_context()
	if s == nil do return
	list: intrinsics.c_va_list
	intrinsics.c_va_start(&list, args)
	defer intrinsics.c_va_end(&list)
	str_vappendf(s, format, Va_Source{list = &list})
}

@(export)
sqlite3_str_vappendf :: proc "c" (s: ^Sqlite_Str, format: cstring, list: C_Va_List) {
	context = runtime.default_context()
	if s == nil do return
	list := list
	str_vappendf(s, format, va_source(&list))
}

@(export)
sqlite3_str_append :: proc "c" (s: ^Sqlite_Str, z: [^]u8, n: c.int) {
	context = runtime.default_context()
	if s == nil || z == nil || n <= 0 do return
	str_put(s, z[:n])
}

@(export)
sqlite3_str_appendall :: proc "c" (s: ^Sqlite_Str, z: cstring) {
	context = runtime.default_context()
	if s == nil do return
	str_put(s, cstring_bytes(z))
}

@(export)
sqlite3_str_appendchar :: proc "c" (s: ^Sqlite_Str, n: c.int, ch: c.char) {
	context = runtime.default_context()
	if s == nil do return
	str_put_char(s, int(n), u8(ch))
}

@(export)
sqlite3_str_reset :: proc "c" (s: ^Sqlite_Str) {
	context = runtime.default_context()
	if s == nil do return
	clear(&s.text)
}

@(export)
sqlite3_str_truncate :: proc "c" (s: ^Sqlite_Str, n: c.int) {
	context = runtime.default_context()
	if s == nil || s.error != 0 || n < 0 || int(n) >= len(s.text) do return
	resize(&s.text, int(n))
}

@(export)
sqlite3_str_errcode :: proc "c" (s: ^Sqlite_Str) -> c.int {
	if s == nil do return SQLITE_NOMEM
	return s.error
}

@(export)
sqlite3_str_length :: proc "c" (s: ^Sqlite_Str) -> c.int {
	if s == nil do return 0
	return c.int(len(s.text))
}

// sqlite3_str_value is the text so far, terminated, or NULL when there is none.
@(export)
sqlite3_str_value :: proc "c" (s: ^Sqlite_Str) -> cstring {
	context = runtime.default_context()
	if s == nil || len(s.text) == 0 do return nil
	append(&s.text, 0)
	pop(&s.text)
	return cstring(raw_data(s.text))
}
