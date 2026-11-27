package tests

import "core:testing"

import db "../engine"

// Column references over several sources and into an enclosing query's row,
// in the shapes where finding the wrong source is easy: a LEFT JOIN's missing
// row, the same table twice, USING and NATURAL, rowid, two levels of
// correlation, a reference evaluated before its source is bound (an ON), a
// name two sources have, and the same table outside and inside a subquery.
// Each runs twice, the second time from the kept parse. The answers are
// SQLite's (3.54.1).

@(private = "file")
cp_store :: proc(t: ^testing.T) -> ^db.Store {
	store, err := db.store_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	run_done(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT, g INTEGER)")
	run_done(t, store, "CREATE TABLE q (id INTEGER PRIMARY KEY, p_id INTEGER, name TEXT, v INTEGER)")
	run_done(t, store, "INSERT INTO p VALUES (1, 'a', 1), (2, 'b', 1), (3, 'c', 2), (4, 'd', 2), (5, 'e', 3)")
	run_done(t, store, "INSERT INTO q VALUES (1, 1, 'x', 10), (2, 1, 'y', 20), (3, 3, 'z', 30), (4, 4, 'w', 5), (5, 9, 'u', 7)")
	return store
}

@(test)
test_a_column_reference_reads_the_source_it_names :: proc(t: ^testing.T) {
	store := cp_store(t)
	defer db.store_close(store)
	cases := [][2]string {
		{"SELECT group_concat(p.name || ':' || coalesce(q.v, 'null'), ',') FROM (SELECT * FROM p ORDER BY id) p LEFT JOIN q ON q.p_id = p.id", "a:10,a:20,b:null,c:30,d:5,e:null"},
		{"SELECT group_concat(x.id || '-' || y.id, ',') FROM p x JOIN p y ON y.g = x.g AND y.id > x.id", "1-2,3-4"},
		{"SELECT group_concat(id, ',') FROM p JOIN q USING (id)", "1,2,3,4,5"},
		{"SELECT group_concat(name, ',') FROM p WHERE EXISTS (SELECT 1 FROM q WHERE q.p_id = p.id AND EXISTS (SELECT 1 FROM q AS r WHERE r.v > q.v AND r.p_id = p.id))", "a"},
		{"SELECT group_concat(p.rowid, ',') FROM p JOIN q ON q.p_id = p.id", "1,1,3,4"},
		{"SELECT group_concat(p.name || (SELECT count(*) FROM q WHERE q.p_id = p.id AND v > (SELECT min(v) FROM q AS m WHERE m.p_id = p.id)), ',') FROM p", "a1,b0,c0,d0,e0"},
	}
	for c in cases {
		for _ in 0 ..< 2 do testing.expectf(t, scalar(t, store, c[0]).s == c[1], "%s", c[0])
	}
	testing.expect_value(t, scalar(t, store, "SELECT sum(v) FROM p JOIN q ON p_id = p.id WHERE g = 1").i, i64(30))
	// The same table outside and inside, under an alias inside.
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, "SELECT group_concat((SELECT count(*) FROM q AS r WHERE r.v > q.v), ',') FROM q").s, "2,1,0,4,3")
	// No column the two tables share holds the same values: no row.
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(id || name, ',') FROM p NATURAL JOIN q").kind, db.Value_Kind.Null)
	// A name two sources have is refused, every time.
	for _ in 0 ..< 2 {
		result, err := db.sql_execute(store, "SELECT name FROM p JOIN q ON q.p_id = p.id")
		testing.expectf(t, !db.error_ok(err), "an ambiguous name answered")
		db.sql_result_destroy(&result)
		db.error_free(&err)
	}
}
