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

// A comparison's collation is an explicit COLLATE, the left operand's first;
// else a column operand's, the left one's first, and a column that declares no
// collation is BINARY: `plain = nocase_column` compares as BINARY. The engine
// skipped a column without a collation and took the right one's, and took a
// right COLLATE over a left one.
@(test)
test_a_comparison_takes_its_collation_by_sqlites_precedence :: proc(t: ^testing.T) {
	cr_check(t, []Cr_Case {
		{"SELECT count(*) FROM c JOIN a ON c.s = a.n", 1},
		{"SELECT count(*) FROM c JOIN a ON a.n = c.s", 6},
		{"SELECT count(*) FROM c JOIN a ON c.s COLLATE BINARY = a.n COLLATE NOCASE", 1},
		{"SELECT count(*) FROM c JOIN a ON c.s COLLATE NOCASE = a.p COLLATE BINARY", 6},
		{"SELECT count(*) FROM c, a WHERE c.u = a.p", 4},
		{"SELECT count(*) FROM c, a WHERE a.p = c.u", 2},
		{"SELECT count(*) FROM c, a WHERE (c.s || '') = a.n", 6},
		{"SELECT count(*) FROM c, a WHERE c.s < a.n", 4},
		{"SELECT count(*) FROM c, a WHERE a.n > c.s", 2},
		{"SELECT count(*) FROM c, a WHERE c.s BETWEEN a.n AND a.n", 1},
		{"SELECT count(*) FROM c, a WHERE a.n BETWEEN c.s AND c.s", 6},
		{"SELECT sum((SELECT count(*) FROM c WHERE c.s = a.n)) FROM a", 1},
		{"SELECT sum((SELECT count(*) FROM c WHERE a.n = c.s)) FROM a", 6},
		{"SELECT sum((SELECT count(*) FROM c WHERE c.u = a.p)) FROM a", 4},
		{"SELECT count(*) FROM c, a WHERE c.s IS a.n", 1},
		{"SELECT count(*) FROM c, a WHERE c.s <> a.n", 11},
	})
}
