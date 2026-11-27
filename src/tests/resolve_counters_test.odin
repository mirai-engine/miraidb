package tests

import "core:log"
import "core:testing"

import db "../engine"

// The line A1 starts from: what a statement run again still works out while it
// runs (db.Resolve_Counters). Each expectation below that grows with the rows
// is one a later step of A1 makes a constant, and that step changes it here:
// a column of an enclosing query, functions and collations, the view parsed
// and the plan made per run or per outer row (A1.8). A column of the query's
// own sources is read through the link its resolution made (A1.8b): a join of
// 100 rows looked 609 names up.

@(private = "file")
RC_ROWS :: 100

@(private = "file")
rc_measure :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> db.Resolve_Counters {
	// The first run parses the text and keeps it; the second is what a query run
	// again costs.
	first := run(t, store, sql)
	db.sql_result_destroy(&first)
	db.resolve_counters_reset()
	again := run(t, store, sql)
	db.sql_result_destroy(&again)
	counted := db.resolve_counters()
	log.infof("%v :: %s", counted, sql)
	return counted
}

@(test)
test_the_names_a_statement_resolves_while_it_runs :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, x INTEGER, name TEXT)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER, label TEXT)")
	run_done(t, store, "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 100) INSERT INTO a SELECT i, i % 7, 'N' || i FROM s")
	run_done(t, store, "INSERT INTO b SELECT id, id, 'l' || id FROM a")
	run_done(t, store, "CREATE VIEW small AS SELECT id, x FROM a WHERE x < 3")

	// One table: the text is not parsed again, nor resolved again (A1.8c), and
	// a column's name is looked up once per statement, not per row.
	one := rc_measure(t, store, "SELECT count(*) FROM a WHERE x > 2 AND name <> 'q'")
	testing.expect_value(t, one.parses, 0)
	testing.expect_value(t, one.resolutions, 0)
	testing.expect_value(t, one.plans, 1)
	testing.expectf(t, one.column_names < 20, "one table: %d column lookups", one.column_names)

	// Two tables: each reference reads the column it is linked to; what is
	// left is the planner's, once per statement.
	join := rc_measure(t, store, "SELECT count(*) FROM a JOIN b ON b.a_id = a.id WHERE a.x > 2")
	testing.expectf(t, join.column_names < 20, "join: %d column lookups", join.column_names)

	// A call is linked to its function when its statement is resolved (A1.8d).
	call := rc_measure(t, store, "SELECT count(*) FROM a WHERE lower(name) = 'n5'")
	testing.expectf(t, call.function_names < 20, "function: %d lookups", call.function_names)

	// A comparison is linked to its collation when its statement is resolved (A1.8e).
	collated := rc_measure(t, store, "SELECT count(*) FROM a WHERE name = 'n5' COLLATE NOCASE")
	testing.expectf(t, collated.collation_names < 20, "collation: %d lookups", collated.collation_names)

	// A view's text is parsed once per catalog generation (A1.8f).
	view := rc_measure(t, store, "SELECT count(*) FROM small")
	testing.expect_value(t, view.parses, 0)

	// A correlated subquery reads the enclosing row's column through its link,
	// from the frame of the select it names, and plans once per statement
	// (A1.8g).
	correlated := rc_measure(t, store, "SELECT count(*) FROM a WHERE x >= (SELECT count(*) FROM b WHERE b.a_id = a.id)")
	testing.expectf(t, correlated.column_names <= RC_ROWS + 20, "correlated: %d column lookups", correlated.column_names)
	testing.expectf(t, correlated.plans <= 2, "correlated: %d plans", correlated.plans)
}
