package sqlite_compat

import "base:intrinsics"
import "base:runtime"
import "core:c"

import engine "../engine"

// SQLite's own printf: sqlite3_mprintf, sqlite3_snprintf, the sqlite3_str
// builder and their va_list forms, with SQLite's conversions and flags
// (printf.c). A program formats SQL with them (`%q`, `%Q`, `%w`), so the text
// has to be the text SQLite makes:
//
//   %d %i %u %x %X %o %p %r   integers (`l` is a C long, `ll` 64 bits), `,`
//                             groups thousands, `r` writes an ordinal (1st)
//   %f %e %E %g %G            doubles, with SQLite's 16 significant digits (20
//                             with `!`), "Inf", "-Inf" and "NaN"
//   %c                        a character, repeated `precision` times
//   %s %z                     a string; `z` frees it with sqlite3_free
//   %q %Q %w                  SQL quoting: `'` doubled, `Q` adds the quotes and
//                             writes NULL for a null pointer, `w` doubles `"`
//   %j %J                     a JSON string, without and with the quotes
//   %n %%                     the length so far, a percent sign
//
// The arguments are read from the C variadic list with Odin's C va_list
// intrinsics, so the variadic entry points are Odin procedures with the C
// ABI: no C code is involved.

// The longest text a builder holds (SQLITE_MAX_LENGTH).
SQLITE_STR_LIMIT :: 1_000_000_000

// Sqlite_Str is the sqlite3_str object.
Sqlite_Str :: struct {
	text:  [dynamic]u8,
	error: c.int,
}

// Va_Source reads the arguments of one formatting call.
@(private)
Va_Source :: struct {
	list: ^intrinsics.c_va_list,
}

@(private)
str_room :: proc(s: ^Sqlite_Str, n: int) -> bool {
	if s.error != 0 do return false
	if n < 0 || len(s.text) + n > SQLITE_STR_LIMIT {
		s.error = SQLITE_TOOBIG
		clear(&s.text)
		return false
	}
	return true
}

@(private)
str_put :: proc(s: ^Sqlite_Str, bytes: []u8) {
	if len(bytes) == 0 || !str_room(s, len(bytes)) do return
	append(&s.text, ..bytes)
}

@(private)
str_put_string :: proc(s: ^Sqlite_Str, text: string) {
	str_put(s, transmute([]u8)text)
}

@(private)
str_put_char :: proc(s: ^Sqlite_Str, n: int, ch: u8) {
	if n <= 0 || !str_room(s, n) do return
	for _ in 0 ..< n do append(&s.text, ch)
}

@(private)
cstring_bytes :: proc(z: cstring) -> []u8 {
	if z == nil do return nil
	p := ([^]u8)(z)
	n := 0
	for p[n] != 0 do n += 1
	return p[:n]
}

// ---------------------------------------------------------------------------
// The formatter.

@(private)
DIGITS :: "0123456789ABCDEF0123456789abcdef"

// str_vappendf appends `format` with the arguments `args` reads, as
// sqlite3_str_vappendf does.
@(private)
str_vappendf :: proc(s: ^Sqlite_Str, format: cstring, args: Va_Source) {
	if format == nil do return
	f := cstring_bytes(format)
	i := 0
	for i < len(f) {
		if f[i] != '%' {
			start := i
			for i < len(f) && f[i] != '%' do i += 1
			str_put(s, f[start:i])
			continue
		}
		i += 1
		if i >= len(f) {
			str_put_string(s, "%")
			break
		}
		left, zero, alternate, alt2 := false, false, false, false
		prefix_flag: u8 = 0
		thousands := false
		width := 0
		precision := -1
		long_flag := 0
		// Flags.
		flags: for i < len(f) {
			switch f[i] {
			case '-':
				left = true
			case '+':
				prefix_flag = '+'
			case ' ':
				prefix_flag = ' '
			case '#':
				alternate = true
			case '!':
				alt2 = true
			case '0':
				zero = true
			case ',':
				thousands = true
			case:
				break flags
			}
			i += 1
		}
		// Width.
		if i < len(f) && f[i] == '*' {
			w := int(intrinsics.c_va_arg(args.list, c.int))
			if w < 0 {
				left = true
				w = w >= -2147483647 ? -w : 0
			}
			width = w
			i += 1
		} else {
			for i < len(f) && f[i] >= '0' && f[i] <= '9' {
				width = (width * 10 + int(f[i] - '0')) & 0x7fffffff
				i += 1
			}
		}
		// Precision.
		if i < len(f) && f[i] == '.' {
			i += 1
			if i < len(f) && f[i] == '*' {
				p := int(intrinsics.c_va_arg(args.list, c.int))
				precision = p < 0 ? (p >= -2147483647 ? -p : -1) : p
				i += 1
			} else {
				precision = 0
				for i < len(f) && f[i] >= '0' && f[i] <= '9' {
					precision = (precision * 10 + int(f[i] - '0')) & 0x7fffffff
					i += 1
				}
			}
		}
		// Length.
		if i < len(f) && f[i] == 'l' {
			long_flag = 1
			i += 1
			if i < len(f) && f[i] == 'l' {
				long_flag = 2
				i += 1
			}
		}
		if i >= len(f) do break
		conversion := f[i]
		i += 1
		buffer: [128]u8
		out: []u8
		extra: [dynamic]u8
		defer delete(extra)
		switch conversion {
		case 'd', 'i', 'u', 'x', 'X', 'o', 'p', 'r':
			out = format_integer(&extra, conversion, args, long_flag, prefix_flag, thousands, alternate, zero, width, precision)
		case 'f', 'e', 'E', 'g', 'G':
			r := intrinsics.c_va_arg(args.list, f64)
			format_double(s, conversion, r, prefix_flag, thousands, alternate, alt2, zero, left, width, precision)
			continue
		case 'n':
			counter := intrinsics.c_va_arg(args.list, ^c.int)
			if counter != nil do counter^ = c.int(len(s.text))
			continue
		case '%':
			buffer[0] = '%'
			out = buffer[:1]
		case 'c':
			ch := u32(intrinsics.c_va_arg(args.list, c.uint))
			n := utf8_encode(buffer[:], ch)
			one := buffer[:n]
			if precision > 1 {
				width -= precision - 1
				if width > 1 && !left {
					str_put_char(s, width - 1, ' ')
					width = 0
				}
				for _ in 0 ..< precision - 1 do str_put(s, one)
			}
			out = one
			alt2 = true
		case 's', 'z':
			z := intrinsics.c_va_arg(args.list, cstring)
			text := cstring_bytes(z)
			out = clip(text, precision, alt2)
			if conversion == 'z' && z != nil {
				append(&extra, ..out)
				out = extra[:]
				sqlite3_free(rawptr(z))
			}
		case 'q', 'Q', 'w':
			z := intrinsics.c_va_arg(args.list, cstring)
			out = format_quoted(&extra, conversion, z, precision, alternate, alt2)
			alt2 = alt2
		case 'j', 'J':
			z := intrinsics.c_va_arg(args.list, cstring)
			format_json(s, conversion, z, precision, alt2, left, width)
			continue
		case:
			// An unknown conversion ends the formatting, as in SQLite.
			return
		}
		// Width, counted in characters when `!` asks for it.
		if alt2 && width > 0 {
			for b in out do if b & 0xc0 == 0x80 do width += 1
		}
		pad := width - len(out)
		if pad > 0 && !left do str_put_char(s, pad, ' ')
		str_put(s, out)
		if pad > 0 && left do str_put_char(s, pad, ' ')
	}
}

@(private)
clip :: proc(text: []u8, precision: int, characters: bool) -> []u8 {
	if precision < 0 do return text
	if !characters do return text[:min(precision, len(text))]
	at, count := 0, 0
	for at < len(text) && count < precision {
		at += 1
		for at < len(text) && text[at] & 0xc0 == 0x80 do at += 1
		count += 1
	}
	return text[:at]
}

@(private)
utf8_encode :: proc(out: []u8, ch: u32) -> int {
	switch {
	case ch < 0x80:
		out[0] = u8(ch)
		return 1
	case ch < 0x800:
		out[0] = 0xc0 | u8(ch >> 6)
		out[1] = 0x80 | u8(ch & 0x3f)
		return 2
	case ch < 0x10000:
		out[0] = 0xe0 | u8(ch >> 12)
		out[1] = 0x80 | u8((ch >> 6) & 0x3f)
		out[2] = 0x80 | u8(ch & 0x3f)
		return 3
	}
	out[0] = 0xf0 | u8((ch >> 18) & 0x07)
	out[1] = 0x80 | u8((ch >> 12) & 0x3f)
	out[2] = 0x80 | u8((ch >> 6) & 0x3f)
	out[3] = 0x80 | u8(ch & 0x3f)
	return 4
}

@(private)
format_integer :: proc(
	out: ^[dynamic]u8,
	conversion: u8,
	args: Va_Source,
	long_flag: int,
	prefix_flag: u8,
	thousands: bool,
	alternate: bool,
	zero: bool,
	width: int,
	precision: int,
) -> []u8 {
	long_flag := long_flag
	thousands := thousands
	alternate := alternate
	precision := precision
	base: u64 = 10
	charset := 0
	signed := false
	prefix_text := ""
	switch conversion {
	case 'd', 'i':
		signed = true
	case 'r':
		signed = true
		thousands = false
	case 'u':
	case 'x':
		base, charset, prefix_text = 16, 16, "0x"
		thousands = false
	case 'X':
		base, prefix_text = 16, "0X"
		thousands = false
	case 'o':
		base, prefix_text = 8, "0"
		thousands = false
	case 'p':
		base, prefix_text = 16, "0x"
		long_flag = size_of(rawptr) == 8 ? 2 : 1
		thousands = false
	}
	value: u64
	sign: u8 = 0
	if signed {
		v: i64
		switch long_flag {
		case 2:
			v = intrinsics.c_va_arg(args.list, i64)
		case 1:
			v = i64(intrinsics.c_va_arg(args.list, c.long))
		case:
			v = i64(intrinsics.c_va_arg(args.list, c.int))
		}
		if v < 0 {
			value = ~u64(v) + 1
			sign = '-'
		} else {
			value = u64(v)
			sign = prefix_flag
		}
	} else {
		switch long_flag {
		case 2:
			value = intrinsics.c_va_arg(args.list, u64)
		case 1:
			value = u64(intrinsics.c_va_arg(args.list, c.ulong))
		case:
			value = u64(intrinsics.c_va_arg(args.list, c.uint))
		}
	}
	if value == 0 do alternate = false
	if zero && precision < width - (sign != 0 ? 1 : 0) do precision = width - (sign != 0 ? 1 : 0)
	table := DIGITS
	scratch: [64]u8
	at := len(scratch)
	v := value
	for {
		at -= 1
		scratch[at] = table[charset + int(v % base)]
		v /= base
		if v == 0 do break
	}
	number := scratch[at:]
	text := make([dynamic]u8, 0, 32 + max(precision, 0), context.temp_allocator)
	if alternate && len(prefix_text) > 0 do append(&text, ..transmute([]u8)prefix_text)
	if sign != 0 do append(&text, sign)
	// Zeros up to the precision, then the digits, grouped by three from the
	// right when `,` asks for it.
	padded := make([dynamic]u8, 0, max(precision, len(number)), context.temp_allocator)
	for _ in len(number) ..< precision do append(&padded, '0')
	append(&padded, ..number)
	for b, k in padded {
		append(&text, b)
		left_over := len(padded) - 1 - k
		if thousands && left_over > 0 && left_over % 3 == 0 do append(&text, ',')
	}
	if conversion == 'r' {
		ordinals := "thstndrd"
		x := int(value % 10)
		if x >= 4 || (value / 10) % 10 == 1 do x = 0
		append(&text, ordinals[x * 2], ordinals[x * 2 + 1])
	}
	append(out, ..text[:])
	return out[:]
}

@(private)
format_double :: proc(
	s: ^Sqlite_Str,
	conversion: u8,
	r: f64,
	prefix_flag: u8,
	thousands: bool,
	alternate: bool,
	alt2: bool,
	zero: bool,
	left: bool,
	width: int,
	precision: int,
) {
	text, prefix, zero_pad := engine.sqlite_format_double(conversion, r, prefix_flag, thousands, alternate, alt2, zero, precision, context.temp_allocator)
	emit_padded(s, text, width, left, zero_pad, prefix)
}

// emit_padded writes a number padded to `width`: spaces on the left or the
// right, or zeros after the sign.
@(private)
emit_padded :: proc(s: ^Sqlite_Str, text: []u8, width: int, left: bool, zero: bool, prefix: u8) {
	pad := width - len(text)
	if pad <= 0 {
		str_put(s, text)
		return
	}
	if left {
		str_put(s, text)
		str_put_char(s, pad, ' ')
	} else if !zero {
		str_put_char(s, pad, ' ')
		str_put(s, text)
	} else {
		adjust := prefix != 0 ? 1 : 0
		str_put(s, text[:adjust])
		str_put_char(s, pad, '0')
		str_put(s, text[adjust:])
	}
}

@(private)
format_quoted :: proc(out: ^[dynamic]u8, conversion: u8, z: cstring, precision: int, alternate: bool, alt2: bool) -> []u8 {
	hex := "0123456789abcdef"
	text: []u8
	need_quote := 0
	alternate := alternate
	if z == nil {
		text = transmute([]u8)string(conversion == 'Q' ? "NULL" : "(NULL)")
	} else {
		text = cstring_bytes(z)
		if conversion == 'Q' do need_quote = 1
	}
	q: u8 = '\''
	if conversion == 'w' {
		q = '"'
		alternate = false
	}
	// The precision counts input bytes (characters with `!`).
	k := precision
	i := 0
	for k != 0 && i < len(text) {
		if alt2 && text[i] & 0xc0 == 0xc0 {
			for i + 1 < len(text) && text[i + 1] & 0xc0 == 0x80 do i += 1
		}
		i += 1
		k -= 1
	}
	used := text[:i]
	if alternate {
		control := 0
		for b in used do if b <= 0x1f do control += 1
		if control > 0 || conversion == 'q' {
			if conversion == 'Q' do need_quote = 2
		} else {
			alternate = false
		}
	}
	if need_quote == 2 {
		append(out, ..transmute([]u8)string("unistr('"))
	} else if need_quote == 1 {
		append(out, '\'')
	}
	for b in used {
		if alternate && b == '\\' {
			append(out, '\\', '\\')
		} else if alternate && b <= 0x1f {
			append(out, '\\', 'u', '0', '0', b >= 0x10 ? '1' : '0', hex[b & 0xf])
		} else {
			append(out, b)
			if b == q do append(out, b)
		}
	}
	if need_quote != 0 {
		append(out, '\'')
		if need_quote == 2 do append(out, ')')
	}
	return out[:]
}

@(private)
format_json :: proc(s: ^Sqlite_Str, conversion: u8, z: cstring, precision: int, alt2: bool, left: bool, width: int) {
	hex := "0123456789abcdef"
	start := len(s.text)
	if z == nil {
		if conversion == 'J' do str_put_string(s, "null")
	} else {
		if conversion == 'J' do str_put_string(s, "\"")
		text := cstring_bytes(z)
		limit := precision < 0 ? len(text) : len(clip(text, precision, alt2))
		for b in text[:limit] {
			switch {
			case b == '"' || b == '\\':
				str_put_char(s, 1, '\\')
				str_put_char(s, 1, b)
			case b == 8:
				str_put_string(s, "\\b")
			case b == 9:
				str_put_string(s, "\\t")
			case b == 10:
				str_put_string(s, "\\n")
			case b == 12:
				str_put_string(s, "\\f")
			case b == 13:
				str_put_string(s, "\\r")
			case b <= 0x1f:
				str_put_string(s, "\\u00")
				str_put_char(s, 1, hex[b >> 4])
				str_put_char(s, 1, hex[b & 0xf])
			case:
				str_put_char(s, 1, b)
			}
		}
		if conversion == 'J' do str_put_string(s, "\"")
	}
	if width <= 0 || s.error != 0 do return
	n := len(s.text) - start
	length := n
	if alt2 do for b in s.text[start:] do if b & 0xc0 == 0x80 do length -= 1
	if width > length {
		pad := width - length
		str_put_char(s, pad, ' ')
		if !left && n > 0 && s.error == 0 {
			copy(s.text[start + pad:], s.text[start:start + n])
			for k in 0 ..< pad do s.text[start + k] = ' '
		}
	}
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
