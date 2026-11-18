package tests

import "core:c"
import "core:os"
import "core:strings"
import "core:testing"

import face "../sqlite_compat"

// SQLite's printf, through the facade's exports: every expected text here is
// what SQLite 3.53.4 itself wrote for the same call (a C program loading
// libsqlite3 and the facade in turn; %j and %J are 3.54's, read from its
// printf.c). A program builds SQL with %q, %Q and %w, so the bytes matter.

@(private = "file")
expect_format :: proc(t: ^testing.T, got: cstring, want: string, loc := #caller_location) {
	defer face.sqlite3_free(rawptr(got))
	testing.expectf(t, string(got) == want, "got %q, want %q", string(got), want, loc = loc)
}

@(test)
test_printf_is_sqlite_printf :: proc(t: ^testing.T) {
	mp :: face.sqlite3_mprintf
	expect_format(t, mp("%d|%5d|%-5d|%05d|%+d|% d|%,d|%,d", c.int(42), c.int(42), c.int(42), c.int(-42), c.int(42), c.int(42), c.int(1234567), c.int(-1000)), "42|   42|42   |-0042|+42| 42|1,234,567|-1,000")
	expect_format(t, mp("%i|%u|%u", c.int(-7), c.uint(3000000000), c.uint(0)), "-7|3000000000|0")
	expect_format(t, mp("%lld|%llu|%lld", min(i64), max(u64), i64(1) << 40), "-9223372036854775808|18446744073709551615|1099511627776")
	expect_format(t, mp("%ld|%lu", c.long(-5), c.ulong(7)), "-5|7")
	expect_format(t, mp("%x|%X|%#x|%#X|%o|%#o|%08x|%#010x", c.int(255), c.int(255), c.int(255), c.int(255), c.int(8), c.int(8), c.int(0xbeef), c.int(0xbeef)), "ff|FF|0xff|0XFF|10|010|0000beef|0x000000beef")
	expect_format(t, mp("%#x|%#o", c.int(0), c.int(0)), "0|0")
	expect_format(t, mp("%r %r %r %r %r %r %r %r", c.int(1), c.int(2), c.int(3), c.int(4), c.int(11), c.int(12), c.int(13), c.int(101)), "1st 2nd 3rd 4th 11th 12th 13th 101st")
	expect_format(t, mp("%.5d|%8.3d|%-8.3d|%.0d", c.int(42), c.int(7), c.int(7), c.int(0)), "00042|     007|007     |0")
	expect_format(t, mp("%*d|%-*d|%.*d|%*.*d", c.int(6), c.int(1), c.int(6), c.int(2), c.int(4), c.int(3), c.int(7), c.int(5), c.int(9)), "     1|2     |0003|  00009")
	expect_format(t, mp("%*d|", c.int(-6), c.int(1)), "1     |")
	expect_format(t, mp("%c|%5c|%-3c|%.3c|%5.3c", c.int('a'), c.int('b'), c.int('c'), c.int('x'), c.int('y')), "a|    b|c  |xxx|  yyy")
	expect_format(t, mp("%s|%10s|%-10s|%.2s|%s", cstring("hello"), cstring("hi"), cstring("hi"), cstring("hello"), cstring(nil)), "hello|        hi|hi        |he|")
	expect_format(t, mp("%!.2s|%.2s|%!5s|", cstring("été"), cstring("été"), cstring("é")), "ét|é|    é|")
	expect_format(t, mp("%q|%Q|%Q|%w|%q", cstring("it's"), cstring("it's"), cstring(nil), cstring("a\"b"), cstring(nil)), "it''s|'it''s'|NULL|a\"\"b|(NULL)")
	expect_format(t, mp("%.3Q|%.2q", cstring("abcdef"), cstring("o'neil")), "'abc'|o''")
	expect_format(t, mp("%#q|%#Q|%#Q", cstring("a\\b\nc"), cstring("plain"), cstring("tab\there")), "a\\\\b\\u000ac|'plain'|unistr('tab\\u0009here')")
	expect_format(t, mp("%j|%J|%J|%10J|%-10J|", cstring("a\"b\\c\n"), cstring("x"), cstring(nil), cstring("ab"), cstring("ab")), "a\\\"b\\\\c\\n|\"x\"|null|      \"ab\"|\"ab\"      |")
	expect_format(t, mp("%f|%.2f|%10.3f|%-10.1f|%+.1f|%.0f|%#.0f|%,.2f", 3.14159, 2.675, 1.5, 2.25, 1.0, 2.5, 3.0, 1234567.891), "3.141590|2.67|     1.500|2.3       |+1.0|3|3.|1,234,567.89")
	expect_format(t, mp("%.2f|%.3f|%.1f|%f", 0.001, 0.0005, 0.05, 1e-7), "0.00|0.001|0.1|0.000000")
	expect_format(t, mp("%e|%.2e|%E|%.0e|%e|%e", 12345.678, 0.000123, 1.0, 5.5, 0.0, -2.5e-300), "1.234568e+04|1.23e-04|1.000000E+00|6e+00|0.000000e+00|-2.500000e-300")
	expect_format(t, mp("%g|%g|%g|%g|%g|%G|%.3g|%#g|%g", 100000.0, 1000000.0, 0.0001, 0.00001, 1.5, 1e-10, 3.14159, 1.0, 0.0), "100000|1e+06|0.0001|1e-05|1.5|1E-10|3.14|1.00000|0")
	expect_format(t, mp("%!.17g|%!.15g|%!g|%.17g|%.20f", 0.1, 49.47, 1.0, 0.1, 0.1), "0.1|49.47|1.0|0.1|0.10000000000000000000")
	inf := transmute(f64)u64(0x7ff0000000000000)
	nan := transmute(f64)u64(0x7ff8000000000000)
	expect_format(t, mp("%f|%f|%+f|%e|%g|%f", inf, -inf, inf, inf, inf, nan), "Inf|-Inf|+Inf|Inf|Inf|NaN")
	expect_format(t, mp("%010.2f|%-10.2f|%+010.2f|%10e", -3.5, 3.5, 3.5, 1.0), "-000003.50|3.50      |+000003.50|1.000000e+00")
	expect_format(t, mp("100%% %d", c.int(5)), "100% 5")
	expect_format(t, mp("a%yb %d", c.int(5)), "a")
	expect_format(t, mp("abc%"), "abc%")
	expect_format(t, mp(""), "")

	n: c.int = -1
	expect_format(t, mp("abc%n%d", &n, c.int(5)), "abc5")
	testing.expect_value(t, n, 3)

	buffer: [8]u8
	same := face.sqlite3_snprintf(len(buffer), raw_data(buffer[:]), "%s-%d", cstring("abcdef"), c.int(12345))
	testing.expect_value(t, string(cstring(raw_data(buffer[:]))), "abcdef-")
	testing.expect(t, rawptr(same) == raw_data(buffer[:]))

	s := face.sqlite3_str_new(nil)
	face.sqlite3_str_appendf(s, "%s:%d;", cstring("a"), c.int(1))
	face.sqlite3_str_append(s, raw_data(string("xyz")), 2)
	face.sqlite3_str_appendchar(s, 3, '-')
	testing.expect_value(t, face.sqlite3_str_length(s), 9)
	expect_format(t, face.sqlite3_str_finish(s), "a:1;xy---")
	testing.expect(t, face.sqlite3_str_finish(face.sqlite3_str_new(nil)) == nil, "an empty builder finishes as NULL")
}

// The same 500 doubles SQLite 3.53.4 formatted, eight ways each: SQLite's own
// decimal conversion (18 approximate digits, rounded half away from zero) is
// what the facade reproduces, last digit included.
@(test)
test_printf_doubles_are_sqlite_doubles :: proc(t: ^testing.T) {
	data, read_err := os.read_entire_file("src/tests/fixtures/printf_sqlite_3_53.txt", context.allocator)
	if !testing.expectf(t, read_err == nil, "fixture: %v", read_err) do return
	defer delete(data)
	lines := strings.split_lines(strings.trim_right(string(data), "\r\n"), context.allocator)
	defer delete(lines)
	x: u64 = 88172645463325252
	mismatches := 0
	for want, k in lines {
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		v: f64
		switch k % 3 {
		case 0:
			v = transmute(f64)(x & 0x7fefffffffffffff)
		case 1:
			v = f64(i64(x % 2000000)) / 1000.0
		case:
			v = f64(x % 100000) / 8.0
		}
		if k & 1 != 0 do v = -v
		got := face.sqlite3_mprintf("%.15g|%!.15g|%.17g|%.6f|%.3e|%g|%.2f|%.10g", v, v, v, v, v, v, v, v)
		if string(got) != strings.trim_right(want, "\r") {
			if mismatches < 5 do testing.expectf(t, false, "value %d: got %q, want %q", k, string(got), want)
			mismatches += 1
		}
		face.sqlite3_free(rawptr(got))
	}
	testing.expect_value(t, mismatches, 0)
	testing.expect_value(t, len(lines), 500)
}
