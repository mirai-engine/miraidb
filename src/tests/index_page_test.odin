package tests

import "core:fmt"
import "core:strings"
import "core:testing"

import db "../engine"

// --- Ordered index over pages ----------------------------------------------

@(private)
ordered_key :: proc(i: int) -> string {
	return fmt.tprintf("key-%05d", i)
}

@(private)
ordered_collect :: proc(op: ^db.Ordered_Pages) -> [dynamic]string {
	keys := make([dynamic]string)
	cursor := db.ordered_seek(op, "")
	buf: [db.INDEX_PAGE_MAX_KEY]u8
	for cursor.valid {
		key, _, ok := db.ordered_cursor_read(&cursor, buf[:])
		if !ok do break
		append(&keys, strings.clone(key))
		if !db.ordered_next(&cursor) do break
	}
	return keys
}

@(test)
test_ordered_index_pages :: proc(t: ^testing.T) {
	// A B+tree over 4 KiB pages has to survive splits, a multi-level tree, a
	// pool smaller than the tree, deletions and a reopen. Every step is checked
	// against a reference list, not against itself.
	vfs := db.vfs_memory_new()
	defer db.vfs_memory_destroy(vfs)
	op, create_err := db.ordered_create(vfs, "index", 4)
	if !testing.expectf(t, db.error_ok(create_err), "create: %s", create_err.message) do return
	in_use := true
	defer {
		if in_use do db.ordered_close(op)
	}

	total :: 5000
	// Scrambled insertion order: the tree splits at different places than it
	// would with sorted input.
	for i in 0 ..< total {
		scrambled := (i * 7919) % total
		put_err := db.ordered_put(op, ordered_key(scrambled), u64(scrambled) + 1)
		if !testing.expectf(t, db.error_ok(put_err), "put %d: %s", scrambled, put_err.message) do return
	}
	testing.expect_value(t, db.ordered_entries(op), u64(total))
	testing.expect(t, op.height >= 2)

	for i in 0 ..< total {
		key := ordered_key(i)
		cursor := db.ordered_seek(op, key)
		buf: [db.INDEX_PAGE_MAX_KEY]u8
		found, value, ok := db.ordered_cursor_read(&cursor, buf[:])
		if !testing.expectf(t, ok && found == key, "seek %s", key) do return
		testing.expect_value(t, value, u64(i) + 1)
	}

	// Every key, in key order, with no duplicates or gaps.
	all := ordered_collect(op)
	defer {
		for key in all do delete(key)
		delete(all)
	}
	if testing.expect_value(t, len(all), total) {
		for key, i in all do testing.expect_value(t, key, ordered_key(i))
	}

	// Prefix lookup narrows to the matching keys.
	matches := db.ordered_lookup_prefix(op, "key-0499")
	defer delete(matches)
	testing.expect_value(t, len(matches), 10) // 04990..04999

	// A bounded range, both ends.
	ranged := db.ordered_scan(op, ordered_key(100), ordered_key(109), true)
	defer delete(ranged)
	testing.expect_value(t, len(ranged), 10)
	exclusive := db.ordered_scan(op, ordered_key(100), ordered_key(109), false)
	defer delete(exclusive)
	testing.expect_value(t, len(exclusive), 9)

	// Delete a third of the keys and confirm the survivors, not the count alone.
	remaining := make([dynamic]bool, total)
	defer delete(remaining)
	for i in 0 ..< total do remaining[i] = true
	for i := 0; i < total; i += 3 {
		if !testing.expectf(t, db.ordered_remove(op, ordered_key(i)), "remove %d", i) do return
		remaining[i] = false
	}
	testing.expect_value(t, db.ordered_entries(op), u64(total)-u64((total + 2) / 3))
	for i in 0 ..< total {
		testing.expectf(t, db.ordered_contains(op, ordered_key(i)) == remaining[i], "contains %d", i)
	}
	survivors := ordered_collect(op)
	defer {
		for key in survivors do delete(key)
		delete(survivors)
	}
	expected := make([dynamic]int)
	defer delete(expected)
	for i in 0 ..< total {
		if remaining[i] do append(&expected, i)
	}
	if testing.expect_value(t, len(survivors), len(expected)) {
		for key, i in survivors do testing.expect_value(t, key, ordered_key(expected[i]))
	}

	// Removing a key twice reports the second time as absent.
	testing.expect(t, !db.ordered_remove(op, ordered_key(3)))

	// The file must be readable after a flush and a reopen.
	flush_err := db.ordered_flush(op, 7)
	testing.expectf(t, db.error_ok(flush_err), "flush: %s", flush_err.message)
	db.ordered_close(op)
	in_use = false
	reopened, open_err := db.ordered_open(vfs, "index", 4)
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.ordered_close(reopened)
	testing.expect_value(t, db.ordered_entries(reopened), u64(len(expected)))
	for i in 0 ..< total {
		found, keep := true, remaining[i]
		_ = found
		testing.expectf(t, db.ordered_contains(reopened, ordered_key(i)) == keep, "reopened contains %d", i)
	}

	// Clearing must leave an index that answers on the next insert.
	clear_err := db.ordered_clear(reopened)
	testing.expectf(t, db.error_ok(clear_err), "clear: %s", clear_err.message)
	testing.expect_value(t, db.ordered_entries(reopened), u64(0))
	testing.expect(t, !db.ordered_contains(reopened, ordered_key(0)))
	testing.expect(t, db.error_ok(db.ordered_put(reopened, "alpha", 99)))
	testing.expect(t, db.ordered_contains(reopened, "alpha"))
	testing.expect_value(t, db.ordered_entries(reopened), u64(1))
}

@(test)
test_ordered_index_rejects_a_key_that_cannot_fit :: proc(t: ^testing.T) {
	vfs := db.vfs_memory_new()
	defer db.vfs_memory_destroy(vfs)
	op, create_err := db.ordered_create(vfs, "index", 4)
	if !testing.expectf(t, db.error_ok(create_err), "create: %s", create_err.message) do return
	defer db.ordered_close(op)
	huge := strings.repeat("x", db.INDEX_PAGE_MAX_KEY + 1, context.temp_allocator)
	put_err := db.ordered_put(op, huge, 1)
	testing.expect_value(t, put_err.kind, db.Error_Kind.Quota_Exceeded)
	testing.expect_value(t, db.ordered_entries(op), u64(0))
}
