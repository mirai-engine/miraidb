package tests

import "core:testing"

import db "../engine"

// A correlated reference reads a column of the statement the subquery is written
// in. It was refused ("column not found") before, which is also what LATERAL
// needs: one evaluation of the subquery per row of the sources to its left.

@(test)
test_correlated_subqueries :: proc(t: ^testing.T) {
	store := fresh_db(t, "correlated")
	if store == nil do return
	defer cleanup_db(store, "correlated")

	run_done(t, store, "CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept INTEGER, salary INTEGER)")
	run_done(t, store, "INSERT INTO emp VALUES (1, 'a', 1, 100), (2, 'b', 1, 200), (3, 'c', 2, 150)")

	// A scalar subquery compared against the row it belongs to.
	rows := run(
		t,
		store,
		"SELECT name FROM emp e WHERE salary > (SELECT avg(salary) FROM emp WHERE dept = e.dept) ORDER BY name",
	)
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect_value(t, rows.rows[0][0].s, "b")
	db.sql_result_destroy(&rows)

	// EXISTS, IN and a count(*) all read the outer row.
	exists := run(
		t,
		store,
		"SELECT name FROM emp e WHERE EXISTS (SELECT 1 FROM emp x WHERE x.dept = e.dept AND x.salary > 180) ORDER BY name",
	)
	testing.expect_value(t, len(exists.rows), 2)
	testing.expect_value(t, exists.rows[0][0].s, "a")
	db.sql_result_destroy(&exists)

	counted := run(
		t,
		store,
		"SELECT name FROM emp e WHERE (SELECT count(*) FROM emp x WHERE x.dept = e.dept) > 1 ORDER BY name",
	)
	testing.expect_value(t, len(counted.rows), 2)
	db.sql_result_destroy(&counted)

	// Two frames deep: the innermost statement still sees the outermost row.
	deep := run(
		t,
		store,
		"SELECT name FROM emp e WHERE salary = (SELECT max(salary) FROM emp WHERE dept IN (SELECT d.dept FROM emp d WHERE d.id = e.id)) ORDER BY name",
	)
	testing.expect_value(t, len(deep.rows), 2) // b and c are the best of their dept
	db.sql_result_destroy(&deep)

	// A column that exists nowhere is still an error, not a crash.
	missing := run_error(t, store, "SELECT (SELECT nope FROM emp) FROM emp")
	defer db.error_free(&missing)
	testing.expect_value(t, missing.kind, db.Error_Kind.Column_Not_Found)
}

@(test)
test_lateral_subqueries :: proc(t: ^testing.T) {
	store := fresh_db(t, "lateral")
	if store == nil do return
	defer cleanup_db(store, "lateral")

	run_done(t, store, "CREATE TABLE dept (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "INSERT INTO dept VALUES (1, 'eng'), (2, 'sales'), (3, 'empty')")
	run_done(t, store, "CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept INTEGER, salary INTEGER)")
	run_done(t, store, "INSERT INTO emp VALUES (1, 'a', 1, 100), (2, 'b', 1, 200), (3, 'c', 2, 150)")

	// One evaluation per department: the aggregates differ per row.
	rows := run(
		t,
		store,
		"SELECT d.name, x.n, x.top FROM dept d, LATERAL (SELECT count(*) AS n, max(salary) AS top FROM emp WHERE dept = d.id) x ORDER BY d.id",
	)
	testing.expect_value(t, len(rows.rows), 3)
	testing.expect_value(t, rows.rows[0][1].i, i64(2))
	testing.expect_value(t, rows.rows[0][2].i, i64(200))
	testing.expect_value(t, rows.rows[1][1].i, i64(1))
	testing.expect_value(t, rows.rows[1][2].i, i64(150))
	testing.expect_value(t, rows.rows[2][1].i, i64(0))
	testing.expect_value(t, rows.rows[2][2].kind, db.Value_Kind.Null)
	db.sql_result_destroy(&rows)

	// LEFT JOIN LATERAL keeps the department that matches nothing.
	left := run(
		t,
		store,
		"SELECT d.name, x.top FROM dept d LEFT JOIN LATERAL (SELECT max(salary) AS top FROM emp WHERE dept = d.id) x ON true ORDER BY d.id",
	)
	testing.expect_value(t, len(left.rows), 3)
	testing.expect_value(t, left.rows[2][1].kind, db.Value_Kind.Null)
	db.sql_result_destroy(&left)

	// An ON condition over the lateral row filters like any join.
	filtered := run(
		t,
		store,
		"SELECT d.name FROM dept d JOIN LATERAL (SELECT max(salary) AS top FROM emp WHERE dept = d.id) x ON x.top > 120 ORDER BY d.id",
	)
	testing.expect_value(t, len(filtered.rows), 2)
	db.sql_result_destroy(&filtered)

	// A derived table without LATERAL is still evaluated once, which is the
	// difference the keyword makes.
	once := run(
		t,
		store,
		"SELECT d.name, y.n FROM dept d, (SELECT count(*) AS n FROM emp) y ORDER BY d.id",
	)
	testing.expect_value(t, once.rows[0][1].i, i64(3))
	testing.expect_value(t, once.rows[2][1].i, i64(3))
	db.sql_result_destroy(&once)
}
