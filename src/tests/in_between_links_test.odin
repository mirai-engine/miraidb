package tests

import "core:testing"

import db "../engine"

// BETWEEN and IN compare under the collation their resolution decided
// (Compare_Link, A1.10), as a comparison operator does: an IN by its operand's
// collation, a BETWEEN by each comparison's, with SQLite's precedence. A NOCASE
// column's IN looked the collation up by its name for every item of every row,
// and lowered both texts into copies to compare them. Each answer is SQLite's.

@(private = "file")
Ib_Case :: struct {
	sql:    string,
	sqlite: i64,
}

@(private = "file")
IB_CASES := []Ib_Case {
	{"SELECT count(*) FROM t WHERE n IN ('k3', 'k7', 'k11')", 120},
	{"SELECT count(*) FROM t WHERE s IN ('K3', 'K7')", 0},
	{"SELECT count(*) FROM t WHERE s COLLATE NOCASE IN ('K3', 'K7')", 80},
	{"SELECT count(*) FROM t WHERE n COLLATE BINARY IN ('k3', 'K7')", 40},
	{"SELECT count(*) FROM t WHERE n NOT IN ('k3', 'k7')", 1920},
	{"SELECT count(*) FROM t WHERE n IN (SELECT lower(n) FROM t WHERE id < 4)", 120},
	{"SELECT count(*) FROM t WHERE n COLLATE RTRIM IN ('K3  ', 'K7')", 80},
	{"SELECT count(*) FROM t WHERE n BETWEEN 'k1' AND 'k3'", 920},
	{"SELECT count(*) FROM t WHERE s BETWEEN 'K1' AND 'K3'", 0},
	// The high bound's COLLATE decides the high comparison alone.
	{"SELECT count(*) FROM t WHERE s BETWEEN 'K1' AND 'K3' COLLATE NOCASE", 960},
	{"SELECT count(*) FROM t WHERE s COLLATE NOCASE BETWEEN 'K1' AND 'K3'", 920},
	{"SELECT count(*) FROM t WHERE n NOT BETWEEN 'k1' AND 'k3'", 1080},
	{"SELECT count(*) FROM t WHERE x BETWEEN 20 AND 40", 420},
	{"SELECT count(*) FROM t WHERE x IN (3, 7, 11)", 60},
}

@(test)
test_between_and_in_compare_under_their_linked_collation :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, x INTEGER, s TEXT, n TEXT COLLATE NOCASE)")
	run_done(t, store, "WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r WHERE i < 2000) INSERT INTO t SELECT i, i % 100, 'k' || (i % 50), 'K' || (i % 50) FROM r")
	for c, i in IB_CASES {
		// The second run is the kept statement's, whose links are made.
		for run_index in 0 ..< 2 {
			db.resolve_counters_reset()
			got := scalar(t, store, c.sql).i
			testing.expectf(t, got == c.sqlite, "case %d: got %d, SQLite %d: %s", i, got, c.sqlite, c.sql)
			if run_index == 1 {
				names := db.resolve_counters().collation_names
				testing.expectf(t, names < 20, "case %d looked a collation up %d times: %s", i, names, c.sql)
			}
		}
	}
}
