package tests

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
