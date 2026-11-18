package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import db "../engine"

// What CPython's sqlite3 tests needed of the engine, each checked here where
// the engine can answer it on its own; scripts/python_sqlite3.py runs the
// tests themselves through the facade.

@(private = "file")
face_store :: proc(t: ^testing.T) -> ^db.Store {
	store, err := db.store_open("", {persistent = false})
	testing.expect(t, db.error_ok(err))
	// The sqlite3_* face's rules.
	store.sqlite_names = true
	store.sqlite_rules = true
	store.foreign_keys_off = true
	return store
}

@(private = "file")
face_ok :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
}

@(private = "file")
face_fails :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, message: string) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, !db.error_ok(err) && strings.contains(err.message, message), "%s: want %q, got %q", sql, message, err.message)
}

// face_ints reads the first column of every row as an integer.
@(private = "file")
face_ints :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) -> [dynamic]i64 {
	out := make([dynamic]i64, context.temp_allocator)
	stmt := db.embed_prepare(conn, sql)
	if !testing.expectf(t, stmt != nil, "prepare %s: %s", sql, db.embed_error(conn)) do return out
	defer db.embed_finalize(stmt)
	for {
		has_row, err := db.embed_step(stmt)
		if !testing.expectf(t, db.error_ok(err), "step %s: %s", sql, err.message) {
			db.error_free(&err)
			return out
		}
		if !has_row do break
		append(&out, db.embed_column_int(stmt, 0))
	}
	return out
}

@(private = "file")
expect_list :: proc(t: ^testing.T, got: [dynamic]i64, want: []i64, what: string) {
	same := len(got) == len(want)
	if same do for v, i in want do if got[i] != v do same = false
	testing.expectf(t, same, "%s: got %v, want %v", what, got[:], want)
}

@(test)
test_insert_names_the_rowid :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE TABLE t (x)")
	// A rowid table without an INTEGER PRIMARY KEY takes the rowid it is given,
	// as SQLite does, and counts on from the largest.
	face_ok(t, conn, "INSERT INTO t (rowid, x) VALUES (4294967296, 'a')")
	face_ok(t, conn, "INSERT INTO t (x) VALUES ('b')")
	face_ok(t, conn, "INSERT INTO t (oid, x) VALUES (7, 'c')")
	expect_list(t, face_ints(t, conn, "SELECT rowid FROM t ORDER BY rowid"), {7, 4294967296, 4294967297}, "rowids")
	face_fails(t, conn, "INSERT INTO t (rowid, x) VALUES (7, 'd')", "UNIQUE constraint failed: t.rowid")
	face_fails(t, conn, "INSERT INTO t (_rowid_, x) VALUES ('x', 'd')", "datatype mismatch")
	// With an INTEGER PRIMARY KEY the rowid is that column.
	face_ok(t, conn, "CREATE TABLE k (id INTEGER PRIMARY KEY, v)")
	face_ok(t, conn, "INSERT INTO k (rowid, v) VALUES (40, 'v')")
	expect_list(t, face_ints(t, conn, "SELECT id FROM k"), {40}, "alias")
}

@(test)
test_replace_and_upsert_see_the_transaction :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, u TEXT UNIQUE)")
	face_ok(t, conn, "BEGIN")
	// The first row is staged, not committed: REPLACE still finds it, and the
	// new row's key is chosen before the old one goes, as SQLite chooses it.
	face_ok(t, conn, "INSERT OR REPLACE INTO t (name, u) VALUES ('a', 'foo')")
	face_ok(t, conn, "INSERT OR REPLACE INTO t (name, u) VALUES ('b', 'foo')")
	expect_list(t, face_ints(t, conn, "SELECT id FROM t"), {2}, "replaced")
	face_ok(t, conn, "INSERT INTO t (id, name, u) VALUES (2, 'c', 'bar') ON CONFLICT (id) DO UPDATE SET name = excluded.name")
	expect_list(t, face_ints(t, conn, "SELECT count(*) FROM t WHERE name = 'c'"), {1}, "upserted")
	face_ok(t, conn, "COMMIT")
}

@(test)
test_returning_takes_expressions :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)")
	face_ok(t, conn, "INSERT INTO t (n) VALUES (10), (20)")
	stmt := db.embed_prepare(conn, "UPDATE t SET n = n + 1 WHERE id = 2 RETURNING 1, n * 2 AS twice, *")
	if !testing.expect(t, stmt != nil) do return
	defer db.embed_finalize(stmt)
	has_row, err := db.embed_step(stmt)
	testing.expect(t, db.error_ok(err) && has_row)
	testing.expect_value(t, db.embed_column_count(stmt), 4)
	testing.expect_value(t, db.embed_column_name(stmt, 0), "1")
	testing.expect_value(t, db.embed_column_name(stmt, 1), "twice")
	testing.expect_value(t, db.embed_column_int(stmt, 0), i64(1))
	testing.expect_value(t, db.embed_column_int(stmt, 1), i64(42))
	testing.expect_value(t, db.embed_column_int(stmt, 3), i64(21))
}

@(test)
test_names_match_without_case_under_sqlite_rules :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE TABLE t (c)")
	face_ok(t, conn, "INSERT INTO T VALUES (1)")
	face_ok(t, conn, "UPDATE T SET C = 2")
	face_ok(t, conn, "CREATE INDEX i ON T (c)")
	face_ok(t, conn, "CREATE VIEW v AS SELECT c FROM t")
	expect_list(t, face_ints(t, conn, "SELECT c FROM main.T"), {2}, "qualified")
	expect_list(t, face_ints(t, conn, "SELECT c FROM V"), {2}, "view")
	expect_list(t, face_ints(t, conn, "SELECT count(*) FROM pragma_table_info('T')"), {1}, "pragma")
	face_fails(t, conn, "CREATE TABLE T (d)", "already exists")
	face_ok(t, conn, "DROP INDEX I")
	face_ok(t, conn, "DROP VIEW V")
	face_ok(t, conn, "DROP TABLE T")
	// The engine's own rules keep names exact.
	store.sqlite_rules = false
	face_ok(t, conn, "CREATE TABLE u (c)")
	face_fails(t, conn, "INSERT INTO U VALUES (1)", "U")
}

@(test)
test_checks_run_inside_the_open_transaction :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE TABLE p (id INTEGER PRIMARY KEY)")
	face_ok(t, conn, "CREATE TABLE c (id INTEGER PRIMARY KEY, p INTEGER REFERENCES p (id))")
	face_ok(t, conn, "BEGIN")
	face_ok(t, conn, "INSERT INTO c VALUES (1, 9)")
	// The check reads the transaction (it used to wait for its lock forever).
	expect_list(t, face_ints(t, conn, "SELECT count(*) FROM pragma_foreign_key_check"), {1}, "orphans")
	face_ok(t, conn, "ROLLBACK")
}

@(test)
test_create_virtual_table_keeps_its_text :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE VIRTUAL TABLE docs USING fts4(body)")
	stmt := db.embed_prepare(conn, "SELECT sql FROM sqlite_master WHERE name = 'docs'")
	if !testing.expect(t, stmt != nil) do return
	defer db.embed_finalize(stmt)
	has_row, err := db.embed_step(stmt)
	testing.expect(t, db.error_ok(err) && has_row)
	testing.expect_value(t, db.embed_column_text(stmt, 0), "CREATE VIRTUAL TABLE docs USING fts4(body)")
}

// A function that opens a transaction on its own connection in the middle of
// a SELECT, as Python's sqlite3 does when the function inserts.
@(private = "file")
begin_and_insert :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
	conn := (^db.Embed_Conn)(user)
	if !db.embed_in_transaction(conn) do db.error_drop(db.embed_exec(conn, "BEGIN"))
	err := db.embed_exec(conn, "INSERT INTO log VALUES (1)")
	return db.value_null(), err
}

@(test)
test_function_may_begin_a_transaction_mid_select :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE TABLE t (x)")
	face_ok(t, conn, "CREATE TABLE log (x)")
	face_ok(t, conn, "INSERT INTO t VALUES (1), (2)")
	testing.expect(t, db.error_ok(db.store_register_function(store, "dup", 1, begin_and_insert, rawptr(conn))))
	// The SELECT ends while the connection holds the write lock the function
	// took; it used to wait for that lock to price itself.
	face_ints(t, conn, "SELECT dup(x) FROM t")
	testing.expect(t, db.embed_in_transaction(conn))
	face_ok(t, conn, "COMMIT")
	expect_list(t, face_ints(t, conn, "SELECT count(*) FROM log"), {2}, "logged")
}

@(private = "file")
Window_Calls :: struct {
	steps, inverses, values: int,
}

@(private = "file")
window_calls: Window_Calls

@(private = "file")
window_step :: proc(group: ^db.Aggregate_Group, args: []db.Value) -> db.Error {
	if group.state == nil do group.state = new(i64)
	(^i64)(group.state)^ += args[0].i
	window_calls.steps += 1
	return db.ERROR_NONE
}

@(private = "file")
window_inverse :: proc(group: ^db.Aggregate_Group, args: []db.Value) -> db.Error {
	(^i64)(group.state)^ -= args[0].i
	window_calls.inverses += 1
	return db.ERROR_NONE
}

@(private = "file")
window_value :: proc(group: ^db.Aggregate_Group) -> (db.Value, db.Error) {
	window_calls.values += 1
	if group.state == nil do return db.value_null(), db.ERROR_NONE
	return db.value_int((^i64)(group.state)^), db.ERROR_NONE
}

@(private = "file")
window_final :: proc(group: ^db.Aggregate_Group) -> (db.Value, db.Error) {
	if group.state != nil do free(group.state)
	group.state = nil
	return db.value_null(), db.ERROR_NONE
}

@(test)
test_window_function_is_fed_incrementally :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	testing.expect(t, db.error_ok(db.store_register_aggregate(store, "wsum", 1, window_step, window_final)))
	db.store_set_aggregate_window(store, "wsum", 1, window_value, window_inverse)
	face_ok(t, conn, "CREATE TABLE t (x INTEGER)")
	face_ok(t, conn, "INSERT INTO t VALUES (1), (2), (3), (4), (5)")
	window_calls = {}
	got := face_ints(t, conn, "SELECT wsum(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM t ORDER BY x")
	expect_list(t, got, {3, 6, 9, 12, 9}, "sliding sums")
	// Each row enters once and the three that leave go once: xStep five
	// times, xInverse three, xValue once a row, as SQLite calls them.
	testing.expect_value(t, window_calls, Window_Calls{steps = 5, inverses = 3, values = 5})
}

@(test)
test_two_connections_share_a_sqlite_file :: proc(t: ^testing.T) {
	path := "_test_shared.db"
	os.remove(path)
	defer os.remove(path)
	testing.expect(t, db.sqlite_create_empty_file(path))
	first, first_err := db.embed_open(path)
	testing.expect(t, db.error_ok(first_err))
	second, second_err := db.embed_open(path)
	testing.expect(t, db.error_ok(second_err))
	defer db.embed_close(second)
	defer db.embed_close(first)
	face_ok(t, first, "CREATE TABLE t (x)")
	face_ok(t, first, "BEGIN")
	face_ok(t, first, "INSERT INTO t VALUES (1)")
	// The other connection reads the last commit while the first writes, and
	// a write of its own finds the file locked.
	expect_list(t, face_ints(t, second, "SELECT count(*) FROM t"), {0}, "before commit")
	face_fails(t, second, "INSERT INTO t VALUES (2)", "database is locked")
	face_ok(t, first, "COMMIT")
	expect_list(t, face_ints(t, second, "SELECT count(*) FROM t"), {1}, "after commit")
	face_ok(t, second, "INSERT INTO t VALUES (2)")
	expect_list(t, face_ints(t, first, "SELECT x FROM t ORDER BY x"), {1, 2}, "both")
}

// A statement run at once (sqlite3_exec) reads the names another connection
// committed, as a prepared one does: here the table the first made.
@(test)
test_exec_sees_another_connection_commit :: proc(t: ^testing.T) {
	path := "_test_shared_exec.db"
	os.remove(path)
	defer os.remove(path)
	testing.expect(t, db.sqlite_create_empty_file(path))
	first, first_err := db.embed_open(path)
	testing.expect(t, db.error_ok(first_err))
	second, second_err := db.embed_open(path)
	testing.expect(t, db.error_ok(second_err))
	defer db.embed_close(second)
	defer db.embed_close(first)
	face_ok(t, first, "CREATE TABLE t (x)")
	face_ok(t, second, "INSERT INTO t VALUES (1)")
	expect_list(t, face_ints(t, first, "SELECT x FROM t"), {1}, "the second's row")
}

// The registry of shared files outlives the allocator of whoever made it. The
// first connection to a SQLite file in the process makes the registry; when
// that happens under an arena that is then reused (the test runner reuses each
// test's), a file another connection still holds must stay findable. Run on
// its own this test is the one that makes the registry.
@(test)
test_shared_files_outlive_the_opener_allocator :: proc(t: ^testing.T) {
	buffer := make([]byte, 64 * 1024 * 1024)
	defer delete(buffer)
	arena: mem.Arena
	mem.arena_init(&arena, buffer)
	paths: [8]string
	for &path, k in paths do path = fmt.aprintf("_test_registry_%d.db", k)
	defer for path in paths {
		os.remove(path)
		delete(path)
	}
	{
		context.allocator = mem.arena_allocator(&arena)
		for path in paths {
			os.remove(path)
			testing.expect(t, db.sqlite_create_empty_file(path))
			conn, err := db.embed_open(path)
			testing.expect(t, db.error_ok(err))
			if conn != nil do db.embed_close(conn)
		}
	}

	held := "_test_registry_held.db"
	os.remove(held)
	defer os.remove(held)
	testing.expect(t, db.sqlite_create_empty_file(held))
	first, first_err := db.embed_open(held)
	testing.expect(t, db.error_ok(first_err))
	defer db.embed_close(first)
	face_ok(t, first, "CREATE TABLE t (x)")
	// The arena is reused: what it held is gone.
	mem.zero_slice(buffer)

	second, second_err := db.embed_open(held)
	testing.expect(t, db.error_ok(second_err))
	defer db.embed_close(second)
	face_ok(t, first, "BEGIN")
	face_ok(t, first, "INSERT INTO t VALUES (1)")
	face_fails(t, second, "INSERT INTO t VALUES (2)", "database is locked")
	face_ok(t, first, "COMMIT")
}

// An attached database is written as SQLite writes one: a table made there, rows
// put in it inside the connection's transaction, which reads its own writes and
// takes them back on ROLLBACK; and a SQLite file that was not there is created
// and holds what was committed to it.
@(test)
test_attached_databases_are_written :: proc(t: ^testing.T) {
	path := "_test_attached_write.db"
	os.remove(path)
	defer os.remove(path)
	conn, open_err := db.embed_open(":memory:")
	testing.expect(t, db.error_ok(open_err))
	defer db.embed_close(conn)
	conn.store.sqlite_rules = true
	conn.store.sqlite_names = true

	face_ok(t, conn, "ATTACH DATABASE ':memory:' AS side")
	face_ok(t, conn, "CREATE TABLE side.foo (key INTEGER)")
	face_ok(t, conn, "INSERT INTO side.foo (key) VALUES (3), (4)")
	expect_list(t, face_ints(t, conn, "SELECT key FROM side.foo ORDER BY key"), {3, 4}, "autocommit")
	face_ok(t, conn, "BEGIN")
	face_ok(t, conn, "INSERT INTO side.foo VALUES (5)")
	face_ok(t, conn, "UPDATE side.foo SET key = key * 10 WHERE key = 3")
	expect_list(t, face_ints(t, conn, "SELECT key FROM side.foo ORDER BY key"), {4, 5, 30}, "inside the transaction")
	face_ok(t, conn, "ROLLBACK")
	expect_list(t, face_ints(t, conn, "SELECT key FROM side.foo ORDER BY key"), {3, 4}, "after ROLLBACK")
	face_ok(t, conn, "DELETE FROM side.foo WHERE key = 3")
	face_fails(t, conn, "INSERT INTO nowhere.foo VALUES (1)", "unknown database nowhere")
	// A failed statement is undone there alone.
	face_ok(t, conn, "CREATE UNIQUE INDEX side.foo_key ON foo (key)")
	face_fails(t, conn, "INSERT INTO side.foo VALUES (6), (4)", "UNIQUE constraint failed")
	expect_list(t, face_ints(t, conn, "SELECT key FROM side.foo ORDER BY key"), {4}, "after a failed statement")

	face_ok(t, conn, "ATTACH DATABASE '_test_attached_write.db' AS disk")
	face_ok(t, conn, "CREATE TABLE disk.kept (v TEXT)")
	face_ok(t, conn, "INSERT INTO disk.kept VALUES ('on disk')")
	face_ok(t, conn, "DETACH DATABASE disk")
	again, again_err := db.embed_open(path)
	testing.expect(t, db.error_ok(again_err))
	defer db.embed_close(again)
	expect_list(t, face_ints(t, again, "SELECT count(*) FROM kept"), {1}, "the file holds the commit")
}

// A string literal where a name goes is that name, as SQLite reads it.
@(test)
test_a_string_literal_names_an_object :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE TABLE 'quoted'(id INTEGER PRIMARY KEY, 'c0name')")
	face_ok(t, conn, "INSERT INTO 'quoted' VALUES (1, 'x')")
	expect_list(t, face_ints(t, conn, "SELECT id FROM quoted WHERE c0name = 'x'"), {1}, "the row")
}

// A full-text table has SQLite's shadow tables beside it, made with the text
// SQLite writes: the content table holds the documents, kept with each write,
// and they go with the table.
@(test)
test_full_text_tables_have_sqlite_shadow_tables :: proc(t: ^testing.T) {
	store := face_store(t)
	defer db.store_close(store)
	conn := db.embed_wrap(store)
	defer db.embed_close(conn)
	face_ok(t, conn, "CREATE VIRTUAL TABLE test USING fts4(example)")
	want := []string {
		"CREATE TABLE 'test_content'(docid INTEGER PRIMARY KEY, 'c0example')",
		"CREATE TABLE 'test_segments'(blockid INTEGER PRIMARY KEY, block BLOB)",
		"CREATE TABLE 'test_segdir'(level INTEGER,idx INTEGER,start_block INTEGER,leaves_end_block INTEGER,end_block INTEGER,root BLOB,PRIMARY KEY(level, idx))",
		"CREATE TABLE 'test_docsize'(docid INTEGER PRIMARY KEY, size BLOB)",
		"CREATE TABLE 'test_stat'(id INTEGER PRIMARY KEY, value BLOB)",
	}
	for sql in want {
		name := sql[len("CREATE TABLE '"):strings.index(sql, "'(")]
		quoted, _ := strings.replace_all(sql, "'", "''", context.temp_allocator)
		query := fmt.tprintf("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '%s' AND sql = '%s'", name, quoted)
		expect_list(t, face_ints(t, conn, query), {1}, name)
	}
	face_ok(t, conn, "INSERT INTO test VALUES ('hello world')")
	face_ok(t, conn, "INSERT INTO test VALUES ('second doc')")
	face_ok(t, conn, "DELETE FROM test WHERE rowid = 1")
	expect_list(t, face_ints(t, conn, "SELECT docid FROM test_content"), {2}, "the content table")
	expect_list(t, face_ints(t, conn, "SELECT rowid FROM test WHERE test MATCH 'second'"), {2}, "the match")
	face_ok(t, conn, "DROP TABLE test")
	expect_list(t, face_ints(t, conn, "SELECT count(*) FROM sqlite_master WHERE name LIKE 'test%'"), {0}, "after DROP")

	face_ok(t, conn, "CREATE VIRTUAL TABLE five USING fts5(a, b UNINDEXED)")
	expect_list(t, face_ints(t, conn, "SELECT v FROM five_config WHERE k = 'version'"), {4}, "fts5 config")
	face_ok(t, conn, "INSERT INTO five VALUES ('x', 'y')")
	expect_list(t, face_ints(t, conn, "SELECT count(*) FROM five_content WHERE c0 = 'x' AND c1 = 'y'"), {1}, "fts5 content")
}
