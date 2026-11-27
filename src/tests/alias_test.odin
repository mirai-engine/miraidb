package tests

import "core:testing"

import db "../engine"

// A table given an alias is known by the alias alone, in SQLite and in
// PostgreSQL: `SELECT q.v FROM q AS r` is "no such column: q.v". Inside a
// subquery that reads q under another name, q is then the enclosing query's
// q. The engine let the table's own name reach it too, so such a subquery
// compared the inner row with itself: SQLite answers 2,1,0,4,3 below, the
// engine answered 0,0,0,1,1. The planner read the qualifier the same way, and
// could have narrowed the inner table by the outer row's column.
@(test)
test_a_table_behind_an_alias_is_known_by_the_alias :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE TABLE q (id INTEGER PRIMARY KEY, p_id INTEGER, v INTEGER)")
	run_done(t, store, "INSERT INTO p VALUES (1, 'a'), (2, 'b'), (3, 'c'), (4, 'd')")
	run_done(t, store, "INSERT INTO q VALUES (1, 1, 10), (2, 1, 20), (3, 3, 30), (4, 4, 5), (5, 9, 7)")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat((SELECT count(*) FROM q AS r WHERE r.v > q.v), ',') FROM q").s, "2,1,0,4,3")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(p.name || ':' || q.v || ':' || (SELECT count(*) FROM q AS r WHERE r.v > q.v AND r.p_id = p.id), ',') FROM p JOIN q ON q.p_id = p.id").s, "a:10:1,a:20:0,c:30:0,d:5:0")
	// Through the alias, the table answers as before.
	testing.expect_value(t, scalar(t, store, "SELECT sum(r.v) FROM q AS r WHERE r.p_id = 1").i, i64(30))
	for sql in ([]string{"SELECT q.v FROM q AS r", "SELECT r.v FROM q AS r WHERE q.p_id = 1"}) {
		result, run_err := db.sql_execute(store, sql)
		testing.expectf(t, !db.error_ok(run_err), "%s: a table's name answered behind its alias", sql)
		db.sql_result_destroy(&result)
		db.error_free(&run_err)
	}
}
