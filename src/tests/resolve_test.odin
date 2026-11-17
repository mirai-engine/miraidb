package tests

import "core:testing"

import db "../engine"

@(test)
test_names_resolved_before_running :: proc(t: ^testing.T) {
	// A name that is not there is refused before the statement runs, so an
	// empty table does not hide a misspelling (D37); and every scope the
	// executor knows still resolves.
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	for sql in ([]string {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b INTEGER)",
		"CREATE TABLE u (k INTEGER, v TEXT)",
		"CREATE TABLE log (x TEXT)",
		"CREATE VIEW vv AS SELECT a, b AS bee FROM t",
		"CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.a); END",
	}) {
		testing.expectf(t, db.error_drop(db.embed_exec(conn, sql)), "%s: %s", sql, db.embed_error(conn))
	}

	refused := []string {
		"SELECT nope FROM t",
		"SELECT a FROM t WHERE nope = 1",
		"SELECT a FROM t ORDER BY nope",
		"SELECT a FROM t GROUP BY nope",
		"SELECT * FROM missing",
		"SELECT t.nope FROM t",
		"SELECT x.a FROM t",
		"SELECT a FROM t WHERE id IN (SELECT nope FROM u)",
		"SELECT b FROM vv",
		"WITH c AS (SELECT a FROM t) SELECT b FROM c",
		"SELECT s.b FROM (SELECT a FROM t) AS s",
		"INSERT INTO t (nope) VALUES (1)",
		"INSERT INTO missing VALUES (1)",
		"UPDATE t SET nope = 1",
		"UPDATE t SET a = nope",
		"DELETE FROM t WHERE nope = 1",
	}
	for sql in refused {
		stmt := db.embed_prepare(conn, sql)
		if !testing.expectf(t, stmt == nil, "prepared, should be refused: %s", sql) {
			db.embed_finalize(stmt)
			continue
		}
		kind := db.embed_error_kind(conn)
		testing.expectf(t, kind == .Column_Not_Found || kind == .Table_Not_Found, "%s: %v %s", sql, kind, db.embed_error(conn))
		// The plain entry point refuses it too, though the table is empty.
		testing.expectf(t, !db.error_drop(db.embed_exec(conn, sql)), "ran, should be refused: %s", sql)
	}

	accepted := []string {
		"SELECT a AS x FROM t ORDER BY x",
		"SELECT b AS g, count(*) FROM t GROUP BY g HAVING count(*) > 0",
		"SELECT rowid, _rowid_, oid FROM t",
		"SELECT t.id, u.v FROM t JOIN u ON u.k = t.id",
		"SELECT id FROM t AS r WHERE EXISTS (SELECT 1 FROM u WHERE u.k = r.id)",
		"SELECT s.a FROM (SELECT a FROM t) AS s",
		"SELECT k.column1 FROM (VALUES (1), (2)) AS k",
		"WITH c(z) AS (SELECT a FROM t) SELECT z FROM c",
		"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3) SELECT i FROM n",
		"SELECT bee FROM vv",
		"SELECT key, value FROM json_each('[1, 2]')",
		"SELECT a FROM t UNION SELECT v FROM u ORDER BY a",
		"SELECT id FROM t JOIN t AS t2 USING (id)",
		"INSERT INTO t (id, a, b) VALUES (1, 'p', 1) ON CONFLICT (id) DO UPDATE SET b = excluded.b + b",
		"INSERT INTO t (a, b) VALUES ('q', 2)",
		"UPDATE t SET b = u.k FROM u WHERE u.v = t.a",
		"SELECT count(*) FROM t WHERE a = 'p' OR a = 'q' OR a = 'r' OR b = 1",
	}
	for sql in accepted {
		stmt := db.embed_prepare(conn, sql)
		if !testing.expectf(t, stmt != nil, "refused, should prepare: %s: %s", sql, db.embed_error(conn)) do continue
		db.embed_finalize(stmt)
	}
	// A trigger's body names NEW, and runs.
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO t (a, b) VALUES ('q', 2)")))
	stmt := db.embed_prepare(conn, "SELECT count(*) FROM log")
	if testing.expect(t, stmt != nil) {
		_, err := db.embed_step(stmt)
		testing.expect(t, db.error_drop(err))
		testing.expect_value(t, db.embed_column_int(stmt, 0), i64(1))
		db.embed_finalize(stmt)
	}
}
