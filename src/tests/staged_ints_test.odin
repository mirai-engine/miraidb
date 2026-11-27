package tests

import "core:math/rand"
import "core:testing"

import db "../engine"

// Staged_Ints (A2.6) answers as the map it replaced: random puts, overwrites
// and erases over few keys, so probes collide and the backward shift of an
// erase runs across the end of the array, checked against a map after every
// step, through a growth, a clear and a copy.
@(test)
test_staged_ints_answer_as_a_map :: proc(t: ^testing.T) {
	m: db.Staged_Ints
	db.staged_ints_init(&m)
	defer db.staged_ints_destroy(&m)
	model := make(map[[3]u64]db.Row_Id)
	defer delete(model)
	state := rand.create(7)
	r := rand.default_random_generator(&state)
	check :: proc(t: ^testing.T, m: ^db.Staged_Ints, model: map[[3]u64]db.Row_Id, step: int) -> bool {
		if !testing.expectf(t, db.staged_ints_len(m) == len(model), "step %d: %d keys, the map has %d", step, db.staged_ints_len(m), len(model)) do return false
		for index in 0 ..< u64(2) {
			for value in 0 ..< u64(300) {
				key := [3]u64{index, 1, value}
				want, has := model[key]
				got, found := db.staged_ints_get(m, key)
				if !testing.expectf(t, found == has && (!has || got == want), "step %d: key %v", step, key) do return false
			}
		}
		return true
	}
	for step in 0 ..< 6000 {
		key := [3]u64{rand.uint64(r) % 2, 1, rand.uint64(r) % 300}
		switch rand.uint64(r) % 3 {
		case 0, 1:
			id := db.Row_Id(rand.uint64(r) % 1000)
			db.staged_ints_put(&m, key, id)
			model[key] = id
		case 2:
			db.staged_ints_erase(&m, key)
			delete_key(&model, key)
		}
		if step % 97 == 0 && !check(t, &m, model, step) do return
		if step == 3000 {
			copied: db.Staged_Ints
			db.staged_ints_copy(&copied, &m, context.allocator)
			ok := check(t, &copied, model, step)
			db.staged_ints_destroy(&copied)
			if !ok do return
		}
	}
	if !check(t, &m, model, -1) do return
	db.staged_ints_clear(&m)
	clear(&model)
	check(t, &m, model, -2)
	db.staged_ints_put(&m, {0, 1, 5}, 9)
	got, found := db.staged_ints_get(&m, {0, 1, 5})
	testing.expect(t, found && got == 9)
}
