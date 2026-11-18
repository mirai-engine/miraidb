package tests

import "core:os"
import "core:testing"

import db "../engine"

@(test)
test_affinity_and_untyped_columns :: proc(t: ^testing.T) {
	// SQLite's typing (S7): a column without a type keeps any value, a type
	// name is read by its affinity, a text that reads as a number becomes one
	// in a numeric column, and values of different classes compare in SQLite's
	// order. STRICT and WITHOUT ROWID survive a reopen, and an untyped column
	// crosses a .sqlite export with its values' classes.
	store := fresh_db(t, "affinity")
	if store == nil do return
	run(t, store, "CREATE TABLE m (x, n NUMBERISH, i INTEGER, t TEXT, u UNSIGNED BIG INT)")
	run(t, store, "INSERT INTO m VALUES (1, '7', '12', 34, '9'), ('a', '1.5', 3.0, 1.5, 2), (x'00', 'z', 4, 'w', NULL), (NULL, 2.0, 5, NULL, 1)")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(typeof(x), ',') FROM m").s, "integer,text,blob,null")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(typeof(n), ',') FROM m").s, "integer,real,text,integer")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(typeof(i), ',') FROM m").s, "integer,integer,integer,integer")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(t, ',') FROM m").s, "34,1.5,w")
	testing.expect_value(t, scalar(t, store, "SELECT typeof(u) FROM m WHERE u = 9").s, "integer")
	// Across classes: numbers before text before blobs.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM m WHERE x > 5").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT typeof(max(x)) FROM m").s, "blob")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM m WHERE i = '12'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM m WHERE t = 34").i, i64(1))

	run(t, store, "CREATE TABLE s (i INTEGER, b BLOB) STRICT")
	run(t, store, "CREATE TABLE w (k TEXT PRIMARY KEY, v) WITHOUT ROWID")
	run(t, store, "INSERT INTO w VALUES ('a', 1)")
	db.store_close(store)

	reopened, open_err := db.store_open("_test_affinity", {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	defer cleanup_db(reopened, "affinity")
	refused := run_error(t, reopened, "INSERT INTO s VALUES ('abc', x'00')")
	testing.expect_value(t, refused.kind, db.Error_Kind.Check_Violation)
	_, rowid := db.sql_execute(reopened, "SELECT rowid FROM w")
	testing.expect_value(t, rowid.kind, db.Error_Kind.Column_Not_Found)
	testing.expect_value(t, scalar(t, reopened, "SELECT group_concat(typeof(x), ',') FROM m").s, "integer,text,blob,null")

	// The export keeps each value's class in the untyped column.
	path := "_test_affinity.sqlite"
	os.remove(path)
	defer os.remove(path)
	_, _, export_err := db.sqlite_file_write(reopened, path)
	if !testing.expectf(t, db.error_ok(export_err), "export: %s", export_err.message) do return
	imported, import_err := db.embed_open(path)
	if !testing.expectf(t, db.error_ok(import_err), "import: %s", import_err.message) do return
	defer db.embed_close(imported)
	stmt := db.embed_prepare(imported, "SELECT group_concat(typeof(x), ',') FROM m")
	if testing.expect(t, stmt != nil) {
		_, step_err := db.embed_step(stmt)
		testing.expect(t, db.error_drop(step_err))
		testing.expect_value(t, db.embed_column_text(stmt, 0), "integer,text,blob,null")
		db.embed_finalize(stmt)
	}
}
