package engine

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:math"
import "core:mem"
import "base:runtime"
import "core:sync"

// Timestamp is microseconds since the Unix epoch, UTC.
Timestamp :: distinct i64

// Uuid is a 128-bit identifier stored big-endian, as text form prints it.
Uuid :: distinct [16]u8

// Duration is a signed length of time in microseconds.
Duration :: distinct i64

// Identity is the 32-byte identifier of a client or module.
Identity :: distinct [32]u8

// Value_Kind is the runtime tag of a Value. It mirrors Type_Kind plus Null and
// the composite kinds used inside product values.
Value_Kind :: enum u8 {
	Null,
	Default,
	Bool,
	Int,
	Uint,
	Float,
	String,
	Bytes,
	Timestamp,
	Uuid,
	Array,
	Product,
	Int128,
	Uint128,
	Duration,
	Identity,
	Connection,
}

// Value_Payload is the 16-byte payload of a Value. Every field starts at the
// same offset (a raw union), so only the one selected by `kind` is meaningful;
// the others alias its bytes. Two payloads need more than 16 bytes: Int128 and
// Uint128 keep their 128 bits as two words (a u128 field would force 16-byte
// alignment and grow the value to 32), and the 32-byte Identity lives behind a
// pointer into an intern table. Together they keep size_of(Value) at 24.
Value_Payload :: struct #raw_union {
	b:     bool,
	i:     i64,
	u:     u64,
	f:     f64,
	s:     string,
	bytes: []u8,
	uuid:  Uuid,
	list:  []Value,
	big:   [2]u64,
	ident: ^Identity,
}

// Value is a dynamically typed value. Only the field that matches `kind` is
// meaningful. Ints are signed 64-bit, Uints unsigned 64-bit and Floats IEEE-754
// double; Int128/Uint128 are read through value_big and Identity through
// value_identity_of.
Value :: struct {
	kind: Value_Kind,
	using payload: Value_Payload,
}

// big_words splits a 128-bit number into the two words the payload stores,
// least significant first, so the layout keeps 8-byte alignment.
@(private)
big_words :: proc(v: u128) -> [2]u64 {
	return {u64(v), u64(v >> 64)}
}

// value_big returns the 128-bit payload of an Int128 or Uint128 value.
value_big :: proc(v: Value) -> u128 {
	return u128(v.big[0]) | u128(v.big[1]) << 64
}

// identity_table interns 32-byte identities so a Value can point at one from
// its 16-byte payload. Identities are few (one per client or module) and a value
// may be copied into any number of rows, so the table owns them and never frees.
@(private = "file")
identity_table: map[Identity]^Identity
@(private = "file")
identity_table_lock: sync.Mutex

@(private)
intern_identity :: proc(id: Identity) -> ^Identity {
	sync.mutex_lock(&identity_table_lock)
	defer sync.mutex_unlock(&identity_table_lock)
	if stored, ok := identity_table[id]; ok {
		return stored
	}
	stored := new(Identity, runtime.heap_allocator())
	stored^ = id
	// The table outlives every temporary allocator a caller may install (the
	// test runner tracks leaks per test), so it grows on the process heap.
	previous := context.allocator
	context.allocator = runtime.heap_allocator()
	identity_table[id] = stored
	context.allocator = previous
	return stored
}

// value_identity_of returns the identity payload, or the zero identity when the
// value holds something else.
value_identity_of :: proc(v: Value) -> Identity {
	if v.kind == .Identity && v.ident != nil {
		return v.ident^
	}
	return {}
}

value_null :: proc() -> Value {
	return Value{kind = .Null}
}

// value_default marks a column the caller did not supply, so the engine can tell
// it apart from an explicit NULL. It never reaches storage.
value_default :: proc() -> Value {
	return Value{kind = .Default}
}

value_bool :: proc(b: bool) -> Value {
	return Value{kind = .Bool, b = b}
}

value_int :: proc(i: i64) -> Value {
	return Value{kind = .Int, i = i}
}

value_uint :: proc(u: u64) -> Value {
	return Value{kind = .Uint, u = u}
}

value_float :: proc(f: f64) -> Value {
	return Value{kind = .Float, f = f}
}

value_string :: proc(s: string) -> Value {
	return Value{kind = .String, s = s}
}

value_bytes :: proc(b: []u8) -> Value {
	return Value{kind = .Bytes, bytes = b}
}

value_timestamp :: proc(t: Timestamp) -> Value {
	return Value{kind = .Timestamp, i = i64(t)}
}

value_uuid :: proc(u: Uuid) -> Value {
	return Value{kind = .Uuid, uuid = u}
}

value_int128 :: proc(v: i128) -> Value {
	return Value{kind = .Int128, big = big_words(u128(v))}
}

value_uint128 :: proc(v: u128) -> Value {
	return Value{kind = .Uint128, big = big_words(v)}
}

value_as_i128 :: proc(v: Value) -> i128 {
	#partial switch v.kind {
	case .Int128:
		return i128(value_big(v))
	case .Uint128:
		return i128(value_big(v))
	case .Int, .Timestamp:
		return i128(v.i)
	case .Uint:
		return i128(v.u)
	case .Duration:
		return i128(v.i)
	case .Connection:
		return i128(v.u)
	case .Float:
		return i128(v.f)
	}
	return 0
}

value_as_u128 :: proc(v: Value) -> u128 {
	#partial switch v.kind {
	case .Int128:
		return value_big(v)
	case .Uint128:
		return value_big(v)
	case .Int, .Timestamp:
		return u128(v.i)
	case .Uint:
		return u128(v.u)
	case .Duration:
		return u128(v.i)
	case .Connection:
		return u128(v.u)
	case .Float:
		return u128(v.f)
	}
	return 0
}

value_duration :: proc(v: Duration) -> Value {
	return Value{kind = .Duration, i = i64(v)}
}

value_identity :: proc(v: Identity) -> Value {
	return Value{kind = .Identity, ident = intern_identity(v)}
}

value_connection :: proc(v: u64) -> Value {
	return Value{kind = .Connection, u = v}
}

value_array :: proc(items: []Value) -> Value {
	return Value{kind = .Array, list = items}
}

value_product :: proc(items: []Value) -> Value {
	return Value{kind = .Product, list = items}
}

value_is_null :: proc(v: Value) -> bool {
	return v.kind == .Null
}

// value_is_numeric reports whether the value takes part in numeric arithmetic.
value_is_numeric :: proc(v: Value) -> bool {
	#partial switch v.kind {
	case .Int, .Uint, .Float, .Timestamp, .Int128, .Uint128, .Duration, .Connection:
		return true
	case:
		return false
	}
}

value_kind_name :: proc(kind: Value_Kind) -> string {
	switch kind {
	case .Null:
		return "null"
	case .Default:
		return "default"
	case .Bool:
		return "bool"
	case .Int:
		return "int"
	case .Uint:
		return "uint"
	case .Float:
		return "float"
	case .String:
		return "string"
	case .Bytes:
		return "bytes"
	case .Timestamp:
		return "timestamp"
	case .Uuid:
		return "uuid"
	case .Array:
		return "array"
	case .Product:
		return "product"
	case .Int128:
		return "int128"
	case .Uint128:
		return "uint128"
	case .Duration:
		return "duration"
	case .Identity:
		return "identity"
	case .Connection:
		return "connection"
	}
	return "unknown"
}

// value_clone deep-copies a value into `alloc`. Composite and byte values are
// copied so the result never aliases the argument.
value_clone :: proc(v: Value, alloc: mem.Allocator) -> Value {
	out := v
	#partial switch v.kind {
	case .String:
		out.s = strings.clone(v.s, alloc)
	case .Bytes:
		out.bytes = slice.clone(v.bytes, alloc)
	case .Array, .Product:
		list := make([]Value, len(v.list), alloc)
		for item, i in v.list {
			list[i] = value_clone(item, alloc)
		}
		out.list = list
	case:
	}
	return out
}

// value_deep_free releases what value_clone allocated, when the value lives in
// a per-value allocator. Tables use arenas instead and do not call this.
value_deep_free :: proc(v: Value, alloc: mem.Allocator) {
	#partial switch v.kind {
	case .String:
		delete(v.s, alloc)
	case .Bytes:
		delete(v.bytes, alloc)
	case .Array, .Product:
		for item in v.list {
			value_deep_free(item, alloc)
		}
		delete(v.list, alloc)
	case:
	}
}

// values_destroy frees a list of values and the list itself; it is the way to
// release what a call returned.
values_destroy :: proc(values: []Value) {
	value_deep_free(value_product(values), context.allocator)
}

// value_wire_size estimates the bytes a value contributes on the wire. It is a
// hint for sizing buffers and quotas, not an exact encoding length.
value_wire_size :: proc(v: Value) -> u64 {
	switch v.kind {
	case .Null, .Default:
		return 1
	case .Bool:
		return 1
	case .String:
		return u64(len(v.s))
	case .Bytes:
		return u64(len(v.bytes))
	case .Array, .Product:
		total := u64(0)
		for item in v.list do total += value_wire_size(item)
		return total
	case .Int, .Uint, .Float, .Timestamp, .Duration, .Connection:
		return 8
	case .Int128, .Uint128:
		return 16
	case .Uuid:
		return 16
	case .Identity:
		return 32
	}
	return 8
}

// value_equal is structural equality. Numeric values compare across kinds, so
// `1` (int) equals `1` (uint) and `1.0` (float).
value_equal :: proc(a, b: Value) -> bool {
	if value_is_numeric(a) && value_is_numeric(b) {
		return numeric_equal(a, b)
	}
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case .Null, .Default:
		return true
	case .Bool:
		return a.b == b.b
	case .String:
		return a.s == b.s
	case .Bytes:
		return slice.equal(a.bytes, b.bytes)
	case .Uuid:
		return a.uuid == b.uuid
	case .Identity:
		return value_identity_of(a) == value_identity_of(b)
	case .Timestamp:
		return a.i == b.i
	case .Array, .Product:
		if len(a.list) != len(b.list) {
			return false
		}
		for item, i in a.list {
			if !value_equal(item, b.list[i]) {
				return false
			}
		}
		return true
	case .Int, .Uint, .Float, .Int128, .Uint128, .Duration, .Connection:
		return numeric_equal(a, b)
	}
	return false
}

@(private)
numeric_equal :: proc(a, b: Value) -> bool {
	return numeric_compare_exact(a, b) == .Equal
}

@(private)
numeric_as_f64 :: proc(v: Value) -> (f64, bool) {
	#partial switch v.kind {
	case .Int, .Timestamp:
		if v.i > (1 << 53) || v.i < -(1 << 53) do return 0, false
		return f64(v.i), true
	case .Uint:
		if v.u > (1 << 53) do return 0, false
		return f64(v.u), true
	case .Float:
		return v.f, true
	case .Int128:
		return f64(i128(value_big(v))), true
	case .Uint128:
		return f64(value_big(v)), true
	case .Duration:
		return f64(v.i), true
	case .Connection:
		return f64(v.u), true
	}
	return 0, false
}

// value_compare orders values of the same kind, and numeric values across
// kinds. Null sorts before everything. `ok` is false when the two values are
// not comparable (for example a string and a timestamp).
value_compare :: proc(a, b: Value) -> (order: slice.Ordering, ok: bool) {
	if a.kind == .Null || b.kind == .Null {
		if a.kind == .Null && b.kind == .Null do return .Equal, true
		if a.kind == .Null do return .Less, true
		return .Greater, true
	}
	if value_is_numeric(a) && value_is_numeric(b) {
		return numeric_compare_exact(a, b), true
	}
	if a.kind != b.kind {
		return .Equal, false
	}
	switch a.kind {
	case .Default:
		return .Equal, true
	case .Bool:
		if a.b == b.b do return .Equal, true
		return a.b ? .Greater : .Less, true
	case .String:
		return string_ordering(strings.compare(a.s, b.s)), true
	case .Bytes:
		return slice_ordering(cmp_bytes(a.bytes, b.bytes)), true
	case .Uuid:
		return slice_ordering(cmp_uuid(a.uuid, b.uuid)), true
	case .Identity:
		return slice_ordering(cmp_identity(value_identity_of(a), value_identity_of(b))), true
	case .Timestamp:
		return slice_ordering(slice.cmp(a.i, b.i)), true
	case .Array, .Product:
		n := min(len(a.list), len(b.list))
		for i in 0 ..< n {
			o, inner_ok := value_compare(a.list[i], b.list[i])
			if !inner_ok do return .Equal, false
			if o != .Equal do return o, true
		}
		return slice_ordering(slice.cmp(len(a.list), len(b.list))), true
	case .Null:
		return .Equal, true
	case .Int, .Uint, .Float, .Int128, .Uint128, .Duration, .Connection:
		return numeric_compare_exact(a, b), true
	}
	return .Equal, false
}

@(private)
is_unsigned_kind :: proc(kind: Value_Kind) -> bool {
	return kind == .Uint || kind == .Uint128
}

@(private)
numeric_compare_exact :: proc(a, b: Value) -> slice.Ordering {
	// A float on either side promotes the comparison to double.
	if a.kind != .Float && b.kind != .Float {
		a_unsigned := is_unsigned_kind(a.kind)
		b_unsigned := is_unsigned_kind(b.kind)
		if a_unsigned && b_unsigned {
			au := value_as_u128(a)
			bu := value_as_u128(b)
			if au < bu do return .Less
			if au > bu do return .Greater
			return .Equal
		}
		max_signed := u128(max(i128))
		if a_unsigned && value_as_u128(a) > max_signed do return .Greater
		if b_unsigned && value_as_u128(b) > max_signed do return .Less
		ai := value_as_i128(a)
		bi := value_as_i128(b)
		if ai < bi do return .Less
		if ai > bi do return .Greater
		return .Equal
	}
	af, _ := numeric_as_f64(a)
	bf, _ := numeric_as_f64(b)
	if !is_finite_f64(af) || !is_finite_f64(bf) {
		return .Equal
	}
	if af < bf do return .Less
	if af > bf do return .Greater
	return .Equal
}

@(private)
cmp_bytes :: proc(a, b: []u8) -> slice.Ordering {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] < b[i] do return .Less
		if a[i] > b[i] do return .Greater
	}
	if len(a) < len(b) do return .Less
	if len(a) > len(b) do return .Greater
	return .Equal
}

@(private)
cmp_identity :: proc(a, b: Identity) -> slice.Ordering {
	for i in 0 ..< 32 {
		if a[i] < b[i] do return .Less
		if a[i] > b[i] do return .Greater
	}
	return .Equal
}

@(private)
cmp_uuid :: proc(a, b: Uuid) -> slice.Ordering {
	for i in 0 ..< 16 {
		if a[i] < b[i] do return .Less
		if a[i] > b[i] do return .Greater
	}
	return .Equal
}

@(private)
is_finite_f64 :: proc(f: f64) -> bool {
	return !math.is_nan(f) && !math.is_inf(f)
}

@(private)
string_ordering :: proc(c: int) -> slice.Ordering {
	if c < 0 do return .Less
	if c > 0 do return .Greater
	return .Equal
}

@(private)
slice_ordering :: proc(o: slice.Ordering) -> slice.Ordering {
	return o
}

// value_hash is consistent with value_equal for values of the same kind.
value_hash :: proc(v: Value) -> u64 {
	mix :: proc(h: u64, x: u64) -> u64 {
		return (h ~ x) * 0x100000001b3
	}
	h := u64(0xcbf29ce484222325)
	h = mix(h, u64(v.kind))
	switch v.kind {
	case .Null, .Default:
	case .Bool:
		h = mix(h, v.b ? 1 : 0)
	case .Int, .Timestamp:
		h = mix(h, u64(v.i))
	case .Uint:
		h = mix(h, v.u)
	case .Float:
		h = mix(h, u64(transmute(u64)v.f))
	case .String:
		for c in v.s do h = mix(h, u64(c))
	case .Bytes:
		for c in v.bytes do h = mix(h, u64(c))
	case .Uuid:
		for c in v.uuid do h = mix(h, u64(c))
	case .Array, .Product:
		h = mix(h, u64(len(v.list)))
		for item in v.list {
			h = mix(h, value_hash(item))
		}
	case .Int128, .Uint128:
		h = mix(h, u64(value_big(v)))
		h = mix(h, u64(value_big(v) >> 64))
	case .Duration:
		h = mix(h, u64(v.i))
	case .Connection:
		h = mix(h, v.u)
	case .Identity:
		id := value_identity_of(v)
		for c in id do h = mix(h, u64(c))
	}
	return h
}

// value_format renders the value for diagnostics and CLI output. `null` prints
// as NULL and strings print bare.
// value_format renders the value for diagnostics, CLI output and the text
// functions. The caller owns the result and must free it with the same
// allocator: the builder is destroyed here, so its buffer cannot be returned.
value_format :: proc(v: Value, alloc: mem.Allocator) -> string {
	b := strings.builder_make(alloc)
	defer strings.builder_destroy(&b)
	value_format_to(&b, v)
	return strings.clone(strings.to_string(b), alloc)
}

value_format_to :: proc(b: ^strings.Builder, v: Value) {
	switch v.kind {
	case .Null:
		strings.write_string(b, "NULL")
	case .Default:
		strings.write_string(b, "DEFAULT")
	case .Bool:
		strings.write_string(b, v.b ? "true" : "false")
	case .Int, .Timestamp:
		fmt.sbprintf(b, "%d", v.i)
	case .Uint:
		fmt.sbprintf(b, "%d", v.u)
	case .Int128:
		write_i128(b, i128(value_big(v)))
	case .Uint128:
		write_u128(b, value_big(v))
	case .Duration:
		fmt.sbprintf(b, "%d", v.i)
	case .Connection:
		fmt.sbprintf(b, "%d", v.u)
	case .Identity:
		id := value_identity_of(v)
		write_hex(b, id[:])
	case .Float:
		fmt.sbprintf(b, "%v", v.f)
	case .String:
		strings.write_string(b, v.s)
	case .Bytes:
		strings.write_string(b, "x'")
		for c in v.bytes {
			fmt.sbprintf(b, "%02x", c)
		}
		strings.write_string(b, "'")
	case .Uuid:
		strings.write_string(b, uuid_format(v.uuid))
	case .Array:
		strings.write_string(b, "[")
		for item, i in v.list {
			if i > 0 do strings.write_string(b, ", ")
			value_format_to(b, item)
		}
		strings.write_string(b, "]")
	case .Product:
		strings.write_string(b, "(")
		for item, i in v.list {
			if i > 0 do strings.write_string(b, ", ")
			value_format_to(b, item)
		}
		strings.write_string(b, ")")
	}
}

@(private)
write_hex :: proc(b: ^strings.Builder, bytes: []u8) {
	digits := "0123456789abcdef"
	for c in bytes {
		strings.write_byte(b, digits[c >> 4])
		strings.write_byte(b, digits[c & 0x0f])
	}
}

@(private)
write_u128 :: proc(b: ^strings.Builder, value: u128) {
	if value == 0 {
		strings.write_byte(b, '0')
		return
	}
	buf: [40]u8
	pos := len(buf)
	v := value
	for v > 0 {
		pos -= 1
		buf[pos] = u8('0' + u8(v % 10))
		v /= 10
	}
	strings.write_bytes(b, buf[pos:])
}

@(private)
write_i128 :: proc(b: ^strings.Builder, value: i128) {
	if value < 0 {
		strings.write_byte(b, '-')
		write_u128(b, u128(-value))
		return
	}
	write_u128(b, u128(value))
}

uuid_format :: proc(u: Uuid) -> string {
	hex_digits := "0123456789abcdef"
	buf: [36]u8
	pos := 0
	for c, i in u {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			buf[pos] = '-'
			pos += 1
		}
		buf[pos] = hex_digits[c >> 4]
		buf[pos + 1] = hex_digits[c & 0x0f]
		pos += 2
	}
	return string(buf[:])
}

uuid_parse :: proc(text: string) -> (Uuid, bool) {
	u: Uuid
	pos := 0
	for c in text {
		if c == '-' do continue
		if pos >= 32 do return {}, false
		digit, ok := hex_digit_value(c)
		if !ok do return {}, false
		byte_index := pos / 2
		if pos % 2 == 0 {
			u[byte_index] = u8(digit << 4)
		} else {
			u[byte_index] |= u8(digit)
		}
		pos += 1
	}
	return u, pos == 32
}

identity_parse :: proc(text: string) -> (Identity, bool) {
	id: Identity
	if len(text) != 64 do return id, false
	for i in 0 ..< 32 {
		high, high_ok := hex_digit_value(rune(text[i * 2]))
		low, low_ok := hex_digit_value(rune(text[i * 2 + 1]))
		if !high_ok || !low_ok do return id, false
		id[i] = u8(high << 4 | low)
	}
	return id, true
}

@(private)
hex_digit_value :: proc(c: rune) -> (int, bool) {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0'), true
	case c >= 'a' && c <= 'f':
		return int(c - 'a') + 10, true
	case c >= 'A' && c <= 'F':
		return int(c - 'A') + 10, true
	}
	return 0, false
}

// value_to_i64 / value_to_u64 / value_to_f64 convert with SQL-like rules: only
// numeric values convert, and a float truncates toward zero.
value_to_i64 :: proc(v: Value) -> (i64, bool) {
	#partial switch v.kind {
	case .Int, .Timestamp:
		return v.i, true
	case .Uint:
		if v.u > u64(max(i64)) do return 0, false
		return i64(v.u), true
	case .Float:
		// Truncate toward zero, saturating instead of converting out of range:
		// a caller asking for a start of 1e30 wants "past the end", not an
		// undefined conversion.
		if v.f != v.f do return 0, true
		if v.f >= 9223372036854775808.0 do return max(i64), true
		if v.f <= -9223372036854775808.0 do return min(i64), true
		return i64(v.f), true
	case .Int128:
		value := i128(value_big(v))
		if value < i128(min(i64)) || value > i128(max(i64)) do return 0, false
		return i64(value), true
	case .Uint128:
		if value_big(v) > u128(max(i64)) do return 0, false
		return i64(value_big(v)), true
	case .Duration:
		return v.i, true
	case .Connection:
		if v.u > u64(max(i64)) do return 0, false
		return i64(v.u), true
	}
	return 0, false
}

value_to_u64 :: proc(v: Value) -> (u64, bool) {
	#partial switch v.kind {
	case .Int, .Timestamp:
		if v.i < 0 do return 0, false
		return u64(v.i), true
	case .Uint:
		return v.u, true
	case .Float:
		if v.f < 0 do return 0, false
		return u64(v.f), true
	case .Int128:
		value := i128(value_big(v))
		if value < 0 || u128(value) > u128(max(u64)) do return 0, false
		return u64(value), true
	case .Uint128:
		if value_big(v) > u128(max(u64)) do return 0, false
		return u64(value_big(v)), true
	case .Duration:
		if v.i < 0 do return 0, false
		return u64(v.i), true
	case .Connection:
		return v.u, true
	}
	return 0, false
}

value_to_f64 :: proc(v: Value) -> (f64, bool) {
	#partial switch v.kind {
	case .Int, .Timestamp:
		return f64(v.i), true
	case .Uint:
		return f64(v.u), true
	case .Float:
		return v.f, true
	case .Int128:
		return f64(i128(value_big(v))), true
	case .Uint128:
		return f64(value_big(v)), true
	case .Duration:
		return f64(v.i), true
	case .Connection:
		return f64(v.u), true
	}
	return 0, false
}

// value_is_truthy is the SQL truth test: NULL and false are falsey.
value_is_truthy :: proc(v: Value) -> bool {
	#partial switch v.kind {
	case .Null:
		return false
	case .Bool:
		return v.b
	case .Int, .Timestamp:
		return v.i != 0
	case .Uint:
		return v.u != 0
	case .Int128, .Uint128:
		return value_big(v) != 0
	case .Duration:
		return v.i != 0
	case .Connection:
		return v.u != 0
	case .Float:
		return v.f != 0
	case .String:
		return len(v.s) != 0
	}
	return false
}

// value_parse_number turns a token into the narrowest numeric Value that holds
// it exactly, matching how the lexer classifies literals.
value_parse_number :: proc(text: string) -> (Value, bool) {
	clean := text
	is_float := false
	for c in clean {
		if c == '.' || c == 'e' || c == 'E' {
			is_float = true
			break
		}
	}
	if is_float {
		f, ok := strconv.parse_f64(clean)
		if !ok do return {}, false
		return value_float(f), true
	}
	negative := len(clean) > 0 && clean[0] == '-'
	digits := negative ? clean[1:] : clean
	trimmed := digits
	for len(trimmed) > 1 && trimmed[0] == '0' do trimmed = trimmed[1:]
	if len(trimmed) == 0 || len(trimmed) > 39 do return {}, false
	magnitude, ok := strconv.parse_u128(trimmed)
	if !ok do return {}, false
	// parse_u128 wraps on overflow; re-formatting catches it.
	formatted: [40]u8
	if u128_digits(magnitude, &formatted) != trimmed do return {}, false

	if negative {
		limit := u128(max(i128)) + 1
		if magnitude > limit do return {}, false
		signed := i128(0) - i128(magnitude)
		if signed >= i128(min(i64)) && signed <= i128(max(i64)) {
			return value_int(i64(signed)), true
		}
		return value_int128(signed), true
	}
	if magnitude <= u128(max(i64)) {
		return value_int(i64(magnitude)), true
	}
	if magnitude <= u128(max(u64)) {
		return value_uint(u64(magnitude)), true
	}
	return value_uint128(magnitude), true
}

@(private)
u128_digits :: proc(value: u128, buf: ^[40]u8) -> string {
	pos := len(buf)
	v := value
	if v == 0 {
		pos -= 1
		buf[pos] = '0'
		return string(buf[pos:])
	}
	for v > 0 {
		pos -= 1
		buf[pos] = u8('0' + u8(v % 10))
		v /= 10
	}
	return string(buf[pos:])
}
