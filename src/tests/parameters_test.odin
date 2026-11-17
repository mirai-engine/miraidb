package tests

import "core:testing"

import db "../engine"

@(test)
test_numbered_and_named_parameters :: proc(t: ^testing.T) {
	// SQLite's parameter forms: `?NNN` binds the n-th value and may repeat;
	// `:name`, `@name` and `$name` take the next slot the first time a name
	// appears and the same slot after; a bare `?` takes one past the largest
	// slot so far. ORMs write `:name`, and a statement that repeats `?1` binds
	// one value once.
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)

	stmt := db.embed_prepare(conn, "SELECT ?1, :a, @b, $c, ?, :a, ?7")
	if !testing.expectf(t, stmt != nil, "prepare: %s", db.embed_error(conn)) do return
	defer db.embed_finalize(stmt)
	testing.expect_value(t, db.Embed_Parameter_Count(stmt), 7)
	names := []string{"?1", ":a", "@b", "$c", "", "", "?7"}
	for name, index in names {
		testing.expect_value(t, db.embed_parameter_name(stmt, index), name)
	}
	testing.expect_value(t, db.embed_parameter_index(stmt, ":a"), 1)
	testing.expect_value(t, db.embed_parameter_index(stmt, "$c"), 3)
	testing.expect_value(t, db.embed_parameter_index(stmt, "a"), -1)

	for value, index in ([]i64{10, 20, 30, 40, 50, 60, 70}) {
		testing.expect(t, db.error_drop(db.embed_bind_int(stmt, index, value)))
	}
	has_row, step_err := db.embed_step(stmt)
	testing.expect(t, db.error_drop(step_err) && has_row)
	// ?1, :a, @b, $c, the bare ? (slot 5), :a again (slot 2), ?7.
	for expected, column in ([]i64{10, 20, 30, 40, 50, 20, 70}) {
		testing.expect_value(t, db.embed_column_int(stmt, column), expected)
	}

	// The number is bounded as SQLite bounds it, and a `::` cast is still a cast.
	refused := db.embed_exec(conn, "SELECT ?0")
	testing.expect_value(t, refused.kind, db.Error_Kind.Sql_Syntax)
	db.error_free(&refused)
	cast_stmt := db.embed_prepare(conn, "SELECT '7'::integer + :n")
	if testing.expect(t, cast_stmt != nil) {
		testing.expect_value(t, db.Embed_Parameter_Count(cast_stmt), 1)
		testing.expect(t, db.error_drop(db.embed_bind_int(cast_stmt, 0, 1)))
		row, cast_err := db.embed_step(cast_stmt)
		testing.expect(t, db.error_drop(cast_err) && row)
		testing.expect_value(t, db.embed_column_int(cast_stmt, 0), i64(8))
		db.embed_finalize(cast_stmt)
	}
}
