package engine

import "core:mem"
import "core:slice"

// Byte_Writer appends little-endian primitives and length-prefixed blobs to a
// growable buffer. Every byte in the engine's own formats goes through it.
Byte_Writer :: struct {
	data: [dynamic]u8,
}

bw_init :: proc(w: ^Byte_Writer) {
	w.data = make([dynamic]u8)
}

bw_destroy :: proc(w: ^Byte_Writer) {
	delete(w.data)
	w.data = nil
}

bw_clear :: proc(w: ^Byte_Writer) {
	clear(&w.data)
}

bw_bytes :: proc(w: ^Byte_Writer) -> []u8 {
	return w.data[:]
}

bw_write_u8 :: proc(w: ^Byte_Writer, v: u8) {
	append(&w.data, v)
}

bw_write_raw :: proc(w: ^Byte_Writer, v: []u8) {
	append(&w.data, ..v)
}

bw_write_u16 :: proc(w: ^Byte_Writer, v: u16) {
	append(&w.data, u8(v), u8(v >> 8))
}

bw_write_u32 :: proc(w: ^Byte_Writer, v: u32) {
	append(&w.data, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

bw_write_u64 :: proc(w: ^Byte_Writer, v: u64) {
	append(
		&w.data,
		u8(v),
		u8(v >> 8),
		u8(v >> 16),
		u8(v >> 24),
		u8(v >> 32),
		u8(v >> 40),
		u8(v >> 48),
		u8(v >> 56),
	)
}

bw_write_i64 :: proc(w: ^Byte_Writer, v: i64) {
	bw_write_u64(w, u64(v))
}

bw_write_f64 :: proc(w: ^Byte_Writer, v: f64) {
	bw_write_u64(w, u64(transmute(u64)v))
}

bw_write_len_bytes :: proc(w: ^Byte_Writer, v: []u8) {
	bw_write_u32(w, u32(len(v)))
	bw_write_raw(w, v)
}

bw_write_string :: proc(w: ^Byte_Writer, v: string) {
	bw_write_len_bytes(w, transmute([]u8)v)
}

// Byte_Reader reads what Byte_Writer wrote. A short read sets `bad`; every
// getter returns zero after that and callers check once at the end.
Byte_Reader :: struct {
	data: []u8,
	pos:  int,
	bad:  bool,
}

br_init :: proc(r: ^Byte_Reader, data: []u8) {
	r.data = data
	r.pos = 0
	r.bad = false
}

br_remaining :: proc(r: ^Byte_Reader) -> int {
	return len(r.data) - r.pos
}

br_read_raw :: proc(r: ^Byte_Reader, n: int) -> []u8 {
	if r.bad || n < 0 || r.pos + n > len(r.data) {
		r.bad = true
		return nil
	}
	out := r.data[r.pos:r.pos + n]
	r.pos += n
	return out
}

br_read_u8 :: proc(r: ^Byte_Reader) -> u8 {
	raw := br_read_raw(r, 1)
	if raw == nil do return 0
	return raw[0]
}

br_read_u16 :: proc(r: ^Byte_Reader) -> u16 {
	raw := br_read_raw(r, 2)
	if raw == nil do return 0
	return u16(raw[0]) | u16(raw[1]) << 8
}

br_read_u32 :: proc(r: ^Byte_Reader) -> u32 {
	raw := br_read_raw(r, 4)
	if raw == nil do return 0
	return u32(raw[0]) |
		u32(raw[1]) << 8 |
		u32(raw[2]) << 16 |
		u32(raw[3]) << 24
}

br_read_u64 :: proc(r: ^Byte_Reader) -> u64 {
	raw := br_read_raw(r, 8)
	if raw == nil do return 0
	return u64(raw[0]) |
		u64(raw[1]) << 8 |
		u64(raw[2]) << 16 |
		u64(raw[3]) << 24 |
		u64(raw[4]) << 32 |
		u64(raw[5]) << 40 |
		u64(raw[6]) << 48 |
		u64(raw[7]) << 56
}

br_read_i64 :: proc(r: ^Byte_Reader) -> i64 {
	return i64(br_read_u64(r))
}

br_read_f64 :: proc(r: ^Byte_Reader) -> f64 {
	return transmute(f64)br_read_u64(r)
}

br_read_len_bytes :: proc(r: ^Byte_Reader, alloc: mem.Allocator) -> []u8 {
	n := br_read_u32(r)
	if r.bad do return nil
	if u64(n) > u64(br_remaining(r)) {
		r.bad = true
		return nil
	}
	raw := br_read_raw(r, int(n))
	out := make([]u8, len(raw), alloc)
	copy(out, raw)
	return out
}

br_read_string :: proc(r: ^Byte_Reader, alloc: mem.Allocator) -> string {
	raw := br_read_len_bytes(r, alloc)
	return string(raw)
}

// --- Value encoding: self-describing, used by the commit log ----------------

value_encode :: proc(w: ^Byte_Writer, v: Value) {
	bw_write_u8(w, u8(v.kind))
	switch v.kind {
	case .Null, .Default:
	case .Bool:
		bw_write_u8(w, v.b ? 1 : 0)
	case .Int, .Timestamp:
		bw_write_i64(w, v.i)
	case .Uint:
		bw_write_u64(w, v.u)
	case .Int128, .Uint128:
		bw_write_u64(w, u64(value_big(v)))
		bw_write_u64(w, u64(value_big(v) >> 64))
	case .Duration:
		bw_write_i64(w, v.i)
	case .Connection:
		bw_write_u64(w, v.u)
	case .Identity:
		id := value_identity_of(v)
		bw_write_raw(w, id[:])
	case .Float:
		bw_write_f64(w, v.f)
	case .String:
		bw_write_string(w, v.s)
	case .Bytes:
		bw_write_len_bytes(w, v.bytes)
	case .Uuid:
		u := v.uuid
		bw_write_raw(w, u[:])
	case .Array, .Product:
		bw_write_u32(w, u32(len(v.list)))
		for item in v.list {
			value_encode(w, item)
		}
	}
}

value_decode :: proc(r: ^Byte_Reader, alloc: mem.Allocator) -> Value {
	kind := Value_Kind(br_read_u8(r))
	if r.bad do return {}
	switch kind {
	case .Null:
		return value_null()
	case .Default:
		return value_default()
	case .Bool:
		return value_bool(br_read_u8(r) != 0)
	case .Int:
		return value_int(br_read_i64(r))
	case .Timestamp:
		return value_timestamp(Timestamp(br_read_i64(r)))
	case .Uint:
		return value_uint(br_read_u64(r))
	case .Int128:
		lo := br_read_u64(r)
		hi := br_read_u64(r)
		return value_int128(i128(u128(hi) << 64 | u128(lo)))
	case .Uint128:
		lo := br_read_u64(r)
		hi := br_read_u64(r)
		return value_uint128(u128(hi) << 64 | u128(lo))
	case .Duration:
		return value_duration(Duration(br_read_i64(r)))
	case .Connection:
		return value_connection(br_read_u64(r))
	case .Identity:
		raw := br_read_raw(r, 32)
		if r.bad do return {}
		id: Identity
		copy(id[:], raw)
		return value_identity(id)
	case .Float:
		return value_float(br_read_f64(r))
	case .String:
		return value_string(br_read_string(r, alloc))
	case .Bytes:
		return value_bytes(br_read_len_bytes(r, alloc))
	case .Uuid:
		raw := br_read_raw(r, 16)
		if r.bad do return {}
		u: Uuid
		copy(u[:], raw)
		return value_uuid(u)
	case .Array, .Product:
		n := int(br_read_u32(r))
		if r.bad || n < 0 || n > br_remaining(r) {
			r.bad = true
			return {}
		}
		items := make([]Value, n, alloc)
		for i in 0 ..< n {
			items[i] = value_decode(r, alloc)
			if r.bad do return {}
		}
		if kind == .Array do return value_array(items)
		return value_product(items)
	}
	// Unknown kind means a newer format wrote it.
	r.bad = true
	return {}
}

// --- Key encoding: order preserving, used by indexes ------------------------

// value_encode_key writes an order-preserving representation: byte-wise order
// of the output equals value order, so indexes may compare raw bytes.
value_encode_key :: proc(w: ^Byte_Writer, v: Value) {
	switch v.kind {
	case .Null, .Default:
		bw_write_u8(w, 0x00)
	case .Bool:
		bw_write_u8(w, 0x01)
		bw_write_u8(w, v.b ? 1 : 0)
	case .Int:
		bw_write_u8(w, 0x02)
		write_be_u64(w, u64(v.i) ~ (u64(1) << 63))
	case .Uint:
		bw_write_u8(w, 0x03)
		write_be_u64(w, v.u)
	case .Int128:
		bw_write_u8(w, 0x0b)
		write_be_u128(w, value_big(v) ~ (u128(1) << 127))
	case .Uint128:
		bw_write_u8(w, 0x0c)
		write_be_u128(w, value_big(v))
	case .Duration:
		bw_write_u8(w, 0x0d)
		write_be_u64(w, u64(v.i) ~ (u64(1) << 63))
	case .Identity:
		bw_write_u8(w, 0x0e)
		id := value_identity_of(v)
		bw_write_raw(w, id[:])
	case .Connection:
		bw_write_u8(w, 0x0f)
		write_be_u64(w, v.u)
	case .Float:
		bw_write_u8(w, 0x04)
		bits := u64(transmute(u64)v.f)
		if bits & (u64(1) << 63) != 0 {
			bits = ~bits
		} else {
			bits |= (u64(1) << 63)
		}
		write_be_u64(w, bits)
	case .Timestamp:
		bw_write_u8(w, 0x05)
		write_be_u64(w, u64(v.i) ~ (u64(1) << 63))
	case .Uuid:
		bw_write_u8(w, 0x06)
		u := v.uuid
		bw_write_raw(w, u[:])
	case .String:
		bw_write_u8(w, 0x07)
		write_key_blob(w, transmute([]u8)v.s)
	case .Bytes:
		bw_write_u8(w, 0x08)
		write_key_blob(w, v.bytes)
	case .Array, .Product:
		bw_write_u8(w, v.kind == .Array ? 0x09 : 0x0a)
		bw_write_u32(w, u32(len(v.list)))
		for item in v.list {
			value_encode_key(w, item)
		}
	}
}

// write_key_blob escapes NUL bytes and terminates with 0x00 0x00, so a
// concatenation of blobs is unambiguous and still sorts lexicographically.
@(private)
write_key_blob :: proc(w: ^Byte_Writer, blob: []u8) {
	for c in blob {
		if c == 0x00 {
			append(&w.data, 0x00, 0xff)
		} else {
			append(&w.data, c)
		}
	}
	append(&w.data, 0x00, 0x00)
}

@(private)
write_be_u128 :: proc(w: ^Byte_Writer, v: u128) {
	for shift := 120; shift >= 0; shift -= 8 {
		append(&w.data, u8(v >> u128(shift)))
	}
}

@(private)
write_be_u64 :: proc(w: ^Byte_Writer, v: u64) {
	append(
		&w.data,
		u8(v >> 56),
		u8(v >> 48),
		u8(v >> 40),
		u8(v >> 32),
		u8(v >> 24),
		u8(v >> 16),
		u8(v >> 8),
		u8(v),
	)
}

// value_key_bytes returns the encoded key of a single value.
value_key_bytes :: proc(v: Value) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	value_encode_key(&w, v)
	return bw_bytes(&w)
}

// --- CRC32C ----------------------------------------------------------------

@(private)
crc32c_table: [256]u32

@(private)
crc32c_ready: bool

@(private)
crc32c_init :: proc() {
	if crc32c_ready do return
	// Castagnoli polynomial, reflected form.
	poly: u32 = 0x82f63b78
	for i in 0 ..< 256 {
		crc := u32(i)
		for _ in 0 ..< 8 {
			if crc & 1 != 0 {
				crc = (crc >> 1) ~ poly
			} else {
				crc >>= 1
			}
		}
		crc32c_table[i] = crc
	}
	crc32c_ready = true
}

// crc32c is the Castagnoli CRC, the checksum used by every on-disk record.
crc32c :: proc(data: []u8) -> u32 {
	crc32c_init()
	crc := u32(0xffffffff)
	for c in data {
		crc = crc32c_table[byte(crc) ~ c] ~ (crc >> 8)
	}
	return ~crc
}

// --- Small helpers ---------------------------------------------------------

bytes_concat_owned :: proc(parts: []string) -> string {
	total := 0
	for part in parts do total += len(part)
	out := make([]u8, total)
	pos := 0
	for part in parts {
		copy(out[pos:], transmute([]u8)part)
		pos += len(part)
	}
	return string(out)
}

// slice_copy_bytes copies into a fresh allocation.
slice_copy_bytes :: proc(src: []u8, alloc: mem.Allocator) -> []u8 {
	return slice.clone(src, alloc)
}
