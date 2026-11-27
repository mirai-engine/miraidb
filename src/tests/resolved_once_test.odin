package tests

import "core:testing"

import db "../engine"

// A tree kept for another run (the store's statement cache, a prepared
// statement) is resolved once per catalog generation (A1.8c): a run at the
// generation its last resolution held for takes the statement as that
// resolution left it. A transaction that sees another catalog than the
// generation says (one it changed itself, one that began before a change) keeps
// resolving for itself, and leaves nothing another run would take.

@(private = "file")
ro_store :: proc(t: ^testing.T) -> ^db.Store {
	store, err := db.store_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, x INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1, 10), (2, 20)")
	return store
}

@(private = "file")
ro_resolutions :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> u64 {
	db.resolve_counters_reset()
	result := run(t, store, sql)
	db.sql_result_destroy(&result)
	return db.resolve_counters().resolutions
}

@(test)
test_a_kept_tree_is_resolved_once_per_catalog :: proc(t: ^testing.T) {
	store := ro_store(t)
	defer db.store_close(store)
	query :: "SELECT count(*) FROM t WHERE x > 5"
	testing.expect_value(t, ro_resolutions(t, store, query), 1)
	testing.expect_value(t, ro_resolutions(t, store, query), 0)
	testing.expect_value(t, ro_resolutions(t, store, query), 0)
	// A write's text is not kept by the cache; a prepared one is.
	update, update_err := db.sql_prepare(store, "UPDATE t SET x = x + 1 WHERE id = 1")
	if !testing.expectf(t, db.error_ok(update_err), "prepare: %s", update_err.message) do return
	defer db.stmt_prepared_destroy(update)
	for expected in ([]u64{1, 0}) {
		db.resolve_counters_reset()
		result, err := db.prepared_execute(store, update, nil)
		testing.expectf(t, db.error_ok(err), "update: %s", err.message)
		db.sql_result_destroy(&result)
		testing.expect_value(t, db.resolve_counters().resolutions, expected)
	}
	testing.expect_value(t, scalar(t, store, "SELECT x FROM t WHERE id = 1").i, 12)
	// A change to the catalog makes the tree resolve again, once.
	run_done(t, store, "ALTER TABLE t ADD COLUMN y INTEGER DEFAULT 7")
	testing.expect_value(t, ro_resolutions(t, store, query), 1)
	testing.expect_value(t, ro_resolutions(t, store, query), 0)

	// A prepared statement run in one write transaction, as a load runs it.
	prepared, prepare_err := db.sql_prepare(store, "INSERT INTO t (x) VALUES (3)")
	if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return
	defer db.stmt_prepared_destroy(prepared)
	tx := db.tx_begin_write(store)
	db.resolve_counters_reset()
	for _ in 0 ..< 10 {
		result, err := db.prepared_execute_in_tx(tx, prepared, nil)
		testing.expectf(t, db.error_ok(err), "insert: %s", err.message)
		db.sql_result_destroy(&result)
	}
	testing.expect_value(t, db.resolve_counters().resolutions, 1)
	commit_err := db.tx_commit(tx)
	testing.expectf(t, db.error_ok(commit_err), "commit: %s", commit_err.message)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE x = 3 AND y = 7").i, 10)
}

// The resolution rewrites a table's name to its stored spelling, under
// SQLite's rules: a run that takes the kept resolution reads the table the
// first run found.
@(test)
test_a_kept_resolution_keeps_the_names_it_rewrote :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	store.sqlite_names = true
	store.sqlite_rules = true
	run_done(t, store, "CREATE TABLE Mixed (v INTEGER)")
	run_done(t, store, "INSERT INTO Mixed VALUES (1), (2), (3)")
	query :: "SELECT sum(m.v) FROM mixed AS m JOIN MIXED ON MIXED.v = m.v WHERE m.v IN (SELECT v FROM mIxEd)"
	for expected in ([]u64{1, 0, 0}) {
		testing.expect_value(t, ro_resolutions(t, store, query), expected)
		testing.expect_value(t, scalar(t, store, query).i, 6)
	}
}

// A transaction that changed the catalog resolves its trees for itself, at
// every run, and they are resolved again once it commits.
@(test)
test_a_transaction_that_changes_the_catalog_resolves_for_itself :: proc(t: ^testing.T) {
	store := ro_store(t)
	defer db.store_close(store)
	prepared, prepare_err := db.sql_prepare(store, "SELECT count(*) FROM t")
	if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return
	defer db.stmt_prepared_destroy(prepared)
	in_tx :: proc(t: ^testing.T, tx: ^db.Tx, prepared: ^db.Stmt_Prepared) -> u64 {
		db.resolve_counters_reset()
		result, err := db.prepared_execute_in_tx(tx, prepared, nil)
		testing.expectf(t, db.error_ok(err), "run: %s", err.message)
		db.sql_result_destroy(&result)
		return db.resolve_counters().resolutions
	}
	tx := db.tx_begin_write(store)
	testing.expect_value(t, in_tx(t, tx, prepared), 1)
	testing.expect_value(t, in_tx(t, tx, prepared), 0)
	created, create_err := db.sql_execute_in_tx(tx, "CREATE TABLE u (z INTEGER)")
	testing.expectf(t, db.error_ok(create_err), "create: %s", create_err.message)
	db.sql_result_destroy(&created)
	testing.expect_value(t, in_tx(t, tx, prepared), 1)
	testing.expect_value(t, in_tx(t, tx, prepared), 1)
	commit_err := db.tx_commit(tx)
	testing.expectf(t, db.error_ok(commit_err), "commit: %s", commit_err.message)
	for expected in ([]u64{1, 0, 0}) {
		db.resolve_counters_reset()
		result, err := db.prepared_execute(store, prepared, nil)
		testing.expectf(t, db.error_ok(err), "run: %s", err.message)
		db.sql_result_destroy(&result)
		testing.expect_value(t, db.resolve_counters().resolutions, expected)
	}
}

// A read that began before a change sees the catalog as it was: its
// resolution holds for it alone. A tree it resolved is resolved again by the
// next run, which sees the catalog as it is; and it does not take a
// resolution made for the catalog as it is.
@(test)
test_a_read_on_an_older_catalog_keeps_no_resolution :: proc(t: ^testing.T) {
	store := ro_store(t)
	defer db.store_close(store)
	reader := db.tx_begin_read(store)
	run_done(t, store, "ALTER TABLE t ADD COLUMN y INTEGER DEFAULT 7")
	prepared, prepare_err := db.sql_prepare(store, "SELECT count(*) FROM t")
	if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return
	defer db.stmt_prepared_destroy(prepared)
	ro_prepared :: proc(t: ^testing.T, store: ^db.Store, prepared: ^db.Stmt_Prepared, tx: ^db.Tx = nil) -> u64 {
		db.resolve_counters_reset()
		result: db.Sql_Result
		err: db.Error
		if tx != nil do result, err = db.prepared_execute_in_tx(tx, prepared, nil)
		else do result, err = db.prepared_execute(store, prepared, nil)
		if testing.expectf(t, db.error_ok(err) && len(result.rows) == 1, "run: %s", err.message) {
			testing.expect_value(t, result.rows[0][0].i, 2)
		}
		db.error_free(&err)
		db.sql_result_destroy(&result)
		return db.resolve_counters().resolutions
	}
	// The old read resolves for itself and leaves nothing kept.
	testing.expect_value(t, ro_prepared(t, store, prepared, reader), 1)
	testing.expect_value(t, ro_prepared(t, store, prepared), 1)
	testing.expect_value(t, ro_prepared(t, store, prepared), 0)
	// What the catalog as it is kept, the old read does not take.
	testing.expect_value(t, ro_prepared(t, store, prepared, reader), 1)
	db.tx_end(reader)
}
