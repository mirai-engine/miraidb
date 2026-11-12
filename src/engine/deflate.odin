package engine

import "core:bytes"
import "core:compress/zlib"
import "core:mem"

// Deflate encoder (RFC 1951, fixed Huffman blocks with LZ77 matches) wrapped in
// a zlib stream (RFC 1950). The decoder is the standard library's inflate, so
// the encoder is validated against a reference implementation instead of
// against itself.

@(private)
Deflate_Writer :: struct {
	out:       [dynamic]u8,
	bits:      u32,
	bit_count: int,
}

@(private)
deflate_bits :: proc(w: ^Deflate_Writer, value: u32, count: int) {
	if count <= 0 do return
	w.bits |= (value & ((1 << u32(count)) - 1)) << u32(w.bit_count)
	w.bit_count += count
	for w.bit_count >= 8 {
		append(&w.out, u8(w.bits))
		w.bits >>= 8
		w.bit_count -= 8
	}
}

@(private)
deflate_flush :: proc(w: ^Deflate_Writer) {
	if w.bit_count > 0 {
		append(&w.out, u8(w.bits))
		w.bits = 0
		w.bit_count = 0
	}
}

@(private)
deflate_bit_reverse :: proc(value: u32, count: int) -> u32 {
	out: u32
	for i in 0 ..< count do out = out << 1 | (value >> u32(i) & 1)
	return out
}

// Huffman codes are packed most significant bit first, while the stream is
// little endian, so the code is reversed before writing.
@(private)
deflate_code :: proc(w: ^Deflate_Writer, code: u32, count: int) {
	deflate_bits(w, deflate_bit_reverse(code, count), count)
}

@(private)
deflate_literal :: proc(w: ^Deflate_Writer, byte: u8) {
	if byte <= 143 {
		deflate_code(w, 0x30 + u32(byte), 8)
	} else {
		deflate_code(w, 0x190 + u32(byte) - 144, 9)
	}
}

LENGTH_BASE := [29]int{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
LENGTH_EXTRA := [29]int{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
DIST_BASE := [30]int{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
DIST_EXTRA := [30]int{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

@(private)
deflate_length_code :: proc(w: ^Deflate_Writer, length: int) {
	index := 28
	for i in 0 ..< 29 {
		extra := LENGTH_EXTRA[i]
		max_length := i == 28 ? 258 : LENGTH_BASE[i] + (1 << u32(extra)) - 1
		if length >= LENGTH_BASE[i] && length <= max_length {
			index = i
			break
		}
	}
	code := 257 + index
	if code <= 279 {
		deflate_code(w, u32(code - 256), 7)
	} else {
		deflate_code(w, u32(0xC0 + code - 280), 8)
	}
	if extra := LENGTH_EXTRA[index]; extra > 0 {
		deflate_bits(w, u32(length - LENGTH_BASE[index]), extra)
	}
}

@(private)
deflate_distance_code :: proc(w: ^Deflate_Writer, distance: int) {
	index := 29
	for i in 0 ..< 30 {
		extra := DIST_EXTRA[i]
		max_distance := i == 29 ? 32768 : DIST_BASE[i] + (1 << u32(extra)) - 1
		if distance >= DIST_BASE[i] && distance <= max_distance {
			index = i
			break
		}
	}
	deflate_code(w, u32(index), 5)
	if extra := DIST_EXTRA[index]; extra > 0 {
		deflate_bits(w, u32(distance - DIST_BASE[index]), extra)
	}
}

@(private)
DEFLATE_MAX_MATCH :: 258
@(private)
DEFLATE_MIN_MATCH :: 3
@(private)
DEFLATE_WINDOW :: 32768
@(private)
DEFLATE_HASH_BITS :: 15
@(private)
DEFLATE_HASH_SIZE :: 1 << DEFLATE_HASH_BITS
@(private)
DEFLATE_MAX_CHAIN :: 32

@(private)
deflate_hash :: proc(data: []u8, position: int) -> int {
	value :=
		u32(data[position]) | u32(data[position + 1]) << 8 | u32(data[position + 2]) << 16
	return int((value * 2654435761) >> (32 - DEFLATE_HASH_BITS))
}

@(private)
deflate_match_length :: proc(data: []u8, position, candidate: int) -> int {
	limit := len(data) - position
	if limit > DEFLATE_MAX_MATCH do limit = DEFLATE_MAX_MATCH
	length := 0
	for length < limit && data[candidate + length] == data[position + length] do length += 1
	return length
}

@(private)
deflate_lz77 :: proc(w: ^Deflate_Writer, data: []u8) {
	head := make([]i32, DEFLATE_HASH_SIZE)
	defer delete(head)
	for &slot in head do slot = -1
	previous := make([]i32, DEFLATE_WINDOW)
	defer delete(previous)
	for &slot in previous do slot = -1

	position := 0
	for position < len(data) {
		best_length := 0
		best_distance := 0
		if position + DEFLATE_MIN_MATCH <= len(data) {
			hash := deflate_hash(data, position)
			candidate := head[hash]
			chain := 0
			for candidate >= 0 && chain < DEFLATE_MAX_CHAIN {
				distance := position - int(candidate)
				if distance <= 0 || distance > DEFLATE_WINDOW do break
				length := deflate_match_length(data, position, int(candidate))
				if length > best_length {
					best_length = length
					best_distance = distance
					if length >= DEFLATE_MAX_MATCH do break
				}
				candidate = previous[int(candidate) & (DEFLATE_WINDOW - 1)]
				chain += 1
			}
			previous[position & (DEFLATE_WINDOW - 1)] = head[hash]
			head[hash] = i32(position)
		}
		if best_length >= DEFLATE_MIN_MATCH {
			deflate_length_code(w, best_length)
			deflate_distance_code(w, best_distance)
			// Register the positions the match covers so later matches can find them.
			for step in 1 ..< best_length {
				at := position + step
				if at + DEFLATE_MIN_MATCH <= len(data) {
					hash := deflate_hash(data, at)
					previous[at & (DEFLATE_WINDOW - 1)] = head[hash]
					head[hash] = i32(at)
				}
			}
			position += best_length
		} else {
			deflate_literal(w, data[position])
			position += 1
		}
	}
}

@(private)
adler32 :: proc(data: []u8) -> u32 {
	low := u32(1)
	high := u32(0)
	for byte in data {
		low = (low + u32(byte)) % 65521
		high = (high + low) % 65521
	}
	return high << 16 | low
}

// zlib_compress returns a zlib stream with one fixed-Huffman deflate block.
zlib_compress :: proc(data: []u8, alloc: mem.Allocator) -> []u8 {
	w := Deflate_Writer{}
	w.out = make([dynamic]u8, 0, len(data) / 2 + 16, alloc)
	append(&w.out, 0x78, 0x01)
	deflate_bits(&w, 1, 1) // BFINAL
	deflate_bits(&w, 1, 2) // BTYPE: fixed Huffman
	deflate_lz77(&w, data)
	deflate_code(&w, 0, 7) // end of block (code 256)
	deflate_flush(&w)
	checksum := adler32(data)
	append(&w.out, u8(checksum >> 24), u8(checksum >> 16), u8(checksum >> 8), u8(checksum))
	return w.out[:]
}

// zlib_decompress inflates a zlib stream with the standard library decoder.
zlib_decompress :: proc(data: []u8, alloc: mem.Allocator) -> ([]u8, bool) {
	buffer: bytes.Buffer
	if err := zlib.inflate_from_byte_array(data, &buffer); err != nil do return nil, false
	out := make([]u8, len(buffer.buf), alloc)
	copy(out, buffer.buf[:])
	delete(buffer.buf)
	return out, true
}
