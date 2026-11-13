package engine

import "core:strings"

// Ordered index over pages.
//
// An index used to be an rbtree holding the encoded keys of every row, which
// meant a table with an index kept a copy of its key columns in RAM forever and
// rebuilt the tree on every open. This file stores the same order-preserving
// keys in a B+tree of 4 KiB pages, so the keys live on disk and the pool bounds
// what a lookup costs in memory.
//
// A leaf cell is `u16 key length | key | u64 value`; a branch cell is
// `u16 key length | key | u32 child`. Leaves are chained through the page header
// (`next_free`), which is what makes a range scan a single pass: a cursor needs
// no parent stack, only the leaf it sits on. A branch routes a key to the first
// child whose separator is greater than the key, and keeps its leftmost child in
// `next_free`.
//
// Deletion removes the cell and leaves an empty leaf in place: a lookup that
// lands on an empty leaf follows the chain until it finds an entry, and because
// the chain is ordered that answer is still the lower bound. Merging is the next
// step (D5b), so an index that loses every row keeps its leaves until the file
// is rebuilt.

INDEX_PAGE_MAGIC :: u32(0x4D52_5049) // "MRPI"
INDEX_PAGE_VERSION :: u32(1)

// INDEX_PAGE_MAX_KEY bounds one key so a cell always fits a page. A row whose
// index key is longer is refused by the insert, with a message that names the
// limit, instead of silently corrupting the tree.
INDEX_PAGE_MAX_KEY :: 1000

// INDEX_PAGE_FRAMES is the pool one index file keeps. An index is read through
// the same buffer pool: 32 pages is 128 KiB per index, which is what the file
// doc promises instead of one frame per key.
INDEX_PAGE_FRAMES :: 32

@(private)
INDEX_HDR_ROOT :: 52

@(private)
INDEX_HDR_HEIGHT :: 56

@(private)
INDEX_HDR_ENTRIES :: 60

@(private)
INDEX_HDR_MAGIC :: 68

@(private)
INDEX_HDR_VERSION :: 72

// IP_SCRATCH holds a page worth of cells plus the one being inserted, so an
// insert can rebuild a page without reading it twice.
@(private)
IP_SCRATCH :: PAGE_SIZE + INDEX_PAGE_MAX_KEY + 64

@(private)
IP_MAX_CELLS :: PAGE_SIZE / PAGE_SLOT_LEN

@(private)
Ip_Cell :: struct {
	off: u16,
	len: u16,
}

// Ip_Cells is a decoded page: the cells live in `bytes` and `items` gives them
// in key order. It is the working copy an insert or a split edits.
@(private)
Ip_Cells :: struct {
	items: [dynamic]Ip_Cell,
	bytes: []u8,
	used:  int,
}

Ordered_Pages :: struct {
	file:    ^Page_File,
	vfs:     ^Vfs,
	path:    string,
	frames:  int,
	root:    Page_Id,
	height:  u32,
	entries: u64,
}

// --- Cell encoding ---------------------------------------------------------

@(private)
ip_key_of :: proc(cell: []u8) -> []u8 {
	return cell[2:2 + int(page_get_u16(cell))]
}

@(private)
ip_value_of :: proc(cell: []u8) -> u64 {
	return get_u64_le(cell[2 + int(page_get_u16(cell)):])
}

@(private)
ip_child_of :: proc(cell: []u8) -> Page_Id {
	return Page_Id(get_u32_le(cell[2 + int(page_get_u16(cell)):]))
}

@(private)
ip_leaf_cell :: proc(buf: []u8, key: string, value: u64) -> []u8 {
	page_put_u16(buf, u16(len(key)))
	copy(buf[2:], key)
	put_u64_le(buf[2 + len(key):], value)
	return buf[:2 + len(key) + 8]
}

@(private)
ip_branch_cell :: proc(buf: []u8, key: string, child: Page_Id) -> []u8 {
	page_put_u16(buf, u16(len(key)))
	copy(buf[2:], key)
	put_u32_le(buf[2 + len(key):], u32(child))
	return buf[:2 + len(key) + 4]
}

// --- Page working set ------------------------------------------------------

@(private)
ip_cells_begin :: proc(cells: ^Ip_Cells, scratch: []u8) {
	clear(&cells.items)
	cells.bytes = scratch
	cells.used = 0
}

@(private)
ip_cells_decode :: proc(cells: ^Ip_Cells, data: []u8) {
	header := page_header_decode(data)
	clear(&cells.items)
	cells.used = 0
	for i in 0 ..< int(header.slots) {
		off, length := page_slot_get(data, u16(i))
		if length == 0 do continue
		if cells.used + int(length) > len(cells.bytes) do return
		copy(cells.bytes[cells.used:], data[off:off + length])
		append(&cells.items, Ip_Cell{off = u16(cells.used), len = length})
		cells.used += int(length)
	}
}

@(private)
ip_cell_bytes :: proc(cells: ^Ip_Cells, i: int) -> []u8 {
	item := cells.items[i]
	return cells.bytes[item.off:item.off + item.len]
}

@(private)
ip_cells_insert :: proc(cells: ^Ip_Cells, pos: int, cell: []u8) -> bool {
	if cells.used + len(cell) > len(cells.bytes) do return false
	copy(cells.bytes[cells.used:], cell)
	entry := Ip_Cell{off = u16(cells.used), len = u16(len(cell))}
	cells.used += len(cell)
	append(&cells.items, entry)
	for i := len(cells.items) - 1; i > pos; i -= 1 do cells.items[i] = cells.items[i - 1]
	cells.items[pos] = entry
	return true
}

@(private)
ip_cells_total :: proc(cells: ^Ip_Cells) -> int {
	total := len(cells.items) * PAGE_SLOT_LEN
	for item in cells.items do total += int(item.len)
	return total
}

// ip_lower_bound returns the first position whose key is >= `key`.
@(private)
ip_lower_bound :: proc(cells: ^Ip_Cells, key: string) -> int {
	lo, hi := 0, len(cells.items)
	for lo < hi {
		mid := (lo + hi) / 2
		if strings.compare(string(ip_key_of(ip_cell_bytes(cells, mid))), key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// ip_child_for returns the position of the first separator greater than `key`.
// Position 0 means the branch's leftmost child.
@(private)
ip_child_for :: proc(cells: ^Ip_Cells, key: string) -> int {
	lo, hi := 0, len(cells.items)
	for lo < hi {
		mid := (lo + hi) / 2
		if strings.compare(string(ip_key_of(ip_cell_bytes(cells, mid))), key) <= 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// ip_page_write lays the cells out in order: cells from the header upward and
// the slot directory from the end downward, so a page needs one pass and no
// compaction.
@(private)
ip_page_write :: proc(data: []u8, kind: Page_Kind, next: Page_Id, cells: ^Ip_Cells) -> Error {
	n := len(cells.items)
	if PAGE_HEADER_LEN + ip_cells_total(cells) > PAGE_SIZE {
		return errf(.Internal, "index page would need more than a page")
	}
	for i in 0 ..< PAGE_SIZE do data[i] = 0
	offsets: [IP_MAX_CELLS]u16
	cursor := PAGE_HEADER_LEN
	for item, i in cells.items {
		offsets[i] = u16(cursor)
		copy(data[cursor:], cells.bytes[item.off:item.off + item.len])
		cursor += int(item.len)
	}
	for item, i in cells.items {
		page_slot_put(data, u16(i), offsets[i], item.len)
	}
	page_header_encode(
		data,
		Page_Header {
			kind = kind,
			slots = u16(n),
			slot_start = u16(PAGE_SIZE - n * PAGE_SLOT_LEN),
			free_start = u16(cursor),
			row_count = u16(n),
			next_free = next,
		},
	)
	return ERROR_NONE
}

// ip_split_point picks the cell where a page is cut in two, leaving both halves
// inside a page. The greedy fill keeps the left half near half a page, which is
// what keeps the tree shallow.
@(private)
ip_split_point :: proc(cells: ^Ip_Cells) -> int {
	capacity := PAGE_SIZE - PAGE_HEADER_LEN
	half := capacity / 2
	n := len(cells.items)
	used := 0
	k := 0
	for k < n {
		size := int(cells.items[k].len) + PAGE_SLOT_LEN
		if used + size > half && k > 0 do break
		if used + size > capacity do break
		used += size
		k += 1
	}
	if k == 0 do k = 1
	if k >= n do k = n - 1
	// A page whose first cell is huge can leave the right half too big; move the
	// cut left until both halves fit. k = n - 1 always fits, so this ends.
	for k > 1 {
		right := 0
		for i in k ..< n do right += int(cells.items[i].len) + PAGE_SLOT_LEN
		if right <= capacity do break
		k -= 1
	}
	return k
}

// --- Open, close, header ---------------------------------------------------

@(private)
ip_header_sync :: proc(op: ^Ordered_Pages) {
	data := op.file.frames[0].data
	put_u32_le(data[INDEX_HDR_ROOT:INDEX_HDR_ROOT + 4], u32(op.root))
	put_u32_le(data[INDEX_HDR_HEIGHT:INDEX_HDR_HEIGHT + 4], op.height)
	put_u64_le(data[INDEX_HDR_ENTRIES:INDEX_HDR_ENTRIES + 8], op.entries)
	put_u32_le(data[INDEX_HDR_MAGIC:INDEX_HDR_MAGIC + 4], INDEX_PAGE_MAGIC)
	put_u32_le(data[INDEX_HDR_VERSION:INDEX_HDR_VERSION + 4], INDEX_PAGE_VERSION)
}

// ordered_create starts an empty index file: one leaf, which is also the root.
ordered_create :: proc(vfs: ^Vfs, path: string, frames: int) -> (^Ordered_Pages, Error) {
	file, create_err := page_file_create(vfs, path, frames, .Index_Header)
	if create_err.kind != .None do return nil, create_err
	op := new(Ordered_Pages)
	op.file = file
	op.vfs = file.vfs
	op.path = strings.clone(path)
	op.frames = frames
	root, alloc_err := page_alloc(file)
	if alloc_err.kind != .None {
		page_file_close(file)
		delete(op.path)
		free(op)
		return nil, alloc_err
	}
	frame, frame_err := page_load(file, root)
	if frame_err.kind != .None {
		page_file_close(file)
		delete(op.path)
		free(op)
		return nil, frame_err
	}
	scratch: [IP_SCRATCH]u8
	cells: Ip_Cells
	ip_cells_begin(&cells, scratch[:])
	defer delete(cells.items)
	ip_page_write(frame.data, .Index_Leaf, NO_PAGE_ID, &cells)
	page_release(file, frame, true)
	op.root = root
	op.height = 1
	op.entries = 0
	ip_header_sync(op)
	return op, ERROR_NONE
}

// ordered_open reads an index file that a previous session wrote. A header that
// does not verify, or a root that points outside the file, is reported as
// corrupt so the caller can rebuild from the log.
ordered_open :: proc(vfs: ^Vfs, path: string, frames: int) -> (^Ordered_Pages, Error) {
	file, open_err := page_file_open(vfs, path, frames)
	if open_err.kind != .None do return nil, open_err
	header := file.frames[0].data
	if get_u32_le(header[INDEX_HDR_MAGIC:INDEX_HDR_MAGIC + 4]) != INDEX_PAGE_MAGIC ||
	   get_u32_le(header[INDEX_HDR_VERSION:INDEX_HDR_VERSION + 4]) != INDEX_PAGE_VERSION ||
	   page_header_decode(header).kind != .Index_Header {
		page_file_close(file)
		return nil, errf(.Corrupt_Log, "the index file %s has no header", path)
	}
	op := new(Ordered_Pages)
	op.file = file
	op.vfs = file.vfs
	op.path = strings.clone(path)
	op.frames = frames
	op.root = Page_Id(get_u32_le(header[INDEX_HDR_ROOT:INDEX_HDR_ROOT + 4]))
	op.height = get_u32_le(header[INDEX_HDR_HEIGHT:INDEX_HDR_HEIGHT + 4])
	op.entries = get_u64_le(header[INDEX_HDR_ENTRIES:INDEX_HDR_ENTRIES + 8])
	if op.root == 0 || op.root >= file.page_count || op.height == 0 {
		page_file_close(file)
		delete(op.path)
		free(op)
		return nil, errf(.Corrupt_Log, "the index file %s points at no root", path)
	}
	return op, ERROR_NONE
}

ordered_close :: proc(op: ^Ordered_Pages) {
	if op == nil do return
	page_file_close(op.file)
	delete(op.path)
	free(op)
}

// ordered_flush writes the dirty pages, then the header with the sequence they
// are complete up to, the same order the row files use.
ordered_flush :: proc(op: ^Ordered_Pages, applied_seq: u64) -> Error {
	ip_header_sync(op)
	return page_flush(op.file, applied_seq)
}

// ordered_clear empties the index. The file is a cache over the log, so it is
// simpler and safer to start a fresh file than to walk every page marking it
// free: no dirty frame can survive into a file that claims to be empty.
ordered_clear :: proc(op: ^Ordered_Pages) -> Error {
	page_file_close(op.file)
	fresh, create_err := ordered_create(op.vfs, op.path, op.frames)
	if create_err.kind != .None do return create_err
	op.file = fresh.file
	op.root = fresh.root
	op.height = fresh.height
	op.entries = 0
	// fresh shares the path string; drop the extra copy instead of the field.
	delete(fresh.path)
	free(fresh)
	return ERROR_NONE
}

// --- Lookup ----------------------------------------------------------------

@(private)
ip_find_leaf :: proc(op: ^Ordered_Pages, key: string) -> (Page_Id, Error) {
	id := op.root
	scratch: [IP_SCRATCH]u8
	cells: Ip_Cells
	ip_cells_begin(&cells, scratch[:])
	defer delete(cells.items)
	for {
		frame, load_err := page_load(op.file, id)
		if load_err.kind != .None do return 0, load_err
		header := page_header_decode(frame.data)
		if header.kind == .Index_Leaf {
			page_release(op.file, frame, false)
			return id, ERROR_NONE
		}
		if header.kind != .Index_Branch {
			page_release(op.file, frame, false)
			return 0, errf(.Corrupt_Log, "index page %d of %s is not a branch", id, op.path)
		}
		ip_cells_decode(&cells, frame.data)
		position := ip_child_for(&cells, key)
		child := header.next_free
		if position > 0 do child = ip_child_of(ip_cell_bytes(&cells, position - 1))
		page_release(op.file, frame, false)
		if child == NO_PAGE_ID do return 0, errf(.Corrupt_Log, "index page %d of %s has no child", id, op.path)
		id = child
	}
}

Ordered_Cursor :: struct {
	op:   ^Ordered_Pages,
	page: Page_Id,
	slot: u16,
	count: u16,
	valid: bool,
}

// ip_cursor_step moves to the first non-empty leaf after the current one.
@(private)
ip_cursor_step :: proc(cursor: ^Ordered_Cursor) -> bool {
	for {
		frame, load_err := page_load(cursor.op.file, cursor.page)
		if load_err.kind != .None do return false
		next := page_header_decode(frame.data).next_free
		page_release(cursor.op.file, frame, false)
		if next == NO_PAGE_ID do return false
		cursor.page = next
		cursor.slot = 0
		frame, load_err = page_load(cursor.op.file, cursor.page)
		if load_err.kind != .None do return false
		cursor.count = page_header_decode(frame.data).slots
		page_release(cursor.op.file, frame, false)
		if cursor.count > 0 do return true
	}
}

// ordered_seek puts a cursor on the first entry whose key is >= `key`. An empty
// key means "from the first entry".
ordered_seek :: proc(op: ^Ordered_Pages, key: string) -> Ordered_Cursor {
	cursor := Ordered_Cursor{op = op}
	leaf, find_err := ip_find_leaf(op, key)
	if find_err.kind != .None do return cursor
	scratch: [IP_SCRATCH]u8
	cells: Ip_Cells
	ip_cells_begin(&cells, scratch[:])
	defer delete(cells.items)
	frame, load_err := page_load(op.file, leaf)
	if load_err.kind != .None do return cursor
	ip_cells_decode(&cells, frame.data)
	position := ip_lower_bound(&cells, key)
	page_release(op.file, frame, false)
	cursor.page = leaf
	cursor.slot = u16(position)
	cursor.count = u16(len(cells.items))
	if int(cursor.slot) >= int(cursor.count) {
		if !ip_cursor_step(&cursor) do return cursor
	}
	cursor.valid = true
	return cursor
}

ordered_next :: proc(cursor: ^Ordered_Cursor) -> bool {
	if !cursor.valid do return false
	cursor.slot += 1
	if int(cursor.slot) < int(cursor.count) do return true
	return ip_cursor_step(cursor)
}

// ordered_cursor_read copies the current key into `buf` and returns it with the
// value. The key is copied because the page may be evicted as soon as the cursor
// moves.
ordered_cursor_read :: proc(cursor: ^Ordered_Cursor, buf: []u8) -> (key: string, value: u64, ok: bool) {
	if !cursor.valid do return "", 0, false
	frame, load_err := page_load(cursor.op.file, cursor.page)
	if load_err.kind != .None do return "", 0, false
	defer page_release(cursor.op.file, frame, false)
	if int(cursor.slot) >= int(page_header_decode(frame.data).slots) do return "", 0, false
	off, length := page_slot_get(frame.data, cursor.slot)
	cell := frame.data[off:off + length]
	raw := ip_key_of(cell)
	if len(raw) > len(buf) do return "", 0, false
	copy(buf, raw)
	return string(buf[:len(raw)]), ip_value_of(cell), true
}

// ordered_lookup_prefix returns every row whose stored key starts with
// `prefix`, in key order.
ordered_lookup_prefix :: proc(op: ^Ordered_Pages, prefix: string) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id)
	cursor := ordered_seek(op, prefix)
	buf: [INDEX_PAGE_MAX_KEY]u8
	for cursor.valid {
		key, value, ok := ordered_cursor_read(&cursor, buf[:])
		if !ok do break
		if !strings.has_prefix(key, prefix) do break
		append(&ids, Row_Id(value))
		if !ordered_next(&cursor) do break
	}
	return ids
}

// ordered_scan returns the rows whose key falls in [start, end]. An empty start
// means the beginning, an empty end means the end. As in the in-memory tree, an
// entry whose key has `end` as a prefix counts as equal, so a scan to a prefix
// works on a non-unique index.
ordered_scan :: proc(
	op: ^Ordered_Pages,
	start: string,
	end: string,
	inclusive_end: bool,
) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id)
	cursor := ordered_seek(op, start)
	buf: [INDEX_PAGE_MAX_KEY]u8
	for cursor.valid {
		key, value, ok := ordered_cursor_read(&cursor, buf[:])
		if !ok do break
		if end != "" {
			order := strings.compare(key, end)
			if strings.has_prefix(key, end) do order = 0
			if order > 0 do break
			if order == 0 && !inclusive_end do break
		}
		append(&ids, Row_Id(value))
		if !ordered_next(&cursor) do break
	}
	return ids
}

// ordered_entries is how many keys the index holds.
ordered_entries :: proc(op: ^Ordered_Pages) -> u64 {
	return op.entries
}

// ordered_contains reports whether `key` is present.
ordered_contains :: proc(op: ^Ordered_Pages, key: string) -> bool {
	cursor := ordered_seek(op, key)
	buf: [INDEX_PAGE_MAX_KEY]u8
	found, _, ok := ordered_cursor_read(&cursor, buf[:])
	if !ok do return false
	return found == key
}

// --- Insert ----------------------------------------------------------------

// Ip_Split is what a recursive insert reports upward: the promoted separator and
// the page that took the right half. `sep` is heap-owned by the caller, which
// writes it into the parent and then frees it.
@(private)
Ip_Split :: struct {
	happened: bool,
	sep:      []u8,
	right:    Page_Id,
}

@(private)
ip_insert_page :: proc(op: ^Ordered_Pages, id: Page_Id, key: string, value: u64) -> (Ip_Split, Error) {
	frame, load_err := page_load(op.file, id)
	if load_err.kind != .None do return {}, load_err
	header := page_header_decode(frame.data)
	scratch: [IP_SCRATCH]u8
	cells: Ip_Cells
	ip_cells_begin(&cells, scratch[:])
	defer delete(cells.items)
	ip_cells_decode(&cells, frame.data)

	if header.kind == .Index_Leaf {
		position := ip_lower_bound(&cells, key)
		if position < len(cells.items) {
			existing := ip_cell_bytes(&cells, position)
			if string(ip_key_of(existing)) == key {
				// Same key: replace the value in place, the entry count does not move.
				off, _ := page_slot_get(frame.data, u16(position))
				put_u64_le(frame.data[int(off) + 2 + int(page_get_u16(existing)):], value)
				page_release(op.file, frame, true)
				return {}, ERROR_NONE
			}
		}
		cell_buffer: [INDEX_PAGE_MAX_KEY + 16]u8
		cell := ip_leaf_cell(cell_buffer[:], key, value)
		if !ip_cells_insert(&cells, position, cell) {
			page_release(op.file, frame, false)
			return {}, errf(.Quota_Exceeded, "an index key of %d bytes no longer fits a page", len(key))
		}
		if PAGE_HEADER_LEN + ip_cells_total(&cells) <= PAGE_SIZE {
			if write_err := ip_page_write(frame.data, .Index_Leaf, header.next_free, &cells); write_err.kind != .None {
				page_release(op.file, frame, false)
				return {}, write_err
			}
			page_release(op.file, frame, true)
			op.entries += 1
			return {}, ERROR_NONE
		}
		// The leaf is full: cut it in two and hand the first key of the right half
		// to the parent. The left frame is released before allocating, so a pool of
		// a single data frame still makes progress.
		page_release(op.file, frame, false)
		cut := ip_split_point(&cells)
		old_next := header.next_free
		right_id, alloc_err := page_alloc(op.file)
		if alloc_err.kind != .None do return {}, alloc_err
		right_frame, right_err := page_load(op.file, right_id)
		if right_err.kind != .None do return {}, right_err
		right: Ip_Cells
		ip_cells_begin(&right, cells.bytes)
		defer delete(right.items)
		for item in cells.items[cut:] do append(&right.items, item)
		raw_sep := ip_key_of(ip_cell_bytes(&right, 0))
		sep := make([]u8, len(raw_sep))
		copy(sep, raw_sep)
		if write_err := ip_page_write(right_frame.data, .Index_Leaf, old_next, &right); write_err.kind != .None {
			delete(sep)
			page_release(op.file, right_frame, false)
			return {}, write_err
		}
		page_release(op.file, right_frame, true)
		left: Ip_Cells
		ip_cells_begin(&left, cells.bytes)
		defer delete(left.items)
		for item in cells.items[:cut] do append(&left.items, item)
		left_frame, left_err := page_load(op.file, id)
		if left_err.kind != .None {
			delete(sep)
			return {}, left_err
		}
		if write_err := ip_page_write(left_frame.data, .Index_Leaf, right_id, &left); write_err.kind != .None {
			delete(sep)
			page_release(op.file, left_frame, false)
			return {}, write_err
		}
		page_release(op.file, left_frame, true)
		op.entries += 1
		return Ip_Split{happened = true, sep = sep, right = right_id}, ERROR_NONE
	}

	if header.kind != .Index_Branch {
		page_release(op.file, frame, false)
		return {}, errf(.Corrupt_Log, "index page %d of %s is not a branch", id, op.path)
	}
	position := ip_child_for(&cells, key)
	child := header.next_free
	if position > 0 do child = ip_child_of(ip_cell_bytes(&cells, position - 1))
	page_release(op.file, frame, false)
	split, insert_err := ip_insert_page(op, child, key, value)
	if insert_err.kind != .None do return {}, insert_err
	if !split.happened do return {}, ERROR_NONE

	branch_frame, branch_err := page_load(op.file, id)
	if branch_err.kind != .None {
		delete(split.sep)
		return {}, branch_err
	}
	ip_cells_decode(&cells, branch_frame.data)
	cell_buffer: [INDEX_PAGE_MAX_KEY + 16]u8
	cell := ip_branch_cell(cell_buffer[:], string(split.sep), split.right)
	if !ip_cells_insert(&cells, position, cell) {
		delete(split.sep)
		page_release(op.file, branch_frame, false)
		return {}, errf(.Quota_Exceeded, "a branch separator no longer fits a page")
	}
	delete(split.sep)
	if PAGE_HEADER_LEN + ip_cells_total(&cells) <= PAGE_SIZE {
		if write_err := ip_page_write(branch_frame.data, .Index_Branch, header.next_free, &cells); write_err.kind != .None {
			page_release(op.file, branch_frame, false)
			return {}, write_err
		}
		page_release(op.file, branch_frame, true)
		return {}, ERROR_NONE
	}
	// The branch is full too: promote the separator at the cut and give the right
	// half the promoted child as its leftmost child.
	page_release(op.file, branch_frame, false)
	cut := ip_split_point(&cells)
	promoted := ip_cell_bytes(&cells, cut)
	raw_sep := ip_key_of(promoted)
	sep := make([]u8, len(raw_sep))
	copy(sep, raw_sep)
	promoted_child := ip_child_of(promoted)
	right_id, alloc_err := page_alloc(op.file)
	if alloc_err.kind != .None {
		delete(sep)
		return {}, alloc_err
	}
	right_frame, right_err := page_load(op.file, right_id)
	if right_err.kind != .None {
		delete(sep)
		return {}, right_err
	}
	right: Ip_Cells
	ip_cells_begin(&right, cells.bytes)
	defer delete(right.items)
	for item in cells.items[cut + 1:] do append(&right.items, item)
	if write_err := ip_page_write(right_frame.data, .Index_Branch, promoted_child, &right); write_err.kind != .None {
		delete(sep)
		page_release(op.file, right_frame, false)
		return {}, write_err
	}
	page_release(op.file, right_frame, true)
	left: Ip_Cells
	ip_cells_begin(&left, cells.bytes)
	defer delete(left.items)
	for item in cells.items[:cut] do append(&left.items, item)
	left_frame, left_err := page_load(op.file, id)
	if left_err.kind != .None {
		delete(sep)
		return {}, left_err
	}
	if write_err := ip_page_write(left_frame.data, .Index_Branch, header.next_free, &left); write_err.kind != .None {
		delete(sep)
		page_release(op.file, left_frame, false)
		return {}, write_err
	}
	page_release(op.file, left_frame, true)
	return Ip_Split{happened = true, sep = sep, right = right_id}, ERROR_NONE
}

// ordered_put inserts or replaces one key.
ordered_put :: proc(op: ^Ordered_Pages, key: string, value: u64) -> Error {
	if len(key) > INDEX_PAGE_MAX_KEY {
		return errf(
			.Quota_Exceeded,
			"an index key of %d bytes is longer than the %d-byte limit",
			len(key),
			INDEX_PAGE_MAX_KEY,
		)
	}
	split, insert_err := ip_insert_page(op, op.root, key, value)
	if insert_err.kind != .None do return insert_err
	if !split.happened do return ERROR_NONE
	defer delete(split.sep)
	new_root, alloc_err := page_alloc(op.file)
	if alloc_err.kind != .None do return alloc_err
	frame, frame_err := page_load(op.file, new_root)
	if frame_err.kind != .None do return frame_err
	scratch: [IP_SCRATCH]u8
	cells: Ip_Cells
	ip_cells_begin(&cells, scratch[:])
	defer delete(cells.items)
	cell_buffer: [INDEX_PAGE_MAX_KEY + 16]u8
	cell := ip_branch_cell(cell_buffer[:], string(split.sep), split.right)
	ip_cells_insert(&cells, 0, cell)
	if write_err := ip_page_write(frame.data, .Index_Branch, op.root, &cells); write_err.kind != .None {
		page_release(op.file, frame, false)
		return write_err
	}
	page_release(op.file, frame, true)
	op.root = new_root
	op.height += 1
	ip_header_sync(op)
	return ERROR_NONE
}

// --- Remove ----------------------------------------------------------------

// ordered_remove deletes one key. It reports whether the key was there. A leaf
// that loses its last cell stays in the chain, and the cursor walks past it.
ordered_remove :: proc(op: ^Ordered_Pages, key: string) -> bool {
	leaf, find_err := ip_find_leaf(op, key)
	if find_err.kind != .None do return false
	frame, load_err := page_load(op.file, leaf)
	if load_err.kind != .None do return false
	scratch: [IP_SCRATCH]u8
	cells: Ip_Cells
	ip_cells_begin(&cells, scratch[:])
	defer delete(cells.items)
	ip_cells_decode(&cells, frame.data)
	header := page_header_decode(frame.data)
	position := ip_lower_bound(&cells, key)
	if position >= len(cells.items) || string(ip_key_of(ip_cell_bytes(&cells, position))) != key {
		page_release(op.file, frame, false)
		return false
	}
	order_copy := make([]Ip_Cell, len(cells.items) - 1)
	defer delete(order_copy)
	write := 0
	for item, i in cells.items {
		if i == position do continue
		order_copy[write] = item
		write += 1
	}
	clear(&cells.items)
	append(&cells.items, ..order_copy)
	if write_err := ip_page_write(frame.data, .Index_Leaf, header.next_free, &cells); write_err.kind != .None {
		page_release(op.file, frame, false)
		return false
	}
	page_release(op.file, frame, true)
	if op.entries > 0 do op.entries -= 1
	return true
}
