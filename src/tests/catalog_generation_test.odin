package tests

import "core:testing"

import db "../engine"

// A statement's tree is resolved against one catalog: a WHERE that names a
// select-list alias is rewritten to the alias's expression, a table name to its
// stored spelling. A tree kept for another run (the store's statement cache, a
// prepared statement, the embedded API's statement) is parsed again from its
// text when the catalog changed, as SQLite prepares a statement again after a
// schema change. Without that, a column added under the alias's name went
// unseen: the kept tree still read the expression (SQLite answers "1" below,
// the kept tree answered "2,5").

@(private = "file")
CG_ALIAS :: "SELECT group_concat(x, ',') AS g, x + 1 AS y FROM t WHERE y > 2"

@(private = "file")
cg_store :: proc(t: ^testing.T) -> ^db.Store {
	store, err := db.store_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	run_done(t, store, "CREATE TABLE t (x INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1), (2), (5)")
	return store
}

@(private = "file")
cg_add_y :: proc(t: ^testing.T, store: ^db.Store) {
	run_done(t, store, "ALTER TABLE t ADD COLUMN y INTEGER DEFAULT 0")
	run_done(t, store, "UPDATE t SET y = 10 WHERE x = 1")
}

@(private = "file")
cg_prepared_text :: proc(t: ^testing.T, store: ^db.Store, prepared: ^db.Stmt_Prepared, tx: ^db.Tx = nil, loc := #caller_location) -> string {
	result: db.Sql_Result
	err: db.Error
	if tx != nil do result, err = db.prepared_execute_in_tx(tx, prepared, nil)
	else do result, err = db.prepared_execute(store, prepared, nil)
	defer db.sql_result_destroy(&result)
	defer db.error_free(&err)
	if !testing.expectf(t, db.error_ok(err) && len(result.rows) == 1, "prepared: %s", err.message, loc = loc) do return ""
	return result.rows[0][0].s
}

@(test)
test_a_cached_query_follows_a_column_that_takes_an_aliases_name :: proc(t: ^testing.T) {
	store := cg_store(t)
	defer db.store_close(store)
	testing.expect_value(t, scalar(t, store, CG_ALIAS).s, "2,5")
	testing.expect_value(t, scalar(t, store, CG_ALIAS).s, "2,5")
	cg_add_y(t, store)
	testing.expect_value(t, scalar(t, store, CG_ALIAS).s, "1")
}

@(test)
test_a_prepared_statement_follows_a_column_that_takes_an_aliases_name :: proc(t: ^testing.T) {
	store := cg_store(t)
	defer db.store_close(store)
	prepared, prepare_err := db.sql_prepare(store, CG_ALIAS)
	if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return
	defer db.stmt_prepared_destroy(prepared)
	testing.expect_value(t, cg_prepared_text(t, store, prepared), "2,5")
	cg_add_y(t, store)
	testing.expect_value(t, cg_prepared_text(t, store, prepared), "1")

	// A transaction that adds the column itself sees it at once; the tree it
	// resolved holds for that transaction alone, and the rollback takes the
	// column back.
	run_done(t, store, "ALTER TABLE t RENAME COLUMN y TO z")
	testing.expect_value(t, cg_prepared_text(t, store, prepared), "2,5")
	tx := db.tx_begin_write(store)
	added, add_err := db.sql_execute_in_tx(tx, "ALTER TABLE t ADD COLUMN y INTEGER DEFAULT 9")
	db.sql_result_destroy(&added)
	testing.expect(t, db.error_ok(add_err))
	testing.expect_value(t, cg_prepared_text(t, store, prepared, tx), "1,2,5")
	db.tx_rollback(tx)
	testing.expect_value(t, cg_prepared_text(t, store, prepared), "2,5")
}

@(test)
test_an_embedded_statement_follows_a_column_that_takes_an_aliases_name :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	for sql in ([]string{"CREATE TABLE t (x INTEGER)", "INSERT INTO t VALUES (1), (2), (5)"}) {
		err := db.embed_exec(conn, sql)
		testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
		db.error_free(&err)
	}
	stmt := db.embed_prepare(conn, CG_ALIAS)
	if !testing.expect(t, stmt != nil) do return
	defer db.embed_finalize(stmt)
	has_row, step_err := db.embed_step(stmt)
	testing.expect(t, db.error_ok(step_err) && has_row)
	testing.expect_value(t, db.embed_column_text(stmt, 0), "2,5")
	db.embed_reset(stmt)
	for sql in ([]string{"ALTER TABLE t ADD COLUMN y INTEGER DEFAULT 0", "UPDATE t SET y = 10 WHERE x = 1"}) {
		err := db.embed_exec(conn, sql)
		testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
		db.error_free(&err)
	}
	has_row, step_err = db.embed_step(stmt)
	testing.expect(t, db.error_ok(step_err) && has_row)
	testing.expect_value(t, db.embed_column_text(stmt, 0), "1")
}

// Writing rows is no change to the catalog: a query run again after one is
// not parsed again.
@(test)
test_rows_written_keep_a_kept_tree :: proc(t: ^testing.T) {
	store := cg_store(t)
	defer db.store_close(store)
	query := "SELECT count(*) FROM t WHERE x > 1"
	testing.expect_value(t, scalar(t, store, query).i, i64(2))
	before := db.store_catalog_generation(store)
	run_done(t, store, "INSERT INTO t VALUES (7)")
	run_done(t, store, "UPDATE t SET x = x + 1 WHERE x = 7")
	run_done(t, store, "DELETE FROM t WHERE x = 8")
	testing.expect_value(t, db.store_catalog_generation(store), before)
	db.resolve_counters_reset()
	testing.expect_value(t, scalar(t, store, query).i, i64(2))
	testing.expect_value(t, db.resolve_counters().parses, 0)
	// A view is part of the catalog.
	run_done(t, store, "CREATE VIEW v AS SELECT x FROM t")
	testing.expect(t, db.store_catalog_generation(store) != before)
}

// An attached database's catalog is part of what a statement resolves
// against: attaching it, changing it and detaching it move the generation of
// the store it is attached to. The generation is read without a lock, so a
// statement prepared inside a BEGIN (which holds the store's lock) reads it.
@(test)
test_an_attached_catalog_moves_the_generation :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	exec :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) {
		err := db.embed_exec(conn, sql)
		testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
		db.error_free(&err)
	}
	start := db.store_catalog_generation(conn.store)
	exec(t, conn, "ATTACH DATABASE ':memory:' AS side")
	attached := db.store_catalog_generation(conn.store)
	testing.expect(t, attached != start)
	exec(t, conn, "CREATE TABLE side.foo (key INTEGER)")
	created := db.store_catalog_generation(conn.store)
	testing.expect(t, created != attached)
	exec(t, conn, "INSERT INTO side.foo VALUES (1)")
	testing.expect_value(t, db.store_catalog_generation(conn.store), created)
	exec(t, conn, "BEGIN")
	exec(t, conn, "INSERT INTO side.foo VALUES (2)")
	exec(t, conn, "COMMIT")
	exec(t, conn, "DETACH DATABASE side")
	testing.expect(t, db.store_catalog_generation(conn.store) != created)
}
