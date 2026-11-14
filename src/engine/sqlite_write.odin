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

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

SQLITE_WRITE_PAGE_SIZE :: 4096

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
		bytes: [9]u8
		v := value
		for i := 8; i >= 0; i -= 1 {
			bytes[i] = u8(v & 0xff)
			v >>= 8
		}
		// Mark all but the last byte's high bit.
		for i in 0 ..< 8 do bytes[i] |= 0x80
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

// sqlite_write_index_tree writes one index as a b-tree: leaf pages of type 10
// and interior pages of type 2 whose cells carry the largest key of the child.
@(private)
Sqlite_Index_Node :: struct {
	page:         int,
	last_payload: []u8,
}

@(private)
sqlite_write_index_tree :: proc(
	w: ^Sqlite_Writer,
	table: ^Table,
	index: Index_Schema,
	rows: []Sqlite_Export_Row,
	alloc: mem.Allocator,
) -> int {
	if len(index.columns) == 0 do return 0
	keys := make([][]Value, len(rows), alloc)
	defer delete(keys)
	for row, i in rows {
		values := make([]Value, len(index.columns) + 1, alloc)
		for column, position in index.columns {
			if column >= 0 && column < len(row.values) do values[position] = row.values[column]
		}
		values[len(index.columns)] = value_int(row.rowid)
		keys[i] = values
	}
	slice.sort_by(keys, proc(a, b: []Value) -> bool {
		for i in 0 ..< len(a) - 1 {
			order, ok := value_compare(a[i], b[i])
			if ok && order != .Equal do return order == .Less
		}
		return a[len(a) - 1].i < b[len(b) - 1].i
	})

	nodes := make([dynamic]Sqlite_Index_Node, 0, 8, alloc)
	defer delete(nodes)
	owned := make([dynamic][]u8, 0, 8, alloc)
	defer {
		for payload in owned do delete(payload, alloc)
		delete(owned)
	}

	page_no := 0
	page: []u8
	content := 0
	count := 0
	last: []u8
	finish_leaf := proc(w: ^Sqlite_Writer, page: []u8, count: int, content: int) {
		page[0] = 10
		page[3] = u8(count >> 8)
		page[4] = u8(count)
		page[5] = u8(content >> 8)
		page[6] = u8(content)
	}
	for values in keys {
		payload := sqlite_encode_record(values, -1, alloc)
		cell := sqlite_index_cell(w, payload)
		defer delete(cell)
		if page_no == 0 {
			page_no = sqlite_writer_new_page(w)
			page = sqlite_writer_page(w, page_no)
			content = w.usable
			count = 0
		}
		if len(cell) + 8 + (count + 1) * 2 > content && count > 0 {
			finish_leaf(w, page, count, content)
			append(&nodes, Sqlite_Index_Node{page = page_no, last_payload = last})
			page_no = sqlite_writer_new_page(w)
			page = sqlite_writer_page(w, page_no)
			content = w.usable
			count = 0
		}
		content -= len(cell)
		copy(page[content:content + len(cell)], cell)
		at := 8 + count * 2
		page[at] = u8(content >> 8)
		page[at + 1] = u8(content)
		count += 1
		kept := make([]u8, len(payload), alloc)
		copy(kept, payload)
		append(&owned, kept)
		last = kept
		// The payload is encoded fresh per entry; the leaf keeps a copy in `kept`.
		delete(payload, alloc)
	}
	if page_no != 0 {
		finish_leaf(w, page, count, content)
		append(&nodes, Sqlite_Index_Node{page = page_no, last_payload = last})
	}
	if len(nodes) == 0 do return 0
	for len(nodes) > 1 {
		next := make([dynamic]Sqlite_Index_Node, 0, 8, alloc)
		i := 0
		for i < len(nodes) {
			interior_no := sqlite_writer_new_page(w)
			interior := sqlite_writer_page(w, interior_no)
			interior[0] = 2
			content = w.usable
			count = 0
			for i + 1 < len(nodes) {
				key := nodes[i].last_payload
				cell_size := 4 + varint_size(i64(len(key))) + len(key)
				if cell_size + 12 + (count + 1) * 2 > content && count > 0 do break
				content -= cell_size
				child := u32(nodes[i].page)
				interior[content] = u8(child >> 24)
				interior[content + 1] = u8(child >> 16)
				interior[content + 2] = u8(child >> 8)
				interior[content + 3] = u8(child)
				key_buffer := make([dynamic]u8, 0, 9)
				sqlite_put_varint(&key_buffer, u64(len(key)))
				copy(interior[content + 4:content + 4 + len(key_buffer)], key_buffer[:])
				copy(interior[content + 4 + len(key_buffer):content + 4 + len(key_buffer) + len(key)], key)
				delete(key_buffer)
				at := 12 + count * 2
				interior[at] = u8(content >> 8)
				interior[at + 1] = u8(content)
				count += 1
				i += 1
			}
			right := u32(nodes[i].page)
			interior[8] = u8(right >> 24)
			interior[9] = u8(right >> 16)
			interior[10] = u8(right >> 8)
			interior[11] = u8(right)
			i += 1
			interior[3] = u8(count >> 8)
			interior[4] = u8(count)
			interior[5] = u8(content >> 8)
			interior[6] = u8(content)
			last_key := nodes[i - 1].last_payload
			append(&next, Sqlite_Index_Node{page = interior_no, last_payload = last_key})
		}
		delete(nodes)
		nodes = next
	}
	return nodes[0].page
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
		if position >= 0 && position < len(table.schema.columns) {
			sqlite_write_ident(&builder, table.schema.columns[position].name)
		}
	}
	strings.write_byte(&builder, ')')
	return strings.to_string(builder)
}

// --- Database --------------------------------------------------------------

@(private)
sqlite_master_sql :: proc(table: ^Table) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "CREATE TABLE ")
	sqlite_write_ident(&builder, table.schema.name)
	strings.write_string(&builder, " (")
	for column, i in table.schema.columns {
		if i > 0 do strings.write_string(&builder, ", ")
		sqlite_write_ident(&builder, column.name)
		strings.write_byte(&builder, ' ')
		strings.write_string(&builder, sqlite_type_name(column.type))
		if column.not_null do strings.write_string(&builder, " NOT NULL")
	}
	if len(table.schema.primary_key) == 1 {
		position := table.schema.primary_key[0]
		strings.write_string(&builder, ", PRIMARY KEY (")
		sqlite_write_ident(&builder, table.schema.columns[position].name)
		strings.write_byte(&builder, ')')
	}
	strings.write_string(&builder, ")")
	return strings.to_string(builder)
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
	w := Sqlite_Writer {
		page_size = SQLITE_WRITE_PAGE_SIZE,
		usable    = SQLITE_WRITE_PAGE_SIZE,
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

	root_pages := make([dynamic]int, 0, len(names))
	defer delete(root_pages)
	master_rows := make([dynamic]Sqlite_Export_Row, 0, len(names))
	defer delete(master_rows)
	for name in names {
		table := store.tables[name]
		// Reading through the collect makes a paged table export the same as a
		// memory one; the decoded values are released after the records encode.
		collected := make([dynamic]Row)
		table_collect(table, &collected, max(u64))
		defer table_collect_release(table, &collected)
		exported := make([dynamic]Sqlite_Export_Row, 0, len(collected))
		defer delete(exported)
		rowid_column := -1
		if len(table.schema.primary_key) == 1 {
			position := table.schema.primary_key[0]
			if table.schema.columns[position].type.kind == .Int {
				rowid_column = position
			}
		}
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
		cells := make([][]u8, len(exported), alloc)
		keys := make([]i64, len(exported), alloc)
		for row, i in exported {
			payload := sqlite_encode_record(row.values, rowid_column, alloc)
			cells[i] = sqlite_leaf_cell(&w, payload, row.rowid)
			delete(payload, alloc)
			keys[i] = row.rowid
			rows += 1
		}
		root := sqlite_build_tree(&w, cells, keys, alloc)
		for cell in cells do delete(cell)
		delete(cells, alloc)
		delete(keys, alloc)
		append(&root_pages, root)
		master := make([]Value, 5)
		master[0] = value_string("table")
		master[1] = value_string(table.schema.name)
		master[2] = value_string(table.schema.name)
		master[3] = value_int(i64(root))
		master[4] = value_string(sqlite_master_sql(table))
		append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = master})
		tables += 1
		// Secondary indexes: implicit ones (the rowid key) are not needed.
		for index in table.schema.indexes {
			if index.implicit do continue
			index_root := sqlite_write_index_tree(&w, table, index, exported[:], alloc)
			if index_root == 0 do continue
			index_row := make([]Value, 5)
			index_row[0] = value_string("index")
			index_row[1] = value_string(index.name)
			index_row[2] = value_string(table.schema.name)
			index_row[3] = value_int(i64(index_root))
			index_row[4] = value_string(sqlite_index_sql(table, index))
			append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = index_row})
		}
	}

	// sqlite_sequence tracks AUTOINCREMENT counters; SQLite creates it only when a
	// table uses one.
	sequence_rows := make([dynamic]Sqlite_Export_Row, 0, 2)
	defer delete(sequence_rows)
	for name in names {
		table := store.tables[name]
		if table.schema.auto_increment_column < 0 do continue
		values := make([]Value, 2, alloc)
		values[0] = value_string(table.schema.name)
		values[1] = value_int(table.next_sequence)
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
		sequence_row := make([]Value, 5)
		sequence_row[0] = value_string("table")
		sequence_row[1] = value_string("sqlite_sequence")
		sequence_row[2] = value_string("sqlite_sequence")
		sequence_row[3] = value_int(i64(sequence_root))
		sequence_row[4] = value_string("CREATE TABLE sqlite_sequence(name,seq)")
		append(&master_rows, Sqlite_Export_Row{rowid = i64(len(master_rows) + 1), values = sequence_row})
	}

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
		sqlite_release_page(&w, master_root)
		freelist_trunk = master_root
	}

	page_count := len(w.pages)
	header := sqlite_writer_page(&w, 1)
	copy(header[:16], SQLITE_MAGIC)
	header[16] = u8(w.page_size >> 8)
	header[17] = u8(w.page_size)
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
	if write_err := os.write_entire_file(path, file); write_err != nil {
		return tables, rows, errf(.Io, "cannot write %s: %v", path, write_err)
	}
	return tables, rows, ERROR_NONE
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
