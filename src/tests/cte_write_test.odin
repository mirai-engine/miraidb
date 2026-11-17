package tests

import "core:testing"

import db "../engine"

@(private = "file")
cte_count :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) -> i64 {
	stmt := db.embed_prepare(conn, sql)
	if !testing.expectf(t, stmt != nil, "prepare %s: %s", sql, db.embed_error(conn)) do return -1
	defer db.embed_finalize(stmt)
	has_row, err := db.embed_step(stmt)
	if !testing.expect(t, db.error_drop(err) && has_row) do return -1
	return db.embed_column_int(stmt, 0)
}

@(test)
test_cte_on_a_write :: proc(t: ^testing.T) {
	// A WITH in front of an INSERT, an UPDATE or a DELETE, and inside an
	// INSERT's SELECT, gives the write tables it reads by name, recursive ones
	// included, for that statement only.
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	for sql in ([]string {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)",
		"WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 10) INSERT INTO t (id, v) SELECT x, x * 10 FROM n",
		"INSERT INTO t (id, v) WITH more AS (SELECT 11 AS id, 110 AS v) SELECT id, v FROM more",
		"WITH big AS (SELECT id FROM t WHERE v > 80) UPDATE t SET v = 0 WHERE id IN (SELECT id FROM big)",
		"WITH src(id, bonus) AS (SELECT 1, 5) UPDATE t SET v = v + src.bonus FROM src WHERE t.id = src.id",
		"WITH small AS (SELECT id FROM t WHERE id <= 3) DELETE FROM t WHERE id IN (SELECT id FROM small)",
	}) {
		testing.expectf(t, db.error_drop(db.embed_exec(conn, sql)), "%s: %s", sql, db.embed_error(conn))
	}
	testing.expect_value(t, cte_count(t, conn, "SELECT count(*) FROM t"), i64(8))
	testing.expect_value(t, cte_count(t, conn, "SELECT count(*) FROM t WHERE v = 0"), i64(3))
	testing.expect_value(t, cte_count(t, conn, "SELECT sum(v) FROM t"), i64(40 + 50 + 60 + 70 + 80))
	// The CTE lasts for its statement: the name means nothing afterwards.
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "SELECT * FROM big")))
}
