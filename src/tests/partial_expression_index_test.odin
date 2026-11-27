package tests

import "core:strings"
import "core:testing"

import db "../engine"

// The planner reads partial and expression indexes (D36, A2.5): a partial
// index when the query's terms imply its WHERE, an expression index for an
// equality with its expression. Each count is SQLite 3.45's, and so is each
// index: `index` is the one SQLite's EXPLAIN QUERY PLAN searches, empty where
// it scans (a scan of a covering index included, which this engine does not
// have).

@(private = "file")
Pe_Case :: struct {
	sql:    string,
	sqlite: i64,
	index:  string,
}

@(private = "file")
PE_CASES := []Pe_Case {
	{"SELECT count(*) FROM t WHERE lower(s) = 'k3'", 37, "t_lower"},
	{"SELECT count(*) FROM t WHERE lower(t.s) = 'k3'", 37, "t_lower"},
	{"SELECT count(*) FROM t WHERE 'k3' = lower(s)", 37, "t_lower"},
	{"SELECT count(*) FROM t WHERE lower(s) = 'K3'", 0, "t_lower"},
	{"SELECT count(*) FROM t WHERE a + flag = 10", 18, "t_sum"},
	{"SELECT count(*) FROM t WHERE a + flag = 10.0", 18, "t_sum"},
	{"SELECT count(*) FROM t WHERE a + flag = '10'", 0, "t_sum"},
	{"SELECT count(*) FROM t WHERE n COLLATE NOCASE = 'k3'", 40, "t_nocase"},
	// BINARY, not the index's NOCASE.
	{"SELECT count(*) FROM t WHERE n = 'k3'", 0, ""},
	{"SELECT count(*) FROM t WHERE a = 5 AND flag = 1", 5, "t_part"},
	{"SELECT count(*) FROM t WHERE flag = 1 AND a = 5", 5, "t_part"},
	// Nothing implies flag = 1: the partial index misses rows.
	{"SELECT count(*) FROM t WHERE a = 5", 19, ""},
	// `s = ...` and `s > ...` imply `s IS NOT NULL`.
	{"SELECT count(*) FROM t WHERE s = 'k3'", 37, "t_nn"},
	{"SELECT count(*) FROM t WHERE s > 'k45'", 333, "t_nn"},
	{"SELECT count(*) FROM t WHERE upper(s) = 'K3'", 37, ""},
	// The constant's COLLATE is the comparison's, not the index's.
	{"SELECT count(*) FROM t WHERE lower(s) = 'k3' COLLATE NOCASE", 37, ""},
	{"SELECT count(*) FROM t WHERE a = 60 AND a > 50 AND flag = 2", 6, "t_big"},
	{"SELECT count(*) FROM t WHERE a = 60 AND flag = 2", 6, ""},
	{"SELECT count(*) FROM t WHERE lower(s) = NULL", 0, "t_lower"},
	{"SELECT count(*) FROM t WHERE a + flag = 10 AND lower(s) = 'k9'", 6, "t_sum"},
}

@(private = "file")
plan_index_of :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> string {
	explain := strings.concatenate({"EXPLAIN QUERY PLAN ", sql}, context.temp_allocator)
	result := run(t, store, explain)
	defer db.sql_result_destroy(&result)
	for row in result.rows {
		detail := row[3].s
		if cut := strings.index(detail, " USING INDEX "); cut >= 0 && strings.has_prefix(detail, "SEARCH ") {
			return strings.clone(detail[cut + len(" USING INDEX "):], context.temp_allocator)
		}
	}
	return ""
}

@(test)
test_partial_and_expression_indexes_answer_as_sqlite :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, s TEXT, n TEXT, flag INTEGER)")
	run_done(t, store, "WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r WHERE i < 2000) INSERT INTO t SELECT i, CASE WHEN i % 17 = 0 THEN NULL ELSE i % 100 END, CASE WHEN i % 13 = 0 THEN NULL ELSE 'k' || (i % 50) END, 'K' || (i % 50), i % 3 FROM r")
	run_done(t, store, "CREATE INDEX t_lower ON t(lower(s))")
	run_done(t, store, "CREATE INDEX t_sum ON t(a + flag)")
	run_done(t, store, "CREATE INDEX t_nocase ON t(n COLLATE NOCASE)")
	run_done(t, store, "CREATE INDEX t_part ON t(a) WHERE flag = 1")
	run_done(t, store, "CREATE INDEX t_nn ON t(s) WHERE s IS NOT NULL")
	run_done(t, store, "CREATE INDEX t_big ON t(a) WHERE a > 50 AND flag = 2")
	for c, i in PE_CASES {
		got := scalar(t, store, c.sql).i
		testing.expectf(t, got == c.sqlite, "case %d: got %d, SQLite %d: %s", i, got, c.sqlite, c.sql)
		index := plan_index_of(t, store, c.sql)
		testing.expectf(t, index == c.index, "case %d: searched %q, SQLite %q: %s", i, index, c.index, c.sql)
	}
	// A write the transaction has not committed is not in an index yet: the
	// scan answers, with the staged row.
	tx := db.tx_begin_write(store)
	inserted, insert_err := db.sql_execute_in_tx(tx, "INSERT INTO t VALUES (5000, 7, 'k3', 'K3', 1)")
	db.sql_result_destroy(&inserted)
	testing.expect(t, db.error_ok(insert_err))
	counted, count_err := db.sql_execute_in_tx(tx, "SELECT count(*) FROM t WHERE lower(s) = 'k3'")
	testing.expect(t, db.error_ok(count_err) && len(counted.rows) == 1 && counted.rows[0][0].i == 38)
	db.sql_result_destroy(&counted)
	db.error_free(&count_err)
	db.tx_rollback(tx)
	// A row written after the index was made is filed under its expression.
	run_done(t, store, "INSERT INTO t VALUES (5001, 7, 'K3', 'K3', 1)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE lower(s) = 'k3'").i, 38)
	run_done(t, store, "DELETE FROM t WHERE lower(s) = 'k3' AND id > 4000")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE lower(s) = 'k3'").i, 37)
}

// An expression's value can be a number of any kind, and each kind files its
// own key: the equality reads the keys of every kind the constant equals.
@(test)
test_expression_index_finds_every_numeric_kind :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE u (id INTEGER PRIMARY KEY, x UBIGINT, f REAL)")
	run_done(t, store, "WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r WHERE i < 100) INSERT INTO u SELECT i, i % 10, (i % 10) * 1.0 FROM r")
	run_done(t, store, "CREATE INDEX u_x ON u(x * 1)")
	run_done(t, store, "CREATE INDEX u_f ON u(f + 0)")
	CASES :: [?]struct {
		sql:   string,
		count: i64,
		index: string,
	} {
		{"SELECT count(*) FROM u WHERE x * 1 = 7", 10, "u_x"},
		{"SELECT count(*) FROM u WHERE x * 1 = 7.0", 10, "u_x"},
		{"SELECT count(*) FROM u WHERE x * 1 = 7.5", 0, "u_x"},
		{"SELECT count(*) FROM u WHERE f + 0 = 7", 10, "u_f"},
		{"SELECT count(*) FROM u WHERE f + 0 = 7.0", 10, "u_f"},
	}
	for c, i in CASES {
		testing.expectf(t, scalar(t, store, c.sql).i == c.count, "case %d: %s", i, c.sql)
		testing.expectf(t, plan_index_of(t, store, c.sql) == c.index, "case %d plan: %s", i, c.sql)
	}
}
