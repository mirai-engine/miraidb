package tests

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:os"
import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import db "../engine"
import sdk "../client"

// --- Helpers ---------------------------------------------------------------

@(private)
fresh_db :: proc(t: ^testing.T, name: string) -> ^db.Store {
	path := fmt.aprintf("_test_%s", name)
	defer delete(path)
	os.remove_all(path)
	store, err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "open %s failed: %s", path, err.message) {
		return nil
	}
	return store
}

@(private)
cleanup_db :: proc(store: ^db.Store, name: string) {
	path := fmt.aprintf("_test_%s", name)
	defer delete(path)
	db.store_close(store)
	os.remove_all(path)
}

@(private)
run :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> db.Sql_Result {
	result, err := db.sql_execute(store, sql)
	defer db.error_free(&err)
	if !testing.expectf(t, db.error_ok(err), "%s failed: %s", sql, err.message) {
		return {}
	}
	return result
}

// run_done runs a statement whose result the test does not read, and
// frees it.
@(private)
run_done :: proc(t: ^testing.T, store: ^db.Store, sql: string, loc := #caller_location) {
	result, err := db.sql_execute(store, sql)
	testing.expectf(t, db.error_ok(err), "%s failed: %s", sql, err.message, loc = loc)
	db.error_free(&err)
	db.sql_result_destroy(&result)
}

// run_error runs a statement expected to fail and answers its error, the
// message copied into the test's temporary memory: nothing for the test to free.
@(private)
run_error :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> db.Error {
	result, err := db.sql_execute(store, sql)
	db.sql_result_destroy(&result)
	out := db.Error{kind = err.kind, message = strings.clone(err.message, context.temp_allocator)}
	db.error_free(&err)
	return out
}

// run_temp runs a statement and answers its result copied into the test's
// temporary memory, the original freed: for a test that reads one field of it
// (`run_temp(...).rows`) and would otherwise leave the result behind.
@(private)
run_temp :: proc(t: ^testing.T, store: ^db.Store, sql: string, loc := #caller_location) -> db.Sql_Result {
	result, err := db.sql_execute(store, sql)
	testing.expectf(t, db.error_ok(err), "%s failed: %s", sql, err.message, loc = loc)
	db.error_free(&err)
	defer db.sql_result_destroy(&result)
	out := result
	out.columns = make([]string, len(result.columns), context.temp_allocator)
	for column, i in result.columns do out.columns[i] = strings.clone(column, context.temp_allocator)
	out.rows = make([][]db.Value, len(result.rows), context.temp_allocator)
	for row, i in result.rows {
		out.rows[i] = make([]db.Value, len(row), context.temp_allocator)
		for value, j in row do out.rows[i][j] = db.value_clone(value, context.temp_allocator)
	}
	out.row_ids = slice.clone(result.row_ids, context.temp_allocator)
	out.message = strings.clone(result.message, context.temp_allocator)
	return out
}

@(private)
scalar :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> db.Value {
	result := run(t, store, sql)
	defer db.sql_result_destroy(&result)
	if !testing.expectf(t, len(result.rows) == 1 && len(result.rows[0]) >= 1, "%s returned no row", sql) {
		return {}
	}
	// The value outlives the result in the test's temporary memory.
	return db.value_clone(result.rows[0][0], context.temp_allocator)
}

// --- Tests -----------------------------------------------------------------

@(test)
test_crud_and_replay :: proc(t: ^testing.T) {
	store := fresh_db(t, "crud")
	if store == nil do return

	run_done(t, store, "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score DOUBLE DEFAULT 1.5)")
	run_done(t, store, "INSERT INTO users (name) VALUES ('ana'), ('luis')")

	count := scalar(t, store, "SELECT count(*) FROM users")
	testing.expect_value(t, count.i, i64(2))

	row := run(t, store, "SELECT id, name, score FROM users ORDER BY id")
	testing.expect_value(t, len(row.rows), 2)
	testing.expect_value(t, row.rows[0][1].s, "ana")
	testing.expect_value(t, row.rows[0][2].f, f64(1.5))
	db.sql_result_destroy(&row)

	run_done(t, store, "UPDATE users SET score = 10 WHERE name = 'ana'")
	value := scalar(t, store, "SELECT score FROM users WHERE name = 'ana'")
	testing.expect_value(t, value.f, f64(10))

	run_done(t, store, "DELETE FROM users WHERE name = 'luis'")
	remaining := scalar(t, store, "SELECT count(*) FROM users")
	testing.expect_value(t, remaining.i, i64(1))

	sequence := store.commit_seq
	db.store_close(store)

	// Reopen: the state must come back from the commit log alone.
	reopened, err := db.store_open("_test_crud", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(err), "reopen failed: %s", err.message) {
		return
	}
	testing.expect_value(t, reopened.commit_seq, sequence)
	after := scalar(t, reopened, "SELECT count(*) FROM users")
	testing.expect_value(t, after.i, i64(1))
	name := scalar(t, reopened, "SELECT name FROM users")
	testing.expect_value(t, name.s, "ana")
	cleanup_db(reopened, "crud")
}

@(test)
test_constraints :: proc(t: ^testing.T) {
	store := fresh_db(t, "constraints")
	if store == nil do return
	defer cleanup_db(store, "constraints")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'a')")

	duplicate_pk := run_error(t, store, "INSERT INTO t VALUES (1, 'b')")
	testing.expect_value(t, duplicate_pk.kind, db.Error_Kind.Duplicate_Primary_Key)

	duplicate_unique := run_error(t, store, "INSERT INTO t VALUES (2, 'a')")
	testing.expect_value(t, duplicate_unique.kind, db.Error_Kind.Duplicate_Unique)

	null_name := run_error(t, store, "INSERT INTO t VALUES (3, NULL)")
	testing.expect_value(t, null_name.kind, db.Error_Kind.Not_Null_Violation)

	missing_table := run_error(t, store, "SELECT * FROM missing")
	testing.expect_value(t, missing_table.kind, db.Error_Kind.Table_Not_Found)

	count := scalar(t, store, "SELECT count(*) FROM t")
	testing.expect_value(t, count.i, i64(1))
}

@(test)
test_transactions :: proc(t: ^testing.T) {
	store := fresh_db(t, "tx")
	if store == nil do return
	defer cleanup_db(store, "tx")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, value INTEGER NOT NULL)")

	tx := db.tx_begin_write(store)
	dropped_result_182, insert_err := db.sql_execute_in_tx(tx, "INSERT INTO t (value) VALUES (1)")
	defer db.error_free(&insert_err)
	defer db.sql_result_destroy(&dropped_result_182)
	testing.expect(t, db.error_ok(insert_err))
	// Inside the transaction the row is visible.
	result, select_err := db.sql_execute_in_tx(tx, "SELECT count(*) FROM t")
	testing.expect(t, db.error_ok(select_err))
	testing.expect_value(t, result.rows[0][0].i, i64(1))
	db.sql_result_destroy(&result)
	db.tx_rollback(tx)

	count := scalar(t, store, "SELECT count(*) FROM t")
	testing.expect_value(t, count.i, i64(0))

	tx2 := db.tx_begin_write(store)
	dropped_result_195, insert_err2 := db.sql_execute_in_tx(tx2, "INSERT INTO t (value) VALUES (2)")
	defer db.error_free(&insert_err2)
	defer db.sql_result_destroy(&dropped_result_195)
	testing.expect(t, db.error_ok(insert_err2))
	commit_err := db.tx_commit(tx2)
	testing.expect(t, db.error_ok(commit_err))

	count2 := scalar(t, store, "SELECT count(*) FROM t")
	testing.expect_value(t, count2.i, i64(1))
}

@(test)
test_aggregates_and_order :: proc(t: ^testing.T) {
	store := fresh_db(t, "agg")
	if store == nil do return
	defer cleanup_db(store, "agg")

	run_done(t, store, "CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, amount DOUBLE NOT NULL)")
	run_done(t, store, "INSERT INTO events (kind, amount) VALUES ('a', 1.0), ('a', 2.0), ('b', 5.0)")

	grouped := run(t, store, "SELECT kind, count(*), sum(amount) FROM events GROUP BY kind ORDER BY kind")
	testing.expect_value(t, len(grouped.rows), 2)
	testing.expect_value(t, grouped.rows[0][0].s, "a")
	testing.expect_value(t, grouped.rows[0][1].i, i64(2))
	testing.expect_value(t, grouped.rows[0][2].f, f64(3))
	testing.expect_value(t, grouped.rows[1][0].s, "b")
	db.sql_result_destroy(&grouped)

	top := run(t, store, "SELECT kind, amount FROM events ORDER BY amount DESC LIMIT 1")
	testing.expect_value(t, len(top.rows), 1)
	testing.expect_value(t, top.rows[0][0].s, "b")
	db.sql_result_destroy(&top)

	distinct_rows := run(t, store, "SELECT DISTINCT kind FROM events ORDER BY kind")
	testing.expect_value(t, len(distinct_rows.rows), 2)
	db.sql_result_destroy(&distinct_rows)

	offset := run(t, store, "SELECT id FROM events ORDER BY id LIMIT 1 OFFSET 1")
	testing.expect_value(t, len(offset.rows), 1)
	testing.expect_value(t, offset.rows[0][0].i, i64(2))
	db.sql_result_destroy(&offset)
}

@(test)
test_reducers :: proc(t: ^testing.T) {
	store := fresh_db(t, "reducer")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "reducer")

	run_done(t, store, "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")

	add :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		amount, _ := db.value_to_i64(args[0])
		dropped_result_248, err := db.sql_execute_in_tx(ctx.tx, "UPDATE counter SET value = value + 1 WHERE id = 0")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_248)
		if !db.error_ok(err) do return err
		_ = amount
		return db.Error{kind = .None}
	}
	failing :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		dropped_result_254, err := db.sql_execute_in_tx(ctx.tx, "UPDATE counter SET value = value + 100 WHERE id = 0")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_254)
		if !db.error_ok(err) do return err
		return db.Error{kind = .Invalid_Argument, message = "deliberate failure"}
	}

	testing.expect(t, db.error_ok(db.host_register(host, "add", []db.Column_Type{db.type_int}, add)))
	testing.expect(t, db.error_ok(db.host_register(host, "boom", nil, failing)))

	run_done(t, store, "INSERT INTO counter (id, value) VALUES (0, 0)")
	testing.expect(t, db.error_ok(db.host_call(host, "add", []db.Value{db.value_int(1)})))
	testing.expect(t, db.error_ok(db.host_call(host, "add", []db.Value{db.value_int(1)})))
	value := scalar(t, store, "SELECT value FROM counter WHERE id = 0")
	testing.expect_value(t, value.i, i64(2))

	// A failing reducer rolls back everything it did.
	failure := db.host_call(host, "boom", nil)
	testing.expect_value(t, failure.kind, db.Error_Kind.Invalid_Argument)
	value2 := scalar(t, store, "SELECT value FROM counter WHERE id = 0")
	testing.expect_value(t, value2.i, i64(2))

	missing := db.host_call(host, "nope", nil)
	defer db.error_free(&missing)
	testing.expect_value(t, missing.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_subscriptions :: proc(t: ^testing.T) {
	store := fresh_db(t, "subs")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "subs")

	run_done(t, store, "CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO items (name) VALUES ('one')")

	id, snapshot, err := db.host_subscribe(host, "SELECT id, name FROM items")
	defer db.host_rows_destroy(snapshot)
	if !testing.expectf(t, db.error_ok(err), "subscribe failed: %s", err.message) {
		return
	}
	testing.expect_value(t, len(snapshot), 1)
	testing.expect_value(t, snapshot[0][1].s, "one")

	seen: ^[2]int = &{0, 0}
	on_update :: proc(ctx: rawptr, update: ^db.Subscription_Update) {
		counters := (^[2]int)(ctx)
		counters[0] += len(update.inserts)
		counters[1] += len(update.deletes)
	}
	seen[0] = 0
	seen[1] = 0
	host.on_update = on_update
	host.on_update_ctx = seen

	run_done(t, store, "INSERT INTO items (name) VALUES ('two')")
	testing.expect_value(t, seen[0], 1)
	testing.expect_value(t, seen[1], 0)

	seen[0] = 0
	run_done(t, store, "DELETE FROM items WHERE name = 'two'")
	testing.expect_value(t, seen[0], 0)
	testing.expect_value(t, seen[1], 1)

	testing.expect(t, db.host_unsubscribe(host, id))
	testing.expect(t, !db.host_unsubscribe(host, id))
}

@(test)
test_parse_errors :: proc(t: ^testing.T) {
	store := fresh_db(t, "parse")
	if store == nil do return
	defer cleanup_db(store, "parse")

	cases := []string{
		"SELECT",
		"SELECT * FROM",
		"INSERT INTO t VALUES",
		"CREATE TABLE t ()",
		"UPDATE t SET",
		"NONSENSE",
	}
	for sql in cases {
		err := run_error(t, store, sql)
		testing.expectf(t, err.kind != .None, "expected %q to fail", sql)
	}
}

@(test)
test_torn_log_tail :: proc(t: ^testing.T) {
	store := fresh_db(t, "torn")
	if store == nil do return

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, value INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (value) VALUES (1)")
	db.store_close(store)

	// Append garbage to the log: replay must keep the valid prefix and cut the
	// torn tail.
	path := "_test_torn/log"
	file, open_err := os.open(path, {.Read, .Write, .Append})
	if !testing.expect(t, open_err == nil) do return
	garbage := []u8{0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02}
	os.write(file, garbage)
	os.close(file)

	reopened, err := db.store_open("_test_torn", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(err), "reopen with a torn tail failed: %s", err.message) {
		return
	}
	value := scalar(t, reopened, "SELECT count(*) FROM t")
	testing.expect_value(t, value.i, i64(1))
	cleanup_db(reopened, "torn")
}

@(test)
test_key_encoding_order :: proc(t: ^testing.T) {
	values := []db.Value {
		db.value_int(-100),
		db.value_int(0),
		db.value_int(100),
		db.value_string("a"),
		db.value_string("ab"),
		db.value_string("b"),
	}
	for i in 0 ..< len(values) - 1 {
		left := db.value_key_bytes(values[i])
		right := db.value_key_bytes(values[i + 1])
		testing.expectf(t, string(left) < string(right), "%v should sort before %v", values[i], values[i + 1])
		delete(left)
		delete(right)
	}
}

@(test)
test_no_embedded_scripting :: proc(t: ^testing.T) {
	// The engine only accepts SQL: a call to a scripting runtime is a parse or
	// unsupported error, never an execution.
	store := fresh_db(t, "noscript")
	if store == nil do return
	defer cleanup_db(store, "noscript")
	err := run_error(t, store, "EVAL python print(1)")
	testing.expect_value(t, err.kind, db.Error_Kind.Sql_Syntax)
}

@(test)
test_time_budget_note :: proc(t: ^testing.T) {
	// Keeps the time import honest for the test harness: a single insert loop
	// should stay well under a second.
	start := time.tick_now()
	store := fresh_db(t, "perf")
	if store == nil do return
	defer cleanup_db(store, "perf")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	for i in 0 ..< 200 {
		sql := fmt.tprintf("INSERT INTO t (v) VALUES (%d)", i)
		run_done(t, store, sql)
	}
	count := scalar(t, store, "SELECT count(*) FROM t")
	testing.expect_value(t, count.i, i64(200))
	elapsed := time.tick_since(start)
	testing.expectf(t, time.duration_seconds(elapsed) < 10, "200 inserts took %v", elapsed)
}

@(test)
test_bind_parameters :: proc(t: ^testing.T) {
	store := fresh_db(t, "params")
	if store == nil do return
	defer cleanup_db(store, "params")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score INTEGER NOT NULL)")

	insert, insert_err := db.sql_execute_params(
		store,
		"INSERT INTO t (name, score) VALUES (?, ?)",
		[]db.Value{db.value_string("ana"), db.value_int(10)},
	)
	testing.expectf(t, db.error_ok(insert_err), "insert: %s", insert_err.message)
	testing.expect_value(t, insert.affected, 1)
	db.sql_result_destroy(&insert)

	dropped_result_435, second_err := db.sql_execute_params(
		store,
		"INSERT INTO t (name, score) VALUES (?, ?)",
		[]db.Value{db.value_string("luis"), db.value_int(20)},
	)
	defer db.error_free(&second_err)
	defer db.sql_result_destroy(&dropped_result_435)
	testing.expect(t, db.error_ok(second_err))

	select, select_err := db.sql_execute_params(
		store,
		"SELECT name FROM t WHERE score > ? ORDER BY score",
		[]db.Value{db.value_int(5)},
	)
	if !testing.expectf(t, db.error_ok(select_err), "select: %s", select_err.message) {
		return
	}
	testing.expect_value(t, len(select.rows), 2)
	testing.expect_value(t, select.rows[0][0].s, "ana")
	db.sql_result_destroy(&select)

	missing := run_error(t, store, "SELECT * FROM t WHERE score = ?")
	testing.expect_value(t, missing.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_index_ddl_and_ranges :: proc(t: ^testing.T) {
	store := fresh_db(t, "indexddl")
	if store == nil do return

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY AUTOINCREMENT, score INTEGER NOT NULL, tag TEXT NOT NULL)")
	for value in ([]int{30, 10, 20, 40, 5}) {
		statement := fmt.tprintf("INSERT INTO item (score, tag) VALUES (%d, 'v%d')", value, value)
		run_done(t, store, statement)
	}

	// No index on score yet: full scan, correct answer.
	plain := run(t, store, "SELECT score FROM item WHERE score >= 20 AND score < 40 ORDER BY score")
	testing.expect_value(t, len(plain.rows), 2)
	testing.expect_value(t, plain.rows[0][0].i, i64(20))
	testing.expect_value(t, plain.rows[1][0].i, i64(30))
	db.sql_result_destroy(&plain)

	run_done(t, store, "CREATE INDEX item_score ON item (score)")

	ranged := run(t, store, "SELECT score FROM item WHERE score >= 20 AND score < 40 ORDER BY score")
	testing.expect_value(t, len(ranged.rows), 2)
	testing.expect_value(t, ranged.rows[0][0].i, i64(20))
	testing.expect_value(t, ranged.rows[1][0].i, i64(30))
	db.sql_result_destroy(&ranged)

	between := run(t, store, "SELECT count(*) FROM item WHERE score BETWEEN 10 AND 30")
	testing.expect_value(t, between.rows[0][0].i, i64(3))
	db.sql_result_destroy(&between)

	greater := run(t, store, "SELECT count(*) FROM item WHERE score > 25")
	testing.expect_value(t, greater.rows[0][0].i, i64(2))
	db.sql_result_destroy(&greater)

	// The index survives a reopen.
	db.store_close(store)
	reopened, open_err := db.store_open("_test_indexddl", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) {
		return
	}
	after := run(t, reopened, "SELECT count(*) FROM item WHERE score >= 25")
	testing.expect_value(t, after.rows[0][0].i, i64(2))
	db.sql_result_destroy(&after)

	run_done(t, reopened, "DROP INDEX item_score")
	run_done(t, reopened, "DROP INDEX IF EXISTS item_score")
	cleanup_db(reopened, "indexddl")
}

@(test)
test_unique_index_from_ddl :: proc(t: ^testing.T) {
	store := fresh_db(t, "uniqueidx")
	if store == nil do return
	defer cleanup_db(store, "uniqueidx")

	run_done(t, store, "CREATE TABLE u (id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL)")
	run_done(t, store, "CREATE UNIQUE INDEX u_code ON u (code)")
	run_done(t, store, "INSERT INTO u (code) VALUES ('a')")

	duplicate := run_error(t, store, "INSERT INTO u (code) VALUES ('a')")
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Unique)

	dropped := run_error(t, store, "DROP INDEX u_pkey")
	testing.expect_value(t, dropped.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_having :: proc(t: ^testing.T) {
	store := fresh_db(t, "having")
	if store == nil do return
	defer cleanup_db(store, "having")

	run_done(t, store, "CREATE TABLE sale (id INTEGER PRIMARY KEY AUTOINCREMENT, shop TEXT NOT NULL, amount INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO sale (shop, amount) VALUES ('a', 5), ('a', 7), ('b', 2), ('c', 20)")

	result := run(t, store, "SELECT shop, sum(amount) AS total FROM sale GROUP BY shop HAVING sum(amount) > 15 ORDER BY shop")
	testing.expect_value(t, len(result.rows), 1)
	testing.expect_value(t, result.rows[0][0].s, "c")
	testing.expect_value(t, result.rows[0][1].i, i64(20))
	db.sql_result_destroy(&result)

	bad := run_error(t, store, "SELECT shop FROM sale HAVING shop = 'a'")
	testing.expect_value(t, bad.kind, db.Error_Kind.Sql_Unsupported)
}

@(test)
test_compaction :: proc(t: ^testing.T) {
	store := fresh_db(t, "compact")
	if store == nil do return

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT NOT NULL)")
	for i in 0 ..< 50 {
		run_done(t, store, fmt.tprintf("INSERT INTO t (v) VALUES ('row%d')", i))
	}
	run_done(t, store, "DELETE FROM t WHERE id < 10")
	sequence := store.commit_seq

	path := "_test_compact/log"
	size_before, _ := os.stat(path, context.temp_allocator)
	compact_err := db.store_compact(store)
	if !testing.expectf(t, db.error_ok(compact_err), "compact: %s", compact_err.message) {
		return
	}
	size_after, _ := os.stat(path, context.temp_allocator)
	testing.expectf(t, size_after.size < size_before.size, "compaction did not shrink the log")
	// The rewritten log carries the snapshot payload, so the standalone copy is
	// gone: a compacted database is one artifact, not two.
	testing.expect(
		t,
		!os.exists("_test_compact/snapshot"),
		"compaction must not leave the duplicate snapshot file",
	)

	// A commit after compaction keeps working and keeps the sequence.
	run_done(t, store, "INSERT INTO t (v) VALUES ('after')")
	testing.expect_value(t, store.commit_seq, sequence + 1)
	count := scalar(t, store, "SELECT count(*) FROM t")
	testing.expect_value(t, count.i, i64(42)) // 50 - 9 + 1

	db.store_close(store)
	reopened, open_err := db.store_open("_test_compact", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) {
		return
	}
	after := scalar(t, reopened, "SELECT count(*) FROM t")
	testing.expect_value(t, after.i, i64(42))
	testing.expect_value(t, reopened.commit_seq, sequence + 1)
	cleanup_db(reopened, "compact")
}

@(test)
test_ordered_index_scan_bounds :: proc(t: ^testing.T) {
	store := fresh_db(t, "bounds")
	if store == nil do return
	defer cleanup_db(store, "bounds")

	run_done(t, store, "CREATE TABLE n (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "CREATE INDEX n_v ON n (v)")
	for value in ([]int{-5, -1, 0, 1, 5, 100}) {
		run_done(t, store, fmt.tprintf("INSERT INTO n (v) VALUES (%d)", value))
	}
	cases := []struct {
		sql:   string,
		count: i64,
	}{
		{"SELECT count(*) FROM n WHERE v < 0", 2},
		{"SELECT count(*) FROM n WHERE v <= 0", 3},
		{"SELECT count(*) FROM n WHERE v > 0", 3},
		{"SELECT count(*) FROM n WHERE v >= 1", 3},
		{"SELECT count(*) FROM n WHERE v = 0", 1},
		{"SELECT count(*) FROM n WHERE v BETWEEN -1 AND 5", 4},
		{"SELECT count(*) FROM n WHERE v > -6 AND v < 6", 5},
	}
	for test_case in cases {
		result := run(t, store, test_case.sql)
		testing.expectf(t, result.rows[0][0].i == test_case.count, "%s returned %v", test_case.sql, result.rows[0][0].i)
		db.sql_result_destroy(&result)
	}
}

@(test)
test_scheduler :: proc(t: ^testing.T) {
	store := fresh_db(t, "scheduler")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "scheduler")

	run_done(t, store, "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO counter (id, value) VALUES (0, 0)")

	bump :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		amount, _ := db.value_to_i64(args[0])
		statement := fmt.tprintf("UPDATE counter SET value = value + %d WHERE id = 0", amount)
		dropped_result_632, err := db.sql_execute_in_tx(ctx.tx, statement)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_632)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(host, "bump", []db.Column_Type{db.type_int}, bump)))

	now := i64(1_700_000_000_000_000)
	host.now_us = now
	_, schedule_err := db.host_schedule(host, "bump", now + 60_000_000, []db.Value{db.value_int(5)})
	testing.expectf(t, db.error_ok(schedule_err), "schedule: %s", schedule_err.message)

	// Not due yet.
	ran, tick_err := db.host_tick(host, now)
	testing.expect(t, db.error_ok(tick_err))
	testing.expect_value(t, ran, 0)
	value := scalar(t, store, "SELECT value FROM counter WHERE id = 0")
	testing.expect_value(t, value.i, i64(0))

	// Due: the reducer runs and the schedule row disappears.
	ran2, tick_err2 := db.host_tick(host, now + 61_000_000)
	testing.expect(t, db.error_ok(tick_err2))
	testing.expect_value(t, ran2, 1)
	value2 := scalar(t, store, "SELECT value FROM counter WHERE id = 0")
	testing.expect_value(t, value2.i, i64(5))
	pending := scalar(t, store, "SELECT count(*) FROM _schedule")
	testing.expect_value(t, pending.i, i64(0))

	// Unknown reducer: the call is dropped and reported, not retried forever.
	_, bad_schedule := db.host_schedule(host, "bump", now + 1, []db.Value{db.value_int(1)})
	testing.expect(t, db.error_ok(bad_schedule))
	testing.expect(t, db.error_ok(db.host_register(host, "other", nil, bump)))
	_, _ = db.host_tick(host, now + 2)
}

@(private)
join_fixture :: proc(t: ^testing.T, store: ^db.Store) {
	run_done(t, store, "CREATE TABLE author (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)")
	run_done(t, store, "CREATE TABLE book (id INTEGER PRIMARY KEY AUTOINCREMENT, author_id INTEGER NOT NULL, title TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO author (name) VALUES ('ana'), ('luis'), ('zoe')")
	run_done(t, store, "INSERT INTO book (author_id, title) VALUES (1, 'a1'), (1, 'a2'), (2, 'b1'), (9, 'orphan')")
}

@(test)
test_joins :: proc(t: ^testing.T) {
	store := fresh_db(t, "joins")
	if store == nil do return
	defer cleanup_db(store, "joins")
	join_fixture(t, store)

	inner := run(t, store, `
		SELECT author.name, book.title
		FROM author JOIN book ON author.id = book.author_id
		ORDER BY author.id, book.id`)
	testing.expect_value(t, len(inner.rows), 3)
	testing.expect_value(t, inner.rows[0][0].s, "ana")
	testing.expect_value(t, inner.rows[0][1].s, "a1")
	testing.expect_value(t, inner.rows[2][0].s, "luis")
	db.sql_result_destroy(&inner)

	aliased := run(t, store, `
		SELECT a.name, b.title
		FROM author AS a INNER JOIN book b ON a.id = b.author_id
		WHERE b.title = 'b1'`)
	testing.expect_value(t, len(aliased.rows), 1)
	testing.expect_value(t, aliased.rows[0][1].s, "b1")
	db.sql_result_destroy(&aliased)

	left := run(t, store, `
		SELECT author.name, book.title
		FROM author LEFT JOIN book ON author.id = book.author_id
		ORDER BY author.id`)
	testing.expect_value(t, len(left.rows), 4) // ana x2, luis x1, zoe with NULL
	testing.expect_value(t, left.rows[3][0].s, "zoe")
	testing.expect_value(t, left.rows[3][1].kind, db.Value_Kind.Null)
	db.sql_result_destroy(&left)

	grouped := run(t, store, `
		SELECT author.name, count(*)
		FROM author JOIN book ON author.id = book.author_id
		GROUP BY author.id, author.name
		ORDER BY author.id`)
	testing.expect_value(t, len(grouped.rows), 2)
	testing.expect_value(t, grouped.rows[0][1].i, i64(2))
	testing.expect_value(t, grouped.rows[1][1].i, i64(1))
	db.sql_result_destroy(&grouped)

	star := run(t, store, "SELECT b.* FROM book AS b WHERE b.title = 'orphan'")
	testing.expect_value(t, len(star.columns), 3)
	testing.expect_value(t, star.columns[2], "title")
	testing.expect_value(t, star.rows[0][2].s, "orphan")
	db.sql_result_destroy(&star)

	ambiguous := run_error(t, store, "SELECT id FROM author JOIN book ON author.id = book.author_id")
	testing.expect_value(t, ambiguous.kind, db.Error_Kind.Column_Not_Found)

	// A JOIN without ON is a cross join: every author pairs with every book.
	cross := run(t, store, "SELECT count(*) FROM author JOIN book")
	testing.expect_value(t, cross.rows[0][0].i, i64(12))
	db.sql_result_destroy(&cross)
}

@(test)
test_join_subscription :: proc(t: ^testing.T) {
	store := fresh_db(t, "joinsub")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "joinsub")
	join_fixture(t, store)

	_, snapshot, sub_err := db.host_subscribe(host, `
		SELECT author.name, book.title
		FROM author JOIN book ON author.id = book.author_id`)
	defer db.host_rows_destroy(snapshot)
	if !testing.expectf(t, db.error_ok(sub_err), "subscribe: %s", sub_err.message) {
		return
	}
	testing.expect_value(t, len(snapshot), 3)

	inserted := 0
	deleted := 0
	counters: [2]int
	host.on_update = proc(ctx: rawptr, update: ^db.Subscription_Update) {
		counters := (^[2]int)(ctx)
		counters[0] += len(update.inserts)
		counters[1] += len(update.deletes)
	}
	host.on_update_ctx = &counters

	// A change in the joined table must refresh the subscription.
	run_done(t, store, "INSERT INTO book (author_id, title) VALUES (2, 'z1')")
	testing.expect_value(t, counters[0], 1)
	testing.expect_value(t, counters[1], 0)
	inserted = counters[0]
	deleted = counters[1]
	_ = inserted
	_ = deleted
}

// --- Join subscription helpers ---------------------------------------------

@(private)
row_set_key :: proc(row: []db.Value) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for value, i in row {
		if i > 0 do strings.write_byte(&b, 0x1f)
		text := db.value_format(value, context.temp_allocator)
		strings.write_string(&b, text)
	}
	return strings.clone(strings.to_string(b))
}

@(private)
Join_Deltas :: struct {
	inserts:    [dynamic][]db.Value,
	deletes:    [dynamic][]db.Value,
	updates:    int,
	last_table: string,
}

@(private)
join_delta_capture :: proc(ctx: rawptr, update: ^db.Subscription_Update) {
	deltas := (^Join_Deltas)(ctx)
	deltas.updates += 1
	deltas.last_table = update.table
	for row in update.inserts do append(&deltas.inserts, db.value_row_clone(row))
	for row in update.deletes do append(&deltas.deletes, db.value_row_clone(row))
}

// join_deltas_destroy frees the rows still captured, both lists and the deltas.
@(private)
join_deltas_destroy :: proc(deltas: ^Join_Deltas) {
	join_deltas_clear(deltas)
	delete(deltas.inserts)
	delete(deltas.deletes)
	free(deltas)
}

@(private)
join_deltas_clear :: proc(deltas: ^Join_Deltas) -> (inserts, deletes: int) {
	inserts = len(deltas.inserts)
	deletes = len(deltas.deletes)
	for row in deltas.inserts do db.free_values(row)
	for row in deltas.deletes do db.free_values(row)
	clear(&deltas.inserts)
	clear(&deltas.deletes)
	return
}

@(private)
join_set_from_snapshot :: proc(snapshot: [][]db.Value) -> [dynamic]string {
	set: [dynamic]string
	for row in snapshot do append(&set, row_set_key(row))
	return set
}

@(private)
join_set_destroy :: proc(set: ^[dynamic]string) {
	for key in set^ do delete(key)
	delete(set^)
}

// join_set_apply folds a delta into the set: an insert adds a row, a delete must
// match one that was there. `width` is the projection the set tracks, so the
// deltas of a second subscription over the same tables are ignored.
@(private)
join_set_apply :: proc(
	t: ^testing.T,
	set: ^[dynamic]string,
	deltas: ^Join_Deltas,
	width: int,
) {
	for row in deltas.inserts {
		if len(row) == width do append(set, row_set_key(row))
	}
	for row in deltas.deletes {
		if len(row) != width do continue
		key := row_set_key(row)
		found := -1
		for existing, i in set^ {
			if strings.compare(existing, key) == 0 {
				found = i
				break
			}
		}
		if found < 0 {
			testing.expectf(t, false, "a delete arrived for a row that was not in the set: %s", key)
		} else {
			delete(set^[found])
			unordered_remove(set, found)
		}
		delete(key)
	}
}

// join_set_matches_fresh checks the accumulated set against a new subscription
// for the same query, so the deltas and the state they built have to agree with
// what a full evaluation returns.
@(private)
join_set_matches_fresh :: proc(
	t: ^testing.T,
	host: ^db.Host,
	sql: string,
	set: ^[dynamic]string,
	label: string,
) {
	id, snapshot, err := db.host_subscribe(host, sql)
	if !testing.expectf(t, db.error_ok(err), "%s: fresh subscribe failed: %s", label, err.message) {
		return
	}
	fresh := join_set_from_snapshot(snapshot)
	slice.sort(set^[:])
	slice.sort(fresh[:])
	same := len(set^) == len(fresh)
	if same {
		for key, i in set^ {
			if strings.compare(key, fresh[i]) != 0 {
				same = false
				break
			}
		}
	}
	if !same {
		for key in set^ do fmt.printfln("%s [cached] %s", label, key)
		for key in fresh do fmt.printfln("%s [fresh] %s", label, key)
	}
	testing.expectf(t, same, "%s: cached %d rows, fresh %d", label, len(set^), len(fresh))
	join_set_destroy(&fresh)
	for row in snapshot do db.free_values(row)
	delete(snapshot)
	db.host_unsubscribe(host, id)
}

@(test)
test_join_subscription_walks_the_planned_order :: proc(t: ^testing.T) {
	// A subscription over `big JOIN small` written big-first would walk every row of
	// big and probe small once per row. The same query written small-first walks
	// small and probes big, so the plan decides which one the subscription does --
	// and because the tuple index is keyed by source position, that order is chosen
	// once and kept.
	store := fresh_db(t, "joinsub_order")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "joinsub_order")

	run_done(t, store, "CREATE TABLE author (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE TABLE book (id INTEGER PRIMARY KEY, author_id INTEGER, title TEXT)")
	run_done(t, store, "CREATE INDEX book_author ON book (author_id)")
	authors := 5
	books := 1000
	insert_authors := strings.builder_make()
	defer strings.builder_destroy(&insert_authors)
	strings.write_string(&insert_authors, "INSERT INTO author (id, name) VALUES ")
	for i in 0 ..< authors {
		if i > 0 do strings.write_string(&insert_authors, ", ")
		fmt.sbprintf(&insert_authors, "(%d, 'a%d')", i + 1, i + 1)
	}
	run_done(t, store, strings.to_string(insert_authors))
	insert_books := strings.builder_make()
	defer strings.builder_destroy(&insert_books)
	strings.write_string(&insert_books, "INSERT INTO book (id, author_id, title) VALUES ")
	for i in 0 ..< books {
		if i > 0 do strings.write_string(&insert_books, ", ")
		fmt.sbprintf(&insert_books, "(%d, %d, 'b%d')", i + 1, (i % authors) + 1, i + 1)
	}
	run_done(t, store, strings.to_string(insert_books))
	run_done(t, store, "ANALYZE")

	// Written big-first: the plan still starts with the five authors.
	big_first := "SELECT author.name, book.title FROM book JOIN author ON author.id = book.author_id"
	before := db.host_join_rows_walked(host)
	id, snapshot, err := db.host_subscribe(host, big_first)
	if !testing.expectf(t, db.error_ok(err), "subscribe: %s", err.message) do return
	walked := db.host_join_rows_walked(host) - before
	testing.expect_value(t, len(snapshot), books)
	// The written order walks a thousand books and probes an author for each: exactly
	// two thousand candidates. The planned order walks five authors and fetches the
	// books of each, so anything close to a thousand is the plan deciding.
	testing.expectf(t, walked < u64(books) + 100, "the subscription walked %d rows of %d", walked, books)
	big_set := join_set_from_snapshot(snapshot)
	for row in snapshot do db.free_values(row)
	delete(snapshot)

	// The other spelling answers the same set, so the order is a decision about work
	// and not about the answer.
	small_first := "SELECT author.name, book.title FROM author JOIN book ON author.id = book.author_id"
	other_id, other_snapshot, other_err := db.host_subscribe(host, small_first)
	if testing.expectf(t, db.error_ok(other_err), "subscribe: %s", other_err.message) {
		small_set := join_set_from_snapshot(other_snapshot)
		slice.sort(big_set[:])
		slice.sort(small_set[:])
		same := len(big_set) == len(small_set)
		if same {
			for key, i in big_set {
				if strings.compare(key, small_set[i]) != 0 {
					same = false
					break
				}
			}
		}
		testing.expectf(t, same, "the two spellings answered %d and %d rows", len(big_set), len(small_set))
		join_set_destroy(&small_set)
		for row in other_snapshot do db.free_values(row)
		delete(other_snapshot)
	}
	join_set_destroy(&big_set)

	// A commit still publishes the right delta through the reordered walk.
	deltas := new(Join_Deltas)
	defer join_deltas_destroy(deltas)
	host.on_update = join_delta_capture
	host.on_update_ctx = deltas
	run_done(t, store, "INSERT INTO book (author_id, title) VALUES (3, 'new')")
	inserts, deletes := join_deltas_clear(deltas)
	testing.expectf(t, inserts >= 1 && deletes == 0, "insert published %d/%d", inserts, deletes)
	run_done(t, store, "UPDATE author SET name = 'renamed' WHERE id = 3")
	inserts, deletes = join_deltas_clear(deltas)
	testing.expectf(t, inserts >= 1 && inserts == deletes, "rename published %d/%d", inserts, deletes)

	db.host_unsubscribe(host, id)
	db.host_unsubscribe(host, other_id)
}

@(test)
test_join_probes_the_inner_index :: proc(t: ^testing.T) {
	// A nested loop reads the inner rows its ON clause names, not the whole
	// relation once per outer row. The row counter is what proves it: with the
	// probe the statement reads about one row per outer row plus the outer scan,
	// and without it the same statement reads outer times inner.
	store := fresh_db(t, "join_probe")
	if store == nil do return
	defer cleanup_db(store, "join_probe")

	run_done(t, store, "CREATE TABLE author (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE TABLE book (id INTEGER PRIMARY KEY, author_id INTEGER, title TEXT)")
	run_done(t, store, "CREATE INDEX book_author ON book (author_id)")
	authors := 200
	books := 1000
	insert_authors := strings.builder_make()
	defer strings.builder_destroy(&insert_authors)
	strings.write_string(&insert_authors, "INSERT INTO author (id, name) VALUES ")
	for i in 0 ..< authors {
		if i > 0 do strings.write_string(&insert_authors, ", ")
		fmt.sbprintf(&insert_authors, "(%d, 'a%d')", i + 1, i + 1)
	}
	run_done(t, store, strings.to_string(insert_authors))
	insert_books := strings.builder_make()
	defer strings.builder_destroy(&insert_books)
	strings.write_string(&insert_books, "INSERT INTO book (id, author_id, title) VALUES ")
	for i in 0 ..< books {
		if i > 0 do strings.write_string(&insert_books, ", ")
		fmt.sbprintf(&insert_books, "(%d, %d, 'b%d')", i + 1, (i % authors) + 1, i + 1)
	}
	run_done(t, store, strings.to_string(insert_books))

	db.store_reset_rows_scanned(store)
	junction, err := db.sql_execute(store, `
		SELECT author.name, book.title
		FROM author JOIN book ON author.id = book.author_id`)
	if !testing.expectf(t, db.error_ok(err), "join failed: %s", err.message) do return
	scanned := db.store_rows_scanned(store)
	testing.expect_value(t, len(junction.rows), books)
	// A scan of the inner relation would visit 200 * 1000 rows.
	testing.expectf(t, scanned < 4000, "the join read %d rows of %d", scanned, books)
	db.sql_result_destroy(&junction)

	// Every row arrives with the right author, which is what a wrong key or a
	// missing candidate would break.
	one, one_err := db.sql_execute(store, `
		SELECT author.name FROM author JOIN book ON author.id = book.author_id
		WHERE book.id = 3`)
	if testing.expectf(t, db.error_ok(one_err), "point join failed: %s", one_err.message) {
		testing.expect_value(t, len(one.rows), 1)
		if len(one.rows) == 1 do testing.expect_value(t, one.rows[0][0].s, "a3")
		db.sql_result_destroy(&one)
	}

	// A join the probe cannot answer still answers: the ON compares two columns of
	// the inner table, so the value side cannot be evaluated from the outer row.
	inner, inner_err := db.sql_execute(store, `
		SELECT count(*) FROM author JOIN book ON author.id = book.author_id + 0`)
	if testing.expectf(t, db.error_ok(inner_err), "expression join failed: %s", inner_err.message) {
		testing.expect_value(t, inner.rows[0][0].i, i64(books))
		db.sql_result_destroy(&inner)
	}

	// A LEFT join keeps the outer row that matched nothing, with or without the
	// probe.
	run_done(t, store, "INSERT INTO author (id, name) VALUES (999, 'lonely')")
	left, left_err := db.sql_execute(store, `
		SELECT author.name, book.title
		FROM author LEFT JOIN book ON author.id = book.author_id
		WHERE author.id = 999`)
	if testing.expectf(t, db.error_ok(left_err), "left join failed: %s", left_err.message) {
		testing.expect_value(t, len(left.rows), 1)
		db.sql_result_destroy(&left)
	}

	// The plan says which index the loop probes, so the name in the plan and the
	// work the statement did cannot disagree.
	plan, plan_err := db.sql_execute(store, `
		EXPLAIN SELECT author.name FROM author JOIN book ON author.id = book.author_id`)
	if testing.expectf(t, db.error_ok(plan_err), "explain failed: %s", plan_err.message) {
		joined := false
		for row in plan.rows {
			if strings.has_prefix(row[0].s, "join book using index book_author") do joined = true
		}
		testing.expect(t, joined)
		db.sql_result_destroy(&plan)
	}
}

@(test)
test_incremental_join_subscription :: proc(t: ^testing.T) {
	store := fresh_db(t, "joinsub_inc")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "joinsub_inc")
	join_fixture(t, store)

	sql := `
		SELECT author.name, book.title
		FROM author JOIN book ON author.id = book.author_id
		WHERE book.title <> 'skip'`
	id, snapshot, err := db.host_subscribe(host, sql)
	if !testing.expectf(t, db.error_ok(err), "subscribe failed: %s", err.message) do return
	set := join_set_from_snapshot(snapshot)
	testing.expect_value(t, len(set), 3)
	for row in snapshot do db.free_values(row)
	delete(snapshot)

	deltas := new(Join_Deltas)
	defer join_deltas_destroy(deltas)
	host.on_update = join_delta_capture
	host.on_update_ctx = deltas

	Step :: struct {
		sql:     string,
		inserts: int,
		deletes: int,
	}
	steps := []Step{
		// A book insert pairs with its author.
		{"INSERT INTO book (author_id, title) VALUES (2, 'z1')", 1, 0},
		// A change on the joined side: the old tuple goes, the new one arrives.
		{"UPDATE book SET title = 'z2' WHERE title = 'z1'", 1, 1},
		// A change on the base side moves every tuple that names the row.
		{"UPDATE author SET name = 'renamed' WHERE id = 1", 2, 2},
		{"DELETE FROM book WHERE title = 'z2'", 0, 1},
		{"DELETE FROM author WHERE id = 2", 0, 1},
		// The fixture has a book whose author_id is 9: giving author 9 a row
		// makes that orphan join.
		{"INSERT INTO author (id, name) VALUES (9, 'nine')", 1, 0},
		{"INSERT INTO book (author_id, title) VALUES (9, 'n1')", 1, 0},
		{"UPDATE book SET author_id = 1 WHERE title = 'n1'", 1, 1},
	}
	for step in steps {
		run_done(t, store, step.sql)
		join_set_apply(t, &set, deltas, 2)
		inserts, deletes := join_deltas_clear(deltas)
		testing.expectf(
			t,
			inserts == step.inserts && deletes == step.deletes,
			"%s: expected %d/%d inserts/deletes, got %d/%d",
			step.sql,
			step.inserts,
			step.deletes,
			inserts,
			deletes,
		)
		join_set_matches_fresh(t, host, sql, &set, step.sql)
	}
	testing.expect(t, db.host_incremental_updates(host) >= 6)
	testing.expect_value(t, deltas.last_table, "author")

	// A DDL statement falls back to the full evaluation and re-indexes, so the
	// next row change is incremental again.
	run_done(t, store, "CREATE INDEX book_title ON book (title)")
	inserts, deletes := join_deltas_clear(deltas)
	testing.expectf(t, inserts == 0 && deletes == 0, "DDL published %d/%d deltas", inserts, deletes)
	run_done(t, store, "INSERT INTO book (author_id, title) VALUES (9, 'n2')")
	join_set_apply(t, &set, deltas, 2)
	inserts, deletes = join_deltas_clear(deltas)
	testing.expect_value(t, inserts, 1)
	testing.expect_value(t, deletes, 0)
	join_set_matches_fresh(t, host, sql, &set, "after the index")

	// Three books point at ana, so the raw snapshot repeats her name while the
	// cached set keeps one row: the row only goes when the last tuple does.
	dup_sql := "SELECT author.name FROM author JOIN book ON author.id = book.author_id"
	dup_id, dup_snapshot, dup_err := db.host_subscribe(host, dup_sql)
	if !testing.expectf(t, db.error_ok(dup_err), "subscribe failed: %s", dup_err.message) do return
	testing.expect_value(t, len(dup_snapshot), 5)
	for row in dup_snapshot do db.free_values(row)
	delete(dup_snapshot)
	// Each delete still costs the first subscription one row, so the totals are
	// one per removed book until the duplicate count of the second drops.
	dup_steps := []Step{
		{"DELETE FROM book WHERE title = 'a1'", 0, 1},
		{"DELETE FROM book WHERE title = 'a2'", 0, 1},
		{"DELETE FROM book WHERE title = 'n1'", 0, 2},
	}
	for step in dup_steps {
		run_done(t, store, step.sql)
		join_set_apply(t, &set, deltas, 2)
		inserts, deletes = join_deltas_clear(deltas)
		testing.expectf(
			t,
			inserts == step.inserts && deletes == step.deletes,
			"%s: expected %d/%d inserts/deletes, got %d/%d",
			step.sql,
			step.inserts,
			step.deletes,
			inserts,
			deletes,
		)
	}
	db.host_unsubscribe(host, dup_id)
	join_set_matches_fresh(t, host, sql, &set, "after the duplicates")
	db.host_unsubscribe(host, id)
	join_set_destroy(&set)
}

@(test)
test_join_subscription_probes_the_join_key :: proc(t: ^testing.T) {
	// An equi-join is indexed by its key: a commit visits the rows the key names,
	// not every row of the joined table. The counter is what proves it -- the
	// answers were already right when the walk read the whole table.
	store := fresh_db(t, "joinsub_probe")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "joinsub_probe")

	run_done(t, store, "CREATE TABLE author (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE TABLE book (id INTEGER PRIMARY KEY, author_id INTEGER, title TEXT)")
	authors := 200
	books := 900
	insert_authors := strings.builder_make()
	defer strings.builder_destroy(&insert_authors)
	strings.write_string(&insert_authors, "INSERT INTO author (id, name) VALUES ")
	for i in 0 ..< authors {
		if i > 0 do strings.write_string(&insert_authors, ", ")
		fmt.sbprintf(&insert_authors, "(%d, 'a%d')", i + 1, i + 1)
	}
	run_done(t, store, strings.to_string(insert_authors))
	insert_books := strings.builder_make()
	defer strings.builder_destroy(&insert_books)
	strings.write_string(&insert_books, "INSERT INTO book (id, author_id, title) VALUES ")
	for i in 0 ..< books {
		if i > 0 do strings.write_string(&insert_books, ", ")
		fmt.sbprintf(&insert_books, "(%d, %d, 'b%d')", i + 1, (i % authors) + 1, i + 1)
	}
	run_done(t, store, strings.to_string(insert_books))

	sql := "SELECT author.name, book.title FROM author JOIN book ON author.id = book.author_id"
	id, snapshot, sub_err := db.host_subscribe(host, sql)
	if !testing.expectf(t, db.error_ok(sub_err), "subscribe: %s", sub_err.message) do return
	set := join_set_from_snapshot(snapshot)
	testing.expect_value(t, len(set), books)
	for row in snapshot do db.free_values(row)
	delete(snapshot)

	deltas := new(Join_Deltas)
	defer join_deltas_destroy(deltas)
	host.on_update = join_delta_capture
	host.on_update_ctx = deltas

	// A new book probes its author: one candidate, not `authors` of them.
	before := db.host_join_rows_walked(host)
	run_done(t, store, "INSERT INTO book (author_id, title) VALUES (7, 'n1')")
	walked := db.host_join_rows_walked(host) - before
	join_set_apply(t, &set, deltas, 2)
	inserts, deletes := join_deltas_clear(deltas)
	testing.expectf(t, inserts == 1 && deletes == 0, "insert published %d/%d", inserts, deletes)
	testing.expectf(t, walked <= 4, "an insert walked %d rows of %d authors", walked, authors)

	// A change on the base side probes the books of that author: the five that
	// point at it, not all 900 books.
	before = db.host_join_rows_walked(host)
	run_done(t, store, "UPDATE author SET name = 'renamed' WHERE id = 7")
	walked = db.host_join_rows_walked(host) - before
	join_set_apply(t, &set, deltas, 2)
	inserts, deletes = join_deltas_clear(deltas)
	testing.expectf(t, inserts == deletes && inserts >= 4, "update published %d/%d", inserts, deletes)
	testing.expectf(t, walked <= 8, "an update walked %d rows of %d books", walked, books)
	join_set_matches_fresh(t, host, sql, &set, "after the probe")

	// Moving a book to another author takes it out of the old key and files it
	// under the new one, so both sides answer correctly afterwards.
	run_done(t, store, "UPDATE book SET author_id = 1 WHERE id = 8")
	join_set_apply(t, &set, deltas, 2)
	inserts, deletes = join_deltas_clear(deltas)
	testing.expectf(t, inserts == 1 && deletes == 1, "move published %d/%d", inserts, deletes)
	join_set_matches_fresh(t, host, sql, &set, "after the move")

	// A join that cannot be indexed still answers: the key here is an expression,
	// so the walk reads the table and the deltas stay correct.
	expr_sql := "SELECT author.name, book.title FROM author JOIN book ON author.id + 0 = book.author_id"
	expr_id, expr_snapshot, expr_err := db.host_subscribe(host, expr_sql)
	if testing.expectf(t, db.error_ok(expr_err), "subscribe: %s", expr_err.message) {
		testing.expect_value(t, len(expr_snapshot), books + 1)
		for row in expr_snapshot do db.free_values(row)
		delete(expr_snapshot)
		updates_before := deltas.updates
		run_done(t, store, "INSERT INTO book (author_id, title) VALUES (3, 'n2')")
		testing.expect(t, deltas.updates > updates_before)
		join_deltas_clear(deltas)
		db.host_unsubscribe(host, expr_id)
	}
	db.host_unsubscribe(host, id)
	join_set_destroy(&set)
}

@(test)
test_incremental_aggregate_subscription :: proc(t: ^testing.T) {
	store := fresh_db(t, "aggsub_inc")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "aggsub_inc")
	run_done(t, store, "CREATE TABLE sales (id INTEGER PRIMARY KEY AUTOINCREMENT, region TEXT NOT NULL, amount INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO sales (region, amount) VALUES ('east', 10), ('east', 5), ('west', 3)")

	sql := "SELECT region, count(*), sum(amount) FROM sales GROUP BY region"
	id, snapshot, err := db.host_subscribe(host, sql)
	if !testing.expectf(t, db.error_ok(err), "subscribe failed: %s", err.message) do return
	testing.expect_value(t, len(snapshot), 2)
	set := join_set_from_snapshot(snapshot)
	defer join_set_destroy(&set)
	for row in snapshot do db.free_values(row)
	delete(snapshot)

	// A second, ungrouped subscription counts everything: it shares the commit
	// hook but publishes one column, so the set above ignores its deltas.
	total_sql := "SELECT count(*) FROM sales"
	total_id, total_snapshot, total_err := db.host_subscribe(host, total_sql)
	if !testing.expectf(t, db.error_ok(total_err), "subscribe failed: %s", total_err.message) do return
	testing.expect_value(t, len(total_snapshot), 1)
	total_set := join_set_from_snapshot(total_snapshot)
	defer join_set_destroy(&total_set)
	for row in total_snapshot do db.free_values(row)
	delete(total_snapshot)

	deltas := new(Join_Deltas)
	defer join_deltas_destroy(deltas)
	host.on_update = join_delta_capture
	host.on_update_ctx = deltas

	Step :: struct {
		sql:     string,
		inserts: int,
		deletes: int,
	}
	steps := []Step{
		// A new group appears.
		{"INSERT INTO sales (region, amount) VALUES ('north', 4)", 2, 1},
		// An existing group changes: delete plus insert, plus the total.
		{"INSERT INTO sales (region, amount) VALUES ('east', 1)", 2, 2},
		// An update inside the group changes the aggregate, not the total.
		{"UPDATE sales SET amount = 7 WHERE region = 'east' AND amount = 1", 1, 1},
		// Moving the group key empties one group and changes another.
		{"UPDATE sales SET region = 'west' WHERE region = 'north'", 1, 2},
		{"DELETE FROM sales WHERE region = 'east' AND amount = 7", 2, 2},
		{"DELETE FROM sales WHERE region = 'west' AND amount = 3", 2, 2},
		// The last row of the east group goes: only a delete, the group is gone.
		{"DELETE FROM sales WHERE region = 'east' AND amount = 5", 2, 2},
		{"DELETE FROM sales WHERE region = 'east'", 1, 2},
	}
	for step in steps {
		run_done(t, store, step.sql)
		join_set_apply(t, &set, deltas, 3)
		join_set_apply(t, &total_set, deltas, 1)
		inserts, deletes := join_deltas_clear(deltas)
		testing.expectf(
			t,
			inserts == step.inserts && deletes == step.deletes,
			"%s: expected %d/%d inserts/deletes, got %d/%d",
			step.sql,
			step.inserts,
			step.deletes,
			inserts,
			deletes,
		)
		join_set_matches_fresh(t, host, sql, &set, step.sql)
	}
	testing.expect(t, db.host_incremental_updates(host) >= 6)
	join_set_matches_fresh(t, host, total_sql, &total_set, "total")
	db.host_unsubscribe(host, id)
	// The second subscription outlives the first one and tears down on its own.
	testing.expect(t, db.host_unsubscribe(host, total_id))
}

@(test)
test_unsupported_joins_are_refused :: proc(t: ^testing.T) {
	store := fresh_db(t, "join_refused")
	if store == nil do return
	defer cleanup_db(store, "join_refused")
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO a (id) VALUES (1), (2), (3)")
	run_done(t, store, "INSERT INTO b (id) VALUES (2), (3), (4)")

	// NATURAL is not an alias for the preceding table: it joins on the shared
	// id (two rows here, not the nine of a cross join).
	natural := run(t, store, "SELECT count(*) FROM a NATURAL JOIN b")
	testing.expect_value(t, natural.rows[0][0].i, i64(2))
	db.sql_result_destroy(&natural)
	natural_left := run(t, store, "SELECT count(*) FROM a NATURAL LEFT JOIN b")
	testing.expect_value(t, natural_left.rows[0][0].i, i64(3))
	db.sql_result_destroy(&natural_left)

	// LEFT OUTER still parses, and keeps the three rows of the left side.
	left := run(t, store, "SELECT count(*) FROM a LEFT OUTER JOIN b ON a.id = b.id")
	testing.expect_value(t, left.rows[0][0].i, i64(3))
	db.sql_result_destroy(&left)
	// The inner join is the answer RIGHT and FULL would have had to extend.
	inner := run(t, store, "SELECT count(*) FROM a JOIN b ON a.id = b.id")
	testing.expect_value(t, inner.rows[0][0].i, i64(2))
	db.sql_result_destroy(&inner)
}

@(test)
test_integrity_and_latency_stats :: proc(t: ^testing.T) {
	store := fresh_db(t, "integrity")
	if store == nil do return
	defer cleanup_db(store, "integrity")
	run_done(t, store, "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT UNIQUE)")
	run_done(t, store, "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER, amount INTEGER, FOREIGN KEY (parent_id) REFERENCES parent (id))")
	run_done(t, store, "CREATE INDEX child_amount ON child (amount)")
	run_done(t, store, "INSERT INTO parent (id, name) VALUES (1, 'one'), (2, 'two')")
	run_done(t, store, "INSERT INTO child (id, parent_id, amount) VALUES (1, 1, 10), (2, 2, 20), (3, 1, 30)")

	// A healthy database answers `ok` and has no orphans.
	healthy := run(t, store, "PRAGMA integrity_check")
	testing.expect_value(t, len(healthy.rows), 1)
	testing.expect_value(t, healthy.rows[0][0].s, "ok")
	db.sql_result_destroy(&healthy)
	orphans := run(t, store, "PRAGMA foreign_key_check")
	testing.expect_value(t, len(orphans.rows), 0)
	db.sql_result_destroy(&orphans)

	// A raw apply is how a replay writes, and it is the one way a row can reach
	// the tables without the SQL checks. The checker must report it.
	orphan_values := make([]db.Value, 3)
	orphan_values[0] = db.value_int(9)
	orphan_values[1] = db.value_int(77)
	orphan_values[2] = db.value_int(0)
	apply_err := db.store_apply(store, db.Store_Op{kind = .Insert, name = "child", row_id = 9, values = orphan_values})
	testing.expect(t, db.error_ok(apply_err), "the raw insert must apply")
	// A raw apply does not retire the cached read snapshot (only a commit
	// does), so a commit has to follow for the checker to see the row.
	run_done(t, store, "INSERT INTO parent (id, name) VALUES (3, 'three')")
	broken := run(t, store, "PRAGMA foreign_key_check")
	testing.expect_value(t, len(broken.rows), 1)
	testing.expect_value(t, broken.rows[0][0].s, "child")
	testing.expect_value(t, broken.rows[0][2].s, "parent")
	db.sql_result_destroy(&broken)
	report := run(t, store, "PRAGMA integrity_check")
	testing.expect_value(t, len(report.rows), 1)
	testing.expect(t, strings.contains(report.rows[0][0].s, "foreign key"), "the report must name the foreign key")
	db.sql_result_destroy(&report)

	// The latency histograms count the operations and bucket them.
	stats := run(t, store, "PRAGMA stats")
	metrics := make(map[string]i64)
	for row in stats.rows do metrics[row[0].s] = row[1].i
	testing.expect(t, metrics["commits"] > 0)
	testing.expect(t, metrics["queries"] > 0)
	commit_total: i64 = 0
	query_total: i64 = 0
	bound: i64 = 1
	for _ in 0 ..< db.LATENCY_BUCKETS {
		name := fmt.aprintf("commit_us_lt_%d", bound)
		commit_total += metrics[name]
		delete(name)
		name = fmt.aprintf("query_us_lt_%d", bound)
		query_total += metrics[name]
		delete(name)
		bound *= 2
	}
	testing.expect_value(t, commit_total, metrics["commits"])
	testing.expect_value(t, query_total, metrics["queries"])
	// The map borrows the strings the result rows own, so the keys must not be
	// freed here: sql_result_destroy frees them once.
	delete(metrics)
	db.sql_result_destroy(&stats)
	delete(orphan_values)

	// The same numbers are available in Odin, and the bucket boundaries are
	// powers of two.
	direct := db.store_latency_stats(store)
	testing.expect_value(t, direct.commits, u64(metrics["commits"]) + 0)
	testing.expect_value(t, db.latency_bucket(0), 0)
	testing.expect_value(t, db.latency_bucket(1), 0)
	testing.expect_value(t, db.latency_bucket(2), 1)
	testing.expect_value(t, db.latency_bucket(1024), 10)
	testing.expect_value(t, db.latency_bucket(1 << 40), db.LATENCY_BUCKETS - 1)
}

@(test)
test_errors_mid_scan_are_clean :: proc(t: ^testing.T) {
	// A statement that fails on a later row used to free the sources of the
	// earlier ones twice. The filter, the projection and the aggregate paths
	// must report the error and leave the store usable.
	store := fresh_db(t, "midscan")
	if store == nil do return
	defer cleanup_db(store, "midscan")
	run_done(t, store, "CREATE TABLE entry (id INTEGER PRIMARY KEY, amount INTEGER, memo TEXT)")
	run_done(t, store, "INSERT INTO entry VALUES (1, 1, NULL), (2, 2, 'x'), (3, 3, 'y')")

	// The first row passes the filter (NULL keeps the row out), the second
	// raises an error: 'x' is not JSON.
	filter_err := run_error(t, store, "SELECT amount FROM entry WHERE json(memo) IS NOT NULL")
	testing.expect(t, filter_err.kind != .None)
	aggregate_err := run_error(t, store, "SELECT count(*), sum(amount) FROM entry WHERE json(memo) IS NOT NULL")
	testing.expect(t, aggregate_err.kind != .None)
	// A projection error after a good row: the same double free lived there.
	// (upper(NULL) used to be the error here; it is NULL now, as in SQLite.)
	projection_err := run_error(t, store, "SELECT memo + 1 FROM entry")
	testing.expect_value(t, projection_err.kind, db.Error_Kind.Invalid_Type)
	// The store still answers and the rows are intact.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM entry").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT amount FROM entry WHERE id = 2").i, i64(2))

	// A PRAGMA written with its terminator is the same statement.
	version := run(t, store, "PRAGMA schema_version;")
	testing.expect_value(t, len(version.columns), 1)
	db.sql_result_destroy(&version)
	tables := run(t, store, "PRAGMA table_info(entry);")
	testing.expect_value(t, len(tables.rows), 3)
	db.sql_result_destroy(&tables)
}

@(test)
test_statement_stream_destroys_results :: proc(t: ^testing.T) {
	// Every result is destroyed here, which is what the CLI does and what the
	// rest of the suite (whose run() helper returns the result) never does.
	store := fresh_db(t, "soakown")
	if store == nil do return
	defer cleanup_db(store, "soakown")
	step_run :: proc(t: ^testing.T, store: ^db.Store, sql: string) {
		result, err := db.sql_execute(store, sql)
		testing.expectf(t, db.error_ok(err), "%s failed: %s", sql, err.message)
		db.sql_result_destroy(&result)
	}
	step_run(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY AUTOINCREMENT, level TEXT NOT NULL, message TEXT NOT NULL, amount INTEGER NOT NULL)")
	for round in 0 ..< 120 {
		for step in 0 ..< 10 {
			switch step % 4 {
			case 0:
				step_run(t, store, fmt.tprintf(
					"INSERT INTO s (level, message, amount) VALUES ('%s', 'line %d', %d)",
					round % 3 == 0 ? "info" : (round % 3 == 1 ? "warn" : "error"),
					round * 100 + step,
					round * 7 - step,
				))
			case 1:
				step_run(t, store, fmt.tprintf("UPDATE s SET amount = amount + %d WHERE id = %d", step, round * 3 + 1))
			case 2:
				step_run(t, store, fmt.tprintf("DELETE FROM s WHERE id = %d", round * 2 + step))
			case 3:
				step_run(t, store, "SELECT level, count(*), sum(amount) FROM s GROUP BY level")
				step_run(t, store, "SELECT id, message FROM s WHERE amount > 5 ORDER BY id DESC LIMIT 5")
			}
		}
	}
}

@(test)
test_soak_workload :: proc(t: ^testing.T) {
	// A long mixed workload in one process: the shapes a soak run repeats.
	// The test runner's tracking allocator turns a use-after-free into a report
	// with the allocating call site.
	store := fresh_db(t, "soak")
	if store == nil do return
	defer cleanup_db(store, "soak")
	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY AUTOINCREMENT, level TEXT NOT NULL, message TEXT NOT NULL, amount INTEGER NOT NULL)")
	for round in 0 ..< 40 {
		for step in 0 ..< 10 {
			switch step % 4 {
			case 0:
				run_done(t, store, fmt.tprintf(
					"INSERT INTO s (level, message, amount) VALUES ('%s', 'line %d', %d)",
					round % 3 == 0 ? "info" : (round % 3 == 1 ? "warn" : "error"),
					round * 100 + step,
					round * 7 - step,
				))
			case 1:
				run_done(t, store, fmt.tprintf("UPDATE s SET amount = amount + %d WHERE id = %d", step, round * 3 + 1))
			case 2:
				run_done(t, store, fmt.tprintf("DELETE FROM s WHERE id = %d", round * 2 + step))
			case 3:
				grouped := run(t, store, "SELECT level, count(*), sum(amount) FROM s GROUP BY level")
				db.sql_result_destroy(&grouped)
				ordered := run(t, store, "SELECT id, message FROM s WHERE amount > 5 ORDER BY id DESC LIMIT 5")
				db.sql_result_destroy(&ordered)
			}
		}
	}
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM s").i > 0, true)
	check := run(t, store, "PRAGMA integrity_check")
	testing.expect_value(t, check.rows[0][0].s, "ok")
	db.sql_result_destroy(&check)
}

@(test)
test_snapshot_shares_values_safely :: proc(t: ^testing.T) {
	// A snapshot borrows its rows from the table instead of copying them, so the
	// table must not free values that a reader can still see: an update keeps the
	// old values as a version, a delete tombstones the row, and a truncate hands
	// the rows to the shared store until the last reader is gone.
	store := fresh_db(t, "snapshot_share")
	if store == nil do return
	defer cleanup_db(store, "snapshot_share")

	run_done(t, store, "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO items (id, label) VALUES (1, 'one'), (2, 'two'), (3, 'three')")

	// A reader freezes the table while a writer updates and truncates it.
	reader := db.tx_begin_read(store)
	rows := make([dynamic]db.Row, 0, 8)
	defer delete(rows)
	testing.expect(t, db.error_ok(db.tx_collect(reader, "items", &rows)))
	testing.expect_value(t, len(rows), 3)

	writer := db.tx_begin_write(store)
	testing.expect(t, db.error_ok(db.tx_update(writer, "items", rows[0].id, []db.Value{db.value_int(1), db.value_string("ONE")})))
	testing.expect(t, db.error_ok(db.tx_commit(writer)))

	// The reader still sees the value it froze, even though the row was replaced.
	again := make([dynamic]db.Row, 0, 8)
	defer delete(again)
	testing.expect(t, db.error_ok(db.tx_collect(reader, "items", &again)))
	testing.expect_value(t, again[0].values[1].s, "one")
	db.tx_end(reader)

	// A truncate while a snapshot is alive defers the free; the snapshot keeps its
	// rows and the next reader sees the empty table.
	reader = db.tx_begin_read(store)
	frozen := make([dynamic]db.Row, 0, 8)
	defer delete(frozen)
	testing.expect(t, db.error_ok(db.tx_collect(reader, "items", &frozen)))
	testing.expect_value(t, len(frozen), 3)
	writer = db.tx_begin_write(store)
	testing.expect(t, db.error_ok(db.tx_truncate(writer, "items")))
	testing.expect(t, db.error_ok(db.tx_commit(writer)))
	after := make([dynamic]db.Row, 0, 8)
	defer delete(after)
	testing.expect(t, db.error_ok(db.tx_collect(reader, "items", &after)))
	testing.expect_value(t, len(after), 3)
	testing.expect_value(t, after[2].values[1].s, "three")
	db.tx_end(reader)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM items").i, i64(0))
}

@(test)
test_work_budget :: proc(t: ^testing.T) {
	// Metering charges rows read and rows written, not just requests: a reducer
	// that touches a million rows is aborted before it commits, and the store is
	// left exactly as it was.
	store := fresh_db(t, "budget")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "budget")

	run_done(t, store, "CREATE TABLE numbers (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "INSERT INTO numbers (id, value) VALUES ")
	for i in 1 ..= 200 {
		if i > 1 do strings.write_string(&builder, ", ")
		fmt.sbprintf(&builder, "(%d, %d)", i, i)
	}
	run_done(t, store, strings.to_string(builder))

	sweep :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		dropped_result_1652, err := db.sql_execute_in_tx(ctx.tx, "UPDATE numbers SET value = value + 1")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_1652)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(host, "sweep", nil, sweep)))

	// Without a budget the sweep runs and its cost is reported.
	testing.expect(t, db.error_ok(db.host_call_once(host, []u8{1}, "sweep", nil)))
	testing.expect_value(t, scalar(t, store, "SELECT max(value) FROM numbers").i, i64(201))
	spent := db.host_work_units_last(host)
	testing.expectf(t, spent >= 200, "expected at least 200 units, got %d", spent)

	// With a budget below the cost, the call is refused and nothing changes.
	db.host_set_work_budget(host, 50)
	refused := db.host_call_once(host, []u8{2}, "sweep", nil)
	defer db.error_free(&refused)
	testing.expect_value(t, refused.kind, db.Error_Kind.Quota_Exceeded)
	testing.expect_value(t, scalar(t, store, "SELECT max(value) FROM numbers").i, i64(201))
	// A call inside the budget still runs.
	db.host_set_work_budget(host, 10_000)
	testing.expect(t, db.error_ok(db.host_call_once(host, []u8{3}, "sweep", nil)))
	testing.expect_value(t, scalar(t, store, "SELECT max(value) FROM numbers").i, i64(202))
	// Zero removes the ceiling.
	db.host_set_work_budget(host, 0)
	testing.expect(t, db.error_ok(db.host_call_once(host, []u8{4}, "sweep", nil)))
	testing.expect_value(t, scalar(t, store, "SELECT max(value) FROM numbers").i, i64(203))
}

@(test)
test_durability_after_restart :: proc(t: ^testing.T) {
	// Two claims that were written down as gaps and turn out to be handled by the
	// commit log: an idempotent call is deduplicated across a restart because its
	// request id commits with the effects, and a scheduled reducer keeps its due
	// time because that time is a column of _schedule.
	path := fmt.aprintf("_test_%s", "durab")
	defer delete(path)
	defer os.remove_all(path)
	os.remove_all(path)

	bump :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		dropped_result_1691, err := db.sql_execute_in_tx(ctx.tx, "UPDATE counter SET value = value + 1 WHERE id = 0")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_1691)
		return err
	}

	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	host := db.host_init(store)
	run_done(t, store, "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO counter (id, value) VALUES (0, 0)")
	testing.expect(t, db.error_ok(db.host_register(host, "bump", nil, bump)))

	request := []u8{9, 9, 9}
	testing.expect(t, db.error_ok(db.host_call_once(host, request, "bump", nil)))
	testing.expect_value(t, scalar(t, store, "SELECT value FROM counter WHERE id = 0").i, i64(1))

	// A due time in the future survives the restart; nothing runs until it arrives.
	later, _ := db.host_schedule_in(host, "bump", 60_000_000, nil)
	testing.expect(t, later != 0)
	db.host_destroy(host)
	db.store_close(store)

	store, open_err = db.store_open(path, {persistent = true, create = true, durable = false})
	defer db.store_close(store)
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	host = db.host_init(store)
	defer db.host_destroy(host)
	testing.expect(t, db.error_ok(db.host_register(host, "bump", nil, bump)))

	// The retry of the call that already committed does nothing.
	testing.expect(t, db.error_ok(db.host_call_once(host, request, "bump", nil)))
	testing.expect_value(t, scalar(t, store, "SELECT value FROM counter WHERE id = 0").i, i64(1))

	// The schedule is still there, and it is still in the future.
	ran, tick_err := db.host_tick(host, 0)
	testing.expect(t, db.error_ok(tick_err))
	testing.expect_value(t, ran, 0)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _schedule").i, i64(1))
	// A tick past the due time runs it exactly once.
	future := scalar(t, store, "SELECT at_us FROM _schedule").i
	ran, tick_err = db.host_tick(host, future + 1)
	testing.expect(t, db.error_ok(tick_err))
	testing.expect_value(t, ran, 1)
	testing.expect_value(t, scalar(t, store, "SELECT value FROM counter WHERE id = 0").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _schedule").i, i64(0))
}

@(test)
test_idempotent_calls :: proc(t: ^testing.T) {
	store := fresh_db(t, "idempotent")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "idempotent")

	run_done(t, store, "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO counter (id, value) VALUES (0, 0)")

	incr :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		amount, _ := db.value_to_i64(args[0])
		statement := fmt.tprintf("UPDATE counter SET value = value + %d WHERE id = 0", amount)
		dropped_result_1751, err := db.sql_execute_in_tx(ctx.tx, statement)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_1751)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(host, "incr", []db.Column_Type{db.type_int}, incr)))

	request := []u8{1, 2, 3, 4}
	args := []db.Value{db.value_int(7)}
	testing.expect(t, db.error_ok(db.host_call_once(host, request, "incr", args)))
	// The same id must not run the reducer again.
	testing.expect(t, db.error_ok(db.host_call_once(host, request, "incr", args)))
	value := scalar(t, store, "SELECT value FROM counter WHERE id = 0")
	testing.expect_value(t, value.i, i64(7))

	// A different id runs normally.
	testing.expect(t, db.error_ok(db.host_call_once(host, []u8{5}, "incr", args)))
	value2 := scalar(t, store, "SELECT value FROM counter WHERE id = 0")
	testing.expect_value(t, value2.i, i64(14))

	// A failed call is not recorded, so a retry can succeed.
	fail :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		return db.Error{kind = .Invalid_Argument, message = "nope"}
	}
	testing.expect(t, db.error_ok(db.host_register(host, "fail", nil, fail)))
	testing.expect(t, !db.error_ok(db.host_call_once(host, []u8{9}, "fail", nil)))
	testing.expect(t, !db.error_ok(db.host_call_once(host, []u8{9}, "fail", nil))) // no crash: still absent
}

@(test)
test_integer_widths :: proc(t: ^testing.T) {
	store := fresh_db(t, "widths")
	if store == nil do return
	// Closed and reopened below, so the cleanup at the end closes the new store.

	run_done(t, store, `CREATE TABLE nums (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		a TINYINT NOT NULL,
		b SMALLINT NOT NULL,
		c INT4 NOT NULL,
		d UTINYINT NOT NULL,
		e FLOAT4 NOT NULL,
		f DOUBLE NOT NULL
	)`)

	run_done(t, store, "INSERT INTO nums (a, b, c, d, e, f) VALUES (-128, -32768, -2147483648, 255, 0.1, 0.1)")

	row := run(t, store, "SELECT a, b, c, d, e, f FROM nums")
	testing.expect_value(t, row.rows[0][0].i, i64(-128))
	testing.expect_value(t, row.rows[0][1].i, i64(-32768))
	testing.expect_value(t, row.rows[0][2].i, i64(-2147483648))
	testing.expect_value(t, row.rows[0][3].u, u64(255))
	// FLOAT4 rounds to single precision; DOUBLE keeps the double.
	testing.expect_value(t, row.rows[0][4].f, f64(f32(0.1)))
	testing.expect_value(t, row.rows[0][5].f, f64(0.1))
	db.sql_result_destroy(&row)

	out_of_range := []string{
		"INSERT INTO nums (a, b, c, d, e, f) VALUES (128, 0, 0, 0, 0, 0)",
		"INSERT INTO nums (a, b, c, d, e, f) VALUES (0, 32768, 0, 0, 0, 0)",
		"INSERT INTO nums (a, b, c, d, e, f) VALUES (0, 0, 2147483648, 0, 0, 0)",
		"INSERT INTO nums (a, b, c, d, e, f) VALUES (0, 0, 0, 256, 0, 0)",
		"INSERT INTO nums (a, b, c, d, e, f) VALUES (0, 0, 0, -1, 0, 0)",
	}
	for sql in out_of_range {
		err := run_error(t, store, sql)
		testing.expectf(t, err.kind == db.Error_Kind.Invalid_Type, "%q should be rejected", sql)
	}

	// Widths survive a reopen.
	db.store_close(store)
	reopened, open_err := db.store_open("_test_widths", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) {
		return
	}
	after := run(t, reopened, "SELECT a, d FROM nums")
	testing.expect_value(t, after.rows[0][0].i, i64(-128))
	db.sql_result_destroy(&after)
	cleanup_db(reopened, "widths")
}

@(test)
test_cast_to_narrow_types :: proc(t: ^testing.T) {
	store := fresh_db(t, "cast")
	if store == nil do return
	defer cleanup_db(store, "cast")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, a TINYINT NOT NULL)")
	run_done(t, store, "INSERT INTO t (a) VALUES (CAST(100 AS TINYINT))")
	value := scalar(t, store, "SELECT a FROM t")
	testing.expect_value(t, value.i, i64(100))

	err := run_error(t, store, "INSERT INTO t (a) VALUES (CAST(1000 AS TINYINT))")
	testing.expect_value(t, err.kind, db.Error_Kind.Invalid_Type)
}

@(test)
test_composite_primary_key :: proc(t: ^testing.T) {
	store := fresh_db(t, "composite")
	if store == nil do return

	run_done(t, store, `CREATE TABLE kv (
		a INT4 NOT NULL,
		b TEXT NOT NULL,
		value TEXT NOT NULL,
		PRIMARY KEY (a, b)
	)`)
	run_done(t, store, "INSERT INTO kv (a, b, value) VALUES (1, 'x', 'one-x'), (1, 'y', 'one-y'), (2, 'x', 'two-x')")

	duplicate := run_error(t, store, "INSERT INTO kv (a, b, value) VALUES (1, 'x', 'again')")
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Primary_Key)

	count := scalar(t, store, "SELECT count(*) FROM kv")
	testing.expect_value(t, count.i, i64(3))

	row := run(t, store, "SELECT value FROM kv WHERE a = 1 AND b = 'y'")
	testing.expect_value(t, len(row.rows), 1)
	testing.expect_value(t, row.rows[0][0].s, "one-y")
	db.sql_result_destroy(&row)

	// AUTOINCREMENT needs the whole primary key to be one integer column.
	bad := run_error(t, store, `CREATE TABLE bad (
		a INT PRIMARY KEY AUTOINCREMENT,
		b TEXT,
		PRIMARY KEY (a, b)
	)`)
	testing.expect(t, bad.kind != .None)

	// The key survives a reopen.
	db.store_close(store)
	reopened, open_err := db.store_open("_test_composite", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) {
		return
	}
	after := scalar(t, reopened, "SELECT count(*) FROM kv")
	testing.expect_value(t, after.i, i64(3))
	cleanup_db(reopened, "composite")
}

@(test)
test_named_unique_constraints :: proc(t: ^testing.T) {
	store := fresh_db(t, "namedunique")
	if store == nil do return
	defer cleanup_db(store, "namedunique")

	run_done(t, store, `CREATE TABLE pair (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		x INT NOT NULL,
		y INT NOT NULL,
		CONSTRAINT pair_xy UNIQUE (x, y)
	)`)
	run_done(t, store, "INSERT INTO pair (x, y) VALUES (1, 2)")

	duplicate := run_error(t, store, "INSERT INTO pair (x, y) VALUES (1, 2)")
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Unique)
	run_done(t, store, "INSERT INTO pair (x, y) VALUES (1, 3)")

	// A constraint index is a normal index and can be dropped explicitly.
	drop := run_error(t, store, "DROP INDEX pair_xy")
	testing.expect_value(t, drop.kind, db.Error_Kind.None)
	run_done(t, store, "INSERT INTO pair (x, y) VALUES (1, 2)")
}

@(test)
test_128_bit_integers :: proc(t: ^testing.T) {
	store := fresh_db(t, "int128")
	if store == nil do return

	run_done(t, store, "CREATE TABLE big (id INTEGER PRIMARY KEY AUTOINCREMENT, a INT128 NOT NULL, b UINT128 NOT NULL)")
	max_i := i128(170141183460469231731687303715884105727)
	min_i := i128(-170141183460469231731687303715884105728)
	max_u := u128(340282366920938463463374607431768211455)

	run_done(t, store, "INSERT INTO big (a, b) VALUES (170141183460469231731687303715884105727, 340282366920938463463374607431768211455), (-170141183460469231731687303715884105728, 0)")

	row := run(t, store, "SELECT a, b FROM big ORDER BY a")
	testing.expect_value(t, row.rows[0][0].kind, db.Value_Kind.Int128)
	testing.expect_value(t, db.value_as_i128(row.rows[0][0]), min_i)
	testing.expect_value(t, db.value_as_i128(row.rows[1][0]), max_i)
	testing.expect_value(t, db.value_as_u128(row.rows[1][1]), max_u)
	db.sql_result_destroy(&row)

	// A u128 above max(i128) does not fit INT128.
	overflow := run_error(t, store, "INSERT INTO big (a, b) VALUES (340282366920938463463374607431768211455, 0)")
	testing.expect_value(t, overflow.kind, db.Error_Kind.Invalid_Type)

	// Arithmetic stays in 128 bits.
	sum := scalar(t, store, "SELECT sum(a) FROM big")
	testing.expect_value(t, sum.kind, db.Value_Kind.Int128)
	testing.expect_value(t, db.value_as_i128(sum), i128(-1))

	plus := scalar(t, store, "SELECT a + 1 FROM big WHERE a < 0")
	testing.expect_value(t, db.value_as_i128(plus), min_i + 1)

	// The index encodes and orders 128-bit keys.
	run_done(t, store, "CREATE INDEX big_a ON big (a)")
	positive := scalar(t, store, "SELECT count(*) FROM big WHERE a > 0")
	testing.expect_value(t, positive.i, i64(1))
	negative := scalar(t, store, "SELECT count(*) FROM big WHERE a < 0")
	testing.expect_value(t, negative.i, i64(1))

	db.store_close(store)
	reopened, open_err := db.store_open("_test_int128", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) {
		return
	}
	after := scalar(t, reopened, "SELECT a FROM big ORDER BY a LIMIT 1")
	testing.expect_value(t, db.value_as_i128(after), min_i)
	cleanup_db(reopened, "int128")
}

@(test)
test_domain_types :: proc(t: ^testing.T) {
	store := fresh_db(t, "domains")
	if store == nil do return

	run_done(t, store, `CREATE TABLE dom (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		d DURATION NOT NULL,
		who IDENTITY NOT NULL,
		conn CONNECTION NOT NULL
	)`)
	identity_text := "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
	insert := fmt.tprintf("INSERT INTO dom (d, who, conn) VALUES (1500000, '%s', 42)", identity_text)
	run_done(t, store, insert)

	row := run(t, store, "SELECT d, who, conn FROM dom")
	testing.expect_value(t, row.rows[0][0].kind, db.Value_Kind.Duration)
	testing.expect_value(t, row.rows[0][0].i, i64(1500000))
	testing.expect_value(t, row.rows[0][1].kind, db.Value_Kind.Identity)
	testing.expect_value(t, db.value_format(row.rows[0][1], context.temp_allocator), identity_text)
	testing.expect_value(t, row.rows[0][2].kind, db.Value_Kind.Connection)
	testing.expect_value(t, row.rows[0][2].u, u64(42))
	db.sql_result_destroy(&row)

	// A 32-byte blob and a negative duration are accepted.
	blob := "x'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100'"
	run_done(t, store, fmt.tprintf("INSERT INTO dom (d, who, conn) VALUES (-5, %s, 0)", blob))

	// Anything else is rejected.
	bad_identity := run_error(t, store, "INSERT INTO dom (d, who, conn) VALUES (0, 'abcd', 0)")
	testing.expect_value(t, bad_identity.kind, db.Error_Kind.Invalid_Type)

	// Durations order and aggregate numerically.
	positive := scalar(t, store, "SELECT count(*) FROM dom WHERE d > 0")
	testing.expect_value(t, positive.i, i64(1))
	total := scalar(t, store, "SELECT sum(d) FROM dom")
	testing.expect_value(t, total.i, i64(1499995))

	db.store_close(store)
	reopened, open_err := db.store_open("_test_domains", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) {
		return
	}
	after := scalar(t, reopened, "SELECT count(*) FROM dom WHERE d > 0")
	testing.expect_value(t, after.i, i64(1))
	cleanup_db(reopened, "domains")
}

@(test)
test_sequences :: proc(t: ^testing.T) {
	store := fresh_db(t, "sequences")
	if store == nil do return

	run_done(t, store, `CREATE TABLE seq (
		id INTEGER PRIMARY KEY AUTOINCREMENT START 100 INCREMENT 5,
		v TEXT NOT NULL
	)`)
	run_done(t, store, "INSERT INTO seq (v) VALUES ('a'), ('b')")

	rows := run(t, store, "SELECT id FROM seq ORDER BY id")
	testing.expect_value(t, rows.rows[0][0].i, i64(100))
	testing.expect_value(t, rows.rows[1][0].i, i64(105))
	db.sql_result_destroy(&rows)

	// An explicit value moves the sequence past it.
	run_done(t, store, "INSERT INTO seq (id, v) VALUES (200, 'c')")
	run_done(t, store, "INSERT INTO seq (v) VALUES ('d')")
	next := scalar(t, store, "SELECT id FROM seq WHERE v = 'd'")
	testing.expect_value(t, next.i, i64(205))

	db.store_close(store)
	reopened, open_err := db.store_open("_test_sequences", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) {
		return
	}
	run_done(t, reopened, "INSERT INTO seq (v) VALUES ('e')")
	after := scalar(t, reopened, "SELECT id FROM seq WHERE v = 'e'")
	testing.expect_value(t, after.i, i64(210))

	// Bounds are enforced.
	run_done(t, reopened, `CREATE TABLE bounded (
		id INTEGER PRIMARY KEY AUTOINCREMENT START 1 INCREMENT 1 MAXVALUE 2,
		v TEXT NOT NULL
	)`)
	run_done(t, reopened, "INSERT INTO bounded (v) VALUES ('a'), ('b')")
	exhausted := run_error(t, reopened, "INSERT INTO bounded (v) VALUES ('c')")
	testing.expect(t, exhausted.kind != .None)

	// A zero increment is rejected at CREATE TABLE.
	bad := run_error(t, reopened, `CREATE TABLE bad_seq (
		id INTEGER PRIMARY KEY AUTOINCREMENT START 1 INCREMENT 0,
		v TEXT
	)`)
	testing.expect_value(t, bad.kind, db.Error_Kind.Invalid_Argument)
	cleanup_db(reopened, "sequences")
}

@(test)
test_indexed_dml_and_offsets :: proc(t: ^testing.T) {
	store := fresh_db(t, "indexeddml")
	if store == nil do return
	defer cleanup_db(store, "indexeddml")

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY AUTOINCREMENT, score INTEGER NOT NULL, tag TEXT NOT NULL)")
	for value in ([]int{30, 10, 20, 40, 5}) {
		run_done(t, store, fmt.tprintf("INSERT INTO item (score, tag) VALUES (%d, 'v')", value))
	}
	run_done(t, store, "CREATE INDEX item_score ON item (score)")

	insert_result := run(t, store, fmt.tprintf("INSERT INTO item (score, tag) VALUES (7, 'v')"))
	testing.expect(t, insert_result.commit_seq > 0)
	sequence := insert_result.commit_seq
	db.sql_result_destroy(&insert_result)

	update := run(t, store, "UPDATE item SET tag = 'high' WHERE score >= 30")
	testing.expect_value(t, update.affected, 2)
	testing.expect(t, update.commit_seq > sequence)
	db.sql_result_destroy(&update)

	remove := run(t, store, "DELETE FROM item WHERE score < 10")
	testing.expect_value(t, remove.affected, 2) // 5 and 7
	db.sql_result_destroy(&remove)

	// Inside a transaction with staged writes the index cannot see the new row,
	// so the fallback scan must still find and update it.
	tx := db.tx_begin_write(store)
	dropped_result_2086, insert_err := db.sql_execute_in_tx(tx, "INSERT INTO item (score, tag) VALUES (3, 'v')")
	defer db.error_free(&insert_err)
	defer db.sql_result_destroy(&dropped_result_2086)
	testing.expect(t, db.error_ok(insert_err))
	updated, update_err := db.sql_execute_in_tx(tx, "UPDATE item SET tag = 'new' WHERE score = 3")
	testing.expect(t, db.error_ok(update_err))
	testing.expect_value(t, updated.affected, 1)
	db.sql_result_destroy(&updated)
	fmt.eprintln("marker: before commit")
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	fmt.println("marker: after commit")

	count := scalar(t, store, "SELECT count(*) FROM item")
	testing.expect_value(t, count.i, i64(5))
	again := scalar(t, store, "SELECT count(*) FROM item WHERE tag = 'new'")
	testing.expect_value(t, again.i, i64(1))
}

@(test)
test_like_escape :: proc(t: ^testing.T) {
	store := fresh_db(t, "likeescape")
	if store == nil do return
	defer cleanup_db(store, "likeescape")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, s TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO t (s) VALUES ('a%b'), ('axb'), ('a_b'), ('a.b'), ('50%'), ('100')")

	cases := []struct {
		sql:   string,
		count: i64,
	}{
		{`SELECT count(*) FROM t WHERE s LIKE 'a\%b' ESCAPE '\'`, 1},
		{`SELECT count(*) FROM t WHERE s LIKE 'a\_b' ESCAPE '\'`, 1},
		{"SELECT count(*) FROM t WHERE s LIKE 'a_b'", 4},
		{"SELECT count(*) FROM t WHERE s LIKE 'a.b'", 1},
		{"SELECT count(*) FROM t WHERE s ILIKE '50%'", 1},
		{"SELECT count(*) FROM t WHERE s NOT LIKE '%x%'", 5},
	}
	for test_case in cases {
		result := run(t, store, test_case.sql)
		testing.expectf(t, result.rows[0][0].i == test_case.count, "%s returned %v", test_case.sql, result.rows[0][0].i)
		db.sql_result_destroy(&result)
	}

	bad_escape := run_error(t, store, `SELECT * FROM t WHERE s LIKE 'a' ESCAPE 'xx'`)
	testing.expect_value(t, bad_escape.kind, db.Error_Kind.Sql_Syntax)
}

@(test)
test_set_and_show :: proc(t: ^testing.T) {
	store := fresh_db(t, "setshow")
	if store == nil do return
	defer cleanup_db(store, "setshow")

	setting := run(t, store, "SET app = 'demo'")
	db.sql_result_destroy(&setting)

	shown := run(t, store, "SHOW app")
	if testing.expect(t, len(shown.rows) == 1) {
		testing.expect_value(t, shown.rows[0][0].s, "app")
		testing.expect_value(t, shown.rows[0][1].s, "demo")
	}
	db.sql_result_destroy(&shown)

	run_done(t, store, "SET n = 1 + 2")
	number := run(t, store, "SHOW n")
	testing.expect_value(t, number.rows[0][1].i, i64(3))
	db.sql_result_destroy(&number)

	all := run(t, store, "SHOW")
	testing.expect(t, len(all.rows) >= 2)
	db.sql_result_destroy(&all)

	missing := run_error(t, store, "SHOW nope")
	testing.expect_value(t, missing.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_explain :: proc(t: ^testing.T) {
	store := fresh_db(t, "explain")
	if store == nil do return
	defer cleanup_db(store, "explain")

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY AUTOINCREMENT, score INTEGER NOT NULL, tag TEXT NOT NULL)")
	run_done(t, store, "CREATE INDEX item_score ON item (score)")

	by_key := run(t, store, "EXPLAIN SELECT * FROM item WHERE id = 1")
	testing.expect(t, len(by_key.rows) >= 1)
	testing.expect(t, strings_contains(by_key.rows[0][0].s, "using index item_pkey"))
	db.sql_result_destroy(&by_key)

	by_range := run(t, store, "EXPLAIN SELECT * FROM item WHERE score > 10")
	testing.expect(t, strings_contains(by_range.rows[0][0].s, "using index item_score"))
	db.sql_result_destroy(&by_range)

	plain := run(t, store, "EXPLAIN SELECT * FROM item")
	testing.expect(t, strings_contains(plain.rows[0][0].s, "full scan"))
	db.sql_result_destroy(&plain)

	update := run(t, store, "EXPLAIN UPDATE item SET tag = 'x' WHERE score = 1")
	testing.expect(t, strings_contains(update.rows[0][0].s, "update item"))
	testing.expect(t, strings_contains(update.rows[0][0].s, "item_score"))
	db.sql_result_destroy(&update)
}

@(private)
strings_contains :: proc(haystack, needle: string) -> bool {
	return len(needle) == 0 || strings_contains_index(haystack, needle) >= 0
}

@(private)
strings_contains_index :: proc(haystack, needle: string) -> int {
	if len(needle) > len(haystack) do return -1
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle do return i
	}
	return -1
}

@(test)
test_snapshot_restore :: proc(t: ^testing.T) {
	path := "_test_snapshot"
	os.remove_all(path)
	defer os.remove_all(path)

	store, err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "open failed: %s", err.message) do return
	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY AUTOINCREMENT, score INTEGER NOT NULL)")
	run_done(t, store, "CREATE INDEX item_score ON item (score)")
	run_done(t, store, "INSERT INTO item (score) VALUES (10), (20)")
	testing.expect(t, db.error_ok(db.store_snapshot(store)))
	// This record lands after the snapshot and must be replayed on top of it.
	run_done(t, store, "INSERT INTO item (score) VALUES (30)")
	db.store_close(store)

	store, err = db.store_open(path, {persistent = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "reopen failed: %s", err.message) do return
	count := scalar(t, store, "SELECT count(*) FROM item")
	testing.expect_value(t, count.i, i64(3))
	testing.expect_value(t, store.commit_seq, u64(4)) // table, index and the two inserts
	by_index := scalar(t, store, "SELECT count(*) FROM item WHERE score >= 20")
	testing.expect_value(t, by_index.i, i64(2))
	plan := run(t, store, "EXPLAIN SELECT * FROM item WHERE score = 20")
	testing.expect(t, strings_contains(plan.rows[0][0].s, "item_score"))
	db.sql_result_destroy(&plan)

	// A checkpoint must keep the same state and let new commits continue.
	testing.expect(t, db.error_ok(db.store_compact(store)))
	db.store_close(store)

	store, err = db.store_open(path, {persistent = true, durable = false})
	defer db.store_close(store)
	if !testing.expectf(t, db.error_ok(err), "reopen after compact failed: %s", err.message) do return
	testing.expect_value(t, store.commit_seq, u64(4))
	run_done(t, store, "INSERT INTO item (score) VALUES (40)")
	testing.expect_value(t, store.commit_seq, u64(5))
	ids := run(t, store, "SELECT id FROM item ORDER BY id")
	testing.expect_value(t, len(ids.rows), 4)
	testing.expect_value(t, ids.rows[3][0].i, i64(4))
	db.sql_result_destroy(&ids)
}

@(test)
test_table_memory :: proc(t: ^testing.T) {
	store := fresh_db(t, "memory")
	if store == nil do return
	defer cleanup_db(store, "memory")

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score INTEGER NOT NULL)")
	run_done(t, store, "CREATE INDEX item_score ON item (score)")
	run_done(t, store, "INSERT INTO item (name, score) VALUES ('ana', 10), ('luis', 20)")

	memory, err := db.store_table_memory(store, "item")
	testing.expect(t, db.error_ok(err))
	testing.expect_value(t, memory.rows, 2)
	testing.expect(t, memory.row_bytes > 0)
	testing.expect(t, memory.index_entries >= 4) // primary key plus item_score, two rows each
	testing.expect(t, memory.index_bytes > 0)

	_, missing := db.store_table_memory(store, "nope")
	defer db.error_free(&missing)
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)
}

@(test)
test_views :: proc(t: ^testing.T) {
	store := fresh_db(t, "views")
	if store == nil do return
	defer cleanup_db(store, "views")

	run_done(t, store, "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO users (name, score) VALUES ('ana', 20), ('luis', 12), ('eva', 30)")
	run_done(t, store, "CREATE VIEW adults AS SELECT id, name, score FROM users WHERE score >= 18")

	rows := run(t, store, "SELECT name FROM adults ORDER BY name")
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect_value(t, rows.rows[0][0].s, "ana")
	testing.expect_value(t, rows.rows[1][0].s, "eva")
	db.sql_result_destroy(&rows)

	filtered := scalar(t, store, "SELECT count(*) FROM adults WHERE score > 25")
	testing.expect_value(t, filtered.i, i64(1))

	run_done(t, store, "CREATE TABLE teams (user_id INTEGER NOT NULL, team TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO teams (user_id, team) VALUES (1, 'red'), (3, 'blue')")
	run_done(t, store, "CREATE VIEW adult_teams AS SELECT a.name AS player, t.team AS team FROM adults a JOIN teams t ON a.id = t.user_id")
	joined := run(t, store, "SELECT player, team FROM adult_teams ORDER BY player")
	testing.expect_value(t, len(joined.rows), 2)
	testing.expect_value(t, joined.rows[0][0].s, "ana")
	testing.expect_value(t, joined.rows[0][1].s, "red")
	testing.expect_value(t, joined.rows[1][0].s, "eva")
	testing.expect_value(t, joined.rows[1][1].s, "blue")
	db.sql_result_destroy(&joined)

	run_done(t, store, "CREATE VIEW IF NOT EXISTS adults AS SELECT 1 FROM users")
	duplicate := run_error(t, store, "CREATE VIEW adults AS SELECT 1 FROM users")
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Table_Exists)

	run_done(t, store, "CREATE VIEW loop AS SELECT * FROM loop")
	recursive := run_error(t, store, "SELECT * FROM loop")
	testing.expect_value(t, recursive.kind, db.Error_Kind.Sql_Unsupported)

	run_done(t, store, "DROP VIEW IF EXISTS loop")
	missing := run_error(t, store, "DROP VIEW loop")
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)
	gone := run_error(t, store, "SELECT * FROM loop")
	testing.expect_value(t, gone.kind, db.Error_Kind.Table_Not_Found)
}

@(test)
test_view_persistence :: proc(t: ^testing.T) {
	path := "_test_viewpersist"
	os.remove_all(path)
	defer os.remove_all(path)

	store, err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "open failed: %s", err.message) do return
	run_done(t, store, "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO users (name) VALUES ('ana'), ('luis')")
	run_done(t, store, "CREATE VIEW everyone AS SELECT id, name FROM users")
	db.store_close(store)

	store, err = db.store_open(path, {persistent = true, durable = false})
	defer db.store_close(store)
	if !testing.expectf(t, db.error_ok(err), "reopen failed: %s", err.message) do return
	rows := run(t, store, "SELECT name FROM everyone ORDER BY id")
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect_value(t, rows.rows[1][0].s, "luis")
	db.sql_result_destroy(&rows)
}

@(test)
test_schedule_interval :: proc(t: ^testing.T) {
	store := fresh_db(t, "interval")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "interval")

	run_done(t, store, "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO counter (id, value) VALUES (0, 0)")

	bump :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		amount, _ := db.value_to_i64(args[0])
		statement := fmt.tprintf("UPDATE counter SET value = value + %d WHERE id = 0", amount)
		dropped_result_2349, err := db.sql_execute_in_tx(ctx.tx, statement)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_2349)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(host, "bump", []db.Column_Type{db.type_int}, bump)))

	now := i64(1_700_000_000_000_000)
	host.now_us = now
	_, schedule_err := db.host_schedule_every(host, "bump", 1_000_000, []db.Value{db.value_int(2)})
	testing.expectf(t, db.error_ok(schedule_err), "schedule: %s", schedule_err.message)
	_, bad_interval := db.host_schedule_every(host, "bump", 0, nil)
	defer db.error_free(&bad_interval)
	testing.expect_value(t, bad_interval.kind, db.Error_Kind.Invalid_Argument)

	ran, tick_err := db.host_tick(host, now)
	testing.expect(t, db.error_ok(tick_err))
	testing.expect_value(t, ran, 0)

	ran, tick_err = db.host_tick(host, now + 1_000_000)
	testing.expect(t, db.error_ok(tick_err))
	testing.expect_value(t, ran, 1)
	value := scalar(t, store, "SELECT value FROM counter WHERE id = 0")
	testing.expect_value(t, value.i, i64(2))

	// Not due until the next interval.
	ran, _ = db.host_tick(host, now + 1_500_000)
	testing.expect_value(t, ran, 0)
	ran, _ = db.host_tick(host, now + 2_000_000)
	testing.expect_value(t, ran, 1)

	// A late tick runs once and skips the missed occurrences.
	ran, _ = db.host_tick(host, now + 10_000_000)
	testing.expect_value(t, ran, 1)
	at := scalar(t, store, "SELECT at_us FROM _schedule")
	testing.expect(t, at.i > now + 10_000_000)
	pending := scalar(t, store, "SELECT count(*) FROM _schedule")
	testing.expect_value(t, pending.i, i64(1))

	// Immediate schedules run on the next tick.
	_, now_err := db.host_schedule_now(host, "bump", []db.Value{db.value_int(100)})
	testing.expect(t, db.error_ok(now_err))
	ran, _ = db.host_tick(host, now + 10_000_000)
	testing.expect_value(t, ran, 1)
	value = scalar(t, store, "SELECT value FROM counter WHERE id = 0")
	testing.expect_value(t, value.i, i64(106)) // three interval runs plus the immediate one
}

@(test)
test_schedule_migration :: proc(t: ^testing.T) {
	store := fresh_db(t, "schedmigrate")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "schedmigrate")

	// The internal schema as written before intervals existed.
	run_done(t, store, "CREATE TABLE _schedule (id INTEGER PRIMARY KEY AUTOINCREMENT, reducer TEXT NOT NULL, at_us INTEGER NOT NULL, args BLOB NOT NULL)")
	run_done(t, store, "INSERT INTO _schedule (reducer, at_us, args) VALUES ('noop', 0, x'00')")

	noop :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		return {}
	}
	testing.expect(t, db.error_ok(db.host_register(host, "noop", nil, noop)))
	host.now_us = i64(1_700_000_000_000_000)
	_, schedule_err := db.host_schedule_now(host, "noop", nil)
	testing.expectf(t, db.error_ok(schedule_err), "schedule after migration: %s", schedule_err.message)

	// The upgrade rebuilt the table, so only the new row remains.
	pending := scalar(t, store, "SELECT count(*) FROM _schedule")
	testing.expect_value(t, pending.i, i64(1))
	ran, tick_err := db.host_tick(host, host.now_us)
	testing.expect(t, db.error_ok(tick_err))
	testing.expect_value(t, ran, 1)
}

@(test)
test_policies :: proc(t: ^testing.T) {
	store := fresh_db(t, "policies")
	if store == nil do return
	defer cleanup_db(store, "policies")

	ana := "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
	luis := "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"

	run_done(t, store, "CREATE TABLE note (id INTEGER PRIMARY KEY AUTOINCREMENT, owner IDENTITY NOT NULL, body TEXT NOT NULL)")
	insert := fmt.tprintf(
		"INSERT INTO note (owner, body) VALUES ('%s', 'a1'), ('%s', 'a2'), ('%s', 'l1')",
		ana,
		ana,
		luis,
	)
	run_done(t, store, insert)
	run_done(t, store, "CREATE POLICY note_owner ON note USING (owner = current_identity())")

	run_done(t, store, fmt.tprintf("SET identity = '%s'", ana))
	visible := scalar(t, store, "SELECT count(*) FROM note")
	testing.expect_value(t, visible.i, i64(2))

	// Rows outside the policy are invisible to DML as well.
	invisible := run(t, store, "UPDATE note SET body = 'x' WHERE body = 'l1'")
	testing.expect_value(t, invisible.affected, 0)
	db.sql_result_destroy(&invisible)

	// A CHECK policy rejects writes the caller may not make.
	run_done(t, store, "CREATE POLICY note_check ON note CHECK (owner = current_identity())")
	bad := run_error(t, store, fmt.tprintf("INSERT INTO note (owner, body) VALUES ('%s', 'bad')", luis))
	testing.expect_value(t, bad.kind, db.Error_Kind.Permission_Denied)
	run_done(t, store, fmt.tprintf("INSERT INTO note (owner, body) VALUES ('%s', 'ok')", ana))
	denied := run_error(t, store, fmt.tprintf("UPDATE note SET owner = '%s' WHERE body = 'a1'", luis))
	testing.expect_value(t, denied.kind, db.Error_Kind.Permission_Denied)

	// Without the CHECK policy the same UPDATE is allowed and moves the row out
	// of the original owner's view.
	run_done(t, store, "DROP POLICY note_check")
	moved := run(t, store, fmt.tprintf("UPDATE note SET owner = '%s' WHERE body = 'a1'", luis))
	testing.expect_value(t, moved.affected, 1)
	db.sql_result_destroy(&moved)

	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM note").i, i64(2))
	run_done(t, store, fmt.tprintf("SET identity = '%s'", luis))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM note").i, i64(2))

	shown := run(t, store, "SHOW identity")
	testing.expect_value(t, shown.rows[0][1].kind, db.Value_Kind.Identity)
	db.sql_result_destroy(&shown)

	run_done(t, store, "DROP POLICY note_owner")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM note").i, i64(4))

	bad_identity := run_error(t, store, "SET identity = 'not-hex'")
	testing.expect_value(t, bad_identity.kind, db.Error_Kind.Invalid_Type)
}

@(test)
test_durability_modes :: proc(t: ^testing.T) {
	path := "_test_durability"
	os.remove_all(path)
	defer os.remove_all(path)

	store, err := db.store_open(path, {persistent = true, create = true, durable = true, durability = .Batched})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	testing.expect_value(t, store.log.durability, db.Durability.Batched)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (1), (2), (3)")
	db.store_close(store)

	store, err = db.store_open(path, {persistent = true, durable = true, durability = .None})
	if !testing.expectf(t, db.error_ok(err), "reopen: %s", err.message) do return
	testing.expect_value(t, store.log.durability, db.Durability.None)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
	db.store_close(store)

	// durable = false maps to None even when the mode is left at its default.
	store, err = db.store_open(path, {persistent = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "reopen none: %s", err.message) do return
	testing.expect_value(t, store.log.durability, db.Durability.None)
	db.store_close(store)
}

@(test)
test_log_offset_index :: proc(t: ^testing.T) {
	path := "_test_logindex"
	os.remove_all(path)
	defer os.remove_all(path)

	store, err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (1), (2), (3)")
	db.store_close(store)

	index_path := fmt.aprintf("%s/log.index", path)
	defer delete(index_path)
	info, stat_err := os.stat(index_path, context.temp_allocator)
	testing.expectf(t, stat_err == nil, "sidecar missing: %v", stat_err)
	if stat_err == nil {
		// Header plus one entry per commit (table, two inserts).
		testing.expect(t, info.size > 16)
	}

	// Reopen, snapshot and reopen again: the index must agree with the log and
	// the data must survive both the snapshot boundary and a tail rewind.
	store, err = db.store_open(path, {persistent = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "reopen: %s", err.message) do return
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
	testing.expect(t, db.error_ok(db.store_snapshot(store)))
	run_done(t, store, "INSERT INTO t (v) VALUES (4)")
	db.store_close(store)

	store, err = db.store_open(path, {persistent = true, durable = false})
	defer db.store_close(store)
	if !testing.expectf(t, db.error_ok(err), "reopen after snapshot: %s", err.message) do return
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(4))
	testing.expect(t, db.error_ok(db.store_compact(store)))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(4))
}

@(test)
test_log_index_kept_open_matches_the_log :: proc(t: ^testing.T) {
	// The log keeps its sidecar open across commits (D35). After a rewind the
	// sidecar is cut through another handle, so the kept one must not write past
	// the cut: the file holds exactly one entry per record the log keeps, in
	// order, with no hole of zeros.
	path :: "_test_logindex_open"
	os.remove_all(path)
	defer os.remove_all(path)
	testing.expect(t, os.make_directory(path) == nil)
	log, open_err := db.log_open(path, true, .None, .CRC32C)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	offsets: [dynamic]i64
	defer delete(offsets)
	payload := []u8{1, 2, 3, 4}
	for seq in 1 ..= 3 {
		append(&offsets, log.size)
		testing.expect(t, db.error_drop(db.log_append(&log, u64(seq), payload)))
	}
	// The third record is taken back, as a commit that failed to apply is.
	testing.expect(t, db.error_drop(db.log_rewind(&log, offsets[2])))
	pop(&offsets)
	for seq in 3 ..= 4 {
		append(&offsets, log.size)
		testing.expect(t, db.error_drop(db.log_append(&log, u64(seq), payload)))
	}
	db.log_close(&log)

	data, read_err := os.read_entire_file(path + "/log.index", context.temp_allocator)
	if !testing.expectf(t, read_err == nil, "sidecar: %v", read_err) do return
	testing.expect_value(t, len(data), db.LOG_INDEX_HEADER_LEN + 4 * db.LOG_INDEX_ENTRY_LEN)
	for i in 0 ..< min(4, (len(data) - db.LOG_INDEX_HEADER_LEN) / db.LOG_INDEX_ENTRY_LEN) {
		at := db.LOG_INDEX_HEADER_LEN + i * db.LOG_INDEX_ENTRY_LEN
		seq := u64(data[at]) | u64(data[at + 1]) << 8 | u64(data[at + 2]) << 16 | u64(data[at + 3]) << 24
		offset := i64(data[at + 8]) | i64(data[at + 9]) << 8 | i64(data[at + 10]) << 16 | i64(data[at + 11]) << 24
		testing.expect_value(t, seq, u64(i + 1))
		testing.expect_value(t, offset, offsets[i])
	}

	// A reopened log appends after what is there, through a fresh handle.
	log, open_err = db.log_open(path, false, .None, .CRC32C)
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	testing.expect(t, db.error_drop(db.log_append(&log, 5, payload)))
	db.log_close(&log)
	again, again_err := os.read_entire_file(path + "/log.index", context.temp_allocator)
	testing.expect(t, again_err == nil)
	testing.expect_value(t, len(again), db.LOG_INDEX_HEADER_LEN + 5 * db.LOG_INDEX_ENTRY_LEN)
}

@(test)
test_in_memory_log :: proc(t: ^testing.T) {
	store, err := db.store_open("", {in_memory_log = true})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (1), (2), (3)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
	testing.expect(t, store.log.memory_mode)
	testing.expect(t, store.log.size > i64(db.LOG_HEADER_LEN))

	// The commit path is exercised, but there is nothing on disk to compact or
	// snapshot.
	compact := db.store_compact(store)
	defer db.error_free(&compact)
	testing.expect_value(t, compact.kind, db.Error_Kind.Invalid_Argument)
	snapshot := db.store_snapshot(store)
	defer db.error_free(&snapshot)
	testing.expect_value(t, snapshot.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_log_segments :: proc(t: ^testing.T) {
	path := "_test_segments"
	os.remove_all(path)
	defer os.remove_all(path)

	store, err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	run_done(t, store, "CREATE TABLE doc (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL)")
	// About 410 KB of records rotate the 256 KiB segment at least once.
	filler := make([]u8, 1000)
	defer delete(filler)
	for i in 0 ..< len(filler) do filler[i] = u8('a' + (i % 26))
	for _ in 0 ..< 400 {
		run_done(t, store, fmt.tprintf("INSERT INTO doc (body) VALUES ('%s')", string(filler)))
	}
	second := fmt.aprintf("%s/log.1", path)
	testing.expectf(t, os.exists(second), "the log did not rotate")
	delete(second)
	db.store_close(store)

	// Reopen: records from every segment replay in order.
	store, err = db.store_open(path, {persistent = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "reopen: %s", err.message) do return
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM doc").i, i64(400))
	run_done(t, store, "INSERT INTO doc (body) VALUES ('tail')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM doc").i, i64(401))

	// A checkpoint collapses every segment back into the first one.
	testing.expect(t, db.error_ok(db.store_snapshot(store)))
	testing.expect(t, db.error_ok(db.store_compact(store)))
	second = fmt.aprintf("%s/log.1", path)
	testing.expect(t, !os.exists(second))
	delete(second)
	db.store_close(store)

	store, err = db.store_open(path, {persistent = true, durable = false})
	defer db.store_close(store)
	if !testing.expectf(t, db.error_ok(err), "reopen after compact: %s", err.message) do return
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM doc").i, i64(401))
}

@(test)
test_show_tables :: proc(t: ^testing.T) {
	store := fresh_db(t, "showtables")
	if store == nil do return
	defer cleanup_db(store, "showtables")

	run_done(t, store, "CREATE TABLE alpha (id INTEGER PRIMARY KEY AUTOINCREMENT)")
	run_done(t, store, "CREATE TABLE beta (id INTEGER PRIMARY KEY AUTOINCREMENT)")
	run_done(t, store, "CREATE VIEW gamma AS SELECT id FROM alpha")

	shown := run(t, store, "SHOW tables")
	testing.expect_value(t, len(shown.columns), 1)
	testing.expect_value(t, len(shown.rows), 2) // the view lives in _view, not here
	testing.expect_value(t, shown.rows[0][0].s, "alpha")
	testing.expect_value(t, shown.rows[1][0].s, "beta")
	db.sql_result_destroy(&shown)
}

@(test)
test_subscription_set :: proc(t: ^testing.T) {
	store := fresh_db(t, "subset")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "subset")

	run_done(t, store, "CREATE TABLE alpha (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT NOT NULL)")
	run_done(t, store, "CREATE TABLE beta (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO alpha (v) VALUES ('a1')")
	run_done(t, store, "INSERT INTO beta (v) VALUES ('b1')")

	id, snapshots, err := db.host_subscribe_many(
		host,
		[]string{"SELECT v FROM alpha", "SELECT v FROM beta"},
	)
	defer db.host_snapshot_destroy(snapshots)
	if !testing.expectf(t, db.error_ok(err), "subscribe failed: %s", err.message) do return
	testing.expect_value(t, len(snapshots), 2)
	testing.expect_value(t, len(snapshots[0]), 1)
	testing.expect_value(t, snapshots[0][0][0].s, "a1")
	testing.expect_value(t, snapshots[1][0][0].s, "b1")

	// [inserts, deletes, last query index]
	seen: ^[3]int = &{0, 0, -1}
	on_update :: proc(ctx: rawptr, update: ^db.Subscription_Update) {
		counters := (^[3]int)(ctx)
		counters[0] += len(update.inserts)
		counters[1] += len(update.deletes)
		counters[2] = update.query
	}
	host.on_update = on_update
	host.on_update_ctx = seen

	run_done(t, store, "INSERT INTO beta (v) VALUES ('b2')")
	testing.expect_value(t, seen[0], 1)
	testing.expect_value(t, seen[1], 0)
	testing.expect_value(t, seen[2], 1) // only the second query changed

	seen[0] = 0
	seen[2] = -1
	run_done(t, store, "DELETE FROM alpha WHERE v = 'a1'")
	testing.expect_value(t, seen[0], 0)
	testing.expect_value(t, seen[1], 1)
	testing.expect_value(t, seen[2], 0)

	testing.expect(t, db.host_unsubscribe(host, id))
	testing.expect(t, !db.host_unsubscribe(host, id))
}

// wire_ask sends a request the test made for it and frees the request; the
// response is the test's to free.
@(private)
wire_ask :: proc(host: ^db.Host, request: []u8) -> []u8 {
	defer delete(request)
	return db.wire_request(host, request)
}

// wire_ask_owned sends a request as connection `owner` and answers the
// response's kind, the response freed: for the tests that only check it. The
// request stays the caller's.
@(private)
wire_ask_owned :: proc(host: ^db.Host, request: []u8, owner: u64) -> u32 {
	response := db.wire_request_owned(host, request, owner)
	defer delete(response)
	return wire_kind(response)
}

@(private)
wire_kind :: proc(data: []u8) -> u32 {
	return u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
}

@(test)
test_wire_messages :: proc(t: ^testing.T) {
	store := fresh_db(t, "wire")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "wire")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (5)")

	// One-off query over the wire.
	response := wire_ask(host, db.wire_encode_query("SELECT v FROM t", nil))
	defer delete(response)
	testing.expect_value(t, wire_kind(response), db.WIRE_RESULT)
	result, decode_err := db.wire_decode_result(response, context.allocator)
	testing.expect(t, db.error_ok(decode_err))
	testing.expect_value(t, result.rows[0][0].i, i64(5))
	testing.expect(t, result.commit_seq > 0)
	first_seq := result.commit_seq
	db.sql_result_destroy(&result)

	// Reducer call with an idempotency id.
	bump :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		amount, _ := db.value_to_i64(args[0])
		dropped_result_2726, err := db.sql_execute_in_tx(ctx.tx, fmt.tprintf("UPDATE t SET v = v + %d", amount))
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_2726)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(host, "bump", []db.Column_Type{db.type_int}, bump)))
	call := db.wire_encode_call(42, "bump", []db.Value{db.value_int(3)})
	defer delete(call)
	call_response := db.wire_request(host, call)
	defer delete(call_response)
	testing.expect_value(t, wire_kind(call_response), db.WIRE_RESULT)
	decoded, call_err := db.wire_decode_result(call_response, context.allocator)
	testing.expect(t, db.error_ok(call_err))
	testing.expect(t, decoded.commit_seq > first_seq)
	db.sql_result_destroy(&decoded)
	testing.expect_value(t, scalar(t, store, "SELECT v FROM t").i, i64(8))

	// The same id must not run the reducer twice.
	retry := db.wire_request(host, call)
	defer delete(retry)
	retry_result, retry_err := db.wire_decode_result(retry, context.allocator)
	testing.expect(t, db.error_ok(retry_err))
	db.sql_result_destroy(&retry_result)
	testing.expect_value(t, scalar(t, store, "SELECT v FROM t").i, i64(8))

	// Subscribe, then unsubscribe.
	sub := wire_ask(host, db.wire_encode_subscribe([]string{"SELECT v FROM t"}))
	defer delete(sub)
	testing.expect_value(t, wire_kind(sub), db.WIRE_SNAPSHOT)
	sub_id, _, snapshot, sub_err := db.wire_decode_snapshot(sub, context.temp_allocator)
	testing.expect(t, db.error_ok(sub_err))
	testing.expect_value(t, snapshot[0][0][0].i, i64(8))

	unsub := wire_ask(host, db.wire_encode_unsubscribe(sub_id))
	defer delete(unsub)
	removed, unsub_err := db.wire_decode_result(unsub, context.allocator)
	testing.expect(t, db.error_ok(unsub_err))
	testing.expect_value(t, removed.affected, 1)
	db.sql_result_destroy(&removed)
}

@(private)
http_bytes_of :: proc(text: string) -> []u8 {
	// In the test's temporary memory: no caller frees the bytes.
	out := make([]u8, len(text), context.temp_allocator)
	copy(out, text)
	return out
}

@(test)
test_background_compaction :: proc(t: ^testing.T) {
	// The compactor runs on its own thread and allocates with the store's
	// allocator, so the test uses the heap: the tracking allocator is per test
	// and not safe to share across threads.
	old_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer context.allocator = old_allocator

	path := fmt.aprintf("_test_%s", "bgcompact")
	defer delete(path)
	defer os.remove_all(path)
	os.remove_all(path)
	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)

	run_done(t, store, "CREATE TABLE log_rows (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL)")
	// Without a threshold there is nothing to do.
	testing.expect(t, !db.store_background_compact_step(store))

	for _ in 0 ..< 120 {
		run_done(t, store, fmt.tprintf("INSERT INTO log_rows (body) VALUES ('%s')", strings.repeat("x", 200)))
	}
	grown := db.store_log_bytes(store)
	testing.expect(t, grown > 24 << 10)

	// A threshold above the log leaves it alone; one below rewrites it.
	store.compact_bytes = grown + (1 << 20)
	testing.expect(t, !db.store_background_compact_step(store))
	store.compact_bytes = 24 << 10
	testing.expect(t, db.store_background_compact_step(store))
	compacted := db.store_log_bytes(store)
	testing.expect(t, compacted < grown, "compaction must shrink the log")

	// The rows survived the rewrite, and a rewrite right after another one is
	// refused: the snapshot itself is bigger than the threshold.
	counted := scalar(t, store, "SELECT count(*) FROM log_rows")
	testing.expect_value(t, counted.i, i64(120))
	testing.expect(t, !db.store_background_compact_step(store))

	// The worker runs on its own once the log grows past the threshold. The
	// floor from the rewrite above is large, so the test lowers it: what matters
	// here is that the thread notices and rewrites without being asked.
	db.store_stop_background_compaction(store)
	testing.expect(t, db.store_start_background_compaction(store, 8 << 10))
	store.compact_floor = 0
	before_rewrites := store.compact_count
	for _ in 0 ..< 60 {
		run_done(t, store, fmt.tprintf("INSERT INTO log_rows (body) VALUES ('%s')", strings.repeat("z", 200)))
	}
	started := time.now()
	compacted_by_worker := false
	for time.since(started) < 5 * time.Second {
		if store.compact_count > before_rewrites {
			compacted_by_worker = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(
		t,
		compacted_by_worker,
		"the worker must compact without being asked (log %d, count %d)",
		db.store_log_bytes(store),
		store.compact_count,
	)
	// The rows survived the rewrite and the worker still serves reads.
	total := scalar(t, store, "SELECT count(*) FROM log_rows")
	testing.expect(t, total.i >= 180)
	// Closing stops the thread; a hang here fails the suite.
}

@(test)
test_transport_caps :: proc(t: ^testing.T) {
	// A connection can send anything; the transport must refuse what is too big
	// with an error instead of allocating it or crashing.
	long_header := fmt.aprintf("GET /health HTTP/1.1\r\nX: %s\r\n\r\n", strings.repeat("a", 200, context.temp_allocator))
	defer delete(long_header)
	_, _, header_err := db.http_parse_request_within(transmute([]u8)long_header, 64, 1024)
	defer db.error_free(&header_err)
	testing.expect_value(t, header_err.kind, db.Error_Kind.Quota_Exceeded)

	// A declared Content-Length over the body cap is refused before the body
	// arrives, so a client cannot make the server buffer it.
	_, _, body_err := db.http_parse_request_within(
		transmute([]u8)string("POST /query HTTP/1.1\r\nContent-Length: 4096\r\n\r\n"),
		1024,
		1024,
	)
	defer db.error_free(&body_err)
	testing.expect_value(t, body_err.kind, db.Error_Kind.Quota_Exceeded)

	// An overflowing Content-Length does not wrap into a small positive number.
	_, _, overflow_err := db.http_parse_request_within(
		transmute([]u8)string("POST /query HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n"),
		1024,
		1024,
	)
	defer db.error_free(&overflow_err)
	testing.expect_value(t, overflow_err.kind, db.Error_Kind.Quota_Exceeded)

	// A small request still parses, and the host cap answers 413 rather than
	// pretending the body was handled.
	small, _, small_err := db.http_parse_request_within(
		transmute([]u8)string("POST /query HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd"),
		1024,
		1024,
	)
	defer db.http_request_destroy(&small)
	defer db.error_free(&small_err)
	testing.expect(t, db.error_ok(small_err))
	testing.expect_value(t, string(small.body), "abcd")

	store := fresh_db(t, "caps")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "caps")
	db.host_set_request_limits(host, 2, 1024)
	capped := db.http_handle(host, small)
	defer delete(capped)
	testing.expect(t, strings_contains(string(capped), "413 Payload Too Large"))

	db.host_set_request_limits(host, 1 << 20, 1024)
	allowed := db.http_handle(host, small)
	defer delete(allowed)
	testing.expect(t, !strings_contains(string(allowed), "413"))

	// WebSocket frames are checked before the payload is allocated.
	big := make([]u8, 300)
	frame := db.ws_frame(big)
	defer delete(frame)
	_, _, _, frame_err := db.ws_read_frame_within(frame, 128)
	defer db.error_free(&frame_err)
	testing.expect_value(t, frame_err.kind, db.Error_Kind.Quota_Exceeded)
	ok_payload, _, _, ok_err := db.ws_read_frame_within(frame, 1024)
	defer delete(ok_payload)
	defer db.error_free(&ok_err)
	testing.expect(t, db.error_ok(ok_err))

	// A 64-bit length with the top bit set must not wrap into a negative size.
	forged := make([]u8, 14)
	defer delete(forged)
	forged[0] = 0x2
	forged[1] = 127
	forged[2] = 0xff
	forged[3] = 0xff
	_, _, _, forged_err := db.ws_read_frame_within(forged, 1024)
	defer db.error_free(&forged_err)
	testing.expect(t, !db.error_ok(forged_err))
	delete(big)
}

@(test)
test_http_layer :: proc(t: ^testing.T) {
	store := fresh_db(t, "http")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "http")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (7)")

	wire := db.wire_encode_query("SELECT v FROM t", nil)
	defer delete(wire)
	head := fmt.aprintf("POST /query HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n", len(wire))
	request_bytes := make([]u8, len(head) + len(wire))
	copy(request_bytes, head)
	copy(request_bytes[len(head):], wire)
	defer delete(request_bytes)
	defer delete(head)

	request, consumed, parse_err := db.http_parse_request(request_bytes)
	defer db.http_request_destroy(&request)
	defer db.error_free(&parse_err)
	testing.expect(t, db.error_ok(parse_err))
	testing.expect_value(t, consumed, len(request_bytes))
	testing.expect_value(t, request.method, "POST")
	testing.expect_value(t, request.path, "/query")
	testing.expect_value(t, len(request.body), len(wire))

	response := db.http_handle(host, request)
	defer delete(response)
	testing.expect(t, strings_contains(string(response), "HTTP/1.1 200 OK"))
	testing.expect(t, strings_contains(string(response), "Content-Type: application/octet-stream"))
	// The body after the blank line is the wire result.
	body_offset := strings_index_of(string(response), "\r\n\r\n") + 4
	result, result_err := db.wire_decode_result(response[body_offset:], context.allocator)
	testing.expect(t, db.error_ok(result_err))
	testing.expect_value(t, result.rows[0][0].i, i64(7))
	db.sql_result_destroy(&result)

	health, _, dropped_parse_err_2925 := db.http_parse_request(http_bytes_of("GET /health HTTP/1.1\r\n\r\n"))
	defer db.http_request_destroy(&health)
	defer db.error_free(&dropped_parse_err_2925)
	health_response := db.http_handle(host, health)
	defer delete(health_response)
	testing.expect(t, strings_contains(string(health_response), "200 OK"))
	testing.expect(t, strings_contains(string(health_response), "ok"))

	missing, _, dropped_parse_err_2930 := db.http_parse_request(http_bytes_of("POST /nope HTTP/1.1\r\nContent-Length: 0\r\n\r\n"))
	defer db.http_request_destroy(&missing)
	defer db.error_free(&dropped_parse_err_2930)
	missing_response := db.http_handle(host, missing)
	defer delete(missing_response)
	testing.expect(t, strings_contains(string(missing_response), "404 Not Found"))

	// A single reader is enough for the socket loop later: two requests back to
	// back parse one after the other.
	combined := make([]byte, len(request_bytes) + 3)
	defer delete(combined)
	copy(combined, request_bytes)
	copy(combined[len(request_bytes):], "abc")
	combined_request, first, first_err := db.http_parse_request(combined)
	defer db.http_request_destroy(&combined_request)
	defer db.error_free(&first_err)
	testing.expect(t, db.error_ok(first_err))
	testing.expect_value(t, first, len(request_bytes))
}

@(private)
strings_index_of :: proc(haystack, needle: string) -> int {
	return strings_contains_index(haystack, needle)
}

@(test)
test_websocket :: proc(t: ^testing.T) {
	// RFC 6455 section 1.3 example.
	accept := db.ws_accept_key("dGhlIHNhbXBsZSBub25jZQ==")
	defer delete(accept)
	testing.expect_value(t, accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

	request := http_bytes_of(
		"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
	)
	testing.expect(t, db.ws_is_upgrade(request))
	response, ok := db.ws_handshake(request)
	defer delete(response)
	testing.expect(t, ok)
	testing.expect(t, strings_contains(string(response), "101 Switching Protocols"))
	testing.expect(t, strings_contains(string(response), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))

	framed := db.ws_frame(http_bytes_of("hi"))
	defer delete(framed)
	testing.expect_value(t, len(framed), 4)
	testing.expect_value(t, framed[0], u8(0x82))
	testing.expect_value(t, framed[1], u8(2))

	// A masked client frame carrying "hi".
	mask := [4]u8{1, 2, 3, 4}
	client := make([]u8, 8)
	client[0] = 0x82
	client[1] = 0x80 | 2
	copy(client[2:6], mask[:])
	client[6] = 'h' ~ mask[0]
	client[7] = 'i' ~ mask[1]
	payload, consumed, opcode, frame_err := db.ws_read_frame(client)
	testing.expect(t, db.error_ok(frame_err))
	testing.expect_value(t, consumed, 8)
	testing.expect_value(t, opcode, u8(2))
	testing.expect_value(t, string(payload), "hi")
	delete(payload)
	delete(client)
}

@(test)
test_tokens :: proc(t: ^testing.T) {
	store := fresh_db(t, "tokens")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "tokens")

	identity: db.Identity
	identity[0] = 7
	identity[31] = 9
	host.now_us = i64(1_000_000)
	token, issue_err := db.host_issue_token(host, identity, 0)
	defer delete(token)
	testing.expect(t, db.error_ok(issue_err))
	testing.expect_value(t, len(token), 67)
	testing.expect(t, strings_contains(token, "mt_"))

	// Only the HMAC digest is stored, never the credential itself.
	stored := scalar(t, store, "SELECT token FROM _token")
	testing.expect(t, stored.s != token)
	testing.expect_value(t, len(stored.s), 64)

	resolved, valid := db.host_authenticate(host, token)
	testing.expect(t, valid)
	testing.expect_value(t, resolved[0], u8(7))
	testing.expect_value(t, resolved[31], u8(9))

	// AUTH over the wire sets the identity policies see.
	response := wire_ask(host, db.wire_encode_auth(token))
	defer delete(response)
	testing.expect_value(t, wire_kind(response), db.WIRE_RESULT)
	decoded, decode_err := db.wire_decode_result(response, context.allocator)
	testing.expect(t, db.error_ok(decode_err))
	testing.expect_value(t, decoded.affected, 1)
	db.sql_result_destroy(&decoded)
	testing.expect_value(t, store.identity[0], u8(7))

	// Unknown and expired tokens are rejected.
	bad := wire_ask(host, db.wire_encode_auth("nope"))
	defer delete(bad)
	testing.expect_value(t, wire_kind(bad), db.WIRE_ERROR)
	short, short_err := db.host_issue_token(host, identity, -1)
	defer delete(short)
	testing.expect(t, db.error_ok(short_err))
	expired := wire_ask(host, db.wire_encode_auth(short))
	defer delete(expired)
	testing.expect_value(t, wire_kind(expired), db.WIRE_ERROR)

	// Revocation.
	testing.expect(t, db.host_revoke_token(host, token))
	testing.expect(t, !db.host_revoke_token(host, token))
	_, still_valid := db.host_authenticate(host, token)
	testing.expect(t, !still_valid)

	header_request := http_bytes_of("GET /health HTTP/1.1\r\nAuthorization: Bearer abc123\r\n\r\n")
	parsed_token, has_token := db.http_bearer_token(header_request)
	testing.expect(t, has_token)
	testing.expect_value(t, parsed_token, "abc123")
}

@(test)
test_cancellation :: proc(t: ^testing.T) {
	store := fresh_db(t, "cancel")
	if store == nil do return
	defer cleanup_db(store, "cancel")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (1), (2), (3)")

	db.store_cancel(store)
	cancelled := run_error(t, store, "SELECT * FROM t")
	testing.expect_value(t, cancelled.kind, db.Error_Kind.Cancelled)

	// A cancelled update stops before touching rows too.
	cancelled_update := run_error(t, store, "UPDATE t SET v = 0")
	testing.expect_value(t, cancelled_update.kind, db.Error_Kind.Cancelled)

	// The flag is cooperative and stays set until the owner clears it.
	db.store_clear_cancel(store)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE v = 0").i, i64(0))

	db.store_clear_cancel(store)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
	run_done(t, store, "UPDATE t SET v = 0")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE v = 0").i, i64(3))
}

@(test)
test_describe :: proc(t: ^testing.T) {
	store := fresh_db(t, "describe")
	if store == nil do return
	defer cleanup_db(store, "describe")

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score DOUBLE DEFAULT 1.5)")
	run_done(t, store, "CREATE INDEX item_score ON item (score)")

	described := run(t, store, "DESCRIBE item")
	testing.expect_value(t, len(described.columns), 6)
	testing.expect_value(t, described.rows[0][0].s, "column")
	testing.expect_value(t, described.rows[0][1].s, "id")
	testing.expect(t, strings_contains(described.rows[0][2].s, "INT"))
	testing.expect_value(t, described.rows[1][1].s, "name")
	testing.expect_value(t, described.rows[1][3].b, true)

	index_found := false
	for row in described.rows {
		if row[0].s != "index" do continue
		if row[1].s == "item_score" {
			index_found = true
			testing.expect_value(t, row[2].s, "score")
			testing.expect_value(t, row[4].b, false)
		}
	}
	testing.expect(t, index_found)
	described_rows := len(described.rows)
	db.sql_result_destroy(&described)

	alias := run(t, store, "DESC item")
	testing.expect_value(t, len(alias.rows), described_rows)
	db.sql_result_destroy(&alias)

	missing := run_error(t, store, "DESCRIBE nope")
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)
}

@(test)
test_subscription_owners :: proc(t: ^testing.T) {
	store := fresh_db(t, "owners")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "owners")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (1)")

	owner := u64(77)
	owned, snapshot, owned_err := db.host_subscribe_many_owned(host, []string{"SELECT v FROM t"}, owner)
	defer db.host_snapshot_destroy(snapshot)
	testing.expect(t, db.error_ok(owned_err))
	testing.expect_value(t, len(snapshot[0]), 1)
	testing.expect_value(t, db.host_drop_owned(host, owner), 1)
	testing.expect(t, !db.host_unsubscribe(host, owned))
	testing.expect_value(t, db.host_drop_owned(host, owner), 0)

	// Owner 0 is unowned and survives a bulk drop; explicit unsubscribe works.
	unowned, dropped_snapshot_3109, unowned_err := db.host_subscribe_many(host, []string{"SELECT v FROM t"})
	defer db.host_snapshot_destroy(dropped_snapshot_3109)
	testing.expect(t, db.error_ok(unowned_err))
	testing.expect_value(t, db.host_drop_owned(host, 0), 0)
	testing.expect(t, db.host_unsubscribe(host, unowned))

	// One owner can hold several sets, all dropped together.
	first, dropped_snapshot_3115, _ := db.host_subscribe_many_owned(host, []string{"SELECT v FROM t"}, 1)
	defer db.host_snapshot_destroy(dropped_snapshot_3115)
	second, dropped_snapshot_3116, _ := db.host_subscribe_many_owned(host, []string{"SELECT v FROM t"}, 1)
	defer db.host_snapshot_destroy(dropped_snapshot_3116)
	testing.expect_value(t, db.host_drop_owned(host, 1), 2)
	testing.expect(t, !db.host_unsubscribe(host, first))
	testing.expect(t, !db.host_unsubscribe(host, second))
}

@(test)
test_procedures :: proc(t: ^testing.T) {
	store := fresh_db(t, "procedures")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "procedures")

	run_done(t, store, "CREATE TABLE log (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")

	step :: proc(ctx: ^db.Procedure_Ctx, args: []db.Value) -> db.Error {
		dropped_result_3213, err := db.sql_execute_in_tx(ctx.tx, "INSERT INTO log (v) VALUES (1)")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_3213)
		if !db.error_ok(err) do return err
		if commit_err := db.procedure_commit(ctx); commit_err.kind != .None do return commit_err
		_, err = db.sql_execute_in_tx(ctx.tx, "INSERT INTO log (v) VALUES (2)")
		if !db.error_ok(err) do return err
		if commit_err := db.procedure_commit(ctx); commit_err.kind != .None do return commit_err
		_, err = db.sql_execute_in_tx(ctx.tx, "INSERT INTO log (v) VALUES (3)")
		return err
	}
	testing.expect(t, db.error_ok(db.host_register_procedure(host, "step", nil, step)))
	testing.expect(t, db.error_ok(db.host_call_procedure(host, "step", nil)))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log").i, i64(3))

	// A failure after a commit keeps the committed phases and drops only the
	// phase that failed.
	fail_late :: proc(ctx: ^db.Procedure_Ctx, args: []db.Value) -> db.Error {
		dropped_result_3229, err := db.sql_execute_in_tx(ctx.tx, "INSERT INTO log (v) VALUES (4)")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_3229)
		if !db.error_ok(err) do return err
		if commit_err := db.procedure_commit(ctx); commit_err.kind != .None do return commit_err
		return db.Error{kind = .Invalid_Argument, message = "boom"}
	}
	testing.expect(t, db.error_ok(db.host_register_procedure(host, "fail_late", nil, fail_late)))
	failed := db.host_call_procedure(host, "fail_late", nil)
	testing.expect_value(t, failed.kind, db.Error_Kind.Invalid_Argument)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log").i, i64(4))

	// The same procedure runs over the wire (F6).
	response := wire_ask(host, db.wire_encode_call_procedure("step", nil))
	defer delete(response)
	testing.expect_value(t, wire_kind(response), db.WIRE_RESULT)
	decoded, decode_err := db.wire_decode_result(response, context.allocator)
	testing.expect(t, db.error_ok(decode_err))
	testing.expect_value(t, decoded.affected, 1)
	db.sql_result_destroy(&decoded)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log").i, i64(7))
}

@(test)
test_store_memory :: proc(t: ^testing.T) {
	store := fresh_db(t, "storemem")
	if store == nil do return
	defer cleanup_db(store, "storemem")

	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT NOT NULL)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO a (v) VALUES ('one'), ('two')")
	run_done(t, store, "INSERT INTO b (n) VALUES (3)")

	a_memory, a_err := db.store_table_memory(store, "a")
	testing.expect(t, db.error_ok(a_err))
	b_memory, b_err := db.store_table_memory(store, "b")
	testing.expect(t, db.error_ok(b_err))
	// The CREATE texts the engine keeps are rows too (_sqlite_sql).
	text_memory, text_err := db.store_table_memory(store, "_sqlite_sql")
	testing.expect(t, db.error_ok(text_err))
	total := db.store_memory(store)
	testing.expect_value(t, total.rows, a_memory.rows + b_memory.rows + text_memory.rows)
	testing.expect(t, total.row_bytes >= a_memory.row_bytes + b_memory.row_bytes)
	testing.expect(t, total.index_entries >= a_memory.index_entries + b_memory.index_entries)
	testing.expect(t, total.index_bytes >= a_memory.index_bytes + b_memory.index_bytes)
}

@(test)
test_reducer_catalog :: proc(t: ^testing.T) {
	store := fresh_db(t, "catalog")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "catalog")

	bump :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		return {}
	}
	step :: proc(ctx: ^db.Procedure_Ctx, args: []db.Value) -> db.Error {
		return {}
	}
	testing.expect(t, db.error_ok(db.host_register(host, "bump", []db.Column_Type{db.type_int}, bump)))
	testing.expect(t, db.error_ok(db.host_register_procedure(host, "step", nil, step)))

	rows := run(t, store, "SELECT name, kind, params FROM _reducer ORDER BY name")
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect_value(t, rows.rows[0][0].s, "bump")
	testing.expect_value(t, rows.rows[0][1].s, "reducer")
	testing.expect(t, strings_contains(rows.rows[0][2].s, "INT"))
	testing.expect_value(t, rows.rows[1][0].s, "step")
	testing.expect_value(t, rows.rows[1][1].s, "procedure")
	testing.expect_value(t, rows.rows[1][2].s, "")
	db.sql_result_destroy(&rows)

	// Duplicate registration is rejected before touching the catalog.
	duplicate := db.host_register(host, "bump", []db.Column_Type{db.type_string}, bump)
	defer db.error_free(&duplicate)
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Invalid_Argument)
	count := scalar(t, store, "SELECT count(*) FROM _reducer")
	testing.expect_value(t, count.i, i64(2))
}

@(test)
test_commit_ops_hook :: proc(t: ^testing.T) {
	store := fresh_db(t, "opshook")
	if store == nil do return
	defer cleanup_db(store, "opshook")

	seen: ^[3]int = &{0, 0, 0}
	hook :: proc(ctx: rawptr, store: ^db.Store, ops: []db.Store_Op) {
		counters := (^[3]int)(ctx)
		for op in ops {
			// The stream carries the engine's own tables too (the CREATE text).
			if op.name != "t" do continue
			#partial switch op.kind {
			case .Insert:
				counters[0] += 1
			case .Update:
				counters[1] += 1
			case .Delete:
				counters[2] += 1
			case:
			}
		}
	}
	store.on_commit = hook
	store.on_commit_ctx = seen

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (5)")
	testing.expect_value(t, seen[0], 1)
	run_done(t, store, "UPDATE t SET v = 6")
	testing.expect_value(t, seen[1], 1)
	run_done(t, store, "DELETE FROM t")
	testing.expect_value(t, seen[2], 1)
	store.on_commit = nil
}

@(test)
test_log_bit_flip :: proc(t: ^testing.T) {
	path := "_test_bitflip"
	os.remove_all(path)
	defer os.remove_all(path)

	store, err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (v) VALUES (1)")
	run_done(t, store, "INSERT INTO t (v) VALUES (2)")
	run_done(t, store, "INSERT INTO t (v) VALUES (3)")
	db.store_close(store)

	// Flip one bit in the last record's payload: the CRC must reject it and the
	// replay must stop at the previous record, leaving a consistent log.
	log_path := fmt.aprintf("%s/log", path)
	defer delete(log_path)
	file, open_err := os.open(log_path, {.Read, .Write})
	if !testing.expectf(t, open_err == nil, "open log: %v", open_err) do return
	info, stat_err := os.stat(log_path, context.temp_allocator)
	if !testing.expectf(t, stat_err == nil, "stat log: %v", stat_err) {
		os.close(file)
		return
	}
	last := i64(info.size) - 1
	if _, seek_err := os.seek(file, last, .Start); !testing.expectf(t, seek_err == nil, "seek: %v", seek_err) {
		os.close(file)
		return
	}
	one := [1]u8{0xff}
	_, _ = os.write(file, one[:])
	os.close(file)

	store, err = db.store_open(path, {persistent = true, durable = false})
	defer db.store_close(store)
	if !testing.expectf(t, db.error_ok(err), "reopen: %s", err.message) do return
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))
	// The tail was repaired, so appending keeps working.
	run_done(t, store, "INSERT INTO t (v) VALUES (4)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
}

@(test)
test_sql_functions_and_truncate :: proc(t: ^testing.T) {
	store := fresh_db(t, "funcs")
	if store == nil do return
	defer cleanup_db(store, "funcs")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, s TEXT NOT NULL, n INTEGER NOT NULL, f DOUBLE NOT NULL)")
	run_done(t, store, "INSERT INTO t (s, n, f) VALUES ('  Hello  ', 7, 2.6), ('world', -3, -1.4)")

	checks := []struct {
		sql:      string,
		expected: string,
	}{
		{"SELECT substr(s, 3, 5) FROM t WHERE id = 1", "Hello"},
		{"SELECT trim(s) FROM t WHERE id = 1", "Hello"},
		{"SELECT replace('abcabc', 'b', 'X') FROM t WHERE id = 1", "aXcaXc"},
		{"SELECT concat(s, '!') FROM t WHERE id = 2", "world!"},
		{"SELECT mod(n, 4) FROM t WHERE id = 1", "3"},
		{"SELECT pow(2, 3) FROM t WHERE id = 1", "8"},
	}
	for check in checks {
		value := scalar(t, store, check.sql)
		testing.expect_value(t, db.value_format(value, context.temp_allocator), check.expected)
	}
	testing.expect_value(t, scalar(t, store, "SELECT sign(n) FROM t WHERE id = 1").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT sign(n) FROM t WHERE id = 2").i, i64(-1))
	testing.expect_value(t, scalar(t, store, "SELECT round(f) FROM t WHERE id = 1").f, f64(3))
	testing.expect_value(t, scalar(t, store, "SELECT floor(f) FROM t WHERE id = 2").f, f64(-2))
	testing.expect_value(t, scalar(t, store, "SELECT ceil(f) FROM t WHERE id = 2").f, f64(-1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE nullif(n, 7) IS NULL").i, i64(1))

	truncated := run(t, store, "TRUNCATE t")
	db.sql_result_destroy(&truncated)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(0))
}

@(test)
test_meta_and_metrics :: proc(t: ^testing.T) {
	store := fresh_db(t, "meta")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "meta")

	version, found := db.host_meta(host, "schema_version")
	testing.expect(t, found)
	testing.expect_value(t, version, "1")

	ok := wire_ask(host, db.wire_encode_query("SELECT key FROM _meta", nil))
	defer delete(ok)
	testing.expect(t, len(ok) > 0)
	testing.expect_value(t, host.metric_requests, u64(1))
	testing.expect_value(t, host.metric_errors, u64(0))

	bad := wire_ask(host, db.wire_encode_auth("nope"))
	defer delete(bad)
	testing.expect_value(t, wire_kind(bad), db.WIRE_ERROR)
	testing.expect_value(t, host.metric_requests, u64(2))
	testing.expect_value(t, host.metric_errors, u64(1))

	request, _, dropped_parse_err_3393 := db.http_parse_request(http_bytes_of("GET /metrics HTTP/1.1\r\n\r\n"))
	defer db.http_request_destroy(&request)
	defer db.error_free(&dropped_parse_err_3393)
	response := db.http_handle(host, request)
	defer delete(response)
	body := string(response)
	testing.expect(t, strings_contains(body, "miraidb_requests_total 2"))
	testing.expect(t, strings_contains(body, "miraidb_errors_total 1"))
	testing.expect(t, strings_contains(body, "# TYPE miraidb_commit_seq gauge"))
}

@(test)
test_module_variables :: proc(t: ^testing.T) {
	store := fresh_db(t, "modvars")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "modvars")

	testing.expect(t, db.error_ok(db.host_set_module_variable(host, "mode", "fast")))
	value, found := db.host_get_module_variable(host, "mode", context.temp_allocator)
	testing.expect(t, found)
	// The value outlives the statements that run after it was read.
	run_done(t, store, "SELECT key, value FROM _var")
	testing.expect_value(t, value, "fast")

	testing.expect(t, db.error_ok(db.host_set_module_variable(host, "mode", "slow")))
	value, found = db.host_get_module_variable(host, "mode", context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, value, "slow")

	testing.expect(t, db.error_ok(db.host_set_module_variable(host, "region", "eu")))
	names := db.host_module_variable_names(host, context.temp_allocator)
	run_done(t, store, "SELECT key, value FROM _var")
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "mode")
	testing.expect_value(t, names[1], "region")

	// Module variables are committed data, not process state.
	testing.expect_value(t, scalar(t, store, "SELECT value FROM _var WHERE key = 'mode'").s, "slow")
}

@(test)
test_schema_reflection :: proc(t: ^testing.T) {
	store := fresh_db(t, "reflect")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "reflect")

	run_done(t, store, "CREATE TABLE thing (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	run_done(t, store, "CREATE INDEX thing_name ON thing (name)")
	text := db.host_schema_text(host, context.allocator)
	defer delete(text)
	testing.expect(t, strings_contains(text, "table thing"))
	testing.expect(t, strings_contains(text, "name TEXT"))
	testing.expect(t, strings_contains(text, "thing_name"))

	request, _, dropped_parse_err_3444 := db.http_parse_request(http_bytes_of("GET /schema HTTP/1.1\r\n\r\n"))
	defer db.http_request_destroy(&request)
	defer db.error_free(&dropped_parse_err_3444)
	response := db.http_handle(host, request)
	defer delete(response)
	testing.expect(t, strings_contains(string(response), "table thing"))
}

@(test)
test_schema_validation :: proc(t: ^testing.T) {
	store := fresh_db(t, "validate")
	if store == nil do return
	defer cleanup_db(store, "validate")

	dropped_result_3489, duplicated := db.sql_execute(store, "CREATE TABLE dup (a INTEGER, a TEXT)")
	defer db.error_free(&duplicated)
	defer db.sql_result_destroy(&dropped_result_3489)
	testing.expect(t, !db.error_ok(duplicated))
	dropped_result_3491, bad_default := db.sql_execute(store, "CREATE TABLE bad_default (a INTEGER NOT NULL DEFAULT NULL)")
	defer db.error_free(&bad_default)
	defer db.sql_result_destroy(&dropped_result_3491)
	testing.expect(t, !db.error_ok(bad_default))
	run_done(t, store, "CREATE TABLE good (a INTEGER, b TEXT)")
	dropped_result_3483, repeated := db.sql_execute(store, "CREATE INDEX twice ON good (a, a)")
	defer db.error_free(&repeated)
	defer db.sql_result_destroy(&dropped_result_3483)
	testing.expect(t, !db.error_ok(repeated))
	run_done(t, store, "CREATE INDEX once ON good (a, b)")

	run_done(t, store, "INSERT INTO good (a, b) VALUES (1, 'x')")
	testing.expect_value(t, scalar(t, store, "SELECT b FROM good").s, "x")
}

// fresh_host is the standard fixture: an isolated database plus a host.
fresh_host :: proc(t: ^testing.T, name: string) -> (^db.Store, ^db.Host) {
	store := fresh_db(t, name)
	if store == nil do return nil, nil
	return store, db.host_init(store)
}

destroy_host :: proc(store: ^db.Store, host: ^db.Host, name: string) {
	db.host_destroy(host)
	cleanup_db(store, name)
}

// run_params executes a statement with bind parameters, failing the test on error.
run_params :: proc(
	t: ^testing.T,
	store: ^db.Store,
	sql: string,
	params: []db.Value,
) -> db.Sql_Result {
	result, err := db.sql_execute_params(store, sql, params)
	testing.expectf(t, db.error_ok(err), "%s failed: %s", sql, err.message)
	db.error_free(&err)
	return result
}

@(test)
test_fixture_helpers :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "fixture")
	if store == nil do return
	defer destroy_host(store, host, "fixture")

	run_done(t, store, "CREATE TABLE f (id INTEGER PRIMARY KEY, name TEXT)")
	insert := run_params(t, store, "INSERT INTO f (name) VALUES (?)", []db.Value{db.value_string("ok")})
	defer db.sql_result_destroy(&insert)
	testing.expect_value(t, scalar(t, store, "SELECT name FROM f").s, "ok")
}

@(test)
test_codegen :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "codegen")
	if store == nil do return
	defer destroy_host(store, host, "codegen")

	run_done(t, store, "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL)")
	code := db.codegen_odin(host, context.allocator)
	defer delete(code)
	testing.expect(t, strings_contains(code, "package generated"))
	testing.expect(t, strings_contains(code, "Row_person :: struct {"))
	testing.expect(t, strings_contains(code, "id: i64"))
	testing.expect(t, strings_contains(code, "name: string"))
	testing.expect(t, strings_contains(code, "score: f64"))
	testing.expect(t, !strings_contains(code, "_meta"))
}

@(test)
test_export_sql :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "export")
	if store == nil do return
	defer destroy_host(store, host, "export")

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY, label TEXT, qty INTEGER)")
	run_done(t, store, "INSERT INTO item (id, label, qty) VALUES (1, 'it''s ok', 3)")
	run_done(t, store, "INSERT INTO item (id, label, qty) VALUES (2, 'plain', 0)")
	text := db.export_sql(host, context.allocator)
	defer delete(text)
	testing.expect(t, strings_contains(text, "INSERT INTO item VALUES (1, 'it''s ok', 3);"))
	testing.expect(t, strings_contains(text, "INSERT INTO item VALUES (2, 'plain', 0);"))
	testing.expect(t, !strings_contains(text, "_meta"))
}

@(test)
test_client_registry :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "clients")
	if store == nil do return
	defer destroy_host(store, host, "clients")

	testing.expect_value(t, db.host_client_count(host), 0)
	testing.expect(t, db.host_client_connect(host, 1))
	testing.expect(t, db.host_client_connect(host, 1))
	testing.expect_value(t, db.host_client_count(host), 1)

	host.max_clients = 2
	testing.expect(t, db.host_client_connect(host, 2))
	testing.expect(t, !db.host_client_connect(host, 3))
	testing.expect(t, !db.host_client_connected(host, 3))

	db.host_client_disconnect(host, 1)
	testing.expect(t, !db.host_client_connected(host, 1))
	testing.expect(t, db.host_client_connect(host, 3))
	testing.expect_value(t, db.host_client_count(host), 2)

	// Outbound accounting enables a backpressure policy in the transport.
	testing.expect_value(t, db.host_client_bytes(host, 3), u64(0))
	query_one := db.wire_encode_query("SELECT 1", nil)
	defer delete(query_one)
	reply := db.wire_request_owned(host, query_one, 3)
	defer delete(reply)
	testing.expect(t, len(reply) > 0)
	testing.expect(t, db.host_client_bytes(host, 3) > 0)
	testing.expect(t, db.host_client_over_budget(host, 3, 0))
	testing.expect(t, !db.host_client_over_budget(host, 3, 1 << 20))

	request, _, dropped_parse_err_3565 := db.http_parse_request(http_bytes_of("GET /metrics HTTP/1.1\r\n\r\n"))
	defer db.http_request_destroy(&request)
	defer db.error_free(&dropped_parse_err_3565)
	response := db.http_handle(host, request)
	defer delete(response)
	testing.expect(t, strings_contains(string(response), "miraidb_clients 2"))
}

@(test)
test_jwt_tokens :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "jwt")
	if store == nil do return
	defer destroy_host(store, host, "jwt")

	identity: db.Identity
	identity[0] = 3
	identity[31] = 4
	host.now_us = i64(5_000_000)

	token := db.host_issue_jwt(host, identity, 60_000_000)
	defer delete(token)
	resolved, valid := db.host_authenticate(host, token)
	testing.expect(t, valid)
	testing.expect_value(t, resolved[0], u8(3))
	testing.expect_value(t, resolved[31], u8(4))

	tampered := fmt.aprintf("%sA", token)
	defer delete(tampered)
	_, tampered_ok := db.host_authenticate(host, tampered)
	testing.expect(t, !tampered_ok)

	host.now_us = i64(5_000_000) + 120_000_000
	_, expired_ok := db.host_authenticate(host, token)
	testing.expect(t, !expired_ok)

	host.now_us = i64(5_000_000)
	response := wire_ask(host, db.wire_encode_auth(token))
	defer delete(response)
	check, check_ok := db.host_authenticate(host, token)
	testing.expectf(t, check_ok, "direct auth failed before wire (token len %d, now %d)", len(token), host.now_us)
	testing.expect_value(t, check[0], u8(3))
	testing.expect_value(t, wire_kind(response), db.WIRE_RESULT)
}

@(test)
test_show_indexes :: proc(t: ^testing.T) {
	store := fresh_db(t, "show_indexes")
	if store == nil do return
	defer cleanup_db(store, "show_indexes")

	run_done(t, store, "CREATE TABLE thing (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE INDEX thing_name ON thing (name)")
	result := run(t, store, "SHOW indexes")
	defer db.sql_result_destroy(&result)
	if testing.expect(t, len(result.rows) >= 1) {
		found := false
		for row in result.rows {
			if row[1].s == "thing_name" {
				found = true
				testing.expect_value(t, row[2].s, "name")
			}
		}
		testing.expect(t, found)
	}
}

@(test)
test_semijoins :: proc(t: ^testing.T) {
	store := fresh_db(t, "semijoins")
	if store == nil do return
	defer cleanup_db(store, "semijoins")

	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO a (id, v) VALUES (1, 10), (2, 20), (3, 30)")
	run_done(t, store, "INSERT INTO b (id, v) VALUES (1, 20), (2, 40)")

	in_result := run(t, store, "SELECT id FROM a WHERE v IN (SELECT v FROM b) ORDER BY id")
	defer db.sql_result_destroy(&in_result)
	testing.expect_value(t, len(in_result.rows), 1)
	testing.expect_value(t, in_result.rows[0][0].i, i64(2))

	excluded := run(t, store, "SELECT id FROM a WHERE v NOT IN (SELECT v FROM b) ORDER BY id")
	defer db.sql_result_destroy(&excluded)
	testing.expect_value(t, len(excluded.rows), 2)
	testing.expect_value(t, excluded.rows[0][0].i, i64(1))
	testing.expect_value(t, excluded.rows[1][0].i, i64(3))

	exists := run(t, store, "SELECT id FROM a WHERE EXISTS (SELECT id FROM b WHERE v = 20) ORDER BY id")
	defer db.sql_result_destroy(&exists)
	testing.expect_value(t, len(exists.rows), 3)

	missing := run(t, store, "SELECT id FROM a WHERE NOT EXISTS (SELECT id FROM b WHERE v = 999)")
	defer db.sql_result_destroy(&missing)
	testing.expect_value(t, len(missing.rows), 3)

	scalar := run(t, store, "SELECT id FROM a WHERE v = (SELECT min(v) FROM b)")
	defer db.sql_result_destroy(&scalar)
	testing.expect_value(t, len(scalar.rows), 1)
	testing.expect_value(t, scalar.rows[0][0].i, i64(2))
}

@(test)
test_select_without_from :: proc(t: ^testing.T) {
	store := fresh_db(t, "no_from")
	if store == nil do return
	defer cleanup_db(store, "no_from")

	sum := run(t, store, "SELECT 1 + 2 AS s")
	defer db.sql_result_destroy(&sum)
	testing.expect_value(t, len(sum.rows), 1)
	testing.expect_value(t, sum.rows[0][0].i, i64(3))

	text := run(t, store, "SELECT concat('a', 'b') AS joined")
	defer db.sql_result_destroy(&text)
	testing.expect_value(t, text.rows[0][0].s, "ab")

	casted := run(t, store, "SELECT CAST('12' AS INTEGER) AS n")
	defer db.sql_result_destroy(&casted)
	testing.expect_value(t, casted.rows[0][0].i, i64(12))
}

@(test)
test_system_tables :: proc(t: ^testing.T) {
	store := fresh_db(t, "system_tables")
	if store == nil do return
	defer cleanup_db(store, "system_tables")

	run_done(t, store, "CREATE TABLE thing (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER DEFAULT 0)")
	run_done(t, store, "CREATE INDEX thing_name ON thing (name)")

	tables := run(t, store, "SELECT name FROM _tables ORDER BY name")
	testing.expect_value(t, len(tables.rows), 1)
	testing.expect_value(t, tables.rows[0][0].s, "thing")

	counts := run(t, store, "SELECT name, type, not_null, default FROM _columns")
	testing.expect_value(t, len(counts.rows), 3)
	testing.expect_value(t, counts.rows[0][0].s, "id")
	testing.expect_value(t, counts.rows[1][0].s, "name")
	testing.expect_value(t, counts.rows[1][1].s, "TEXT")
	testing.expect_value(t, counts.rows[1][2].b, true)
	testing.expect_value(t, counts.rows[2][0].s, "qty")
	testing.expect_value(t, counts.rows[2][3].s, "0")

	indexes := run(t, store, "SELECT name, columns FROM _indexes WHERE name = 'thing_name'")
	testing.expect_value(t, len(indexes.rows), 1)
	testing.expect_value(t, indexes.rows[0][0].s, "thing_name")
	testing.expect_value(t, indexes.rows[0][1].s, "name")

	// Filters and projections work because the rows go through the normal pipeline.
	picked := run(t, store, "SELECT name FROM _columns WHERE not_null = true AND type = 'TEXT'")
	testing.expect_value(t, len(picked.rows), 1)
	testing.expect_value(t, picked.rows[0][0].s, "name")

	// Internal tables stay hidden.
	hidden := run(t, store, "SELECT count(*) FROM _tables WHERE name = '_meta'")
	testing.expect_value(t, hidden.rows[0][0].i, i64(0))
	db.sql_result_destroy(&tables)
	db.sql_result_destroy(&counts)
	db.sql_result_destroy(&indexes)
	db.sql_result_destroy(&picked)
	db.sql_result_destroy(&hidden)

	// A filter that rejects most catalog rows frees their source slices: those
	// come from the statement allocator, not from the transaction arena.
	rejected := run(t, store, "SELECT name FROM _columns WHERE type = 'NOPE'")
	testing.expect_value(t, len(rejected.rows), 0)
	db.sql_result_destroy(&rejected)
}

@(test)
test_alter_table_add_column :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "alter")
	defer delete(path)
	defer os.remove_all(path)
	store := fresh_db(t, "alter")
	if store == nil do return

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "INSERT INTO t (id, name) VALUES (1, 'a'), (2, 'b')")
	alter := run(t, store, "ALTER TABLE t ADD COLUMN qty INTEGER NOT NULL DEFAULT 7")
	defer db.sql_result_destroy(&alter)
	testing.expect_value(t, alter.kind, db.Sql_Result_Kind.Ack)

	after := run(t, store, "SELECT id, qty FROM t ORDER BY id")
	defer db.sql_result_destroy(&after)
	testing.expect_value(t, len(after.rows), 2)
	testing.expect_value(t, after.rows[0][1].i, i64(7))
	testing.expect_value(t, after.rows[1][1].i, i64(7))

	run_done(t, store, "INSERT INTO t (id, name) VALUES (3, 'c')")
	fresh := scalar(t, store, "SELECT qty FROM t WHERE id = 3")
	testing.expect_value(t, fresh.i, i64(7))

	dropped_result_3794, duplicate := db.sql_execute(store, "ALTER TABLE t ADD COLUMN qty INTEGER")
	defer db.error_free(&duplicate)
	defer db.sql_result_destroy(&dropped_result_3794)
	testing.expect(t, !db.error_ok(duplicate))

	// The change is part of the log: reopening replays it.
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	replayed := scalar(t, reopened, "SELECT qty FROM t WHERE id = 1")
	testing.expect_value(t, replayed.i, i64(7))
	columns := run(t, reopened, "SELECT name FROM _columns WHERE table = 't'")
	defer db.sql_result_destroy(&columns)
	testing.expect_value(t, len(columns.rows), 3)
}

@(test)
test_create_or_replace_view :: proc(t: ^testing.T) {
	store := fresh_db(t, "replace_view")
	if store == nil do return
	defer cleanup_db(store, "replace_view")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO t (id) VALUES (1), (2)")
	run_done(t, store, "CREATE VIEW v AS SELECT id FROM t")

	total := scalar(t, store, "SELECT count(*) FROM v")
	testing.expect_value(t, total.i, i64(2))

	dropped_result_3822, duplicate := db.sql_execute(store, "CREATE VIEW v AS SELECT id FROM t WHERE id = 1")
	defer db.error_free(&duplicate)
	defer db.sql_result_destroy(&dropped_result_3822)
	testing.expect(t, !db.error_ok(duplicate))

	run_done(t, store, "CREATE OR REPLACE VIEW v AS SELECT id FROM t WHERE id = 2")
	after := run(t, store, "SELECT id FROM v")
	defer db.sql_result_destroy(&after)
	testing.expect_value(t, len(after.rows), 1)
	testing.expect_value(t, after.rows[0][0].i, i64(2))

	// A replaced view persists as a normal row change in _view.
	stored := scalar(t, store, "SELECT sql FROM _view WHERE name = 'v'")
	testing.expect(t, strings_contains(stored.s, "id = 2"))
}

@(test)
test_client_catalog :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "client_catalog")
	if store == nil do return
	defer destroy_host(store, host, "client_catalog")

	identity: db.Identity
	identity[0] = 9
	host.now_us = i64(2_000_000)
	testing.expect(t, db.error_ok(db.host_register_client(host, identity, "laptop")))
	name, created, found := db.host_client_catalog(host, identity)
	testing.expect(t, found)
	testing.expect_value(t, name, "laptop")
	testing.expect_value(t, created, i64(2_000_000))
	testing.expect_value(t, db.host_client_count_catalog(host), 1)

	testing.expect(t, db.error_ok(db.host_register_client(host, identity, "desktop")))
	name, _, _ = db.host_client_catalog(host, identity)
	testing.expect_value(t, name, "desktop")
	testing.expect_value(t, db.host_client_count_catalog(host), 1)
}

@(test)
test_wire_request_limit :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "wire_limit")
	if store == nil do return
	defer destroy_host(store, host, "wire_limit")

	oversized := make([]u8, db.WIRE_MAX_REQUEST + 1)
	defer delete(oversized)
	response := db.wire_request(host, oversized)
	defer delete(response)
	testing.expect_value(t, wire_kind(response), db.WIRE_ERROR)

	small := wire_ask(host, db.wire_encode_query("SELECT 1", nil))
	defer delete(small)
	testing.expect_value(t, wire_kind(small), db.WIRE_RESULT)
}

// expect_ordering checks compare, equality and hashing for one pair of values.
expect_ordering :: proc(t: ^testing.T, label: string, a, b: db.Value) {
	order, ok := db.value_compare(a, b)
	testing.expectf(t, ok, "%s: compare rejected", label)
	testing.expectf(t, order == .Less, "%s: expected a < b", label)
	testing.expectf(t, db.value_equal(a, a), "%s: a = a failed", label)
	testing.expectf(t, !db.value_equal(a, b), "%s: a = b matched", label)
	testing.expectf(t, db.value_hash(a) == db.value_hash(a), "%s: hash is not stable", label)
	testing.expectf(t, db.value_hash(a) != db.value_hash(b), "%s: hashes collide", label)
}

@(test)
test_value_order_and_hash :: proc(t: ^testing.T) {
	small_uuid: db.Uuid
	small_uuid[0] = 1
	large_uuid: db.Uuid
	large_uuid[0] = 2
	small_identity: db.Identity
	small_identity[0] = 1
	large_identity: db.Identity
	large_identity[0] = 2

	expect_ordering(t, "bool", db.value_bool(false), db.value_bool(true))
	expect_ordering(t, "int", db.value_int(1), db.value_int(2))
	expect_ordering(t, "uint", db.value_uint(1), db.value_uint(2))
	expect_ordering(t, "float", db.value_float(1.5), db.value_float(2.5))
	expect_ordering(t, "string", db.value_string("a"), db.value_string("b"))
	expect_ordering(t, "bytes", db.value_bytes([]u8{1, 2}), db.value_bytes([]u8{1, 3}))
	expect_ordering(t, "timestamp", db.value_timestamp(1), db.value_timestamp(2))
	expect_ordering(t, "uuid", db.value_uuid(small_uuid), db.value_uuid(large_uuid))
	expect_ordering(t, "duration", db.value_duration(1), db.value_duration(2))
	expect_ordering(t, "identity", db.value_identity(small_identity), db.value_identity(large_identity))
	expect_ordering(t, "connection", db.value_connection(1), db.value_connection(2))
	expect_ordering(t, "int128", db.value_int128(1), db.value_int128(2))
	expect_ordering(t, "uint128", db.value_uint128(1), db.value_uint128(2))
	expect_ordering(
		t,
		"array",
		db.value_array([]db.Value{db.value_int(1)}),
		db.value_array([]db.Value{db.value_int(2)}),
	)
	expect_ordering(
		t,
		"product",
		db.value_product([]db.Value{db.value_int(1), db.value_bool(false)}),
		db.value_product([]db.Value{db.value_int(1), db.value_bool(true)}),
	)

	// Numeric kinds compare across kinds.
	order, ok := db.value_compare(db.value_int(2), db.value_float(2.5))
	testing.expect(t, ok)
	testing.expect_value(t, order, .Less)
	testing.expect(t, db.value_equal(db.value_int(2), db.value_float(2.0)))
	testing.expect(t, db.value_equal(db.value_int(2), db.value_uint(2)))
}

@(test)
test_procedure_logs_and_timers :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "proc_logs")
	if store == nil do return
	defer destroy_host(store, host, "proc_logs")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	handler := proc(ctx: ^db.Procedure_Ctx, args: []db.Value) -> db.Error {
		db.procedure_log(ctx, "phase one")
		dropped_result_3986, first := db.sql_execute_in_tx(ctx.tx, "INSERT INTO t (id) VALUES (1)")
		defer db.error_free(&first)
		defer db.sql_result_destroy(&dropped_result_3986)
		if !db.error_ok(first) do return first
		if commit_err := db.procedure_commit(ctx); !db.error_ok(commit_err) do return commit_err
		db.procedure_log(ctx, "phase two")
		if db.procedure_now_us(ctx) == 0 do return db.errf(.Invalid_Argument, "no timer")
		dropped_result_3991, second := db.sql_execute_in_tx(ctx.tx, "INSERT INTO t (id) VALUES (2)")
		defer db.error_free(&second)
		defer db.sql_result_destroy(&dropped_result_3991)
		return second
	}
	host.now_us = i64(3_000_000)
	testing.expect(t, db.error_ok(db.host_register_procedure(host, "logged", nil, handler)))
	testing.expect(t, db.error_ok(db.host_call_procedure(host, "logged", nil)))

	logs := db.host_procedure_logs(host)
	testing.expect_value(t, len(logs), 2)
	testing.expect_value(t, logs[0], "phase one")
	testing.expect_value(t, logs[1], "phase two")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))
}

@(test)
test_module_abi :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "modules")
	if store == nil do return
	defer destroy_host(store, host, "modules")

	run_done(t, store, "CREATE TABLE ledger (id INTEGER PRIMARY KEY, amount INTEGER)")

	counting := proc(h: ^db.Host, reducer: string, args: []db.Value) -> (db.Value, db.Error) {
		if reducer != "deposit" do return {}, db.errf(.Invalid_Argument, "unknown reducer %s", reducer)
		dropped_result_4015, insert_err := db.sql_execute(h.store, "INSERT INTO ledger (id, amount) VALUES (1, 100)")
		defer db.error_free(&insert_err)
		defer db.sql_result_destroy(&dropped_result_4015)
		if !db.error_ok(insert_err) do return {}, insert_err
		return db.value_string("deposited"), db.ERROR_NONE
	}
	module := db.Module {
		abi_version = db.MODULE_ABI_VERSION,
		name        = "bank",
		call        = counting,
	}
	testing.expect(t, db.error_ok(db.host_register_module(host, module)))
	testing.expect(t, db.error_ok(db.host_register_module(host, db.Module{abi_version = db.MODULE_ABI_VERSION, name = "audit"})))

	names := db.host_module_names(host, context.allocator)
	defer delete(names)
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "audit")
	testing.expect_value(t, names[1], "bank")

	duplicate := db.host_register_module(host, module)
	defer db.error_free(&duplicate)
	testing.expect(t, !db.error_ok(duplicate))
	bad_abi := module
	bad_abi.name = "bad"
	bad_abi.abi_version = 99
	rejected := db.host_register_module(host, bad_abi)
	defer db.error_free(&rejected)
	testing.expect(t, !db.error_ok(rejected))

	result, call_err := db.host_call_module(host, "bank", "deposit", []db.Value{db.value_int(100)})
	testing.expect(t, db.error_ok(call_err))
	testing.expect_value(t, result.s, "deposited")
	testing.expect_value(t, scalar(t, store, "SELECT amount FROM ledger WHERE id = 1").i, i64(100))

	_, unknown := db.host_call_module(host, "ghost", "deposit", nil)
	defer db.error_free(&unknown)
	testing.expect(t, !db.error_ok(unknown))
	_, bad_reducer := db.host_call_module(host, "bank", "withdraw", nil)
	defer db.error_free(&bad_reducer)
	testing.expect(t, !db.error_ok(bad_reducer))

	db.host_shutdown_modules(host)
}

@(test)
test_module_data_access :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "module_data")
	if store == nil do return
	defer destroy_host(store, host, "module_data")

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT)")
	ids: [3]db.Row_Id
	for index in 1 ..= 3 {
		id, insert_err := db.module_insert(
			host,
			"item",
			[]db.Value{db.value_int(i64(index)), db.value_string("row")},
		)
		testing.expect(t, db.error_ok(insert_err))
		ids[index - 1] = id
	}

	scan, scan_err := db.module_scan_begin(host, "item")
	testing.expect(t, db.error_ok(scan_err))
	seen := 0
	for {
		row, more := db.module_scan_next(scan)
		if !more do break
		seen += 1
		testing.expect_value(t, row.values[0].i, i64(seen))
	}
	db.module_scan_end(scan)
	testing.expect_value(t, seen, 3)

	testing.expect(t, db.error_ok(db.module_update(host, "item", ids[1], []db.Value{db.value_int(2), db.value_string("changed")})))
	testing.expect_value(t, scalar(t, store, "SELECT name FROM item WHERE id = 2").s, "changed")

	testing.expect(t, db.error_ok(db.module_delete(host, "item", ids[0])))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM item").i, i64(2))

	removed, range_err := db.module_delete_range(host, "item", ids[1], ids[1])
	testing.expect(t, db.error_ok(range_err))
	testing.expect_value(t, removed, 1)
	testing.expect_value(t, scalar(t, store, "SELECT id FROM item").i, i64(3))
}

@(test)
test_module_identity :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "module_identity")
	if store == nil do return
	defer destroy_host(store, host, "module_identity")

	identity: db.Identity
	identity[0] = 5
	identity[31] = 6
	db.store_set_identity(store, identity)
	testing.expect_value(t, db.module_identity(host)[0], u8(5))
	testing.expect_value(t, db.module_identity(host)[31], u8(6))

	host.now_us = i64(1_000_000)
	token := db.host_issue_jwt(host, identity, 60_000_000)
	defer delete(token)
	resolved, valid := db.module_authenticate(host, token)
	testing.expect(t, valid)
	testing.expect_value(t, resolved[0], u8(5))
	testing.expect_value(t, resolved[31], u8(6))
}

@(test)
test_ephemeral_tables :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "ephemeral")
	defer delete(path)
	defer os.remove_all(path)
	store := fresh_db(t, "ephemeral")
	if store == nil do return

	run_done(t, store, "CREATE TEMPORARY TABLE scratch (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "INSERT INTO scratch (id, v) VALUES (1, 'a'), (2, 'b')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM scratch").i, i64(2))

	// Temporary rows survive their own commit in this session.
	testing.expect_value(t, store.commit_seq, u64(0))
	closed := db.tx_begin_write(store)
	testing.expect(t, db.error_ok(db.tx_commit(closed)))
	testing.expect_value(t, store.commit_seq, u64(0))

	// A durable table makes a logged commit.
	run_done(t, store, "CREATE TABLE durable (id INTEGER PRIMARY KEY)")
	testing.expect(t, store.commit_seq >= 1)

	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)

	dropped_result_4100, missing := db.sql_execute(reopened, "SELECT * FROM scratch")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_4100)
	testing.expect(t, !db.error_ok(missing))
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM durable").i, i64(0))
}

@(test)
test_transaction_read_set :: proc(t: ^testing.T) {
	store := fresh_db(t, "read_set")
	if store == nil do return
	defer cleanup_db(store, "read_set")

	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO a (id) VALUES (1)")
	start_seq := store.commit_seq

	tx := db.tx_begin_write(store)
	testing.expect_value(t, db.tx_read_seq(tx), start_seq)
	read_result, read_err := db.sql_execute_in_tx(tx, "SELECT id FROM a")
	defer db.sql_result_destroy(&read_result)
	testing.expect(t, db.error_ok(read_err))
	dropped_result_4171, write_err := db.sql_execute_in_tx(tx, "INSERT INTO b (id) VALUES (1)")
	defer db.error_free(&write_err)
	defer db.sql_result_destroy(&dropped_result_4171)
	testing.expect(t, db.error_ok(write_err))
	tables := db.tx_read_tables(tx, context.allocator)
	defer delete(tables)
	found_a, found_b := false, false
	for name in tables {
		if name == "a" do found_a = true
		if name == "b" do found_b = true
	}
	testing.expect(t, found_a)
	testing.expect(t, found_b)
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	testing.expect_value(t, store.commit_seq, start_seq + 1)

	// A new transaction starts from the new offset.
	next := db.tx_begin_read(store)
	testing.expect_value(t, db.tx_read_seq(next), start_seq + 1)
	db.tx_end(next)
}

@(test)
test_checksum_modes :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "checksum")
	defer delete(path)
	defer os.remove_all(path)
	os.remove_all(path)
	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false, checksum = db.Checksum.None})
	testing.expect(t, db.error_ok(open_err))
	testing.expect_value(t, store.log.checksum, db.Checksum.None)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO t (id) VALUES (1)")
	db.store_close(store)

	// The header records the algorithm, so a default open still replays.
	reopened, reopen_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(reopen_err))
	testing.expect_value(t, reopened.log.checksum, db.Checksum.None)
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM t").i, i64(1))
	db.store_close(reopened)

	defaulted := fresh_db(t, "checksum_default")
	if defaulted != nil {
		testing.expect_value(t, defaulted.log.checksum, db.Checksum.CRC32C)
		cleanup_db(defaulted, "checksum_default")
	}
}

@(test)
test_event_tables :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "events")
	if store == nil do return
	defer destroy_host(store, host, "events")

	run_done(t, store, "CREATE EVENT TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT)")
	run_done(t, store, "INSERT INTO audit (message) VALUES ('one'), ('two')")

	// Append-only: updates, deletes and truncates are rejected.
	dropped_result_4176, update_err := db.sql_execute(store, "UPDATE audit SET message = 'x'")
	defer db.error_free(&update_err)
	defer db.sql_result_destroy(&dropped_result_4176)
	testing.expect(t, !db.error_ok(update_err))
	dropped_result_4178, delete_err := db.sql_execute(store, "DELETE FROM audit")
	defer db.error_free(&delete_err)
	defer db.sql_result_destroy(&dropped_result_4178)
	testing.expect(t, !db.error_ok(delete_err))
	dropped_result_4164, truncate_err := db.sql_execute(store, "TRUNCATE TABLE audit")
	defer db.error_free(&truncate_err)
	defer db.sql_result_destroy(&dropped_result_4164)
	testing.expect(t, !db.error_ok(truncate_err))

	// The outbox cursor reads only newer rows.
	rows, read_err := db.events_read(host, "audit", db.Row_Id(0), 0, context.temp_allocator)
	testing.expect(t, db.error_ok(read_err))
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0].values[1].s, "one")

	after, after_err := db.events_read(host, "audit", rows[0].id + 1, 1, context.temp_allocator)
	testing.expect(t, db.error_ok(after_err))
	testing.expect_value(t, len(after), 1)
	testing.expect_value(t, after[0].values[1].s, "two")

	// SHOW events lists the table; ordinary tables are not event tables.
	run_done(t, store, "CREATE TABLE ordinary (id INTEGER PRIMARY KEY)")
	shown := run(t, store, "SHOW events")
	defer db.sql_result_destroy(&shown)
	testing.expect_value(t, len(shown.rows), 1)
	testing.expect_value(t, shown.rows[0][0].s, "audit")
}

@(test)
test_row_quota :: proc(t: ^testing.T) {
	store := fresh_db(t, "quota")
	if store == nil do return
	defer cleanup_db(store, "quota")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO t (id) VALUES (1), (2), (3)")

	testing.expect_value(t, db.store_row_quota(store), u64(0))
	db.store_set_row_quota(store, 2)
	testing.expect_value(t, db.store_row_quota(store), u64(2))

	dropped_result_4199, over := db.sql_execute(store, "SELECT id FROM t")
	defer db.error_free(&over)
	defer db.sql_result_destroy(&dropped_result_4199)
	testing.expect(t, !db.error_ok(over))
	testing.expect_value(t, over.kind, db.Error_Kind.Quota_Exceeded)

	// A LIMIT below the quota still works.
	small := run(t, store, "SELECT id FROM t LIMIT 1")
	defer db.sql_result_destroy(&small)
	testing.expect_value(t, len(small.rows), 1)

	// A window query reaches the same refusal with its sources handed to
	// window_sources instead of the row loop. Both shapes used to free a row a
	// second time, which a release build reports as exit 116 with no message; the
	// gate that catches it is `scripts/shell_smoke.py` ("row quota refuses").
	dropped_result_4212, window := db.sql_execute(store, "SELECT row_number() OVER () FROM t")
	defer db.error_free(&window)
	defer db.sql_result_destroy(&dropped_result_4212)
	testing.expect_value(t, window.kind, db.Error_Kind.Quota_Exceeded)

	db.store_set_row_quota(store, 0)
	full := run(t, store, "SELECT id FROM t")
	defer db.sql_result_destroy(&full)
	testing.expect_value(t, len(full.rows), 3)
}

@(test)
test_view_parameters :: proc(t: ^testing.T) {
	store := fresh_db(t, "view_params")
	if store == nil do return
	defer cleanup_db(store, "view_params")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO t (id) VALUES (1), (2), (3)")
	run_done(t, store, "CREATE VIEW above AS SELECT id FROM t WHERE id > ?")

	two := run(t, store, "SELECT id FROM above(1) ORDER BY id")
	defer db.sql_result_destroy(&two)
	testing.expect_value(t, len(two.rows), 2)
	testing.expect_value(t, two.rows[0][0].i, i64(2))

	one := run(t, store, "SELECT count(*) FROM above(2)")
	defer db.sql_result_destroy(&one)
	testing.expect_value(t, one.rows[0][0].i, i64(1))

	// Parameters bind through a parameterised statement as well.
	bound := run_params(t, store, "SELECT count(*) FROM above(?)", []db.Value{db.value_int(0)})
	defer db.sql_result_destroy(&bound)
	testing.expect_value(t, bound.rows[0][0].i, i64(3))

	// A normal table rejects parameters.
	dropped_result_4245, bad := db.sql_execute(store, "SELECT * FROM t(1)")
	defer db.error_free(&bad)
	defer db.sql_result_destroy(&dropped_result_4245)
	testing.expect(t, !db.error_ok(bad))
}

module_shutdowns := 0

module_shutdown_counter :: proc(host: ^db.Host) {
	module_shutdowns += 1
}

@(test)
test_module_hot_swap :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "module_swap")
	if store == nil do return
	defer destroy_host(store, host, "module_swap")

	version_one := proc(h: ^db.Host, reducer: string, args: []db.Value) -> (db.Value, db.Error) {
		return db.value_string("one"), db.ERROR_NONE
	}
	version_two := proc(h: ^db.Host, reducer: string, args: []db.Value) -> (db.Value, db.Error) {
		return db.value_string("two"), db.ERROR_NONE
	}
	module_shutdowns = 0
	first := db.Module {
		abi_version = db.MODULE_ABI_VERSION,
		name        = "shop",
		call        = version_one,
		shutdown    = module_shutdown_counter,
	}
	testing.expect(t, db.error_ok(db.host_register_module(host, first)))
	before, before_err := db.host_call_module(host, "shop", "ping", nil)
	testing.expect(t, db.error_ok(before_err))
	testing.expect_value(t, before.s, "one")

	second := first
	second.call = version_two
	testing.expect(t, db.error_ok(db.host_swap_module(host, second)))
	after, after_err := db.host_call_module(host, "shop", "ping", nil)
	testing.expect(t, db.error_ok(after_err))
	testing.expect_value(t, after.s, "two")
	testing.expect_value(t, module_shutdowns, 1)

	// A swap for an unknown module and one with a bad ABI are rejected.
	ghost := second
	ghost.name = "ghost"
	testing.expect(t, !db.error_drop(db.host_swap_module(host, ghost)))
	bad_abi := second
	bad_abi.abi_version = 99
	testing.expect(t, !db.error_drop(db.host_swap_module(host, bad_abi)))
	still, still_err := db.host_call_module(host, "shop", "ping", nil)
	testing.expect(t, db.error_ok(still_err))
	testing.expect_value(t, still.s, "two")
}

@(test)
test_byte_cursors :: proc(t: ^testing.T) {
	sink: db.Byte_Sink
	defer db.bytes_sink_destroy(&sink)
	db.bytes_sink_write_u32(&sink, 7)
	db.bytes_sink_write_u64(&sink, 1 << 40)
	db.bytes_sink_write_string(&sink, "hello")
	db.bytes_sink_write(&sink, []u8{1, 2, 3})
	testing.expect_value(t, len(db.bytes_sink_bytes(&sink)), 4 + 8 + 4 + 5 + 3)

	source := db.bytes_source(db.bytes_sink_bytes(&sink))
	count, count_ok := db.bytes_source_read_u32(&source)
	testing.expect(t, count_ok)
	testing.expect_value(t, count, u32(7))
	big, big_ok := db.bytes_source_read_u64(&source)
	testing.expect(t, big_ok)
	testing.expect_value(t, big, u64(1 << 40))
	text, text_ok := db.bytes_source_read_string(&source, context.temp_allocator)
	testing.expect(t, text_ok)
	testing.expect_value(t, text, "hello")
	_, tail_ok := db.bytes_source_read_u32(&source)
	testing.expect(t, !tail_ok)
	testing.expect_value(t, db.bytes_source_remaining(&source), 3)
	rest := db.bytes_source_read_all(&source, context.allocator)
	defer delete(rest)
	testing.expect_value(t, len(rest), 3)
	testing.expect_value(t, rest[2], u8(3))
	testing.expect_value(t, db.bytes_source_remaining(&source), 0)

	// A truncated frame is rejected instead of over-reading.
	short := db.bytes_source([]u8{5, 0, 0, 0, 'a'})
	_, short_ok := db.bytes_source_read_string(&short, context.allocator)
	testing.expect(t, !short_ok)
}

http_fake_ok :: proc(ctx: rawptr, request: []u8, alloc: mem.Allocator) -> ([]u8, db.Error) {
	if !strings_contains(string(request), "GET /greet HTTP/1.1") {
		return nil, db.errf(.Invalid_Argument, "unexpected request line")
	}
	if !strings_contains(string(request), "Host: example.test") {
		return nil, db.errf(.Invalid_Argument, "missing host header")
	}
	raw := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
	return transmute([]u8)raw, db.ERROR_NONE
}

http_fake_not_found :: proc(ctx: rawptr, request: []u8, alloc: mem.Allocator) -> ([]u8, db.Error) {
	raw := "HTTP/1.0 404 Not Found\r\n\r\nmissing"
	return transmute([]u8)raw, db.ERROR_NONE
}

http_fake_garbage :: proc(ctx: rawptr, request: []u8, alloc: mem.Allocator) -> ([]u8, db.Error) {
	raw := "nonsense"
	return transmute([]u8)raw, db.ERROR_NONE
}

@(test)
test_http_client :: proc(t: ^testing.T) {
	response, err := db.http_get_via(http_fake_ok, nil, "http://example.test/greet", context.allocator)
	testing.expect(t, db.error_ok(err))
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body), "hello")

	missing, missing_err := db.http_get_via(http_fake_not_found, nil, "http://example.test/nope", context.allocator)
	testing.expect(t, db.error_ok(missing_err))
	testing.expect_value(t, missing.status, 404)
	testing.expect_value(t, string(missing.body), "missing")

	_, scheme := db.http_get_via(http_fake_ok, nil, "https://example.test/greet", context.allocator)
	defer db.error_free(&scheme)
	testing.expect(t, !db.error_ok(scheme))
	_, malformed := db.http_get_via(http_fake_garbage, nil, "http://example.test/greet", context.allocator)
	defer db.error_free(&malformed)
	testing.expect(t, !db.error_ok(malformed))
	_, no_transport := db.http_get_via(nil, nil, "http://example.test/", context.allocator)
	defer db.error_free(&no_transport)
	testing.expect(t, !db.error_ok(no_transport))

	// A body shorter than Content-Length is rejected.
	short_text := "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nab"
	short := transmute([]u8)short_text
	_, short_err := db.http_parse_response(short)
	defer db.error_free(&short_err)
	testing.expect(t, !db.error_ok(short_err))
}

simulation_tick :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
	return db.reducer_sql(ctx, "INSERT INTO ticks (v) VALUES (1)")
}

@(test)
test_deterministic_simulation :: proc(t: ^testing.T) {
	run_script :: proc(t: ^testing.T, name: string) -> (i64, i64, int) {
		store, host := fresh_host(t, name)
		if store == nil do return 0, 0, 0
		defer destroy_host(store, host, name)
		run_done(t, store, "CREATE TABLE ticks (v INTEGER)")
		testing.expect(t, db.error_ok(db.host_register(host, "tick", nil, simulation_tick)))
		sim := db.simulation_init(host, i64(1_000_000_000))
		_, schedule_err := db.host_schedule_every(host, "tick", i64(10_000_000), nil)
		testing.expect(t, db.error_ok(schedule_err))
		_, run_err := db.simulation_run_until(&sim, i64(1_035_000_000), i64(1_000_000))
		testing.expect(t, db.error_ok(run_err))
		count := scalar(t, store, "SELECT count(*) FROM ticks").i
		total := scalar(t, store, "SELECT sum(v) FROM ticks").i
		return count, total, sim.ran
	}

	first_count, first_total, first_ran := run_script(t, "sim_a")
	second_count, second_total, second_ran := run_script(t, "sim_b")
	testing.expect_value(t, first_ran, 3)
	testing.expect_value(t, first_count, i64(3))
	testing.expect_value(t, first_total, i64(3))
	testing.expect_value(t, second_count, first_count)
	testing.expect_value(t, second_total, first_total)
	testing.expect_value(t, second_ran, first_ran)

	// Time cannot move backwards.
	store, host := fresh_host(t, "sim_clock")
	if store == nil do return
	defer destroy_host(store, host, "sim_clock")
	sim := db.simulation_init(host, i64(5_000))
	_, before := db.simulation_advance(&sim, -1)
	defer db.error_free(&before)
	testing.expect(t, !db.error_ok(before))
	testing.expect_value(t, db.simulation_now(&sim), i64(5_000))
}

@(test)
test_commit_time :: proc(t: ^testing.T) {
	store := fresh_db(t, "commit_time")
	if store == nil do return
	defer cleanup_db(store, "commit_time")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	first := db.store_last_commit_us(store)
	testing.expect(t, first > 0)
	run_done(t, store, "INSERT INTO t (id) VALUES (1)")
	second := db.store_last_commit_us(store)
	testing.expect(t, second >= first)
}


sdk_route :: proc(ctx: rawptr, request: []u8, alloc: mem.Allocator) -> ([]u8, db.Error) {
	host := (^db.Host)(ctx)
	parsed, _, parse_err := db.http_parse_request(request)
	defer db.http_request_destroy(&parsed)
	// A parse error is handed to the caller, which frees it; freeing it here
	// too returned an error whose message was already gone.
	if !db.error_ok(parse_err) do return nil, parse_err
	if token, has_token := db.http_bearer_token(request); has_token {
		if identity, valid := db.host_authenticate(host, token); valid {
			db.store_set_identity(host.store, identity)
		}
	}
	return db.http_handle(host, parsed), db.ERROR_NONE
}

sdk_insert :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
	return db.reducer_sql(ctx, "INSERT INTO t (id) VALUES (2)")
}

@(test)
test_client_sdk :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "sdk")
	if store == nil do return
	defer destroy_host(store, host, "sdk")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO t (id) VALUES (1)")
	testing.expect(t, db.error_ok(db.host_register(host, "add", nil, sdk_insert)))

	session := sdk.client_init(sdk_route, host)
	rows, query_err := sdk.client_query(&session, "SELECT id FROM t", context.allocator)
	defer db.sql_result_destroy(&rows)
	testing.expect(t, db.error_ok(query_err))
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect_value(t, rows.rows[0][0].i, i64(1))

	// Errors travel back as the engine's error kind.
	_, missing := sdk.client_query(&session, "SELECT id FROM ghost", context.allocator)
	defer db.error_free(&missing)
	testing.expect(t, !db.error_ok(missing))
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)

	call, call_err := sdk.client_call(&session, "add", nil, context.allocator)
	testing.expect(t, db.error_ok(call_err))
	db.sql_result_destroy(&call)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))

	// A bearer token authenticates the session.
	identity: db.Identity
	identity[0] = 7
	token, token_err := db.host_issue_token(host, identity, 0)
	defer delete(token)
	testing.expect(t, db.error_ok(token_err))
	sdk.client_authenticate(&session, token)
	who, who_err := sdk.client_query(&session, "SELECT current_identity() AS who", context.allocator)
	defer db.sql_result_destroy(&who)
	defer db.error_free(&who_err)
	testing.expectf(t, db.error_ok(who_err), "identity query: %s: %s", db.error_kind_name(who_err.kind), who_err.message)
	testing.expect_value(t, who.rows[0][0].kind, db.Value_Kind.Identity)
	testing.expect_value(t, db.value_identity_of(who.rows[0][0])[0], u8(7))

	// Subscriptions return the snapshot for each query.
	id, _, snapshot, sub_err := sdk.client_subscribe(
		&session,
		[]string{"SELECT id FROM t"},
		context.allocator,
	)
	defer db.host_snapshot_destroy(snapshot)
	testing.expect(t, db.error_ok(sub_err))
	testing.expect(t, id > 0)
	testing.expect_value(t, len(snapshot), 1)
	testing.expect_value(t, len(snapshot[0]), 2)
}

@(test)
test_log_stream_reader :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "stream")
	defer delete(path)
	defer os.remove_all(path)
	store := fresh_db(t, "stream")
	if store == nil do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	for index in 1 ..= 3 do run(t, store, fmt.tprintf("INSERT INTO t (id) VALUES (%d)", index))
	expected := store.commit_seq
	db.store_close(store)

	log_path := fmt.aprintf("%s/log", path)
	defer delete(log_path)
	reader, open_err := db.log_reader_open(log_path)
	testing.expect(t, db.error_ok(open_err))
	defer db.log_reader_close(reader)

	seen := 0
	for {
		record, more, next_err := db.log_reader_next(reader)
		if !db.error_ok(next_err) do break
		if !more do break
		seen += 1
		testing.expect_value(t, record.seq, u64(seen))
		testing.expect(t, len(record.payload) > 0)
	}
	testing.expect_value(t, u64(seen), expected)

	// A truncated file stops cleanly at the torn record.
	data, read_err := os.read_entire_file(log_path, context.allocator)
	testing.expect(t, read_err == nil)
	defer delete(data)
	torn_path := fmt.aprintf("%s/torn", path)
	defer delete(torn_path)
	keep := len(data) - 10
	testing.expect(t, os.write_entire_file(torn_path, data[:keep]) == nil)
	torn, torn_err := db.log_reader_open(torn_path)
	testing.expect(t, db.error_ok(torn_err))
	defer db.log_reader_close(torn)
	valid := 0
	for {
		_, more, _ := db.log_reader_next(torn)
		if !more do break
		valid += 1
	}
	testing.expect(t, valid < seen)
}

@(test)
test_row_size_hint :: proc(t: ^testing.T) {
	store := fresh_db(t, "row_bytes")
	if store == nil do return
	defer cleanup_db(store, "row_bytes")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO t (id, label) VALUES (1, 'hello'), (2, 'world!')")

	result := run(t, store, "SELECT id, label FROM t")
	defer db.sql_result_destroy(&result)
	testing.expect(t, result.row_bytes >= u64(len("hello") + len("world!")))
	testing.expect_value(t, result.rows[0][1].s, "hello")

	// The hint survives a wire roundtrip.
	encoded := db.wire_encode_result(result)
	defer delete(encoded)
	decoded, decode_err := db.wire_decode_result(encoded, context.allocator)
	testing.expect(t, db.error_ok(decode_err))
	defer db.sql_result_destroy(&decoded)
	testing.expect_value(t, decoded.row_bytes, result.row_bytes)
}

@(test)
test_deflate_roundtrip :: proc(t: ^testing.T) {
	payloads := [][]u8{
		transmute([]u8)string(""),
		transmute([]u8)string("hello"),
		make_repeated(t, "abc", 4000),
		make_zeros(4096),
		make_noise(1024),
		make_binary_pattern(512),
	}
	// The first two are literals; the helpers' buffers are the test's.
	defer for payload in payloads[2:] do delete(payload)
	for index in 0 ..< len(payloads) {
		payload := payloads[index]
		compressed := db.zlib_compress(payload, context.allocator)
		defer delete(compressed)
		restored, ok := db.zlib_decompress(compressed, context.allocator)
		testing.expectf(t, ok, "payload %d failed to decompress", index)
		if !ok do continue
		defer delete(restored)
		testing.expectf(t, len(restored) == len(payload), "payload %d length", index)
		for i in 0 ..< len(payload) {
			if restored[i] != payload[i] {
				testing.expectf(t, false, "payload %d differs at %d", index, i)
				break
			}
		}
	}

	// Repetitive data must actually shrink.
	repeated := make_repeated(t, "abcd", 2000)
	defer delete(repeated)
	compressed := db.zlib_compress(repeated, context.allocator)
	defer delete(compressed)
	testing.expect(t, len(compressed) < len(repeated) / 4)
}

make_repeated :: proc(t: ^testing.T, unit: string, count: int) -> []u8 {
	out := make([dynamic]u8, 0, len(unit) * count)
	for _ in 0 ..< count do append(&out, ..transmute([]u8)unit)
	return out[:]
}

make_zeros :: proc(count: int) -> []u8 {
	return make([]u8, count)
}

make_noise :: proc(count: int) -> []u8 {
	out := make([]u8, count)
	state := u32(12345)
	for i in 0 ..< count {
		state = state * 1103515245 + 12345
		out[i] = u8(state >> 16)
	}
	return out
}

make_binary_pattern :: proc(count: int) -> []u8 {
	out := make([]u8, count)
	for i in 0 ..< count do out[i] = u8(i % 7)
	return out
}

@(test)
test_http_compression :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "http_zip")
	if store == nil do return
	defer destroy_host(store, host, "http_zip")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	run_done(t, store, "INSERT INTO t (id) VALUES (1)")

	message := db.wire_encode_query("SELECT id FROM t", nil)
	defer delete(message)

	// A client that offers zlib gets a compressed response.
	head := fmt.aprintf(
		"POST /wire HTTP/1.1\r\nAccept-Encoding: zlib\r\nContent-Length: %d\r\n\r\n",
		len(message),
	)
	defer delete(head)
	raw := strings.concatenate({head, transmute(string)message})
	defer delete(raw)
	request, _, parse_err := db.http_parse_request(transmute([]u8)raw)
	defer db.http_request_destroy(&request)
	defer db.error_free(&parse_err)
	testing.expect(t, db.error_ok(parse_err))
	testing.expect(t, request.accepts_zlib)
	response := db.http_handle(host, request)
	defer delete(response)
	testing.expect(t, strings_contains(string(response), "Content-Encoding: zlib"))
	parsed, response_err := db.http_parse_response(response)
	testing.expect(t, db.error_ok(response_err))
	testing.expect(t, parsed.zlib)
	head_end := strings.index(string(response), "\r\n\r\n")
	testing.expectf(t, head_end > 0, "response: %s", string(response[:min(len(response), 200)]))
	body, inflated := db.zlib_decompress(parsed.body, context.allocator)
	testing.expectf(t, inflated, "body len %d first %v head_end %d", len(parsed.body), parsed.body[:min(len(parsed.body), 8)], head_end)
	defer delete(body)
	decoded, decode_err := db.wire_decode_result(body, context.allocator)
	defer db.sql_result_destroy(&decoded)
	testing.expect(t, db.error_ok(decode_err))
	testing.expect_value(t, len(decoded.rows), 1)
	testing.expect_value(t, decoded.rows[0][0].i, i64(1))

	// A compressed request body is inflated before dispatch.
	compressed := db.zlib_compress(message, context.allocator)
	defer delete(compressed)
	head2 := fmt.aprintf(
		"POST /wire HTTP/1.1\r\nContent-Encoding: zlib\r\nContent-Length: %d\r\n\r\n",
		len(compressed),
	)
	defer delete(head2)
	raw2 := strings.concatenate({head2, transmute(string)compressed})
	defer delete(raw2)
	request2, _, parse2_err := db.http_parse_request(transmute([]u8)raw2)
	defer db.http_request_destroy(&request2)
	defer db.error_free(&parse2_err)
	testing.expect(t, db.error_ok(parse2_err))
	testing.expect(t, request2.zlib_body)
	response2 := db.http_handle(host, request2)
	defer delete(response2)
	parsed2, parse3_err := db.http_parse_response(response2)
	testing.expect(t, db.error_ok(parse3_err))
	testing.expect(t, !parsed2.zlib)
	decoded2, decode2_err := db.wire_decode_result(parsed2.body, context.allocator)
	defer db.sql_result_destroy(&decoded2)
	testing.expect(t, db.error_ok(decode2_err))
	testing.expect_value(t, len(decoded2.rows), 1)
}

@(test)
test_prepared_commit_group :: proc(t: ^testing.T) {
	store := fresh_db(t, "prepared")
	if store == nil do return
	defer cleanup_db(store, "prepared")

	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY)")
	start_seq := store.commit_seq

	first := db.tx_begin_write(store)
	dropped_result_4808, first_err := db.sql_execute_in_tx(first, "INSERT INTO a (id) VALUES (1)")
	defer db.error_free(&first_err)
	defer db.sql_result_destroy(&dropped_result_4808)
	testing.expect(t, db.error_ok(first_err))
	prepared_one, prepare_one_err := db.tx_prepare(first)
	testing.expect(t, db.error_ok(prepare_one_err))
	// Preparing releases the lock and applies nothing yet.
	testing.expect_value(t, store.commit_seq, start_seq)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM a").i, i64(0))

	second := db.tx_begin_write(store)
	dropped_result_4817, second_err := db.sql_execute_in_tx(second, "INSERT INTO b (id) VALUES (1)")
	defer db.error_free(&second_err)
	defer db.sql_result_destroy(&dropped_result_4817)
	testing.expect(t, db.error_ok(second_err))
	prepared_two, prepare_two_err := db.tx_prepare(second)
	testing.expect(t, db.error_ok(prepare_two_err))

	written, commit_err := db.store_commit_prepared(store, []^db.Prepared_Tx{prepared_one, prepared_two})
	testing.expect(t, db.error_ok(commit_err))
	testing.expect_value(t, written, 2)
	testing.expect_value(t, store.commit_seq, start_seq + 2)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM a").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM b").i, i64(1))
	db.prepared_destroy(prepared_one)
	db.prepared_destroy(prepared_two)

	// A read transaction cannot be prepared.
	read := db.tx_begin_read(store)
	_, read_err := db.tx_prepare(read)
	defer db.error_free(&read_err)
	testing.expect(t, !db.error_ok(read_err))
}

@(test)
test_schema_migrations :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "migrations")
	if store == nil do return
	defer destroy_host(store, host, "migrations")

	testing.expect_value(t, db.host_schema_version(host), u32(1))
	migrations := []db.Migration{
		{version = 2, sql = []string{"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"}},
		{
			version = 3,
			sql = []string{
				"ALTER TABLE users ADD COLUMN email TEXT",
				"CREATE INDEX users_email ON users (email)",
			},
		},
	}
	applied, migrate_err := db.host_migrate(host, migrations)
	testing.expect(t, db.error_ok(migrate_err))
	testing.expect_value(t, applied, 2)
	testing.expect_value(t, db.host_schema_version(host), u32(3))
	testing.expect_value(t, len(run_temp(t, store, "SELECT id FROM users").rows), 0)
	testing.expect_value(t, len(run_temp(t, store, "SELECT name FROM _columns WHERE table = 'users'").rows), 3)
	testing.expect_value(t, len(run_temp(t, store, "SELECT name FROM _indexes WHERE name = 'users_email'").rows), 1)

	// Running again applies nothing.
	again, again_err := db.host_migrate(host, migrations)
	testing.expect(t, db.error_ok(again_err))
	testing.expect_value(t, again, 0)

	// A failing step rolls the whole migration back, version included.
	broken := []db.Migration {
		{
			version = 4,
			sql     = []string{"CREATE TABLE oops (id INTEGER PRIMARY KEY)", "NOT VALID SQL"},
		},
	}
	_, broken_err := db.host_migrate(host, broken)
	defer db.error_free(&broken_err)
	testing.expect(t, !db.error_ok(broken_err))
	testing.expect_value(t, db.host_schema_version(host), u32(3))
	testing.expect_value(t, len(run_temp(t, store, "SELECT name FROM _tables WHERE name = 'oops'").rows), 0)

	// A version gap is rejected before running anything.
	gap := []db.Migration{{version = 6, sql = []string{"CREATE TABLE six (id INTEGER PRIMARY KEY)"}}}
	_, gap_err := db.host_migrate(host, gap)
	defer db.error_free(&gap_err)
	testing.expect(t, !db.error_ok(gap_err))
	testing.expect_value(t, len(run_temp(t, store, "SELECT name FROM _tables WHERE name = 'six'").rows), 0)
}

@(test)
test_named_types :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "named_types")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "named_types")
	if store == nil do return

	run_done(t, store, "CREATE TYPE email AS TEXT")
	dropped_result_4799, again := db.sql_execute(store, "CREATE TYPE email AS TEXT")
	defer db.error_free(&again)
	defer db.sql_result_destroy(&dropped_result_4799)
	testing.expect(t, !db.error_ok(again))
	run_done(t, store, "CREATE TYPE IF NOT EXISTS email AS TEXT")

	run_done(t, store, "CREATE TABLE users (id INTEGER PRIMARY KEY, address email)")
	run_done(t, store, "INSERT INTO users (id, address) VALUES (1, 'a@b.c')")
	testing.expect_value(t, scalar(t, store, "SELECT address FROM users").s, "a@b.c")

	described := run(t, store, "SELECT type FROM _columns WHERE table = 'users'")
	defer db.sql_result_destroy(&described)
	found_text := false
	for row in described.rows {
		if row[0].s == "TEXT" do found_text = true
	}
	testing.expect(t, found_text)

	// A8: the catalog keeps the name the column was declared with next to the
	// type it resolved to, so a client can rebuild the schema it was written as.
	named := run(t, store, "SELECT named FROM _columns WHERE table = 'users' AND name = 'address'")
	defer db.sql_result_destroy(&named)
	found_named := false
	for row in named.rows {
		if row[0].s == "email" do found_named = true
	}
	testing.expect(t, found_named)

	shown := run(t, store, "SHOW types")
	defer db.sql_result_destroy(&shown)
	testing.expect_value(t, len(shown.rows), 1)
	testing.expect_value(t, shown.rows[0][0].s, "email")
	testing.expect_value(t, shown.rows[0][1].s, "TEXT")

	// A name no CREATE TYPE defined is read by SQLite's affinity rules, as
	// SQLite reads any type name: NOPE has NUMERIC affinity.
	dropped_result_4934, unknown := db.sql_execute(store, "CREATE TABLE loose (id nope)")
	defer db.error_free(&unknown)
	defer db.sql_result_destroy(&dropped_result_4934)
	testing.expect(t, db.error_ok(unknown))
	dropped_result_4869, bad_base := db.sql_execute(store, "CREATE TYPE weird AS nonsense")
	defer db.error_free(&bad_base)
	defer db.sql_result_destroy(&dropped_result_4869)
	testing.expect(t, !db.error_ok(bad_base))

	// The catalog replays with the rest of the log.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	testing.expect_value(t, scalar(t, reopened, "SELECT address FROM users").s, "a@b.c")
}

pg_build_startup :: proc(user: string) -> []u8 {
	out := make([dynamic]u8, 0, 32)
	append(&out, 0, 0, 0, 0) // length placeholder
	append(&out, 0, 3, 0, 0) // protocol 3.0
	append(&out, ..transmute([]u8)string("user"))
	append(&out, 0)
	append(&out, ..transmute([]u8)user)
	append(&out, 0, 0)
	length := u32(len(out))
	out[0] = u8(length >> 24)
	out[1] = u8(length >> 16)
	out[2] = u8(length >> 8)
	out[3] = u8(length)
	return out[:]
}

pg_build_query :: proc(sql: string) -> []u8 {
	out := make([dynamic]u8, 0, len(sql) + 6)
	append(&out, 'Q', 0, 0, 0, 0)
	append(&out, ..transmute([]u8)sql)
	append(&out, 0)
	length := u32(len(out) - 1)
	out[1] = u8(length >> 24)
	out[2] = u8(length >> 16)
	out[3] = u8(length >> 8)
	out[4] = u8(length)
	return out[:]
}

@(test)
test_postgres_wire :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "pgwire")
	if store == nil do return
	defer destroy_host(store, host, "pgwire")

	startup := pg_build_startup("postgres")
	defer delete(startup)
	parsed, startup_ok := db.pg_parse_startup(startup)
	defer delete(parsed.user)
	testing.expect(t, startup_ok)
	testing.expect_value(t, parsed.user, "postgres")

	ssl_request := []u8{0, 0, 0, 8, 4, 210, 22, 47}
	probe, probe_ok := db.pg_parse_startup(ssl_request)
	testing.expect(t, probe_ok)
	testing.expect(t, probe.ssl_request)

	// The server answers the startup with AuthenticationOk + ReadyForQuery.
	auth := db.pg_authentication_ok()
	defer delete(auth)
	testing.expect_value(t, auth[0], u8('R'))
	testing.expect_value(t, len(auth), 9)
	ready := db.pg_ready_for_query('I')
	defer delete(ready)
	testing.expect_value(t, ready[0], u8('Z'))

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO t (id, label) VALUES (1, 'one')")

	query := pg_build_query("SELECT id, label FROM t")
	defer delete(query)
	response, close := db.pg_handle_message(host, query)
	defer delete(response)
	testing.expect(t, !close)
	// RowDescription, one DataRow, CommandComplete, ReadyForQuery.
	testing.expect_value(t, response[0], u8('T'))
	testing.expect(t, strings_contains(string(response), "label"))
	testing.expect(t, strings_contains(string(response), "one"))
	testing.expect(t, strings_contains(string(response), "SELECT 1"))
	testing.expect_value(t, response[len(response) - 1], u8('I'))

	// A failing statement comes back as ErrorResponse followed by ReadyForQuery.
	bad := pg_build_query("SELECT * FROM ghost")
	defer delete(bad)
	bad_response, bad_close := db.pg_handle_message(host, bad)
	defer delete(bad_response)
	testing.expect(t, !bad_close)
	testing.expect_value(t, bad_response[0], u8('E'))
	testing.expect(t, strings_contains(string(bad_response), "ghost"))

	// Terminate closes the connection.
	terminate := []u8{'X', 0, 0, 0, 4}
	dropped_response_4875, terminate_close := db.pg_handle_message(host, terminate)
	defer delete(dropped_response_4875)
	testing.expect(t, terminate_close)
}

@(test)
test_structural_types :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "structural")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "structural")
	if store == nil do return
	// The store and the host are closed below and reopened; the cleanup at the
	// end closes the reopen, and nothing may close the first pair twice.

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, u UNIT, o OPTION(INT), r RESULT(INT, TEXT))")
	run_done(t, store, "INSERT INTO t (id, u, o, r) VALUES (1, NULL, 5, NULL)")
	testing.expect_value(t, scalar(t, store, "SELECT o FROM t").i, i64(5))

	unit_err: db.Error
	_, unit_err = db.sql_execute(store, "INSERT INTO t (id, u) VALUES (2, 1)")
	testing.expect(t, !db.error_ok(unit_err))
	db.error_free(&unit_err)
	option_err: db.Error
	_, option_err = db.sql_execute(store, "INSERT INTO t (id, o) VALUES (3, 'x')")
	testing.expect(t, !db.error_ok(option_err))
	db.error_free(&option_err)

	described := run(t, store, "SELECT name, type FROM _columns WHERE table = 't'")
	defer db.sql_result_destroy(&described)
	types := map[string]string{}
	defer delete(types)
	for row in described.rows do types[row[0].s] = row[1].s
	testing.expect_value(t, types["u"], "UNIT")
	testing.expect_value(t, types["o"], "OPTION(BIGINT)")
	testing.expect_value(t, types["r"], "RESULT(BIGINT, TEXT)")

	// RESULT is a tagged pair: exactly one side may be set.
	ready := db.Column_Type {
		kind        = .Result,
		inner_kind  = .Int,
		inner_width = 8,
		right_kind  = .String,
	}
	ok_side := db.Value{kind = .Product, list = []db.Value{db.value_int(7), db.value_null()}}
	coerced, ok_err := db.value_coerce(ok_side, ready)
	testing.expect(t, db.error_ok(ok_err))
	testing.expect_value(t, coerced.list[0].i, i64(7))
	err_side := db.Value{kind = .Product, list = []db.Value{db.value_null(), db.value_string("boom")}}
	err_coerced, err_ok_err := db.value_coerce(err_side, ready)
	testing.expect(t, db.error_ok(err_ok_err))
	testing.expect_value(t, err_coerced.list[1].s, "boom")
	both := db.Value{kind = .Product, list = []db.Value{db.value_int(1), db.value_string("x")}}
	_, both_err := db.value_coerce(both, ready)
	defer db.error_free(&both_err)
	testing.expect(t, !db.error_ok(both_err))

	// A named type may itself be structural, and UNIT cannot be NOT NULL.
	run_done(t, store, "CREATE TYPE maybe_count AS OPTION(INT)")
	run_done(t, store, "CREATE TABLE named (id INTEGER PRIMARY KEY, n maybe_count)")
	run_done(t, store, "INSERT INTO named (id, n) VALUES (1, 3)")
	testing.expect_value(t, scalar(t, store, "SELECT n FROM named").i, i64(3))
	dropped_result_5022, unit_not_null := db.sql_execute(store, "CREATE TABLE bad_unit (u UNIT NOT NULL)")
	defer db.error_free(&unit_not_null)
	defer db.sql_result_destroy(&dropped_result_5022)
	testing.expect(t, !db.error_ok(unit_not_null))

	// Structural types survive a reopen through the schema codec.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	testing.expect_value(t, scalar(t, reopened, "SELECT o FROM t").i, i64(5))
}

@(test)
test_statement_work_budget :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "work")
	if store == nil do return
	defer destroy_host(store, host, "work")

	run_done(t, store, "CREATE TABLE e (id INTEGER PRIMARY KEY, label TEXT)")
	for i in 1 ..= 3 {
		statement := fmt.aprintf("INSERT INTO e (id, label) VALUES (%d, 'row%d')", i, i)
		defer delete(statement)
		run_done(t, store, statement)
	}
	selected := run(t, store, "SELECT id, label FROM e")
	defer db.sql_result_destroy(&selected)
	testing.expect(t, selected.work >= 3)
	first_used := db.store_work_used(store)
	testing.expect(t, first_used >= selected.work)

	// A budget below the cost refuses the statement.
	db.store_set_work_budget(store, 1)
	testing.expect_value(t, db.store_work_budget(store), u64(1))
	dropped_result_5019, over := db.sql_execute(store, "SELECT id, label FROM e")
	defer db.error_free(&over)
	defer db.sql_result_destroy(&dropped_result_5019)
	testing.expect_value(t, over.kind, db.Error_Kind.Quota_Exceeded)
	// The message names the work the statement actually spent: it used to say 0,
	// because the count was read after the result had been destroyed.
	testing.expectf(t, strings.contains(over.message, "spends 3 work"), "message: %s", over.message)

	// Mutations pay for the rows they affect.
	db.store_set_work_budget(store, 0)
	inserted := run(t, store, "INSERT INTO e (id, label) VALUES (9, 'nine')")
	defer db.sql_result_destroy(&inserted)
	testing.expect(t, inserted.work >= 1)
	testing.expect(t, db.store_work_used(store) > first_used)

	// A generous budget passes and reports its price.
	db.store_set_work_budget(store, 1000)
	allowed := run(t, store, "SELECT id FROM e")
	defer db.sql_result_destroy(&allowed)
	testing.expect(t, allowed.work >= 4)

	db.store_reset_work(store)
	testing.expect_value(t, db.store_work_used(store), u64(0))
}

@(test)
test_row_versions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "mvcc")
	if store == nil do return
	defer destroy_host(store, host, "mvcc")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO t (id, label) VALUES (1, 'one')")
	first := store.commit_seq
	run_done(t, store, "UPDATE t SET label = 'two' WHERE id = 1")
	second := store.commit_seq
	testing.expect(t, second > first)
	run_done(t, store, "DELETE FROM t WHERE id = 1")
	third := store.commit_seq

	// The pinned snapshot still sees the first value.
	old := db.tx_begin_read_at(store, first)
	old_result, old_err := db.sql_execute_in_tx(old, "SELECT label FROM t")
	testing.expect(t, db.error_ok(old_err))
	testing.expect_value(t, len(old_result.rows), 1)
	testing.expect_value(t, old_result.rows[0][0].s, "one")
	db.sql_result_destroy(&old_result)
	db.tx_end(old)

	// A later snapshot sees the update but not the delete.
	mid := db.tx_begin_read_at(store, second)
	mid_result, mid_err := db.sql_execute_in_tx(mid, "SELECT label FROM t")
	testing.expect(t, db.error_ok(mid_err))
	testing.expect_value(t, mid_result.rows[0][0].s, "two")
	db.sql_result_destroy(&mid_result)
	db.tx_end(mid)

	// The current view is empty and the live count agrees.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(0))

	// Pruning below the pinned snapshot drops the tombstone and the oldest
	// version, and the pinned read then behaves like the current one.
	db.store_prune_versions(store, second)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(0))
	testing.expect(t, third >= second)
}

@(test)
test_hash_and_direct_indexes :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "hash_index")
	defer delete(path)
	defer os.remove_all(path)
	os.remove_all(path)
	store, host := fresh_host(t, "hash_index")
	if store == nil do return
	// Closed and reopened below: one owner per handle.

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, code TEXT, label TEXT)")
	run_done(t, store, "CREATE INDEX t_label_hash ON t USING HASH (label)")
	run_done(t, store, "CREATE UNIQUE INDEX t_code_direct ON t USING DIRECT (code)")
	for i in 1 ..= 3 {
		statement := fmt.aprintf("INSERT INTO t (id, code, label) VALUES (%d, 'c%d', 'same')", i, i)
		defer delete(statement)
		run_done(t, store, statement)
	}
	// The hash index answers an equality lookup over a non-unique key.
	matched := run(t, store, "SELECT id FROM t WHERE label = 'same' ORDER BY id")
	defer db.sql_result_destroy(&matched)
	testing.expect_value(t, len(matched.rows), 3)
	testing.expect_value(t, matched.rows[0][0].i, i64(1))

	// The direct index is unique: a duplicate key is rejected.
	dropped_result_5146, duplicate := db.sql_execute(store, "INSERT INTO t (id, code, label) VALUES (4, 'c1', 'other')")
	defer db.error_free(&duplicate)
	defer db.sql_result_destroy(&dropped_result_5146)
	testing.expect(t, !db.error_ok(duplicate))
	dropped_result_5111, not_direct := db.sql_execute(store, "CREATE INDEX bad ON t USING DIRECT (label)")
	defer db.error_free(&not_direct)
	defer db.sql_result_destroy(&dropped_result_5111)
	testing.expect(t, !db.error_ok(not_direct))

	// Updates move the bucket, deletes empty it.
	run_done(t, store, "UPDATE t SET label = 'moved' WHERE id = 2")
	testing.expect_value(t, len(run_temp(t, store, "SELECT id FROM t WHERE label = 'same'").rows), 2)
	testing.expect_value(t, len(run_temp(t, store, "SELECT id FROM t WHERE label = 'moved'").rows), 1)
	run_done(t, store, "DELETE FROM t WHERE id = 3")
	testing.expect_value(t, len(run_temp(t, store, "SELECT id FROM t WHERE label = 'same'").rows), 1)
	testing.expect_value(t, len(run_temp(t, store, "SELECT id FROM t WHERE code = 'c3'").rows), 0)

	// The algorithm and the buckets survive a reopen.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	testing.expect_value(t, len(run_temp(t, reopened, "SELECT id FROM t WHERE label = 'moved'").rows), 1)
	testing.expect_value(t, len(run_temp(t, reopened, "SELECT id FROM t WHERE code = 'c1'").rows), 1)
	indexes := reopened.tables["t"].schema.indexes
	found_hash := false
	found_direct := false
	for index in indexes {
		if index.name == "t_label_hash" do found_hash = index.algorithm == db.Index_Algorithm.Hash
		if index.name == "t_code_direct" do found_direct = index.algorithm == db.Index_Algorithm.Direct
	}
	testing.expect(t, found_hash)
	testing.expect(t, found_direct)
}

pg_build_frontend :: proc(kind: u8, body: []u8) -> []u8 {
	out := make([dynamic]u8, 0, len(body) + 5)
	append(&out, kind, 0, 0, 0, 0)
	append(&out, ..body)
	length := u32(len(out) - 1)
	out[1] = u8(length >> 24)
	out[2] = u8(length >> 16)
	out[3] = u8(length >> 8)
	out[4] = u8(length)
	return out[:]
}

@(test)
test_postgres_extended_query :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "pgext")
	if store == nil do return
	defer destroy_host(store, host, "pgext")

	run_done(t, store, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "INSERT INTO items (id, name) VALUES (1, 'one')")

	session := db.pg_session_init()
	defer db.pg_session_destroy(session)

	// Parse: name "q1", SQL with one parameter.
	parse_body := make([dynamic]u8)
	defer delete(parse_body)
	append(&parse_body, ..transmute([]u8)string("q1"))
	append(&parse_body, 0)
	append(&parse_body, ..transmute([]u8)string("SELECT id, name FROM items WHERE id = ?"))
	append(&parse_body, 0, 0, 0)
	parse := pg_build_frontend('P', parse_body[:])
	defer delete(parse)
	parse_response, _ := db.pg_handle_session_message(host, session, parse)
	testing.expect_value(t, parse_response[0], u8('1'))
	delete(parse_response)

	// Bind: portal "p1" with the integer parameter 1 in text format.
	bind_body := make([dynamic]u8)
	defer delete(bind_body)
	append(&bind_body, ..transmute([]u8)string("p1"))
	append(&bind_body, 0)
	append(&bind_body, ..transmute([]u8)string("q1"))
	append(&bind_body, 0)
	append(&bind_body, 0, 0) // no parameter formats: text
	append(&bind_body, 0, 1) // one parameter
	append(&bind_body, 0, 0, 0, 1, '1')
	append(&bind_body, 0, 0) // no result formats
	bind := pg_build_frontend('B', bind_body[:])
	defer delete(bind)
	bind_response, _ := db.pg_handle_session_message(host, session, bind)
	testing.expect_value(t, bind_response[0], u8('2'))
	delete(bind_response)

	// Execute: the bound portal runs and returns the row.
	execute_body := make([dynamic]u8)
	defer delete(execute_body)
	append(&execute_body, ..transmute([]u8)string("p1"))
	append(&execute_body, 0, 0, 0, 0, 0)
	execute := pg_build_frontend('E', execute_body[:])
	defer delete(execute)
	exec_response, _ := db.pg_handle_session_message(host, session, execute)
	// Execute sends the rows and CommandComplete only: the description belongs
	// to Describe and ReadyForQuery to Sync, so a pipelining driver reads one of
	// each where it expects them.
	testing.expect_value(t, exec_response[0], u8('D'))
	testing.expect(t, strings_contains(string(exec_response), "one"))
	testing.expect(t, strings_contains(string(exec_response), "SELECT 1"))
	testing.expect_value(t, exec_response[len(exec_response) - 1], u8(0))
	delete(exec_response)

	// Sync closes the cycle with ReadyForQuery on its own.
	sync_response, _ := db.pg_handle_session_message(host, session, []u8{'S', 0, 0, 0, 4})
	testing.expect_value(t, sync_response[0], u8('Z'))
	delete(sync_response)

	// A bound INSERT through Execute writes rows.
	insert_parse_body := make([dynamic]u8)
	defer delete(insert_parse_body)
	append(&insert_parse_body, ..transmute([]u8)string("q2"))
	append(&insert_parse_body, 0)
	append(&insert_parse_body, ..transmute([]u8)string("INSERT INTO items (id, name) VALUES (?, ?)"))
	append(&insert_parse_body, 0, 0, 0)
	insert_parse := pg_build_frontend('P', insert_parse_body[:])
	defer delete(insert_parse)
	response, _ := db.pg_handle_session_message(host, session, insert_parse)
	delete(response)

	insert_bind_body := make([dynamic]u8)
	defer delete(insert_bind_body)
	append(&insert_bind_body, ..transmute([]u8)string("p2"))
	append(&insert_bind_body, 0)
	append(&insert_bind_body, ..transmute([]u8)string("q2"))
	append(&insert_bind_body, 0, 0, 0)
	append(&insert_bind_body, 0, 2)
	append(&insert_bind_body, 0, 0, 0, 1, '2')
	append(&insert_bind_body, 0, 0, 0, 3, 't', 'w', 'o')
	append(&insert_bind_body, 0, 0)
	insert_bind := pg_build_frontend('B', insert_bind_body[:])
	defer delete(insert_bind)
	response, _ = db.pg_handle_session_message(host, session, insert_bind)
	delete(response)

	insert_execute_body := make([dynamic]u8)
	defer delete(insert_execute_body)
	append(&insert_execute_body, ..transmute([]u8)string("p2"))
	append(&insert_execute_body, 0, 0, 0, 0, 0)
	insert_execute := pg_build_frontend('E', insert_execute_body[:])
	defer delete(insert_execute)
	response, _ = db.pg_handle_session_message(host, session, insert_execute)
	testing.expect(t, strings_contains(string(response), "INSERT 0 1"))
	delete(response)
	testing.expect_value(t, scalar(t, store, "SELECT name FROM items WHERE id = 2").s, "two")

	// An unknown portal is an error, not a crash.
	unknown := pg_build_frontend('E', []u8{'z', 'z', 0, 0, 0, 0, 0})
	defer delete(unknown)
	unknown_response, _ := db.pg_handle_session_message(host, session, unknown)
	testing.expect_value(t, unknown_response[0], u8('E'))
	delete(unknown_response)
	// After an error the extended protocol discards everything until Sync.
	skipped, _ := db.pg_handle_session_message(host, session, insert_execute)
	defer delete(skipped)
	testing.expect_value(t, len(skipped), 0)
	after_sync, _ := db.pg_handle_session_message(host, session, []u8{'S', 0, 0, 0, 4})
	testing.expect_value(t, after_sync[0], u8('Z'))
	delete(after_sync)
}

@(test)
test_postgres_dialect :: proc(t: ^testing.T) {
	// The PostgreSQL spellings a client or a migration tool sends first: the
	// `::` cast, SERIAL and identity columns, multi-word type names, `$n`
	// parameters, the session functions and the catalog views.
	store := fresh_db(t, "pg_dialect")
	if store == nil do return
	defer cleanup_db(store, "pg_dialect")
	run(
		t,
		store,
		`CREATE TABLE person (
			id SERIAL PRIMARY KEY,
			name CHARACTER VARYING(40) NOT NULL,
			born DATE,
			meta JSONB,
			balance NUMERIC(10, 2) DEFAULT 0,
			seen TIMESTAMP WITH TIME ZONE,
			ratio DOUBLE PRECISION
		)`,
	)
	run_done(t, store, "INSERT INTO person (name, born) VALUES ('ana', '2020-01-01'), ('luis', NULL)")
	testing.expect_value(t, scalar(t, store, "SELECT max(id) FROM person").i, i64(2))
	run_done(t, store, "CREATE TABLE tag (id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO tag (label) VALUES ('a'), ('b')")
	testing.expect_value(t, scalar(t, store, "SELECT max(id) FROM tag").i, i64(2))

	// `::` binds tighter than any operator and takes a precision.
	testing.expect_value(t, scalar(t, store, "SELECT '41'::bigint + 1").i, i64(42))
	testing.expect_value(t, scalar(t, store, "SELECT 7::text || 'x'").s, "7x")
	testing.expect_value(t, scalar(t, store, "SELECT '2.5'::numeric(4, 1) * 2").f, 5.0)
	testing.expect_value(t, scalar(t, store, "SELECT name FROM person WHERE id::text = '2'").s, "luis")

	// `$n` binds the n-th value and may repeat.
	result, params_err := db.sql_execute_params(store, "SELECT $2 || $1 || $2", []db.Value{db.value_string("b"), db.value_string("a")})
	if testing.expectf(t, db.error_ok(params_err), "params: %s", params_err.message) {
		if testing.expect_value(t, len(result.rows), 1) do testing.expect_value(t, result.rows[0][0].s, "aba")
		db.sql_result_destroy(&result)
	}

	// Session functions, with and without parentheses.
	testing.expect_value(t, scalar(t, store, "SELECT version()").s, db.ENGINE_VERSION_TEXT)
	testing.expect_value(t, scalar(t, store, "SELECT current_database()").s, "miraidb")
	testing.expect_value(t, scalar(t, store, "SELECT current_schema").s, "public")
	testing.expect_value(t, scalar(t, store, "SELECT current_user").s, "miraidb")

	// The catalog, under the names PostgreSQL gives it.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM information_schema.tables WHERE table_name = 'person'").i, i64(1))
	testing.expect_value(
		t,
		scalar(t, store, "SELECT data_type FROM information_schema.columns WHERE table_name = 'person' AND column_name = 'ratio'").s,
		"double precision",
	)
	testing.expect_value(
		t,
		scalar(t, store, "SELECT is_nullable FROM information_schema.columns WHERE table_name = 'person' AND column_name = 'name'").s,
		"NO",
	)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM pg_catalog.pg_tables WHERE tablename = 'tag'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM public.person").i, i64(2))

	// A script splits where its statements end, not inside a string, a comment
	// or a trigger body.
	pieces := db.sql_split_statements(
		"SELECT 'a;b'; -- x;\nSELECT 2;; CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; SELECT 2; END; SELECT 3",
	)
	defer delete(pieces)
	testing.expect_value(t, len(pieces), 4)
	if len(pieces) == 4 {
		testing.expect_value(t, pieces[0], "SELECT 'a;b'")
		testing.expect(t, strings_contains(pieces[2], "SELECT 2; END"))
		testing.expect_value(t, pieces[3], "SELECT 3")
	}
	// sql_statement_end is the same boundary for the first statement: the tail
	// sqlite3_prepare reports and sqlite3_exec goes on from.
	trigger := "CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.a); END; SELECT 1"
	testing.expect_value(t, trigger[:db.sql_statement_end(trigger)], "CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.a); END;")
	bracket := "SELECT [a;b] FROM t; SELECT 2"
	testing.expect_value(t, bracket[:db.sql_statement_end(bracket)], "SELECT [a;b] FROM t;")
}

@(test)
test_postgres_session_transactions :: proc(t: ^testing.T) {
	// BEGIN keeps a transaction open across Query messages, a failed statement
	// aborts it until ROLLBACK, the status byte says which, and every statement
	// gets the tag a driver reads its row count from.
	store := fresh_db(t, "pg_session")
	if store == nil do return
	defer cleanup_db(store, "pg_session")
	host := db.host_init(store)
	defer db.host_destroy(host)
	session := db.pg_session_init()
	defer db.pg_session_destroy(session)
	query :: proc(host: ^db.Host, session: ^db.Pg_Session, sql: string) -> string {
		body := make([dynamic]u8)
		defer delete(body)
		append(&body, ..transmute([]u8)sql)
		append(&body, 0)
		message := pg_build_frontend('Q', body[:])
		defer delete(message)
		response, _ := db.pg_handle_session_message(host, session, message)
		return string(response)
	}
	ends_with_status :: proc(response: string, status: u8) -> bool {
		return len(response) > 0 && response[len(response) - 1] == status
	}

	created := query(host, session, "CREATE TABLE k (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO k VALUES (1, 'a'), (2, 'b')")
	testing.expect(t, strings_contains(created, "CREATE TABLE"))
	testing.expect(t, strings_contains(created, "INSERT 0 2"))
	testing.expect(t, ends_with_status(created, 'I'))
	delete(created)

	begun := query(host, session, "BEGIN; UPDATE k SET v = 'z' WHERE id = 1")
	testing.expect(t, strings_contains(begun, "UPDATE 1"))
	testing.expect(t, ends_with_status(begun, 'T'))
	testing.expect(t, db.pg_session_in_transaction(session))
	delete(begun)
	failed := query(host, session, "SELECT nope FROM k")
	testing.expect(t, strings_contains(failed, "42703"))
	testing.expect(t, ends_with_status(failed, 'E'))
	delete(failed)
	refused := query(host, session, "SELECT 1")
	testing.expect(t, strings_contains(refused, "25P02"))
	delete(refused)
	// COMMIT of a failed transaction rolls it back.
	committed := query(host, session, "COMMIT")
	testing.expect(t, strings_contains(committed, "ROLLBACK"))
	testing.expect(t, ends_with_status(committed, 'I'))
	delete(committed)
	testing.expect(t, !db.pg_session_in_transaction(session))
	testing.expect_value(t, scalar(t, store, "SELECT v FROM k WHERE id = 1").s, "a")

	kept := query(host, session, "BEGIN; DELETE FROM k WHERE id = 2; COMMIT")
	testing.expect(t, strings_contains(kept, "DELETE 1"))
	testing.expect(t, strings_contains(kept, "COMMIT"))
	delete(kept)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM k").i, i64(1))

	// The session itself answers DEALLOCATE; the engine never sees it.
	deallocated := query(host, session, "DEALLOCATE ALL")
	testing.expect(t, strings_contains(deallocated, "DEALLOCATE ALL"))
	delete(deallocated)
}

@(test)
test_array_and_product_types :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "containers")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "containers")
	if store == nil do return

	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, tags ARRAY(TEXT), pair PRODUCT(INT, TEXT))")
	described := run(t, store, "SELECT name, type FROM _columns WHERE table = 'c'")
	defer db.sql_result_destroy(&described)
	types := map[string]string{}
	defer delete(types)
	for row in described.rows do types[row[0].s] = row[1].s
	testing.expect_value(t, types["tags"], "ARRAY(TEXT)")
	testing.expect_value(t, types["pair"], "PRODUCT(BIGINT, TEXT)")

	array_type := db.Column_Type{kind = .Array, inner_kind = .String}
	value := db.Value{kind = .Array, list = []db.Value{db.value_string("a"), db.value_string("b")}}
	coerced, array_err := db.value_coerce(value, array_type)
	testing.expect(t, db.error_ok(array_err))
	testing.expect_value(t, len(coerced.list), 2)
	testing.expect_value(t, coerced.list[1].s, "b")

	wrong := db.Value{kind = .Array, list = []db.Value{db.value_bytes([]u8{1})}}
	_, wrong_err := db.value_coerce(wrong, array_type)
	defer db.error_free(&wrong_err)
	testing.expect(t, !db.error_ok(wrong_err))
	not_array := db.value_int(3)
	_, shape_err := db.value_coerce(not_array, array_type)
	defer db.error_free(&shape_err)
	testing.expect(t, !db.error_ok(shape_err))

	pair_type := db.Column_Type {
		kind       = .Product,
		components = []db.Column_Type{{kind = .Int, width = 8}, {kind = .String}},
	}
	pair := db.Value{kind = .Product, list = []db.Value{db.value_int(7), db.value_string("x")}}
	coerced_pair, pair_err := db.value_coerce(pair, pair_type)
	testing.expect(t, db.error_ok(pair_err))
	testing.expect_value(t, coerced_pair.list[0].i, i64(7))
	triple := db.Value{kind = .Product, list = []db.Value{db.value_int(1), db.value_int(2), db.value_int(3)}}
	_, triple_err := db.value_coerce(triple, pair_type)
	defer db.error_free(&triple_err)
	testing.expect(t, !db.error_ok(triple_err))

	// A named type may name an array, and the schema round-trips both kinds.
	run_done(t, store, "CREATE TYPE labels AS ARRAY(TEXT)")
	run_done(t, store, "CREATE TABLE named (id INTEGER PRIMARY KEY, l labels)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM named").i, i64(0))

	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	types_after := map[string]string{}
	defer delete(types_after)
	for row in run_temp(t, reopened, "SELECT name, type FROM _columns WHERE table = 'c'").rows {
		types_after[row[0].s] = row[1].s
	}
	testing.expect_value(t, types_after["tags"], "ARRAY(TEXT)")
	testing.expect_value(t, types_after["pair"], "PRODUCT(BIGINT, TEXT)")
}

@(test)
test_named_type_references :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "named_refs")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "named_refs")
	if store == nil do return

	run_done(t, store, "CREATE TYPE labels AS ARRAY(TEXT)")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, l labels, plain TEXT)")
	row := run(t, store, "SELECT name, type, named FROM _columns WHERE table = 't' AND name = 'l'")
	defer db.sql_result_destroy(&row)
	testing.expect_value(t, len(row.rows), 1)
	testing.expect_value(t, row.rows[0][1].s, "ARRAY(TEXT)")
	testing.expect_value(t, row.rows[0][2].s, "labels")
	plain := run(t, store, "SELECT named FROM _columns WHERE table = 't' AND name = 'plain'")
	defer db.sql_result_destroy(&plain)
	testing.expect_value(t, plain.rows[0][0].s, "")

	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	// The reference and the resolved type both survive the schema codec.
	after := run(t, reopened, "SELECT type, named FROM _columns WHERE table = 't' AND name = 'l'")
	defer db.sql_result_destroy(&after)
	testing.expect_value(t, after.rows[0][0].s, "ARRAY(TEXT)")
	testing.expect_value(t, after.rows[0][1].s, "labels")
}

pg_patch_length :: proc(message: []u8) {
	length := u32(len(message) - 1)
	message[1] = u8(length >> 24)
	message[2] = u8(length >> 16)
	message[3] = u8(length >> 8)
	message[4] = u8(length)
}

@(test)
test_postgres_binary_and_describe :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "pgbin")
	if store == nil do return
	defer destroy_host(store, host, "pgbin")

	run_done(t, store, "CREATE TABLE n (id INTEGER PRIMARY KEY, score DOUBLE, flag BOOLEAN)")
	run_done(t, store, "INSERT INTO n (id, score, flag) VALUES (1, 2.5, true)")

	session := db.pg_session_init()
	defer db.pg_session_destroy(session)

	// Parse declares int8 (20) and float8 (701) parameter types.
	parse_body := make([dynamic]u8)
	defer delete(parse_body)
	append(&parse_body, ..transmute([]u8)string("q"))
	append(&parse_body, 0)
	append(&parse_body, ..transmute([]u8)string("SELECT id, score, flag FROM n WHERE id = ? AND score > ?"))
	append(&parse_body, 0, 0, 2)
	append(&parse_body, 0, 0, 0, 20)
	append(&parse_body, 0, 0, 2, 189) // 701 = 0x02BD
	parse := pg_build_frontend('P', parse_body[:])
	defer delete(parse)
	response, _ := db.pg_handle_session_message(host, session, parse)
	testing.expect_value(t, response[0], u8('1'))
	delete(response)

	// Describe on the statement reports the parameter types and the row shape.
	describe_body := make([dynamic]u8)
	defer delete(describe_body)
	append(&describe_body, 'S')
	append(&describe_body, ..transmute([]u8)string("q"))
	append(&describe_body, 0)
	describe := pg_build_frontend('D', describe_body[:])
	defer delete(describe)
	response, _ = db.pg_handle_session_message(host, session, describe)
	testing.expect_value(t, response[0], u8('t'))
	testing.expect(t, strings_contains(string(response), "score"))
	delete(response)

	// Bind with binary parameters and binary results.
	bind_body := make([dynamic]u8)
	defer delete(bind_body)
	append(&bind_body, ..transmute([]u8)string("p"))
	append(&bind_body, 0)
	append(&bind_body, ..transmute([]u8)string("q"))
	append(&bind_body, 0)
	append(&bind_body, 0, 1) // one format for all parameters
	append(&bind_body, 0, 1) // binary
	append(&bind_body, 0, 2) // two parameters, both binary
	append(&bind_body, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1)
	append(&bind_body, 0, 0, 0, 8, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	append(&bind_body, 0, 0) // results stay text
	bind := pg_build_frontend('B', bind_body[:])
	defer delete(bind)
	response, _ = db.pg_handle_session_message(host, session, bind)
	testing.expect_value(t, response[0], u8('2'))
	delete(response)

	execute_body := make([dynamic]u8)
	defer delete(execute_body)
	append(&execute_body, ..transmute([]u8)string("p"))
	append(&execute_body, 0, 0, 0, 0, 0)
	execute := pg_build_frontend('E', execute_body[:])
	defer delete(execute)
	response, _ = db.pg_handle_session_message(host, session, execute)
	// Execute answers rows and CommandComplete; ReadyForQuery belongs to Sync.
	testing.expect_value(t, response[0], u8('D'))
	testing.expect(t, strings_contains(string(response), "2.5"))
	testing.expect_value(t, response[len(response) - 1], u8(0))
	delete(response)

	// A binary result format is encoded per column.
	bind_body2 := make([dynamic]u8)
	defer delete(bind_body2)
	append(&bind_body2, ..transmute([]u8)string("p2"))
	append(&bind_body2, 0)
	append(&bind_body2, ..transmute([]u8)string("q"))
	append(&bind_body2, 0)
	append(&bind_body2, 0, 1, 0, 1)
	append(&bind_body2, 0, 2)
	append(&bind_body2, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1)
	append(&bind_body2, 0, 0, 0, 8, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	append(&bind_body2, 0, 1, 0, 1) // one result format: binary
	bind2 := pg_build_frontend('B', bind_body2[:])
	defer delete(bind2)
	response, _ = db.pg_handle_session_message(host, session, bind2)
	testing.expect_value(t, response[0], u8('2'))
	delete(response)

	execute2_body := make([dynamic]u8)
	defer delete(execute2_body)
	append(&execute2_body, ..transmute([]u8)string("p2"))
	append(&execute2_body, 0, 0, 0, 0, 0)
	execute2 := pg_build_frontend('E', execute2_body[:])
	defer delete(execute2)
	// Describe of the portal announces int8 and float8 in binary format: the
	// types the rows are then encoded in.
	describe_portal := pg_build_frontend('D', []u8{'P', 'p', '2', 0})
	defer delete(describe_portal)
	response, _ = db.pg_handle_session_message(host, session, describe_portal)
	testing.expect_value(t, response[0], u8('T'))
	testing.expect(t, strings_contains(string(response), "score"))
	delete(response)
	response, _ = db.pg_handle_session_message(host, session, execute2)
	// The DataRow carries the 8-byte big-endian id and score.
	testing.expect_value(t, response[0], u8('D'))
	testing.expect(t, strings_contains(string(response), "SELECT 1"))
	delete(response)
}

@(test)
test_product_arity :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "product_arity")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "product_arity")
	if store == nil do return

	run_done(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY, triple PRODUCT(INT, TEXT, BOOLEAN))")
	described := run(t, store, "SELECT type FROM _columns WHERE table = 'p' AND name = 'triple'")
	defer db.sql_result_destroy(&described)
	testing.expect_value(t, described.rows[0][0].s, "PRODUCT(BIGINT, TEXT, BOOLEAN)")

	triple_type := db.Column_Type {
		kind = .Product,
		components = []db.Column_Type{{kind = .Int, width = 8}, {kind = .String}, {kind = .Bool}},
	}
	value := db.Value {
		kind = .Product,
		list = []db.Value{db.value_int(4), db.value_string("x"), db.value_bool(true)},
	}
	coerced, ok := db.value_coerce(value, triple_type)
	testing.expect(t, db.error_ok(ok))
	testing.expect_value(t, len(coerced.list), 3)
	testing.expect_value(t, coerced.list[2].b, true)

	short := db.Value{kind = .Product, list = []db.Value{db.value_int(1), db.value_string("x")}}
	_, short_err := db.value_coerce(short, triple_type)
	defer db.error_free(&short_err)
	testing.expect(t, !db.error_ok(short_err))
	dropped_result_5699, one_component := db.sql_execute(store, "CREATE TABLE bad (x PRODUCT(INT))")
	defer db.error_free(&one_component)
	defer db.sql_result_destroy(&dropped_result_5699)
	testing.expect(t, !db.error_ok(one_component))
	dropped_result_5701, nested := db.sql_execute(store, "CREATE TABLE bad2 (x PRODUCT(INT, ARRAY(TEXT)))")
	defer db.error_free(&nested)
	defer db.sql_result_destroy(&dropped_result_5701)
	testing.expect(t, !db.error_ok(nested))

	// Reopen keeps both the arity and the components.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	after := run(t, reopened, "SELECT type FROM _columns WHERE table = 'p' AND name = 'triple'")
	defer db.sql_result_destroy(&after)
	testing.expect_value(t, after.rows[0][0].s, "PRODUCT(BIGINT, TEXT, BOOLEAN)")
	testing.expect_value(t, len(reopened.tables["p"].schema.columns[1].type.components), 3)
}

@(test)
test_client_drop_policy :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "drops")
	if store == nil do return
	defer destroy_host(store, host, "drops")

	testing.expect(t, db.host_client_connect(host, 7))
	testing.expect_value(t, db.host_client_count(host), 1)

	// Unbounded by default: everything fits and bytes are accounted.
	testing.expect(t, db.host_client_enqueue(host, 7, 100))
	db.host_client_dequeue(host, 7, 100)
	testing.expect_value(t, db.host_client_queue(host, 7), u64(0))
	testing.expect_value(t, db.host_client_bytes(host, 7), u64(100))

	// A budget caps the outbox; overflow drops the message and asks to close.
	db.host_set_client_queue_budget(host, 10)
	testing.expect_value(t, db.host_client_queue_budget(host), u64(10))
	testing.expect(t, db.host_client_enqueue(host, 7, 6))
	testing.expect(t, !db.host_client_enqueue(host, 7, 6))
	testing.expect_value(t, db.host_client_queue(host, 7), u64(6))
	testing.expect_value(t, db.host_client_dropped(host, 7), u64(1))
	testing.expect(t, db.host_client_should_drop(host, 7))

	// Draining frees room again, but the drop flag stays until disconnect.
	db.host_client_dequeue(host, 7, 6)
	testing.expect(t, db.host_client_enqueue(host, 7, 6))
	testing.expect(t, db.host_client_should_drop(host, 7))
	db.host_client_disconnect(host, 7)
	testing.expect_value(t, db.host_client_count(host), 0)
	testing.expect(t, !db.host_client_should_drop(host, 7))
}

@(test)
test_snapshot_reads_do_not_block_writers :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "snapshot_reads")
	if store == nil do return
	defer destroy_host(store, host, "snapshot_reads")

	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO s (id, label) VALUES (1, 'before')")

	// A read transaction is open while a writer commits: with snapshot reads the
	// commit does not wait for the reader.
	reader := db.tx_begin_read(store)
	run_done(t, store, "INSERT INTO s (id, label) VALUES (2, 'after')")
	run_done(t, store, "UPDATE s SET label = 'changed' WHERE id = 1")

	// The open reader keeps its view of the data.
	old, old_err := db.sql_execute_in_tx(reader, "SELECT count(*) FROM s")
	testing.expect(t, db.error_ok(old_err))
	testing.expect_value(t, old.rows[0][0].i, i64(1))
	db.sql_result_destroy(&old)
	old_row, old_row_err := db.sql_execute_in_tx(reader, "SELECT label FROM s")
	testing.expect(t, db.error_ok(old_row_err))
	testing.expect_value(t, old_row.rows[0][0].s, "before")
	db.sql_result_destroy(&old_row)
	db.tx_end(reader)

	// A fresh read sees everything the writer committed.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM s").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT label FROM s WHERE id = 1").s, "changed")

	// Metadata statements still work inside a snapshot transaction.
	meta := db.tx_begin_read(store)
	shown, show_err := db.sql_execute_in_tx(meta, "SHOW tables")
	testing.expect(t, db.error_ok(show_err))
	found := false
	for row in shown.rows do if row[0].s == "s" do found = true
	testing.expect(t, found)
	db.sql_result_destroy(&shown)
	explained, explain_err := db.sql_execute_in_tx(meta, "EXPLAIN SELECT * FROM s")
	testing.expect(t, db.error_ok(explain_err))
	db.sql_result_destroy(&explained)
	db.tx_end(meta)
}

@(test)
test_result_row_ids :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "row_ids")
	if store == nil do return
	defer destroy_host(store, host, "row_ids")

	run_done(t, store, "CREATE TABLE r (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO r (id, label) VALUES (10, 'a')")
	run_done(t, store, "INSERT INTO r (id, label) VALUES (20, 'b')")

	result := run(t, store, "SELECT label FROM r ORDER BY id")
	testing.expect_value(t, len(result.row_ids), 2)
	// Row ids start at one, as SQLite's rowid does.
	testing.expect_value(t, u64(result.row_ids[0]), u64(1))
	testing.expect_value(t, u64(result.row_ids[1]), u64(2))
	db.sql_result_destroy(&result)

	run_done(t, store, "DELETE FROM r WHERE id = 10")
	after := run(t, store, "SELECT label FROM r")
	testing.expect_value(t, len(after.row_ids), 1)
	testing.expect_value(t, u64(after.row_ids[0]), u64(2))
	db.sql_result_destroy(&after)

	// Aggregates and joins have no single source row.
	counted := run(t, store, "SELECT count(*) FROM r")
	testing.expect_value(t, len(counted.row_ids), 1)
	testing.expect_value(t, counted.row_ids[0], db.NO_ROW_ID)
	db.sql_result_destroy(&counted)
}

@(test)
test_limited_scan_row_ids_are_stored :: proc(t: ^testing.T) {
	// A scan frees each source slice once it has projected the row, so the row
	// id has to be read from the source *before* the delete. This runs on the
	// real heap on purpose: the tracking allocator leaves freed bytes alone, but
	// the heap writes its free-list link exactly where the row id sits, which is
	// what made the bug visible in production.
	old_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer context.allocator = old_allocator

	store := fresh_db(t, "scan_ids")
	if store == nil do return
	defer cleanup_db(store, "scan_ids")

	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	for i in 1 ..= 400 do run(t, store, fmt.tprintf("INSERT INTO s (id, name) VALUES (%d, 'n%d')", i, i))

	limited := run(t, store, "SELECT id, name FROM s WHERE id % 7 = 0 ORDER BY id DESC LIMIT 5")
	defer db.sql_result_destroy(&limited)
	testing.expect_value(t, len(limited.rows), 5)
	testing.expect_value(t, len(limited.row_ids), 5)
	seen: [5]u64
	for i in 0 ..< 5 {
		testing.expect_value(t, limited.rows[i][0].i % 7, i64(0))
		id := u64(limited.row_ids[i])
		testing.expect(t, id < 400, "a row id must name a stored row, not freed memory")
		for previous in seen[:i] do testing.expect(t, previous != id, "row ids must be distinct")
		seen[i] = id
	}

	// A second execution of the same query sees the same ids.
	again := run(t, store, "SELECT id, name FROM s WHERE id % 7 = 0 ORDER BY id DESC LIMIT 5")
	defer db.sql_result_destroy(&again)
	for i in 0 ..< 5 do testing.expect_value(t, u64(again.row_ids[i]), seen[i])
}

@(test)
test_incremental_subscriptions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "incremental")
	if store == nil do return
	defer destroy_host(store, host, "incremental")

	run_done(t, store, "CREATE TABLE inc (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO inc (id, label) VALUES (2, 'two')")

	id, snapshot, err := db.host_subscribe(host, "SELECT id, label FROM inc WHERE id > 1")
	defer db.host_rows_destroy(snapshot)
	if !testing.expectf(t, db.error_ok(err), "subscribe failed: %s", err.message) do return
	testing.expect_value(t, len(snapshot), 1)
	testing.expect_value(t, snapshot[0][1].s, "two")

	counters: ^[3]int = &{0, 0, 0}
	on_update :: proc(ctx: rawptr, update: ^db.Subscription_Update) {
		values := (^[3]int)(ctx)
		values[0] += len(update.inserts)
		values[1] += len(update.deletes)
		if len(update.inserts) > 0 do values[2] = int(update.inserts[0][0].i)
	}
	host.on_update = on_update
	host.on_update_ctx = counters

	// A matching insert becomes one incremental insert.
	run_done(t, store, "INSERT INTO inc (id, label) VALUES (3, 'three')")
	testing.expect_value(t, counters[0], 1)
	testing.expect_value(t, counters[1], 0)
	testing.expect_value(t, counters[2], 3)
	testing.expect(t, db.host_incremental_updates(host) >= 1)

	// A non-matching insert changes nothing.
	counters[0] = 0
	counters[1] = 0
	run_done(t, store, "INSERT INTO inc (id, label) VALUES (1, 'one')")
	testing.expect_value(t, counters[0], 0)
	testing.expect_value(t, counters[1], 0)

	// An update that keeps the row matching is a delete plus an insert.
	counters[0] = 0
	counters[1] = 0
	run_done(t, store, "UPDATE inc SET label = 'TWO' WHERE id = 2")
	testing.expect_value(t, counters[0], 1)
	testing.expect_value(t, counters[1], 1)

	// An update that moves a row out of the filter is a delete only.
	counters[0] = 0
	counters[1] = 0
	run_done(t, store, "UPDATE inc SET id = 0 WHERE id = 3")
	testing.expect_value(t, counters[0], 0)
	testing.expect_value(t, counters[1], 1)

	// A delete removes the cached row.
	counters[0] = 0
	counters[1] = 0
	run_done(t, store, "DELETE FROM inc WHERE id = 2")
	testing.expect_value(t, counters[0], 0)
	testing.expect_value(t, counters[1], 1)

	// The cached set is empty now; a fresh evaluation would agree.
	testing.expect(t, db.host_unsubscribe(host, id))
}

@(test)
test_foreign_key_catalog :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "fk_catalog")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "fk_catalog")
	if store == nil do return

	run_done(t, store, "CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)")
	run(
		t,
		store,
		"CREATE TABLE books (id INTEGER PRIMARY KEY, author INTEGER, title TEXT, FOREIGN KEY (author) REFERENCES authors (id) ON DELETE CASCADE)",
	)
	books := store.tables["books"].schema
	testing.expect_value(t, len(books.foreign_keys), 1)
	fk := books.foreign_keys[0]
	testing.expect_value(t, fk.ref_table, "authors")
	testing.expect_value(t, fk.ref_columns[0], 0)
	testing.expect_value(t, fk.on_delete, db.Foreign_Key_Action.Cascade)
	testing.expect_value(t, fk.on_update, db.Foreign_Key_Action.Restrict)

	// The parent must exist and key its referenced columns uniquely.
	dropped_result_5904, missing := db.sql_execute(
		store,
		"CREATE TABLE bad (id INTEGER PRIMARY KEY, other INTEGER, FOREIGN KEY (other) REFERENCES ghosts (id))",
	)
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_5904)
	testing.expect(t, !db.error_ok(missing))
	// A key naming no unique key of its parent is declared, as SQLite declares
	// it; enforcing it fails with "foreign key mismatch".
	dropped_result_6037, not_unique := db.sql_execute(
		store,
		"CREATE TABLE bad2 (id INTEGER PRIMARY KEY, other INTEGER, FOREIGN KEY (other) REFERENCES authors (name))",
	)
	defer db.error_free(&not_unique)
	defer db.sql_result_destroy(&dropped_result_6037)
	testing.expect(t, db.error_ok(not_unique))
	mismatch := run_error(t, store, "INSERT INTO bad2 VALUES (1, 1)")
	testing.expect_value(t, mismatch.message, `foreign key mismatch - "bad2" referencing "authors"`)
	dropped_result_5918, bad_column := db.sql_execute(
		store,
		"CREATE TABLE bad3 (id INTEGER PRIMARY KEY, other INTEGER, FOREIGN KEY (other) REFERENCES authors (nope))",
	)
	defer db.error_free(&bad_column)
	defer db.sql_result_destroy(&dropped_result_5918)
	testing.expect(t, !db.error_ok(bad_column))

	// The constraint survives the schema codec.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	after := reopened.tables["books"].schema.foreign_keys
	testing.expect_value(t, len(after), 1)
	testing.expect_value(t, after[0].ref_table, "authors")
	testing.expect_value(t, after[0].on_delete, db.Foreign_Key_Action.Cascade)
}

@(test)
test_foreign_key_enforcement :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "fk_enforce")
	if store == nil do return
	defer destroy_host(store, host, "fk_enforce")

	run_done(t, store, "CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE TABLE books (id INTEGER PRIMARY KEY, author INTEGER, title TEXT, FOREIGN KEY (author) REFERENCES authors (id))")
	run_done(t, store, "CREATE TABLE reviews (id INTEGER PRIMARY KEY, book INTEGER, FOREIGN KEY (book) REFERENCES books (id) ON DELETE CASCADE)")
	run_done(t, store, "INSERT INTO authors (id, name) VALUES (1, 'a')")

	// A child needs its parent.
	dropped_result_5995, missing := db.sql_execute(store, "INSERT INTO books (id, author, title) VALUES (1, 9, 'x')")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_5995)
	testing.expect_value(t, missing.kind, db.Error_Kind.Foreign_Key_Violation)
	testing.expect_value(t, missing.message, "FOREIGN KEY constraint failed")
	run_done(t, store, "INSERT INTO books (id, author, title) VALUES (1, 1, 'x')")
	// NULL keys are not enforced.
	run_done(t, store, "INSERT INTO books (id, author, title) VALUES (2, NULL, 'y')")

	// RESTRICT (the default) refuses to delete a referenced parent.
	dropped_result_6003, restricted := db.sql_execute(store, "DELETE FROM authors WHERE id = 1")
	defer db.error_free(&restricted)
	defer db.sql_result_destroy(&dropped_result_6003)
	testing.expect_value(t, restricted.kind, db.Error_Kind.Foreign_Key_Violation)

	// A cascade chains through grandchildren.
	run_done(t, store, "INSERT INTO reviews (id, book) VALUES (1, 1)")
	run_done(t, store, "DELETE FROM books WHERE id = 1")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM reviews").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM books").i, i64(1))

	// ON UPDATE CASCADE rewrites the children's key.
	run_done(t, store, "CREATE TABLE profiles (id INTEGER PRIMARY KEY, bio TEXT)")
	run_done(t, store, "CREATE TABLE owners (id INTEGER PRIMARY KEY, profile INTEGER, FOREIGN KEY (profile) REFERENCES profiles (id) ON DELETE CASCADE ON UPDATE CASCADE)")
	run_done(t, store, "INSERT INTO profiles (id, bio) VALUES (5, 'b')")
	run_done(t, store, "INSERT INTO owners (id, profile) VALUES (1, 5)")
	run_done(t, store, "UPDATE profiles SET id = 6 WHERE id = 5")
	testing.expect_value(t, scalar(t, store, "SELECT profile FROM owners WHERE id = 1").i, i64(6))

	// ON UPDATE RESTRICT reports the reference.
	dropped_result_6106, update_blocked := db.sql_execute(store, "UPDATE authors SET id = 2 WHERE id = 1")
	defer db.error_free(&update_blocked)
	defer db.sql_result_destroy(&dropped_result_6106)
	testing.expect(t, db.error_ok(update_blocked))

	// A child insert with a staged parent in the same transaction works.
	tx := db.tx_begin_write(store)
	run_tx := proc(t: ^testing.T, tx: ^db.Tx) {
		dropped_result_6112, err1 := db.sql_execute_in_tx(tx, "INSERT INTO authors (id, name) VALUES (7, 'seven')")
		defer db.error_free(&err1)
		defer db.sql_result_destroy(&dropped_result_6112)
		testing.expect(t, db.error_ok(err1))
		dropped_result_6114, err2 := db.sql_execute_in_tx(tx, "INSERT INTO books (id, author, title) VALUES (7, 7, 'seven')")
		defer db.error_free(&err2)
		defer db.sql_result_destroy(&dropped_result_6114)
		testing.expect(t, db.error_ok(err2))
	}
	run_tx(t, tx)
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM books WHERE author = 7").i, i64(1))
}

bounded_module_call :: proc(
	ctx: ^db.Module_Context,
	reducer: string,
	args: []db.Value,
) -> (db.Value, db.Error) {
	if reducer == "alloc" {
		total := 0
		for {
			_, alloc_err := mem.alloc_bytes(1024, 8, ctx.alloc)
			if alloc_err != .None do break
			total += 1024
			if total > 1024 * 1024 do break
		}
		return db.value_int(i64(total)), db.ERROR_NONE
	}
	if reducer == "charge" {
		// Charge more rows than any quota would allow.
		db.module_charge_rows(ctx, 10)
		return db.value_int(i64(ctx.rows_used)), db.ERROR_NONE
	}
	return db.value_null(), db.ERROR_NONE
}

@(test)
test_module_abi_v2 :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "module_v2")
	if store == nil do return
	defer destroy_host(store, host, "module_v2")

	// A 4 KiB budget bounds the module's arena.
	db.host_set_module_limits(host, 4 * 1024, 5)
	memory, rows := db.host_module_limits(host)
	testing.expect_value(t, memory, 4 * 1024)
	testing.expect_value(t, rows, u64(5))

	init_ctx_rows_limit: u64
	inited := false
	init_v2 :: proc(ctx: ^db.Module_Context) -> db.Error {
		return db.ERROR_NONE
	}
	call_v2 :: proc(ctx: ^db.Module_Context, reducer: string, args: []db.Value) -> (db.Value, db.Error) {
		return bounded_module_call(ctx, reducer, args)
	}
	_ = init_ctx_rows_limit
	_ = inited
	module := db.Module {
		abi_version = 2,
		name        = "bounded",
		init_v2     = init_v2,
		call_v2     = call_v2,
	}
	testing.expect(t, db.error_ok(db.host_register_module(host, module)))

	// Allocating past the buffer fails instead of growing without bound.
	allocated, alloc_err := db.host_call_module(host, "bounded", "alloc", nil)
	testing.expect(t, db.error_ok(alloc_err))
	testing.expect(t, allocated.i > 0)
	testing.expect(t, allocated.i <= i64(4 * 1024))

	// Overrunning the row quota is reported.
	_, quota_err := db.host_call_module(host, "bounded", "charge", nil)
	defer db.error_free(&quota_err)
	testing.expect_value(t, quota_err.kind, db.Error_Kind.Quota_Exceeded)

	// v1 modules still register and run.
	v1_call :: proc(host_ptr: ^db.Host, reducer: string, args: []db.Value) -> (db.Value, db.Error) {
		return db.value_int(41), db.ERROR_NONE
	}
	v1 := db.Module{abi_version = 1, name = "legacy", call = v1_call}
	testing.expect(t, db.error_ok(db.host_register_module(host, v1)))
	legacy, legacy_err := db.host_call_module(host, "legacy", "answer", nil)
	testing.expect(t, db.error_ok(legacy_err))
	testing.expect_value(t, legacy.i, i64(41))

	// An unknown ABI is rejected.
	bad := db.Module{abi_version = 7, name = "bad"}
	testing.expect(t, !db.error_drop(db.host_register_module(host, bad)))
	names := db.host_module_names(host, context.allocator)
	defer delete(names)
	testing.expect_value(t, len(names), 2)
}

@(test)
test_client_call_and_poll :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "cli_poll")
	if store == nil do return
	defer destroy_host(store, host, "cli_poll")

	run_done(t, store, "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO items (id, label) VALUES (1, 'one')")

	insert_one :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		dropped_result_6214, err := db.sql_execute_in_tx(ctx.tx, "INSERT INTO items (id, label) VALUES (2, 'two')")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_6214)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(host, "insert_one", nil, insert_one)))

	session := sdk.client_init(sdk_route, host)

	// call: the CLI path for `miraidb call`.
	called, call_err := sdk.client_call(&session, "insert_one", nil, context.allocator)
	testing.expect(t, db.error_ok(call_err))
	db.sql_result_destroy(&called)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM items").i, i64(2))

	// subscribe: two snapshots and the diff the CLI prints.
	first, first_err := sdk.client_query(&session, "SELECT id, label FROM items", context.allocator)
	testing.expect(t, db.error_ok(first_err))
	testing.expect_value(t, len(first.rows), 2)

	run_done(t, store, "INSERT INTO items (id, label) VALUES (3, 'three')")
	run_done(t, store, "DELETE FROM items WHERE id = 1")
	second, second_err := sdk.client_query(&session, "SELECT id, label FROM items", context.allocator)
	testing.expect(t, db.error_ok(second_err))

	delta := sdk.client_poll_diff(first.rows, second.rows, context.allocator)
	testing.expect_value(t, len(delta.inserts), 1)
	testing.expect_value(t, delta.inserts[0][1].s, "three")
	testing.expect_value(t, len(delta.deletes), 1)
	testing.expect_value(t, delta.deletes[0][1].s, "one")
	sdk.poll_delta_destroy(&delta)

	// No changes means no delta.
	quiet := sdk.client_poll_diff(second.rows, second.rows, context.allocator)
	testing.expect_value(t, len(quiet.inserts), 0)
	testing.expect_value(t, len(quiet.deletes), 0)
	sdk.poll_delta_destroy(&quiet)

	db.sql_result_destroy(&first)
	db.sql_result_destroy(&second)
}

@(test)
test_postgres_describe_plans_only :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "pgplan")
	if store == nil do return
	defer destroy_host(store, host, "pgplan")

	run_done(t, store, "CREATE TABLE d (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO d (id, label) VALUES (1, 'x')")

	session := db.pg_session_init()
	defer db.pg_session_destroy(session)

	// A statement whose WHERE would fail at run time still describes: the planner
	// only reads the AST and the projection list.
	parse_body := make([dynamic]u8)
	defer delete(parse_body)
	append(&parse_body, ..transmute([]u8)string("q"))
	append(&parse_body, 0)
	append(&parse_body, ..transmute([]u8)string("SELECT id AS boom FROM d WHERE ghost = 1"))
	append(&parse_body, 0, 0, 0)
	parse := pg_build_frontend('P', parse_body[:])
	defer delete(parse)
	response, _ := db.pg_handle_session_message(host, session, parse)
	delete(response)

	describe_body := make([dynamic]u8)
	defer delete(describe_body)
	append(&describe_body, 'S')
	append(&describe_body, ..transmute([]u8)string("q"))
	append(&describe_body, 0)
	describe := pg_build_frontend('D', describe_body[:])
	defer delete(describe)
	response, _ = db.pg_handle_session_message(host, session, describe)
	// ParameterDescription then RowDescription with the alias.
	testing.expect_value(t, response[0], u8('t'))
	testing.expect(t, strings_contains(string(response), "boom"))
	delete(response)

	// `SELECT *` expands to the table's columns without executing.
	star_parse := make([dynamic]u8)
	defer delete(star_parse)
	append(&star_parse, ..transmute([]u8)string("s"))
	append(&star_parse, 0)
	append(&star_parse, ..transmute([]u8)string("SELECT * FROM d"))
	append(&star_parse, 0, 0, 0)
	packet := pg_build_frontend('P', star_parse[:])
	defer delete(packet)
	response, _ = db.pg_handle_session_message(host, session, packet)
	delete(response)

	star_describe_body := make([dynamic]u8)
	defer delete(star_describe_body)
	append(&star_describe_body, 'S')
	append(&star_describe_body, ..transmute([]u8)string("s"))
	append(&star_describe_body, 0)
	star_describe := pg_build_frontend('D', star_describe_body[:])
	defer delete(star_describe)
	response, _ = db.pg_handle_session_message(host, session, star_describe)
	testing.expect(t, strings_contains(string(response), "id"))
	testing.expect(t, strings_contains(string(response), "label"))
	delete(response)

	// Executing the same statement does fail, which proves Describe never ran it.
	bind_body := make([dynamic]u8)
	defer delete(bind_body)
	append(&bind_body, ..transmute([]u8)string("p"))
	append(&bind_body, 0)
	append(&bind_body, ..transmute([]u8)string("q"))
	append(&bind_body, 0, 0, 0, 0, 0, 0, 0)
	bind := pg_build_frontend('B', bind_body[:])
	defer delete(bind)
	response, _ = db.pg_handle_session_message(host, session, bind)
	delete(response)

	execute_body := make([dynamic]u8)
	defer delete(execute_body)
	append(&execute_body, ..transmute([]u8)string("p"))
	append(&execute_body, 0, 0, 0, 0, 0)
	execute := pg_build_frontend('E', execute_body[:])
	defer delete(execute)
	response, _ = db.pg_handle_session_message(host, session, execute)
	testing.expect_value(t, response[0], u8('E'))
	delete(response)
}

@(test)
test_delete_releases_versions :: proc(t: ^testing.T) {
	// Regression: a deleted row used to record its live values twice (as the row
	// value and as a version), so closing the table freed them twice.
	path := fmt.aprintf("_test_%s", "delete_versions")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "delete_versions")
	if store == nil do return

	run_done(t, store, "CREATE TABLE d (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO d (id, label) VALUES (1, 'one')")
	run_done(t, store, "UPDATE d SET label = 'two' WHERE id = 1")
	run_done(t, store, "DELETE FROM d WHERE id = 1")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM d").i, i64(0))

	// Pruning the tombstone and closing the store must free every value once.
	db.store_prune_versions(store, store.commit_seq)
	db.host_destroy(host)
	db.store_close(store)

	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM d").i, i64(0))
	// Replay of the delete must leave the same state, and the table stays usable.
	run_done(t, reopened, "INSERT INTO d (id, label) VALUES (2, 'again')")
	testing.expect_value(t, scalar(t, reopened, "SELECT label FROM d").s, "again")
}

// dump_database renders the schema and every user table as one canonical string,
// so two stores can be compared.
dump_database :: proc(t: ^testing.T, store: ^db.Store) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	tables := run(t, store, "SHOW tables")
	defer db.sql_result_destroy(&tables)
	for row in tables.rows {
		name := row[0].s
		if strings.has_prefix(name, "_") do continue
		strings.write_string(&builder, "table ")
		strings.write_string(&builder, name)
		strings.write_string(&builder, "\n")
		columns := run(t, store, fmt.tprintf("SELECT name, type, named FROM _columns WHERE table = '%s' ORDER BY name", name))
		defer db.sql_result_destroy(&columns)
		for column in columns.rows {
			strings.write_string(&builder, "  col ")
			strings.write_string(&builder, column[0].s)
			strings.write_string(&builder, " ")
			strings.write_string(&builder, column[1].s)
			strings.write_string(&builder, " [")
			strings.write_string(&builder, column[2].s)
			strings.write_string(&builder, "]\n")
		}
		indexes := run(t, store, fmt.tprintf("SELECT name, columns FROM _indexes WHERE table = '%s' ORDER BY name", name))
		defer db.sql_result_destroy(&indexes)
		for index in indexes.rows {
			strings.write_string(&builder, "  idx ")
			strings.write_string(&builder, index[0].s)
			strings.write_string(&builder, " (")
			strings.write_string(&builder, index[1].s)
			strings.write_string(&builder, ")\n")
		}
		// SELECT without ORDER BY has no defined order, so the dump sorts by id.
		rows := run(t, store, fmt.tprintf("SELECT * FROM %s ORDER BY id", name))
		defer db.sql_result_destroy(&rows)
		for row_cells in rows.rows {
			strings.write_string(&builder, "  row")
			for value in row_cells {
				strings.write_string(&builder, "|")
				strings.write_string(&builder, db.value_format(value, context.temp_allocator))
			}
			strings.write_string(&builder, "\n")
		}
	}
	// to_string borrows the builder's buffer, so the caller gets its own copy and
	// the builder below can still be destroyed.
	return strings.clone(strings.to_string(builder))
}

@(test)
test_kitchen_sink_replay :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "kitchen_sink")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "kitchen_sink")
	if store == nil do return

	run_done(t, store, "CREATE TYPE tags AS ARRAY(TEXT)")
	run(
		t,
		store,
		"CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT NOT NULL, tags tags, pair PRODUCT(INT, TEXT), maybe OPTION(INT))",
	)
	run(
		t,
		store,
		"CREATE TABLE children (id INTEGER PRIMARY KEY, code TEXT, parent INTEGER, CONSTRAINT children_parent FOREIGN KEY (parent) REFERENCES parents (id) ON DELETE CASCADE)",
	)
	run_done(t, store, "CREATE UNIQUE INDEX children_code ON children USING DIRECT (code)")
	run_done(t, store, "CREATE INDEX children_parent_idx ON children USING HASH (parent)")
	run_done(t, store, "CREATE TABLE log_events (id INTEGER PRIMARY KEY, note TEXT) ")
	run_done(t, store, "CREATE EVENT TABLE audit (id INTEGER PRIMARY KEY, what TEXT)")
	run_done(t, store, "CREATE VIEW child_codes AS SELECT code FROM children WHERE code IS NOT NULL")
	run_done(t, store, "INSERT INTO parents (id, name, maybe) VALUES (1, 'p', 7)")
	run_done(t, store, "INSERT INTO children (id, code, parent) VALUES (1, 'c1', 1)")
	run_done(t, store, "INSERT INTO children (id, code, parent) VALUES (2, 'c2', 1)")
	run_done(t, store, "UPDATE children SET code = 'c2b' WHERE id = 2")
	run_done(t, store, "DELETE FROM children WHERE id = 1")
	run_done(t, store, "ALTER TABLE parents ADD COLUMN extra TEXT")
	run_done(t, store, "INSERT INTO parents (id, name, extra) VALUES (2, 'q', 'e')")

	before := dump_database(t, store)
	defer delete(before)
	testing.expect(t, strings_contains(before, "children"))
	testing.expect(t, strings_contains(before, "c2b"))

	// Snapshot, compact, close and reopen: the dump must not change.
	db.store_snapshot(store)
	run_done(t, store, "INSERT INTO log_events (id, note) VALUES (1, 'x')")
	delete(before)
	before = dump_database(t, store)
	db.host_destroy(host)
	db.store_close(store)

	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	after := dump_database(t, reopened)
	defer delete(after)
	testing.expect_value(t, after, before)
	// The named reference, the FK and the direct index survive.
	testing.expect_value(t, reopened.tables["children"].schema.foreign_keys[0].ref_table, "parents")
	testing.expect_value(t, reopened.tables["children"].schema.indexes[1].algorithm, db.Index_Algorithm.Direct)
}

@(test)
test_index_matches_full_scan :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "index_scan")
	if store == nil do return
	defer destroy_host(store, host, "index_scan")

	run_done(t, store, "CREATE TABLE indexed (id INTEGER PRIMARY KEY, grp TEXT, n INTEGER)")
	run_done(t, store, "CREATE TABLE plain (id INTEGER PRIMARY KEY, grp TEXT, n INTEGER)")
	run_done(t, store, "CREATE INDEX indexed_grp ON indexed USING HASH (grp)")
	for i in 1 ..= 20 {
		grp := i % 3 == 0 ? "b" : "a"
		run_done(t, store, fmt.tprintf("INSERT INTO indexed (id, grp, n) VALUES (%d, '%s', %d)", i, grp, i))
		run_done(t, store, fmt.tprintf("INSERT INTO plain (id, grp, n) VALUES (%d, '%s', %d)", i, grp, i))
	}
	run_done(t, store, "UPDATE indexed SET grp = 'c' WHERE id = 4")
	run_done(t, store, "UPDATE plain SET grp = 'c' WHERE id = 4")
	run_done(t, store, "DELETE FROM indexed WHERE id = 7")
	run_done(t, store, "DELETE FROM plain WHERE id = 7")

	predicates := []string{
		"grp = 'a'",
		"grp = 'b'",
		"grp = 'c'",
		"grp = 'missing'",
		"grp = 'a' AND n > 10",
		"grp = 'a' OR n = 7",
		"n BETWEEN 3 AND 6",
		"grp IS NULL",
	}
	for predicate in predicates {
		indexed := run(t, store, fmt.tprintf("SELECT id, grp, n FROM indexed WHERE %s ORDER BY id", predicate))
		defer db.sql_result_destroy(&indexed)
		plain := run(t, store, fmt.tprintf("SELECT id, grp, n FROM plain WHERE %s ORDER BY id", predicate))
		defer db.sql_result_destroy(&plain)
		testing.expect_value(t, len(indexed.rows), len(plain.rows))
		for row, i in indexed.rows {
			for value, j in row {
				testing.expect(t, db.value_equal(value, plain.rows[i][j]))
			}
		}
	}
	// ORDER BY through the index agrees with a sort of the full scan.
	ordered := run(t, store, "SELECT id FROM indexed ORDER BY grp, id")
	defer db.sql_result_destroy(&ordered)
	sorted_plain := run(t, store, "SELECT id FROM plain ORDER BY grp, id")
	defer db.sql_result_destroy(&sorted_plain)
	testing.expect_value(t, len(ordered.rows), len(sorted_plain.rows))
	for row, i in ordered.rows {
		testing.expect_value(t, row[0].i, sorted_plain.rows[i][0].i)
	}
}

@(test)
test_soak_update_delete_prune :: proc(t: ^testing.T) {
	// Its own directory: the workload soak next door uses `_test_soak`, and a
	// handle this test leaves behind must not refuse that one.
	path := fmt.aprintf("_test_%s", "soak_prune")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "soak_prune")
	if store == nil do return

	run_done(t, store, "CREATE TABLE soak (id INTEGER PRIMARY KEY, n INTEGER)")
	expected := make(map[i64]bool)
	defer delete(expected)
	for i in 1 ..= 50 {
		run_done(t, store, fmt.tprintf("INSERT INTO soak (id, n) VALUES (%d, %d)", i, i))
		expected[i64(i)] = true
	}
	// Churn: updates, deletes and reinserts keep the version chains busy.
	for round in 0 ..< 40 {
		id := i64(round % 25 + 1)
		run_done(t, store, fmt.tprintf("UPDATE soak SET n = n + 1 WHERE id = %d", id))
		if round % 3 == 0 {
			run_done(t, store, fmt.tprintf("DELETE FROM soak WHERE id = %d", id))
			delete_key(&expected, id)
			run_done(t, store, fmt.tprintf("INSERT INTO soak (id, n) VALUES (%d, %d)", id, round))
			expected[id] = true
		}
		if round % 10 == 0 do db.store_prune_versions(store, store.commit_seq)
	}
	rows := run(t, store, "SELECT id FROM soak ORDER BY id")
	defer db.sql_result_destroy(&rows)
	testing.expect_value(t, len(rows.rows), len(expected))
	for row in rows.rows do testing.expect(t, row[0].i in expected)

	// Close with tombstones and history alive, then reopen and compare counts.
	db.store_prune_versions(store, store.commit_seq)
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	again := run(t, reopened, "SELECT id FROM soak ORDER BY id")
	defer db.sql_result_destroy(&again)
	testing.expect_value(t, len(again.rows), len(expected))
}

// --- SQLite file format ----------------------------------------------------

SQLITE_FIXTURE :: "src/tests/fixtures/tiny.sqlite"

@(test)
test_sqlite_read_fixture :: proc(t: ^testing.T) {
	file, open_err := db.sqlite_file_open(SQLITE_FIXTURE)
	if !testing.expectf(t, db.error_ok(open_err), "open fixture: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	testing.expect_value(t, file.page_size, u32(512))
	testing.expect_value(t, len(file.tables), 2)
	testing.expect_value(t, file.tables[0].name, "people")
	testing.expect_value(t, file.tables[0].pk_position, 0)
	testing.expect_value(t, file.tables[1].name, "tags")
	testing.expect(t, file.tables[1].without_rowid)

	rows, rows_err := db.sqlite_table_rows(&file, &file.tables[0], context.temp_allocator)
	if !testing.expectf(t, db.error_ok(rows_err), "rows: %s", rows_err.message) do return
	testing.expect_value(t, len(rows), 4)
	// Integer primary key, text, real and blob values.
	testing.expect_value(t, rows[0][0].i, i64(1))
	testing.expect_value(t, rows[0][1].s, "Ada")
	testing.expect_value(t, rows[0][2].f, 9.5)
	testing.expect_value(t, len(rows[0][3].bytes), 3)
	// Nulls and negative numbers survive.
	testing.expect(t, db.value_is_null(rows[1][3]))
	testing.expect_value(t, rows[1][2].f, -1.25)
	// A text longer than a page goes through the overflow chain intact.
	testing.expect_value(t, len(rows[2][1].s), 809)
	testing.expect(t, strings.has_prefix(rows[2][1].s, "overflow-"))
	// A rowid column left null in the record is filled from the cell key.
	testing.expect_value(t, rows[3][0].i, i64(9))
	testing.expect_value(t, rows[3][1].s, "Lin")

	tag_rows, tag_err := db.sqlite_table_rows(&file, &file.tables[1], context.temp_allocator)
	if !testing.expectf(t, db.error_ok(tag_err), "tags: %s", tag_err.message) do return
	testing.expect_value(t, len(tag_rows), 3)
	testing.expect_value(t, tag_rows[0][0].s, "a")
	testing.expect_value(t, tag_rows[2][1].s, "gamma")
}

@(test)
test_sqlite_import_queries :: proc(t: ^testing.T) {
	file, open_err := db.sqlite_file_open(SQLITE_FIXTURE)
	if !testing.expectf(t, db.error_ok(open_err), "open fixture: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	store := fresh_db(t, "sqlite_import")
	if store == nil do return
	defer cleanup_db(store, "sqlite_import")

	tables, rows, import_err := db.sqlite_import(&file, store)
	if !testing.expectf(t, db.error_ok(import_err), "import: %s", import_err.message) do return
	testing.expect_value(t, tables, 2)
	testing.expect_value(t, rows, 7)

	names := run(t, store, "SELECT name FROM people WHERE score IS NOT NULL ORDER BY score DESC")
	defer db.sql_result_destroy(&names)
	testing.expect_value(t, len(names.rows), 3)
	testing.expect_value(t, names.rows[0][0].s, "Ada")
	count := scalar(t, store, "SELECT count(*) FROM tags")
	testing.expect_value(t, count.i, i64(3))
	long := run(t, store, "SELECT name FROM people WHERE id = 7")
	defer db.sql_result_destroy(&long)
	testing.expect_value(t, len(long.rows[0][0].s), 809)
}

// A WITHOUT ROWID table stores its key first; what SQLite 3.54.1 wrote in the
// fixture has to come back in the columns the table declares.
@(test)
test_sqlite_import_without_rowid_order :: proc(t: ^testing.T) {
	file, open_err := db.sqlite_file_open("src/tests/fixtures/without_rowid.sqlite")
	if !testing.expectf(t, db.error_ok(open_err), "open fixture: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	store := fresh_db(t, "sqlite_import_without_rowid")
	if store == nil do return
	defer cleanup_db(store, "sqlite_import_without_rowid")

	tables, rows, import_err := db.sqlite_import(&file, store)
	if !testing.expectf(t, db.error_ok(import_err), "import: %s", import_err.message) do return
	testing.expect_value(t, tables, 2)
	testing.expect_value(t, rows, 6)

	w := run(t, store, "SELECT b, a, c FROM w ORDER BY a")
	defer db.sql_result_destroy(&w)
	testing.expect_value(t, len(w.rows), 3)
	testing.expect_value(t, w.rows[0][0].i, i64(2))
	testing.expect_value(t, w.rows[0][1].s, "a")
	testing.expect_value(t, w.rows[0][2].i, i64(30))
	testing.expect(t, db.value_is_null(w.rows[1][0]))
	testing.expect_value(t, w.rows[1][1].s, "m")
	testing.expect_value(t, w.rows[2][1].s, "x")
	testing.expect_value(t, w.rows[2][2].i, i64(3))
	z := run(t, store, "SELECT x, y, z FROM z ORDER BY y")
	defer db.sql_result_destroy(&z)
	testing.expect_value(t, len(z.rows), 3)
	testing.expect_value(t, z.rows[0][0].s, "x1")
	testing.expect_value(t, z.rows[0][2].i, i64(2))
	testing.expect_value(t, z.rows[1][0].s, "x0")
	testing.expect_value(t, z.rows[2][0].s, "x9")
	testing.expect_value(t, z.rows[2][2].i, i64(1))
}

// An index b-tree keeps entries in its interior cells too: a WITHOUT ROWID
// table SQLite 3.54.1 spread over 1 KiB pages loses none of its 1500 rows.
@(test)
test_sqlite_import_without_rowid_pages :: proc(t: ^testing.T) {
	file, open_err := db.sqlite_file_open("src/tests/fixtures/without_rowid_pages.sqlite")
	if !testing.expectf(t, db.error_ok(open_err), "open fixture: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	store := fresh_db(t, "sqlite_import_without_rowid_pages")
	if store == nil do return
	defer cleanup_db(store, "sqlite_import_without_rowid_pages")

	_, rows, import_err := db.sqlite_import(&file, store)
	if !testing.expectf(t, db.error_ok(import_err), "import: %s", import_err.message) do return
	testing.expect_value(t, rows, 1500)
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT id) FROM k").i, i64(1500))
	testing.expect_value(t, scalar(t, store, "SELECT sum(n) FROM k").i, i64(1125750))
}

// An index over several pages stores each entry once, as SQLite's do: the
// entry at a page boundary lives in the interior cell, not on a leaf as well
// (SQLite's integrity_check answered "wrong # of entries in index").
@(test)
test_sqlite_write_index_pages :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "sqlite_write_index_pages")
	if store == nil do return
	defer destroy_host(store, host, "sqlite_write_index_pages")
	run_done(t, store, "CREATE TABLE t (a INT PRIMARY KEY, b TEXT)")
	run_done(t, store, "CREATE INDEX tb ON t (b)")
	tx := db.tx_begin_write(store)
	for i in 1 ..= 3000 {
		dropped_result_6705, err := db.sql_execute_in_tx_params(
			tx,
			"INSERT INTO t (a, b) VALUES (?, ?)",
			[]db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("value-%06d-padding-padding", i))},
		)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_6705)
		testing.expect(t, db.error_ok(err))
	}
	testing.expect(t, db.error_ok(db.tx_commit(tx)))

	path := "_test_sqlite_index_pages.db"
	defer os.remove(path)
	_, rows, write_err := db.sqlite_file_write(store, path)
	if !testing.expectf(t, db.error_ok(write_err), "write: %s", write_err.message) do return
	testing.expect_value(t, rows, 3000)
	ok, reason := db.sqlite_mirror_validate(path)
	testing.expectf(t, ok, "the written file is broken: %s", reason)
}

// A WITHOUT ROWID table is written as SQLite stores it: an index b-tree keyed
// by its primary key, its own text kept, its secondary indexes ending in the
// key instead of a rowid, and no sqlite_master row for the key itself.
@(test)
test_sqlite_write_without_rowid :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "sqlite_write_without_rowid")
	if store == nil do return
	defer destroy_host(store, host, "sqlite_write_without_rowid")
	run_done(t, store, "CREATE TABLE w (b, a TEXT PRIMARY KEY, c INT) WITHOUT ROWID")
	run_done(t, store, "CREATE INDEX wc ON w (c)")
	run_done(t, store, "CREATE TABLE n (id INTEGER PRIMARY KEY, v TEXT) WITHOUT ROWID")
	run_done(t, store, "INSERT INTO w VALUES (1, 'x', 3), (2, 'a', 30), (NULL, 'm', -1)")
	tx := db.tx_begin_write(store)
	for i in 1 ..= 2000 {
		dropped_result_6737, err := db.sql_execute_in_tx_params(tx, "INSERT INTO n VALUES (?, ?)", []db.Value{db.value_int(i64(2001 - i)), db.value_string(fmt.tprintf("v%d", i))})
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_6737)
		testing.expect(t, db.error_ok(err))
	}
	testing.expect(t, db.error_ok(db.tx_commit(tx)))

	path := "_test_sqlite_without_rowid.db"
	defer os.remove(path)
	_, rows, write_err := db.sqlite_file_write(store, path)
	if !testing.expectf(t, db.error_ok(write_err), "write: %s", write_err.message) do return
	testing.expect_value(t, rows, 2003)
	ok, reason := db.sqlite_mirror_validate(path)
	testing.expectf(t, ok, "the written file is broken: %s", reason)

	file, open_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	for table in file.tables {
		testing.expect(t, table.without_rowid)
		if table.name == "w" do testing.expect_value(t, table.sql, "CREATE TABLE w (b, a TEXT PRIMARY KEY, c INT) WITHOUT ROWID")
	}
	for tree in file.index_trees do testing.expectf(t, tree.name == "wc", "unexpected index b-tree %s", tree.name)
	back := fresh_db(t, "sqlite_write_without_rowid_back")
	if back == nil do return
	defer cleanup_db(back, "sqlite_write_without_rowid_back")
	_, imported, import_err := db.sqlite_import(&file, back)
	if !testing.expectf(t, db.error_ok(import_err), "import: %s", import_err.message) do return
	testing.expect_value(t, imported, 2003)
	testing.expect_value(t, scalar(t, back, "SELECT b FROM w WHERE a = 'a'").i, i64(2))
	testing.expect_value(t, scalar(t, back, "SELECT v FROM n WHERE id = 1").s, "v2000")
}

// The index of an empty table is in the file, with an empty b-tree.
@(test)
test_sqlite_write_empty_index :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "sqlite_write_empty_index")
	if store == nil do return
	defer destroy_host(store, host, "sqlite_write_empty_index")
	run_done(t, store, "CREATE TABLE t (a INT PRIMARY KEY, b TEXT)")
	run_done(t, store, "CREATE INDEX tb ON t (b)")

	path := "_test_sqlite_empty_index.db"
	defer os.remove(path)
	_, _, write_err := db.sqlite_file_write(store, path)
	if !testing.expectf(t, db.error_ok(write_err), "write: %s", write_err.message) do return
	file, open_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	names := make([dynamic]string, context.temp_allocator)
	for tree in file.index_trees do append(&names, tree.name)
	testing.expectf(t, slice.contains(names[:], "tb"), "indexes in the file: %v", names[:])
	ok, reason := db.sqlite_mirror_validate(path)
	testing.expectf(t, ok, "the written file is broken: %s", reason)
}

@(test)
test_sqlite_write_roundtrip :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "sqlite_write")
	if store == nil do return
	defer destroy_host(store, host, "sqlite_write")
	run_done(t, store, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score FLOAT, blob_col BLOB, note TEXT)")
	run_done(t, store, "CREATE INDEX people_score ON people (score)")
	run_params(t, store, "INSERT INTO people (id, name, score, blob_col, note) VALUES (?, ?, ?, ?, ?)", []db.Value{
		db.value_int(1), db.value_string("Ada"), db.value_float(9.5), db.value_bytes([]u8{0x61, 0x62, 0x63}), db.value_string("first"),
	})
	run_done(t, store, "INSERT INTO people (id, name, score) VALUES (2, 'Grace', -1.25)")
	// A text longer than a page exercises the overflow chain on the way out.
	long: string
	{
		builder := strings.builder_make()
		strings.write_string(&builder, "overflow-")
		for _ in 0 ..< 900 do strings.write_byte(&builder, 'x')
		long = strings.to_string(builder)
	}
	defer delete(long)
	run_params(t, store, "INSERT INTO people (id, name, note) VALUES (?, ?, ?)", []db.Value{db.value_int(8), db.value_string("Overflow"), db.value_string(long)})

	path := "_test_sqlite_out.db"
	defer os.remove(path)
	tables, rows, write_err := db.sqlite_file_write(store, path)
	if !testing.expectf(t, db.error_ok(write_err), "write: %s", write_err.message) do return
	testing.expect_value(t, tables, 1)
	testing.expect_value(t, rows, 3)

	file, open_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	testing.expect_value(t, file.page_size, u32(4096))
	testing.expect_value(t, len(file.tables), 1)
	testing.expect_value(t, file.tables[0].name, "people")
	// The exported file carries the secondary index; the reader still parses the
	// schema (index b-trees are read by SQLite, not by the importer).
	testing.expect_value(t, len(file.tables[0].columns), 5)
	read, read_err := db.sqlite_table_rows(&file, &file.tables[0], context.temp_allocator)
	if !testing.expectf(t, db.error_ok(read_err), "read: %s", read_err.message) do return
	testing.expect_value(t, len(read), 3)
	testing.expect_value(t, read[0][0].i, i64(1))
	testing.expect_value(t, read[0][1].s, "Ada")
	testing.expect_value(t, read[0][2].f, 9.5)
	testing.expect_value(t, string(read[0][3].bytes), "abc")
	// An omitted column came out as NULL, not as a zero value.
	testing.expect(t, db.value_is_null(read[1][3]))
	testing.expect(t, db.value_is_null(read[1][4]))
	testing.expect_value(t, len(read[2][4].s), 909)
	testing.expect(t, strings.has_prefix(read[2][4].s, "overflow-"))
}

@(test)
test_sqlite_write_many_rows :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "sqlite_write_many")
	if store == nil do return
	defer destroy_host(store, host, "sqlite_write_many")
	run_done(t, store, "CREATE TABLE big (id INTEGER PRIMARY KEY, name TEXT, score FLOAT)")
	tx := db.tx_begin_write(store)
	for i in 1 ..= 300 {
		dropped_result_6851, insert_err := db.sql_execute_in_tx_params(
			tx,
			"INSERT INTO big (id, name, score) VALUES (?, ?, ?)",
			[]db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("row%d", i)), db.value_float(f64(i) / 2)},
		)
		defer db.error_free(&insert_err)
		defer db.sql_result_destroy(&dropped_result_6851)
		testing.expect(t, db.error_ok(insert_err))
	}
	testing.expect(t, db.error_ok(db.tx_commit(tx)))

	path := "_test_sqlite_many.db"
	defer os.remove(path)
	_, rows, write_err := db.sqlite_file_write(store, path)
	if !testing.expectf(t, db.error_ok(write_err), "write: %s", write_err.message) do return
	testing.expect_value(t, rows, 300)

	// The table needs several leaf pages and an interior root; read them all back.
	file, open_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	read, read_err := db.sqlite_table_rows(&file, &file.tables[0], context.temp_allocator)
	if !testing.expectf(t, db.error_ok(read_err), "read: %s", read_err.message) do return
	testing.expect_value(t, len(read), 300)
	testing.expect_value(t, read[0][0].i, i64(1))
	testing.expect_value(t, read[299][0].i, i64(300))
	testing.expect_value(t, read[299][1].s, "row300")
	testing.expect_value(t, read[299][2].f, 150.0)
}

@(test)
test_embed_statement_lifecycle :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "embed open: %s", open_err.message) do return
	defer db.embed_close(conn)
	testing.expect(t, db.error_ok(db.embed_exec(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score FLOAT)")))

	insert := db.embed_prepare(conn, "INSERT INTO t (id, name, score) VALUES (?, ?, ?)")
	if !testing.expect(t, insert != nil) do return
	testing.expect(t, db.error_ok(db.embed_bind_int(insert, 0, 1)))
	testing.expect(t, db.error_ok(db.embed_bind_text(insert, 1, "Ada")))
	testing.expect(t, db.error_ok(db.embed_bind_float(insert, 2, 9.5)))
	has_row, step_err := db.embed_step(insert)
	testing.expect(t, db.error_ok(step_err))
	testing.expect(t, !has_row)
	// The same statement runs again after reset with new bindings.
	db.embed_reset(insert)
	testing.expect(t, db.error_ok(db.embed_bind_int(insert, 0, 2)))
	testing.expect(t, db.error_ok(db.embed_bind_text(insert, 1, "Grace")))
	testing.expect(t, db.error_ok(db.embed_bind_null(insert, 2)))
	has_row, step_err = db.embed_step(insert)
	testing.expect(t, db.error_ok(step_err))
	testing.expect(t, !has_row)
	db.embed_finalize(insert)

	query := db.embed_prepare(conn, "SELECT id, name, score FROM t ORDER BY id")
	if !testing.expect(t, query != nil) do return
	defer db.embed_finalize(query)
	rows := 0
	for {
		has, err := db.embed_step(query)
		if !testing.expect(t, db.error_ok(err)) do break
		if !has do break
		rows += 1
		if rows == 1 {
			// Metadata is available once the statement has produced its first row.
			testing.expect_value(t, db.embed_column_count(query), 3)
			testing.expect_value(t, db.embed_column_name(query, 1), "name")
			testing.expect_value(t, db.embed_column_int(query, 0), i64(1))
			testing.expect_value(t, db.embed_column_text(query, 1), "Ada")
			testing.expect_value(t, db.embed_column_float(query, 2), 9.5)
			testing.expect(t, !db.embed_column_is_null(query, 2))
		} else {
			testing.expect(t, db.embed_column_is_null(query, 2))
			testing.expect_value(t, db.embed_column_type(query, 0), db.Value_Kind.Int)
		}
	}
	testing.expect_value(t, rows, 2)
	// Errors land on the connection and do not crash.
	bad := db.embed_prepare(conn, "SELECT * FROM missing")
	_, bad_err := db.embed_step(bad)
	defer db.error_free(&bad_err)
	testing.expect(t, !db.error_ok(bad_err))
	testing.expect(t, strings_contains(db.embed_error(conn), "missing"))
	db.embed_finalize(bad)
}

@(test)
test_embed_opens_sqlite_file :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(SQLITE_FIXTURE)
	if !testing.expectf(t, db.error_ok(open_err), "embed sqlite: %s", open_err.message) do return
	defer db.embed_close(conn)
	stmt := db.embed_prepare(conn, "SELECT count(*) FROM people")
	if !testing.expect(t, stmt != nil) do return
	defer db.embed_finalize(stmt)
	row, step_err := db.embed_step(stmt)
	testing.expect(t, db.error_ok(step_err))
	testing.expect(t, row)
	testing.expect_value(t, db.embed_column_int(stmt, 0), i64(4))
}

@(test)
test_not_null_survives_replay :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "not_null_replay")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "not_null_replay")
	if store == nil do return
	run_done(t, store, "CREATE TABLE strict (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO strict (id, name) VALUES (1, 'ok')")
	dropped_result_6874, insert_err := db.sql_execute(store, "INSERT INTO strict (id, name) VALUES (2, NULL)")
	defer db.error_free(&insert_err)
	defer db.sql_result_destroy(&dropped_result_6874)
	testing.expect_value(t, insert_err.kind, db.Error_Kind.Not_Null_Violation)
	db.host_destroy(host)
	db.store_close(store)

	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	dropped_result_6882, replay_err := db.sql_execute(reopened, "INSERT INTO strict (id, name) VALUES (3, NULL)")
	defer db.error_free(&replay_err)
	defer db.sql_result_destroy(&dropped_result_6882)
	testing.expect_value(t, replay_err.kind, db.Error_Kind.Not_Null_Violation)
	described := run(t, reopened, "DESCRIBE strict")
	defer db.sql_result_destroy(&described)
	found := false
	for row in described.rows {
		if row[0].s == "column" && row[1].s == "name" {
			found = true
			testing.expect(t, row[3].b, "not_null must survive the log")
		}
	}
	testing.expect(t, found)
}

@(test)
test_pragma_and_sqlite_functions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "pragma")
	if store == nil do return
	defer destroy_host(store, host, "pragma")
	run_done(t, store, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)")
	run_done(t, store, "CREATE INDEX people_age ON people (age)")

	info := run(t, store, "PRAGMA table_info(people)")
	defer db.sql_result_destroy(&info)
	testing.expect_value(t, len(info.rows), 3)
	testing.expect_value(t, info.columns[1], "name")
	testing.expect_value(t, info.rows[1][1].s, "name")
	testing.expect_value(t, info.rows[1][3].i, i64(1))

	indexes := run(t, store, "PRAGMA index_list(people)")
	defer db.sql_result_destroy(&indexes)
	testing.expect_value(t, len(indexes.rows), 2)
	fks := run(t, store, "PRAGMA foreign_key_list(people)")
	defer db.sql_result_destroy(&fks)
	testing.expect_value(t, len(fks.rows), 0)
	dbs := run(t, store, "PRAGMA database_list")
	defer db.sql_result_destroy(&dbs)
	testing.expect_value(t, dbs.rows[0][1].s, "main")
	testing.expect_value(t, run_temp(t, store, "PRAGMA page_size").rows[0][0].i, i64(4096))
	testing.expect_value(t, run_temp(t, store, "PRAGMA integrity_check").rows[0][0].s, "ok")

	functions := run(
		t,
		store,
		"SELECT typeof(1), typeof(1.5), typeof('x'), typeof(NULL), quote('it''s'), hex('AB'), iif(0, 'a', 'b'), sqlite_version(), instr('hello', 'll'), format('%d/%s', 7, 'x'), char(65, 66)",
	)
	defer db.sql_result_destroy(&functions)
	row := functions.rows[0]
	testing.expect_value(t, row[0].s, "integer")
	testing.expect_value(t, row[1].s, "real")
	testing.expect_value(t, row[2].s, "text")
	testing.expect_value(t, row[3].s, "null")
	testing.expect_value(t, row[4].s, "'it''s'")
	testing.expect_value(t, row[5].s, "4142")
	testing.expect_value(t, row[6].s, "b")
	testing.expect_value(t, row[7].s, "3.54.1")
	testing.expect_value(t, row[8].i, i64(3))
	testing.expect_value(t, row[9].s, "7/x")
	testing.expect_value(t, row[10].s, "AB")
}

@(test)
test_glob_operator :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "glob")
	if store == nil do return
	defer destroy_host(store, host, "glob")
	run_done(t, store, "CREATE TABLE files (id INTEGER PRIMARY KEY, name TEXT)")
	for name in ([]string{"alpha.txt", "beta.txt", "gamma.log", "Alpha.txt", "a1.txt", "a2.txt"}) {
		run_params(t, store, "INSERT INTO files (name) VALUES (?)", []db.Value{db.value_string(name)})
	}
	cases := []struct{ predicate: string, expected: i64 }{
		{"name GLOB '*.txt'", 5},
		{"name GLOB 'a*'", 3},
		{"name GLOB 'A*'", 1},
		{"name GLOB 'a?.txt'", 2},
		{"name GLOB 'a[0-9].txt'", 2},
		{"name GLOB '[^a]*'", 3},
		{"name NOT GLOB '*.txt'", 1},
		{"name LIKE 'a%'", 4},
	}
	for item in cases {
		result := run(t, store, fmt.tprintf("SELECT count(*) FROM files WHERE %s", item.predicate))
		defer db.sql_result_destroy(&result)
		testing.expectf(t, result.rows[0][0].i == item.expected, "%s: expected %d, got %d", item.predicate, item.expected, result.rows[0][0].i)
	}
	testing.expect_value(t, run_temp(t, store, "SELECT name FROM files WHERE name GLOB 'a[0-9].txt' ORDER BY name").rows[0][0].s, "a1.txt")
}

@(test)
test_returning_clause :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "returning")
	defer delete(path)
	defer os.remove_all(path)
	store, host := fresh_host(t, "returning")
	if store == nil do return
	run_done(t, store, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)")

	inserted := run(t, store, "INSERT INTO items (name, qty) VALUES ('a', 1), ('b', 2) RETURNING id, name, qty")
	defer db.sql_result_destroy(&inserted)
	testing.expect_value(t, inserted.kind, db.Sql_Result_Kind.Rows)
	testing.expect_value(t, len(inserted.rows), 2)
	testing.expect_value(t, inserted.rows[0][1].s, "a")
	testing.expect_value(t, inserted.rows[1][0].i, i64(2))

	updated := run(t, store, "UPDATE items SET qty = qty + 10 WHERE name = 'a' RETURNING *")
	defer db.sql_result_destroy(&updated)
	testing.expect_value(t, len(updated.rows), 1)
	testing.expect_value(t, updated.rows[0][2].i, i64(11))
	// The write is visible after the statement, not only in the returning rows.
	testing.expect_value(t, scalar(t, store, "SELECT qty FROM items WHERE name = 'a'").i, i64(11))

	deleted := run(t, store, "DELETE FROM items WHERE id = 2 RETURNING name")
	defer db.sql_result_destroy(&deleted)
	testing.expect_value(t, len(deleted.rows), 1)
	testing.expect_value(t, deleted.rows[0][0].s, "b")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM items").i, i64(1))

	// The deletes and updates survive a reopen.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM items").i, i64(1))
	testing.expect_value(t, scalar(t, reopened, "SELECT qty FROM items").i, i64(11))
}

@(test)
test_upsert :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "upsert")
	if store == nil do return
	defer destroy_host(store, host, "upsert")
	run_done(t, store, "CREATE TABLE stock (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)")
	run_done(t, store, "INSERT INTO stock (id, name, qty) VALUES (1, 'a', 5)")

	// DO UPDATE runs the assignments over the stored row and reports it.
	updated := run(t, store, "INSERT INTO stock (id, name, qty) VALUES (1, 'a', 7) ON CONFLICT (id) DO UPDATE SET qty = qty + 1 RETURNING *")
	defer db.sql_result_destroy(&updated)
	testing.expect_value(t, len(updated.rows), 1)
	testing.expect_value(t, updated.rows[0][2].i, i64(6))
	testing.expect_value(t, updated.affected, 1)

	// DO NOTHING leaves the row alone on a collision...
	ignored := run(t, store, "INSERT INTO stock (id, name, qty) VALUES (1, 'a', 100) ON CONFLICT DO NOTHING")
	defer db.sql_result_destroy(&ignored)
	testing.expect_value(t, ignored.affected, 0)
	testing.expect_value(t, scalar(t, store, "SELECT qty FROM stock WHERE id = 1").i, i64(6))
	// ...and inserts normally when there is no collision.
	run_done(t, store, "INSERT INTO stock (id, name, qty) VALUES (2, 'b', 9) ON CONFLICT DO NOTHING")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM stock").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT qty FROM stock WHERE id = 2").i, i64(9))
}

@(test)
test_any_column_affinity :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "any_column")
	if store == nil do return
	run_done(t, store, "CREATE TABLE mixed (id INTEGER PRIMARY KEY, v ANY)")
	run_done(t, store, "INSERT INTO mixed (id, v) VALUES (1, 10)")
	run_done(t, store, "INSERT INTO mixed (id, v) VALUES (2, 'text')")
	run_done(t, store, "INSERT INTO mixed (id, v) VALUES (3, 1.5)")
	run_params(t, store, "INSERT INTO mixed (id, v) VALUES (?, ?)", []db.Value{db.value_int(4), db.value_bytes([]u8{1, 2})})
	run_done(t, store, "INSERT INTO mixed (id, v) VALUES (5, NULL)")

	kinds := run(t, store, "SELECT v, typeof(v) FROM mixed ORDER BY id")
	defer db.sql_result_destroy(&kinds)
	testing.expect_value(t, len(kinds.rows), 5)
	testing.expect_value(t, kinds.rows[0][1].s, "integer")
	testing.expect_value(t, kinds.rows[0][0].i, i64(10))
	testing.expect_value(t, kinds.rows[1][1].s, "text")
	testing.expect_value(t, kinds.rows[1][0].s, "text")
	testing.expect_value(t, kinds.rows[2][1].s, "real")
	testing.expect_value(t, kinds.rows[2][0].f, 1.5)
	testing.expect_value(t, kinds.rows[3][1].s, "blob")
	testing.expect_value(t, len(kinds.rows[3][0].bytes), 2)
	testing.expect_value(t, kinds.rows[4][1].s, "null")

	// The typeless column survives a reopen with its values intact.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open("_test_any_column", {persistent = true, create = true, durable = false})
	testing.expect(t, db.error_ok(open_err))
	defer db.store_close(reopened)
	defer os.remove_all("_test_any_column")
	testing.expect_value(t, scalar(t, reopened, "SELECT v FROM mixed WHERE id = 2").s, "text")
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM mixed").i, i64(5))
}

@(test)
test_sqlite_import_typeless_column :: proc(t: ^testing.T) {
	file, open_err := db.sqlite_file_open("src/tests/fixtures/any.sqlite")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	store := fresh_db(t, "sqlite_any")
	if store == nil do return
	defer cleanup_db(store, "sqlite_any")
	_, rows, import_err := db.sqlite_import(&file, store)
	testing.expect(t, db.error_ok(import_err))
	testing.expect_value(t, rows, 4)
	kinds := run(t, store, "SELECT typeof(v) FROM mixed ORDER BY id")
	defer db.sql_result_destroy(&kinds)
	testing.expect_value(t, kinds.rows[0][0].s, "integer")
	testing.expect_value(t, kinds.rows[1][0].s, "text")
	testing.expect_value(t, kinds.rows[2][0].s, "real")
	testing.expect_value(t, kinds.rows[3][0].s, "blob")
}

@(test)
test_vfs_memory_and_quota :: proc(t: ^testing.T) {
	vfs := db.vfs_memory_new()
	defer db.vfs_memory_destroy(vfs)
	file, open_err := vfs.ops.open(vfs, "a.log", {.Read, .Write, .Create})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	testing.expect(t, db.error_ok(db.vfs_write_all(file, http_bytes_of("hello"))))
	testing.expect_value(t, file.ops.size(file), i64(5))
	_, seek_err := file.ops.seek(file, 0)
	testing.expect(t, db.error_ok(seek_err))
	read, read_err := db.vfs_read_all(file, 5)
	defer delete(read)
	testing.expect(t, db.error_ok(read_err))
	testing.expect_value(t, string(read), "hello")
	testing.expect(t, db.error_ok(file.ops.truncate(file, 2)))
	testing.expect_value(t, file.ops.size(file), i64(2))
	file.ops.close(file)

	// A quota rejects the write that would cross the limit.
	quota := db.vfs_quota_new(vfs, 4)
	defer db.vfs_quota_destroy(quota)
	limited, limited_err := quota.ops.open(quota, "b.log", {.Write, .Create})
	if !testing.expectf(t, db.error_ok(limited_err), "quota open: %s", limited_err.message) do return
	_, write_err := limited.ops.write(limited, http_bytes_of("abcdef"))
	defer db.error_free(&write_err)
	testing.expect_value(t, write_err.kind, db.Error_Kind.Quota_Exceeded)
	limited.ops.close(limited)
	testing.expect(t, db.error_ok(quota.ops.remove(quota, "b.log")))
}

@(test)
test_prepared_statement_reuse :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "prepared_host")
	if store == nil do return
	defer destroy_host(store, host, "prepared_host")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

	insert, prepare_err := db.sql_prepare(store, "INSERT INTO t (name) VALUES (?)")
	if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return
	defer db.stmt_prepared_destroy(insert)
	for name in ([]string{"a", "b"}) {
		_, exec_err := db.prepared_execute(store, insert, []db.Value{db.value_string(name)})
		testing.expect(t, db.error_ok(exec_err))
	}
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))

	// The parsed statement runs again without re-parsing.
	count, count_err := db.sql_prepare(store, "SELECT count(*) FROM t")
	defer db.stmt_prepared_destroy(count)
	testing.expect(t, db.error_ok(count_err))
	for _ in 0 ..< 2 {
		result, exec_err := db.prepared_execute(store, count, nil)
		testing.expect(t, db.error_ok(exec_err))
		testing.expect_value(t, result.rows[0][0].i, i64(2))
		db.sql_result_destroy(&result)
	}

	// Pragmas also prepare.
	page_size, pragma_err := db.sql_prepare(store, "PRAGMA page_size")
	defer db.stmt_prepared_destroy(page_size)
	testing.expect(t, db.error_ok(pragma_err))
	result, exec_err := db.prepared_execute(store, page_size, nil)
	testing.expect(t, db.error_ok(exec_err))
	testing.expect_value(t, result.rows[0][0].i, i64(4096))
	db.sql_result_destroy(&result)
}

// Remote module fixture: a thread that speaks the wire protocol on a socket, the
// way a separate process would.
@(private)
Remote_Listener :: struct {
	listener: net.TCP_Socket,
	host:     ^db.Host,
	requests:    int,
	connections: int,
	stop:        bool,
	err:      db.Error,
}

@(private)
remote_read_exact :: proc(socket: net.TCP_Socket, buffer: []u8) -> bool {
	total := 0
	for total < len(buffer) {
		read, recv_err := net.recv(socket, buffer[total:])
		if recv_err != nil || read <= 0 do return false
		total += read
	}
	return true
}

// remote_listener_stop ends the listening thread and waits for it. Closing the
// socket is not enough: on Linux a thread blocked in `accept` is not woken by a
// close of the listening socket, and the join then waits forever. One connection
// to the port wakes it on every platform: it reads nothing from that connection,
// drops it, and sees `stop` on the next turn of its loop.
@(private)
remote_listener_stop :: proc(state: ^Remote_Listener, port: int, worker: ^thread.Thread) {
	sync.atomic_store(&state.stop, true)
	if wake, wake_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port}); wake_err == nil {
		net.close(wake)
	}
	thread.destroy(worker)
	net.close(state.listener)
}

@(private)
remote_listen_proc :: proc(data: rawptr) {
	context = runtime.default_context()
	state := (^Remote_Listener)(data)
	for !sync.atomic_load(&state.stop) {
		client, _, accept_err := net.accept_tcp(state.listener)
		if accept_err != nil do return
		state.connections += 1
		// Serve every request this connection asks for: the client pools the
		// socket, so a keep-alive test must see several messages per accept.
		for {
			header: [4]u8
			if !remote_read_exact(client, header[:]) do break
			length := int(u32(header[0]) | u32(header[1]) << 8 | u32(header[2]) << 16 | u32(header[3]) << 24)
			if length <= 0 || length > 1 << 20 do break
			payload := make([]u8, length)
			if !remote_read_exact(client, payload) {
				delete(payload)
				break
			}
			state.requests += 1
			response := db.wire_request(state.host, payload)
			put_u32_le_test(header[:], u32(len(response)))
			net.send(client, header[:])
			net.send(client, response)
			delete(response)
			delete(payload)
		}
		net.close(client)
	}
}

@(private)
put_u32_le_test :: proc(target: []u8, value: u32) {
	target[0] = u8(value)
	target[1] = u8(value >> 8)
	target[2] = u8(value >> 16)
	target[3] = u8(value >> 24)
}

@(test)
test_remote_module :: proc(t: ^testing.T) {
	// The module is a second host that speaks the wire protocol from its own
	// thread: exactly the bytes a separate process exchanges, plus the same
	// error paths when the module is unreachable.
	old_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer context.allocator = old_allocator

	module_store, module_host := fresh_host(t, "remote_mod")
	if module_store == nil do return
	defer destroy_host(module_store, module_host, "remote_mod")
	run_done(t, module_store, "CREATE TABLE hits (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL, at INTEGER NOT NULL)")
	note :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		// The clock is the caller's, which is what makes a call reproducible.
		statement := fmt.tprintf("INSERT INTO hits (note, at) VALUES ('from the host', %d)", ctx.now_us)
		dropped_result_7339, err := db.sql_execute_in_tx(ctx.tx, statement)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_7339)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(module_host, "note", nil, note)))

	// Pick a port by binding and asking for the bound endpoint.
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, listen_err := net.listen_tcp(endpoint)
	if !testing.expectf(t, listen_err == nil, "listen: %v", listen_err) do return
	bound, bound_err := net.bound_endpoint(listener)
	testing.expect(t, bound_err == nil)
	state := Remote_Listener{listener = listener, host = module_host}
	net.set_option(listener, .Reuse_Address, true)
	worker := thread.create_and_start_with_data(&state, remote_listen_proc, name = "module-test")

	host := db.host_init(module_store)
	register_err := db.host_register_remote_module(host, "notes", "127.0.0.1", bound.port, []string{"note"})
	testing.expectf(t, db.error_ok(register_err), "register: %s", register_err.message)
	testing.expect_value(t, len(db.host_remote_module_names(host, context.temp_allocator)), 1)

	// The call crosses the socket, runs the reducer on the other host and its
	// effect lands in the module's own store. The caller's clock travels with the
	// call, so the module never reads its own.
	host.now_us = 1_700_000_000_000
	value, call_err := db.host_call_module(host, "notes", "note", nil)
	testing.expectf(t, db.error_ok(call_err), "call: %s", call_err.message)
	testing.expect_value(t, value.i, i64(1))
	testing.expect(t, state.requests >= 1)
	count := scalar(t, module_store, "SELECT count(*) FROM hits WHERE note = 'from the host'")
	testing.expect_value(t, count.i, i64(1))
	// A second call reuses the pooled socket instead of connecting again.
	_, second := db.host_call_module(host, "notes", "note", nil)
	defer db.error_free(&second)
	testing.expectf(t, db.error_ok(second), "second call: %s", second.message)
	testing.expect_value(t, state.connections, 1)
	testing.expect_value(t, scalar(t, module_store, "SELECT count(*) FROM hits").i, i64(2))
	testing.expect_value(t, scalar(t, module_store, "SELECT at FROM hits LIMIT 1").i, i64(1_700_000_000_000))

	// An unregistered reducer is refused before any socket work.
	_, unknown := db.host_call_module(host, "notes", "nope", nil)
	defer db.error_free(&unknown)
	testing.expect_value(t, unknown.kind, db.Error_Kind.Sql_Unsupported)
	// A module that is not listening is an error, not a crash.
	db.host_register_remote_module(host, "dead", "127.0.0.1", 1, nil)
	_, dead := db.host_call_module(host, "dead", "note", nil)
	defer db.error_free(&dead)
	testing.expect_value(t, dead.kind, db.Error_Kind.Io)

	db.host_destroy(host)
	remote_listener_stop(&state, bound.port, worker)
	os.remove_all("_test_remote_mod")
}

@(test)
test_spatial_rtree :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "rtree")
	defer delete(path)
	defer os.remove_all(path)
	os.remove_all(path)
	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return

	run_done(t, store, "CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx, miny, maxy)")
	run(
		t,
		store,
		"INSERT INTO places (id, minx, maxx, miny, maxy) VALUES (1, 0, 10, 0, 10), (2, 20, 30, 20, 30), (3, 5, 15, 5, 15)",
	)
	// A point is covered by every box that contains it.
	point := "SELECT count(*) FROM places WHERE minx <= 6 AND maxx >= 6 AND miny <= 6 AND maxy >= 6"
	testing.expect_value(t, scalar(t, store, point).i, i64(2))
	// A window overlaps one of them.
	window := "SELECT id FROM places WHERE minx <= 12 AND maxx >= 12 AND miny <= 12 AND maxy >= 12"
	rows := run(t, store, window)
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect_value(t, rows.rows[0][0].i, i64(3))
	db.sql_result_destroy(&rows)
	// Coordinates are REAL, so fractional boxes work.
	run_done(t, store, "INSERT INTO places (id, minx, maxx, miny, maxy) VALUES (4, 5.5, 6.5, 5.5, 6.5)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM places WHERE id = 4 AND maxx = 6.5").i, i64(1))
	// Moving a box moves it out of the window.
	run_done(t, store, "UPDATE places SET minx = 100, maxx = 110, miny = 100, maxy = 110 WHERE id = 3")
	window_count := strings.concatenate({"SELECT count(*) FROM places WHERE minx <= 12 AND maxx >= 12 AND miny <= 12 AND maxy >= 12"})
	defer delete(window_count)
	testing.expect_value(t, scalar(t, store, window_count).i, i64(0))
	// Deleting removes it from every query.
	run_done(t, store, "DELETE FROM places WHERE id = 4")
	testing.expect_value(t, scalar(t, store, point).i, i64(1))

	// A shape that is not a set of min/max pairs is refused.
	dropped_result_7284, bad_shape := db.sql_execute(store, "CREATE VIRTUAL TABLE broken USING rtree(id, minx, maxx, miny)")
	defer db.error_free(&bad_shape)
	defer db.sql_result_destroy(&dropped_result_7284)
	testing.expect_value(t, bad_shape.kind, db.Error_Kind.Invalid_Argument)
	// rtree_i32 stores integers.
	run_done(t, store, "CREATE VIRTUAL TABLE grid USING rtree_i32(id, minx, maxx, miny, maxy)")
	run_done(t, store, "INSERT INTO grid (id, minx, maxx, miny, maxy) VALUES (1, 0, 2, 0, 2)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM grid WHERE maxx >= 1 AND minx <= 1").i, i64(1))
	// MATCH is a full-text operator: asking an rtree for it fails instead of
	// silently returning nothing.
	dropped_result_7344, no_match := db.sql_execute(store, "SELECT count(*) FROM places WHERE places MATCH 'x'")
	defer db.error_free(&no_match)
	defer db.sql_result_destroy(&dropped_result_7344)
	testing.expect(t, !db.error_ok(no_match))

	// Both the boxes and the catalog survive a reopen.
	db.store_close(store)
	store, open_err = db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM places").i, i64(3))
	testing.expect_value(t, scalar(t, store, point).i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _virtual").i, i64(2))

	// Dropping the virtual table forgets it.
	run_done(t, store, "DROP TABLE grid")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _virtual").i, i64(1))
	db.store_close(store)
}

@(test)
test_extension_load :: proc(t: ^testing.T) {
	// An extension is a process on the other side of a socket. The module here is
	// a second host served from a thread, so the test exercises the real path:
	// SQL records it, the host registers it, calls cross the wire, and a restart
	// registers it again from the catalog row.
	old_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer context.allocator = old_allocator

	module_store, module_host := fresh_host(t, "ext_module")
	if module_store == nil do return
	defer destroy_host(module_store, module_host, "ext_module")
	run_done(t, module_store, "CREATE TABLE hits (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL)")
	note :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		dropped_result_7470, err := db.sql_execute_in_tx(ctx.tx, "INSERT INTO hits (note) VALUES ('from an extension')")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_7470)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(module_host, "note", nil, note)))

	endpoint := net.Endpoint{address = net.IP4_Loopback, port = 0}
	listener, listen_err := net.listen_tcp(endpoint)
	if !testing.expectf(t, listen_err == nil, "listen: %v", listen_err) do return
	bound, bound_err := net.bound_endpoint(listener)
	testing.expect(t, bound_err == nil)
	state := Remote_Listener{listener = listener, host = module_host}
	net.set_option(listener, .Reuse_Address, true)
	worker := thread.create_and_start_with_data(&state, remote_listen_proc, name = "ext-test")

	path := fmt.aprintf("_test_%s", "extension")
	defer delete(path)
	defer os.remove_all(path)
	os.remove_all(path)
	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	host := db.host_init(store)
	run_done(t, store, "CREATE TABLE before_load (id INTEGER PRIMARY KEY)")

	// The address is required and must carry a usable port.
	dropped_result_7494, no_port := db.sql_execute(store, "LOAD EXTENSION broken AT '127.0.0.1'")
	defer db.error_free(&no_port)
	defer db.sql_result_destroy(&dropped_result_7494)
	testing.expect_value(t, no_port.kind, db.Error_Kind.Invalid_Argument)

	address := fmt.aprintf("127.0.0.1:%d", bound.port)
	defer delete(address)
	load_sql := fmt.aprintf("LOAD EXTENSION notes AT '%s' USING note", address)
	defer delete(load_sql)
	run_done(t, store, load_sql)
	testing.expect_value(t, len(db.host_remote_module_names(host, context.temp_allocator)), 1)

	// A call crosses the socket and lands in the extension's own database.
	value, call_err := db.host_call_module(host, "notes", "note", nil)
	testing.expectf(t, db.error_ok(call_err), "call: %s", call_err.message)
	testing.expect_value(t, value.i, i64(1))
	testing.expect_value(t, scalar(t, module_store, "SELECT count(*) FROM hits").i, i64(1))
	// The declared reducer list is enforced before a socket is opened.
	_, unknown := db.host_call_module(host, "notes", "drop_everything", nil)
	defer db.error_free(&unknown)
	testing.expect_value(t, unknown.kind, db.Error_Kind.Sql_Unsupported)

	// Unloading forgets both the module and the catalog row.
	run_done(t, store, "UNLOAD EXTENSION notes")
	testing.expect_value(t, len(db.host_remote_module_names(host, context.temp_allocator)), 0)
	_, gone := db.host_call_module(host, "notes", "note", nil)
	defer db.error_free(&gone)
	testing.expect_value(t, gone.kind, db.Error_Kind.Invalid_Argument)
	dropped_result_7518, unload_again := db.sql_execute(store, "UNLOAD EXTENSION notes")
	defer db.error_free(&unload_again)
	defer db.sql_result_destroy(&dropped_result_7518)
	testing.expect_value(t, unload_again.kind, db.Error_Kind.Invalid_Argument)
	run_done(t, store, "UNLOAD EXTENSION IF EXISTS notes")

	// A restart registers what the database remembers.
	run_done(t, store, load_sql)
	db.host_destroy(host)
	db.store_close(store)
	store, open_err = db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	host = db.host_init(store)
	testing.expect_value(t, len(db.host_remote_module_names(host, context.temp_allocator)), 1)
	value, call_err = db.host_call_module(host, "notes", "note", nil)
	testing.expectf(t, db.error_ok(call_err), "call after reopen: %s", call_err.message)
	testing.expect_value(t, scalar(t, module_store, "SELECT count(*) FROM hits").i, i64(2))

	db.host_destroy(host)
	db.store_close(store)
	remote_listener_stop(&state, bound.port, worker)
}

@(test)
test_full_text_search :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "fts")
	defer delete(path)
	defer os.remove_all(path)
	os.remove_all(path)
	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return

	run_done(t, store, "CREATE VIRTUAL TABLE docs USING fts5(body)")
	run_done(t, store, "INSERT INTO docs (body) VALUES ('the quick brown fox'), ('a lazy dog sleeps')")
	// Plain projection returns the stored columns, not the tokens.
	rows := run(t, store, "SELECT body FROM docs WHERE docs MATCH 'fox'")
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect_value(t, rows.rows[0][0].s, "the quick brown fox")
	db.sql_result_destroy(&rows)
	// One term.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'fox'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'FOX'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'cat'").i, i64(0))
	// OR, and several terms that must all be present.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'fox OR dog'").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'the fox'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'the dog'").i, i64(0))
	// NOT excludes the documents that carry the second term.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'the NOT fox'").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'a NOT fox'").i, i64(1))
	// The index follows updates and deletes.
	run_done(t, store, "UPDATE docs SET body = 'a fast cat' WHERE body = 'the quick brown fox'")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'fox'").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'cat'").i, i64(1))
	run_done(t, store, "DELETE FROM docs WHERE body = 'a lazy dog sleeps'")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'cat OR dog'").i, i64(1))
	// A second virtual table has its own index.
	run_done(t, store, "CREATE VIRTUAL TABLE notes USING fts5(text)")
	run_done(t, store, "INSERT INTO notes (text) VALUES ('cat cat')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM notes WHERE notes MATCH 'cat'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'cat'").i, i64(1))
	// An unknown module is refused rather than silently creating a plain table.
	dropped_result_7432, bad := db.sql_execute(store, "CREATE VIRTUAL TABLE bad USING nosuchmodule(id)")
	defer db.error_free(&bad)
	defer db.sql_result_destroy(&dropped_result_7432)
	testing.expect_value(t, bad.kind, db.Error_Kind.Sql_Unsupported)

	// The index is data, so it survives a reopen.
	db.store_close(store)
	store, open_err = db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'cat'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM notes WHERE notes MATCH 'cat'").i, i64(1))

	// Dropping the virtual table drops the shadow table with it.
	run_done(t, store, "DROP TABLE docs")
	dropped_result_7498, gone := db.sql_execute(store, "SELECT count(*) FROM _fts_docs_terms")
	defer db.error_free(&gone)
	defer db.sql_result_destroy(&dropped_result_7498)
	testing.expect_value(t, gone.kind, db.Error_Kind.Table_Not_Found)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _virtual").i, i64(1))
	db.store_close(store)
}

@(test)
test_sqlite_live_mirror :: proc(t: ^testing.T) {
	// A database opened from a .sqlite file keeps that file a valid SQLite
	// database: a commit mirrors back to it, so another driver can read it.
	path := "_test_live_mirror.db"
	os.remove(path)

	store := fresh_db(t, "mirror_source")
	if store == nil do return
	run_done(t, store, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO items (id, name) VALUES (1, 'one')")
	_, _, export_err := db.sqlite_file_write(store, path)
	testing.expect(t, db.error_ok(export_err))
	db.store_close(store)
	os.remove_all("_test_mirror_source")

	conn, open_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "embed_open: %s", open_err.message) do return
	// The file is reported as the main database, not an empty path: by its
	// full path, as SQLite reports it.
	list := run(t, conn.store, "PRAGMA database_list")
	listed := list.rows[0][2].s
	testing.expectf(t, len(listed) > len(path) && strings.has_suffix(listed, path), "database_list names %q", listed)
	db.sql_result_destroy(&list)

	insert, insert_err := db.sql_execute(conn.store, "INSERT INTO items (id, name) VALUES (2, 'two')")
	testing.expect(t, db.error_ok(insert_err))
	testing.expect_value(t, insert.affected, 1)
	db.sql_result_destroy(&insert)
	db.embed_close(conn)

	// Reopen the file with the SQLite reader: both rows are there.
	file, file_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(file_err), "sqlite_file_open: %s", file_err.message) do return
	defer db.sqlite_file_destroy(&file)
	testing.expect_value(t, len(file.tables), 1)
	testing.expect_value(t, file.tables[0].name, "items")
	rows, rows_err := db.sqlite_table_rows(&file, &file.tables[0], context.allocator)
	testing.expect(t, db.error_ok(rows_err))
	defer {
		for row in rows do db.free_values(row)
		delete(rows)
	}
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[1][1].s, "two")
	os.remove(path)
}

@(test)
test_keys_cross_a_sqlite_file_both_ways :: proc(t: ^testing.T) {
	// A written file carries every key the model holds (D33). The primary key of
	// a text column and a UNIQUE column travel as index rows, because an inline
	// constraint would ask SQLite for an automatic index (sqlite_autoindex_*)
	// that the writer does not produce, and SQLite calls such a file malformed.
	path := "_test_keys_round_trip.db"
	os.remove(path)
	source := fresh_db(t, "keys_source")
	if source == nil do return
	run_done(t, source, "CREATE TABLE k (code TEXT PRIMARY KEY, v INTEGER)")
	run_done(t, source, "INSERT INTO k (code, v) VALUES ('a', 1)")
	run_done(t, source, "CREATE TABLE u (id INTEGER PRIMARY KEY, code TEXT UNIQUE)")
	run_done(t, source, "INSERT INTO u (id, code) VALUES (1, 'x')")
	run_done(t, source, "CREATE TABLE cp (a INTEGER, b INTEGER, PRIMARY KEY (a, b))")
	run_done(t, source, "INSERT INTO cp (a, b) VALUES (1, 2)")
	_, _, export_err := db.sqlite_file_write(source, path)
	testing.expect(t, db.error_ok(export_err))
	db.store_close(source)
	os.remove_all("_test_keys_source")

	file, file_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(file_err), "sqlite_file_open: %s", file_err.message) do return
	defer db.sqlite_file_destroy(&file)
	testing.expect_value(t, len(file.tables), 3)
	// Each key is declared in the table text the way SQLite declares it, and the
	// reader has to see it, or an import drops the constraint.
	for table in file.tables {
		switch table.name {
		case "k":
			// The text is the one the table was created with; the engine still
			// refuses a NULL key after the trip (below).
			testing.expect_value(t, table.columns[0].primary_key, true)
		case "cp":
			testing.expect_value(t, len(table.primary_group), 2)
		case "u":
			// The table keeps the text it was created with, UNIQUE inline, so its
			// index is the automatic one that declaration asks for.
			testing.expect_value(t, len(table.unique_groups), 1)
		}
	}
	// The key indexes are automatic ones: no SQL, because the declaration in the
	// table text is what says what they are, and the integer key is the rowid,
	// which needs none.
	testing.expect_value(t, len(file.indexes), 0)

	// The way back: the import recreates the keys, so the engine refuses what the
	// engine refused before the trip.
	store := fresh_db(t, "keys_import")
	if store == nil do return
	defer cleanup_db(store, "keys_import")
	tables, rows, import_err := db.sqlite_import(&file, store)
	testing.expect(t, db.error_ok(import_err))
	testing.expect_value(t, tables, 3)
	testing.expect_value(t, rows, 3)
	duplicate_text := run_error(t, store, "INSERT INTO k (code, v) VALUES ('a', 9)")
	testing.expect_value(t, duplicate_text.kind, db.Error_Kind.Duplicate_Primary_Key)
	duplicate_unique := run_error(t, store, "INSERT INTO u (id, code) VALUES (9, 'x')")
	testing.expect_value(t, duplicate_unique.kind, db.Error_Kind.Duplicate_Unique)
	duplicate_composite := run_error(t, store, "INSERT INTO cp (a, b) VALUES (1, 2)")
	testing.expect_value(t, duplicate_composite.kind, db.Error_Kind.Duplicate_Primary_Key)
	null_key := run_error(t, store, "INSERT INTO k (code, v) VALUES (NULL, 1)")
	testing.expect_value(t, null_key.kind, db.Error_Kind.Not_Null_Violation)
	os.remove(path)
}

@(test)
test_import_keeps_the_keys_sqlite_declared :: proc(t: ^testing.T) {
	// SQLite spells a UNIQUE column and a composite key as table constraints and
	// backs each with an automatic index that carries no SQL. The constraint has
	// to be read from the table text, or the imported table accepts the duplicate
	// the source file refused (D33).
	file, open_err := db.sqlite_file_open("src/tests/fixtures/keys.sqlite")
	if !testing.expectf(t, db.error_ok(open_err), "sqlite_file_open: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	store := fresh_db(t, "keys_fixture")
	if store == nil do return
	defer cleanup_db(store, "keys_fixture")
	tables, rows, import_err := db.sqlite_import(&file, store)
	testing.expect(t, db.error_ok(import_err))
	testing.expect_value(t, tables, 5)
	testing.expect_value(t, rows, 9)
	duplicates := []string{
		"INSERT INTO k (code, v) VALUES ('a', 9)",
		"INSERT INTO u (id, code, n) VALUES (9, 'x', 0)",
		"INSERT INTO cu (a, b) VALUES (1, 2)",
		"INSERT INTO cp (a, b) VALUES (1, 2)",
		"INSERT INTO t3 (a, b, c) VALUES ('p', 'q', 'r')",
	}
	for statement in duplicates {
		refusal := run_error(t, store, statement)
		testing.expectf(t, refusal.kind != db.Error_Kind.None, "%s was accepted", statement)
	}
	// And the keys survive the way back out: the written text declares them and
	// the automatic indexes follow it.
	path := "_test_keys_fixture.db"
	os.remove(path)
	_, _, export_err := db.sqlite_file_write(store, path)
	testing.expect(t, db.error_ok(export_err))
	written, written_err := db.sqlite_file_open(path)
	if !testing.expect(t, db.error_ok(written_err)) do return
	defer {
		db.sqlite_file_destroy(&written)
		os.remove(path)
	}
	summary := strings.builder_make()
	defer strings.builder_destroy(&summary)
	for table in written.tables {
		strings.write_string(&summary, table.name)
		strings.write_byte(&summary, ':')
		strings.write_int(&summary, len(table.primary_group))
		strings.write_byte(&summary, '/')
		strings.write_int(&summary, len(table.unique_groups))
		if table.name == "k" && len(table.columns) > 0 && table.columns[0].primary_key {
			strings.write_string(&summary, "pk")
		}
		strings.write_byte(&summary, ' ')
	}
	// The table text comes back exactly as the fixture spelled it, and since every
	// key it declares is carried by an automatic index, no named index row is
	// written at all: the declaration and its number are enough. The tables
	// keep the order the fixture made them in, which is SQLite's.
	testing.expect_value(t, strings.to_string(summary), "k:0/1pk u:0/1 cu:0/1 cp:2/0 t3:0/1 ")
	testing.expect_value(t, len(written.indexes), 0)
	for table in written.tables {
		for original in file.tables {
			if original.name != table.name do continue
			testing.expect_value(t, table.sql, original.sql)
		}
	}
}

@(test)
test_limit_stops_the_scan :: proc(t: ^testing.T) {
	// LIMIT on a statement that neither filters nor shrinks stops the scan once it
	// has the rows it needs, instead of collecting the table and slicing (D23).
	store := fresh_db(t, "limit_scan")
	if store == nil do return
	defer cleanup_db(store, "limit_scan")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
	{
		tx := db.tx_begin_write(store)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		strings.write_string(&builder, "INSERT INTO t (id, v) VALUES ")
		for i in 1 ..= 1000 {
			if i > 1 do strings.write_string(&builder, ", ")
			fmt.sbprintf(&builder, "(%d, 'v%d')", i, i)
		}
		dropped_result_7797, insert_err := db.sql_execute_in_tx(tx, strings.to_string(builder))
		defer db.error_free(&insert_err)
		defer db.sql_result_destroy(&dropped_result_7797)
		testing.expect(t, db.error_ok(insert_err))
		testing.expect(t, db.error_ok(db.tx_commit(tx)))
	}

	db.store_reset_rows_scanned(store)
	ten, ten_err := db.sql_execute(store, "SELECT id FROM t LIMIT 10")
	if testing.expectf(t, db.error_ok(ten_err), "limit: %s", ten_err.message) {
		testing.expect_value(t, len(ten.rows), 10)
		testing.expect_value(t, ten.rows[0][0].i, i64(1))
		testing.expect_value(t, ten.rows[9][0].i, i64(10))
	}
	db.sql_result_destroy(&ten)
	scanned := db.store_rows_scanned(store)
	testing.expectf(t, scanned == 10, "the scan read %d rows for LIMIT 10", scanned)

	// OFFSET is kept: five rows are read to answer LIMIT 3 OFFSET 2.
	db.store_reset_rows_scanned(store)
	offset, offset_err := db.sql_execute(store, "SELECT id FROM t LIMIT 3 OFFSET 2")
	if testing.expectf(t, db.error_ok(offset_err), "limit offset: %s", offset_err.message) {
		testing.expect_value(t, len(offset.rows), 3)
		testing.expect_value(t, offset.rows[0][0].i, i64(3))
		testing.expect_value(t, offset.rows[2][0].i, i64(5))
	}
	db.sql_result_destroy(&offset)
	testing.expect_value(t, db.store_rows_scanned(store), u64(5))

	// A parameter decides it just as well.
	param, param_err := db.sql_execute_params(store, "SELECT id FROM t LIMIT ?", []db.Value{db.value_int(4)})
	if testing.expectf(t, db.error_ok(param_err), "limit param: %s", param_err.message) do testing.expect_value(t, len(param.rows), 4)
	db.sql_result_destroy(&param)

	// ORDER BY cannot stop early - it has to see the whole table - but the answer
	// is still the last three rows.
	descending, desc_err := db.sql_execute(store, "SELECT id FROM t ORDER BY id DESC LIMIT 3")
	if testing.expectf(t, db.error_ok(desc_err), "limit desc: %s", desc_err.message) {
		testing.expect_value(t, len(descending.rows), 3)
		testing.expect_value(t, descending.rows[0][0].i, i64(1000))
		testing.expect_value(t, descending.rows[2][0].i, i64(998))
	}
	db.sql_result_destroy(&descending)

	// A WHERE clause may discard rows, so the scan runs on.
	filtered, filtered_err := db.sql_execute(store, "SELECT id FROM t WHERE id > 990 LIMIT 2")
	if testing.expectf(t, db.error_ok(filtered_err), "limit where: %s", filtered_err.message) {
		testing.expect_value(t, len(filtered.rows), 2)
		testing.expect_value(t, filtered.rows[0][0].i, i64(991))
	}
	db.sql_result_destroy(&filtered)

	// And the join stops once it has its rows rather than building the product.
	run_done(t, store, "CREATE TABLE u (id INTEGER PRIMARY KEY)")
	{
		tx := db.tx_begin_write(store)
		for i in 1 ..= 200 {
			dropped_result_7852, insert_err := db.sql_execute_in_tx(tx, fmt.tprintf("INSERT INTO u (id) VALUES (%d)", i))
			defer db.error_free(&insert_err)
			defer db.sql_result_destroy(&dropped_result_7852)
			testing.expect(t, db.error_ok(insert_err))
		}
		testing.expect(t, db.error_ok(db.tx_commit(tx)))
	}
	db.store_reset_rows_scanned(store)
	pair, pair_err := db.sql_execute(store, "SELECT u.id, t.id FROM u, t LIMIT 5")
	if testing.expectf(t, db.error_ok(pair_err), "limit join: %s", pair_err.message) {
		testing.expect_value(t, len(pair.rows), 5)
		testing.expect_value(t, pair.rows[0][0].i, i64(1))
		testing.expect_value(t, pair.rows[0][1].i, i64(1))
	}
	db.sql_result_destroy(&pair)
	joined_scanned := db.store_rows_scanned(store)
	testing.expectf(t, joined_scanned < 300, "the join read %d rows for LIMIT 5", joined_scanned)
}

@(test)
test_row_quota_stops_a_cross_join :: proc(t: ^testing.T) {
	// A cross join used to build every combination before the projection could
	// count one row, so a quota could not stop the spike it exists for (D23).
	store := fresh_db(t, "quota_join")
	if store == nil do return
	defer cleanup_db(store, "quota_join")
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY)")
	{
		tx := db.tx_begin_write(store)
		for i in 1 ..= 200 {
			dropped_result_7881, insert_a := db.sql_execute_in_tx(tx, fmt.tprintf("INSERT INTO a (id) VALUES (%d)", i))
			defer db.error_free(&insert_a)
			defer db.sql_result_destroy(&dropped_result_7881)
			testing.expect(t, db.error_ok(insert_a))
			dropped_result_7883, insert_b := db.sql_execute_in_tx(tx, fmt.tprintf("INSERT INTO b (id) VALUES (%d)", i))
			defer db.error_free(&insert_b)
			defer db.sql_result_destroy(&dropped_result_7883)
			testing.expect(t, db.error_ok(insert_b))
		}
		testing.expect(t, db.error_ok(db.tx_commit(tx)))
	}
	db.store_set_row_quota(store, 100)
	defer db.store_set_row_quota(store, 0)
	db.store_reset_rows_scanned(store)
	cross, cross_err := db.sql_execute(store, "SELECT a.id, b.id FROM a, b")
	defer db.error_free(&cross_err)
	testing.expect_value(t, cross_err.kind, db.Error_Kind.Quota_Exceeded)
	db.sql_result_destroy(&cross)
	// 40 000 combinations exist; the refusal has to arrive while the join builds,
	// not after the whole product is in memory.
	scanned := db.store_rows_scanned(store)
	testing.expectf(t, scanned < 1000, "the join built %d rows before refusing", scanned)

	// A statement that can shrink its output is judged by what it emits: an
	// aggregate over the same cross join answers with one row.
	counted, counted_err := db.sql_execute(store, "SELECT count(*) FROM a, b")
	if testing.expectf(t, db.error_ok(counted_err), "count over a join: %s", counted_err.message) {
		testing.expect_value(t, counted.rows[0][0].i, i64(40000))
	}
	db.sql_result_destroy(&counted)

	// And the plain quota still refuses a single-table scan that is too wide.
	wide, wide_err := db.sql_execute(store, "SELECT * FROM a")
	defer db.error_free(&wide_err)
	testing.expect_value(t, wide_err.kind, db.Error_Kind.Quota_Exceeded)
	db.sql_result_destroy(&wide)
}

@(test)
test_rewrite_keeps_a_keyed_table_as_it_was :: proc(t: ^testing.T) {
	// The rest of D27: a table whose declaration SQLite backs with an automatic
	// index used to be rebuilt, because the rewrite could not number those
	// indexes. It can now, so a schema change elsewhere leaves the declaration -
	// and the numbers SQLite gives it - exactly as the file had them.
	source := "src/tests/fixtures/keys.sqlite"
	path := "_test_keys_mirror.db"
	os.remove(path)
	data, read_err := os.read_entire_file(source, context.allocator)
	if !testing.expect(t, read_err == nil) do return
	defer delete(data)
	if !testing.expect(t, os.write_entire_file(path, data) == nil) do return

	before, before_err := db.sqlite_file_open(path)
	if !testing.expect(t, db.error_ok(before_err)) do return
	originals := make(map[string]string)
	defer {
		for name, sql in originals {
			delete(name)
			delete(sql)
		}
		delete(originals)
	}
	// The keys are copies: `before` is destroyed below, and its names with it.
	for table in before.tables do originals[strings.clone(table.name)] = strings.clone(table.sql)
	group_counts := make(map[string]int, context.temp_allocator)
	for table in before.tables do group_counts[strings.clone(table.name, context.temp_allocator)] = len(table.key_order)
	db.sqlite_file_destroy(&before)

	conn, open_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "embed_open: %s", open_err.message) do return
	// A schema change takes the whole-file rewrite, which is the path that used to
	// rebuild every table from the engine's model.
	created, create_err := db.sql_execute(conn.store, "CREATE TABLE newcomer (id INTEGER PRIMARY KEY)")
	testing.expect(t, db.error_ok(create_err))
	db.sql_result_destroy(&created)
	db.embed_close(conn)

	after, after_err := db.sqlite_file_open(path)
	if !testing.expect(t, db.error_ok(after_err)) do return
	defer {
		db.sqlite_file_destroy(&after)
		os.remove(path)
	}
	seen := 0
	for table in after.tables {
		original, found := originals[table.name]
		if !found do continue
		testing.expect_value(t, table.sql, original)
		testing.expect_value(t, len(table.key_order), group_counts[table.name])
		seen += 1
	}
	testing.expect_value(t, seen, 5)
}

@(test)
test_mirror_patches_only_the_pages_it_touched :: proc(t: ^testing.T) {
	path := "_test_mirror_patch.db"
	journal := "_test_mirror_patch.db-journal"
	os.remove(path)
	os.remove(journal)

	// Build a database and export it, then open it the way a caller would.
	source := fresh_db(t, "mirror_patch_source")
	if source == nil do return
	run_done(t, source, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)")
	{
		tx := db.tx_begin_write(source)
		for i in 1 ..= 400 {
			dropped_result_7981, insert_err := db.sql_execute_in_tx_params(
				tx,
				"INSERT INTO items (id, name, score) VALUES (?, ?, ?)",
				[]db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("row%d", i)), db.value_int(i64(i % 10))},
			)
			defer db.error_free(&insert_err)
			defer db.sql_result_destroy(&dropped_result_7981)
			testing.expect(t, db.error_ok(insert_err))
		}
		testing.expect(t, db.error_ok(db.tx_commit(tx)))
	}
	_, _, export_err := db.sqlite_file_write(source, path)
	testing.expect(t, db.error_ok(export_err), "export must succeed")
	db.store_close(source)
	os.remove_all("_test_mirror_patch_source")

	conn, open_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "embed_open: %s", open_err.message) do return
	store := conn.store

	// One row of each kind: a commit should rewrite a leaf and the header, not
	// the table.
	insert, insert_err := db.sql_execute(store, "INSERT INTO items (id, name, score) VALUES (900, 'late', 3)")
	testing.expect(t, db.error_ok(insert_err))
	db.sql_result_destroy(&insert)
	pages_after_insert := store.mirror_pages_written
	testing.expectf(t, pages_after_insert > 0, "the insert must write something")
	testing.expectf(t, pages_after_insert <= 4, "an insert wrote %d pages", pages_after_insert)
	testing.expect_value(t, store.mirror_full_writes, 0)

	update, update_err := db.sql_execute(store, "UPDATE items SET name = 'renamed' WHERE id = 900")
	testing.expect(t, db.error_ok(update_err))
	db.sql_result_destroy(&update)
	testing.expectf(t, store.mirror_pages_written - pages_after_insert <= 4, "an update wrote too much")
	testing.expect_value(t, store.mirror_full_writes, 0)

	remove, remove_err := db.sql_execute(store, "DELETE FROM items WHERE id = 5")
	testing.expect(t, db.error_ok(remove_err))
	db.sql_result_destroy(&remove)
	testing.expect_value(t, store.mirror_full_writes, 0)
	testing.expect(t, store.mirror_bytes_written < 64 * 1024, "three commits must not rewrite the table")

	// No journal is left behind once the commits are durable.
	_, journal_err := os.stat(journal, context.temp_allocator)
	testing.expect(t, journal_err != nil, "the journal must be gone after a commit")
	db.embed_close(conn)

	// The file is still a database: every row but the deleted one is there, and
	// the renamed one carries its new value.
	file, file_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(file_err), "sqlite_file_open: %s", file_err.message) do return
	defer db.sqlite_file_destroy(&file)
	rows, rows_err := db.sqlite_table_rows(&file, &file.tables[0], context.allocator)
	if !testing.expectf(t, db.error_ok(rows_err), "read: %s", rows_err.message) do return
	defer {
		for row in rows do db.free_values(row)
		delete(rows)
	}
	testing.expect_value(t, len(rows), 400)
	found_late := false
	found_five := false
	for row in rows {
		if row[0].i == 900 {
			found_late = true
			testing.expect_value(t, row[1].s, "renamed")
		}
		if row[0].i == 5 do found_five = true
	}
	testing.expect(t, found_late, "the inserted row must be in the file")
	testing.expect(t, !found_five, "the deleted row must be gone")
	os.remove(path)
	os.remove(journal)
}

@(test)
test_mirror_survives_a_torn_commit :: proc(t: ^testing.T) {
	path := "_test_mirror_torn.db"
	journal := "_test_mirror_torn.db-journal"
	os.remove(path)
	os.remove(journal)

	source := fresh_db(t, "mirror_torn_source")
	if source == nil do return
	run_done(t, source, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
	{
		tx := db.tx_begin_write(source)
		for i in 1 ..= 200 {
			dropped_result_8066, err := db.sql_execute_in_tx_params(
				tx,
				"INSERT INTO t (id, v) VALUES (?, ?)",
				[]db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("v%d", i))},
			)
			defer db.error_free(&err)
			defer db.sql_result_destroy(&dropped_result_8066)
			testing.expect(t, db.error_ok(err))
		}
		testing.expect(t, db.error_ok(db.tx_commit(tx)))
	}
	_, _, export_err := db.sqlite_file_write(source, path)
	testing.expect(t, db.error_ok(export_err))
	db.store_close(source)
	os.remove_all("_test_mirror_torn_source")

	conn, open_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	// The first commit builds the layout and patches it; the second one is the
	// one that dies between its data pages and the header.
	first, first_err := db.sql_execute(conn.store, "INSERT INTO t (id, v) VALUES (900, 'nine')")
	testing.expect(t, db.error_ok(first_err))
	testing.expect_value(t, conn.store.last_error.kind, db.Error_Kind.None)
	db.sql_result_destroy(&first)
	db.store_mirror_crash_before_header(conn.store)
	second, second_err := db.sql_execute(conn.store, "INSERT INTO t (id, v) VALUES (901, 'ten')")
	// The commit itself is safe -- the log is the truth -- but the mirror says it
	// could not finish.
	testing.expect(t, db.error_ok(second_err))
	testing.expect_value(t, conn.store.last_error.kind, db.Error_Kind.Io)
	db.sql_result_destroy(&second)
	_, journal_err := os.stat(journal, context.temp_allocator)
	testing.expect(t, journal_err == nil, "the crash must leave its journal behind")
	db.embed_close(conn)

	// Opening the file as its owner rolls the torn commit back: the journal wins
	// and is deleted, so the file is the state before the crash.
	file, file_err := db.sqlite_file_open(path, context.allocator, true)
	if !testing.expectf(t, db.error_ok(file_err), "sqlite_file_open: %s", file_err.message) do return
	rows, rows_err := db.sqlite_table_rows(&file, &file.tables[0], context.allocator)
	testing.expect(t, db.error_ok(rows_err))
	testing.expect_value(t, len(rows), 201)
	recovered_nine := false
	recovered_ten := false
	for row in rows {
		if row[0].i == 900 do recovered_nine = true
		if row[0].i == 901 do recovered_ten = true
	}
	testing.expect(t, recovered_nine, "the committed row before the crash must survive")
	testing.expect(t, !recovered_ten, "the torn row must not be in the file")
	for row in rows do db.free_values(row)
	delete(rows)
	db.sqlite_file_destroy(&file)
	_, stale_err := os.stat(journal, context.temp_allocator)
	testing.expect(t, stale_err != nil, "recovery must delete the journal")

	// The file still takes commits after the recovery.
	again, again_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(again_err), "reopen: %s", again_err.message) do return
	last, last_err := db.sql_execute(again.store, "INSERT INTO t (id, v) VALUES (902, 'eleven')")
	testing.expect(t, db.error_ok(last_err))
	testing.expect_value(t, again.store.mirror_full_writes, 0)
	db.sql_result_destroy(&last)
	db.embed_close(again)
	os.remove(path)
	os.remove(journal)
}

// file_pages reads a SQLite file's own page count from its header.
@(private)
file_pages :: proc(t: ^testing.T, path: string) -> int {
	data, read_err := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, read_err == nil, "cannot read %s", path) do return 0
	defer delete(data)
	if len(data) < 32 do return 0
	pages := int(data[28]) << 24 | int(data[29]) << 16 | int(data[30]) << 8 | int(data[31])
	return pages
}

@(test)
test_mirror_grows_and_reopens :: proc(t: ^testing.T) {
	path := "_test_mirror_grow.db"
	os.remove(path)
	source := fresh_db(t, "mirror_grow_source")
	if source == nil do return
	run_done(t, source, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)")
	run_done(t, source, "CREATE TABLE others (id INTEGER PRIMARY KEY, tag TEXT)")
	run_done(t, source, "CREATE TABLE indexed (id INTEGER PRIMARY KEY, code INTEGER)")
	run_done(t, source, "CREATE INDEX indexed_code ON indexed (code)")
	{
		tx := db.tx_begin_write(source)
		for i in 1 ..= 400 {
			dropped_result_8156, err := db.sql_execute_in_tx_params(
				tx,
				"INSERT INTO items (id, name, score) VALUES (?, ?, ?)",
				[]db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("row%d", i)), db.value_int(i64(i % 10))},
			)
			defer db.error_free(&err)
			defer db.sql_result_destroy(&dropped_result_8156)
			testing.expect(t, db.error_ok(err))
		}
		for i in 1 ..= 50 {
			dropped_result_8164, err := db.sql_execute_in_tx_params(
				tx,
				"INSERT INTO others (id, tag) VALUES (?, ?)",
				[]db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("tag%d", i))},
			)
			defer db.error_free(&err)
			defer db.sql_result_destroy(&dropped_result_8164)
			testing.expect(t, db.error_ok(err))
		}
		testing.expect(t, db.error_ok(db.tx_commit(tx)))
	}
	_, _, export_err := db.sqlite_file_write(source, path)
	testing.expect(t, db.error_ok(export_err))
	db.store_close(source)
	os.remove_all("_test_mirror_grow_source")

	conn, open_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	mirror_check :: proc(t: ^testing.T, path: string) {
		ok, reason := db.sqlite_mirror_validate(path)
		testing.expectf(t, ok, "the mirrored tree is broken: %s", reason)
	}
	mirror_statement :: proc(t: ^testing.T, store: ^db.Store, sql: string) {
		result, err := db.sql_execute(store, sql)
		testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
		db.sql_result_destroy(&result)
	}
	mirror_statement(t, conn.store, "INSERT INTO items (id, name, score) VALUES (900, 'late', 3)")
	mirror_statement(t, conn.store, "UPDATE items SET name = 'renamed' WHERE id = 900")
	mirror_statement(t, conn.store, "DELETE FROM items WHERE id = 5")
	mirror_statement(t, conn.store, "INSERT INTO others (id, tag) VALUES (77, 'extra')")
	// Growth: enough rows to split leaves and make the tree taller than one page.
	{
		tx := db.tx_begin_write(conn.store)
		for i in 1000 ..= 2500 {
			dropped_result_8197, err := db.sql_execute_in_tx_params(
				tx,
				"INSERT INTO items (id, name, score) VALUES (?, ?, ?)",
				[]db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("bulk%d", i)), db.value_int(i64(i % 7))},
			)
			defer db.error_free(&err)
			defer db.sql_result_destroy(&dropped_result_8197)
			testing.expect(t, db.error_ok(err))
		}
		testing.expect(t, db.error_ok(db.tx_commit(tx)))
	}
	testing.expectf(
		t,
		conn.store.mirror_full_writes == 0,
		"growth must patch in place, full=%d reason=%s",
		conn.store.mirror_full_writes,
		conn.store.mirror_reason,
	)
	mirror_check(t, path)
	mirror_statement(t, conn.store, "DELETE FROM items WHERE id > 2400")
	mirror_check(t, path)
	// A table with a secondary index cannot be patched: it re-encodes the file.
	mirror_statement(t, conn.store, "INSERT INTO indexed (id, code) VALUES (1, 10)")
	testing.expect(t, conn.store.mirror_full_writes > 0, "an indexed table must re-encode")
	// A schema change re-encodes too, and patching resumes afterwards.
	mirror_statement(t, conn.store, "CREATE TABLE fresh (id INTEGER PRIMARY KEY, v TEXT)")
	fulls := conn.store.mirror_full_writes
	mirror_statement(t, conn.store, "INSERT INTO items (id, name, score) VALUES (9999, 'after', 1)")
	testing.expect_value(t, conn.store.mirror_full_writes, fulls)
	mirror_check(t, path)

	// Emptying a leaf unlinks it and puts its page on the free list; the next
	// growth takes that page back instead of making the file longer.
	before := file_pages(t, path)
	mirror_statement(t, conn.store, "DELETE FROM items WHERE id BETWEEN 2300 AND 2400")
	after_delete := file_pages(t, path)
	mirror_statement(t, conn.store, "INSERT INTO items (id, name, score) VALUES (3001, 'refill', 1), (3002, 'refill', 1), (3003, 'refill', 1)")
	after_insert := file_pages(t, path)
	mirror_check(t, path)
	testing.expectf(
		t,
		after_insert <= after_delete + 1,
		"a freed page was not reused: %d pages after the delete, %d after the insert",
		after_delete,
		after_insert,
	)
	testing.expect(t, after_delete <= before, "a delete must not grow the file")
	testing.expect_value(t, conn.store.mirror_full_writes, fulls)
	db.embed_close(conn)

	// Reopening reads the layout back from the file and keeps patching.
	again, again_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(again_err), "reopen: %s", again_err.message) do return
	mirror_statement(t, again.store, "INSERT INTO items (id, name, score) VALUES (10000, 'third', 2)")
	mirror_statement(t, again.store, "DELETE FROM items WHERE id = 1000")
	testing.expect_value(t, again.store.mirror_full_writes, 0)
	db.embed_close(again)

	file, file_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(file_err), "sqlite_file_open: %s", file_err.message) do return
	defer db.sqlite_file_destroy(&file)
	// Every table the commits touched is still there, with the right rows.
	counts := make(map[string]int)
	for &table in file.tables {
		rows, rows_err := db.sqlite_table_rows(&file, &table, context.allocator)
		testing.expectf(t, db.error_ok(rows_err), "read %s: %s", table.name, rows_err.message)
		counts[table.name] = len(rows)
		for row in rows do db.free_values(row)
		delete(rows)
	}
	defer delete(counts)
	// 400 + one late row + 1501 bulk rows - 100 over 2400 - 101 emptied from a
	// leaf + 3 that refilled the freed page - 2 deleted around the reopen.
	testing.expect_value(t, counts["items"], 1704)
	testing.expect_value(t, counts["others"], 51)
	testing.expect_value(t, counts["indexed"], 1)
	testing.expect_value(t, counts["fresh"], 0)
	os.remove(path)
}

@(test)
test_column_collation_and_generated :: proc(t: ^testing.T) {
	path := fmt.aprintf("_test_%s", "collgen")
	defer delete(path)
	defer os.remove_all(path)
	os.remove_all(path)
	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return

	run_done(t, store, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE UNIQUE, tag TEXT)")
	run_done(t, store, "INSERT INTO users (id, name, tag) VALUES (1, 'Alice', 'A'), (2, 'bob', 'B')")

	// The column's collation applies without an explicit COLLATE.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM users WHERE name = 'alice'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM users WHERE name = 'ALICE'").i, i64(1))
	// Sorting folds too: alice before bob.
	ordered := run(t, store, "SELECT name FROM users ORDER BY name")
	testing.expect_value(t, ordered.rows[0][0].s, "Alice")
	testing.expect_value(t, ordered.rows[1][0].s, "bob")
	db.sql_result_destroy(&ordered)
	// The unique index is case-insensitive.
	dropped_result_8200, duplicate := db.sql_execute(store, "INSERT INTO users (id, name) VALUES (3, 'ALICE')")
	defer db.error_free(&duplicate)
	defer db.sql_result_destroy(&dropped_result_8200)
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Unique)
	// A column without a collation keeps BINARY.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM users WHERE tag = 'a'").i, i64(0))

	// GENERATED columns are computed on write, from the row being stored.
	run_done(t, store, "CREATE TABLE lines (id INTEGER PRIMARY KEY, qty INTEGER NOT NULL, price INTEGER NOT NULL, total INTEGER GENERATED ALWAYS AS (qty * price) STORED)")
	run_done(t, store, "INSERT INTO lines (id, qty, price) VALUES (1, 2, 5)")
	testing.expect_value(t, scalar(t, store, "SELECT total FROM lines WHERE id = 1").i, i64(10))
	run_done(t, store, "UPDATE lines SET qty = 3 WHERE id = 1")
	testing.expect_value(t, scalar(t, store, "SELECT total FROM lines WHERE id = 1").i, i64(15))
	// A generated column cannot be written directly.
	dropped_result_8156, direct_insert := db.sql_execute(store, "INSERT INTO lines (id, qty, price, total) VALUES (2, 1, 1, 99)")
	defer db.error_free(&direct_insert)
	defer db.sql_result_destroy(&dropped_result_8156)
	testing.expect_value(t, direct_insert.kind, db.Error_Kind.Invalid_Argument)
	dropped_result_8158, direct_update := db.sql_execute(store, "UPDATE lines SET total = 0")
	defer db.error_free(&direct_update)
	defer db.sql_result_destroy(&dropped_result_8158)
	testing.expect_value(t, direct_update.kind, db.Error_Kind.Invalid_Argument)

	// Both survive a reopen: the flags and the expression travel in the schema.
	db.store_close(store)
	reopened, reopen_err := db.store_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(reopen_err), "reopen: %s", reopen_err.message) do return
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM users WHERE name = 'ALiCe'").i, i64(1))
	testing.expect_value(t, scalar(t, reopened, "SELECT total FROM lines WHERE id = 1").i, i64(15))
	run_done(t, reopened, "UPDATE lines SET price = 10 WHERE id = 1")
	testing.expect_value(t, scalar(t, reopened, "SELECT total FROM lines WHERE id = 1").i, i64(30))
	db.store_close(reopened)
}

// A column JOIN ... USING (or NATURAL JOIN) shares is the join's, unqualified:
// the left side's value, or the right side's where an outer join left the
// left one NULL. Every answer here is SQLite 3.54.1's.
@(test)
test_using_column_is_the_joins :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "using_column")
	if store == nil do return
	defer destroy_host(store, host, "using_column")
	run_done(t, store, "CREATE TABLE v (a INT, b INT)")
	run_done(t, store, "CREATE TABLE w (a INT, c INT)")
	run_done(t, store, "INSERT INTO v VALUES (1, 2), (5, 6)")
	run_done(t, store, "INSERT INTO w VALUES (1, 3), (7, 8)")
	testing.expect_value(t, scalar(t, store, "SELECT a FROM v JOIN w USING (a)").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT a FROM v NATURAL JOIN w").i, i64(1))
	full := run_temp(t, store, "SELECT a FROM v FULL JOIN w USING (a) ORDER BY a").rows
	if testing.expect_value(t, len(full), 3) {
		testing.expect_value(t, full[0][0].i, i64(1))
		testing.expect_value(t, full[1][0].i, i64(5))
		testing.expect_value(t, full[2][0].i, i64(7))
	}
}

// Under SQLite's rules a name two relations of a query have is ambiguous at
// prepare, in SQLite's words; a USING or NATURAL column is not.
@(test)
test_ambiguous_column_at_prepare :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	conn.store.sqlite_names = true
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE v (a, b)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE w (a, c)")))
	for sql in ([]string{"SELECT a FROM v, w", "SELECT a FROM v AS p, v AS q", "SELECT v.a FROM v, w WHERE a = 1", "SELECT rowid FROM v, w"}) {
		stmt := db.embed_prepare(conn, sql)
		testing.expectf(t, stmt == nil, "%s was prepared", sql)
		if stmt != nil do db.embed_finalize(stmt)
		testing.expect(t, strings.has_prefix(db.embed_error(conn), "ambiguous column name: "))
	}
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE k (a PRIMARY KEY, n)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE o (oid, d)")))
	for sql in ([]string{"SELECT a FROM v JOIN w USING (a)", "SELECT a FROM v NATURAL JOIN w", "SELECT b, c FROM v, w", "INSERT INTO k VALUES (1, 1) ON CONFLICT (a) DO UPDATE SET n = n + excluded.n", "SELECT oid FROM v, o"}) {
		stmt := db.embed_prepare(conn, sql)
		testing.expectf(t, stmt != nil, "%s: %s", sql, db.embed_error(conn))
		if stmt != nil do db.embed_finalize(stmt)
	}
}

// Under SQLite's rules a call is checked at prepare, as SQLite checks it: a
// function no one has is "no such function", a count of arguments it does
// not take "wrong number of arguments". A program's function takes what it
// registered; a function only the engine has is not refused for being unknown.
@(test)
test_function_calls_checked_at_prepare :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	conn.store.sqlite_names = true
	one :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
		return db.value_int(1), db.ERROR_NONE
	}
	testing.expect(t, db.error_ok(db.store_register_function(conn.store, "mine", 1, one)))
	refused := []struct {
		sql, message: string,
	} {
		{"SELECT nofunc(1)", "no such function: nofunc"},
		{"SELECT abs()", "wrong number of arguments to function abs()"},
		{"SELECT substr('x')", "wrong number of arguments to function substr()"},
		{"SELECT coalesce(1)", "wrong number of arguments to function coalesce()"},
		{"SELECT mine(1, 2)", "wrong number of arguments to function mine()"},
	}
	for case_ in refused {
		stmt := db.embed_prepare(conn, case_.sql)
		testing.expectf(t, stmt == nil, "%s was prepared", case_.sql)
		if stmt != nil do db.embed_finalize(stmt)
		testing.expect_value(t, db.embed_error(conn), case_.message)
	}
	for sql in ([]string{"SELECT abs(1), substr('x', 1), coalesce(1, 2), count(*)", "SELECT mine(1)", "SELECT max(1, 2, 3), iif(1, 2)", "SELECT array_length(NULL)"}) {
		stmt := db.embed_prepare(conn, sql)
		testing.expectf(t, stmt != nil, "%s: %s", sql, db.embed_error(conn))
		if stmt != nil do db.embed_finalize(stmt)
	}
}

// A table renamed to a name another table, view or index has is refused, in
// SQLite's words (renaming over a view left two objects of one name); under
// SQLite's rules a trigger's name is taken once, whatever its case.
@(test)
test_ddl_name_collisions :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	for sql in ([]string{"CREATE TABLE v (a)", "CREATE TABLE x (a)", "CREATE INDEX xi ON x (a)", "CREATE VIEW w AS SELECT 1"}) {
		testing.expect(t, db.error_drop(db.embed_exec(conn, sql)))
	}
	for target in ([]string{"w", "x", "xi"}) {
		err := db.embed_exec(conn, fmt.tprintf("ALTER TABLE v RENAME TO %s", target))
		testing.expect_value(t, err.message, fmt.tprintf("there is already another table or index with this name: %s", target))
		db.error_free(&err)
	}
	testing.expect(t, db.error_drop(db.embed_exec(conn, "ALTER TABLE v RENAME TO v2")))
	conn.store.sqlite_names = true
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TRIGGER tr AFTER INSERT ON v2 BEGIN SELECT 1; END")))
	again := db.embed_exec(conn, "CREATE TRIGGER TR AFTER INSERT ON v2 BEGIN SELECT 1; END")
	testing.expect_value(t, again.message, "trigger TR already exists")
	db.error_free(&again)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TRIGGER IF NOT EXISTS tr AFTER INSERT ON v2 BEGIN SELECT 1; END")))
	reserved := db.embed_exec(conn, "ALTER TABLE v2 RENAME TO sqlite_x")
	testing.expect_value(t, reserved.message, "object name reserved for internal use: sqlite_x")
	db.error_free(&reserved)
}

// A transaction that writes a table and then drops it commits: the rows it
// staged go with the table (the commit applied them after the drop, failed,
// and lost the whole transaction). A ROLLBACK TO before the drop brings both
// back.
@(test)
test_drop_after_writes_commits :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	exec :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, loc := #caller_location) {
		err := db.embed_exec(conn, sql)
		testing.expectf(t, err.kind == .None, "%s: %s", sql, err.message, loc = loc)
		db.error_free(&err)
	}
	exec(t, conn, "CREATE TABLE t (a INT)")
	exec(t, conn, "CREATE TABLE keep (a INT)")
	exec(t, conn, "INSERT INTO t VALUES (1)")
	exec(t, conn, "BEGIN")
	exec(t, conn, "INSERT INTO t VALUES (9)")
	exec(t, conn, "UPDATE t SET a = 2 WHERE a = 1")
	exec(t, conn, "INSERT INTO keep VALUES (7)")
	exec(t, conn, "DROP TABLE t")
	exec(t, conn, "COMMIT")
	testing.expect(t, tx_has_table(conn, "keep") && !tx_has_table(conn, "t"))

	exec(t, conn, "CREATE TABLE u (a INT)")
	exec(t, conn, "BEGIN")
	exec(t, conn, "INSERT INTO u VALUES (1)")
	exec(t, conn, "SAVEPOINT s")
	exec(t, conn, "INSERT INTO u VALUES (2)")
	exec(t, conn, "DROP TABLE u")
	exec(t, conn, "ROLLBACK TO s")
	exec(t, conn, "COMMIT")
	stmt := db.embed_prepare(conn, "SELECT count(*), sum(a) FROM u")
	if testing.expect(t, stmt != nil) {
		_, step_err := db.embed_step(stmt)
		testing.expect(t, db.error_drop(step_err))
		testing.expect_value(t, db.embed_column_int(stmt, 0), i64(1))
		testing.expect_value(t, db.embed_column_int(stmt, 1), i64(1))
		db.embed_finalize(stmt)
	}
	tx_has_table :: proc(conn: ^db.Embed_Conn, name: string) -> bool {
		_, found := conn.store.tables[name]
		return found
	}
}

// A program that asks for a statement's columns before its first step makes
// it run then; a runtime error it meets is still the first step's answer
// (SQLite's shell asks first, and printed nothing for such an error).
@(test)
test_step_reports_error_of_early_run :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	for ask in 0 ..< 3 {
		stmt := db.embed_prepare(conn, "SELECT json('{')")
		if !testing.expect(t, stmt != nil) do return
		switch ask {
		case 1:
			_ = db.embed_column_count(stmt)
		case 2:
			_ = db.embed_column_name(stmt, 0)
		}
		has_row, step_err := db.embed_step(stmt)
		testing.expectf(t, !has_row && step_err.kind != .None, "ask %d: the step answered no error", ask)
		testing.expect_value(t, db.embed_error(conn), "malformed JSON")
		db.error_free(&step_err)
		// A reset runs it again, and the error comes again.
		db.embed_reset(stmt)
		_ = db.embed_column_count(stmt)
		_, again := db.embed_step(stmt)
		testing.expect(t, again.kind != .None)
		db.error_free(&again)
		db.embed_finalize(stmt)
	}
}

// A scalar subquery's value outlives the subquery: an aggregate's text was
// read after its result had been freed (an UPDATE stored the freed bytes).
@(test)
test_scalar_subquery_text_outlives_it :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "scalar_subquery_text")
	if store == nil do return
	defer destroy_host(store, host, "scalar_subquery_text")
	run_done(t, store, "CREATE TABLE s (k INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO s VALUES (1, 'a'), (2, 'zz-the-largest-label-of-all-of-them'), (3, 'm')")
	testing.expect_value(t, scalar(t, store, "SELECT (SELECT max(label) FROM s) || '!'").s, "zz-the-largest-label-of-all-of-them!")
	run_done(t, store, "UPDATE s SET label = (SELECT upper(max(label)) FROM s) WHERE k = 1")
	run_done(t, store, "INSERT INTO s VALUES (4, 'filler-' || hex(randomblob(64)))")
	testing.expect_value(t, scalar(t, store, "SELECT label FROM s WHERE k = 1").s, "ZZ-THE-LARGEST-LABEL-OF-ALL-OF-THEM")
}

@(test)
test_attach_and_detach :: proc(t: ^testing.T) {
	other_path := fmt.aprintf("_test_%s", "attached_other")
	defer delete(other_path)
	os.remove_all(other_path)
	other, open_err := db.store_open(other_path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open other: %s", open_err.message) do return
	run_done(t, other, "CREATE TABLE other_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	run_done(t, other, "INSERT INTO other_items (id, name) VALUES (1, 'one'), (2, 'two')")
	db.store_close(other)

	store, host := fresh_host(t, "attach_principal")
	if store == nil do return
	// Closed below for the reopen, so the handles are released explicitly.
	run_done(t, store, "CREATE TABLE mine (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
	run_done(t, store, "INSERT INTO mine (id, label) VALUES (10, 'ten')")

	// A table of the attached database is readable through `name.table`.
	attach_sql := fmt.aprintf("ATTACH '%s' AS side", other_path)
	defer delete(attach_sql)
	attach_result := run(t, store, attach_sql)
	defer db.sql_result_destroy(&attach_result)
	testing.expect_value(t, attach_result.kind, db.Sql_Result_Kind.Ack)
	count := scalar(t, store, "SELECT count(*) FROM side.other_items")
	testing.expect_value(t, count.i, i64(2))

	// A join across the two databases works, and the attached log is untouched.
	joined := run(t, store, "SELECT mine.label, side.other_items.name FROM mine, side.other_items WHERE side.other_items.id = 2")
	testing.expect_value(t, len(joined.rows), 1)
	testing.expect_value(t, joined.rows[0][0].s, "ten")
	testing.expect_value(t, joined.rows[0][1].s, "two")
	db.sql_result_destroy(&joined)

	// Attaching the same name twice is refused.
	dropped_result_8410, twice := db.sql_execute(store, attach_sql)
	defer db.error_free(&twice)
	defer db.sql_result_destroy(&dropped_result_8410)
	testing.expect_value(t, twice.kind, db.Error_Kind.Invalid_Argument)

	// An unknown database and an unknown table are clean errors.
	dropped_result_8476, unknown_db := db.sql_execute(store, "SELECT * FROM nope.other_items")
	defer db.error_free(&unknown_db)
	defer db.sql_result_destroy(&dropped_result_8476)
	testing.expect_value(t, unknown_db.kind, db.Error_Kind.Table_Not_Found)
	dropped_result_8478, unknown_table := db.sql_execute(store, "SELECT * FROM side.nope")
	defer db.error_free(&unknown_table)
	defer db.sql_result_destroy(&dropped_result_8478)
	testing.expect_value(t, unknown_table.kind, db.Error_Kind.Table_Not_Found)

	// A write to the attached database lands there, as in SQLite.
	write_result, write := db.sql_execute(store, "INSERT INTO side.other_items (id, name) VALUES (3, 'three')")
	testing.expectf(t, db.error_ok(write), "write: %s", write.message)
	db.sql_result_destroy(&write_result)

	// A write to one database reads the others, as SQLite resolves names
	// across the connection: main's rows into side, side's into main, and
	// side's own rows into side, all in the statement's transaction.
	run_done(t, store, "CREATE TABLE side.copied (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO side.copied SELECT id, label FROM mine")
	testing.expect_value(t, scalar(t, store, "SELECT label FROM side.copied WHERE id = 10").s, "ten")
	run_done(t, store, "INSERT INTO side.copied SELECT id + 100, name FROM side.other_items WHERE id = 1")
	testing.expect_value(t, scalar(t, store, "SELECT label FROM side.copied WHERE id = 101").s, "one")
	run_done(t, store, "UPDATE side.copied SET label = (SELECT max(label) FROM mine) WHERE id = 101")
	testing.expect_value(t, scalar(t, store, "SELECT label FROM side.copied WHERE id = 101").s, "ten")
	run_done(t, store, "INSERT INTO mine SELECT id + 1000, name FROM side.other_items")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM mine").i, i64(4))
	run_done(t, store, "DELETE FROM side.copied WHERE id IN (SELECT id FROM mine)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM side.copied").i, i64(1))
	run_done(t, store, "DROP TABLE side.copied")
	run_done(t, store, "DELETE FROM mine WHERE id > 1000")

	// The catalog survives a reopen of the principal.
	db.host_destroy(host)
	db.store_close(store)
	reopened, reopen_err := db.store_open("_test_attach_principal", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(reopen_err), "reopen: %s", reopen_err.message) do return
	host = db.host_init(reopened)
	count = scalar(t, reopened, "SELECT count(*) FROM side.other_items")
	testing.expect_value(t, count.i, i64(3))

	// DETACH forgets it, and a reopen stays detached.
	detach_result := run(t, reopened, "DETACH side")
	defer db.sql_result_destroy(&detach_result)
	testing.expect_value(t, detach_result.kind, db.Sql_Result_Kind.Ack)
	dropped_result_8515, gone := db.sql_execute(reopened, "SELECT * FROM side.other_items")
	defer db.error_free(&gone)
	defer db.sql_result_destroy(&dropped_result_8515)
	testing.expect_value(t, gone.kind, db.Error_Kind.Table_Not_Found)

	db.store_close(reopened)
	again, again_err := db.store_open("_test_attach_principal", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(again_err), "reopen after detach: %s", again_err.message) do return
	dropped_result_8521, still_gone := db.sql_execute(again, "SELECT * FROM side.other_items")
	defer db.error_free(&still_gone)
	defer db.sql_result_destroy(&dropped_result_8521)
	testing.expect_value(t, still_gone.kind, db.Error_Kind.Table_Not_Found)
	db.store_close(again)
	db.host_destroy(host)
	os.remove_all("_test_attach_principal")
	os.remove_all(other_path)
}

@(test)
test_json_table_functions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "json_table")
	if store == nil do return
	defer destroy_host(store, host, "json_table")

	// json_each walks the direct children of a document.
	walked := run(t, store, `SELECT key, value, type, atom, fullkey, path FROM json_each('[10, "two", {"a": 1}]')`)
	testing.expect_value(t, len(walked.rows), 3)
	testing.expect_value(t, walked.rows[0][0].i, i64(0))
	testing.expect_value(t, walked.rows[0][1].i, i64(10))
	testing.expect_value(t, walked.rows[0][2].s, "integer")
	testing.expect_value(t, walked.rows[0][4].s, "$[0]")
	testing.expect_value(t, walked.rows[0][5].s, "$")
	testing.expect_value(t, walked.rows[1][1].s, "two")
	testing.expect_value(t, walked.rows[1][2].s, "text")
	// A container value is its JSON text and has no atom.
	testing.expect_value(t, walked.rows[2][1].s, `{"a":1}`)
	testing.expect_value(t, walked.rows[2][2].s, "object")
	testing.expect(t, db.value_is_null(walked.rows[2][3]))
	db.sql_result_destroy(&walked)

	// An object keys by name, quoting a member that would not read back.
	object := run(t, store, `SELECT key, fullkey FROM json_each('{"a": 1, "b c": 2}') ORDER BY key`)
	testing.expect_value(t, len(object.rows), 2)
	testing.expect_value(t, object.rows[0][0].s, "a")
	testing.expect_value(t, object.rows[0][1].s, "$.a")
	testing.expect_value(t, object.rows[1][0].s, "b c")
	testing.expect_value(t, object.rows[1][1].s, `$."b c"`)
	db.sql_result_destroy(&object)

	// A scalar document is one row with no key.
	scalar_doc := run(t, store, "SELECT key, value, type FROM json_each('7')")
	testing.expect_value(t, len(scalar_doc.rows), 1)
	testing.expect(t, db.value_is_null(scalar_doc.rows[0][0]))
	testing.expect_value(t, scalar_doc.rows[0][1].i, i64(7))
	db.sql_result_destroy(&scalar_doc)

	// json_tree yields nested nodes with a parent link.
	tree := run(t, store, `SELECT type, fullkey, parent FROM json_tree('{"a": [1, 2]}') ORDER BY id`)
	testing.expect_value(t, len(tree.rows), 4)
	testing.expect_value(t, tree.rows[0][0].s, "object")
	testing.expect_value(t, tree.rows[0][1].s, "$")
	testing.expect(t, db.value_is_null(tree.rows[0][2]))
	testing.expect_value(t, tree.rows[1][0].s, "array")
	testing.expect_value(t, tree.rows[1][1].s, "$.a")
	testing.expect_value(t, tree.rows[1][2].i, i64(1))
	testing.expect_value(t, tree.rows[2][1].s, "$.a[0]")
	testing.expect_value(t, tree.rows[2][2].i, i64(2))
	db.sql_result_destroy(&tree)

	// The argument may be a column of a real table, materialized per statement.
	run_done(t, store, "CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT)")
	run_done(t, store, `INSERT INTO docs (id, body) VALUES (1, '[10, 20]')`)
	joined := run(t, store, "SELECT docs.id, json_each.value FROM docs, json_each(docs.body) ORDER BY json_each.value")
	testing.expect_value(t, len(joined.rows), 2)
	testing.expect_value(t, joined.rows[0][1].i, i64(10))
	testing.expect_value(t, joined.rows[1][1].i, i64(20))
	db.sql_result_destroy(&joined)

	// Bad input is a clean error, not a crash.
	dropped_result_8590, invalid := db.sql_execute(store, "SELECT * FROM json_each('not json')")
	defer db.error_free(&invalid)
	defer db.sql_result_destroy(&dropped_result_8590)
	testing.expect_value(t, invalid.kind, db.Error_Kind.Invalid_Argument)
	dropped_result_8592, missing := db.sql_execute(store, "SELECT * FROM json_each()")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_8592)
	testing.expect_value(t, missing.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_pragma_list_and_accepted_settings :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "pragma_extra")
	if store == nil do return
	defer destroy_host(store, host, "pragma_extra")
	names := run(t, store, "PRAGMA pragma_list")
	defer db.sql_result_destroy(&names)
	found := false
	for row in names.rows {
		if row[0].s == "table_info" do found = true
	}
	testing.expect(t, found)
	functions := run(t, store, "PRAGMA function_list")
	defer db.sql_result_destroy(&functions)
	testing.expect(t, len(functions.rows) > 20)
	// Settings a client inspects answer what the engine actually does, not a
	// neutral number: a database that claims WAL or a page cache it does not have
	// makes a caller build on a guarantee that is not there.
	testing.expect_value(t, run_temp(t, store, "PRAGMA cache_size").rows[0][0].i, i64(0))
	testing.expect_value(t, run_temp(t, store, "PRAGMA mmap_size").rows[0][0].i, i64(0))
	testing.expect_value(t, run_temp(t, store, "PRAGMA page_size").rows[0][0].i, i64(4096))
	testing.expect_value(t, run_temp(t, store, "PRAGMA encoding").rows[0][0].s, "UTF-8")
	testing.expect_value(t, run_temp(t, store, "PRAGMA foreign_keys").rows[0][0].i, i64(1))
	testing.expect_value(t, run_temp(t, store, "PRAGMA journal_mode").rows[0][0].s, "delete")
	// The locks are taken per transaction: SQLite's `normal`. Asking for
	// `exclusive` answers the mode in effect instead of failing, as SQLite does
	// when it cannot switch.
	testing.expect_value(t, run_temp(t, store, "PRAGMA locking_mode").rows[0][0].s, "normal")
	testing.expect_value(t, run_temp(t, store, "PRAGMA locking_mode = EXCLUSIVE").rows[0][0].s, "normal")
	// fresh_db opens with durable = false, so the honest answer is OFF (0).
	testing.expect_value(t, run_temp(t, store, "PRAGMA synchronous").rows[0][0].i, i64(0))
	testing.expect_value(t, run_temp(t, store, "PRAGMA data_version").rows[0][0].i, i64(store.commit_seq))
	testing.expect_value(t, run_temp(t, store, "PRAGMA freelist_count").rows[0][0].i, i64(0))
	testing.expect(t, run_temp(t, store, "PRAGMA page_count").rows[0][0].i > 0)

	// synchronous is a real setting: it moves the durability of the next commit.
	testing.expect_value(t, run_temp(t, store, "PRAGMA synchronous = NORMAL").kind, db.Sql_Result_Kind.Ack)
	testing.expect_value(t, run_temp(t, store, "PRAGMA synchronous").rows[0][0].i, i64(1))
	testing.expect_value(t, store.log.durability, db.Durability.Batched)
	testing.expect_value(t, run_temp(t, store, "PRAGMA synchronous = FULL").kind, db.Sql_Result_Kind.Ack)
	testing.expect_value(t, store.log.durability, db.Durability.Full)
	dropped_result_8570, bad_level := db.sql_execute(store, "PRAGMA synchronous = sometimes")
	defer db.error_free(&bad_level)
	defer db.sql_result_destroy(&dropped_result_8570)
	testing.expect_value(t, bad_level.kind, db.Error_Kind.Invalid_Argument)

	// A knob that would change what a statement does cannot be accepted silently:
	// the read tells the truth and the write is refused.
	testing.expect_value(t, run_temp(t, store, "PRAGMA query_only").rows[0][0].i, i64(0))
	dropped_result_8576, query_only := db.sql_execute(store, "PRAGMA query_only = ON")
	defer db.error_free(&query_only)
	defer db.sql_result_destroy(&dropped_result_8576)
	testing.expect_value(t, query_only.kind, db.Error_Kind.Sql_Unsupported)

	// Tuning knobs with no equivalent are still accepted.
	testing.expect_value(t, run_temp(t, store, "PRAGMA busy_timeout = 5000").kind, db.Sql_Result_Kind.Ack)
	testing.expect_value(t, run_temp(t, store, "PRAGMA busy_timeout").rows[0][0].i, i64(0))

	dropped_result_8583, unknown := db.sql_execute(store, "PRAGMA not_a_pragma")
	defer db.error_free(&unknown)
	defer db.sql_result_destroy(&dropped_result_8583)
	testing.expect_value(t, unknown.kind, db.Error_Kind.Sql_Unsupported)
}

@(test)
test_like_glob_functions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "like_glob")
	if store == nil do return
	defer destroy_host(store, host, "like_glob")
	result := run(t, store, "SELECT glob('a*', 'abc'), glob('a*', 'xbc'), like('A%', 'abc'), like('a%', 'xbc'), glob('a*', NULL)")
	defer db.sql_result_destroy(&result)
	row := result.rows[0]
	testing.expect(t, row[0].b)
	testing.expect(t, !row[1].b)
	testing.expect(t, row[2].b) // LIKE ignores case
	testing.expect(t, !row[3].b)
	testing.expect(t, db.value_is_null(row[4]))
	// The function form accepts columns and patterns from the table.
	run_done(t, store, "CREATE TABLE files (name TEXT)")
	run_done(t, store, "INSERT INTO files (name) VALUES ('alpha.txt'), ('beta.log')")
	count := scalar(t, store, "SELECT count(*) FROM files WHERE glob('*.txt', name)")
	testing.expect_value(t, count.i, i64(1))
}

@(test)
test_insert_select :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "insert_select")
	if store == nil do return
	defer destroy_host(store, host, "insert_select")
	run_done(t, store, "CREATE TABLE src (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)")
	run_done(t, store, "INSERT INTO src (name, qty) VALUES ('a', 1), ('b', 2), ('c', 3)")
	run_done(t, store, "CREATE TABLE dst (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)")
	inserted := run(t, store, "INSERT INTO dst (name, qty) SELECT name, qty FROM src WHERE qty > 1")
	defer db.sql_result_destroy(&inserted)
	testing.expect_value(t, inserted.affected, 2)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM dst").i, i64(2))
	// A query without FROM supplies literal values.
	testing.expect_value(t, run_temp(t, store, "INSERT INTO dst (name, qty) SELECT 'x', 9").affected, 1)
	// RETURNING reports the rows the query supplied.
	back := run(t, store, "INSERT INTO dst (name, qty) SELECT name, qty FROM src WHERE qty >= 3 RETURNING name")
	defer db.sql_result_destroy(&back)
	testing.expect_value(t, len(back.rows), 1)
	testing.expect_value(t, back.rows[0][0].s, "c")
	// An arity mismatch is rejected before anything is written.
	dropped_result_8626, mismatch := db.sql_execute(store, "INSERT INTO dst (name) SELECT name, qty FROM src")
	defer db.error_free(&mismatch)
	defer db.sql_result_destroy(&dropped_result_8626)
	testing.expect_value(t, mismatch.kind, db.Error_Kind.Invalid_Argument)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM dst").i, i64(4))
}

@(test)
test_upsert_excluded :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "upsert_excluded")
	if store == nil do return
	defer destroy_host(store, host, "upsert_excluded")
	run_done(t, store, "CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT, hits INTEGER)")
	run_done(t, store, "INSERT INTO u (name, hits) VALUES ('a', 1)")
	// `excluded.col` is the proposed row; `u.col` and a bare `col` are stored.
	run_done(t, store, "INSERT INTO u (id, name, hits) VALUES (1, 'b', 5) ON CONFLICT (id) DO UPDATE SET name = excluded.name, hits = u.hits + excluded.hits")
	row := run_temp(t, store, "SELECT name, hits FROM u").rows[0]
	testing.expect_value(t, row[0].s, "b")
	testing.expect_value(t, row[1].i, i64(6))
	// A bare column still means the stored value.
	run_done(t, store, "INSERT INTO u (id, name, hits) VALUES (1, 'c', 10) ON CONFLICT DO UPDATE SET hits = hits + 1")
	testing.expect_value(t, scalar(t, store, "SELECT hits FROM u").i, i64(7))
	// The proposed row is available to functions and operators.
	run_done(t, store, "INSERT INTO u (id, name, hits) VALUES (1, 'd', 2) ON CONFLICT (id) DO UPDATE SET name = upper(excluded.name) || '!', hits = excluded.hits * 2")
	row = run_temp(t, store, "SELECT name, hits FROM u").rows[0]
	testing.expect_value(t, row[0].s, "D!")
	testing.expect_value(t, row[1].i, i64(4))
}

@(test)
test_text_and_blob_functions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "text_functions")
	if store == nil do return
	defer destroy_host(store, host, "text_functions")
	run_done(t, store, "CREATE TABLE g (k TEXT, v INTEGER)")
	run_done(t, store, "INSERT INTO g (k, v) VALUES ('a', 1), ('a', 2), ('b', NULL), ('b', 3)")
	// group_concat joins the non-null values of each group, in row order.
	grouped := run(t, store, "SELECT k, group_concat(v), group_concat(v, '|') FROM g GROUP BY k ORDER BY k")
	defer db.sql_result_destroy(&grouped)
	testing.expect_value(t, grouped.rows[0][1].s, "1,2")
	testing.expect_value(t, grouped.rows[0][2].s, "1|2")
	testing.expect_value(t, grouped.rows[1][1].s, "3")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(k) FROM g").s, "a,a,b,b")
	// Length counts bytes for text and blobs, characters for length().
	testing.expect_value(t, scalar(t, store, "SELECT octet_length('abc')").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT octet_length(char(233))").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT octet_length(unhex('616263'))").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT length('abc')").i, i64(3))
	// unicode() reports the first code point.
	testing.expect_value(t, scalar(t, store, "SELECT unicode('A')").i, i64(65))
	// Blob constructors and the hex decoder.
	testing.expect_value(t, scalar(t, store, "SELECT length(zeroblob(5))").i, i64(5))
	testing.expect_value(t, scalar(t, store, "SELECT length(randomblob(7))").i, i64(7))
	testing.expect(t, db.value_is_null(scalar(t, store, "SELECT unhex('zz')")))
	testing.expect(t, db.value_is_null(scalar(t, store, "SELECT unhex('abc')")))
	// concat_ws skips nulls and joins with the separator.
	testing.expect_value(t, scalar(t, store, "SELECT concat_ws('-', 'a', NULL, 'b', 3)").s, "a-b-3")
	testing.expect(t, db.value_is_null(scalar(t, store, "SELECT concat_ws(NULL, 'a', 'b')")))
	// random() produces a number.
	testing.expect_value(t, scalar(t, store, "SELECT typeof(random())").s, "integer")
}

// SQLite positions text by character, not by byte, and substr counts a negative
// start from the end and a negative length back from the start.
@(test)
test_text_positions_count_characters :: proc(t: ^testing.T) {
	store := fresh_db(t, "chars")
	if store == nil do return
	defer cleanup_db(store, "chars")

	checks := []struct {
		sql:      string,
		expected: string,
	}{
		{`SELECT substr('abcdef', 1, 3)`, "abc"},
		{`SELECT substr('abcdef', 3)`, "cdef"},
		{`SELECT substr('abcdef', -3)`, "def"},
		{`SELECT substr('abcdef', -3, 2)`, "de"},
		{`SELECT substr('abcdef', 2, -2)`, "a"},
		{`SELECT substr('abcdef', 1, -1)`, ""},
		{`SELECT substr('abcdef', 0, 3)`, "ab"},
		{`SELECT substr('abcdef', 0)`, "abcdef"},
		{`SELECT substr('abcdef', -99, 3)`, ""},
		{`SELECT substr('abcdef', -99)`, "abcdef"},
		{`SELECT substr('abcdef', 99)`, ""},
		{`SELECT substr('abcdef', 3, 0)`, ""},
		{`SELECT substr('abcdef', 2.9)`, "bcdef"},
		{`SELECT substr('héllo', 2, 2)`, "él"},
		{`SELECT substr('日本語', 2)`, "本語"},
		{`SELECT length('héllo')`, "5"},
		{`SELECT length('日本語')`, "3"},
		{`SELECT length('')`, "0"},
	}
	for check in checks {
		value := scalar(t, store, check.sql)
		testing.expect_value(t, db.value_format(value, context.temp_allocator), check.expected)
	}
	// NULL propagates: a text function does not turn it into an error.
	testing.expect(t, db.value_is_null(scalar(t, store, `SELECT substr(NULL, 1)`)))
	testing.expect(t, db.value_is_null(scalar(t, store, `SELECT substr('abc', NULL)`)))
	testing.expect(t, db.value_is_null(scalar(t, store, `SELECT substr('abc', 1, NULL)`)))
	// Characters, not bytes: é is two bytes and 日 is three.
	testing.expect_value(t, scalar(t, store, `SELECT instr('héllo', 'llo')`).i, i64(3))
	testing.expect_value(t, scalar(t, store, `SELECT instr('日本語', '語')`).i, i64(3))
}

// A statement knows how many parameters it binds, a bind past them is refused,
// and the handle registry tells a live pointer from a forgotten one without
// touching what it points at (D29).
@(test)
test_bind_range_and_live_handles :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open failed: %s", open_err.message) do return
	defer db.embed_close(conn)
	// A prepare reads the catalog, so the table exists first (D37).
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE t (a INTEGER, b INTEGER)")))

	stmt := db.embed_prepare(conn, "INSERT INTO t (a, b) VALUES (?, ?)")
	if !testing.expect(t, stmt != nil) do return
	testing.expect_value(t, db.Embed_Parameter_Count(stmt), 2)
	testing.expect(t, db.error_ok(db.embed_bind_int(stmt, 0, 1)))
	testing.expect(t, db.error_ok(db.embed_bind_int(stmt, 1, 2)))
	out_of_range := db.embed_bind_int(stmt, 2, 3)
	defer db.error_free(&out_of_range)
	testing.expect_value(t, out_of_range.kind, db.Error_Kind.Invalid_Argument)
	testing.expect(t, strings.contains(out_of_range.message, "out of range"))
	db.embed_finalize(stmt)

	// Preparation parses, so a syntax error is reported where a caller expects
	// one and no handle comes back.
	broken := db.embed_prepare(conn, "SELECT ((")
	testing.expect(t, broken == nil)
	testing.expect(t, len(db.embed_error(conn)) > 0)

	// The registry answers by value: a forgotten pointer is not dereferenced.
	marker := new(int)
	testing.expect(t, !db.handle_is_live(rawptr(marker)))
	db.handle_register(rawptr(marker))
	testing.expect(t, db.handle_is_live(rawptr(marker)))
	testing.expect(t, db.handle_forget(rawptr(marker)))
	testing.expect(t, !db.handle_is_live(rawptr(marker)))
	testing.expect(t, !db.handle_forget(rawptr(marker)))
	free(marker)
	testing.expect(t, !db.handle_is_live(nil))
}

// SQLite spells an in-memory database in five ways and a program written against
// its API starts with one of them (D28).
@(test)
test_open_in_memory_the_way_sqlite_does :: proc(t: ^testing.T) {
	spellings := []string{":memory:", "", "file::memory:", "file::memory:?cache=shared", "file:memdb1?mode=memory&cache=shared"}
	for spelling in spellings {
		store, err := db.store_open(spelling, {persistent = true, create = true, durable = true})
		if !testing.expectf(t, db.error_ok(err), "%q did not open: %s", spelling, err.message) {
			continue
		}
		testing.expect_value(t, store.persistent, false)
		run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
		run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 'a')")
		testing.expect_value(t, scalar(t, store, "SELECT v FROM t WHERE id = 1").s, "a")
		db.store_close(store)
		// Nothing was written where a directory could have been made.
		if len(spelling) > 0 && !strings.has_prefix(spelling, "file:") {
			testing.expect(t, !os.exists(spelling))
		}
	}
	// A database opened as memory is a fresh one each time.
	first, _ := db.store_open(":memory:", {persistent = true, create = true})
	run_done(t, first, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
	db.store_close(first)
	second, _ := db.store_open(":memory:", {persistent = true, create = true})
	defer db.store_close(second)
	missing := run_error(t, second, "SELECT * FROM t")
	testing.expectf(t, missing.kind != .None, "a fresh :memory: database still has the table")
	// The spellings are recognised without opening anything.
	testing.expect(t, db.store_path_is_memory(":memory:"))
	testing.expect(t, db.store_path_is_memory(""))
	testing.expect(t, db.store_path_is_memory("file:x?mode=memory"))
	testing.expect(t, !db.store_path_is_memory("_test_something"))
	testing.expect(t, !db.store_path_is_memory("file:data.db"))
}

// A text value is bytes, and hex() shows the bytes; a byte that is not part of
// a UTF-8 sequence is escaped when a value is written as JSON, so a document is
// always parseable (D32).
@(test)
test_text_is_bytes_and_json_stays_valid :: proc(t: ^testing.T) {
	store := fresh_db(t, "bytes")
	if store == nil do return
	defer cleanup_db(store, "bytes")

	// hex answers the UTF-8 bytes, not the code point: é is C3 A9.
	testing.expect_value(t, db.value_format(scalar(t, store, `SELECT hex(char(233))`), context.temp_allocator), "C3A9")
	testing.expect_value(t, db.value_format(scalar(t, store, `SELECT hex('abc')`), context.temp_allocator), "616263")
	testing.expect_value(t, db.value_format(scalar(t, store, `SELECT hex(unhex('00ff'))`), context.temp_allocator), "00FF")
	testing.expect_value(t, scalar(t, store, `SELECT octet_length(char(233))`).i, i64(2))
	testing.expect_value(t, scalar(t, store, `SELECT length(char(233))`).i, i64(1))

	// Valid text is written as it came.
	valid := scalar(t, store, `SELECT json_object('a', char(233))`)
	testing.expect_value(t, db.value_format(valid, context.temp_allocator), `{"a":"é"}`)

	// A byte that is not part of a UTF-8 sequence is escaped as its Latin-1
	// reading, so the output is a JSON document a parser accepts.
	raw_bytes := []u8{'a', 0xE9, 'b'}
	raw := string(raw_bytes)
	written := db.json_write(db.json_from_value(db.value_string(raw), context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, written, `"a\u00e9b"`)
}

// WHERE asks a value for its truth, and SQLite converts a text to a number
// first: 'a' is zero and false, '1a' is one and true. Fifty-three statements
// through both engines found this one reporting a row SQLite drops.
@(test)
test_text_truth_is_numeric :: proc(t: ^testing.T) {
	store := fresh_db(t, "truth")
	if store == nil do return
	defer cleanup_db(store, "truth")

	cases := []struct {
		literal: string,
		truthy:  bool,
	}{
		{"'a'", false},
		{"'1'", true},
		{"'1a'", true},
		{"'a1'", false},
		{"''", false},
		{"'0'", false},
		{"'05'", true},
		{"' 12 '", true},
		{"'0x10'", false},
		{"'-3'", true},
		{"'  '", false},
		{"x'00'", false},
		{"x'31'", true},
		{"'3e2'", true},
		{"'.5'", true},
		{"'-'", false},
		{"'1_000'", true},
	}
	for c in cases {
		result := run(t, store, fmt.tprintf("SELECT 1 WHERE %s", c.literal))
		defer db.sql_result_destroy(&result)
		testing.expect_value(t, len(result.rows), c.truthy ? 1 : 0)
	}
	// CASE WHEN asks the same question, and so does a stored column.
	testing.expect_value(t, scalar(t, store, `SELECT CASE WHEN 'a' THEN 1 ELSE 0 END`).i, i64(0))
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT)")
	run_done(t, store, "INSERT INTO t (id, s) VALUES (1, '1'), (2, 'a'), (3, '0')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE s").i, i64(1))
	// A number and a text are different storage classes: they are not equal,
	// as in SQLite, unless a column's affinity converts one of them first.
	testing.expect_value(t, len(run_temp(t, store, `SELECT 1 WHERE 1 = '1'`).rows), 0)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE id = '2'").i, i64(1))
}

// A JSON number is written back with the type it had: 1.0 is not 1, and reading
// the value back gives a real. The number alone cannot tell the two apart, so
// Json_Value carries the bit set by the parser or by json_from_value.
@(test)
test_json_keeps_real_type :: proc(t: ^testing.T) {
	store := fresh_db(t, "jsonreal")
	if store == nil do return
	defer cleanup_db(store, "jsonreal")

	checks := []struct {
		sql:      string,
		expected: string,
	}{
		{`SELECT json_object('a', 1, 'b', 1.0)`, `{"a":1,"b":1.0}`},
		{`SELECT json_array(1.0, 2, 1.5)`, `[1.0,2,1.5]`},
		{`SELECT json('{"a":1,"b":1.0}')`, `{"a":1,"b":1.0}`},
	}
	for check in checks {
		testing.expect_value(t, db.value_format(scalar(t, store, check.sql), context.temp_allocator), check.expected)
	}
	testing.expect_value(t, scalar(t, store, `SELECT json_type('1.0')`).s, "real")
	testing.expect_value(t, scalar(t, store, `SELECT json_type('1')`).s, "integer")
	testing.expect_value(t, scalar(t, store, `SELECT typeof(json_extract('{"a":1.0}', '$.a'))`).s, "real")
	testing.expect_value(t, scalar(t, store, `SELECT typeof(json_extract('{"a":1}', '$.a'))`).s, "integer")
}

// INSERT OR REPLACE deletes every row the new one collides with, on any unique
// index, and counts one affected row.
@(test)
test_insert_or_replace :: proc(t: ^testing.T) {
	store := fresh_db(t, "replace")
	if store == nil do return
	defer cleanup_db(store, "replace")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, u TEXT UNIQUE, v TEXT)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'a', 'x'), (2, 'b', 'y')")

	// A collision on the primary key replaces that row.
	result := run(t, store, "INSERT OR REPLACE INTO t VALUES (1, 'c', 'z')")
	testing.expect_value(t, result.affected, 1)
	db.sql_result_destroy(&result)
	testing.expect_value(t, scalar(t, store, "SELECT v FROM t WHERE id = 1").s, "z")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))
	// changes() reports the inserted row, not the deleted one.
	testing.expect_value(t, scalar(t, store, "SELECT changes()").i, i64(1))

	// A collision on a unique index deletes the row that held the value.
	run_done(t, store, "INSERT OR REPLACE INTO t VALUES (3, 'b', 'w')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT id FROM t WHERE u = 'b'").i, i64(3))

	// A row can collide under two indexes at once: both rows go, one arrives.
	run_done(t, store, "CREATE TABLE two (id INTEGER PRIMARY KEY, u TEXT UNIQUE, v TEXT)")
	run_done(t, store, "INSERT INTO two VALUES (1, 'a', 'x'), (2, 'b', 'y')")
	run_done(t, store, "INSERT OR REPLACE INTO two VALUES (1, 'b', 'z')")
	rows := run(t, store, "SELECT id, u, v FROM two")
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect_value(t, rows.rows[0][0].i, i64(1))
	testing.expect_value(t, rows.rows[0][1].s, "b")
	testing.expect_value(t, rows.rows[0][2].s, "z")
	db.sql_result_destroy(&rows)

	// No conflict inserts like a plain INSERT, and RETURNING reports the row.
	returned := run(t, store, "INSERT OR REPLACE INTO t VALUES (4, 'd', 'q') RETURNING v")
	testing.expect_value(t, len(returned.rows), 1)
	testing.expect_value(t, returned.rows[0][0].s, "q")
	db.sql_result_destroy(&returned)

	// A delete trigger does not fire for the rows REPLACE removes, which is
	// SQLite's behaviour with recursive triggers off.
	run_done(t, store, "CREATE TABLE audited (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "CREATE TABLE audit (note TEXT)")
	run_done(t, store, `
		CREATE TRIGGER audited_del BEFORE DELETE ON audited
		BEGIN INSERT INTO audit (note) VALUES ('deleted'); END`)
	run_done(t, store, "INSERT INTO audited VALUES (1, 'old')")
	run_done(t, store, "INSERT OR REPLACE INTO audited VALUES (1, 'new')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT v FROM audited WHERE id = 1").s, "new")

	// The other resolutions are in test_insert_conflict_resolutions; an unknown
	// one is still a syntax error rather than "expected into".
	testing.expect_value(t, run_error(t, store, "INSERT OR SKIP INTO t VALUES (9, 'q', 'r')").kind, db.Error_Kind.Sql_Syntax)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
}

// format()/printf() follow SQLite's printf: flags, width and precision apply,
// and a conversion the engine does not know is written back unchanged instead
// of being dropped. The differential corpus found this (D30).
@(test)
test_format_flags_and_precision :: proc(t: ^testing.T) {
	store := fresh_db(t, "format")
	if store == nil do return
	defer cleanup_db(store, "format")

	checks := []struct {
		sql:      string,
		expected: string,
	}{
		{`SELECT printf('%05.2f', 3.14159)`, "03.14"},
		{`SELECT printf('%5.1f', 2.5)`, "  2.5"},
		{`SELECT printf('%-6s|', 'ab')`, "ab    |"},
		{`SELECT printf('%+.3d', 7)`, "+007"},
		{`SELECT printf('%.3d', -7)`, "-007"},
		{`SELECT printf('%08x', 255)`, "000000ff"},
		{`SELECT printf('%08.3f', 3.14159)`, "0003.142"},
		{`SELECT printf('%.3s', 'abcdef')`, "abc"},
		{`SELECT printf('%q', 'it''s')`, "it''s"},
		{`SELECT printf('%u', -1)`, "18446744073709551615"},
		{`SELECT printf('%d-%s', 1, 'a')`, "1-a"},
		{`SELECT printf('100%%')`, "100%"},
		{`SELECT printf('%s', NULL)`, ""},
		{`SELECT printf('%e', 1234.5)`, "1.234500e+03"},
		{`SELECT printf('%g', 1000000.0)`, "1e+06"},
		{`SELECT printf('%c', 'Hello')`, "H"},
		{`SELECT printf('%10.4f|', 3.14159265)`, "    3.1416|"},
		// SQL's %z is %s, as in SQLite (the C form frees its argument).
		{`SELECT printf('%z', 1)`, "1"},
		// SQLite's own printf, shared with sqlite3_mprintf: `*` reads the width
		// or precision from the arguments, %Q quotes, %w doubles `"`, and an
		// unknown conversion ends the text.
		{`SELECT printf('%.*c', 3, 'xy')`, "xxx"},
		{`SELECT printf('%*d|', 5, 42)`, "   42|"},
		{`SELECT printf('%Q %Q %w', 'it''s', NULL, 'a"b')`, "'it''s' NULL a\"\"b"},
		{`SELECT printf('%,d %r %!.3s', 1234567, 22, 'ñandú')`, "1,234,567 22nd ñan"},
		{`SELECT printf('%d%hhd', 5, 6)`, "5"},
		{`SELECT printf('%s', x'414243')`, "ABC"},
		{`SELECT format('%d/%d', 3, 4)`, "3/4"},
	}
	for check in checks {
		value := scalar(t, store, check.sql)
		testing.expect_value(t, db.value_format(value, context.temp_allocator), check.expected)
	}
}

@(test)
test_changes_and_last_insert_rowid :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "changes_rowid")
	if store == nil do return
	defer destroy_host(store, host, "changes_rowid")
	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, n TEXT)")
	run_done(t, store, "INSERT INTO c (n) VALUES ('a'), ('b'), ('c')")
	testing.expect_value(t, scalar(t, store, "SELECT changes()").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT last_insert_rowid()").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT total_changes()").i, i64(3))
	// An update reports its own count and leaves the last row id alone.
	run_done(t, store, "UPDATE c SET n = 'z' WHERE id <= 2")
	testing.expect_value(t, scalar(t, store, "SELECT changes()").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT last_insert_rowid()").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT total_changes()").i, i64(5))
	// A select does not reset the count.
	testing.expect_value(t, scalar(t, store, "SELECT changes()").i, i64(2))
	run_done(t, store, "DELETE FROM c")
	testing.expect_value(t, scalar(t, store, "SELECT changes()").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT total_changes()").i, i64(8))
}

@(test)
test_savepoints :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "savepoints")
	if store == nil do return
	defer destroy_host(store, host, "savepoints")
	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY, n TEXT)")

	count_in :: proc(t: ^testing.T, tx: ^db.Tx, sql: string) -> i64 {
		result, err := db.sql_execute_in_tx(tx, sql)
		defer db.sql_result_destroy(&result)
		testing.expectf(t, db.error_ok(err), "%s failed: %s", sql, err.message)
		if len(result.rows) == 0 || len(result.rows[0]) == 0 do return -1
		return result.rows[0][0].i
	}

	tx := db.tx_begin_write(store)
	dropped_result_9236, insert_err := db.sql_execute_in_tx(tx, "INSERT INTO s (n) VALUES ('one')")
	defer db.error_free(&insert_err)
	defer db.sql_result_destroy(&dropped_result_9236)
	testing.expect(t, db.error_ok(insert_err))
	testing.expect(t, db.error_ok(db.tx_savepoint(tx, "a")))
	dropped_result_9239, second := db.sql_execute_in_tx(tx, "INSERT INTO s (n) VALUES ('two')")
	defer db.error_free(&second)
	defer db.sql_result_destroy(&dropped_result_9239)
	testing.expect(t, db.error_ok(second))
	testing.expect_value(t, count_in(t, tx, "SELECT count(*) FROM s"), i64(2))

	// Rollback to a keeps the savepoint and undoes what came after.
	testing.expect(t, db.error_ok(db.tx_rollback_to_savepoint(tx, "a")))
	testing.expect_value(t, count_in(t, tx, "SELECT count(*) FROM s"), i64(1))

	// A table created after the savepoint disappears with it.
	dropped_result_9248, created := db.sql_execute_in_tx(tx, "CREATE TABLE later (x INTEGER)")
	defer db.error_free(&created)
	defer db.sql_result_destroy(&dropped_result_9248)
	testing.expect(t, db.error_ok(created))
	testing.expect(t, db.error_ok(db.tx_rollback_to_savepoint(tx, "a")))
	dropped_result_9139, missing := db.sql_execute_in_tx(tx, "SELECT count(*) FROM later")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_9139)
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)

	// Nested savepoints: releasing the outer one drops the inner one too.
	dropped_result_9257, third := db.sql_execute_in_tx(tx, "INSERT INTO s (n) VALUES ('three')")
	defer db.error_free(&third)
	defer db.sql_result_destroy(&dropped_result_9257)
	testing.expect(t, db.error_ok(third))
	testing.expect(t, db.error_ok(db.tx_savepoint(tx, "b")))
	dropped_result_9260, fourth := db.sql_execute_in_tx(tx, "INSERT INTO s (n) VALUES ('four')")
	defer db.error_free(&fourth)
	defer db.sql_result_destroy(&dropped_result_9260)
	testing.expect(t, db.error_ok(fourth))
	testing.expect(t, db.error_ok(db.tx_release_savepoint(tx, "a")))
	released := db.tx_release_savepoint(tx, "b")
	testing.expect_value(t, released.kind, db.Error_Kind.Invalid_Argument)
	db.error_free(&released)
	testing.expect_value(t, count_in(t, tx, "SELECT count(*) FROM s"), i64(3))

	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM s").i, i64(3))
}

@(test)
test_common_table_expressions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "ctes")
	if store == nil do return
	defer destroy_host(store, host, "ctes")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT, v INTEGER)")
	run_done(t, store, "INSERT INTO t (n, v) VALUES ('a', 1), ('b', 2), ('c', 3)")

	big := run(t, store, "WITH big AS (SELECT * FROM t WHERE v > 1) SELECT n FROM big ORDER BY n")
	defer db.sql_result_destroy(&big)
	testing.expect_value(t, len(big.rows), 2)
	testing.expect_value(t, big.rows[0][0].s, "b")
	testing.expect_value(t, big.rows[1][0].s, "c")

	// A later CTE can read an earlier one.
	testing.expect_value(t, scalar(t, store, "WITH one AS (SELECT 10 AS x), two AS (SELECT x * 2 AS y FROM one) SELECT y FROM two").i, i64(20))
	// An explicit column list renames the projections.
	testing.expect_value(t, scalar(t, store, "WITH c(n) AS (SELECT 42) SELECT n FROM c").i, i64(42))
	// The materialized table can be read more than once in one statement.
	testing.expect_value(t, scalar(t, store, "WITH big AS (SELECT * FROM t WHERE v > 1) SELECT count(*) FROM big a JOIN big b ON a.id = b.id").i, i64(2))

	// The CTE is scoped to the statement.
	dropped_result_9180, missing := db.sql_execute(store, "SELECT * FROM big")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_9180)
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)
	// The recursive keyword is accepted; a base term without a step yields one row.
	testing.expect_value(t, scalar(t, store, "WITH RECURSIVE r(x) AS (SELECT 1) SELECT count(*) FROM r").i, i64(1))
	// The store still holds only the real table.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
}

@(test)
test_union_queries :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "union")
	if store == nil do return
	defer destroy_host(store, host, "union")
	run_done(t, store, "CREATE TABLE a (x INTEGER)")
	run_done(t, store, "INSERT INTO a (x) VALUES (1), (2), (3)")

	// UNION drops duplicates; UNION ALL keeps them.
	deduped := run(t, store, "SELECT x FROM a WHERE x <= 2 UNION SELECT x FROM a WHERE x >= 2")
	defer db.sql_result_destroy(&deduped)
	testing.expect_value(t, len(deduped.rows), 3)
	all_rows := run(t, store, "SELECT x FROM a WHERE x <= 2 UNION ALL SELECT x FROM a WHERE x >= 2")
	defer db.sql_result_destroy(&all_rows)
	testing.expect_value(t, len(all_rows.rows), 4)
	// Chains and tail clauses apply to the merged result.
	chained := run(t, store, "SELECT 1 AS v UNION SELECT 2 UNION SELECT 3 ORDER BY v DESC")
	defer db.sql_result_destroy(&chained)
	testing.expect_value(t, len(chained.rows), 3)
	testing.expect_value(t, chained.rows[0][0].i, i64(3))
	limited := run(t, store, "SELECT x FROM a UNION SELECT x * 10 FROM a ORDER BY x DESC LIMIT 2")
	defer db.sql_result_destroy(&limited)
	testing.expect_value(t, len(limited.rows), 2)
	testing.expect_value(t, limited.rows[0][0].i, i64(30))
	// Arity must match.
	dropped_result_9140, mismatch := db.sql_execute(store, "SELECT 1 UNION SELECT 2, 3")
	defer db.error_free(&mismatch)
	defer db.sql_result_destroy(&dropped_result_9140)
	testing.expect_value(t, mismatch.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_recursive_cte :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "recursive_cte")
	if store == nil do return
	defer destroy_host(store, host, "recursive_cte")
	counting := run(t, store, "WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < 10) SELECT count(*), max(x) FROM cnt")
	defer db.sql_result_destroy(&counting)
	testing.expect_value(t, counting.rows[0][0].i, i64(10))
	testing.expect_value(t, counting.rows[0][1].i, i64(10))
	// The step reads the accumulated rows: 5! = 120.
	factorial := run(t, store, "WITH RECURSIVE f(n, value) AS (SELECT 1, 1 UNION ALL SELECT n + 1, value * (n + 1) FROM f WHERE n < 5) SELECT value FROM f ORDER BY n DESC LIMIT 1")
	defer db.sql_result_destroy(&factorial)
	testing.expect_value(t, factorial.rows[0][0].i, i64(120))
	// A query that never stops fails at the step quota instead of running away.
	previous := db.recursion_limit
	db.recursion_limit = 25
	dropped_result_9160, runaway := db.sql_execute(store, "WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r) SELECT count(*) FROM r")
	defer db.error_free(&runaway)
	defer db.sql_result_destroy(&dropped_result_9160)
	db.recursion_limit = previous
	testing.expect_value(t, runaway.kind, db.Error_Kind.Cancelled)
}

@(test)
test_collate_expressions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "collate")
	if store == nil do return
	defer destroy_host(store, host, "collate")
	run_done(t, store, "CREATE TABLE p (name TEXT)")
	run_done(t, store, "INSERT INTO p (name) VALUES ('Alice'), ('alice'), ('ALICE'), ('Bob'), ('pad '), ('pad')")

	// BINARY is the default: it compares bytes, so case matters.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM p WHERE name = 'alice'").i, i64(1))
	// NOCASE folds case on either side of the comparison.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM p WHERE name = 'alice' COLLATE NOCASE").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM p WHERE name COLLATE NOCASE = 'alice'").i, i64(3))
	// RTRIM ignores trailing spaces.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM p WHERE name = 'pad' COLLATE RTRIM").i, i64(2))
	// Ordering follows the collation too.
	testing.expect(t, scalar(t, store, "SELECT 'b' COLLATE NOCASE > 'A'").b)
	testing.expect(t, scalar(t, store, "SELECT 'b' COLLATE BINARY > 'A'").b)
	// The collation only affects comparisons: the value passes through.
	testing.expect_value(t, scalar(t, store, "SELECT name COLLATE NOCASE FROM p WHERE name = 'Alice'").s, "Alice")
	// LIKE keeps its own case rule; COLLATE does not alter it.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM p WHERE name LIKE 'ali%'").i, i64(3))
	// ORDER BY sorts on the folded key.
	ordered := run(t, store, "SELECT name FROM p WHERE name <> 'pad' AND name <> 'pad ' ORDER BY name COLLATE NOCASE")
	defer db.sql_result_destroy(&ordered)
	testing.expect_value(t, len(ordered.rows), 4)
	testing.expect_value(t, ordered.rows[3][0].s, "Bob")
	descending := run(t, store, "SELECT name FROM p WHERE name <> 'pad' AND name <> 'pad ' ORDER BY name COLLATE NOCASE DESC")
	defer db.sql_result_destroy(&descending)
	testing.expect_value(t, descending.rows[0][0].s, "Bob")
}

@(test)
test_alter_table_rename :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "rename_table")
	if store == nil do return
	run_done(t, store, "CREATE TABLE old (id INTEGER PRIMARY KEY, n TEXT)")
	run_done(t, store, "INSERT INTO old (n) VALUES ('a'), ('b')")
	run_done(t, store, "ALTER TABLE old RENAME TO fresh")

	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM fresh").i, i64(2))
	dropped_result_9283, missing := db.sql_execute(store, "SELECT * FROM old")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_9283)
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)
	// A second rename continues from the new name.
	run_done(t, store, "ALTER TABLE fresh RENAME TO again")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM again").i, i64(2))
	// A name in use is rejected.
	run_done(t, store, "CREATE TABLE other (x INTEGER)")
	dropped_result_9290, clash := db.sql_execute(store, "ALTER TABLE again RENAME TO other")
	defer db.error_free(&clash)
	defer db.sql_result_destroy(&dropped_result_9290)
	testing.expect_value(t, clash.kind, db.Error_Kind.Table_Exists)
	// The renamed table keeps inserting and numbering rows.
	run_done(t, store, "INSERT INTO again (n) VALUES ('c')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM again").i, i64(3))

	// The rename survives a reopen through the log.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open("_test_rename_table", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen failed: %s", open_err.message) do return
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM again").i, i64(3))
	dropped_result_9302, gone := db.sql_execute(reopened, "SELECT * FROM fresh")
	defer db.error_free(&gone)
	defer db.sql_result_destroy(&dropped_result_9302)
	testing.expect_value(t, gone.kind, db.Error_Kind.Table_Not_Found)
	cleanup_db(reopened, "rename_table")
}

@(test)
test_update_from_delete_using :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "update_from")
	if store == nil do return
	defer destroy_host(store, host, "update_from")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, price INTEGER, tag TEXT)")
	run_done(t, store, "CREATE TABLE src (id INTEGER, factor INTEGER, note TEXT)")
	run_done(t, store, "INSERT INTO t (price, tag) VALUES (10, 'a'), (20, 'b'), (30, 'c')")
	run_done(t, store, "INSERT INTO src (id, factor, note) VALUES (1, 2, 'x'), (3, 4, 'y')")

	// The joined row feeds both the WHERE and the assignments.
	updated := run(t, store, "UPDATE t SET price = price * src.factor, tag = src.note FROM src WHERE t.id = src.id")
	defer db.sql_result_destroy(&updated)
	testing.expect_value(t, updated.affected, 2)
	rows := run_temp(t, store, "SELECT id, price, tag FROM t ORDER BY id").rows
	testing.expect_value(t, rows[0][1].i, i64(20))
	testing.expect_value(t, rows[0][2].s, "x")
	testing.expect_value(t, rows[1][1].i, i64(20))
	testing.expect_value(t, rows[1][2].s, "b")
	testing.expect_value(t, rows[2][1].i, i64(120))
	testing.expect_value(t, rows[2][2].s, "y")

	// DELETE ... USING removes only the targets the join matches.
	deleted := run(t, store, "DELETE FROM t USING src WHERE t.id = src.id AND src.factor > 3")
	defer db.sql_result_destroy(&deleted)
	testing.expect_value(t, deleted.affected, 1)
	remaining := run(t, store, "SELECT id FROM t ORDER BY id")
	defer db.sql_result_destroy(&remaining)
	testing.expect_value(t, len(remaining.rows), 2)
	testing.expect_value(t, remaining.rows[1][0].i, i64(2))
	// Without FROM the plain form still works.
	testing.expect_value(t, run_temp(t, store, "UPDATE t SET price = price + 1").affected, 2)
}

@(test)
test_date_time_functions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "datetime")
	if store == nil do return
	defer destroy_host(store, host, "datetime")

	testing.expect_value(t, scalar(t, store, "SELECT date('2024-03-05')").s, "2024-03-05")
	testing.expect_value(t, scalar(t, store, "SELECT time('2024-03-05 14:23:07')").s, "14:23:07")
	testing.expect_value(t, scalar(t, store, "SELECT datetime('2024-03-05 14:23:07')").s, "2024-03-05 14:23:07")
	testing.expect_value(t, scalar(t, store, "SELECT time('14:23:07')").s, "14:23:07")
	testing.expect_value(t, scalar(t, store, "SELECT unixepoch('2024-03-05')").i, i64(1709596800))
	testing.expect_value(t, scalar(t, store, "SELECT date(1709596800, 'unixepoch')").s, "2024-03-05")
	testing.expect_value(t, scalar(t, store, "SELECT date(0, 'unixepoch')").s, "1970-01-01")
	// Julian days put noon at the half.
	testing.expect_value(t, scalar(t, store, "SELECT julianday('2000-01-01 12:00:00')").f, 2451545.0)
	// Modifiers.
	testing.expect_value(t, scalar(t, store, "SELECT date('2024-01-31', '+1 month')").s, "2024-02-29")
	testing.expect_value(t, scalar(t, store, "SELECT date('2024-03-05', '-1 day')").s, "2024-03-04")
	testing.expect_value(t, scalar(t, store, "SELECT datetime('2024-03-05 14:23:07', '-2 hours')").s, "2024-03-05 12:23:07")
	testing.expect_value(t, scalar(t, store, "SELECT date('2024-03-05', 'start of month')").s, "2024-03-01")
	testing.expect_value(t, scalar(t, store, "SELECT date('2024-03-05', 'start of year')").s, "2024-01-01")
	testing.expect_value(t, scalar(t, store, "SELECT date('2024-02-29', '+1 year')").s, "2025-03-01")
	// strftime codes.
	testing.expect_value(t, scalar(t, store, "SELECT strftime('%Y/%m/%d', '2024-03-05')").s, "2024/03/05")
	testing.expect_value(t, scalar(t, store, "SELECT strftime('%F %T', '2024-03-05 14:23:07')").s, "2024-03-05 14:23:07")
	testing.expect_value(t, scalar(t, store, "SELECT strftime('%j', '2024-03-05')").s, "065")
	testing.expect_value(t, scalar(t, store, "SELECT strftime('%s', '2024-03-05')").s, "1709596800")
	// 'now' works and returns a usable date.
	testing.expect_value(t, scalar(t, store, "SELECT length(date('now'))").i, i64(10))
	// Unparsable and null inputs give NULL.
	testing.expect(t, db.value_is_null(scalar(t, store, "SELECT date('not a date')")))
	testing.expect(t, db.value_is_null(scalar(t, store, "SELECT date(NULL)")))
	// The functions read columns too.
	run_done(t, store, "CREATE TABLE events (at TEXT)")
	run_done(t, store, "INSERT INTO events (at) VALUES ('2024-03-05 14:23:07'), ('2023-12-31')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM events WHERE date(at) = '2023-12-31'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT max(strftime('%Y', at)) FROM events").s, "2024")
}

@(test)
test_math_functions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "math")
	if store == nil do return
	defer destroy_host(store, host, "math")
	testing.expect_value(t, scalar(t, store, "SELECT log(100)").f, 2.0)
	testing.expect(t, math_abs(scalar(t, store, "SELECT log10(1000)").f - 3.0) < 1e-9)
	testing.expect_value(t, scalar(t, store, "SELECT log2(8)").f, 3.0)
	testing.expect_value(t, scalar(t, store, "SELECT exp(0)").f, 1.0)
	testing.expect_value(t, scalar(t, store, "SELECT sin(0)").f, 0.0)
	testing.expect_value(t, scalar(t, store, "SELECT cos(0)").f, 1.0)
	testing.expect(t, math_abs(scalar(t, store, "SELECT atan2(0, 1)").f) < 0.000001)
	testing.expect(t, math_abs(scalar(t, store, "SELECT radians(180)").f - 3.141592653589793) < 1e-9)
	testing.expect_value(t, scalar(t, store, "SELECT degrees(pi())").f, 180.0)
	testing.expect_value(t, scalar(t, store, "SELECT round(3.14159, 2)").f, 3.14)
	testing.expect_value(t, scalar(t, store, "SELECT round(2.5)").f, 3.0)
	testing.expect_value(t, scalar(t, store, "SELECT floor(1.9)").f, 1.0)
	testing.expect_value(t, scalar(t, store, "SELECT ceil(1.1)").f, 2.0)
	testing.expect_value(t, scalar(t, store, "SELECT trunc(-3.7)").f, -3.0)
	testing.expect_value(t, scalar(t, store, "SELECT sqrt(16)").f, 4.0)
	testing.expect_value(t, scalar(t, store, "SELECT pow(2, 10)").f, 1024.0)
	testing.expect_value(t, scalar(t, store, "SELECT mod(7, 3)").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT sign(-2)").i, i64(-1))
	// The domain edge gives NULL rather than an error.
	testing.expect(t, db.value_is_null(scalar(t, store, "SELECT log(0)")))
}

@(private)
math_abs :: proc(x: f64) -> f64 {
	return x < 0 ? -x : x
}

@(test)
test_sqlite_import_wal_and_journal :: proc(t: ^testing.T) {
	// A write-ahead log carries the committed pages that are not in the file.
	wal_store, wal_host := fresh_host(t, "wal_import")
	if wal_store == nil do return
	wal_file, wal_err := db.sqlite_file_open("src/tests/fixtures/wal.sqlite")
	if !testing.expectf(t, db.error_ok(wal_err), "open wal fixture: %s", wal_err.message) do return
	tables, rows, import_err := db.sqlite_import(&wal_file, wal_store)
	db.sqlite_file_destroy(&wal_file)
	testing.expect(t, db.error_ok(import_err))
	testing.expect_value(t, tables, 1)
	testing.expect_value(t, rows, 2)
	testing.expect_value(t, scalar(t, wal_store, "SELECT count(*) FROM t").i, i64(2))
	testing.expect_value(t, scalar(t, wal_store, "SELECT name FROM t WHERE id = 2").s, "two")
	destroy_host(wal_store, wal_host, "wal_import")

	// A hot rollback journal restores the pages of the interrupted transaction,
	// so the schema it protects is the one that comes back.
	journal_store, journal_host := fresh_host(t, "journal_import")
	if journal_store == nil do return
	journal_file, journal_err := db.sqlite_file_open("src/tests/fixtures/journal.sqlite")
	if !testing.expectf(t, db.error_ok(journal_err), "open journal fixture: %s", journal_err.message) do return
	_, _, journal_import_err := db.sqlite_import(&journal_file, journal_store)
	db.sqlite_file_destroy(&journal_file)
	testing.expect(t, db.error_ok(journal_import_err))
	testing.expect_value(t, scalar(t, journal_store, "SELECT x FROM old").i, i64(7))
	dropped_result_9438, missing := db.sql_execute(journal_store, "SELECT y FROM fresh")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_9438)
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)
	destroy_host(journal_store, journal_host, "journal_import")
}

@(test)
test_json_functions :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "json")
	if store == nil do return
	defer destroy_host(store, host, "json")

	testing.expect_value(t, scalar(t, store, `SELECT json_valid('{"a":1}')`).i, i64(1))
	testing.expect_value(t, scalar(t, store, `SELECT json_valid('{bad')`).i, i64(0))
	testing.expect_value(t, scalar(t, store, `SELECT json_type('{"a":[1,2]}')`).s, "object")
	testing.expect_value(t, scalar(t, store, `SELECT json_type('[1,2]', '$[1]')`).s, "integer")
	testing.expect_value(t, scalar(t, store, `SELECT json_type('1.5')`).s, "real")
	testing.expect_value(t, scalar(t, store, `SELECT json_type('null')`).s, "null")
	// A number keeps the text it was written with, as in SQLite.
	testing.expect_value(t, scalar(t, store, `SELECT json('[1.50, 1e2, -0, 12345678901234567890]')`).s, "[1.50,1e2,-0,12345678901234567890]")
	// Paths walk objects and arrays; `[#]` is one past the last element, so it
	// finds nothing, and `[#-1]` is the last, as in SQLite.
	testing.expect_value(t, scalar(t, store, `SELECT json_extract('{"a":{"b":[10,20,30]}}', '$.a.b[1]')`).i, i64(20))
	testing.expect(t, db.value_is_null(scalar(t, store, `SELECT json_extract('[10,20,30]', '$[#]')`)))
	testing.expect_value(t, scalar(t, store, `SELECT json_extract('[10,20,30]', '$[#-1]')`).i, i64(30))
	testing.expect(t, db.value_is_null(scalar(t, store, `SELECT json_extract('{"a":1}', '$.missing')`)))
	// Several paths produce a JSON array.
	testing.expect_value(t, scalar(t, store, `SELECT json_extract('{"a":1,"b":2}', '$.a', '$.b')`).s, "[1,2]")
	// Builders and quoting.
	testing.expect_value(t, scalar(t, store, `SELECT json_array(1, 'two', NULL, 3.5)`).s, `[1,"two",null,3.5]`)
	testing.expect_value(t, scalar(t, store, `SELECT json_object('k', 1, 'j', 'x')`).s, `{"k":1,"j":"x"}`)
	testing.expect_value(t, scalar(t, store, `SELECT json_quote('he said "hi"')`).s, `"he said \"hi\""`)
	testing.expect_value(t, scalar(t, store, `SELECT json_array_length('[1,2,3]')`).i, i64(3))
	testing.expect_value(t, scalar(t, store, `SELECT json_array_length('{"a":[1,2]}', '$.a')`).i, i64(2))
	// json() minifies; malformed input is an error.
	testing.expect_value(t, scalar(t, store, `SELECT json(' { "a" : [ 1 , 2 ] } ')`).s, `{"a":[1,2]}`)
	dropped_result_9473, malformed := db.sql_execute(store, `SELECT json('{bad')`)
	defer db.error_free(&malformed)
	defer db.sql_result_destroy(&dropped_result_9473)
	testing.expect_value(t, malformed.kind, db.Error_Kind.Invalid_Argument)
	// The functions read columns.
	run_done(t, store, "CREATE TABLE docs (body TEXT)")
	run_done(t, store, `INSERT INTO docs (body) VALUES ('{"n":1}'), ('{"n":2}')`)
	testing.expect_value(t, scalar(t, store, `SELECT sum(json_extract(body, '$.n')) FROM docs`).i, i64(3))
	// Mutators: set, replace (only existing paths) and remove.
	testing.expect_value(t, scalar(t, store, `SELECT json_set('{"a":1}', '$.a', 2, '$.b', 'x')`).s, `{"a":2,"b":"x"}`)
	testing.expect_value(t, scalar(t, store, `SELECT json_set('[10,20]', '$[2]', 30)`).s, "[10,20,30]")
	testing.expect_value(t, scalar(t, store, `SELECT json_set('[10,20]', '$[0]', 5)`).s, "[5,20]")
	testing.expect_value(t, scalar(t, store, `SELECT json_replace('{"a":1}', '$.a', 9)`).s, `{"a":9}`)
	testing.expect_value(t, scalar(t, store, `SELECT json_replace('{"a":1}', '$.zz', 9)`).s, `{"a":1}`)
	testing.expect_value(t, scalar(t, store, `SELECT json_remove('{"a":1,"b":2}', '$.a')`).s, `{"b":2}`)
	testing.expect_value(t, scalar(t, store, `SELECT json_remove('[10,20,30]', '$[1]')`).s, "[10,30]")
	testing.expect_value(t, scalar(t, store, `SELECT json_remove('{"a":[1,2],"b":3}', '$.a')`).s, `{"b":3}`)
	dropped_result_9488, bad_set := db.sql_execute(store, `SELECT json_set('{"a":1}', '$.a')`)
	defer db.error_free(&bad_set)
	defer db.sql_result_destroy(&dropped_result_9488)
	testing.expect_value(t, bad_set.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_strict_table_option :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "strict_tables")
	if store == nil do return
	defer destroy_host(store, host, "strict_tables")
	// STRICT is accepted; the declared types are already enforced.
	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY, n TEXT NOT NULL) STRICT")
	run_done(t, store, "INSERT INTO s (n) VALUES ('x')")
	testing.expect_value(t, scalar(t, store, "SELECT n FROM s").s, "x")
	dropped_result_9501, not_null := db.sql_execute(store, "INSERT INTO s (n) VALUES (NULL)")
	defer db.error_free(&not_null)
	defer db.sql_result_destroy(&dropped_result_9501)
	testing.expect_value(t, not_null.kind, db.Error_Kind.Not_Null_Violation)
	// A STRICT table refuses a value its column cannot convert, in SQLite's words.
	run_done(t, store, "CREATE TABLE si (i INTEGER) STRICT")
	refused := run_error(t, store, "INSERT INTO si VALUES ('abc')")
	testing.expect_value(t, refused.kind, db.Error_Kind.Check_Violation)
	testing.expect(t, strings.contains(refused.message, "cannot store TEXT value in INTEGER column si.i"))
	dropped_result_9508, unknown := db.sql_execute(store, "CREATE TABLE sv (x VARCHAR) STRICT")
	defer db.error_free(&unknown)
	defer db.sql_result_destroy(&dropped_result_9508)
	testing.expect(t, !db.error_ok(unknown))
	// WITHOUT ROWID: the primary key is the identity, and rowid names nothing.
	run_done(t, store, "CREATE TABLE w (id INTEGER PRIMARY KEY, v TEXT) WITHOUT ROWID")
	run_done(t, store, "INSERT INTO w VALUES (2, 'b'), (1, 'a')")
	testing.expect_value(t, scalar(t, store, "SELECT v FROM w WHERE id = 1").s, "a")
	dropped_result_9514, rowid := db.sql_execute(store, "SELECT rowid FROM w")
	defer db.error_free(&rowid)
	defer db.sql_result_destroy(&dropped_result_9514)
	testing.expect_value(t, rowid.kind, db.Error_Kind.Column_Not_Found)
	dropped_result_9516, keyless := db.sql_execute(store, "CREATE TABLE nk (v TEXT) WITHOUT ROWID")
	defer db.error_free(&keyless)
	defer db.sql_result_destroy(&dropped_result_9516)
	testing.expect(t, !db.error_ok(keyless))
	// SQLite walks a WITHOUT ROWID table in its key's order, so does a scan here.
	run_done(t, store, "CREATE TABLE z (x, y, z, PRIMARY KEY (z, x)) WITHOUT ROWID")
	run_done(t, store, "INSERT INTO z VALUES ('x1', 'y1', 2), ('x0', 'y2', 2), ('x9', 'y3', 1)")
	scanned := run_temp(t, store, "SELECT x FROM z").rows
	testing.expect_value(t, len(scanned), 3)
	if len(scanned) == 3 {
		testing.expect_value(t, scanned[0][0].s, "x9")
		testing.expect_value(t, scanned[1][0].s, "x0")
		testing.expect_value(t, scanned[2][0].s, "x1")
	}
}

// CREATE TABLE ... AS SELECT: columns named after the result, declared with
// their expression's affinity, the rows copied, and the text SQLite writes
// (every expected text here is SQLite 3.54.1's for the same statement).
@(test)
test_create_table_as_select :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "create_table_as")
	if store == nil do return
	defer destroy_host(store, host, "create_table_as")
	run_done(t, store, "CREATE TABLE t (a INTEGER, b TEXT, c REAL, d, e NUMERIC)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'x', 1.5, 'any', 3), (2, 'y', 2.5, 7, 4)")
	run_done(t, store, "CREATE TABLE v AS SELECT a, b FROM t")
	testing.expect_value(t, scalar(t, store, "SELECT sql FROM sqlite_schema WHERE name = 'v'").s, "CREATE TABLE v(a INT,b TEXT)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM v").i, i64(2))
	run_done(t, store, "CREATE TABLE w AS SELECT *, a + 1 AS plus, CAST(a AS TEXT) AS ct, a AS \"select\", b AS a FROM t WHERE a = 2")
	testing.expect_value(
		t,
		scalar(t, store, "SELECT sql FROM sqlite_schema WHERE name = 'w'").s,
		"CREATE TABLE w(\n  a INT,\n  b TEXT,\n  c REAL,\n  d,\n  e NUM,\n  plus,\n  ct TEXT,\n  \"select\" INT,\n  \"a:1\" TEXT\n)",
	)
	testing.expect_value(t, scalar(t, store, "SELECT \"a:1\" FROM w").s, "y")
	run_done(t, store, "CREATE TABLE e AS SELECT a FROM t WHERE 0")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM e").i, i64(0))
	// IF NOT EXISTS leaves an existing table alone; without it, the name is taken.
	run_done(t, store, "CREATE TABLE IF NOT EXISTS v AS SELECT 1")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM v").i, i64(2))
	dropped_result_9555, taken := db.sql_execute(store, "CREATE TABLE v AS SELECT 1")
	defer db.error_free(&taken)
	defer db.sql_result_destroy(&dropped_result_9555)
	testing.expect_value(t, taken.kind, db.Error_Kind.Table_Exists)
}

// A bare column beside min() or max() reads the row they chose, as SQLite
// answers: the row of the extreme, the last row of an all-NULL group, and the
// group's first row when no min() or max() is there.
@(test)
test_bare_columns_follow_min_max :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "bare_min_max")
	if store == nil do return
	defer destroy_host(store, host, "bare_min_max")
	run_done(t, store, "CREATE TABLE t (g INT, a INT, b TEXT)")
	run_done(t, store, "INSERT INTO t VALUES (1, 1, 'x'), (1, 5, 'y'), (1, 3, 'z'), (2, NULL, 'n'), (2, 7, 'q'), (2, 7, 'r'), (3, NULL, 'o1'), (3, NULL, 'o2')")
	testing.expect_value(t, scalar(t, store, "SELECT b FROM (SELECT max(a), b FROM t)").s, "q")
	testing.expect_value(t, scalar(t, store, "SELECT b FROM (SELECT min(a), b FROM t)").s, "x")
	grouped := run_temp(t, store, "SELECT g, max(a), b FROM t GROUP BY g ORDER BY g").rows
	testing.expect_value(t, len(grouped), 3)
	if len(grouped) == 3 {
		testing.expect_value(t, grouped[0][2].s, "y")
		testing.expect_value(t, grouped[1][2].s, "q")
		testing.expect_value(t, grouped[2][2].s, "o2")
	}
	both := run_temp(t, store, "SELECT g, max(a), min(a), b FROM t WHERE g = 1 GROUP BY g").rows
	if testing.expect_value(t, len(both), 1) do testing.expect_value(t, both[0][3].s, "x")
	counted := run_temp(t, store, "SELECT g, count(*), b FROM t WHERE g = 2 GROUP BY g").rows
	if testing.expect_value(t, len(counted), 1) do testing.expect_value(t, counted[0][2].s, "n")
}

@(test)
test_alter_table_drop_column :: proc(t: ^testing.T) {
	store, host := fresh_host(t, "drop_column")
	if store == nil do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b INTEGER, c TEXT)")
	run_done(t, store, "INSERT INTO t (a, b, c) VALUES ('x', 10, 'y'), ('z', 20, 'w')")
	run_done(t, store, "ALTER TABLE t DROP COLUMN b")
	rows := run_temp(t, store, "SELECT id, a, c FROM t ORDER BY id").rows
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0][1].s, "x")
	testing.expect_value(t, rows[0][2].s, "y")
	testing.expect_value(t, rows[1][1].s, "z")
	testing.expect_value(t, rows[1][2].s, "w")
	// The table keeps working with the new shape.
	run_done(t, store, "INSERT INTO t (a, c) VALUES ('q', 'r')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT c FROM t WHERE a = 'q'").s, "r")
	// Key and unique columns cannot be dropped.
	dropped_result_9525, key_err := db.sql_execute(store, "ALTER TABLE t DROP COLUMN id")
	defer db.error_free(&key_err)
	defer db.sql_result_destroy(&dropped_result_9525)
	testing.expect_value(t, key_err.kind, db.Error_Kind.Sql_Unsupported)
	// An index on other columns stays, as in SQLite; one on the column blocks
	// the drop.
	run_done(t, store, "CREATE TABLE indexed (id INTEGER PRIMARY KEY, a TEXT, b TEXT)")
	run_done(t, store, "CREATE UNIQUE INDEX indexed_a ON indexed (a)")
	run_done(t, store, "INSERT INTO indexed (id, a, b) VALUES (1, 'x', 'y')")
	dropped_result_9749, indexed_err := db.sql_execute(store, "ALTER TABLE indexed DROP COLUMN b")
	defer db.error_free(&indexed_err)
	defer db.sql_result_destroy(&dropped_result_9749)
	testing.expect_value(t, indexed_err.kind, db.Error_Kind.None)
	testing.expect_value(t, run_error(t, store, "INSERT INTO indexed (id, a) VALUES (2, 'x')").kind, db.Error_Kind.Duplicate_Unique)
	dropped_result_9535, on_index := db.sql_execute(store, "ALTER TABLE indexed DROP COLUMN a")
	defer db.error_free(&on_index)
	defer db.sql_result_destroy(&dropped_result_9535)
	testing.expect_value(t, on_index.kind, db.Error_Kind.Sql_Unsupported)
	dropped_result_9537, missing := db.sql_execute(store, "ALTER TABLE t DROP COLUMN nope")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_9537)
	testing.expect_value(t, missing.kind, db.Error_Kind.Column_Not_Found)

	// The altered shape survives the log replay: the stored rows are remapped
	// by column name when the commit is applied.
	db.host_destroy(host)
	db.store_close(store)
	reopened, open_err := db.store_open("_test_drop_column", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen failed: %s", open_err.message) do return
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM t").i, i64(3))
	testing.expect_value(t, scalar(t, reopened, "SELECT c FROM t WHERE a = 'x'").s, "y")
	cleanup_db(reopened, "drop_column")
}

@(test)
test_vacuum_into :: proc(t: ^testing.T) {
	store := fresh_db(t, "vacuum_source")
	if store == nil do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)")
	run_done(t, store, "INSERT INTO t (a) VALUES ('x'), ('y'), ('z')")
	target := "_test_vacuum_copy"
	os.remove_all(target)
	run_done(t, store, "VACUUM INTO './_test_vacuum_copy'")
	// The copy is a database of its own: it reads and takes new commits.
	copy_store, open_err := db.store_open(target, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open the copy failed: %s", open_err.message) {
		cleanup_db(store, "vacuum_source")
		return
	}
	testing.expect_value(t, scalar(t, copy_store, "SELECT count(*) FROM t").i, i64(3))
	testing.expect_value(t, scalar(t, copy_store, "SELECT a FROM t WHERE id = 3").s, "z")
	run_done(t, copy_store, "INSERT INTO t (a) VALUES ('copy')")
	testing.expect_value(t, scalar(t, copy_store, "SELECT count(*) FROM t").i, i64(4))
	// The original is untouched, and an existing target is refused.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
	dropped_result_9572, exists_err := db.sql_execute(store, "VACUUM INTO './_test_vacuum_copy'")
	defer db.error_free(&exists_err)
	defer db.sql_result_destroy(&dropped_result_9572)
	testing.expect_value(t, exists_err.kind, db.Error_Kind.Io)
	// A plain VACUUM compacts the live log and keeps the data.
	run_done(t, store, "VACUUM")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
	cleanup_db(copy_store, "vacuum_copy")
	cleanup_db(store, "vacuum_source")
}

@(test)
test_sqlite_export_deterministic :: proc(t: ^testing.T) {
	store := fresh_db(t, "export_det")
	if store == nil do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b INTEGER, c REAL, d BLOB)")
	run_done(t, store, "CREATE UNIQUE INDEX t_a ON t (a)")
	run_done(t, store, "INSERT INTO t (a, b, c, d) VALUES ('x', 1, 1.5, x'00ff'), ('y', NULL, -2.25, NULL)")
	run_done(t, store, "INSERT INTO t (a, b) VALUES ('z', 9223372036854775807)")

	first := "_test_export_a.sqlite"
	second := "_test_export_b.sqlite"
	replayed := "_test_export_c.sqlite"
	for path in ([]string{first, second, replayed}) do os.remove(path)
	_, _, write_err := db.sqlite_file_write(store, first)
	testing.expect_value(t, write_err.kind, db.Error_Kind.None)
	_, _, second_err := db.sqlite_file_write(store, second)
	testing.expect_value(t, second_err.kind, db.Error_Kind.None)

	// Two exports of one state are byte-identical: the writer allocates pages in
	// a fixed order from a fresh file, so there are no free pages to reuse.
	bytes_a, read_a := os.read_entire_file(first, context.allocator)
	bytes_b, read_b := os.read_entire_file(second, context.allocator)
	testing.expect(t, read_a == nil && read_b == nil, "cannot read the exports")
	testing.expect_value(t, len(bytes_a), len(bytes_b))
	testing.expect(t, string(bytes_a) == string(bytes_b), "the two exports differ")
	delete(bytes_a)
	delete(bytes_b)

	// The same bytes come out after the log is replayed from disk.
	db.store_close(store)
	reopened, open_err := db.store_open("_test_export_det", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen failed: %s", open_err.message) do return
	_, _, replay_err := db.sqlite_file_write(reopened, replayed)
	testing.expect_value(t, replay_err.kind, db.Error_Kind.None)
	bytes_c, read_c := os.read_entire_file(replayed, context.allocator)
	testing.expect(t, read_c == nil, "cannot read the replayed export")
	bytes_a2, read_a2 := os.read_entire_file(first, context.allocator)
	testing.expect(t, read_a2 == nil, "cannot read the first export again")
	testing.expect(t, string(bytes_a2) == string(bytes_c), "the replayed export differs")
	delete(bytes_c)
	delete(bytes_a2)
	for path in ([]string{first, second, replayed}) do os.remove(path)
	cleanup_db(reopened, "export_det")
}

@(test)
test_window_functions :: proc(t: ^testing.T) {
	store := fresh_db(t, "windows")
	if store == nil do return
	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY, g TEXT, n INTEGER)")
	run_done(t, store, "INSERT INTO s (g, n) VALUES ('a', 10), ('a', 20), ('b', 5), ('b', 5), ('b', 7)")

	// row_number follows the window ORDER BY, which may be descending.
	numbered := run_temp(t, store, "SELECT id, row_number() OVER (ORDER BY id DESC) AS rn FROM s ORDER BY id").rows
	testing.expect_value(t, len(numbered), 5)
	for row, i in numbered do testing.expect_value(t, row[1].i, i64(5 - i))

	// A partition with no ORDER BY aggregates the whole partition.
	totals := run_temp(t, store, "SELECT id, sum(n) OVER (PARTITION BY g) AS total FROM s ORDER BY id").rows
	want_totals := []i64{30, 30, 17, 17, 17}
	for row, i in totals do testing.expect_value(t, row[1].i, want_totals[i])

	// With ORDER BY the frame runs to the last peer: a running total.
	running := run_temp(t, store, "SELECT id, sum(n) OVER (PARTITION BY g ORDER BY id) AS r FROM s ORDER BY id").rows
	want_running := []i64{10, 30, 5, 10, 17}
	for row, i in running do testing.expect_value(t, row[1].i, want_running[i])

	// Rank and dense_rank share peers but count them differently.
	ranked := run_temp(t, store, "SELECT id, rank() OVER (ORDER BY n) AS r, dense_rank() OVER (ORDER BY n) AS d FROM s ORDER BY id").rows
	want_rank := []i64{4, 5, 1, 1, 3}
	want_dense := []i64{3, 4, 1, 1, 2}
	for row, i in ranked {
		testing.expect_value(t, row[1].i, want_rank[i])
		testing.expect_value(t, row[2].i, want_dense[i])
	}

	// lag and lead read other rows, and lag falls back to its default.
	shifted := run_temp(t, store, "SELECT id, lag(n, 1, -1) OVER (ORDER BY id) AS prev, lead(n) OVER (ORDER BY id) AS next FROM s ORDER BY id").rows
	testing.expect_value(t, shifted[0][1].i, i64(-1))
	testing.expect_value(t, shifted[0][2].i, i64(20))
	testing.expect_value(t, shifted[4][1].i, i64(5))
	testing.expect_value(t, shifted[4][2].kind, db.Value_Kind.Null)

	// count(*) and avg() as windows, and first_value/last_value on the frame.
	counted := run_temp(t, store, "SELECT id, count(*) OVER (PARTITION BY g) AS c FROM s ORDER BY id").rows
	want_count := []i64{2, 2, 3, 3, 3}
	for row, i in counted do testing.expect_value(t, row[1].i, want_count[i])
	edges := run_temp(t, store, "SELECT id, first_value(n) OVER (PARTITION BY g ORDER BY id) AS f, last_value(n) OVER (PARTITION BY g ORDER BY id) AS l FROM s ORDER BY id").rows
	testing.expect_value(t, edges[1][1].i, i64(10))
	testing.expect_value(t, edges[1][2].i, i64(20))
	testing.expect_value(t, edges[4][1].i, i64(5))
	testing.expect_value(t, edges[4][2].i, i64(7))

	// ORDER BY can name the window projection, and LIMIT applies after it.
	alias_sorted := run_temp(t, store, "SELECT id, row_number() OVER (ORDER BY id DESC) AS rn FROM s ORDER BY rn LIMIT 2").rows
	testing.expect_value(t, len(alias_sorted), 2)
	testing.expect_value(t, alias_sorted[0][0].i, i64(5))
	testing.expect_value(t, alias_sorted[1][0].i, i64(4))

	// ntile splits the rows into buckets, larger buckets first.
	buckets := run_temp(t, store, "SELECT id, ntile(2) OVER (ORDER BY id) AS b FROM s ORDER BY id").rows
	want_bucket := []i64{1, 1, 1, 2, 2}
	for row, i in buckets do testing.expect_value(t, row[1].i, want_bucket[i])

	// A frame on a ranking function is accepted and has no effect on it; the
	// aggregate case is covered by test_window_frames.
	framed_rank := run(
		t,
		store,
		"SELECT row_number() OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM s ORDER BY id",
	)
	testing.expect_value(t, len(framed_rank.rows), 5)
	db.sql_result_destroy(&framed_rank)
	// A window beside GROUP BY reads the groups rather than approximating a row:
	// every group is one row of the window's input, so row_number numbers them.
	grouped_numbers := run(t, store, "SELECT g, count(*), row_number() OVER (ORDER BY g) FROM s GROUP BY g ORDER BY g")
	testing.expect_value(t, len(grouped_numbers.rows), 2)
	testing.expect_value(t, grouped_numbers.rows[0][2].i, 1)
	testing.expect_value(t, grouped_numbers.rows[1][2].i, 2)
	db.sql_result_destroy(&grouped_numbers)
	cleanup_db(store, "windows")
}

@(test)
test_triggers :: proc(t: ^testing.T) {
	store := fresh_db(t, "triggers")
	if store == nil do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)")
	run_done(t, store, "CREATE TABLE audit (id INTEGER PRIMARY KEY, note TEXT)")
	run_done(t, store, "CREATE TRIGGER t_ins AFTER INSERT ON t FOR EACH ROW BEGIN INSERT INTO audit (note) VALUES ('in:' || NEW.a); INSERT INTO audit (note) VALUES ('count:' || (SELECT count(*) FROM t)); END")
	run_done(t, store, "CREATE TRIGGER t_upd AFTER UPDATE ON t BEGIN INSERT INTO audit (note) VALUES (OLD.a || '>' || NEW.a); END")
	run_done(t, store, "CREATE TRIGGER t_del AFTER DELETE ON t BEGIN INSERT INTO audit (note) VALUES ('del:' || OLD.a); END")

	run_done(t, store, "INSERT INTO t (a) VALUES ('x'), ('y')")
	notes := run_temp(t, store, "SELECT note FROM audit ORDER BY id").rows
	testing.expect_value(t, len(notes), 4)
	testing.expect_value(t, notes[0][0].s, "in:x")
	testing.expect_value(t, notes[1][0].s, "count:1")
	testing.expect_value(t, notes[2][0].s, "in:y")
	testing.expect_value(t, notes[3][0].s, "count:2")
	run_done(t, store, "UPDATE t SET a = 'z' WHERE id = 1")
	run_done(t, store, "DELETE FROM t WHERE id = 2")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(6))
	testing.expect_value(t, scalar(t, store, "SELECT note FROM audit WHERE id = 5").s, "x>z")
	testing.expect_value(t, scalar(t, store, "SELECT note FROM audit WHERE id = 6").s, "del:y")

	// Dropping the trigger stops it.
	run_done(t, store, "DROP TRIGGER t_ins")
	run_done(t, store, "INSERT INTO t (a) VALUES ('quiet')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(6))
	missing := run_error(t, store, "DROP TRIGGER t_ins")
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)
	run_done(t, store, "DROP TRIGGER IF EXISTS t_ins")

	// BEFORE triggers are modelled too (their order is covered by test_before_triggers);
	// this one is created and dropped before it can fire, so the counts below stay.
	before := run_error(t, store, "CREATE TRIGGER b BEFORE INSERT ON t BEGIN INSERT INTO audit (note) VALUES ('no'); END")
	testing.expect(t, db.error_ok(before))
	run_done(t, store, "DROP TRIGGER b")
	// WHEN is accepted (the condition itself is covered by test_trigger_when).
	run_done(t, store, "CREATE TRIGGER w AFTER INSERT ON t WHEN NEW.a = 'x' BEGIN INSERT INTO audit (note) VALUES ('when'); END")
	run_done(t, store, "DROP TRIGGER w")

	// Triggers live in the log, so a reopen keeps them.
	db.store_close(store)
	reopened, open_err := db.store_open("_test_triggers", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen failed: %s", open_err.message) do return
	// The insert trigger was dropped, so a new row only fires the update one.
	run_done(t, reopened, "INSERT INTO t (a) VALUES ('after')")
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM audit").i, i64(6))
	run_done(t, reopened, "UPDATE t SET a = 'after2' WHERE a = 'after'")
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM audit").i, i64(7))
	testing.expect_value(t, scalar(t, reopened, "SELECT note FROM audit WHERE id = 7").s, "after>after2")

	// A trigger that fires itself is stopped by the depth limit, and the whole
	// statement rolls back.
	run_done(t, reopened, "CREATE TABLE r (id INTEGER PRIMARY KEY, n INTEGER)")
	run_done(t, reopened, "CREATE TRIGGER r_self AFTER INSERT ON r BEGIN INSERT INTO r (n) VALUES (NEW.n + 1); END")
	recursive := run_error(t, reopened, "INSERT INTO r (n) VALUES (0)")
	testing.expect_value(t, recursive.kind, db.Error_Kind.Sql_Unsupported)
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM r").i, i64(0))
	cleanup_db(reopened, "triggers")
}

@(test)
test_log_on_memory_vfs :: proc(t: ^testing.T) {
	// A persistent database can live on a virtual file system: the commit log
	// writes and replays through it, so nothing touches the disk.
	system := db.vfs_memory_new()
	defer db.vfs_memory_destroy(system)
	options := db.Store_Options {
		persistent = true,
		create     = true,
		durable    = false,
		vfs        = system,
	}
	store, open_err := db.store_open("virtual/memdb", options)
	if !testing.expectf(t, db.error_ok(open_err), "open failed: %s", open_err.message) do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)")
	run_done(t, store, "INSERT INTO t (a) VALUES ('x'), ('y')")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))
	db.store_close(store)

	reopened, reopen_err := db.store_open("virtual/memdb", options)
	if !testing.expectf(t, db.error_ok(reopen_err), "reopen failed: %s", reopen_err.message) do return
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM t").i, i64(2))
	testing.expect_value(t, scalar(t, reopened, "SELECT a FROM t WHERE id = 2").s, "y")
	db.store_close(reopened)

	// Compaction needs real files, and says so.
	compact_store, compact_err := db.store_open("virtual/memdb", options)
	if testing.expectf(t, db.error_ok(compact_err), "reopen failed: %s", compact_err.message) {
		dropped_result_9793, vacuum_err := db.sql_execute(compact_store, "VACUUM")
		defer db.error_free(&vacuum_err)
		defer db.sql_result_destroy(&dropped_result_9793)
		testing.expect_value(t, vacuum_err.kind, db.Error_Kind.Sql_Unsupported)
		db.store_close(compact_store)
	}

	// The quota wrapper turns an oversized write into a clean error.
	inner := db.vfs_memory_new()
	defer db.vfs_memory_destroy(inner)
	quota := db.vfs_quota_new(inner, 64)
	defer db.vfs_quota_destroy(quota)
	tight := db.Store_Options {
		persistent = true,
		create     = true,
		durable    = false,
		vfs        = quota,
	}
	tiny, tiny_err := db.store_open("quota/db", tight)
	if !testing.expectf(t, db.error_ok(tiny_err), "quota open failed: %s", tiny_err.message) do return
	dropped_result_9898, write_err := db.sql_execute(tiny, "CREATE TABLE big (a TEXT)")
	defer db.error_free(&write_err)
	defer db.sql_result_destroy(&dropped_result_9898)
	testing.expect_value(t, write_err.kind, db.Error_Kind.Quota_Exceeded)
	db.store_close(tiny)
}

@(test)
test_roles_and_permissions :: proc(t: ^testing.T) {
	store := fresh_db(t, "roles")
	if store == nil do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)")
	// Without a grant catalog every write stays open.
	run_done(t, store, "INSERT INTO t (a) VALUES ('one')")

	run_done(t, store, "GRANT insert ON t TO writer")
	denied := run_error(t, store, "INSERT INTO t (a) VALUES ('two')")
	testing.expect_value(t, denied.kind, db.Error_Kind.Permission_Denied)
	run_done(t, store, "GRANT writer TO '*'")
	run_done(t, store, "INSERT INTO t (a) VALUES ('two')")
	run_done(t, store, "REVOKE writer FROM '*'")
	again := run_error(t, store, "INSERT INTO t (a) VALUES ('three')")
	testing.expect_value(t, again.kind, db.Error_Kind.Permission_Denied)

	// Each action needs its own grant.
	run_done(t, store, "GRANT update ON t TO editor")
	run_done(t, store, "GRANT editor TO '*'")
	run_done(t, store, "UPDATE t SET a = 'changed' WHERE a = 'two'")
	no_delete := run_error(t, store, "DELETE FROM t WHERE a = 'changed'")
	testing.expect_value(t, no_delete.kind, db.Error_Kind.Permission_Denied)
	testing.expect_value(t, scalar(t, store, "SELECT has_role('editor')").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT has_role('writer')").b, false)

	// A role granted to one identity only matches that identity.
	identity := db.Identity{}
	db.store_set_identity(store, identity)
	run_done(t, store, "GRANT admin TO '0000000000000000000000000000000000000000000000000000000000000000'")
	testing.expect_value(t, scalar(t, store, "SELECT has_role('admin')").b, true)
	other: db.Identity
	other[0] = 1
	db.store_set_identity(store, other)
	testing.expect_value(t, scalar(t, store, "SELECT has_role('admin')").b, false)
	db.store_set_identity(store, identity)

	// Grants are catalog rows, so a reopen keeps enforcing them.
	db.store_close(store)
	reopened, open_err := db.store_open("_test_roles", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen failed: %s", open_err.message) do return
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM t").i, i64(2))
	testing.expect_value(t, scalar(t, reopened, "SELECT has_role('admin')").b, true)
	testing.expect_value(t, scalar(t, reopened, "SELECT has_role('editor')").b, true)
	still_denied := run_error(t, reopened, "DELETE FROM t WHERE a = 'changed'")
	testing.expect_value(t, still_denied.kind, db.Error_Kind.Permission_Denied)
	cleanup_db(reopened, "roles")
}

@(test)
test_value_layout :: proc(t: ^testing.T) {
	// The size contract: 24 bytes per value keeps a five-column row cheap.
	testing.expect_value(t, size_of(db.Value), 24)
	testing.expect_value(t, size_of(db.Value_Payload), 16)
	testing.expect_value(t, align_of(db.Value), 8)
	testing.expect(t, 5 * size_of(db.Value) <= 200, "five values must fit in 200 bytes")
	fmt.printfln(
		"[layout] Value=%d payload=%d Row=%d Column=%d five_values=%d",
		size_of(db.Value),
		size_of(db.Value_Payload),
		size_of(db.Row),
		size_of(db.Column),
		5 * size_of(db.Value),
	)

	// The 128-bit payloads keep every bit, sign included.
	signed := i128(min(i64)) << 12
	signed_value := db.value_int128(signed)
	testing.expect(t, db.value_big(signed_value) == cast(u128)signed, "a negative int128 keeps its bits")
	testing.expect_value(t, db.value_as_i128(signed_value), signed)
	unsigned_value := db.value_uint128(max(u128))
	testing.expect_value(t, db.value_big(unsigned_value), max(u128))
	testing.expect_value(t, db.value_as_u128(unsigned_value), max(u128))

	// An identity is interned behind the payload, so two values built from the
	// same bytes are equal and report the same identity.
	identity: db.Identity
	identity[0] = 7
	identity[31] = 9
	first := db.value_identity(identity)
	second := db.value_identity(identity)
	testing.expect(t, db.value_equal(first, second), "the same identity must compare equal")
	testing.expect_value(t, db.value_identity_of(first), identity)
	other := identity
	other[0] = 8
	testing.expect(t, !db.value_equal(first, db.value_identity(other)), "a different identity must differ")

	// Every moved payload survives the log: values are encoded on commit,
	// decoded on replay and held in rows of the new layout.
	store := fresh_db(t, "value_layout")
	if store == nil do return
	run_done(t, store, `CREATE TABLE v (
		id INTEGER PRIMARY KEY,
		u  UUID,
		b  INT128,
		n  UINT128,
		i  IDENTITY,
		a  ANY
	)`)
	run_done(t, store, "INSERT INTO v (id, u) VALUES (1, '00010203-0405-0607-0809-0a0b0c0d0e0f')")
	run_done(t, store, "INSERT INTO v (id, b) VALUES (2, 170141183460469231731687303715884105727)")
	run_done(t, store, "INSERT INTO v (id, n) VALUES (3, 340282366920938463463374607431768211455)")
	run_done(t, store, "INSERT INTO v (id, i) VALUES (4, '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')")
	run_done(t, store, "INSERT INTO v (id, a) VALUES (5, 5), (6, 'seis'), (7, 7.5), (8, x'00ff')")

	stored_uuid := scalar(t, store, "SELECT u FROM v WHERE id = 1")
	testing.expect_value(t, stored_uuid.kind, db.Value_Kind.Uuid)
	testing.expect_value(t, stored_uuid.uuid[0], u8(0))
	testing.expect_value(t, stored_uuid.uuid[15], u8(0x0f))
	stored_big := scalar(t, store, "SELECT b FROM v WHERE id = 2")
	testing.expect_value(t, stored_big.kind, db.Value_Kind.Int128)
	testing.expect_value(t, db.value_big(stored_big), u128(max(i128)))
	stored_unsigned := scalar(t, store, "SELECT n FROM v WHERE id = 3")
	testing.expect_value(t, stored_unsigned.kind, db.Value_Kind.Uint128)
	testing.expect_value(t, db.value_big(stored_unsigned), max(u128))
	stored_identity := scalar(t, store, "SELECT i FROM v WHERE id = 4")
	testing.expect_value(t, stored_identity.kind, db.Value_Kind.Identity)
	testing.expect_value(t, db.value_identity_of(stored_identity)[0], u8(0))
	testing.expect_value(t, db.value_identity_of(stored_identity)[31], u8(0x1f))
	testing.expect_value(t, scalar(t, store, "SELECT a FROM v WHERE id = 5").i, i64(5))
	testing.expect_value(t, scalar(t, store, "SELECT a FROM v WHERE id = 6").s, "seis")
	testing.expect_value(t, scalar(t, store, "SELECT a FROM v WHERE id = 7").f, 7.5)
	testing.expect_value(t, len(scalar(t, store, "SELECT a FROM v WHERE id = 8").bytes), 2)

	// A reopen replays the log, which encodes and decodes every class again.
	db.store_close(store)
	reopened, open_err := db.store_open("_test_value_layout", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen failed: %s", open_err.message) {
		cleanup_db(store, "value_layout")
		return
	}
	testing.expect_value(t, scalar(t, reopened, "SELECT u FROM v WHERE id = 1").uuid[6], u8(0x06))
	replayed_big := scalar(t, reopened, "SELECT b FROM v WHERE id = 2")
	testing.expect_value(t, db.value_big(replayed_big), u128(max(i128)))
	testing.expect_value(t, db.value_big(scalar(t, reopened, "SELECT n FROM v WHERE id = 3")), max(u128))
	testing.expect_value(t, db.value_identity_of(scalar(t, reopened, "SELECT i FROM v WHERE id = 4"))[31], u8(0x1f))
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM v").i, i64(8))
	testing.expect_value(t, scalar(t, reopened, "SELECT typeof(a) FROM v WHERE id = 8").s, "blob")
	cleanup_db(reopened, "value_layout")
}

@(test)
test_commit_queue :: proc(t: ^testing.T) {
	// The policy first: priority order, FIFO inside a priority.
	queue: db.Commit_Queue
	low := new(db.Prepared_Tx)
	normal := new(db.Prepared_Tx)
	high := new(db.Prepared_Tx)
	db.commit_queue_push(&queue, low, .Low)
	db.commit_queue_push(&queue, normal, .Normal)
	db.commit_queue_push(&queue, high, .High)
	testing.expect_value(t, db.commit_queue_len(&queue), 3)
	first := db.commit_queue_drain(&queue, 1)
	testing.expect_value(t, len(first), 1)
	testing.expect(t, first[0] == high, "the high-priority entry must go first")
	delete(first)
	rest := db.commit_queue_drain(&queue, 5)
	testing.expect_value(t, len(rest), 2)
	testing.expect(t, rest[0] == normal, "normal before low")
	testing.expect(t, rest[1] == low, "low last")
	delete(rest)

	// Aging: a low entry that waits its rounds is promoted past fresher highs.
	db.commit_queue_push(&queue, low, .Low)
	for round in 0 ..< db.COMMIT_QUEUE_AGING {
		fresh := new(db.Prepared_Tx)
		db.commit_queue_push(&queue, fresh, .High)
		batch := db.commit_queue_drain(&queue, 1)
		testing.expect_value(t, len(batch), 1)
		testing.expectf(t, batch[0] == fresh, "round %d served the waiting entry early", round)
		delete(batch)
		free(fresh)
	}
	fresh := new(db.Prepared_Tx)
	db.commit_queue_push(&queue, fresh, .High)
	promoted_batch := db.commit_queue_drain(&queue, 1)
	testing.expect(t, promoted_batch[0] == low, "the aged entry must win once it waited long enough")
	delete(promoted_batch)
	testing.expect(t, db.commit_queue_stats(&queue).promoted >= 1)
	after := db.commit_queue_drain(&queue, 5)
	testing.expect(t, after[0] == fresh)
	delete(after)
	free(fresh)
	free(low)
	free(normal)
	free(high)
	db.commit_queue_destroy(&queue)

	// Then a real group commit through the queue.
	store := fresh_db(t, "commit_queue")
	if store == nil do return
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY)")
	start_seq := store.commit_seq

	first_tx := db.tx_begin_write(store)
	dropped_result_10239, first_err := db.sql_execute_in_tx(first_tx, "INSERT INTO a (id) VALUES (1)")
	defer db.error_free(&first_err)
	defer db.sql_result_destroy(&dropped_result_10239)
	testing.expect(t, db.error_ok(first_err))
	prepared_a, prepare_a_err := db.tx_prepare(first_tx)
	testing.expect(t, db.error_ok(prepare_a_err))

	second_tx := db.tx_begin_write(store)
	dropped_result_10245, second_err := db.sql_execute_in_tx(second_tx, "INSERT INTO b (id) VALUES (1)")
	defer db.error_free(&second_err)
	defer db.sql_result_destroy(&dropped_result_10245)
	testing.expect(t, db.error_ok(second_err))
	prepared_b, prepare_b_err := db.tx_prepare(second_tx)
	testing.expect(t, db.error_ok(prepare_b_err))

	real: db.Commit_Queue
	db.commit_queue_push(&real, prepared_a, .Low)
	db.commit_queue_push(&real, prepared_b, .High)
	written, commit_err := db.store_commit_queue(store, &real, 1)
	testing.expect(t, db.error_ok(commit_err))
	testing.expect_value(t, written, 1)
	testing.expect_value(t, store.commit_seq, start_seq + 1)
	// The high-priority insert landed first.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM b").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM a").i, i64(0))
	written_rest, rest_err := db.store_commit_queue(store, &real, 4)
	testing.expect(t, db.error_ok(rest_err))
	testing.expect_value(t, written_rest, 1)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM a").i, i64(1))
	testing.expect_value(t, db.commit_queue_len(&real), 0)
	db.commit_queue_destroy(&real)
	cleanup_db(store, "commit_queue")
}

@(test)
test_writer_lock :: proc(t: ^testing.T) {
	// One database directory has one owner. A second open from this process is
	// refused by the engine's registry before the operating system is asked, and
	// the refusal names the pid that holds it; closing the owner releases both.
	path := fmt.aprintf("_test_%s", "writer_lock")
	defer delete(path)
	os.remove_all(path)
	defer os.remove_all(path)

	first, first_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(first_err), "first open: %s", first_err.message) do return

	second, second_err := db.store_open(path, {persistent = true, create = true, durable = false})
	defer db.error_free(&second_err)
	testing.expect(t, second == nil)
	testing.expect_value(t, second_err.kind, db.Error_Kind.Locked)
	testing.expectf(t, strings.contains(second_err.message, path), "refusal names the database: %s", second_err.message)
	testing.expectf(t, strings.contains(second_err.message, "pid"), "refusal names the owner: %s", second_err.message)

	// The lock file carries the owner, and it is inside the directory.
	lock_file := fmt.aprintf("%s/lock", path)
	defer delete(lock_file)
	testing.expect(t, os.exists(lock_file))

	db.store_close(first)
	third, third_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(third_err), "reopen after close: %s", third_err.message) do return
	db.store_close(third)

	// A database that does not exist is still reported as missing, never as
	// locked: the lock is taken after the directory exists.
	missing := fmt.aprintf("_test_%s_missing", "writer_lock")
	defer delete(missing)
	os.remove_all(missing)
	_, missing_err := db.store_open(missing, {persistent = true, create = false, durable = false})
	defer db.error_free(&missing_err)
	testing.expect_value(t, missing_err.kind, db.Error_Kind.Io)
}

@(test)
test_fault_injection :: proc(t: ^testing.T) {
	// Every write of a short workload is broken in turn: the append of the log
	// header, the record of CREATE TABLE, the record of each commit. A run may
	// commit or report failure; what it may never do is report failure and leave
	// the row behind, or report success and lose it. The database is reopened
	// without the fault to see what really landed.
	memory := db.vfs_memory_new()
	defer db.vfs_memory_destroy(memory)
	fault := db.vfs_fault_new(memory)
	defer db.vfs_fault_destroy(fault)

	fired := 0
	for n in 1 ..= 24 {
		path := fmt.aprintf("_fault_%d", n)
		db.vfs_fault_arm(fault, .Write, u64(n))
		store, open_err := db.store_open(path, {persistent = true, create = true, durable = true, vfs = fault})
		if !db.error_ok(open_err) {
			db.error_free(&open_err)
			// A fault during the initial header leaves no usable database; opening
			// again must report the same thing instead of inventing state.
			_, retry_err := db.store_open(path, {persistent = true, create = false, durable = false, vfs = memory})
			testing.expectf(t, retry_err.kind != .None, "n=%d: a failed header opened clean", n)
			db.error_free(&retry_err)
			delete(path)
			continue
		}
		created := db.error_ok(run_err(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"))
		inserted := 0
		for i in 0 ..< 6 {
			statement := fmt.tprintf("INSERT INTO t (v) VALUES (%d)", i)
			if db.error_ok(run_err(t, store, statement)) do inserted += 1
		}
		if db.vfs_fault_fired(fault) do fired += 1
		db.store_close(store)

		clean, clean_err := db.store_open(path, {persistent = true, create = false, durable = false, vfs = memory})
		if !testing.expectf(t, db.error_ok(clean_err), "n=%d: reopen failed: %s", n, clean_err.message) {
			delete(path)
			continue
		}
		result, count_err := db.sql_execute(clean, "SELECT count(*) FROM t")
		count := i64(0)
		if db.error_ok(count_err) {
			count = result.rows[0][0].i
		}
		db.sql_result_destroy(&result)
		testing.expectf(t, db.error_ok(count_err) == created, "n=%d: table exists=%v created=%v", n, db.error_ok(count_err), created)
		db.error_free(&count_err)
		testing.expectf(t, count == i64(inserted), "n=%d: %d rows landed, %d commits reported success", n, count, inserted)
		db.store_close(clean)
		delete(path)
	}

	// A short write is a failed write: the record is incomplete, so the commit
	// must not be reported as applied, and the reopen must not see the row.
	short_fired := 0
	for n in 1 ..= 8 {
		path := fmt.aprintf("_fault_short_%d", n)
		store, open_err := db.store_open(path, {persistent = true, create = true, durable = true, vfs = fault})
		if !db.error_ok(open_err) {
			db.error_free(&open_err)
			delete(path)
			continue
		}
		// Arm after the open: every one of these faults lands on a record.
		db.vfs_fault_arm(fault, .Write, u64(n))
		db.vfs_fault_short(fault, 3)
		created := db.error_ok(run_err(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"))
		inserted := 0
		if db.error_ok(run_err(t, store, "INSERT INTO t (v) VALUES (1)")) do inserted += 1
		if db.vfs_fault_fired(fault) do short_fired += 1
		db.store_close(store)
		clean, clean_err := db.store_open(path, {persistent = true, create = false, durable = false, vfs = memory})
		testing.expectf(t, db.error_ok(clean_err), "short n=%d: reopen: %s", n, clean_err.message)
		if db.error_ok(clean_err) {
			result, count_err := db.sql_execute(clean, "SELECT count(*) FROM t")
			count := i64(0)
			if db.error_ok(count_err) do count = result.rows[0][0].i
			db.sql_result_destroy(&result)
			testing.expectf(t, db.error_ok(count_err) == created, "short n=%d: table exists=%v created=%v", n, db.error_ok(count_err), created)
			db.error_free(&count_err)
			testing.expectf(t, count == i64(inserted), "short n=%d: %d rows, %d reported", n, count, inserted)
			db.store_close(clean)
		}
		delete(path)
	}

	testing.expectf(t, fired > 0, "no write fault was ever reached")
	testing.expectf(t, short_fired > 0, "no short write was ever reached")

	// A read failure during recovery is reported, never a crash, and the database
	// still opens once reads work again.
	{
		path := fmt.aprintf("_fault_read")
		defer delete(path)
		store, open_err := db.store_open(path, {persistent = true, create = true, durable = false, vfs = memory})
		if !testing.expectf(t, db.error_ok(open_err), "seed open: %s", open_err.message) do return
		run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
		run_done(t, store, "INSERT INTO t (id) VALUES (1)")
		db.store_close(store)

		db.vfs_fault_arm(fault, .Read, 1)
		_, replay_err := db.store_open(path, {persistent = true, create = false, durable = false, vfs = fault})
		testing.expectf(t, replay_err.kind != .None, "a failing read during replay must be reported")
		db.error_free(&replay_err)
		db.vfs_fault_arm(fault, .Read, 0)
		clean, clean_err := db.store_open(path, {persistent = true, create = false, durable = false, vfs = memory})
		testing.expectf(t, db.error_ok(clean_err), "reopen after a read fault: %s", clean_err.message)
		if db.error_ok(clean_err) {
			testing.expect_value(t, scalar(t, clean, "SELECT count(*) FROM t").i, i64(1))
			db.store_close(clean)
		}
	}
}

@(private)
// run_err runs a statement that may fail and answers its error, the message in
// the test's temporary memory, the result freed.
run_err :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> db.Error {
	result, err := db.sql_execute(store, sql)
	db.sql_result_destroy(&result)
	out := db.Error{kind = err.kind, message = strings.clone(err.message, context.temp_allocator)}
	db.error_free(&err)
	return out
}

@(test)
test_ddl_in_transaction :: proc(t: ^testing.T) {
	// A transaction is the unit of atomicity for schema as well as rows: a table,
	// the rows in it and an index over them commit together, and a rollback takes
	// the index with it.
	store := fresh_db(t, "ddl_in_tx")
	if store == nil do return
	defer cleanup_db(store, "ddl_in_tx")
	run_done(t, store, "CREATE TABLE t (a INTEGER NOT NULL, b TEXT)")
	run_done(t, store, "INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y')")

	// Rows changed and an index created in the same transaction.
	tx := db.tx_begin_write(store)
	dropped_result_10449, insert_err := db.sql_execute_in_tx(tx, "INSERT INTO t (a, b) VALUES (3, 'z')")
	defer db.error_free(&insert_err)
	defer db.sql_result_destroy(&dropped_result_10449)
	testing.expect(t, db.error_ok(insert_err))
	dropped_result_10451, index_err := db.sql_execute_in_tx(tx, "CREATE INDEX t_a ON t (a)")
	defer db.error_free(&index_err)
	defer db.sql_result_destroy(&dropped_result_10451)
	testing.expectf(t, db.error_ok(index_err), "create index with rows: %s", index_err.message)
	dropped_result_10453, update_err := db.sql_execute_in_tx(tx, "UPDATE t SET b = 'q' WHERE a = 1")
	defer db.error_free(&update_err)
	defer db.sql_result_destroy(&dropped_result_10453)
	testing.expect(t, db.error_ok(update_err))
	testing.expect(t, db.error_ok(db.tx_commit(tx)))

	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(3))
	plan, plan_err := db.sql_execute(store, "EXPLAIN SELECT b FROM t WHERE a = 2")
	testing.expect(t, db.error_ok(plan_err))
	uses_index := false
	for row in plan.rows {
		if len(row) > 0 && strings.contains(row[0].s, "using index t_a") do uses_index = true
	}
	db.sql_result_destroy(&plan)
	testing.expectf(t, uses_index, "the index is usable after the commit")

	// Table, rows and a unique index created together.
	tx = db.tx_begin_write(store)
	dropped_result_10469, create_err := db.sql_execute_in_tx(tx, "CREATE TABLE u (id INTEGER, label TEXT)")
	defer db.error_free(&create_err)
	defer db.sql_result_destroy(&dropped_result_10469)
	testing.expect(t, db.error_ok(create_err))
	dropped_result_10471, rows_err := db.sql_execute_in_tx(tx, "INSERT INTO u (id, label) VALUES (7, 'seven'), (8, 'eight')")
	defer db.error_free(&rows_err)
	defer db.sql_result_destroy(&dropped_result_10471)
	testing.expect(t, db.error_ok(rows_err))
	dropped_result_10473, unique_err := db.sql_execute_in_tx(tx, "CREATE UNIQUE INDEX u_id ON u (id)")
	defer db.error_free(&unique_err)
	defer db.sql_result_destroy(&dropped_result_10473)
	testing.expectf(t, db.error_ok(unique_err), "unique index on a new table: %s", unique_err.message)
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM u WHERE id = 8").i, i64(1))
	dropped_result_10337, duplicate_err := db.sql_execute(store, "INSERT INTO u (id, label) VALUES (8, 'again')")
	defer db.error_free(&duplicate_err)
	defer db.sql_result_destroy(&dropped_result_10337)
	testing.expect_value(t, duplicate_err.kind, db.Error_Kind.Duplicate_Unique)

	// A rollback takes the index with it and leaves nothing behind.
	tx = db.tx_begin_write(store)
	dropped_result_10484, staged_err := db.sql_execute_in_tx(tx, "CREATE INDEX t_b ON t (b)")
	defer db.error_free(&staged_err)
	defer db.sql_result_destroy(&dropped_result_10484)
	testing.expect(t, db.error_ok(staged_err))
	db.tx_rollback(tx)
	dropped_result_10345, missing_err := db.sql_execute(store, "DROP INDEX t_b")
	defer db.error_free(&missing_err)
	defer db.sql_result_destroy(&dropped_result_10345)
	testing.expect_value(t, missing_err.kind, db.Error_Kind.Index_Not_Found)

	// Two indexes in one transaction, one of them created and dropped again.
	tx = db.tx_begin_write(store)
	dropped_result_10494, first_err := db.sql_execute_in_tx(tx, "CREATE INDEX t_b ON t (b)")
	defer db.error_free(&first_err)
	defer db.sql_result_destroy(&dropped_result_10494)
	testing.expect(t, db.error_ok(first_err))
	dropped_result_10496, second_err := db.sql_execute_in_tx(tx, "CREATE INDEX t_ab ON t (a, b)")
	defer db.error_free(&second_err)
	defer db.sql_result_destroy(&dropped_result_10496)
	testing.expect(t, db.error_ok(second_err))
	dropped_result_10498, drop_err := db.sql_execute_in_tx(tx, "DROP INDEX t_ab")
	defer db.error_free(&drop_err)
	defer db.sql_result_destroy(&dropped_result_10498)
	testing.expectf(t, db.error_ok(drop_err), "drop inside the creating transaction: %s", drop_err.message)
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE b = 'q'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _indexes").i, i64(3))
}

@(test)
test_full_text_ranking :: proc(t: ^testing.T) {
	// BM25 reads the postings, not the documents: a rare term outweighs a common
	// one, a short document outweighs a long one at equal frequency, rank orders
	// best first, and the helpers mark the match.
	store := fresh_db(t, "fts_rank")
	if store == nil do return
	defer cleanup_db(store, "fts_rank")
	run_done(t, store, "CREATE VIRTUAL TABLE docs USING fts5(body)")

	// `common` appears in every document; `rare` in one. Both documents have the
	// same length, so only the document frequency decides the order.
	run_done(t, store, "INSERT INTO docs (body) VALUES ('common words here'), ('common rare words')")
	rows := run(
		t,
		store,
		"SELECT body FROM docs WHERE docs MATCH 'common OR rare' ORDER BY rank LIMIT 1",
	)
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect_value(t, rows.rows[0][0].s, "common rare words")
	db.sql_result_destroy(&rows)

	// At equal frequency, the shorter document wins: same term, one token versus
	// eight.
	run_done(t, store, "DELETE FROM docs")
	run_done(t, store, "INSERT INTO docs (body) VALUES ('target'), ('target a b c d e f g')")
	rows = run(
		t,
		store,
		"SELECT body, rank FROM docs WHERE docs MATCH 'target' ORDER BY rank",
	)
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect_value(t, rows.rows[0][0].s, "target")
	testing.expectf(t, rows.rows[0][1].f < rows.rows[1][1].f, "rank is ordered best first")
	// rank is negative BM25: a better match is a more negative number.
	testing.expectf(t, rows.rows[0][1].f < 0, "rank is negative")
	db.sql_result_destroy(&rows)

	// The token count matters: repeating a term raises its score, not its length.
	run_done(t, store, "DELETE FROM docs")
	run_done(t, store, "INSERT INTO docs (body) VALUES ('alpha alpha alpha beta'), ('alpha beta gamma delta')")
	rows = run(t, store, "SELECT body FROM docs WHERE docs MATCH 'alpha' ORDER BY rank LIMIT 1")
	testing.expect_value(t, rows.rows[0][0].s, "alpha alpha alpha beta")
	db.sql_result_destroy(&rows)

	// AND is the juxtaposition it already was; OR widens; NOT removes.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'alpha AND beta'").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'alpha NOT beta'").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'gamma OR beta'").i, i64(2))

	// snippet and highlight mark the tokens the pattern asks for.
	run_done(t, store, "DELETE FROM docs")
	run_done(t, store, "INSERT INTO docs (body) VALUES ('the quick brown fox jumps over the lazy dog')")
	highlight := scalar(t, store, "SELECT highlight(body, 'fox') FROM docs").s
	testing.expectf(t, strings.contains(highlight, "[fox]"), "highlight marks the word: %s", highlight)
	snippet := scalar(t, store, "SELECT snippet(body, 'lazy') FROM docs").s
	testing.expectf(t, strings.contains(snippet, "[lazy]"), "snippet marks the word: %s", snippet)
	testing.expectf(t, strings.contains(snippet, "…"), "snippet trims around the match: %s", snippet)

	// The score follows the corpus as it changes: deleting the long document makes
	// the average length smaller.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs WHERE docs MATCH 'quick'").i, i64(1))

	// A plain table has no rank, and asking for it is an error rather than a zero.
	run_done(t, store, "CREATE TABLE plain (body TEXT)")
	run_done(t, store, "INSERT INTO plain (body) VALUES ('nothing to rank')")
	dropped_result_10338, rank_err := db.sql_execute(store, "SELECT rank FROM plain")
	defer db.error_free(&rank_err)
	defer db.sql_result_destroy(&dropped_result_10338)
	testing.expect_value(t, rank_err.kind, db.Error_Kind.Column_Not_Found)
}

@(test)
test_full_text_phrase_prefix_and_column :: proc(t: ^testing.T) {
	// The rest of the query language: a phrase needs its words adjacent and in
	// order, a prefix matches every term that starts with it, and `col:` limits an
	// item to one column. Ranking and the helpers follow the same items.
	store := fresh_db(t, "fts_ops")
	if store == nil do return
	defer cleanup_db(store, "fts_ops")
	run_done(t, store, "CREATE VIRTUAL TABLE notes USING fts5(title, body)")
	run(
		t,
		store,
		`INSERT INTO notes (title, body) VALUES
		('fox report', 'the quick brown fox jumps'),
		('brown paper', 'a fox that is quick and brown'),
		('database notes', 'indexing and indexes in a database'),
		('don''t panic', 'towels are useful')`,
	)
	count :: proc(t: ^testing.T, store: ^db.Store, pattern: string) -> i64 {
		return scalar(t, store, fmt.tprintf("SELECT count(*) FROM notes WHERE notes MATCH '%s'", pattern)).i
	}
	// Phrase: both rows carry `quick` and `brown`, only one has them adjacent.
	testing.expect_value(t, count(t, store, `"quick brown"`), i64(1))
	testing.expect_value(t, count(t, store, `"brown quick"`), i64(0))
	testing.expect_value(t, count(t, store, `"quick brown fox"`), i64(1))
	// A phrase is still an item: it composes with OR and NOT.
	testing.expect_value(t, count(t, store, `"quick brown" OR towels`), i64(2))
	testing.expect_value(t, count(t, store, `fox NOT "quick brown"`), i64(1))
	// Prefix: `index*` reaches `indexing` and `indexes`, `qu*` reaches `quick`.
	testing.expect_value(t, count(t, store, "index*"), i64(1))
	testing.expect_value(t, count(t, store, "qu*"), i64(2))
	testing.expect_value(t, count(t, store, "zebra*"), i64(0))
	testing.expect_value(t, count(t, store, `"quick bro*"`), i64(1))
	// Column filter: `fox` is in both bodies but only one title.
	testing.expect_value(t, count(t, store, "fox"), i64(2))
	testing.expect_value(t, count(t, store, "title:fox"), i64(1))
	testing.expect_value(t, count(t, store, "body:fox"), i64(2))
	testing.expect_value(t, count(t, store, "title:bro*"), i64(1))
	testing.expect_value(t, count(t, store, `body:"quick brown"`), i64(1))
	testing.expect_value(t, count(t, store, `title:"quick brown"`), i64(0))
	// A bare word the tokenizer splits is a phrase of its parts.
	testing.expect_value(t, count(t, store, "don''t"), i64(1))
	// AND is an operator that changes nothing, never a term to look for.
	testing.expect_value(t, count(t, store, "fox AND quick"), i64(2))
	// An unknown column is refused with its name.
	dropped_result_10478, bad := db.sql_execute(store, "SELECT count(*) FROM notes WHERE notes MATCH 'author:fox'")
	defer db.error_free(&bad)
	defer db.sql_result_destroy(&dropped_result_10478)
	testing.expect_value(t, bad.kind, db.Error_Kind.Column_Not_Found)

	// Ranking reads the item's own count: the phrase-matching row ranks first.
	rows := run(t, store, `SELECT title FROM notes WHERE notes MATCH '"quick brown" OR fox' ORDER BY rank LIMIT 1`)
	if testing.expect_value(t, len(rows.rows), 1) {
		testing.expect_value(t, rows.rows[0][0].s, "fox report")
	}
	db.sql_result_destroy(&rows)
	// highlight marks prefixes and phrase words, and not what NOT excludes.
	marked := run(t, store, "SELECT highlight(body, 'qu* NOT towels') FROM notes WHERE notes MATCH 'qu*' ORDER BY title LIMIT 1")
	if testing.expect_value(t, len(marked.rows), 1) {
		testing.expect_value(t, marked.rows[0][0].s, "a fox that is [quick] and brown")
	}
	db.sql_result_destroy(&marked)
}

@(test)
test_insert_caches_follow_the_catalog :: proc(t: ^testing.T) {
	// An insert remembers the table it resolved and whether `_grant` and
	// `_trigger` exist, for the rest of its transaction. Every change that could
	// make those answers wrong happens here between two inserts of one
	// transaction, and the second insert must see it.
	store := fresh_db(t, "insert_caches")
	if store == nil do return
	defer cleanup_db(store, "insert_caches")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT UNIQUE)")
	run_done(t, store, "CREATE TABLE log (msg TEXT)")

	tx := db.tx_begin_write(store)
	step :: proc(t: ^testing.T, tx: ^db.Tx, sql: string) -> bool {
		result, err := db.sql_execute_in_tx(tx, sql)
		db.sql_result_destroy(&result)
		return testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
	}
	if !step(t, tx, "INSERT INTO t (id, v) VALUES (1, 'a')") do return
	// A trigger created mid-transaction fires for the next insert: the cached
	// "no trigger table" answer is gone with the create.
	if !step(t, tx, "CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log (msg) VALUES (NEW.v); END") do return
	if !step(t, tx, "INSERT INTO t (id, v) VALUES (2, 'b')") do return
	// The keys registered without a trigger and with one both still guard
	// uniqueness inside the transaction.
	dropped_result_10666, duplicate := db.sql_execute_in_tx(tx, "INSERT INTO t (id, v) VALUES (3, 'a')")
	defer db.sql_result_destroy(&dropped_result_10666)
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Unique)
	db.error_free(&duplicate)
	// Dropping a table resets the cache too: the next insert into another table
	// resolves it afresh, and the dropped one is gone.
	if !step(t, tx, "CREATE TABLE scratch (x INTEGER)") do return
	if !step(t, tx, "INSERT INTO scratch (x) VALUES (1)") do return
	if !step(t, tx, "INSERT INTO t (id, v) VALUES (5, 'd')") do return
	// A savepoint rollback drops the staged row, and the next insert stages into
	// the restored record rather than the discarded one.
	if !testing.expect(t, db.error_ok(db.tx_savepoint(tx, "s"))) do return
	if !step(t, tx, "INSERT INTO t (id, v) VALUES (6, 'e')") do return
	if !testing.expect(t, db.error_ok(db.tx_rollback_to_savepoint(tx, "s"))) do return
	if !step(t, tx, "INSERT INTO t (id, v) VALUES (7, 'f')") do return
	// The same on a table no trigger touches, so nothing else moves the cache
	// between the rollback and the insert that must not reuse it.
	if !step(t, tx, "INSERT INTO scratch (x) VALUES (10)") do return
	if !testing.expect(t, db.error_ok(db.tx_savepoint(tx, "q"))) do return
	if !step(t, tx, "INSERT INTO scratch (x) VALUES (11)") do return
	if !testing.expect(t, db.error_ok(db.tx_rollback_to_savepoint(tx, "q"))) do return
	if !step(t, tx, "INSERT INTO scratch (x) VALUES (12)") do return
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(x) FROM scratch").s, "1,10,12")

	ids := run(t, store, "SELECT id FROM t ORDER BY id")
	got := make([dynamic]i64, 0, 4)
	defer delete(got)
	for row in ids.rows do append(&got, row[0].i)
	db.sql_result_destroy(&ids)
	testing.expectf(t, len(got) == 4 && got[0] == 1 && got[1] == 2 && got[2] == 5 && got[3] == 7, "rows %v", got[:])
	// The trigger fired for every insert into t after it was created: b, d and
	// f; e was rolled back with its savepoint.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log WHERE msg = 'e'").i, i64(0))
}

@(test)
test_scans_come_out_in_row_id_order :: proc(t: ^testing.T) {
	// A scan walks the table's ordered id list instead of its map. Every writer
	// keeps that list right: inserts in several transactions, deletes with their
	// history pruned, a truncate, a commit while a reader holds the table (which
	// copies it), and ids that arrive out of order.
	store := fresh_db(t, "row_order")
	if store == nil do return
	defer cleanup_db(store, "row_order")
	run_done(t, store, "CREATE TABLE t (n INTEGER NOT NULL)")
	for batch in 0 ..< 3 {
		tx := db.tx_begin_write(store)
		for i in 0 ..< 200 {
			_, err := db.tx_insert(tx, "t", []db.Value{db.value_int(i64(batch * 200 + i))})
			if !testing.expect(t, db.error_ok(err)) do return
		}
		testing.expect(t, db.error_ok(db.tx_commit(tx)))
	}
	ascending :: proc(t: ^testing.T, store: ^db.Store, expected_count: int, label: string) {
		tx := db.tx_begin_read(store)
		defer db.tx_end(tx)
		table := db.tx_table_probe(tx, "t")
		rows := make([dynamic]db.Row)
		defer db.table_collect_release(table, &rows)
		db.table_collect(table, &rows)
		testing.expectf(t, len(rows) == expected_count, "%s: %d rows, expected %d", label, len(rows), expected_count)
		for i in 1 ..< len(rows) {
			if rows[i - 1].id >= rows[i].id {
				testing.expectf(t, false, "%s: row %d has id %d after %d", label, i, rows[i].id, rows[i - 1].id)
				return
			}
		}
	}
	ascending(t, store, 600, "after three batches")

	run_done(t, store, "DELETE FROM t WHERE n % 3 = 0")
	ascending(t, store, 400, "after deletes, history kept")
	db.store_prune_history(store)
	ascending(t, store, 400, "after the history is pruned")

	// A reader holds the table while a commit changes it: the commit copies the
	// table, and both the reader's view and the new one stay ordered.
	reader := db.tx_begin_read(store)
	run_done(t, store, "INSERT INTO t (n) VALUES (1000), (1001)")
	{
		table := db.tx_table_probe(reader, "t")
		rows := make([dynamic]db.Row)
		db.table_collect(table, &rows)
		testing.expect_value(t, len(rows), 400)
		db.table_collect_release(table, &rows)
	}
	db.tx_end(reader)
	ascending(t, store, 402, "after a commit under a reader")

	run_done(t, store, "DELETE FROM t")
	run_done(t, store, "INSERT INTO t (n) VALUES (1), (2), (3)")
	db.store_prune_history(store)
	ascending(t, store, 3, "after emptying and refilling")
	run_done(t, store, "TRUNCATE t")
	ascending(t, store, 0, "after a truncate")
	run_done(t, store, "INSERT INTO t (n) VALUES (7)")
	ascending(t, store, 1, "after a truncate and an insert")

	// Ids that arrive out of order (a replay, an explicit row id) are placed.
	{
		schema := db.Table_Schema{name = "loose"}
		columns := []db.Column{{name = "n", type = db.Column_Type{kind = .Int, width = 8}}}
		schema.columns = columns
		loose, create_err := db.table_create(&schema)
		if testing.expect(t, db.error_ok(create_err)) {
			for id in ([]u64{50, 10, 30, 20, 40, 10}) {
				insert_err := db.table_insert(loose, db.Row_Id(id), []db.Value{db.value_int(i64(id))})
				db.error_free(&insert_err)
			}
			rows := make([dynamic]db.Row)
			db.table_collect(loose, &rows)
			got := make([dynamic]u64, 0, 5)
			for row in rows do append(&got, u64(row.id))
			testing.expectf(t, len(got) == 5 && got[0] == 10 && got[1] == 20 && got[4] == 50, "out-of-order ids came out %v", got[:])
			delete(got)
			db.table_collect_release(loose, &rows)
			db.table_destroy(loose)
		}
	}
}

@(test)
test_typed_sorts_agree_with_the_library :: proc(t: ^testing.T) {
	// The two introsorts that replaced slice.sort_by on the hot paths, against
	// slice.sort, on random input, sorted input, reversed input and duplicates,
	// at sizes that exercise the insertion sort, the quicksort and the heapsort.
	state := u64(0x9e3779b97f4a7c15)
	next :: proc(state: ^u64) -> u64 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 7
		state^ ~= state^ << 17
		return state^
	}
	for size in ([]int{0, 1, 2, 5, 23, 24, 25, 100, 1000, 5000}) {
		for shape in 0 ..< 4 {
			ids := make([]db.Row_Id, size)
			defer delete(ids)
			for i in 0 ..< size {
				switch shape {
				case 0:
					ids[i] = db.Row_Id(next(&state))
				case 1:
					ids[i] = db.Row_Id(i)
				case 2:
					ids[i] = db.Row_Id(size - i)
				case 3:
					ids[i] = db.Row_Id(next(&state) % 7)
				}
			}
			expected := slice.clone(ids)
			defer delete(expected)
			slice.sort(expected)
			rows := make([]db.Row, size)
			defer delete(rows)
			for id, i in ids do rows[i].id = id
			db.row_ids_sort(ids)
			db.rows_sort_by_id(rows)
			for i in 0 ..< size {
				if ids[i] != expected[i] || rows[i].id != expected[i] {
					testing.expectf(t, false, "size %d shape %d differs at %d", size, shape, i)
					break
				}
			}
		}
	}
}

@(test)
test_full_text_cost :: proc(t: ^testing.T) {
	// The scan follows the match, not the corpus: with five thousand documents and
	// one match, the query visits a handful of rows. This is measured, not
	// assumed: rows_scanned counts what every scan visited.
	store := fresh_db(t, "fts_cost")
	if store == nil do return
	defer cleanup_db(store, "fts_cost")
	run_done(t, store, "CREATE VIRTUAL TABLE docs USING fts5(body)")
	insert, prepare_err := db.sql_prepare(store, "INSERT INTO docs (body) VALUES (?)")
	if !testing.expectf(t, db.error_ok(prepare_err), "prepare: %s", prepare_err.message) do return
	tx := db.tx_begin_write(store)
	for i in 0 ..< 5000 {
		text := fmt.tprintf("word%d filler common text", i)
		_, insert_err := db.prepared_execute_in_tx(tx, insert, []db.Value{db.value_string(text)})
		if !testing.expectf(t, db.error_ok(insert_err), "insert %d: %s", i, insert_err.message) {
			db.tx_rollback(tx)
			return
		}
	}
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	db.stmt_prepared_destroy(insert)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM docs").i, i64(5000))

	// A bulk load stays linear: one row visited per document, not the growing
	// index. The prepared insert above is what a loader does; this checks that the
	// shadow tables do not turn it into a quadratic scan.
	testing.expectf(t, scalar(t, store, "SELECT count(*) FROM _fts_docs_terms").i > 5000, "postings exist")

	db.store_reset_rows_scanned(store)
	rows, query_err := db.sql_execute(store, "SELECT body FROM docs WHERE docs MATCH 'word4242'")
	testing.expect(t, db.error_ok(query_err))
	testing.expect_value(t, len(rows.rows), 1)
	if len(rows.rows) == 1 {
		testing.expect_value(t, rows.rows[0][0].s, "word4242 filler common text")
	}
	scanned := db.store_rows_scanned(store)
	db.sql_result_destroy(&rows)
	testing.expectf(t, scanned <= 8, "a MATCH over 5000 documents visited %d rows", scanned)

	// Without a MATCH the same table still costs a full scan: the shortcut must
	// not change what a plain query means.
	db.store_reset_rows_scanned(store)
	wide, wide_err := db.sql_execute(store, "SELECT count(*) FROM docs")
	testing.expect(t, db.error_ok(wide_err))
	testing.expect_value(t, db.store_rows_scanned(store), u64(5000))
	db.sql_result_destroy(&wide)

	// OR of two rare terms visits their postings only.
	db.store_reset_rows_scanned(store)
	two, two_err := db.sql_execute(store, "SELECT body FROM docs WHERE docs MATCH 'word7 OR word8'")
	testing.expect(t, db.error_ok(two_err))
	testing.expect_value(t, len(two.rows), 2)
	two_scanned := db.store_rows_scanned(store)
	db.sql_result_destroy(&two)
	testing.expectf(t, two_scanned <= 16, "two rare terms visited %d rows", two_scanned)

	// A term that every document carries costs its postings, because BM25 has to
	// look at every candidate to rank them. That is the honest bound, and it is
	// written down rather than hidden: the cost follows the postings of the query,
	// not the size of the vocabulary.
	db.store_reset_rows_scanned(store)
	common, common_err := db.sql_execute(store, "SELECT count(*) FROM docs WHERE docs MATCH 'common'")
	testing.expect(t, db.error_ok(common_err))
	testing.expect_value(t, common.rows[0][0].i, i64(5000))
	common_scanned := db.store_rows_scanned(store)
	db.sql_result_destroy(&common)
	testing.expectf(t, common_scanned >= 5000, "a common term must read its postings, visited %d", common_scanned)
	testing.expectf(t, common_scanned < 30000, "a common term must not scan the vocabulary: %d", common_scanned)
}

@(test)
test_idempotent_result :: proc(t: ^testing.T) {
	// A retry after a lost reply gets the answer the first call produced, and the
	// reducer does not run again.
	store := fresh_db(t, "idem_result")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "idem_result")
	run_done(t, store, "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO counter (id, value) VALUES (0, 0)")

	runs := 0
	tally :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		amount := args[0].i
		statement := fmt.tprintf("UPDATE counter SET value = value + %d WHERE id = 0", amount)
		if _, err := db.sql_execute_in_tx(ctx.tx, statement); !db.error_ok(err) do return err
		read_result, read_err := db.sql_execute_in_tx(ctx.tx, "SELECT value FROM counter WHERE id = 0")
		db.sql_result_destroy(&read_result)
		if !db.error_ok(read_err) do return read_err
		// The reducer names its result; it is recorded with the request. The slice
		// lives in the transaction: a literal would live in this frame, which is
		// gone by the time the host reads it.
		result := make([]db.Value, 1, ctx.tx.alloc)
		result[0] = db.value_int(amount * 10)
		ctx.result = result
		return db.Error{}
	}
	testing.expect(t, db.error_ok(db.host_register(host, "tally", []db.Column_Type{db.type_int}, tally)))
	_ = runs

	request := []u8{7, 7}
	first, first_err := db.host_call_once_result(host, request, "tally", []db.Value{db.value_int(4)})
	testing.expect(t, db.error_ok(first_err))
	if testing.expectf(t, len(first) == 1, "first call returned %d values", len(first)) {
		testing.expect_value(t, first[0].i, i64(40))
	}
	db.values_destroy(first)

	// The retry returns the stored result and leaves the counter alone.
	second, second_err := db.host_call_once_result(host, request, "tally", []db.Value{db.value_int(4)})
	testing.expect(t, db.error_ok(second_err))
	if testing.expectf(t, len(second) == 1, "retry returned %d values", len(second)) {
		testing.expect_value(t, second[0].i, i64(40))
	}
	db.values_destroy(second)
	testing.expect_value(t, scalar(t, store, "SELECT value FROM counter WHERE id = 0").i, i64(4))

	// A different request runs and answers with its own result.
	third, third_err := db.host_call_once_result(host, []u8{8}, "tally", []db.Value{db.value_int(3)})
	testing.expect(t, db.error_ok(third_err))
	if testing.expectf(t, len(third) == 1, "third call returned %d values", len(third)) {
		testing.expect_value(t, third[0].i, i64(30))
	}
	db.values_destroy(third)
	testing.expect_value(t, scalar(t, store, "SELECT value FROM counter WHERE id = 0").i, i64(7))

	// A reducer that names no result still replays as an empty answer, not an error.
	quiet :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		return db.Error{}
	}
	testing.expect(t, db.error_ok(db.host_register(host, "quiet", nil, quiet)))
	empty, empty_err := db.host_call_once_result(host, []u8{9}, "quiet", nil)
	testing.expect(t, db.error_ok(empty_err))
	testing.expect_value(t, len(empty), 0)
	db.values_destroy(empty)
}

@(test)
test_page_store_roundtrip :: proc(t: ^testing.T) {
	// Pages keep rows, not the other way around: put, get, delete, flush and
	// reopen rebuilds the directory from the page bytes.
	vfs := db.vfs_memory_new()
	defer db.vfs_memory_destroy(vfs)
	rows, open_err := db.page_rows_create(vfs, "pages", 8)
	if !testing.expectf(t, db.error_ok(open_err), "create: %s", open_err.message) do return

	for i in 0 ..< 500 {
		values := []db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("row-%d", i))}
		put_err := db.page_rows_put(rows, db.Row_Id(i), values)
		if !testing.expectf(t, db.error_ok(put_err), "put %d: %s", i, put_err.message) do return
	}
	testing.expect_value(t, rows.rows, u64(500))

	row, found := db.page_rows_get(rows, db.Row_Id(42), context.temp_allocator)
	testing.expect(t, found)
	if found {
		testing.expect_value(t, row.values[0].i, i64(42))
		testing.expect_value(t, row.values[1].s, "row-42")
	}
	testing.expect(t, db.page_rows_delete(rows, db.Row_Id(7)))
	testing.expect_value(t, rows.rows, u64(499))
	_, deleted := db.page_rows_get(rows, db.Row_Id(7), context.temp_allocator)
	testing.expect(t, !deleted)

	testing.expect(t, db.error_ok(db.page_rows_flush(rows, 5)))
	testing.expect_value(t, rows.file.applied_seq, u64(5))
	db.page_rows_close(rows)

	reopened, reopen_err := db.page_rows_open(vfs, "pages", 4)
	if !testing.expectf(t, db.error_ok(reopen_err), "reopen: %s", reopen_err.message) do return
	defer db.page_rows_close(reopened)
	testing.expect_value(t, reopened.file.applied_seq, u64(5))
	testing.expect_value(t, reopened.rows, u64(499))
	again, exists := db.page_rows_get(reopened, db.Row_Id(42), context.temp_allocator)
	testing.expect(t, exists)
	if exists {
		testing.expect_value(t, again.values[1].s, "row-42")
	}
}

@(private)
count_visitor :: proc(ctx: rawptr, row: db.Row) -> bool {
	counters := cast(^[2]i64)ctx
	counters[0] += 1
	counters[1] += row.values[0].i
	return true
}

@(test)
test_page_store_streams_within_the_pool :: proc(t: ^testing.T) {
	// A table far larger than the buffer pool is read page by page: the pool holds
	// four pages, the file holds more than forty, and every row decodes.
	vfs := db.vfs_memory_new()
	defer db.vfs_memory_destroy(vfs)
	rows, open_err := db.page_rows_create(vfs, "big", 4)
	if !testing.expectf(t, db.error_ok(open_err), "create: %s", open_err.message) do return
	defer db.page_rows_close(rows)

	total: i64 = 0
	for i in 0 ..< 5000 {
		values := []db.Value{db.value_int(i64(i)), db.value_string("payload that makes the row big enough to fill pages")}
		put_err := db.page_rows_put(rows, db.Row_Id(i), values)
		if !testing.expectf(t, db.error_ok(put_err), "put %d: %s", i, put_err.message) do return
		total += i64(i)
	}
	file_pages := rows.file.page_count
	testing.expectf(t, file_pages > 4, "the file should outgrow the pool, has %d pages", file_pages)
	testing.expect_value(t, db.page_resident(rows.file), 4)

	counters := [2]i64{0, 0}
	testing.expect(t, db.error_ok(db.page_rows_each(rows, &counters, count_visitor)))
	testing.expect_value(t, counters[0], i64(5000))
	testing.expect_value(t, counters[1], total)
	testing.expectf(t, rows.file.evictions > 0, "the pool must have evicted, evicted %d", rows.file.evictions)
	testing.expect_value(t, db.page_resident(rows.file), 4)
}

@(test)
test_page_store_header_is_a_promise :: proc(t: ^testing.T) {
	// The header names the sequence the pages are complete up to. Break the write
	// of a flush anywhere and the reopen either keeps the old sequence or, when it
	// already says the new one, has every row: never a sequence with missing rows.
	memory := db.vfs_memory_new()
	defer db.vfs_memory_destroy(memory)
	fault := db.vfs_fault_new(memory)
	defer db.vfs_fault_destroy(fault)

	succeeding := 0
	for n in 1 ..= 40 {
		path := fmt.aprintf("faulty_%d", n)
		defer delete(path)
		base, base_err := db.page_rows_create(memory, path, 8)
		if !testing.expectf(t, db.error_ok(base_err), "n=%d create: %s", n, base_err.message) do return
		for i in 0 ..< 500 {
			put_err := db.page_rows_put(base, db.Row_Id(i), []db.Value{db.value_int(i64(i))})
			testing.expectf(t, db.error_ok(put_err), "n=%d seed %d: %s", n, i, put_err.message)
		}
		if flush_err := db.page_rows_flush(base, 1); !testing.expectf(t, db.error_ok(flush_err), "n=%d seed flush: %s", n, flush_err.message) do return
		db.page_rows_close(base)

		rows, open_err := db.page_rows_open(memory, path, 8)
		if !testing.expectf(t, db.error_ok(open_err), "n=%d open: %s", n, open_err.message) do return
		for i in 500 ..< 700 {
			db.page_rows_put(rows, db.Row_Id(i), []db.Value{db.value_int(i64(i))})
		}
		db.vfs_fault_arm(fault, .Write, u64(n))
		flush_err := db.page_rows_flush(rows, 2)
		db.vfs_fault_arm(fault, .Write, 0)
		db.page_rows_close(rows)

		reopened, reopen_err := db.page_rows_open(memory, path, 8)
		if !db.error_ok(reopen_err) {
			// A page that landed halfway cannot be trusted; a corrupt page file is
			// the honest answer, and the caller rebuilds from the log.
			testing.expectf(t, reopen_err.kind == db.Error_Kind.Corrupt_Log, "n=%d: %s", n, reopen_err.message)
			continue
		}
		succeeding += 1
		seq := reopened.file.applied_seq
		testing.expectf(t, seq == 1 || seq == 2, "n=%d: header claims sequence %d", n, seq)
		if seq == 2 {
			for i in 0 ..< 700 {
				_, exists := db.page_rows_get(reopened, db.Row_Id(i), context.temp_allocator)
				testing.expectf(t, exists, "n=%d: header says 2 but row %d is missing", n, i)
			}
		} else {
			for i in 0 ..< 500 {
				_, exists := db.page_rows_get(reopened, db.Row_Id(i), context.temp_allocator)
				testing.expectf(t, exists, "n=%d: header says 1 but row %d is missing", n, i)
			}
		}
		_ = flush_err
		db.page_rows_close(reopened)
	}
	testing.expectf(t, succeeding > 0, "no reopen succeeded")
}

@(test)
test_as_of :: proc(t: ^testing.T) {
	// A table keeps its versions until they are pruned, so a query can read the
	// rows as they were at any commit sequence it still has.
	store := fresh_db(t, "as_of")
	if store == nil do return
	defer cleanup_db(store, "as_of")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 'one'), (2, 'two')")
	first := store.commit_seq
	run_done(t, store, "UPDATE t SET v = 'ONE' WHERE id = 1")
	second := store.commit_seq
	run_done(t, store, "DELETE FROM t WHERE id = 2")
	third := store.commit_seq
	run_done(t, store, "INSERT INTO t (id, v) VALUES (3, 'three')")
	testing.expect(t, first < second && second < third)

	// Now: one updated, one deleted, one added.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT v FROM t WHERE id = 1").s, "ONE")

	// At `first` the original two rows are there and nothing else.
	statement := fmt.tprintf("SELECT count(*) FROM t AS OF %d", first)
	testing.expect_value(t, scalar(t, store, statement).i, i64(2))
	statement = fmt.tprintf("SELECT v FROM t AS OF %d WHERE id = 1", first)
	testing.expect_value(t, scalar(t, store, statement).s, "one")
	statement = fmt.tprintf("SELECT count(*) FROM t AS OF %d WHERE id = 3", first)
	testing.expect_value(t, scalar(t, store, statement).i, i64(0))

	// At `second` the update is visible and the delete is not yet.
	statement = fmt.tprintf("SELECT v FROM t AS OF %d WHERE id = 1", second)
	testing.expect_value(t, scalar(t, store, statement).s, "ONE")
	statement = fmt.tprintf("SELECT count(*) FROM t AS OF %d WHERE id = 2", second)
	testing.expect_value(t, scalar(t, store, statement).i, i64(1))

	// At `third` the delete has happened and the insert has not.
	statement = fmt.tprintf("SELECT count(*) FROM t AS OF %d", third)
	testing.expect_value(t, scalar(t, store, statement).i, i64(1))
	statement = fmt.tprintf("SELECT count(*) FROM t AS OF %d WHERE id = 3", third)
	testing.expect_value(t, scalar(t, store, statement).i, i64(0))

	// Updates and deletes in the same statement see the historical rows.
	statement = fmt.tprintf("SELECT max(v) FROM t AS OF %d", first)
	testing.expect_value(t, scalar(t, store, statement).s, "two")

	// Pruning what no reader needs discards that history: a read before it finds
	// only the rows whose versions are still there, never inventing the others.
	db.store_prune_versions(store, second)
	statement = fmt.tprintf("SELECT count(*) FROM t AS OF %d", first)
	testing.expect_value(t, scalar(t, store, statement).i, i64(1))
	statement = fmt.tprintf("SELECT count(*) FROM t AS OF %d WHERE id = 2", first)
	testing.expect_value(t, scalar(t, store, statement).i, i64(1))

	// A sequence beyond the log is clamped to the latest commit, and a view is
	// refused rather than half read.
	run_done(t, store, "CREATE VIEW v AS SELECT id FROM t")
	dropped_result_10930, view_err := db.sql_execute(store, "SELECT * FROM v AS OF 1")
	defer db.error_free(&view_err)
	defer db.sql_result_destroy(&dropped_result_10930)
	testing.expect_value(t, view_err.kind, db.Error_Kind.Sql_Unsupported)
}

@(test)
test_window_frames :: proc(t: ^testing.T) {
	// A ROWS frame decides which rows the aggregate sees for each row; without
	// one, the default (partition start to the last peer) stays as it was.
	store := fresh_db(t, "window_frames")
	if store == nil do return
	defer cleanup_db(store, "window_frames")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 10), (2, 20), (3, 30), (4, 40), (5, 50)")
	column :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> [dynamic]i64 {
		result := run(t, store, sql)
		out := make([dynamic]i64, 0, len(result.rows))
		for row in result.rows do append(&out, row[0].i)
		db.sql_result_destroy(&result)
		return out
	}

	moving := column(
		t,
		store,
		"SELECT SUM(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM t ORDER BY id",
	)
	testing.expect_value(t, len(moving), 5)
	if len(moving) == 5 {
		testing.expect_value(t, moving[0], i64(30))
		testing.expect_value(t, moving[1], i64(60))
		testing.expect_value(t, moving[2], i64(90))
		testing.expect_value(t, moving[3], i64(120))
		testing.expect_value(t, moving[4], i64(90))
	}
	delete(moving)

	running := column(
		t,
		store,
		"SELECT COUNT(*) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t ORDER BY id",
	)
	testing.expect_value(t, len(running), 5)
	if len(running) == 5 {
		for value, i in running do testing.expect_value(t, value, i64(i + 1))
	}
	delete(running)

	whole := run(
		t,
		store,
		"SELECT AVG(v) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM t ORDER BY id",
	)
	testing.expect_value(t, len(whole.rows), 5)
	for row in whole.rows {
		average, _ := db.value_to_f64(row[0])
		testing.expect_value(t, average, f64(30))
	}
	db.sql_result_destroy(&whole)

	// The frame moves the value functions too.
	lasts := column(
		t,
		store,
		"SELECT LAST_VALUE(v) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) FROM t ORDER BY id",
	)
	testing.expect_value(t, len(lasts), 5)
	if len(lasts) == 5 {
		for value in lasts do testing.expect_value(t, value, i64(50))
	}
	delete(lasts)

	firsts := column(
		t,
		store,
		"SELECT FIRST_VALUE(v) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 2 PRECEDING) FROM t ORDER BY id",
	)
	testing.expect_value(t, len(firsts), 5)
	if len(firsts) == 5 {
		// The frame is empty for the first two rows, then two rows back.
		testing.expect_value(t, firsts[0], i64(0))
		testing.expect_value(t, firsts[1], i64(0))
		testing.expect_value(t, firsts[2], i64(10))
		testing.expect_value(t, firsts[3], i64(20))
		testing.expect_value(t, firsts[4], i64(30))
	}
	delete(firsts)

	// An empty frame is an empty group: count 0, sum NULL.
	empties := run(
		t,
		store,
		"SELECT COUNT(*) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 2 PRECEDING), SUM(v) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 2 PRECEDING) FROM t ORDER BY id",
	)
	testing.expect_value(t, len(empties.rows), 5)
	if len(empties.rows) == 5 {
		testing.expect_value(t, empties.rows[0][0].i, i64(0))
		testing.expect_value(t, empties.rows[0][1].kind, db.Value_Kind.Null)
		testing.expect_value(t, empties.rows[3][0].i, i64(1))
		testing.expect_value(t, empties.rows[3][1].i, i64(20))
	}
	db.sql_result_destroy(&empties)

	// The shorthand form ends at the current row, like the SQL standard.
	shorthand := column(
		t,
		store,
		"SELECT SUM(v) OVER (ORDER BY id ROWS 1 PRECEDING) FROM t ORDER BY id",
	)
	testing.expect_value(t, len(shorthand), 5)
	if len(shorthand) == 5 {
		testing.expect_value(t, shorthand[0], i64(10))
		testing.expect_value(t, shorthand[1], i64(30))
		testing.expect_value(t, shorthand[4], i64(90))
	}
	delete(shorthand)

	// Partitioning still applies before the frame.
	partitioned := column(
		t,
		store,
		"SELECT SUM(v) OVER (PARTITION BY id % 2 ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t ORDER BY id",
	)
	testing.expect_value(t, len(partitioned), 5)
	if len(partitioned) == 5 {
		testing.expect_value(t, partitioned[0], i64(10))
		testing.expect_value(t, partitioned[1], i64(20))
		testing.expect_value(t, partitioned[2], i64(40))
		testing.expect_value(t, partitioned[3], i64(60))
		testing.expect_value(t, partitioned[4], i64(80))
	}
	delete(partitioned)

	// A RANGE frame is measured in the ordering value, not refused: the answers are
	// checked against sqlite3 in test_window_range_and_groups_frames.
	range_result, range_exec_err := db.sql_execute(
		store,
		"SELECT SUM(v) OVER (ORDER BY id RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t",
	)
	testing.expect(t, db.error_ok(range_exec_err))
	db.sql_result_destroy(&range_result)
	// A start of UNBOUNDED FOLLOWING is not a frame.
	bad_start := run_error(
		t,
		store,
		"SELECT SUM(v) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED FOLLOWING AND CURRENT ROW) FROM t",
	)
	testing.expect_value(t, bad_start.kind, db.Error_Kind.Invalid_Argument)
}

@(test)
test_before_triggers :: proc(t: ^testing.T) {
	// A BEFORE trigger runs while the row is still only proposed: its body sees NEW,
	// the row is not written yet, and a body that fails stops the write. The same
	// statements through sqlite3 give the same order and the same log.
	store := fresh_db(t, "trigger_before")
	if store == nil do return
	defer cleanup_db(store, "trigger_before")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
	run_done(t, store, "CREATE TABLE log (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL)")
	run_done(t, store, `
		CREATE TRIGGER t_before BEFORE INSERT ON t
		BEGIN INSERT INTO log (note) VALUES ('before ' || NEW.v); END`)
	run_done(t, store, `
		CREATE TRIGGER t_after AFTER INSERT ON t
		BEGIN INSERT INTO log (note) VALUES ('after ' || NEW.v); END`)
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 10)")

	run_done(t, store, `
		CREATE TRIGGER t_update BEFORE UPDATE ON t
		BEGIN INSERT INTO log (note) VALUES ('upd ' || OLD.v || '->' || NEW.v); END`)
	run_done(t, store, "UPDATE t SET v = 11 WHERE id = 1")
	run_done(t, store, `
		CREATE TRIGGER t_delete BEFORE DELETE ON t
		BEGIN INSERT INTO log (note) VALUES ('del ' || OLD.v); END`)
	run_done(t, store, "DELETE FROM t WHERE id = 1")

	expected := [4]string{"before 10", "after 10", "upd 10->11", "del 11"}
	log_result, log_err := db.sql_execute(store, "SELECT note FROM log ORDER BY id")
	if testing.expectf(t, db.error_ok(log_err), "%s", log_err.message) {
		testing.expect_value(t, len(log_result.rows), 4)
		for want, i in expected {
			if i < len(log_result.rows) do testing.expect_value(t, log_result.rows[i][0].s, want)
		}
	}
	db.sql_result_destroy(&log_result)

	// A BEFORE trigger whose body fails stops the insert, and the rows its body
	// wrote are gone with the statement.
	run_done(t, store, "CREATE TABLE guard (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
	run_done(t, store, `
		CREATE TRIGGER guard_stop BEFORE INSERT ON guard WHEN NEW.v > 0
		BEGIN INSERT INTO log (note) VALUES ('refused'); INSERT INTO nope (x) VALUES (1); END`)
	refused := run_error(t, store, "INSERT INTO guard (id, v) VALUES (1, 1)")
	testing.expect(t, refused.kind != .None)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM guard").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log WHERE note = 'refused'").i, i64(0))

	// The WHEN condition skips the trigger without an error.
	allowed := run_error(t, store, "INSERT INTO guard (id, v) VALUES (2, 0)")
	testing.expect(t, db.error_ok(allowed))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM guard").i, i64(1))
}

@(test)
test_trigger_when :: proc(t: ^testing.T) {
	// WHEN decides whether a trigger fires for a row, with NEW and OLD in scope.
	store := fresh_db(t, "trigger_when")
	if store == nil do return
	defer cleanup_db(store, "trigger_when")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
	run_done(t, store, "CREATE TABLE audit (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL)")

	run(
		t,
		store,
		"CREATE TRIGGER big_insert AFTER INSERT ON t WHEN NEW.v > 10 BEGIN INSERT INTO audit (note) VALUES ('insert') END",
	)
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 5)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(0))
	run_done(t, store, "INSERT INTO t (id, v) VALUES (2, 20)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(1))

	// UPDATE sees both rows: only a real increase is audited.
	run(
		t,
		store,
		"CREATE TRIGGER rise AFTER UPDATE ON t WHEN OLD.v < NEW.v BEGIN INSERT INTO audit (note) VALUES ('rise') END",
	)
	run_done(t, store, "UPDATE t SET v = 4 WHERE id = 2")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(1))
	run_done(t, store, "UPDATE t SET v = 30 WHERE id = 2")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(2))

	// DELETE has OLD only.
	run(
		t,
		store,
		"CREATE TRIGGER gone AFTER DELETE ON t WHEN OLD.v >= 10 BEGIN INSERT INTO audit (note) VALUES ('gone') END",
	)
	run_done(t, store, "DELETE FROM t WHERE id = 1")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(2))
	run_done(t, store, "DELETE FROM t WHERE id = 2")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit").i, i64(3))

	// A condition that is not a boolean still decides: NULL and 0 do not fire.
	run_done(t, store, "INSERT INTO t (id, v) VALUES (3, 50)")
	run(
		t,
		store,
		"CREATE TRIGGER never AFTER INSERT ON t WHEN NULL BEGIN INSERT INTO audit (note) VALUES ('never') END",
	)
	run_done(t, store, "INSERT INTO t (id, v) VALUES (4, 60)")
	// big_insert fired for both rows; the NULL condition did not.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit WHERE note = 'insert'").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM audit WHERE note = 'never'").i, i64(0))

	// A bad condition is refused at CREATE TRIGGER, not discovered later.
	dropped_result_11281, bad := db.sql_execute(
		store,
		"CREATE TRIGGER broken AFTER INSERT ON t WHEN NEW.v > BEGIN INSERT INTO audit (note) VALUES ('x') END",
	)
	defer db.error_free(&bad)
	defer db.sql_result_destroy(&dropped_result_11281)
	testing.expect(t, !db.error_ok(bad))

	// A catalog written before WHEN existed gets the column on first use.
	run_done(t, store, "DROP TRIGGER big_insert")
	run_done(t, store, "DROP TABLE _triggers")
	run_done(t, store, "CREATE TABLE _triggers (name TEXT PRIMARY KEY NOT NULL, table_name TEXT NOT NULL, event TEXT NOT NULL, timing TEXT NOT NULL, body TEXT NOT NULL)")
	run(
		t,
		store,
		"CREATE TRIGGER migrated AFTER INSERT ON t WHEN NEW.v > 100 BEGIN INSERT INTO audit (note) VALUES ('migrated') END",
	)
	run_done(t, store, "INSERT INTO t (id, v) VALUES (5, 200)")
	testing.expect_value(
		t,
		scalar(t, store, "SELECT count(*) FROM audit WHERE note = 'migrated'").i,
		i64(1),
	)
}

@(test)
test_alter_rename_column :: proc(t: ^testing.T) {
	// A column can be renamed in place; indexes follow because they refer to
	// columns by position, not by name.
	store := fresh_db(t, "rename_column")
	if store == nil do return
	defer os.remove_all("_test_rename_column")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT NOT NULL, score INTEGER)")
	run_done(t, store, "CREATE UNIQUE INDEX t_label ON t (label)")
	run_done(t, store, "INSERT INTO t (id, label, score) VALUES (1, 'a', 10), (2, 'b', 20)")

	run_done(t, store, "ALTER TABLE t RENAME COLUMN label TO name")
	testing.expect_value(t, scalar(t, store, "SELECT name FROM t WHERE id = 1").s, "a")
	// The optional COLUMN and the missing COLUMN spelling are the same statement.
	run_done(t, store, "ALTER TABLE t RENAME score TO points")
	testing.expect_value(t, scalar(t, store, "SELECT sum(points) FROM t").i, i64(30))
	// The unique index still rejects a duplicate through the new name.
	dropped_result_11321, duplicate := db.sql_execute(store, "INSERT INTO t (id, name, points) VALUES (3, 'a', 30)")
	defer db.error_free(&duplicate)
	defer db.sql_result_destroy(&dropped_result_11321)
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Unique)
	// The old name is gone.
	dropped_result_11324, old_name := db.sql_execute(store, "SELECT label FROM t")
	defer db.error_free(&old_name)
	defer db.sql_result_destroy(&dropped_result_11324)
	testing.expect_value(t, old_name.kind, db.Error_Kind.Column_Not_Found)

	// Renaming to an existing column, or renaming a missing one, is refused.
	dropped_result_11234, clash := db.sql_execute(store, "ALTER TABLE t RENAME COLUMN name TO points")
	defer db.error_free(&clash)
	defer db.sql_result_destroy(&dropped_result_11234)
	testing.expect_value(t, clash.kind, db.Error_Kind.Invalid_Argument)
	dropped_result_11236, missing := db.sql_execute(store, "ALTER TABLE t RENAME COLUMN nope TO other")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_11236)
	testing.expect_value(t, missing.kind, db.Error_Kind.Column_Not_Found)

	// A virtual table keeps the column names its index was built with.
	run_done(t, store, "CREATE VIRTUAL TABLE docs USING fts5(body)")
	dropped_result_11241, virtual := db.sql_execute(store, "ALTER TABLE docs RENAME COLUMN body TO text")
	defer db.error_free(&virtual)
	defer db.sql_result_destroy(&dropped_result_11241)
	testing.expect_value(t, virtual.kind, db.Error_Kind.Sql_Unsupported)

	// The rename is in the log: a reopen sees the new schema.
	db.store_close(store)
	reopened, open_err := db.store_open("_test_rename_column", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	defer cleanup_db(reopened, "rename_column")
	testing.expect_value(t, scalar(t, reopened, "SELECT count(name) FROM t").i, i64(2))
}

@(test)
test_connection_identity :: proc(t: ^testing.T) {
	// The identity belongs to the connection: authenticating on one client must
	// not lend its rows to another, and two clients keep their own view.
	store, host := fresh_host(t, "conn_identity")
	if store == nil do return
	defer destroy_host(store, host, "conn_identity")
	ana := "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
	luis := "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
	run_done(t, store, "CREATE TABLE note (id INTEGER PRIMARY KEY AUTOINCREMENT, owner IDENTITY NOT NULL, body TEXT NOT NULL)")
	insert := fmt.tprintf(
		"INSERT INTO note (owner, body) VALUES ('%s', 'a1'), ('%s', 'a2'), ('%s', 'l1')",
		ana, ana, luis,
	)
	run_done(t, store, insert)
	run_done(t, store, "CREATE POLICY note_owner ON note USING (owner = current_identity())")

	ana_identity, _ := db.identity_parse(ana)
	luis_identity, _ := db.identity_parse(luis)
	host.now_us = i64(1_000_000)
	ana_token, ana_err := db.host_issue_token(host, ana_identity, 0)
	defer delete(ana_token)
	luis_token, luis_err := db.host_issue_token(host, luis_identity, 0)
	defer delete(luis_token)
	testing.expect(t, db.error_ok(ana_err) && db.error_ok(luis_err))

	count_for :: proc(t: ^testing.T, host: ^db.Host, owner: u64, sql: string) -> i64 {
		request := db.wire_encode_query(sql, nil)
		defer delete(request)
		response := db.wire_request_owned(host, request, owner)
		defer delete(response)
		result, err := db.wire_decode_result(response, context.allocator)
		if !testing.expectf(t, db.error_ok(err), "owner %d: %s", owner, err.message) do return -1
		defer db.sql_result_destroy(&result)
		if len(result.rows) == 0 || len(result.rows[0]) == 0 do return -1
		return result.rows[0][0].i
	}

	testing.expect(t, db.host_client_connect(host, 1))
	testing.expect(t, db.host_client_connect(host, 2))
	// Before authenticating, a client sees what the default identity sees: none
	// of the rows. The store starts with no identity, so this is the baseline.
	testing.expect_value(t, count_for(t, host, 1, "SELECT count(*) FROM note"), i64(0))

	// Client 1 authenticates as Ana.
	auth := db.wire_encode_auth(ana_token)
	defer delete(auth)
	testing.expect_value(t, wire_ask_owned(host, auth, 1), db.WIRE_RESULT)
	testing.expect_value(t, count_for(t, host, 1, "SELECT count(*) FROM note"), i64(2))

	// Client 2 is still unauthenticated: it must not inherit Ana.
	testing.expect_value(t, count_for(t, host, 2, "SELECT count(*) FROM note"), i64(0))
	// Authenticating client 2 as Luis gives it his two rows and leaves client 1
	// with Ana's.
	luis_auth := db.wire_encode_auth(luis_token)
	defer delete(luis_auth)
	testing.expect_value(t, wire_ask_owned(host, luis_auth, 2), db.WIRE_RESULT)
	testing.expect_value(t, count_for(t, host, 2, "SELECT count(*) FROM note"), i64(1))
	testing.expect_value(t, count_for(t, host, 1, "SELECT count(*) FROM note"), i64(2))
	testing.expect_value(
		t,
		count_for(t, host, 1, "SELECT count(*) FROM note WHERE owner = current_identity()"),
		i64(2),
	)

	// A bad token leaves the caller as it was.
	nope_auth := db.wire_encode_auth("nope")
	defer delete(nope_auth)
	testing.expect_value(t, wire_ask_owned(host, nope_auth, 2), db.WIRE_ERROR)
	testing.expect_value(t, count_for(t, host, 2, "SELECT count(*) FROM note"), i64(1))

	// A new, unauthenticated connection starts from the default again.
	testing.expect(t, db.host_client_connect(host, 3))
	testing.expect_value(t, count_for(t, host, 3, "SELECT count(*) FROM note"), i64(0))

	// SET identity inside a request persists for that client only.
	set := db.wire_encode_query(fmt.tprintf("SET identity = '%s'", ana), nil)
	defer delete(set)
	testing.expect_value(t, wire_ask_owned(host, set, 3), db.WIRE_RESULT)
	testing.expect_value(t, count_for(t, host, 3, "SELECT count(*) FROM note"), i64(2))
	testing.expect_value(t, count_for(t, host, 2, "SELECT count(*) FROM note"), i64(1))
}

@(test)
test_paged_table_roundtrip :: proc(t: ^testing.T) {
	// A table whose rows live in a page file behaves like any other: inserts,
	// lookups by key, updates, deletes, constraints and a reopen. The row map
	// stays empty and the pool stays small, which is the point of the exercise.
	path := "_test_paged_roundtrip"
	os.remove_all(path)
	defer os.remove_all(path)
	store, open_err := db.store_open(path, {
		persistent = true,
		create = true,
		durable = false,
		paged_tables = true,
		page_frames = 4,
	})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	closed := false
	defer if !closed do db.store_close(store)

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)")
	body: strings.Builder
	strings.builder_init(&body)
	defer strings.builder_destroy(&body)
	strings.write_string(&body, "INSERT INTO item (id, name, qty) VALUES ")
	for i in 0 ..< 400 {
		if i > 0 do strings.write_string(&body, ", ")
		fmt.sbprintf(&body, "(%d, 'name-%d', %d)", i, i, i)
	}
	run_done(t, store, strings.to_string(body))

	table, table_err := db.store_table(store, "item")
	testing.expect(t, db.error_ok(table_err))
	testing.expect(t, table.paged != nil)
	testing.expect_value(t, len(table.rows), 0)
	stats := db.page_rows_stats(table.paged)
	testing.expectf(t, stats.pages > 4, "the file holds %d pages", stats.pages)
	testing.expectf(t, stats.resident <= 4, "the pool holds %d pages", stats.resident)
	testing.expect_value(t, stats.rows, u64(400))

	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM item").i, i64(400))
	testing.expect_value(t, scalar(t, store, "SELECT name FROM item WHERE id = 150").s, "name-150")
	testing.expect_value(t, scalar(t, store, "SELECT max(qty) FROM item").i, i64(399))

	run_done(t, store, "UPDATE item SET qty = 999 WHERE id = 150")
	testing.expect_value(t, scalar(t, store, "SELECT qty FROM item WHERE id = 150").i, i64(999))
	testing.expect_value(t, scalar(t, store, "SELECT qty FROM item WHERE id = 151").i, i64(151))

	run_done(t, store, "DELETE FROM item WHERE id = 150")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM item").i, i64(399))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM item WHERE id = 150").i, i64(0))

	duplicate := run_error(t, store, "INSERT INTO item (id, name, qty) VALUES (200, 'dup', 1)")
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Primary_Key)

	// An in-place schema change cannot stream over pages yet, so it is refused
	// instead of silently dropping the rows.
	alter := run_error(t, store, "ALTER TABLE item ADD COLUMN extra TEXT")
	testing.expect_value(t, alter.kind, db.Error_Kind.Sql_Unsupported)
	as_of := run_error(t, store, "SELECT * FROM item AS OF 1")
	testing.expect_value(t, as_of.kind, db.Error_Kind.Sql_Unsupported)

	// A transaction that writes and rolls back leaves the pages untouched.
	tx := db.tx_begin_write(store)
	dropped_result_11651, delete_err := db.sql_execute_in_tx(tx, "DELETE FROM item")
	defer db.error_free(&delete_err)
	defer db.sql_result_destroy(&dropped_result_11651)
	testing.expect(t, db.error_ok(delete_err))
	inside, inside_err := db.sql_execute_in_tx(tx, "SELECT count(*) FROM item")
	testing.expect(t, db.error_ok(inside_err))
	testing.expect_value(t, inside.rows[0][0].i, i64(0))
	db.sql_result_destroy(&inside)
	db.tx_rollback(tx)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM item").i, i64(399))

	// A simple query streams over the pages: it never collects the table, which
	// is what keeps the memory bounded. The counter records the path taken.
	streams_before := store.stream_scans
	aggregated := run(t, store, "SELECT count(*), sum(qty), min(qty), max(qty), avg(qty) FROM item")
	testing.expect_value(t, len(aggregated.rows), 1)
	testing.expect_value(t, aggregated.rows[0][0].i, i64(399))
	testing.expect_value(t, aggregated.rows[0][1].i, i64(79650))
	testing.expect_value(t, aggregated.rows[0][2].i, i64(0))
	testing.expect_value(t, aggregated.rows[0][3].i, i64(399))
	testing.expect_value(t, aggregated.rows[0][4].kind, db.Value_Kind.Float)
	testing.expectf(
		t,
		abs(aggregated.rows[0][4].f - 79650.0 / 399.0) < 0.0001,
		"avg is %v",
		aggregated.rows[0][4].f,
	)
	db.sql_result_destroy(&aggregated)
	testing.expect_value(t, store.stream_scans, streams_before + 1)

	// LIMIT stops the scan and the projection runs per row.
	limited := run(t, store, "SELECT id FROM item LIMIT 5")
	testing.expect_value(t, len(limited.rows), 5)
	db.sql_result_destroy(&limited)
	testing.expect_value(t, store.stream_scans, streams_before + 2)

	// ORDER BY needs every row, so it takes the materializing path.
	ordered := run(t, store, "SELECT id FROM item ORDER BY id DESC LIMIT 3")
	testing.expect_value(t, len(ordered.rows), 3)
	testing.expect_value(t, ordered.rows[0][0].i, i64(399))
	db.sql_result_destroy(&ordered)
	testing.expect_value(t, store.stream_scans, streams_before + 2)

	// LIMIT 0 returns nothing, for a projection and for the single aggregate row.
	empty_limit := run(t, store, "SELECT id FROM item LIMIT 0")
	testing.expect_value(t, len(empty_limit.rows), 0)
	db.sql_result_destroy(&empty_limit)
	empty_aggregate := run(t, store, "SELECT count(*) FROM item LIMIT 0")
	testing.expect_value(t, len(empty_aggregate.rows), 0)
	db.sql_result_destroy(&empty_aggregate)
	skipped_aggregate := run(t, store, "SELECT count(*) FROM item OFFSET 1")
	testing.expect_value(t, len(skipped_aggregate.rows), 0)
	db.sql_result_destroy(&skipped_aggregate)

	// An aggregate over no rows is still one row, with the neutral values.
	empty := run(t, store, "SELECT count(*), sum(qty) FROM item WHERE id = 9999")
	testing.expect_value(t, len(empty.rows), 1)
	testing.expect_value(t, empty.rows[0][0].i, i64(0))
	testing.expect_value(t, empty.rows[0][1].kind, db.Value_Kind.Null)
	db.sql_result_destroy(&empty)

	// group_concat accumulates while streaming when no index answers the filter.
	concat := run(t, store, "SELECT group_concat(name) FROM item WHERE qty IN (0, 1, 2)")
	testing.expect_value(t, concat.rows[0][0].s, "name-0,name-1,name-2")
	db.sql_result_destroy(&concat)

	db.store_close(store)
	closed = true

	// The page files are a cache: reopening discards them and replays the log,
	// with a different pool size.
	again, again_err := db.store_open(path, {
		persistent = true,
		paged_tables = true,
		page_frames = 2,
	})
	if !testing.expectf(t, db.error_ok(again_err), "reopen: %s", again_err.message) do return
	defer db.store_close(again)
	rebuilt, rebuilt_err := db.store_table(again, "item")
	testing.expect(t, db.error_ok(rebuilt_err))
	testing.expect(t, rebuilt.paged != nil)
	testing.expect_value(t, len(rebuilt.rows), 0)
	testing.expect_value(t, db.page_rows_stats(rebuilt.paged).resident <= 2, true)
	testing.expect_value(t, scalar(t, again, "SELECT count(*) FROM item").i, i64(399))
	testing.expect_value(t, scalar(t, again, "SELECT name FROM item WHERE id = 399").s, "name-399")
	testing.expect_value(t, scalar(t, again, "SELECT qty FROM item WHERE id = 151").i, i64(151))
}

@(test)
test_paged_table_churn :: proc(t: ^testing.T) {
	// Updating and deleting rows leaves holes in the pages. Compaction reclaims
	// them, and it must not move the slot a row is indexed by: this walks enough
	// churn to force compaction many times and then checks every value.
	path := "_test_paged_churn"
	os.remove_all(path)
	defer os.remove_all(path)
	store, open_err := db.store_open(path, {
		persistent = true,
		create = true,
		durable = false,
		paged_tables = true,
		page_frames = 4,
	})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)

	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, v TEXT, n INTEGER)")
	body: strings.Builder
	strings.builder_init(&body)
	defer strings.builder_destroy(&body)
	strings.write_string(&body, "INSERT INTO c (id, v, n) VALUES ")
	for id in 0 ..< 300 {
		if id > 0 do strings.write_string(&body, ", ")
		fmt.sbprintf(&body, "(%d, 'round-0-%d', %d)", id, id, id)
	}
	run_done(t, store, strings.to_string(body))

	for round in 1 ..< 7 {
		tx := db.tx_begin_write(store)
		for id in 0 ..< 300 {
			statement := fmt.tprintf(
				"UPDATE c SET v = 'round-%d-%d', n = %d WHERE id = %d",
				round,
				id,
				round * 1000 + id,
				id,
			)
			dropped_result_11776, update_err := db.sql_execute_in_tx(tx, statement)
			defer db.error_free(&update_err)
			defer db.sql_result_destroy(&dropped_result_11776)
			if !db.error_ok(update_err) {
				db.tx_rollback(tx)
				testing.expectf(t, db.error_ok(update_err), "update %d: %s", id, update_err.message)
				return
			}
		}
		if commit_err := db.tx_commit(tx); !testing.expectf(t, db.error_ok(commit_err), "commit: %s", commit_err.message) {
			return
		}
	}

	tx := db.tx_begin_write(store)
	for id in 0 ..< 300 {
		if id % 2 != 0 do continue
		dropped_result_11791, delete_err := db.sql_execute_in_tx(tx, fmt.tprintf("DELETE FROM c WHERE id = %d", id))
		defer db.error_free(&delete_err)
		defer db.sql_result_destroy(&dropped_result_11791)
		testing.expect(t, db.error_ok(delete_err))
	}
	for id in 1000 ..< 1150 {
		statement := fmt.tprintf("INSERT INTO c (id, v, n) VALUES (%d, 'new-%d', %d)", id, id, id)
		dropped_result_11796, insert_err := db.sql_execute_in_tx(tx, statement)
		defer db.error_free(&insert_err)
		defer db.sql_result_destroy(&dropped_result_11796)
		testing.expect(t, db.error_ok(insert_err))
	}
	testing.expect(t, db.error_ok(db.tx_commit(tx)))

	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM c").i, i64(300))
	for id in 0 ..< 300 {
		if id % 2 == 0 {
			visible := scalar(t, store, fmt.tprintf("SELECT count(*) FROM c WHERE id = %d", id))
			testing.expect_value(t, visible.i, i64(0))
			continue
		}
		row := run(t, store, fmt.tprintf("SELECT v, n FROM c WHERE id = %d", id))
		testing.expectf(t, len(row.rows) == 1, "row %d is missing", id)
		if len(row.rows) == 1 {
			testing.expect_value(t, row.rows[0][0].s, fmt.tprintf("round-6-%d", id))
			testing.expect_value(t, row.rows[0][1].i, i64(6000 + id))
		}
		db.sql_result_destroy(&row)
	}
	for id in 1000 ..< 1150 {
		row := run(t, store, fmt.tprintf("SELECT v, n FROM c WHERE id = %d", id))
		testing.expectf(t, len(row.rows) == 1, "new row %d is missing", id)
		if len(row.rows) == 1 {
			testing.expect_value(t, row.rows[0][0].s, fmt.tprintf("new-%d", id))
			testing.expect_value(t, row.rows[0][1].i, i64(id))
		}
		db.sql_result_destroy(&row)
	}
	table, table_err := db.store_table(store, "c")
	testing.expect(t, db.error_ok(table_err))
	testing.expect_value(t, db.page_rows_stats(table.paged).rows, u64(300))
	// The directory is on disk now, so its entry count comes from the tree.
	testing.expect_value(t, db.ordered_entries(table.paged.dir), u64(300))
}

@(test)
test_paged_commit_survives_a_failed_write :: proc(t: ^testing.T) {
	// One transaction commits while a write fails at every possible point: the
	// log record, a data page, the page header. A commit that reported success
	// must have every row after a reopen (the log holds them and the pages are
	// rebuilt from it); a commit that reported failure must have none. The test
	// requires that some write index actually fired, so it cannot pass by never
	// taking the failure path.
	memory := db.vfs_memory_new()
	defer db.vfs_memory_destroy(memory)
	fault := db.vfs_fault_new(memory)
	defer db.vfs_fault_destroy(fault)

	fired_cases := 0
	for n in 1 ..= 40 {
		path := fmt.aprintf("_paged_fault_%d", n)
		defer delete(path)
		db.vfs_fault_arm(fault, .Write, u64(n))
		store, open_err := db.store_open(path, {
			persistent = true,
			create = true,
			durable = true,
			vfs = fault,
			paged_tables = true,
			page_frames = 2,
		})
		if !db.error_ok(open_err) {
			db.error_free(&open_err)
			continue
		}
		if !db.error_ok(run_err(t, store, "CREATE TABLE p (id INTEGER PRIMARY KEY, v TEXT)")) {
			db.store_close(store)
			continue
		}
		committed := false
		armed := true
		tx := db.tx_begin_write(store)
		for i in 0 ..< 50 {
			statement := fmt.tprintf("INSERT INTO p (v) VALUES ('row-%d')", i)
			inserted, insert_err := db.sql_execute_in_tx(tx, statement)
			db.sql_result_destroy(&inserted)
			defer db.error_free(&insert_err)
			if !db.error_ok(insert_err) {
				// The fault fired while staging: nothing to commit.
				db.tx_rollback(tx)
				armed = false
				break
			}
		}
		if armed {
			commit_err := db.tx_commit(tx)
			committed = db.error_ok(commit_err)
			db.error_free(&commit_err)
			if db.vfs_fault_fired(fault) do fired_cases += 1
		}
		db.vfs_fault_arm(fault, .Write, 0)
		db.store_close(store)

		// Reopen without the fault: the log and the page files are whatever the
		// failed writes left behind.
		reopened, reopen_err := db.store_open(path, {
			persistent = true,
			create = false,
			durable = false,
			vfs = memory,
			paged_tables = true,
			page_frames = 2,
		})
		if !testing.expectf(t, db.error_ok(reopen_err), "n=%d reopen: %s", n, reopen_err.message) do continue
		result, count_err := db.sql_execute(reopened, "SELECT count(*) FROM p")
		if !testing.expectf(t, db.error_ok(count_err), "n=%d count: %s", n, count_err.message) {
			db.store_close(reopened)
			continue
		}
		count := result.rows[0][0].i
		db.sql_result_destroy(&result)
		db.store_close(reopened)
		expected := committed ? i64(50) : i64(0)
		testing.expectf(
			t,
			count == expected,
			"n=%d: the commit %s but %d rows survived",
			n,
			committed ? "reported success" : "reported failure",
			count,
		)
	}
	testing.expectf(t, fired_cases > 0, "no write index fired during a commit")
}

@(test)
test_paged_index_pages :: proc(t: ^testing.T) {
	// A paged table keeps its index keys in the index file, not in the table
	// arena: the point-lookup path, the range path, constraints, updates,
	// deletes, TRUNCATE and a reopen all have to work through those pages.
	path := "_test_paged_index"
	os.remove_all(path)
	defer os.remove_all(path)
	options := db.Store_Options {
		persistent   = true,
		create       = true,
		durable      = false,
		paged_tables = true,
		page_frames  = 4,
	}
	store, open_err := db.store_open(path, options)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	closed := false
	defer if !closed do db.store_close(store)

	run_done(t, store, "CREATE TABLE doc (id INTEGER PRIMARY KEY, slug TEXT NOT NULL, body TEXT)")
	run_done(t, store, "CREATE INDEX doc_slug ON doc (slug)")
	total :: 3000
	body: strings.Builder
	strings.builder_init(&body)
	defer strings.builder_destroy(&body)
	strings.write_string(&body, "INSERT INTO doc (id, slug, body) VALUES ")
	// id_for_slug remembers which row took which key, so every expectation below
	// is derived from the data instead of guessed.
	id_for_slug := make([]int, total)
	defer delete(id_for_slug)
	for i in 0 ..< total {
		scrambled := (i * 7919) % total
		id_for_slug[scrambled] = i
		if i > 0 do strings.write_string(&body, ", ")
		fmt.sbprintf(&body, "(%d, 'slug-%05d', 'body %d')", i, scrambled, i)
	}
	run_done(t, store, strings.to_string(body))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM doc").i, i64(total))

	table, table_err := db.store_table(store, "doc")
	if !testing.expect(t, db.error_ok(table_err)) do return

	// The keys are in pages: memory per index is the pool, not one entry per row.
	memory := db.table_memory(table)
	testing.expect_value(t, memory.rows, total)
	testing.expect_value(t, memory.index_entries, 2 * total)
	testing.expect(t, memory.index_bytes > 0)
	testing.expect(t, memory.index_bytes <= 2 * (db.INDEX_PAGE_FRAMES + 1) * db.PAGE_SIZE)

	// A point lookup through the index visits a handful of rows, not the table.
	db.store_reset_rows_scanned(store)
	found := scalar(t, store, "SELECT id FROM doc WHERE slug = 'slug-01234'")
	testing.expect_value(t, found.i, i64(id_for_slug[1234]))
	testing.expectf(t, db.store_rows_scanned(store) <= 4, "point lookup scanned %d", db.store_rows_scanned(store))

	// Range scan across pages, both ends included as SQL says.
	range_count := scalar(t, store, "SELECT count(*) FROM doc WHERE slug >= 'slug-01000' AND slug < 'slug-01100'")
	testing.expect_value(t, range_count.i, i64(100))

	// The primary key index answers too, and it refuses a duplicate.
	old_slug := fmt.tprintf("slug-%05d", (77 * 7919) % total)
	testing.expect_value(t, scalar(t, store, "SELECT slug FROM doc WHERE id = 77").s, old_slug)
	duplicate := run_error(t, store, "INSERT INTO doc (id, slug, body) VALUES (77, 'another', 'x')")
	testing.expect_value(t, duplicate.kind, db.Error_Kind.Duplicate_Primary_Key)

	// An update moves the entry: the old key stops matching and the new one works.
	run_done(t, store, "UPDATE doc SET slug = 'slug-99999' WHERE id = 77")
	testing.expect_value(t, scalar(t, store, fmt.tprintf("SELECT count(*) FROM doc WHERE slug = '%s'", old_slug)).i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT id FROM doc WHERE slug = 'slug-99999'").i, i64(77))

	// A delete removes it from both indexes.
	run_done(t, store, "DELETE FROM doc WHERE id = 77")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM doc WHERE slug = 'slug-99999'").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM doc WHERE id = 77").i, i64(0))

	// TRUNCATE empties the index files and the table answers again afterwards.
	run_done(t, store, "TRUNCATE TABLE doc")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM doc").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM doc WHERE slug = 'slug-00001'").i, i64(0))
	run_done(t, store, "INSERT INTO doc (id, slug, body) VALUES (1, 'slug-00001', 'reborn')")
	testing.expect_value(t, scalar(t, store, "SELECT id FROM doc WHERE slug = 'slug-00001'").i, i64(1))
	run_done(t, store, "DELETE FROM doc WHERE id = 1")

	// Reopen: the index files are discarded with the table pages and rebuilt by
	// the replay, so a lookup must find the rows the log holds.
	run_done(t, store, "INSERT INTO doc (id, slug, body) VALUES (5, 'kept', 'x')")
	db.store_close(store)
	closed = true
	reopened, reopen_err := db.store_open(path, options)
	if !testing.expectf(t, db.error_ok(reopen_err), "reopen: %s", reopen_err.message) do return
	defer db.store_close(reopened)
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM doc").i, i64(1))
	testing.expect_value(t, scalar(t, reopened, "SELECT id FROM doc WHERE slug = 'kept'").i, i64(5))

	// An index created after a reopen walks rows that the replay put in pages: the
	// visitor needs the table pointer, which the first version left unset.
	run_done(t, reopened, "CREATE INDEX doc_body ON doc (body)")
	testing.expect_value(t, scalar(t, reopened, "SELECT id FROM doc WHERE body = 'x'").i, i64(5))

	// Dropping the index closes its file and the table keeps answering by scan.
	reopened_table, reopened_err := db.store_table(reopened, "doc")
	if testing.expect(t, db.error_ok(reopened_err)) {
		testing.expect_value(t, db.table_index_count(reopened_table, 1), u64(1))
	}
	run_done(t, reopened, "DROP INDEX doc_slug")
	testing.expect_value(t, scalar(t, reopened, "SELECT id FROM doc WHERE slug = 'kept'").i, i64(5))
}

@(test)
test_replay_streams_the_log :: proc(t: ^testing.T) {
	// Opening a database must not read the whole log into memory. This builds a
	// log larger than the stream buffer out of many small commits, reopens it and
	// checks the replay never had to grow past its starting buffer, then tears the
	// tail off and checks the record that was cut is the only one dropped.
	path := "_test_replay_stream"
	os.remove_all(path)
	defer os.remove_all(path)
	options := db.Store_Options {
		persistent = true,
		create     = true,
		durable    = false,
	}
	store, open_err := db.store_open(path, options)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	total :: 3000
	for i in 0 ..< total {
		run_done(t, store, fmt.tprintf("INSERT INTO t (id, v) VALUES (%d, %d)", i, i))
	}
	db.store_close(store)

	log_path := fmt.tprintf("%s/log", path)
	handle, file_err := os.open(log_path, {.Read, .Write})
	if !testing.expect(t, file_err == nil, "cannot open the log") do return
	log_bytes, size_err := os.file_size(handle)
	os.close(handle)
	if !testing.expect(t, size_err == nil, "cannot size the log") do return
	// Every record is far smaller than the stream buffer, so the file has to be
	// bigger than it for this test to mean anything.
	if !testing.expect(t, log_bytes > 64 * 1024, "the log is too small to prove anything") do return

	reopened, reopen_err := db.store_open(path, options)
	if !testing.expectf(t, db.error_ok(reopen_err), "reopen: %s", reopen_err.message) do return
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM t").i, i64(total))
	testing.expect_value(t, reopened.replay_records, u64(total) + 1)
	// Zero means the walk never had to grow past LOG_STREAM_INITIAL: the replay
	// held one record, not the file.
	testing.expect_value(t, reopened.replay_buffer_bytes, 0)
	db.store_close(reopened)

	// Cut the last record in half. The replay has to stop at the last complete
	// record, drop the torn tail and keep appending on a clean boundary.
	handle, file_err = os.open(log_path, {.Read, .Write})
	if !testing.expect(t, file_err == nil, "cannot reopen the log") do return
	if trunc_err := os.truncate(handle, log_bytes - 5); trunc_err != nil {
		os.close(handle)
		testing.expect(t, false, "cannot truncate the log")
		return
	}
	os.close(handle)
	torn, torn_err := db.store_open(path, options)
	if !testing.expectf(t, db.error_ok(torn_err), "open after a torn tail: %s", torn_err.message) do return
	testing.expect_value(t, scalar(t, torn, "SELECT count(*) FROM t").i, i64(total - 1))
	testing.expect_value(t, torn.commit_seq, u64(total))
	// The append works again and the record after the tear is the one we just wrote.
	run_done(t, torn, "INSERT INTO t (id, v) VALUES (9999, 9999)")
	db.store_close(torn)
	again, again_err := db.store_open(path, options)
	if !testing.expectf(t, db.error_ok(again_err), "reopen after the repair: %s", again_err.message) do return
	defer db.store_close(again)
	testing.expect_value(t, scalar(t, again, "SELECT count(*) FROM t").i, i64(total))
	testing.expect_value(t, scalar(t, again, "SELECT v FROM t WHERE id = 9999").i, i64(9999))
}

@(test)
test_page_directory_survives_a_reopen :: proc(t: ^testing.T) {
	// The directory of a table is a B+tree in the table's own file. Opening must
	// read its root instead of walking every row page, and a file that predates
	// the directory must still open by walking once and writing it back.
	vfs := db.vfs_memory_new()
	defer db.vfs_memory_destroy(vfs)
	rows, create_err := db.page_rows_create(vfs, "pages", 8)
	if !testing.expectf(t, db.error_ok(create_err), "create: %s", create_err.message) do return
	total :: 2000
	for i in 0 ..< total {
		values := []db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("row-%d", i))}
		put_err := db.page_rows_put(rows, db.Row_Id(i), values)
		if !testing.expectf(t, db.error_ok(put_err), "put %d: %s", i, put_err.message) do return
	}
	// Updates move a row to another slot or page; the directory has to follow.
	for i := 0; i < total; i += 7 {
		values := []db.Value{db.value_int(i64(i)), db.value_string(fmt.tprintf("changed-%d", i))}
		if put_err := db.page_rows_put(rows, db.Row_Id(i), values); !testing.expect(t, db.error_ok(put_err)) do return
	}
	testing.expect(t, db.error_ok(db.page_rows_flush(rows, 1)))
	db.page_rows_close(rows)

	reopened, open_err := db.page_rows_open(vfs, "pages", 8)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.page_rows_close(reopened)
	testing.expect(t, reopened.opened_from_directory)
	testing.expect_value(t, db.ordered_entries(reopened.dir), u64(total))
	testing.expect_value(t, reopened.rows, u64(total))
	for i in 0 ..< total {
		testing.expect(t, db.page_rows_contains(reopened, db.Row_Id(i)))
		row, found := db.page_rows_get(reopened, db.Row_Id(i), context.temp_allocator)
		if !testing.expectf(t, found, "row %d is missing", i) do return
		if i % 7 == 0 {
			testing.expect_value(t, row.values[1].s, fmt.tprintf("changed-%d", i))
		} else {
			testing.expect_value(t, row.values[1].s, fmt.tprintf("row-%d", i))
		}
	}
	testing.expect_value(t, db.page_rows_delete(reopened, db.Row_Id(5)), true)
	testing.expect_value(t, db.page_rows_delete(reopened, db.Row_Id(5)), false)
	testing.expect(t, !db.page_rows_contains(reopened, db.Row_Id(5)))
	// The delete is in a dirty page; a legacy reader sees the file, so flush it.
	testing.expect(t, db.error_ok(db.page_rows_flush(reopened, 2)))

	// A file written before the directory existed has no root in page 0. Wipe the
	// magic to look like one: the open must rebuild it by walking and answer the
	// same rows.
	if forget_err := db.page_rows_forget_directory(vfs, "pages"); !testing.expect(t, db.error_ok(forget_err)) do return
	legacy, legacy_err := db.page_rows_open(vfs, "pages", 8)
	if !testing.expectf(t, db.error_ok(legacy_err), "legacy open: %s", legacy_err.message) do return
	defer db.page_rows_close(legacy)
	testing.expect(t, !legacy.opened_from_directory)
	testing.expect_value(t, legacy.rows, u64(total - 1))
	testing.expect(t, db.page_rows_contains(legacy, db.Row_Id(1999)))
	testing.expect(t, !db.page_rows_contains(legacy, db.Row_Id(5)))

	// Truncate clears the directory, and the table answers on the next insert.
	testing.expect(t, db.error_ok(db.page_rows_truncate(legacy)))
	testing.expect_value(t, legacy.rows, u64(0))
	testing.expect(t, !db.page_rows_contains(legacy, db.Row_Id(1999)))
	values := []db.Value{db.value_int(1), db.value_string("first")}
	if testing.expect(t, db.error_ok(db.page_rows_put(legacy, db.Row_Id(1), values))) {
		testing.expect_value(t, legacy.rows, u64(1))
		row, found := db.page_rows_get(legacy, db.Row_Id(1), context.temp_allocator)
		testing.expect(t, found)
		if found do testing.expect_value(t, row.values[1].s, "first")
	}
}

@(test)
test_read_only_opens_beside_a_writer :: proc(t: ^testing.T) {
	// "Varios procesos" needs a reader that can open while the writer works. The
	// lock has two bytes: the writer byte is exclusive, the reader byte is shared,
	// so a reader joins and a second writer is still refused.
	path := "_test_read_only"
	os.remove_all(path)
	defer os.remove_all(path)
	writer, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "writer: %s", open_err.message) do return
	writer_open := true
	defer if writer_open do db.store_close(writer)
	run_done(t, writer, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, writer, "INSERT INTO t (id, v) VALUES (1, 10), (2, 20)")

	reader, reader_err := db.store_open(path, {
		persistent = true,
		create     = false,
		durable    = false,
		read_only  = true,
	})
	if !testing.expectf(t, db.error_ok(reader_err), "reader: %s", reader_err.message) do return
	reader_open := true
	defer if reader_open do db.store_close(reader)
	testing.expect_value(t, scalar(t, reader, "SELECT count(*) FROM t").i, i64(2))
	testing.expect_value(t, scalar(t, reader, "SELECT v FROM t WHERE id = 2").i, i64(20))

	// A reader is a snapshot of the state at open, and it cannot write.
	run_done(t, writer, "INSERT INTO t (id, v) VALUES (3, 30)")
	testing.expect_value(t, scalar(t, reader, "SELECT count(*) FROM t").i, i64(2))
	insert_err := run_error(t, reader, "INSERT INTO t (id, v) VALUES (4, 40)")
	testing.expect_value(t, insert_err.kind, db.Error_Kind.Transaction_Read_Only)
	create_err := run_error(t, reader, "CREATE TABLE other (id INTEGER PRIMARY KEY)")
	testing.expect_value(t, create_err.kind, db.Error_Kind.Transaction_Read_Only)
	compact_err := db.store_compact(reader)
	defer db.error_free(&compact_err)
	testing.expect_value(t, compact_err.kind, db.Error_Kind.Transaction_Read_Only)

	// The writer can keep writing, but it cannot rewrite the log while a reader
	// holds the reader byte.
	run_done(t, writer, "INSERT INTO t (id, v) VALUES (4, 40)")
	testing.expect_value(t, scalar(t, writer, "SELECT count(*) FROM t").i, i64(4))
	writer_compact := db.store_compact(writer)
	defer db.error_free(&writer_compact)
	testing.expect_value(t, writer_compact.kind, db.Error_Kind.Locked)

	// A second writer is still refused, even though the reader is allowed in.
	second, second_err := db.store_open(path, {persistent = true, create = false, durable = false})
	defer db.error_free(&second_err)
	if !testing.expect(t, !db.error_ok(second_err), "a second writer must be refused") {
		db.store_close(second)
	}
	testing.expect_value(t, second_err.kind, db.Error_Kind.Locked)

	// With the reader gone the writer compacts, and what it wrote survives.
	db.store_close(reader)
	reader_open = false
	testing.expect(t, db.error_ok(db.store_compact(writer)))
	testing.expect_value(t, scalar(t, writer, "SELECT count(*) FROM t").i, i64(4))
	db.store_close(writer)
	writer_open = false

	// And a reader of the compacted log sees the same rows.
	after, after_err := db.store_open(path, {
		persistent = true,
		create     = false,
		read_only  = true,
	})
	if !testing.expectf(t, db.error_ok(after_err), "reader after compact: %s", after_err.message) do return
	defer db.store_close(after)
	testing.expect_value(t, scalar(t, after, "SELECT count(*) FROM t").i, i64(4))
	testing.expect_value(t, scalar(t, after, "SELECT v FROM t WHERE id = 3").i, i64(30))
}

@(test)
test_trusted_open_skips_the_replay :: proc(t: ^testing.T) {
	// A paged database that closed cleanly names one sequence in its catalog, in
	// every page file and in the end of its log. Opening it should read those,
	// not walk the log: the counters below are the proof.
	path := "_test_trusted_open"
	os.remove_all(path)
	defer os.remove_all(path)
	options := db.Store_Options {
		persistent   = true,
		create       = true,
		durable      = false,
		paged_tables = true,
		page_frames  = 8,
	}
	store, open_err := db.store_open(path, options)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
	run_done(t, store, "CREATE INDEX item_name ON item (name)")
	// A view, a trigger and the CREATE texts live in the engine's own tables,
	// which have no page file: the catalog carries their rows, so they no
	// longer force a replay.
	run_done(t, store, "CREATE VIEW item_names AS SELECT name FROM item")
	run_done(t, store, "CREATE TABLE item_log (n INTEGER)")
	run_done(t, store, "CREATE TRIGGER item_logged AFTER DELETE ON item BEGIN INSERT INTO item_log VALUES (old.id); END")
	for i in 0 ..< 200 {
		run_done(t, store, fmt.tprintf("INSERT INTO item (id, name) VALUES (%d, 'n%03d')", i, i))
	}
	run_done(t, store, "DELETE FROM item WHERE id = 7")
	run_done(t, store, "UPDATE item SET name = 'changed' WHERE id = 8")
	closed_seq := store.commit_seq
	db.store_close(store)

	// The offset index is what makes the trusted test cheap, so it has to exist
	// and start with its header. A sidecar created by this build used to begin
	// with an entry instead, which every lookup then rejected.
	index_path := fmt.tprintf("%s/log.index", path)
	index_bytes, index_err := os.read_entire_file_from_path(index_path, context.allocator)
	if !testing.expect(t, index_err == nil, "the log index must exist") do return
	testing.expect(t, len(index_bytes) >= 16 && string(index_bytes[:8]) == "MIRADX01")
	delete(index_bytes)

	reopen_options := options
	reopen_options.create = false
	reopened, reopen_err := db.store_open(path, reopen_options)
	if !testing.expectf(t, db.error_ok(reopen_err), "reopen: %s", reopen_err.message) do return
	testing.expect_value(t, reopened.replays_skipped, u64(1))
	testing.expect_value(t, reopened.replay_records, u64(0))
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM item_names").i, i64(199))
	testing.expect_value(t, scalar(t, reopened, "SELECT n FROM item_log").i, i64(7))
	testing.expect_value(t, scalar(t, reopened, "SELECT sql FROM sqlite_master WHERE name = 'item_names'").s, "CREATE VIEW item_names AS SELECT name FROM item")
	testing.expect_value(t, reopened.commit_seq, closed_seq)
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM item").i, i64(199))
	testing.expect_value(t, scalar(t, reopened, "SELECT name FROM item WHERE id = 8").s, "changed")
	testing.expect_value(t, scalar(t, reopened, "SELECT count(*) FROM item WHERE id = 7").i, i64(0))
	// The index file was opened, not rebuilt: a point lookup through it answers.
	probe := run(t, reopened, "SELECT id FROM item WHERE name = 'n010'")
	testing.expect_value(t, len(probe.rows), 1)
	testing.expect_value(t, probe.rows[0][0].i, i64(10))
	db.sql_result_destroy(&probe)

	// A commit after a trusted open continues the sequence, and the next open
	// trusts again.
	run_done(t, reopened, "INSERT INTO item (id, name) VALUES (500, 'later')")
	testing.expect_value(t, reopened.commit_seq, closed_seq + 1)
	db.store_close(reopened)

	again, again_err := db.store_open(path, reopen_options)
	if !testing.expectf(t, db.error_ok(again_err), "reopen 2: %s", again_err.message) do return
	testing.expect_value(t, again.replays_skipped, u64(1))
	testing.expect_value(t, scalar(t, again, "SELECT count(*) FROM item").i, i64(200))
	testing.expect_value(t, scalar(t, again, "SELECT name FROM item WHERE id = 500").s, "later")
	db.store_close(again)

	// A catalog that is not there, or does not validate, costs a replay and
	// nothing else: the log still has everything.
	catalog_path := fmt.tprintf("%s/catalog", path)
	testing.expect(t, os.exists(catalog_path))
	os.remove(catalog_path)
	replayed, replayed_err := db.store_open(path, reopen_options)
	defer db.error_free(&replayed_err)
	if !testing.expectf(t, db.error_ok(replayed_err), "reopen without a catalog: %s", replayed_err.message) do return
	testing.expect_value(t, replayed.replays_skipped, u64(0))
	testing.expect(t, replayed.replay_records > 0)
	testing.expect_value(t, scalar(t, replayed, "SELECT count(*) FROM item").i, i64(200))
	testing.expect(t, os.exists(catalog_path))
	db.store_close(replayed)

	// A catalog whose bytes were damaged is rejected by the checksum.
	if !testing.expect(t, os.write_entire_file(catalog_path, []u8{'n', 'o', 'p', 'e'}) == nil) do return
	torn, torn_err := db.store_open(path, reopen_options)
	if !testing.expectf(t, db.error_ok(torn_err), "reopen with a torn catalog: %s", torn_err.message) do return
	testing.expect_value(t, torn.replays_skipped, u64(0))
	testing.expect(t, torn.replay_records > 0)
	testing.expect_value(t, scalar(t, torn, "SELECT name FROM item WHERE id = 500").s, "later")
	db.store_close(torn)
}

@(test)
test_analyze_and_plan_estimates :: proc(t: ^testing.T) {
	// ANALYZE measures the data; a plan reads the numbers; a table without them
	// is planned exactly the way it was before statistics existed.
	store := fresh_db(t, "analyze")
	if store == nil do return
	defer cleanup_db(store, "analyze")
	run_done(t, store, "CREATE TABLE ev (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, amount INTEGER)")
	run_done(t, store, "CREATE INDEX ev_kind ON ev (kind)")
	run_done(t, store, "CREATE INDEX ev_amount ON ev (amount)")
	for i in 0 ..< 400 {
		run_done(t, store, fmt.tprintf("INSERT INTO ev (id, kind, amount) VALUES (%d, 'k%d', %d)", i, i % 2, i))
	}

	// Without statistics the plan falls back to the table's row count — the index
	// is taken when it exists, which is what the executor did before ANALYZE —
	// and the estimate says 400 because nothing has measured the column yet.
	before := run(t, store, "EXPLAIN SELECT * FROM ev WHERE amount = 42")
	testing.expect(t, strings_contains(before.rows[0][0].s, "using index ev_amount"))
	testing.expect(t, strings_contains(before.rows[0][0].s, "est. 400 rows"))
	db.sql_result_destroy(&before)

	analyzed := run(t, store, "ANALYZE")
	testing.expect_value(t, analyzed.affected, 1)
	db.sql_result_destroy(&analyzed)

	// 400 rows with 400 distinct amounts: an equality keeps one, so the index
	// answers and the estimate says so.
	point := run(t, store, "EXPLAIN SELECT * FROM ev WHERE amount = 42")
	testing.expect(t, strings_contains(point.rows[0][0].s, "using index ev_amount"))
	testing.expect(t, strings_contains(point.rows[0][0].s, "est. 1 rows"))
	db.sql_result_destroy(&point)

	// Two distinct kinds over 400 rows: an equality keeps half of them on
	// average, so collecting the ids costs more than reading the rows.
	wide := run(t, store, "EXPLAIN SELECT * FROM ev WHERE kind = 'k0'")
	testing.expect(t, strings_contains(wide.rows[0][0].s, "full scan"))
	testing.expect(t, strings_contains(wide.rows[0][0].s, "est. 200 rows"))
	db.sql_result_destroy(&wide)

	// The executor makes the same choice the plan prints.
	db.store_reset_rows_scanned(store)
	wide_rows := run(t, store, "SELECT count(*) FROM ev WHERE kind = 'k0'")
	testing.expect_value(t, wide_rows.rows[0][0].i, i64(200))
	db.sql_result_destroy(&wide_rows)
	testing.expect(t, db.store_rows_scanned(store) >= 400)
	db.store_reset_rows_scanned(store)
	point_rows := run(t, store, "SELECT count(*) FROM ev WHERE amount = 42")
	testing.expect_value(t, point_rows.rows[0][0].i, i64(1))
	db.sql_result_destroy(&point_rows)
	testing.expectf(t, db.store_rows_scanned(store) <= 4, "point lookup scanned %d", db.store_rows_scanned(store))

	// The statistics are a file: a reopen loads them, so the plan keeps its
	// numbers without measuring again.
	db.store_close(store)
	store = nil
	reopened, open_err := db.store_open("_test_analyze", {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	defer db.store_close(reopened)
	after := run(t, reopened, "EXPLAIN SELECT * FROM ev WHERE amount = 42")
	testing.expect(t, strings_contains(after.rows[0][0].s, "est. 1 rows"))
	db.sql_result_destroy(&after)

	// A table that is not there is an error, and DROP TABLE forgets what it
	// measured instead of leaving a plan for a table nobody can read.
	dropped_result_12139, missing := db.sql_execute(reopened, "ANALYZE nope")
	defer db.error_free(&missing)
	defer db.sql_result_destroy(&dropped_result_12139)
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)
	run_done(t, reopened, "DROP TABLE ev")
	gone := run(t, reopened, "EXPLAIN SELECT * FROM ev WHERE amount = 42")
	testing.expect(t, strings_contains(gone.rows[0][0].s, "scan ev"))
	testing.expect(t, !strings_contains(gone.rows[0][0].s, "est."))
	db.sql_result_destroy(&gone)
	// A second ANALYZE after the drop measures nothing and does not resurrect it.
	again := run(t, reopened, "ANALYZE")
	testing.expect_value(t, again.affected, 0)
	db.sql_result_destroy(&again)
}

@(private)
explain_note :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> string {
	result, err := db.sql_execute(store, sql)
	if !testing.expectf(t, db.error_ok(err), "explain failed: %s", err.message) do return ""
	defer db.sql_result_destroy(&result)
	for row in result.rows {
		text := row[0].s
		if strings.has_prefix(text, "note:") do return strings.clone(text)
	}
	return ""
}

@(test)
test_explain_announces_stale_statistics :: proc(t: ^testing.T) {
	// The planner prices a query from numbers ANALYZE measured, and a commit after
	// that makes them a guess. The plan says so, with both sequences, instead of
	// printing an estimate that looks like a measurement.
	store := fresh_db(t, "stale_stats")
	if store == nil do return
	defer cleanup_db(store, "stale_stats")

	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO s (v) VALUES (1), (2), (3)")

	// Nothing measured yet: the plan is a guess and says so.
	note := explain_note(t, store, "EXPLAIN SELECT * FROM s WHERE v = 2")
	testing.expectf(t, strings.has_prefix(note, "note: no statistics"), "fresh note: %s", note)
	delete(note)

	run_done(t, store, "ANALYZE s")
	note = explain_note(t, store, "EXPLAIN SELECT * FROM s WHERE v = 2")
	testing.expectf(t, len(note) == 0, "a measured plan carried a note: %s", note)
	delete(note)

	// A commit after the measurement makes the numbers older than the data.
	run_done(t, store, "INSERT INTO s (v) VALUES (4)")
	note = explain_note(t, store, "EXPLAIN SELECT * FROM s WHERE v = 2")
	testing.expectf(
		t,
		strings.has_prefix(note, "note: statistics measured at commit"),
		"stale note: %s",
		note,
	)
	testing.expect(t, strings.contains(note, "data at commit"))
	delete(note)

	// Measuring again clears it.
	run_done(t, store, "ANALYZE s")
	note = explain_note(t, store, "EXPLAIN SELECT * FROM s WHERE v = 2")
	testing.expectf(t, len(note) == 0, "a re-measured plan carried a note: %s", note)
	delete(note)
}

@(private)
check_plan_marker :: proc(t: ^testing.T, store: ^db.Store, sql: string, marker: string) {
	result, err := db.sql_execute(store, sql)
	if !testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message) do return
	defer db.sql_result_destroy(&result)
	found := false
	for row in result.rows {
		if strings.contains(row[0].s, marker) do found = true
	}
	testing.expectf(t, found, "%s: no %q in the plan", sql, marker)
}

@(private)
plan_estimate :: proc(t: ^testing.T, store: ^db.Store, sql: string, params: []db.Value) -> int {
	result, err := db.sql_execute_params(store, sql, params)
	if !testing.expectf(t, db.error_ok(err), "explain failed: %s", err.message) do return -1
	defer db.sql_result_destroy(&result)
	for row in result.rows {
		text := row[0].s
		marker := strings.index(text, "est. ")
		if marker < 0 do continue
		rest := text[marker + len("est. "):]
		end := strings.index(rest, " rows")
		if end < 0 do continue
		if value, ok := strconv.parse_int(rest[:end]); ok do return int(value)
	}
	return -1
}

@(test)
test_plan_reads_a_range_written_as_two_comparisons :: proc(t: ^testing.T) {
	// `v >= a AND v < b` is one band of the table, so it is priced and answered
	// like `v BETWEEN a AND b`: one range scan, not two filters that each keep a
	// third of the rows and lose to the scan.
	store := fresh_db(t, "range_plan")
	if store == nil do return
	defer cleanup_db(store, "range_plan")

	run_done(t, store, "CREATE TABLE r (id INTEGER PRIMARY KEY, n INTEGER)")
	insert := strings.builder_make()
	defer strings.builder_destroy(&insert)
	strings.write_string(&insert, "INSERT INTO r (n) VALUES ")
	for i in 0 ..< 400 {
		if i > 0 do strings.write_string(&insert, ", ")
		fmt.sbprintf(&insert, "(%d)", i + 1)
	}
	run_done(t, store, strings.to_string(insert))
	run_done(t, store, "CREATE INDEX r_n ON r (n)")
	run_done(t, store, "ANALYZE r")

	range_plan := plan_line_of(t, store, "EXPLAIN SELECT * FROM r WHERE n >= 100 AND n < 150")
	between_plan := plan_line_of(t, store, "EXPLAIN SELECT * FROM r WHERE n BETWEEN 100 AND 149")
	testing.expectf(t, strings.contains(range_plan, "using index r_n"), "range plan: %s", range_plan)
	testing.expectf(t, strings.contains(between_plan, "using index r_n"), "between plan: %s", between_plan)
	// The two spellings of the same band price the same.
	testing.expectf(t, range_plan == between_plan, "range priced as %q, between as %q", range_plan, between_plan)

	// The bounds keep their own inclusivity, and nothing outside the band arrives.
	counts := [3]i64{0, 0, 0}
	for sql, i in ([3]string{
		"SELECT count(*) FROM r WHERE n >= 100 AND n < 150",
		"SELECT count(*) FROM r WHERE n >= 100 AND n <= 150",
		"SELECT count(*) FROM r WHERE 150 > n AND 100 <= n",
	}) {
		result, err := db.sql_execute(store, sql)
		if testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message) {
			counts[i] = result.rows[0][0].i
			db.sql_result_destroy(&result)
		}
	}
	testing.expect_value(t, counts[0], i64(50))
	testing.expect_value(t, counts[1], i64(51))
	// The bounds written the other way round are the same band.
	testing.expect_value(t, counts[2], i64(50))

	// The scan reads the band, not the table.
	db.store_reset_rows_scanned(store)
	result, err := db.sql_execute(store, "SELECT count(*) FROM r WHERE n >= 100 AND n < 150")
	if testing.expectf(t, db.error_ok(err), "count: %s", err.message) {
		testing.expect_value(t, result.rows[0][0].i, i64(50))
		db.sql_result_destroy(&result)
	}
	testing.expectf(t, db.store_rows_scanned(store) <= 60, "the range read %d rows", db.store_rows_scanned(store))

	// One end alone is still a superset the filter has to finish, and two ranges on
	// two columns keep the per-column product.
	one_end, one_err := db.sql_execute(store, "SELECT count(*) FROM r WHERE n >= 400")
	if testing.expectf(t, db.error_ok(one_err), "one end: %s", one_err.message) {
		testing.expect_value(t, one_end.rows[0][0].i, i64(1))
		db.sql_result_destroy(&one_end)
	}
}

@(private)
plan_line_of :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> string {
	result, err := db.sql_execute(store, sql)
	if !testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message) do return ""
	defer db.sql_result_destroy(&result)
	for row in result.rows {
		if strings.has_prefix(row[0].s, "scan ") do return strings.clone(row[0].s, context.temp_allocator)
	}
	return ""
}

@(test)
test_plan_reads_a_bound_value :: proc(t: ^testing.T) {
	// A prepared statement is priced with the value it was given, so `n < ?` keeps
	// the same estimate as `n < 5` instead of falling back to a third of the table.
	// The plan is chosen per execution, which is what lets the histogram answer.
	store := fresh_db(t, "bound_plan")
	if store == nil do return
	defer cleanup_db(store, "bound_plan")

	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY, n INTEGER)")
	insert := strings.builder_make()
	defer strings.builder_destroy(&insert)
	strings.write_string(&insert, "INSERT INTO b (n) VALUES ")
	for i in 0 ..< 400 {
		if i > 0 do strings.write_string(&insert, ", ")
		fmt.sbprintf(&insert, "(%d)", i + 1)
	}
	run_done(t, store, strings.to_string(insert))
	run_done(t, store, "ANALYZE b")

	literal := plan_estimate(t, store, "EXPLAIN SELECT * FROM b WHERE n < 50", nil)
	bound := plan_estimate(
		t,
		store,
		"EXPLAIN SELECT * FROM b WHERE n < ?",
		[]db.Value{db.value_int(50)},
	)
	testing.expectf(t, literal > 20 && literal < 80, "literal estimate: %d", literal)
	testing.expectf(t, bound == literal, "a bound value estimated %d, the literal %d", bound, literal)

	// A statement that binds nothing keeps the old fallback: a third at most.
	unbound := plan_estimate(t, store, "EXPLAIN SELECT * FROM b WHERE n < ?", nil)
	testing.expectf(t, unbound > 100, "an unbound parameter estimated %d", unbound)

	// The bound value also decides the access: 1 of 400 rows probes the index,
	// 380 of 400 keeps the scan.
	run_done(t, store, "CREATE INDEX b_n ON b (n)")
	narrow, narrow_err := db.sql_execute_params(
		store,
		"EXPLAIN SELECT * FROM b WHERE n = ?",
		[]db.Value{db.value_int(7)},
	)
	if testing.expectf(t, db.error_ok(narrow_err), "explain failed: %s", narrow_err.message) {
		testing.expect(t, strings.contains(narrow.rows[0][0].s, "using index b_n"))
		db.sql_result_destroy(&narrow)
	}
}

@(private)
order_sequence :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> [dynamic]string {
	out: [dynamic]string
	result, err := db.sql_execute(store, sql)
	if !testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message) do return out
	defer db.sql_result_destroy(&result)
	for row in result.rows do append(&out, row_set_key(row))
	return out
}

@(test)
test_order_by_comes_from_the_index :: proc(t: ^testing.T) {
	// An index whose key is exactly the ORDER BY hands the rows over in order, so
	// the sort has nothing to do. The answer has to be the same sequence the sort
	// would produce, ties included, which is why the key has to be complete and why
	// a descending sort needs a unique index.
	store := fresh_db(t, "order_index")
	if store == nil do return
	defer cleanup_db(store, "order_index")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)")
	run_done(t, store, "CREATE TABLE u (id INTEGER PRIMARY KEY, n INTEGER)")
	insert_t := strings.builder_make()
	defer strings.builder_destroy(&insert_t)
	insert_u := strings.builder_make()
	defer strings.builder_destroy(&insert_u)
	strings.write_string(&insert_t, "INSERT INTO t (n) VALUES ")
	strings.write_string(&insert_u, "INSERT INTO u (n) VALUES ")
	rows := 300
	for i in 0 ..< rows {
		if i > 0 {
			strings.write_string(&insert_t, ", ")
			strings.write_string(&insert_u, ", ")
		}
		// A key that repeats, written out of order, so ties exist and the insert
		// order is not the key order.
		fmt.sbprintf(&insert_t, "(%d)", ((i * 7) % 50) + 1)
		fmt.sbprintf(&insert_u, "(%d)", ((i * 7) % 50) + 1)
	}
	run_done(t, store, strings.to_string(insert_t))
	run_done(t, store, strings.to_string(insert_u))
	run_done(t, store, "CREATE INDEX t_n ON t (n)")

	check_plan_marker(t, store, "EXPLAIN SELECT * FROM t ORDER BY id", "order by (index t_pkey)")
	check_plan_marker(t, store, "EXPLAIN SELECT * FROM t ORDER BY id DESC", "order by (index t_pkey)")
	check_plan_marker(t, store, "EXPLAIN SELECT * FROM t ORDER BY n", "order by (index t_n)")
	// A non-unique index cannot answer a descending sort: the ties would come back
	// in the opposite row order.
	check_plan_marker(t, store, "EXPLAIN SELECT * FROM t ORDER BY n DESC", "order by (sort)")
	check_plan_marker(t, store, "EXPLAIN SELECT * FROM t ORDER BY id, n", "order by (sort)")

	// The same statement over a table without that index sorts, and both have to
	// answer the same sequence, ties included.
	from_index := order_sequence(t, store, "SELECT id, n FROM t ORDER BY n")
	from_sort := order_sequence(t, store, "SELECT id, n FROM u ORDER BY n")
	testing.expect_value(t, len(from_index), rows)
	testing.expect_value(t, len(from_sort), rows)
	same := len(from_index) == len(from_sort)
	if same {
		for key, i in from_index {
			if strings.compare(key, from_sort[i]) != 0 {
				same = false
				break
			}
		}
	}
	testing.expect(t, same)
	for key in from_index do delete(key)
	for key in from_sort do delete(key)
	delete(from_index)
	delete(from_sort)

	ascending := order_sequence(t, store, "SELECT id FROM t ORDER BY id")
	testing.expect_value(t, len(ascending), rows)
	if len(ascending) == rows {
		testing.expect_value(t, ascending[0], "1")
		testing.expect_value(t, ascending[rows - 1], fmt.tprintf("%d", rows))
	}
	for key in ascending do delete(key)
	delete(ascending)

	descending := order_sequence(t, store, "SELECT id FROM t ORDER BY id DESC LIMIT 3")
	testing.expect_value(t, len(descending), 3)
	if len(descending) == 3 {
		testing.expect_value(t, descending[0], fmt.tprintf("%d", rows))
		testing.expect_value(t, descending[2], fmt.tprintf("%d", rows - 2))
	}
	for key in descending do delete(key)
	delete(descending)

	// A filter still runs, and LIMIT still counts what survives it.
	filtered := order_sequence(t, store, "SELECT id, n FROM t WHERE n > 40 ORDER BY n LIMIT 4")
	testing.expect_value(t, len(filtered), 4)
	for key in filtered do delete(key)
	delete(filtered)

	// A LIMIT with nothing else to drop a row ends the walk: three rows read for
	// three rows asked, instead of a pass over the table.
	db.store_reset_rows_scanned(store)
	tail := order_sequence(t, store, "SELECT id FROM t ORDER BY id DESC LIMIT 3")
	testing.expect_value(t, len(tail), 3)
	testing.expectf(t, db.store_rows_scanned(store) <= 4, "a LIMIT read %d rows", db.store_rows_scanned(store))
	for key in tail do delete(key)
	delete(tail)

	// A filter means the walk cannot stop early, and the answer is still right.
	db.store_reset_rows_scanned(store)
	tail = order_sequence(t, store, "SELECT id FROM t WHERE n > 40 ORDER BY id DESC LIMIT 3")
	testing.expect_value(t, len(tail), 3)
	testing.expectf(t, db.store_rows_scanned(store) > 3, "a filtered LIMIT stopped early")
	for key in tail do delete(key)
	delete(tail)

	// OFFSET is taken from the same ordered read.
	window := order_sequence(t, store, "SELECT id FROM t ORDER BY id LIMIT 2 OFFSET 2")
	testing.expect_value(t, len(window), 2)
	if len(window) == 2 {
		testing.expect_value(t, window[0], "3")
		testing.expect_value(t, window[1], "4")
	}
	for key in window do delete(key)
	delete(window)
}

@(test)
test_plan_prices_a_view_from_its_own_from :: proc(t: ^testing.T) {
	// A view has no rows to measure until the statement runs. The plan prices it
	// by the relation its own query reads, so it is not "zero rows" -- which would
	// put it first in every join order -- and EXPLAIN says where the number came
	// from instead of passing a guess off as a measurement.
	store := fresh_db(t, "view_plan")
	if store == nil do return
	defer cleanup_db(store, "view_plan")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)")
	insert := strings.builder_make()
	defer strings.builder_destroy(&insert)
	strings.write_string(&insert, "INSERT INTO t (n) VALUES ")
	for i in 0 ..< 400 {
		if i > 0 do strings.write_string(&insert, ", ")
		fmt.sbprintf(&insert, "(%d)", i + 1)
	}
	run_done(t, store, strings.to_string(insert))
	run_done(t, store, "ANALYZE t")
	run_done(t, store, "CREATE VIEW v AS SELECT * FROM t WHERE n < 100")
	run_done(t, store, "CREATE VIEW w AS SELECT * FROM v")

	estimate := plan_estimate(t, store, "EXPLAIN SELECT * FROM v", nil)
	testing.expectf(t, estimate > 80 && estimate < 130, "a view estimated %d rows", estimate)

	// A view over a view keeps the number: the planner follows the chain.
	nested := plan_estimate(t, store, "EXPLAIN SELECT * FROM w", nil)
	testing.expectf(t, nested == estimate, "a nested view estimated %d, the view %d", nested, estimate)

	// The plan tells the truth about where the number came from.
	result, err := db.sql_execute(store, "EXPLAIN SELECT * FROM v")
	if testing.expectf(t, db.error_ok(err), "explain failed: %s", err.message) {
		testing.expect(t, strings.contains(result.rows[0][0].s, "a view"))
		testing.expect(t, strings.contains(result.rows[0][0].s, "from the relation it reads"))
		db.sql_result_destroy(&result)
	}

	// The estimate is what the plan decides with: over 400 rows a join to the view
	// must not treat it as empty.
	run_done(t, store, "CREATE TABLE other (id INTEGER PRIMARY KEY, n INTEGER)")
	run_done(t, store, "INSERT INTO other (n) VALUES (1), (2), (3)")
	run_done(t, store, "ANALYZE other")
	order, order_err := db.sql_execute(store, `
		EXPLAIN SELECT * FROM other JOIN v ON other.n = v.n`)
	defer db.error_free(&order_err)
	if testing.expectf(t, db.error_ok(order_err), "explain failed: %s", order_err.message) {
		joined := false
		for row in order.rows {
			if strings.has_prefix(row[0].s, "join ") do joined = true
			testing.expectf(t, !strings.contains(row[0].s, "est. 0 rows"), "the plan priced a relation at zero: %s", row[0].s)
		}
		testing.expect(t, joined)
		db.sql_result_destroy(&order)
	}
}

@(private)
plan_step_names :: proc(plan: db.Sql_Result) -> string {
	// The steps of a plan in run order, without the "join order:" summary, which
	// only appears when the order differs from the written one.
	names := make([dynamic]string)
	defer delete(names)
	defer for name in names do delete(name)
	for row in plan.rows {
		line := row[0].s
		prefix := ""
		if strings.has_prefix(line, "scan ") {
			prefix = "scan "
		} else if strings.has_prefix(line, "join ") && !strings_contains(line, "join order:") {
			prefix = "join "
		} else {
			continue
		}
		rest := line[len(prefix):]
		end := 0
		for end < len(rest) && rest[end] != ' ' && rest[end] != '(' do end += 1
		append(&names, strings.clone(rest[:end]))
	}
	return strings.join(names[:], " > ")
}

@(test)
test_star_lists_the_written_columns_after_a_reorder :: proc(t: ^testing.T) {
	// The planner may run the relations of a join in another order, but `SELECT *`
	// still lists them in the order the query wrote them. It used to expand the star
	// from the relation the plan started at, so a reordered join printed the other
	// table's columns — silently, and twice when both sources resolved to the same
	// table.
	store := fresh_db(t, "star_reorder")
	if store == nil do return
	defer cleanup_db(store, "star_reorder")
	run_done(t, store, "CREATE TABLE small (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "CREATE TABLE big (id INTEGER PRIMARY KEY, small_id INTEGER, note TEXT)")
	run_done(t, store, "INSERT INTO small (id, label) VALUES (1, 'a'), (2, 'b')")
	for start := 0; start < 200; start += 50 {
		builder := strings.builder_make()
		fmt.sbprintf(&builder, "INSERT INTO big (id, small_id, note) VALUES ")
		for i in start ..< start + 50 {
			if i > start do fmt.sbprintf(&builder, ",")
			fmt.sbprintf(&builder, "(%d,%d,'n%d')", i, i % 2 + 1, i)
		}
		run_done(t, store, strings.to_string(builder))
		strings.builder_destroy(&builder)
	}
	run_done(t, store, "ANALYZE")

	// The small relation runs first, so the plan is reordered.
	plan := run(t, store, "EXPLAIN SELECT * FROM big JOIN small ON small.id = big.small_id")
	reordered := false
	for row in plan.rows {
		if strings_contains(row[0].s, "join order:") do reordered = true
	}
	testing.expect(t, reordered)
	db.sql_result_destroy(&plan)

	result, err := db.sql_execute(store, "SELECT * FROM big JOIN small ON small.id = big.small_id LIMIT 1")
	if testing.expectf(t, db.error_ok(err), "%s", err.message) {
		names := [5]string{"id", "small_id", "note", "id", "label"}
		testing.expect_value(t, len(result.columns), 5)
		for name, i in names {
			if i < len(result.columns) do testing.expect_value(t, result.columns[i], name)
		}
	}
	db.sql_result_destroy(&result)
}

@(test)
test_window_range_and_groups_frames :: proc(t: ^testing.T) {
	// ROWS counts rows, GROUPS counts peer groups, and RANGE counts the ORDER BY
	// value. Every expected number below is what sqlite3 answers for the same rows,
	// including the descending frame.
	store := fresh_db(t, "window_frames_offsets")
	if store == nil do return
	defer cleanup_db(store, "window_frames_offsets")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT, n INTEGER, v REAL)")
	run_done(t, store, `
		INSERT INTO t (id, g, n, v) VALUES
		 (1,'a',10,1.5),(2,'a',20,2.5),(3,'a',20,2.5),(4,'a',40,4.5),
		 (5,'b',10,1.5),(6,'b',30,3.5),(7,'b',30,3.5),(8,'b',30,3.5)`)

	Check :: struct {
		sql:      string,
		expected: [8]i64,
	}
	checks := [7]Check{
		// RANGE without an offset runs to the last peer: 10 and 20 are separate
		// values, the two 20s share their total, and 40 takes the whole partition.
		{
			"SELECT sum(n) OVER (ORDER BY n RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t ORDER BY id",
			{20, 60, 60, 190, 20, 150, 150, 150},
		},
		// A RANGE offset is measured in the order value: 10..30 around each n.
		{
			"SELECT sum(n) OVER (ORDER BY n RANGE BETWEEN CURRENT ROW AND 10 FOLLOWING) FROM t ORDER BY id",
			{60, 130, 130, 40, 60, 130, 130, 130},
		},
		// GROUPS 1 PRECEDING..1 FOLLOWING covers three peer groups.
		{
			"SELECT count(*) OVER (ORDER BY n GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM t ORDER BY id",
			{4, 7, 7, 4, 4, 6, 6, 6},
		},
		{
			"SELECT count(*) OVER (ORDER BY n GROUPS BETWEEN 2 PRECEDING AND 2 FOLLOWING) FROM t ORDER BY id",
			{7, 8, 8, 6, 7, 8, 8, 8},
		},
		// The same frame read in descending order walks the values the other way.
		{
			"SELECT sum(n) OVER (ORDER BY n RANGE BETWEEN 15 PRECEDING AND 15 FOLLOWING) FROM t ORDER BY id DESC",
			{170, 170, 170, 60, 130, 150, 150, 60},
		},
		// A partition restarts the groups.
		{
			"SELECT sum(n) OVER (PARTITION BY g ORDER BY n GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t ORDER BY id",
			{10, 50, 50, 80, 10, 100, 100, 100},
		},
		// RANGE 0 PRECEDING..0 FOLLOWING is exactly the peers of the row.
		{
			"SELECT sum(n) OVER (ORDER BY n RANGE BETWEEN 0 PRECEDING AND 0 FOLLOWING) FROM t ORDER BY id",
			{20, 40, 40, 40, 20, 90, 90, 90},
		},
	}
	for check in checks {
		result, err := db.sql_execute(store, check.sql)
		if !testing.expectf(t, db.error_ok(err), "%s: %s", check.sql, err.message) do continue
		if testing.expectf(t, len(result.rows) == 8, "%s: %d rows", check.sql, len(result.rows)) {
			for expected, i in check.expected {
				testing.expectf(
					t,
					result.rows[i][0].i == expected,
					"%s: row %d is %d, expected %d",
					check.sql,
					i,
					result.rows[i][0].i,
					expected,
				)
			}
		}
		db.sql_result_destroy(&result)
	}

	// A frame measured in the order value needs exactly one numeric term, and a
	// text ordering has no arithmetic to do.
	refused := [2]string{
		"SELECT sum(n) OVER (ORDER BY n, id RANGE BETWEEN 10 PRECEDING AND CURRENT ROW) FROM t",
		"SELECT sum(n) OVER (ORDER BY g RANGE BETWEEN 10 PRECEDING AND CURRENT ROW) FROM t",
	}
	for sql in refused {
		result, err := db.sql_execute(store, sql)
		defer db.error_free(&err)
		testing.expectf(t, !db.error_ok(err), "%s should be refused", sql)
		db.sql_result_destroy(&result)
	}
}

@(test)
test_join_using :: proc(t: ^testing.T) {
	// `JOIN b USING (c)` is `ON a.c = b.c` with one extra rule: `SELECT *` prints the
	// merged column once, from the left relation. The condition is desugared where
	// it is parsed, so the planner probes it like any other equality.
	store := fresh_db(t, "join_using")
	if store == nil do return
	defer cleanup_db(store, "join_using")

	run_done(t, store, "CREATE TABLE dept (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept INTEGER, salary INTEGER)")
	// The employee table is the big one, so the planner starts at the departments
	// and `SELECT *` has to keep writing the columns in the order the query did.
	for i in 0 ..< 300 {
		run_done(t, store, fmt.tprintf("INSERT INTO emp (id, name, dept, salary) VALUES (%d, 'e%d', %d, %d)", i, i, i % 3 + 1, i * 10))
	}
	// One employee in a department that does not exist, for the outer row.
	run_done(t, store, "INSERT INTO emp (id, name, dept, salary) VALUES (300, 'gone', 9, 5)")
	run_done(t, store, "INSERT INTO dept (id, name) VALUES (0, 'eng'), (1, 'ops'), (2, 'hr'), (3, 'new')")
	run_done(t, store, "ANALYZE")

	result, err := db.sql_execute(store, "SELECT * FROM emp JOIN dept USING (id) WHERE emp.id < 3 ORDER BY emp.id")
	if testing.expectf(t, db.error_ok(err), "%s", err.message) {
		// The merged column appears once, from the left relation, and the right one
		// is listed without it.
		names := [5]string{"id", "name", "dept", "salary", "name"}
		testing.expectf(t, len(result.columns) == 5, "%d columns: %v", len(result.columns), result.columns)
		for name, i in names {
			if i < len(result.columns) do testing.expect_value(t, result.columns[i], name)
		}
		testing.expect_value(t, len(result.rows), 3)
		if len(result.rows) == 2 {
			testing.expect_value(t, result.rows[0][0].i, i64(0))
			testing.expect_value(t, result.rows[0][1].s, "e0")
			testing.expect_value(t, result.rows[0][3].i, i64(0))
			testing.expect_value(t, result.rows[0][4].s, "eng")
		}
	}
	db.sql_result_destroy(&result)

	// The same join written with ON lists the join column twice.
	on_result, on_err := db.sql_execute(
		store,
		"SELECT * FROM emp JOIN dept ON dept.id = emp.id WHERE emp.id < 3 ORDER BY emp.id",
	)
	if testing.expectf(t, db.error_ok(on_err), "%s", on_err.message) {
		testing.expect_value(t, len(on_result.columns), 6)
		testing.expect_value(t, on_result.columns[4], "id")
	}
	db.sql_result_destroy(&on_result)

	// A qualified star still lists every column of the relation, merged or not.
	qualified, qualified_err := db.sql_execute(
		store,
		"SELECT dept.* FROM emp JOIN dept USING (id) WHERE emp.id < 3 ORDER BY emp.id",
	)
	if testing.expectf(t, db.error_ok(qualified_err), "%s", qualified_err.message) {
		testing.expect_value(t, len(qualified.columns), 2)
		testing.expect_value(t, qualified.columns[0], "id")
	}
	db.sql_result_destroy(&qualified)

	// Two merged columns leave both out of the right side.
	both, both_err := db.sql_execute(
		store,
		"SELECT * FROM emp JOIN dept USING (id, name) WHERE emp.id < 3",
	)
	if testing.expectf(t, db.error_ok(both_err), "%s", both_err.message) {
		testing.expect_value(t, len(both.columns), 4)
	}
	db.sql_result_destroy(&both)

	// A LEFT join keeps the rows that match nothing, with the right side empty.
	left, left_err := db.sql_execute(
		store,
		"SELECT * FROM emp LEFT JOIN dept USING (id) WHERE emp.id >= 300 ORDER BY emp.id",
	)
	if testing.expectf(t, db.error_ok(left_err), "%s", left_err.message) {
		testing.expect_value(t, len(left.rows), 1)
		if len(left.rows) == 1 {
			testing.expect_value(t, left.rows[0][0].i, i64(300))
			testing.expect(t, left.rows[0][4].kind == .Null)
		}
	}
	db.sql_result_destroy(&left)

	// USING reaches the planner as an equality, so the join probes the index.
	// The desugared equality reaches the planner, so the second relation is
	// reached through its primary key instead of being scanned per outer row.
	plan := run(t, store, "EXPLAIN SELECT count(*) FROM emp JOIN dept USING (id) WHERE emp.id < 3")
	probed := false
	for row in plan.rows {
		if strings.has_prefix(row[0].s, "join ") && strings_contains(row[0].s, "using index") {
			probed = true
		}
	}
	testing.expect(t, probed)
	db.sql_result_destroy(&plan)

	// A column that is not in both relations is an error, not a silent cross join.
	missing, missing_err := db.sql_execute(store, "SELECT * FROM emp JOIN dept USING (nope)")
	defer db.error_free(&missing_err)
	testing.expect(t, !db.error_ok(missing_err))
	db.sql_result_destroy(&missing)
}

@(test)
test_plan_does_not_cross_join_before_it_can_filter :: proc(t: ^testing.T) {
	// Only books joins the other two relations: authors and publishers share no
	// condition. A plan that binds them first multiplies them (200 x 5) before
	// books can filter anything, and the old greedy did exactly that, because it
	// compared the rows one outer row matches — which for the first relation in
	// the list is its own row count, not a per-outer figure.
	store := fresh_db(t, "plan_cross")
	if store == nil do return
	defer cleanup_db(store, "plan_cross")
	run_done(t, store, "CREATE TABLE authors (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TABLE publishers (id INTEGER PRIMARY KEY)")
	run_done(t, store, "CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER, publisher_id INTEGER)")
	run_done(t, store, "CREATE INDEX books_author ON books (author_id)")
	run_done(t, store, "CREATE INDEX books_publisher ON books (publisher_id)")
	for i in 0 ..< 5 {
		run_done(t, store, fmt.tprintf("INSERT INTO publishers (id) VALUES (%d)", i))
	}
	for start := 0; start < 200; start += 50 {
		builder := strings.builder_make()
		fmt.sbprintf(&builder, "INSERT INTO authors (id) VALUES ")
		for i in start ..< start + 50 {
			if i > start do fmt.sbprintf(&builder, ",")
			fmt.sbprintf(&builder, "(%d)", i)
		}
		run_done(t, store, strings.to_string(builder))
		strings.builder_destroy(&builder)
	}
	for start := 0; start < 2000; start += 200 {
		builder := strings.builder_make()
		fmt.sbprintf(&builder, "INSERT INTO books (id, author_id, publisher_id) VALUES ")
		for i in start ..< start + 200 {
			if i > start do fmt.sbprintf(&builder, ",")
			fmt.sbprintf(&builder, "(%d,%d,%d)", i, i % 200, i % 5)
		}
		run_done(t, store, strings.to_string(builder))
		strings.builder_destroy(&builder)
	}
	run_done(t, store, "ANALYZE")

	plan := run(
		t,
		store,
		`EXPLAIN SELECT count(*)
		 FROM publishers
		 JOIN books ON books.publisher_id = publishers.id
		 JOIN authors ON books.author_id = authors.id`,
	)
	joined_lines := make([dynamic]string, 0, 4)
	defer delete(joined_lines)
	for row in plan.rows {
		if strings.has_prefix(row[0].s, "join ") && !strings_contains(row[0].s, "join order:") {
			append(&joined_lines, row[0].s)
		}
	}
	testing.expect_value(t, len(joined_lines), 2)
	if len(joined_lines) == 2 {
		// Books runs second, through the index it has on the publisher, and the
		// authors are reached through the primary key after that.
		testing.expectf(
			t,
			strings_contains(joined_lines[0], "join books using index books_publisher"),
			"books should be probed second, plan: %s / %s",
			joined_lines[0],
			joined_lines[1],
		)
		testing.expect(t, strings_contains(joined_lines[1], "join authors"))
	}
	first_steps := plan_step_names(plan)
	defer delete(first_steps)
	db.sql_result_destroy(&plan)

	db.store_reset_rows_scanned(store)
	count := scalar(
		t,
		store,
		`SELECT count(*)
		 FROM publishers
		 JOIN books ON books.publisher_id = publishers.id
		 JOIN authors ON books.author_id = authors.id`,
	)
	testing.expect_value(t, count.i, i64(2000))
	// Two thousand books, and one probe each for the publisher and the author: a
	// plan that crossed the two unjoined relations first would visit 200 x 5
	// partials times a thousand books.
	scanned := db.store_rows_scanned(store)
	testing.expectf(t, scanned < 10_000, "the join visited %d rows", scanned)

	// The same join spelled the other way round is planned to the same size: the
	// cost is a property of the schema, not of the FROM the user wrote. The two
	// plans need not be identical — two orders can cost almost the same — but
	// neither may cross the two unjoined relations before books filters them.
	other_plan := run(
		t,
		store,
		`EXPLAIN SELECT count(*) FROM authors
		 JOIN books ON books.author_id = authors.id
		 JOIN publishers ON books.publisher_id = publishers.id`,
	)
	other_steps := plan_step_names(other_plan)
	defer delete(other_steps)
	db.sql_result_destroy(&other_plan)
	db.store_reset_rows_scanned(store)
	other_count := scalar(
		t,
		store,
		`SELECT count(*) FROM authors
		 JOIN books ON books.author_id = authors.id
		 JOIN publishers ON books.publisher_id = publishers.id`,
	)
	testing.expect_value(t, other_count.i, i64(2000))
	other_scanned := db.store_rows_scanned(store)
	testing.expectf(
		t,
		other_scanned < 20_000,
		"the join spelled the other way visited %d rows (%s)",
		other_scanned,
		other_steps,
	)
}

@(test)
test_plan_reorders_a_join :: proc(t: ^testing.T) {
	// A nested loop reads the whole inner relation per outer row, so the order of
	// the joins decides how many rows are read. The planner picks the join that
	// keeps few rows first, and the executor follows the plan.
	store := fresh_db(t, "plan_join")
	if store == nil do return
	defer cleanup_db(store, "plan_join")
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY, code INTEGER)")
	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, num INTEGER)")
	for i in 0 ..< 10 {
		run_done(t, store, fmt.tprintf("INSERT INTO a (id, name) VALUES (%d, 'a%d')", i, i))
	}
	// b is large and its code column has 10 distinct values: each outer row
	// matches 100 rows, so joining it early multiplies everything after it.
	for i in 0 ..< 1000 {
		run_done(t, store, fmt.tprintf("INSERT INTO b (id, code) VALUES (%d, %d)", i, i % 10))
	}
	run_done(t, store, "INSERT INTO c (id, num) VALUES (1, 1), (2, 2)")
	run_done(t, store, "ANALYZE")

	plan := run(t, store, "EXPLAIN SELECT count(*) FROM a JOIN b ON a.id = b.code JOIN c ON a.id = c.num")
	testing.expect(t, strings_contains(plan.rows[0][0].s, "scan c"))
	joined_lines := make([dynamic]string, 0, 4)
	defer delete(joined_lines)
	for row in plan.rows {
		if strings.has_prefix(row[0].s, "join ") && !strings_contains(row[0].s, "join order") {
			append(&joined_lines, row[0].s)
		}
	}
	testing.expect_value(t, len(joined_lines), 2)
	// c keeps two rows, a ten and b a thousand: c runs first, a second (ten rows
	// per outer row), b last, so b is scanned twice instead of once per outer row
	// of a.
	testing.expect(t, strings_contains(joined_lines[0], "join a "))
	testing.expect(t, strings_contains(joined_lines[1], "join b "))
	order_line := false
	for row in plan.rows {
		if strings_contains(row[0].s, "join order:") do order_line = true
	}
	testing.expect(t, order_line)
	db.sql_result_destroy(&plan)

	// The executor reads what the plan promised: the reordered join visits about
	// a thousand rows, the written order about twelve thousand.
	db.store_reset_rows_scanned(store)
	count := scalar(t, store, "SELECT count(*) FROM a JOIN b ON a.id = b.code JOIN c ON a.id = c.num")
	testing.expect_value(t, count.i, i64(200))
	testing.expectf(
		t,
		db.store_rows_scanned(store) < 3000,
		"the reordered join scanned %d rows",
		db.store_rows_scanned(store),
	)
	db.store_reset_rows_scanned(store)
	written := scalar(t, store, "SELECT count(*) FROM a JOIN c ON a.id = c.num JOIN b ON a.id = b.code")
	testing.expect_value(t, written.i, i64(200))
	testing.expect(t, db.store_rows_scanned(store) < 3000)

	// A LEFT join keeps the written order: moving the null-supplying relation
	// ahead of the join would change which rows survive.
	left := run(t, store, "EXPLAIN SELECT count(*) FROM a LEFT JOIN b ON a.id = b.code")
	testing.expect(t, !strings_contains(left.rows[0][0].s, "join order:"))
	db.sql_result_destroy(&left)
}

@(test)
test_in_and_not_in_with_null :: proc(t: ^testing.T) {
	// SQL three-valued logic: a NULL in the list makes a non-match unknown, so
	// neither IN nor NOT IN answers TRUE for a row it did not find. Skipping the
	// NULL instead turns NOT IN into "every row that is not equal", which is a
	// wrong answer and not a missing feature.
	store := fresh_db(t, "in_null")
	if store == nil do return
	defer cleanup_db(store, "in_null")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1, 1), (2, 2), (3, NULL)")

	testing.expect_value(t, scalar(t, store, "SELECT 2 IN (1, NULL)").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT 2 NOT IN (1, NULL)").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT 1 IN (1, NULL)").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT 1 NOT IN (1, NULL)").b, false)
	testing.expect_value(t, scalar(t, store, "SELECT 2 IN (1, 2)").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT 2 NOT IN (1, 2)").b, false)
	testing.expect_value(t, scalar(t, store, "SELECT 2 IN (1, 3)").b, false)
	testing.expect_value(t, scalar(t, store, "SELECT 2 NOT IN (1, 3)").b, true)

	// WHERE keeps only what is TRUE, so an unknown never becomes a row.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE v NOT IN (1, NULL)").i, i64(0))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE v NOT IN (1)").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE v IN (1, NULL)").i, i64(1))

	// The subquery form follows the same rule.
	testing.expect_value(t, scalar(t, store, "SELECT 2 IN (SELECT NULL)").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT 2 NOT IN (SELECT NULL)").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT 1 IN (SELECT v FROM t WHERE v = 1)").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT 2 IN (SELECT v FROM t WHERE v = 1)").b, false)
}

@(test)
test_aggregate_distinct :: proc(t: ^testing.T) {
	// DISTINCT inside an aggregate folds each value once. It was parsed into the
	// call and then ignored, so count(DISTINCT x) answered the row count.
	store := fresh_db(t, "agg_distinct")
	if store == nil do return
	defer cleanup_db(store, "agg_distinct")

	run_done(t, store, "CREATE TABLE d (id INTEGER PRIMARY KEY, x INTEGER, label TEXT)")
	run_done(t, store, "INSERT INTO d (id, x, label) VALUES (1, 1, 'a'), (2, 1, 'a'), (3, 2, 'b'), (4, 3, 'b'), (5, 3, 'b'), (6, NULL, NULL)")

	testing.expect_value(t, scalar(t, store, "SELECT count(x) FROM d").i, i64(5))
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT x) FROM d").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT sum(DISTINCT x) FROM d").i, i64(6))
	testing.expect_value(t, scalar(t, store, "SELECT avg(DISTINCT x) FROM d").f, f64(2))
	testing.expect_value(t, scalar(t, store, "SELECT min(DISTINCT x) FROM d").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT max(DISTINCT x) FROM d").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT label) FROM d").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(DISTINCT label) FROM d").s, "a,b")
	// 1 and 1.0 compare equal, so a DISTINCT aggregate folds them once.
	run_done(t, store, "CREATE TABLE mixed (x ANY)")
	run_done(t, store, "INSERT INTO mixed VALUES (1), (1.0), (2), ('1')")
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT x) FROM mixed").i, i64(3))

	// A grouped DISTINCT aggregate and the streaming path (paged tables) agree
	// with the collected one.
	grouped := run(t, store, "SELECT label, count(DISTINCT x) AS n FROM d GROUP BY label ORDER BY label")
	testing.expect_value(t, len(grouped.rows), 3)
	db.sql_result_destroy(&grouped)

	paged_path := "_test_agg_distinct_paged"
	os.remove_all(paged_path)
	defer os.remove_all(paged_path)
	paged, open_err := db.store_open(paged_path, {
		persistent  = true,
		create      = true,
		durable     = false,
		paged_tables = true,
		page_frames = 4,
	})
	if !testing.expectf(t, db.error_ok(open_err), "open paged: %s", open_err.message) do return
	defer db.store_close(paged)
	run_done(t, paged, "CREATE TABLE p (id INTEGER PRIMARY KEY, x INTEGER)")
	run_done(t, paged, "INSERT INTO p VALUES (1, 1), (2, 1), (3, 2), (4, 2), (5, 3)")
	testing.expect_value(t, scalar(t, paged, "SELECT count(DISTINCT x) FROM p").i, i64(3))
	testing.expect_value(t, scalar(t, paged, "SELECT sum(DISTINCT x) FROM p").i, i64(6))

	// The key map owns the keys it stores. A key freed right after the insert
	// would be overwritten by the next allocation, and the same aggregate would
	// answer differently from run to run: 40 distinct values, twenty times, with
	// string work in between to reuse whatever was freed.
	run_done(t, store, "CREATE TABLE wide (x INTEGER)")
	body: strings.Builder
	strings.builder_init(&body)
	defer strings.builder_destroy(&body)
	strings.write_string(&body, "INSERT INTO wide (x) VALUES ")
	for i in 0 ..< 200 {
		if i > 0 do strings.write_string(&body, ", ")
		fmt.sbprintf(&body, "(%d)", i % 40 + 1)
	}
	run_done(t, store, strings.to_string(body))
	for _ in 0 ..< 20 {
		testing.expect_value(t, scalar(t, store, "SELECT sum(DISTINCT x) FROM wide").i, i64(820))
		testing.expect_value(t, scalar(t, store, "SELECT upper(concat('a', 'b', 'c') || 'd')").s, "ABCD")
	}
}

@(test)
test_order_by_ties_follow_the_row_id :: proc(t: ^testing.T) {
	// A query with ties must answer the same rows in the same order on every run.
	// The scan order of a table is a map, so without a tiebreaker the same
	// statement could come back differently; the row id is the last sort key,
	// which is also the order SQLite scans in.
	store := fresh_db(t, "order_ties")
	if store == nil do return
	defer cleanup_db(store, "order_ties")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "INSERT INTO t (id, name) VALUES (1, 'a'), (2, 'b'), (3, 'a'), (4, 'a'), (5, 'b')")

	for _ in 0 ..< 3 {
		desc := run(t, store, "SELECT id FROM t ORDER BY name DESC")
		if !testing.expect_value(t, len(desc.rows), 5) {
			db.sql_result_destroy(&desc)
			return
		}
		testing.expect_value(t, desc.rows[0][0].i, i64(2))
		testing.expect_value(t, desc.rows[1][0].i, i64(5))
		testing.expect_value(t, desc.rows[2][0].i, i64(1))
		testing.expect_value(t, desc.rows[3][0].i, i64(3))
		testing.expect_value(t, desc.rows[4][0].i, i64(4))
		db.sql_result_destroy(&desc)
	}
	// A second key still decides first; the row id only breaks the ties.
	second := run(t, store, "SELECT id FROM t ORDER BY name DESC, id DESC")
	testing.expect_value(t, second.rows[0][0].i, i64(5))
	testing.expect_value(t, second.rows[1][0].i, i64(2))
	testing.expect_value(t, second.rows[4][0].i, i64(1))
	db.sql_result_destroy(&second)
}

@(test)
test_scalar_minmax_and_trim_sets :: proc(t: ^testing.T) {
	// SQLite answers min/max with two or more arguments as scalar functions, and
	// trims a set of characters given as the second argument; both are used in
	// migrations and neither was implemented.
	store := fresh_db(t, "sqlite_scalars")
	if store == nil do return
	defer cleanup_db(store, "sqlite_scalars")

	testing.expect_value(t, scalar(t, store, "SELECT min(2, 3)").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT max(2, 3)").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT min(2.5, 3)").f, f64(2.5))
	testing.expect_value(t, scalar(t, store, "SELECT min('b', 'a')").s, "a")
	testing.expect_value(t, scalar(t, store, "SELECT max('b', 'a')").s, "b")
	testing.expect_value(t, scalar(t, store, "SELECT min(1, NULL)").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT min(3, 1, 2)").i, i64(1))

	testing.expect_value(t, scalar(t, store, "SELECT trim('  x  ')").s, "x")
	testing.expect_value(t, scalar(t, store, "SELECT trim('xxaxx', 'x')").s, "a")
	testing.expect_value(t, scalar(t, store, "SELECT ltrim('xxaxx', 'x')").s, "axx")
	testing.expect_value(t, scalar(t, store, "SELECT rtrim('xxaxx', 'x')").s, "xxa")
	// The default set is the space, as in SQLite, not every whitespace character.
	testing.expect_value(t, scalar(t, store, "SELECT length(ltrim(char(9) || 'x'))").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT trim(NULL)").kind, db.Value_Kind.Null)

	// The aggregate forms are unchanged: min(x) still folds a column.
	run_done(t, store, "CREATE TABLE m (x INTEGER)")
	run_done(t, store, "INSERT INTO m VALUES (5), (2), (9)")
	testing.expect_value(t, scalar(t, store, "SELECT min(x) FROM m").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT max(x) FROM m").i, i64(9))
}

@(test)
test_group_by_a_projection_alias :: proc(t: ^testing.T) {
	// `SELECT dept AS d ... GROUP BY d` groups by what the projection names. A name
	// that is a column of a source still means the column, which is what SQL says:
	// aliasing `salary` to `dept` must not silently regroup the table.
	store := fresh_db(t, "group_alias")
	if store == nil do return
	defer cleanup_db(store, "group_alias")

	run_done(t, store, "CREATE TABLE emp (id INTEGER PRIMARY KEY, dept INTEGER, salary INTEGER)")
	run_done(t, store, "INSERT INTO emp (dept, salary) VALUES (1, 10), (1, 20), (2, 30)")

	Check :: struct {
		sql:    string,
		groups: int,
		first:  [2]i64,
		second: [2]i64,
	}
	checks := [3]Check{
		// Grouped by the alias, ordered by it: two departments, two and one rows.
		{"SELECT dept AS d, count(*) AS n FROM emp GROUP BY d ORDER BY d", 2, {1, 2}, {2, 1}},
		// `dept` is a column here, so this groups by it and not by the alias.
		{"SELECT salary AS dept, count(*) AS n FROM emp GROUP BY dept ORDER BY dept", 2, {10, 2}, {30, 1}},
		// An expression can be named and grouped by that name.
		{"SELECT dept * 10 AS tens, count(*) AS n FROM emp GROUP BY tens ORDER BY tens", 2, {10, 2}, {20, 1}},
	}
	for check in checks {
		result, err := db.sql_execute(store, check.sql)
		if !testing.expectf(t, db.error_ok(err), "%s: %s", check.sql, err.message) do continue
		if testing.expectf(t, len(result.rows) == check.groups, "%s: %d groups", check.sql, len(result.rows)) {
			testing.expect_value(t, result.rows[0][0].i, check.first[0])
			testing.expect_value(t, result.rows[0][1].i, check.first[1])
			testing.expect_value(t, result.rows[1][0].i, check.second[0])
			testing.expect_value(t, result.rows[1][1].i, check.second[1])
		}
		db.sql_result_destroy(&result)
	}

	// The same alias in a join, where the name it stands for belongs to another
	// table than the one the row comes from.
	run_done(t, store, "CREATE TABLE dept (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "INSERT INTO dept (id, name) VALUES (1, 'eng'), (2, 'ops')")
	result, err := db.sql_execute(store, `
		SELECT dept.name AS team, count(*) AS n
		FROM emp JOIN dept ON dept.id = emp.dept
		GROUP BY team ORDER BY team`)
	if testing.expectf(t, db.error_ok(err), "join: %s", err.message) {
		testing.expect_value(t, len(result.rows), 2)
		if len(result.rows) == 2 {
			testing.expect_value(t, result.rows[0][0].s, "eng")
			testing.expect_value(t, result.rows[0][1].i, i64(2))
			testing.expect_value(t, result.rows[1][0].s, "ops")
			testing.expect_value(t, result.rows[1][1].i, i64(1))
		}
		db.sql_result_destroy(&result)
	}
}

@(test)
test_case_expressions :: proc(t: ^testing.T) {
	// Both forms of CASE, wherever an expression is allowed. The branch is only
	// evaluated when it is chosen, which is what makes the division guard safe.
	store := fresh_db(t, "case_expr")
	if store == nil do return
	defer cleanup_db(store, "case_expr")

	run_done(t, store, "CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept INTEGER, salary REAL)")
	run_done(t, store, "INSERT INTO emp VALUES (1, 'ana', 1, 100.5), (2, 'luis', 1, NULL), (3, 'maria', 2, 90.0), (4, NULL, NULL, 75.25)")

	searched := run(t, store, "SELECT id, CASE WHEN salary IS NULL THEN 'none' WHEN salary > 90 THEN 'high' ELSE 'low' END AS band FROM emp ORDER BY id")
	testing.expect_value(t, len(searched.rows), 4)
	testing.expect_value(t, searched.rows[0][1].s, "high")
	testing.expect_value(t, searched.rows[1][1].s, "none")
	testing.expect_value(t, searched.rows[2][1].s, "low")
	db.sql_result_destroy(&searched)

	testing.expect_value(t, scalar(t, store, "SELECT CASE dept WHEN 1 THEN 'eng' WHEN 2 THEN 'sales' ELSE 'other' END FROM emp WHERE id = 3").s, "sales")
	// A NULL operand matches no branch: ELSE runs. Without ELSE the answer is NULL.
	testing.expect_value(t, scalar(t, store, "SELECT CASE dept WHEN 1 THEN 'eng' ELSE 'other' END FROM emp WHERE id = 4").s, "other")
	testing.expect_value(t, scalar(t, store, "SELECT CASE dept WHEN 1 THEN 'eng' END FROM emp WHERE id = 4").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT CASE WHEN NULL THEN 1 ELSE 2 END").i, i64(2))
	// The branch that is not chosen is not evaluated.
	testing.expect_value(t, scalar(t, store, "SELECT CASE WHEN 1 = 0 THEN 1 / 0 ELSE 7 END").i, i64(7))
	// A CASE filters and aggregates like any other expression.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM emp WHERE CASE WHEN salary IS NULL THEN 0 ELSE 1 END = 1").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT count(CASE WHEN dept = 1 THEN 1 END) FROM emp").i, i64(2))
	// Nested, and used as the grouping expression.
	grouped := run(t, store, "SELECT CASE WHEN CASE WHEN dept = 2 THEN 2 ELSE 1 END = 2 THEN 'two' ELSE 'one' END AS g, count(*) FROM emp GROUP BY CASE WHEN dept = 2 THEN 2 ELSE 1 END ORDER BY g")
	if testing.expect_value(t, len(grouped.rows), 2) {
		testing.expect_value(t, grouped.rows[0][0].s, "one")
		testing.expect_value(t, grouped.rows[0][1].i, i64(3))
		testing.expect_value(t, grouped.rows[1][0].s, "two")
		testing.expect_value(t, grouped.rows[1][1].i, i64(1))
	}
	db.sql_result_destroy(&grouped)
}

@(test)
test_snapshot_indexes_are_its_own :: proc(t: ^testing.T) {
	// A snapshot copies the index trees, not just the rows. After the source
	// changes, a lookup on the frozen table still answers the state it was taken
	// at, and the source answers the new one: the two never share a tree.
	store := fresh_db(t, "snapshot_index")
	if store == nil do return
	defer cleanup_db(store, "snapshot_index")

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)")
	run_done(t, store, "CREATE INDEX item_qty ON item (qty)")
	run_done(t, store, "INSERT INTO item (id, name, qty) VALUES (1, 'a', 10), (2, 'b', 20), (3, 'c', 30)")

	tx := db.tx_begin_read(store)
	frozen, frozen_err := db.tx_table(tx, "item")
	if !testing.expectf(t, db.error_ok(frozen_err), "frozen table: %s", frozen_err.message) {
		db.tx_end(tx)
		return
	}
	position := -1
	for index, i in frozen.indexes {
		if index.schema.name == "item_qty" do position = i
	}
	if !testing.expect(t, position >= 0) {
		db.tx_end(tx)
		return
	}

	run_done(t, store, "UPDATE item SET qty = 99 WHERE id = 1")
	run_done(t, store, "DELETE FROM item WHERE id = 2")
	run_done(t, store, "INSERT INTO item (id, name, qty) VALUES (4, 'd', 40)")

	testing.expect_value(t, db.table_row_count(frozen), 3)
	// The probe carries every column of the row: an index names its columns by
	// position, so `qty` is the third one.
	old_ids := db.table_index_lookup(frozen, position, []db.Value{db.value_null(), db.value_null(), db.value_int(10)})
	testing.expect_value(t, len(old_ids), 1)
	if len(old_ids) == 1 {
		// The id the frozen index names is the row whose qty is 10 in the frozen
		// table, whatever the row-id counter did.
		row, exists := frozen.rows[old_ids[0]]
		testing.expect(t, exists)
		testing.expect_value(t, row.values[2].i, i64(10))
	}
	delete(old_ids)
	new_ids := db.table_index_lookup(frozen, position, []db.Value{db.value_null(), db.value_null(), db.value_int(99)})
	testing.expect_value(t, len(new_ids), 0)
	delete(new_ids)

	live, live_err := db.store_table(store, "item")
	if testing.expect(t, db.error_ok(live_err)) {
		live_ids := db.table_index_lookup(live, position, []db.Value{db.value_null(), db.value_null(), db.value_int(99)})
		testing.expect_value(t, len(live_ids), 1)
		delete(live_ids)
	}
	db.tx_end(tx)
}

@(test)
test_snapshot_survives_dropping_the_source :: proc(t: ^testing.T) {
	// The frozen copy owns its rows, its tree nodes and its keys. A writer may
	// drop the source table while a reader holds the snapshot, and the reader must
	// still answer from what it copied: anything shared would be freed by the drop.
	store := fresh_db(t, "snapshot_drop")
	if store == nil do return
	defer cleanup_db(store, "snapshot_drop")

	run_done(t, store, "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)")
	run_done(t, store, "CREATE INDEX item_qty ON item (qty)")
	run_done(t, store, "INSERT INTO item (id, name, qty) VALUES (1, 'a', 10), (2, 'b', 20)")

	tx := db.tx_begin_read(store)
	frozen, frozen_err := db.tx_table(tx, "item")
	if !testing.expectf(t, db.error_ok(frozen_err), "frozen table: %s", frozen_err.message) {
		db.tx_end(tx)
		return
	}
	run_done(t, store, "DROP TABLE item")

	testing.expect_value(t, db.table_row_count(frozen), 2)
	position := -1
	for index, i in frozen.indexes {
		if index.schema.name == "item_qty" do position = i
	}
	if testing.expect(t, position >= 0) {
		ids := db.table_index_lookup(frozen, position, []db.Value{db.value_null(), db.value_null(), db.value_int(10)})
		testing.expect_value(t, len(ids), 1)
		delete(ids)
	}
	db.tx_end(tx)
}

@(test)
test_a_commit_copies_the_table_a_reader_holds :: proc(t: ^testing.T) {
	// A read transaction shares the tables instead of copying them, so a commit
	// that has to change one takes the copy instead. The copy is per table: the
	// table a commit does not write is the same object before and after, and a
	// commit nobody is reading copies nothing.
	store := fresh_db(t, "cow")
	if store == nil do return
	defer cleanup_db(store, "cow")

	run_done(t, store, "CREATE TABLE c (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "CREATE TABLE other (id INTEGER PRIMARY KEY, w INTEGER)")
	run_done(t, store, "INSERT INTO c (id, v) VALUES (1, 10)")
	run_done(t, store, "INSERT INTO other (id, w) VALUES (1, 20)")

	before, before_err := db.store_table(store, "c")
	if !testing.expect(t, db.error_ok(before_err)) do return
	other_before, other_err := db.store_table(store, "other")
	if !testing.expect(t, db.error_ok(other_err)) do return
	testing.expect_value(t, before.refs, 1)

	// Two readers share one object: opening a read copies nothing.
	first := db.tx_begin_read(store)
	second := db.tx_begin_read(store)
	shared_a, _ := db.tx_table(first, "c")
	shared_b, _ := db.tx_table(second, "c")
	testing.expect_value(t, shared_a, before)
	testing.expect_value(t, shared_b, before)
	testing.expect_value(t, before.refs, 3)

	run_done(t, store, "UPDATE c SET v = 11 WHERE id = 1")
	after, after_err := db.store_table(store, "c")
	if !testing.expect(t, db.error_ok(after_err)) {
		db.tx_end(first)
		db.tx_end(second)
		return
	}
	testing.expect(t, after != before)
	// The reader keeps the table it opened with, values included.
	frozen, frozen_err := db.tx_table(first, "c")
	if testing.expect(t, db.error_ok(frozen_err)) {
		seen := i64(0)
		for _, row in frozen.rows do seen = row.values[1].i
		testing.expect_value(t, seen, i64(10))
	}
	// The table the commit did not write is not copied.
	other_after, _ := db.store_table(store, "other")
	testing.expect_value(t, other_after, other_before)
	db.tx_end(first)
	db.tx_end(second)

	// With no reader open a commit writes the table in place.
	committed, committed_err := db.store_table(store, "c")
	if testing.expect(t, db.error_ok(committed_err)) {
		run_done(t, store, "UPDATE c SET v = 12 WHERE id = 1")
		again, _ := db.store_table(store, "c")
		testing.expect_value(t, again, committed)
	}
}

// A frame that has not fully arrived is not a protocol error: the transport
// reads again. Before this, a frame split across two reads closed the socket,
// which is what a client that writes a large subscribe sees on a slow link.
@(test)
test_partial_frame_waits_for_the_rest :: proc(t: ^testing.T) {
	message := []u8{'a', 'b', 'c', 'd', 'e', 'f'}
	frame := db.ws_frame(message)
	defer delete(frame)

	// One byte, then a header half, then a missing tail: all incomplete.
	cuts := []int{1, 3, 5, len(frame) - 1}
	for cut in cuts {
		_, _, _, err := db.ws_read_frame_within(frame[:cut], 0)
		defer db.error_free(&err)
		testing.expectf(t, err.kind == .Incomplete, "cut %d answered %v", cut, err.kind)
	}

	payload, consumed, opcode, err := db.ws_read_frame_within(frame, 0)
	defer delete(payload)
	testing.expect(t, db.error_ok(err))
	testing.expect_value(t, consumed, len(frame))
	testing.expect_value(t, opcode, u8(2))
	testing.expect_value(t, len(payload), len(message))

	// A frame that claims more than the cap is refused, not awaited.
	_, _, _, over := db.ws_read_frame_within(frame, len(message) - 1)
	defer db.error_free(&over)
	testing.expect_value(t, over.kind, db.Error_Kind.Quota_Exceeded)
}

// A delta is routed by the subscription that produced it: the transport asks
// which connection created it instead of guessing from the table.
@(test)
test_subscription_knows_its_connection :: proc(t: ^testing.T) {
	store := fresh_db(t, "subowner")
	if store == nil do return
	defer cleanup_db(store, "subowner")
	host := db.host_init(store)
	defer db.host_destroy(host)

	run_done(t, store, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
	run_done(t, store, "INSERT INTO items (name) VALUES ('one')")

	first, snapshot, err := db.host_subscribe_many_owned(host, []string{"SELECT id, name FROM items"}, 7)
	testing.expectf(t, db.error_ok(err), "subscribe failed: %s", err.message)
	defer db.host_snapshot_destroy(snapshot)
	testing.expect_value(t, db.host_subscription_owner(host, first), u64(7))

	second, snapshot_two, second_err := db.host_subscribe_many_owned(
		host,
		[]string{"SELECT count(*) AS n FROM items"},
		9,
	)
	testing.expectf(t, db.error_ok(second_err), "second subscribe failed: %s", second_err.message)
	defer db.host_snapshot_destroy(snapshot_two)
	testing.expect_value(t, db.host_subscription_owner(host, second), u64(9))

	// An id nobody created belongs to no connection, so nothing is written.
	testing.expect_value(t, db.host_subscription_owner(host, first + second + 100), u64(0))
}

// A database served to clients refuses the statements that reach outside it: a
// file path, a module, an export path. The embedded open still allows them,
// because the embedded caller is the host.
@(test)
test_host_statements_need_host_access :: proc(t: ^testing.T) {
	store := fresh_db(t, "hostaccess")
	if store == nil do return
	defer cleanup_db(store, "hostaccess")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
	testing.expect(t, db.store_host_access(store))

	// The file the two statements would name. ATTACH checks that it exists, so a
	// missing path would fail for the wrong reason.
	path := "_test_hostaccess_source.db"
	_ = os.write_entire_file(path, "not a database")
	defer os.remove(path)

	allowed, allowed_err := db.sql_execute(
		store,
		strings.concatenate({"ATTACH '", path, "' AS attached"}, context.temp_allocator),
	)
	defer db.sql_result_destroy(&allowed)
	defer db.error_free(&allowed_err)
	testing.expectf(t, allowed_err.kind != .None || allowed.commit_seq > 0, "%v", allowed_err)

	db.store_set_host_access(store, false)
	testing.expect(t, !db.store_host_access(store))

	// A refused statement changes nothing and says why.
	before := store.commit_seq
	refusals := []string{
		strings.concatenate({"ATTACH '", path, "' AS again"}, context.temp_allocator),
		"LOAD EXTENSION nowhere AT '127.0.0.1:1'",
		"VACUUM INTO '_test_hostaccess_out.db'",
	}
	defer os.remove("_test_hostaccess_out.db")
	for sql in refusals {
		dropped_result_13504, err := db.sql_execute(store, sql)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_13504)
		testing.expectf(t, err.kind == .Permission_Denied, "%s answered %v", sql, err.kind)
		testing.expectf(
			t,
			strings.contains(err.message, "disabled for this database"),
			"%s said %q",
			sql,
			err.message,
		)
	}
	testing.expect_value(t, store.commit_seq, before)

	// Reading, writing and DDL stay available: they are the database, not the host.
	run_done(t, store, "INSERT INTO t (v) VALUES ('still here')")
	run_done(t, store, "CREATE TABLE other (id INTEGER)")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(1))

	// Turning it back on restores the statement: the switch is a policy, not a
	// schema change.
	db.store_set_host_access(store, true)
	attached, again := db.sql_execute(store, strings.concatenate({"ATTACH '", path, "' AS third"}, context.temp_allocator))
	db.sql_result_destroy(&attached)
	testing.expect(t, again.kind != .Permission_Denied)
	db.error_free(&again)
}

// An expression may nest 100 deep and no deeper. Before this, 166 nested
// parentheses killed the process with a stack overflow and no message; the
// parser and the evaluator both refuse now, and the third check below (a chain
// that parses iteratively and only recurses when it is evaluated) proves the
// evaluator's half.
@(test)
test_expression_depth_is_bounded :: proc(t: ^testing.T) {
	store := fresh_db(t, "depth")
	if store == nil do return
	defer cleanup_db(store, "depth")

	// The statements are built in the test's temporary memory.
	deep :: proc(count: int, open_char, close_char: string) -> string {
		builder := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< count do strings.write_string(&builder, open_char)
		strings.write_string(&builder, "1")
		for _ in 0 ..< count do strings.write_string(&builder, close_char)
		strings.write_string(&builder, " AS x")
		return strings.to_string(builder)
	}

	// The outermost expression is level one, so the deepest that parses is the
	// limit minus one level of parentheses.
	at_limit, ok := db.sql_execute(store, strings.concatenate({"SELECT ", deep(db.MAX_EXPRESSION_DEPTH - 1, "(", ")")}, context.temp_allocator))
	testing.expectf(t, db.error_ok(ok), "depth %d failed: %s", db.MAX_EXPRESSION_DEPTH - 1, ok.message)
	if db.error_ok(ok) {
		testing.expect_value(t, at_limit.rows[0][0].i, i64(1))
		db.sql_result_destroy(&at_limit)
	}

	// One more is refused, with a message, and the process is still here.
	over := run_error(t, store, strings.concatenate({"SELECT ", deep(db.MAX_EXPRESSION_DEPTH, "(", ")")}, context.temp_allocator))
	testing.expect_value(t, over.kind, db.Error_Kind.Sql_Unsupported)
	testing.expectf(t, strings.contains(over.message, "nests deeper than"), "%s", over.message)

	// A `+` chain of 2000 terms parses as a left-deep tree and used to overflow
	// the stack during evaluation rather than during parsing.
	chain := strings.builder_make()
	defer strings.builder_destroy(&chain)
	strings.write_string(&chain, "SELECT 1")
	for _ in 0 ..< 2000 do strings.write_string(&chain, "+1")
	chain_err := run_error(t, store, strings.to_string(chain))
	testing.expect_value(t, chain_err.kind, db.Error_Kind.Sql_Unsupported)

	// 300 nested CASEs are the same story through a different rule.
	nested := strings.builder_make()
	defer strings.builder_destroy(&nested)
	strings.write_string(&nested, "SELECT ")
	for _ in 0 ..< 300 do strings.write_string(&nested, "CASE WHEN 1 THEN ")
	strings.write_string(&nested, "1")
	for _ in 0 ..< 300 do strings.write_string(&nested, " END")
	case_err := run_error(t, store, strings.to_string(nested))
	testing.expect_value(t, case_err.kind, db.Error_Kind.Sql_Unsupported)
}

// The row quota is read where the rows appear, not after the result is whole.
// What it still cannot do is stop the intermediate a join builds before the
// projection runs, which is the join's own work and is capped by the work budget.
@(test)
test_row_quota_refuses_while_producing :: proc(t: ^testing.T) {
	store := fresh_db(t, "quota_work")
	if store == nil do return
	defer cleanup_db(store, "quota_work")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "INSERT INTO t (id, v) VALUES ")
	for i in 1 ..= 200 {
		if i > 1 do strings.write_string(&builder, ", ")
		fmt.sbprintf(&builder, "(%d, %d)", i, i)
	}
	run_done(t, store, strings.to_string(builder))

	db.store_set_row_quota(store, 10)
	defer db.store_set_row_quota(store, 0)

	over := run_error(t, store, "SELECT * FROM t")
	testing.expect_value(t, over.kind, db.Error_Kind.Quota_Exceeded)
	testing.expectf(t, strings.contains(over.message, "more than 10 rows"), "%s", over.message)

	// A join multiplies the rows the quota has to stop.
	joined := run_error(t, store, "SELECT a.id, b.id FROM t a, t b")
	testing.expectf(t, joined.kind == .Quota_Exceeded || joined.kind == .None, "%v", joined.kind)

	// Under the quota the same statement answers, so the cap is a cap and not a
	// restriction on the query.
	small, small_err := db.sql_execute(store, "SELECT id FROM t WHERE id <= 5 ORDER BY id")
	testing.expect(t, db.error_ok(small_err))
	if db.error_ok(small_err) {
		testing.expect_value(t, len(small.rows), 5)
		db.sql_result_destroy(&small)
	}

	db.store_set_row_quota(store, 0)
	all, all_err := db.sql_execute(store, "SELECT count(*) FROM t")
	testing.expect(t, db.error_ok(all_err))
	if db.error_ok(all_err) {
		testing.expect_value(t, all.rows[0][0].i, i64(200))
		db.sql_result_destroy(&all)
	}
}

// An imported file's indexes are read, imported and then usable: a plan can walk
// one and DROP INDEX finds it. Before this the reader skipped every row of type
// `index`, so a 250 000-row import scanned and `DROP INDEX` answered
// index_not_found.
@(test)
test_imported_indexes_are_planned_and_droppable :: proc(t: ^testing.T) {
	path := "_test_indexes_imported.db"
	os.remove(path)
	defer os.remove(path)

	// Build the file with the exporter, which writes sqlite_master rows of type
	// `index` exactly as SQLite does.
	source := fresh_db(t, "indexes_source")
	if source == nil do return
	run_done(t, source, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
	run_done(t, source, "CREATE UNIQUE INDEX people_name ON people (name)")
	run_done(t, source, "CREATE INDEX people_age ON people (age)")
	run_done(t, source, "INSERT INTO people (id, name, age) VALUES (1, 'ana', 30), (2, 'bo', 40)")
	_, _, export_err := db.sqlite_file_write(source, path)
	testing.expectf(t, db.error_ok(export_err), "export: %s", export_err.message)
	db.store_close(source)
	os.remove_all("_test_indexes_source")

	file, open_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	testing.expect_value(t, len(file.indexes), 2)

	// Import it into a store and the index is there to be used.
	store, store_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(store_err), "store: %s", store_err.message) do return
	defer db.store_close(store)
	_, _, import_err := db.sqlite_import(&file, store)
	testing.expectf(t, db.error_ok(import_err), "import: %s", import_err.message)
	db.sqlite_file_destroy(&file)

	plan := run(t, store, "EXPLAIN SELECT * FROM people WHERE name = 'ana'")
	defer db.sql_result_destroy(&plan)
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	for row in plan.rows do for value in row do strings.write_string(&text, value.s)
	testing.expectf(t, strings.contains(strings.to_string(text), "people_name"), "%s", strings.to_string(text))

	list := run(t, store, "PRAGMA index_list(people)")
	defer db.sql_result_destroy(&list)
	listed := strings.builder_make()
	defer strings.builder_destroy(&listed)
	for row in list.rows do strings.write_string(&listed, row[1].s)
	testing.expect(t, strings.contains(strings.to_string(listed), "people_name"))
	testing.expect(t, strings.contains(strings.to_string(listed), "people_age"))

	drop, drop_err := db.sql_execute(store, "DROP INDEX people_age")
	if !testing.expectf(t, db.error_ok(drop_err), "drop: %s", drop_err.message) do return
	db.sql_result_destroy(&drop)
	missing := run_error(t, store, "DROP INDEX people_age")
	testing.expect_value(t, missing.kind, db.Error_Kind.Index_Not_Found)

	after := run(t, store, "PRAGMA index_list(people)")
	defer db.sql_result_destroy(&after)
	remaining := strings.builder_make()
	defer strings.builder_destroy(&remaining)
	for row in after.rows do strings.write_string(&remaining, row[1].s)
	testing.expect(t, strings.contains(strings.to_string(remaining), "people_name"))
	testing.expect(t, !strings.contains(strings.to_string(remaining), "people_age"))
}

// A database with no tables still writes a file SQLite can open: page 1 needs a
// b-tree header at offset 100, and the empty b-tree the master is built from has
// to reserve the room for it. Dropping the last table of a mirrored file takes
// exactly this path, so before the fix the file was left malformed.
@(test)
test_empty_export_is_a_readable_file :: proc(t: ^testing.T) {
	path := "_test_empty_export.db"
	os.remove(path)
	defer os.remove(path)

	store := fresh_db(t, "empty_export")
	if store == nil do return
	run_done(t, store, "CREATE TABLE only_one (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "INSERT INTO only_one (id, v) VALUES (1, 'x')")
	run_done(t, store, "DROP TABLE only_one")
	_, _, export_err := db.sqlite_file_write(store, path)
	testing.expectf(t, db.error_ok(export_err), "export: %s", export_err.message)
	db.store_close(store)
	os.remove_all("_test_empty_export")

	file, open_err := db.sqlite_file_open(path)
	if !testing.expectf(t, db.error_ok(open_err), "the empty file is not readable: %s", open_err.message) do return
	defer db.sqlite_file_destroy(&file)
	testing.expect_value(t, len(file.tables), 0)
	testing.expect_value(t, len(file.indexes), 0)

	// Page 1 must hold a leaf b-tree header after the 100-byte file header.
	data, read_err := os.read_entire_file(path, context.allocator)
	if !testing.expect(t, read_err == nil) do return
	defer delete(data)
	testing.expect_value(t, data[100], u8(13))
	testing.expect_value(t, data[100 + 3], u8(0))
	testing.expect_value(t, data[100 + 4], u8(0))
}

// A token is a row in the database, so a connection that never built a Host can
// still issue one and a later connection can check it. The key that digests are
// built with has to be the database's, or every connection would invent its own
// and no credential would survive a reopen (D25).
@(test)
test_credential_without_a_host :: proc(t: ^testing.T) {
	store := fresh_db(t, "credential")
	if store == nil do return
	path := fmt.aprintf("_test_%s", "credential")
	defer delete(path)

	identity: db.Identity
	identity[0] = 3
	identity[31] = 4
	token, issue_err := db.store_issue_token(store, identity, 0, 1_000_000)
	testing.expect(t, db.error_ok(issue_err))
	testing.expect_value(t, len(token), 67)
	// No host exists, so the metadata table that holds the key was created by
	// issuing, not by host_init.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM _meta").i, 1)

	resolved, valid := db.store_authenticate(store, token, 1_000_000)
	testing.expect(t, valid, "a token issued here is accepted here")
	testing.expect_value(t, resolved[0], u8(3))
	testing.expect_value(t, resolved[31], u8(4))

	// The clock is a parameter, so expiry is testable without waiting.
	_, early := db.store_authenticate(store, token, 999_999)
	testing.expect(t, early)
	short, short_err := db.store_issue_token(store, identity, -1, 1_000_000)
	testing.expect(t, db.error_ok(short_err))
	_, live := db.store_authenticate(store, short, 1_000_000)
	testing.expect(t, !live, "an expired token names nobody")

	// Reopening keeps the key, so the credential survives the process: this is the
	// defect the C ABI smoke caught, where every connection made a new key.
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen failed: %s", open_err.message) do return
	defer cleanup_db(reopened, "credential")
	again, survives := db.store_authenticate(reopened, token, 1_000_000)
	testing.expect(t, survives, "a token issued before the reopen is still accepted")
	testing.expect_value(t, again[31], u8(4))
	_, unknown := db.store_authenticate(reopened, "mt_00", 1_000_000)
	testing.expect(t, !unknown)
	delete(token)
	delete(short)
}

// ALTER COLUMN ... TYPE is a rewrite: every stored value is converted with CAST's
// rules, the declaration changes, and a value the conversion refuses refuses the
// whole statement. The replay of the log record runs the same conversion, so a
// reopened database agrees with the one that made the change (D9).
@(test)
test_alter_column_type :: proc(t: ^testing.T) {
	store := fresh_db(t, "alter_type")
	if store == nil do return
	path := fmt.aprintf("_test_%s", "alter_type")
	defer delete(path)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 10), (2, 20)")
	run_done(t, store, "CREATE INDEX t_v ON t (v)")

	run_done(t, store, "ALTER TABLE t ALTER COLUMN v TYPE REAL")
	testing.expect_value(t, scalar(t, store, "SELECT typeof(v) FROM t WHERE id = 1").s, "real")
	testing.expect_value(t, scalar(t, store, "SELECT v FROM t WHERE id = 2").f, 20.0)
	// The index survived the rewrite and still answers through the new type.
	testing.expect_value(t, scalar(t, store, "SELECT id FROM t WHERE v = 20.0").i, 2)

	// Real to Text, then a text that is not a number: the downgrade is refused as
	// a whole and every row keeps the type it had.
	run_done(t, store, "INSERT INTO t (id, v) VALUES (3, 30)")
	run_done(t, store, "ALTER TABLE t ALTER COLUMN v TYPE TEXT")
	testing.expect_value(t, scalar(t, store, "SELECT typeof(v) FROM t WHERE id = 1").s, "text")
	testing.expect_value(t, scalar(t, store, "SELECT v FROM t WHERE id = 2").s, "20")
	run_done(t, store, "UPDATE t SET v = 'thirty' WHERE id = 3")
	dropped_result_13920, bad := db.sql_execute(store, "ALTER TABLE t ALTER COLUMN v TYPE INTEGER")
	defer db.error_free(&bad)
	defer db.sql_result_destroy(&dropped_result_13920)
	testing.expect(t, !db.error_ok(bad), "a text that is not a number cannot become an integer")
	if !db.error_ok(bad) {
		testing.expect_value(t, bad.kind, db.Error_Kind.Invalid_Type)
		testing.expect(t, strings_contains(bad.message, "cannot become BIGINT"))
	}
	testing.expect_value(t, scalar(t, store, "SELECT typeof(v) FROM t WHERE id = 1").s, "text")

	// Two values that collide under the new type are refused by the rebuilt table.
	run_done(t, store, "CREATE TABLE u (id INTEGER PRIMARY KEY, k TEXT UNIQUE)")
	run_done(t, store, "INSERT INTO u (id, k) VALUES (1, '1'), (2, '01')")
	dropped_result_13931, collide := db.sql_execute(store, "ALTER TABLE u ALTER COLUMN k TYPE INTEGER")
	defer db.error_free(&collide)
	defer db.sql_result_destroy(&dropped_result_13931)
	testing.expect(t, !db.error_ok(collide), "a type change cannot merge unique keys")
	testing.expect_value(t, scalar(t, store, "SELECT typeof(k) FROM u WHERE id = 2").s, "text")

	// The standard's other spelling, and an unchanged type as a no-op.
	run_done(t, store, "ALTER TABLE u ALTER k SET DATA TYPE TEXT")
	run_done(t, store, "ALTER TABLE u ALTER COLUMN k TYPE TEXT")

	// A generated column is refused, because SQLite recomputes it from its
	// expression and a type would not survive a trip through the mirror.
	run_done(t, store, "CREATE TABLE g (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER GENERATED ALWAYS AS (a * 2))")
	dropped_result_13829, generated := db.sql_execute(store, "ALTER TABLE g ALTER COLUMN b TYPE REAL")
	defer db.error_free(&generated)
	defer db.sql_result_destroy(&dropped_result_13829)
	testing.expect(t, !db.error_ok(generated))
	testing.expect_value(t, generated.kind, db.Error_Kind.Sql_Unsupported)

	// Reopening replays the change through the same conversion.
	db.store_close(store)
	reopened, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "reopen failed: %s", open_err.message) do return
	defer cleanup_db(reopened, "alter_type")
	testing.expect_value(t, scalar(t, reopened, "SELECT typeof(v) FROM t WHERE id = 1").s, "text")
	testing.expect_value(t, scalar(t, reopened, "SELECT v FROM t WHERE id = 2").s, "20")
}

// A window beside GROUP BY reads the groups: the argument of an aggregate window is
// an aggregate that was already evaluated for the group, so `sum(count(*)) OVER ()`
// is the total of the per-group counts, which a subquery of the same groups answers
// too. The ranking windows read the captured keys, and ORDER BY may name either.
@(test)
test_windows_beside_group_by :: proc(t: ^testing.T) {
	store := fresh_db(t, "window_group")
	if store == nil do return
	defer cleanup_db(store, "window_group")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT, v INTEGER)")
	run_done(t, store, "INSERT INTO t (id, k, v) VALUES (1, 'a', 1), (2, 'a', 2), (3, 'b', 3), (4, 'b', 4), (5, 'c', 5)")

	// The percentage-of-total shape: the window total is 5, the same number the
	// same groups answer through a subquery.
	run_done(t, store, "SELECT k, count(*) AS n, sum(count(*)) OVER () AS total FROM t GROUP BY k")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, 5)
	result := run(t, store, "SELECT k, count(*) AS n, sum(count(*)) OVER () AS total FROM t GROUP BY k ORDER BY k")
	testing.expect_value(t, len(result.rows), 3)
	testing.expect_value(t, result.rows[0][1].i, 2)
	testing.expect_value(t, result.rows[0][2].i, 5)
	testing.expect_value(t, result.rows[2][1].i, 1)
	testing.expect_value(t, result.rows[2][2].i, 5)
	db.sql_result_destroy(&result)
	testing.expect_value(
		t,
		scalar(t, store, "WITH g AS (SELECT count(*) AS n FROM t GROUP BY k) SELECT sum(n) FROM g").i,
		5,
	)
	// avg and max over the same values.
	testing.expect_value(
		t,
		scalar(t, store, "SELECT avg(count(*)) OVER () FROM t GROUP BY k LIMIT 1").f,
		5.0 / 3.0,
	)
	testing.expect_value(t, scalar(t, store, "SELECT max(count(*)) OVER () FROM t GROUP BY k LIMIT 1").i, 2)

	// A running window is cumulative from the partition start, one row per group.
	running := run(t, store, "SELECT k, sum(count(*)) OVER (ORDER BY k) AS s FROM t GROUP BY k ORDER BY k")
	testing.expect_value(t, len(running.rows), 3)
	testing.expect_value(t, running.rows[0][1].i, 2)
	testing.expect_value(t, running.rows[1][1].i, 4)
	testing.expect_value(t, running.rows[2][1].i, 5)
	db.sql_result_destroy(&running)

	// Rank and row_number read the order key of the groups; the tie between a and b
	// is what makes them peers, so both get rank 1 and the next rank is 3.
	ranked := run(t, store, "SELECT k, rank() OVER (ORDER BY count(*) DESC) AS r FROM t GROUP BY k ORDER BY k")
	testing.expect_value(t, ranked.rows[0][1].i, 1)
	testing.expect_value(t, ranked.rows[1][1].i, 1)
	testing.expect_value(t, ranked.rows[2][1].i, 3)
	db.sql_result_destroy(&ranked)
	testing.expect_value(
		t,
		scalar(t, store, "SELECT row_number() OVER (PARTITION BY k ORDER BY k) FROM t GROUP BY k ORDER BY k LIMIT 1").i,
		1,
	)
	// first_value over the groups takes the first group's value.
	testing.expect_value(
		t,
		scalar(t, store, "SELECT first_value(count(*)) OVER (ORDER BY k) FROM t GROUP BY k ORDER BY k LIMIT 1").i,
		2,
	)

	// ORDER BY can name the window projection, and the row still answers its group.
	ordered := run(t, store, "SELECT k, count(*) AS n, sum(count(*)) OVER () AS total FROM t GROUP BY k ORDER BY total DESC, n ASC, k")
	testing.expect_value(t, ordered.rows[0][0].s, "c")
	db.sql_result_destroy(&ordered)

	// An empty group set is an empty answer, not a crash.
	empty := run(t, store, "SELECT k, count(*) AS n, sum(count(*)) OVER () FROM t WHERE id > 99 GROUP BY k")
	testing.expect_value(t, len(empty.rows), 0)
	db.sql_result_destroy(&empty)

	// A RANGE frame with an offset reads the ORDER BY value per row, and beside
	// GROUP BY that value may be an aggregate the frame can no longer reach.
	dropped_result_13917, range_err := db.sql_execute(
		store,
		"SELECT k, sum(count(*)) OVER (ORDER BY k RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t GROUP BY k",
	)
	defer db.error_free(&range_err)
	defer db.sql_result_destroy(&dropped_result_13917)
	testing.expect(t, !db.error_ok(range_err))
	testing.expect_value(t, range_err.kind, db.Error_Kind.Sql_Unsupported)

	// DISTINCT inside a window used to be parsed and dropped, so the window counted
	// every row: 2, 2 and 1 became three values instead of two.
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT count(*)) OVER () FROM t GROUP BY k LIMIT 1").i, 2)
	run_done(t, store, "CREATE TABLE d (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "INSERT INTO d (id, v) VALUES (1, 1), (2, 1), (3, 2)")
	testing.expect_value(t, scalar(t, store, "SELECT count(DISTINCT v) OVER () FROM d LIMIT 1").i, 2)
}

// A host function is SQL calling code the caller linked. The registry is consulted
// last, so a builtin keeps its name; the arity is checked before the handler runs;
// a handler reads through the group context like any other call, so it works as the
// argument of an aggregate.
@(test)
test_host_functions :: proc(t: ^testing.T) {
	store := fresh_db(t, "host_functions")
	if store == nil do return
	defer cleanup_db(store, "host_functions")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT, v INTEGER)")
	run_done(t, store, "INSERT INTO t (id, k, v) VALUES (1, 'a', 1), (2, 'a', 2), (3, 'b', 3)")

	prefix := "id:"
	twice :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
		if args[0].kind == .Null do return db.value_null(), db.ERROR_NONE
		number, ok := db.value_to_i64(args[0])
		if !ok {
			return {}, db.errf(db.Error_Kind.Invalid_Type, "twice() expects an integer")
		}
		return db.value_int(number * 2), db.ERROR_NONE
	}
	labelled :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
		tag := cast(^string)user
		text := args[0].kind == .String ? args[0].s : ""
		return db.value_string(fmt.tprintf("%s%s", tag^, text)), db.ERROR_NONE
	}
	refuse :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
		return {}, db.errf(db.Error_Kind.Invalid_Argument, "refuse() was called with %d", len(args))
	}
	testing.expect(t, db.error_ok(db.store_register_function(store, "twice", 1, twice)))
	testing.expect(t, db.error_ok(db.store_register_function(store, "labelled", 1, labelled, rawptr(&prefix))))
	testing.expect(t, db.error_ok(db.store_register_function(store, "refuse", -1, refuse)))

	testing.expect_value(t, scalar(t, store, "SELECT twice(21)").i, 42)
	testing.expect_value(t, scalar(t, store, "SELECT TWICE(4)").i, 8)
	testing.expect_value(t, scalar(t, store, "SELECT twice(1 + 1)").i, 4)
	testing.expect_value(t, scalar(t, store, "SELECT twice(NULL)").kind, db.Value_Kind.Null)
	testing.expect_value(t, scalar(t, store, "SELECT labelled('x')").s, "id:x")
	// The function runs per row, in WHERE, and as the argument of an aggregate.
	testing.expect_value(t, scalar(t, store, "SELECT twice(v) FROM t WHERE id = 2").i, 4)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE twice(v) > 2").i, 2)
	testing.expect_value(t, scalar(t, store, "SELECT sum(twice(v)) FROM t").i, 12)
	testing.expect_value(t, scalar(t, store, "SELECT twice(count(*)) FROM t GROUP BY k ORDER BY k LIMIT 1").i, 4)

	// The arity is the statement's error, and the handler's own error travels.
	bad_arity := run_error(t, store, "SELECT twice(1, 2)")
	testing.expect_value(t, bad_arity.kind, db.Error_Kind.Invalid_Argument)
	testing.expect(t, strings_contains(bad_arity.message, "wrong number of arguments to function twice()"))
	handled := run_error(t, store, "SELECT refuse(1, 2, 3)")
	testing.expect_value(t, handled.kind, db.Error_Kind.Invalid_Argument)
	testing.expect(t, strings_contains(handled.message, "refuse() was called with 3"))
	type_err := run_error(t, store, "SELECT twice('x')")
	testing.expect_value(t, type_err.kind, db.Error_Kind.Invalid_Type)

	// A builtin keeps its name: the host is asked only where the name is unknown.
	testing.expect(t, db.error_ok(db.store_register_function(store, "upper", 1, twice)))
	testing.expect_value(t, scalar(t, store, "SELECT upper('a')").s, "A")

	// Unregistering restores "unknown function", and registering nothing is a
	// refusable call rather than a crash.
	testing.expect(t, db.store_unregister_function(store, "twice"))
	testing.expect(t, !db.store_unregister_function(store, "twice"))
	unknown := run_error(t, store, "SELECT twice(1)")
	testing.expect_value(t, unknown.kind, db.Error_Kind.Sql_Unsupported)
	testing.expect(t, !db.error_drop(db.store_register_function(store, "", 0, twice)))
}

// A window can also sit inside a larger projection: its answer gets a hidden slot,
// the projection is evaluated once the windows are filled, and the node reads that
// slot. Anywhere in the tree, and nowhere that is read before the rows exist.
@(test)
test_windows_inside_expressions :: proc(t: ^testing.T) {
	store := fresh_db(t, "window_nested")
	if store == nil do return
	defer cleanup_db(store, "window_nested")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT, v INTEGER)")
	run_done(t, store, "INSERT INTO t (id, k, v) VALUES (1, 'a', 1), (2, 'a', 2), (3, 'b', 3), (4, 'b', 4), (5, 'c', 5)")

	// The list is 15 and its maximum 5.
	testing.expect_value(t, scalar(t, store, "SELECT sum(v) OVER () + 1 FROM t LIMIT 1").i, 16)
	testing.expect_value(t, scalar(t, store, "SELECT 1 + sum(v) OVER () FROM t LIMIT 1").i, 16)
	testing.expect_value(t, scalar(t, store, "SELECT sum(v) OVER () * 2 FROM t LIMIT 1").i, 30)
	testing.expect_value(t, scalar(t, store, "SELECT sum(v) OVER () + max(v) OVER () FROM t LIMIT 1").i, 20)
	// A call and a CASE are walked like a binary expression.
	testing.expect_value(t, scalar(t, store, "SELECT abs(sum(v) OVER () - 20) FROM t LIMIT 1").i, 5)
	testing.expect_value(
		t,
		scalar(t, store, "SELECT CASE WHEN sum(v) OVER () > 10 THEN 1 ELSE 0 END FROM t LIMIT 1").i,
		1,
	)
	// The value is per row, and ORDER BY may name it.
	rows := run(t, store, "SELECT id, sum(v) OVER () + v AS adj FROM t ORDER BY adj DESC, id DESC LIMIT 2")
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect_value(t, rows.rows[0][0].i, 5)
	testing.expect_value(t, rows.rows[1][1].i, 19)
	db.sql_result_destroy(&rows)

	// The percentage-of-total idiom, which needs a nested window beside GROUP BY.
	pct := run(t, store, "SELECT k, count(*) * 100.0 / sum(count(*)) OVER () AS pct FROM t GROUP BY k ORDER BY k")
	testing.expect_value(t, len(pct.rows), 3)
	testing.expect_value(t, pct.rows[0][1].f, 40.0)
	testing.expect_value(t, pct.rows[2][1].f, 20.0)
	db.sql_result_destroy(&pct)

	// A window anywhere in a projection needs the whole scan: a LIMIT may not stop
	// it, or the window answers from the rows the scan was allowed to read. The
	// pushdown itself still applies to a projection without one.
	testing.expect_value(t, scalar(t, store, "SELECT sum(v) OVER () FROM t LIMIT 1").i, 15)
	testing.expect_value(t, scalar(t, store, "SELECT max(v) OVER () FROM t LIMIT 1").i, 5)
	limited := run(t, store, "SELECT id FROM t LIMIT 2")
	testing.expect_value(t, len(limited.rows), 2)
	db.sql_result_destroy(&limited)

	// WHERE is evaluated before any row exists, so a window there stays refused.
	where_err := run_error(t, store, "SELECT id FROM t WHERE sum(v) OVER () > 0")
	testing.expect_value(t, where_err.kind, db.Error_Kind.Sql_Unsupported)
}

// Row history is kept by default, and pruning it is the caller's decision: a
// process that runs statements and exits (the CLI) drops it after every statement,
// and a pinned read keeps what it needs until it ends.
@(test)
test_prune_history_respects_a_pin :: proc(t: ^testing.T) {
	store := fresh_db(t, "prune_history")
	if store == nil do return
	defer cleanup_db(store, "prune_history")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT)")
	run_done(t, store, "INSERT INTO t (id, label) VALUES (1, 'one')")
	first := store.commit_seq
	run_done(t, store, "UPDATE t SET label = 'two' WHERE id = 1")
	testing.expect_value(t, len(store.pinned_reads), 0)

	// With a pinned read at the first commit the history it needs survives a prune,
	// which cannot even take the store's lock while the pin is alive.
	pinned := db.tx_begin_read_at(store, first)
	testing.expect_value(t, len(store.pinned_reads), 1)
	db.store_prune_history(store)
	old, old_err := db.sql_execute_in_tx(pinned, "SELECT label FROM t")
	if testing.expectf(t, db.error_ok(old_err), "pinned read failed: %s", old_err.message) {
		testing.expect_value(t, old.rows[0][0].s, "one")
		db.sql_result_destroy(&old)
	}
	db.tx_end(pinned)
	testing.expect_value(t, len(store.pinned_reads), 0)

	// With no pin the same call drops the replaced value, and the current view is
	// what a later read asks for.
	db.store_prune_history(store)
	view, view_err := db.sql_execute(store, "SELECT label FROM t")
	testing.expect(t, db.error_ok(view_err))
	testing.expect_value(t, view.rows[0][0].s, "two")
	db.sql_result_destroy(&view)
	table, found := store.tables["t"]
	testing.expect(t, found)
	if found {
		for _, row in table.rows do testing.expect_value(t, len(row.versions), 0)
	}
}

// An error message is the receiver's to free, and error_free is how. A statement
// that fails answers with one, and a process that answers failures all day has to
// give them back: before error_free existed, every refused statement left its
// message behind (tools/leakcheck measured one per REPLACE that collided).
@(test)
test_error_free_releases_the_message :: proc(t: ^testing.T) {
	store := fresh_db(t, "error_free")
	if store == nil do return
	defer cleanup_db(store, "error_free")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")

	dropped_result_14381, missing := db.sql_execute(store, "SELECT * FROM nope")
	defer db.sql_result_destroy(&dropped_result_14381)
	testing.expect(t, !db.error_ok(missing))
	testing.expectf(t, len(missing.message) > 0, "a refusal carries a message")
	db.error_free(&missing)
	testing.expect_value(t, missing.kind, db.Error_Kind.None)
	testing.expect_value(t, len(missing.message), 0)

	// The same for an error that a statement answers with and the caller drops: a
	// REPLACE that collides is not a failure, and its first attempt's message is
	// freed where it is swallowed.
	run_done(t, store, "INSERT INTO t (id, v) VALUES (1, 1)")
	run_done(t, store, "INSERT OR REPLACE INTO t (id, v) VALUES (1, 2)")
	replaced, replaced_err := db.sql_execute(store, "SELECT v FROM t WHERE id = 1")
	testing.expect(t, db.error_ok(replaced_err))
	testing.expect_value(t, replaced.rows[0][0].i, 2)
	db.sql_result_destroy(&replaced)

	// A nil error frees nothing, so a caller does not have to guard the call.
	nothing: db.Error
	db.error_free(&nothing)
	db.error_free(nil)
}

// A collation a host registers decides when two texts are equal, and SQL names it
// with COLLATE. It is used where a comparison happens; where the engine folds the
// text into a key it is refused with a message, because a host comparison has no
// folded form and answering in the wrong order would be worse than not answering.
@(private)
collation_by_length :: proc(a, b: string, user: rawptr) -> int {
	if len(a) != len(b) do return len(a) < len(b) ? -1 : 1
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

@(test)
test_host_collations :: proc(t: ^testing.T) {
	store := fresh_db(t, "host_collation")
	if store == nil do return
	defer cleanup_db(store, "host_collation")
	run_done(t, store, "CREATE TABLE w (name TEXT)")

	// A name nobody registered is refused, as SQLite refuses it: a comparison that
	// falls back to BINARY answers a question nobody asked.
	dropped_result_14267, unknown := db.sql_execute(store, "SELECT 1 WHERE 'a' = 'a' COLLATE spanish")
	defer db.error_free(&unknown)
	defer db.sql_result_destroy(&dropped_result_14267)
	testing.expect_value(t, unknown.kind, db.Error_Kind.Invalid_Argument)

	testing.expect(t, db.error_ok(db.store_register_collation(store, "by_length", collation_by_length)))
	testing.expect_value(t, db.store_collation_count(store), 1)
	// The three built-in names belong to the engine.
	reserved := db.store_register_collation(store, "NOCASE", collation_by_length)
	defer db.error_free(&reserved)
	testing.expect_value(t, reserved.kind, db.Error_Kind.Invalid_Argument)

	run_done(t, store, "INSERT INTO w (name) VALUES ('ab'), ('abc'), ('xy'), ('abcd')")
	// Equality and ordering ask the host comparison: 'ab' and 'xy' have the same
	// length and are ordered by bytes, 'abc' is longer.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM w WHERE name = 'ab' COLLATE by_length").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM w WHERE name < 'abc' COLLATE by_length").i, i64(2))
	testing.expect(t, scalar(t, store, "SELECT 'ab' = 'xy' COLLATE by_length").b == false)
	testing.expect(t, scalar(t, store, "SELECT 'ab' < 'xy' COLLATE by_length").b)
	// HAVING and CASE ask it too, because they compare.
	testing.expect_value(t, scalar(t, store, "SELECT CASE WHEN 'ab' = 'xy' COLLATE by_length THEN 1 ELSE 0 END").i, i64(0))
	// One row per length: 2 ('ab', 'xy'), 3 ('abc'), 4 ('abcd'). Only the group of
	// length 3 has a single row and a name that sorts before 'abcd' by the host
	// comparison, so the HAVING clause keeps exactly one group.
	having := run(
		t,
		store,
		"SELECT length(name) AS n FROM w GROUP BY n HAVING count(*) = 1 AND min(name) < 'abcd' COLLATE by_length",
	)
	defer db.sql_result_destroy(&having)
	testing.expect_value(t, len(having.rows), 1)
	testing.expect_value(t, having.rows[0][0].i, i64(3))

	// ORDER BY ranks the values under the host comparison, as SQLite orders
	// them: by length, then by bytes; DESC reverses it.
	ordered := run(t, store, "SELECT name FROM w ORDER BY name COLLATE by_length")
	defer db.sql_result_destroy(&ordered)
	descending := run(t, store, "SELECT name FROM w ORDER BY name COLLATE by_length DESC")
	defer db.sql_result_destroy(&descending)
	want := []string{"ab", "xy", "abc", "abcd"}
	if testing.expect_value(t, len(ordered.rows), 4) && testing.expect_value(t, len(descending.rows), 4) {
		for name, i in want {
			testing.expect_value(t, ordered.rows[i][0].s, name)
			testing.expect_value(t, descending.rows[3 - i][0].s, name)
		}
	}

	// GROUP BY and DISTINCT group by the classes the comparison makes: 'ab'
	// and 'xy' are not equal by length then bytes, so every name is its own.
	testing.expect_value(t, len(run_temp(t, store, "SELECT name FROM w GROUP BY name COLLATE by_length").rows), 4)
	testing.expect_value(t, len(run_temp(t, store, "SELECT DISTINCT name COLLATE by_length FROM w").rows), 4)
	// A window's ORDER BY ranks under it too: the running sum follows the
	// comparison's order, 'ab' (2), 'xy' (2), 'abc' (3), 'abcd' (4).
	running := run(t, store, "SELECT name, sum(length(name)) OVER (ORDER BY name COLLATE by_length) FROM w ORDER BY 2")
	defer db.sql_result_destroy(&running)
	if testing.expect_value(t, len(running.rows), 4) {
		testing.expect_value(t, running.rows[0][1].i, i64(2))
		testing.expect_value(t, running.rows[3][1].i, i64(11))
	}
	for statement in ([]string{}) {
		dropped_result_14489, refused := db.sql_execute(store, statement)
		defer db.error_free(&refused)
		defer db.sql_result_destroy(&dropped_result_14489)
		testing.expectf(
			t,
			refused.kind == db.Error_Kind.Sql_Unsupported,
			"%s should be refused, answered %s",
			statement,
			db.error_kind_name(refused.kind),
		)
	}
	// A column may carry one: its comparisons, its ORDER BY and its keys
	// follow it. An index on it is kept and not read, so a lookup still
	// compares with the collation.
	run_done(t, store, "CREATE TABLE lc (x TEXT COLLATE by_length)")
	run_done(t, store, "INSERT INTO lc VALUES ('abc'), ('ab'), ('xy')")
	testing.expect_value(t, scalar(t, store, "SELECT x FROM lc ORDER BY x LIMIT 1").s, "ab")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM lc WHERE x < 'aaa'").i, i64(2))
	dropped_result_14505, keyed := db.sql_execute(store, "CREATE TABLE keyed (x TEXT COLLATE by_length UNIQUE)")
	defer db.error_free(&keyed)
	defer db.sql_result_destroy(&dropped_result_14505)
	testing.expect_value(t, keyed.kind, db.Error_Kind.None)
	run_done(t, store, "INSERT INTO keyed VALUES ('ab')")
	testing.expect_value(t, run_error(t, store, "INSERT INTO keyed VALUES ('ab')").kind, db.Error_Kind.Duplicate_Unique)
	dropped_result_14509, indexed := db.sql_execute(store, "CREATE INDEX lc_x ON lc (x)")
	defer db.error_free(&indexed)
	defer db.sql_result_destroy(&dropped_result_14509)
	testing.expect_value(t, indexed.kind, db.Error_Kind.None)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM lc WHERE x < 'aaa'").i, i64(2))

	// The built-in names still fold: NOCASE matches 'ab' against 'AB', which the
	// host comparison would not (same length, different bytes).
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM w WHERE name = 'AB' COLLATE nocase").i, i64(1))
	testing.expect(t, scalar(t, store, "SELECT 'ab' = 'AB' COLLATE by_length").b == false)
	// Dropping it unregisters it, and the name is unknown again.
	testing.expect(t, db.store_unregister_collation(store, "By_Length"))
	testing.expect_value(t, db.store_collation_count(store), 0)
	dropped_result_14355, gone := db.sql_execute(store, "SELECT 1 WHERE 'a' = 'a' COLLATE by_length")
	defer db.error_free(&gone)
	defer db.sql_result_destroy(&dropped_result_14355)
	testing.expect_value(t, gone.kind, db.Error_Kind.Invalid_Argument)
}

// --- Integer arithmetic ----------------------------------------------------

// A 64-bit result that does not fit is an error, never a wrapped value, and the
// two quotients the hardware division traps on (min / -1 and min % -1) answer
// without killing the process. SQLite would promote to a real; PostgreSQL refuses
// with "bigint out of range", and this engine refuses too, so a caller reads the
// same reason from +, -, *, / and abs().
@(test)
test_integer_arithmetic_overflow :: proc(t: ^testing.T) {
	store := fresh_db(t, "int_overflow")
	if store == nil do return
	defer cleanup_db(store, "int_overflow")

	overflowing := []string{
		"SELECT 9223372036854775807 + 1",
		"SELECT 9223372036854775807 - (-1)",
		"SELECT 2 * 9223372036854775807",
		"SELECT (-9223372036854775808) / -1",
		"SELECT abs(-9223372036854775808)",
		"SELECT 9223372036854775807 + CAST(1 AS INTEGER)",
	}
	for statement in overflowing {
		err := run_error(t, store, statement)
		testing.expectf(t, err.kind == .Invalid_Argument, "%s answered instead of refusing", statement)
	}

	// The remainder of the same pair is zero and must not go through the trap.
	remainder := scalar(t, store, "SELECT (-9223372036854775808) % -1")
	testing.expect_value(t, remainder.i, i64(0))

	// The edges that do fit still answer.
	testing.expect_value(t, scalar(t, store, "SELECT 9223372036854775807 * 1").i, i64(max(i64)))
	testing.expect_value(t, scalar(t, store, "SELECT 4611686018427387903 * 2").i, i64(9223372036854775806))
	testing.expect_value(t, scalar(t, store, "SELECT -7 % 3").i, i64(-1))
	testing.expect_value(t, scalar(t, store, "SELECT abs(-9223372036854775807)").i, i64(max(i64)))
}

// A window inside the expression around it is not a column of the result:
// `sum(v) OVER () + 1` projects one value, not three. The answers used to live in
// slots behind the visible columns, and every output path that publishes a whole
// row -- `--json`, the SDK, the wire -- published them too.
@(test)
test_window_inside_an_expression_is_one_column :: proc(t: ^testing.T) {
	store := fresh_db(t, "window_columns")
	if store == nil do return
	defer cleanup_db(store, "window_columns")

	run_done(t, store, "CREATE TABLE t (v INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1), (2), (3), (4)")

	plain := run(t, store, "SELECT sum(v) OVER () + 1 AS s FROM t")
	defer db.sql_result_destroy(&plain)
	testing.expect_value(t, len(plain.rows), 4)
	testing.expect_value(t, len(plain.columns), 1)
	for row in plain.rows {
		testing.expect_value(t, len(row), 1)
		testing.expect_value(t, row[0].i, i64(11))
	}

	limited := run(t, store, "SELECT sum(v) OVER () + 1 AS s FROM t LIMIT 1")
	defer db.sql_result_destroy(&limited)
	testing.expect_value(t, len(limited.rows), 1)
	testing.expect_value(t, len(limited.rows[0]), 1)

	// Two windows in one expression, and a plain column beside it.
	both := run(t, store, "SELECT v, sum(v) OVER () + count(v) OVER () AS s FROM t ORDER BY v")
	defer db.sql_result_destroy(&both)
	testing.expect_value(t, len(both.rows), 4)
	testing.expect_value(t, len(both.rows[0]), 2)
	testing.expect_value(t, both.rows[0][1].i, i64(14))
}

// SQLite names the row itself `rowid`, `_rowid_` and `oid`, unless the table
// declares a column with that name. A single-column INTEGER PRIMARY KEY is the
// rowid, which is what `last_insert_rowid` already answers; any other table
// answers the engine's row id, which starts at zero where SQLite starts at one.
@(test)
test_rowid_spellings :: proc(t: ^testing.T) {
	store := fresh_db(t, "rowid_spellings")
	if store == nil do return
	defer cleanup_db(store, "rowid_spellings")

	run_done(t, store, "CREATE TABLE plain (a INTEGER)")
	run_done(t, store, "INSERT INTO plain VALUES (10), (20)")
	rows := run(t, store, "SELECT rowid, a FROM plain ORDER BY rowid")
	defer db.sql_result_destroy(&rows)
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect_value(t, rows.rows[0][0].i, i64(1))
	testing.expect_value(t, rows.rows[1][0].i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM plain WHERE rowid = 2").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT _rowid_ FROM plain WHERE a = 10").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT oid FROM plain WHERE rowid = 2").i, i64(2))

	// The INTEGER PRIMARY KEY is the rowid, and last_insert_rowid agrees.
	run_done(t, store, "CREATE TABLE keyed (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "INSERT INTO keyed VALUES (7, 'a')")
	testing.expect_value(t, scalar(t, store, "SELECT rowid FROM keyed").i, i64(7))
	testing.expect_value(t, scalar(t, store, "SELECT last_insert_rowid()").i, i64(7))

	// A column with that name wins over the alias.
	run_done(t, store, "CREATE TABLE shadow (rowid TEXT, a INTEGER)")
	run_done(t, store, "INSERT INTO shadow VALUES ('x', 1)")
	testing.expect_value(t, scalar(t, store, "SELECT rowid FROM shadow").s, "x")

	// Two tables make an unqualified rowid ambiguous, and qualifying answers.
	err := run_error(t, store, "SELECT rowid FROM plain p, plain q")
	testing.expect_value(t, err.kind, db.Error_Kind.Column_Not_Found)
	both := run(t, store, "SELECT p.rowid, q.rowid FROM plain p, plain q")
	defer db.sql_result_destroy(&both)
	testing.expect_value(t, len(both.rows), 4)
	testing.expect_value(t, len(both.rows[0]), 2)
}

// C7: an update rewrites the row it names. The stored row keeps its id, so a
// reader holding a row id, a subscription delta or a rowid finds the same row
// before and after: it is not a delete followed by an insert.
@(test)
test_update_keeps_the_row_in_place :: proc(t: ^testing.T) {
	store := fresh_db(t, "update_in_place")
	if store == nil do return
	defer cleanup_db(store, "update_in_place")

	run_done(t, store, "CREATE TABLE t (v INTEGER, note TEXT)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'a'), (2, 'b')")

	before := run(t, store, "SELECT rowid, v, note FROM t ORDER BY rowid")
	testing.expect_value(t, len(before.rows), 2)
	first_id := before.row_ids[0]
	second_id := before.row_ids[1]
	second_rowid := before.rows[1][0].i
	db.sql_result_destroy(&before)

	run_done(t, store, "UPDATE t SET note = 'z' WHERE v = 2")

	after := run(t, store, "SELECT rowid, v, note FROM t ORDER BY rowid")
	defer db.sql_result_destroy(&after)
	testing.expect_value(t, len(after.rows), 2)
	testing.expect_value(t, after.rows[1][2].s, "z")
	testing.expect_value(t, after.row_ids[1], second_id)
	testing.expect_value(t, after.rows[1][0].i, second_rowid)
	testing.expect(t, after.row_ids[0] == first_id)
	testing.expect(t, after.row_ids[1] != after.row_ids[0])

	// No row was added or removed: the update rewrote two values in place.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t").i, i64(2))
}

// D3: a log whose format this build does not read is refused by name, before a
// single record is interpreted. A newer file may hold records this build would
// misread; an older one no longer has the layout it expects.
@(test)
test_log_format_is_negotiated :: proc(t: ^testing.T) {
	path := "_test_log_version"
	os.remove_all(path)
	defer os.remove_all(path)

	store, err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	run_done(t, store, "CREATE TABLE t (v INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1)")
	db.store_close(store)

	log_path := fmt.aprintf("%s/log", path)
	defer delete(log_path)

	patch_u32_le(t, log_path, 8, db.LOG_VERSION + 1)
	newer, newer_err := db.store_open(path, {persistent = true, create = false, durable = false})
	defer db.error_free(&newer_err)
	testing.expect(t, !db.error_ok(newer_err))
	testing.expect_value(t, newer_err.kind, db.Error_Kind.Format_Too_New)
	if db.error_ok(newer_err) do db.store_close(newer)

	patch_u32_le(t, log_path, 8, db.LOG_VERSION - 1)
	older, older_err := db.store_open(path, {persistent = true, create = false, durable = false})
	defer db.error_free(&older_err)
	testing.expect(t, !db.error_ok(older_err))
	testing.expect_value(t, older_err.kind, db.Error_Kind.Corrupt_Log)
	if db.error_ok(older_err) do db.store_close(older)
}

@(private)
patch_u32_le :: proc(t: ^testing.T, path: string, offset: int, value: u32) {
	file, open_err := os.open(path, {.Read, .Write})
	if !testing.expectf(t, open_err == nil, "open %s: %v", path, open_err) do return
	defer os.close(file)
	if _, seek_err := os.seek(file, i64(offset), .Start); !testing.expectf(t, seek_err == nil, "seek: %v", seek_err) do return
	bytes := [4]u8{u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)}
	if _, write_err := os.write(file, bytes[:]); !testing.expectf(t, write_err == nil, "write: %v", write_err) do return
}

// F6: a procedure is called through the same wire endpoint as a reducer, and an
// unknown name answers an error rather than an empty result.
@(test)
test_procedure_over_the_wire :: proc(t: ^testing.T) {
	store := fresh_db(t, "wire_procedure")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "wire_procedure")

	run_done(t, store, "CREATE TABLE log (v INTEGER NOT NULL)")

	step :: proc(ctx: ^db.Procedure_Ctx, args: []db.Value) -> db.Error {
		dropped_result_14729, err := db.sql_execute_in_tx(ctx.tx, "INSERT INTO log (v) VALUES (7)")
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_14729)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register_procedure(host, "step", nil, step)))

	response := wire_ask(host, db.wire_encode_call_procedure("step", nil))
	defer delete(response)
	testing.expect_value(t, wire_kind(response), db.WIRE_RESULT)
	result, decode_err := db.wire_decode_result(response, context.allocator)
	testing.expect(t, db.error_ok(decode_err))
	db.sql_result_destroy(&result)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log").i, i64(1))

	unknown := wire_ask(host, db.wire_encode_call_procedure("nope", nil))
	defer delete(unknown)
	testing.expect_value(t, wire_kind(unknown), db.WIRE_ERROR)
}

// G4: an immediate schedule is due at the current host time, so the next tick
// runs it without waiting for a clock to advance.
@(test)
test_schedule_now :: proc(t: ^testing.T) {
	store := fresh_db(t, "schedule_now")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "schedule_now")

	run_done(t, store, "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
	run_done(t, store, "INSERT INTO counter (id, value) VALUES (0, 0)")

	bump :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
		amount, _ := db.value_to_i64(args[0])
		statement := fmt.tprintf("UPDATE counter SET value = value + %d WHERE id = 0", amount)
		dropped_result_14763, err := db.sql_execute_in_tx(ctx.tx, statement)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_14763)
		return err
	}
	testing.expect(t, db.error_ok(db.host_register(host, "bump", []db.Column_Type{db.type_int}, bump)))

	now := i64(1_700_000_000_000_000)
	host.now_us = now
	id, schedule_err := db.host_schedule_now(host, "bump", []db.Value{db.value_int(5)})
	testing.expect(t, db.error_ok(schedule_err))
	testing.expect(t, id != 0)

	// No clock advance: the schedule is already due.
	ran, tick_err := db.host_tick(host, now)
	testing.expect(t, db.error_ok(tick_err))
	testing.expect_value(t, ran, 1)
	testing.expect_value(t, scalar(t, store, "SELECT value FROM counter WHERE id = 0").i, i64(5))
}

// A RIGHT join keeps the rows of the right side that nothing matched, and a FULL
// join keeps both sides' unmatched rows; the side with no match answers NULL for
// every one of its columns, as a LEFT join already did for the other side.
@(test)
test_right_and_full_joins :: proc(t: ^testing.T) {
	store := fresh_db(t, "outer_joins")
	if store == nil do return
	defer cleanup_db(store, "outer_joins")

	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, x TEXT)")
	run_done(t, store, "CREATE TABLE b (id INTEGER PRIMARY KEY, y TEXT)")
	run_done(t, store, "INSERT INTO a VALUES (1, 'a'), (2, 'b')")
	run_done(t, store, "INSERT INTO b VALUES (2, 'y'), (3, 'z')")

	right := run(t, store, "SELECT a.id, a.x, b.id, b.y FROM a RIGHT JOIN b ON a.id = b.id ORDER BY b.id")
	defer db.sql_result_destroy(&right)
	testing.expect_value(t, len(right.rows), 2)
	testing.expect_value(t, right.rows[0][0].i, i64(2))
	testing.expect_value(t, right.rows[0][3].s, "y")
	testing.expect_value(t, right.rows[1][0].kind, db.Value_Kind.Null)
	testing.expect_value(t, right.rows[1][1].kind, db.Value_Kind.Null)
	testing.expect_value(t, right.rows[1][2].i, i64(3))

	// RIGHT OUTER is the same join, and the count is the right side's.
	counted := run(t, store, "SELECT count(*) FROM a RIGHT OUTER JOIN b ON a.id = b.id")
	testing.expect_value(t, counted.rows[0][0].i, i64(2))
	db.sql_result_destroy(&counted)

	full := run(t, store, "SELECT a.id, b.id FROM a FULL JOIN b ON a.id = b.id ORDER BY a.id")
	defer db.sql_result_destroy(&full)
	testing.expect_value(t, len(full.rows), 3)
	// ORDER BY puts the NULL first, so the right-only row leads.
	testing.expect_value(t, full.rows[0][0].kind, db.Value_Kind.Null)
	testing.expect_value(t, full.rows[0][1].i, i64(3))
	testing.expect_value(t, full.rows[1][0].i, i64(1))
	testing.expect_value(t, full.rows[1][1].kind, db.Value_Kind.Null)
	testing.expect_value(t, full.rows[2][0].i, i64(2))
	testing.expect_value(t, full.rows[2][1].i, i64(2))

	// A left side with no rows at all still answers every row of the right side,
	// with every column of the left one NULL.
	run_done(t, store, "DELETE FROM a")
	empty := run(t, store, "SELECT b.id, a.x FROM a RIGHT JOIN b ON a.id = b.id ORDER BY b.id")
	defer db.sql_result_destroy(&empty)
	testing.expect_value(t, len(empty.rows), 2)
	testing.expect_value(t, empty.rows[0][0].i, i64(2))
	testing.expect_value(t, empty.rows[0][1].kind, db.Value_Kind.Null)

	// Isolating the unmatched rows is what an outer join is for.
	unmatched := run(t, store, "SELECT b.id FROM a RIGHT JOIN b ON a.id = b.id WHERE a.id IS NULL ORDER BY b.id")
	defer db.sql_result_destroy(&unmatched)
	testing.expect_value(t, len(unmatched.rows), 2)

	// The outer half is part of the answer, so the planner leaves the order be.
	explained := run(t, store, "EXPLAIN SELECT a.id FROM a RIGHT JOIN b ON a.id = b.id")
	defer db.sql_result_destroy(&explained)
	testing.expect(t, len(explained.rows) > 0)
}

// PostgreSQL's array surface: the `ARRAY[...]` constructor, the `T[]` type
// spelling, the element accessor, the set operators and the two functions that
// report a size. The container itself existed (`ARRAY(T)` as a column type); what
// was missing was every way a client spells one.
@(test)
test_array_syntax_and_operators :: proc(t: ^testing.T) {
	store := fresh_db(t, "array_syntax")
	if store == nil do return
	defer cleanup_db(store, "array_syntax")

	literal := scalar(t, store, "SELECT ARRAY[1, 2, 3]")
	testing.expect_value(t, literal.kind, db.Value_Kind.Array)
	testing.expect_value(t, len(literal.list), 3)
	testing.expect_value(t, literal.list[2].i, i64(3))

	empty := scalar(t, store, "SELECT ARRAY[]")
	testing.expect_value(t, empty.kind, db.Value_Kind.Array)
	testing.expect_value(t, len(empty.list), 0)

	// One-based, as in PostgreSQL, and out of range is NULL rather than an error.
	testing.expect_value(t, scalar(t, store, "SELECT (ARRAY[10, 20, 30])[2]").i, i64(20))
	testing.expect_value(t, scalar(t, store, "SELECT (ARRAY[10, 20])[9]").kind, db.Value_Kind.Null)

	testing.expect_value(t, scalar(t, store, "SELECT array_length(ARRAY[1,2,3], 1)").i, i64(3))
	testing.expect_value(t, scalar(t, store, "SELECT cardinality(ARRAY[1,2])").i, i64(2))

	// `||` joins two arrays, or an array and one element on either side.
	joined := scalar(t, store, "SELECT ARRAY[1,2] || ARRAY[3]")
	testing.expect_value(t, len(joined.list), 3)
	testing.expect_value(t, joined.list[2].i, i64(3))
	appended := scalar(t, store, "SELECT ARRAY[1,2] || 3")
	testing.expect_value(t, len(appended.list), 3)
	prepended := scalar(t, store, "SELECT 0 || ARRAY[1]")
	testing.expect_value(t, prepended.list[0].i, i64(0))

	// The set operators, and SQL's two quantified comparisons.
	testing.expect_value(t, scalar(t, store, "SELECT ARRAY[1,2,3] @> ARRAY[2]").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT ARRAY[1,2,3] @> ARRAY[9]").b, false)
	testing.expect_value(t, scalar(t, store, "SELECT ARRAY[1,2,3] @> 3").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT ARRAY[1] <@ ARRAY[1,2]").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT ARRAY[1,2] && ARRAY[2]").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT ARRAY[1,2] && ARRAY[9]").b, false)
	testing.expect_value(t, scalar(t, store, "SELECT 1 = ANY(ARRAY[1,2])").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT 5 = ANY(ARRAY[1,2])").b, false)
	testing.expect_value(t, scalar(t, store, "SELECT 5 <> ALL(ARRAY[1,2])").b, true)
	testing.expect_value(t, scalar(t, store, "SELECT 1 <> ALL(ARRAY[1,2])").b, false)

	// A column declared with the PostgreSQL spelling stores and answers one.
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, tags TEXT[])")
	run_done(t, store, "INSERT INTO t VALUES (1, ARRAY['a','b']), (2, ARRAY[])")
	stored := run(t, store, "SELECT id, tags, cardinality(tags) FROM t ORDER BY id")
	defer db.sql_result_destroy(&stored)
	testing.expect_value(t, stored.rows[0][1].kind, db.Value_Kind.Array)
	testing.expect_value(t, len(stored.rows[0][1].list), 2)
	testing.expect_value(t, stored.rows[0][1].list[1].s, "b")
	testing.expect_value(t, stored.rows[0][2].i, i64(2))
	testing.expect_value(t, stored.rows[1][2].i, i64(0))

	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE tags @> ARRAY['a']").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE 'b' = ANY(tags)").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT tags[1] FROM t WHERE id = 1").s, "a")

	// The cast spelling, and the refusal that keeps an array of arrays out.
	casted := scalar(t, store, "SELECT ARRAY['x']::TEXT[]")
	testing.expect_value(t, casted.kind, db.Value_Kind.Array)
	refused := run_error(t, store, "CREATE TABLE deep (a INT[][])")
	testing.expect_value(t, refused.kind, db.Error_Kind.Sql_Unsupported)

	// `array` is still a column name: the bracket is what makes it a constructor.
	run_done(t, store, "CREATE TABLE named (array INTEGER)")
	run_done(t, store, "INSERT INTO named VALUES (7)")
	testing.expect_value(t, scalar(t, store, "SELECT array FROM named").i, i64(7))

	// array_agg is how a query builds one: NULLs are elements, an empty group is
	// NULL, and DISTINCT keeps one of each.
	run_done(t, store, "CREATE TABLE g (k TEXT, v INTEGER)")
	run_done(t, store, "INSERT INTO g VALUES ('a', 1), ('a', 2), ('b', 3), ('b', NULL)")
	grouped := run(t, store, "SELECT k, array_agg(v) FROM g GROUP BY k ORDER BY k")
	defer db.sql_result_destroy(&grouped)
	testing.expect_value(t, len(grouped.rows), 2)
	testing.expect_value(t, len(grouped.rows[0][1].list), 2)
	testing.expect_value(t, grouped.rows[1][1].list[1].kind, db.Value_Kind.Null)

	testing.expect_value(t, scalar(t, store, "SELECT array_agg(v) FROM g WHERE k = 'z'").kind, db.Value_Kind.Null)
	one_of_each := scalar(t, store, "SELECT array_agg(DISTINCT k) FROM g")
	testing.expect_value(t, len(one_of_each.list), 2)
	testing.expect_value(t, scalar(t, store, "SELECT cardinality(array_agg(v)) FROM g").i, i64(4))
}

// A driver that does not know a parameter's type sends an array as PostgreSQL
// writes one: `{a,b}` as text. PostgreSQL parses it against the target type; here
// the array on the other side of the comparison says what the elements are, and
// a text value stored into an array column is parsed the same way.
@(test)
test_array_text_form :: proc(t: ^testing.T) {
	store := fresh_db(t, "array_text")
	if store == nil do return
	defer cleanup_db(store, "array_text")

	casted := scalar(t, store, "SELECT '{1,2,3}'::INT[]")
	testing.expect_value(t, casted.kind, db.Value_Kind.Array)
	testing.expect_value(t, len(casted.list), 3)
	testing.expect_value(t, casted.list[0].i, i64(1))

	empty := scalar(t, store, "SELECT '{}'::TEXT[]")
	testing.expect_value(t, len(empty.list), 0)

	// Quoted elements keep their separators, an unquoted NULL is the null
	// element, and a quoted "NULL" is the word.
	quoted := scalar(t, store, "SELECT '{\"a,b\",\"c d\",NULL,\"NULL\"}'::TEXT[]")
	testing.expect_value(t, len(quoted.list), 4)
	testing.expect_value(t, quoted.list[0].s, "a,b")
	testing.expect_value(t, quoted.list[1].s, "c d")
	testing.expect_value(t, quoted.list[2].kind, db.Value_Kind.Null)
	testing.expect_value(t, quoted.list[3].s, "NULL")

	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, tags TEXT[])")
	run_done(t, store, "INSERT INTO t VALUES (1, '{a,b}')")
	stored := run(t, store, "SELECT tags FROM t WHERE id = 1")
	defer db.sql_result_destroy(&stored)
	testing.expect_value(t, len(stored.rows[0][0].list), 2)
	testing.expect_value(t, stored.rows[0][0].list[1].s, "b")

	// The text form compares with the array column, which is how a parameter
	// whose type the driver did not know arrives.
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE tags = '{a,b}'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE tags @> '{a}'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM t WHERE tags && '{b,c}'").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT '{a,b}' = tags FROM t").b, true)
}

// A migration drops a table and creates it again, usually in one transaction.
// The commit used to apply the create first and meet the table it was meant to
// replace ("table t already exists", with the old schema left in place), and
// dropping a table created in the same transaction freed the map's own key.
@(test)
test_drop_and_create_in_one_transaction :: proc(t: ^testing.T) {
	path := "_test_drop_create"
	os.remove_all(path)
	defer os.remove_all(path)
	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return

	run_done(t, store, "CREATE TABLE t (a INTEGER)")
	run_done(t, store, "INSERT INTO t VALUES (1)")

	// Drop, recreate with another shape, write, and commit in one transaction.
	tx := db.tx_begin_write(store)
	defer if tx != nil do db.tx_rollback(tx)
	for statement in ([]string {
		"DROP TABLE t",
		"CREATE TABLE t (a INTEGER, b TEXT)",
		"INSERT INTO t VALUES (5, 'x')",
	}) {
		dropped_result_14994, err := db.sql_execute_in_tx(tx, statement)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_14994)
		testing.expectf(t, db.error_ok(err), "%s failed: %s", statement, err.message)
	}
	// Inside the transaction the new table is the visible one, and the row that
	// was in the old one is gone.
	inside, inside_err := db.sql_execute_in_tx(tx, "SELECT a, b FROM t")
	testing.expect(t, db.error_ok(inside_err))
	testing.expect_value(t, len(inside.rows), 1)
	testing.expect_value(t, inside.rows[0][0].i, i64(5))
	testing.expect_value(t, inside.rows[0][1].s, "x")
	db.sql_result_destroy(&inside)
	testing.expect(t, db.error_ok(db.tx_commit(tx)))
	tx = nil

	// The commit applied the drop before the create: the new shape is what the
	// store has, and the log replays to the same place.
	db.store_close(store)
	reopened, reopen_err := db.store_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(reopen_err), "reopen: %s", reopen_err.message) do return
	defer db.store_close(reopened)
	rows := run(t, reopened, "SELECT a, b FROM t")
	defer db.sql_result_destroy(&rows)
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect_value(t, rows.rows[0][1].s, "x")

	// A table created and dropped inside one transaction never reaches the log.
	tx2 := db.tx_begin_write(reopened)
	defer if tx2 != nil do db.tx_rollback(tx2)
	for statement in ([]string {"CREATE TABLE gone (a INTEGER)", "DROP TABLE gone"}) {
		dropped_result_15023, err := db.sql_execute_in_tx(tx2, statement)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_15023)
		testing.expectf(t, db.error_ok(err), "%s failed: %s", statement, err.message)
	}
	testing.expect(t, db.error_ok(db.tx_commit(tx2)))
	tx2 = nil
	missing := run_error(t, reopened, "SELECT a FROM gone")
	testing.expect_value(t, missing.kind, db.Error_Kind.Table_Not_Found)

	// Create, drop and create again inside one transaction: the last one wins.
	tx3 := db.tx_begin_write(reopened)
	defer if tx3 != nil do db.tx_rollback(tx3)
	for statement in ([]string {
		"CREATE TABLE again (a INTEGER)",
		"DROP TABLE again",
		"CREATE TABLE again (b TEXT)",
		"INSERT INTO again VALUES ('y')",
	}) {
		dropped_result_15040, err := db.sql_execute_in_tx(tx3, statement)
		defer db.error_free(&err)
		defer db.sql_result_destroy(&dropped_result_15040)
		testing.expectf(t, db.error_ok(err), "%s failed: %s", statement, err.message)
	}
	testing.expect(t, db.error_ok(db.tx_commit(tx3)))
	tx3 = nil
	testing.expect_value(t, scalar(t, reopened, "SELECT b FROM again").s, "y")
}

@(test)
test_sqlite_file_keeps_its_page_size :: proc(t: ^testing.T) {
	// A SQLite file keeps the page size it has: it used to be written whole at
	// 4096 on its first commit. PRAGMA page_size takes effect at once on a file
	// with no table and at the next VACUUM otherwise, as in SQLite.
	path :: "_test_pagesize.db"
	os.remove(path)
	defer os.remove(path)
	defer os.remove(path + "-journal")
	testing.expect(t, db.sqlite_create_empty_file(path))
	page_size_of :: proc(t: ^testing.T, path: string) -> u32 {
		file, open_err := db.sqlite_file_open(path)
		if !testing.expectf(t, db.error_ok(open_err), "read %s: %s", path, open_err.message) {
			db.error_free(&open_err)
			return 0
		}
		defer db.sqlite_file_destroy(&file)
		return file.page_size
	}
	options := db.Store_Options{persistent = true, create = false, durable = false}

	conn, open_err := db.embed_open(path, options)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	testing.expect(t, db.error_drop(db.embed_exec(conn, "PRAGMA page_size = 1024")))
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA page_size").i, i64(1024))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "BEGIN")))
	for i in 1 ..= 200 {
		testing.expect(t, db.error_drop(db.embed_exec(conn, fmt.tprintf("INSERT INTO t VALUES (%d, '%s')", i, strings.repeat("x", 100, context.temp_allocator)))))
	}
	testing.expect(t, db.error_drop(db.embed_exec(conn, "COMMIT")))
	db.embed_close(conn)
	testing.expect_value(t, page_size_of(t, path), u32(1024))

	// Read back, the size is the file's, and a commit patches its pages rather
	// than writing it again.
	conn, open_err = db.embed_open(path, options)
	if !testing.expectf(t, db.error_ok(open_err), "reopen: %s", open_err.message) do return
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA page_size").i, i64(1024))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO t VALUES (201, 'late')")))
	testing.expect_value(t, conn.store.mirror_full_writes, 0)
	testing.expect_value(t, page_size_of(t, path), u32(1024))

	// On a file with tables a new size waits for VACUUM; a size SQLite would
	// not take is ignored.
	testing.expect(t, db.error_drop(db.embed_exec(conn, "PRAGMA page_size = 1000")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "PRAGMA page_size = 4096")))
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA page_size").i, i64(1024))
	testing.expect_value(t, page_size_of(t, path), u32(1024))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "VACUUM")))
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA page_size").i, i64(4096))
	testing.expect_value(t, page_size_of(t, path), u32(4096))
	// 65536 is written as 1 in the header, and reads back as 65536.
	testing.expect(t, db.error_drop(db.embed_exec(conn, "PRAGMA page_size = 65536")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "VACUUM")))
	testing.expect_value(t, page_size_of(t, path), u32(65536))
	db.embed_close(conn)

	conn, open_err = db.embed_open(path, options)
	if !testing.expectf(t, db.error_ok(open_err), "last open: %s", open_err.message) do return
	defer db.embed_close(conn)
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA page_size").i, i64(65536))
	testing.expect_value(t, scalar(t, conn.store, "SELECT count(*) FROM t").i, i64(201))
	testing.expect_value(t, scalar(t, conn.store, "SELECT body FROM t WHERE id = 201").s, "late")
}

@(test)
test_temp_tables_leave_the_sqlite_file_alone :: proc(t: ^testing.T) {
	// A TEMP table is not in the file. A write to one used to reach the mirror as
	// an unknown table and rewrite the whole file at every commit; and a
	// read-only connection refused to make one, where SQLite's temp database
	// stays writable when main is not (sqldiff --vtab makes one).
	path :: "_test_temp_mirror.db"
	os.remove(path)
	defer os.remove(path)
	testing.expect(t, db.sqlite_create_empty_file(path))
	conn, open_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO t VALUES (1, 'a')")))
	fulls := conn.store.mirror_full_writes
	writes := conn.store.mirror_pages_written
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TEMP TABLE scratch (x INTEGER)")))
	for i in 1 ..= 5 {
		testing.expect(t, db.error_drop(db.embed_exec(conn, fmt.tprintf("INSERT INTO scratch VALUES (%d)", i))))
	}
	testing.expect_value(t, conn.store.mirror_full_writes, fulls)
	testing.expect_value(t, conn.store.mirror_pages_written, writes)
	testing.expect_value(t, scalar(t, conn.store, "SELECT sum(x) FROM scratch").i, i64(15))
	db.embed_close(conn)

	// Read-only: TEMP tables are written, main is not, and the file is untouched.
	reader, reader_err := db.embed_open(path, {persistent = true, create = false, durable = false})
	if !testing.expectf(t, db.error_ok(reader_err), "read-only open: %s", reader_err.message) do return
	defer db.embed_close(reader)
	// What sqlite3_open_v2 does with SQLITE_OPEN_READONLY.
	reader.store.read_only = true
	before, before_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, before_err == nil)
	testing.expect(t, db.error_drop(db.embed_exec(reader, "CREATE TEMP TABLE pairs (k TEXT, n INTEGER)")))
	testing.expect(t, db.error_drop(db.embed_exec(reader, "INSERT INTO pairs SELECT v, id FROM t")))
	testing.expect(t, db.error_drop(db.embed_exec(reader, "UPDATE pairs SET n = n + 10")))
	testing.expect_value(t, scalar(t, reader.store, "SELECT n FROM pairs WHERE k = 'a'").i, i64(11))
	refused := db.embed_exec(reader, "INSERT INTO t VALUES (2, 'b')")
	defer db.error_free(&refused)
	testing.expect_value(t, refused.kind, db.Error_Kind.Transaction_Read_Only)
	refused_table := db.embed_exec(reader, "CREATE TABLE more (x INTEGER)")
	defer db.error_free(&refused_table)
	testing.expect_value(t, refused_table.kind, db.Error_Kind.Transaction_Read_Only)
	testing.expect(t, db.error_drop(db.embed_exec(reader, "DROP TABLE pairs")))
	after, after_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, after_err == nil)
	testing.expect(t, string(after) == string(before), "a read-only connection wrote the file")
	testing.expect_value(t, scalar(t, reader.store, "SELECT count(*) FROM t").i, i64(1))
}
