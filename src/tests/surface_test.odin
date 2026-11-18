package tests

import "core:testing"

import db "../engine"

@(test)
test_update_or_resolutions :: proc(t: ^testing.T) {
	// UPDATE OR <resolution> (S2) acts like INSERT's: FAIL keeps the rows
	// updated before the failing one, ABORT keeps none, IGNORE skips the row,
	// REPLACE removes what it collides with, and ROLLBACK cannot end a
	// transaction the caller opened.
	store := fresh_db(t, "update_or")
	if store == nil do return
	defer cleanup_db(store, "update_or")
	run(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, u INTEGER UNIQUE)")
	run(t, store, "INSERT INTO t (id, u) VALUES (1, 1), (2, 2), (3, 3)")
	MOVES :: "SET u = CASE id WHEN 1 THEN 100 WHEN 2 THEN 3 END WHERE id <= 2"

	_ = run_error(t, store, "UPDATE OR ABORT t " + MOVES)
	testing.expect_value(t, scalar(t, store, "SELECT u FROM t WHERE id = 1").i, i64(1))
	_ = run_error(t, store, "UPDATE OR FAIL t " + MOVES)
	testing.expect_value(t, scalar(t, store, "SELECT u FROM t WHERE id = 1").i, i64(100))
	testing.expect_value(t, scalar(t, store, "SELECT u FROM t WHERE id = 2").i, i64(2))

	run(t, store, "UPDATE OR IGNORE t SET u = 3 WHERE id = 2")
	testing.expect_value(t, scalar(t, store, "SELECT u FROM t WHERE id = 2").i, i64(2))
	run(t, store, "UPDATE OR REPLACE t SET u = 3 WHERE id = 2")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT u FROM t WHERE id = 2").i, i64(3))

	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "BEGIN")))
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "UPDATE OR ROLLBACK t SET u = 100 WHERE id = 2")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "ROLLBACK")))
}
