package tests

import "core:testing"

import db "../engine"

// An update that keeps a row's unique keys checks and moves none of them (R2:
// it was 55-60% of an update), and the row still holds its keys: a later row of
// the same transaction that repeats one is refused, and INSERT OR REPLACE finds
// and replaces it.

@(private = "file")
keys_row :: proc(rows: []db.Row, id: i64) -> db.Row_Id {
	for row in rows do if row.values[0].i == id do return row.id
	return db.Row_Id(max(u64))
}

@(test)
test_an_update_that_keeps_its_keys_moves_none :: proc(t: ^testing.T) {
	store := fresh_db(t, "update_keys")
	if store == nil do return
	defer cleanup_db(store, "update_keys")

	run_done(t, store, "CREATE TABLE k (id INTEGER PRIMARY KEY, code INTEGER UNIQUE, tag TEXT, n INTEGER)")
	run_done(t, store, "CREATE INDEX k_tag ON k (tag)")
	run_done(t, store, "INSERT INTO k VALUES (1, 10, 'a', 0), (2, 20, 'b', 0)")

	writer := db.tx_begin_write(store)
	rows := make([dynamic]db.Row, 0, 4)
	defer delete(rows)
	testing.expect(t, db.error_ok(db.tx_collect(writer, "k", &rows)))
	one, two := keys_row(rows[:], 1), keys_row(rows[:], 2)

	// Only `n` changes: no unique key is staged for the row.
	testing.expect(t, db.error_ok(db.tx_update(writer, "k", one, []db.Value{db.value_int(1), db.value_int(10), db.value_string("a"), db.value_int(1)})))
	testing.expect_value(t, len(writer.state.writes["k"].unique_keys), 0)

	// The committed row still holds code 10.
	_, taken := db.tx_insert(writer, "k", []db.Value{db.value_int(3), db.value_int(10), db.value_string("c"), db.value_int(0)})
	testing.expect_value(t, taken.kind, db.Error_Kind.Duplicate_Unique)
	db.error_free(&taken)

	// A row that moves its key gives the old one up.
	testing.expect(t, db.error_ok(db.tx_update(writer, "k", two, []db.Value{db.value_int(2), db.value_int(30), db.value_string("b"), db.value_int(0)})))
	_, freed := db.tx_insert(writer, "k", []db.Value{db.value_int(4), db.value_int(20), db.value_string("d"), db.value_int(0)})
	testing.expect(t, db.error_ok(freed))
	db.error_free(&freed)
	testing.expect(t, db.error_ok(db.tx_commit(writer)))

	// The indexes file every row under its key after the commit.
	testing.expect_value(t, scalar(t, store, "SELECT n FROM k WHERE code = 10").i, i64(1))
	testing.expect_value(t, scalar(t, store, "SELECT id FROM k WHERE code = 20").i, i64(4))
	testing.expect_value(t, scalar(t, store, "SELECT id FROM k WHERE code = 30").i, i64(2))
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM k WHERE tag = 'a'").i, i64(1))

	testing.expect_value(t, scalar(t, store, "PRAGMA integrity_check").s, "ok")
}

@(test)
test_insert_or_replace_finds_a_key_an_update_kept :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	script := []string{
		"CREATE TABLE k (id INTEGER PRIMARY KEY, code INTEGER UNIQUE, n INTEGER)",
		"INSERT INTO k VALUES (1, 10, 0), (2, 20, 0)",
		// The update keeps code 10; the REPLACE must still find row 1 holding it.
		"BEGIN",
		"UPDATE k SET n = 5 WHERE id = 1",
		"INSERT OR REPLACE INTO k VALUES (9, 10, 0)",
		"COMMIT",
	}
	for sql in script {
		err := db.embed_exec(conn, sql)
		testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
		db.error_free(&err)
	}
	testing.expect_value(t, scalar(t, conn.store, "SELECT count(*) FROM k WHERE code = 10").i, i64(1))
	testing.expect_value(t, scalar(t, conn.store, "SELECT id FROM k WHERE code = 10").i, i64(9))
	testing.expect_value(t, scalar(t, conn.store, "SELECT count(*) FROM k").i, i64(2))
}
