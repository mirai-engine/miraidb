package engine

import "core:strings"

// The catalog is a cache of the table schemas, written next to the page files so
// a store whose pages are current can open without replaying the log.
//
// The log is the truth and it is the only place a schema is created: a commit
// that creates a table writes its Create_Table record, and replay is what builds
// the catalog on an ordinary open. Reading the schemas back out of the log is
// the expensive half of opening a large database, though (every record has to be
// walked to find them), and the page files already hold every row. So the store
// keeps this file: the schemas plus the counters that are not derivable from a
// page file cheaply, all at one sequence.
//
// It is a cache with a proof attached. The file is valid only when its checksum
// holds and its sequence is exactly the one the log ends at, and each page file
// carries the same sequence in its own header. If any of that is off — a commit
// landed after the catalog was written, a page file is stale, a crash tore the
// write — the store discards the page files and replays, which is what it did
// before this file existed.
//
// Layout:
//
//	header  32 bytes: "MRCT" | u32 version | u64 commit_seq | u64 payload_len | u32 crc32c | u32 flags
//	payload        : u32 count | count * entry
//	entry          : string name | schema_encode | u64 next_row_id | i64 next_sequence | i64 next_int_key
//
// The payload is written before the header, so a torn write leaves a header that
// describes a payload that is not there, and the checksum rejects it.
CATALOG_MAGIC :: "MRCT"
CATALOG_VERSION :: u32(1)
CATALOG_HEADER_LEN :: 32

// Catalog_Entry is one table as the catalog remembers it: the schema the log
// would have replayed, plus the counters a page file does not carry.
Catalog_Entry :: struct {
	schema:        Table_Schema,
	next_row_id:   u64,
	next_sequence: i64,
	next_int_key:  i64,
}

store_catalog_path :: proc(store: ^Store) -> string {
	return strings.concatenate({store.path, "/catalog"})
}

// catalog_covers_everything is true when a page file backs every table, which is
// the condition for opening the catalog instead of replaying the log: a table
// without a page file keeps its rows nowhere else.
@(private)
catalog_covers_everything :: proc(store: ^Store) -> bool {
	for _, table in store.tables {
		if table.paged == nil do return false
	}
	return true
}

// catalog_encode serializes every table of the store at `seq`, header included.
// The caller owns the buffer.
catalog_encode :: proc(store: ^Store, seq: u64) -> []u8 {
	names := map_keys_sorted(store.tables)
	defer delete(names)
	payload: Byte_Writer
	bw_init(&payload)
	bw_write_u32(&payload, u32(len(names)))
	for name in names {
		table := store.tables[name]
		bw_write_string(&payload, table.schema.name)
		schema_encode(&payload, &table.schema)
		bw_write_u64(&payload, table.next_row_id)
		bw_write_u64(&payload, u64(table.next_sequence))
		bw_write_u64(&payload, u64(table.next_int_key))
	}
	body := bw_bytes(&payload)
	out := make([]u8, CATALOG_HEADER_LEN + len(body))
	copy(out[:4], CATALOG_MAGIC)
	put_u32_le(out[4:8], CATALOG_VERSION)
	put_u64_le(out[8:16], seq)
	put_u64_le(out[16:24], u64(len(body)))
	put_u32_le(out[24:28], crc32c(body))
	// Bit 0 promises the page files hold the whole state: every table here is
	// paged, so nothing is missing that only the log could supply. A catalog that
	// names an in-memory table (a `_`-prefixed one, which paging skips) is not
	// trustworthy on its own and the store replays instead.
	flags := u32(0)
	if catalog_covers_everything(store) do flags |= 1
	put_u32_le(out[28:32], flags)
	copy(out[CATALOG_HEADER_LEN:], body)
	bw_destroy(&payload)
	return out
}

// catalog_write replaces the catalog with the state at `seq`. It is a cache, so
// a failure is reported and never fails the commit that earned it: the log
// already holds the change and the next open replays.
catalog_write :: proc(store: ^Store, seq: u64) -> Error {
	if store == nil || !store.persistent do return ERROR_NONE
	path := store_catalog_path(store)
	defer delete(path)
	data := catalog_encode(store, seq)
	defer delete(data)
	file, open_err := log_file_open(store.vfs, path, {.Read, .Write, .Create, .Trunc})
	if open_err.kind != .None {
		return errf(.Io, "cannot write %s: %v", path, open_err.message)
	}
	defer log_file_close(file)
	if _, write_err := log_file_write(file, data); write_err.kind != .None {
		return errf(.Io, "cannot write %s: %v", path, write_err.message)
	}
	// Durable after the pages, so a catalog that names a sequence never claims a
	// page file the disk does not have.
	if store.log.durability != .None {
		if sync_err := log_file_sync(file); sync_err.kind != .None {
			return errf(.Io, "cannot sync %s: %v", path, sync_err.message)
		}
	}
	return ERROR_NONE
}

// catalog_read returns the catalog when it validates: magic, version, length and
// checksum. It says nothing about whether the page files agree with it; that is
// the caller's check.
catalog_read :: proc(store: ^Store) -> (seq: u64, entries: []Catalog_Entry, ok: bool) {
	path := store_catalog_path(store)
	defer delete(path)
	file, open_err := log_file_open(store.vfs, path, {.Read})
	if open_err.kind != .None do return 0, nil, false
	defer log_file_close(file)
	size := log_file_size(file)
	if size < CATALOG_HEADER_LEN do return 0, nil, false
	header: [CATALOG_HEADER_LEN]u8
	n, read_err := log_file_read(file, header[:])
	if read_err.kind != .None || n != CATALOG_HEADER_LEN do return 0, nil, false
	if string(header[:4]) != CATALOG_MAGIC do return 0, nil, false
	if get_u32_le(header[4:8]) != CATALOG_VERSION do return 0, nil, false
	seq = get_u64_le(header[8:16])
	length := int(get_u64_le(header[16:24]))
	if length < 4 || i64(CATALOG_HEADER_LEN + length) > size do return 0, nil, false
	body := make([]u8, length)
	defer delete(body)
	got, body_err := log_file_read(file, body)
	if body_err.kind != .None || got != length do return 0, nil, false
	if crc32c(body) != get_u32_le(header[24:28]) do return 0, nil, false
	if get_u32_le(header[28:32]) & 1 == 0 do return 0, nil, false
	r: Byte_Reader
	br_init(&r, body)
	count := int(br_read_u32(&r))
	if r.bad || count < 0 || count > length do return 0, nil, false
	entries = make([]Catalog_Entry, count)
	for i in 0 ..< count {
		name := br_read_string(&r, context.allocator)
		if r.bad {
			catalog_entries_destroy(entries[:i])
			return 0, nil, false
		}
		schema := schema_decode(&r, context.allocator)
		if r.bad || schema.name != name {
			delete(name)
			schema_destroy(&schema, context.allocator)
			catalog_entries_destroy(entries[:i])
			return 0, nil, false
		}
		// schema_decode owns its own copy of the name and the columns; the extra
		// name is redundant, so it goes before it leaks.
		delete(name)
		entries[i] = Catalog_Entry {
			schema        = schema,
			next_row_id   = br_read_u64(&r),
			next_sequence = i64(br_read_u64(&r)),
			next_int_key  = i64(br_read_u64(&r)),
		}
		if r.bad {
			catalog_entries_destroy(entries[:i + 1])
			return 0, nil, false
		}
	}
	return seq, entries, true
}

catalog_entries_destroy :: proc(entries: []Catalog_Entry) {
	for &entry in entries do schema_destroy(&entry.schema, context.allocator)
	delete(entries)
}
