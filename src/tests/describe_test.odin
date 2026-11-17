package tests

import "core:testing"

import db "../engine"

@(test)
test_result_column_origins :: proc(t: ^testing.T) {
	// A result column that names a table's column has an origin: the table's
	// real name (not its alias), the column and its type. An expression has
	// none, and a statement whose source is not a table answers nothing rather
	// than a guess. This is what sqlite3_column_table_name, _origin_name and
	// _decltype read.
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	setup := db.embed_exec(conn, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score REAL)")
	testing.expect(t, db.error_drop(setup))

	stmt := db.embed_prepare(conn, "SELECT p.name, score * 2, id AS key FROM people p")
	if !testing.expect(t, stmt != nil) do return
	origins := db.embed_column_origins(stmt)
	defer db.embed_column_origins_destroy(origins)
	if testing.expect_value(t, len(origins), 3) {
		testing.expect_value(t, origins[0].table, "people")
		testing.expect_value(t, origins[0].column, "name")
		testing.expect_value(t, origins[0].decltype, "TEXT")
		testing.expect_value(t, origins[1].table, "")
		testing.expect_value(t, origins[2].column, "id")
		testing.expect_value(t, origins[2].decltype, "INTEGER")
	}
	db.embed_finalize(stmt)

	derived := db.embed_prepare(conn, "SELECT name FROM (SELECT name FROM people) AS d")
	if testing.expect(t, derived != nil) {
		testing.expect(t, db.embed_column_origins(derived) == nil)
		db.embed_finalize(derived)
	}

	// Inside an open transaction the description sees the tables it created.
	testing.expect(t, db.error_drop(db.embed_exec(conn, "BEGIN")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE later (v BLOB)")))
	fresh := db.embed_prepare(conn, "SELECT v FROM later")
	if testing.expect(t, fresh != nil) {
		later := db.embed_column_origins(fresh)
		defer db.embed_column_origins_destroy(later)
		if testing.expect_value(t, len(later), 1) do testing.expect_value(t, later[0].decltype, "BLOB")
		db.embed_finalize(fresh)
	}
	testing.expect(t, db.error_drop(db.embed_exec(conn, "ROLLBACK")))
}
