package engine

import "core:mem"

// Staged_Ints files the staged row that holds each integer key a transaction
// stages (Table_Writes.unique_ints): the key is the index's position and the
// two words of index_int_key. It was an Odin map, which hashed the 24 bytes of
// the key with a byte hasher and rehashed itself three times while a batch of
// 256 rows grew it from 64: a unique insert paid ~160 ns to register its key
// (A2.6). This is one array, open-addressed with linear probing and the
// integer mix Int_Keys uses; a key taken out moves the keys after it back into
// the gap (backward shift), so a probe ends at the first empty slot. The array
// is made at the first key, so a transaction that stages none pays nothing.
Staged_Ints :: struct {
	slots:     []Staged_Int_Slot,
	count:     int,
	allocator: mem.Allocator,
}

// Staged_Int_Slot is one key and its row; a slot whose id is INVALID_ROW_ID is
// empty.
Staged_Int_Slot :: struct {
	key: [3]u64,
	id:  Row_Id,
}

STAGED_INTS_FIRST :: 64

@(private)
staged_ints_hash :: #force_inline proc "contextless" (key: [3]u64) -> u64 {
	h := key[2] ~ (key[1] * 0x9e3779b97f4a7c15) ~ (key[0] * 0xc2b2ae3d27d4eb4f)
	h ~= h >> 33
	h *= 0xff51afd7ed558ccd
	h ~= h >> 33
	h *= 0xc4ceb9fe1a85ec53
	h ~= h >> 33
	return h
}

// staged_ints_init readies `m` to allocate from `allocator` when it files its
// first key.
staged_ints_init :: proc(m: ^Staged_Ints, allocator := context.allocator) {
	m^ = Staged_Ints{allocator = allocator}
}

staged_ints_destroy :: proc(m: ^Staged_Ints) {
	if m.slots != nil do delete(m.slots, m.allocator)
	m.slots = nil
	m.count = 0
}

staged_ints_len :: #force_inline proc "contextless" (m: ^Staged_Ints) -> int {
	return m.count
}

// staged_ints_clear empties `m`, keeping its slots.
staged_ints_clear :: proc(m: ^Staged_Ints) {
	if m.count == 0 do return
	mem.set(raw_data(m.slots), 0xff, len(m.slots) * size_of(Staged_Int_Slot))
	m.count = 0
}

// staged_ints_get is the row filed under `key`.
staged_ints_get :: proc "contextless" (m: ^Staged_Ints, key: [3]u64) -> (id: Row_Id, found: bool) {
	if m.count == 0 do return 0, false
	mask := u64(len(m.slots) - 1)
	for i := staged_ints_hash(key) & mask; ; i = (i + 1) & mask {
		slot := &m.slots[i]
		if slot.id == INVALID_ROW_ID do return 0, false
		if slot.key == key do return slot.id, true
	}
}

// staged_ints_put files `id` under `key`, replacing the row filed there before.
staged_ints_put :: proc(m: ^Staged_Ints, key: [3]u64, id: Row_Id) {
	// At most five eighths full, so a probe stays short.
	if (m.count + 1) * 8 > len(m.slots) * 5 do staged_ints_grow(m)
	mask := u64(len(m.slots) - 1)
	for i := staged_ints_hash(key) & mask; ; i = (i + 1) & mask {
		slot := &m.slots[i]
		if slot.id != INVALID_ROW_ID && slot.key != key do continue
		if slot.id == INVALID_ROW_ID do m.count += 1
		slot^ = Staged_Int_Slot{key = key, id = id}
		return
	}
}

// staged_ints_erase takes `key` out, when it is filed.
staged_ints_erase :: proc(m: ^Staged_Ints, key: [3]u64) {
	if m.count == 0 do return
	mask := u64(len(m.slots) - 1)
	i := staged_ints_hash(key) & mask
	for {
		slot := &m.slots[i]
		if slot.id == INVALID_ROW_ID do return
		if slot.key == key do break
		i = (i + 1) & mask
	}
	// Backward shift: each key after the gap that its home allows moves into it.
	gap := i
	for j := (gap + 1) & mask; ; j = (j + 1) & mask {
		slot := m.slots[j]
		if slot.id == INVALID_ROW_ID do break
		home := staged_ints_hash(slot.key) & mask
		// The key stays when its home lies cyclically in (gap, j].
		if (j > gap && home > gap && home <= j) || (j < gap && (home > gap || home <= j)) do continue
		m.slots[gap] = slot
		gap = j
	}
	m.slots[gap] = Staged_Int_Slot{id = INVALID_ROW_ID}
	m.count -= 1
}

// staged_ints_copy gives `target` the keys of `source`, in `allocator`.
staged_ints_copy :: proc(target: ^Staged_Ints, source: ^Staged_Ints, allocator: mem.Allocator) {
	target^ = Staged_Ints{allocator = allocator, count = source.count}
	if source.slots == nil do return
	target.slots = make([]Staged_Int_Slot, len(source.slots), allocator)
	copy(target.slots, source.slots)
}

// staged_ints_grow doubles the slots and files every key again.
@(private)
staged_ints_grow :: proc(m: ^Staged_Ints) {
	if m.allocator.procedure == nil do m.allocator = context.allocator
	old := m.slots
	capacity := max(STAGED_INTS_FIRST, len(old) * 2)
	m.slots = make([]Staged_Int_Slot, capacity, m.allocator)
	mem.set(raw_data(m.slots), 0xff, capacity * size_of(Staged_Int_Slot))
	mask := u64(capacity - 1)
	for slot in old {
		if slot.id == INVALID_ROW_ID do continue
		i := staged_ints_hash(slot.key) & mask
		for m.slots[i].id != INVALID_ROW_ID do i = (i + 1) & mask
		m.slots[i] = slot
	}
	if old != nil do delete(old, m.allocator)
}
