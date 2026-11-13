package engine

import "core:slice"
import "core:strings"
import "core:sync"

// Statistics are what a plan needs to know about the data instead of guessing:
// how many rows a table holds, how many distinct values each column has and how
// many of them are NULL. ANALYZE measures them once, a plan reads them, and
// `<db>/stats` keeps them so an open does not have to measure again.
//
// They are a cache and never a source of truth. No query answer depends on them:
// a missing, stale or unreadable file only means the planner falls back to what
// it did before it had statistics (estimate the table's full row count), and a
// table whose statistics are older than its rows is still correct to read, just
// planned from older numbers.
//
// File layout:
//
//	header  32 B: "MRST" | u32 version | u64 analyzed_seq | u64 payload_len | u32 crc32c | u32 reserved
//	payload      : u32 count | count * table
//	table        : string name | u64 rows | u32 columns | columns * {u64 distinct_count, u64 nulls, u8 saturated}
STATS_FILE_MAGIC :: "MRST"
STATS_FILE_VERSION :: u32(2)
STATS_FILE_HEADER_LEN :: 32

// STATS_DISTINCT_CAP bounds the set ANALYZE builds per column. Past it the count
// stops growing and the column is marked saturated, which a plan reads as "at
// least this many", never as an answer.
STATS_DISTINCT_CAP :: 20_000

// Column_Stats is what one pass over a column remembers.
Column_Stats :: struct {
	// distinct_count is how many different non-null values the column held. The
	// name avoids `distinct`, which Odin keeps as a keyword.
	distinct_count: u64,
	nulls:          u64,
	saturated:      bool,
}

// Table_Stats is the measured shape of one table. The columns slice belongs to
// the store, so a caller must not free it.
Table_Stats :: struct {
	rows:    u64,
	columns: []Column_Stats,
}

// stats_analyze measures every table (or one, when `only` is set) and stores the
// result. It measures through a read transaction, which is what makes it see one
// state without holding the store lock for the whole scan, and then takes the
// write lock only to install the numbers and write the file.
stats_analyze :: proc(store: ^Store, only: string) -> (count: int, err: Error) {
	names := store_table_names(store, context.allocator)
	defer delete(names)
	slice.sort(names)
	measured: map[string]Table_Stats
	// The store owns the columns and the keys once they are installed, so the
	// cleanup below must not free what it handed over.
	installed := false
	defer {
		if !installed {
			for name, stats in measured {
				delete(stats.columns)
				delete(name)
			}
		}
		delete(measured)
	}
	tx := tx_begin_read(store)
	for name in names {
		if len(only) > 0 && !strings.equal_fold(name, only) do continue
		if strings.has_prefix(name, "_") do continue
		table, table_err := tx_table(tx, name)
		if table_err.kind != .None {
			tx_end(tx)
			return 0, table_err
		}
		stats, stats_err := stats_measure_table(tx, table)
		if stats_err.kind != .None {
			tx_end(tx)
			return 0, stats_err
		}
		measured[strings.clone(name)] = stats
	}
	tx_end(tx)
	if len(measured) == 0 && len(only) > 0 {
		return 0, errf(.Table_Not_Found, "table %s does not exist", only)
	}
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	for name, stats in measured {
		stats_store_put(store, name, stats)
	}
	installed = true
	// A table that is gone must not keep a stale entry the planner would use.
	if len(only) == 0 {
		for name in store.stats {
			if _, exists := store.tables[name]; !exists do stats_remove(store, name)
		}
	}
	store.stats_seq = store.commit_seq
	count = len(store.stats)
	if save_err := stats_save(store); save_err.kind != .None {
		store.last_error = save_err
	}
	return count, ERROR_NONE
}

@(private)
stats_measure_table :: proc(tx: ^Tx, table: ^Table) -> (Table_Stats, Error) {
	columns := make([]Column_Stats, len(table.schema.columns))
	rows := make([dynamic]Row)
	if collect_err := tx_collect(tx, table.schema.name, &rows); collect_err.kind != .None {
		delete(columns)
		return {}, collect_err
	}
	defer delete(rows)
	// One set per column, filled in the same pass. They live only for this call;
	// the counts are what survives.
	sets := make([]map[string]bool, len(columns))
	defer {
		for set in sets do delete(set)
		delete(sets)
	}
	for i in 0 ..< len(sets) do sets[i] = make(map[string]bool)
	for row in rows {
		for column, i in row.values {
			if i >= len(columns) do break
			if column.kind == .Null {
				columns[i].nulls += 1
				continue
			}
			if columns[i].saturated do continue
			key := value_key_bytes(column)
			if _, seen := sets[i][string(key)]; !seen {
				if len(sets[i]) >= STATS_DISTINCT_CAP {
					columns[i].saturated = true
					delete(key)
					continue
				}
				sets[i][strings.clone(string(key))] = true
				columns[i].distinct_count += 1
			}
			delete(key)
		}
	}
	return Table_Stats{rows = u64(len(rows)), columns = columns}, ERROR_NONE
}

// stats_estimate_rows predicts how many of a table's rows a predicate keeps.
// Without statistics it returns the row count, which is the assumption a plan
// made before any of this existed. A predicate with no recognizable conjunct
// keeps everything for the same reason.
stats_estimate_rows :: proc(store: ^Store, table: ^Table, predicate: ^Expr) -> u64 {
	total := u64(table_row_count(table))
	stats, has_stats := stats_get(store, table.schema.name)
	if has_stats do total = stats.rows
	if predicate == nil || !has_stats || stats.rows == 0 do return total
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	estimate := f64(stats.rows)
	for expr in conjuncts {
		if estimate <= 1 do break
		qualifier, column_name, op, ok := comparison_details(expr)
		if !ok do continue
		if len(qualifier) > 0 && !strings.equal_fold(qualifier, table.schema.name) do continue
		column_index, found := schema_column_index(&table.schema, column_name)
		if !found || column_index >= len(stats.columns) do continue
		column := stats.columns[column_index]
		fraction: f64
		switch {
		case op == .Eq:
			// An equality keeps one of the distinct values, or everything when the
			// column holds a single one.
			distinct_count := max(column.distinct_count, 1)
			fraction = 1 / f64(distinct_count)
			if column.nulls > 0 {
				fraction = 1 / f64(distinct_count + 1)
			}
		case op == .Lt, op == .Le, op == .Gt, op == .Ge:
			// Half-open ranges have no histogram to read, so this is the classic
			// one-third rule: it is a guess and it says so.
			fraction = 1.0 / 3.0
		case:
			continue
		}
		estimate *= fraction
	}
	return u64(max(estimate, 1.0))
}

// stats_selective reports whether an index over `column` is worth using: a
// lookup that keeps most of the table costs more than the scan it replaces,
// because the ids have to be collected first. Only statistics can answer this,
// so a table without them keeps using the index as it always did.
stats_selective :: proc(store: ^Store, table: ^Table, column: int) -> bool {
	stats, has_stats := stats_get(store, table.schema.name)
	if !has_stats || stats.rows == 0 || column >= len(stats.columns) do return true
	distinct_count := max(stats.columns[column].distinct_count, 1)
	// An equality keeps about rows/distinct rows. With four distinct values that
	// is a quarter of the table, which is where the probe stops paying: the ids
	// have to be collected first, and half a table of ids costs more than reading
	// the rows. Fewer than four distinct values therefore means a scan.
	return distinct_count >= 4
}

// --- Storage ---------------------------------------------------------------

stats_get :: proc(store: ^Store, name: string) -> (Table_Stats, bool) {
	stats, found := store.stats[name]
	return stats, found
}

@(private)
stats_store_put :: proc(store: ^Store, name: string, stats: Table_Stats) {
	if old, exists := store.stats[name]; exists {
		delete(old.columns)
	}
	key := name
	if _, exists := store.stats[name]; !exists do key = strings.clone(name)
	store.stats[key] = stats
}

@(private)
stats_remove :: proc(store: ^Store, name: string) {
	old, exists := store.stats[name]
	if !exists do return
	delete(old.columns)
	// The map owns the key string and `delete_key` only hands back the value, so
	// the key is left to stats_destroy. One small string per dropped table is a
	// cheaper answer than a second index of owned names.
	delete_key(&store.stats, name)
}

// stats_forget drops the statistics of one table, which is what a DROP TABLE
// owes the planner: a plan built from a table that is gone would be wrong.
stats_forget :: proc(store: ^Store, name: string) {
	stats_remove(store, name)
}

stats_destroy :: proc(store: ^Store) {
	for name, stats in store.stats {
		delete(stats.columns)
		delete(name)
	}
	delete(store.stats)
	store.stats = nil
}

@(private)
stats_save :: proc(store: ^Store) -> Error {
	if store == nil || !store.persistent do return ERROR_NONE
	path := store_stats_path(store)
	defer delete(path)
	names := map_keys_sorted(store.stats)
	defer delete(names)
	payload: Byte_Writer
	bw_init(&payload)
	bw_write_u32(&payload, u32(len(names)))
	for name in names {
		stats := store.stats[name]
		bw_write_string(&payload, name)
		bw_write_u64(&payload, stats.rows)
		bw_write_u32(&payload, u32(len(stats.columns)))
		for column in stats.columns {
			bw_write_u64(&payload, column.distinct_count)
			bw_write_u64(&payload, column.nulls)
			bw_write_u8(&payload, u8(1) if column.saturated else u8(0))
		}
	}
	body := bw_bytes(&payload)
	out := make([]u8, STATS_FILE_HEADER_LEN + len(body))
	copy(out[:4], STATS_FILE_MAGIC)
	put_u32_le(out[4:8], STATS_FILE_VERSION)
	put_u64_le(out[8:16], store.stats_seq)
	put_u64_le(out[16:24], u64(len(body)))
	put_u32_le(out[24:28], crc32c(body))
	put_u32_le(out[28:32], 0)
	copy(out[STATS_FILE_HEADER_LEN:], body)
	bw_destroy(&payload)
	defer delete(out)
	file, open_err := log_file_open(store.vfs, path, {.Read, .Write, .Create, .Trunc})
	if open_err.kind != .None {
		return errf(.Io, "cannot write %s: %v", path, open_err.message)
	}
	defer log_file_close(file)
	if _, write_err := log_file_write(file, out); write_err.kind != .None {
		return errf(.Io, "cannot write %s: %v", path, write_err.message)
	}
	return ERROR_NONE
}

// stats_load reads the statistics file when it validates. It never reports an
// error: a cache that cannot be read just leaves the planner without numbers.
stats_load :: proc(store: ^Store) {
	path := store_stats_path(store)
	defer delete(path)
	file, open_err := log_file_open(store.vfs, path, {.Read})
	if open_err.kind != .None do return
	defer log_file_close(file)
	size := log_file_size(file)
	if size < STATS_FILE_HEADER_LEN do return
	header: [STATS_FILE_HEADER_LEN]u8
	n, read_err := log_file_read(file, header[:])
	if read_err.kind != .None || n != STATS_FILE_HEADER_LEN do return
	if string(header[:4]) != STATS_FILE_MAGIC do return
	if get_u32_le(header[4:8]) != STATS_FILE_VERSION do return
	length := int(get_u64_le(header[16:24]))
	if length < 4 || i64(STATS_FILE_HEADER_LEN + length) > size do return
	body := make([]u8, length)
	defer delete(body)
	got, body_err := log_file_read(file, body)
	if body_err.kind != .None || got != length do return
	if crc32c(body) != get_u32_le(header[24:28]) do return
	r: Byte_Reader
	br_init(&r, body)
	count := int(br_read_u32(&r))
	if r.bad || count < 0 || count > length do return
	for _ in 0 ..< count {
		name := br_read_string(&r, context.allocator)
		if r.bad {
			delete(name)
			stats_destroy(store)
			return
		}
		rows := br_read_u64(&r)
		columns := int(br_read_u32(&r))
		if r.bad || columns < 0 || columns > length {
			delete(name)
			stats_destroy(store)
			return
		}
		measured := make([]Column_Stats, columns)
		for i in 0 ..< columns {
			distinct_count := br_read_u64(&r)
			nulls := br_read_u64(&r)
			saturated := br_read_u8(&r) != 0
			measured[i] = Column_Stats {
				distinct_count = distinct_count,
				nulls          = nulls,
				saturated      = saturated,
			}
		}
		if r.bad {
			delete(measured)
			delete(name)
			stats_destroy(store)
			return
		}
		if old, exists := store.stats[name]; exists do delete(old.columns)
		store.stats[name] = Table_Stats{rows = rows, columns = measured}
	}
	store.stats_seq = get_u64_le(header[8:16])
}

store_stats_path :: proc(store: ^Store) -> string {
	return strings.concatenate({store.path, "/stats"})
}
