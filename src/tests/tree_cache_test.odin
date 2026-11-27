package tests

import "core:testing"

import db "../engine"

// The trees a statement reads beside its own, a view's query and a policy's
// predicate, are kept by their text for a catalog generation (A1.8f): a run
// that reads them again does not parse them again. A change to the catalog
// (the view's table altered, a policy replaced) parses them again, and a read
// that began before a change parses its own.

@(private = "file")
tc_parses :: proc(t: ^testing.T, store: ^db.Store, sql: string, want: i64, loc := #caller_location) -> u64 {
	db.resolve_counters_reset()
	testing.expect_value(t, scalar(t, store, sql).i, want, loc = loc)
	return db.resolve_counters().parses
}

@(test)
test_a_view_is_parsed_once_per_catalog :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, x INTEGER)")
	run_done(t, store, "INSERT INTO a VALUES (1, 1), (2, 5), (3, 9)")
	run_done(t, store, "CREATE VIEW big AS SELECT * FROM a WHERE x > 2")
	run_done(t, store, "CREATE VIEW bigger AS SELECT id FROM big WHERE x > 6")
	tc_parses(t, store, "SELECT count(*) FROM big", 2)
	testing.expect_value(t, tc_parses(t, store, "SELECT count(*) FROM big", 2), 0)
	// A view over a view, and the same view twice in one statement.
	tc_parses(t, store, "SELECT count(*) FROM bigger", 1)
	testing.expect_value(t, tc_parses(t, store, "SELECT count(*) FROM bigger", 1), 0)
	both :: "SELECT count(*) FROM big AS p JOIN big AS q ON q.id = p.id"
	tc_parses(t, store, both, 2)
	testing.expect_value(t, tc_parses(t, store, both, 2), 0)
	// The view's table altered: `*` names one more column, which a kept tree
	// resolved before would not see.
	run_done(t, store, "ALTER TABLE a ADD COLUMN y INTEGER DEFAULT 4")
	testing.expect_value(t, scalar(t, store, "SELECT sum(y) FROM big").i, 8)
	testing.expect_value(t, tc_parses(t, store, "SELECT sum(y) FROM big", 8), 0)
	// The view replaced by another of its name.
	run_done(t, store, "DROP VIEW bigger")
	run_done(t, store, "CREATE VIEW bigger AS SELECT id FROM big WHERE x > 4")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM bigger").i, 2)
}

@(test)
test_a_read_on_an_older_catalog_parses_its_own_view :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, x INTEGER)")
	run_done(t, store, "INSERT INTO a VALUES (1, 1), (2, 5), (3, 9)")
	run_done(t, store, "CREATE VIEW v AS SELECT * FROM a")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM v").i, 3)
	reader := db.tx_begin_read(store)
	run_done(t, store, "ALTER TABLE a ADD COLUMN y INTEGER DEFAULT 4")
	// The old read sees the table without y: its view's columns are its own.
	{
		result, run_err := db.sql_execute_in_tx(reader, "SELECT * FROM v WHERE id = 1")
		defer db.sql_result_destroy(&result)
		if testing.expectf(t, db.error_ok(run_err) && len(result.rows) == 1, "old read: %s", run_err.message) {
			testing.expect_value(t, len(result.rows[0]), 2)
		}
		db.error_free(&run_err)
	}
	db.tx_end(reader)
	// What the old read parsed is not what a new one reads.
	testing.expect_value(t, scalar(t, store, "SELECT sum(y) FROM v").i, 12)
	result := run(t, store, "SELECT * FROM v WHERE id = 1")
	defer db.sql_result_destroy(&result)
	if testing.expect(t, len(result.rows) == 1) do testing.expect_value(t, len(result.rows[0]), 3)
}

@(test)
test_a_policy_is_parsed_once_per_catalog :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1, 1), (2, 2), (3, 3)")
	run_done(t, store, "CREATE POLICY big ON t USING (a > 1)")
	tc_parses(t, store, "SELECT count(*) FROM t", 2)
	testing.expect_value(t, tc_parses(t, store, "SELECT count(*) FROM t", 2), 0)
	testing.expect_value(t, tc_parses(t, store, "SELECT count(*) FROM t WHERE id > 0", 2), 1)
	testing.expect_value(t, tc_parses(t, store, "SELECT count(*) FROM t WHERE id > 0", 2), 0)
	// A policy replaced is the one that holds.
	run_done(t, store, "DROP POLICY big")
	run_done(t, store, "CREATE POLICY big ON t USING (a > 2)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, 1)
	testing.expect_value(t, tc_parses(t, store, "SELECT count(*) FROM t", 1), 0)
}
