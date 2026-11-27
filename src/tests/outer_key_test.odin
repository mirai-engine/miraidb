package tests

import "core:testing"

import db "../engine"

// A correlated subquery probes an index of its table with a column of the
// query around it, as it does with a constant: for one run of the subquery
// that column is constant. The column is the one its link names (an enclosing
// select's), and it keys the probe only where the probe finds every row the
// comparison keeps: a TEXT column compared with an INTEGER one turns '05' into
// 5 (SQLite's affinity), and an outer column's collation can decide the
// comparison, so those are still scanned. Each answer below is SQLite's.

@(private = "file")
OK_SETUP := []string {
	"CREATE TABLE a (id INTEGER PRIMARY KEY, x INTEGER, t TEXT, n TEXT COLLATE NOCASE)",
	"CREATE TABLE c (id INTEGER PRIMARY KEY, a_id INTEGER, s TEXT, u TEXT COLLATE NOCASE)",
	"CREATE INDEX c_a ON c (a_id)",
	"CREATE INDEX c_s ON c (s)",
	"CREATE INDEX c_u ON c (u)",
	"WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r WHERE i < 60) INSERT INTO a SELECT i, i % 9, CASE i % 3 WHEN 0 THEN 'Ab' WHEN 1 THEN 'cd' ELSE 'EF' END, CASE i % 2 WHEN 0 THEN 'ab' ELSE 'XY' END FROM r",
	"WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r WHERE i < 300) INSERT INTO c SELECT i, (i * 7) % 61, CASE i % 4 WHEN 0 THEN '0' || (i % 9) WHEN 1 THEN '' || (i % 9) WHEN 2 THEN 'ab' ELSE 'AB' END, CASE i % 3 WHEN 0 THEN 'ab' WHEN 1 THEN 'AB' ELSE 'Cd' END FROM r",
}

@(private = "file")
Ok_Case :: struct {
	sql:    string,
	sqlite: i64,
	// probed is set where the subquery reads through the index: the run
	// scans far fewer rows than a subquery that read all of c per outer row.
	probed: bool,
}

@(private = "file")
OK_CASES := []Ok_Case {
	{"SELECT sum((SELECT count(*) FROM c WHERE c.a_id = a.id)) FROM a", 296, true},
	{"SELECT sum((SELECT count(*) FROM c WHERE a.id = c.a_id)) FROM a", 296, true},
	{"SELECT sum((SELECT count(*) FROM c WHERE c.a_id > a.id AND c.a_id <= a.id + 3)) FROM a", 858, false},
	{"SELECT sum((SELECT count(*) FROM c WHERE c.a_id BETWEEN a.x AND a.id)) FROM a", 8189, false},
	// TEXT against INTEGER: '05' is 5 to the comparison, not to the index.
	{"SELECT sum((SELECT count(*) FROM c WHERE c.s = a.x)) FROM a", 1000, false},
	// The inner column's collation folds the index as it folds the comparison.
	{"SELECT sum((SELECT count(*) FROM c WHERE c.u = a.t)) FROM a", 6000, true},
	// The outer column's NOCASE decides a comparison the binary index cannot answer.
	{"SELECT sum((SELECT count(*) FROM c WHERE c.s = a.n)) FROM a", 2250, false},
	{"SELECT sum((SELECT count(*) FROM c WHERE c.s = a.t)) FROM a", 0, true},
	{"SELECT count(*) FROM a WHERE EXISTS (SELECT 1 FROM c WHERE c.a_id = a.id AND c.u = 'cd')", 60, false},
}

@(test)
test_a_correlated_subquery_probes_an_index_with_the_outer_row :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	for sql in OK_SETUP do run_done(t, store, sql)
	for c, i in OK_CASES {
		for _ in 0 ..< 2 {
			db.store_reset_rows_scanned(store)
			got := scalar(t, store, c.sql).i
			testing.expectf(t, got == c.sqlite, "case %d: got %d, SQLite %d: %s", i, got, c.sqlite, c.sql)
			// 60 outer rows reading all 300 of c each is 18 000 rows.
			if c.probed {
				scanned := db.store_rows_scanned(store)
				testing.expectf(t, scanned < 9000, "case %d scanned %d rows: %s", i, scanned, c.sql)
			}
		}
	}
}
