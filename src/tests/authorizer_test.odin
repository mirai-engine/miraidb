package tests

import "core:testing"

import db "../engine"

@(private = "file")
Auth_Rule :: struct {
	action: db.Auth_Action,
	column: string,
	answer: db.Auth_Answer,
	asked:  int,
}

@(private = "file")
auth_rule :: proc(ctx: rawptr, request: db.Auth_Request) -> db.Auth_Answer {
	rule := (^Auth_Rule)(ctx)
	rule.asked += 1
	if request.action != rule.action do return .Allow
	if len(rule.column) > 0 {
		column, _ := request.arg2.?
		if column != rule.column do return .Allow
	}
	return rule.answer
}

@(test)
test_authorizer :: proc(t: ^testing.T) {
	// The authorizer is asked while a statement is prepared. Deny fails the
	// prepare, Ignore on a read turns the column into NULL, and Ignore on the
	// statement's own action makes it do nothing.
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	testing.expect(t, db.error_drop(db.embed_exec(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b INTEGER)")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO t (a, b) VALUES ('p', 1)")))

	rule := Auth_Rule{action = .Read, column = "b", answer = .Deny}
	conn.store.hooks.authorizer = auth_rule
	conn.store.hooks.authorizer_ctx = &rule

	denied := db.embed_prepare(conn, "SELECT a FROM t WHERE b = 1")
	testing.expect(t, denied == nil)
	testing.expect_value(t, db.embed_error(conn), "access to t.b is prohibited")
	testing.expect_value(t, db.embed_error_kind(conn), db.Error_Kind.Permission_Denied)

	rule.answer = .Ignore
	ignored := db.embed_prepare(conn, "SELECT a, b FROM t")
	if testing.expect(t, ignored != nil) {
		has_row, step_err := db.embed_step(ignored)
		testing.expect(t, db.error_drop(step_err) && has_row)
		testing.expect_value(t, db.embed_column_text(ignored, 0), "p")
		testing.expect(t, db.embed_column_is_null(ignored, 1))
		db.embed_finalize(ignored)
	}

	rule = Auth_Rule{action = .Insert, answer = .Ignore}
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO t (a, b) VALUES ('q', 2)")))
	conn.store.hooks.authorizer = nil
	count := db.embed_prepare(conn, "SELECT count(*) FROM t")
	if testing.expect(t, count != nil) {
		_, err := db.embed_step(count)
		testing.expect(t, db.error_drop(err))
		testing.expect_value(t, db.embed_column_int(count, 0), i64(1))
		db.embed_finalize(count)
	}
	asked := rule.asked
	testing.expect(t, db.error_drop(db.embed_exec(conn, "SELECT a FROM t")))
	testing.expect_value(t, rule.asked, asked)
}
