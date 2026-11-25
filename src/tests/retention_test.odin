package tests

import "core:fmt"
import "core:testing"

import db "../engine"

// Version retention (D3): how much row history a store keeps, and AS OF on every
// table of a join.

// A commit made while a reader held the table writes into a copy of it. The copy
// did not carry the commit's sequence, so the value that commit replaced kept
// "replaced at 0": an AS OF between that commit and the row's next update read
// the old value, and no prune ever dropped it.
@(test)
test_as_of_reads_a_table_copied_for_a_reader :: proc(t: ^testing.T) {
	store, open_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 0), (2, 0)")
	reader := db.tx_begin_read(store)
	run_done(t, store, "UPDATE t SET v = 1 WHERE id = 1")
	middle := store.commit_seq
	run_done(t, store, "UPDATE t SET v = 2 WHERE id = 2")
	db.tx_end(reader)
	testing.expect_value(t, scalar(t, store, fmt.tprintf("SELECT v FROM t AS OF %d WHERE id = 1", middle)).i, i64(1))
	testing.expect_value(t, scalar(t, store, fmt.tprintf("SELECT v FROM t AS OF %d WHERE id = 1", middle - 1)).i, i64(0))
}
