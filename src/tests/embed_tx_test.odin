package tests

import "core:testing"

import db "../engine"

// embed_count runs a count through the connection, so it reads what the
// connection's open transaction sees.
@(private = "file")
embed_count :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) -> i64 {
	stmt := db.embed_prepare(conn, sql)
	if !testing.expectf(t, stmt != nil, "prepare %s: %s", sql, db.embed_error(conn)) do return -1
	defer db.embed_finalize(stmt)
	has_row, err := db.embed_step(stmt)
	defer db.error_free(&err)
	if !testing.expectf(t, db.error_ok(err) && has_row, "step %s: %s", sql, err.message) do return -1
	return db.embed_column_int(stmt, 0)
}

@(private = "file")
embed_ok :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
}

@(private = "file")
embed_refused :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, message: string) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, err.message == message, "%s answered %q, want %q", sql, err.message, message)
}

@(test)
test_embed_transactions :: proc(t: ^testing.T) {
	// The classic embedded API keeps one transaction per connection: BEGIN opens
	// it, every statement of the connection runs inside it, and COMMIT or
	// ROLLBACK ends it. A program that writes `BEGIN; ...; COMMIT` depends on it,
	// and the embedding layer used to refuse BEGIN outright.
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	embed_ok(t, conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	testing.expect(t, !db.embed_in_transaction(conn))

	// ROLLBACK undoes what the transaction wrote, and the connection is back in
	// autocommit.
	embed_ok(t, conn, "BEGIN")
	testing.expect(t, db.embed_in_transaction(conn))
	embed_ok(t, conn, "INSERT INTO t (v) VALUES (1)")
	testing.expect_value(t, embed_count(t, conn, "SELECT count(*) FROM t"), i64(1))
	embed_ok(t, conn, "ROLLBACK")
	testing.expect(t, !db.embed_in_transaction(conn))
	testing.expect_value(t, embed_count(t, conn, "SELECT count(*) FROM t"), i64(0))

	// COMMIT keeps it; END and BEGIN's lock modes are SQLite's other spellings.
	embed_ok(t, conn, "BEGIN IMMEDIATE TRANSACTION")
	embed_ok(t, conn, "INSERT INTO t (v) VALUES (2)")
	embed_ok(t, conn, "END")
	testing.expect_value(t, embed_count(t, conn, "SELECT count(*) FROM t"), i64(1))

	// The errors are SQLite's, word for word.
	embed_refused(t, conn, "COMMIT", "cannot commit - no transaction is active")
	embed_refused(t, conn, "ROLLBACK", "cannot rollback - no transaction is active")
	embed_ok(t, conn, "BEGIN")
	embed_refused(t, conn, "BEGIN", "cannot start a transaction within a transaction")

	// A statement that fails inside the transaction is undone alone: the
	// transaction stays open and keeps what came before.
	embed_ok(t, conn, "INSERT INTO t (id, v) VALUES (10, 3)")
	duplicate := db.embed_exec(conn, "INSERT INTO t (id, v) VALUES (10, 4)")
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Primary_Key)
	db.error_free(&duplicate)
	testing.expect(t, db.embed_in_transaction(conn))
	embed_ok(t, conn, "COMMIT")
	testing.expect_value(t, embed_count(t, conn, "SELECT count(*) FROM t"), i64(2))

	// An outermost SAVEPOINT opens a transaction and releasing it commits;
	// ROLLBACK TO undoes what came after the savepoint and keeps it open.
	embed_ok(t, conn, "SAVEPOINT outer")
	testing.expect(t, db.embed_in_transaction(conn))
	embed_ok(t, conn, "INSERT INTO t (v) VALUES (5)")
	embed_ok(t, conn, "SAVEPOINT inner")
	embed_ok(t, conn, "INSERT INTO t (v) VALUES (6)")
	embed_ok(t, conn, "ROLLBACK TO inner")
	testing.expect_value(t, embed_count(t, conn, "SELECT count(*) FROM t"), i64(3))
	embed_ok(t, conn, "RELEASE outer")
	testing.expect(t, !db.embed_in_transaction(conn))
	testing.expect_value(t, embed_count(t, conn, "SELECT count(*) FROM t"), i64(3))
	embed_refused(t, conn, "RELEASE nowhere", "no such savepoint: nowhere")

	// A prepared statement steps inside the open transaction too.
	embed_ok(t, conn, "BEGIN")
	insert := db.embed_prepare(conn, "INSERT INTO t (v) VALUES (?)")
	if testing.expect(t, insert != nil) {
		testing.expect(t, db.error_drop(db.embed_bind_int(insert, 0, 7)))
		_, step_err := db.embed_step(insert)
		testing.expect(t, db.error_drop(step_err))
		db.embed_finalize(insert)
	}
	embed_ok(t, conn, "ROLLBACK")
	testing.expect_value(t, embed_count(t, conn, "SELECT count(*) FROM t"), i64(3))

	// Closing with a transaction open rolls it back instead of leaving the
	// store's write lock held.
	embed_ok(t, conn, "BEGIN")
	embed_ok(t, conn, "INSERT INTO t (v) VALUES (8)")
}
