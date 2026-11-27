package tests

import "core:testing"

import db "../engine"

// The triggers a write fires are kept by the store per table, event and timing
// for a catalog generation (trigger_list), instead of read from the catalog at
// every row: a trigger created, dropped, or created in a transaction that rolls
// back is what the next write fires, from this connection or another.

@(private = "file")
tl_open :: proc(t: ^testing.T, store: ^db.Store) -> ^db.Embed_Conn {
	return db.embed_wrap(store)
}

@(private = "file")
tl_ok :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, loc := #caller_location) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message, loc = loc)
}

@(test)
test_a_write_fires_the_triggers_its_catalog_has_now :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	one := tl_open(t, store)
	defer db.embed_close(one)
	two := tl_open(t, store)
	defer db.embed_close(two)
	logged :: proc(t: ^testing.T, store: ^db.Store, want: i64, loc := #caller_location) {
		got := scalar(t, store, "SELECT count(*) FROM log").i
		testing.expectf(t, got == want, "log has %d rows, want %d", got, want, loc = loc)
	}

	tl_ok(t, one, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
	tl_ok(t, one, "CREATE TABLE log (v INTEGER, what TEXT)")
	// No trigger yet: the empty list is the one kept.
	tl_ok(t, one, "INSERT INTO t (v) VALUES (1)")
	tl_ok(t, one, "INSERT INTO t (v) VALUES (2)")
	logged(t, store, 0)

	tl_ok(t, one, "CREATE TRIGGER t_a AFTER INSERT ON t BEGIN INSERT INTO log VALUES (NEW.v, 'a'); END")
	tl_ok(t, two, "INSERT INTO t (v) VALUES (3)")
	tl_ok(t, one, "INSERT INTO t (v) VALUES (4)")
	logged(t, store, 2)

	// A second trigger on the same event fires beside the first, in name order.
	tl_ok(t, two, "CREATE TRIGGER t_b AFTER INSERT ON t WHEN NEW.v > 4 BEGIN INSERT INTO log VALUES (NEW.v, 'b'); END")
	tl_ok(t, one, "INSERT INTO t (v) VALUES (5)")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(what, '') FROM log WHERE v = 5").s, "ab")

	tl_ok(t, one, "DROP TRIGGER t_a")
	tl_ok(t, two, "INSERT INTO t (v) VALUES (6)")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(what, '') FROM log WHERE v = 6").s, "b")

	// A trigger created inside a transaction fires in it, and not once the
	// transaction rolls back.
	tl_ok(t, one, "BEGIN")
	tl_ok(t, one, "CREATE TRIGGER t_c AFTER INSERT ON t BEGIN INSERT INTO log VALUES (NEW.v, 'c'); END")
	tl_ok(t, one, "INSERT INTO t (v) VALUES (7)")
	tl_ok(t, one, "ROLLBACK")
	tl_ok(t, one, "INSERT INTO t (v) VALUES (8)")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(what, '') FROM log WHERE v >= 7").s, "b")
	logged(t, store, 6)

	// An UPDATE OF fires by the columns its SET names, from the kept list too.
	tl_ok(t, one, "CREATE TRIGGER t_u AFTER UPDATE OF v ON t BEGIN INSERT INTO log VALUES (NEW.v, 'u'); END")
	tl_ok(t, one, "UPDATE t SET id = id WHERE id = 1")
	tl_ok(t, one, "UPDATE t SET v = 10 WHERE id = 1")
	tl_ok(t, two, "UPDATE t SET v = 11 WHERE id = 2")
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM log WHERE what = 'u'").i, i64(2))
}
