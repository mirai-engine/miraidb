package tests

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
