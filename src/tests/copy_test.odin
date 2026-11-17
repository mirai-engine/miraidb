package tests

import "core:os"
import "core:testing"

import db "../engine"

// COPY is how a dump moves rows: the text format (tab separated, `\N` for NULL,
// backslash escapes) and CSV, to a file or to the client. These tests write and
// read files next to the test binary, so they need the store's host access, which
// `store_open` grants.

@(private)
copy_store :: proc(t: ^testing.T, name: string) -> ^db.Store {
	path := name
	os.remove_all(path)
	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return nil
	return store
}

@(test)
test_copy_text_and_csv_roundtrip :: proc(t: ^testing.T) {
	store := copy_store(t, "_test_copy_db_text")
	if store == nil do return
	defer db.store_close(store)
	defer os.remove_all("_test_copy_db_text")
	defer os.remove("_test_copy.txt")
	defer os.remove("_test_copy.csv")

	run(t, store, "CREATE TABLE src (id INTEGER PRIMARY KEY, name TEXT, n REAL, ok BOOLEAN)")
	// A tab, a backslash, an empty string and NULLs: the four things a text dump
	// has to escape or mark.
	run(t, store, "INSERT INTO src VALUES (1, 'plain', 1.5, true)")
	run(t, store, "INSERT INTO src VALUES (2, 'tab\there\\and', 0, false)")
	run(t, store, "INSERT INTO src VALUES (3, '', NULL, NULL)")
	run(t, store, "INSERT INTO src VALUES (4, NULL, NULL, NULL)")

	// Text: out to a file, back into a table of the same shape.
	result := run(t, store, "COPY src TO '_test_copy.txt'")
	testing.expect_value(t, result.affected, 4)
	db.sql_result_destroy(&result)
	run(t, store, "CREATE TABLE round (id INTEGER PRIMARY KEY, name TEXT, n REAL, ok BOOLEAN)")
	result = run(t, store, "COPY round FROM '_test_copy.txt'")
	testing.expect_value(t, result.affected, 4)
	db.sql_result_destroy(&result)
	rows := run(t, store, "SELECT id, name, n, ok FROM round ORDER BY id")
	defer db.sql_result_destroy(&rows)
	testing.expect_value(t, len(rows.rows), 4)
	testing.expect_value(t, rows.rows[1][1].s, "tab\there\\and")
	testing.expect_value(t, rows.rows[2][1].s, "")
	testing.expect_value(t, rows.rows[2][2].kind, db.Value_Kind.Null)
	testing.expect_value(t, rows.rows[3][1].kind, db.Value_Kind.Null)
	testing.expect_value(t, rows.rows[0][3].b, true)
	testing.expect_value(t, rows.rows[1][3].b, false)

	// CSV: the header goes out and is skipped on the way back, and the empty
	// string stays a string where the empty field stays NULL.
	result = run(t, store, "COPY src TO '_test_copy.csv' (FORMAT csv, HEADER)")
	testing.expect_value(t, result.affected, 4)
	db.sql_result_destroy(&result)
	run(t, store, "CREATE TABLE round_csv (id INTEGER PRIMARY KEY, name TEXT, n REAL, ok BOOLEAN)")
	result = run(t, store, "COPY round_csv FROM '_test_copy.csv' (FORMAT csv, HEADER)")
	testing.expect_value(t, result.affected, 4)
	db.sql_result_destroy(&result)
	csv_rows := run(t, store, "SELECT id, name, n, ok FROM round_csv ORDER BY id")
	defer db.sql_result_destroy(&csv_rows)
	testing.expect_value(t, len(csv_rows.rows), 4)
	testing.expect_value(t, csv_rows.rows[1][1].s, "tab\there\\and")
	testing.expect_value(t, csv_rows.rows[2][1].s, "")
	testing.expect_value(t, csv_rows.rows[3][1].kind, db.Value_Kind.Null)

	// TO STDOUT hands the text back to the caller, which is what the CLI prints
	// and what the wire sends as CopyData.
	text := run(t, store, "COPY src (id, name) TO STDOUT WITH (FORMAT csv)")
	defer db.sql_result_destroy(&text)
	testing.expect_value(t, text.kind, db.Sql_Result_Kind.Ack)
	// A tab is not a CSV separator, so it travels unquoted; the empty string is
	// quoted so it does not read back as NULL.
	testing.expect_value(t, text.message, "1,plain\n2,tab\there\\and\n3,\"\"\n4,\n")
}

@(test)
test_copy_options_and_column_lists :: proc(t: ^testing.T) {
	store := copy_store(t, "_test_copy_db_options")
	if store == nil do return
	defer db.store_close(store)
	defer os.remove_all("_test_copy_db_options")
	defer os.remove("_test_copy_opts.txt")

	// A column list leaves the others to their defaults, and DELIMITER and NULL
	// spell the format differently.
	run(t, store, "CREATE TABLE t (a INTEGER, b TEXT DEFAULT 'dflt', c INTEGER DEFAULT 7)")
	if write_err := os.write_entire_file("_test_copy_opts.txt", "10;NA\n11;x\n"); write_err != nil {
		testing.expectf(t, false, "cannot write the fixture: %v", write_err)
		return
	}
	result := run(t, store, "COPY t (a, b) FROM '_test_copy_opts.txt' (DELIMITER ';', NULL 'NA')")
	testing.expect_value(t, result.affected, 2)
	db.sql_result_destroy(&result)
	rows := run(t, store, "SELECT a, b, c FROM t ORDER BY a")
	defer db.sql_result_destroy(&rows)
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect_value(t, rows.rows[0][0].i, i64(10))
	testing.expect_value(t, rows.rows[0][1].kind, db.Value_Kind.Null)
	testing.expect_value(t, rows.rows[0][2].i, i64(7))
	testing.expect_value(t, rows.rows[1][1].s, "x")
}

@(test)
test_copy_refuses_a_bad_row :: proc(t: ^testing.T) {
	store := copy_store(t, "_test_copy_db_bad")
	if store == nil do return
	defer db.store_close(store)
	defer os.remove_all("_test_copy_db_bad")
	defer os.remove("_test_copy_bad.txt")

	run(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

	// A field that is not the column's type names the row and the column.
	_ = os.write_entire_file("_test_copy_bad.txt", "1\tok\nnope\tx\n")
	bad := run_error(t, store, "COPY t FROM '_test_copy_bad.txt'")
	defer db.error_free(&bad)
	testing.expect_value(t, bad.kind, db.Error_Kind.Invalid_Type)

	// A duplicate key half way through writes none of the rows before it.
	_ = os.write_entire_file("_test_copy_bad.txt", "1\tok\n1\tagain\n")
	duplicate := run_error(t, store, "COPY t FROM '_test_copy_bad.txt'")
	defer db.error_free(&duplicate)
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Primary_Key)
	count := run(t, store, "SELECT count(*) FROM t")
	defer db.sql_result_destroy(&count)
	testing.expect_value(t, count.rows[0][0].i, i64(0))

	// The wrong number of fields is refused before anything is written.
	_ = os.write_entire_file("_test_copy_bad.txt", "1\n")
	short := run_error(t, store, "COPY t FROM '_test_copy_bad.txt'")
	defer db.error_free(&short)
	testing.expect_value(t, short.kind, db.Error_Kind.Invalid_Argument)

	// A NULL in a NOT NULL column is the insert's own error, under the row that
	// caused it.
	_ = os.write_entire_file("_test_copy_bad.txt", "2\t\\N\n")
	null_row := run_error(t, store, "COPY t FROM '_test_copy_bad.txt'")
	defer db.error_free(&null_row)
	testing.expect_value(t, null_row.kind, db.Error_Kind.Not_Null_Violation)

	// STDIN belongs to a client: the engine says so instead of reading a stream
	// nobody is writing to.
	stdin := run_error(t, store, "COPY t FROM STDIN")
	defer db.error_free(&stdin)
	testing.expect_value(t, stdin.kind, db.Error_Kind.Sql_Unsupported)

	// A table that is not there, and a column that is not there.
	missing_table := run_error(t, store, "COPY gone FROM '_test_copy_bad.txt'")
	defer db.error_free(&missing_table)
	testing.expect_value(t, missing_table.kind, db.Error_Kind.Table_Not_Found)
	missing_column := run_error(t, store, "COPY t (nope) TO '_test_copy_bad.txt'")
	defer db.error_free(&missing_column)
	testing.expect_value(t, missing_column.kind, db.Error_Kind.Column_Not_Found)
}

// GROUPING SETS, ROLLUP and CUBE answer one row per group of every set. Before
// this, `GROUP BY ROLLUP(a, b)` parsed and then failed at execution with "GROUP BY
// expression failed", which is worse than refusing it.
@(test)
test_grouping_sets :: proc(t: ^testing.T) {
	store := fresh_db(t, "grouping")
	if store == nil do return
	defer cleanup_db(store, "grouping")

	run(t, store, "CREATE TABLE sales (region TEXT, product TEXT, amount INTEGER)")
	run(
		t,
		store,
		"INSERT INTO sales VALUES ('north', 'a', 10), ('north', 'b', 20), ('south', 'a', 5)",
	)

	// ROLLUP: the detail rows, then one per region, then the total.
	rows := run(
		t,
		store,
		"SELECT region, product, sum(amount), grouping(region), grouping(product) FROM sales GROUP BY ROLLUP(region, product)",
	)
	testing.expect_value(t, len(rows.rows), 6)
	testing.expect_value(t, rows.rows[0][0].s, "north")
	testing.expect_value(t, rows.rows[0][1].s, "a")
	testing.expect_value(t, rows.rows[0][2].i, i64(10))
	testing.expect_value(t, rows.rows[0][3].i, i64(0))
	testing.expect_value(t, rows.rows[3][0].s, "north")
	testing.expect_value(t, rows.rows[3][1].kind, db.Value_Kind.Null)
	testing.expect_value(t, rows.rows[3][2].i, i64(30))
	testing.expect_value(t, rows.rows[3][4].i, i64(1))
	testing.expect_value(t, rows.rows[5][0].kind, db.Value_Kind.Null)
	testing.expect_value(t, rows.rows[5][2].i, i64(35))
	// Both columns rolled up: the mask has one bit per argument.
	testing.expect_value(t, rows.rows[5][3].i, i64(1))
	testing.expect_value(t, rows.rows[5][4].i, i64(1))
	db.sql_result_destroy(&rows)

	// CUBE: every subset, the total first.
	cube := run(
		t,
		store,
		"SELECT region, product, sum(amount) FROM sales GROUP BY CUBE(region, product)",
	)
	testing.expect_value(t, len(cube.rows), 8)
	testing.expect_value(t, cube.rows[0][0].kind, db.Value_Kind.Null)
	testing.expect_value(t, cube.rows[0][1].kind, db.Value_Kind.Null)
	testing.expect_value(t, cube.rows[0][2].i, i64(35))
	db.sql_result_destroy(&cube)

	// GROUPING SETS names the sets one by one, including the empty one.
	sets := run(
		t,
		store,
		"SELECT region, product, sum(amount), grouping(region, product) FROM sales GROUP BY GROUPING SETS ((region, product), (region), ())",
	)
	testing.expect_value(t, len(sets.rows), 6)
	testing.expect_value(t, sets.rows[0][0].s, "north")
	testing.expect_value(t, sets.rows[0][3].i, i64(0))
	testing.expect_value(t, sets.rows[3][1].kind, db.Value_Kind.Null)
	testing.expect_value(t, sets.rows[3][3].i, i64(1)) // (region) leaves product out: mask 01
	testing.expect_value(t, sets.rows[5][3].i, i64(3)) // () leaves both out
	db.sql_result_destroy(&sets)

	// A plain expression beside a construct multiplies the sets.
	mixed := run(
		t,
		store,
		"SELECT region, product, sum(amount) FROM sales GROUP BY region, ROLLUP(product)",
	)
	testing.expect_value(t, len(mixed.rows), 5)
	db.sql_result_destroy(&mixed)

	// A plain GROUP BY is one set with every expression: unchanged.
	plain := run(t, store, "SELECT region, sum(amount) FROM sales GROUP BY region ORDER BY region")
	testing.expect_value(t, len(plain.rows), 2)
	db.sql_result_destroy(&plain)

	// HAVING reads the rolled-up row, and ORDER BY orders the rows of every set.
	having := run(
		t,
		store,
		"SELECT region, sum(amount) FROM sales GROUP BY ROLLUP(region) HAVING sum(amount) >= 5 ORDER BY sum(amount)",
	)
	testing.expect_value(t, len(having.rows), 3)
	testing.expect_value(t, having.rows[2][0].kind, db.Value_Kind.Null)
	testing.expect_value(t, having.rows[2][1].i, i64(35))
	db.sql_result_destroy(&having)

	// GROUPING() outside a grouping clause says so instead of answering 0.
	refused := run_error(t, store, "SELECT grouping(region) FROM sales")
	defer db.error_free(&refused)
	testing.expect_value(t, refused.kind, db.Error_Kind.Invalid_Argument)
}
