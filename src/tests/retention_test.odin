package tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"

import db "../engine"
import face "../sqlite_compat"

// Version retention (D3): how much row history a store keeps, and AS OF on every
// table of a join.

@(private = "file")
retention_versions :: proc(store: ^db.Store, name: string) -> int {
	table, found := store.tables[name]
	if !found do return -1
	count := 0
	row_rows := db.rows_iter(&table.rows)
	for row in db.rows_next(&row_rows) do count += len(row.versions)
	return count
}

// Through the sqlite3_* facade a database keeps the history a pinned read needs
// and no more: 100 000 updates leave no superseded value behind. It used to keep
// every value it replaced, a database that only grew.
@(test)
test_the_facade_keeps_no_history_nobody_reads :: proc(t: ^testing.T) {
	handle: rawptr
	if !testing.expect_value(t, face.sqlite3_open(":memory:", &handle), face.SQLITE_OK) do return
	defer face.sqlite3_close(handle)
	setup: cstring = "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER); INSERT INTO t (v) SELECT 0 FROM generate_series(1, 10)"
	if !testing.expect_value(t, face.sqlite3_exec(handle, setup, nil, nil, nil), face.SQLITE_OK) do return
	stmt: rawptr
	if !testing.expect_value(t, face.sqlite3_prepare_v2(handle, "UPDATE t SET v = v + 1 WHERE id = ?", -1, &stmt, nil), face.SQLITE_OK) do return
	defer face.sqlite3_finalize(stmt)
	for i in 0 ..< 100_000 {
		face.sqlite3_bind_int(stmt, 1, i32(i % 10 + 1))
		if !testing.expect_value(t, face.sqlite3_step(stmt), face.SQLITE_DONE) do return
		face.sqlite3_reset(stmt)
	}
	store := (^face.Database)(handle).conn.store
	testing.expect_value(t, retention_versions(store, "t"), 0)
	testing.expect_value(t, db.store_retention(store).kind, db.Retention_Kind.Readers)
}

// A store that keeps the last N commits answers an AS OF inside them, prunes
// what is older, and a store that keeps everything keeps every version.
@(test)
test_retention_keeps_its_window :: proc(t: ^testing.T) {
	store, open_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 0)")
	for i in 1 ..= 20 do run_done(t, store, fmt.tprintf("UPDATE t SET v = %d WHERE id = 1", i))
	testing.expect_value(t, retention_versions(store, "t"), 20)

	run_done(t, store, "PRAGMA history_retention = 'commits=3'")
	testing.expect_value(t, scalar(t, store, "PRAGMA history_retention").s, "commits=3")
	for i in 21 ..= 30 do run_done(t, store, fmt.tprintf("UPDATE t SET v = %d WHERE id = 1", i))
	// Three commits back still reads what it read.
	testing.expect_value(t, scalar(t, store, fmt.tprintf("SELECT v FROM t AS OF %d", store.commit_seq - 3)).i, i64(27))
	testing.expect_value(t, scalar(t, store, fmt.tprintf("SELECT v FROM t AS OF %d", store.commit_seq - 1)).i, i64(29))
	testing.expectf(t, retention_versions(store, "t") <= 4, "%d versions kept for a window of 3", retention_versions(store, "t"))

	run_done(t, store, "PRAGMA history_retention = readers")
	run_done(t, store, "UPDATE t SET v = 31 WHERE id = 1")
	testing.expect_value(t, retention_versions(store, "t"), 0)

	_, bad_err := db.sql_execute(store, "PRAGMA history_retention = 'weeks=2'")
	defer db.error_free(&bad_err)
	testing.expect_value(t, bad_err.kind, db.Error_Kind.Invalid_Argument)
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

// A read still open keeps the rows it reads while the retention prunes after
// every commit; once it ends, the next commit drops the history it no longer
// needs.
@(test)
test_retention_waits_for_an_open_read :: proc(t: ^testing.T) {
	store, open_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)
	db.store_set_retention(store, {kind = .Readers})
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 0), (2, 0)")
	reader := db.tx_begin_read(store)
	for i in 1 ..= 10 do run_done(t, store, fmt.tprintf("UPDATE t SET v = %d", i))
	result, err := db.sql_execute_in_tx(reader, "SELECT sum(v) FROM t")
	testing.expectf(t, db.error_ok(err), "read: %s", err.message)
	if db.error_ok(err) do testing.expect_value(t, result.rows[0][0].i, i64(0))
	db.sql_result_destroy(&result)
	db.error_free(&err)
	db.tx_end(reader)
	testing.expect_value(t, scalar(t, store, "SELECT sum(v) FROM t").i, i64(20))
	run_done(t, store, "UPDATE t SET v = 11 WHERE id = 1")
	testing.expect_value(t, retention_versions(store, "t"), 0)
}

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

// Poison_Allocator overwrites a block as it is freed, so a read of freed memory
// reads 0xdd instead of what was there: a use-after-free that a quiet heap
// would answer correctly fails the test every time.
@(private = "file")
Poison_Allocator :: struct {
	backing: mem.Allocator,
	sizes:   map[rawptr]int,
	mutex:   sync.Mutex,
}

@(private = "file")
poison_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	p := (^Poison_Allocator)(data)
	sync.lock(&p.mutex)
	defer sync.unlock(&p.mutex)
	#partial switch mode {
	case .Free:
		if old_memory != nil {
			if known, ok := p.sizes[old_memory]; ok {
				mem.set(old_memory, 0xdd, known)
				delete_key(&p.sizes, old_memory)
			}
		}
	case .Resize, .Resize_Non_Zeroed:
		if old_memory != nil do delete_key(&p.sizes, old_memory)
	}
	out, err := p.backing.procedure(p.backing.data, mode, size, alignment, old_memory, old_size, loc)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if err == nil && out != nil do p.sizes[raw_data(out)] = len(out)
	}
	return out, err
}

// A commit while a reader is open writes a copy of the table that borrows the
// reader's values; the update moves them into the copy's history, and the
// retention prunes that history after the commit. Nothing pins the reader's
// sequence, so the prune freed the values the reader was still reading: its
// next statement read freed memory. They wait for the reader now.
@(test)
test_a_prune_leaves_a_reader_its_values :: proc(t: ^testing.T) {
	poison := Poison_Allocator{backing = context.allocator}
	poison.sizes = make(map[rawptr]int, 0, context.allocator)
	defer delete(poison.sizes)
	context.allocator = mem.Allocator{procedure = poison_proc, data = &poison}

	store, open_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)
	db.store_set_retention(store, {kind = .Readers})
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 'first row as the reader saw it'), (2, 'second row as the reader saw it'), (3, 'gone')")
	reader := db.tx_begin_read(store)
	run_done(t, store, "UPDATE t SET v = 'changed once' WHERE id = 1")
	run_done(t, store, "DELETE FROM t WHERE id = 3")
	for i in 1 ..= 20 do run_done(t, store, fmt.tprintf("UPDATE t SET v = 'changed %d'", i))
	// What the writer stored after the copy is its own, and goes on being freed.
	if testing.expect(t, store.tables["t"].store != nil) {
		testing.expect(t, len(store.tables["t"].store.pending) <= 3)
	}
	result, err := db.sql_execute_in_tx(reader, "SELECT group_concat(v, '|') FROM t")
	if testing.expectf(t, db.error_ok(err), "read: %s", err.message) {
		testing.expectf(t, strings.compare(result.rows[0][0].s, "first row as the reader saw it|second row as the reader saw it|gone") == 0, "the reader read %q", result.rows[0][0].s)
	}
	db.sql_result_destroy(&result)
	db.error_free(&err)
	db.tx_end(reader)
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(v, '|') FROM t").s, "changed 20|changed 20")
	run_done(t, store, "UPDATE t SET v = 'after' WHERE id = 1")
	testing.expect_value(t, retention_versions(store, "t"), 0)
}
