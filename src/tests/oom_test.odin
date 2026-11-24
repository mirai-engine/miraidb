package tests

import "core:fmt"
import "core:strings"
import "core:testing"

import db "../engine"
import face "../sqlite_compat"

// Allocation failure (D23): an allocation the system refuses fails the statement
// with Out_Of_Memory and leaves the database as the statements before it left
// it; it never ends the process.

@(private = "file")
OOM_SCRIPT := [?]string {
	"CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT UNIQUE, c)",
	"CREATE INDEX t_c ON t (c)",
	"INSERT INTO t VALUES (1, 'one', 10), (2, 'two', 20), (3, 'three', 30)",
	"CREATE TABLE log (x)",
	"CREATE TRIGGER logged AFTER UPDATE ON t BEGIN INSERT INTO log VALUES (new.a); END",
	"BEGIN",
	"UPDATE t SET b = b || '!', c = c + 1 WHERE a > 1",
	"DELETE FROM t WHERE a = 1",
	"INSERT INTO t SELECT a + 10, b || '?', c * 2 FROM t",
	"COMMIT",
	"SELECT t.b, count(*) FROM t JOIN log ON log.x = t.a WHERE c > 20 GROUP BY t.b ORDER BY 2, 1",
}

// The statements BEGIN and COMMIT are; a failure between them leaves the state
// of the statements before BEGIN once the transaction is rolled back.
@(private = "file")
OOM_BEGIN :: 5
@(private = "file")
OOM_COMMIT :: 9

@(private = "file")
oom_dump :: proc(conn: ^db.Embed_Conn) -> string {
	stmt := db.embed_prepare(conn, "SELECT group_concat(a || ':' || b || ':' || c, ',') || ' log ' || (SELECT count(*) FROM log) FROM (SELECT * FROM t ORDER BY a)")
	if stmt == nil do return "(no table)"
	defer db.embed_finalize(stmt)
	has_row, err := db.embed_step(stmt)
	if !db.error_ok(err) {
		defer db.error_free(&err)
		return fmt.tprintf("(error %v)", err.kind)
	}
	if !has_row do return "(no row)"
	return strings.clone(db.embed_column_text(stmt, 0), context.temp_allocator)
}

// test_allocation_failure_walk runs the script once for each allocation it
// makes, failing that one and every one after it, as a machine that ran out of
// memory does. Each statement either works or answers Out_Of_Memory; once the
// memory is back the connection runs again, the rollback of an open transaction
// included, and the table holds what the statements that worked committed.
@(test)
test_allocation_failure_walk :: proc(t: ^testing.T) {
	backing := context.allocator
	context.allocator = db.oom_allocator(&backing)
	// What the table holds after each statement when nothing fails.
	states: [len(OOM_SCRIPT) + 1]string
	testing.expect(t, OOM_SCRIPT[OOM_BEGIN] == "BEGIN" && OOM_SCRIPT[OOM_COMMIT] == "COMMIT")
	{
		conn, open_err := db.embed_open("", {persistent = false})
		if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
		states[0] = oom_dump(conn)
		for sql, i in OOM_SCRIPT {
			err := db.embed_exec(conn, sql)
			defer db.error_free(&err)
			if !testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message) {
				db.embed_close(conn)
				return
			}
			states[i + 1] = oom_dump(conn)
		}
		db.embed_close(conn)
	}
	walked := 0
	failures := 0
	for nth := 1; nth < 100_000; nth += 1 {
		conn, open_err := db.embed_open("", {persistent = false})
		if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
		db.oom_inject(nth)
		worked := 0
		refused := false
		for sql in OOM_SCRIPT {
			err := db.embed_exec(conn, sql)
			defer db.error_free(&err)
			if db.error_ok(err) {
				if !testing.expectf(t, !refused, "nth %d: %s worked after a refusal", nth, sql) do break
				worked += 1
				continue
			}
			if !testing.expectf(t, err.kind == .Out_Of_Memory, "nth %d: %s: %v %s", nth, sql, err.kind, err.message) do break
			refused = true
		}
		reached := db.oom_injected_calls() >= nth
		db.oom_inject(0)
		in_tx := worked > OOM_BEGIN && worked <= OOM_COMMIT
		if in_tx {
			err := db.embed_exec(conn, "ROLLBACK")
			testing.expectf(t, db.error_ok(err), "nth %d: rollback: %s", nth, err.message)
			db.error_free(&err)
		}
		want := states[in_tx ? OOM_BEGIN : worked]
		got := oom_dump(conn)
		testing.expectf(t, got == want, "nth %d, %d statements worked: got %q, want %q", nth, worked, got, want)
		if refused {
			// The memory is back: the connection writes again.
			err := db.embed_exec(conn, "CREATE TABLE after (x)")
			testing.expectf(t, db.error_ok(err), "nth %d: after: %s", nth, err.message)
			db.error_free(&err)
			failures += 1
		}
		db.embed_close(conn)
		walked = nth
		if !reached do break
		if testing.failed(t) do break
	}
	testing.expectf(t, walked > 100 && failures > 0, "the script made %d allocations, %d refused", walked, failures)
}

// Through the sqlite3_* facade a refused allocation is SQLITE_NOMEM, from
// sqlite3_exec and from sqlite3_errcode, and the handle works once memory is back.
@(test)
test_a_refused_allocation_is_sqlite_nomem :: proc(t: ^testing.T) {
	handle: rawptr
	if !testing.expect_value(t, face.sqlite3_open(":memory:", &handle), face.SQLITE_OK) do return
	defer face.sqlite3_close(handle)
	setup: cstring = "CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT); INSERT INTO t VALUES (1, 'x'), (2, 'y')"
	if !testing.expect_value(t, face.sqlite3_exec(handle, setup, nil, nil, nil), face.SQLITE_OK) do return
	refused := 0
	for nth := 1; nth < 10_000; nth += 1 {
		db.oom_inject(nth)
		rc := face.sqlite3_exec(handle, "UPDATE t SET b = b || 'z' WHERE a > 0", nil, nil, nil)
		code := face.sqlite3_errcode(handle)
		reached := db.oom_injected_calls() >= nth
		db.oom_inject(0)
		if rc != face.SQLITE_OK {
			testing.expectf(t, rc == face.SQLITE_NOMEM && code == face.SQLITE_NOMEM, "nth %d: rc %d, errcode %d", nth, rc, code)
			refused += 1
		}
		testing.expect_value(t, face.sqlite3_exec(handle, "SELECT count(*) FROM t", nil, nil, nil), face.SQLITE_OK)
		if !reached || testing.failed(t) do break
	}
	testing.expectf(t, refused > 0, "no allocation was refused")
}
