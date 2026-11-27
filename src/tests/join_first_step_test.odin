package tests

import "core:testing"

import db "../engine"

// A rule SQLite follows that the engine did not, found while letting a
// correlated subquery probe an index. Every answer below is SQLite's.

@(private = "file")
CR_SETUP := []string {
	"CREATE TABLE a (id INTEGER PRIMARY KEY, n TEXT COLLATE NOCASE, p TEXT)",
	"CREATE TABLE c (id INTEGER PRIMARY KEY, s TEXT, u TEXT COLLATE NOCASE)",
	"CREATE TABLE d (id INTEGER PRIMARY KEY, c_id INTEGER, w TEXT)",
	"INSERT INTO a VALUES (1,'ab','ab'),(2,'XY','XY'),(3,'Ab','xy')",
	"INSERT INTO c VALUES (1,'ab','ab'),(2,'AB','AB'),(3,'xy','xy'),(4,'Xy','b')",
	"INSERT INTO d VALUES (1,1,'p'),(2,2,'q'),(3,2,'p'),(4,4,'r')",
}

@(private = "file")
Cr_Case :: struct {
	sql:    string,
	sqlite: i64,
}

@(private = "file")
cr_check :: proc(t: ^testing.T, cases: []Cr_Case) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	for sql in CR_SETUP do run_done(t, store, sql)
	for c in cases {
		// The second run reads the tree its first run resolved and linked.
		for _ in 0 ..< 2 {
			got := scalar(t, store, c.sql).i
			testing.expectf(t, got == c.sqlite, "got %d, SQLite %d: %s", got, c.sqlite, c.sql)
		}
	}
}

// An ON that names only the relation the planner puts first is answered by
// the step after it. Kept on the first step, which the executor reads without
// a condition, it was dropped: `c JOIN a ON a.p = 'ab'` kept every pair.
@(test)
test_an_on_of_the_relation_run_first_still_filters :: proc(t: ^testing.T) {
	cr_check(t, []Cr_Case {
		{"SELECT count(*) FROM c JOIN a ON a.p = 'ab'", 4},
		{"SELECT count(*) FROM c JOIN a ON 'AB' = a.n", 8},
		{"SELECT count(*) FROM c JOIN a ON a.id > 1", 8},
		{"SELECT count(*) FROM c JOIN a ON a.id = 2 JOIN d ON d.c_id = c.id", 4},
		{"SELECT count(*) FROM c JOIN d ON d.w = 'p' JOIN a ON a.id = c.id", 6},
		{"SELECT count(*) FROM d JOIN c ON c.s = 'xy' JOIN a ON a.p = 'xy'", 4},
		{"SELECT count(*) FROM c JOIN a ON a.n = 'AB' WHERE c.id < 3", 4},
	})
}
