package engine

import "core:mem"
import "core:sync"

// Int_Keys files the row that holds each integer key of an index (Index.ints):
// an open-addressed table with linear probing. It was an Odin map, whose hashes
// are seeded with the address of its cells, so a copy had to file every key
// again: 10-48 ms of a commit over 50 000 rows with a reader open (R7). A slot's
// place here depends on its key alone. A key taken out moves the keys after it
// back into the gap (backward shift), so the table never holds a deleted slot
// and a probe ends at the first empty one.
//
// The slots are in pages of up to INT_KEYS_PAGE, which a reader's table shares
// with the copy a commit writes: the copy takes the list of pages with one more
// reference each and copies a page when it first writes to it, as the rows'
// blocks do (Row_Blocks). A table under INT_KEYS_PAGE slots is one page of its
// own size.
Int_Keys :: struct {
	pages:     []^Int_Keys_Page,
	// capacity is the slots, a power of two; page holds min(capacity, INT_KEYS_PAGE).
	capacity:  int,
	page:      int,
	// page_shift and page_mask find a slot's page without a division: a probe
	// that divided by `page` cost the unique inserts 10%.
	page_shift: uint,
	page_mask:  u64,
	count:     int,
	allocator: mem.Allocator,
}

Int_Keys_Page :: struct {
	refs:  int,
	slots: []Int_Key_Slot,
}

// Int_Key_Slot is one key and its row; a slot whose id is INVALID_ROW_ID is empty.
Int_Key_Slot :: struct {
	key: [2]u64,
	id:  Row_Id,
}

INT_KEYS_FIRST :: 16
INT_KEYS_PAGE :: 4096

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
int_keys_page_new :: proc(slots: int, allocator: mem.Allocator) -> (^Int_Keys_Page, mem.Allocator_Error) {
	page, err := new(Int_Keys_Page, allocator)
	if err != nil do return nil, err
	page.slots, err = make([]Int_Key_Slot, slots, allocator)
	if err != nil {
		free(page, allocator)
		return nil, err
	}
	// Every byte 0xff makes every id INVALID_ROW_ID: all slots empty.
	mem.set(raw_data(page.slots), 0xff, slots * size_of(Int_Key_Slot))
	page.refs = 1
	return page, nil
}

@(private)
int_keys_page_release :: proc(page: ^Int_Keys_Page, allocator: mem.Allocator) {
	if sync.atomic_sub(&page.refs, 1) != 1 do return
	delete(page.slots, allocator)
	free(page, allocator)
}

int_keys_destroy :: proc(m: ^Int_Keys) {
	for page in m.pages do int_keys_page_release(page, m.allocator)
	if m.pages != nil do delete(m.pages, m.allocator)
	m^ = {}
}

int_keys_len :: #force_inline proc "contextless" (m: ^Int_Keys) -> int {
	return m.count
}

// int_keys_at is slot `i`, to read.
@(private)
int_keys_at :: #force_inline proc "contextless" (m: ^Int_Keys, i: u64) -> ^Int_Key_Slot {
	return &m.pages[i >> m.page_shift].slots[i & m.page_mask]
}

// int_keys_mut is slot `i`, to change: a page another table still lists is
// copied first.
@(private)
int_keys_mut :: proc(m: ^Int_Keys, i: u64) -> (^Int_Key_Slot, mem.Allocator_Error) {
	at := i >> m.page_shift
	page := m.pages[at]
	if sync.atomic_load(&page.refs) != 1 {
		own, err := int_keys_page_new(m.page, m.allocator)
		if err != nil do return nil, err
		copy(own.slots, page.slots)
		m.pages[at] = own
		int_keys_page_release(page, m.allocator)
		page = own
	}
	return &page.slots[i & m.page_mask], nil
}

// int_keys_get is the row filed under `key`.
int_keys_get :: proc "contextless" (m: ^Int_Keys, key: [2]u64) -> (id: Row_Id, found: bool) {
	if m.count == 0 do return 0, false
	mask := u64(m.capacity - 1)
	for i := int_keys_hash(key) & mask; ; i = (i + 1) & mask {
		slot := int_keys_at(m, i)
		if slot.id == INVALID_ROW_ID do return 0, false
		if slot.key == key do return slot.id, true
	}
}

// int_keys_put files `id` under `key`, replacing the row filed there before.
int_keys_put :: proc(m: ^Int_Keys, key: [2]u64, id: Row_Id) -> mem.Allocator_Error {
	// At most five eighths full, so a probe stays short.
	if (m.count + 1) * 8 > m.capacity * 5 do int_keys_grow(m) or_return
	mask := u64(m.capacity - 1)
	for i := int_keys_hash(key) & mask; ; i = (i + 1) & mask {
		page := m.pages[i >> m.page_shift]
		slot := &page.slots[i & m.page_mask]
		if slot.id != INVALID_ROW_ID && slot.key != key do continue
		if slot.id == id do return nil
		// The slot found is written in place when its page is this table's
		// own; a page a reader's table still lists is copied first.
		if sync.atomic_load(&page.refs) != 1 do slot = int_keys_mut(m, i) or_return
		if slot.id == INVALID_ROW_ID do m.count += 1
		slot^ = Int_Key_Slot{key = key, id = id}
		return nil
	}
}

// int_keys_grow doubles the table into pages of its own.
@(private)
int_keys_grow :: proc(m: ^Int_Keys) -> mem.Allocator_Error {
	if m.allocator.procedure == nil do m.allocator = context.allocator
	capacity := max(INT_KEYS_FIRST, m.capacity * 2)
	page := min(capacity, INT_KEYS_PAGE)
	pages := make([]^Int_Keys_Page, capacity / page, m.allocator) or_return
	for &slot_page, i in pages {
		made, err := int_keys_page_new(page, m.allocator)
		if err != nil {
			for made_page in pages[:i] do int_keys_page_release(made_page, m.allocator)
			delete(pages, m.allocator)
			return err
		}
		slot_page = made
	}
	mask := u64(capacity - 1)
	shift := uint(0)
	for 1 << shift < page do shift += 1
	page_mask := u64(page - 1)
	for old_page in m.pages {
		for old in old_page.slots {
			if old.id == INVALID_ROW_ID do continue
			i := int_keys_hash(old.key) & mask
			for pages[i >> shift].slots[i & page_mask].id != INVALID_ROW_ID do i = (i + 1) & mask
			pages[i >> shift].slots[i & page_mask] = old
		}
	}
	for old_page in m.pages do int_keys_page_release(old_page, m.allocator)
	if m.pages != nil do delete(m.pages, m.allocator)
	m.pages = pages
	m.capacity = capacity
	m.page = page
	m.page_shift = shift
	m.page_mask = page_mask
	return nil
}

// int_keys_remove takes `key` out when `id` is the row filed under it.
int_keys_remove :: proc(m: ^Int_Keys, key: [2]u64, id: Row_Id) -> mem.Allocator_Error {
	if m.count == 0 do return nil
	mask := u64(m.capacity - 1)
	gap := int_keys_hash(key) & mask
	for {
		slot := int_keys_at(m, gap)
		if slot.id == INVALID_ROW_ID do return nil
		if slot.key == key {
			if slot.id != id do return nil
			break
		}
		gap = (gap + 1) & mask
	}
	// Each key after the gap that may sit in it (its home is not between the
	// gap and its own slot) moves back, and its slot is the gap now.
	for next := (gap + 1) & mask; int_keys_at(m, next).id != INVALID_ROW_ID; next = (next + 1) & mask {
		moving := int_keys_at(m, next)^
		home := int_keys_hash(moving.key) & mask
		stays := gap <= next ? (gap < home && home <= next) : (gap < home || home <= next)
		if stays do continue
		into := int_keys_mut(m, gap) or_return
		into^ = moving
		gap = next
	}
	last := int_keys_mut(m, gap) or_return
	last.id = INVALID_ROW_ID
	m.count -= 1
	return nil
}

// int_keys_clone gives `target` the pages of `source`, one more reference each.
int_keys_clone :: proc(target: ^Int_Keys, source: ^Int_Keys, allocator: mem.Allocator) -> mem.Allocator_Error {
	int_keys_destroy(target)
	if source.pages == nil {
		target.allocator = allocator
		return nil
	}
	// The pages are the source's allocator's: the copy frees what it copies
	// with it too.
	pages, err := make([]^Int_Keys_Page, len(source.pages), source.allocator)
	if err != nil do return err
	for page, i in source.pages {
		sync.atomic_add(&page.refs, 1)
		pages[i] = page
	}
	target^ = source^
	target.pages = pages
	return nil
}
