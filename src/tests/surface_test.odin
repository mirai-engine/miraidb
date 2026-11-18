package tests

import "core:os"
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
test_window_filter_over_groups :: proc(t: ^testing.T) {
	// FILTER on a window over grouped rows reads each group's values; the
	// answers are SQLite's.
	store := fresh_db(t, "window_filter_groups")
	if store == nil do return
	defer cleanup_db(store, "window_filter_groups")
	run(t, store, "CREATE TABLE w (g INTEGER, n INTEGER)")
	run(t, store, "INSERT INTO w VALUES (1, 10), (1, 5), (2, 7), (3, 1), (3, 2), (3, 3)")
	answer :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> string {
		return scalar(t, store, strings.concatenate({"SELECT group_concat(coalesce(x, 'null'), ',') FROM (", sql, ")"}, context.temp_allocator)).s
	}
	testing.expect_value(t, answer(t, store, "SELECT sum(sum(n)) FILTER (WHERE g > 1) OVER (ORDER BY g) AS x FROM w GROUP BY g ORDER BY g"), "null,7,13")
	testing.expect_value(t, answer(t, store, "SELECT count(*) FILTER (WHERE count(*) > 1) OVER () AS x FROM w GROUP BY g ORDER BY g"), "2,2,2")
	testing.expect_value(t, answer(t, store, "SELECT max(sum(n)) FILTER (WHERE sum(n) < 15) OVER (ORDER BY g ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS x FROM w GROUP BY g ORDER BY g"), "null,7,7")
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

@(test)
test_sqlite_schema_catalog :: proc(t: ^testing.T) {
	// sqlite_schema (and its older name sqlite_master) lists the tables,
	// indexes, views and triggers, in any query shape, including what the
	// current transaction created; `main.` names the database itself.
	store := fresh_db(t, "sqlite_schema")
	if store == nil do return
	defer cleanup_db(store, "sqlite_schema")
	run(t, store, "CREATE TABLE main.p (id INTEGER PRIMARY KEY, k TEXT UNIQUE, n INT)")
	run(t, store, "CREATE INDEX main.p_n ON p (n)")
	run(t, store, "CREATE TABLE log (m)")
	run(t, store, "CREATE VIEW v AS SELECT k FROM p")
	run(t, store, "CREATE TRIGGER tr AFTER INSERT ON p BEGIN INSERT INTO log VALUES (new.k); END")
	run(t, store, "INSERT INTO main.p (k, n) VALUES ('a', 1)")
	run(t, store, "UPDATE main.p SET n = 2")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM main.p WHERE n = 2").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log").i, i64(1))

	testing.expect_value(t, scalar(t, store, "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name)").s, "log,p")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_schema WHERE type = 'index' ORDER BY name)").s, "p_n,sqlite_autoindex_p_1")
	testing.expect_value(t, scalar(t, store, "SELECT sql FROM main.sqlite_master WHERE name = 'v'").s, `CREATE VIEW v AS SELECT k FROM p`)
	testing.expect_value(t, scalar(t, store, "SELECT tbl_name FROM sqlite_master WHERE type = 'trigger'").s, "p")
	testing.expect_value(t, scalar(t, store, "SELECT sql FROM sqlite_master WHERE type = 'trigger'").s, `CREATE TRIGGER tr AFTER INSERT ON p BEGIN INSERT INTO log VALUES (new.k); END`)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM sqlite_master m JOIN p ON m.tbl_name = 'p'").i, i64(4))
	testing.expect_value(t, scalar(t, store, "SELECT EXISTS (SELECT 1 FROM sqlite_schema WHERE name = 'p') AND NOT EXISTS (SELECT 1 FROM sqlite_schema WHERE name = 'gone')").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM sqlite_temp_master").i, i64(0))
	_ = run_error(t, store, "SELECT nosuch FROM sqlite_master")
	_ = run_error(t, store, "INSERT INTO other.p (k) VALUES ('x')")

	// What a transaction created is in its own catalog before it commits.
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "BEGIN")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE fresh (a)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "DROP TABLE log")))
	stmt := db.embed_prepare(conn, "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name)")
	has_row, step_err := db.embed_step(stmt)
	testing.expect(t, db.error_drop(step_err) && has_row)
	testing.expect_value(t, db.embed_column_text(stmt, 0), "fresh,p")
	db.embed_finalize(stmt)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "ROLLBACK")))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM sqlite_master WHERE name IN ('fresh', 'log')").i, i64(1))
	run(t, store, "DROP TABLE main.log")
	info := run(t, store, "PRAGMA main.table_info(p)")
	testing.expect_value(t, len(info.rows), 3)
	db.sql_result_destroy(&info)
}

@(test)
test_user_version_is_stored :: proc(t: ^testing.T) {
	// PRAGMA user_version and application_id are 32-bit integers kept with
	// the data: a reopen reads them back, a rollback undoes them, and a value
	// that is no 32-bit integer is 0, as SQLite stores it. They used to be
	// session variables held as text.
	store := fresh_db(t, "user_version")
	if store == nil do return
	testing.expect_value(t, scalar(t, store, "PRAGMA user_version").i, i64(0))
	run(t, store, "PRAGMA main.user_version = 7")
	run(t, store, "PRAGMA application_id = -5")
	version := scalar(t, store, "PRAGMA user_version")
	testing.expect_value(t, version.kind, db.Value_Kind.Int)
	testing.expect_value(t, version.i, i64(7))

	conn := db.embed_wrap(store)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "BEGIN")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "PRAGMA user_version = 9")))
	stmt := db.embed_prepare(conn, "PRAGMA user_version")
	has_row, step_err := db.embed_step(stmt)
	testing.expect(t, db.error_drop(step_err) && has_row)
	testing.expect_value(t, db.embed_column_int(stmt, 0), i64(9))
	db.embed_finalize(stmt)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "ROLLBACK")))
	db.embed_close(conn)
	testing.expect_value(t, scalar(t, store, "PRAGMA user_version").i, i64(7))

	db.store_close(store)
	reopened, err := db.store_open("_test_user_version", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(err), "reopen failed: %s", err.message) do return
	defer cleanup_db(reopened, "user_version")
	testing.expect_value(t, scalar(t, reopened, "PRAGMA user_version").i, i64(7))
	testing.expect_value(t, scalar(t, reopened, "PRAGMA application_id").i, i64(-5))
	for text in ([]string{"4294967297", "'abc'", "2147483648"}) {
		run(t, reopened, strings.concatenate({"PRAGMA user_version = ", text}, context.temp_allocator))
		testing.expectf(t, scalar(t, reopened, "PRAGMA user_version").i == 0, "%s", text)
	}
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM sqlite_master").i, i64(0))
}

@(test)
test_pragma_table_functions :: proc(t: ^testing.T) {
	// A pragma that answers rows is readable as a table, pragma_<name>(arg),
	// alone, filtered, and once per row of the catalog it is joined to.
	store := fresh_db(t, "pragma_functions")
	if store == nil do return
	defer cleanup_db(store, "pragma_functions")
	run(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY, k TEXT NOT NULL, n INT)")
	run(t, store, "CREATE TABLE q (a TEXT, b TEXT)")
	run(t, store, "CREATE INDEX q_b ON q (b)")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(name, ',') FROM pragma_table_info('p')").s, "id,k,n")
	testing.expect_value(t, scalar(t, store, "SELECT \"notnull\" FROM pragma_table_info('p') WHERE name = 'id'").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT \"notnull\" FROM pragma_table_info('p') WHERE name = 'k'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM sqlite_master m JOIN pragma_table_info(m.name) c WHERE m.type = 'table'").i, i64(5))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM pragma_index_list('q') WHERE name = 'q_b'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM pragma_table_info('nosuch')").i, i64(0))
	run(t, store, "PRAGMA user_version = 12")
	testing.expect_value(t, scalar(t, store, "SELECT user_version FROM pragma_user_version").i, i64(12))
	// The hidden columns arg and schema, and the argument a term gives.
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(arg, ',') FROM pragma_table_info('q')").s, "q,q")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(name, ',') FROM pragma_table_info WHERE arg = 'q'").s, "a,b")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM sqlite_master m, pragma_table_info p WHERE p.arg = m.name AND m.type = 'table'").i, i64(5))
	testing.expect_value(t, scalar(t, store, "SELECT schema FROM pragma_table_info('q', 'main') LIMIT 1").s, "main")
	// A pragma that changes something is not a table function.
	_ = run_error(t, store, "SELECT * FROM pragma_optimize")
}

@(test)
test_update_of_triggers :: proc(t: ^testing.T) {
	// UPDATE OF fires only when the SET names one of its columns (the value
	// need not change), for an UPSERT's DO UPDATE and for a foreign key's
	// cascade, which writes the child's key columns. The sequence and its log
	// are what SQLite writes for the same statements.
	store := fresh_db(t, "update_of")
	if store == nil do return
	defer cleanup_db(store, "update_of")
	for sql in ([]string {
		"CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT, c TEXT)",
		"CREATE TABLE log (m TEXT)",
		"CREATE TABLE child (id INTEGER PRIMARY KEY, pa INTEGER REFERENCES t(a) ON UPDATE CASCADE, x TEXT)",
		"CREATE TRIGGER tb AFTER UPDATE OF b ON t BEGIN INSERT INTO log VALUES ('b:' || new.b); END",
		"CREATE TRIGGER tbc BEFORE UPDATE OF c, b ON t BEGIN INSERT INTO log VALUES ('bc:' || coalesce(new.c,'')); END",
		"CREATE TRIGGER cpa AFTER UPDATE OF pa ON child BEGIN INSERT INTO log VALUES ('pa:' || new.pa); END",
		"CREATE TRIGGER cx AFTER UPDATE OF x ON child BEGIN INSERT INTO log VALUES ('x'); END",
		"PRAGMA foreign_keys = ON",
		"INSERT INTO t VALUES (1, 'p', 'q'), (2, 'r', 's')",
		"INSERT INTO child VALUES (10, 1, 'z')",
		"UPDATE t SET b = b WHERE a = 1",
		"UPDATE t SET c = 'k' WHERE a = 2",
		"UPDATE t SET a = a",
		"UPDATE t SET a = 5 WHERE a = 1",
		"INSERT INTO t VALUES (2, 'dup', 'w') ON CONFLICT (a) DO UPDATE SET c = excluded.c",
		"INSERT INTO t VALUES (2, 'dup', 'w') ON CONFLICT (a) DO UPDATE SET b = excluded.b",
	}) {
		result := run(t, store, sql)
		db.sql_result_destroy(&result)
	}
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(m, ' ') FROM log").s, "bc:q b:p bc:k pa:5 bc:w bc:w b:dup")
	testing.expect_value(t, scalar(t, store, "SELECT sql FROM sqlite_master WHERE name = 'tbc'").s,
		`CREATE TRIGGER tbc BEFORE UPDATE OF c, b ON t BEGIN INSERT INTO log VALUES ('bc:' || coalesce(new.c,'')); END`)
	_ = run_error(t, store, "CREATE TRIGGER bad AFTER INSERT OF b ON t BEGIN SELECT 1; END")
}

// file_scalar answers one value from a connection, as text.
@(private)
file_scalar :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) -> string {
	stmt := db.embed_prepare(conn, sql)
	if !testing.expectf(t, stmt != nil, "%s did not prepare: %s", sql, db.embed_error(conn)) do return ""
	defer db.embed_finalize(stmt)
	has_row, step_err := db.embed_step(stmt)
	if !testing.expectf(t, db.error_drop(step_err) && has_row, "%s: %s", sql, db.embed_error(conn)) do return ""
	value, _ := db.embed_column_value(stmt, 0)
	return db.sqlite_value_text(value, context.temp_allocator)
}

@(test)
test_sqlite_file_round_trip :: proc(t: ^testing.T) {
	// A SQLite file carries views, triggers, an AUTOINCREMENT key with the
	// counter sqlite_sequence keeps, and user_version and application_id in
	// its header. An export writes them all, and opening the file gives them
	// back as working objects: before, a view or a trigger from a file was
	// text the engine could not run, AUTOINCREMENT and the header were lost.
	store := fresh_db(t, "file_round_trip")
	if store == nil do return
	defer cleanup_db(store, "file_round_trip")
	for sql in ([]string {
		"CREATE TABLE s (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)",
		"CREATE TABLE log (m TEXT)",
		"INSERT INTO s (v) VALUES ('a'), ('b')",
		"DELETE FROM s WHERE id = 2",
		"CREATE VIEW sv AS SELECT v FROM s",
		"CREATE TRIGGER tr AFTER INSERT ON s BEGIN INSERT INTO log VALUES (new.v); END",
		"CREATE TRIGGER svi INSTEAD OF INSERT ON sv BEGIN INSERT INTO s (v) VALUES (upper(new.v)); END",
		"CREATE TRIGGER tu AFTER UPDATE OF v ON s BEGIN INSERT INTO log VALUES ('u'); END",
		"PRAGMA user_version = 42",
		"PRAGMA application_id = -7",
	}) {
		result := run(t, store, sql)
		db.sql_result_destroy(&result)
	}
	path := "_test_round_trip.sqlite"
	os.remove(path)
	defer os.remove(path)
	_, _, export_err := db.sqlite_file_write(store, path)
	if !testing.expectf(t, db.error_ok(export_err), "export: %s", export_err.message) do return

	conn, open_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	testing.expect_value(t, file_scalar(t, conn, "SELECT group_concat(v, ',') FROM sv"), "a")
	testing.expect_value(t, file_scalar(t, conn, "PRAGMA user_version"), "42")
	testing.expect_value(t, file_scalar(t, conn, "PRAGMA application_id"), "-7")
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO s (v) VALUES ('c')")))
	// AUTOINCREMENT does not hand out 2 again.
	testing.expect_value(t, file_scalar(t, conn, "SELECT group_concat(id, ',') FROM s"), "1,3")
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO sv VALUES ('d')")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "UPDATE s SET v = v WHERE id = 1")))
	testing.expect_value(t, file_scalar(t, conn, "SELECT group_concat(m, ',') FROM log"), "c,D,u")
	testing.expect_value(t, file_scalar(t, conn, "SELECT count(*) FROM sqlite_master WHERE type IN ('view', 'trigger')"), "4")
	testing.expect_value(t, file_scalar(t, conn, "SELECT sql FROM sqlite_master WHERE name = 's'"), `CREATE TABLE s (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)`)
	// A dropped view leaves the file's catalog too.
	testing.expect(t, db.error_drop(db.embed_exec(conn, "DROP TRIGGER svi")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "DROP VIEW sv")))
	testing.expect_value(t, file_scalar(t, conn, "SELECT count(*) FROM sqlite_master WHERE type IN ('view', 'trigger')"), "2")
}

@(test)
test_constraint_messages :: proc(t: ^testing.T) {
	// A broken key or NOT NULL says so in SQLite's words, which programs
	// match: "UNIQUE constraint failed: t.a, t.b", "NOT NULL constraint
	// failed: t.c". They used to name the engine's index.
	store := fresh_db(t, "constraint_messages")
	if store == nil do return
	defer cleanup_db(store, "constraint_messages")
	run(t, store, "CREATE TABLE k (a TEXT PRIMARY KEY, b INTEGER UNIQUE, c INT NOT NULL DEFAULT 0, d INT, e INT, UNIQUE (d, e))")
	run(t, store, "CREATE TABLE r (id INTEGER PRIMARY KEY)")
	run(t, store, "INSERT INTO k (a, b, d, e) VALUES ('x', 1, 1, 1)")
	run(t, store, "INSERT INTO r VALUES (1)")
	run(t, store, "INSERT INTO k (a, b) VALUES ('m', 2)")
	cases := [][2]string {
		{"INSERT INTO k (a, b) VALUES ('x', 2)", "UNIQUE constraint failed: k.a"},
		{"INSERT INTO k (a, b) VALUES ('y', 1)", "UNIQUE constraint failed: k.b"},
		{"INSERT INTO k (a, b, d, e) VALUES ('z', 5, 1, 1)", "UNIQUE constraint failed: k.d, k.e"},
		{"INSERT INTO k (a, b, c) VALUES ('w', 9, NULL)", "NOT NULL constraint failed: k.c"},
		{"INSERT INTO r VALUES (1)", "UNIQUE constraint failed: r.id"},
		{"UPDATE k SET b = 1 WHERE a = 'm'", "UNIQUE constraint failed: k.b"},
	}
	for c in cases {
		err := run_error(t, store, c[0])
		testing.expectf(t, err.message == c[1], "%s: %s", c[0], err.message)
	}
}

@(test)
test_create_text_is_kept :: proc(t: ^testing.T) {
	// sqlite_master answers each CREATE as it was written, the way SQLite
	// keeps it (no IF NOT EXISTS, no `main.`, no terminator), ALTER TABLE
	// edits it as SQLite does, and pragma table_info reads the declared types
	// from it. The expected texts are SQLite's for the same statements. The
	// text is data: it survives a reopen and goes with a rollback.
	store := fresh_db(t, "create_text")
	if store == nil do return
	for sql in ([]string {
		"  CREATE TABLE IF NOT EXISTS t1 (a INT, b text, c varchar(10) NOT NULL, d) ;",
		"CREATE TABLE main.t3(a /*c*/ )",
		"create index if not exists i1 on t1(b)",
		"create unique index u1 on t1 (c, d)",
		"create view  v1 as  select 1",
		"CREATE TRIGGER IF NOT EXISTS tr1 AFTER INSERT ON t1 BEGIN SELECT 1; END",
		"ALTER TABLE t1 ADD COLUMN e TEXT DEFAULT 5",
		"ALTER TABLE t1 RENAME COLUMN b TO bb",
		"ALTER TABLE t1 RENAME TO t9",
		"create table w (x, y integer, z text)",
		"ALTER TABLE w DROP COLUMN y",
		"ALTER TABLE w DROP COLUMN x",
	}) {
		result := run(t, store, sql)
		db.sql_result_destroy(&result)
	}
	want := [][2]string {
		{"i1", `CREATE INDEX i1 on "t9"(bb)`},
		{"t3", `CREATE TABLE t3(a /*c*/ )`},
		{"t9", `CREATE TABLE "t9" (a INT, bb text, c varchar(10) NOT NULL, d, e TEXT DEFAULT 5)`},
		{"tr1", `CREATE TRIGGER tr1 AFTER INSERT ON "t9" BEGIN SELECT 1; END`},
		{"u1", `CREATE UNIQUE INDEX u1 on "t9" (c, d)`},
		{"v1", `CREATE VIEW v1 as  select 1`},
		{"w", `CREATE TABLE w (z text)`},
	}
	check := proc(t: ^testing.T, store: ^db.Store, want: [][2]string) {
		for pair in want {
			sql := strings.concatenate({"SELECT sql FROM sqlite_master WHERE name = '", pair[0], "'"}, context.temp_allocator)
			testing.expectf(t, scalar(t, store, sql).s == pair[1], "%s: %s", pair[0], scalar(t, store, sql).s)
		}
		info := run(t, store, "PRAGMA table_info(t9)")
		defer db.sql_result_destroy(&info)
		types := make([dynamic]string, context.temp_allocator)
		for row in info.rows do append(&types, row[2].s)
		testing.expect_value(t, strings.join(types[:], ",", context.temp_allocator), "INT,TEXT,varchar(10),,TEXT")
	}
	check(t, store, want)

	// A rollback takes a CREATE's text with it.
	conn := db.embed_wrap(store)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "BEGIN")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE gone (q)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "ROLLBACK")))
	db.embed_close(conn)
	run(t, store, "CREATE TABLE gone (q REAL)")
	testing.expect_value(t, scalar(t, store, "SELECT sql FROM sqlite_master WHERE name = 'gone'").s, "CREATE TABLE gone (q REAL)")
	run(t, store, "DROP TABLE gone")
	run(t, store, "CREATE TABLE gone (r)")
	testing.expect_value(t, scalar(t, store, "SELECT sql FROM sqlite_master WHERE name = 'gone'").s, "CREATE TABLE gone (r)")

	db.store_close(store)
	reopened, err := db.store_open("_test_create_text", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(err), "reopen: %s", err.message) do return
	defer cleanup_db(reopened, "create_text")
	check(t, reopened, want)
}

@(test)
test_alter_table_follows :: proc(t: ^testing.T) {
	// ALTER TABLE carries along what names the table or the column, as
	// SQLite does; the texts and answers expected are SQLite's.
	store := fresh_db(t, "alter_follows")
	if store == nil do return
	defer cleanup_db(store, "alter_follows")
	exec :: proc(t: ^testing.T, store: ^db.Store, statements: ..string) {
		for sql in statements {
			result := run(t, store, sql)
			db.sql_result_destroy(&result)
		}
	}
	text :: proc(t: ^testing.T, store: ^db.Store, name: string) -> string {
		return scalar(t, store, strings.concatenate({"SELECT sql FROM sqlite_master WHERE name = '", name, "'"}, context.temp_allocator)).s
	}
	// RENAME TO: the trigger moves with its table and keeps firing; the view
	// and the trigger body read the new name.
	exec(t, store,
		"create table t(a, b)", "create table t2(a, b)", "create view v as select b from t",
		"create trigger tr after insert on t begin insert into t2 select * from t; end",
		"alter table t rename to tt", "insert into tt values (1, 2)")
	testing.expect_value(t, scalar(t, store, "SELECT b FROM t2").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT b FROM v").i, i64(2))
	testing.expect_value(t, text(t, store, "v"), `CREATE VIEW v as select b from "tt"`)
	testing.expect_value(t, text(t, store, "tr"), `CREATE TRIGGER tr after insert on "tt" begin insert into t2 select * from "tt"; end`)

	// RENAME COLUMN: a CHECK, UPDATE OF, NEW and OLD, and a qualified mention
	// follow; the same name in another table does not.
	exec(t, store,
		"create table c(a, b, c, check (b > a))", "alter table c rename column b to bb",
		"create table p(a, b)", "create table u(b)", "create view pv as select p.b, u.b as ub from p, u",
		"create trigger pt after update of b on p begin update u set b = new.b where b = old.b; end",
		"alter table p rename column b to bb", "insert into p values (1, 5)", "insert into u values (5)", "update p set bb = 6")
	testing.expect_value(t, text(t, store, "c"), `CREATE TABLE c(a, bb, c, check (bb > a))`)
	_ = run_error(t, store, "insert into c values (1, 0, 0)")
	testing.expect_value(t, scalar(t, store, "SELECT b FROM u").i, i64(6))
	testing.expect_value(t, scalar(t, store, "SELECT bb || ',' || ub FROM pv").s, "6,6")
	testing.expect_value(t, text(t, store, "pv"), `CREATE VIEW pv as select p.bb, u.b as ub from p, u`)
	testing.expect_value(t, text(t, store, "pt"), `CREATE TRIGGER pt after update of bb on p begin update u set b = new.bb where b = old.bb; end`)

	// DROP COLUMN: the other indexes stay and are used; a column an index,
	// a key or a table CHECK reads stays, in SQLite's words.
	exec(t, store, "create table d(a, b, c)", "create index da on d(a)", "create index dc on d(c)",
		"insert into d values (1, 2, 3)", "alter table d drop column b")
	testing.expect_value(t, scalar(t, store, "SELECT a FROM d WHERE c = 3").i, i64(1))
	testing.expect_value(t, text(t, store, "d"), "CREATE TABLE d(a, c)")
	refusals := [][2]string {
		{"alter table d drop column c", "error in index dc after drop column: no such column: c"},
		{"alter table c drop column bb", "error in table c after drop column: no such column: bb"},
	}
	exec(t, store, "create table k(a integer primary key, b unique)")
	for refusal in refusals {
		err := run_error(t, store, refusal[0])
		testing.expectf(t, err.message == refusal[1], "%s: %s", refusal[0], err.message)
	}
	testing.expect_value(t, run_error(t, store, "alter table k drop column a").message, `cannot drop PRIMARY KEY column: "a"`)
	testing.expect_value(t, run_error(t, store, "alter table k drop column b").message, `cannot drop UNIQUE column: "b"`)
}

@(test)
test_mirror_patches_sqlite_sequence :: proc(t: ^testing.T) {
	// A mirrored file keeps sqlite_sequence current on the page-patch path:
	// a deleted top rowid is not handed out again by the next reader of the
	// file, and the commits rewrite nothing whole.
	store := fresh_db(t, "mirror_sequence")
	if store == nil do return
	defer cleanup_db(store, "mirror_sequence")
	run(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
	run(t, store, "CREATE TABLE n (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
	run(t, store, "INSERT INTO s (v) VALUES (1)")
	path := "_test_mirror_sequence.sqlite"
	os.remove(path)
	defer os.remove(path)
	_, _, export_err := db.sqlite_file_write(store, path)
	if !testing.expectf(t, db.error_ok(export_err), "export: %s", export_err.message) do return

	conn, open_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	for sql in ([]string{"INSERT INTO s (v) VALUES (2)", "INSERT INTO s (v) VALUES (3)", "DELETE FROM s WHERE id = 3", "INSERT INTO n (v) VALUES (7)"}) {
		testing.expectf(t, db.error_drop(db.embed_exec(conn, sql)), "%s: %s", sql, db.embed_error(conn))
	}
	testing.expect_value(t, conn.store.mirror_full_writes, 0)
	db.embed_close(conn)

	again, again_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(again_err), "reopen: %s", again_err.message) do return
	defer db.embed_close(again)
	testing.expect(t, db.error_drop(db.embed_exec(again, "INSERT INTO s (v) VALUES (4)")))
	testing.expect_value(t, file_scalar(t, again, "SELECT max(id) FROM s"), "4")
	testing.expect_value(t, file_scalar(t, again, "SELECT max(id) FROM n"), "1")
}

@(test)
test_sqlite_file_foreign_keys :: proc(t: ^testing.T) {
	// A SQLite file's REFERENCES come with it, in the order their parents
	// need, and the file opens with SQLite's default: declared, enforced after
	// PRAGMA foreign_keys = ON. Before, the keys were dropped on import.
	store := fresh_db(t, "file_foreign_keys")
	if store == nil do return
	defer cleanup_db(store, "file_foreign_keys")
	run(t, store, "CREATE TABLE parent (id INTEGER PRIMARY KEY, n INTEGER)")
	run(t, store, "CREATE TABLE child (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES parent (id) ON DELETE CASCADE)")
	run(t, store, "INSERT INTO parent VALUES (1, 1)")
	run(t, store, "INSERT INTO child VALUES (1, 1)")
	path := "_test_file_foreign_keys.sqlite"
	os.remove(path)
	defer os.remove(path)
	_, _, export_err := db.sqlite_file_write(store, path)
	if !testing.expectf(t, db.error_ok(export_err), "export: %s", export_err.message) do return

	conn, open_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	testing.expect_value(t, file_scalar(t, conn, "PRAGMA foreign_keys"), "0")
	testing.expect_value(t, file_scalar(t, conn, "SELECT \"table\" || '.' || \"to\" || ' ' || on_delete FROM pragma_foreign_key_list('child')"), "parent.id CASCADE")
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO child VALUES (2, 99)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "PRAGMA foreign_keys = ON")))
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "INSERT INTO child VALUES (3, 98)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "DELETE FROM parent WHERE id = 1")))
	testing.expect_value(t, file_scalar(t, conn, "SELECT group_concat(id, ',') FROM child"), "2")
}
