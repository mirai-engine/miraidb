package tests

import "core:testing"

import db "../engine"

// A sum of squares kept in the group's state: the shape of every C aggregate,
// which keeps its accumulator in sqlite3_aggregate_context memory.
@(private = "file")
Squares :: struct {
	total:  i64,
	finals: ^int,
}

@(private = "file")
squares_step :: proc(group: ^db.Aggregate_Group, args: []db.Value) -> db.Error {
	if group.state == nil do group.state = new(Squares)
	state := (^Squares)(group.state)
	if args[0].kind == .Null do return db.ERROR_NONE
	if args[0].kind == .String && args[0].s == "boom" {
		return db.errf(.Invalid_Argument, "sum_squares() refused a row")
	}
	number, _ := db.value_to_i64(args[0])
	state.total += number * number
	return db.ERROR_NONE
}

@(private = "file")
squares_final :: proc(group: ^db.Aggregate_Group) -> (db.Value, db.Error) {
	counter := (^int)(group.user)
	counter^ += 1
	if group.state == nil do return db.value_null(), db.ERROR_NONE
	state := (^Squares)(group.state)
	total := state.total
	free(state)
	group.state = nil
	return db.value_int(total), db.ERROR_NONE
}

@(test)
test_host_aggregates_and_arities :: proc(t: ^testing.T) {
	store := fresh_db(t, "host_aggregates")
	if store == nil do return
	defer cleanup_db(store, "host_aggregates")
	run(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT, v INTEGER)")
	run(t, store, "INSERT INTO t (id, k, v) VALUES (1, 'a', 1), (2, 'a', 2), (3, 'b', 3), (4, 'b', 3)")

	finals := 0
	testing.expect(t, db.error_ok(db.store_register_aggregate(store, "sum_squares", 1, squares_step, squares_final, &finals)))

	// Over the table, per group, and through DISTINCT.
	testing.expect_value(t, scalar(t, store, "SELECT sum_squares(v) FROM t").i, i64(1 + 4 + 9 + 9))
	testing.expect_value(t, scalar(t, store, "SELECT sum_squares(v) FROM t GROUP BY k ORDER BY k LIMIT 1").i, i64(5))
	testing.expect_value(t, scalar(t, store, "SELECT sum_squares(DISTINCT v) FROM t").i, i64(14))
	testing.expect_value(t, scalar(t, store, "SELECT sum_squares(v) + 1 FROM t WHERE k = 'b'").i, i64(19))
	// No row still calls the final once: it answers NULL, as SQLite's sum() does.
	before := finals
	testing.expect_value(t, scalar(t, store, "SELECT sum_squares(v) FROM t WHERE id > 99").kind, db.Value_Kind.Null)
	testing.expect_value(t, finals, before + 1)
	// As a window function over the whole partition.
	testing.expect_value(t, scalar(t, store, "SELECT w FROM (SELECT id, sum_squares(v) OVER (PARTITION BY k) AS w FROM t) AS x WHERE id = 1").i, i64(5))

	// A step that fails is the statement's error, and the final still runs so
	// the state is released.
	run(t, store, "CREATE TABLE s (x TEXT)")
	run(t, store, "INSERT INTO s (x) VALUES ('2'), ('boom')")
	before = finals
	refused := run_error(t, store, "SELECT sum_squares(x) FROM s")
	testing.expect(t, strings_contains(refused.message, "sum_squares() refused a row"))
	testing.expect_value(t, finals, before + 1)

	// A name is registered per number of arguments: f/1 and f/2 are two
	// functions, -1 takes any other count, and a count nobody registered is
	// SQLite's "wrong number of arguments".
	one :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
		return db.value_int(1), db.ERROR_NONE
	}
	two :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
		return db.value_int(2), db.ERROR_NONE
	}
	testing.expect(t, db.error_ok(db.store_register_function(store, "pick", 1, one)))
	testing.expect(t, db.error_ok(db.store_register_function(store, "pick", 2, two)))
	testing.expect_value(t, scalar(t, store, "SELECT pick(0)").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT pick(0, 0)").i, i64(2))
	wrong := run_error(t, store, "SELECT pick(0, 0, 0)")
	testing.expect(t, strings_contains(wrong.message, "wrong number of arguments to function pick()"))
	testing.expect(t, db.store_unregister_function(store, "pick", 2))
	testing.expect_value(t, scalar(t, store, "SELECT pick(0)").i, i64(1))

	// A registration that overrides answers before the builtin of its name;
	// one that does not leaves the builtin in place.
	testing.expect(t, db.error_ok(db.store_register_function(store, "upper", 1, two)))
	testing.expect_value(t, scalar(t, store, "SELECT upper('a')").s, "A")
	testing.expect(t, db.error_ok(db.store_register_function(store, "upper", 1, two, nil, true)))
	testing.expect_value(t, scalar(t, store, "SELECT upper('a')").i, i64(2))
	testing.expect(t, db.store_unregister_function(store, "upper"))
	testing.expect_value(t, scalar(t, store, "SELECT upper('a')").s, "A")

	// A builtin aggregate keeps its name, and unregistering the aggregate makes
	// the name unknown again.
	testing.expect(t, !db.error_ok(db.store_register_aggregate(store, "count", 1, squares_step, squares_final)))
	testing.expect(t, db.store_unregister_function(store, "sum_squares"))
	gone := run_error(t, store, "SELECT sum_squares(v) FROM t")
	testing.expect_value(t, gone.kind, db.Error_Kind.Sql_Unsupported)
}
