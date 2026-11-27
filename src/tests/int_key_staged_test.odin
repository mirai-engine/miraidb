package tests

import "core:fmt"
import "core:testing"
import "core:time"

import db "../engine"

// An INSERT that leaves an INTEGER PRIMARY KEY out gets one past the largest
// the table holds, the rows the transaction staged included, as SQLite gives
// it. The staged rows' largest is kept as they are appended (Table_Writes): a
// load of n rows walked them at every insert, n²/2 row reads, and 16 000 rows
// in one transaction cost 78 µs an insert instead of 2.

@(private = "file")
ik_exec :: proc(t: ^testing.T, tx: ^db.Tx, sql: string, loc := #caller_location) {
	result, err := db.sql_execute_in_tx(tx, sql)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message, loc = loc)
	db.error_free(&err)
	db.sql_result_destroy(&result)
}

@(private = "file")
ik_last :: proc(t: ^testing.T, tx: ^db.Tx, loc := #caller_location) -> i64 {
	result, err := db.sql_execute_in_tx(tx, "SELECT max(id) FROM t")
	defer db.sql_result_destroy(&result)
	defer db.error_free(&err)
	if !testing.expectf(t, db.error_ok(err) && len(result.rows) == 1, "max: %s", err.message, loc = loc) do return 0
	return result.rows[0][0].i
}

@(test)
test_an_omitted_integer_key_follows_the_staged_rows :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (0)")
	tx := db.tx_begin_write(store)
	for _ in 0 ..< 3 do ik_exec(t, tx, "INSERT INTO t (v) VALUES (1)")
	testing.expect_value(t, ik_last(t, tx), 4)
	// The largest staged row taken out: the next key is one past the rest.
	ik_exec(t, tx, "DELETE FROM t WHERE id = 4")
	ik_exec(t, tx, "INSERT INTO t (v) VALUES (2)")
	testing.expect_value(t, ik_last(t, tx), 4)
	// A key named past the others, then one moved up and one moved down.
	ik_exec(t, tx, "INSERT INTO t (id, v) VALUES (100, 3)")
	ik_exec(t, tx, "INSERT INTO t (v) VALUES (4)")
	testing.expect_value(t, ik_last(t, tx), 101)
	ik_exec(t, tx, "UPDATE t SET id = 7 WHERE id >= 100 AND v = 4")
	ik_exec(t, tx, "UPDATE t SET id = 6 WHERE id = 100")
	ik_exec(t, tx, "INSERT INTO t (v) VALUES (5)")
	testing.expect_value(t, ik_last(t, tx), 8)
	// A statement that fails takes back the rows it staged, and their keys.
	failed, failed_err := db.sql_execute_in_tx(tx, "INSERT INTO t (v) VALUES (6), (7), (NULL)")
	testing.expect(t, !db.error_ok(failed_err), "a NULL in a NOT NULL column fails")
	db.error_free(&failed_err)
	db.sql_result_destroy(&failed)
	ik_exec(t, tx, "INSERT INTO t (v) VALUES (8)")
	testing.expect_value(t, ik_last(t, tx), 9)
	// ROLLBACK TO takes them back as well.
	savepoint_err := db.tx_savepoint(tx, "s")
	testing.expectf(t, db.error_ok(savepoint_err), "savepoint: %s", savepoint_err.message)
	for _ in 0 ..< 5 do ik_exec(t, tx, "INSERT INTO t (v) VALUES (9)")
	testing.expect_value(t, ik_last(t, tx), 14)
	back_err := db.tx_rollback_to_savepoint(tx, "s")
	testing.expectf(t, db.error_ok(back_err), "rollback to: %s", back_err.message)
	ik_exec(t, tx, "INSERT INTO t (v) VALUES (10)")
	testing.expect_value(t, ik_last(t, tx), 10)
	commit_err := db.tx_commit(tx)
	testing.expectf(t, db.error_ok(commit_err), "commit: %s", commit_err.message)
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(id, ',') FROM (SELECT id FROM t ORDER BY id)").s, "1,2,3,4,6,7,8,9,10")
}

// The cost of an insert does not grow with the rows staged before it: 16 times
// the rows cost about 16 times the time, where walking them cost 16² (13
// times the time per row, measured). The bound leaves room for a slow
// machine; a walk per insert is far past it.
@(test)
test_a_load_that_leaves_the_key_out_costs_the_same_per_row :: proc(t: ^testing.T) {
	per_row :: proc(t: ^testing.T, rows: int) -> f64 {
		store, err := db.store_open("", {persistent = false})
		if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return 0
		defer db.store_close(store)
		run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
		prepared, prepare_err := db.sql_prepare(store, "INSERT INTO t (v) VALUES (1)")
		if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return 0
		defer db.stmt_prepared_destroy(prepared)
		tx := db.tx_begin_write(store)
		start := time.now()
		for _ in 0 ..< rows {
			result, run_err := db.prepared_execute_in_tx(tx, prepared, nil)
			db.sql_result_destroy(&result)
			db.error_free(&run_err)
		}
		elapsed := time.duration_nanoseconds(time.since(start))
		commit_err := db.tx_commit(tx)
		testing.expectf(t, db.error_ok(commit_err), "commit: %s", commit_err.message)
		testing.expect_value(t, scalar(t, store, "SELECT max(id) FROM t").i, i64(rows))
		return f64(elapsed) / f64(rows)
	}
	small := per_row(t, 1000)
	large := per_row(t, 16000)
	testing.expectf(t, large < small * 4, "%s per row at 1000 rows, %s at 16000",
		fmt.tprintf("%.0f ns", small), fmt.tprintf("%.0f ns", large))
}
