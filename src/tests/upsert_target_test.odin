package tests

import "core:testing"

import db "../engine"

// An UPSERT answers a collision on the key its ON CONFLICT names, a UNIQUE
// column as much as the primary key, and on any key when it names none. The
// conflicting row was looked for by the primary key alone, so every upsert on
// another unique column failed with the collision it was written to answer,
// DO NOTHING included. Each answer (the error and the table after it) is
// SQLite 3.45's.

@(private = "file")
Upsert_Case :: struct {
	sql:   string,
	error: string,
	state: string,
}

@(private = "file")
UPSERT_CASES := []Upsert_Case {
	{"INSERT INTO a (k, v) VALUES (2, 'x') ON CONFLICT (k) DO UPDATE SET v = 'up'", "", "1:1:one,2:2:up"},
	{"INSERT INTO a (k, v) VALUES (2, 'x') ON CONFLICT DO UPDATE SET v = excluded.v || '!'", "", "1:1:one,2:2:x!"},
	{"INSERT INTO a (k, v) VALUES (1, 'x') ON CONFLICT (k) DO NOTHING", "", "1:1:one,2:2:x!"},
	// The target is the key the clause answers: a collision on another stands.
	{"INSERT INTO a (k, v) VALUES (1, 'x') ON CONFLICT (id) DO UPDATE SET v = 'wrong'", "UNIQUE constraint failed: a.k", "1:1:one,2:2:x!"},
	{"INSERT INTO a (id, k, v) VALUES (1, 9, 'x') ON CONFLICT (k) DO UPDATE SET v = 'wrong'", "UNIQUE constraint failed: a.id", "1:1:one,2:2:x!"},
	{"INSERT INTO a (id, k, v) VALUES (1, 9, 'x') ON CONFLICT (id) DO UPDATE SET v = 'by id'", "", "1:1:by id,2:2:x!"},
	// The second row collides with the first, staged by the same statement.
	{"INSERT INTO a (k, v) VALUES (7, 'a'), (7, 'b') ON CONFLICT (k) DO UPDATE SET v = excluded.v", "", "1:1:by id,2:2:x!,3:7:b"},
}

@(private = "file")
UPSERT_STATE :: "SELECT group_concat(id || ':' || k || ':' || v, ',') FROM (SELECT * FROM a ORDER BY id)"

@(test)
test_upsert_answers_the_key_its_target_names :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE a (id INTEGER PRIMARY KEY, k INTEGER UNIQUE, v TEXT)")
	run_done(t, store, "INSERT INTO a (k, v) VALUES (1, 'one'), (2, 'two')")
	for c, i in UPSERT_CASES {
		result, run_err := db.sql_execute(store, c.sql)
		db.sql_result_destroy(&result)
		got := run_err.message
		testing.expectf(t, got == c.error, "case %d: error %q, SQLite %q: %s", i, got, c.error, c.sql)
		db.error_free(&run_err)
		state := scalar(t, store, UPSERT_STATE)
		testing.expectf(t, state.s == c.state, "case %d: table %q, SQLite %q: %s", i, state.s, c.state, c.sql)
	}

	// A table with no primary key, and a key of two columns named in another
	// order.
	run_done(t, store, "CREATE TABLE b (k INTEGER UNIQUE, v TEXT)")
	run_done(t, store, "INSERT INTO b VALUES (1, 'one'), (2, 'two')")
	run_done(t, store, "INSERT INTO b VALUES (2, 'x') ON CONFLICT (k) DO UPDATE SET v = b.v || '+'")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(k || ':' || v, ',') FROM (SELECT * FROM b ORDER BY k)").s, "1:one,2:two+")
	run_done(t, store, "CREATE TABLE p (x INTEGER, y INTEGER, v TEXT, UNIQUE (x, y))")
	run_done(t, store, "INSERT INTO p VALUES (1, 1, 'a'), (1, 2, 'b')")
	run_done(t, store, "INSERT INTO p VALUES (1, 2, 'x') ON CONFLICT (y, x) DO UPDATE SET v = 'pair'")
	run_done(t, store, "INSERT INTO p VALUES (2, 2, 'x') ON CONFLICT (x, y) DO UPDATE SET v = 'never'")
	testing.expect_value(t, scalar(t, store, "SELECT group_concat(x || y || ':' || v, ',') FROM (SELECT * FROM p ORDER BY x, y)").s, "11:a,12:pair,22:x")
}
