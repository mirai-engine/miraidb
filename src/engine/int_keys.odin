package engine

import "core:mem"

// Int_Keys files the row that holds each integer key of an index (Index.ints):
// an open-addressed table with linear probing, its slots in one slice. It was an
// Odin map, whose hashes are seeded with the address of its cells, so a copy had
// to file every key again: 10-48 ms of a commit over 50 000 rows with a reader
// open (R7). A slot's place here depends on its key alone, so a copy is the
// slice, copied as it is. A key taken out moves the keys after it back into the
// gap (backward shift), so the table never holds a deleted slot and a probe ends
// at the first empty one.
Int_Keys :: struct {
	slots:     []Int_Key_Slot,
	count:     int,
	allocator: mem.Allocator,
}

// Int_Key_Slot is one key and its row; a slot whose id is INVALID_ROW_ID is empty.
Int_Key_Slot :: struct {
	key: [2]u64,
	id:  Row_Id,
}

INT_KEYS_FIRST :: 16

@(private)
int_keys_hash :: #force_inline proc "contextless" (key: [2]u64) -> u64 {
	// The key spaces are 0 and 1 (index_int_key); the value is mixed with the
	// finalizer of MurmurHash3, so consecutive ids land apart.
	h := key[1] ~ (key[0] * 0x9e3779b97f4a7c15)
	h ~= h >> 33
	h *= 0xff51afd7ed558ccd
	h ~= h >> 33
	h *= 0xc4ceb9fe1a85ec53
	h ~= h >> 33
	return h
}

@(private)
int_keys_alloc :: proc(capacity: int, allocator: mem.Allocator) -> ([]Int_Key_Slot, mem.Allocator_Error) {
	slots, err := make([]Int_Key_Slot, capacity, allocator)
	if err != nil do return nil, err
	// Every byte 0xff makes every id INVALID_ROW_ID: all slots empty.
	mem.set(raw_data(slots), 0xff, capacity * size_of(Int_Key_Slot))
	return slots, nil
}

int_keys_destroy :: proc(m: ^Int_Keys) {
	if m.slots != nil do delete(m.slots, m.allocator)
	m^ = {}
}

int_keys_len :: #force_inline proc "contextless" (m: ^Int_Keys) -> int {
	return m.count
}

// int_keys_get is the row filed under `key`.
int_keys_get :: proc "contextless" (m: ^Int_Keys, key: [2]u64) -> (id: Row_Id, found: bool) {
	if m.count == 0 do return 0, false
	mask := u64(len(m.slots) - 1)
	for i := int_keys_hash(key) & mask; ; i = (i + 1) & mask {
		slot := &m.slots[i]
		if slot.id == INVALID_ROW_ID do return 0, false
		if slot.key == key do return slot.id, true
	}
}

// int_keys_put files `id` under `key`, replacing the row filed there before.
int_keys_put :: proc(m: ^Int_Keys, key: [2]u64, id: Row_Id) -> mem.Allocator_Error {
	// At most five eighths full, so a probe stays short.
	if (m.count + 1) * 8 > len(m.slots) * 5 do int_keys_grow(m) or_return
	mask := u64(len(m.slots) - 1)
	for i := int_keys_hash(key) & mask; ; i = (i + 1) & mask {
		slot := &m.slots[i]
		if slot.id == INVALID_ROW_ID {
			slot^ = Int_Key_Slot{key = key, id = id}
			m.count += 1
			return nil
		}
		if slot.key == key {
			slot.id = id
			return nil
		}
	}
}

@(private)
int_keys_grow :: proc(m: ^Int_Keys) -> mem.Allocator_Error {
	if m.allocator.procedure == nil do m.allocator = context.allocator
	capacity := max(INT_KEYS_FIRST, len(m.slots) * 2)
	slots := int_keys_alloc(capacity, m.allocator) or_return
	mask := u64(capacity - 1)
	for old in m.slots {
		if old.id == INVALID_ROW_ID do continue
		i := int_keys_hash(old.key) & mask
		for slots[i].id != INVALID_ROW_ID do i = (i + 1) & mask
		slots[i] = old
	}
	if m.slots != nil do delete(m.slots, m.allocator)
	m.slots = slots
	return nil
}

// int_keys_remove takes `key` out when `id` is the row filed under it.
int_keys_remove :: proc "contextless" (m: ^Int_Keys, key: [2]u64, id: Row_Id) {
	if m.count == 0 do return
	mask := u64(len(m.slots) - 1)
	gap := int_keys_hash(key) & mask
	for {
		slot := &m.slots[gap]
		if slot.id == INVALID_ROW_ID do return
		if slot.key == key {
			if slot.id != id do return
			break
		}
		gap = (gap + 1) & mask
	}
	// Each key after the gap that may sit in it (its home is not between the
	// gap and its own slot) moves back, and its slot is the gap now.
	for next := (gap + 1) & mask; m.slots[next].id != INVALID_ROW_ID; next = (next + 1) & mask {
		home := int_keys_hash(m.slots[next].key) & mask
		stays := gap <= next ? (gap < home && home <= next) : (gap < home || home <= next)
		if stays do continue
		m.slots[gap] = m.slots[next]
		gap = next
	}
	m.slots[gap].id = INVALID_ROW_ID
	m.count -= 1
}

// int_keys_clone copies `source` into `target`, in `allocator`.
int_keys_clone :: proc(target: ^Int_Keys, source: ^Int_Keys, allocator: mem.Allocator) -> mem.Allocator_Error {
	int_keys_destroy(target)
	target.allocator = allocator
	if source.slots == nil do return nil
	slots, err := make([]Int_Key_Slot, len(source.slots), allocator)
	if err != nil do return err
	copy(slots, source.slots)
	target.slots = slots
	target.count = source.count
	return nil
}
