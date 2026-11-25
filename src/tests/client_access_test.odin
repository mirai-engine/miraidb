package tests

import "core:fmt"
import "core:strings"
import "core:testing"

import db "../engine"

// A store without host access serves clients it does not trust (the server's
// default). Grants decide what such a client may do only if it cannot reach what
// decides them: it read `_meta`, whose key signs every token and JWT, and could
// write itself into `_role` and `_grant` or name its identity with SET identity.

@(private = "file")
access_identity :: proc(seed: u8) -> (db.Identity, string) {
	identity: db.Identity
	for i in 0 ..< len(identity) do identity[i] = seed
	text := db.identity_text(identity)
	defer delete(text)
	return identity, strings.clone(text, context.temp_allocator)
}

@(test)
test_a_client_cannot_reach_the_credentials :: proc(t: ^testing.T) {
	store, open_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)
	host := db.host_init(store)
	defer db.host_destroy(host)
	ana, ana_text := access_identity(0xa1)
	token, issue_err := db.host_issue_token(host, ana, 0)
	defer delete(token)
	if !testing.expectf(t, db.error_ok(issue_err), "issue: %s", issue_err.message) do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, fmt.tprintf("GRANT writer TO '%s'", ana_text))
	run_done(t, store, "GRANT insert ON t TO writer")
	run_done(t, store, "CREATE VIEW key_view AS SELECT value FROM _meta")
	run_done(t, store, "CREATE TABLE audit (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TRIGGER escalate AFTER INSERT ON audit BEGIN INSERT INTO _role VALUES ('writer', '*'); END")

	db.store_set_host_access(store, false)
	db.store_set_identity(store, ana)
	before := store.commit_seq
	refusals := []string {
		"SELECT value FROM _meta",
		"SELECT * FROM _token",
		"SELECT count(*) FROM t JOIN _meta ON 1",
		"SELECT (SELECT value FROM _meta LIMIT 1)",
		"SELECT * FROM key_view",
		"INSERT INTO _role VALUES ('writer', '*')",
		"INSERT INTO _token VALUES ('x', x'00', 0)",
		"DELETE FROM _grant",
		"UPDATE _grant SET role = 'everyone'",
		"DROP TABLE _grant",
		"ALTER TABLE _grant ADD COLUMN note TEXT",
		"DROP TABLE _meta",
		"GRANT writer TO '*'",
		"REVOKE insert ON t FROM writer",
		"CREATE POLICY mine ON t USING (1)",
		"DROP POLICY IF EXISTS mine",
		"CREATE VIEW _policy AS SELECT 1",
		fmt.tprintf("SET identity = '%s'", strings.repeat("0", 64, context.temp_allocator)),
		"INSERT INTO audit VALUES (1)",
	}
	for sql in refusals {
		err := run_error(t, store, sql)
		testing.expectf(t, err.kind == .Permission_Denied, "%s answered %v: %s", sql, err.kind, err.message)
	}
	testing.expect_value(t, store.commit_seq, before)
	testing.expect_value(t, db.store_identity(store), ana)

	// What the engine reads for itself still works: a token is checked, and the
	// grants decide the client's writes.
	resolved, valid := db.host_authenticate(host, token)
	testing.expect(t, valid)
	testing.expect_value(t, resolved, ana)
	run_done(t, store, "INSERT INTO t (v) VALUES ('ana writes')")
	db.store_set_identity(store, {})
	anonymous := run_error(t, store, "INSERT INTO t (v) VALUES ('nobody')")
	testing.expect_value(t, anonymous.kind, db.Error_Kind.Permission_Denied)
	// Its own tables, and dropping them, stay the client's.
	db.store_set_identity(store, ana)
	run_done(t, store, "CREATE TABLE scratch (id INTEGER)")
	run_done(t, store, "DROP TABLE scratch")

	// The host trusts itself again: the same statements are its to run.
	db.store_set_host_access(store, true)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _meta WHERE key = 'token_key'").i, i64(1))
	run_done(t, store, fmt.tprintf("SET identity = '%s'", strings.repeat("0", 64, context.temp_allocator)))
}
