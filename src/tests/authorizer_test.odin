package tests

import "core:strings"
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

@(private = "file")
Auth_Inner_Rule :: struct {
	inner:  string,
	column: string,
	answer: db.Auth_Answer,
	// in_view counts the questions asked about the body of view vv: the
	// strings of a request live only during the call.
	in_view: int,
}

@(private = "file")
auth_inner_rule :: proc(ctx: rawptr, request: db.Auth_Request) -> db.Auth_Answer {
	rule := (^Auth_Inner_Rule)(ctx)
	inner, has_inner := request.inner.?
	if has_inner && inner == "vv" do rule.in_view += 1
	column, _ := request.arg2.?
	if request.action != .Read || column != rule.column do return .Allow
	if len(rule.inner) > 0 && (!has_inner || inner != rule.inner) do return .Allow
	return rule.answer
}

@(private = "file")
auth_text :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) -> (texts: [dynamic]string) {
	texts = make([dynamic]string)
	stmt := db.embed_prepare(conn, sql)
	if !testing.expectf(t, stmt != nil, "prepare %s: %s", sql, db.embed_error(conn)) do return
	defer db.embed_finalize(stmt)
	for {
		has_row, err := db.embed_step(stmt)
		if !testing.expect(t, db.error_drop(err)) || !has_row do break
		for i in 0 ..< db.embed_column_count(stmt) {
			// The text belongs to the statement, which is finalized before return.
			append(&texts, strings.clone(db.embed_column_is_null(stmt, i) ? "NULL" : db.embed_column_text(stmt, i)))
		}
	}
	return
}

@(test)
test_authorizer_star_view_trigger :: proc(t: ^testing.T) {
	// An Ignore reaches a column read through `*`, inside a view, and inside a
	// trigger's body each time it fires; the view or trigger is the sixth
	// argument of the questions about its body.
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	for sql in ([]string {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b INTEGER)",
		"CREATE TABLE log (x TEXT)",
		"CREATE VIEW vv AS SELECT a, b FROM t WHERE b > 0",
		"CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.a); END",
		"INSERT INTO t (a, b) VALUES ('p', 1)",
	}) {
		testing.expectf(t, db.error_drop(db.embed_exec(conn, sql)), "%s: %s", sql, db.embed_error(conn))
	}
	rule := Auth_Inner_Rule{column = "b", answer = .Ignore}
	conn.store.hooks.authorizer = auth_inner_rule
	conn.store.hooks.authorizer_ctx = &rule

	star := auth_text(t, conn, "SELECT * FROM t")
	testing.expect(t, len(star) == 3 && star[2] == "NULL")
	auth_texts_delete(star)
	// Inside the view b is NULL, so its WHERE keeps no row.
	view := auth_text(t, conn, "SELECT a FROM vv")
	testing.expect_value(t, len(view), 0)
	auth_texts_delete(view)
	testing.expect(t, rule.in_view > 0)

	rule = Auth_Inner_Rule{inner = "tr", column = "a", answer = .Ignore}
	testing.expect(t, db.error_drop(db.embed_exec(conn, "INSERT INTO t (a, b) VALUES ('q', 2)")))
	conn.store.hooks.authorizer = nil
	logged := auth_text(t, conn, "SELECT x FROM log ORDER BY rowid")
	testing.expect(t, len(logged) == 2 && logged[0] == "p" && logged[1] == "NULL")
	auth_texts_delete(logged)
}

@(private = "file")
auth_texts_delete :: proc(texts: [dynamic]string) {
	for text in texts do delete(text)
	delete(texts)
}
