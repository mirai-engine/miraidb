package engine

import "core:mem"
import "core:strings"

// SQLite's own printf (printf.c), once for both of its callers: a program's
// sqlite3_mprintf, sqlite3_snprintf and sqlite3_str (the facade reads their C
// arguments) and the SQL functions printf() and format(), whose arguments are
// the call's values. A program formats SQL with it (`%q`, `%Q`, `%w`), so the
// text has to be the text SQLite makes:
//
//   %d %i %u %x %X %o %p %r   integers (`l` is a C long, `ll` 64 bits), `,`
//                             groups thousands, `r` writes an ordinal (1st)
//   %f %e %E %g %G            doubles, with SQLite's 16 significant digits (20
//                             with `!`), "Inf", "-Inf" and "NaN"
//   %c                        a character, repeated `precision` times
//   %s %z                     a string; `z` frees a C argument once written
//   %q %Q %w                  SQL quoting: `'` doubled, `Q` adds the quotes and
//                             writes NULL for a missing text, `w` doubles `"`
//   %j %J                     a JSON string, without and with the quotes
//   %n %%                     the length so far (C only), a percent sign
//
// An unknown conversion ends the formatting, as in SQLite.

// PRINTF_LIMIT is the longest text a format makes (SQLITE_MAX_LENGTH).
PRINTF_LIMIT :: 1_000_000_000

// Printf_Out is the text a format appends to. too_big is set, and the text
// emptied, once it would pass the limit; nothing is appended after that.
Printf_Out :: struct {
	text:    [dynamic]u8,
	too_big: bool,
}

// Printf_Args is where a format's arguments come from: the values of a SQL
// call (SQLite's SQLITE_PRINTF_SQLFUNC), or a program's C arguments through
// the procedures the facade gives, which read its va_list.
Printf_Args :: struct {
	values:  []Value,
	used:    int,
	sql:     bool,
	user:    rawptr,
	// c_int reads an int (a width, a precision, a %c character).
	c_int:   proc(user: rawptr) -> i64,
	// c_integer reads an integer of `long_flag` size (0 int, 1 long, 2 long
	// long), signed or not, as 64 bits.
	c_integer: proc(user: rawptr, long_flag: int, signed: bool) -> u64,
	c_double:  proc(user: rawptr) -> f64,
	// c_text reads a char*: its bytes, whether it was NULL, and the pointer
	// a %z frees with c_free.
	c_text:    proc(user: rawptr) -> (text: []u8, present: bool, pointer: rawptr),
	c_free:    proc(pointer: rawptr),
	// c_counter reads the int* %n writes the length to.
	c_counter: proc(user: rawptr) -> ^i32,
}

@(private)
printf_room :: proc(s: ^Printf_Out, n: int) -> bool {
	if s.too_big do return false
	if n < 0 || len(s.text) + n > PRINTF_LIMIT {
		s.too_big = true
		clear(&s.text)
		return false
	}
	return true
}

// printf_put appends bytes, as sqlite3_str_append does.
printf_put :: proc(s: ^Printf_Out, bytes: []u8) {
	if len(bytes) == 0 || !printf_room(s, len(bytes)) do return
	append(&s.text, ..bytes)
}

@(private)
printf_put_string :: proc(s: ^Printf_Out, text: string) {
	printf_put(s, transmute([]u8)text)
}

// printf_put_char appends `n` copies of a byte, as sqlite3_str_appendchar.
printf_put_char :: proc(s: ^Printf_Out, n: int, ch: u8) {
	if n <= 0 || !printf_room(s, n) do return
	for _ in 0 ..< n do append(&s.text, ch)
}

// The arguments, read as SQLite reads them: from a SQL call with
// sqlite3_value_int64, _double and _text (a missing one is 0, 0.0 or NULL).

@(private)
printf_arg_value :: proc(args: ^Printf_Args) -> (Value, bool) {
	if args.used >= len(args.values) do return {}, false
	args.used += 1
	return args.values[args.used - 1], true
}

@(private)
printf_arg_int :: proc(args: ^Printf_Args) -> i64 {
	if !args.sql do return args.c_int(args.user)
	return printf_arg_int64(args)
}

@(private)
printf_arg_int64 :: proc(args: ^Printf_Args) -> i64 {
	value, ok := printf_arg_value(args)
	if !ok do return 0
	#partial switch value.kind {
	case .Int:
		return value.i
	case .Bool:
		return value.b ? 1 : 0
	case .Float:
		return sqlite_real_to_int(value.f)
	case .String:
		return sqlite_text_to_int(value.s)
	case .Bytes:
		return sqlite_text_to_int(string(value.bytes))
	case .Null:
		return 0
	}
	number, _ := value_to_i64(value)
	return number
}

@(private)
printf_arg_integer :: proc(args: ^Printf_Args, long_flag: int, signed: bool) -> u64 {
	if !args.sql do return args.c_integer(args.user, long_flag, signed)
	return u64(printf_arg_int64(args))
}

@(private)
printf_arg_double :: proc(args: ^Printf_Args) -> f64 {
	if !args.sql do return args.c_double(args.user)
	value, ok := printf_arg_value(args)
	if !ok do return 0
	#partial switch value.kind {
	case .Float:
		return value.f
	case .Int:
		return f64(value.i)
	case .Bool:
		return value.b ? 1 : 0
	case .String:
		return sqlite_text_to_real(value.s)
	case .Bytes:
		return sqlite_text_to_real(string(value.bytes))
	case .Null:
		return 0
	}
	number, _ := value_to_f64(value)
	return number
}

// printf_arg_text is a text argument: its bytes and whether there is one (a
// NULL pointer, or a NULL value, is none). `pointer` is the C pointer a %z
// frees. A SQL value's text lives in the temporary allocator.
@(private)
printf_arg_text :: proc(args: ^Printf_Args) -> (text: []u8, present: bool, pointer: rawptr) {
	if !args.sql do return args.c_text(args.user)
	value, ok := printf_arg_value(args)
	if !ok || value.kind == .Null do return nil, false, nil
	if value.kind == .Bytes do return value.bytes, true, nil
	if value.kind == .String do return transmute([]u8)value.s, true, nil
	return transmute([]u8)sqlite_value_text(value, context.temp_allocator), true, nil
}

@(private)
PRINTF_DIGITS :: "0123456789ABCDEF0123456789abcdef"

// printf_append appends `format` with the arguments `args` gives, as
// sqlite3_str_vappendf does.
printf_append :: proc(s: ^Printf_Out, format: []u8, args: ^Printf_Args) {
	f := format
	i := 0
	for i < len(f) {
		if f[i] != '%' {
			start := i
			for i < len(f) && f[i] != '%' do i += 1
			printf_put(s, f[start:i])
			continue
		}
		i += 1
		if i >= len(f) {
			printf_put_string(s, "%")
			break
		}
		left, zero, alternate, alt2 := false, false, false, false
		prefix_flag: u8 = 0
		thousands := false
		width := 0
		precision := -1
		long_flag := 0
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
			w := printf_arg_int(args)
			if w < 0 {
				left = true
				w = w >= -2147483647 ? -w : 0
			}
			width = int(min(w, 0x7fffffff))
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
				p := printf_arg_int(args)
				precision = int(p < 0 ? (p >= -2147483647 ? -p : -1) : min(p, 0x7fffffff))
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
			out = printf_integer(&extra, conversion, args, long_flag, prefix_flag, thousands, alternate, zero, width, precision)
		case 'f', 'e', 'E', 'g', 'G':
			r := printf_arg_double(args)
			text, prefix, zero_pad := sqlite_format_double(conversion, r, prefix_flag, thousands, alternate, alt2, zero, precision, context.temp_allocator)
			printf_padded(s, text, width, left, zero_pad, prefix)
			continue
		case 'n':
			// A SQL call has no pointer to write the length to.
			if !args.sql {
				if counter := args.c_counter(args.user); counter != nil do counter^ = i32(len(s.text))
			}
			continue
		case '%':
			buffer[0] = '%'
			out = buffer[:1]
		case 'c':
			one: []u8
			if args.sql {
				// A SQL call's %c is the first character of its text.
				text, present, _ := printf_arg_text(args)
				n := 0
				if present && len(text) > 0 {
					buffer[0] = text[0]
					n = 1
					if text[0] & 0xc0 == 0xc0 {
						for n < 4 && n < len(text) && text[n] & 0xc0 == 0x80 {
							buffer[n] = text[n]
							n += 1
						}
					}
				} else {
					buffer[0] = 0
					n = 1
				}
				one = buffer[:n]
			} else {
				n := printf_utf8_encode(buffer[:], u32(printf_arg_int(args)))
				one = buffer[:n]
			}
			if precision > 1 {
				width -= precision - 1
				if width > 1 && !left {
					printf_put_char(s, width - 1, ' ')
					width = 0
				}
				for _ in 0 ..< precision - 1 do printf_put(s, one)
			}
			out = one
			alt2 = true
		case 's', 'z':
			text, _, pointer := printf_arg_text(args)
			out = printf_clip(text, precision, alt2)
			if conversion == 'z' && pointer != nil && args.c_free != nil {
				append(&extra, ..out)
				out = extra[:]
				args.c_free(pointer)
			}
		case 'q', 'Q', 'w':
			text, present, _ := printf_arg_text(args)
			out = printf_quoted(&extra, conversion, text, present, precision, alternate, alt2)
		case 'j', 'J':
			text, present, _ := printf_arg_text(args)
			printf_json(s, conversion, text, present, precision, alt2, left, width)
			continue
		case:
			return
		}
		// Width, counted in characters when `!` asks for it.
		if alt2 && width > 0 {
			for b in out do if b & 0xc0 == 0x80 do width += 1
		}
		pad := width - len(out)
		if pad > 0 && !left do printf_put_char(s, pad, ' ')
		printf_put(s, out)
		if pad > 0 && left do printf_put_char(s, pad, ' ')
	}
}

@(private)
printf_clip :: proc(text: []u8, precision: int, characters: bool) -> []u8 {
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
printf_utf8_encode :: proc(out: []u8, ch: u32) -> int {
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
printf_integer :: proc(
	out: ^[dynamic]u8,
	conversion: u8,
	args: ^Printf_Args,
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
		v := i64(printf_arg_integer(args, long_flag, true))
		if v < 0 {
			value = ~u64(v) + 1
			sign = '-'
		} else {
			value = u64(v)
			sign = prefix_flag
		}
	} else {
		value = printf_arg_integer(args, long_flag, false)
	}
	if value == 0 do alternate = false
	if zero && precision < width - (sign != 0 ? 1 : 0) do precision = width - (sign != 0 ? 1 : 0)
	digits := PRINTF_DIGITS
	scratch: [64]u8
	at := len(scratch)
	v := value
	for {
		at -= 1
		scratch[at] = digits[charset + int(v % base)]
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

// printf_padded writes a number padded to `width`: spaces on the left or the
// right, or zeros after the sign.
@(private)
printf_padded :: proc(s: ^Printf_Out, text: []u8, width: int, left: bool, zero: bool, prefix: u8) {
	pad := width - len(text)
	if pad <= 0 {
		printf_put(s, text)
		return
	}
	if left {
		printf_put(s, text)
		printf_put_char(s, pad, ' ')
	} else if !zero {
		printf_put_char(s, pad, ' ')
		printf_put(s, text)
	} else {
		adjust := prefix != 0 ? 1 : 0
		printf_put(s, text[:adjust])
		printf_put_char(s, pad, '0')
		printf_put(s, text[adjust:])
	}
}

@(private)
printf_quoted :: proc(out: ^[dynamic]u8, conversion: u8, z: []u8, present: bool, precision: int, alternate: bool, alt2: bool) -> []u8 {
	hex := "0123456789abcdef"
	text: []u8
	need_quote := 0
	alternate := alternate
	if !present {
		text = transmute([]u8)string(conversion == 'Q' ? "NULL" : "(NULL)")
	} else {
		text = z
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
printf_json :: proc(s: ^Printf_Out, conversion: u8, text: []u8, present: bool, precision: int, alt2: bool, left: bool, width: int) {
	hex := "0123456789abcdef"
	start := len(s.text)
	if !present {
		if conversion == 'J' do printf_put_string(s, "null")
	} else {
		if conversion == 'J' do printf_put_string(s, "\"")
		limit := precision < 0 ? len(text) : len(printf_clip(text, precision, alt2))
		for b in text[:limit] {
			switch {
			case b == '"' || b == '\\':
				printf_put_char(s, 1, '\\')
				printf_put_char(s, 1, b)
			case b == 8:
				printf_put_string(s, "\\b")
			case b == 9:
				printf_put_string(s, "\\t")
			case b == 10:
				printf_put_string(s, "\\n")
			case b == 12:
				printf_put_string(s, "\\f")
			case b == 13:
				printf_put_string(s, "\\r")
			case b <= 0x1f:
				printf_put_string(s, "\\u00")
				printf_put_char(s, 1, hex[b >> 4])
				printf_put_char(s, 1, hex[b & 0xf])
			case:
				printf_put_char(s, 1, b)
			}
		}
		if conversion == 'J' do printf_put_string(s, "\"")
	}
	if width <= 0 || s.too_big do return
	n := len(s.text) - start
	length := n
	if alt2 do for b in s.text[start:] do if b & 0xc0 == 0x80 do length -= 1
	if width > length {
		pad := width - length
		printf_put_char(s, pad, ' ')
		if !left && n > 0 && !s.too_big {
			copy(s.text[start + pad:], s.text[start:start + n])
			for k in 0 ..< pad do s.text[start + k] = ' '
		}
	}
}

// sqlite_printf_values is SQL's printf() and format(): the pattern with the
// call's values as its arguments, as SQLite formats them. `too_big` is
// SQLite's "string or blob too big".
sqlite_printf_values :: proc(pattern: string, values: []Value, alloc: mem.Allocator = context.allocator) -> (text: string, too_big: bool) {
	out := Printf_Out{text = make([dynamic]u8, 0, len(pattern) + 16, context.temp_allocator)}
	args := Printf_Args{values = values, sql = true}
	printf_append(&out, transmute([]u8)pattern, &args)
	if out.too_big do return "", true
	return strings.clone(string(out.text[:]), alloc), false
}
