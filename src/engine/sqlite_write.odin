package engine

// SQLite database-file writer.
//
// `sqlite_file_write` turns the store into a real SQLite database: a 100-byte
// header, a sqlite_master table at page 1, one table b-tree per table (leaf
// pages plus interior levels when the table does not fit in one page) and
// overflow chains for long records. Readers such as the SQLite shell, Python's
// sqlite3 or the course testers can then open the result.
//
// The writer is intentionally simple: it emits a freshly packed database (no
// freelist, no journal, no WAL) using the default 4096-byte page size.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

SQLITE_WRITE_PAGE_SIZE :: 4096

// sqlite_image_page_count is the page count a database image's header records
// (bytes 28 to 31), whatever its page size.
sqlite_image_page_count :: proc(image: []u8) -> int {
	if len(image) < 32 do return 0
	return int(u32(image[28]) << 24 | u32(image[29]) << 16 | u32(image[30]) << 8 | u32(image[31]))
}

// sqlite_page_size_valid is SQLite's rule: a power of two from 512 to 65536.
sqlite_page_size_valid :: proc(size: int) -> bool {
	return size >= 512 && size <= 65536 && size & (size - 1) == 0
}

// store_sqlite_page_size is the page size the store's SQLite form uses: the one
// the file it was read from had, or the one a VACUUM set (kept as a header
// integer, so it is logged and travels with the transaction), else 4096.
store_sqlite_page_size :: proc(store: ^Store) -> int {
	size := int(store_header_value(store, "page_size"))
	return sqlite_page_size_valid(size) ? size : SQLITE_WRITE_PAGE_SIZE
}

@(private)
Sqlite_Writer :: struct {
	pages:     [dynamic][]u8,
	page_size: int,
	usable:    int,
}

@(private)
sqlite_writer_destroy :: proc(w: ^Sqlite_Writer) {
	for page in w.pages do delete(page)
	delete(w.pages)
	w^ = {}
}

@(private)
sqlite_writer_new_page :: proc(w: ^Sqlite_Writer) -> int {
	page := make([]u8, w.page_size)
	append(&w.pages, page)
	return len(w.pages) // 1-based page numbers
}

@(private)
sqlite_writer_page :: proc(w: ^Sqlite_Writer, number: int) -> []u8 {
	return w.pages[number - 1]
}

// --- Serialisation ---------------------------------------------------------

@(private)
sqlite_put_varint :: proc(buffer: ^[dynamic]u8, value: u64) {
	// The last byte of a nine-byte varint carries eight bits.
	if value <= 0x7f {
		append(buffer, u8(value))
		return
	}
	if value > (u64(1) << 56) - 1 {
		// The ninth byte holds the low eight bits and the first eight hold seven
		// each, high bit set. Eight bits in every byte lost the top seven bits of
		// the value: every negative rowid came back as a large positive one, and
		// SQLite found the table out of order.
		bytes: [9]u8
		v := value
		bytes[8] = u8(v & 0xff)
		v >>= 8
		for i := 7; i >= 0; i -= 1 {
			bytes[i] = u8(v & 0x7f) | 0x80
			v >>= 7
		}
		for b in bytes do append(buffer, b)
		return
	}
	groups: [9]u8
	count := 0
	v := value
	for v > 0 {
		groups[count] = u8(v & 0x7f)
		v >>= 7
		count += 1
	}
	for i := count - 1; i >= 0; i -= 1 {
		b := groups[i]
		if i > 0 do b |= 0x80
		append(buffer, b)
	}
}

@(private)
sqlite_put_be32 :: proc(buffer: ^[dynamic]u8, value: u32) {
	append(buffer, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
}

@(private)
sqlite_put_be64 :: proc(buffer: ^[dynamic]u8, value: u64) {
	for shift: i32 = 7; shift >= 0; shift -= 1 do append(buffer, u8(value >> (u32(shift) * 8)))
}

// sqlite_serial_type picks the smallest serial type for a value.
@(private)
sqlite_serial_type :: proc(value: Value) -> (serial: u64, width: int) {
	#partial switch value.kind {
	case .Null:
		return 0, 0
	case .Bool:
		return value.b ? 9 : 8, 0
	case .Int:
		n := value.i
		switch {
		case n == 0:
			return 8, 0
		case n == 1:
			return 9, 0
		case n >= -128 && n <= 127:
			return 1, 1
		case n >= -32768 && n <= 32767:
			return 2, 2
		case n >= -(i64(1) << 23) && n < (i64(1) << 23):
			return 3, 3
		case n >= -(i64(1) << 31) && n < (i64(1) << 31):
			return 4, 4
		case n >= -(i64(1) << 47) && n < (i64(1) << 47):
			return 5, 6
		}
		return 6, 8
	case .Uint:
		if value.u <= u64(max(i64)) {
			return sqlite_serial_type(value_int(i64(value.u)))
		}
		return 7, 8
	case .Float:
		return 7, 8
	case .String:
		return 13 + u64(len(value.s)) * 2, len(value.s)
	case .Bytes:
		return 12 + u64(len(value.bytes)) * 2, len(value.bytes)
	}
	text := value_format(value, context.temp_allocator)
	return 13 + u64(len(text)) * 2, len(text)
}

@(private)
sqlite_write_body :: proc(buffer: ^[dynamic]u8, value: Value, width: int) {
	#partial switch value.kind {
	case .Bool:
		return
	case .Int:
		if width == 0 do return
		bits := u64(value.i)
		if width < 8 {
			for i in 0 ..< width do append(buffer, u8(bits >> (u32(width - 1 - i) * 8)))
			return
		}
		sqlite_put_be64(buffer, bits)
		return
	case .Uint:
		if width == 8 {
			sqlite_put_be64(buffer, value.u)
		}
		return
	case .Float:
		sqlite_put_be64(buffer, transmute(u64)(value.f))
		return
	case .String:
		append(buffer, value.s)
		return
	case .Bytes:
		for b in value.bytes do append(buffer, b)
		return
	case .Null:
		return
	}
	text := value_format(value, context.temp_allocator)
	append(buffer, text)
}

// sqlite_encode_record builds the record payload for one row. The rowid column
// is written as NULL so the cell key stays authoritative, like SQLite does.
sqlite_encode_record :: proc(values: []Value, rowid_column: int, alloc: mem.Allocator) -> []u8 {
	header := make([dynamic]u8, 0, len(values) + 4)
	defer delete(header)
	body := make([dynamic]u8, 0, 32)
	defer delete(body)
	for value, i in values {
		v := value
		if i == rowid_column do v = value_null()
		serial, width := sqlite_serial_type(v)
		sqlite_put_varint(&header, serial)
		sqlite_write_body(&body, v, width)
	}
	// The header length counts itself, so encode until the size is stable.
	header_len := len(header) + 1
	for {
		prefix := make([dynamic]u8, 0, 9)
		sqlite_put_varint(&prefix, u64(header_len))
		actual := len(prefix) + len(header)
		delete(prefix)
		if actual == header_len do break
		header_len = actual
	}
	record := make([dynamic]u8, 0, header_len + len(body))
	defer delete(record)
	sqlite_put_varint(&record, u64(header_len))
	for b in header do append(&record, b)
	for b in body do append(&record, b)
	result := make([]u8, len(record), alloc)
	copy(result, record[:])
	return result
}

// --- Pages -----------------------------------------------------------------

// sqlite_cell_payload splits a payload into the local part plus overflow pages,
// returning the bytes that go inside the cell and the overflow page numbers.
@(private)
sqlite_split_payload :: proc(
	w: ^Sqlite_Writer,
	payload: []u8,
	table_leaf: bool,
	overflow: ^[dynamic]int,
) -> []u8 {
	local := sqlite_local_size(len(payload), w.usable, table_leaf)
	if local >= len(payload) {
		out := make([]u8, len(payload))
		copy(out, payload)
		return out
	}
	// Overflow pages hold 4 bytes of next pointer plus data.
	capacity := w.usable - 4
	remaining := payload[local:]
	previous := -1
	for len(remaining) > 0 {
		page_no := sqlite_writer_new_page(w)
		page := sqlite_writer_page(w, page_no)
		take := min(capacity, len(remaining))
		copy(page[4:4 + take], remaining[:take])
		if previous >= 0 {
			previous_page := sqlite_writer_page(w, previous)
			previous_page[0] = u8(page_no >> 24)
			previous_page[1] = u8(page_no >> 16)
			previous_page[2] = u8(page_no >> 8)
			previous_page[3] = u8(page_no)
		} else {
			append(overflow, page_no)
		}
		previous = page_no
		remaining = remaining[take:]
	}
	// The cell keeps the local part and the first overflow page number.
	out := make([]u8, local + 4)
	copy(out[:local], payload[:local])
	first := u32(overflow[0])
	out[local] = u8(first >> 24)
	out[local + 1] = u8(first >> 16)
	out[local + 2] = u8(first >> 8)
	out[local + 3] = u8(first)
	return out
}

@(private)
Sqlite_Leaf :: struct {
	page:  int,
	max_key: i64,
}

// sqlite_build_tree writes rows into leaf pages and then interior levels,
// returning the root page number.
@(private)
sqlite_build_tree :: proc(
	w: ^Sqlite_Writer,
	cells: [][]u8, // fully formed leaf cells, in key order
	keys: []i64,
	alloc: mem.Allocator,
	// reserve keeps the last N bytes free; the sqlite_master tree reserves the
	// file header so its root can move to page 1.
	reserve := 0,
) -> int {
	if len(cells) == 0 {
		// An empty table is a single empty leaf page whose content starts at the
		// end of the usable area. `reserve` has to be honoured here too: the
		// sqlite_master tree reserves the 100-byte file header so its root can
		// move to page 1, and a page whose content starts at `usable` has no room
		// for that shift — the move then left page 1 without a b-tree header and
		// SQLite called the file malformed.
		content := w.usable - reserve
		page_no := sqlite_writer_new_page(w)
		page := sqlite_writer_page(w, page_no)
		page[0] = 13
		page[5] = u8(content >> 8)
		page[6] = u8(content)
		return page_no
	}
	leaves := make([dynamic]Sqlite_Leaf, 0, 8)
	defer delete(leaves)
	current := sqlite_writer_new_page(w)
	page := sqlite_writer_page(w, current)
	page[0] = 13
	content := w.usable - reserve
	pointer_count := 0
	for cell, i in cells {
		space := content - (8 + (pointer_count + 1) * 2)
		if len(cell) > space && pointer_count > 0 {
			// Close this leaf and start another.
			sqlite_finish_leaf(w, current, pointer_count, content)
			append(&leaves, Sqlite_Leaf{page = current, max_key = keys[i - 1]})
			current = sqlite_writer_new_page(w)
			page = sqlite_writer_page(w, current)
			page[0] = 13
			content = w.usable - reserve
			pointer_count = 0
			space = content - (8 + 2)
		}
		content -= len(cell)
		copy(page[content:content + len(cell)], cell)
		at := 8 + pointer_count * 2
		page[at] = u8(content >> 8)
		page[at + 1] = u8(content)
		pointer_count += 1
	}
	sqlite_finish_leaf(w, current, pointer_count, content)
	append(&leaves, Sqlite_Leaf{page = current, max_key = keys[len(keys) - 1]})

	if len(leaves) == 1 do return leaves[0].page
	// Interior levels: cells are (child page, max key), plus a right-most child.
	level := make([dynamic]Sqlite_Leaf, 0, 8)
	defer delete(level)
	for leaf in leaves do append(&level, leaf)
	for len(level) > 1 {
		next := make([dynamic]Sqlite_Leaf, 0, 8)
		i := 0
		for i < len(level) {
			page_no := sqlite_writer_new_page(w)
			interior := sqlite_writer_page(w, page_no)
			interior[0] = 5
			content = w.usable - reserve
			count := 0
			start := i
			// Keep at least one child for the right-most pointer.
			for i + 1 < len(level) {
				cell_size := 4 + varint_size(level[i].max_key)
				space := content - (12 + (count + 1) * 2)
				if cell_size > space && count > 0 do break
				content -= cell_size
				at := content
				child := u32(level[i].page)
				interior[at] = u8(child >> 24)
				interior[at + 1] = u8(child >> 16)
				interior[at + 2] = u8(child >> 8)
				interior[at + 3] = u8(child)
				key_buffer := make([dynamic]u8, 0, 9)
				sqlite_put_varint(&key_buffer, u64(level[i].max_key))
				copy(interior[at + 4:at + 4 + len(key_buffer)], key_buffer[:])
				delete(key_buffer)
				pointer_at := 12 + count * 2
				interior[pointer_at] = u8(at >> 8)
				interior[pointer_at + 1] = u8(at)
				count += 1
				i += 1
			}
			right := u32(level[i].page)
			interior[8] = u8(right >> 24)
			interior[9] = u8(right >> 16)
			interior[10] = u8(right >> 8)
			interior[11] = u8(right)
			i += 1
			interior[3] = u8(count >> 8)
			interior[4] = u8(count)
			interior[5] = u8(content >> 8)
			interior[6] = u8(content)
			append(&next, Sqlite_Leaf{page = page_no, max_key = level[i - 1].max_key})
			_ = start
		}
		// Ownership passes to `level`: free the old buffer, then adopt `next`
		// (a deferred delete here would free the same buffer twice).
		delete(level)
		level = next
	}
	return level[0].page
}

@(private)
sqlite_finish_leaf :: proc(w: ^Sqlite_Writer, page_no: int, count: int, content: int) {
	page := sqlite_writer_page(w, page_no)
	page[0] = 13
	page[3] = u8(count >> 8)
	page[4] = u8(count)
	page[5] = u8(content >> 8)
	page[6] = u8(content)
}

@(private)
varint_size :: proc(value: i64) -> int {
	v := u64(value)
	if v <= 0x7f do return 1
	if v > (u64(1) << 56) - 1 do return 9
	count := 0
	for v > 0 {
		v >>= 7
		count += 1
	}
	return count
}

// sqlite_leaf_cell builds one table-leaf cell: payload length, rowid, payload.
@(private)
sqlite_leaf_cell :: proc(w: ^Sqlite_Writer, payload: []u8, rowid: i64) -> []u8 {
	overflow := make([dynamic]int, 0, 4)
	defer delete(overflow)
	body := sqlite_split_payload(w, payload, true, &overflow)
	cell := make([dynamic]u8, 0, len(body) + 9)
	defer delete(cell)
	sqlite_put_varint(&cell, u64(len(payload)))
	sqlite_put_varint(&cell, u64(rowid))
	for b in body do append(&cell, b)
	delete(body)
	result := make([]u8, len(cell))
	copy(result, cell[:])
	return result
}


// sqlite_index_cell builds an index-leaf cell: the payload length and the
// payload (key columns plus the rowid), with the index overflow rules.
@(private)
sqlite_index_cell :: proc(w: ^Sqlite_Writer, payload: []u8) -> []u8 {
	overflow := make([dynamic]int, 0, 4)
	defer delete(overflow)
	body := sqlite_split_payload(w, payload, false, &overflow)
	cell := make([dynamic]u8, 0, len(body) + 9)
	defer delete(cell)
	sqlite_put_varint(&cell, u64(len(payload)))
	for b in body do append(&cell, b)
	delete(body)
	result := make([]u8, len(cell))
	copy(result, cell[:])
	return result
}

// sqlite_write_index_tree writes one index as a b-tree (sqlite_index_btree).
@(private)
sqlite_write_index_tree :: proc(
	w: ^Sqlite_Writer,
	table: ^Table,
	index: Index_Schema,
	rows: []Sqlite_Export_Row,
	alloc: mem.Allocator,
	store: ^Store = nil,
	text := "",
) -> int {
	if len(index.columns) == 0 do return 0
	// A partial index holds only its rows, and an expression index the values of
	// its expressions over the file's own values, which is what SQLite checks.
	position, has_position := table_index_position(table, index.name)
	plain := index_is_plain(index) || !has_position
	// What follows the indexed values in each entry: the rowid, or for a
	// WITHOUT ROWID table the primary key's columns the index does not hold.
	suffix := make([dynamic]int, 0, 4, alloc)
	defer delete(suffix)
	if table.schema.without_rowid {
		for column in table.schema.primary_key {
			if !plain || !slice.contains(index.columns[:], column) do append(&suffix, column)
		}
	}
	width := len(index.columns) + (table.schema.without_rowid ? len(suffix) : 1)
	keys := make([dynamic][]Value, 0, len(rows), alloc)
	// A plain key borrows the row's values; an expression's are its own. In an
	// index that mixes them (`b COLLATE rtrim, a`) only the expressions' are:
	// freeing the column's was a double free.
	defer {
		for key in keys {
			if !plain {
				for value, part in key[:len(index.columns)] {
					if part < len(index.exprs) && len(index.exprs[part]) > 0 do value_deep_free(value, alloc)
				}
			}
			delete(key, alloc)
		}
		delete(keys)
	}
	for row in rows {
		if !plain && !index_row_included(table, position, row.values) do continue
		values := make([]Value, width, alloc)
		if plain {
			for column, part in index.columns {
				if column >= 0 && column < len(row.values) do values[part] = row.values[column]
			}
		} else {
			parts := index_part_values(table, position, row.values, alloc)
			copy(values, parts)
			delete(parts, alloc)
		}
		if table.schema.without_rowid {
			for column, k in suffix {
				if column < len(row.values) do values[len(index.columns) + k] = row.values[column]
			}
		} else {
			values[len(index.columns)] = value_int(row.rowid)
		}
		append(&keys, values)
	}
	// The entries go in the index's own order: a DESC part backwards, and a
	// text by its collation (the part's COLLATE, else its column's), or
	// SQLite's integrity check finds the rows missing from the index.
	order := Sqlite_Index_Order{store = store}
	order.desc, order.collations = sqlite_index_part_order(text, len(index.columns), context.temp_allocator)
	for column, part in index.columns {
		if len(order.collations[part]) == 0 && column >= 0 && column < len(table.schema.columns) {
			order.collations[part] = table.schema.columns[column].collation
		}
	}
	context.user_ptr = &order
	slice.sort_by(keys[:], proc(a, b: []Value) -> bool {
		return sqlite_entry_compare(a, b, (^Sqlite_Index_Order)(context.user_ptr)) < 0
	})

	payloads := make([][]u8, len(keys), alloc)
	defer {
		for payload in payloads do delete(payload, alloc)
		delete(payloads, alloc)
	}
	for values, i in keys do payloads[i] = sqlite_encode_record(values, -1, alloc)
	return sqlite_index_btree(w, payloads, alloc)
}

// Sqlite_Index_Order is how one index orders its entries: per key part,
// backwards or not and the collation of a text.
@(private)
Sqlite_Index_Order :: struct {
	store:      ^Store,
	desc:       []bool,
	collations: []string,
}

// sqlite_entry_compare orders two index entries value by value, in SQLite's
// order of storage classes, with each key part's direction and collation.
@(private)
sqlite_entry_compare :: proc(a, b: []Value, order: ^Sqlite_Index_Order) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		result := 0
		collation := i < len(order.collations) ? order.collations[i] : ""
		if a[i].kind == .String && b[i].kind == .String && len(collation) > 0 && !strings.equal_fold(collation, "binary") {
			if compared, known := collation_compare(order.store, collation, a[i].s, b[i].s); known do result = compared
		} else if compared, ok := value_compare(a[i], b[i]); ok {
			result = compared == .Less ? -1 : (compared == .Greater ? 1 : 0)
		}
		if result == 0 do continue
		if i < len(order.desc) && order.desc[i] do result = -result
		return result
	}
	return len(a) < len(b) ? -1 : (len(a) > len(b) ? 1 : 0)
}

// sqlite_index_part_order reads each key part's DESC and COLLATE from a
// CREATE INDEX text; without a text every part is ascending, with no
// collation of its own.
@(private)
sqlite_index_part_order :: proc(text: string, parts: int, alloc: mem.Allocator) -> (desc: []bool, collations: []string) {
	desc = make([]bool, parts, alloc)
	collations = make([]string, parts, alloc)
	if len(text) == 0 do return
	tokens := sql_text_tokens(text)
	// The key list is the first parenthesis after ON.
	at := 0
	for at < len(tokens) && !strings.equal_fold(tokens[at].text, "on") do at += 1
	for at < len(tokens) && tokens[at].text != "(" do at += 1
	if at >= len(tokens) do return
	at += 1
	part, depth := 0, 0
	previous := ""
	for ; at < len(tokens) && part < parts; at += 1 {
		token := tokens[at].text
		switch {
		case token == "(":
			depth += 1
		case token == ")" && depth == 0:
			return
		case token == ")":
			depth -= 1
		case token == "," && depth == 0:
			part += 1
		case depth == 0 && strings.equal_fold(token, "desc"):
			desc[part] = true
		case depth == 0 && strings.equal_fold(previous, "collate"):
			collations[part] = strings.trim(token, "\"'`[]")
		}
		previous = token
	}
	return
}

// sqlite_entry_less orders index entries value by value, in SQLite's order of
// storage classes.
@(private)
sqlite_entry_less :: proc(a, b: []Value) -> bool {
	for i in 0 ..< min(len(a), len(b)) {
		order, ok := value_compare(a[i], b[i])
		if ok && order != .Equal do return order == .Less
	}
	return len(a) < len(b)
}

// sqlite_write_without_rowid writes a WITHOUT ROWID table as SQLite stores
// it: an index b-tree whose entries are the primary key's columns, then the
// other columns in declaration order, sorted by the key.
@(private)
sqlite_write_without_rowid :: proc(w: ^Sqlite_Writer, table: ^Table, rows: []Sqlite_Export_Row, alloc: mem.Allocator) -> int {
	order := make([dynamic]int, 0, len(table.schema.columns), alloc)
	defer delete(order)
	for column in table.schema.primary_key do append(&order, column)
	for _, column in table.schema.columns {
		if !slice.contains(table.schema.primary_key[:], column) do append(&order, column)
	}
	entries := make([][]Value, len(rows), alloc)
	defer {
		for entry in entries do delete(entry, alloc)
		delete(entries, alloc)
	}
	for row, i in rows {
		entry := make([]Value, len(order), alloc)
		for column, k in order {
			if column < len(row.values) do entry[k] = row.values[column]
		}
		entries[i] = entry
	}
	slice.sort_by(entries, sqlite_entry_less)
	payloads := make([][]u8, len(entries), alloc)
	defer {
		for payload in payloads do delete(payload, alloc)
		delete(payloads, alloc)
	}
	for entry, i in entries do payloads[i] = sqlite_encode_record(entry, -1, alloc)
	return sqlite_index_btree(w, payloads, alloc)
}

// sqlite_index_btree writes sorted index records as a b-tree: leaf pages of
// type 10 and interior pages of type 2. Every entry is stored once: the entry
// where a page ends is not on any leaf, it is the interior cell that separates
// that page from the next one, as in SQLite's own index b-trees.
@(private)
sqlite_index_btree :: proc(w: ^Sqlite_Writer, payloads: [][]u8, alloc: mem.Allocator) -> int {
	if len(payloads) == 0 {
		// A b-tree over no entries is one empty leaf, as SQLite writes it (the
		// file used to lose the index of an empty table).
		page_no := sqlite_writer_new_page(w)
		page := sqlite_writer_page(w, page_no)
		page[0] = 10
		page[5], page[6] = u8(w.usable >> 8), u8(w.usable)
		return page_no
	}
	cell_size := proc(w: ^Sqlite_Writer, payload: []u8) -> int {
		local := sqlite_local_size(len(payload), w.usable, false)
		return varint_size(i64(len(payload))) + local + (local < len(payload) ? 4 : 0)
	}
	// The level being written: its entries, and for an interior level the page
	// left of each entry plus the one after the last.
	entries := make([dynamic][]u8, 0, len(payloads), alloc)
	defer delete(entries)
	for payload in payloads do append(&entries, payload)
	children := make([dynamic]int, 0, 8, alloc)
	defer delete(children)
	leaf := true
	for {
		sizes := make([]int, len(entries), alloc)
		defer delete(sizes, alloc)
		for entry, i in entries do sizes[i] = cell_size(w, entry) + (leaf ? 0 : 4)
		room := w.usable - (leaf ? 8 : 12)
		groups, separators := sqlite_index_split(sizes, room, alloc)
		defer {
			for group in groups do delete(group)
			delete(groups)
			delete(separators)
		}
		pages := make([dynamic]int, 0, len(groups), alloc)
		for group in groups {
			page_no := sqlite_writer_new_page(w)
			content := w.usable
			for item, k in group {
				cell := sqlite_index_cell(w, entries[item])
				defer delete(cell)
				page := sqlite_writer_page(w, page_no)
				if leaf {
					content -= len(cell)
					copy(page[content:], cell)
				} else {
					content -= len(cell) + 4
					child := u32(children[item])
					page[content], page[content + 1], page[content + 2], page[content + 3] =
						u8(child >> 24), u8(child >> 16), u8(child >> 8), u8(child)
					copy(page[content + 4:], cell)
				}
				at := (leaf ? 8 : 12) + k * 2
				page[at], page[at + 1] = u8(content >> 8), u8(content)
			}
			page := sqlite_writer_page(w, page_no)
			page[0] = leaf ? 10 : 2
			page[3], page[4] = u8(len(group) >> 8), u8(len(group))
			page[5], page[6] = u8(content >> 8), u8(content)
			if !leaf {
				right := u32(children[group[len(group) - 1] + 1])
				page[8], page[9], page[10], page[11] = u8(right >> 24), u8(right >> 16), u8(right >> 8), u8(right)
			}
			append(&pages, page_no)
		}
		if len(separators) == 0 {
			root := pages[0]
			delete(pages)
			return root
		}
		next := make([dynamic][]u8, 0, len(separators), alloc)
		for item in separators do append(&next, entries[item])
		delete(entries)
		entries = next
		delete(children)
		children = pages
		leaf = false
	}
}

// sqlite_index_split cuts a level's entries into pages of `room` bytes (a
// cell plus its 2-byte pointer each). The entry at a cut goes to no page: it
// separates the two pages in the level above. The last entry never separates,
// since no page would follow it; the one before it does instead.
@(private)
sqlite_index_split :: proc(sizes: []int, room: int, alloc: mem.Allocator) -> (groups: [dynamic][dynamic]int, separators: [dynamic]int) {
	groups = make([dynamic][dynamic]int, 0, 8, alloc)
	separators = make([dynamic]int, 0, 8, alloc)
	current := make([dynamic]int, 0, 16, alloc)
	used := 0
	for i := 0; i < len(sizes); i += 1 {
		cost := sizes[i] + 2
		if len(current) > 0 && used + cost > room {
			if i == len(sizes) - 1 && len(current) > 1 {
				last := pop(&current)
				append(&groups, current)
				append(&separators, last)
				current = make([dynamic]int, 0, 16, alloc)
				append(&current, i)
				used = cost
				continue
			}
			if i < len(sizes) - 1 {
				append(&groups, current)
				append(&separators, i)
				current = make([dynamic]int, 0, 16, alloc)
				used = 0
				continue
			}
		}
		append(&current, i)
		used += cost
	}
	append(&groups, current)
	return groups, separators
}

// sqlite_is_table_key answers whether an index is a WITHOUT ROWID table's
// primary key, which SQLite keeps as the table's own b-tree.
@(private)
sqlite_is_table_key :: proc(table: ^Table, index: ^Index_Schema) -> bool {
	return table.schema.without_rowid && index.implicit && index.unique &&
		schema_index_matches(index, table.schema.primary_key)
}

@(private)
sqlite_index_by_name :: proc(schema: ^Table_Schema, name: string) -> (Index_Schema, bool) {
	for index in schema.indexes {
		if index.name == name do return index, true
	}
	return {}, false
}

@(private)
sqlite_name_in :: proc(names: []string, name: string) -> bool {
	for other in names {
		if other == name do return true
	}
	return false
}

// sqlite_index_sql renders the CREATE INDEX statement stored in sqlite_master.
@(private)
sqlite_index_sql :: proc(table: ^Table, index: Index_Schema) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, index.unique ? "CREATE UNIQUE INDEX " : "CREATE INDEX ")
	sqlite_write_ident(&builder, index.name)
	strings.write_string(&builder, " ON ")
	sqlite_write_ident(&builder, table.schema.name)
	strings.write_string(&builder, " (")
	for position, i in index.columns {
		if i > 0 do strings.write_string(&builder, ", ")
		if i < len(index.exprs) && len(index.exprs[i]) > 0 {
			strings.write_string(&builder, index.exprs[i])
		} else if position >= 0 && position < len(table.schema.columns) {
			sqlite_write_ident(&builder, table.schema.columns[position].name)
		}
	}
	strings.write_byte(&builder, ')')
	if len(index.where_sql) > 0 {
		strings.write_string(&builder, " WHERE ")
		strings.write_string(&builder, index.where_sql)
	}
	return strings.to_string(builder)
}

// --- Database --------------------------------------------------------------

// sqlite_rowid_alias is the column SQLite stores as the table's rowid, and only
// that one: a single INTEGER primary key. SQLite needs no index for it, because
// the row's own key is the index.
@(private)
sqlite_rowid_alias :: proc(table: ^Table) -> int {
	if table.schema.without_rowid do return -1
	if len(table.schema.primary_key) != 1 do return -1
	position := table.schema.primary_key[0]
	if position < 0 || position >= len(table.schema.columns) do return -1
	if table.schema.columns[position].type.kind != .Int do return -1
	return position
}

@(private)
sqlite_column_is_key :: proc(schema: ^Table_Schema, position: int) -> bool {
	for key in schema.primary_key {
		if key == position do return true
	}
	return false
}

@(private)
sqlite_master_sql :: proc(table: ^Table, store: ^Store = nil) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "CREATE TABLE ")
	sqlite_write_ident(&builder, table.schema.name)
	strings.write_string(&builder, " (")
	// An AUTOINCREMENT key is spelled inline, the only place SQLite accepts it.
	counted := table.schema.auto_increment_column
	if counted >= 0 && sqlite_rowid_alias(table) != counted do counted = -1
	for column, i in table.schema.columns {
		if i > 0 do strings.write_string(&builder, ", ")
		sqlite_write_ident(&builder, column.name)
		strings.write_byte(&builder, ' ')
		strings.write_string(&builder, sqlite_type_name(column.type))
		if i == counted {
			strings.write_string(&builder, " PRIMARY KEY AUTOINCREMENT")
			continue
		}
		// A key column is never NULL in this engine, and the exported table has
		// to keep saying so: the PRIMARY KEY clause is written only for the rowid
		// alias, and SQLite would let a NULL into a text key.
		if column.not_null || sqlite_column_is_key(&table.schema, i) {
			strings.write_string(&builder, " NOT NULL")
		}
		// A constant default is written as its literal, for the kinds SQLite
		// spells the same way; a per-row one is SQL text SQLite evaluates alike.
		if column.has_default && len(column.default_sql) == 0 {
			#partial switch column.default_value.kind {
			case .Int, .Uint, .Float, .String:
				literal := value_sql_literal(column.default_value)
				strings.write_string(&builder, " DEFAULT ")
				strings.write_string(&builder, literal)
				if column.default_value.kind == .String do delete(literal)
			}
		}
		if len(column.default_sql) > 0 {
			strings.write_string(&builder, " DEFAULT (")
			strings.write_string(&builder, column.default_sql)
			strings.write_byte(&builder, ')')
		}
	}
	// The key is declared inline, as SQLite declares it, and its index is written
	// as the automatic index a declaration implies (see the index loop). A text
	// or composite key needs that index; without it SQLite reports the file as
	// malformed (D33). A `UNIQUE` column is not declared here, because it would
	// ask for an automatic index of its own; it travels as a named index instead.
	if len(table.schema.primary_key) > 0 && counted < 0 {
		strings.write_string(&builder, ", PRIMARY KEY (")
		for position, i in table.schema.primary_key {
			if i > 0 do strings.write_string(&builder, ", ")
			sqlite_write_ident(&builder, table.schema.columns[position].name)
		}
		strings.write_byte(&builder, ')')
	}
	// The foreign keys, as REFERENCES SQLite enforces once they are on.
	for key in table.schema.foreign_keys {
		strings.write_string(&builder, ", FOREIGN KEY (")
		for position, i in key.columns {
			if i > 0 do strings.write_string(&builder, ", ")
			sqlite_write_ident(&builder, table.schema.columns[position].name)
		}
		strings.write_string(&builder, ") REFERENCES ")
		sqlite_write_ident(&builder, key.ref_table)
		// The parent's column names, when the parent can be read.
		if parent, found := store_parent_table(store, key.ref_table); found {
			strings.write_string(&builder, " (")
			for position, i in key.ref_columns {
				if i > 0 do strings.write_string(&builder, ", ")
				if position >= 0 && position < len(parent.schema.columns) do sqlite_write_ident(&builder, parent.schema.columns[position].name)
			}
			strings.write_byte(&builder, ')')
		}
		if key.on_delete == .Cascade do strings.write_string(&builder, " ON DELETE CASCADE")
		if key.on_update == .Cascade do strings.write_string(&builder, " ON UPDATE CASCADE")
		if key.deferred do strings.write_string(&builder, " DEFERRABLE INITIALLY DEFERRED")
	}
	// CHECK constraints travel as written, so SQLite keeps enforcing them.
	for check in table.schema.checks {
		strings.write_string(&builder, ", ")
		if len(check.name) > 0 {
			strings.write_string(&builder, "CONSTRAINT ")
			sqlite_write_ident(&builder, check.name)
			strings.write_byte(&builder, ' ')
		}
		strings.write_string(&builder, "CHECK (")
		strings.write_string(&builder, check.sql)
		strings.write_byte(&builder, ')')
	}
	strings.write_string(&builder, ")")
	if table.schema.without_rowid do strings.write_string(&builder, " WITHOUT ROWID")
	return strings.to_string(builder)
}

// store_parent_table is a foreign key's parent, as committed.
@(private)
store_parent_table :: proc(store: ^Store, name: string) -> (^Table, bool) {
	if store == nil do return nil, false
	if table, found := store.tables[name]; found do return table, true
	for key, table in store.tables {
		if strings.equal_fold(key, name) do return table, true
	}
	return nil, false
}

@(private)
sqlite_type_name :: proc(t: Column_Type) -> string {
	#partial switch t.kind {
	case .Int, .Uint, .Bool:
		return "INTEGER"
	case .Float:
		return "REAL"
	case .String:
		return "TEXT"
	case .Bytes:
		return "BLOB"
	case .Timestamp:
		return "TEXT"
	case .Uuid:
		return "TEXT"
	case .Any:
		// An ANY column keeps any value: BLOB is SQLite's name for no affinity,
		// and NUMERIC the one an affinity column was declared with.
		return t.width == SQLITE_NUMERIC_WIDTH ? "NUMERIC" : "BLOB"
	case:
		return "TEXT"
	}
}

@(private)
Sqlite_Export_Row :: struct {
	rowid:  i64,
	values: []Value,
}

// sqlite_file_write exports every persistent user table to a SQLite database.
sqlite_file_write :: proc(store: ^Store, path: string, alloc := context.allocator) -> (tables: int, rows: int, err: Error) {
	image: []u8
	image, tables, rows, err = sqlite_file_image(store, alloc)
	if err.kind != .None do return
	defer delete(image)
	// The change counter goes on from the file being replaced: a connection in
	// another process notices a commit by the counter moving, and a rewrite
	// that started it over at 1 could land on the value it last saw.
	if previous, previous_ok := sqlite_file_change_counter(path); previous_ok && len(image) >= 96 {
		next := previous + 1
		for k in 0 ..< 4 {
			image[24 + k] = u8(next >> uint(24 - 8 * k))
			image[92 + k] = u8(next >> uint(24 - 8 * k))
		}
	}
	if write_err := os.write_entire_file(path, image); write_err != nil {
		return tables, rows, errf(.Io, "cannot write %s: %v", path, write_err)
	}
	return tables, rows, ERROR_NONE
}

// sqlite_file_change_counter reads the file change counter at offset 24 of a
// SQLite file's header.
sqlite_file_change_counter :: proc(path: string) -> (counter: u32, ok: bool) {
	file, open_err := os.open(path, {.Read})
	if open_err != nil do return 0, false
	defer os.close(file)
	header: [28]u8
	got, read_err := os.read(file, header[:])
	if read_err != nil || got < 28 || string(header[:16]) != SQLITE_MAGIC do return 0, false
	return u32(header[24]) << 24 | u32(header[25]) << 16 | u32(header[26]) << 8 | u32(header[27]), true
}

// sqlite_file_image builds the SQLite database image of the store, the bytes
// a file would hold. The caller owns them.
sqlite_file_image :: proc(store: ^Store, alloc := context.allocator) -> (image: []u8, tables: int, rows: int, err: Error) {
	page_size := store_sqlite_page_size(store)
	w := Sqlite_Writer {
		page_size = page_size,
		usable    = page_size,
	}
	defer sqlite_writer_destroy(&w)
	// Page 1 is reserved for sqlite_master even though its content is written last.
	sqlite_writer_new_page(&w)

	freelist_trunk := 0
	names := make([dynamic]string, 0, len(store.tables))
	defer delete(names)
	for name, table in store.tables {
		if strings.has_prefix(name, "_") do continue
		if table.schema.ephemeral do continue
		append(&names, name)
	}
	slice.sort_by(names[:], proc(a, b: string) -> bool { return a < b })

	// What the last rewrite had to rebuild is reported, not hidden: a caller can
	// ask a Store what its file lost (D27).
	for loss in store.mirror_losses do delete(loss)
	clear(&store.mirror_losses)
	// The texts the objects were created with (sqlite_text.odin).
	texts := store_sql_texts(store, context.temp_allocator)
	root_pages := make([dynamic]int, 0, len(names))
	defer delete(root_pages)
	master_rows := make([dynamic]Sqlite_Export_Row, 0, len(names))
	// Each row's array is `alloc`'s; the texts the rows own are listed in
	// `owned`, the rest (names) are borrowed from the schemas.
	owned := make([dynamic]string)
	defer {
		for row in master_rows do delete(row.values, alloc)
		delete(master_rows)
		for text in owned do delete(text)
		delete(owned)
	}
	for name in names {
		table := store.tables[name]
		// Reading through the collect makes a paged table export the same as a
		// memory one; the decoded values are released after the records encode.
		collected := make([dynamic]Row)
		table_collect(table, &collected, max(u64))
		defer table_collect_release(table, &collected)
		exported := make([dynamic]Sqlite_Export_Row, 0, len(collected))
		// The copies of the rows' values serve the table's cells and then its
		// indexes (sqlite_write_index_tree reads them): they go with the table.
		defer {
			for row in exported do delete(row.values, alloc)
			delete(exported)
		}
		rowid_column := sqlite_rowid_alias(table)
		next_rowid := i64(1)
		for row in collected {
			if len(row.values) == 0 do continue
			rowid := next_rowid
			if rowid_column >= 0 && rowid_column < len(row.values) {
				if row.values[rowid_column].kind == .Int do rowid = row.values[rowid_column].i
			}
			values := make([]Value, len(row.values), alloc)
			copy(values, row.values)
			append(&exported, Sqlite_Export_Row{rowid = rowid, values = values})
			next_rowid = max(next_rowid + 1, rowid + 1)
		}
		sort_export_rows(exported[:])
		root: int
		if table.schema.without_rowid {
			root = sqlite_write_without_rowid(&w, table, exported[:], alloc)
			rows += len(exported)
		} else {
			cells := make([][]u8, len(exported), alloc)
			keys := make([]i64, len(exported), alloc)
			for row, i in exported {
				payload := sqlite_encode_record(row.values, rowid_column, alloc)
				cells[i] = sqlite_leaf_cell(&w, payload, row.rowid)
				delete(payload, alloc)
				keys[i] = row.rowid
				rows += 1
			}
			root = sqlite_build_tree(&w, cells, keys, alloc)
			for cell in cells do delete(cell)
			delete(cells, alloc)
			delete(keys, alloc)
		}
		append(&root_pages, root)
		master := make([]Value, 5, alloc)
		master[0] = value_string("table")
		master[1] = value_string(table.schema.name)
		master[2] = value_string(table.schema.name)
		master[3] = value_int(i64(root))
		// An object the engine did not change keeps the text the file had, so a
		// rewrite no longer drops the rules the model cannot hold (D27).
		table_sql, original, keep_text := sqlite_table_sql(store, table, texts)
		append(&owned, table_sql)
		master[4] = value_string(table_sql)
		if !keep_text {
			if imported, was_imported := store_mirror_kept_lookup(store, table.schema.name); was_imported && imported.has_rules {
				loss := fmt.aprintf(
					"%s was rebuilt from the engine's model, which does not hold REFERENCES, UNIQUE, COLLATE or a generated column",
					table.schema.name,
				)
				append(&store.mirror_losses, loss)
			}
		}
		append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = master})
		tables += 1
		// A kept text keeps its own key declarations, so the automatic indexes
		// they imply are written first, with the number the declaration gives
		// them: SQLite numbers automatic indexes in the order it creates them,
		// which is the order the constraints appear (D27).
		if keep_text {
			for index_name, order in original.key_indexes {
				index, found := sqlite_index_by_name(&table.schema, index_name)
				if !found do continue
				if sqlite_is_table_key(table, &index) do continue
				index_root := sqlite_write_index_tree(&w, table, index, exported[:], alloc, store)
				if index_root == 0 do continue
				row := make([]Value, 5, alloc)
				row[0] = value_string("index")
				autoindex := fmt.aprintf("sqlite_autoindex_%s_%d", table.schema.name, order + 1)
				append(&owned, autoindex)
				row[1] = value_string(autoindex)
				row[2] = value_string(table.schema.name)
				row[3] = value_int(i64(index_root))
				row[4] = value_null()
				append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = row})
			}
		}
		// Secondary indexes. The rowid alias needs none; the key does, and it is
		// named the way SQLite names the index a table constraint implies, with a
		// NULL SQL: the declaration in the table's own text is what says what it
		// is. A table whose original text was kept has no such row, because
		// `mirror_text_keepable` refuses a text that declares a key (D33).
		alias := sqlite_rowid_alias(table)
		for &index in table.schema.indexes {
			if index.implicit && len(index.columns) == 1 && index.columns[0] == alias do continue
			if sqlite_is_table_key(table, &index) do continue
			if keep_text && sqlite_name_in(original.key_indexes, index.name) do continue
			index_text := texts[index.name] or_else ""
			if kept, imported := store_mirror_kept_lookup(store, index.name); imported && len(index_text) == 0 do index_text = kept.sql
			index_root := sqlite_write_index_tree(&w, table, index, exported[:], alloc, store, index_text)
			if index_root == 0 do continue
			implied := !keep_text && index.unique && len(table.schema.primary_key) > 0 &&
				schema_index_matches(&index, table.schema.primary_key)
			index_row := make([]Value, 5, alloc)
			index_row[0] = value_string("index")
			if implied {
				autoindex := fmt.aprintf("sqlite_autoindex_%s_1", table.schema.name)
				append(&owned, autoindex)
				index_row[1] = value_string(autoindex)
			} else {
				index_row[1] = value_string(index.name)
			}
			index_row[2] = value_string(table.schema.name)
			index_row[3] = value_int(i64(index_root))
			if implied {
				// SQLite stores NULL in the sql column of an automatic index: there
				// is no statement to re-run, the declaration that made it is enough.
				index_row[4] = value_null()
			} else {
				if text, has_text := texts[index.name]; has_text {
					index_row[4] = value_string(strings.clone(text))
				} else {
					index_row[4] = value_string(sqlite_index_sql(table, index))
				}
				append(&owned, index_row[4].s)
			}
			append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = index_row})
		}
		// An index the engine could not build goes back as the file had it: its
		// table refuses writes while it is kept, so its entries are still the
		// ones the rows imply (D24).
		for kept in store.mirror_kept {
			if kept.kind != "index" || !strings.equal_fold(kept.table, table.schema.name) do continue
			built := false
			for index in table.schema.indexes do built ||= strings.equal_fold(index.name, kept.name)
			if built do continue
			kept_row := make([]Value, 5, alloc)
			kept_row[0] = value_string("index")
			kept_row[1] = value_string(kept.name)
			kept_row[2] = value_string(table.schema.name)
			kept_row[3] = value_int(i64(sqlite_index_btree(&w, kept.payloads, alloc)))
			kept_row[4] = value_string(kept.sql)
			append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = kept_row})
		}
	}

	// The views and triggers: the engine's, with the file's own text for one
	// that came from it unchanged, and then the ones a file held that the
	// engine could not read, as the file had them (D27).
	for object in store_catalog_objects(store, context.temp_allocator) {
		row := make([]Value, 5, alloc)
		row[0] = value_string(object.type)
		row[1] = value_string(object.name)
		row[2] = value_string(object.tbl_name)
		row[3] = value_int(0)
		row[4] = value_string(strings.clone(object.sql))
		append(&owned, row[4].s)
		append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = row})
	}

	// sqlite_sequence tracks AUTOINCREMENT counters; SQLite creates it only when a
	// table uses one.
	sequence_rows := make([dynamic]Sqlite_Export_Row, 0, 2)
	defer {
		for row in sequence_rows do delete(row.values, alloc)
		delete(sequence_rows)
	}
	for name in names {
		table := store.tables[name]
		if table.schema.auto_increment_column < 0 do continue
		// SQLite stores the last rowid given out; the engine keeps the next.
		values := make([]Value, 2, alloc)
		values[0] = value_string(table.schema.name)
		values[1] = value_int(max(table.next_sequence - 1, 0))
		append(&sequence_rows, Sqlite_Export_Row{rowid = i64(len(sequence_rows) + 1), values = values})
	}
	if len(sequence_rows) > 0 {
		sequence_cells := make([][]u8, len(sequence_rows), alloc)
		sequence_keys := make([]i64, len(sequence_rows), alloc)
		for row, i in sequence_rows {
			payload := sqlite_encode_record(row.values, -1, alloc)
			sequence_cells[i] = sqlite_leaf_cell(&w, payload, row.rowid)
			delete(payload, alloc)
			sequence_keys[i] = row.rowid
		}
		sequence_root := sqlite_build_tree(&w, sequence_cells, sequence_keys, alloc)
		for cell in sequence_cells do delete(cell)
		delete(sequence_cells, alloc)
		delete(sequence_keys, alloc)
		sequence_row := make([]Value, 5, alloc)
		sequence_row[0] = value_string("table")
		sequence_row[1] = value_string("sqlite_sequence")
		sequence_row[2] = value_string("sqlite_sequence")
		sequence_row[3] = value_int(i64(sequence_root))
		sequence_row[4] = value_string("CREATE TABLE sqlite_sequence(name,seq)")
		append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = sequence_row})
	}

	sqlite_master_order(store, master_rows[:])

	// sqlite_master: build the tree with page 1 as its root.
	master_cells := make([][]u8, len(master_rows), alloc)
	master_keys := make([]i64, len(master_rows), alloc)
	for row, i in master_rows {
		payload := sqlite_encode_record(row.values, -1, alloc)
		master_cells[i] = sqlite_leaf_cell(&w, payload, row.rowid)
		delete(payload, alloc)
		master_keys[i] = row.rowid
	}
	master_root := sqlite_build_tree(&w, master_cells, master_keys, alloc, SQLITE_HEADER_MIN)
	for cell in master_cells do delete(cell)
	delete(master_cells, alloc)
	delete(master_keys, alloc)
	if master_root != 1 {
		// Page 1 holds the 100-byte file header, so its b-tree header starts at
		// offset 100 and every cell offset shifts by 100. The built root page
		// becomes a freelist trunk once its content has moved.
		sqlite_move_to_page_one(&w, master_root)
		if master_root == len(w.pages) {
			// The root was the last page written, so the file just ends before
			// it: an empty database is one page, as SQLite writes it.
			delete(w.pages[master_root - 1])
			resize(&w.pages, master_root - 1)
		} else {
			sqlite_release_page(&w, master_root)
			freelist_trunk = master_root
		}
	}

	page_count := len(w.pages)
	header := sqlite_writer_page(&w, 1)
	copy(header[:16], SQLITE_MAGIC)
	// 65536 does not fit two bytes: SQLite writes it as 1.
	stored_size := w.page_size == 65536 ? 1 : w.page_size
	header[16] = u8(stored_size >> 8)
	header[17] = u8(stored_size)
	header[18] = 1 // write version: legacy
	header[19] = 1 // read version: legacy
	header[21] = 64
	header[22] = 32
	header[23] = 32
	// Change counter and database size.
	header[24], header[25], header[26], header[27] = 0, 0, 0, 1
	header[28] = u8(page_count >> 24)
	header[29] = u8(page_count >> 16)
	header[30] = u8(page_count >> 8)
	header[31] = u8(page_count)
	if freelist_trunk > 0 {
		header[32] = u8(freelist_trunk >> 24)
		header[33] = u8(freelist_trunk >> 16)
		header[34] = u8(freelist_trunk >> 8)
		header[35] = u8(freelist_trunk)
		header[36], header[37], header[38], header[39] = 0, 0, 0, 1
	}
	// The program's integers: user_version and application_id.
	for name, offset in ([2]string{"user_version", "application_id"}) {
		value := u32(i32(store_header_value(store, name)))
		at := offset == 0 ? 60 : 68
		header[at], header[at + 1], header[at + 2], header[at + 3] = u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)
	}
	// Schema cookie, schema format 4, default cache size.
	header[40], header[41], header[42], header[43] = 0, 0, 0, 1
	header[44], header[45], header[46], header[47] = 0, 0, 0, 4
	// Text encoding: UTF-8.
	header[56], header[57], header[58], header[59] = 0, 0, 0, 1
	// Version-valid-for and the SQLite library version.
	header[92], header[93], header[94], header[95] = 0, 0, 0, 1
	header[96], header[97], header[98], header[99] = 0, 46, 54, 1

	file := make([]u8, page_count * w.page_size)
	for page, i in w.pages {
		copy(file[i * w.page_size:], page)
	}
	return file, tables, rows, ERROR_NONE
}

// sqlite_master_order puts the catalog rows in the order their objects were
// made, which is the order SQLite keeps them in (and lists, and dumps): each
// object's place is the row its CREATE text has in _sqlite_sql, an automatic
// index follows its table, sqlite_sequence the first table that counts, and
// an object without a text keeps its place after the rest. The rowids follow.
@(private)
sqlite_master_order :: proc(store: ^Store, rows: []Sqlite_Export_Row) {
	created := make(map[string]f64, len(rows), context.temp_allocator)
	if table, found := store.tables[SQL_TEXT_TABLE]; found {
		stored := make([dynamic]Row, context.temp_allocator)
		table_collect(table, &stored, max(u64))
		defer table_collect_release(table, &stored)
		for row in stored {
			if len(row.values) > 0 && row.values[0].kind == .String do created[row.values[0].s] = f64(row.id)
		}
	}
	text_of :: proc(v: Value) -> string {
		return v.kind == .String ? v.s : ""
	}
	Keyed :: struct {
		key: f64,
		row: Sqlite_Export_Row,
	}
	keyed := make([]Keyed, len(rows), context.temp_allocator)
	last := f64(1e15)
	for row, i in rows {
		kind, name, owner := text_of(row.values[0]), text_of(row.values[1]), text_of(row.values[2])
		key, found := created[name]
		switch {
		case found:
		case kind == "index" && row.values[4].kind == .Null:
			key = (created[owner] or_else last + f64(i)) + 0.25
		case name == "sqlite_sequence":
			key = last + f64(i)
			for other in rows {
				other_name := text_of(other.values[1])
				if table, has := store.tables[other_name]; has && table.schema.auto_increment_column >= 0 {
					if at, has_text := created[other_name]; has_text {
						key = at + 0.5
						break
					}
				}
			}
		case:
			key = last + f64(i)
		}
		keyed[i] = Keyed{key = key, row = row}
	}
	slice.stable_sort_by(keyed, proc(a, b: Keyed) -> bool { return a.key < b.key })
	for item, i in keyed {
		rows[i] = item.row
		rows[i].rowid = i64(i + 1)
	}
}

// sqlite_move_to_page_one copies a built root page into page 1, shifting the
// b-tree header and every cell by the 100 bytes the file header occupies.
@(private)
sqlite_move_to_page_one :: proc(w: ^Sqlite_Writer, root: int) {
	src := sqlite_writer_page(w, root)
	dst := sqlite_writer_page(w, 1)
	page_type := src[0]
	count := int(sqlite_be16(src, 3))
	content := int(sqlite_be16(src, 5))
	header := 8
	if page_type == 5 || page_type == 2 do header = 12
	shift := SQLITE_HEADER_MIN
	if content + shift > w.usable do return
	copy(dst[content + shift:w.usable], src[content:w.usable])
	dst[shift] = page_type
	dst[shift + 3] = u8(count >> 8)
	dst[shift + 4] = u8(count)
	dst[shift + 5] = u8((content + shift) >> 8)
	dst[shift + 6] = u8(content + shift)
	for i in 0 ..< count {
		src_at := header + i * 2
		pointer := int(sqlite_be16(src, src_at))
		dst_at := shift + header + i * 2
		dst[dst_at] = u8((pointer + shift) >> 8)
		dst[dst_at + 1] = u8(pointer + shift)
	}
	if page_type == 5 || page_type == 2 {
		copy(dst[shift + 8:shift + 12], src[8:12])
	}
}

// sqlite_release_page turns a spent page into a one-page freelist trunk.
@(private)
sqlite_release_page :: proc(w: ^Sqlite_Writer, page_no: int) {
	page := sqlite_writer_page(w, page_no)
	for i in 0 ..< len(page) do page[i] = 0
	page[0], page[1], page[2], page[3] = 0, 0, 0, 0
	page[4], page[5], page[6], page[7] = 0, 0, 0, 0
}

@(private)
sort_export_rows :: proc(rows: []Sqlite_Export_Row) {
	slice.sort_by(rows, proc(a, b: Sqlite_Export_Row) -> bool { return a.rowid < b.rowid })
}
