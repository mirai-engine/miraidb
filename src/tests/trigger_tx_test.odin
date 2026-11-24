package tests

import "core:strings"
import "core:testing"

import db "../engine"

// Triggers and policies against the rows of their own transaction (D11), and
// a trigger's RAISE, each checked against what SQLite answers.

@(private = "file")
trig_open :: proc(t: ^testing.T) -> ^db.Embed_Conn {
	conn, err := db.embed_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	if conn != nil {
		conn.store.sqlite_names = true
		conn.store.sqlite_rules = true
	}
	return conn
}

@(private = "file")
trig_ok :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, loc := #caller_location) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message, loc = loc)
}

@(private = "file")
trig_fails :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, kind: db.Error_Kind, message: string, loc := #caller_location) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	// The engine's syntax errors say where; the end is SQLite's text.
	testing.expectf(t, err.kind == kind && strings.has_suffix(err.message, message), "%s: got %v %q, want %v %q", sql, err.kind, err.message, kind, message, loc = loc)
}

@(private = "file")
trig_rows :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, want: string, loc := #caller_location) {
	out := strings.builder_make(context.temp_allocator)
	stmt := db.embed_prepare(conn, sql)
	if !testing.expectf(t, stmt != nil, "prepare %s: %s", sql, db.embed_error(conn), loc = loc) do return
	defer db.embed_finalize(stmt)
	first := true
	for {
		has_row, err := db.embed_step(stmt)
		if !testing.expectf(t, db.error_ok(err), "step %s: %s", sql, err.message, loc = loc) {
			db.error_free(&err)
			break
		}
		if !has_row do break
		if !first do strings.write_byte(&out, ' ')
		first = false
		for i in 0 ..< db.embed_column_count(stmt) {
			if i > 0 do strings.write_byte(&out, '|')
			if value, ok := db.embed_column_value(stmt, i); ok && value.kind != .Null {
				strings.write_string(&out, db.sqlite_value_text(value, context.temp_allocator))
			}
		}
	}
	got := strings.to_string(out)
	testing.expectf(t, got == want, "%s: got %q, want %q", sql, got, want, loc = loc)
}

// RAISE parsed as a call to a function nobody has ("no such function: RAISE"),
// so no trigger could refuse a row or skip one.
@(test)
test_a_trigger_raises_as_sqlite :: proc(t: ^testing.T) {
	conn := trig_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	trig_ok(t, conn, "CREATE TABLE t (a)")
	trig_ok(t, conn, "CREATE TRIGGER no_nine BEFORE INSERT ON t WHEN new.a = 9 BEGIN SELECT RAISE(ABORT, 'no nine'); END")
	trig_fails(t, conn, "INSERT INTO t VALUES (1), (9)", .Trigger_Raise, "no nine")
	trig_rows(t, conn, "SELECT count(*) FROM t", "0")
	// IGNORE skips the row that fired it, and the statement goes on.
	trig_ok(t, conn, "CREATE TRIGGER no_even BEFORE INSERT ON t WHEN new.a % 2 = 0 BEGIN SELECT RAISE(IGNORE); END")
	trig_ok(t, conn, "INSERT INTO t VALUES (1), (2), (3), (4)")
	trig_rows(t, conn, "SELECT changes(), group_concat(a) FROM t", "2|1,3")
	// FAIL keeps the rows the statement wrote before it.
	trig_ok(t, conn, "CREATE TRIGGER no_seven BEFORE INSERT ON t WHEN new.a = 7 BEGIN SELECT RAISE(FAIL, 'no seven'); END")
	trig_fails(t, conn, "INSERT INTO t VALUES (5), (7), (11)", .Trigger_Raise, "no seven")
	trig_rows(t, conn, "SELECT group_concat(a) FROM t", "1,3,5")
	// IGNORE in an AFTER trigger ends it; the row stays.
	trig_ok(t, conn, "CREATE TABLE log (x)")
	trig_ok(t, conn, "CREATE TRIGGER logged AFTER UPDATE ON t BEGIN INSERT INTO log VALUES (new.a); SELECT RAISE(IGNORE) WHERE new.a = 30; INSERT INTO log VALUES (-new.a); END")
	trig_ok(t, conn, "UPDATE t SET a = a * 10")
	trig_rows(t, conn, "SELECT group_concat(a) FROM t", "10,30,50")
	trig_rows(t, conn, "SELECT group_concat(x) FROM log", "10,-10,30,50,-50")
	// Outside a trigger RAISE is refused, and its message is a string literal.
	trig_fails(t, conn, "SELECT RAISE(ABORT, 'x')", .Sql_Syntax, "RAISE() may only be used within a trigger-program")
	trig_fails(t, conn, "CREATE TRIGGER bad BEFORE DELETE ON t BEGIN SELECT RAISE(ABORT, 'x' || old.a); END", .Sql_Syntax, `near "||": syntax error`)
}

// RAISE(ROLLBACK) ends the transaction it fires in, the rows before it included.
@(test)
test_a_raised_rollback_ends_the_transaction :: proc(t: ^testing.T) {
	conn := trig_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	trig_ok(t, conn, "CREATE TABLE t (a)")
	trig_ok(t, conn, "CREATE TRIGGER no_three BEFORE INSERT ON t WHEN new.a = 3 BEGIN SELECT RAISE(ROLLBACK, 'three'); END")
	trig_ok(t, conn, "BEGIN")
	trig_ok(t, conn, "INSERT INTO t VALUES (0)")
	trig_fails(t, conn, "INSERT INTO t VALUES (1), (3)", .Trigger_Raise, "three")
	trig_rows(t, conn, "SELECT count(*) FROM t", "0")
	trig_ok(t, conn, "INSERT INTO t VALUES (4)")
	trig_rows(t, conn, "SELECT group_concat(a) FROM t", "4")
}

// DROP TABLE left the table's triggers behind, and they fired on the next table
// of that name.
@(test)
test_a_dropped_table_takes_its_triggers :: proc(t: ^testing.T) {
	conn := trig_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	trig_ok(t, conn, "CREATE TABLE t (a)")
	trig_ok(t, conn, "CREATE TABLE log (x)")
	trig_ok(t, conn, "CREATE TRIGGER copied AFTER INSERT ON T BEGIN INSERT INTO log VALUES (new.a); END")
	trig_ok(t, conn, "BEGIN")
	trig_ok(t, conn, "DROP TABLE t")
	trig_rows(t, conn, "SELECT count(*) FROM sqlite_master WHERE type = 'trigger'", "0")
	trig_ok(t, conn, "ROLLBACK")
	trig_rows(t, conn, "SELECT name FROM sqlite_master WHERE type = 'trigger'", "copied")
	trig_ok(t, conn, "DROP TABLE t")
	trig_ok(t, conn, "CREATE TABLE t (a)")
	trig_ok(t, conn, "INSERT INTO t VALUES (1)")
	trig_rows(t, conn, "SELECT count(*) FROM log", "0")
}

// A trigger created, dropped or rolled back in a transaction acts on the rows
// of that transaction as SQLite's does.
@(test)
test_triggers_follow_their_transaction :: proc(t: ^testing.T) {
	conn := trig_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	trig_ok(t, conn, "CREATE TABLE t (a)")
	trig_ok(t, conn, "CREATE TABLE log (x)")
	trig_ok(t, conn, "BEGIN")
	trig_ok(t, conn, "INSERT INTO t VALUES (1)")
	trig_ok(t, conn, "CREATE TRIGGER counted AFTER INSERT ON t BEGIN INSERT INTO log SELECT count(*) FROM t; END")
	trig_ok(t, conn, "INSERT INTO t VALUES (2)")
	trig_ok(t, conn, "SAVEPOINT s")
	trig_ok(t, conn, "DROP TRIGGER counted")
	trig_ok(t, conn, "INSERT INTO t VALUES (3)")
	trig_ok(t, conn, "ROLLBACK TO s")
	trig_ok(t, conn, "INSERT INTO t VALUES (4)")
	trig_ok(t, conn, "COMMIT")
	trig_rows(t, conn, "SELECT group_concat(x) FROM log", "2,3")
	trig_ok(t, conn, "BEGIN")
	trig_ok(t, conn, "DROP TRIGGER counted")
	trig_ok(t, conn, "ROLLBACK")
	trig_ok(t, conn, "INSERT INTO t VALUES (5)")
	trig_rows(t, conn, "SELECT group_concat(x) FROM log", "2,3,4")
}

// A policy created, dropped or rolled back in a transaction holds the rest of
// that transaction, and goes with it.
@(test)
test_policies_follow_their_transaction :: proc(t: ^testing.T) {
	conn := trig_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	trig_ok(t, conn, "CREATE TABLE t (a)")
	trig_ok(t, conn, "INSERT INTO t VALUES (1), (2), (3)")
	trig_ok(t, conn, "BEGIN")
	trig_ok(t, conn, "CREATE POLICY big ON t USING (a > 1)")
	trig_rows(t, conn, "SELECT count(*) FROM t", "2")
	trig_ok(t, conn, "ROLLBACK")
	trig_rows(t, conn, "SELECT count(*) FROM t", "3")
	trig_ok(t, conn, "BEGIN")
	trig_ok(t, conn, "INSERT INTO t VALUES (0)")
	trig_ok(t, conn, "CREATE POLICY positive ON t CHECK (a > 0)")
	trig_fails(t, conn, "INSERT INTO t VALUES (-1)", .Permission_Denied, "insert into t violates a policy")
	trig_ok(t, conn, "COMMIT")
	trig_rows(t, conn, "SELECT count(*) FROM t", "4")
	trig_ok(t, conn, "BEGIN")
	trig_ok(t, conn, "DROP POLICY positive")
	trig_ok(t, conn, "INSERT INTO t VALUES (-2)")
	trig_ok(t, conn, "ROLLBACK")
	trig_fails(t, conn, "INSERT INTO t VALUES (-3)", .Permission_Denied, "insert into t violates a policy")
	// A dropped table takes its policies, as it takes its triggers.
	trig_ok(t, conn, "DROP TABLE t")
	trig_ok(t, conn, "CREATE TABLE t (a)")
	trig_ok(t, conn, "INSERT INTO t VALUES (-4)")
	trig_rows(t, conn, "SELECT count(*) FROM t", "1")
}
