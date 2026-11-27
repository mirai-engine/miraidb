package tests

import "core:strings"
import "core:testing"
import "core:time"

import db "../engine"

// One statement has one now, however many rows it reads or writes and however
// many contexts it makes (one per row on some paths): `now()`, the date
// functions' 'now', a column's DEFAULT and the triggers it fires all see the
// time of the statement, as SQLite fixes it per statement. The next statement
// has its own, inside a transaction too. Every context is made by
// eval_context, which takes the time from the statement; each used to read the
// clock, so a statement over many rows saw many times.

@(private = "file")
ST_ROWS :: 5000

@(private = "file")
st_store :: proc(t: ^testing.T) -> ^db.Store {
	store, err := db.store_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	run_done(t, store, "CREATE TABLE n (i INTEGER PRIMARY KEY)")
	run_done(t, store, "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 5000) INSERT INTO n SELECT i FROM s")
	return store
}

@(test)
test_a_statement_has_one_now :: proc(t: ^testing.T) {
	store := st_store(t)
	defer db.store_close(store)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM n").i, i64(ST_ROWS))
	// Per row of a scan, through a function the WHERE calls and the projection.
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT now()) FROM n WHERE now() IS NOT NULL").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT julianday('now')) FROM n").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT strftime('%Y-%m-%d %H:%M:%f', 'now')) FROM n").i, i64(1))
	// A column's DEFAULT, filled once per inserted row, and a trigger fired per
	// row: the same instant.
	run_done(t, store, "CREATE TABLE stamped (i INTEGER, at TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now')))")
	run_done(t, store, "CREATE TABLE fired (i INTEGER, at TEXT)")
	run_done(t, store, "CREATE TRIGGER stamp AFTER INSERT ON stamped BEGIN INSERT INTO fired VALUES (new.i, strftime('%Y-%m-%d %H:%M:%f', 'now')); END")
	run_done(t, store, "INSERT INTO stamped (i) SELECT i FROM n")
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT at) FROM stamped").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT at) FROM fired").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT (SELECT min(at) FROM stamped) = (SELECT min(at) FROM fired)").i, i64(1))
	// An UPDATE over every row writes one time.
	run_done(t, store, "UPDATE stamped SET at = strftime('%Y-%m-%d %H:%M:%f', 'now')")
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT at) FROM stamped").i, i64(1))
}

@(test)
test_each_statement_of_a_transaction_has_its_own_now :: proc(t: ^testing.T) {
	store := st_store(t)
	defer db.store_close(store)
	tx := db.tx_begin_write(store)
	now_of :: proc(t: ^testing.T, tx: ^db.Tx) -> string {
		result, err := db.sql_execute_in_tx(tx, "SELECT strftime('%Y-%m-%d %H:%M:%f', 'now')")
		defer db.sql_result_destroy(&result)
		defer db.error_free(&err)
		if !testing.expect(t, db.error_ok(err) && len(result.rows) == 1) do return ""
		// The result is freed on the way out: the text is kept.
		return strings.clone(result.rows[0][0].s, context.temp_allocator)
	}
	first := now_of(t, tx)
	time.sleep(5 * time.Millisecond)
	second := now_of(t, tx)
	db.tx_rollback(tx)
	testing.expectf(t, first != second, "two statements, one time: %s / %s", first, second)
}
