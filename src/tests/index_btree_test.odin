package tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"

import db "../engine"

// A memory index is a B+tree a reader's table shares with the copy a commit
// writes (R7). It has to answer as a sorted map, and a shared copy has to stay
// as it was while the original goes on changing.

@(private = "file")
ibt_check :: proc(t: ^testing.T, tree: ^db.Index_Tree, want: map[string]db.Row_Id, label: string, loc := #caller_location) -> bool {
	keys := make([dynamic]string, context.temp_allocator)
	for key in want do append(&keys, key)
	slice.sort(keys[:])
	if !testing.expectf(t, tree.count == len(keys), "%s: count %d, want %d", label, tree.count, len(keys), loc = loc) do return false
	i := 0
	for c := db.ib_first(tree); c.valid; c.valid = db.ib_advance(&c) {
		if !testing.expectf(t, i < len(keys) && db.ib_key(&c) == keys[i], "%s: key %d is %q", label, i, db.ib_key(&c), loc = loc) do return false
		if !testing.expectf(t, db.ib_slot(&c).first == want[keys[i]], "%s: %q holds %d", label, keys[i], db.ib_slot(&c).first, loc = loc) do return false
		i += 1
	}
	if !testing.expectf(t, i == len(keys), "%s: walked %d of %d", label, i, len(keys), loc = loc) do return false
	i = len(keys) - 1
	for c := db.ib_last(tree); c.valid; c.valid = db.ib_retreat(&c) {
		if !testing.expectf(t, i >= 0 && db.ib_key(&c) == keys[i], "%s: backwards key %d is %q", label, i, db.ib_key(&c), loc = loc) do return false
		i -= 1
	}
	if !testing.expectf(t, i == -1, "%s: walked back to %d", label, i, loc = loc) do return false
	for probe in ([]string{"", "k0", "k05000", "k12345", "k99999", "z"}) {
		at, _ := slice.binary_search(keys[:], probe)
		c := db.ib_lower_bound(tree, probe)
		if at == len(keys) {
			if !testing.expectf(t, !c.valid, "%s: lower bound of %q past the end", label, probe, loc = loc) do return false
		} else {
			if !testing.expectf(t, c.valid && db.ib_key(&c) == keys[at], "%s: lower bound of %q", label, probe, loc = loc) do return false
		}
	}
	return true
}

@(test)
test_index_tree_answers_as_a_sorted_map :: proc(t: ^testing.T) {
	gen := rand.create(23)
	context.random_generator = rand.default_random_generator(&gen)
	keys, keys_err := db.key_store_make()
	if !testing.expect(t, keys_err == nil) do return
	defer db.key_store_release(keys)

	tree: db.Index_Tree
	defer db.ib_free(&tree)
	want := make(map[string]db.Row_Id)
	defer delete(want)
	copies: [dynamic]db.Index_Tree
	frozen: [dynamic]map[string]db.Row_Id
	defer {
		for &copied in copies do db.ib_free(&copied)
		delete(copies)
		for m in frozen do delete(m)
		delete(frozen)
	}
	for step in 0 ..< 30_000 {
		key := fmt.tprintf("k%05d", rand.int_max(6000))
		if rand.int_max(3) == 0 {
			if held, ok := want[key]; ok {
				testing.expect(t, db.ib_remove_id(&tree, key, held) == nil)
				delete_key(&want, key)
			} else {
				testing.expect(t, db.ib_remove_id(&tree, key, 1) == nil)
			}
		} else if key not_in want {
			slot, inserted, err := db.ib_upsert(&tree, key, keys.allocator)
			if !testing.expect(t, err == nil && inserted) do return
			id := db.Row_Id(step + 1)
			slot^ = db.Index_Slot{first = id}
			// The map keeps the tree's copy of the key: the key itself is
			// temporary.
			c := db.ib_lower_bound(&tree, key)
			want[db.ib_key(&c)] = id
		}
		// Now and then a reader takes the tree as it is; it has to stay so.
		if step % 5000 == 2500 {
			copied: db.Index_Tree
			db.ib_share(&copied, &tree)
			append(&copies, copied)
			snapshot := make(map[string]db.Row_Id)
			for k, v in want do snapshot[k] = v
			append(&frozen, snapshot)
		}
		if step % 3000 == 0 && !ibt_check(t, &tree, want, "tree") do return
	}
	if !ibt_check(t, &tree, want, "tree") do return
	for &copied, i in copies {
		if !ibt_check(t, &copied, frozen[i], fmt.tprintf("copy %d", i)) do return
	}
	// The copies go first; the tree still answers without them.
	for &copied in copies do db.ib_free(&copied)
	clear(&copies)
	if !ibt_check(t, &tree, want, "tree after the copies") do return
	// Emptied, it holds nothing.
	for key, id in want do testing.expect(t, db.ib_remove_id(&tree, key, id) == nil)
	clear(&want)
	testing.expect(t, tree.root == nil)
	testing.expect_value(t, tree.count, 0)
}
