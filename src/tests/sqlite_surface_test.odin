package tests

// Tests for SQLite's surface that the engine used to refuse (roadmap items S1
// and S2). Each answer here is the one SQLite gives; scripts/differential.py
// asks SQLite itself for the same shapes.

import "core:mem"
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

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1, 1), (2, NULL), (3, 2)")
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

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO t VALUES (1), (2), (3), (4), (5), (6)")
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

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, u INTEGER UNIQUE)")
	run_done(t, store, "INSERT INTO t VALUES (100, 1000)")
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
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO a VALUES (1, 'a')")
	run_done(t, store, "INSERT OR IGNORE INTO a VALUES (1, 'x'), (2, 'b'), (3, NULL), (4, 'd')")
	testing.expect_value(t, count(t, store, "a"), i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT v FROM a WHERE id = 1").s, "a")

	// OR FAIL stops at the failing row and keeps the rows before it.
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO b VALUES (5)")
	failed := run_error(t, store, "INSERT OR FAIL INTO b VALUES (1), (2), (5), (3)")
	testing.expect_value(t, failed.kind, db.Error_Kind.Duplicate_Primary_Key)
	testing.expect_value(t, count(t, store, "b"), i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT max(id) FROM b WHERE id < 5").i, i64(2))

	// OR ROLLBACK in a statement that owns its transaction is ABORT; inside a
	// transaction the caller opened, a broken constraint ends that transaction,
	// as in SQLite: its earlier work goes too.
	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY)")
	testing.expect_value(t, run_error(t, store, "INSERT OR ROLLBACK INTO c VALUES (1), (1)").kind, db.Error_Kind.Duplicate_Primary_Key)
	testing.expect_value(t, count(t, store, "c"), i64(0))
	{
		conn := db.embed_wrap(store)
		defer db.embed_close(conn)
		testing.expect(t, db.error_drop(db.embed_exec(conn, "BEGIN")))
		testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO c VALUES (5)")))
		testing.expect(t, !db.error_drop(db.embed_exec(conn, "INSERT OR ROLLBACK INTO c VALUES (5)")))
		testing.expect(t, !db.embed_in_transaction(conn))
	}
	testing.expect_value(t, count(t, store, "c"), i64(0))

	// REPLACE INTO is INSERT OR REPLACE.
	run_done(t, store, "REPLACE INTO a VALUES (1, 'z'), (9, 'n')")
	testing.expect_value(t, scalar(t, store, "SELECT v FROM a WHERE id = 1").s, "z")
	testing.expect_value(t, count(t, store, "a"), i64(4))
}

@(private = "file")
column_ints :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> [dynamic]i64 {
	out := make([dynamic]i64, context.temp_allocator)
	result := run(t, store, sql)
	defer db.sql_result_destroy(&result)
	for row in result.rows do append(&out, row[0].kind == .Null ? -1 : row[0].i)
	return out
}

@(private = "file")
expect_ints :: proc(t: ^testing.T, store: ^db.Store, sql: string, want: []i64) {
	got := column_ints(t, store, sql)
	ok := len(got) == len(want)
	if ok do for v, i in want do if got[i] != v do ok = false
	testing.expectf(t, ok, "%s: got %v, want %v (-1 is NULL)", sql, got[:], want)
}

@(test)
test_compound_operators :: proc(t: ^testing.T) {
	store := fresh_db(t, "compound_ops")
	if store == nil do return
	defer cleanup_db(store, "compound_ops")

	run_done(t, store, "CREATE TABLE n (x INTEGER)")
	run_done(t, store, "INSERT INTO n VALUES (1), (2), (2), (3), (NULL)")
	expect_ints(t, store, "SELECT x FROM n INTERSECT SELECT 2 ORDER BY 1", {2})
	expect_ints(t, store, "SELECT x FROM n EXCEPT SELECT 2 ORDER BY 1", {-1, 1, 3})
	// Left to right: the UNION removes the duplicate, the UNION ALL after it adds one.
	expect_ints(t, store, "SELECT 1 UNION SELECT 1 UNION ALL SELECT 1", {1, 1})
	expect_ints(t, store, "SELECT x FROM n UNION ALL SELECT 5 EXCEPT SELECT 1 ORDER BY 1", {-1, 2, 3, 5})
	expect_ints(t, store, "SELECT x FROM n INTERSECT SELECT 2 UNION SELECT 9 ORDER BY 1", {2, 9})
}

@(test)
test_nulls_first_and_last :: proc(t: ^testing.T) {
	store := fresh_db(t, "nulls_order")
	if store == nil do return
	defer cleanup_db(store, "nulls_order")

	run_done(t, store, "CREATE TABLE n (id INTEGER PRIMARY KEY, x INTEGER)")
	run_done(t, store, "CREATE INDEX n_x ON n (x)")
	run_done(t, store, "INSERT INTO n VALUES (1, 2), (2, NULL), (3, 1)")
	// The defaults: NULL is the smallest value.
	expect_ints(t, store, "SELECT x FROM n ORDER BY x", {-1, 1, 2})
	expect_ints(t, store, "SELECT x FROM n ORDER BY x DESC", {2, 1, -1})
	// Explicit placement, whatever the direction; the index walk cannot give it.
	expect_ints(t, store, "SELECT x FROM n ORDER BY x NULLS LAST", {1, 2, -1})
	expect_ints(t, store, "SELECT x FROM n ORDER BY x DESC NULLS FIRST", {-1, 2, 1})
	expect_ints(t, store, "SELECT id, row_number() OVER (ORDER BY x NULLS LAST) AS r FROM n ORDER BY r", {3, 1, 2})
	// An ORDER BY expression that fails is the statement's error. It used to sort
	// as NULL, so a misspelt column or a window here returned unsorted rows.
	testing.expect_value(t, run_error(t, store, "SELECT id FROM n ORDER BY no_such_column").kind, db.Error_Kind.Column_Not_Found)
	testing.expect(t, run_error(t, store, "SELECT id FROM n ORDER BY row_number() OVER (ORDER BY x)").kind != .None)
}

@(test)
test_derived_tables_and_values :: proc(t: ^testing.T) {
	store := fresh_db(t, "derived")
	if store == nil do return
	defer cleanup_db(store, "derived")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)")
	expect_ints(t, store, "SELECT s.v FROM (SELECT v FROM t WHERE v > 10) AS s ORDER BY s.v", {20, 30})
	expect_ints(t, store, "SELECT count(*) FROM (SELECT id FROM t UNION SELECT 7)", {4})
	expect_ints(t, store, "SELECT column1 FROM (VALUES (5, 'a'), (6, 'b'))", {5, 6})
	expect_ints(t, store, "VALUES (8), (9)", {8, 9})
	expect_ints(t, store, "SELECT t.v FROM t JOIN (VALUES (2), (3)) AS k ON k.column1 = t.id ORDER BY t.v", {20, 30})
	testing.expect_value(t, run_error(t, store, "SELECT * FROM (VALUES (1), (2, 3))").kind, db.Error_Kind.Sql_Syntax)

	// A CTE or derived table named like a real table hides it for its statement
	// only: the next statement of the same transaction reads the table again.
	tx := db.tx_begin_write(store)
	shadow, shadow_err := db.sql_execute_in_tx(tx, "WITH t AS (SELECT 99 AS v) SELECT v FROM t")
	testing.expect(t, db.error_ok(shadow_err))
	if testing.expect_value(t, len(shadow.rows), 1) do testing.expect_value(t, shadow.rows[0][0].i, i64(99))
	db.sql_result_destroy(&shadow)
	real, real_err := db.sql_execute_in_tx(tx, "SELECT count(*) FROM t")
	testing.expect(t, db.error_ok(real_err))
	if testing.expect_value(t, len(real.rows), 1) do testing.expect_value(t, real.rows[0][0].i, i64(3))
	db.sql_result_destroy(&real)
	db.tx_rollback(tx)
}

@(test)
test_row_values :: proc(t: ^testing.T) {
	store := fresh_db(t, "row_values")
	if store == nil do return
	defer cleanup_db(store, "row_values")

	run_done(t, store, "CREATE TABLE p (a INTEGER, b TEXT)")
	run_done(t, store, "INSERT INTO p VALUES (1, 'x'), (2, 'y'), (2, 'z'), (3, NULL)")
	expect_ints(t, store, "SELECT a FROM p WHERE (a, b) = (2, 'y')", {2})
	expect_ints(t, store, "SELECT a FROM p WHERE (a, b) > (2, 'y') ORDER BY a", {2, 3})
	expect_ints(t, store, "SELECT a FROM p WHERE (a, b) IN ((1, 'x'), (2, 'z')) ORDER BY a", {1, 2})
	expect_ints(t, store, "SELECT a FROM p WHERE (a, b) IN (SELECT a, b FROM p WHERE a > 1) ORDER BY a", {2, 2})
	// NULL in a deciding column makes the comparison unknown.
	testing.expect_value(t, scalar(t, store, "SELECT (1, NULL) = (1, 2)").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT (1, 2) IN (SELECT 1, NULL)").kind, db.Value_Kind.Null)
	testing.expect(t, db.value_is_truthy(scalar(t, store, "SELECT (1, NULL) < (2, 0)")))
	testing.expect(t, db.value_is_truthy(scalar(t, store, "SELECT (NULL, 1) IS (NULL, 1)")))
	// A row value alone, or of the wrong width, is refused as in SQLite.
	testing.expect_value(t, run_error(t, store, "SELECT (1, 2)").kind, db.Error_Kind.Sql_Syntax)
	testing.expect_value(t, run_error(t, store, "SELECT (1, 2) = (1, 2, 3)").kind, db.Error_Kind.Sql_Syntax)
}

@(test)
test_check_constraints :: proc(t: ^testing.T) {
	store := fresh_db(t, "checks")
	if store == nil do return

	run_done(t, store, `CREATE TABLE p (
		id INTEGER PRIMARY KEY,
		name TEXT CONSTRAINT name_len CHECK (length(name) > 1),
		qty INTEGER CHECK (qty >= 0),
		CHECK (qty < 100 OR name = 'big'))`)
	run_done(t, store, "INSERT INTO p VALUES (1, 'ab', 5)")
	named := run_error(t, store, "INSERT INTO p VALUES (2, 'a', 5)")
	testing.expect_value(t, named.kind, db.Error_Kind.Check_Violation)
	testing.expect_value(t, named.message, "CHECK constraint failed: name_len")
	unnamed := run_error(t, store, "INSERT INTO p VALUES (3, 'cd', -1)")
	testing.expect_value(t, unnamed.message, "CHECK constraint failed: qty >= 0")
	testing.expect_value(t, run_error(t, store, "INSERT INTO p VALUES (4, 'cd', 500)").kind, db.Error_Kind.Check_Violation)
	run_done(t, store, "INSERT INTO p VALUES (5, 'big', 500)")
	// NULL passes a CHECK, as in SQL.
	run_done(t, store, "INSERT INTO p VALUES (6, NULL, NULL)")
	testing.expect_value(t, run_error(t, store, "UPDATE p SET qty = -5 WHERE id = 1").kind, db.Error_Kind.Check_Violation)
	// OR IGNORE skips a row a CHECK refuses.
	run_done(t, store, "INSERT OR IGNORE INTO p VALUES (7, 'x', 1), (8, 'xy', 1)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM p").i, i64(4))
	// A malformed CHECK is refused with the table.
	testing.expect(t, run_error(t, store, "CREATE TABLE bad (x INTEGER CHECK (x >))").kind != .None)

	// The constraints are part of the schema the log keeps.
	db.store_close(store)
	reopened, err := db.store_open("_test_checks", {persistent = true, create = false, durable = false})
	testing.expect(t, db.error_ok(err))
	defer cleanup_db(reopened, "checks")
	testing.expect_value(t, run_error(t, reopened, "INSERT INTO p VALUES (9, 'z', 1)").kind, db.Error_Kind.Check_Violation)
	run_done(t, reopened, "INSERT INTO p VALUES (10, 'zz', 1)")

	// A column's own CHECK goes with the column; one that names it from the
	// table blocks the drop, and a rename rewrites the CHECK, as in SQLite.
	run_done(t, reopened, "CREATE TABLE d (id INTEGER PRIMARY KEY, q INTEGER CHECK (q > 0), r INTEGER, CHECK (r < 10))")
	run_done(t, reopened, "ALTER TABLE d DROP COLUMN q")
	testing.expect_value(t, run_error(t, reopened, "ALTER TABLE d DROP COLUMN r").kind, db.Error_Kind.Sql_Unsupported)
	run_done(t, reopened, "ALTER TABLE d RENAME COLUMN r TO s")
	testing.expect_value(t, run_error(t, reopened, "INSERT INTO d VALUES (1, 50)").kind, db.Error_Kind.Check_Violation)
	run_done(t, reopened, "INSERT INTO d (id, s) VALUES (2, 5)")
}

@(test)
test_column_references_and_defaults :: proc(t: ^testing.T) {
	store := fresh_db(t, "col_refs")
	if store == nil do return

	run_done(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO p VALUES (1)")
	// A column-level REFERENCES, with the parent's key implied.
	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, pid INTEGER CONSTRAINT to_p REFERENCES p ON DELETE CASCADE, note TEXT DEFAULT 'none')")
	run_done(t, store, "INSERT INTO c (id, pid) VALUES (1, 1)")
	testing.expect(t, run_error(t, store, "INSERT INTO c (id, pid) VALUES (2, 99)").kind != .None)
	testing.expect_value(t, scalar(t, store, "SELECT note FROM c WHERE id = 1").s, "none")
	run_done(t, store, "DELETE FROM p WHERE id = 1")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM c").i, i64(0))
	// A table may reference itself.
	run_done(t, store, "CREATE TABLE tree (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES tree (id))")
	run_done(t, store, "INSERT INTO tree VALUES (1, NULL), (2, 1)")
	testing.expect(t, run_error(t, store, "INSERT INTO tree VALUES (3, 42)").kind != .None)

	// CURRENT_TIMESTAMP and its siblings, as values and as a per-row DEFAULT.
	testing.expect_value(t, scalar(t, store, "SELECT length(CURRENT_TIMESTAMP)").i, i64(19))
	testing.expect_value(t, scalar(t, store, "SELECT length(CURRENT_DATE)").i, i64(10))
	testing.expect_value(t, scalar(t, store, "SELECT length(CURRENT_TIME)").i, i64(8))
	run_done(t, store, "CREATE TABLE stamps (id INTEGER PRIMARY KEY, at TEXT DEFAULT CURRENT_TIMESTAMP, n INTEGER DEFAULT (1 + 1))")
	run_done(t, store, "INSERT INTO stamps (id) VALUES (1)")
	testing.expect(t, db.value_is_truthy(scalar(t, store, "SELECT at = datetime('now') OR at < datetime('now') FROM stamps")))
	testing.expect_value(t, scalar(t, store, "SELECT n FROM stamps").i, i64(2))

	// Index and key columns may carry a direction.
	run_done(t, store, "CREATE INDEX stamps_at ON stamps (at DESC, id ASC)")
	run_done(t, store, "CREATE TABLE k (a INTEGER, b INTEGER, PRIMARY KEY (a DESC, b))")
	// ON CONFLICT on a constraint is accepted (test_constraint_on_conflict).
	run_done(t, store, "CREATE TABLE oc (x INTEGER UNIQUE ON CONFLICT REPLACE)")

	// The per-row default survives a reopen.
	db.store_close(store)
	reopened, err := db.store_open("_test_col_refs", {persistent = true, create = false, durable = false})
	testing.expect(t, db.error_ok(err))
	defer cleanup_db(reopened, "col_refs")
	run_done(t, reopened, "INSERT INTO stamps (id) VALUES (2)")
	testing.expect_value(t, scalar(t, reopened, "SELECT length(at) FROM stamps WHERE id = 2").i, i64(19))
}

@(test)
test_deferred_foreign_keys :: proc(t: ^testing.T) {
	store := fresh_db(t, "deferred_fk")
	if store == nil do return
	defer cleanup_db(store, "deferred_fk")

	run_done(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p (id) DEFERRABLE INITIALLY DEFERRED)")
	// The child may come first; the commit finds its parent.
	tx := db.tx_begin_write(store)
	testing.expect(t, func_exec(t, tx, "INSERT INTO c VALUES (1, 10)"))
	testing.expect(t, func_exec(t, tx, "INSERT INTO p VALUES (10)"))
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	// A commit that leaves a child without its parent is refused and rolled back.
	tx = db.tx_begin_write(store)
	testing.expect(t, func_exec(t, tx, "INSERT INTO c VALUES (2, 20)"))
	broken := db.tx_commit(tx)
	testing.expect(t, broken.kind != .None)
	db.error_free(&broken)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM c").i, i64(1))
	// A parent replaced within the transaction is fine.
	tx = db.tx_begin_write(store)
	testing.expect(t, func_exec(t, tx, "DELETE FROM p WHERE id = 10"))
	testing.expect(t, func_exec(t, tx, "INSERT INTO p VALUES (10)"))
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	// In autocommit the statement is the transaction: checked at its end.
	testing.expect(t, run_error(t, store, "INSERT INTO c VALUES (3, 30)").kind != .None)
	// NOT DEFERRABLE and INITIALLY IMMEDIATE check at once, as before.
	run_done(t, store, "CREATE TABLE i (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p (id) DEFERRABLE INITIALLY IMMEDIATE)")
	tx = db.tx_begin_write(store)
	_, now := db.sql_execute_in_tx(tx, "INSERT INTO i VALUES (1, 77)")
	testing.expect(t, now.kind != .None)
	db.error_free(&now)
	db.tx_rollback(tx)
}

@(test)
test_partial_and_expression_indexes :: proc(t: ^testing.T) {
	store := fresh_db(t, "partial_idx")
	if store == nil do return

	run_done(t, store, "CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT, deleted INTEGER DEFAULT 0)")
	run_done(t, store, "INSERT INTO u (id, email) VALUES (1, 'A@x.io'), (2, 'b@x.io'), (3, NULL), (4, NULL)")
	// Unique over an expression, among the live rows only.
	run_done(t, store, "CREATE UNIQUE INDEX u_live ON u (lower(email)) WHERE deleted = 0")
	testing.expect_value(t, run_error(t, store, "INSERT INTO u (id, email) VALUES (5, 'a@X.io')").kind, db.Error_Kind.Duplicate_Unique)
	run_done(t, store, "UPDATE u SET deleted = 1 WHERE id = 1")
	run_done(t, store, "INSERT INTO u (id, email) VALUES (5, 'a@X.io')")
	// A row outside the index is not constrained by it, and moving it back in is.
	run_done(t, store, "INSERT INTO u (id, email, deleted) VALUES (6, 'b@x.io', 1)")
	testing.expect_value(t, run_error(t, store, "UPDATE u SET deleted = 0 WHERE id = 1").kind, db.Error_Kind.Duplicate_Unique)
	// OR IGNORE and REPLACE see the index, the defaults of the row included.
	run_done(t, store, "INSERT OR IGNORE INTO u (id, email) VALUES (8, 'B@x.io'), (9, 'c@x.io')")
	run_done(t, store, "REPLACE INTO u (id, email) VALUES (10, 'C@X.IO')")
	expect_ints(t, store, "SELECT id FROM u ORDER BY id", {1, 2, 3, 4, 5, 6, 10})
	// Queries answer from the rows, whatever the index holds.
	expect_ints(t, store, "SELECT id FROM u WHERE lower(email) = 'b@x.io' ORDER BY id", {2, 6})
	expect_ints(t, store, "SELECT id FROM u WHERE deleted = 0 ORDER BY id", {2, 3, 4, 5, 10})

	// A UNIQUE index the rows already break is refused, plain or not.
	run_done(t, store, "CREATE TABLE d (id INTEGER PRIMARY KEY, x INTEGER)")
	run_done(t, store, "INSERT INTO d VALUES (1, 5), (2, 5), (3, 6)")
	testing.expect_value(t, run_error(t, store, "CREATE UNIQUE INDEX d_x ON d (x)").kind, db.Error_Kind.Duplicate_Unique)
	expect_ints(t, store, "SELECT count(*) FROM d WHERE x = 5", {2})
	run_done(t, store, "CREATE UNIQUE INDEX d_pair ON d (x, id % 2)")
	run_done(t, store, "CREATE UNIQUE INDEX d_six ON d (x) WHERE x > 5")
	// What changes between evaluations cannot key an index.
	testing.expect_value(t, run_error(t, store, "CREATE INDEX d_r ON d (random())").kind, db.Error_Kind.Sql_Unsupported)
	testing.expect_value(t, run_error(t, store, "CREATE INDEX d_n ON d (x) WHERE x > (SELECT 1)").kind, db.Error_Kind.Sql_Unsupported)
	testing.expect_value(t, run_error(t, store, "CREATE INDEX d_t ON d (date('now'))").kind, db.Error_Kind.Sql_Unsupported)

	// The index survives a reopen and is enforced after it.
	db.store_close(store)
	reopened, err := db.store_open("_test_partial_idx", {persistent = true, create = false, durable = false})
	testing.expect(t, db.error_ok(err))
	defer cleanup_db(reopened, "partial_idx")
	testing.expect_value(t, run_error(t, reopened, "INSERT INTO u (id, email) VALUES (11, 'B@X.IO')").kind, db.Error_Kind.Duplicate_Unique)
	run_done(t, reopened, "INSERT INTO u (id, email, deleted) VALUES (12, 'B@X.IO', 1)")
	testing.expect_value(t, run_error(t, reopened, "INSERT INTO d VALUES (4, 6)").kind, db.Error_Kind.Duplicate_Unique)
	run_done(t, reopened, "DROP INDEX d_six")
	run_done(t, reopened, "INSERT INTO d VALUES (4, 6)")
}

@(test)
test_unique_allows_many_nulls :: proc(t: ^testing.T) {
	// SQL holds no two NULLs equal, so a UNIQUE column takes any number of them;
	// the engine refused the second.
	store := fresh_db(t, "unique_nulls")
	if store == nil do return
	defer cleanup_db(store, "unique_nulls")

	run_done(t, store, "CREATE TABLE n (id INTEGER PRIMARY KEY, x INTEGER UNIQUE, a INTEGER, b INTEGER, UNIQUE (a, b))")
	run_done(t, store, "INSERT INTO n VALUES (1, NULL, 1, NULL), (2, NULL, 1, NULL), (3, 5, 1, 2)")
	testing.expect_value(t, run_error(t, store, "INSERT INTO n VALUES (4, 5, 9, 9)").kind, db.Error_Kind.Duplicate_Unique)
	testing.expect_value(t, run_error(t, store, "INSERT INTO n VALUES (5, 7, 1, 2)").kind, db.Error_Kind.Duplicate_Unique)
	expect_ints(t, store, "SELECT count(*) FROM n WHERE x IS NULL", {2})
	run_done(t, store, "UPDATE n SET x = NULL WHERE id = 3")
	run_done(t, store, "DELETE FROM n WHERE id = 1")
	expect_ints(t, store, "SELECT id FROM n WHERE x IS NULL ORDER BY id", {2, 3})
	run_done(t, store, "INSERT INTO n VALUES (6, 5, NULL, NULL)")
}

@(test)
test_unique_null_check_allocates_nothing :: proc(t: ^testing.T) {
	// Every write asks each UNIQUE index whether the row's key has a NULL. For an
	// index over plain columns that is a look at the columns: encoding the key
	// into a heap buffer to find out made updates 40% slower.
	store := fresh_db(t, "unique_null_alloc")
	if store == nil do return
	defer cleanup_db(store, "unique_null_alloc")

	run_done(t, store, "CREATE TABLE n (id INTEGER PRIMARY KEY, a INTEGER, b TEXT, UNIQUE (a, b))")
	run_done(t, store, "CREATE UNIQUE INDEX n_e ON n (a + 1)")
	reader := db.tx_begin_read(store)
	defer db.tx_end(reader)
	table := db.tx_table_probe(reader, "n")
	if !testing.expect(t, table != nil) do return
	plain, expression := -1, -1
	for index, i in table.indexes {
		if index.schema.name == "n_e" do expression = i
		else if len(index.schema.columns) == 2 do plain = i
	}
	if !testing.expect(t, plain >= 0 && expression >= 0) do return

	full := []db.Value{db.value_int(1), db.value_int(2), db.value_string("x")}
	half := []db.Value{db.value_int(1), db.value_int(2), db.value_null()}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		testing.expect(t, !db.index_key_has_null(table, plain, full))
		testing.expect(t, db.index_key_has_null(table, plain, half))
	}
	testing.expect_value(t, track.total_allocation_count, 0)
	// An expression part is still evaluated: a + 1 over a NULL is NULL.
	testing.expect(t, !db.index_key_has_null(table, expression, full))
	testing.expect(t, db.index_key_has_null(table, expression, []db.Value{db.value_int(1), db.value_null(), db.value_string("x")}))
}

@(test)
test_functions_give_null_for_null :: proc(t: ^testing.T) {
	store := fresh_db(t, "null_args")
	if store == nil do return
	defer cleanup_db(store, "null_args")

	for sql in ([]string{
		"SELECT lower(NULL)", "SELECT upper(NULL)", "SELECT replace(NULL, 'a', 'b')",
		"SELECT replace('a', NULL, 'b')", "SELECT instr(NULL, 'a')", "SELECT sign(NULL)",
		"SELECT sqrt(NULL)", "SELECT printf(NULL)",
	}) {
		testing.expectf(t, scalar(t, store, sql).kind == .Null, "%s should be NULL", sql)
	}
	testing.expect_value(t, scalar(t, store, "SELECT hex(char(NULL))").s, "00")
}
