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

@(test)
test_constraint_on_conflict :: proc(t: ^testing.T) {
	// A constraint's ON CONFLICT (S1) decides what a row that breaks it does
	// when the statement names no resolution, and it survives a reopen.
	store := fresh_db(t, "on_conflict")
	if store == nil do return
	run(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, u INTEGER UNIQUE ON CONFLICT FAIL, n TEXT NOT NULL ON CONFLICT IGNORE, r INTEGER, UNIQUE (r) ON CONFLICT ROLLBACK)")
	run(t, store, "INSERT INTO c VALUES (1, 1, 'a', 1)")
	db.store_close(store)
	reopened, open_err := db.store_open("_test_on_conflict", {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	defer cleanup_db(reopened, "on_conflict")

	// FAIL keeps the rows before the failing one.
	_ = run_error(t, reopened, "INSERT INTO c VALUES (2, 2, 'b', 2), (3, 1, 'c', 3)")
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM c").i, i64(2))
	// IGNORE skips a row that leaves n NULL.
	run(t, reopened, "INSERT INTO c VALUES (4, 4, NULL, 4)")
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM c").i, i64(2))
	// An explicit OR wins over the declared one.
	_ = run_error(t, reopened, "INSERT OR ABORT INTO c VALUES (5, 5, NULL, 5)")

	// ROLLBACK ends the transaction the statement broke in.
	conn := db.embed_wrap(reopened)
	defer db.embed_close(conn)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "BEGIN")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO c VALUES (6, 6, 'f', 6)")))
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "INSERT INTO c VALUES (7, 7, 'g', 1)")))
	testing.expect(t, !db.embed_in_transaction(conn))
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM c").i, i64(2))
}

@(test)
test_natural_joins :: proc(t: ^testing.T) {
	// NATURAL JOIN (S3) is USING over the names both sides share: `*` lists a
	// shared column once, LEFT keeps the unmatched rows, and two tables with
	// nothing in common give their cross product.
	store := fresh_db(t, "natural")
	if store == nil do return
	defer cleanup_db(store, "natural")
	run(t, store, "CREATE TABLE a (id INTEGER, k TEXT, x INTEGER)")
	run(t, store, "CREATE TABLE b (id INTEGER, k TEXT, y INTEGER)")
	run(t, store, "CREATE TABLE c (z INTEGER)")
	run(t, store, "INSERT INTO a VALUES (1, 'p', 10), (2, 'q', 20), (3, 'r', 30)")
	run(t, store, "INSERT INTO b VALUES (1, 'p', 100), (2, 'x', 200)")
	run(t, store, "INSERT INTO c VALUES (7), (8)")
	star := run(t, store, "SELECT * FROM a NATURAL JOIN b")
	testing.expect_value(t, len(star.columns), 4)
	testing.expect_value(t, len(star.rows), 1)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM a NATURAL LEFT JOIN b").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM a NATURAL JOIN c").i, i64(6))
}

@(test)
test_memory_attach_and_vacuum :: proc(t: ^testing.T) {
	// ATTACH ':memory:' adds an empty database in memory and DETACH closes it;
	// VACUUM of a database in memory does nothing, as in SQLite (S6).
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "ATTACH ':memory:' AS aux")))
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "ATTACH ':memory:' AS aux")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "DETACH aux")))
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "DETACH aux")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "VACUUM")))
}

@(test)
test_generate_series :: proc(t: ^testing.T) {
	// generate_series (S6), SQLite's series extension: STOP defaults to
	// 4294967295 and STEP to 1, a negative STEP reverses the values, START is
	// required, the arguments are HIDDEN columns, and the row id is the value.
	store := fresh_db(t, "series")
	if store == nil do return
	defer cleanup_db(store, "series")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(value, ',') FROM generate_series(1, 10, 3)").s, "1,4,7,10")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(value, ',') FROM generate_series(1, 10, -3)").s, "10,7,4,1")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM generate_series WHERE start = 2 AND stop = 4").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT sum(g.value) FROM (SELECT 3 AS n) AS t, generate_series(1, t.n) AS g").i, i64(6))
	testing.expect_value(t, len(run(t, store, "SELECT * FROM generate_series(1, 2)").columns), 1)
	_ = run_error(t, store, "SELECT count(*) FROM generate_series")
}

@(test)
test_instead_of_triggers :: proc(t: ^testing.T) {
	// INSTEAD OF triggers (S6) make a view writable: the statement on the view
	// writes nothing and counts no change, its trigger's body does the write,
	// and a view without one, a BEFORE trigger on a view and an INSTEAD OF
	// trigger on a table are refused. The triggers go with the view.
	store := fresh_db(t, "instead")
	if store == nil do return
	defer cleanup_db(store, "instead")
	for sql in ([]string {
		"CREATE TABLE t (a INTEGER, b TEXT)",
		"CREATE VIEW v AS SELECT a, b FROM t",
		"CREATE TRIGGER vi INSTEAD OF INSERT ON v BEGIN INSERT INTO t VALUES (NEW.a, NEW.b); END",
		"CREATE TRIGGER vu INSTEAD OF UPDATE ON v BEGIN UPDATE t SET b = NEW.b WHERE a = OLD.a; END",
		"CREATE TRIGGER vd INSTEAD OF DELETE ON v BEGIN DELETE FROM t WHERE a = OLD.a; END",
	}) {
		result := run(t, store, sql)
		db.sql_result_destroy(&result)
	}
	inserted := run(t, store, "INSERT INTO v VALUES (1, 'a'), (2, 'b'), (3, 'c')")
	testing.expect_value(t, inserted.affected, 0)
	db.sql_result_destroy(&inserted)
	updated := run(t, store, "UPDATE v SET b = 'z' WHERE a >= 2")
	db.sql_result_destroy(&updated)
	deleted := run(t, store, "DELETE FROM v WHERE a = 3")
	db.sql_result_destroy(&deleted)
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(a || b, ',') FROM (SELECT a, b FROM t ORDER BY a)").s, "1a,2z")
	returned := run(t, store, "INSERT INTO v (b, a) VALUES ('q', 9) RETURNING a")
	testing.expect(t, len(returned.rows) == 1 && returned.rows[0][0].i == 9)
	db.sql_result_destroy(&returned)
	for sql in ([]string {
		"CREATE VIEW w AS SELECT 1 AS z",
		"CREATE TRIGGER wi INSTEAD OF INSERT ON w BEGIN SELECT 1; END",
	}) {
		result := run(t, store, sql)
		db.sql_result_destroy(&result)
	}
	_ = run_error(t, store, "DELETE FROM w")
	_ = run_error(t, store, "CREATE TRIGGER vb BEFORE INSERT ON v BEGIN SELECT 1; END")
	_ = run_error(t, store, "CREATE TRIGGER ti INSTEAD OF INSERT ON t BEGIN SELECT 1; END")
	dropped := run(t, store, "DROP VIEW v")
	db.sql_result_destroy(&dropped)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _triggers WHERE table_name = 'v'").i, i64(0))
}
