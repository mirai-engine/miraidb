package tests

import "core:testing"

import db "../engine"

// A cursor reads a query a few rows at a time, which is how a client walks a
// result too large to hold. It lives in the transaction that declared it.
@(test)
test_cursors :: proc(t: ^testing.T) {
	store := fresh_db(t, "cursor")
	if store == nil do return
	defer cleanup_db(store, "cursor")

	run(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
	run(t, store, "INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c'), (4, 'd')")

	tx := db.tx_begin_write(store)
	if !testing.expect(t, tx != nil) do return
	defer if tx != nil do db.tx_rollback(tx)

	fetch := proc(t: ^testing.T, tx: ^db.Tx, sql: string) -> db.Sql_Result {
		result, err := db.sql_execute_in_tx(tx, sql)
		testing.expectf(t, db.error_ok(err), "%s failed: %s", sql, err.message)
		return result
	}
	fetch_error := proc(t: ^testing.T, tx: ^db.Tx, sql: string) -> db.Error {
		result, err := db.sql_execute_in_tx(tx, sql)
		db.sql_result_destroy(&result)
		return err
	}

	declared := fetch(t, tx, "DECLARE c CURSOR FOR SELECT id, v FROM t ORDER BY id")
	testing.expect_value(t, declared.kind, db.Sql_Result_Kind.Ack)
	db.sql_result_destroy(&declared)

	// Two rows at a time, then the next one.
	two := fetch(t, tx, "FETCH 2 FROM c")
	testing.expect_value(t, len(two.rows), 2)
	testing.expect_value(t, two.rows[0][0].i, i64(1))
	testing.expect_value(t, two.rows[1][1].s, "b")
	testing.expect_value(t, two.columns[1], "v")
	db.sql_result_destroy(&two)

	next := fetch(t, tx, "FETCH NEXT FROM c")
	testing.expect_value(t, len(next.rows), 1)
	testing.expect_value(t, next.rows[0][0].i, i64(3))
	db.sql_result_destroy(&next)

	// FIRST and LAST move to an end, ABSOLUTE and RELATIVE to a position, and
	// BACKWARD reads back the rows it passed.
	first := fetch(t, tx, "FETCH FIRST FROM c")
	testing.expect_value(t, first.rows[0][0].i, i64(1))
	db.sql_result_destroy(&first)
	last := fetch(t, tx, "FETCH LAST FROM c")
	testing.expect_value(t, last.rows[0][0].i, i64(4))
	db.sql_result_destroy(&last)
	absolute := fetch(t, tx, "FETCH ABSOLUTE 2 FROM c")
	testing.expect_value(t, absolute.rows[0][0].i, i64(2))
	db.sql_result_destroy(&absolute)
	relative := fetch(t, tx, "FETCH RELATIVE 2 FROM c")
	testing.expect_value(t, relative.rows[0][0].i, i64(4))
	db.sql_result_destroy(&relative)
	backward := fetch(t, tx, "FETCH BACKWARD 2 FROM c")
	testing.expect_value(t, len(backward.rows), 2)
	testing.expect_value(t, backward.rows[0][0].i, i64(3))
	db.sql_result_destroy(&backward)

	// MOVE moves without handing rows out, and answers the count it moved.
	moved := fetch(t, tx, "MOVE FIRST IN c")
	testing.expect_value(t, moved.kind, db.Sql_Result_Kind.Rows)
	testing.expect_value(t, len(moved.rows), 0)
	testing.expect_value(t, moved.affected, 1)
	db.sql_result_destroy(&moved)

	// A cursor the transaction did not declare is not there, and neither is one
	// that was closed.
	missing := fetch_error(t, tx, "FETCH 1 FROM nope")
	defer db.error_free(&missing)
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)

	closed := fetch(t, tx, "CLOSE c")
	testing.expect_value(t, closed.kind, db.Sql_Result_Kind.Ack)
	db.sql_result_destroy(&closed)
	gone := fetch_error(t, tx, "FETCH 1 FROM c")
	defer db.error_free(&gone)
	testing.expect_value(t, gone.kind, db.Error_Kind.Table_Not_Found)

	// The same name cannot be declared twice while it is open.
	fetch(t, tx, "DECLARE c CURSOR FOR SELECT id FROM t")
	twice := fetch_error(t, tx, "DECLARE c CURSOR FOR SELECT id FROM t")
	defer db.error_free(&twice)
	testing.expect_value(t, twice.kind, db.Error_Kind.Duplicate_Primary_Key)

	// WITH HOLD outlives the transaction in PostgreSQL, which this engine does not
	// do: it says so instead of answering a cursor that then disappears.
	hold := fetch_error(t, tx, "DECLARE h CURSOR WITH HOLD FOR SELECT id FROM t")
	defer db.error_free(&hold)
	testing.expect_value(t, hold.kind, db.Error_Kind.Sql_Unsupported)

	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	tx = nil
}
