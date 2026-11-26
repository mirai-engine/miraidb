package tests

import "core:math/rand"
import "core:strings"
import "core:testing"

import db "../engine"

// A UNIQUE index over one column files its integer keys in a hash beside the
// tree, and a transaction stages them in a map of its own (R2). Both have to
// call two values one key exactly when SQLite's UNIQUE does.

@(private = "file")
ik_open :: proc(t: ^testing.T) -> ^db.Embed_Conn {
	conn, err := db.embed_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	return conn
}

@(private = "file")
ik_ok :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, loc := #caller_location) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message, loc = loc)
}

@(private = "file")
ik_taken :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, loc := #caller_location) {
	err := db.embed_exec(conn, sql)
	defer db.error_free(&err)
	testing.expectf(t, strings.contains(err.message, "UNIQUE constraint failed"), "%s: got %v %q, want a UNIQUE failure", sql, err.kind, err.message, loc = loc)
}

@(private = "file")
ik_count :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string, want: i64, loc := #caller_location) {
	got := scalar(t, conn.store, sql)
	testing.expectf(t, got.i == want, "%s: got %v, want %d", sql, got, want, loc = loc)
}

@(test)
test_integer_keys_collide_as_sqlite :: proc(t: ^testing.T) {
	conn := ik_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	ik_ok(t, conn, "CREATE TABLE f (x UNIQUE)")
	ik_ok(t, conn, "INSERT INTO f VALUES (5)")
	ik_taken(t, conn, "INSERT INTO f VALUES (5.0)")
	ik_ok(t, conn, "INSERT INTO f VALUES (5.5)")
	ik_ok(t, conn, "INSERT INTO f VALUES ('5')")
	ik_ok(t, conn, "INSERT INTO f VALUES (0)")
	ik_taken(t, conn, "INSERT INTO f VALUES (-0.0)")
	// 2^53 + 1 is no real; 2^53 is both.
	ik_ok(t, conn, "INSERT INTO f VALUES (9007199254740993)")
	ik_ok(t, conn, "INSERT INTO f VALUES (9007199254740992.0)")
	ik_taken(t, conn, "INSERT INTO f VALUES (9007199254740992)")
	// The same within one transaction, against the staged keys.
	ik_ok(t, conn, "BEGIN")
	ik_ok(t, conn, "INSERT INTO f VALUES (6.0)")
	ik_taken(t, conn, "INSERT INTO f VALUES (6)")
	ik_ok(t, conn, "INSERT INTO f VALUES (7)")
	ik_taken(t, conn, "INSERT INTO f VALUES (7.0)")
	ik_ok(t, conn, "COMMIT")
	ik_count(t, conn, "SELECT count(*) FROM f WHERE x = 5.0", 1)
	ik_count(t, conn, "SELECT count(*) FROM f WHERE x = 6", 1)
	ik_count(t, conn, "SELECT count(*) FROM f", 8)
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA integrity_check").s, "ok")
}

@(test)
test_unsigned_keys_follow_every_write :: proc(t: ^testing.T) {
	conn := ik_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	ik_ok(t, conn, "CREATE TABLE u (id UINT4 NOT NULL, n INTEGER)")
	ik_ok(t, conn, "CREATE UNIQUE INDEX u_id ON u (id)")
	ik_ok(t, conn, "INSERT INTO u VALUES (7, 0)")
	ik_taken(t, conn, "INSERT INTO u VALUES (7, 1)")
	// An update moves the key; a delete gives it up.
	ik_ok(t, conn, "UPDATE u SET id = 8 WHERE id = 7")
	ik_ok(t, conn, "INSERT INTO u VALUES (7, 2)")
	ik_taken(t, conn, "INSERT INTO u VALUES (8, 3)")
	ik_ok(t, conn, "DELETE FROM u WHERE id = 7")
	ik_ok(t, conn, "INSERT INTO u VALUES (7, 4)")
	// A statement that fails takes back the keys it staged.
	ik_ok(t, conn, "BEGIN")
	ik_taken(t, conn, "INSERT INTO u VALUES (30, 0), (8, 0)")
	ik_ok(t, conn, "INSERT INTO u VALUES (30, 5)")
	ik_taken(t, conn, "INSERT INTO u VALUES (30, 6)")
	ik_ok(t, conn, "COMMIT")
	ik_count(t, conn, "SELECT n FROM u WHERE id = 30", 5)

	table := conn.store.tables["u"]
	index := -1
	for idx, i in table.indexes do if idx.schema.name == "u_id" do index = i
	if testing.expect(t, index >= 0) {
		testing.expect(t, table.indexes[index].int_keyed)
		testing.expect_value(t, table.indexes[index].ints.count, 3)
	}

	// A commit while a reader is open writes a copy of the table: its keys
	// come along.
	reader := db.tx_begin_read(conn.store)
	ik_ok(t, conn, "INSERT INTO u VALUES (40, 0)")
	ik_taken(t, conn, "INSERT INTO u VALUES (40, 1)")
	ik_taken(t, conn, "INSERT INTO u VALUES (8, 1)")
	db.tx_end(reader)
	ik_ok(t, conn, "INSERT INTO u VALUES (41, 0)")
	ik_taken(t, conn, "INSERT INTO u VALUES (40, 2)")

	// Emptied, the table holds no key.
	ik_ok(t, conn, "DELETE FROM u")
	ik_ok(t, conn, "INSERT INTO u VALUES (8, 0)")
	ik_ok(t, conn, "INSERT INTO u VALUES (40, 0)")
	ik_count(t, conn, "SELECT count(*) FROM u", 2)
	ik_count(t, conn, "SELECT n FROM u WHERE id = 8", 0)
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA integrity_check").s, "ok")
}

@(private = "file")
ik_reader_count :: proc(t: ^testing.T, reader: ^db.Tx, sql: string, want: i64, loc := #caller_location) {
	result, err := db.sql_execute_in_tx(reader, sql)
	defer db.sql_result_destroy(&result)
	defer db.error_free(&err)
	if !testing.expectf(t, db.error_ok(err) && len(result.rows) == 1, "%s: %s", sql, err.message, loc = loc) do return
	testing.expectf(t, result.rows[0][0].i == want, "%s: got %d, want %d", sql, result.rows[0][0].i, want, loc = loc)
}

// A commit with a reader open copies the integer keys in one piece, cells,
// hashes and deleted slots as they are (R7): the copy and the original have to
// answer every key the same way, and then go their own ways.
@(test)
test_a_copied_key_map_answers_as_its_original :: proc(t: ^testing.T) {
	conn := ik_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	ik_ok(t, conn, "CREATE TABLE k (id INTEGER NOT NULL UNIQUE, n INTEGER)")
	ik_ok(t, conn, "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 3000) INSERT INTO k SELECT i, i FROM s")
	// Deleted keys leave slots behind in the map; the copy keeps them.
	ik_ok(t, conn, "DELETE FROM k WHERE id % 3 = 0")

	reader := db.tx_begin_read(conn.store)
	ik_ok(t, conn, "INSERT INTO k VALUES (3, -3), (5000, 0)")
	ik_ok(t, conn, "DELETE FROM k WHERE id = 1")
	ik_taken(t, conn, "INSERT INTO k VALUES (2999, 0)")
	ik_taken(t, conn, "INSERT INTO k VALUES (2998, 0)")

	// The writer's copy.
	table := conn.store.tables["k"]
	keyed := -1
	for idx, i in table.indexes do if idx.int_keyed do keyed = i
	if testing.expect(t, keyed >= 0) do testing.expect_value(t, table.indexes[keyed].ints.count, 2001)
	ik_count(t, conn, "SELECT count(*) FROM k WHERE id = 3", 1)
	ik_count(t, conn, "SELECT count(*) FROM k WHERE id = 1", 0)
	ik_count(t, conn, "SELECT count(*) FROM k WHERE id = 6", 0)
	ik_count(t, conn, "SELECT n FROM k WHERE id = 2999", 2999)
	// The reader's original, untouched.
	ik_reader_count(t, reader, "SELECT count(*) FROM k WHERE id = 3", 0)
	ik_reader_count(t, reader, "SELECT count(*) FROM k WHERE id = 1", 1)
	ik_reader_count(t, reader, "SELECT count(*) FROM k WHERE id = 5000", 0)
	ik_reader_count(t, reader, "SELECT count(*) FROM k", 2000)
	db.tx_end(reader)

	// Every key the copy holds is found by the key, and none it gave up is.
	ik_count(t, conn, "SELECT count(*) FROM k AS a WHERE (SELECT count(*) FROM k AS b WHERE b.id = a.id) = 1", 2001)
	ik_ok(t, conn, "INSERT INTO k VALUES (1, 1), (6, 6)")
	ik_taken(t, conn, "INSERT INTO k VALUES (3, 0)")
	ik_count(t, conn, "SELECT count(*) FROM k", 2003)
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA integrity_check").s, "ok")
}

// Int_Keys against an Odin map: random puts and removes over few keys, so
// probes collide, wrap past the end and shift back; then a copy goes its own way.
@(test)
test_integer_keys_table_answers_as_a_map :: proc(t: ^testing.T) {
	keys: db.Int_Keys
	defer db.int_keys_destroy(&keys)
	want := make(map[[2]u64]db.Row_Id)
	defer delete(want)
	gen := rand.create(7)
	context.random_generator = rand.default_random_generator(&gen)
	for step in 0 ..< 40_000 {
		key := [2]u64{u64(rand.int_max(2)), u64(rand.int_max(600))}
		id := db.Row_Id(rand.int_max(4) + 1)
		if rand.int_max(3) == 0 {
			db.int_keys_remove(&keys, key, id)
			if held, ok := want[key]; ok && held == id do delete_key(&want, key)
		} else {
			testing.expect(t, db.int_keys_put(&keys, key, id) == nil)
			want[key] = id
		}
		if step % 997 == 0 || step == 39_999 {
			testing.expect_value(t, db.int_keys_len(&keys), len(want))
			for space in u64(0) ..< 2 {
				for value in u64(0) ..< 600 {
					got, found := db.int_keys_get(&keys, {space, value})
					held, ok := want[{space, value}]
					if !testing.expectf(t, found == ok && (!ok || got == held), "step %d key %d/%d: got %v %d, want %v %d", step, space, value, found, got, ok, held) do return
				}
			}
		}
	}
	copied: db.Int_Keys
	defer db.int_keys_destroy(&copied)
	testing.expect(t, db.int_keys_clone(&copied, &keys, context.allocator) == nil)
	for key, id in want {
		got, found := db.int_keys_get(&copied, key)
		testing.expect(t, found && got == id)
		db.int_keys_remove(&copied, key, id)
	}
	testing.expect_value(t, db.int_keys_len(&copied), 0)
	testing.expect_value(t, db.int_keys_len(&keys), len(want))
	for key, id in want {
		got, found := db.int_keys_get(&keys, key)
		testing.expect(t, found && got == id)
	}
}

// An INSERT that leaves the INTEGER PRIMARY KEY out takes one past the largest
// one held. That is read off the index now, walking back from past the
// numbers, where every such insert walked every row; it has to answer as the
// walk does, negatives, deletes and a transaction's own writes included.
@(test)
test_the_next_integer_key_comes_from_the_index :: proc(t: ^testing.T) {
	conn := ik_open(t)
	if conn == nil do return
	defer db.embed_close(conn)
	ik_ok(t, conn, "CREATE TABLE p (id INTEGER PRIMARY KEY, v TEXT)")
	ik_ok(t, conn, "INSERT INTO p (id, v) VALUES (-5, 'a')")
	ik_ok(t, conn, "INSERT INTO p (v) VALUES ('b')")
	ik_count(t, conn, "SELECT id FROM p WHERE v = 'b'", -4)
	ik_ok(t, conn, "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 500) INSERT INTO p (id, v) SELECT i * 3, 'x' FROM s")
	// The largest goes; the next is one past the largest left.
	ik_ok(t, conn, "DELETE FROM p WHERE id = 1500")
	ik_ok(t, conn, "INSERT INTO p (v) VALUES ('c')")
	ik_count(t, conn, "SELECT id FROM p WHERE v = 'c'", 1498)
	// In a transaction, its own delete and its own inserts count. (The checks
	// read through the store, which waits for the transaction: they come after
	// the commit.)
	ik_ok(t, conn, "BEGIN")
	ik_ok(t, conn, "DELETE FROM p WHERE id >= 1490")
	ik_ok(t, conn, "INSERT INTO p (v) VALUES ('d')")
	ik_ok(t, conn, "INSERT INTO p (id, v) VALUES (9000, 'e')")
	ik_ok(t, conn, "INSERT INTO p (v) VALUES ('f')")
	ik_ok(t, conn, "COMMIT")
	ik_count(t, conn, "SELECT id FROM p WHERE v = 'd'", 1489)
	ik_count(t, conn, "SELECT id FROM p WHERE v = 'f'", 9001)

	// The index and the walk agree on the stored rows.
	table := conn.store.tables["p"]
	walked, walked_found := db.table_largest_int(table, 0)
	indexed, indexed_found, ok := db.table_largest_int_indexed(table, 0)
	testing.expect(t, ok)
	testing.expect_value(t, indexed_found, walked_found)
	testing.expect_value(t, indexed, walked)
	testing.expect_value(t, indexed, 9001)
	// Emptied, the table starts again at one.
	ik_ok(t, conn, "DELETE FROM p")
	ik_ok(t, conn, "INSERT INTO p (v) VALUES ('g')")
	ik_count(t, conn, "SELECT id FROM p WHERE v = 'g'", 1)
	// Without an index on the column there is nothing to read: the walk answers.
	ik_ok(t, conn, "CREATE TABLE q (n INTEGER, v TEXT)")
	_, _, q_ok := db.table_largest_int_indexed(conn.store.tables["q"], 0)
	testing.expect(t, !q_ok)
	testing.expect_value(t, scalar(t, conn.store, "PRAGMA integrity_check").s, "ok")
}
