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

@(test)
test_empty_aggregate_bare_column :: proc(t: ^testing.T) {
	store := fresh_db(t, "empty_aggregate")
	if store == nil do return
	defer cleanup_db(store, "empty_aggregate")
	run_done(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY, score REAL)")

	// An aggregate over no row answers one row, and a bare column in it is
	// NULL: it used to fail with "column id does not exist" until the table had
	// a row.
	result, err := db.sql_execute(store, "SELECT count(*), id * 2, p.score FROM p")
	defer db.sql_result_destroy(&result)
	if testing.expectf(t, db.error_ok(err), "empty aggregate: %s", err.message) && testing.expect_value(t, len(result.rows), 1) {
		testing.expect_value(t, result.rows[0][0].i, i64(0))
		testing.expect_value(t, result.rows[0][1].kind, db.Value_Kind.Null)
		testing.expect_value(t, result.rows[0][2].kind, db.Value_Kind.Null)
	}
	grouped, grouped_err := db.sql_execute(store, "SELECT count(*) FROM p GROUP BY score")
	defer db.sql_result_destroy(&grouped)
	testing.expect(t, db.error_ok(grouped_err))
	testing.expect_value(t, len(grouped.rows), 0)
}

@(test)
test_expression_column_names :: proc(t: ^testing.T) {
	store := fresh_db(t, "expression_names")
	if store == nil do return
	defer cleanup_db(store, "expression_names")
	run_done(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY, score REAL)")

	// An unaliased expression is ?column? by default, and named by its text
	// when the store asks for SQLite's names.
	named, _ := db.sql_execute(store, "SELECT count(*), 1+2, id AS k FROM p")
	defer db.sql_result_destroy(&named)
	testing.expect_value(t, named.columns[0], "?column?")
	store.sqlite_names = true
	sqlite_named, _ := db.sql_execute(store, "SELECT count(*), 1+2, id AS k FROM p")
	defer db.sql_result_destroy(&sqlite_named)
	if testing.expect_value(t, len(sqlite_named.columns), 3) {
		testing.expect_value(t, sqlite_named.columns[0], "count(*)")
		testing.expect_value(t, sqlite_named.columns[1], "1+2")
		testing.expect_value(t, sqlite_named.columns[2], "k")
	}
}
