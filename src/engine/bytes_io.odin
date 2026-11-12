package engine

import "core:mem"

// Byte_Source and Byte_Sink are the cursors modules use for byte oriented I/O:
// framed payloads, imported blobs, or data handed back to a host. They mirror
// the encoding primitives but keep their own position, so a consumer can stream
// a buffer without slicing it.

Byte_Source :: struct {
	data:     []u8,
	position: int,
}

Byte_Sink :: struct {
	data: [dynamic]u8,
}

bytes_source :: proc(data: []u8) -> Byte_Source {
	return Byte_Source{data = data}
}

bytes_source_remaining :: proc(source: ^Byte_Source) -> int {
	remaining := len(source.data) - source.position
	return remaining < 0 ? 0 : remaining
}

// bytes_source_read copies at most len(out) bytes and reports how many were
// available.
bytes_source_read :: proc(source: ^Byte_Source, out: []u8) -> int {
	available := bytes_source_remaining(source)
	if available <= 0 do return 0
	count := len(out)
	if count > available do count = available
	copy(out[:count], source.data[source.position:source.position + count])
	source.position += count
	return count
}

bytes_source_read_all :: proc(source: ^Byte_Source, alloc: mem.Allocator) -> []u8 {
	available := bytes_source_remaining(source)
	out := make([]u8, available, alloc)
	copy(out, source.data[source.position:])
	source.position += available
	return out
}

bytes_source_read_u32 :: proc(source: ^Byte_Source) -> (u32, bool) {
	if bytes_source_remaining(source) < 4 do return 0, false
	value := u32(source.data[source.position]) |
		u32(source.data[source.position + 1]) << 8 |
		u32(source.data[source.position + 2]) << 16 |
		u32(source.data[source.position + 3]) << 24
	source.position += 4
	return value, true
}

bytes_source_read_u64 :: proc(source: ^Byte_Source) -> (u64, bool) {
	low, low_ok := bytes_source_read_u32(source)
	if !low_ok do return 0, false
	high, high_ok := bytes_source_read_u32(source)
	if !high_ok do return 0, false
	return u64(low) | u64(high) << 32, true
}

bytes_source_read_string :: proc(source: ^Byte_Source, alloc: mem.Allocator) -> (string, bool) {
	length, length_ok := bytes_source_read_u32(source)
	if !length_ok do return "", false
	count := int(length)
	if count > bytes_source_remaining(source) do return "", false
	out := make([]u8, count, alloc)
	copy(out, source.data[source.position:source.position + count])
	source.position += count
	return string(out), true
}

bytes_sink_write :: proc(sink: ^Byte_Sink, data: []u8) {
	append(&sink.data, ..data)
}

bytes_sink_write_u32 :: proc(sink: ^Byte_Sink, value: u32) {
	append(
		&sink.data,
		u8(value),
		u8(value >> 8),
		u8(value >> 16),
		u8(value >> 24),
	)
}

bytes_sink_write_u64 :: proc(sink: ^Byte_Sink, value: u64) {
	bytes_sink_write_u32(sink, u32(value))
	bytes_sink_write_u32(sink, u32(value >> 32))
}

bytes_sink_write_string :: proc(sink: ^Byte_Sink, text: string) {
	bytes_sink_write_u32(sink, u32(len(text)))
	bytes_sink_write(sink, transmute([]u8)text)
}

bytes_sink_bytes :: proc(sink: ^Byte_Sink) -> []u8 {
	return sink.data[:]
}

bytes_sink_reset :: proc(sink: ^Byte_Sink) {
	clear(&sink.data)
}

bytes_sink_destroy :: proc(sink: ^Byte_Sink) {
	delete(sink.data)
	sink.data = nil
}
