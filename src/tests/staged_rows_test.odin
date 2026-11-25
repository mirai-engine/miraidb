package tests

import "core:testing"

import db "../engine"

// A transaction keeps the rows it inserts in an array while their ids run
// upward one at a time, and in a map otherwise (R2). Either way it has to
// answer as one set of rows, in id order at the commit.

@(private = "file")
sr_row :: proc(id: u64) -> db.Row {
	return db.Row{id = db.Row_Id(id), values = nil}
}

@(test)
test_staged_rows_answer_as_one_set :: proc(t: ^testing.T) {
	s: db.Staged_Rows
	db.srows_init(&s, 4)
	defer db.srows_destroy(&s)

	for id in u64(10) ..= 13 do db.srows_set(&s, sr_row(id))
	testing.expect_value(t, db.srows_len(&s), 4)
	testing.expect_value(t, len(s.dense), 4)
	// Past a gap, below the first, and right after the last.
	db.srows_set(&s, sr_row(20))
	db.srows_set(&s, sr_row(3))
	db.srows_set(&s, sr_row(14))
	testing.expect_value(t, len(s.dense), 5)
	testing.expect_value(t, len(s.sparse), 2)
	testing.expect_value(t, db.srows_len(&s), 7)
	for id in ([]u64{3, 10, 11, 12, 13, 14, 20}) do testing.expectf(t, db.srows_has(&s, db.Row_Id(id)), "row %d", id)
	for id in ([]u64{2, 9, 15, 19, 21}) do testing.expectf(t, !db.srows_has(&s, db.Row_Id(id)), "no row %d", id)

	// A hole in the middle stays; one at the end is given back.
	db.srows_erase(&s, 11)
	testing.expect(t, !db.srows_has(&s, 11))
	db.srows_erase(&s, 14)
	testing.expect_value(t, len(s.dense), 4)
	db.srows_erase(&s, 20)
	testing.expect_value(t, db.srows_len(&s), 4)
	// Refilled, a hole counts again; an overwrite does not.
	db.srows_set(&s, sr_row(11))
	db.srows_set(&s, sr_row(11))
	db.srows_set(&s, sr_row(3))
	testing.expect_value(t, db.srows_len(&s), 5)

	ids := db.srows_ids_sorted(&s)
	defer delete(ids)
	want := []db.Row_Id{3, 10, 11, 12, 13}
	if testing.expect_value(t, len(ids), len(want)) {
		for id, i in want do testing.expect_value(t, ids[i], id)
	}

	// The map holds an id the array would reach next: it stays there.
	db.srows_set(&s, sr_row(15))
	db.srows_set(&s, sr_row(14))
	testing.expect_value(t, len(s.dense), 5)
	db.srows_set(&s, sr_row(15))
	testing.expect_value(t, db.srows_len(&s), 7)

	db.srows_clear(&s)
	testing.expect_value(t, db.srows_len(&s), 0)
	testing.expect(t, !db.srows_has(&s, 10))
}

@(test)
test_a_transaction_stages_rows_in_any_order :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	script := []string{
		"CREATE TABLE r (x INTEGER UNIQUE, y TEXT)",
		"INSERT INTO r VALUES (1, 'a')",
		"BEGIN",
		"INSERT INTO r VALUES (2, 'b'), (3, 'c')",
		// A rowid the statement names, past a gap; the next rows follow it.
		"INSERT INTO r (rowid, x, y) VALUES (100, 4, 'd')",
		"INSERT INTO r VALUES (5, 'e')",
		// One between the rows the transaction numbered and the named one.
		"INSERT INTO r (rowid, x, y) VALUES (50, 6, 'f')",
		"UPDATE r SET y = 'C' WHERE x = 3",
		"DELETE FROM r WHERE x = 2",
		"SAVEPOINT s",
		"INSERT INTO r VALUES (7, 'g')",
		"DELETE FROM r WHERE x = 4",
		"ROLLBACK TO s",
		"RELEASE s",
		"COMMIT",
	}
	for sql in script {
		err := db.embed_exec(conn, sql)
		testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
		db.error_free(&err)
	}
	// A statement that fails takes its rows back.
	failed := db.embed_exec(conn, "INSERT INTO r VALUES (8, 'h'), (3, 'dup')")
	testing.expect(t, !db.error_ok(failed))
	db.error_free(&failed)

	result := run_temp(t, conn.store, "SELECT rowid, x, y FROM r ORDER BY rowid")
	want := [][3]string{{"1", "1", "a"}, {"3", "3", "C"}, {"50", "6", "f"}, {"100", "4", "d"}, {"101", "5", "e"}}
	if testing.expect_value(t, len(result.rows), len(want)) {
		for row, i in want {
			for column in 0 ..< 3 {
				testing.expectf(t, db.sqlite_value_text(result.rows[i][column], context.temp_allocator) == row[column], "row %d column %d: %v", i, column, result.rows[i][column])
			}
		}
	}
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA integrity_check").s, "ok")
}
