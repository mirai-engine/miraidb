// The reference suite, run against this engine.
//
// The reference database ships a Criterion suite (`crates/bench/benches/
// generic.rs`) that times its raw datastore - the in-process API, no module, no
// network - against SQLite. This program runs the same workloads, with the same
// schemas, the same generated rows and the same sizes, through this engine's
// in-process API, so the two sets of numbers answer the same question:
//
//	empty                          one write transaction that changes nothing
//	insert_bulk  load=2048 count=256  2048 rows present, 256 more in one tx
//	iterate      count=256         one read transaction over every row
//	update_bulk  load=2048 count=256  256 rows found by id and rewritten, one tx
//	filter       load=2048 count=256  the rows an index finds for one value
//
// Tables are `u32_u64_str (id, age, name)` and `u32_u64_u64 (id, x, y)`, each
// with a unique index on `id` (`unique_0`) or an ordered index on every column
// (`btree_each_column`). Rows come from the reference's xorshift generator with
// seed 0xdeadbeef, so both engines store exactly the same values.
//
//	odin run benchmarks/parity -o:speed -- [mem|disk|disk-fsync] [--json]
//
// `mem` is an in-memory store; `disk` writes the commit log and lets the OS
// flush it (the reference's durable test database also commits before its log
// reaches the disk: its durability worker syncs in the background); `disk-fsync`
// waits for the disk on every commit, which the reference never does.
package parity

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import db "../../src/engine"

Shape :: enum {
	U32_U64_Str,
	U32_U64_U64,
}

Strategy :: enum {
	Unique_0,
	Btree_Each_Column,
}

Row_Data :: struct {
	id: u32,
	a:  u64, // age, or x
	b:  u64, // y; unused for the string shape
	s:  string, // name
}

// XorShift is the reference's generator, step for step: it returns the state
// before the step.
XorShift :: struct {
	state: u64,
}

xorshift_next :: proc(rng: ^XorShift) -> u64 {
	old := rng.state
	rng.state ~= rng.state << 13
	rng.state ~= rng.state >> 7
	rng.state ~= rng.state << 17
	return old
}

// The reference names a person "<last>, <first> [<n>]" from two word lists; the
// text here has the same shape and a similar length (16 to 24 bytes), which is
// what the cost of storing and comparing it depends on.
nth_name :: proc(n: u64) -> string {
	FIRST :: [8]string{"Ana", "Luis", "Maria", "Jose", "Lucia", "Pedro", "Elena", "Tomas"}
	LAST :: [8]string{"Garcia", "Lopez", "Martinez", "Sanchez", "Perez", "Gomez", "Diaz", "Torres"}
	first := FIRST
	last := LAST
	return fmt.aprintf("%s, %s [%d]", last[(n / 8) % 8], first[n % 8], n / 64)
}

create_sequential :: proc(shape: Shape, seed: u64, count: u32, buckets: u64) -> []Row_Data {
	rng := XorShift{seed}
	rows := make([]Row_Data, count)
	for i in 0 ..< count {
		switch shape {
		case .U32_U64_Str:
			name := nth_name(xorshift_next(&rng) % buckets)
			age := xorshift_next(&rng) % buckets
			rows[i] = Row_Data{id = i, a = age, s = name}
		case .U32_U64_U64:
			x := xorshift_next(&rng) % buckets
			y := xorshift_next(&rng) % buckets
			rows[i] = Row_Data{id = i, a = x, b = y}
		}
	}
	return rows
}

shape_name :: proc(shape: Shape) -> string {
	return shape == .U32_U64_Str ? "u32_u64_str" : "u32_u64_u64"
}

strategy_name :: proc(strategy: Strategy) -> string {
	return strategy == .Unique_0 ? "unique_0" : "btree_each_column"
}

table_name :: proc(shape: Shape, strategy: Strategy) -> string {
	return fmt.aprintf("%s_%s", strategy_name(strategy), shape_name(shape))
}

exec :: proc(store: ^db.Store, sql: string) {
	result, err := db.sql_execute(store, sql)
	if !db.error_ok(err) {
		fmt.eprintfln("parity: %s: %s", sql, err.message)
		os.exit(1)
	}
	db.sql_result_destroy(&result)
}

create_table :: proc(store: ^db.Store, shape: Shape, strategy: Strategy) -> string {
	name := table_name(shape, strategy)
	columns := shape == .U32_U64_Str ? "id UINT4 NOT NULL, age UBIGINT NOT NULL, name TEXT NOT NULL" : "id UINT4 NOT NULL, x UBIGINT NOT NULL, y UBIGINT NOT NULL"
	exec(store, fmt.tprintf("CREATE TABLE %s (%s)", name, columns))
	switch strategy {
	case .Unique_0:
		exec(store, fmt.tprintf("CREATE UNIQUE INDEX %s_id ON %s USING BTREE (id)", name, name))
	case .Btree_Each_Column:
		names := shape == .U32_U64_Str ? []string{"id", "age", "name"} : []string{"id", "x", "y"}
		for column in names {
			exec(store, fmt.tprintf("CREATE INDEX %s_%s ON %s USING BTREE (%s)", name, column, name, column))
		}
	}
	return name
}

row_values :: proc(shape: Shape, row: Row_Data, out: []db.Value) {
	out[0] = db.value_uint(u64(row.id))
	switch shape {
	case .U32_U64_Str:
		out[1] = db.value_uint(row.a)
		out[2] = db.value_string(row.s)
	case .U32_U64_U64:
		out[1] = db.value_uint(row.a)
		out[2] = db.value_uint(row.b)
	}
}

insert_rows :: proc(store: ^db.Store, name: string, shape: Shape, rows: []Row_Data) {
	tx := db.tx_begin_write(store)
	values: [3]db.Value
	for row in rows {
		row_values(shape, row, values[:])
		if _, err := db.tx_insert(tx, name, values[:]); !db.error_ok(err) {
			fmt.eprintfln("parity: insert: %s", err.message)
			os.exit(1)
		}
	}
	if err := db.tx_commit(tx); !db.error_ok(err) {
		fmt.eprintfln("parity: commit: %s", err.message)
		os.exit(1)
	}
	db.store_prune_history(store)
}

clear_table :: proc(store: ^db.Store, name: string) {
	tx := db.tx_begin_write(store)
	if err := db.tx_truncate(tx, name); !db.error_ok(err) {
		fmt.eprintfln("parity: truncate: %s", err.message)
		os.exit(1)
	}
	_ = db.tx_commit(tx)
	// Row history is kept for `AS OF` until the embedder says it keeps none, as
	// the CLI does after every statement. The reference keeps no history, so
	// neither does this run.
	db.store_prune_history(store)
}

index_on :: proc(table: ^db.Table, column: int) -> int {
	for index, i in table.indexes {
		if len(index.schema.columns) == 1 && index.schema.columns[0] == column do return i
	}
	return -1
}

// --- Timing ------------------------------------------------------------------

Sample :: struct {
	name:      string,
	median_ns: f64,
	min_ns:    f64,
	runs:      int,
}

samples: [dynamic]Sample

// measure runs `prepare` untimed and `routine` timed, `runs` times, and records
// the median: the reference reports Criterion's estimate, which a median tracks
// on a machine whose timer is this noisy.
measure :: proc(name: string, runs: int, data: rawptr, prepare: proc(data: rawptr), routine: proc(data: rawptr)) {
	times := make([]f64, runs)
	defer delete(times)
	for i in 0 ..< runs {
		if prepare != nil do prepare(data)
		start := time.tick_now()
		routine(data)
		times[i] = f64(time.tick_since(start))
	}
	slice.sort(times)
	append(&samples, Sample{name = name, median_ns = times[runs / 2], min_ns = times[0], runs = runs})
}

// --- Workloads -----------------------------------------------------------------

Bench :: struct {
	store:   ^db.Store,
	name:    string,
	shape:   Shape,
	load:    []Row_Data,
	batch:   []Row_Data,
	column:  int,
	values:  []db.Value,
	cursor:  int,
	all:     []Row_Data,
}

bench_empty :: proc(data: rawptr) {
	b := (^Bench)(data)
	tx := db.tx_begin_write(b.store)
	_ = db.tx_commit(tx)
}

bench_insert_prepare :: proc(data: rawptr) {
	b := (^Bench)(data)
	clear_table(b.store, b.name)
	insert_rows(b.store, b.name, b.shape, b.load)
}

bench_insert :: proc(data: rawptr) {
	b := (^Bench)(data)
	insert_rows(b.store, b.name, b.shape, b.batch)
}

// bench_iterate walks every row in place, as the reference's iteration does:
// table_scan reads the rows where the table keeps them (table_collect would
// copy each one into a list first).
bench_iterate :: proc(data: rawptr) {
	b := (^Bench)(data)
	tx := db.tx_begin_read(b.store)
	table := db.tx_table_probe(tx, b.name)
	scan := db.table_scan(table)
	sum: u64
	for id in db.table_scan_next(&scan) do sum += u64(id)
	db.table_scan_end(&scan)
	db.tx_end(tx)
	if sum == max(u64) do fmt.println(sum)
}

bench_update_prepare :: proc(data: rawptr) {
	b := (^Bench)(data)
	clear_table(b.store, b.name)
	insert_rows(b.store, b.name, b.shape, b.load)
}

// bench_update follows the reference: take the first `count` rows, find each by
// its id through the unique index, and write it back with column 1 plus one.
bench_update :: proc(data: rawptr) {
	b := (^Bench)(data)
	tx := db.tx_begin_write(b.store)
	table := db.tx_table_probe(tx, b.name)
	rows := make([dynamic]db.Row, 0, len(b.load))
	db.table_collect(table, &rows)
	index := index_on(table, 0)
	values: [3]db.Value
	for row in rows[:len(b.batch)] {
		ids := db.table_index_lookup(table, index, row.values)
		if len(ids) != 1 {
			fmt.eprintln("parity: update could not find its row")
			os.exit(1)
		}
		copy(values[:], row.values)
		values[1] = db.value_uint(row.values[1].u + 1)
		if err := db.tx_update(tx, b.name, ids[0], values[:]); !db.error_ok(err) {
			fmt.eprintfln("parity: update: %s", err.message)
			os.exit(1)
		}
		delete(ids)
	}
	db.table_collect_release(table, &rows)
	_ = db.tx_commit(tx)
}

bench_filter_prepare :: proc(data: rawptr) {
	b := (^Bench)(data)
	row_values(b.shape, b.all[b.cursor], b.values)
	b.cursor = (b.cursor + 1) % len(b.all)
}

bench_filter :: proc(data: rawptr) {
	b := (^Bench)(data)
	tx := db.tx_begin_read(b.store)
	table := db.tx_table_probe(tx, b.name)
	index := index_on(table, b.column)
	ids := db.table_index_lookup(table, index, b.values)
	sum: u64
	for id in ids {
		row, found := db.table_get_row(table, id, context.temp_allocator)
		if found do sum += u64(row.id)
	}
	delete(ids)
	db.tx_end(tx)
	if sum == max(u64) do fmt.println(sum)
}

// --- The suite -----------------------------------------------------------------

table_suite :: proc(store: ^db.Store, shape: Shape, prefix: string) {
	tables := [2]string{create_table(store, shape, .Unique_0), create_table(store, shape, .Btree_Each_Column)}
	strategies := [2]Strategy{.Unique_0, .Btree_Each_Column}

	data := create_sequential(shape, 0xdeadbeef, 2048 + 256, 1000)
	for name, i in tables {
		b := Bench{store = store, name = name, shape = shape, load = data[:2048], batch = data[2048:]}
		label := fmt.aprintf("%s/insert_bulk/%s/%s/load=2048/count=256", prefix, shape_name(shape), strategy_name(strategies[i]))
		measure(label, 60, &b, bench_insert_prepare, bench_insert)
		clear_table(store, name)
	}
	for name, i in tables {
		if strategies[i] == .Unique_0 {
			iterate_rows := create_sequential(shape, 0xdeadbeef, 256, 1000)
			insert_rows(store, name, shape, iterate_rows)
			b := Bench{store = store, name = name, shape = shape}
			measure(fmt.aprintf("%s/iterate/%s/unique_0/count=256", prefix, shape_name(shape)), 2000, &b, nil, bench_iterate)
			clear_table(store, name)

			update_rows := create_sequential(shape, 0xdeadbeef, 2048, 1000)
			u := Bench{store = store, name = name, shape = shape, load = update_rows, batch = update_rows[:256]}
			measure(fmt.aprintf("%s/update_bulk/%s/unique_0/load=2048/count=256", prefix, shape_name(shape)), 60, &u, bench_update_prepare, bench_update)
			clear_table(store, name)
		} else {
			// The reference filters on column 2 with eight buckets: 2048 rows,
			// 256 per value.
			filter_rows := create_sequential(shape, 0xdeadbeef, 2048, 8)
			insert_rows(store, name, shape, filter_rows)
			values := make([]db.Value, 3)
			// Column 2 is `name` in the first shape and `y` in the second: the
			// reference's `filter/string/index` and `filter/u64/index`.
			f := Bench{store = store, name = name, shape = shape, column = 2, values = values, all = filter_rows}
			kind := shape == .U32_U64_Str ? "string" : "u64"
			measure(fmt.aprintf("%s/filter/%s/index/load=2048/count=256", prefix, kind), 2000, &f, bench_filter_prepare, bench_filter)
			clear_table(store, name)
		}
	}
}

// sql_suite measures what a statement costs through SQL, which the reference's
// suite does not have: the parse, the plan and the executor around the same
// table. There is no reference number for these; the parity gate holds them to
// this engine's own baseline.
sql_suite :: proc(store: ^db.Store, prefix: string) {
	exec(store, "CREATE TABLE sql_t (id UINT4 NOT NULL, age UBIGINT NOT NULL, name TEXT NOT NULL)")
	exec(store, "CREATE UNIQUE INDEX sql_t_id ON sql_t (id)")
	for i in 0 ..< 256 do exec(store, fmt.tprintf("INSERT INTO sql_t VALUES (%d, %d, 'name%d')", i, i * 3, i))
	b := Bench{store = store, name = "sql_t"}
	measure(fmt.aprintf("%s/sql/select_1", prefix), 2000, &b, nil, proc(data: rawptr) {
		sql_run((^Bench)(data).store, "SELECT 1")
	})
	measure(fmt.aprintf("%s/sql/point_rowid/count=256", prefix), 2000, &b, nil, proc(data: rawptr) {
		sql_run((^Bench)(data).store, "SELECT * FROM sql_t WHERE rowid = 77")
	})
	measure(fmt.aprintf("%s/sql/point_index/count=256", prefix), 2000, &b, nil, proc(data: rawptr) {
		sql_run((^Bench)(data).store, "SELECT * FROM sql_t WHERE id = 77")
	})
	measure(fmt.aprintf("%s/sql/count/count=256", prefix), 2000, &b, nil, proc(data: rawptr) {
		sql_run((^Bench)(data).store, "SELECT count(*) FROM sql_t")
	})
}

// sql_run runs one statement and drops its answer; a failure stops the suite.
sql_run :: proc(store: ^db.Store, sql: string) {
	result, err := db.sql_execute(store, sql)
	defer db.sql_result_destroy(&result)
	defer db.error_free(&err)
	if !db.error_ok(err) {
		fmt.eprintfln("parity: %s: %s", sql, err.message)
		os.exit(1)
	}
}

main :: proc() {
	mode := "mem"
	as_json := false
	for arg in os.args[1:] {
		switch arg {
		case "--json":
			as_json = true
		case:
			mode = arg
		}
	}
	path := "_parity_db"
	os.remove_all(path)
	defer os.remove_all(path)
	options: db.Store_Options
	switch mode {
	case "mem":
		options = {persistent = false, create = true}
	case "disk":
		options = {persistent = true, create = true, durable = false, durability = .None}
	case "disk-fsync":
		options = {persistent = true, create = true, durable = true, durability = .Full}
	case:
		fmt.eprintln("parity: mode is mem, disk or disk-fsync")
		os.exit(2)
	}
	store, open_err := db.store_open(path, options)
	if !db.error_ok(open_err) {
		fmt.eprintfln("parity: open: %s", open_err.message)
		os.exit(1)
	}
	defer db.store_close(store)

	prefix := fmt.aprintf("miraidb/%s", mode)
	b := Bench{store = store}
	measure(fmt.aprintf("%s/empty", prefix), 5000, &b, nil, bench_empty)
	table_suite(store, .U32_U64_Str, prefix)
	table_suite(store, .U32_U64_U64, prefix)
	sql_suite(store, prefix)

	if as_json {
		builder := strings.builder_make()
		strings.write_string(&builder, "[")
		for sample, i in samples {
			if i > 0 do strings.write_string(&builder, ",")
			fmt.sbprintf(&builder, `{{"name":"%s","median_ns":%.0f,"min_ns":%.0f,"runs":%d}}`, sample.name, sample.median_ns, sample.min_ns, sample.runs)
		}
		strings.write_string(&builder, "]")
		fmt.println(strings.to_string(builder))
		return
	}
	for sample in samples {
		fmt.printfln("%-74s %9.2f us  (min %.2f, n=%d)", sample.name, sample.median_ns / 1000, sample.min_ns / 1000, sample.runs)
	}
}
