package tests

// Tests for SQLite's surface that the engine used to refuse (roadmap items S1
// and S2). Each answer here is the one SQLite gives; scripts/differential.py
// asks SQLite itself for the same shapes.

import "core:testing"

import db "../engine"

@(test)
test_is_compares_null_as_a_value :: proc(t: ^testing.T) {
	store := fresh_db(t, "is_values")
	if store == nil do return
	defer cleanup_db(store, "is_values")

	expect_true :: proc(t: ^testing.T, store: ^db.Store, sql: string, want: bool) {
		v := scalar(t, store, sql)
		testing.expectf(t, v.kind != .Null, "%s answered NULL", sql)
		testing.expectf(t, db.value_is_truthy(v) == want, "%s answered %v", sql, v)
	}
	expect_true(t, store, "SELECT NULL IS NULL", true)
	expect_true(t, store, "SELECT 1 IS NULL", false)
	expect_true(t, store, "SELECT 1 IS 1", true)
	expect_true(t, store, "SELECT 1 IS NOT 2", true)
	expect_true(t, store, "SELECT NULL IS NOT 1", true)
	// Values of different classes are different values, not an error.
	expect_true(t, store, "SELECT 'a' IS 1", false)
	expect_true(t, store, "SELECT NULL IS DISTINCT FROM NULL", false)
	expect_true(t, store, "SELECT 1 IS DISTINCT FROM NULL", true)
	expect_true(t, store, "SELECT 2 IS NOT DISTINCT FROM 2", true)

	run(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run(t, store, "INSERT INTO t VALUES (1, 1), (2, NULL), (3, 2)")
	// `v != 1` drops the NULL row; `v IS NOT 1` keeps it.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE v != 1").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE v IS NOT 1").i, i64(2))
}

@(test)
test_bitwise_operators :: proc(t: ^testing.T) {
	store := fresh_db(t, "bitwise")
	if store == nil do return
	defer cleanup_db(store, "bitwise")

	cases := []struct {
		sql:  string,
		want: i64,
	} {
		{"SELECT 6 & 3", 2},
		{"SELECT 6 | 3", 7},
		{"SELECT ~6", -7},
		{"SELECT 1 << 2", 4},
		{"SELECT 8 >> 1", 4},
		{"SELECT -8 >> 1", -4},
		{"SELECT 1 << 64", 0},
		{"SELECT 1 << -1", 0},
		{"SELECT 4 >> -1", 8},
		{"SELECT 6.7 & 3", 2},
		{"SELECT '6' | 1", 7},
		// Bitwise binds looser than `+` and tighter than `=`.
		{"SELECT 1 + 2 & 3", 3},
		{"SELECT 1 << 2 + 1", 8},
	}
	for c in cases {
		testing.expectf(t, scalar(t, store, c.sql).i == c.want, "%s: want %d", c.sql, c.want)
	}
	testing.expect_value(t, scalar(t, store, "SELECT 5 & NULL").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT ~NULL").kind, db.Value_Kind.Null)
	testing.expect(t, db.value_is_truthy(scalar(t, store, "SELECT 4 | 1 = 5")))
	// A blob is not an integer.
	testing.expect_value(t, run_error(t, store, "SELECT x'01' & 1").kind, db.Error_Kind.Invalid_Type)
}

@(test)
test_json_arrow_operators :: proc(t: ^testing.T) {
	store := fresh_db(t, "json_arrow")
	if store == nil do return
	defer cleanup_db(store, "json_arrow")

	// `->` answers JSON text, `->>` the SQL value.
	testing.expect_value(t, scalar(t, store, `SELECT '{"a":{"b":[1,2]}}' -> '$.a'`).s, `{"b":[1,2]}`)
	testing.expect_value(t, scalar(t, store, `SELECT '{"a":{"b":[1,2]}}' ->> '$.a.b[1]'`).i, i64(2))
	testing.expect_value(t, scalar(t, store, `SELECT '{"a":"x"}' -> 'a'`).s, `"x"`)
	testing.expect_value(t, scalar(t, store, `SELECT '{"a":"x"}' ->> 'a'`).s, "x")
	testing.expect_value(t, scalar(t, store, `SELECT '[5,6]' ->> 1`).i, i64(6))
	testing.expect_value(t, scalar(t, store, `SELECT '{"a":1}' -> 'zz'`).kind, db.Value_Kind.Null)
	// Keys are case sensitive, as in SQLite.
	testing.expect_value(t, scalar(t, store, `SELECT json_extract('{"A":1}', '$.a')`).kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, `SELECT json_extract('{"A":1}', '$.A')`).i, i64(1))
	// `5 -3` is still a subtraction.
	testing.expect_value(t, scalar(t, store, "SELECT 5 -3").i, i64(2))
}

@(test)
test_limit_with_a_comma :: proc(t: ^testing.T) {
	store := fresh_db(t, "limit_comma")
	if store == nil do return
	defer cleanup_db(store, "limit_comma")

	run(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	run(t, store, "INSERT INTO t VALUES (1), (2), (3), (4), (5), (6)")
	// `LIMIT 2, 3` is `LIMIT 3 OFFSET 2`.
	result := run(t, store, "SELECT id FROM t ORDER BY id LIMIT 2, 3")
	defer db.sql_result_destroy(&result)
	if testing.expect_value(t, len(result.rows), 3) {
		testing.expect_value(t, result.rows[0][0].i, i64(3))
		testing.expect_value(t, result.rows[2][0].i, i64(5))
	}
}
