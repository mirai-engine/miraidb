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

@(test)
test_a_failed_statement_is_undone_in_a_transaction :: proc(t: ^testing.T) {
	// SQLite's default resolution is ABORT: a statement that fails inside a
	// transaction is taken back whole, and the statements before it stay. The
	// engine used to keep the rows a statement staged before its failing row.
	store := fresh_db(t, "stmt_abort")
	if store == nil do return
	defer cleanup_db(store, "stmt_abort")

	run(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, u INTEGER UNIQUE)")
	run(t, store, "INSERT INTO t VALUES (100, 1000)")
	tx := db.tx_begin_write(store)
	ok := func_exec(t, tx, "INSERT INTO t VALUES (1, 10)")
	testing.expect(t, ok)
	_, dup := db.sql_execute_in_tx(tx, "INSERT INTO t VALUES (2, 20), (3, 30), (2, 40), (4, 50)")
	testing.expect_value(t, dup.kind, db.Error_Kind.Duplicate_Primary_Key)
	db.error_free(&dup)
	// An UPDATE that collides halfway is undone too.
	_, clash := db.sql_execute_in_tx(tx, "UPDATE t SET u = 7")
	testing.expect(t, clash.kind != .None)
	db.error_free(&clash)
	testing.expect(t, func_exec(t, tx, "INSERT INTO t VALUES (5, 50)"))
	testing.expect(t, db.error_ok(db.tx_commit(tx)))

	result := run(t, store, "SELECT id, u FROM t ORDER BY id")
	defer db.sql_result_destroy(&result)
	if testing.expect_value(t, len(result.rows), 3) {
		testing.expect_value(t, result.rows[0][0].i, i64(1))
		testing.expect_value(t, result.rows[0][1].i, i64(10))
		testing.expect_value(t, result.rows[1][0].i, i64(5))
		testing.expect_value(t, result.rows[2][0].i, i64(100))
		testing.expect_value(t, result.rows[2][1].i, i64(1000))
	}
}

@(private = "file")
func_exec :: proc(t: ^testing.T, tx: ^db.Tx, sql: string) -> bool {
	result, err := db.sql_execute_in_tx(tx, sql)
	db.sql_result_destroy(&result)
	if !testing.expectf(t, db.error_ok(err), "%s failed: %s", sql, err.message) {
		db.error_free(&err)
		return false
	}
	return true
}

@(test)
test_insert_conflict_resolutions :: proc(t: ^testing.T) {
	store := fresh_db(t, "conflict_modes")
	if store == nil do return
	defer cleanup_db(store, "conflict_modes")

	count :: proc(t: ^testing.T, store: ^db.Store, table: string) -> i64 {
		sql := table == "a" ? "SELECT count(*) FROM a" : table == "b" ? "SELECT count(*) FROM b" : "SELECT count(*) FROM c"
		return scalar(t, store, sql).i
	}

	// OR IGNORE skips the rows that break a key or NOT NULL and keeps the rest.
	run(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT NOT NULL)")
	run(t, store, "INSERT INTO a VALUES (1, 'a')")
	run(t, store, "INSERT OR IGNORE INTO a VALUES (1, 'x'), (2, 'b'), (3, NULL), (4, 'd')")
	testing.expect_value(t, count(t, store, "a"), i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT v FROM a WHERE id = 1").s, "a")

	// OR FAIL stops at the failing row and keeps the rows before it.
	run(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY)")
	run(t, store, "INSERT INTO b VALUES (5)")
	failed := run_error(t, store, "INSERT OR FAIL INTO b VALUES (1), (2), (5), (3)")
	testing.expect_value(t, failed.kind, db.Error_Kind.Duplicate_Primary_Key)
	testing.expect_value(t, count(t, store, "b"), i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT max(id) FROM b WHERE id < 5").i, i64(2))

	// OR ROLLBACK in a statement that owns its transaction is ABORT; inside a
	// transaction the caller opened it is refused, with the reason.
	run(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY)")
	testing.expect_value(t, run_error(t, store, "INSERT OR ROLLBACK INTO c VALUES (1), (1)").kind, db.Error_Kind.Duplicate_Primary_Key)
	testing.expect_value(t, count(t, store, "c"), i64(0))
	tx := db.tx_begin_write(store)
	_, refused := db.sql_execute_in_tx(tx, "INSERT OR ROLLBACK INTO c VALUES (1)")
	testing.expect_value(t, refused.kind, db.Error_Kind.Sql_Unsupported)
	db.error_free(&refused)
	db.tx_rollback(tx)

	// REPLACE INTO is INSERT OR REPLACE.
	run(t, store, "REPLACE INTO a VALUES (1, 'z'), (9, 'n')")
	testing.expect_value(t, scalar(t, store, "SELECT v FROM a WHERE id = 1").s, "z")
	testing.expect_value(t, count(t, store, "a"), i64(4))
}
