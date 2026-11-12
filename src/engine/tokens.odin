package engine

import "core:crypto"
import "core:crypto/hmac"
import "core:strings"

// Tokens are opaque session credentials. A token is 32 bytes from the OS
// CSPRNG, presented as `mt_` followed by its hex form. Only the
// HMAC-SHA256(token, server key) is stored in `_token`, so a leaked database
// file does not leak live credentials. The key lives in `_meta` and is created
// on first use. This is still a session token, not a JWT: there are no claims
// beyond identity and expiry.

TOKEN_TABLE :: "_token"
TOKEN_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _token (
		token TEXT PRIMARY KEY,
		identity IDENTITY NOT NULL,
		expires_us INTEGER NOT NULL DEFAULT 0
	)`

@(private)
tokens_ensure_table :: proc(host: ^Host) -> Error {
	if _, exists := host.store.tables[TOKEN_TABLE]; exists do return ERROR_NONE
	result, create_err := sql_execute(host.store, TOKEN_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	return ERROR_NONE
}

@(private)
token_hex :: proc(bytes: []u8) -> string {
	digits := "0123456789abcdef"
	out := make([]u8, len(bytes) * 2)
	for byte, i in bytes {
		out[i * 2] = digits[byte >> 4]
		out[i * 2 + 1] = digits[byte & 0x0f]
	}
	return string(out)
}

@(private)
token_unhex :: proc(text: string) -> ([]u8, bool) {
	if len(text) % 2 != 0 do return nil, false
	out := make([]u8, len(text) / 2)
	for i in 0 ..< len(out) {
		high, high_ok := hex_digit(text[i * 2])
		low, low_ok := hex_digit(text[i * 2 + 1])
		if !high_ok || !low_ok do return nil, false
		out[i] = high << 4 | low
	}
	return out, true
}

@(private)
hex_digit :: proc(c: u8) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

@(private)
host_token_key :: proc(host: ^Host) -> []u8 {
	if len(host.token_key) == 32 do return host.token_key
	if stored, found := host_meta(host, "token_key"); found {
		if key, ok := token_unhex(stored); ok && len(key) == 32 {
			host.token_key = key
			return key
		}
	}
	key := make([]u8, 32)
	crypto.rand_bytes(key)
	encoded := token_hex(key)
	_, _ = sql_execute_params(
		host.store,
		"INSERT INTO _meta (key, value) VALUES ('token_key', ?)",
		[]Value{value_string(encoded)},
	)
	host.token_key = key
	return key
}

// token_digest is the stored form of a credential.
@(private)
token_digest :: proc(host: ^Host, token: string) -> string {
	dst := make([]u8, 32, context.temp_allocator)
	message := transmute([]u8)token
	hmac.sum(.SHA256, dst, message, host_token_key(host))
	return token_hex(dst)
}

// host_issue_token creates a token for `identity`. `ttl_us` of zero means it
// never expires; otherwise it expires that many microseconds from now.
host_issue_token :: proc(host: ^Host, identity: Identity, ttl_us: i64) -> (string, Error) {
	if err := tokens_ensure_table(host); err.kind != .None do return "", err
	secret := make([]u8, 32)
	crypto.rand_bytes(secret)
	token := strings.concatenate({"mt_", token_hex(secret)})
	digest := token_digest(host, token)
	expires := i64(0)
	if ttl_us != 0 do expires = host_now(host) + ttl_us
	_, insert_err := sql_execute_params(
		host.store,
		"INSERT INTO _token (token, identity, expires_us) VALUES (?, ?, ?)",
		[]Value{value_string(digest), value_identity(identity), value_int(expires)},
	)
	if insert_err.kind != .None do return "", insert_err
	return token, ERROR_NONE
}

// host_authenticate resolves a token to its identity. An expired token is
// treated as unknown.
host_authenticate :: proc(host: ^Host, token: string) -> (Identity, bool) {
	if len(token) == 0 do return Identity{}, false
	// A JWT header is the base64url of `{"alg":...}`, always starting with eyJ.
	if strings.has_prefix(token, "eyJ") {
		if identity, valid := jwt_identity(host, token); valid do return identity, true
		return Identity{}, false
	}
	if err := tokens_ensure_table(host); err.kind != .None do return Identity{}, false
	digest := token_digest(host, token)
	result, query_err := sql_execute_params(
		host.store,
		"SELECT identity, expires_us FROM _token WHERE token = ?",
		[]Value{value_string(digest)},
	)
	if query_err.kind != .None do return Identity{}, false
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return Identity{}, false
	row := result.rows[0]
	expires := row[1].i
	if expires != 0 && expires < host_now(host) do return Identity{}, false
	if row[0].kind != .Identity do return Identity{}, false
	return value_identity_of(row[0]), true
}

// host_revoke_token drops one token. It reports whether a row was removed.
host_revoke_token :: proc(host: ^Host, token: string) -> bool {
	if err := tokens_ensure_table(host); err.kind != .None do return false
	digest := token_digest(host, token)
	result, delete_err := sql_execute_params(
		host.store,
		"DELETE FROM _token WHERE token = ?",
		[]Value{value_string(digest)},
	)
	if delete_err.kind != .None do return false
	removed := result.affected > 0
	sql_result_destroy(&result)
	return removed
}
