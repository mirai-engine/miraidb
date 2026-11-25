package engine

import "core:mem"

// Staged_Rows holds the rows a transaction inserted into one table, by id. The
// ids a transaction hands out run upward one at a time (Table_Writes.next_row_id),
// so those rows go in an array in id order, `base` being the id of the first;
// any other id (one a statement names, below `base` or past a gap) goes in the
// map. An insert was a hash insert of an 80-byte row, rehashed twice as a batch
// of 256 grew the map, and the commit sorted the ids back into order; it is an
// append now, and the commit walks the array (R2).
//
// An id is in the array or in the map, never both: the array grows only by the
// id right after its last, and an id already in the map is overwritten there.
// A row taken out of the array leaves a hole, its id INVALID_ROW_ID.
Staged_Rows :: struct {
	dense:  [dynamic]Row,
	base:   u64,
	count:  int,
	sparse: map[Row_Id]Row,
}

srows_init :: proc(s: ^Staged_Rows, capacity: int, alloc: mem.Allocator = context.allocator) {
	s.dense = make([dynamic]Row, 0, capacity, alloc)
	s.sparse = make(map[Row_Id]Row, 0, alloc)
	s.base = 0
	s.count = 0
}

srows_destroy :: proc(s: ^Staged_Rows) {
	delete(s.dense)
	delete(s.sparse)
	s^ = {}
}

srows_clear :: proc(s: ^Staged_Rows) {
	clear(&s.dense)
	clear(&s.sparse)
	s.base = 0
	s.count = 0
}

// srows_copy gives `target` the rows of `source`, in `alloc`.
srows_copy :: proc(target: ^Staged_Rows, source: ^Staged_Rows, alloc: mem.Allocator) {
	target.dense = make([dynamic]Row, len(source.dense), alloc)
	copy(target.dense[:], source.dense[:])
	target.sparse = make(map[Row_Id]Row, len(source.sparse), alloc)
	for id, row in source.sparse do target.sparse[id] = row
	target.base = source.base
	target.count = source.count
}

srows_len :: #force_inline proc(s: ^Staged_Rows) -> int {
	return s.count
}

// srows_slot is the array slot of `id`, or nil when the array does not hold it.
@(private)
srows_slot :: #force_inline proc(s: ^Staged_Rows, id: Row_Id) -> ^Row {
	if u64(id) < s.base || u64(id) - s.base >= u64(len(s.dense)) do return nil
	return &s.dense[u64(id) - s.base]
}

// srows_ptr is the staged row `id`, to read or change in place; nil when the
// transaction inserted no such row.
srows_ptr :: proc(s: ^Staged_Rows, id: Row_Id) -> ^Row {
	if slot := srows_slot(s, id); slot != nil {
		if slot.id == INVALID_ROW_ID do return nil
		return slot
	}
	if len(s.sparse) == 0 do return nil
	if row, ok := &s.sparse[id]; ok do return row
	return nil
}

srows_get :: proc(s: ^Staged_Rows, id: Row_Id) -> (Row, bool) {
	if row := srows_ptr(s, id); row != nil do return row^, true
	return {}, false
}

srows_has :: proc(s: ^Staged_Rows, id: Row_Id) -> bool {
	return srows_ptr(s, id) != nil
}

// srows_set stages `row` under its id, replacing a row staged there before.
srows_set :: proc(s: ^Staged_Rows, row: Row) {
	id := row.id
	if slot := srows_slot(s, id); slot != nil {
		if slot.id == INVALID_ROW_ID do s.count += 1
		slot^ = row
		return
	}
	if id in s.sparse {
		s.sparse[id] = row
		return
	}
	if len(s.dense) == 0 {
		s.base = u64(id)
		append(&s.dense, row)
	} else if u64(id) == s.base + u64(len(s.dense)) {
		append(&s.dense, row)
	} else {
		s.sparse[id] = row
	}
	s.count += 1
}

// srows_erase takes the row `id` out, when it is staged.
srows_erase :: proc(s: ^Staged_Rows, id: Row_Id) {
	if slot := srows_slot(s, id); slot != nil {
		if slot.id == INVALID_ROW_ID do return
		slot^ = Row{id = INVALID_ROW_ID}
		s.count -= 1
		// A hole at the end is given back, so the next id appends again.
		for len(s.dense) > 0 && s.dense[len(s.dense) - 1].id == INVALID_ROW_ID do pop(&s.dense)
		return
	}
	if id in s.sparse {
		delete_key(&s.sparse, id)
		s.count -= 1
	}
}

// srows_ids_sorted lists the staged ids in order, in `alloc`. Without rows in
// the map the array is already in order and is read as it is.
srows_ids_sorted :: proc(s: ^Staged_Rows, alloc: mem.Allocator = context.allocator) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id, 0, s.count, alloc)
	for row in s.dense do if row.id != INVALID_ROW_ID do append(&ids, row.id)
	if len(s.sparse) > 0 {
		for id in s.sparse do append(&ids, id)
		row_ids_sort(ids[:])
	}
	return ids
}

// srows_ptrs lists the staged rows, to read or change in place: the array's in
// id order, then the map's. Nothing may be staged while the list is in use.
srows_ptrs :: proc(s: ^Staged_Rows, alloc: mem.Allocator = context.temp_allocator) -> []^Row {
	out := make([dynamic]^Row, 0, s.count, alloc)
	for &row in s.dense do if row.id != INVALID_ROW_ID do append(&out, &row)
	for _, &row in s.sparse do append(&out, &row)
	return out[:]
}
