package tests

import "core:testing"

import db "../engine"

// MERGE is how a load job says "these rows are the truth": update the ones that
// are there, insert the ones that are not, and delete what a clause says. It used
// to be a syntax error, so every migration script that used it stopped here.

@(test)
test_merge_updates_inserts_and_deletes :: proc(t: ^testing.T) {
	store := fresh_db(t, "merge")
	if store == nil do return
	defer cleanup_db(store, "merge")

	run_done(t, store, "CREATE TABLE stock (id INTEGER PRIMARY KEY, qty INTEGER, note TEXT)")
	run_done(t, store, "INSERT INTO stock VALUES (1, 5, 'a'), (2, 0, 'b'), (3, 9, 'c')")
	run_done(t, store, "CREATE TABLE feed (id INTEGER PRIMARY KEY, qty INTEGER)")
	run_done(t, store, "INSERT INTO feed VALUES (1, 10), (3, 1), (4, 7)")

	// One clause updates what matched and one inserts what did not.
	result := run(
		t,
		store,
		"MERGE INTO stock AS s USING feed AS f ON s.id = f.id " +
		"WHEN MATCHED THEN UPDATE SET qty = f.qty " +
		"WHEN NOT MATCHED THEN INSERT (id, qty, note) VALUES (f.id, f.qty, 'new')",
	)
	testing.expect_value(t, result.affected, 3)
	db.sql_result_destroy(&result)
	rows := run(t, store, "SELECT id, qty, note FROM stock ORDER BY id")
	testing.expect_value(t, len(rows.rows), 4)
	testing.expect_value(t, rows.rows[0][1].i, i64(10))
	testing.expect_value(t, rows.rows[0][2].s, "a") // untouched columns stay
	testing.expect_value(t, rows.rows[2][1].i, i64(1))
	testing.expect_value(t, rows.rows[3][2].s, "new")
	db.sql_result_destroy(&rows)

	// A condition on the clause decides which matched rows it takes.
	run(
		t,
		store,
		"MERGE INTO stock AS s USING feed AS f ON s.id = f.id " +
		"WHEN MATCHED AND f.qty = 1 THEN DELETE",
	)
	kept := run(t, store, "SELECT id FROM stock ORDER BY id")
	testing.expect_value(t, len(kept.rows), 3)
	testing.expect_value(t, kept.rows[0][0].i, i64(1))
	testing.expect_value(t, kept.rows[1][0].i, i64(2))
	db.sql_result_destroy(&kept)

	// Two source rows for one target would change it twice: refused, and nothing
	// is written.
	run_done(t, store, "CREATE TABLE twice (k INTEGER, qty INTEGER)")
	run_done(t, store, "INSERT INTO twice VALUES (1, 100), (1, 200)")
	double := run_error(
		t,
		store,
		"MERGE INTO stock USING twice ON stock.id = twice.k WHEN MATCHED THEN UPDATE SET qty = twice.qty",
	)
	testing.expect_value(t, double.kind, db.Error_Kind.Invalid_Argument)
	untouched := run(t, store, "SELECT qty FROM stock WHERE id = 1")
	testing.expect_value(t, untouched.rows[0][0].i, i64(10))
	db.sql_result_destroy(&untouched)

	// WHAT NOT MATCHED BY SOURCE would need is refused, with words that say so.
	refused := run_error(
		t,
		store,
		"MERGE INTO stock USING feed ON stock.id = feed.id WHEN NOT MATCHED BY SOURCE THEN DELETE",
	)
	testing.expect_value(t, refused.kind, db.Error_Kind.Sql_Unsupported)

	// A source column that does not exist is a column error, not a crash.
	missing := run_error(
		t,
		store,
		"MERGE INTO stock USING feed ON stock.id = feed.id WHEN MATCHED THEN UPDATE SET nope = feed.qty",
	)
	testing.expect_value(t, missing.kind, db.Error_Kind.Column_Not_Found)
}
