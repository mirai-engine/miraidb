package tests

import "core:fmt"
import "core:os"
import "core:testing"

import db "../engine"

// The mirror patches a commit into the file instead of re-encoding it (D37):
// a table without an INTEGER PRIMARY KEY by the engine's row id, which is the
// rowid the file gave the row, and a table with an index by building the
// index again.

@(private = "file")
mp_export :: proc(t: ^testing.T, path: string, statements: []string) -> bool {
	os.remove(path)
	os.remove(fmt.tprintf("%s-journal", path))
	// The store it is written from is the test's own: the tests run at once.
	name := fmt.tprintf("mirror_patch_%s", path)
	source := fresh_db(t, name)
	if source == nil do return false
	defer cleanup_db(source, name)
	for statement in statements do run_done(t, source, statement)
	_, _, export_err := db.sqlite_file_write(source, path)
	return testing.expectf(t, db.error_ok(export_err), "export: %s", export_err.message)
}

@(private = "file")
mp_exec :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, loc := #caller_location) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message, loc = loc)
}

@(private = "file")
mp_valid :: proc(t: ^testing.T, path: string, loc := #caller_location) {
	ok, reason := db.sqlite_mirror_validate(path, context.temp_allocator)
	testing.expectf(t, ok, "the file is not valid: %s", reason, loc = loc)
}

@(test)
test_a_table_without_an_integer_key_keeps_its_rowids :: proc(t: ^testing.T) {
	path := "_test_mirror_rowids.db"
	defer os.remove(path)
	// Rowids with gaps, as SQLite leaves them after deletes.
	setup := []string {
		"CREATE TABLE c (x INTEGER, y TEXT)",
		"INSERT INTO c (rowid, x, y) VALUES (5, 1, 'a'), (9, 2, 'b'), (40, 3, 'c')",
	}
	if !mp_export(t, path, setup) do return
	conn, open_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	// The rowids are the file's, not numbered again from 1.
	testing.expect_value(t, scalar(t, conn.store, "SELECT group_concat(rowid) FROM (SELECT rowid FROM c ORDER BY rowid)").s, "5,9,40")
	mp_exec(t, conn, "INSERT INTO c (x, y) VALUES (4, 'd')")
	mp_exec(t, conn, "UPDATE c SET y = 'B' WHERE x = 2")
	mp_exec(t, conn, "DELETE FROM c WHERE x = 1")
	// Each commit was a patch, under the rows' own rowids.
	testing.expect_value(t, conn.store.mirror_full_writes, 0)
	db.embed_close(conn)
	mp_valid(t, path)

	again, again_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(again_err), "reopen: %s", again_err.message) do return
	defer db.embed_close(again)
	testing.expect_value(t, scalar(t, again.store, "SELECT group_concat(rowid || ':' || y) FROM (SELECT rowid, y FROM c ORDER BY rowid)").s, "9:B,40:c,41:d")
}

@(test)
test_a_table_with_an_index_is_patched :: proc(t: ^testing.T) {
	path := "_test_mirror_index.db"
	defer os.remove(path)
	setup := []string {
		"CREATE TABLE tags (id INTEGER PRIMARY KEY, tag TEXT, n INTEGER)",
		"CREATE INDEX tags_tag ON tags (tag)",
		"CREATE INDEX tags_n ON tags (n DESC, tag)",
		"WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 120) INSERT INTO tags SELECT i, 'tag' || (i * 7 % 120), i % 13 FROM s",
	}
	if !mp_export(t, path, setup) do return
	conn, open_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	mp_exec(t, conn, "INSERT INTO tags VALUES (1000, 'aaa first', 99)")
	mp_exec(t, conn, "UPDATE tags SET tag = 'zzz last', n = -1 WHERE id = 7")
	mp_exec(t, conn, "DELETE FROM tags WHERE id = 8")
	mp_exec(t, conn, "INSERT INTO tags SELECT id + 2000, tag || 'x', n FROM tags WHERE id < 20")
	// The indexes were built again; the file was not re-encoded.
	testing.expect_value(t, conn.store.mirror_full_writes, 0)
	db.embed_close(conn)
	// Every index holds one entry per row, in its order (DESC included).
	mp_valid(t, path)
}

