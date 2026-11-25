package tests

import "core:strings"
import "core:testing"

import db "../engine"

// A UNIQUE index over one column files its integer keys in a hash beside the
// tree, and a transaction stages them in a map of its own (R2). Both have to
// call two values one key exactly when SQLite's UNIQUE does.

@(private = "file")
ik_open :: proc(t: ^testing.T) -> ^db.Embed_Conn {
	conn, err := db.embed_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	return conn
}

@(private = "file")
ik_ok :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, loc := #caller_location) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message, loc = loc)
}

@(private = "file")
ik_taken :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, loc := #caller_location) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, strings.contains(err.message, "UNIQUE constraint failed"), "%s: got %v %q, want a UNIQUE failure", sql, err.kind, err.message, loc = loc)
}

@(private = "file")
ik_count :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, want: i64, loc := #caller_location) {
	testing.expectf(t, scalar(t, conn.store, sql).i == want, "%s: want %d", sql, want, loc = loc)
}

@(test)
test_integer_keys_collide_as_sqlite :: proc(t: ^testing.T) {
	conn := ik_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	ik_ok(t, conn, "CREATE TABLE f (x UNIQUE)")
	ik_ok(t, conn, "INSERT INTO f VALUES (5)")
	ik_taken(t, conn, "INSERT INTO f VALUES (5.0)")
	ik_ok(t, conn, "INSERT INTO f VALUES (5.5)")
	ik_ok(t, conn, "INSERT INTO f VALUES ('5')")
	ik_ok(t, conn, "INSERT INTO f VALUES (0)")
	ik_taken(t, conn, "INSERT INTO f VALUES (-0.0)")
	// 2^53 + 1 is no real; 2^53 is both.
	ik_ok(t, conn, "INSERT INTO f VALUES (9007199254740993)")
	ik_ok(t, conn, "INSERT INTO f VALUES (9007199254740992.0)")
	ik_taken(t, conn, "INSERT INTO f VALUES (9007199254740992)")
	// The same within one transaction, against the staged keys.
	ik_ok(t, conn, "BEGIN")
	ik_ok(t, conn, "INSERT INTO f VALUES (6.0)")
	ik_taken(t, conn, "INSERT INTO f VALUES (6)")
	ik_ok(t, conn, "INSERT INTO f VALUES (7)")
	ik_taken(t, conn, "INSERT INTO f VALUES (7.0)")
	ik_ok(t, conn, "COMMIT")
	ik_count(t, conn, "SELECT count(*) FROM f WHERE x = 5.0", 1)
	ik_count(t, conn, "SELECT count(*) FROM f WHERE x = 6", 1)
	ik_count(t, conn, "SELECT count(*) FROM f", 8)
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA integrity_check").s, "ok")
}

@(test)
test_unsigned_keys_follow_every_write :: proc(t: ^testing.T) {
	conn := ik_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	ik_ok(t, conn, "CREATE TABLE u (id UINT4 NOT NULL, n INTEGER)")
	ik_ok(t, conn, "CREATE UNIQUE INDEX u_id ON u (id)")
	ik_ok(t, conn, "INSERT INTO u VALUES (7, 0)")
	ik_taken(t, conn, "INSERT INTO u VALUES (7, 1)")
	// An update moves the key; a delete gives it up.
	ik_ok(t, conn, "UPDATE u SET id = 8 WHERE id = 7")
	ik_ok(t, conn, "INSERT INTO u VALUES (7, 2)")
	ik_taken(t, conn, "INSERT INTO u VALUES (8, 3)")
	ik_ok(t, conn, "DELETE FROM u WHERE id = 7")
	ik_ok(t, conn, "INSERT INTO u VALUES (7, 4)")
	// A statement that fails takes back the keys it staged.
	ik_ok(t, conn, "BEGIN")
	ik_taken(t, conn, "INSERT INTO u VALUES (30, 0), (8, 0)")
	ik_ok(t, conn, "INSERT INTO u VALUES (30, 5)")
	ik_taken(t, conn, "INSERT INTO u VALUES (30, 6)")
	ik_ok(t, conn, "COMMIT")
	ik_count(t, conn, "SELECT n FROM u WHERE id = 30", 5)

	table := conn.store.tables["u"]
	index := -1
	for idx, i in table.indexes do if idx.schema.name == "u_id" do index = i
	if testing.expect(t, index >= 0) {
		testing.expect(t, table.indexes[index].int_keyed)
		testing.expect_value(t, len(table.indexes[index].ints), 3)
	}

	// A commit while a reader is open writes a copy of the table: its keys
	// come along.
	reader := db.tx_begin_read(conn.store)
	ik_ok(t, conn, "INSERT INTO u VALUES (40, 0)")
	ik_taken(t, conn, "INSERT INTO u VALUES (40, 1)")
	ik_taken(t, conn, "INSERT INTO u VALUES (8, 1)")
	db.tx_end(reader)
	ik_ok(t, conn, "INSERT INTO u VALUES (41, 0)")
	ik_taken(t, conn, "INSERT INTO u VALUES (40, 2)")

	// Emptied, the table holds no key.
	ik_ok(t, conn, "DELETE FROM u")
	ik_ok(t, conn, "INSERT INTO u VALUES (8, 0)")
	ik_ok(t, conn, "INSERT INTO u VALUES (40, 0)")
	ik_count(t, conn, "SELECT count(*) FROM u", 2)
	ik_count(t, conn, "SELECT n FROM u WHERE id = 8", 0)
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA integrity_check").s, "ok")
}
