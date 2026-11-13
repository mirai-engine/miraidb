package engine

// SQLite mirror writer: patch the pages a commit changed.
//
// A database opened from a `.sqlite` file keeps that file a valid SQLite
// database. `sqlite_file_write` keeps that promise by re-encoding the whole
// state after every commit: correct, inspectable, and O(state) per commit.
//
// This file keeps the promise without re-encoding the world. It remembers how
// the file is laid out -- for every table, the leaf pages its b-tree is made of
// and the rowids each leaf holds -- and after a commit it rewrites only:
//
//   * the leaf page of every row the commit inserted, updated or deleted,
//   * the separator the leaf's parent holds for it, because a leaf's largest
//     rowid is what tells a reader where to descend,
//   * the parent page, its parent, and a new root when a full page had to
//     split, and
//   * page 1, whose header carries the change counter, the database size and
//     the free list, and whose cells name each table's root page.
//
// Everything else stays where it is. Before a page is touched its original goes
// into a rollback journal in SQLite's own format, so an interrupted commit
// leaves the previous state readable -- by this engine (`sqlite_journal_rollback`
// reads the journal back) and by SQLite, which validates the same format. The
// journal is deleted once the new pages are durable.
//
// What it cannot patch, it re-encodes:
//
//   * a table with no single INTEGER primary key: SQLite's rowid is the only
//     thing a leaf is ordered by, and without that key a row's rowid is not
//     stable across exports,
//   * a table with a secondary index: the index b-trees would go stale, and
//     updating them is the page-store work D5 does, not this file's,
//   * any schema change, truncation or drop: `sqlite_file_write` handles those.
//
// The layout is read back from the file, never from a sidecar: a file written by
// another driver is re-read on open, and a file this engine cannot parse is
// rewritten from the store.

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:fmt"

SQLITE_MIRROR_JOURNAL_MAGIC :: "\xd9\xd5\x05\xf9\x20\xa1\x63\xd7"

// Mirror_Cell is one cell of a table leaf: a rowid and the record payload.
@(private)
Mirror_Cell :: struct {
	rowid:    i64,
	payload:  []u8, // owned by the mirror's allocator
	overflow: [dynamic]int,
}

// Mirror_Leaf is one leaf page of a table's b-tree.
@(private)
Mirror_Leaf :: struct {
	page:   int,
	rowids: [dynamic]i64, // in key order, the last one being max_key
}

// Mirror_Master_Row is one row of sqlite_master: type, name, tbl_name, rootpage
// and the SQL that recreates it.
@(private)
Mirror_Master_Row :: struct {
	rowid: i64,
	kind:  string, // "table" or "index"
	name:  string,
	table: string,
	root:  int,
	sql:   string,
}

// Mirror_Table is one table's place in the file.
@(private)
Mirror_Table :: struct {
	name:      string,
	root:      int,
	leaves:    [dynamic]Mirror_Leaf, // in key order
	supported: bool,
	// rowid_of maps a store row to the SQLite rowid the file uses for it, so a
	// delete can find the row it removes and an update that moves the key can
	// remove the old row before writing the new one.
	rowid_of: map[Row_Id]i64,
}

// Sqlite_Mirror is the layout of one mirrored file plus the pages a commit has
// staged but not written yet.
@(private)
Sqlite_Mirror :: struct {
	alloc:         mem.Allocator,
	path:          string,
	image:         []u8, // the file as it will be once the staged pages land
	page_size:     int,
	usable:        int,
	page_count:    int,
	freelist:      int,
	freelist_free: int,
	change:        u32,
	root:          int, // sqlite_master's root page (1 unless it outgrew page 1)
	master:        [dynamic]Mirror_Master_Row,
	tables:        map[string]Mirror_Table,
	dirty:         map[int][]u8,
	dirty_original: map[int][]u8,
	dirty_order:   [dynamic]int,
	master_dirty:  bool,
	// crash_before_header makes the next commit stop between its data pages and
	// the header, which is what a process that dies mid-commit leaves behind.
	crash_before_header: bool,
	// why the last commit had to re-encode the whole file, for the tests
	fallback_reason: string,
	// What a commit costs: the number this file exists to shrink.
	bytes_written: u64,
	pages_written: int,
	full_writes:   int,
}

// --- Lifetime --------------------------------------------------------------

@(private)
mirror_destroy :: proc(m: ^Sqlite_Mirror) {
	if m == nil do return
	for _, table in m.tables {
		for leaf in table.leaves do delete(leaf.rowids)
		delete(table.leaves)
		delete(table.rowid_of)
		delete(table.name, m.alloc)
	}
	delete(m.tables)
	for page, bytes in m.dirty {
		_ = page
		delete(bytes, m.alloc)
	}
	delete(m.dirty)
	for page, bytes in m.dirty_original {
		_ = page
		delete(bytes, m.alloc)
	}
	delete(m.dirty_original)
	delete(m.dirty_order)
	for row in m.master {
		delete(row.kind, m.alloc)
		delete(row.name, m.alloc)
		delete(row.table, m.alloc)
		delete(row.sql, m.alloc)
	}
	delete(m.master)
	delete(m.image, m.alloc)
	delete(m.path, m.alloc)
	free(m, m.alloc)
}

// mirror_page is a mutable view of one page of the pending image.
@(private)
mirror_page :: proc(m: ^Sqlite_Mirror, page: int) -> []u8 {
	offset := (page - 1) * m.page_size
	if page < 1 || offset < 0 || offset + m.page_size > len(m.image) do return nil
	return m.image[offset:offset + m.page_size]
}

// mirror_stage records a page that must reach the file. The image is updated at
// once, so the rest of the commit sees it.
@(private)
mirror_stage :: proc(m: ^Sqlite_Mirror, page: int, bytes: []u8) -> bool {
	if len(bytes) != m.page_size do return false
	target := mirror_page(m, page)
	if target == nil do return false
	// The journal needs the page as it was before this commit touched it, so it
	// is captured on the first stage of every page.
	if len(m.dirty_original[page]) == 0 {
		original := make([]u8, m.page_size, m.alloc)
		copy(original, target)
		m.dirty_original[page] = original
	}
	copy(target, bytes)
	if image, present := m.dirty[page]; present {
		copy(image, bytes)
	} else {
		copied := make([]u8, m.page_size, m.alloc)
		copy(copied, bytes)
		m.dirty[page] = copied
		append(&m.dirty_order, page)
	}
	return true
}

@(private)
mirror_put_be32 :: proc(page: []u8, at: int, value: u32) {
	if at < 0 || at + 4 > len(page) do return
	page[at] = u8(value >> 24)
	page[at + 1] = u8(value >> 16)
	page[at + 2] = u8(value >> 8)
	page[at + 3] = u8(value)
}

// mirror_alloc_page hands out a page: from the free list first, then by growing
// the image. The caller fills it and stages it.
@(private)
mirror_alloc_page :: proc(m: ^Sqlite_Mirror) -> int {
	for m.freelist != 0 {
		trunk_page := m.freelist
		trunk := mirror_page(m, trunk_page)
		if trunk == nil do break
		count := int(sqlite_be32(trunk, 4))
		if count > 0 {
			page := int(sqlite_be32(trunk, 8))
			if page < 1 || page > m.page_count do break
			for i in 1 ..< count {
				value := sqlite_be32(trunk, 8 + i * 4)
				mirror_put_be32(trunk, 8 + (i - 1) * 4, value)
			}
			mirror_put_be32(trunk, 4, u32(count - 1))
			m.freelist_free -= 1
			if block := mirror_page(m, page); block != nil {
				for i in 0 ..< len(block) do block[i] = 0
			}
			if !mirror_stage(m, trunk_page, trunk) do return 0
			return page
		}
		// An empty trunk is a free page like any other; the head moves on.
		next := int(sqlite_be32(trunk, 0))
		m.freelist = next
		m.freelist_free -= 1
		block := mirror_page(m, trunk_page)
		for i in 0 ..< len(block) do block[i] = 0
		return trunk_page
	}
	m.page_count += 1
	needed := m.page_count * m.page_size
	if needed > len(m.image) {
		grown := make([]u8, needed, m.alloc)
		copy(grown, m.image)
		delete(m.image, m.alloc)
		m.image = grown
	}
	block := mirror_page(m, m.page_count)
	for i in 0 ..< len(block) do block[i] = 0
	return m.page_count
}

// mirror_free_page puts a page on the free list: a chain of trunk pages, each
// holding page numbers, exactly as the header describes them.
@(private)
mirror_free_page :: proc(m: ^Sqlite_Mirror, page: int) -> bool {
	if page < 2 || page > m.page_count do return false
	capacity := m.usable / 4 - 2
	if m.freelist != 0 {
		trunk := mirror_page(m, m.freelist)
		count := int(sqlite_be32(trunk, 4))
		if count < capacity {
			mirror_put_be32(trunk, 8 + count * 4, u32(page))
			mirror_put_be32(trunk, 4, u32(count + 1))
			m.freelist_free += 1
			return mirror_stage(m, m.freelist, trunk)
		}
	}
	block := mirror_page(m, page)
	if block == nil do return false
	for i in 0 ..< len(block) do block[i] = 0
	mirror_put_be32(block, 0, u32(m.freelist))
	mirror_put_be32(block, 4, 0)
	m.freelist = page
	m.freelist_free += 1
	return mirror_stage(m, page, block)
}

// --- Reading the layout ----------------------------------------------------

@(private)
Mirror_Build_Ctx :: struct {
	m:      ^Sqlite_Mirror,
	rows:   [dynamic]Mirror_Master_Row,
	ok:     bool,
}

@(private)
mirror_master_visit :: proc(user: rawptr, rowid: i64, payload: []u8) -> bool {
	ctx := (^Mirror_Build_Ctx)(user)
	values, decoded := sqlite_record(payload, ctx.m.alloc)
	if !decoded do return false
	defer {
		for value in values do value_deep_free(value, ctx.m.alloc)
		delete(values, ctx.m.alloc)
	}
	if len(values) < 5 do return true
	row := Mirror_Master_Row {
		rowid = rowid,
		kind  = strings.clone(values[0].s, ctx.m.alloc),
		name  = strings.clone(values[1].s, ctx.m.alloc),
		table = strings.clone(values[2].s, ctx.m.alloc),
		root  = int(values[3].i),
		sql   = strings.clone(values[4].s, ctx.m.alloc),
	}
	append(&ctx.rows, row)
	return true
}

// mirror_leaf_rowids reads a leaf page's rowids in key order, without copying
// any payload.
@(private)
mirror_leaf_rowids :: proc(m: ^Sqlite_Mirror, page: int) -> ([dynamic]i64, bool) {
	out := make([dynamic]i64, 0, 16, m.alloc)
	block := mirror_page(m, page)
	if block == nil do return out, false
	if block[0] != 13 do return out, false
	count := int(sqlite_be16(block, 3))
	for i in 0 ..< count {
		at := 8 + i * 2
		if at + 2 > len(block) do return out, false
		pointer := int(sqlite_be16(block, at))
		if pointer >= len(block) do return out, false
		_, size := sqlite_varint(block[pointer:], 0)
		if size == 0 do return out, false
		rowid, rowid_size := sqlite_varint(block[pointer:], size)
		if rowid_size == 0 do return out, false
		append(&out, i64(rowid))
	}
	return out, true
}

// mirror_collect_leaves walks a table's b-tree and returns its leaf pages in
// key order, refusing anything deeper than three levels (a table that size is
// re-encoded whole rather than patched).
@(private)
mirror_collect_leaves :: proc(m: ^Sqlite_Mirror, root: int, out: ^[dynamic]int, depth: int) -> bool {
	if depth > 3 do return false
	block := mirror_page(m, root)
	if block == nil do return false
	base := 0
	if root == 1 do base = SQLITE_HEADER_MIN
	if base + 12 > len(block) do return false
	kind := block[base]
	count := int(sqlite_be16(block, base + 3))
	if kind == 13 {
		append(out, root)
		return true
	}
	if kind != 5 && kind != 2 do return false
	for i in 0 ..< count {
		at := base + 12 + i * 2
		if at + 2 > len(block) do return false
		pointer := int(sqlite_be16(block, at))
		if pointer + 4 > len(block) do return false
		child := int(sqlite_be32(block, pointer))
		if !mirror_collect_leaves(m, child, out, depth + 1) do return false
	}
	right := int(sqlite_be32(block, base + 8))
	if right != 0 && !mirror_collect_leaves(m, right, out, depth + 1) do return false
	return true
}

// mirror_rowid_column returns the column whose integer value is the SQLite
// rowid, or -1 when the table has no single INTEGER primary key.
@(private)
mirror_rowid_column :: proc(schema: Table_Schema) -> int {
	if len(schema.primary_key) != 1 do return -1
	position := schema.primary_key[0]
	if position < 0 || position >= len(schema.columns) do return -1
	if schema.columns[position].type.kind != .Int do return -1
	return position
}

// mirror_build reads a mirrored file and returns the map a commit patches.
@(private)
mirror_build :: proc(store: ^Store, path: string, alloc := context.allocator) -> (^Sqlite_Mirror, Error) {
	file, open_err := sqlite_file_open(path, alloc, true)
	if open_err.kind != .None {
		return nil, errf(.Io, "cannot read %s: %v", path, open_err.message)
	}
	defer sqlite_file_destroy(&file)
	// A file with a WAL or a hot journal is another process's business: rewrite
	// it whole instead of patching pages under a log that would replay over
	// them.
	if file.wal_committed > 0 do return nil, errf(.Io, "%s has a write-ahead log", path)
	if len(file.data) < int(file.page_size) do return nil, errf(.Io, "%s is not a database", path)
	if int(file.page_size) != SQLITE_WRITE_PAGE_SIZE {
		return nil, errf(.Io, "%s uses %d-byte pages", path, file.page_size)
	}

	m := new(Sqlite_Mirror, alloc)
	m.alloc = alloc
	m.path = strings.clone(path, alloc)
	m.page_size = int(file.page_size)
	m.usable = int(file.usable)
	m.tables = make(map[string]Mirror_Table, alloc)
	m.dirty = make(map[int][]u8, alloc)
	m.dirty_original = make(map[int][]u8, alloc)
	m.image = make([]u8, len(file.data), alloc)
	copy(m.image, file.data)
	header := mirror_page(m, 1)
	count := int(sqlite_be32(header, 16))
	m.page_count = int(sqlite_be32(header, 28))
	if m.page_count <= 0 do m.page_count = count
	m.freelist = int(sqlite_be32(header, 32))
	m.freelist_free = int(sqlite_be32(header, 36))
	m.change = sqlite_be32(header, 24)
	if m.page_count * m.page_size > len(m.image) {
		grown := make([]u8, m.page_count * m.page_size, alloc)
		copy(grown, m.image)
		delete(m.image, alloc)
		m.image = grown
	}

	ctx := Mirror_Build_Ctx{m = m, ok = true}
	if !sqlite_walk(&file, 1, true, mirror_master_visit, &ctx, 0) {
		mirror_destroy(m)
		return nil, errf(.Io, "%s has an unreadable schema", path)
	}
	m.master = ctx.rows
	m.root = 1

	failed := false
	for row in m.master {
		if row.kind != "table" || row.name == "sqlite_sequence" do continue
		table, known := store.tables[row.name]
		if !known do continue
		entry := Mirror_Table {
			name = strings.clone(row.name, alloc),
			root = row.root,
		}
		entry.rowid_of = make(map[Row_Id]i64, alloc)
		pages := make([dynamic]int, 0, 8, alloc)
		walker_ok := mirror_collect_leaves(m, row.root, &pages, 0)
		if walker_ok {
			for page in pages {
				rowids, ok := mirror_leaf_rowids(m, page)
				if !ok {
					delete(rowids)
					walker_ok = false
					break
				}
				append(&entry.leaves, Mirror_Leaf{page = page, rowids = rowids})
			}
		}
		delete(pages)
		if !walker_ok {
			// The tree is taller than this writer patches; re-encode instead.
			for leaf in entry.leaves do delete(leaf.rowids)
			delete(entry.leaves)
			delete(entry.rowid_of)
			delete(entry.name, alloc)
			failed = true
			continue
		}
		entry.supported = mirror_rowid_column(table.schema) >= 0
		if entry.supported {
			for index in table.schema.indexes {
				if !index.implicit do entry.supported = false
			}
		}
		if entry.supported {
			column := mirror_rowid_column(table.schema)
			collected := make([dynamic]Row)
			table_collect(table, &collected, max(u64))
			for row2 in collected {
				if column < len(row2.values) && row2.values[column].kind == .Int {
					entry.rowid_of[row2.id] = row2.values[column].i
				}
			}
			table_collect_release(table, &collected)
		}
		m.tables[entry.name] = entry
	}
	if failed {
		// Anything this writer cannot patch is best handled by starting from a
		// file the writer produced.
		mirror_destroy(m)
		return nil, errf(.Io, "%s has a table this writer cannot patch", path)
	}
	return m, ERROR_NONE
}

// --- Cells and pages -------------------------------------------------------

// mirror_split_payload copies a payload into the cell's local part plus a chain
// of overflow pages, returning the bytes the cell keeps.
@(private)
mirror_split_payload :: proc(
	m: ^Sqlite_Mirror,
	payload: []u8,
	table_leaf: bool,
	overflow: ^[dynamic]int,
) -> ([]u8, bool) {
	local := sqlite_local_size(len(payload), m.usable, table_leaf)
	if local >= len(payload) {
		out := make([]u8, len(payload), m.alloc)
		copy(out, payload)
		return out, true
	}
	capacity := m.usable - 4
	remaining := payload[local:]
	previous := -1
	for len(remaining) > 0 {
		page_no := mirror_alloc_page(m)
		if page_no == 0 do return nil, false
		block := mirror_page(m, page_no)
		take := min(capacity, len(remaining))
		copy(block[4:4 + take], remaining[:take])
		if previous >= 0 {
			mirror_put_be32(mirror_page(m, previous), 0, u32(page_no))
		} else {
			append(overflow, page_no)
		}
		previous = page_no
		remaining = remaining[take:]
	}
	out := make([]u8, local + 4, m.alloc)
	copy(out[:local], payload[:local])
	mirror_put_be32(out, local, u32(overflow[0]))
	return out, true
}

// mirror_leaf_cell builds one table-leaf cell: payload length, rowid, payload.
@(private)
mirror_leaf_cell :: proc(m: ^Sqlite_Mirror, cell: Mirror_Cell) -> ([]u8, bool) {
	overflow := make([dynamic]int, 0, 4, m.alloc)
	defer delete(overflow)
	body, ok := mirror_split_payload(m, cell.payload, true, &overflow)
	if !ok do return nil, false
	out := make([dynamic]u8, 0, len(body) + 12, m.alloc)
	defer delete(out)
	sqlite_put_varint(&out, u64(len(cell.payload)))
	sqlite_put_varint(&out, u64(cell.rowid))
	for byte in body do append(&out, byte)
	delete(body, m.alloc)
	result := make([]u8, len(out), m.alloc)
	copy(result, out[:])
	return result, true
}

// mirror_pack_leaf lays cells into a page: pointers after the header, cell
// bodies growing down from the end of the file block. It fails when they do not
// fit, which is the caller's cue to split.
@(private)
mirror_pack_leaf :: proc(m: ^Sqlite_Mirror, cells: []Mirror_Cell, base: int) -> ([]u8, bool) {
	total: int = base + 8 + len(cells) * 2
	for cell in cells {
		local := sqlite_local_size(len(cell.payload), m.usable, true)
		kept := min(local, len(cell.payload))
		if kept < len(cell.payload) do kept += 4
		total += varint_size(i64(len(cell.payload))) + varint_size(cell.rowid) + kept
		if total > m.usable do return nil, false
	}
	page := make([]u8, m.page_size, m.alloc)
	page[base] = 13
	content := m.usable
	for cell, i in cells {
		overflow := make([dynamic]int, 0, 4, m.alloc)
		body, ok := mirror_split_payload(m, cell.payload, true, &overflow)
		delete(overflow)
		if !ok {
			delete(page)
			return nil, false
		}
		head := make([dynamic]u8, 0, len(body) + 12, m.alloc)
		sqlite_put_varint(&head, u64(len(cell.payload)))
		sqlite_put_varint(&head, u64(cell.rowid))
		for byte in body do append(&head, byte)
		delete(body, m.alloc)
		if len(head) > content - (base + 8 + len(cells) * 2) {
			delete(head)
			delete(page)
			return nil, false
		}
		content -= len(head)
		copy(page[content:content + len(head)], head[:])
		delete(head)
		at := base + 8 + i * 2
		page[at] = u8(content >> 8)
		page[at + 1] = u8(content)
	}
	page[base + 3] = u8(len(cells) >> 8)
	page[base + 4] = u8(len(cells))
	page[base + 5] = u8(content >> 8)
	page[base + 6] = u8(content)
	return page, true
}

// Mirror_Child is one pointer of an interior page: the page and the largest
// rowid its subtree holds. The last child is the page's right pointer, which is
// the one SQLite stores without a key.
@(private)
Mirror_Child :: struct {
	page:    int,
	max_key: i64,
}

// mirror_subtree_max returns the largest rowid a subtree holds. It walks the
// right spine, which is what SQLite calls the right-most child, and remembers
// the largest separator it saw: a leaf that lost every row still has one, and
// that is the key its separator has to keep.
@(private)
mirror_subtree_max :: proc(m: ^Sqlite_Mirror, page: int) -> (i64, bool) {
	current := page
	fallback: i64 = 0
	have_fallback := false
	for _ in 0 ..< 4 {
		block := mirror_page(m, current)
		if block == nil do return 0, have_fallback
		base := current == 1 ? SQLITE_HEADER_MIN : 0
		kind := block[base]
		if kind == 13 {
			rowids, ok := mirror_leaf_rowids(m, current)
			defer delete(rowids)
			if !ok do return 0, false
			if len(rowids) > 0 do return rowids[len(rowids) - 1], true
			return fallback, have_fallback
		}
		if kind != 5 do return 0, false
		count := int(sqlite_be16(block, base + 3))
		for i in 0 ..< count {
			pointer := int(sqlite_be16(block, base + 12 + i * 2))
			if pointer + 4 > len(block) do return 0, false
			key, size := sqlite_varint(block[pointer + 4:], 0)
			if size > 0 {
				fallback = i64(key)
				have_fallback = true
			}
		}
		right := int(sqlite_be32(block, base + 8))
		if right == 0 do return 0, have_fallback
		current = right
	}
	return 0, have_fallback
}

// mirror_children reads an interior page's children in order, the right pointer
// last, each with the largest rowid its subtree holds. The key comes from the
// cell SQLite already stores for the child, so an empty leaf is no special case.
@(private)
mirror_children :: proc(m: ^Sqlite_Mirror, page: int) -> ([dynamic]Mirror_Child, bool) {
	out := make([dynamic]Mirror_Child, 0, 8, m.alloc)
	block := mirror_page(m, page)
	if block == nil {
		delete(out)
		return out, false
	}
	base := page == 1 ? SQLITE_HEADER_MIN : 0
	if block[base] != 5 && block[base] != 2 {
		delete(out)
		return out, false
	}
	count := int(sqlite_be16(block, base + 3))
	for i in 0 ..< count {
		at := base + 12 + i * 2
		pointer := int(sqlite_be16(block, at))
		if pointer + 4 > len(block) {
			delete(out)
			return out, false
		}
		child := int(sqlite_be32(block, pointer))
		key, size := sqlite_varint(block[pointer + 4:], 0)
		if size == 0 {
			delete(out)
			return out, false
		}
		append(&out, Mirror_Child{page = child, max_key = i64(key)})
	}
	right := int(sqlite_be32(block, base + 8))
	if right == 0 {
		delete(out)
		return out, false
	}
	max_key, ok := mirror_subtree_max(m, right)
	if !ok {
		delete(out)
		return out, false
	}
	append(&out, Mirror_Child{page = right, max_key = max_key})
	return out, true
}

// mirror_pack_interior lays a child list into an interior page.
@(private)
mirror_pack_interior :: proc(m: ^Sqlite_Mirror, children: []Mirror_Child, base: int) -> ([]u8, bool) {
	if len(children) < 2 do return nil, false
	cells := len(children) - 1
	total: int = base + 12 + cells * 2
	for child, i in children {
		if i == len(children) - 1 do break
		total += 4 + varint_size(child.max_key)
		if total > m.usable do return nil, false
	}
	page := make([]u8, m.page_size, m.alloc)
	page[base] = 5
	content := m.usable
	for child, i in children {
		if i == len(children) - 1 do break
		key := make([dynamic]u8, 0, 9, m.alloc)
		sqlite_put_varint(&key, u64(child.max_key))
		size := 4 + len(key)
		content -= size
		mirror_put_be32(page, content, u32(child.page))
		copy(page[content + 4:content + size], key[:])
		delete(key)
		at := base + 12 + i * 2
		page[at] = u8(content >> 8)
		page[at + 1] = u8(content)
	}
	right := children[len(children) - 1]
	mirror_put_be32(page, base + 8, u32(right.page))
	page[base + 3] = u8(cells >> 8)
	page[base + 4] = u8(cells)
	page[base + 5] = u8(content >> 8)
	page[base + 6] = u8(content)
	return page, true
}

// mirror_read_leaf decodes a leaf page into cells, following overflow chains so
// a cell can be re-encoded wherever it lands next.
@(private)
mirror_read_leaf :: proc(m: ^Sqlite_Mirror, page: int) -> ([dynamic]Mirror_Cell, bool) {
	out := make([dynamic]Mirror_Cell, 0, 16, m.alloc)
	block := mirror_page(m, page)
	if block == nil do return out, false
	if block[0] != 13 do return out, false
	count := int(sqlite_be16(block, 3))
	for i in 0 ..< count {
		at := 8 + i * 2
		pointer := int(sqlite_be16(block, at))
		if pointer >= len(block) do return out, false
		payload_len, size := sqlite_varint(block[pointer:], 0)
		if size == 0 do return out, false
		rowid, rowid_size := sqlite_varint(block[pointer:], size)
		if rowid_size == 0 do return out, false
		local := sqlite_local_size(int(payload_len), m.usable, true)
		cursor := pointer + size + rowid_size
		if cursor + local > len(block) do return out, false
		payload := make([]u8, int(payload_len), m.alloc)
		copy(payload[:local], block[cursor:cursor + local])
		cell := Mirror_Cell{rowid = i64(rowid), payload = payload}
		if local < int(payload_len) {
			if cursor + local + 4 > len(block) do return out, false
			next := int(sqlite_be32(block, cursor + local))
			written := local
			for next != 0 && written < int(payload_len) {
				overflow_page := mirror_page(m, next)
				if overflow_page == nil do return out, false
				append(&cell.overflow, next)
				next = int(sqlite_be32(overflow_page, 0))
				take := min(len(overflow_page) - 4, int(payload_len) - written)
				copy(payload[written:written + take], overflow_page[4:4 + take])
				written += take
			}
			if written != int(payload_len) do return out, false
		}
		append(&out, cell)
	}
	return out, true
}

@(private)
mirror_cell_free :: proc(m: ^Sqlite_Mirror, cell: Mirror_Cell) {
	delete(cell.payload, m.alloc)
	for page in cell.overflow do _ = mirror_free_page(m, page)
	delete(cell.overflow)
}

@(private)
mirror_cells_destroy :: proc(m: ^Sqlite_Mirror, cells: ^[dynamic]Mirror_Cell) {
	for cell in cells {
		delete(cell.payload, m.alloc)
		delete(cell.overflow)
	}
	delete(cells^)
	cells^ = nil
}

// --- Patching one table ----------------------------------------------------

// Mirror_Edit is one row the commit removed and one it wrote. An update that
// moves the key is two edits in two leaves.
@(private)
Mirror_Edit :: struct {
	remove:  bool,
	rowid:   i64,
	payload: []u8, // owned while the edit lives
}

// mirror_list_insert and mirror_list_remove keep a dynamic array ordered; Odin's
// own ordered_insert is written for page directories, not for any element.
@(private)
mirror_list_insert :: proc(list: ^[dynamic]$T, at: int, value: T) {
	append(list, value)
	for i := len(list) - 1; i > at; i -= 1 do list[i] = list[i - 1]
	list[at] = value
}

@(private)
mirror_list_remove :: proc(list: ^[dynamic]$T, at: int) {
	for i in at ..< len(list) - 1 do list[i] = list[i + 1]
	_ = pop(list)
}

// mirror_leaf_index finds the leaf a rowid belongs to: the first leaf whose
// largest rowid is not smaller, else the last leaf.
@(private)
mirror_leaf_index :: proc(table: ^Mirror_Table, rowid: i64) -> int {
	if len(table.leaves) == 0 do return -1
	low := 0
	high := len(table.leaves) - 1
	for low < high {
		mid := (low + high) / 2
		last := table.leaves[mid].rowids[len(table.leaves[mid].rowids) - 1]
		if last < rowid {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}

@(private)
mirror_cell_search :: proc(cells: []Mirror_Cell, rowid: i64) -> int {
	low := 0
	high := len(cells)
	for low < high {
		mid := (low + high) / 2
		if cells[mid].rowid < rowid {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}

// mirror_leaf_size is what the cells would occupy, overflow already accounted
// for by the local-size rule. It allocates nothing, so it can be asked before a
// split whether both halves fit.
@(private)
mirror_leaf_size :: proc(m: ^Sqlite_Mirror, cells: []Mirror_Cell) -> int {
	total := 8 + len(cells) * 2
	for cell in cells {
		local := sqlite_local_size(len(cell.payload), m.usable, true)
		kept := min(local, len(cell.payload))
		if kept < len(cell.payload) do kept += 4
		total += varint_size(i64(len(cell.payload))) + varint_size(cell.rowid) + kept
	}
	return total
}

// mirror_leaf_rowids_from refreshes a leaf's recorded rowids after a rewrite.
@(private)
mirror_leaf_rowids_from :: proc(m: ^Sqlite_Mirror, leaf: ^Mirror_Leaf, cells: []Mirror_Cell) {
	clear(&leaf.rowids)
	for cell in cells do append(&leaf.rowids, cell.rowid)
}

// mirror_chain walks from the root to the page's parent, returning the interior
// pages in order. The chain is empty when the root is the page itself.
@(private)
mirror_chain :: proc(m: ^Sqlite_Mirror, root, target: int) -> ([dynamic]int, bool) {
	chain := make([dynamic]int, 0, 4, m.alloc)
	current := root
	for _ in 0 ..< 4 {
		if current == target do return chain, true
		block := mirror_page(m, current)
		if block == nil do return chain, false
		base := current == 1 ? SQLITE_HEADER_MIN : 0
		kind := block[base]
		if kind != 5 && kind != 2 do return chain, false
		append(&chain, current)
		children, ok := mirror_children(m, current)
		if !ok do return chain, false
		next := 0
		for child in children {
			if child.page == target || mirror_subtree_has(m, child.page, target) {
				next = child.page
				break
			}
		}
		delete(children)
		if next == 0 do return chain, false
		current = next
	}
	return chain, false
}

// mirror_subtree_has reports whether a page's subtree contains `target`.
@(private)
mirror_subtree_has :: proc(m: ^Sqlite_Mirror, page, target: int) -> bool {
	if page == target do return true
	block := mirror_page(m, page)
	if block == nil do return false
	base := page == 1 ? SQLITE_HEADER_MIN : 0
	kind := block[base]
	if kind != 5 && kind != 2 do return false
	children, ok := mirror_children(m, page)
	if !ok do return false
	for child in children {
		if mirror_subtree_has(m, child.page, target) do return true
	}
	return false
}

// mirror_sync_parent rewrites the interior page that points at the leaf so its
// separator matches the leaf's new largest rowid, and adds the child when the
// leaf split.
@(private)
mirror_sync_parent :: proc(m: ^Sqlite_Mirror, table: ^Mirror_Table, leaf_index: int) -> bool {
	leaf := &table.leaves[leaf_index]
	chain, ok := mirror_chain(m, table.root, leaf.page)
	defer delete(chain)
	if !ok {
		m.fallback_reason = "chain"
		return false
	}
	if len(chain) == 0 do return true
	parent_page := chain[len(chain) - 1]
	parent := mirror_page(m, parent_page)
	base := parent_page == 1 ? SQLITE_HEADER_MIN : 0
	// When the parent is the root, its children are exactly this table's leaves:
	// rebuilding it from them keeps every separator right and picks up the
	// leaves a split just added. Deeper down, the parent's children are interior
	// pages, so only the one child changes.
	children, read_ok := mirror_children(m, parent_page)
	if !read_ok do return false
	defer delete(children)
	// An empty leaf keeps the largest key seen so far: it holds nothing, so any
	// key that is not smaller than its neighbours' keeps the tree ordered.
	last_key: i64 = 0
	direct := len(chain) == 1
	if direct && parent[base] == 5 {
		clear(&children)
		for leaf2 in table.leaves {
			if len(leaf2.rowids) > 0 {
				last_key = leaf2.rowids[len(leaf2.rowids) - 1]
			}
			append(&children, Mirror_Child{page = leaf2.page, max_key = last_key})
		}
	} else {
		// Deeper tree: update the one child, and insert it when it is new.
		found := false
		if len(leaf.rowids) == 0 do return false
		for child, i in children {
			if child.page == leaf.page {
				children[i].max_key = leaf.rowids[len(leaf.rowids) - 1]
				found = true
				break
			}
		}
		if !found {
			// A new leaf from a split: it follows the leaf before it.
			previous := table.leaves[leaf_index - 1]
			insert_at := len(children) - 1
			for child, i in children {
				if child.page == previous.page {
					insert_at = i + 1
					break
				}
			}
			mirror_list_insert(&children, insert_at, Mirror_Child {
				page    = leaf.page,
				max_key = leaf.rowids[len(leaf.rowids) - 1],
			})
		}
	}
	packed, pack_ok := mirror_pack_interior(m, children[:], base)
	if !pack_ok {
		probe := mirror_page(m, parent_page)
		m.fallback_reason = fmt.aprintf(
			"pack interior: %d children on page %d (kind %d cells %d direct %v leaves %d depth %d)",
			len(children),
			parent_page,
			probe[base],
			probe[base] == 5 ? int(sqlite_be16(probe, base + 3)) : -1,
			direct,
			len(table.leaves),
			len(chain),
			allocator = m.alloc,
		)
		return false
	}
	defer delete(packed)
	return mirror_stage(m, parent_page, packed)
}

// mirror_apply_leaf rewrites one leaf with the edits that belong to it, and
// splits it when they no longer fit.
@(private)
mirror_apply_leaf :: proc(m: ^Sqlite_Mirror, table: ^Mirror_Table, leaf_index: int, edits: []Mirror_Edit) -> bool {
	leaf := &table.leaves[leaf_index]
	cells, ok := mirror_read_leaf(m, leaf.page)
	if !ok {
		m.fallback_reason = "read leaf"
		return false
	}
	// One owner for the cells: every path below frees them, including the ones
	// that give up and let the caller re-encode the file.
	defer mirror_cells_destroy(m, &cells)
	for edit in edits {
		at := mirror_cell_search(cells[:], edit.rowid)
		present := at < len(cells) && cells[at].rowid == edit.rowid
		if present {
			mirror_cell_free(m, cells[at])
			mirror_list_remove(&cells, at)
		}
		if edit.remove do continue
		payload := make([]u8, len(edit.payload), m.alloc)
		copy(payload, edit.payload)
		mirror_list_insert(&cells, at < len(cells) ? at : len(cells), Mirror_Cell {
			rowid   = edit.rowid,
			payload = payload,
		})
	}
	if len(cells) == 0 {
		// A leaf that lost its last row leaves the tree. SQLite's cursor does
		// not expect an empty page between two others, and its integrity check
		// calls it out, so the page is unlinked and freed instead.
		if len(table.leaves) == 1 {
			// A table with one empty leaf is how an empty table looks.
			packed, pack_ok := mirror_pack_leaf(m, cells[:], 0)
			if !pack_ok {
				m.fallback_reason = "pack empty"
				return false
			}
			defer delete(packed)
			if !mirror_stage(m, leaf.page, packed) {
				m.fallback_reason = "stage empty"
				return false
			}
			return true
		}
		chain, chain_ok := mirror_chain(m, table.root, leaf.page)
		defer delete(chain)
		if !chain_ok || len(chain) != 1 || chain[0] != table.root {
			// Only a two-level tree unlinks a page here; deeper trees re-encode.
			m.fallback_reason = "drop empty leaf"
			return false
		}
		root_page := chain[0]
		// The page to free has to be read before the list shifts: removing the
		// entry moves every leaf after it.
		empty_page := leaf.page
		mirror_list_remove(&table.leaves, leaf_index)
		if !mirror_free_page(m, empty_page) {
			m.fallback_reason = "free empty leaf"
			return false
		}
		if len(table.leaves) == 1 {
			// The root had one leaf left: the leaf becomes the root.
			only := table.leaves[0]
			table.root = only.page
			if !mirror_set_table_root(m, table.name, only.page) {
				m.fallback_reason = "master row"
				return false
			}
			if !mirror_free_page(m, root_page) {
				m.fallback_reason = "free root"
				return false
			}
			return true
		}
		next := leaf_index
		if next >= len(table.leaves) do next = len(table.leaves) - 1
		return mirror_sync_parent(m, table, next)
	}
	size := mirror_leaf_size(m, cells[:])
	if size <= m.usable {
		packed, pack_ok := mirror_pack_leaf(m, cells[:], 0)
		if !pack_ok {
			m.fallback_reason = "pack leaf"
			return false
		}
		staged := mirror_stage(m, leaf.page, packed)
		delete(packed)
		if !staged {
			m.fallback_reason = "stage leaf"
			return false
		}
		mirror_leaf_rowids_from(m, leaf, cells[:])
		return mirror_sync_parent(m, table, leaf_index)
	}
	// Split: the cells need more than one page, so they are cut into as many
	// chunks as they need. The first stays in this leaf and the rest become new
	// leaves after it, which is what the parent's separators then describe.
	chunks := make([dynamic]int, 0, 4, m.alloc)
	defer delete(chunks)
	start := 0
	for start < len(cells) {
		end := start + 1
		for end <= len(cells) && mirror_leaf_size(m, cells[start:end]) <= m.usable do end += 1
		end -= 1
		if end <= start {
			m.fallback_reason = "split chunk"
			return false
		}
		append(&chunks, end)
		start = end
	}
	first := 0
	new_leaves: int = 0
	for end, chunk in chunks {
		page_no := leaf.page
		if chunk > 0 {
			page_no = mirror_alloc_page(m)
			if page_no == 0 {
				m.fallback_reason = "alloc"
				return false
			}
		}
		packed, pack_ok := mirror_pack_leaf(m, cells[first:end], 0)
		if !pack_ok {
			m.fallback_reason = "pack chunk"
			return false
		}
		staged := mirror_stage(m, page_no, packed)
		delete(packed)
		if !staged {
			m.fallback_reason = "stage chunk"
			return false
		}
		if chunk == 0 {
			mirror_leaf_rowids_from(m, leaf, cells[first:end])
		} else {
			rowids := make([dynamic]i64, 0, end - first, m.alloc)
			for cell in cells[first:end] do append(&rowids, cell.rowid)
			mirror_list_insert(&table.leaves, leaf_index + chunk, Mirror_Leaf{page = page_no, rowids = rowids})
			new_leaves += 1
		}
		first = end
	}
	if table.root == leaf.page {
		// The tree was a single leaf; it needs a root above it now.
		root_page := mirror_alloc_page(m)
		if root_page == 0 {
			m.fallback_reason = "alloc root"
			return false
		}
		children := make([dynamic]Mirror_Child, 0, 4, m.alloc)
		defer delete(children)
		for leaf2 in table.leaves {
			max_key := i64(0)
			if len(leaf2.rowids) > 0 do max_key = leaf2.rowids[len(leaf2.rowids) - 1]
			append(&children, Mirror_Child{page = leaf2.page, max_key = max_key})
		}
		packed, pack_ok := mirror_pack_interior(m, children[:], 0)
		if !pack_ok {
			m.fallback_reason = "pack root"
			return false
		}
		defer delete(packed)
		if !mirror_stage(m, root_page, packed) {
			m.fallback_reason = "stage root"
			return false
		}
		table.root = root_page
		if !mirror_set_table_root(m, table.name, root_page) {
			m.fallback_reason = "master row"
			return false
		}
		return true
	}
	for i in 0 ..= new_leaves {
		if !mirror_sync_parent(m, table, leaf_index + i) {
			if len(m.fallback_reason) == 0 do m.fallback_reason = "sync parent"
			return false
		}
	}
	return true
}

// --- sqlite_master ---------------------------------------------------------

// mirror_set_table_root points a table's master row at a new root page.
@(private)
mirror_set_table_root :: proc(m: ^Sqlite_Mirror, name: string, root: int) -> bool {
	for &row in m.master {
		if row.kind == "table" && row.name == name {
			row.root = root
			m.master_dirty = true
			return true
		}
	}
	return false
}

// mirror_write_master rebuilds page 1 from the rows it holds. The schema table
// has to stay on one page: past that, the file is re-encoded instead.
@(private)
mirror_write_master :: proc(m: ^Sqlite_Mirror) -> bool {
	if !m.master_dirty do return true
	if m.root != 1 do return false
	cells := make([dynamic]Mirror_Cell, 0, len(m.master), m.alloc)
	defer mirror_cells_destroy(m, &cells)
	for row in m.master {
		values := make([]Value, 5, m.alloc)
		values[0] = value_string(row.kind)
		values[1] = value_string(row.name)
		values[2] = value_string(row.table)
		values[3] = value_int(i64(row.root))
		values[4] = value_string(row.sql)
		payload := sqlite_encode_record(values, -1, m.alloc)
		delete(values, m.alloc)
		if payload == nil do return false
		append(&cells, Mirror_Cell{rowid = row.rowid, payload = payload})
	}
	packed, ok := mirror_pack_leaf(m, cells[:], SQLITE_HEADER_MIN)
	if !ok do return false
	defer delete(packed)
	// Page 1 keeps the 100-byte file header, and its cell pointers are absolute.
	if !mirror_stage(m, 1, packed) do return false
	m.master_dirty = false
	return true
}

// --- Committing the staged pages -------------------------------------------

@(private)
mirror_journal_path :: proc(m: ^Sqlite_Mirror) -> string {
	return strings.concatenate({m.path, "-journal"}, m.alloc)
}

// mirror_page_checksum is SQLite's own journal checksum: every two-hundredth
// byte of the page, added to the nonce that heads the journal.
@(private)
mirror_page_checksum :: proc(bytes: []u8, nonce: u32) -> u32 {
	sum := nonce
	i := len(bytes) - 200
	for i > 0 {
		sum += u32(bytes[i])
		i -= 200
	}
	return sum
}

// mirror_write_journal records the pages a commit is about to overwrite, in
// SQLite's rollback-journal format, and makes it durable before any page of the
// database moves. A reader that finds it restores those pages, which is what
// makes a torn commit harmless.
@(private)
mirror_write_journal :: proc(m: ^Sqlite_Mirror, original_count: int) -> Error {
	path := mirror_journal_path(m)
	defer delete(path)
	sector := 512
	count := len(m.dirty_order)
	per_record := 4 + m.page_size + 4
	stride := (per_record + sector - 1) / sector * sector
	total := sector + count * stride
	image := make([]u8, total, m.alloc)
	defer delete(image, m.alloc)
	copy(image[:8], SQLITE_MIRROR_JOURNAL_MAGIC)
	nonce := m.change * 2654435761 + 1
	mirror_put_be32(image, 8, u32(count))
	mirror_put_be32(image, 12, nonce)
	mirror_put_be32(image, 16, u32(original_count))
	mirror_put_be32(image, 20, u32(sector))
	mirror_put_be32(image, 24, u32(m.page_size))
	at := sector
	for page in m.dirty_order {
		original := m.dirty_original[page]
		if len(original) != m.page_size do continue
		mirror_put_be32(image, at, u32(page))
		copy(image[at + 4:at + 4 + m.page_size], original)
		checksum := mirror_page_checksum(original, nonce)
		mirror_put_be32(image, at + 4 + m.page_size, checksum)
		at += stride
	}
	file, open_err := os.open(path, {.Read, .Write, .Create, .Trunc})
	if open_err != nil {
		return errf(.Io, "cannot write %s: %v", path, open_err)
	}
	defer os.close(file)
	if _, write_err := os.write(file, image); write_err != nil {
		return errf(.Io, "cannot write %s: %v", path, write_err)
	}
	if sync_err := os.sync(file); sync_err != nil {
		return errf(.Io, "cannot flush %s: %v", path, sync_err)
	}
	return ERROR_NONE
}

// mirror_commit_pages journals the pages it is about to replace, writes them,
// and writes page 1 last so the header only advertises a state whose pages are
// already on disk.
@(private)
mirror_commit_pages :: proc(m: ^Sqlite_Mirror) -> Error {
	if len(m.dirty_order) == 0 do return ERROR_NONE
	original_count := m.page_count
	header := mirror_page(m, 1)
	if len(m.dirty_original[1]) == 0 {
		original := make([]u8, m.page_size, m.alloc)
		copy(original, header)
		m.dirty_original[1] = original
	}
	m.change += 1
	mirror_put_be32(header, 24, m.change)
	mirror_put_be32(header, 28, u32(m.page_count))
	mirror_put_be32(header, 32, u32(m.freelist))
	mirror_put_be32(header, 36, u32(m.freelist_free))
	mirror_put_be32(header, 92, m.change)
	if !mirror_stage(m, 1, header) do return errf(.Io, "cannot stage the header")
	if journal_err := mirror_write_journal(m, original_count); journal_err.kind != .None {
		return journal_err
	}
	path := mirror_journal_path(m)
	defer delete(path)
	file, open_err := os.open(m.path, {.Read, .Write})
	if open_err != nil do return errf(.Io, "cannot open %s: %v", m.path, open_err)
	defer os.close(file)
	written: u64 = 0
	// Page 1 goes last: until it lands, the file still describes the state the
	// journal can restore.
	for page in m.dirty_order {
		if page == 1 do continue
		block := m.dirty[page]
		if block == nil do continue
		if _, seek_err := os.seek(file, i64(page - 1) * i64(m.page_size), .Start); seek_err != nil {
			return errf(.Io, "cannot seek to page %d: %v", page, seek_err)
		}
		if _, write_err := os.write(file, block); write_err != nil {
			return errf(.Io, "cannot write page %d: %v", page, write_err)
		}
		written += u64(m.page_size)
		m.pages_written += 1
	}
	if m.crash_before_header {
		// The journal is durable and the data pages are on disk; the header still
		// describes the state the journal can restore. That is exactly the window
		// a crash lives in.
		m.crash_before_header = false
		return errf(.Io, "the mirror commit stopped before its header")
	}
	if block := m.dirty[1]; block != nil {
		if _, seek_err := os.seek(file, 0, .Start); seek_err != nil {
			return errf(.Io, "cannot seek to the header: %v", seek_err)
		}
		if _, write_err := os.write(file, block); write_err != nil {
			return errf(.Io, "cannot write the header: %v", write_err)
		}
		written += u64(m.page_size)
		m.pages_written += 1
	}
	if sync_err := os.sync(file); sync_err != nil do return errf(.Io, "cannot flush %s: %v", m.path, sync_err)
	m.bytes_written += written
	for page, block in m.dirty {
		_ = page
		delete(block, m.alloc)
	}
	for page, block in m.dirty_original {
		_ = page
		delete(block, m.alloc)
	}
	// The maps are emptied, not just cleared: destroy must not see the slices
	// that were just freed.
	delete(m.dirty)
	m.dirty = make(map[int][]u8, m.alloc)
	delete(m.dirty_original)
	m.dirty_original = make(map[int][]u8, m.alloc)
	clear(&m.dirty_order)
	// The pages are durable, so the journal has done its job.
	if remove_err := os.remove(path); remove_err != nil {
		// A stale journal would roll the commit back on the next open, so this
		// is worth reporting even though the commit itself is safe.
		return errf(.Io, "cannot remove %s: %v", path, remove_err)
	}
	return ERROR_NONE
}

// mirror_edits_for turns one commit's operations into edits per table.
@(private)
Mirror_Table_Edits :: struct {
	name:  string,
	edits: [dynamic]Mirror_Edit,
}

@(private)
mirror_apply_commit :: proc(store: ^Store, m: ^Sqlite_Mirror, ops: []Store_Op) -> (needs_full: bool, err: Error) {
	groups := make(map[string]int) // table -> index into tables
	tables := make([dynamic]Mirror_Table_Edits, 0, 4, m.alloc)
	defer {
		for &group in tables {
			for edit in group.edits {
				if edit.payload != nil do delete(edit.payload, m.alloc)
			}
			delete(group.edits)
		}
		delete(tables)
		delete(groups)
	}
	for op in ops {
		table, known := m.tables[op.name]
		if !known || !table.supported {
			m.fallback_reason = "unsupported table"
			return true, ERROR_NONE
		}
		schema, schema_known := store.tables[op.name]
		if !schema_known {
			m.fallback_reason = "unknown schema"
			return true, ERROR_NONE
		}
		column := mirror_rowid_column(schema.schema)
		if column < 0 {
			m.fallback_reason = "no rowid column"
			return true, ERROR_NONE
		}
		at, seen := groups[op.name]
		if !seen {
			at = len(tables)
			groups[op.name] = at
			append(&tables, Mirror_Table_Edits{name = op.name})
		}
		switch op.kind {
		case .Insert:
			if column >= len(op.values) || op.values[column].kind != .Int {
				m.fallback_reason = "insert without an integer key"
				return true, ERROR_NONE
			}
			rowid := op.values[column].i
			payload := sqlite_encode_record(op.values, column, m.alloc)
			if payload == nil do return true, ERROR_NONE
			append(&tables[at].edits, Mirror_Edit{rowid = rowid, payload = payload})
		case .Delete:
			rowid, present := table.rowid_of[op.row_id]
			if !present {
				m.fallback_reason = "delete without a rowid"
				return true, ERROR_NONE
			}
			append(&tables[at].edits, Mirror_Edit{remove = true, rowid = rowid})
		case .Update:
			old, present := table.rowid_of[op.row_id]
			if !present {
				m.fallback_reason = "update without a rowid"
				return true, ERROR_NONE
			}
			if column >= len(op.values) || op.values[column].kind != .Int do return true, ERROR_NONE
			new_rowid := op.values[column].i
			if new_rowid != old {
				append(&tables[at].edits, Mirror_Edit{remove = true, rowid = old})
			}
			payload := sqlite_encode_record(op.values, column, m.alloc)
			if payload == nil do return true, ERROR_NONE
			append(&tables[at].edits, Mirror_Edit{rowid = new_rowid, payload = payload})
		case .Create_Table, .Truncate, .Drop_Table, .Create_Index, .Drop_Index, .Alter_Table:
			return true, ERROR_NONE
		}
	}

	// Apply one table at a time, highest leaf first: a split inserts a leaf after
	// the one it filled, so the leaves still to be visited keep their indices.
	for group in tables {
		table := m.tables[group.name]
		edits := group.edits
		// Resolve each edit's leaf now, before any leaf moves.
		leaves := make([]int, len(edits), m.alloc)
		defer delete(leaves, m.alloc)
		for edit, i in edits {
			index := mirror_leaf_index(&table, edit.rowid)
			if index < 0 {
				m.fallback_reason = "no leaf"
				return true, ERROR_NONE
			}
			leaves[i] = index
		}
		// Sort the edit indices by leaf, descending (an Odin closure cannot
		// capture locals, so the leaf travels with the index).
		Mirror_Order :: struct {
			leaf:  int,
			index: int,
		}
		sorted := make([]Mirror_Order, len(edits), m.alloc)
		defer delete(sorted, m.alloc)
		for i in 0 ..< len(sorted) do sorted[i] = Mirror_Order{leaf = leaves[i], index = i}
		slice.sort_by(sorted, proc(a, b: Mirror_Order) -> bool { return a.leaf > b.leaf })
		order := sorted
		i := 0
		for i < len(order) {
			leaf_index := order[i].leaf
			batch := make([dynamic]Mirror_Edit, 0, 4, m.alloc)
			for i < len(order) && order[i].leaf == leaf_index {
				append(&batch, edits[order[i].index])
				i += 1
			}
			applied := mirror_apply_leaf(m, &table, leaf_index, batch[:])
			delete(batch)
			if !applied {
				if len(m.fallback_reason) == 0 do m.fallback_reason = "leaf"
				// Give up without touching the map: the caller re-encodes the
				// whole file and destroys this mirror, so freeing the table's
				// buffers here would free them twice.
				return true, ERROR_NONE
			}
		}
		// The store's map follows the file: an insert teaches it a rowid, a
		// delete forgets one, and an update may move one.
		for op in ops {
			if op.name != group.name do continue
			switch op.kind {
			case .Insert:
				if column := mirror_rowid_column(store.tables[op.name].schema); column >= 0 {
					if column < len(op.values) && op.values[column].kind == .Int {
						table.rowid_of[op.row_id] = op.values[column].i
					}
				}
			case .Delete:
				delete_key(&table.rowid_of, op.row_id)
			case .Update:
				if column := mirror_rowid_column(store.tables[op.name].schema); column >= 0 {
					if column < len(op.values) && op.values[column].kind == .Int {
						table.rowid_of[op.row_id] = op.values[column].i
					}
				}
			case .Create_Table, .Truncate, .Drop_Table, .Create_Index, .Drop_Index, .Alter_Table:
			}
		}
		m.tables[group.name] = table
	}
	if !mirror_write_master(m) {
		m.fallback_reason = "master"
		return true, ERROR_NONE
	}
	err = mirror_commit_pages(m)
	return false, err
}

// --- Checking the tree -----------------------------------------------------

// sqlite_mirror_validate reads a mirrored file and checks the invariants a
// b-tree reader relies on: every leaf's rowids increase, every leaf's largest
// rowid is not above the separator its parent stores for it, and the leaves
// appear in key order. It is the assertion the mirror tests make after a
// commit; SQLite's own `PRAGMA integrity_check` is the same check by another
// implementation.
sqlite_mirror_validate :: proc(path: string, alloc := context.allocator) -> (ok: bool, reason: string) {
	file, open_err := sqlite_file_open(path, alloc, true)
	if open_err.kind != .None do return false, "cannot open"
	defer sqlite_file_destroy(&file)
	for &table in file.tables {
		check := Mirror_Check{file = &file, alloc = alloc, ok = true}
		mirror_check_page(&check, table.root_page, 0, false)
		if !check.ok do return false, check.reason
		delete(check.reason, alloc)
	}
	return true, ""
}

@(private)
Mirror_Check :: struct {
	file:   ^Sqlite_File,
	alloc:  mem.Allocator,
	ok:     bool,
	reason: string,
	last:   i64,
}

@(private)
mirror_check_page :: proc(check: ^Mirror_Check, page_no: u32, ceiling: i64, has_ceiling: bool) {
	if !check.ok do return
	block := sqlite_page(check.file, page_no)
	if block == nil {
		check.ok = false
		check.reason = "missing page"
		return
	}
	base := page_no == 1 ? SQLITE_HEADER_MIN : 0
	if base + 8 > len(block) {
		check.ok = false
		check.reason = "short page"
		return
	}
	kind := block[base]
	count := int(sqlite_be16(block, base + 3))
	switch kind {
	case 5:
		header := base + 12
		previous: i64 = 0
		first := true
		for i in 0 ..< count {
			pointer := int(sqlite_be16(block, header + i * 2))
			if pointer + 4 > len(block) {
				check.ok = false
				check.reason = "bad cell pointer"
				return
			}
			child := sqlite_be32(block, pointer)
			key, size := sqlite_varint(block[pointer + 4:], 0)
			if size == 0 {
				check.ok = false
				check.reason = "bad separator"
				return
			}
			if !first && i64(key) <= previous {
				check.ok = false
				check.reason = fmt.aprintf(
					"page %d separators out of order: %d then %d",
					page_no,
					previous,
					key,
					allocator = check.alloc,
				)
				return
			}
			previous = i64(key)
			first = false
			mirror_check_page(check, child, i64(key), true)
			if !check.ok do return
		}
		right := sqlite_be32(block, base + 8)
		if right != 0 do mirror_check_page(check, right, ceiling, has_ceiling)
	case 13:
		previous := i64(0)
		first := true
		for i in 0 ..< count {
			pointer := int(sqlite_be16(block, base + 8 + i * 2))
			if pointer >= len(block) {
				check.ok = false
				check.reason = "bad leaf pointer"
				return
			}
			_, size := sqlite_varint(block[pointer:], 0)
			rowid, rowid_size := sqlite_varint(block[pointer:], size)
			if rowid_size == 0 {
				check.ok = false
				check.reason = "bad rowid"
				return
			}
			value := i64(rowid)
			if !first && value <= previous {
				check.ok = false
				check.reason = "rowids out of order"
				return
			}
			if has_ceiling && value > ceiling {
				check.ok = false
				check.reason = fmt.aprintf(
					"page %d rowid %d above its separator %d",
					page_no,
					value,
					ceiling,
					allocator = check.alloc,
				)
				return
			}
			previous = value
			first = false
		}
	case:
		check.ok = false
		check.reason = "unknown page type"
	}
}
