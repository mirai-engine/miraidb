package engine

// SQLite database-file reader.
//
// The engine keeps its own format (a commit log plus snapshots), but users come
// with .sqlite/.db files. This file parses the SQLite file format just enough to
// import it: the 100-byte header, the sqlite_master b-tree, table b-trees with
// their rowid keys, index b-trees for WITHOUT ROWID tables, the varint and
// serial-type encodings, and the overflow chains.
//
// The reader is deliberately read-only and allocation-explicit: `sqlite_file_open`
// takes ownership of the file bytes and `sqlite_file_destroy` releases them.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

SQLITE_MAGIC :: "SQLite format 3\x00"

// Sqlite_Column is one column as declared in sqlite_master.
Sqlite_Column :: struct {
	name:        string,
	declared:    string,
	not_null:    bool,
	primary_key: bool,
	// autoincrement is INTEGER PRIMARY KEY AUTOINCREMENT: a rowid is never
	// handed out twice, which sqlite_sequence remembers.
	autoincrement: bool,
	inferred:    Type_Kind,
}

// Sqlite_Table is one sqlite_master row of type table.
Sqlite_Table :: struct {
	name:          string,
	root_page:     u32,
	sql:           string,
	columns:       []Sqlite_Column,
	without_rowid: bool,
	// pk_position is the column index of INTEGER PRIMARY KEY, which SQLite
	// stores as the rowid and leaves null inside the record.
	pk_position:   int,
	// primary_group and unique_groups are the column positions of a table-level
	// PRIMARY KEY or UNIQUE clause. A single-column key travels as
	// `column.primary_key`; these hold what a column cannot say, because a key
	// the engine cannot recreate is a constraint the import silently drops (D33).
	primary_group: []int,
	unique_groups: [dynamic][]int,
	// key_order holds every key group in the order SQLite creates its automatic
	// indexes from the declaration, rowid alias excluded. A rewrite that keeps the
	// text has to spell those indexes with these numbers (D27).
	key_order:     [dynamic][]int,
}

// Sqlite_Index is one sqlite_master row of type index whose SQL SQLite stored.
// An automatic index (`sqlite_autoindex_*`) has no SQL, so the constraint it
// mirrors is read from the table text instead and recreated as a table-level key
// (sqlite_constraints_from_sql).
// Sqlite_Object is a catalog entry the engine does not model: a view or a
// trigger. Its SQL is kept verbatim, because a rewrite that dropped it would
// delete part of the user's database (D27).
Sqlite_Object :: struct {
	kind:  string, // "view" or "trigger"
	name:  string,
	table: string,
	sql:   string,
}

Sqlite_Index :: struct {
	name:  string,
	table: string,
	sql:   string,
}

// Sqlite_Index_Tree is one index row of sqlite_master with a b-tree: its
// name, its table, its root page and whether a WHERE makes it partial.
Sqlite_Index_Tree :: struct {
	name:    string,
	table:   string,
	root:    u32,
	partial: bool,
}

// Sqlite_File is an open SQLite database image held in memory.
Sqlite_File :: struct {
	data:      []u8,
	page_size: u32,
	usable:    u32,
	encoding:  u32,
	tables:    []Sqlite_Table,
	// indexes are the secondary indexes the file declares. An import recreates
	// them, so a plan can use one and DROP INDEX finds it; before this they were
	// silently dropped, and the imported database scanned.
	indexes:   []Sqlite_Index,
	// others are the views and triggers, kept as text because the engine has no
	// model for them. A rewrite re-emits them unchanged (D27).
	others:    []Sqlite_Object,
	// index_trees are every index b-tree sqlite_master names, automatic ones
	// included: what a check walks to count an index's entries.
	index_trees: []Sqlite_Index_Tree,
	// sequence_root is sqlite_sequence's root page, 0 when the file has none.
	sequence_root: u32,
	// catalog names every object with a CREATE text in sqlite_master's
	// order, which is the order SQLite lists them in.
	catalog: []string,
	// wal_pages holds the images a write-ahead log carries; the reader consults
	// them before the database file. wal_committed is the database size at the
	// last commit frame (0 when the log has no commit).
	wal_pages:     map[u32][]u8,
	wal_committed: u32,
	alloc:     mem.Allocator,
}

SQLITE_HEADER_MIN :: 100

@(private)
sqlite_be16 :: proc(data: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(data) do return 0
	return u16(data[at]) << 8 | u16(data[at + 1])
}

@(private)
sqlite_be32 :: proc(data: []u8, at: int) -> u32 {
	if at < 0 || at + 4 > len(data) do return 0
	return u32(data[at]) << 24 | u32(data[at + 1]) << 16 | u32(data[at + 2]) << 8 | u32(data[at + 3])
}

// sqlite_varint decodes SQLite's big-endian base-128 integer. The ninth byte
// contributes a full eight bits.
sqlite_varint :: proc(data: []u8, at: int) -> (value: u64, size: int) {
	i := at
	for i < len(data) && i - at < 9 {
		b := data[i]
		if i - at == 8 {
			value = value << 8 | u64(b)
			i += 1
			break
		}
		value = value << 7 | u64(b & 0x7f)
		i += 1
		if b & 0x80 == 0 do break
	}
	return value, i - at
}

// sqlite_is_empty_file reports an existing regular file with no bytes.
sqlite_is_empty_file :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil do return false
	return info.type == .Regular && info.size == 0
}

// Path_Kind is what a path names on disk, for opening it the way SQLite does.
Path_Kind :: enum {
	Missing,
	File,
	Directory,
}

path_kind :: proc(path: string) -> Path_Kind {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil do return .Missing
	return info.type == .Directory ? .Directory : .File
}

// sqlite_create_empty_file makes the zero-byte file SQLite leaves for a new
// database; the first commit writes it.
sqlite_create_empty_file :: proc(path: string) -> bool {
	file, err := os.open(path, {.Read, .Write, .Create})
	if err != nil do return false
	os.close(file)
	return true
}

sqlite_is_file :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < len(SQLITE_MAGIC) do return false
	return string(data[:len(SQLITE_MAGIC)]) == SQLITE_MAGIC
}

// sqlite_read_signed reads a big-endian two's complement integer of 1..8 bytes.
@(private)
sqlite_read_signed :: proc(data: []u8, at, width: int) -> i64 {
	x: i64
	for k in 0 ..< width {
		x = x << 8 | i64(data[at + k])
	}
	if width < 8 {
		shift := u32(64 - width * 8)
		x = (x << shift) >> shift
	}
	return x
}

// sqlite_local_size returns how many payload bytes live inside the cell.
@(private)
sqlite_local_size :: proc(payload_len: int, usable: int, table_leaf: bool) -> int {
	max_local: int
	min_local: int
	if table_leaf {
		max_local = usable - 35
		min_local = ((usable - 12) * 32 / 255) - 23
	} else {
		max_local = ((usable - 12) * 64 / 255) - 23
		min_local = ((usable - 12) * 32 / 255) - 23
	}
	if payload_len <= max_local do return payload_len
	local := min_local + (payload_len - min_local) % (usable - 4)
	if local > max_local do return min_local
	return local
}

// sqlite_wal_load reads a -wal file and keeps its frames as page images. The
// frames whose salts do not match the header end the log, as SQLite does, and
// the last frame with a database size marks the last commit.
@(private)
sqlite_wal_load :: proc(file: ^Sqlite_File, path: string) -> bool {
	data, read_err := os.read_entire_file(path, file.alloc)
	if read_err != nil do return false
	defer delete(data, file.alloc)
	if len(data) < 32 do return false
	magic := sqlite_be32(data, 0)
	if magic != 0x377f0682 && magic != 0x377f0683 do return false
	page_size := u32(sqlite_be32(data, 8))
	if page_size < 512 || page_size & (page_size - 1) != 0 do return false
	salt1 := sqlite_be32(data, 16)
	salt2 := sqlite_be32(data, 20)
	frame_len := 24 + int(page_size)
	frame := 32
	file.wal_pages = make(map[u32][]u8, 8, file.alloc)
	for frame + frame_len <= len(data) {
		page_no := sqlite_be32(data, frame)
		db_size := sqlite_be32(data, frame + 4)
		if sqlite_be32(data, frame + 8) != salt1 || sqlite_be32(data, frame + 12) != salt2 do break
		if page_no == 0 do break
		image := make([]u8, page_size, file.alloc)
		copy(image, data[frame + 24:frame + 24 + int(page_size)])
		if previous, exists := file.wal_pages[page_no]; exists do delete(previous, file.alloc)
		file.wal_pages[page_no] = image
		if db_size > 0 do file.wal_committed = db_size
		frame += frame_len
	}
	// An empty database takes the page size from the log.
	if len(file.data) <= int(file.page_size) do file.page_size = page_size
	return len(file.wal_pages) > 0
}

// sqlite_journal_rollback restores the pages a hot rollback journal recorded.
// SQLite writes the original page images there before touching the database, so
// a journal next to the file means the transaction never committed and the
// images win. Records start on sector boundaries. Once the images are back the
// journal is deleted, which is what makes this recovery rather than a replay
// that would undo the next commit as well.
@(private)
sqlite_journal_rollback :: proc(file: ^Sqlite_File, path: string, recover := false) -> bool {
	data, read_err := os.read_entire_file(path, file.alloc)
	if read_err != nil do return false
	defer delete(data, file.alloc)
	if len(data) < 28 do return false
	magic := [8]u8{0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7}
	for byte, i in magic {
		if data[i] != byte do return false
	}
	page_size := u32(sqlite_be32(data, 24))
	if page_size < 512 || page_size & (page_size - 1) != 0 do return false
	sector := u32(sqlite_be32(data, 20))
	if sector < 32 || sector & (sector - 1) != 0 do sector = 512
	at := int(sector)
	applied := false
	for at + 4 + int(page_size) <= len(data) {
		page_no := sqlite_be32(data, at)
		if page_no == 0 do break
		image := data[at + 4:at + 4 + int(page_size)]
		offset := (int(page_no) - 1) * int(page_size)
		if offset + int(page_size) <= len(file.data) {
			copy(file.data[offset:offset + int(page_size)], image)
			applied = true
		}
		record := 4 + int(page_size) + 4
		at += (record + int(sector) - 1) / int(sector) * int(sector)
	}
	if applied && recover {
		// The owner is about to write the file: the transaction is rolled back
		// and keeping the journal would restore these pages over the next
		// commit. A plain reader leaves it alone.
		os.remove(path)
	}
	return applied
}

@(private)
sqlite_page :: proc(file: ^Sqlite_File, page_no: u32) -> []u8 {
	if image, in_wal := file.wal_pages[page_no]; in_wal do return image
	if file.wal_committed > 0 && page_no > file.wal_committed do return nil
	offset := int(page_no - 1) * int(file.page_size)
	if offset < 0 || offset >= len(file.data) do return nil
	end := min(offset + int(file.page_size), len(file.data))
	return file.data[offset:end]
}

// sqlite_payload copies a cell payload, following the overflow chain.
@(private)
sqlite_payload :: proc(
	file: ^Sqlite_File,
	cell: []u8,
	at: int,
	payload_len: int,
	table_leaf: bool,
	alloc: mem.Allocator,
) -> ([]u8, bool) {
	local := sqlite_local_size(payload_len, int(file.usable), table_leaf)
	if at + local > len(cell) do return nil, false
	payload := make([]u8, payload_len, alloc)
	copy(payload[:local], cell[at:at + local])
	if local < payload_len {
		// The four bytes after the local payload point at the first overflow page.
		if at + local + 4 > len(cell) do return nil, false
		next := sqlite_be32(cell, at + local)
		written := local
		for next != 0 && written < payload_len {
			page := sqlite_page(file, next)
			if len(page) < 4 do return nil, false
			next = sqlite_be32(page, 0)
			available := len(page) - 4
			take := min(available, payload_len - written)
			copy(payload[written:written + take], page[4:4 + take])
			written += take
		}
		if written != payload_len do return nil, false
	}
	return payload, true
}

// sqlite_record decodes one record payload into values.
sqlite_record :: proc(payload: []u8, alloc: mem.Allocator) -> ([]Value, bool) {
	header_len, header_size := sqlite_varint(payload, 0)
	if header_size == 0 || int(header_len) > len(payload) || int(header_len) < header_size do return nil, false
	types := make([dynamic]u64, 0, 8, alloc)
	defer delete(types)
	at := header_size
	for at < int(header_len) {
		serial, size := sqlite_varint(payload, at)
		if size == 0 do return nil, false
		append(&types, serial)
		at += size
	}
	values := make([]Value, len(types), alloc)
	body := int(header_len)
	for serial, i in types {
		width := 0
		kind := Value_Kind.Null
		switch {
		case serial == 0:
			kind = .Null
		case serial == 1:
			kind = .Int; width = 1
		case serial == 2:
			kind = .Int; width = 2
		case serial == 3:
			kind = .Int; width = 3
		case serial == 4:
			kind = .Int; width = 4
		case serial == 5:
			kind = .Int; width = 6
		case serial == 6:
			kind = .Int; width = 8
		case serial == 7:
			kind = .Float; width = 8
		case serial == 8:
			values[i] = value_int(0)
			continue
		case serial == 9:
			values[i] = value_int(1)
			continue
		case serial >= 12 && serial % 2 == 0:
			kind = .Bytes; width = int((serial - 12) / 2)
		case serial >= 13:
			kind = .String; width = int((serial - 13) / 2)
		case:
			return nil, false
		}
		if body + width > len(payload) do return nil, false
		#partial switch kind {
		case .Int:
			values[i] = value_int(sqlite_read_signed(payload, body, width))
		case .Float:
			bits := u64(0)
			for k in 0 ..< 8 do bits = bits << 8 | u64(payload[body + k])
			values[i] = value_float(transmute(f64)(bits))
		case .String:
			text := strings.clone(string(payload[body:body + width]), alloc)
			values[i] = value_string(text)
		case .Bytes:
			bytes := make([]u8, width, alloc)
			copy(bytes, payload[body:body + width])
			values[i] = value_bytes(bytes)
		case .Null:
			values[i] = value_null()
		}
		body += width
	}
	return values, true
}

// sqlite_walk visits every cell payload of a b-tree in key order.
@(private)
sqlite_walk :: proc(
	file: ^Sqlite_File,
	page_no: u32,
	table: bool,
	visit: proc(user: rawptr, rowid: i64, payload: []u8) -> bool,
	user: rawptr,
	depth: int,
) -> bool {
	if depth > 64 do return false
	page := sqlite_page(file, page_no)
	if len(page) < 8 do return false
	// Page 1 starts with the 100-byte file header, so its b-tree page header is
	// at offset 100. Cell pointers stay absolute to the page, as stored.
	base := page_no == 1 ? SQLITE_HEADER_MIN : 0
	if len(page) < base + 12 do return false
	page_type := page[base]
	cell_count := int(sqlite_be16(page, base + 3))
	header := base + 8
	if page_type == 5 || page_type == 2 do header = base + 12
	if page_type == 5 || page_type == 2 {
		// Interior page: visit children in order, then the right-most pointer.
		// An index's interior cell is an entry of its own, between the child
		// before it and the next one (a table's only carries a key).
		for i in 0 ..< cell_count {
			at := header + i * 2
			if at + 2 > len(page) do return false
			pointer := int(sqlite_be16(page, at))
			if pointer + 4 > len(page) do return false
			child := sqlite_be32(page, pointer)
			if !sqlite_walk(file, child, table, visit, user, depth + 1) do return false
			if page_type == 2 {
				cell := page[pointer + 4:]
				payload_len, size := sqlite_varint(cell, 0)
				if size == 0 do return false
				payload, ok := sqlite_payload(file, cell, size, int(payload_len), false, file.alloc)
				if !ok do return false
				keep_going := visit(user, 0, payload)
				delete(payload, file.alloc)
				if !keep_going do return false
			}
		}
		right := sqlite_be32(page, base + 8)
		if right != 0 {
			if !sqlite_walk(file, right, table, visit, user, depth + 1) do return false
		}
		return true
	}
	leaf_table := page_type == 13
	if page_type != 13 && page_type != 10 do return false
	for i in 0 ..< cell_count {
		at := header + i * 2
		if at + 2 > len(page) do return false
		pointer := int(sqlite_be16(page, at))
		if pointer >= len(page) do return false
		cell := page[pointer:]
		payload_len, size := sqlite_varint(cell, 0)
		if size == 0 do return false
		cursor := size
		rowid := i64(0)
		if leaf_table {
			raw, rowid_size := sqlite_varint(cell, cursor)
			if rowid_size == 0 do return false
			rowid = i64(raw)
			cursor += rowid_size
		}
		// Index cells (WITHOUT ROWID tables) have no rowid: the key columns are
		// the payload itself, so nothing else is skipped here.
		payload, ok := sqlite_payload(file, cell, cursor, int(payload_len), leaf_table, file.alloc)
		if !ok do return false
		keep_going := visit(user, rowid, payload)
		delete(payload, file.alloc)
		if !keep_going do return false
	}
	return true
}

@(private)
Sqlite_Master_Ctx :: struct {
	file:    ^Sqlite_File,
	tables:  [dynamic]Sqlite_Table,
	indexes: [dynamic]Sqlite_Index,
	others:  [dynamic]Sqlite_Object,
	trees:   [dynamic]Sqlite_Index_Tree,
	sequence_root: u32,
	catalog: [dynamic]string,
}

@(private)
sqlite_master_visit :: proc(user: rawptr, rowid: i64, payload: []u8) -> bool {
	ctx := cast(^Sqlite_Master_Ctx)user
	values, ok := sqlite_record(payload, ctx.file.alloc)
	if !ok do return true
	// What is kept below is cloned; the decoded row is this call's.
	defer {
		for value in values do value_deep_free(value, ctx.file.alloc)
		delete(values, ctx.file.alloc)
	}
	if len(values) < 5 do return true
	kind := values[0]
	name := values[1]
	sql := values[4]
	if name.kind == .String && sql.kind == .String && len(sql.s) > 0 {
		append(&ctx.catalog, strings.clone(name.s, ctx.file.alloc))
	}
	if kind.kind == .String && strings.equal_fold(kind.s, "index") {
		if name.kind == .String && values[3].kind == .Int && values[3].i > 0 {
			append(
				&ctx.trees,
				Sqlite_Index_Tree {
					name = strings.clone(name.s, ctx.file.alloc),
					table = values[2].kind == .String ? strings.clone(values[2].s, ctx.file.alloc) : "",
					root = u32(values[3].i),
					partial = sql.kind == .String && sqlite_contains_word(sql.s, "WHERE"),
				},
			)
		}
		// sql is the CREATE INDEX statement SQLite kept; the table name is the
		// fourth column. An automatic index has no SQL and is left out.
		if name.kind == .String && sql.kind == .String && len(sql.s) > 0 &&
		   !strings.has_prefix(name.s, "sqlite_") {
			append(
				&ctx.indexes,
				Sqlite_Index {
					name = strings.clone(name.s, ctx.file.alloc),
					table = values[2].kind == .String ? strings.clone(values[2].s, ctx.file.alloc) : "",
					sql = strings.clone(sql.s, ctx.file.alloc),
				},
			)
		}
		return true
	}
	if kind.kind == .String &&
	   (strings.equal_fold(kind.s, "view") || strings.equal_fold(kind.s, "trigger")) {
		// A view or a trigger is part of the database even though the engine has
		// no model for it: keep its text so a rewrite can put it back (D27).
		if name.kind == .String && sql.kind == .String && len(sql.s) > 0 {
			append(
				&ctx.others,
				Sqlite_Object {
					kind = strings.clone(kind.s, ctx.file.alloc),
					name = strings.clone(name.s, ctx.file.alloc),
					table = values[2].kind == .String ? strings.clone(values[2].s, ctx.file.alloc) : "",
					sql = strings.clone(sql.s, ctx.file.alloc),
				},
			)
		}
		return true
	}
	if kind.kind != .String || !strings.equal_fold(kind.s, "table") do return true
	if name.kind != .String do return true
	if strings.equal_fold(name.s, "sqlite_sequence") && values[3].kind == .Int {
		ctx.sequence_root = u32(values[3].i)
		return true
	}
	if strings.has_prefix(name.s, "sqlite_") do return true
	table := Sqlite_Table {
		name      = strings.clone(name.s, ctx.file.alloc),
		root_page = u32(values[3].i),
		sql       = sql.kind == .String ? strings.clone(sql.s, ctx.file.alloc) : "",
		// No column is the rowid until the declaration says so: a NULL in the
		// first column of a table without an INTEGER PRIMARY KEY used to come
		// back as the row's rowid.
		pk_position = -1,
	}
	// The columns are read from the table's own copy of the text.
	table.columns = sqlite_columns_from_sql(table.sql, ctx.file.alloc)
	table.without_rowid = sqlite_contains_word(table.sql, "WITHOUT ROWID")
	sqlite_constraints_from_sql(table.sql, &table, ctx.file.alloc)
	for column, i in table.columns {
		if table.without_rowid do break
		if column.primary_key && strings.equal_fold(column.declared, "INTEGER") {
			table.pk_position = i
			break
		}
	}
	append(&ctx.tables, table)
	return true
}

@(private)
sqlite_contains_word :: proc(haystack, word: string) -> bool {
	upper := strings.to_upper(haystack, context.temp_allocator)
	return strings.contains(upper, word)
}

// sqlite_table_items splits the top-level parenthesised list of a CREATE TABLE
// statement on the commas that separate its items. It is the one scanner the
// column reader and the constraint reader share.
@(private)
sqlite_table_items :: proc(sql: string, alloc: mem.Allocator) -> []string {
	items := make([dynamic]string, 0, 8, alloc)
	open := strings.index_rune(sql, '(')
	if open < 0 do return items[:]
	depth := 0
	start := open + 1
	end := -1
	for i in open ..< len(sql) {
		switch sql[i] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
			if depth == 0 {
				end = i
				break
			}
		}
		if end >= 0 do break
	}
	if end < 0 do return items[:]
	body := sql[start:end]
	item_start := 0
	depth = 0
	in_quote: u8 = 0
	for i in 0 ..= len(body) {
		last := i == len(body)
		c := body[i] if !last else u8(',')
		if in_quote != 0 {
			if c == in_quote do in_quote = 0
			continue
		}
		if c == '"' || c == '\'' || c == '`' || c == '[' {
			in_quote = c == '[' ? u8(']') : c
			continue
		}
		if c == '(' {
			depth += 1
			continue
		}
		if c == ')' {
			depth -= 1
			continue
		}
		if c == ',' && depth == 0 {
			append(&items, strings.trim_space(body[item_start:i]))
			item_start = i + 1
		}
	}
	return items[:]
}

// sqlite_columns_from_sql extracts the column list of a CREATE TABLE statement.
// It is a small scanner, not a full parser: it reads each item's name, declared
// type and the NOT NULL / PRIMARY KEY flags.
sqlite_columns_from_sql :: proc(sql: string, alloc: mem.Allocator) -> []Sqlite_Column {
	columns := make([dynamic]Sqlite_Column, 0, 8, alloc)
	items := sqlite_table_items(sql, context.temp_allocator)
	for item in items {
		if column, ok := sqlite_parse_column(item, alloc); ok do append(&columns, column)
	}
	return columns[:]
}

// sqlite_constraints_from_sql reads the key clauses of a CREATE TABLE statement
// into the table it describes. A single-column table-level key becomes the
// column's own flag; anything wider stays a group, so an import can recreate it
// and the imported table refuses a duplicate (D33).
@(private)
sqlite_constraints_from_sql :: proc(sql: string, table: ^Sqlite_Table, alloc: mem.Allocator) {
	items := sqlite_table_items(sql, context.temp_allocator)
	position := 0
	for item in items {
		upper := strings.to_upper(item, context.temp_allocator)
		if column, is_column := sqlite_parse_column(item, context.temp_allocator); is_column {
			if position < len(table.columns) && sqlite_has_word(upper, "UNIQUE") &&
			   !column.primary_key {
				// A column-level UNIQUE names just that column: there is no list
				// to read, and an empty group would be written as UNIQUE ().
				group := make([]int, 1, alloc)
				group[0] = position
				append(&table.unique_groups, group)
				append(&table.key_order, group)
			} else if column.primary_key && (table.without_rowid || !sqlite_declared_integer(column.declared)) {
				// Owned by unique_groups so the destroy loop frees it once; the
				// import skips a group that repeats the column's key.
				group := make([]int, 1, alloc)
				group[0] = position
				append(&table.unique_groups, group)
				append(&table.key_order, group)
			}
			position += 1
			continue
		}
		primary := sqlite_has_word(upper, "PRIMARY")
		if !primary && !sqlite_has_word(upper, "UNIQUE") do continue
		positions := sqlite_group_key(upper, item, table.columns, alloc)
		if len(positions) == 0 {
			delete(positions, alloc)
			continue
		}
		// An INTEGER PRIMARY KEY in a rowid table is the rowid, and SQLite makes
		// no index for it, so it takes no automatic number.
		rowid_alias := primary && len(positions) == 1 && !table.without_rowid &&
			sqlite_declared_integer(table.columns[positions[0]].declared)
		if !rowid_alias do append(&table.key_order, positions)
		if primary {
			if len(positions) == 1 {
				table.columns[positions[0]].primary_key = true
				table.columns[positions[0]].not_null = true
				// The rowid's key went into no list: nothing else frees it.
				if rowid_alias do delete(positions, alloc)
			} else {
				table.primary_group = positions
			}
			continue
		}
		append(&table.unique_groups, positions)
	}
}

// sqlite_group_key maps the parenthesised column list that follows a key word to
// column positions.
@(private)
sqlite_group_key :: proc(upper, item: string, columns: []Sqlite_Column, alloc: mem.Allocator) -> []int {
	positions := make([dynamic]int, 0, 2, alloc)
	open := strings.index_rune(item, '(')
	if open < 0 do return positions[:]
	close := -1
	depth := 0
	in_quote: u8 = 0
	for i in open ..< len(item) {
		c := item[i]
		if in_quote != 0 {
			if c == in_quote do in_quote = 0
			continue
		}
		if c == '"' || c == '\'' || c == '`' || c == '[' {
			in_quote = c == '[' ? u8(']') : c
			continue
		}
		if c == '(' {
			depth += 1
			continue
		}
		if c == ')' {
			depth -= 1
			if depth == 0 {
				close = i
				break
			}
		}
	}
	if close < 0 do return positions[:]
	for part in strings.split(item[open + 1:close], ",", context.temp_allocator) {
		name := sqlite_unquote_ident(strings.trim_space(part))
		for column, i in columns {
			if strings.equal_fold(column.name, name) {
				append(&positions, i)
				break
			}
		}
	}
	return positions[:]
}

@(private)
sqlite_unquote_ident :: proc(text: string) -> string {
	if len(text) >= 2 {
		switch text[0] {
		case '"', '\'', '`':
			if text[len(text) - 1] == text[0] do return text[1:len(text) - 1]
		case '[':
			if text[len(text) - 1] == ']' do return text[1:len(text) - 1]
		}
	}
	return text
}

// sqlite_has_word looks for a keyword outside quoted text, so a DEFAULT holding
// the word does not count as the constraint.
@(private)
sqlite_declared_integer :: proc(declared: string) -> bool {
	return strings.equal_fold(strings.trim_space(declared), "INTEGER")
}

@(private)
sqlite_has_word :: proc(upper: string, word: string) -> bool {
	from := 0
	for {
		at := strings.index(upper[from:], word)
		if at < 0 do return false
		at += from
		before_ok := at == 0 || !sqlite_word_byte(upper[at - 1])
		after := at + len(word)
		after_ok := after >= len(upper) || !sqlite_word_byte(upper[after])
		if before_ok && after_ok do return true
		from = at + 1
	}
}

@(private)
sqlite_word_byte :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

@(private)
sqlite_parse_column :: proc(item: string, alloc: mem.Allocator) -> (Sqlite_Column, bool) {
	if len(item) == 0 do return {}, false
	upper := strings.to_upper(item, context.temp_allocator)
	// Table constraints are not columns.
	for prefix in ([]string{"CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"}) {
		if strings.has_prefix(upper, prefix) do return {}, false
	}
	// Column name: bare or quoted.
	name_end := 0
	quoted := false
	if item[0] == '"' || item[0] == '`' || item[0] == '\'' || item[0] == '[' {
		closing := item[0] == '[' ? u8(']') : item[0]
		name_end = strings.index_byte(item[1:], closing)
		if name_end < 0 do return {}, false
		name_end += 2
		quoted = true
	} else {
		for name_end < len(item) && !is_sqlite_space(item[name_end]) do name_end += 1
	}
	name := item[:name_end]
	if quoted do name = item[1:len(name) - 1]
	rest := strings.trim_space(item[name_end:])
	rest_upper := strings.to_upper(rest, context.temp_allocator)
	stop := len(rest)
	for marker in ([]string{"NOT NULL", "PRIMARY KEY", "UNIQUE", "DEFAULT", "CHECK", "COLLATE", "REFERENCES", "GENERATED", " AS "}) {
		if at := strings.index(rest_upper, marker); at >= 0 && at < stop do stop = at
	}
	declared := strings.trim_space(rest[:stop])
	column := Sqlite_Column {
		name        = strings.clone(name, alloc),
		declared    = strings.clone(declared, alloc),
		not_null    = strings.contains(rest_upper, "NOT NULL"),
		primary_key = strings.contains(rest_upper, "PRIMARY KEY"),
		autoincrement = sqlite_has_word(rest_upper, "AUTOINCREMENT"),
		inferred    = sqlite_affinity(declared),
	}
	return column, true
}

@(private)
is_sqlite_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// sqlite_affinity maps a declared type to SQLite's affinity rules, then to the
// nearest engine type.
sqlite_affinity :: proc(declared: string) -> Type_Kind {
	upper := strings.to_upper(declared, context.temp_allocator)
	if strings.contains(upper, "INT") do return .Int
	if strings.contains(upper, "CHAR") || strings.contains(upper, "CLOB") || strings.contains(upper, "TEXT") do return .String
	// A typeless column (or NUMERIC affinity) keeps the storage class it receives.
	if len(strings.trim_space(declared)) == 0 do return .Any
	// BLOB is SQLite's "no affinity": the column keeps whatever class it holds.
	if strings.contains(upper, "BLOB") do return .Any
	if strings.contains(upper, "REAL") || strings.contains(upper, "FLOA") || strings.contains(upper, "DOUB") do return .Float
	if strings.contains(upper, "NUM") do return .Any
	// Any other declared type behaves like NUMERIC affinity.
	return .Any
}

// sqlite_file_open reads a SQLite database into memory. `recover` is for a
// caller that owns the file and is about to write it: it makes a hot rollback
// journal win and then removes it, which is what recovery means. A plain reader
// leaves the journal on disk for whoever does own it.
sqlite_file_open :: proc(
	path: string,
	alloc := context.allocator,
	recover := false,
) -> (Sqlite_File, Error) {
	data, read_err := os.read_entire_file(path, alloc)
	if read_err != nil {
		return {}, errf(.Io, "cannot read %s: %v", path, read_err)
	}
	return sqlite_file_parse(data, path, alloc, recover, true)
}

// sqlite_file_from_bytes reads a database image held in memory, the bytes
// sqlite3_serialize hands out: there is no journal or log beside it. The
// bytes are copied.
sqlite_file_from_bytes :: proc(image: []u8, alloc := context.allocator) -> (Sqlite_File, Error) {
	data := make([]u8, len(image), alloc)
	copy(data, image)
	return sqlite_file_parse(data, "the database image", alloc, false, false)
}

// sqlite_file_parse reads a database image it owns. `side_files` says the
// image is a file, whose journal or write-ahead log is read through.
@(private)
sqlite_file_parse :: proc(
	data: []u8,
	path: string,
	alloc: mem.Allocator,
	recover: bool,
	side_files: bool,
) -> (Sqlite_File, Error) {
	if len(data) < SQLITE_HEADER_MIN {
		delete(data, alloc)
		return {}, errf(.Invalid_Argument, "%s is too short to be a SQLite database", path)
	}
	if string(data[:len(SQLITE_MAGIC)]) != SQLITE_MAGIC {
		delete(data, alloc)
		return {}, errf(.Invalid_Argument, "%s is not a SQLite database", path)
	}
	file := Sqlite_File{data = data, alloc = alloc}
	page_size := u32(sqlite_be16(data, 16))
	if page_size == 1 do page_size = 65536
	if page_size < 512 || page_size & (page_size - 1) != 0 {
		delete(data, alloc)
		return {}, errf(.Invalid_Argument, "%s has an invalid page size", path)
	}
	file.page_size = page_size
	reserved := u32(data[20])
	file.usable = page_size - reserved
	file.encoding = u32(sqlite_be32(data, 56))
	if side_files {
		// A hot rollback journal holds the pages the interrupted transaction
		// must restore, so it wins over the database file.
		journal_path := fmt.aprintf("%s-journal", path, allocator = alloc)
		defer delete(journal_path, alloc)
		sqlite_journal_rollback(&file, journal_path, recover)
		// A write-ahead log keeps the most recent commits out of the database
		// file.
		wal_path := fmt.aprintf("%s-wal", path, allocator = alloc)
		defer delete(wal_path, alloc)
		sqlite_wal_load(&file, wal_path)
	}
	if file.encoding != 0 && file.encoding != 1 {
		delete(data, alloc)
		return {}, errf(.Sql_Unsupported, "%s uses a non-UTF-8 text encoding", path)
	}
	// The lists become the file's, which sqlite_file_destroy frees with the
	// file's allocator: an empty [dynamic] would grow with the caller's
	// context.allocator instead, and a file read into a temporary allocator
	// left them behind.
	ctx := Sqlite_Master_Ctx {
		file    = &file,
		tables  = make([dynamic]Sqlite_Table, file.alloc),
		indexes = make([dynamic]Sqlite_Index, file.alloc),
		others  = make([dynamic]Sqlite_Object, file.alloc),
		trees   = make([dynamic]Sqlite_Index_Tree, file.alloc),
		catalog = make([dynamic]string, file.alloc),
	}
	if !sqlite_walk(&file, 1, true, sqlite_master_visit, &ctx, 0) {
		delete(data, alloc)
		return {}, errf(.Corrupt_Log, "%s has a malformed sqlite_master", path)
	}
	file.tables = ctx.tables[:]
	file.indexes = ctx.indexes[:]
	file.others = ctx.others[:]
	file.index_trees = ctx.trees[:]
	file.sequence_root = ctx.sequence_root
	file.catalog = ctx.catalog[:]
	return file, ERROR_NONE
}

sqlite_file_destroy :: proc(file: ^Sqlite_File) {
	for _, image in file.wal_pages do delete(image, file.alloc)
	delete(file.wal_pages)
	for &table in file.tables {
		delete(table.name, file.alloc)
		delete(table.sql, file.alloc)
		for column in table.columns {
			delete(column.name, file.alloc)
			delete(column.declared, file.alloc)
		}
		delete(table.columns, file.alloc)
		delete(table.primary_group, file.alloc)
		for group in table.unique_groups do delete(group, file.alloc)
		delete(table.unique_groups)
		// Every group in key_order is owned by unique_groups or primary_group, so
		// this frees the array and not the groups.
		delete(table.key_order)
	}
	for &index in file.indexes {
		delete(index.name, file.alloc)
		delete(index.table, file.alloc)
		delete(index.sql, file.alloc)
	}
	delete(file.indexes, file.alloc)
	for &object in file.others {
		delete(object.kind, file.alloc)
		delete(object.name, file.alloc)
		delete(object.table, file.alloc)
		delete(object.sql, file.alloc)
	}
	delete(file.others, file.alloc)
	for tree in file.index_trees {
		delete(tree.name, file.alloc)
		delete(tree.table, file.alloc)
	}
	delete(file.index_trees, file.alloc)
	for name in file.catalog do delete(name, file.alloc)
	delete(file.catalog, file.alloc)
	delete(file.tables, file.alloc)
	delete(file.data, file.alloc)
	file^ = {}
}

// sqlite_table_rows reads every row of one table in storage order. Values are
// allocated from `alloc`.
sqlite_table_rows :: proc(file: ^Sqlite_File, table: ^Sqlite_Table, alloc: mem.Allocator) -> ([][]Value, Error) {
	rows := make([dynamic][]Value, 0, 16, alloc)
	Ctx :: struct {
		file:  ^Sqlite_File,
		rows:  ^[dynamic][]Value,
		table: ^Sqlite_Table,
		alloc: mem.Allocator,
	}
	ctx := Ctx{file = file, rows = &rows, table = table, alloc = alloc}
	visit := proc(user: rawptr, rowid: i64, payload: []u8) -> bool {
		ctx := cast(^Ctx)user
		values, ok := sqlite_record(payload, ctx.alloc)
		if !ok do return true
		if ctx.table.without_rowid {
			// A WITHOUT ROWID record holds the key first: the columns go back
			// to the order the table declares them.
			declared := make([]Value, len(ctx.table.columns), ctx.alloc)
			for column, i in sqlite_storage_order(ctx.table, context.temp_allocator) {
				if i < len(values) {
					declared[column] = values[i]
					values[i] = {}
				}
			}
			for value in values do value_deep_free(value, ctx.alloc)
			delete(values, ctx.alloc)
			values = declared
		}
		if ctx.table.pk_position >= 0 && ctx.table.pk_position < len(values) {
			if values[ctx.table.pk_position].kind == .Null do values[ctx.table.pk_position] = value_int(rowid)
		}
		append(ctx.rows, values)
		return true
	}
	if !sqlite_walk(file, table.root_page, !table.without_rowid, visit, &ctx, 0) {
		return nil, errf(.Corrupt_Log, "table %s has a malformed b-tree", table.name)
	}
	return rows[:], ERROR_NONE
}

// sqlite_storage_order answers, for each field of a WITHOUT ROWID table's
// record, the declared column it holds: the primary key's columns in key
// order, then every other column in declaration order.
sqlite_storage_order :: proc(table: ^Sqlite_Table, alloc: mem.Allocator) -> []int {
	order := make([dynamic]int, 0, len(table.columns), alloc)
	in_key := make([]bool, len(table.columns), context.temp_allocator)
	if len(table.primary_group) > 0 {
		for column in table.primary_group {
			if column < 0 || column >= len(table.columns) || in_key[column] do continue
			in_key[column] = true
			append(&order, column)
		}
	} else {
		for column, i in table.columns {
			if column.primary_key {
				in_key[i] = true
				append(&order, i)
				break
			}
		}
	}
	for _, i in table.columns {
		if !in_key[i] do append(&order, i)
	}
	return order[:]
}

// sqlite_value_text renders a value the way the SQLite shell does in list mode.
sqlite_value_text :: proc(value: Value, alloc: mem.Allocator) -> string {
	#partial switch value.kind {
	case .Null:
		return strings.clone("", alloc)
	case .Int:
		return fmt.aprintf("%d", value.i, allocator = alloc)
	case .Uint:
		return fmt.aprintf("%d", value.u, allocator = alloc)
	case .Float:
		return sqlite_real_text(value.f, alloc)
	case .Bool:
		return strings.clone(value.b ? "1" : "0", alloc)
	case .String:
		return strings.clone(value.s, alloc)
	case .Bytes:
		return strings.clone(string(value.bytes), alloc)
	case:
		return value_format(value, alloc)
	}
}

// --- Import ----------------------------------------------------------------

// sqlite_import materialises the file into a store: one table per non-system
// table, with the schema inferred from the declared types and the rows inserted
// through the normal statement path so constraints apply.
// Declared_Rules is a file's CREATE TABLE as the engine's parser reads it; the
// import takes its DEFAULT and CHECK clauses.
Declared_Rules :: struct {
	query: Query,
	stmt:  Create_Table_Stmt,
}

@(private)
sqlite_declared_rules :: proc(sql: string) -> (Declared_Rules, bool) {
	if len(sql) == 0 do return {}, false
	query, err := sql_parse(sql)
	if err.kind != .None {
		error_free(&err)
		return {}, false
	}
	stmt, ok := query.statement.(Create_Table_Stmt)
	if !ok {
		query_destroy(&query)
		return {}, false
	}
	return Declared_Rules{query = query, stmt = stmt}, true
}

sqlite_import :: proc(
	file: ^Sqlite_File,
	store: ^Store,
	alloc := context.allocator,
) -> (tables: int, rows: int, err: Error) {
	// One write transaction: import is all-or-nothing and pays a single commit.
	tx := tx_begin_write(store)
	tables, rows, err = sqlite_import_tx(file, tx, alloc)
	if err.kind != .None {
		tx_rollback(tx)
		return
	}
	if commit_err := tx_commit(tx); commit_err.kind != .None {
		return tables, rows, commit_err
	}
	sqlite_import_finish(file, store)
	return tables, rows, ERROR_NONE
}

// sqlite_import_tx creates a file's tables, rows, indexes, views, triggers
// and header integers in the transaction. On an error the caller rolls the
// transaction back.
sqlite_import_tx :: proc(
	file: ^Sqlite_File,
	tx: ^Tx,
	alloc := context.allocator,
) -> (tables: int, rows: int, err: Error) {
	// A file's rows are SQLite's, written with its foreign keys off by
	// default, so the import does not enforce them.
	saved_keys := tx.store.foreign_keys_off
	tx.store.foreign_keys_off = true
	defer tx.store.foreign_keys_off = saved_keys
	// A table's parents come first, so its REFERENCES can be declared.
	created := make(map[string]bool, len(file.tables), context.temp_allocator)
	for at in sqlite_import_order(file) {
		table := &file.tables[at]
		if len(table.columns) == 0 do continue
		rows_of_table, rows_err := sqlite_table_rows(file, table, alloc)
		if rows_err.kind != .None do return tables, rows, rows_err
		// The rows are inserted through SQL, which copies them.
		defer {
			for row in rows_of_table {
				for value in row do value_deep_free(value, alloc)
				delete(row, alloc)
			}
			delete(rows_of_table, alloc)
		}
		sqlite_infer_columns(table, rows_of_table)
		create := strings.builder_make(alloc)
		defer strings.builder_destroy(&create)
		// The file's own declaration, read with the engine's parser, gives the
		// DEFAULT and CHECK clauses the inferred columns do not carry. A
		// declaration the parser cannot read imports without them, as before.
		declared, declared_ok := sqlite_declared_rules(table.sql)
		defer if declared_ok do query_destroy(&declared.query)
		strings.write_string(&create, "CREATE TABLE ")
		sqlite_write_ident(&create, table.name)
		strings.write_string(&create, " (")
		for column, i in table.columns {
			if i > 0 do strings.write_string(&create, ", ")
			sqlite_write_ident(&create, column.name)
			strings.write_byte(&create, ' ')
			strings.write_string(&create, column_type_name(Column_Type{kind = column.inferred}))
			if column.not_null do strings.write_string(&create, " NOT NULL")
			if declared_ok {
				for definition in declared.stmt.columns {
					if !strings.equal_fold(definition.name, column.name) do continue
					if len(definition.default_sql) > 0 {
						strings.write_string(&create, " DEFAULT (")
						strings.write_string(&create, definition.default_sql)
						strings.write_byte(&create, ')')
					}
					for check in definition.checks {
						if len(check.name) > 0 {
							strings.write_string(&create, " CONSTRAINT ")
							sqlite_write_ident(&create, check.name)
						}
						strings.write_string(&create, " CHECK (")
						strings.write_string(&create, check.sql)
						strings.write_byte(&create, ')')
					}
				}
			}
			// A text key is declared inline here even though the engine keeps it as
			// an index: the import only has to hand the engine a schema it accepts,
			// and an export writes the key as an index row (D33).
			if column.primary_key do strings.write_string(&create, " PRIMARY KEY")
			if column.primary_key && column.autoincrement && i == table.pk_position {
				strings.write_string(&create, " AUTOINCREMENT")
			}
		}
		// A key wider than one column, or a text key, is declared as a table
		// constraint: the engine keeps it as an index and enforces it, and an
		// export then carries it as an index row (D33).
		if len(table.primary_group) > 0 {
			strings.write_string(&create, ", PRIMARY KEY (")
			sqlite_write_group(&create, table, table.primary_group)
		}
		for group in table.unique_groups {
			if len(group) == 1 && table.columns[group[0]].primary_key do continue
			strings.write_string(&create, ", UNIQUE (")
			sqlite_write_group(&create, table, group)
		}
		if declared_ok {
			for constraint in declared.stmt.constraints {
				if !constraint.is_check do continue
				strings.write_string(&create, ", ")
				if len(constraint.name) > 0 {
					strings.write_string(&create, "CONSTRAINT ")
					sqlite_write_ident(&create, constraint.name)
					strings.write_byte(&create, ' ')
				}
				strings.write_string(&create, "CHECK (")
				strings.write_string(&create, constraint.check_sql)
				strings.write_byte(&create, ')')
			}
			// The foreign keys whose parent the import has made (or the table
			// itself); one naming a table the file lacks, or a cycle, is left
			// out.
			for constraint in declared.stmt.constraints {
				if !constraint.is_foreign do continue
				if !strings.equal_fold(constraint.ref_table, table.name) && !created[strings.to_lower(constraint.ref_table, context.temp_allocator)] do continue
				strings.write_string(&create, ", FOREIGN KEY (")
				for name, i in constraint.columns {
					if i > 0 do strings.write_string(&create, ", ")
					sqlite_write_ident(&create, name)
				}
				strings.write_string(&create, ") REFERENCES ")
				sqlite_write_ident(&create, constraint.ref_table)
				if len(constraint.ref_columns) > 0 {
					strings.write_string(&create, " (")
					for name, i in constraint.ref_columns {
						if i > 0 do strings.write_string(&create, ", ")
						sqlite_write_ident(&create, name)
					}
					strings.write_byte(&create, ')')
				}
				if constraint.on_delete == .Cascade do strings.write_string(&create, " ON DELETE CASCADE")
				if constraint.on_update == .Cascade do strings.write_string(&create, " ON UPDATE CASCADE")
				if constraint.deferred do strings.write_string(&create, " DEFERRABLE INITIALLY DEFERRED")
			}
		}
		strings.write_string(&create, ")")
		if table.without_rowid do strings.write_string(&create, " WITHOUT ROWID")
		created[strings.to_lower(table.name, context.temp_allocator)] = true
		if _, create_err := sql_execute_in_tx(tx, strings.to_string(create)); create_err.kind != .None {
			return tables, rows, create_err
		}
		// The table's text is the file's, as the program wrote it, not the
		// engine's rendering the import ran: PRAGMA table_info and the declared
		// types read it, and an ALTER edits it.
		if len(table.sql) > 0 {
			if text_err := sql_text_set(tx, table.name, table.sql); text_err.kind != .None do return tables, rows, text_err
		}
		tables += 1
		insert := strings.builder_make(alloc)
		defer strings.builder_destroy(&insert)
		strings.write_string(&insert, "INSERT INTO ")
		sqlite_write_ident(&insert, table.name)
		strings.write_string(&insert, " (")
		for column, i in table.columns {
			if i > 0 do strings.write_string(&insert, ", ")
			sqlite_write_ident(&insert, column.name)
		}
		strings.write_string(&insert, ") VALUES (")
		for i in 0 ..< len(table.columns) {
			if i > 0 do strings.write_string(&insert, ", ")
			strings.write_string(&insert, "?")
		}
		strings.write_string(&insert, ")")
		for row in rows_of_table {
			values := make([]Value, len(table.columns), context.temp_allocator)
			copy(values, row)
			if _, insert_err := sql_execute_in_tx_params(tx, strings.to_string(insert), values); insert_err.kind != .None {
				return tables, rows, insert_err
			}
			rows += 1
		}
	}
	// Secondary indexes, in the order the file lists them. SQLite's own CREATE
	// INDEX statement is run as it stands, so a unique or multi-column index keeps
	// its shape. An index this engine cannot express (a partial index, an
	// expression index) is retried without the WHERE clause, and if that also
	// fails it is left out rather than failing the import: the data is the point,
	// the access path is an optimisation.
	for index in file.indexes {
		if len(index.sql) == 0 do continue
		if _, create_err := sql_execute_in_tx(tx, index.sql); create_err.kind == .None do continue
		if plain, ok := sqlite_index_without_where(index.sql, context.temp_allocator); ok {
			discarded_21, discarded_21_err := sql_execute_in_tx(tx, plain)
			sql_result_destroy(&discarded_21)
			error_free(&discarded_21_err)
		}
	}
	// The views, then the triggers (an INSTEAD OF trigger needs its view), as
	// the file wrote them. One this engine cannot read stays text the file
	// keeps (D27), as every view and trigger did before.
	for kind in ([]string{"view", "trigger"}) {
		for object in file.others {
			if !strings.equal_fold(object.kind, kind) do continue
			created, create_err := sql_execute_in_tx(tx, object.sql)
			if create_err.kind != .None {
				error_free(&create_err)
				continue
			}
			sql_result_destroy(&created)
		}
	}
	if order_err := sqlite_import_text_order(file, tx); order_err.kind != .None do return tables, rows, order_err
	// The page size the file was written with, so writing it back keeps it.
	if int(file.page_size) != SQLITE_WRITE_PAGE_SIZE && sqlite_page_size_valid(int(file.page_size)) {
		if size_err := header_set(tx, "page_size", i64(file.page_size)); size_err.kind != .None {
			return tables, rows, size_err
		}
	}
	// The integers SQLite keeps in the header for the program.
	page_one := sqlite_page(file, 1)
	if len(page_one) >= 72 {
		for name, offset in ([2]string{"user_version", "application_id"}) {
			at := offset == 0 ? 60 : 68
			value := i64(i32(sqlite_be32(page_one, at)))
			if value == 0 do continue
			if header_err := header_set(tx, name, value); header_err.kind != .None {
				return tables, rows, header_err
			}
		}
	}
	return tables, rows, ERROR_NONE
}

// sqlite_import_finish does what has to wait for the import's commit: the
// AUTOINCREMENT counters, and the catalog text a mirror rewrite keeps.
sqlite_import_finish :: proc(file: ^Sqlite_File, store: ^Store) {
	// sqlite_sequence remembers the last rowid each AUTOINCREMENT table gave
	// out, which may be above every rowid left in the table.
	if file.sequence_root != 0 {
		sequence := Sqlite_Table{name = "sqlite_sequence", root_page = file.sequence_root, pk_position = -1}
		if counters, counters_err := sqlite_table_rows(file, &sequence, context.temp_allocator); counters_err.kind == .None {
			for counter in counters {
				if len(counter) < 2 || counter[0].kind != .String || counter[1].kind != .Int do continue
				table, found := store.tables[counter[0].s]
				if !found || table.schema.auto_increment_column < 0 do continue
				if counter[1].i + 1 > table.next_sequence do table.next_sequence = counter[1].i + 1
			}
		} else {
			error_free(&counters_err)
		}
	}
	// Remember the catalog the file spelled, now that the tables exist in the
	// store: a rewrite re-emits it for every object it does not change (D27).
	store_mirror_keep(store, file)
}

// sqlite_import_text_order stores the catalog's texts again in the order
// sqlite_master has them: the import makes the tables first and the indexes,
// views and triggers after, but SQLite lists what was made in the order it
// was made, and the row a text has is that order (sqlite_schema_order).
@(private)
sqlite_import_text_order :: proc(file: ^Sqlite_File, tx: ^Tx) -> Error {
	texts := tx_sql_texts(tx, context.temp_allocator)
	if len(texts) == 0 do return ERROR_NONE
	names := make([dynamic]string, 0, len(texts), context.temp_allocator)
	for name in file.catalog do if name in texts do append(&names, name)
	rest := make([dynamic]string, 0, len(texts), context.temp_allocator)
	for name in texts do if !slice.contains(names[:], name) do append(&rest, name)
	slice.sort(rest[:])
	append(&names, ..rest[:])
	for name in names do if err := sql_text_forget(tx, name); err.kind != .None do return err
	for name in names do if err := sql_text_set(tx, name, texts[name]); err.kind != .None do return err
	return ERROR_NONE
}

// sqlite_import_order lists the file's tables so that a table comes after the
// tables its REFERENCES name; a cycle keeps the file's order for what is left.
@(private)
sqlite_import_order :: proc(file: ^Sqlite_File) -> []int {
	parents := make([][]string, len(file.tables), context.temp_allocator)
	for &table, i in file.tables {
		declared, ok := sqlite_declared_rules(table.sql)
		if !ok do continue
		names := make([dynamic]string, 0, 2, context.temp_allocator)
		for constraint in declared.stmt.constraints {
			if constraint.is_foreign && !strings.equal_fold(constraint.ref_table, table.name) {
				append(&names, strings.to_lower(constraint.ref_table, context.temp_allocator))
			}
		}
		query_destroy(&declared.query)
		parents[i] = names[:]
	}
	present := make(map[string]bool, len(file.tables), context.temp_allocator)
	for table in file.tables do present[strings.to_lower(table.name, context.temp_allocator)] = true
	order := make([dynamic]int, 0, len(file.tables), context.temp_allocator)
	placed := make([]bool, len(file.tables), context.temp_allocator)
	done := make(map[string]bool, len(file.tables), context.temp_allocator)
	for len(order) < len(file.tables) {
		progress := false
		for &table, i in file.tables {
			if placed[i] do continue
			ready := true
			for parent in parents[i] {
				if present[parent] && !done[parent] do ready = false
			}
			if !ready do continue
			placed[i] = true
			done[strings.to_lower(table.name, context.temp_allocator)] = true
			append(&order, i)
			progress = true
		}
		if progress do continue
		// A cycle: the next table in the file's order goes first.
		for &table, i in file.tables {
			if placed[i] do continue
			placed[i] = true
			done[strings.to_lower(table.name, context.temp_allocator)] = true
			append(&order, i)
			break
		}
	}
	return order[:]
}

@(private)
sqlite_write_group :: proc(builder: ^strings.Builder, table: ^Sqlite_Table, group: []int) {
	for position, i in group {
		if i > 0 do strings.write_string(builder, ", ")
		if position >= 0 && position < len(table.columns) {
			sqlite_write_ident(builder, table.columns[position].name)
		}
	}
	strings.write_byte(builder, ')')
}

// sqlite_index_without_where drops a trailing WHERE clause, which is what makes
// a partial index partial. Everything up to it is a CREATE INDEX this engine
// understands.
@(private)
sqlite_index_without_where :: proc(sql: string, alloc: mem.Allocator) -> (string, bool) {
	upper := strings.to_upper(sql, context.temp_allocator)
	at := strings.index(upper, " WHERE ")
	if at < 0 do return "", false
	return strings.trim_space(sql[:at]), true
}

@(private)
sqlite_write_ident :: proc(builder: ^strings.Builder, name: string) {
	strings.write_byte(builder, '"')
	strings.write_string(builder, name)
	strings.write_byte(builder, '"')
}

// sqlite_infer_columns narrows a declared type that does not decide the engine
// type (NUMERIC, empty) by looking at the rows actually present.
@(private)
sqlite_infer_columns :: proc(table: ^Sqlite_Table, rows: [][]Value) {
	for &column, i in table.columns {
		if column.inferred != .Float do continue
		_ = i
		if strings.contains(strings.to_upper(column.declared, context.temp_allocator), "NUM") == false &&
		   len(strings.trim_space(column.declared)) != 0 {
			continue
		}
		seen_int := false
		seen_float := false
		seen_text := false
		for row in rows {
			if i >= len(row) do continue
			#partial switch row[i].kind {
			case .Int, .Bool:
				seen_int = true
			case .Float:
				seen_float = true
			case .String:
				seen_text = true
			case:
			}
		}
		switch {
		case seen_text:
			column.inferred = .String
		case seen_float:
			column.inferred = .Float
		case seen_int:
			column.inferred = .Int
		}
	}
}

// sqlite_real_text renders a real as SQLite 3.54's text form does: printf's
// `%!.17g` with SQLite's own decimal conversion (sqlite_fp.odin), which keeps
// up to 17 significant digits but stops at fewer when they already read back
// as the same double (0.1 is "0.1", 0.1 + 0.2 is "0.30000000000000004"), and
// keeps a ".0" on a whole number (1.0, 1.0e+20). An infinity is "Inf" or
// "-Inf", and zero prints without its sign.
sqlite_real_text :: proc(f: f64, alloc: mem.Allocator) -> string {
	if f != f do return strings.clone("NaN", alloc)
	text, _, _ := sqlite_format_double('g', f, 0, false, false, true, false, 17, context.temp_allocator)
	return strings.clone(string(text), alloc)
}
