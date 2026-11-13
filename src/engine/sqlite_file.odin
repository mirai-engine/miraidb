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
import "core:strings"

SQLITE_MAGIC :: "SQLite format 3\x00"

// Sqlite_Column is one column as declared in sqlite_master.
Sqlite_Column :: struct {
	name:        string,
	declared:    string,
	not_null:    bool,
	primary_key: bool,
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
}

// Sqlite_File is an open SQLite database image held in memory.
Sqlite_File :: struct {
	data:      []u8,
	page_size: u32,
	usable:    u32,
	encoding:  u32,
	tables:    []Sqlite_Table,
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
		for i in 0 ..< cell_count {
			at := header + i * 2
			if at + 2 > len(page) do return false
			pointer := int(sqlite_be16(page, at))
			if pointer + 4 > len(page) do return false
			child := sqlite_be32(page, pointer)
			if !sqlite_walk(file, child, table, visit, user, depth + 1) do return false
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
	file:   ^Sqlite_File,
	tables: [dynamic]Sqlite_Table,
}

@(private)
sqlite_master_visit :: proc(user: rawptr, rowid: i64, payload: []u8) -> bool {
	ctx := cast(^Sqlite_Master_Ctx)user
	values, ok := sqlite_record(payload, ctx.file.alloc)
	if !ok || len(values) < 5 do return true
	kind := values[0]
	name := values[1]
	sql := values[4]
	if kind.kind != .String || !strings.equal_fold(kind.s, "table") do return true
	if name.kind != .String do return true
	if strings.has_prefix(name.s, "sqlite_") do return true
	table := Sqlite_Table {
		name      = strings.clone(name.s, ctx.file.alloc),
		root_page = u32(values[3].i),
		sql       = sql.kind == .String ? strings.clone(sql.s, ctx.file.alloc) : "",
		columns   = sqlite_columns_from_sql(sql.kind == .String ? sql.s : "", ctx.file.alloc),
	}
	table.without_rowid = sqlite_contains_word(table.sql, "WITHOUT ROWID")
	for column, i in table.columns {
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

// sqlite_columns_from_sql extracts the column list of a CREATE TABLE statement.
// It is a small scanner, not a full parser: it splits the top-level parenthesised
// list on commas, then reads each item's name, declared type and the NOT NULL /
// PRIMARY KEY flags.
sqlite_columns_from_sql :: proc(sql: string, alloc: mem.Allocator) -> []Sqlite_Column {
	columns := make([dynamic]Sqlite_Column, 0, 8, alloc)
	open := strings.index_rune(sql, '(')
	if open < 0 do return columns[:]
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
	if end < 0 do return columns[:]
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
			item := strings.trim_space(body[item_start:i])
			item_start = i + 1
			if column, ok := sqlite_parse_column(item, alloc); ok do append(&columns, column)
		}
	}
	return columns[:]
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
	if strings.contains(upper, "BLOB") do return .Bytes
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
	// A hot rollback journal holds the pages the interrupted transaction must
	// restore, so it wins over the database file.
	journal_path := fmt.aprintf("%s-journal", path, allocator = alloc)
	defer delete(journal_path, alloc)
	sqlite_journal_rollback(&file, journal_path, recover)
	// A write-ahead log keeps the most recent commits out of the database file.
	wal_path := fmt.aprintf("%s-wal", path, allocator = alloc)
	defer delete(wal_path, alloc)
	sqlite_wal_load(&file, wal_path)
	if file.encoding != 0 && file.encoding != 1 {
		delete(data, alloc)
		return {}, errf(.Sql_Unsupported, "%s uses a non-UTF-8 text encoding", path)
	}
	ctx := Sqlite_Master_Ctx{file = &file}
	if !sqlite_walk(&file, 1, true, sqlite_master_visit, &ctx, 0) {
		delete(data, alloc)
		return {}, errf(.Corrupt_Log, "%s has a malformed sqlite_master", path)
	}
	file.tables = ctx.tables[:]
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
	}
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
		return fmt.aprintf("%g", value.f, allocator = alloc)
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
sqlite_import :: proc(file: ^Sqlite_File, store: ^Store, alloc := context.allocator) -> (tables: int, rows: int, err: Error) {
	// One write transaction: import is all-or-nothing and pays a single commit.
	tx := tx_begin_write(store)
	for &table in file.tables {
		if len(table.columns) == 0 do continue
		rows_of_table, rows_err := sqlite_table_rows(file, &table, alloc)
		if rows_err.kind != .None do return tables, rows, rows_err
		sqlite_infer_columns(&table, rows_of_table)
		create := strings.builder_make(alloc)
		defer strings.builder_destroy(&create)
		strings.write_string(&create, "CREATE TABLE ")
		sqlite_write_ident(&create, table.name)
		strings.write_string(&create, " (")
		for column, i in table.columns {
			if i > 0 do strings.write_string(&create, ", ")
			sqlite_write_ident(&create, column.name)
			strings.write_byte(&create, ' ')
			strings.write_string(&create, column_type_name(Column_Type{kind = column.inferred}))
			if column.not_null do strings.write_string(&create, " NOT NULL")
			if i == table.pk_position do strings.write_string(&create, " PRIMARY KEY")
		}
		strings.write_string(&create, ")")
		if _, create_err := sql_execute_in_tx(tx, strings.to_string(create)); create_err.kind != .None {
			tx_rollback(tx)
			return tables, rows, create_err
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
				tx_rollback(tx)
				return tables, rows, insert_err
			}
			rows += 1
		}
	}
	if commit_err := tx_commit(tx); commit_err.kind != .None {
		return tables, rows, commit_err
	}
	return tables, rows, ERROR_NONE
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
