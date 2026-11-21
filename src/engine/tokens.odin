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
token_hex :: proc(bytes: []u8, alloc := context.allocator) -> string {
	digits := "0123456789abcdef"
	out := make([]u8, len(bytes) * 2, alloc)
	for byte, i in bytes {
		out[i * 2] = digits[byte >> 4]
		out[i * 2 + 1] = digits[byte & 0x0f]
	}
	return string(out)
}

@(private)
token_unhex :: proc(text: string, alloc := context.allocator) -> ([]u8, bool) {
	if len(text) % 2 != 0 do return nil, false
	out := make([]u8, len(text) / 2, alloc)
	for i in 0 ..< len(out) {
		high, high_ok := hex_digit(text[i * 2])
		low, low_ok := hex_digit(text[i * 2 + 1])
		if !high_ok || !low_ok {
			delete(out, alloc)
			return nil, false
		}
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

// store_token_key returns the HMAC key of `store`, creating it on first use. It
// is the key of the database, not of a Host, so a connection that never built a
// host (the C ABI) authenticates with the same key the server would use.
store_token_key :: proc(store: ^Store) -> []u8 {
	if len(store.token_key) == 32 do return store.token_key
	// The key is a row in _meta, and a database opened by an embedder has no host
	// to create that table: without this the insert below would fail and every
	// connection would invent a key of its own, which no other connection could
	// check a token against.
	if _, exists := store.tables[META_TABLE]; !exists {
		result, create_err := sql_execute(store, META_SCHEMA_SQL)
		if create_err.kind != .None {
			error_free(&create_err)
			return nil
		}
		sql_result_destroy(&result)
	}
	if stored, found := store_meta(store, "token_key"); found {
		if key, ok := token_unhex(stored); ok {
			if len(key) == 32 {
				store.token_key = key
				return key
			}
			delete(key)
		}
	}
	key := make([]u8, 32)
	crypto.rand_bytes(key)
	encoded := token_hex(key, context.temp_allocator)
	saved, save_err := sql_execute_params(
		store,
		"INSERT INTO _meta (key, value) VALUES ('token_key', ?)",
		[]Value{value_string(encoded)},
	)
	sql_result_destroy(&saved)
	error_free(&save_err)
	store.token_key = key
	return key
}

// store_token_digest is the stored form of a credential.
@(private)
// The digest is a query parameter: it lives in the temporary allocator.
store_token_digest :: proc(store: ^Store, token: string) -> string {
	dst := make([]u8, 32, context.temp_allocator)
	message := transmute([]u8)token
	hmac.sum(.SHA256, dst, message, store_token_key(store))
	return token_hex(dst, context.temp_allocator)
}

@(private)
host_token_key :: proc(host: ^Host) -> []u8 {
	return store_token_key(host.store)
}

@(private)
token_digest :: proc(host: ^Host, token: string) -> string {
	return store_token_digest(host.store, token)
}

// host_issue_token creates a token for `identity`. `ttl_us` of zero means it
// never expires; otherwise it expires that many microseconds from now.
host_issue_token :: proc(host: ^Host, identity: Identity, ttl_us: i64) -> (string, Error) {
	return store_issue_token(host.store, identity, ttl_us, host_now(host))
}

// store_issue_token is host_issue_token for a store with no host, with the clock
// passed in so a caller can also issue an already-expired token on purpose.
store_issue_token :: proc(store: ^Store, identity: Identity, ttl_us, now_us: i64) -> (string, Error) {
	result, create_err := sql_execute(store, TOKEN_SCHEMA_SQL)
	if create_err.kind != .None do return "", create_err
	sql_result_destroy(&result)
	secret := make([]u8, 32, context.temp_allocator)
	crypto.rand_bytes(secret)
	token := strings.concatenate({"mt_", token_hex(secret, context.temp_allocator)})
	digest := store_token_digest(store, token)
	expires := i64(0)
	if ttl_us != 0 do expires = now_us + ttl_us
	inserted, insert_err := sql_execute_params(
		store,
		"INSERT INTO _token (token, identity, expires_us) VALUES (?, ?, ?)",
		[]Value{value_string(digest), value_identity(identity), value_int(expires)},
	)
	sql_result_destroy(&inserted)
	if insert_err.kind != .None {
		delete(token)
		return "", insert_err
	}
	return token, ERROR_NONE
}

// host_authenticate resolves a token to its identity. An expired token is
// treated as unknown.
host_authenticate :: proc(host: ^Host, token: string) -> (Identity, bool) {
	return store_authenticate(host.store, token, host_now(host))
}

// store_authenticate resolves a token against a database. An embedded connection
// (the C ABI) has no reducer catalog to build a Host for, so the lookup is written
// against the store and the host wrapper passes its own clock.
store_authenticate :: proc(store: ^Store, token: string, now_us: i64) -> (Identity, bool) {
	if len(token) == 0 do return Identity{}, false
	// A JWT header is the base64url of `{"alg":...}`, always starting with eyJ.
	if strings.has_prefix(token, "eyJ") {
		if identity, valid := jwt_identity_store(store, token, now_us); valid {
			return identity, true
		}
		return Identity{}, false
	}
	if _, exists := store.tables[TOKEN_TABLE]; !exists do return Identity{}, false
	digest := store_token_digest(store, token)
	result, query_err := sql_execute_params(
		store,
		"SELECT identity, expires_us FROM _token WHERE token = ?",
		[]Value{value_string(digest)},
	)
	if query_err.kind != .None {
		error_free(&query_err)
		return Identity{}, false
	}
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return Identity{}, false
	row := result.rows[0]
	expires := row[1].i
	if expires != 0 && expires < now_us do return Identity{}, false
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
	if delete_err.kind != .None {
		error_free(&delete_err)
		return false
	}
	removed := result.affected > 0
	sql_result_destroy(&result)
	return removed
}
