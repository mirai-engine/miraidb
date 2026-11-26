package tests

import "core:testing"

import db "../engine"

// A query's text run again is not parsed again; the names are resolved at each
// run, so the same text follows the schema and its parameters.
@(test)
test_a_query_run_again_follows_the_schema :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE q (a INTEGER, b TEXT)")
	run_done(t, store, "INSERT INTO q VALUES (1, 'one'), (2, 'two')")
	star := "SELECT * FROM q ORDER BY a"
	first := run(t, store, star)
	testing.expect_value(t, len(first.columns), 2)
	db.sql_result_destroy(&first)
	// A column more: the same text answers it.
	run_done(t, store, "ALTER TABLE q ADD COLUMN c INTEGER DEFAULT 7")
	second := run(t, store, star)
	testing.expect_value(t, len(second.columns), 3)
	if testing.expect(t, len(second.rows) == 2 && len(second.rows[0]) == 3) do testing.expect_value(t, second.rows[0][2].i, i64(7))
	db.sql_result_destroy(&second)
	// Another table under the name.
	run_done(t, store, "DROP TABLE q")
	run_done(t, store, "CREATE TABLE q (a INTEGER)")
	run_done(t, store, "INSERT INTO q VALUES (5)")
	third := run(t, store, star)
	testing.expect_value(t, len(third.columns), 1)
	if testing.expect(t, len(third.rows) == 1) do testing.expect_value(t, third.rows[0][0].i, i64(5))
	db.sql_result_destroy(&third)
	// Parameters are the run's own.
	run_done(t, store, "INSERT INTO q VALUES (6), (7)")
	for want in ([]i64{5, 6, 7}) {
		result, run_err := db.sql_execute_params(store, "SELECT a FROM q WHERE a = ?", []db.Value{db.value_int(want)})
		testing.expectf(t, db.error_ok(run_err) && len(result.rows) == 1 && result.rows[0][0].i == want, "a = %d", want)
		db.sql_result_destroy(&result)
		db.error_free(&run_err)
	}
}
