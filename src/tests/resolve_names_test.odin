package tests

import "core:testing"

import db "../engine"

// Under SQLite's rules the resolution rewrites a table's name to its stored
// spelling inside the tree, joins and subqueries included. A tree that runs
// again (a prepared statement, a query the store keeps by its text) keeps that
// name, so it must live as long as the tree: in the transaction's arena it was
// freed at the end of the first run, and a later run read whatever reused the
// memory ("no such table: " and garbage).
@(test)
test_a_tree_run_again_keeps_the_names_its_resolution_wrote :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	store.sqlite_names = true
	store.sqlite_rules = true
	run_done(t, store, "CREATE TABLE Alpha (id INTEGER PRIMARY KEY, b INTEGER)")
	run_done(t, store, "CREATE TABLE Beta (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "INSERT INTO Alpha VALUES (1, 10), (2, 20), (3, 30)")
	run_done(t, store, "INSERT INTO Beta VALUES (10, 'ten'), (20, 'twenty'), (30, 'thirty')")
	// Spelled in another case than stored, in a join and in a subquery.
	query := "SELECT group_concat(v, ',') FROM (SELECT beta.v AS v FROM alpha JOIN BETA ON beta.id = alpha.b WHERE alpha.id IN (SELECT id FROM ALPHA WHERE id < 3) ORDER BY alpha.id)"
	prepared, prepare_err := db.sql_prepare(store, query)
	if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return
	defer db.stmt_prepared_destroy(prepared)
	for round in 0 ..< 6 {
		testing.expect_value(t, scalar(t, store, query).s, "ten,twenty")
		result, run_err := db.prepared_execute(store, prepared, nil)
		if testing.expectf(t, db.error_ok(run_err) && len(result.rows) == 1, "prepared, round %d: %s", round, run_err.message) {
			testing.expect_value(t, result.rows[0][0].s, "ten,twenty")
		}
		db.sql_result_destroy(&result)
		db.error_free(&run_err)
		// Other statements take the arenas the run gave back and write over them.
		run_done(t, store, "SELECT 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' || Alpha.id, 'yyyyyyyyyyyyyyyyyyyyyyyyyyyy' FROM Alpha JOIN Beta ON Beta.id = Alpha.b")
		run_done(t, store, "INSERT INTO Beta VALUES (100 + 0, 'zzzzzzzzzzzzzzzzzzzzzzzzzzzz') ON CONFLICT (id) DO UPDATE SET v = 'zzzzzzzzzzzzzzzzzzzzzzzzzz'")
	}
}
