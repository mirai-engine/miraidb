package engine

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

// SQLite's answers where the engine's own rules differ, for a statement that
// runs under SQLite's rules: the sqlite3_* face and a SQLite file
// (docs/sqlite-semantics.md).

// sqlite_arithmetic is SQLite's arithmetic over integers and reals: a
// division or a remainder by zero is NULL, an integer result that leaves 64
// bits is computed as a REAL, and `%` takes both operands as integers,
// answering a REAL when either was one.
sqlite_arithmetic :: proc(op: Binary_Op, left, right: Value) -> Value {
	as_int :: proc(v: Value) -> i64 {
		#partial switch v.kind {
		case .Bool:
			return v.b ? 1 : 0
		case .Float:
			return sqlite_real_to_int(v.f)
		}
		return v.i
	}
	as_real :: proc(v: Value) -> f64 {
		#partial switch v.kind {
		case .Bool:
			return v.b ? 1 : 0
		case .Int:
			return f64(v.i)
		}
		return v.f
	}
	real := left.kind == .Float || right.kind == .Float
	if op == .Mod {
		a, b := as_int(left), as_int(right)
		if b == 0 do return value_null()
		remainder := b == -1 ? i64(0) : a % b
		return real ? value_float(f64(remainder)) : value_int(remainder)
	}
	if real {
		a, b := as_real(left), as_real(right)
		#partial switch op {
		case .Add:
			return value_float(a + b)
		case .Sub:
			return value_float(a - b)
		case .Mul:
			return value_float(a * b)
		case .Div:
			if b == 0 do return value_null()
			return value_float(a / b)
		}
		return value_null()
	}
	a, b := as_int(left), as_int(right)
	#partial switch op {
	case .Add:
		if sum, overflow := intrinsics.overflow_add(a, b); !overflow do return value_int(sum)
		return value_float(f64(a) + f64(b))
	case .Sub:
		if difference, overflow := intrinsics.overflow_sub(a, b); !overflow do return value_int(difference)
		return value_float(f64(a) - f64(b))
	case .Mul:
		if product, overflow := intrinsics.overflow_mul(a, b); !overflow do return value_int(product)
		return value_float(f64(a) * f64(b))
	case .Div:
		if b == 0 do return value_null()
		if a == min(i64) && b == -1 do return value_float(-f64(a))
		return value_int(a / b)
	}
	return value_null()
}

// sqlite_real_to_int truncates toward zero and clamps, as SQLite converts.
sqlite_real_to_int :: proc(f: f64) -> i64 {
	if math.is_nan(f) do return 0
	if f >= 9223372036854775807.0 do return max(i64)
	if f <= -9223372036854775808.0 do return min(i64)
	return i64(f)
}

// sqlite_numeric_prefix reads the longest number at the start of a text:
// spaces, a sign, digits, a fraction and an exponent. `integer` says it had
// neither a fraction nor an exponent.
sqlite_numeric_prefix :: proc(text: string) -> (number: string, integer: bool) {
	at := 0
	for at < len(text) && (text[at] == ' ' || text[at] == '\t' || text[at] == '\n' || text[at] == '\r') do at += 1
	start := at
	if at < len(text) && (text[at] == '+' || text[at] == '-') do at += 1
	digits := 0
	for at < len(text) && text[at] >= '0' && text[at] <= '9' {
		at += 1
		digits += 1
	}
	integer = true
	if at < len(text) && text[at] == '.' {
		fraction := at + 1
		for fraction < len(text) && text[fraction] >= '0' && text[fraction] <= '9' do fraction += 1
		if digits > 0 || fraction > at + 1 {
			digits += fraction - at - 1
			at = fraction
			integer = false
		}
	}
	if digits == 0 do return "", true
	if at < len(text) && (text[at] == 'e' || text[at] == 'E') {
		exponent := at + 1
		if exponent < len(text) && (text[exponent] == '+' || text[exponent] == '-') do exponent += 1
		if exponent < len(text) && text[exponent] >= '0' && text[exponent] <= '9' {
			for exponent < len(text) && text[exponent] >= '0' && text[exponent] <= '9' do exponent += 1
			at = exponent
			integer = false
		}
	}
	return text[start:at], integer
}

// sqlite_text_to_int is CAST(text AS INTEGER): the longest integer prefix,
// clamped; a text without one is 0.
sqlite_text_to_int :: proc(text: string) -> i64 {
	at := 0
	for at < len(text) && (text[at] == ' ' || text[at] == '\t' || text[at] == '\n' || text[at] == '\r') do at += 1
	negative := false
	if at < len(text) && (text[at] == '+' || text[at] == '-') {
		negative = text[at] == '-'
		at += 1
	}
	magnitude: u64 = 0
	big := false
	for at < len(text) && text[at] >= '0' && text[at] <= '9' {
		digit := u64(text[at] - '0')
		if magnitude > (max(u64) - digit) / 10 {
			big = true
		} else {
			magnitude = magnitude * 10 + digit
		}
		at += 1
	}
	if negative {
		if big || magnitude > u64(max(i64)) + 1 do return min(i64)
		return -i64(magnitude)
	}
	if big || magnitude > u64(max(i64)) do return max(i64)
	return i64(magnitude)
}

// sqlite_text_to_real is CAST(text AS REAL): the longest real prefix, or 0.0.
sqlite_text_to_real :: proc(text: string) -> f64 {
	number, _ := sqlite_numeric_prefix(text)
	if len(number) == 0 do return 0
	parsed, ok := strconv.parse_f64(number)
	if !ok {
		// An exponent past the range still says which way it went.
		if strings.contains(number, "e-") || strings.contains(number, "E-") do return 0
		return strings.has_prefix(number, "-") ? math.inf_f64(-1) : math.inf_f64(1)
	}
	return parsed
}

// sqlite_cast is SQLite's CAST: the target is read by its affinity.
sqlite_cast :: proc(v: Value, type_name: string) -> Value {
	if v.kind == .Null do return value_null()
	affinity := sqlite_affinity_type(type_name)
	text_of :: proc(v: Value) -> string {
		if v.kind == .Bytes do return string(v.bytes)
		return sqlite_value_text(v, context.allocator)
	}
	upper := strings.to_upper(type_name, context.temp_allocator)
	switch {
	case affinity.kind == .Int:
		#partial switch v.kind {
		case .Int:
			return v
		case .Bool:
			return value_int(v.b ? 1 : 0)
		case .Float:
			return value_int(sqlite_real_to_int(v.f))
		}
		return value_int(sqlite_text_to_int(text_of(v)))
	case affinity.kind == .Float:
		#partial switch v.kind {
		case .Float:
			return v
		case .Int:
			return value_float(f64(v.i))
		case .Bool:
			return value_float(v.b ? 1 : 0)
		}
		return value_float(sqlite_text_to_real(text_of(v)))
	case affinity.kind == .String:
		if v.kind == .String do return v
		return value_string(text_of(v))
	case strings.contains(upper, "BLOB") || len(strings.trim_space(upper)) == 0:
		// BLOB (no affinity): the value's bytes.
		if v.kind == .Bytes do return v
		text := text_of(v)
		bytes := make([]u8, len(text))
		copy(bytes, text)
		return value_bytes(bytes)
	}
	// NUMERIC: an integer when the prefix is one and fits, a real otherwise; a
	// real stays a real.
	#partial switch v.kind {
	case .Int, .Float:
		return v
	case .Bool:
		return value_int(v.b ? 1 : 0)
	}
	number, integer := sqlite_numeric_prefix(text_of(v))
	if len(number) == 0 do return value_int(0)
	if integer {
		if parsed, ok := strconv.parse_i64(number); ok do return value_int(parsed)
	}
	real := sqlite_text_to_real(number)
	if real == math.trunc(real) && math.abs(real) < 9.2e18 do return value_int(i64(real))
	return value_float(real)
}

// ascii_case folds ASCII letters only, as SQLite's upper, lower and LIKE do.
ascii_case :: proc(text: string, upper: bool, alloc: mem.Allocator = context.allocator) -> string {
	out := make([]u8, len(text), alloc)
	for i in 0 ..< len(text) {
		c := text[i]
		if upper && c >= 'a' && c <= 'z' do c -= 32
		if !upper && c >= 'A' && c <= 'Z' do c += 32
		out[i] = c
	}
	return string(out)
}
