package tests

import "core:math/rand"
import "core:slice"
import "core:testing"

import db "../engine"

// A memory table keeps its rows in blocks that a reader's table shares with
// the copy a commit writes (R7). They have to answer as one sorted slice, and a
// shared block has to stay as the reader saw it when the writer changes it.

@(private = "file")
rb_check :: proc(t: ^testing.T, r: ^db.Row_Blocks, want: []u64, loc := #caller_location) -> bool {
	if !testing.expect_value(t, db.rows_len(r), len(want), loc = loc) do return false
	it := db.rows_iter(r)
	i := 0
	for row in db.rows_next(&it) {
		if !testing.expectf(t, i < len(want) && u64(row.id) == want[i], "row %d is %d, want %v", i, row.id, i < len(want) ? want[i] : 0, loc = loc) do return false
		i += 1
	}
	for block in r.blocks do if !testing.expect(t, block.count > 0, loc = loc) do return false
	for id in want {
		at := db.rows_find(r, db.Row_Id(id))
		if !testing.expectf(t, at >= 0 && u64(db.rows_at(r, at).id) == id, "row %d not found", id, loc = loc) do return false
	}
	return true
}

@(test)
test_row_blocks_answer_as_one_sorted_slice :: proc(t: ^testing.T) {
	gen := rand.create(11)
	context.random_generator = rand.default_random_generator(&gen)
	r: db.Row_Blocks
	defer db.rows_destroy(&r)
	want := make([dynamic]u64)
	defer delete(want)
	// Ids in order first (appends), then ids between them (splits).
	for id in u64(1) ..= 1000 do db.rows_put(&r, db.Row{id = db.Row_Id(id * 10)})
	for id in u64(1) ..= 1000 do append(&want, id * 10)
	for _ in 0 ..< 3000 {
		id := u64(rand.int_max(20_000)) + 1
		if _, found := slice.binary_search(want[:], id); found do continue
		db.rows_put(&r, db.Row{id = db.Row_Id(id)})
		at, _ := slice.binary_search(want[:], id)
		inject_at(&want, at, id)
	}
	if !rb_check(t, &r, want[:]) do return
	for id in ([]db.Row_Id{0, 5, 20_001, 99_999}) do testing.expect_value(t, db.rows_find(&r, id), -1)
	testing.expect(t, len(r.blocks) > (len(want) + db.ROW_BLOCK - 1) / db.ROW_BLOCK)

	// A copy shares every block; a change copies the block it lands in.
	copied: db.Row_Blocks
	db.rows_share(&copied, &r)
	defer db.rows_destroy(&copied)
	before := r.blocks[0]
	testing.expect_value(t, before.refs, 2)
	row := db.rows_mut(&copied, 0)
	row.deleted_seq = 7
	append(&row.versions, db.Row_Version{created_seq = 1, deleted_seq = 7})
	testing.expect(t, copied.blocks[0] != before)
	testing.expect_value(t, before.refs, 1)
	testing.expect_value(t, db.rows_at(&r, 0).deleted_seq, 0)
	testing.expect_value(t, len(db.rows_at(&r, 0).versions), 0)
	testing.expect_value(t, len(db.rows_at(&copied, 0).versions), 1)
	// Rows put in the copy are not in the original.
	db.rows_put(&copied, db.Row{id = 7})
	db.rows_put(&copied, db.Row{id = 50_000})
	testing.expect_value(t, db.rows_find(&r, 7), -1)
	testing.expect_value(t, db.rows_find(&r, 50_000), -1)
	if !rb_check(t, &r, want[:]) do return
	testing.expect_value(t, db.rows_len(&copied), len(want) + 2)
}

// A table copied for a reader shares its blocks: the reader keeps its rows, its
// history and its deleted rows as they were while the writer updates, deletes,
// puts rows between others and prunes.
@(test)
test_a_reader_keeps_its_rows_while_the_writer_changes_shared_blocks :: proc(t: ^testing.T) {
	store, open_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.store_close(store)
	db.store_set_retention(store, {kind = .Readers})
	run_done(t, store, "CREATE TABLE r (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 2000) INSERT INTO r SELECT i * 2, 'v' || i FROM s")
	reader := db.tx_begin_read(store)
	run_done(t, store, "UPDATE r SET v = 'new' WHERE id % 6 = 0")
	run_done(t, store, "DELETE FROM r WHERE id % 10 = 0")
	run_done(t, store, "INSERT INTO r (id, v) VALUES (3, 'odd'), (1001, 'odd'), (5000, 'end')")
	run_done(t, store, "UPDATE r SET v = 'again' WHERE id < 100")

	result, err := db.sql_execute_in_tx(reader, "SELECT count(*), sum(length(v)), sum(CASE WHEN v = 'new' THEN 1 ELSE 0 END), min(id), max(id) FROM r")
	if testing.expectf(t, db.error_ok(err), "read: %s", err.message) {
		row := result.rows[0]
		testing.expect_value(t, row[0].i, 2000)
		testing.expect_value(t, row[2].i, 0)
		testing.expect_value(t, row[3].i, 2)
		testing.expect_value(t, row[4].i, 4000)
	}
	db.sql_result_destroy(&result)
	db.error_free(&err)
	db.tx_end(reader)

	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM r").i, 2000 - 400 + 3)
	testing.expect_value(t, scalar(t, store, "SELECT count(*) FROM r WHERE v = 'new'").i, 666 - 133 - 13)
	testing.expect_value(t, scalar(t, store, "SELECT v FROM r WHERE id = 1001").s, "odd")
	testing.expect_value(t, scalar(t, store, "PRAGMA integrity_check").s, "ok")
}
