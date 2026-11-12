package engine

import "core:crypto"
import "core:crypto/hmac"
import "core:fmt"
import "core:strings"

// HS256 JWTs signed with the server token key. A JWT is
// `header.payload.signature`, base64url without padding. Validation checks the
// signature, the `sub` claim (identity in hex) and `exp` when present. There is
// no revocation list: a JWT is valid until it expires.

JWT_HEADER :: `{"alg":"HS256","typ":"JWT"}`

@(private)
B64URL_ALPHABET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

@(private)
b64url_encode :: proc(data: []u8) -> string {
	alphabet := B64URL_ALPHABET
	out := make([dynamic]u8, 0, (len(data) + 2) / 3 * 4)
	i := 0
	for i + 2 < len(data) {
		n := int(data[i]) << 16 | int(data[i + 1]) << 8 | int(data[i + 2])
		append(&out, alphabet[(n >> 18) & 63])
		append(&out, alphabet[(n >> 12) & 63])
		append(&out, alphabet[(n >> 6) & 63])
		append(&out, alphabet[n & 63])
		i += 3
	}
	remaining := len(data) - i
	if remaining == 1 {
		n := int(data[i]) << 16
		append(&out, alphabet[(n >> 18) & 63])
		append(&out, alphabet[(n >> 12) & 63])
	} else if remaining == 2 {
		n := int(data[i]) << 16 | int(data[i + 1]) << 8
		append(&out, alphabet[(n >> 18) & 63])
		append(&out, alphabet[(n >> 12) & 63])
		append(&out, alphabet[(n >> 6) & 63])
	}
	return string(out[:])
}

@(private)
b64url_value :: proc(c: u8) -> (u8, bool) {
	switch {
	case c >= 'A' && c <= 'Z':
		return c - 'A', true
	case c >= 'a' && c <= 'z':
		return c - 'a' + 26, true
	case c >= '0' && c <= '9':
		return c - '0' + 52, true
	case c == '-':
		return 62, true
	case c == '_':
		return 63, true
	}
	return 0, false
}

@(private)
b64url_decode :: proc(text: string) -> ([]u8, bool) {
	if len(text) % 4 == 1 do return nil, false
	out := make([dynamic]u8, 0, len(text) * 3 / 4 + 1)
	accumulator: u32
	bits: int
	for c in text {
		value, ok := b64url_value(u8(c))
		if !ok do return nil, false
		accumulator = accumulator << 6 | u32(value)
		bits += 6
		if bits >= 8 {
			bits -= 8
			append(&out, u8(accumulator >> u32(bits)))
		}
	}
	return out[:], true
}

@(private)
jwt_string_claim :: proc(claims: string, name: string) -> string {
	needle := strings.concatenate({`"`, name, `"`})
	defer delete(needle)
	at := strings.index(claims, needle)
	if at < 0 do return ""
	pos := at + len(needle)
	for pos < len(claims) && (claims[pos] == ' ' || claims[pos] == ':') do pos += 1
	if pos >= len(claims) || claims[pos] != '"' do return ""
	pos += 1
	start := pos
	for pos < len(claims) && claims[pos] != '"' do pos += 1
	if pos >= len(claims) do return ""
	return claims[start:pos]
}

@(private)
jwt_number_claim :: proc(claims: string, name: string) -> (i64, bool) {
	needle := strings.concatenate({`"`, name, `"`})
	defer delete(needle)
	at := strings.index(claims, needle)
	if at < 0 do return 0, false
	pos := at + len(needle)
	for pos < len(claims) && (claims[pos] == ' ' || claims[pos] == ':') do pos += 1
	value := i64(0)
	digits := 0
	for pos < len(claims) && claims[pos] >= '0' && claims[pos] <= '9' {
		value = value * 10 + i64(claims[pos] - '0')
		pos += 1
		digits += 1
	}
	return value, digits > 0
}

@(private)
identity_from_hex :: proc(text: string) -> (Identity, bool) {
	if len(text) != 64 do return Identity{}, false
	bytes, ok := token_unhex(text)
	if !ok || len(bytes) != 32 do return Identity{}, false
	identity: Identity
	copy(identity[:], bytes)
	return identity, true
}

// jwt_identity validates a HS256 JWT and returns its subject.
@(private)
jwt_identity :: proc(host: ^Host, token: string) -> (Identity, bool) {
	first := strings.index(token, ".")
	if first < 0 do return Identity{}, false
	after_first := token[first + 1:]
	second_offset := strings.index(after_first, ".")
	if second_offset < 0 do return Identity{}, false
	second := first + 1 + second_offset
	signature := token[second + 1:]
	if strings.index(signature, ".") >= 0 do return Identity{}, false

	signing_input := token[:second]
	expected := make([]u8, 32, context.temp_allocator)
	hmac.sum(.SHA256, expected, transmute([]u8)signing_input, host_token_key(host))
	expected_text := b64url_encode(expected)
	if crypto.compare_constant_time(transmute([]u8)expected_text, transmute([]u8)signature) != 1 {
		return Identity{}, false
	}

	payload, decoded := b64url_decode(token[first + 1:second])
	if !decoded do return Identity{}, false
	claims := string(payload)
	subject := jwt_string_claim(claims, "sub")
	if len(subject) == 0 do return Identity{}, false
	if expiry, has_expiry := jwt_number_claim(claims, "exp"); has_expiry {
		if expiry < host_now(host) / 1_000_000 do return Identity{}, false
	}
	return identity_from_hex(subject)
}

// host_issue_jwt signs a JWT for `identity`. `ttl_us` of zero means no `exp`.
host_issue_jwt :: proc(host: ^Host, identity: Identity, ttl_us: i64) -> string {
	header := JWT_HEADER
	header_text := b64url_encode(transmute([]u8)header)
	expiry := ""
	if ttl_us != 0 {
		expiry = fmt.aprintf(`,"exp":%d`, (host_now(host) + ttl_us) / 1_000_000)
	}
	subject := identity
	payload := strings.concatenate({`{"sub":"`, token_hex(subject[:]), `"`, expiry, `}`})
	defer delete(payload)
	payload_text := b64url_encode(transmute([]u8)payload)
	signing_input := strings.concatenate({header_text, ".", payload_text})
	signature := make([]u8, 32, context.temp_allocator)
	hmac.sum(.SHA256, signature, transmute([]u8)signing_input, host_token_key(host))
	return strings.concatenate({signing_input, ".", b64url_encode(signature)})
}
