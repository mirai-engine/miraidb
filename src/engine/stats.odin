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
//	table        : string name | u64 rows | u32 columns | columns * column
//	column       : u64 distinct_count | u64 nulls | u8 saturated | u8 numeric |
//	               f64 min | f64 max | u64 buckets * STATS_HISTOGRAM_BUCKETS
STATS_FILE_MAGIC :: "MRST"
STATS_FILE_VERSION :: u32(3)
STATS_FILE_HEADER_LEN :: 32

// STATS_DISTINCT_CAP bounds the set ANALYZE builds per column. Past it the count
// stops growing and the column is marked saturated, which a plan reads as "at
// least this many", never as an answer.
STATS_DISTINCT_CAP :: 20_000

// STATS_HISTOGRAM_BUCKETS is how many equi-width buckets a numeric column keeps.
// Sixteen is enough for a range estimate to follow the data instead of assuming a
// third of the table: the buckets span [min, max] and count the rows in each.
STATS_HISTOGRAM_BUCKETS :: 16

// Column_Stats is what one pass over a column remembers.
Column_Stats :: struct {
	// distinct_count is how many different non-null values the column held. The
	// name avoids `distinct`, which Odin keeps as a keyword.
	distinct_count: u64,
	nulls:          u64,
	saturated:      bool,
	// numeric says the histogram is meaningful: min, max and the bucket counts
	// were measured. Text and blobs keep only the counts, so a range over them
	// falls back to the one-third rule.
	numeric:  bool,
	min:      f64,
	max:      f64,
	buckets:  [STATS_HISTOGRAM_BUCKETS]u64,
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
	// First pass: distinct values, NULLs and the numeric range of each column.
	numeric := make([]bool, len(columns))
	for i in 0 ..< len(columns) do numeric[i] = true
	seen_numeric := make([]bool, len(columns))
	for row in rows {
		for column, i in row.values {
			if i >= len(columns) do break
			if column.kind == .Null {
				columns[i].nulls += 1
				continue
			}
			if i < len(numeric) {
				if number, ok := value_as_f64(column); ok {
					if !seen_numeric[i] {
						columns[i].min = number
						columns[i].max = number
						seen_numeric[i] = true
					} else {
						columns[i].min = min(columns[i].min, number)
						columns[i].max = max(columns[i].max, number)
					}
				} else {
					numeric[i] = false
				}
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
	// Second pass: count the rows in each bucket of the range measured above. The
	// rows are already in memory, so this costs nothing but the walk.
	for i in 0 ..< len(columns) {
		columns[i].numeric = numeric[i] && seen_numeric[i]
	}
	for row in rows {
		for column, i in row.values {
			if i >= len(columns) || !columns[i].numeric do continue
			if column.kind == .Null do continue
			number, ok := value_as_f64(column)
			if !ok do continue
			columns[i].buckets[stats_bucket(columns[i], number)] += 1
		}
	}
	return Table_Stats{rows = u64(len(rows)), columns = columns}, ERROR_NONE
}

// stats_bucket maps a number into the bucket of a column's histogram.
@(private)
stats_bucket :: proc(column: Column_Stats, number: f64) -> int {
	span := column.max - column.min
	if span <= 0 do return 0
	fraction := (number - column.min) / span
	bucket := int(fraction * f64(STATS_HISTOGRAM_BUCKETS))
	if bucket < 0 do return 0
	if bucket >= STATS_HISTOGRAM_BUCKETS do return STATS_HISTOGRAM_BUCKETS - 1
	return bucket
}

// stats_rows_below how many rows of a column hold a value under `number`, read
// from the histogram. The bucket that contains the value is counted in
// proportion to where the value falls inside it, which is what makes a range
// follow the data instead of assuming a third of the table.
@(private)
stats_rows_below :: proc(stats: Table_Stats, column_index: int, number: f64, inclusive: bool) -> u64 {
	if column_index >= len(stats.columns) do return 0
	column := stats.columns[column_index]
	if !column.numeric do return stats.rows / 3
	if number < column.min do return 0
	if number > column.max do return stats.rows - column.nulls
	bucket := stats_bucket(column, number)
	below := u64(0)
	for i in 0 ..< bucket do below += column.buckets[i]
	span := column.max - column.min
	within: f64 = 1
	if span > 0 {
		low := column.min + f64(bucket) * span / f64(STATS_HISTOGRAM_BUCKETS)
		width := span / f64(STATS_HISTOGRAM_BUCKETS)
		if width > 0 do within = (number - low) / width
	}
	within = max(0, min(within, 1))
	below += u64(f64(column.buckets[bucket]) * within)
	if inclusive && below + 1 <= stats.rows do below += 1
	return min(below, stats.rows)
}

// stats_estimate_rows predicts how many of a table's rows a predicate keeps.
// Without statistics it returns the row count, which is the assumption a plan
// made before any of this existed. A predicate with no recognizable conjunct
// keeps everything for the same reason.
stats_estimate_rows :: proc(
	store: ^Store,
	table: ^Table,
	predicate: ^Expr,
	params: []Value,
) -> u64 {
	total := u64(table_row_count(table))
	stats, has_stats := stats_get(store, table.schema.name)
	if has_stats do total = stats.rows
	if predicate == nil || !has_stats || stats.rows == 0 do return total
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	estimate := f64(stats.rows)
	// A range written as two comparisons is one range, not two independent
	// filters: `v >= 5 AND v < 9` keeps a band of the table, not two thirds of it.
	range_low, range_high, range_fraction, has_range := stats_range_of(stats, table, conjuncts[:], params)
	if has_range do estimate *= range_fraction
	for expr in conjuncts {
		if estimate <= 1 do break
		if has_range && (expr == range_low || expr == range_high) do continue
		if binary, is_binary := expr^.(Binary_Expr); is_binary {
			estimate *= stats_binary_fraction(stats, table, binary, params)
			continue
		}
		if between, is_between := expr^.(Between_Expr); is_between && !between.negated {
			estimate *= stats_between_fraction(stats, table, between, params)
			continue
		}
	}
	_ = estimate
	return u64(max(estimate, 1.0))
}

// stats_range_of finds the one range a predicate writes as two comparisons on the
// same column and answers it as a band: which conjuncts hold the bounds, and the
// share of the table between them. One range per estimate is enough to price a
// plan; two independent ranges on two columns keep the per-conjunct product.
@(private)
stats_range_of :: proc(
	stats: Table_Stats,
	table: ^Table,
	conjuncts: []^Expr,
	params: []Value,
) -> (
	low_expr: ^Expr,
	high_expr: ^Expr,
	fraction: f64,
	ok: bool,
) {
	column := -1
	low: f64
	high: f64
	low_value: f64
	high_value: f64
	have_low := false
	have_high := false
	high_inclusive := true
	for expr in conjuncts {
		binary, is_binary := expr^.(Binary_Expr)
		if !is_binary do continue
		bound_column, number, lower, inclusive, bound_ok := stats_range_bound(table, binary, params)
		if !bound_ok do continue
		if column < 0 {
			column = bound_column
		} else if bound_column != column {
			continue
		}
		if lower {
			if !have_low || number > low_value {
				low = number
				low_value = number
				low_expr = expr
				have_low = true
			}
		} else {
			if !have_high || number < high_value {
				high = number
				high_value = number
				high_expr = expr
				high_inclusive = inclusive
				have_high = true
			}
		}
	}
	if column < 0 || !have_low || !have_high do return nil, nil, 1, false
	if high < low do return low_expr, high_expr, 1.0 / f64(stats.rows), true
	return low_expr, high_expr, stats_range_fraction(stats, column, low, high, high_inclusive), true
}

// stats_range_bound reads one comparison as a bound on a column.
@(private)
stats_range_bound :: proc(
	table: ^Table,
	binary: Binary_Expr,
	params: []Value,
) -> (
	column: int,
	number: f64,
	lower: bool,
	inclusive: bool,
	ok: bool,
) {
	column = -1
	#partial switch binary.op {
	case .Gt:
		lower = true
	case .Ge:
		lower = true
		inclusive = true
	case .Lt:
		lower = false
	case .Le:
		lower = false
		inclusive = true
	case:
		return column, 0, false, false, false
	}
	qualifier, column_name, value_expr, reversed, sides_ok := comparison_sides(binary)
	if !sides_ok do return column, 0, false, false, false
	if len(qualifier) > 0 && !strings.equal_fold(qualifier, table.schema.name) {
		return column, 0, false, false, false
	}
	column_index, found := schema_column_index(&table.schema, column_name)
	if !found do return column, 0, false, false, false
	value, constant := eval_constant(value_expr, params)
	if !constant do return column, 0, false, false, false
	numeric, is_number := value_as_f64(value)
	if !is_number do return column, 0, false, false, false
	if reversed do lower = !lower
	return column_index, numeric, lower, inclusive, true
}

// stats_range_fraction is the share of a table's rows a band keeps: everything
// below `high`, less what is below `low`.
@(private)
stats_range_fraction :: proc(
	stats: Table_Stats,
	column: int,
	low: f64,
	high: f64,
	high_inclusive: bool,
) -> f64 {
	if stats.rows == 0 || column < 0 || column >= len(stats.columns) do return 1
	below_high := stats_rows_below(stats, column, high, high_inclusive)
	below_low := stats_rows_below(stats, column, low, false)
	kept := below_high - min(below_high, below_low)
	return f64(max(kept, 1)) / f64(stats.rows)
}

// stats_binary_fraction is the share of a table's rows one comparison keeps.
@(private)
stats_binary_fraction :: proc(
	stats: Table_Stats,
	table: ^Table,
	binary: Binary_Expr,
	params: []Value,
) -> f64 {
	#partial switch binary.op {
	case .Eq, .Lt, .Le, .Gt, .Ge:
	case:
		return 1
	}
	qualifier, column_name, value_expr, reversed, ok := comparison_sides(binary)
	if !ok do return 1
	if len(qualifier) > 0 && !strings.equal_fold(qualifier, table.schema.name) do return 1
	column_index, found := schema_column_index(&table.schema, column_name)
	if !found || column_index >= len(stats.columns) do return 1
	column := stats.columns[column_index]
	op := binary.op
	if reversed {
		#partial switch op {
		case .Lt:
			op = .Gt
		case .Le:
			op = .Ge
		case .Gt:
			op = .Lt
		case .Ge:
			op = .Le
		}
	}
	if op == .Eq {
		distinct_count := max(column.distinct_count, 1)
		if column.nulls > 0 do distinct_count += 1
		return 1 / f64(distinct_count)
	}
	// A prepared statement prices its plan with the value it was given, so a
	// bound parameter reads the histogram instead of estimating a third of the
	// table.
	bound, constant := eval_constant(value_expr, params)
	number, is_number := value_as_f64(bound)
	if !constant || !is_number || !column.numeric || stats.rows == 0 do return 1.0 / 3.0
	// `<` and `<=` keep the rows below; `>` and `>=` keep the rest. The boundary
	// itself is counted for the inclusive operators only, which is the one row a
	// histogram cannot place precisely.
	inclusive := op == .Le || op == .Gt
	below := stats_rows_below(stats, column_index, number, inclusive)
	kept := below
	#partial switch op {
	case .Gt, .Ge:
		kept = stats.rows - below
	}
	if stats.rows == 0 do return 0
	return f64(max(kept, 1)) / f64(stats.rows)
}

// stats_between_fraction is the share of a table's rows a BETWEEN keeps.
@(private)
stats_between_fraction :: proc(
	stats: Table_Stats,
	table: ^Table,
	between: Between_Expr,
	params: []Value,
) -> f64 {
	if stats.rows == 0 do return 1
	column, is_column := between.operand^.(Column_Expr)
	if !is_column do return 0.25
	if len(column.table) > 0 && !strings.equal_fold(column.table, table.schema.name) do return 0.25
	column_index, found := schema_column_index(&table.schema, column.name)
	if !found || column_index >= len(stats.columns) do return 0.25
	if !stats.columns[column_index].numeric do return 0.25
	low_value, low_ok := eval_constant(between.low, params)
	high_value, high_ok := eval_constant(between.high, params)
	low, low_number := value_as_f64(low_value)
	high, high_number := value_as_f64(high_value)
	if !low_ok || !high_ok || !low_number || !high_number do return 0.25
	return stats_range_fraction(stats, column_index, low, high, true)
}

// value_as_f64 reads a value as a number for histogram work. It is statistics
// only and never answers a query, so it accepts the numeric kinds and refuses
// everything else.
@(private)
value_as_f64 :: proc(v: Value) -> (number: f64, ok: bool) {
	#partial switch v.kind {
	case .Int:
		return f64(v.i), true
	case .Uint:
		return f64(v.u), true
	case .Float:
		return v.f, true
	case .Timestamp, .Duration:
		return f64(v.i), true
	}
	return 0, false
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
			bw_write_u8(&payload, u8(1) if column.numeric else u8(0))
			bw_write_u64(&payload, transmute(u64)column.min)
			bw_write_u64(&payload, transmute(u64)column.max)
			for bucket in column.buckets do bw_write_u64(&payload, bucket)
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
			numeric := br_read_u8(&r) != 0
			minimum := transmute(f64)br_read_u64(&r)
			maximum := transmute(f64)br_read_u64(&r)
			measured[i] = Column_Stats {
				distinct_count = distinct_count,
				nulls          = nulls,
				saturated      = saturated,
				numeric        = numeric,
				min            = minimum,
				max            = maximum,
			}
			for bucket in 0 ..< STATS_HISTOGRAM_BUCKETS {
				measured[i].buckets[bucket] = br_read_u64(&r)
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
