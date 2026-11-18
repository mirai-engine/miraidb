package tests

import "core:strings"
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

@(test)
test_aggregate_filter_and_order :: proc(t: ^testing.T) {
	// An aggregate's FILTER (WHERE ...) and ORDER BY (S4): the group keeps the
	// rows the filter holds for, in the order the ORDER BY gives, for the
	// built-in aggregates, a window's frame and DISTINCT alike; a scalar
	// function refuses both, as in SQLite.
	store := fresh_db(t, "aggregate_filter")
	if store == nil do return
	defer cleanup_db(store, "aggregate_filter")
	result := run(t, store, "CREATE TABLE t (g INTEGER, x TEXT, y INTEGER)")
	db.sql_result_destroy(&result)
	result = run(t, store, "INSERT INTO t VALUES (1, 'b', 2), (1, 'a', 3), (2, 'c', 1), (2, NULL, 5), (1, 'd', NULL)")
	db.sql_result_destroy(&result)
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(x ORDER BY y DESC) FROM t WHERE g = 1").s, "a,b,d")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(x, '-' ORDER BY x) FILTER (WHERE y > 1) FROM t").s, "a-b")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FILTER (WHERE y > 1) FROM t").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT json_group_array(x ORDER BY y) FROM t").s, `["d","c","b","a",null]`)
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT x ORDER BY x) FILTER (WHERE g = 1) FROM t").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT max(c) FROM (SELECT count(*) FILTER (WHERE y > 1) OVER (ORDER BY y) AS c FROM t)").i, i64(3))
	// `filter` stays a name a column or an alias may have.
	testing.expect_value(t, scalar(t, store, "SELECT filter FROM (SELECT count(*) AS filter FROM t)").i, i64(5))
	_ = run_error(t, store, "SELECT abs(y) FILTER (WHERE 1) FROM t")
	_ = run_error(t, store, "SELECT abs(y ORDER BY x) FROM t")
	_ = run_error(t, store, "SELECT row_number() FILTER (WHERE y > 1) OVER (ORDER BY y) FROM t")
}

@(test)
test_window_clause :: proc(t: ^testing.T) {
	// The WINDOW clause (S4): `OVER name` takes a definition whole, `OVER (name
	// ...)` adds an ORDER BY or a frame to it, a definition may build on an
	// earlier one, and SQLite's four refusals hold.
	store := fresh_db(t, "window_clause")
	if store == nil do return
	defer cleanup_db(store, "window_clause")
	result := run(t, store, "CREATE TABLE t (g INTEGER, x TEXT, y INTEGER)")
	db.sql_result_destroy(&result)
	result = run(t, store, "INSERT INTO t VALUES (1, 'b', 2), (1, 'a', 3), (2, 'c', 1), (2, 'e', 5), (1, 'd', 4)")
	db.sql_result_destroy(&result)
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(s, ',') FROM (SELECT sum(y) OVER w AS s FROM t WINDOW w AS (PARTITION BY g ORDER BY y) ORDER BY x)").s, "5,2,1,9,6")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(s, ',') FROM (SELECT sum(y) OVER (w ORDER BY x) AS s FROM t WINDOW w AS (PARTITION BY g) ORDER BY x)").s, "3,5,1,9,6")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(s, ',') FROM (SELECT sum(y) OVER (w ROWS 1 PRECEDING) AS s FROM t WINDOW w AS (ORDER BY y) ORDER BY y)").s, "1,3,5,7,9")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(s, ',') FROM (SELECT sum(y) OVER v AS s FROM t WINDOW w AS (PARTITION BY g), v AS (w ORDER BY y) ORDER BY x)").s, "5,2,1,9,6")
	_ = run_error(t, store, "SELECT sum(y) OVER nope FROM t")
	_ = run_error(t, store, "SELECT sum(y) OVER (w PARTITION BY x) FROM t WINDOW w AS (PARTITION BY g)")
	_ = run_error(t, store, "SELECT sum(y) OVER (w ORDER BY x) FROM t WINDOW w AS (ORDER BY y)")
	_ = run_error(t, store, "SELECT sum(y) OVER (w) FROM t WINDOW w AS (ROWS 1 PRECEDING)")
}

@(test)
test_jsonb_and_array_insert :: proc(t: ^testing.T) {
	// JSONB (S5): jsonb() writes SQLite's binary form with the smallest header
	// for each size, every JSON function reads it back, the jsonb_* forms
	// answer it, and a number keeps the text it was written with.
	// json_array_insert answers what SQLite's own json109.test expects.
	store := fresh_db(t, "jsonb")
	if store == nil do return
	defer cleanup_db(store, "jsonb")
	testing.expect_value(t, scalar(t, store, `SELECT hex(jsonb('[1.50, 1e2, "b", null, true, false, {"k":-3}]'))`).s, "CB1445312E35303531653217620001025C176B232D33")
	testing.expect_value(t, scalar(t, store, `SELECT hex(jsonb('"abcdefghijklmnop"'))`).s, "C7106162636465666768696A6B6C6D6E6F70")
	testing.expect_value(t, scalar(t, store, `SELECT hex(jsonb_array(1, 2.5, 'x', 'a"b', NULL))`).s, "CB0E133135322E35177848615C226200")
	testing.expect_value(t, scalar(t, store, `SELECT json(jsonb('{"a":[1,2,{"b":null}],"c":"d"}'))`).s, `{"a":[1,2,{"b":null}],"c":"d"}`)
	testing.expect_value(t, scalar(t, store, `SELECT json('[1.50, 1e2, -0, 12345678901234567890]')`).s, "[1.50,1e2,-0,12345678901234567890]")
	testing.expect_value(t, scalar(t, store, `SELECT jsonb_extract(jsonb('{"a":[1,2],"b":3}'), '$.b')`).i, i64(3))
	testing.expect_value(t, scalar(t, store, `SELECT typeof(jsonb_extract(jsonb('{"a":[1,2]}'), '$.a'))`).s, "blob")
	testing.expect_value(t, scalar(t, store, `SELECT json_extract(jsonb_set(jsonb('{"a":1}'), '$.b', 2), '$.b')`).i, i64(2))
	testing.expect_value(t, scalar(t, store, `SELECT json(jsonb_group_array(n)) FROM (SELECT 1 AS n UNION ALL SELECT 2)`).s, "[1,2]")
	testing.expect_value(t, scalar(t, store, `SELECT sum(value) FROM json_each(jsonb('[10,20]'))`).i, i64(30))
	testing.expect_value(t, scalar(t, store, `SELECT json_extract('[1,2,3]', '$[#-1]')`).i, i64(3))
	_ = run_error(t, store, "SELECT json(x'ff')")

	cases := [][2]string {
		{`SELECT json_array_insert('[1,2,3]','$[0]',999,'$[0]',888)`, "[888,999,1,2,3]"},
		{`SELECT json_array_insert('[1,2,3]','$[0]',999,'$[#]',888)`, "[999,1,2,3,888]"},
		{`SELECT json_array_insert('[1,2,3]','$[1]',888)`, "[1,888,2,3]"},
		{`SELECT json_array_insert('[1,2,3]','$[3]',888)`, "[1,2,3,888]"},
		{`SELECT json_array_insert('[1,2,3]','$[#-1]',888)`, "[1,2,888,3]"},
		{`SELECT json_array_insert('[1,2,3]','$[#-3]',888)`, "[888,1,2,3]"},
		{`SELECT json_array_insert('[1,2,3]','$[#-4]',888)`, "[1,2,3]"},
		{`SELECT json_array_insert('{"a":[1,2,3]}','$.b[0]',888)`, `{"a":[1,2,3],"b":[888]}`},
		{`SELECT json_array_insert('{"a":[1,2,3]}','$.b.c.d[0]',888)`, `{"a":[1,2,3],"b":{"c":{"d":[888]}}}`},
		{`SELECT json_array_insert('{"a":[1,2,3]}','$[0]',888)`, `{"a":[1,2,3]}`},
		{`SELECT json(jsonb_array_insert('[1]','$[0]',0))`, "[0,1]"},
	}
	for c in cases do testing.expectf(t, scalar(t, store, c[0]).s == c[1], "%s", c[0])
	for sql in ([]string {
		`SELECT json_array_insert('{"a":[1,2,3]}','$.a',888)`,
		`SELECT json_array_insert('{"a":[1,2,3]}','$.b.c.d[0',888)`,
		`SELECT json_array_insert('{"a":[1,2,3]}','$.b[0]',888,'$.a[1]','999','$.c',0)`,
	}) {
		err := run_error(t, store, sql)
		testing.expectf(t, strings.contains(err.message, "not an array element"), "%s: %s", sql, err.message)
	}
}
