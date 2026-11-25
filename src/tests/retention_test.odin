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

// AS OF names a commit for each table of a join, not only the first.
@(test)
test_as_of_on_a_join :: proc(t: ^testing.T) {
	store, open_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER, qty INTEGER)")
	run_done(t, store, "CREATE INDEX b_a ON b (a_id)")
	run_done(t, store, "INSERT INTO a VALUES (1, 'one'), (2, 'two')")
	run_done(t, store, "INSERT INTO b VALUES (10, 1, 5), (20, 2, 7)")
	before := store.commit_seq
	run_done(t, store, "UPDATE a SET name = 'ONE' WHERE id = 1")
	run_done(t, store, "UPDATE b SET qty = 50 WHERE id = 10")
	run_done(t, store, "DELETE FROM b WHERE id = 20")
	now := fmt.tprintf("SELECT group_concat(a.name || ':' || b.qty, ',') FROM a JOIN b ON b.a_id = a.id")
	testing.expect_value(t, scalar(t, store, now).s, "ONE:50")
	both := fmt.tprintf("SELECT group_concat(a.name || ':' || b.qty, ',') FROM a AS OF %d JOIN b AS OF %d ON b.a_id = a.id", before, before)
	testing.expect_value(t, scalar(t, store, both).s, "one:5,two:7")
	// The second table alone at the old commit: the index probe would read the
	// live keys, so the historical side is scanned.
	inner := fmt.tprintf("SELECT group_concat(a.name || ':' || b.qty, ',') FROM a JOIN b AS OF %d ON b.a_id = a.id", before)
	testing.expect_value(t, scalar(t, store, inner).s, "ONE:5,two:7")
}
