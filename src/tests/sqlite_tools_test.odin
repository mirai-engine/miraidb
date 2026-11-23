package tests

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import db "../engine"

// What SQLite's own tools (sqldiff, dbhash, mptest) found the engine answering
// differently, each checked here where the engine can answer it on its own;
// scripts/sqlite_tools.py runs the tools themselves through the facade.

@(private = "file")
tools_store :: proc(t: ^testing.T) -> ^db.Store {
	store, err := db.store_open("", {persistent = false})
	testing.expect(t, db.error_ok(err))
	store.sqlite_names = true
	store.sqlite_rules = true
	store.foreign_keys_off = true
	store.host_access = true
	return store
}

@(private = "file")
tools_ok :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
}

// tools_rows answers every row as its columns' text joined by `|`, the rows
// joined by a space: what SQLite's shell prints, on one line.
@(private = "file")
tools_rows :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	stmt := db.embed_prepare(conn, sql)
	if !testing.expectf(t, stmt != nil, "prepare %s: %s", sql, db.embed_error(conn)) do return ""
	defer db.embed_finalize(stmt)
	first := true
	for {
		has_row, err := db.embed_step(stmt)
		if !testing.expectf(t, db.error_ok(err), "step %s: %s", sql, err.message) {
			db.error_free(&err)
			break
		}
		if !has_row do break
		if !first do strings.write_byte(&out, ' ')
		first = false
		for i in 0 ..< db.embed_column_count(stmt) {
			if i > 0 do strings.write_byte(&out, '|')
			// Each value as SQLite turns it into text; NULL is empty.
			if value, ok := db.embed_column_value(stmt, i); ok && value.kind != .Null {
				strings.write_string(&out, db.sqlite_value_text(value, context.temp_allocator))
			}
		}
	}
	return strings.to_string(out)
}

@(private = "file")
tools_expect :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, want: string) {
	got := tools_rows(t, conn, sql)
	testing.expectf(t, got == want, "%s: got %q, want %q", sql, got, want)
}

@(test)
test_sum_and_total_add_as_sqlite :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	// A comparison is an integer to sum(), a text its number, and total() is
	// always a real, 0.0 over no rows, and never overflows (sqldiff --summary
	// sums `A.x IS NOT B.x`).
	tools_expect(t, conn, "SELECT sum(1 IS NOT 2), sum('3'), sum('x'), total('2.5'), avg('4')", "1|3|0.0|2.5|4.0")
	tools_ok(t, conn, "CREATE TABLE n (x)")
	tools_expect(t, conn, "SELECT total(x), typeof(total(x)), sum(x) FROM n", "0.0|real|")
	tools_ok(t, conn, "INSERT INTO n VALUES (9223372036854775807), (1)")
	tools_expect(t, conn, "SELECT total(x), typeof(total(1)) FROM n", "9.2233720368547758e+18|real")
	tools_expect(t, conn, "SELECT typeof(sum('9223372036854775808')), sum(' 7 ')", "real|7")
}

@(test)
test_distinct_compounds_come_out_in_index_order :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	// SQLite answers UNION, INTERSECT and EXCEPT from its temporary index:
	// NULL, numbers, texts by the first COLLATE any term writes, then blobs.
	tools_expect(t, conn, "SELECT 3 UNION SELECT 'b' UNION SELECT NULL UNION SELECT 1 UNION SELECT x'00' UNION SELECT 2.5", " 1 2.5 3 b \x00")
	tools_expect(t, conn, "SELECT 3 UNION SELECT 1 UNION ALL SELECT 0", "1 3 0")
	tools_expect(t, conn, "SELECT 'B' UNION SELECT 'a' COLLATE nocase", "a B")
	// Two columns of one name pass through the table an ORDER BY sorts.
	tools_expect(t, conn, "SELECT NULL, NULL UNION ALL SELECT 2, 1 ORDER BY 2", "| 2|1")
}

@(test)
test_strftime_knows_every_sqlite_code :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	at := "'2024-02-29 12:30:05.5'"
	tools_expect(t, conn, strings.concatenate({"SELECT strftime('%f|%e|%I|%l|%k|%p|%P|%R|%u|%U|%W|%V|%G|%g|%j|%J', ", at, ")"}, context.temp_allocator),
		"05.500|29|12|12|12|PM|pm|12:30|4|08|09|09|2024|24|060|2460370.020896991")
	// An unknown code makes the answer NULL; a number in a text is a day.
	tools_expect(t, conn, "SELECT strftime('%Q', 'now') IS NULL, strftime('%Y', '2461001.75')", "1|2025")
	// A time is read in whole milliseconds and never rounded into the next
	// second (or day): this used to answer 0001-01-2021.
	tools_expect(t, conn, "SELECT datetime('2020-12-31 23:59:59.999'), time('12:00:00.7')", "2020-12-31 23:59:59|12:00:00")
}

@(test)
test_a_dropped_table_lets_its_names_go_in_the_transaction :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE c (id INTEGER PRIMARY KEY, v)")
	tools_ok(t, conn, "CREATE INDEX cv ON c (v)")
	tools_ok(t, conn, "INSERT INTO c VALUES (1, 0)")
	// What reading a file another process wrote does: drop everything, make
	// it again, in one transaction. The old key and the old index are gone.
	tools_ok(t, conn, "BEGIN")
	tools_ok(t, conn, "DROP TABLE c")
	tools_ok(t, conn, "CREATE TABLE c (id INTEGER PRIMARY KEY, v)")
	tools_ok(t, conn, "INSERT INTO c VALUES (1, 5)")
	tools_ok(t, conn, "CREATE INDEX cv ON c (v)")
	tools_ok(t, conn, "COMMIT")
	tools_expect(t, conn, "SELECT id, v FROM c", "1|5")
	tools_expect(t, conn, "SELECT name FROM sqlite_schema WHERE type = 'index'", "cv")
}

@(test)
test_queries_sqldiff_writes :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE n (q, r)")
	tools_ok(t, conn, "INSERT INTO n VALUES (1, 2), (3, 4)")
	// An enclosing query's alias.rowid, read from a correlated subquery.
	tools_expect(t, conn, "SELECT count(*) FROM n A WHERE EXISTS (SELECT 1 FROM n B WHERE A.rowid = B.rowid)", "2")
	tools_expect(t, conn, "SELECT (SELECT A.oid + 0) FROM n A", "1 2")
	// A database attached to the connection: its catalog, its pragmas, and a
	// WHERE naming a select-list alias over its tables.
	tools_ok(t, conn, "ATTACH ':memory:' AS aux")
	tools_ok(t, conn, "CREATE TABLE aux.w (k TEXT PRIMARY KEY, v) WITHOUT ROWID")
	tools_ok(t, conn, "INSERT INTO aux.w VALUES ('a', 1), ('b', 2)")
	tools_expect(t, conn, "SELECT name FROM aux.sqlite_schema WHERE type = 'table'", "w")
	tools_expect(t, conn, "SELECT n.v || 'x' AS c FROM aux.w AS n WHERE c LIKE '2%'", "2x")
	tools_expect(t, conn, "PRAGMA aux.index_list = w", "0|sqlite_autoindex_w_1|1|pk|0")
	tools_expect(t, conn, "PRAGMA aux.index_xinfo = 'sqlite_autoindex_w_1'", "0|0|k|0|BINARY|1 1|1|v|0|BINARY|0")
}

@(test)
test_index_xinfo_lists_what_an_entry_holds :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE p (a INTEGER PRIMARY KEY, b TEXT COLLATE nocase UNIQUE, c, d, UNIQUE (c, d))")
	tools_ok(t, conn, "CREATE INDEX pe ON p (lower(b), d)")
	tools_ok(t, conn, "CREATE TABLE q (x, y, z, PRIMARY KEY (y, x)) WITHOUT ROWID")
	tools_ok(t, conn, "CREATE INDEX qz ON q (z, x)")
	// A rowid table's entry ends with the rowid; an expression is cid -2.
	tools_expect(t, conn, "PRAGMA index_xinfo(sqlite_autoindex_p_1)", "0|1|b|0|nocase|1 1|-1||0|BINARY|0")
	tools_expect(t, conn, "PRAGMA index_info(pe)", "0|-2| 1|3|d")
	// Without a rowid, the primary key's own index carries every other
	// column, and another index the key columns it leaves out.
	tools_expect(t, conn, "PRAGMA index_xinfo(sqlite_autoindex_q_1)", "0|1|y|0|BINARY|1 1|0|x|0|BINARY|1 2|2|z|0|BINARY|0")
	tools_expect(t, conn, "PRAGMA index_xinfo(qz)", "0|2|z|0|BINARY|1 1|0|x|0|BINARY|1 2|1|y|0|BINARY|0")
}

@(test)
test_reals_take_sqlite_s_text :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	// quote() writes %!0.17g; a literal past a double's range is infinity.
	tools_expect(t, conn, "SELECT quote(0.1), quote(1.0 / 3), quote(1e300), quote(9e999), 1e-400", "0.1|0.33333333333333332|1.0e+300|9.0e+999|0.0")
	// A REAL column keeps -0.0 as 0.0, as SQLite's record does; a column
	// without a type keeps the sign.
	tools_ok(t, conn, "CREATE TABLE z (r REAL, n)")
	tools_ok(t, conn, "INSERT INTO z VALUES (-0.0, -0.0)")
	tools_expect(t, conn, "SELECT quote(r), atan2(r, -1) > 0, atan2(n, -1) < 0 FROM z", "0.0|1|1")
	// SQL's printf is SQLite's, the one sqlite3_mprintf answers with.
	tools_expect(t, conn, "SELECT printf('%.*c|%Q|%,d|%r', 3, 'x', NULL, 1234567, 3)", "xxx|NULL|1,234,567|3rd")
}

@(test)
test_the_mirror_keeps_its_header_when_a_root_splits :: proc(t: ^testing.T) {
	path := "_test_tools_mirror.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	conn, open_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	tools_ok(t, conn, "CREATE TABLE x (q)")
	tools_ok(t, conn, "INSERT INTO x VALUES (1)")
	tools_ok(t, conn, "CREATE TABLE t1 (a INTEGER PRIMARY KEY, b)")
	// Two rows that need two leaves: the root splits, and the new root's row
	// in sqlite_master rewrites page 1, which used to lose the file header.
	tools_ok(t, conn, "INSERT INTO t1 VALUES (1, zeroblob(3000))")
	tools_ok(t, conn, "INSERT INTO t1 VALUES (2, zeroblob(3000))")
	// Rows past a page keep their overflow chains through later rewrites.
	tools_ok(t, conn, "INSERT INTO t1 VALUES (3, zeroblob(9000)), (4, zeroblob(20000))")
	tools_ok(t, conn, "UPDATE t1 SET b = zeroblob(7000) WHERE a = 2")
	tools_ok(t, conn, "DELETE FROM t1 WHERE a = 1")
	db.embed_close(conn)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil && len(data) > 16 && string(data[:15]) == "SQLite format 3")
	ok, reason := db.sqlite_mirror_validate(path, context.temp_allocator)
	testing.expectf(t, ok, "the file is malformed: %s", reason)
	again, again_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(again_err), "reopen: %s", again_err.message) do return
	defer db.embed_close(again)
	tools_expect(t, again, "SELECT a, length(b) FROM t1", "2|7000 3|9000 4|20000")
}

// Guard_Allocator gives every block pages of its own and hands them back to
// the system when the block is freed or moved, so a pointer kept into a dynamic
// array across an append faults at once instead of, now and then, when the heap
// happened to return that memory.
@(private = "file")
Guard_Allocator :: struct {
	sizes:   map[rawptr]int,
	backing: mem.Allocator,
}

@(private = "file")
guard_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	guard := (^Guard_Allocator)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		block, err := virtual.reserve_and_commit(uint(max(size, 1)))
		if err != nil do return nil, err
		guard.sizes[raw_data(block)] = max(size, 1)
		return block[:size], nil
	case .Free:
		if old_memory == nil do return nil, nil
		held, ok := guard.sizes[old_memory]
		// A block made before the guard was in place goes back where it came from.
		if !ok do return guard.backing.procedure(guard.backing.data, mode, size, alignment, old_memory, old_size, loc)
		delete_key(&guard.sizes, old_memory)
		virtual.release(old_memory, uint(held))
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		fresh, err := guard_allocator_proc(data, .Alloc, size, alignment, nil, 0, loc)
		if err != nil || old_memory == nil do return fresh, err
		copy(fresh, ([^]byte)(old_memory)[:min(old_size, size)])
		_, _ = guard_allocator_proc(data, .Free, 0, 0, old_memory, old_size, loc)
		return fresh, nil
	case .Free_All, .Query_Features, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

@(test)
test_a_leaf_split_into_many_pages_keeps_its_page :: proc(t: ^testing.T) {
	// mptest's multiwrite01: 32 rows of 1500 bytes added to a table in one
	// commit split its last leaf into many pages. The split kept a pointer to
	// the leaf in the list it was growing and read through it after the list
	// moved: now and then that memory was gone, and the client died with an
	// access violation while it held the file's EXCLUSIVE lock.
	path := "_test_tools_split.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	guard := Guard_Allocator{sizes = make(map[rawptr]int), backing = context.allocator}
	defer delete(guard.sizes)
	conn, open_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	tools_ok(t, conn, "CREATE TABLE t1 (a INTEGER PRIMARY KEY, b)")
	tools_ok(t, conn, "INSERT INTO t1 VALUES (1, zeroblob(2000))")
	tools_ok(t, conn, "INSERT INTO t1 VALUES (2, zeroblob(1000))")
	for step in ([]string{"2", "4", "8", "16", "32"}) {
		// Read again before each, as another process's commit makes a client
		// read the file again: the leaf list is then built to its size, so the
		// split's inserts move it. The layout is read with the guard (an open
		// reads it with the process's heap).
		db.embed_close(conn)
		conn, open_err = db.embed_open(path)
		if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
		{
			context.allocator = mem.Allocator{procedure = guard_allocator_proc, data = &guard}
			db.store_set_sqlite_mirror(conn.store, path)
		}
		// The path the store keeps is the heap's again; only the layout is the guard's.
		kept := conn.store.sqlite_mirror
		conn.store.sqlite_mirror = strings.clone(kept)
		delete(kept, mem.Allocator{procedure = guard_allocator_proc, data = &guard})
		tools_ok(t, conn, strings.concatenate({"INSERT INTO t1 SELECT a + ", step, ", zeroblob(1500) FROM t1"}, context.temp_allocator))
		// The commit patched the file's pages: the split is the path under test.
		testing.expectf(t, conn.store.mirror_full_writes == 0, "a + %s rewrote the file: %s", step, conn.store.mirror_reason)
	}
	tools_expect(t, conn, "SELECT count(*), sum(length(b)) FROM t1", "64|96000")
	db.embed_close(conn)
	ok, reason := db.sqlite_mirror_validate(path, context.temp_allocator)
	testing.expectf(t, ok, "the file is malformed: %s", reason)
	again, again_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(again_err), "reopen: %s", again_err.message) do return
	defer db.embed_close(again)
	tools_expect(t, again, "SELECT count(*), sum(length(b)) FROM t1", "64|96000")
}

@(private = "file")
count_rows :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
	conn := (^db.Embed_Conn)(user)
	stmt := db.embed_prepare(conn, "SELECT count(*) FROM t")
	if stmt == nil do return db.value_null(), db.errf(.Internal, "prepare failed")
	defer db.embed_finalize(stmt)
	has_row, err := db.embed_step(stmt)
	if !db.error_ok(err) || !has_row do return db.value_null(), err
	return db.value_int(db.embed_column_int(stmt, 0)), db.ERROR_NONE
}

@(test)
test_a_function_may_run_sql_inside_a_write_to_a_shared_file :: proc(t: ^testing.T) {
	path := "_test_tools_eval.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	conn, open_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE t (x)")
	tools_ok(t, conn, "INSERT INTO t VALUES (1)")
	testing.expect(t, db.error_ok(db.store_register_function(conn.store, "rows_now", 0, count_rows, rawptr(conn))))
	// mptest's eval('PRAGMA page_size') inside an INSERT: the function's
	// statement used to wait for the file lock its own INSERT held.
	tools_ok(t, conn, "INSERT INTO t VALUES (rows_now())")
	tools_expect(t, conn, "SELECT x FROM t", "1 1")
}

@(test)
test_a_step_that_met_busy_runs_again :: proc(t: ^testing.T) {
	path := "_test_tools_busy.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	first, first_err := db.embed_open(path)
	if !testing.expect(t, db.error_ok(first_err)) do return
	defer db.embed_close(first)
	second, second_err := db.embed_open(path)
	if !testing.expect(t, db.error_ok(second_err)) do return
	defer db.embed_close(second)
	tools_ok(t, first, "CREATE TABLE c (n)")
	tools_ok(t, first, "BEGIN")
	tools_ok(t, first, "INSERT INTO c VALUES (1)")
	stmt := db.embed_prepare(second, "INSERT INTO c VALUES (2)")
	if !testing.expect(t, stmt != nil) do return
	defer db.embed_finalize(stmt)
	_, busy := db.embed_step(stmt)
	testing.expect_value(t, busy.kind, db.Error_Kind.Locked)
	db.error_free(&busy)
	tools_ok(t, first, "COMMIT")
	// The same statement, stepped again, runs: it used to answer DONE without
	// running, and mptest lost the counts it read that way.
	_, again := db.embed_step(stmt)
	testing.expectf(t, db.error_ok(again), "second step: %s", again.message)
	db.error_free(&again)
	tools_expect(t, second, "SELECT n FROM c ORDER BY n", "1 2")
}

@(test)
test_truncate_then_insert_the_same_key :: proc(t: ^testing.T) {
	// TRUNCATE leaves no committed row to collide with: inserting a key the
	// table held before, in the same transaction, failed as a duplicate, and
	// the commit then kept the table empty.
	store := fresh_db(t, "truncate_reinsert")
	if store == nil do return
	defer cleanup_db(store, "truncate_reinsert")
	run_done(t, store, "CREATE TABLE t (a INT PRIMARY KEY, b TEXT)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'x'), (2, 'y')")
	tx := db.tx_begin_write(store)
	for sql in ([]string{"TRUNCATE t", "INSERT INTO t VALUES (1, 'z')"}) {
		result, err := db.sql_execute_in_tx(tx, sql)
		testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
		db.error_free(&err)
		db.sql_result_destroy(&result)
	}
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, 1)
	testing.expect_value(t, scalar(t, store, "SELECT b FROM t WHERE a = 1").s, "z")
}

@(test)
test_a_connection_catches_up_table_by_table :: proc(t: ^testing.T) {
	// Another connection's commit used to make this one read the whole file
	// and rebuild every table: 12 ms a statement on mptest's file, so five
	// writers took four times SQLite's time. Only the tables whose rows moved
	// are reloaded now; their triggers do not run again.
	path := "_test_tools_catch_up.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	a, a_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(a_err), "open: %s", a_err.message) do return
	defer db.embed_close(a)
	tools_ok(t, a, "CREATE TABLE t1 (k INTEGER PRIMARY KEY, v)")
	tools_ok(t, a, "CREATE TABLE t2 (k INTEGER PRIMARY KEY, v)")
	tools_ok(t, a, "CREATE TABLE log (n)")
	tools_ok(t, a, "CREATE TRIGGER t1_log AFTER INSERT ON t1 BEGIN INSERT INTO log VALUES (new.k); END")
	tools_ok(t, a, "INSERT INTO t1 VALUES (1, 'a'), (2, 'b')")
	tools_ok(t, a, "INSERT INTO t2 VALUES (1, 'x')")
	b, b_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(b_err), "open: %s", b_err.message) do return
	defer db.embed_close(b)
	tools_expect(t, b, "SELECT count(*) FROM log", "2")
	untouched := b.store.tables["t2"]
	tools_ok(t, a, "INSERT INTO t1 VALUES (3, 'c')")
	tools_ok(t, a, "UPDATE t1 SET v = 'B' WHERE k = 2")
	tools_expect(t, b, "SELECT k, v FROM t1", "1|a 2|B 3|c")
	// The trigger ran in a, once; b reloaded its rows without running it.
	tools_expect(t, b, "SELECT n FROM log", "1 2 3")
	tools_expect(t, b, "SELECT v FROM t2", "x")
	testing.expect(t, b.store.tables["t2"] == untouched, "t2 did not change and was rebuilt")
	// b's own write, then a's: b still sees its own row.
	tools_ok(t, b, "UPDATE t2 SET v = 'y'")
	tools_ok(t, a, "DELETE FROM t1 WHERE k = 1")
	tools_expect(t, b, "SELECT v FROM t2", "y")
	tools_expect(t, b, "SELECT k FROM t1", "2 3")
	tools_expect(t, a, "SELECT v FROM t2", "y")
	// A table that outgrows its page gets a new root page, which rewrites its
	// row of sqlite_master: that is no schema change, and the other tables
	// stay. Half of mptest's catch-ups read the whole file for it.
	untouched = b.store.tables["t2"]
	tools_ok(t, a, "INSERT INTO t1 SELECT k + 10, randomblob(1500) FROM t1")
	tools_ok(t, a, "INSERT INTO t1 SELECT k + 20, randomblob(1500) FROM t1")
	tools_expect(t, b, "SELECT count(*) FROM t1", "8")
	tools_expect(t, b, "SELECT v FROM t2", "y")
	testing.expect(t, b.store.tables["t2"] == untouched, "a new root page of t1 rebuilt t2")
	// A table whose pages did not move is not read again, so what b knows of a
	// tree must follow b's own commits: one to a table with an index re-encodes
	// the file and moves every table's pages, t2's included. a's change to t2
	// after that still reaches b.
	tools_ok(t, a, "CREATE TABLE t0 (k INTEGER PRIMARY KEY, v)")
	tools_ok(t, a, "CREATE INDEX t0v ON t0 (v)")
	tools_expect(t, b, "SELECT count(*) FROM t0", "0")
	tools_ok(t, b, "INSERT INTO t0 SELECT k, randomblob(3000) FROM t1")
	tools_ok(t, a, "UPDATE t2 SET v = 'z'")
	tools_expect(t, b, "SELECT v FROM t2", "z")
	tools_expect(t, b, "SELECT count(*) FROM t0", "8")
	tools_expect(t, a, "SELECT count(*) FROM t0", "8")
	// A commit that leaves every row as it was reloads nothing, and b's mirror
	// still follows the file: it kept the change counter from before, so b's
	// next commit wrote the counter a's had, which another process that last
	// read a's would take for no change.
	tools_ok(t, a, "UPDATE t2 SET v = v")
	tools_expect(t, b, "SELECT v FROM t2", "z")
	if image, read_err := os.read_entire_file(path, context.temp_allocator); read_err == nil && len(image) >= 28 {
		counter := u32(image[24]) << 24 | u32(image[25]) << 16 | u32(image[26]) << 8 | u32(image[27])
		testing.expect_value(t, b.store.mirror.change, counter)
	}
	// A schema change reads the whole file.
	tools_ok(t, a, "CREATE TABLE t3 (z)")
	tools_ok(t, a, "INSERT INTO t3 VALUES (9)")
	tools_expect(t, b, "SELECT z FROM t3", "9")
}

@(private = "file")
tools_reverse :: proc(a, b: string, user: rawptr) -> int {
	return a < b ? 1 : a > b ? -1 : 0
}

// tools_fails runs a statement that must fail with `message`.
@(private = "file")
tools_fails :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, message: string) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, err.message == message, "%s: got %q, want %q", sql, err.message, message)
}

// An index the engine cannot build from a file (its collation, or its
// function, is the program's that wrote the file) used to be built without
// its WHERE, or left out: a partial UNIQUE index made whole refused rows
// SQLite accepts, and the next rewrite dropped the other from the user's file.
// It is kept as the file has it now, and its table refuses writes, as SQLite
// does without the collation, until the program registers it (D24).
@(test)
test_an_index_the_engine_cannot_build_is_kept :: proc(t: ^testing.T) {
	path := "_test_tools_kept_index.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	{
		a, a_err := db.embed_open(path)
		if !testing.expectf(t, db.error_ok(a_err), "open: %s", a_err.message) do return
		testing.expect(t, db.error_ok(db.store_register_collation(a.store, "rev", tools_reverse)))
		tools_ok(t, a, "CREATE TABLE t (a INTEGER, b TEXT)")
		tools_ok(t, a, "INSERT INTO t VALUES (1, 'x'), (1, 'y'), (2, 'z')")
		tools_ok(t, a, "CREATE INDEX i ON t (b COLLATE rev)")
		tools_ok(t, a, "CREATE UNIQUE INDEX pu ON t (a) WHERE b COLLATE rev = 'x'")
		tools_ok(t, a, "CREATE TABLE u (x)")
		db.embed_close(a)
	}
	b, b_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(b_err), "open: %s", b_err.message) do return
	defer db.embed_close(b)
	testing.expect_value(t, b.store.mirror_kept_indexes, 2)
	kept, found := db.store_mirror_kept_index(b.store, "pu")
	testing.expect(t, found && kept.reason == "no such collation sequence: rev", "pu is kept with its reason")
	// Reads answer from the rows; writes to t wait for the collation.
	tools_expect(t, b, "SELECT a, b FROM t ORDER BY rowid", "1|x 1|y 2|z")
	tools_fails(t, b, "INSERT INTO t VALUES (3, 'w')", "no such collation sequence: rev")
	tools_fails(t, b, "DELETE FROM t", "no such collation sequence: rev")
	// Another table is written, and a rewrite of the whole file (DDL) keeps
	// both indexes, with the entries their rows imply.
	tools_ok(t, b, "INSERT INTO u VALUES (1)")
	tools_ok(t, b, "CREATE INDEX ux ON u (x)")
	ok, reason := db.sqlite_mirror_validate(path, context.temp_allocator)
	testing.expectf(t, ok, "the file is malformed: %s", reason)
	tools_expect(t, b, "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 't' ORDER BY name", "i pu")
	tools_expect(t, b, "SELECT sql FROM sqlite_master WHERE name = 'pu'", "CREATE UNIQUE INDEX pu ON t (a) WHERE b COLLATE rev = 'x'")
	// With the collation registered the indexes are built and t is written as
	// SQLite writes it: the partial index takes the second a = 1 that is not 'x',
	// and refuses one that is.
	testing.expect(t, db.error_ok(db.store_register_collation(b.store, "rev", tools_reverse)))
	tools_ok(t, b, "INSERT INTO t VALUES (1, 'q')")
	tools_fails(t, b, "INSERT INTO t VALUES (1, 'x')", "UNIQUE constraint failed: t.a")
	testing.expect_value(t, b.store.mirror_kept_indexes, 0)
	ok, reason = db.sqlite_mirror_validate(path, context.temp_allocator)
	testing.expectf(t, ok, "the file is malformed: %s", reason)
}

// An index ordered by a collation nobody registered was accepted and written
// in BINARY order, which SQLite then found missing every row. It is refused
// now, as SQLite refuses it (D24).
@(test)
test_an_index_needs_what_it_can_evaluate :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE t (a INTEGER, b TEXT)")
	tools_fails(t, conn, "CREATE INDEX c ON t (b COLLATE nobody)", "no such collation sequence: nobody")
	tools_fails(t, conn, "CREATE INDEX p ON t (a) WHERE b COLLATE nobody = 'x'", "no such collation sequence: nobody")
	tools_ok(t, conn, "CREATE INDEX e ON t (upper(b) COLLATE nocase)")
}

// An index over a program's function evaluated it without the program's
// functions: every row's key was NULL, so a partial UNIQUE index enforced
// nothing and SQLite found the file's index missing every row. It calls the
// program's function now, in the statement and in the commit (D24).
@(test)
test_an_index_calls_a_program_s_function :: proc(t: ^testing.T) {
	path := "_test_tools_function_index.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	same :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
		return args[0], db.ERROR_NONE
	}
	{
		conn, err := db.embed_open(path)
		if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
		defer db.embed_close(conn)
		testing.expect(t, db.error_ok(db.store_register_function(conn.store, "same", 1, same)))
		tools_ok(t, conn, "CREATE TABLE t (a INTEGER, b TEXT)")
		tools_ok(t, conn, "INSERT INTO t VALUES (1, 'x'), (2, 'y')")
		tools_ok(t, conn, "CREATE INDEX f ON t (same(b))")
		tools_ok(t, conn, "CREATE UNIQUE INDEX w ON t (a) WHERE same(b) = 'x'")
		tools_ok(t, conn, "INSERT INTO t VALUES (1, 'z')")
		tools_fails(t, conn, "INSERT INTO t VALUES (1, 'x')", "UNIQUE constraint failed: t.a")
	}
	ok, reason := db.sqlite_mirror_validate(path, context.temp_allocator)
	testing.expectf(t, ok, "the file is malformed: %s", reason)
}

// A rowid SQLite writes in nine bytes (a negative one, or one past 2^56) lost
// its top seven bits on the way to the file: -5 came back as
// 144115188075855867 and SQLite found the table out of order. An omitted
// INTEGER PRIMARY KEY after -5 is -4, as SQLite gives it, not 1.
@(test)
test_a_negative_rowid_reaches_the_file :: proc(t: ^testing.T) {
	path := "_test_tools_negative_rowid.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	{
		conn, err := db.embed_open(path)
		if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
		tools_ok(t, conn, "CREATE TABLE t (k INTEGER PRIMARY KEY, v)")
		tools_ok(t, conn, "INSERT INTO t VALUES (-5, 'a')")
		tools_ok(t, conn, "INSERT INTO t (v) VALUES ('b')")
		tools_ok(t, conn, "INSERT INTO t VALUES (1152921504606846976, 'c'), (-9223372036854775808, 'd')")
		tools_expect(t, conn, "SELECT k, v FROM t WHERE v = 'b'", "-4|b")
		db.embed_close(conn)
	}
	ok, reason := db.sqlite_mirror_validate(path, context.temp_allocator)
	testing.expectf(t, ok, "the file is malformed: %s", reason)
	again, err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(err), "reopen: %s", err.message) do return
	defer db.embed_close(again)
	tools_expect(t, again, "SELECT k, v FROM t ORDER BY k", "-9223372036854775808|d -5|a -4|b 1152921504606846976|c")
}

// SQLite's INTEGER PRIMARY KEY is the rowid: a value its affinity cannot make
// an integer is "datatype mismatch", where another INTEGER column keeps it. A
// real key was kept and reached the file as a rowid nobody wrote.
@(test)
test_an_integer_primary_key_takes_only_integers :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE t (k INTEGER PRIMARY KEY, a INTEGER)")
	tools_ok(t, conn, "INSERT INTO t VALUES (2.0, 1), ('7', 1), (' 8 ', 1), (NULL, 1)")
	tools_ok(t, conn, "INSERT INTO t VALUES (1, -1.838), (3, 'x')")
	for value in ([]string{"-1.838", "'x'", "x'01'", "9.3e18"}) {
		tools_fails(t, conn, strings.concatenate({"INSERT INTO t VALUES (", value, ", 1)"}, context.temp_allocator), "datatype mismatch")
	}
	tools_fails(t, conn, "UPDATE t SET k = 3.5 WHERE k = 2", "datatype mismatch")
	tools_expect(t, conn, "SELECT k, typeof(a) FROM t ORDER BY k", "1|real 2|integer 3|text 7|integer 8|integer 9|integer")
}

// SQLite lets a PRIMARY KEY other than the INTEGER one that is the rowid hold
// NULL, each NULL a key of its own: it kept the bug for the files that rely on
// it. A WITHOUT ROWID table's key refuses NULL, as SQLite's does.
@(test)
test_a_primary_key_takes_null_as_sqlite_s_does :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE t (s TEXT PRIMARY KEY, a)")
	tools_ok(t, conn, "INSERT INTO t VALUES (NULL, 1), (NULL, 2), ('x', 3)")
	tools_fails(t, conn, "INSERT INTO t VALUES ('x', 4)", "UNIQUE constraint failed: t.s")
	tools_ok(t, conn, "CREATE TABLE p (a, b, PRIMARY KEY (a, b))")
	tools_ok(t, conn, "INSERT INTO p VALUES (1, NULL), (1, NULL)")
	tools_ok(t, conn, "CREATE TABLE w (s TEXT PRIMARY KEY, a) WITHOUT ROWID")
	tools_fails(t, conn, "INSERT INTO w VALUES (NULL, 1)", "NOT NULL constraint failed: w.s")
	tools_ok(t, conn, "CREATE TABLE r (k INTEGER PRIMARY KEY, a)")
	tools_ok(t, conn, "INSERT INTO r VALUES (NULL, 1)")
	tools_expect(t, conn, "SELECT count(*), count(s) FROM t", "3|1")
	tools_expect(t, conn, "SELECT count(*) FROM p", "2")
	tools_expect(t, conn, "SELECT k FROM r", "1")
}

// Two empty texts are equal whatever their pointers. Odin's runtime compares
// the data pointers before the length, so an empty text with a nil pointer
// came out less than another: an index put two '' entries out of rowid order
// (the row whose key was NULL made the nil one), and SQLite found the file's
// index missing a row.
@(test)
test_two_empty_texts_are_equal :: proc(t: ^testing.T) {
	nil_data := transmute(string)runtime.Raw_String{nil, 0}
	not_nil := "x"[:0]
	order, ok := db.value_compare(db.value_string(not_nil), db.value_string(nil_data))
	testing.expectf(t, ok && order == .Equal, "'' against '': %v", order)
	testing.expect_value(t, db.text_compare(not_nil, nil_data), 0)
	testing.expect_value(t, db.text_compare(nil_data, "a"), -1)
	path := "_test_tools_empty_text.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	{
		conn, err := db.embed_open(path)
		if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
		defer db.embed_close(conn)
		tools_ok(t, conn, "CREATE TABLE t (s TEXT PRIMARY KEY, c)")
		tools_ok(t, conn, "INSERT INTO t VALUES ('b', '')")
		tools_ok(t, conn, "CREATE INDEX i ON t (c)")
		tools_ok(t, conn, "INSERT INTO t VALUES (NULL, '')")
	}
	valid, reason := db.sqlite_mirror_validate(path, context.temp_allocator)
	testing.expectf(t, valid, "the file is malformed: %s", reason)
}

// An omitted INTEGER PRIMARY KEY is one past the largest key, as SQLite gives
// it: after -5 comes -4, and 1 only in a table without one. The engine started
// at 1 whatever the table held.
@(test)
test_an_omitted_key_follows_a_negative_one :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE t (k INTEGER PRIMARY KEY, v)")
	tools_ok(t, conn, "INSERT INTO t (v) VALUES ('a')")
	tools_ok(t, conn, "DELETE FROM t")
	tools_ok(t, conn, "INSERT INTO t VALUES (-5, 'b')")
	tools_ok(t, conn, "INSERT INTO t (v) VALUES ('c'), ('d')")
	tools_expect(t, conn, "SELECT k, v FROM t ORDER BY k", "-5|b -4|c -3|d")
}

// ADD COLUMN puts the column after the last one, before the table
// constraints, as SQLite does: after `PRIMARY KEY (a, b)` it was text SQLite
// cannot parse, and the file could not be opened again.
@(test)
test_an_added_column_goes_before_the_table_constraints :: proc(t: ^testing.T) {
	path := "_test_tools_add_column.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	{
		conn, err := db.embed_open(path)
		if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
		defer db.embed_close(conn)
		tools_ok(t, conn, "CREATE TABLE w (a INTEGER NOT NULL, b TEXT NOT NULL, c, PRIMARY KEY (a, b)) WITHOUT ROWID")
		tools_ok(t, conn, "ALTER TABLE w ADD COLUMN x INTEGER DEFAULT 1")
		tools_ok(t, conn, "INSERT INTO w (a, b) VALUES (1, 'k')")
		tools_expect(t, conn, "SELECT sql FROM sqlite_master WHERE name = 'w'", "CREATE TABLE w (a INTEGER NOT NULL, b TEXT NOT NULL, c, x INTEGER DEFAULT 1, PRIMARY KEY (a, b)) WITHOUT ROWID")
	}
	again, err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(err), "reopen: %s", err.message) do return
	defer db.embed_close(again)
	tools_expect(t, again, "SELECT a, b, c, x FROM w", "1|k||1")
}

// ALTER rebuilt the table from every row it held, tombstones included, so a
// deleted row came back; and the rows the transaction had staged kept the old
// shape: they read NULL for the added column instead of its DEFAULT, and an
// UPDATE of one indexed past its values and took the process down.
@(test)
test_alter_keeps_deleted_rows_deleted_and_reshapes_staged_ones :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE t (a, b)")
	tools_ok(t, conn, "INSERT INTO t VALUES (1, 'x'), (6, 'gone')")
	tools_ok(t, conn, "DELETE FROM t WHERE a = 6")
	tools_ok(t, conn, "BEGIN")
	tools_ok(t, conn, "INSERT INTO t VALUES (2, 'y')")
	tools_ok(t, conn, "UPDATE t SET b = 'z' WHERE a = 1")
	tools_ok(t, conn, "ALTER TABLE t ADD COLUMN c INTEGER DEFAULT 3")
	tools_ok(t, conn, "INSERT INTO t (a, b) VALUES (3, 'w')")
	tools_expect(t, conn, "SELECT a, b, c FROM t ORDER BY a", "1|z|3 2|y|3 3|w|3")
	tools_ok(t, conn, "UPDATE t SET b = 'q' WHERE a = 2")
	tools_ok(t, conn, "COMMIT")
	tools_expect(t, conn, "SELECT a, b, c FROM t ORDER BY a", "1|z|3 2|q|3 3|w|3")
}

// An integer and a real are one key space, ordered by value as SQLite
// compares them. Every integer sorted before every real: through an index
// `c < -3` skipped -3.5, a range lost the integers inside it, `c = 5.0` missed
// the 5, and a UNIQUE column took 5.0 beside 5.
@(test)
test_numbers_share_one_key_space :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE t (a, c)")
	tools_ok(t, conn, "INSERT INTO t VALUES (1, 5), (2, -10), (3, -2), (4, 'x'), (5, NULL), (6, -3.5), (7, 100), (8, 9007199254740993), (9, 9007199254740992.0)")
	tools_ok(t, conn, "CREATE INDEX i ON t (c)")
	tools_expect(t, conn, "SELECT a FROM t WHERE c < -3 ORDER BY a", "2 6")
	tools_expect(t, conn, "SELECT a FROM t WHERE c >= -3.5 AND c < 6 ORDER BY a", "1 3 6")
	tools_expect(t, conn, "SELECT a FROM t WHERE c = 5.0", "1")
	tools_expect(t, conn, "SELECT a FROM t WHERE c = 9007199254740993", "8")
	tools_expect(t, conn, "SELECT a FROM t WHERE c >= 9007199254740993", "4 8")
	tools_expect(t, conn, "SELECT a FROM t ORDER BY c, a", "5 2 6 3 1 7 9 8 4")
	tools_ok(t, conn, "CREATE TABLE u (k UNIQUE)")
	tools_ok(t, conn, "INSERT INTO u VALUES (5)")
	tools_fails(t, conn, "INSERT INTO u VALUES (5.0)", "UNIQUE constraint failed: u.k")
}

// INSERT OR REPLACE and UPSERT looked for the row they collide with by the
// value as written, before the column's affinity: `22` into a TEXT key missed
// the `'22'` it should replace, and the insert failed on it.
@(test)
test_a_replace_looks_up_the_value_as_stored :: proc(t: ^testing.T) {
	store := tools_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	tools_ok(t, conn, "CREATE TABLE t (s TEXT PRIMARY KEY, a)")
	tools_ok(t, conn, "INSERT INTO t VALUES (22, 1), ('x', 2)")
	tools_ok(t, conn, "INSERT OR REPLACE INTO t VALUES (22, 9)")
	tools_expect(t, conn, "SELECT s, typeof(s), a FROM t ORDER BY s", "22|text|9 x|text|2")
	tools_ok(t, conn, "INSERT INTO t VALUES (22, 5) ON CONFLICT (s) DO UPDATE SET a = 7")
	tools_expect(t, conn, "SELECT a FROM t WHERE s = '22'", "7")
	tools_ok(t, conn, "CREATE TABLE n (k INTEGER UNIQUE, v)")
	tools_ok(t, conn, "INSERT INTO n VALUES ('5', 1)")
	tools_ok(t, conn, "INSERT OR REPLACE INTO n VALUES (5.0, 2)")
	tools_expect(t, conn, "SELECT k, typeof(k), v FROM n", "5|integer|2")
}
