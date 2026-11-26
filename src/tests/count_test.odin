package tests

import "core:testing"

import db "../engine"

// `SELECT count(*) FROM t` counts the rows the transaction sees without
// reading them (as SQLite's OP_Count): the deleted rows a prune has not taken
// yet do not count, a reader counts its own snapshot, and a transaction that
// staged rows for the table counts them through the usual path.

@(private = "file")
count_in :: proc(t: ^testing.T, tx: ^db.Tx, sql: string, loc := #caller_location) -> i64 {
	result, err := db.sql_execute_in_tx(tx, sql)
	defer db.sql_result_destroy(&result)
	defer db.error_free(&err)
	if !testing.expectf(t, db.error_ok(err) && len(result.rows) == 1, "%s: %s", sql, err.message, loc = loc) do return -1
	return result.rows[0][0].i
}

@(test)
test_count_star_counts_the_rows_a_transaction_sees :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 10) INSERT INTO c SELECT i, 'v' || i FROM s")
	run_done(t, store, "DELETE FROM c WHERE id <= 3")
	// The deleted rows are still kept, for readers before the delete.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM c").i, i64(7))
	// The same answer the scan gives, which the WHERE makes it take.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM c WHERE 1").i, i64(7))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) AS n FROM c").i, i64(7))

	// A reader keeps counting its snapshot while a writer deletes.
	reader := db.tx_begin_read(store)
	run_done(t, store, "DELETE FROM c WHERE id <= 5")
	testing.expect_value(t, count_in(t, reader, "SELECT count(*) FROM c"), i64(7))
	db.tx_end(reader)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM c").i, i64(5))

	// A transaction counts what it staged.
	tx := db.tx_begin_write(store)
	inserted, insert_err := db.sql_execute_in_tx(tx, "INSERT INTO c VALUES (100, 'x'), (101, 'y')")
	db.sql_result_destroy(&inserted)
	testing.expect(t, db.error_ok(insert_err))
	testing.expect_value(t, count_in(t, tx, "SELECT count(*) FROM c"), i64(7))
	deleted, delete_err := db.sql_execute_in_tx(tx, "DELETE FROM c WHERE id = 10")
	db.sql_result_destroy(&deleted)
	testing.expect(t, db.error_ok(delete_err))
	testing.expect_value(t, count_in(t, tx, "SELECT count(*) FROM c"), i64(6))
	db.tx_rollback(tx)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM c").i, i64(5))

	// The column is named as the usual path names it (the WHERE sends the
	// statement there).
	named := run(t, store, "SELECT count(*) FROM c")
	defer db.sql_result_destroy(&named)
	usual := run(t, store, "SELECT count(*) FROM c WHERE 1")
	defer db.sql_result_destroy(&usual)
	if testing.expect(t, len(named.columns) == 1 && len(usual.columns) == 1) {
		testing.expect_value(t, named.columns[0], usual.columns[0])
	}
}

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
