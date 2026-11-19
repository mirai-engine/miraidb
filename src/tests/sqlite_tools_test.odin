package tests

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
