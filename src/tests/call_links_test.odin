package tests

import "core:strings"
import "core:testing"

import db "../engine"

// A call is linked to what it reaches when its statement is resolved (A1.8d):
// a builtin by its dispatch name, a JSON or a date function, or a program's
// function that answers before a builtin of its name. It is not looked up by
// name at every row. The registry is part of the catalog: a function
// registered or dropped moves the generation, and a kept statement links its
// calls again.

@(private = "file")
cl_store :: proc(t: ^testing.T) -> ^db.Store {
	store, err := db.store_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, x REAL)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'Ab', 1.25), (2, 'cD', 2.5), (3, NULL, -3.75)")
	return store
}

@(test)
test_a_linked_call_answers_as_a_call_by_name :: proc(t: ^testing.T) {
	store := cl_store(t)
	defer db.store_close(store)
	query :: "SELECT group_concat(coalesce(upper(name), 'none') || ':' || ceiling(x) || ':' || power(2, id) || ':' || if(id > 1, 'y', 'n') || ':' || json_extract('{\"a\":' || id || '}', '$.a') || ':' || date('2020-01-0' || id, '+1 day') || ':' || abs(x) || ':' || coalesce(length(name), -1) || ':' || round(x, 1), ',') FROM (SELECT * FROM t ORDER BY id)"
	// A view's query is parsed at every run that reads it, as a tree of its
	// own that keeps no links (A1.8f will): its calls are found by name, and
	// what a linked call answers must be the same.
	run_done(t, store, "CREATE VIEW by_name AS " + query)
	db.resolve_counters_reset()
	by_name := run(t, store, "SELECT * FROM by_name")
	unlinked := db.resolve_counters()
	defer db.sql_result_destroy(&by_name)
	if !testing.expectf(t, len(by_name.rows) == 1, "by name: %d rows", len(by_name.rows)) do return
	testing.expectf(t, unlinked.function_names >= 30, "by name: %d function lookups", unlinked.function_names)
	want := by_name.rows[0][0].s
	testing.expect(t, len(want) > 40, "the query answers every row")
	for _ in 0 ..< 3 do testing.expect_value(t, scalar(t, store, query).s, want)
	db.resolve_counters_reset()
	testing.expect_value(t, scalar(t, store, query).s, want)
	// group_concat is found by its name once per statement; nothing per row.
	counted := db.resolve_counters()
	testing.expectf(t, counted.function_names <= 2, "%d function lookups", counted.function_names)
}

@(private = "file")
cl_twice :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
	if len(args) != 1 || args[0].kind != .Int do return db.value_null(), {}
	return db.value_int(args[0].i * 2), {}
}

@(private = "file")
cl_shout :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
	return db.value_string("SHOUT"), {}
}

@(test)
test_a_kept_statement_follows_the_functions_registered :: proc(t: ^testing.T) {
	store := cl_store(t)
	defer db.store_close(store)
	// A program's function registered after the statement ran is reached.
	twice :: "SELECT sum(twice(id)) FROM t"
	testing.expect(t, !db.error_ok(run_error(t, store, twice)), "no twice() yet")
	testing.expect(t, db.error_ok(db.store_register_function(store, "twice", 1, cl_twice)))
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, twice).i, 12)
	// One that answers before a builtin of its name is reached, kept or not.
	upper :: "SELECT group_concat(upper(name), ',') FROM t"
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, upper).s, "AB,CD")
	testing.expect(t, db.error_ok(db.store_register_function(store, "upper", 1, cl_shout, nil, true)))
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, upper).s, "SHOUT,SHOUT,SHOUT")
	// Dropped, the builtin answers again.
	testing.expect(t, db.store_unregister_function(store, "upper"))
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, upper).s, "AB,CD")
	// A prepared statement follows them as well.
	prepared, prepare_err := db.sql_prepare(store, upper)
	if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return
	defer db.stmt_prepared_destroy(prepared)
	prepared_text :: proc(t: ^testing.T, store: ^db.Store, prepared: ^db.Stmt_Prepared) -> string {
		result, err := db.prepared_execute(store, prepared, nil)
		defer db.sql_result_destroy(&result)
		defer db.error_free(&err)
		if !testing.expectf(t, db.error_ok(err) && len(result.rows) == 1, "run: %s", err.message) do return ""
		return strings.clone(result.rows[0][0].s, context.temp_allocator)
	}
	testing.expect_value(t, prepared_text(t, store, prepared), "AB,CD")
	testing.expect(t, db.error_ok(db.store_register_function(store, "upper", 1, cl_shout, nil, true)))
	testing.expect_value(t, prepared_text(t, store, prepared), "SHOUT,SHOUT,SHOUT")
}
