package engine

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

// Minimal RFC 6455 support: the handshake and binary frames carrying the same
// wire messages as the HTTP endpoints. Text frames are accepted too. Pings are
// ignored; close frames end the loop in the server binary.

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

@(private)
ws_rotl :: proc(value: u32, count: u32) -> u32 {
	return (value << count) | (value >> (32 - count))
}

@(private)
ws_put_be32 :: proc(out: []u8, value: u32) {
	out[0] = u8(value >> 24)
	out[1] = u8(value >> 16)
	out[2] = u8(value >> 8)
	out[3] = u8(value)
}

@(private)
ws_get_be32 :: proc(data: []u8) -> u32 {
	return u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
}

// sha1 is implemented here because the core library ships SHA-3 and Blake2 but
// no SHA-1, and the WebSocket handshake requires exactly SHA-1.
ws_sha1 :: proc(data: []u8) -> [20]u8 {
	h: [5]u32 = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0}
	padded_len := ((len(data) + 9 + 63) / 64) * 64
	padded := make([]u8, padded_len)
	defer delete(padded)
	copy(padded, data)
	padded[len(data)] = 0x80
	bit_len := u64(len(data)) * 8
	for i in 0 ..< 8 {
		padded[padded_len - 1 - i] = u8(bit_len >> (8 * u64(i)))
	}
	for offset := 0; offset < padded_len; offset += 64 {
		w: [80]u32
		for i in 0 ..< 16 {
			w[i] = ws_get_be32(padded[offset + i * 4:])
		}
		for i in 16 ..< 80 {
			w[i] = ws_rotl(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1)
		}
		a, b, c, d, e := h[0], h[1], h[2], h[3], h[4]
		for i in 0 ..< 80 {
			f, k: u32
			switch {
			case i < 20:
				f = (b & c) | ((~b) & d)
				k = 0x5A827999
			case i < 40:
				f = b ~ c ~ d
				k = 0x6ED9EBA1
			case i < 60:
				f = (b & c) | (b & d) | (c & d)
				k = 0x8F1BBCDC
			case:
				f = b ~ c ~ d
				k = 0xCA62C1D6
			}
			temp := ws_rotl(a, 5) + f + e + k + w[i]
			e = d
			d = c
			c = ws_rotl(b, 30)
			b = a
			a = temp
		}
		h[0] += a
		h[1] += b
		h[2] += c
		h[3] += d
		h[4] += e
	}
	out: [20]u8
	for i in 0 ..< 5 do ws_put_be32(out[i * 4:], h[i])
	return out
}

// ws_accept_key computes base64(SHA-1(key + GUID)), the value the client checks.
ws_accept_key :: proc(key: string) -> string {
	combined := strings.concatenate({key, WS_GUID})
	defer delete(combined)
	bytes := make([]u8, len(combined))
	defer delete(bytes)
	copy(bytes, combined)
	digest := ws_sha1(bytes)
	encoded, _ := base64.encode(digest[:])
	return encoded
}

ws_is_upgrade :: proc(request: []u8) -> bool {
	text := strings.to_lower(string(request))
	defer delete(text)
	return strings.index(text, "upgrade: websocket") >= 0
}

@(private)
ws_header :: proc(request: []u8, name: string) -> (string, bool) {
	text := string(request)
	lower := strings.to_lower(text)
	defer delete(lower)
	position := strings.index(lower, name)
	if position < 0 do return "", false
	start := position + len(name)
	end := start
	for end < len(text) && text[end] != '\r' && text[end] != '\n' do end += 1
	return strings.trim_space(text[start:end]), true
}

// ws_handshake answers a valid upgrade request with 101 and the accept key.
ws_handshake :: proc(request: []u8) -> ([]u8, bool) {
	key, found := ws_header(request, "sec-websocket-key:")
	if !found do return nil, false
	accept := ws_accept_key(key)
	defer delete(accept)
	response := fmt.aprintf(
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		accept,
	)
	defer delete(response)
	out := make([]u8, len(response))
	copy(out, response)
	return out, true
}

// ws_frame wraps a payload in one unmasked binary frame.
ws_frame :: proc(payload: []u8) -> []u8 {
	out := make([dynamic]u8, 0, len(payload) + 10)
	append(&out, 0x82) // FIN + binary
	length := len(payload)
	switch {
	case length <= 125:
		append(&out, u8(length))
	case length <= 65535:
		append(&out, 126, u8(length >> 8), u8(length))
	case:
		append(&out, 127)
		for i := 7; i >= 0; i -= 1 {
			append(&out, u8(u64(length) >> (8 * u64(i))))
		}
	}
	append(&out, ..payload)
	result := make([]u8, len(out))
	copy(result, out[:])
	delete(out)
	return result
}

// ws_read_frame parses one client frame (masked, as the RFC requires) and
// returns its payload, the bytes consumed and the opcode.
WS_DEFAULT_MAX_FRAME :: 1 << 20

ws_read_frame :: proc(
	data: []u8,
) -> (payload: []u8, consumed: int, opcode: u8, err: Error) {
	return ws_read_frame_within(data, WS_DEFAULT_MAX_FRAME)
}

// ws_read_frame_within refuses a frame whose declared length is over the limit
// (zero disables it). The length is checked before the payload is allocated, so
// a forged 64-bit length cannot ask for gigabytes or wrap negative.
ws_read_frame_within :: proc(
	data: []u8,
	max_bytes: int,
) -> (payload: []u8, consumed: int, opcode: u8, err: Error) {
	if len(data) < 2 do return nil, 0, 0, errf(.Invalid_Argument, "short WebSocket frame")
	opcode = data[0] & 0x0f
	masked := data[1] & 0x80 != 0
	length := int(data[1] & 0x7f)
	offset := 2
	switch length {
	case 126:
		if len(data) < 4 do return nil, 0, opcode, errf(.Invalid_Argument, "short frame length")
		length = int(data[2]) << 8 | int(data[3])
		offset = 4
	case 127:
		if len(data) < 10 do return nil, 0, opcode, errf(.Invalid_Argument, "short frame length")
		length = 0
		for i in 0 ..< 8 do length = length << 8 | int(data[2 + i])
		offset = 10
	}
	mask: [4]u8
	if masked {
		if len(data) < offset + 4 do return nil, 0, opcode, errf(.Invalid_Argument, "short frame mask")
		copy(mask[:], data[offset:offset + 4])
		offset += 4
	}
	if length < 0 || (max_bytes > 0 && length > max_bytes) {
		return nil, 0, opcode, errf(
			.Quota_Exceeded,
			"WebSocket frame is %d bytes, more than the %d byte limit",
			length,
			max_bytes,
		)
	}
	if len(data) < offset + length do return nil, 0, opcode, errf(.Invalid_Argument, "incomplete frame")
	payload = make([]u8, length)
	copy(payload, data[offset:offset + length])
	if masked {
		for i in 0 ..< length do payload[i] ~= mask[i % 4]
	}
	return payload, offset + length, opcode, ERROR_NONE
}
