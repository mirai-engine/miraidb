// miraidb command line: create, query and inspect databases.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import db "../engine"
import sdk "../client"

USAGE :: `miraidb - embeddable relational database

Usage:
  miraidb create <database>                 create an empty database
  miraidb sql <database> <statement...>     run one statement and print the result
  miraidb sqlite <file> <statement|.dbinfo|.tables>
                                            read a SQLite file (imports it)
  miraidb import-sqlite <file> <database>   copy a SQLite file into the engine
  miraidb export-sqlite <database> <file>   write the database as a SQLite file
  miraidb repl <database>                   interactive session
  miraidb inspect <database>                list tables, columns and indexes
  miraidb describe <database> <table>       show one table's columns and indexes
  miraidb bench <database> [rows]           time that many inserts in one transaction
  miraidb bench-read <database> [rows] [iterations]
                                            time opening read transactions
  miraidb codegen <database>                print Odin structs for every table
  miraidb export <database>                 print INSERT statements for every table
  miraidb call <url> <reducer> [args...]    call a reducer on a running server
  miraidb subscribe <url> <sql> [--count N] [--interval ms]
                                            print a result set and its changes
  miraidb check <database>                  replay the commit log and report
  miraidb compact <database>                snapshot and rewrite the log as one record
  miraidb snapshot <database>               write <database>/snapshot

Options:
  --no-sync                                 do not fsync every commit (faster, less safe)
  --memory                                  run against an in-memory database
  --read-only                               open as a reader: shared lock, no writes
  --paged                                   keep new tables in page files, not in RAM
  --page-frames=N                           pages of each table file kept in the pool
  --mirror-report                           print what keeping a .sqlite mirror
                                            current cost, when a sql statement commits
  --memory-report                           print this process memory when a sql
                                            statement finishes
  --json                                    print a query result as one JSON
                                            array of rows, for a tool to compare

The database is a directory holding a commit log. SQL covers CREATE, DROP and
ALTER TABLE, INSERT, UPDATE, DELETE, UPSERT, SELECT with joins, common table
expressions, window frames, aggregates, DISTINCT, GROUP BY/HAVING, ORDER BY and
LIMIT/OFFSET, plus triggers, views, row policies, full-text and spatial tables,
JSON functions, ATTACH and SAVEPOINT.

In the REPL:
  .tables            list tables
  .schema <table>    show one table
  .help              this text
  .quit              leave

BEGIN/COMMIT/ROLLBACK keep one transaction open across statements.`

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.println(USAGE)
		os.exit(2)
	}
	command := args[1]
	rest := args[2:]
	durable := true
	durability := db.Durability.Full
	persistent := true
	paged := false
	page_frames := 0
	memory_report := false
	mirror_report := false
	json_output := false
	read_only := false
	filtered := make([dynamic]string, 0, len(rest))
	defer delete(filtered)
	for arg in rest {
		switch arg {
		case "--no-sync":
			durable = false
		case "--durability=full":
			durability = .Full
		case "--durability=batched":
			durability = .Batched
		case "--durability=none":
			durable = false
		case "--memory":
			persistent = false
		case "--read-only":
			read_only = true
		case "--paged":
			paged = true
		case "--memory-report":
			memory_report = true
		case "--mirror-report":
			mirror_report = true
		case "--json":
			json_output = true
		case:
			if strings.has_prefix(arg, "--page-frames=") {
				parsed, ok := strconv.parse_int(arg[len("--page-frames="):])
				if !ok || parsed <= 0 do usage_error("--page-frames needs a positive integer")
				page_frames = int(parsed)
				continue
			}
			append(&filtered, arg)
		}
	}
	arguments := filtered[:]
	if json_output {
		shell.mode = .Json
		shell.headers = false
	}

	switch command {
	case "help", "--help", "-h":
		fmt.println(USAGE)
		return
	case "create":
		if len(arguments) < 1 do usage_error("create needs a database path")
		store, err := db.store_open(arguments[0], {persistent = true, create = true, durable = durable, durability = durability})
		if !db.error_ok(err) do fail(err)
		db.store_close(store)
		fmt.printfln("created %s", arguments[0])
	case "sql":
		if len(arguments) < 2 do usage_error("sql needs a database path and a statement")
		store, err := open_database(arguments[0], persistent, durable, durability, paged, page_frames, read_only)
		if !db.error_ok(err) do fail(err)
		baseline := memory_report ? cli_current_rss_bytes() : 0
		statement := strings.join(arguments[1:], " ")
		result, exec_err := db.sql_execute(store, statement)
		if !db.error_ok(exec_err) do fail(exec_err)
		print_result(result)
		db.sql_result_destroy(&result)
		if mirror_report {
			// A database opened from a .sqlite file patches that file after every
			// commit; these are the pages it had to write.
			fmt.printfln("mirror-pages: %d", store.mirror_pages_written)
			fmt.printfln("mirror-bytes: %d", store.mirror_bytes_written)
			fmt.printfln("mirror-rewrites: %d", store.mirror_full_writes)
			if len(store.mirror_reason) > 0 do fmt.printfln("mirror-reason: %s", store.mirror_reason)
		}
		if memory_report {
			// The peak covers the whole process, and opening a database already
			// read the log, so the number the gate reads is how much the statement
			// added over that baseline.
			peak := cli_peak_rss_bytes()
			growth := peak > baseline ? peak - baseline : 0
			fmt.printfln("baseline-rss-bytes: %d", baseline)
			fmt.printfln("peak-rss-bytes: %d", peak)
			fmt.printfln("query-growth-bytes: %d", growth)
		}
		db.store_close(store)
	case "sqlite":
		if len(arguments) < 2 do usage_error("sqlite needs a .sqlite/.db file and a statement")
		run_sqlite_file(arguments[0], strings.join(arguments[1:], " "))
	case "import-sqlite":
		if len(arguments) < 2 do usage_error("import-sqlite needs a SQLite file and a database path")
		file, file_err := db.sqlite_file_open(arguments[0])
		if !db.error_ok(file_err) do fail(file_err)
		defer db.sqlite_file_destroy(&file)
		store, err := db.store_open(arguments[1], {persistent = true, create = true, durable = durable, durability = durability})
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		table_count, row_count, import_err := db.sqlite_import(&file, store)
		if !db.error_ok(import_err) do fail(import_err)
		fmt.printfln("imported %d table%s and %d row%s", table_count, table_count == 1 ? "" : "s", row_count, row_count == 1 ? "" : "s")
	case "export-sqlite":
		if len(arguments) < 2 do usage_error("export-sqlite needs a database path and a file")
		store, err := open_database(arguments[0], persistent, durable, durability)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		table_count, row_count, write_err := db.sqlite_file_write(store, arguments[1])
		if !db.error_ok(write_err) do fail(write_err)
		fmt.printfln("wrote %d table%s and %d row%s to %s", table_count, table_count == 1 ? "" : "s", row_count, row_count == 1 ? "" : "s", arguments[1])
	case "repl":
		if len(arguments) < 1 do usage_error("repl needs a database path")
		store, err := open_database(arguments[0], persistent, durable, durability)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		repl(store)
	case "export":
		if len(arguments) < 1 do usage_error("export needs a database path")
		store, err := open_database(arguments[0], persistent, durable, durability)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		host := db.host_init(store)
		defer db.host_destroy(host)
		fmt.print(db.export_sql(host, context.allocator))
	case "codegen":
		if len(arguments) < 1 do usage_error("codegen needs a database path")
		store, err := open_database(arguments[0], persistent, durable, durability)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		host := db.host_init(store)
		defer db.host_destroy(host)
		text := db.codegen_odin(host, context.allocator)
		fmt.print(text)
	case "call":
		if len(arguments) < 2 do usage_error("call needs a URL and a reducer")
		session, target, call_err := connect(arguments[0])
		if !db.error_ok(call_err) do fail(call_err)
		_ = target
		args := make([dynamic]db.Value, 0, len(arguments) - 2)
		defer delete(args)
		for text in arguments[2:] do append(&args, cli_argument(text))
		result, invoke_err := sdk.client_call(&session, arguments[1], args[:], context.allocator)
		if !db.error_ok(invoke_err) do fail(invoke_err)
		print_result(result)
		db.sql_result_destroy(&result)
	case "subscribe":
		if len(arguments) < 2 do usage_error("subscribe needs a URL and a statement")
		count := 10
		interval := 500
		position := 2
		for position < len(arguments) {
			if arguments[position] == "--count" && position + 1 < len(arguments) {
				parsed, ok := strconv.parse_int(arguments[position + 1])
				if !ok || parsed < 0 do usage_error("--count must be a non-negative integer")
				count = int(parsed)
				position += 2
				continue
			}
			if arguments[position] == "--interval" && position + 1 < len(arguments) {
				parsed, ok := strconv.parse_int(arguments[position + 1])
				if !ok || parsed < 0 do usage_error("--interval must be a positive number of milliseconds")
				interval = int(parsed)
				position += 2
				continue
			}
			usage_error("unknown subscribe option")
		}
		session, target, sub_err := connect(arguments[0])
		if !db.error_ok(sub_err) do fail(sub_err)
		_ = target
		previous, query_err := sdk.client_query(&session, arguments[1], context.allocator)
		if !db.error_ok(query_err) do fail(query_err)
		print_result(previous)
		for _ in 0 ..< count {
			time.sleep(time.Duration(interval) * time.Millisecond)
			next, next_err := sdk.client_query(&session, arguments[1], context.allocator)
			if !db.error_ok(next_err) do fail(next_err)
			delta := sdk.client_poll_diff(previous.rows, next.rows, context.allocator)
			for row in delta.inserts do print_row("+", row)
			for row in delta.deletes do print_row("-", row)
			sdk.poll_delta_destroy(&delta)
			db.sql_result_destroy(&previous)
			previous = next
		}
		db.sql_result_destroy(&previous)
	case "bench-read":
		if len(arguments) < 1 do usage_error("bench-read needs a database path")
		rows := 50000
		iterations := 200
		if len(arguments) >= 2 {
			if parsed, ok := strconv.parse_int(arguments[1]); ok && parsed > 0 do rows = int(parsed)
		}
		if len(arguments) >= 3 {
			if parsed, ok := strconv.parse_int(arguments[2]); ok && parsed > 0 do iterations = int(parsed)
		}
		store, err := open_database(arguments[0], persistent, durable, durability)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		_, create_err := db.sql_execute(store, "CREATE TABLE IF NOT EXISTS reads (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
		if !db.error_ok(create_err) do fail(create_err)
		existing := 0
		if counted, count_err := db.sql_execute(store, "SELECT count(*) FROM reads"); db.error_ok(count_err) {
			existing = int(counted.rows[0][0].i)
			db.sql_result_destroy(&counted)
		}
		if existing < rows {
			insert, prepare_err := db.sql_prepare(store, "INSERT INTO reads (v) VALUES (1)")
			if !db.error_ok(prepare_err) do fail(prepare_err)
			tx := db.tx_begin_write(store)
			for _ in existing ..< rows {
				_, insert_err := db.prepared_execute_in_tx(tx, insert, nil)
				if !db.error_ok(insert_err) {
					db.tx_rollback(tx)
					fail(insert_err)
				}
			}
			if commit_err := db.tx_commit(tx); !db.error_ok(commit_err) do fail(commit_err)
			db.stmt_prepared_destroy(insert)
		}
		// Opening a read copies nothing: it takes a reference per table, and a
		// commit that has to change a table a reader holds copies that table
		// instead. Both numbers are reported, because the copy moved rather than
		// vanished: a read nobody watches the commit for, and the commit that has
		// to pay for a live reader.
		if _, commit_err := db.sql_execute(store, "INSERT INTO reads (v) VALUES (1)"); !db.error_ok(commit_err) {
			fail(commit_err)
		}
		cold_start := time.now()
		cold := db.tx_begin_read(store)
		db.tx_end(cold)
		fmt.printfln("first read after a commit: %.1f us", time.duration_microseconds(time.since(cold_start)))

		held := db.tx_begin_read(store)
		copy_start := time.now()
		if _, commit_err := db.sql_execute(store, "INSERT INTO reads (v) VALUES (1)"); !db.error_ok(commit_err) {
			db.tx_end(held)
			fail(commit_err)
		}
		fmt.printfln("commit with a read open: %.1f us", time.duration_microseconds(time.since(copy_start)))
		db.tx_end(held)

		start := time.now()
		for _ in 0 ..< iterations {
			tx := db.tx_begin_read(store)
			db.tx_end(tx)
		}
		elapsed := time.since(start)
		per_iteration := time.duration_microseconds(elapsed) / f64(iterations)
		fmt.printfln(
			"%d read transactions over %d rows in %.3fs (%.1f us each, %.1f us per 1k rows)",
			iterations,
			rows,
			time.duration_seconds(elapsed),
			per_iteration,
			rows > 0 ? per_iteration / (f64(rows) / 1000) : 0,
		)
	case "bench":
		if len(arguments) < 1 do usage_error("bench needs a database path")
		store, err := open_database(arguments[0], persistent, durable, durability, paged, page_frames)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		rows := 1000
		if len(arguments) >= 2 {
			parsed_value, ok := strconv.parse_int(arguments[1])
			parsed := int(parsed_value)
			if !ok || parsed <= 0 do usage_error("bench rows must be a positive integer")
			rows = parsed
		}
		_, create_err := db.sql_execute(store, "CREATE TABLE IF NOT EXISTS bench (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER NOT NULL)")
		if !db.error_ok(create_err) do fail(create_err)
		start := time.now()
		prepared, prepare_err := db.sql_prepare(store, "INSERT INTO bench (v) VALUES (1)")
		if !db.error_ok(prepare_err) do fail(prepare_err)
		defer db.stmt_prepared_destroy(prepared)
		tx := db.tx_begin_write(store)
		for _ in 0 ..< rows {
			_, insert_err := db.prepared_execute_in_tx(tx, prepared, nil)
			if !db.error_ok(insert_err) {
				db.tx_rollback(tx)
				fail(insert_err)
			}
		}
		if commit_err := db.tx_commit(tx); !db.error_ok(commit_err) do fail(commit_err)
		elapsed := time.since(start)
		seconds := time.duration_seconds(elapsed)
		rate := seconds > 0 ? f64(rows) / seconds : 0
		fmt.printfln("%d inserts in %v (%.0f/s)", rows, elapsed, rate)
	case "describe":
		if len(arguments) < 2 do usage_error("describe needs a database path and a table")
		store, err := open_database(arguments[0], persistent, durable, durability)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		result, exec_err := db.sql_execute(store, fmt.tprintf("DESCRIBE %s", arguments[1]))
		if !db.error_ok(exec_err) do fail(exec_err)
		defer db.sql_result_destroy(&result)
		print_result(result)
	case "inspect":
		if len(arguments) < 1 do usage_error("inspect needs a database path")
		store, err := db.store_open(arguments[0], {persistent = persistent, create = false, durable = false})
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		inspect(store)
	case "compact":
		if len(arguments) < 1 do usage_error("compact needs a database path")
		store, err := open_database(arguments[0], persistent, durable, durability)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		if compact_err := db.store_compact(store); !db.error_ok(compact_err) do fail(compact_err)
		fmt.printfln("compacted %s (commit sequence %d)", arguments[0], store.commit_seq)
	case "snapshot":
		if len(arguments) < 1 do usage_error("snapshot needs a database path")
		store, err := open_database(arguments[0], persistent, durable, durability)
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		if snapshot_err := db.store_snapshot(store); !db.error_ok(snapshot_err) do fail(snapshot_err)
		fmt.printfln("wrote %s/snapshot at commit sequence %d", arguments[0], store.commit_seq)
	case "check":
		if len(arguments) < 1 do usage_error("check needs a database path")
		store, err := db.store_open(arguments[0], {persistent = persistent, create = false, durable = false})
		if !db.error_ok(err) do fail(err)
		defer db.store_close(store)
		check(store)
	case:
		fmt.eprintfln("miraidb: unknown command %q", command)
		fmt.eprintln(USAGE)
		os.exit(2)
	}
}

// open_database opens the engine format, or imports a SQLite file into an
// in-memory database so the same statements answer against it.
open_database :: proc(
	path: string,
	persistent: bool,
	durable: bool,
	durability: db.Durability,
	paged := false,
	page_frames := 0,
	read_only := false,
) -> (^db.Store, db.Error) {
	if db.sqlite_is_file(path) {
		file, file_err := db.sqlite_file_open(path)
		if !db.error_ok(file_err) do return nil, file_err
		defer db.sqlite_file_destroy(&file)
		store, store_err := db.store_open("", {persistent = false, durable = false})
		if !db.error_ok(store_err) do return nil, store_err
		if _, _, import_err := db.sqlite_import(&file, store); !db.error_ok(import_err) {
			db.store_close(store)
			return nil, import_err
		}
		// The file stays the user's database: every commit patches it back.
		db.store_set_sqlite_mirror(store, path)
		return store, db.ERROR_NONE
	}
	return db.store_open(
		path,
		{
			persistent = persistent,
			// A reader never creates: it joins a database that exists.
			create = !read_only,
			durable = durable,
			durability = durability,
			paged_tables = paged,
			page_frames = page_frames,
			read_only = read_only,
		},
	)
}

// connect builds a client for the authority in `url`.
connect :: proc(url: string) -> (session: sdk.Client, target: ^db.Tcp_Target, err: db.Error) {
	authority, _, split_err := db.Http_Split_Url(url)
	if split_err.kind != .None do return {}, nil, split_err
	target = new(db.Tcp_Target)
	target.authority = authority
	session = sdk.client_init(db.http_tcp_transport, target)
	return session, target, db.ERROR_NONE
}

// cli_argument parses one command line value: numbers stay numbers.
cli_argument :: proc(text: string) -> db.Value {
	if number, ok := strconv.parse_int(text); ok do return db.value_int(i64(number))
	return db.value_string(text)
}

print_row :: proc(prefix: string, row: []db.Value) {
	fmt.print(prefix)
	first := true
	for value in row {
		if !first do fmt.print(",")
		first = false
		fmt.print(db.value_format(value, context.temp_allocator))
	}
	fmt.println()
}

usage_error :: proc(message: string) {
	fmt.eprintfln("miraidb: %s", message)
	os.exit(2)
}

fail :: proc(err: db.Error) {
	fmt.eprintfln("miraidb: %s: %s", db.error_kind_name(err.kind), err.message)
	os.exit(1)
}

// --- Output ----------------------------------------------------------------

// run_sqlite_file answers one statement against a SQLite file. Dot commands
// mirror the ones the SQLite shell offers.
run_sqlite_file :: proc(path: string, statement: string) {
	file, file_err := db.sqlite_file_open(path)
	if !db.error_ok(file_err) do fail(file_err)
	defer db.sqlite_file_destroy(&file)
	switch statement {
	case ".dbinfo":
		fmt.printfln("database page size: %d", file.page_size)
		fmt.printfln("number of tables: %d", len(file.tables))
		return
	case ".tables":
		names := make([dynamic]string, 0, len(file.tables))
		defer delete(names)
		for table in file.tables do append(&names, table.name)
		sort_strings(names[:])
		for name, i in names {
			if i > 0 do fmt.print(" ")
			fmt.print(name)
		}
		fmt.println()
		return
	case ".schema":
		for table in file.tables {
			if len(table.sql) > 0 do fmt.printfln("%s;", table.sql)
		}
		return
	}
	store, store_err := db.store_open("", {persistent = false, durable = false})
	if !db.error_ok(store_err) do fail(store_err)
	defer db.store_close(store)
	if _, _, import_err := db.sqlite_import(&file, store); !db.error_ok(import_err) do fail(import_err)
	result, exec_err := db.sql_execute(store, statement)
	if !db.error_ok(exec_err) do fail(exec_err)
	defer db.sql_result_destroy(&result)
	for row in result.rows {
		builder := strings.builder_make()
		for value, i in row {
			if i > 0 do strings.write_byte(&builder, '|')
			strings.write_string(&builder, db.sqlite_value_text(value, context.temp_allocator))
		}
		fmt.println(strings.to_string(builder))
		strings.builder_destroy(&builder)
	}
}

// sort_strings sorts in place without pulling the slice package into the CLI.
sort_strings :: proc(values: []string) {
	for i in 1 ..< len(values) {
		j := i
		for j > 0 && values[j] < values[j - 1] {
			values[j], values[j - 1] = values[j - 1], values[j]
			j -= 1
		}
	}
}

// --- Shell settings --------------------------------------------------------

Shell_Mode :: enum {
	Column,
	List,
	Csv,
	Tabs,
	Json,
}

Shell_Settings :: struct {
	mode:        Shell_Mode,
	headers:     bool,
	timer:       bool,
	output:      ^os.File,
	output_path: string,
}

// The shell starts like SQLite's: column mode, headers on, stdout.
shell: Shell_Settings = {mode = .Column, headers = true}

// shell_write sends text to the .output target, or to stdout when there is none.
shell_write :: proc(text: string) {
	if shell.output != nil {
		if _, write_err := os.write(shell.output, transmute([]u8)text); write_err != nil {
			fmt.eprintfln("cannot write the output file: %v", write_err)
		}
		return
	}
	fmt.print(text)
}

shell_writef :: proc(format: string, args: ..any) {
	text := fmt.aprintf(format, ..args)
	defer delete(text)
	shell_write(text)
}

shell_mode_name :: proc(mode: Shell_Mode) -> string {
	switch mode {
	case .Column:
		return "column"
	case .List:
		return "list"
	case .Csv:
		return "csv"
	case .Tabs:
		return "tabs"
	case .Json:
		return "json"
	}
	return "column"
}

print_result :: proc(result: db.Sql_Result) {
	switch result.kind {
	case .Rows:
		print_rows(result.columns, result.rows)
		if shell.mode == .Column {
			shell_writef("(%d row%s)\n", len(result.rows), len(result.rows) == 1 ? "" : "s")
		}
	case .Affected:
		shell_writef("%d row%s affected\n", result.affected, result.affected == 1 ? "" : "s")
	case .Ack:
		if len(result.message) > 0 {
			shell_writef("%s\n", result.message)
		} else {
			shell_write("ok\n")
		}
	}
}

print_rows :: proc(columns: []string, rows: [][]db.Value) {
	if len(columns) == 0 {
		return
	}
	if shell.mode == .Json {
		print_rows_json(rows)
		return
	}
	if shell.mode == .List {
		for row in rows {
			for column, c in columns {
				if c >= len(row) do break
				shell_writef("%s = %s\n", column, cell_text(row[c]))
			}
			shell_write("\n")
		}
		return
	}
	if shell.mode == .Csv || shell.mode == .Tabs {
		separator := shell.mode == .Csv ? "," : "\t"
		if shell.headers {
			for column, i in columns {
				if i > 0 do shell_write(separator)
				shell_write(csv_cell(column, shell.mode == .Csv))
			}
			shell_write("\n")
		}
		for row in rows {
			for value, c in row {
				if c >= len(columns) do break
				if c > 0 do shell_write(separator)
				shell_write(csv_cell(cell_text(value), shell.mode == .Csv))
			}
			shell_write("\n")
		}
		return
	}
	widths := make([]int, len(columns))
	defer delete(widths)
	for column, i in columns {
		widths[i] = len(column)
	}
	formatted := make([][]string, len(rows))
	defer {
		for row in formatted do delete(row)
		delete(formatted)
	}
	for row, r in rows {
		cells := make([]string, len(columns))
		for value, c in row {
			if c >= len(columns) do continue
			text := cell_text(value)
			cells[c] = text
			widths[c] = max(widths[c], len(text))
		}
		formatted[r] = cells
	}
	if shell.headers {
		for column, i in columns {
			shell_writef("%-*s", widths[i], column)
			if i + 1 < len(columns) do shell_write("  ")
		}
		shell_write("\n")
		for width, i in widths {
			shell_write(strings.repeat("-", width))
			if i + 1 < len(widths) do shell_write("  ")
		}
		shell_write("\n")
	}
	for row in formatted {
		for cell, i in row {
			shell_write(cell)
			if i + 1 < len(columns) {
				shell_write(strings.repeat(" ", widths[i] - len(cell)))
				shell_write("  ")
			}
		}
		shell_write("\n")
	}
}

// csv_cell quotes a CSV field when it needs it; tabs never quote.
csv_cell :: proc(text: string, quoting: bool) -> string {
	if !quoting do return text
	needs_quotes := strings.contains(text, ",") || strings.contains(text, "\"") || strings.contains(text, "\n")
	if !needs_quotes do return text
	escaped, _ := strings.replace_all(text, "\"", "\"\"")
	return fmt.aprintf("\"%s\"", escaped)
}

// print_rows_json writes one JSON array holding every row, so a tool can parse
// the result instead of scraping a table. Values keep their kind: numbers are
// numbers, NULL is null, a blob is {"$blob":"<hex>"} and everything else is the
// text value_format produces.
@(private)
print_rows_json :: proc(rows: [][]db.Value) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_byte(&builder, '[')
	for row, r in rows {
		if r > 0 do strings.write_byte(&builder, ',')
		strings.write_byte(&builder, '[')
		for value, c in row {
			if c > 0 do strings.write_byte(&builder, ',')
			json_value(&builder, value)
		}
		strings.write_byte(&builder, ']')
	}
	strings.write_byte(&builder, ']')
	fmt.println(strings.to_string(builder))
}

@(private)
json_value :: proc(builder: ^strings.Builder, value: db.Value) {
	#partial switch value.kind {
	case .Null, .Default:
		strings.write_string(builder, "null")
	case .Bool:
		strings.write_string(builder, value.b ? "true" : "false")
	case .Int:
		fmt.sbprintf(builder, "%d", value.i)
	case .Uint:
		fmt.sbprintf(builder, "%d", value.u)
	case .Int128, .Uint128:
		strings.write_string(builder, db.value_format(value, context.temp_allocator))
	case .Float:
		if value.f != value.f || value.f - value.f != 0 {
			// NaN and infinity are not JSON numbers: keep them as text so a
			// comparison can still see what the engine produced.
			fmt.sbprintf(builder, "%q", db.value_format(value, context.temp_allocator))
			return
		}
		if value.f == math.floor(value.f) && math.abs(value.f) < 1e15 {
			// A real that happens to be integral keeps its point: a consumer that
			// reads the schema expects a number it can tell from an integer.
			fmt.sbprintf(builder, "%d.0", i64(value.f))
		} else {
			fmt.sbprintf(builder, "%.17g", value.f)
		}
	case .Bytes:
		strings.write_string(builder, `{"$blob":"`)
		for byte in value.bytes do fmt.sbprintf(builder, "%02x", byte)
		strings.write_string(builder, `"}`)
	case:
		json_string(builder, db.value_format(value, context.temp_allocator))
	}
}

@(private)
json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for i := 0; i < len(text); i += 1 {
		byte := text[i]
		switch byte {
		case '"':
			strings.write_string(builder, `\"`)
		case '\\':
			strings.write_string(builder, `\\`)
		case '\n':
			strings.write_string(builder, `\n`)
		case '\r':
			strings.write_string(builder, `\r`)
		case '\t':
			strings.write_string(builder, `\t`)
		case:
			if byte < 0x20 {
				fmt.sbprintf(builder, `\u%04x`, byte)
			} else {
				strings.write_byte(builder, byte)
			}
		}
	}
	strings.write_byte(builder, '"')
}

cell_text :: proc(value: db.Value) -> string {
	if value.kind == .Null do return "NULL"
	return strings.clone(db.value_format(value, context.temp_allocator))
}

// --- Inspect ---------------------------------------------------------------

inspect :: proc(store: ^db.Store) {
	tx := db.tx_begin_read(store)
	defer db.tx_end(tx)
	names := db.store_table_names(store, context.temp_allocator)
	for name in names {
		table, err := db.tx_table(tx, name)
		if !db.error_ok(err) do continue
		fmt.printfln("table %s (%d rows)", name, db.table_row_count(table))
		for column in table.schema.columns {
			flags := strings.builder_make()
			defer strings.builder_destroy(&flags)
			if column.unique do strings.write_string(&flags, " unique")
			if column.not_null do strings.write_string(&flags, " not null")
			if column.auto_increment do strings.write_string(&flags, " autoincrement")
			fmt.printfln(
				"  %-20s %-10s%s",
				column.name,
				db.column_type_name(column.type),
				strings.to_string(flags),
			)
		}
		if len(table.schema.primary_key) > 0 {
			names := strings.builder_make()
			defer strings.builder_destroy(&names)
			for position, i in table.schema.primary_key {
				if i > 0 do strings.write_string(&names, ", ")
				strings.write_string(&names, table.schema.columns[position].name)
			}
			fmt.printfln("  primary key (%s)", strings.to_string(names))
		}
		for index in table.schema.indexes {
			fmt.printfln("  index %s%s", index.name, index.unique ? " (unique)" : "")
		}
		memory := db.table_memory(table)
		fmt.printfln(
			"  storage %d bytes in rows, %d index entries (%d bytes)",
			memory.row_bytes,
			memory.index_entries,
			memory.index_bytes,
		)
		fmt.println()
	}
	memory := db.store_memory(store)
	fmt.printfln(
		"total %d rows, %d bytes in rows, %d index entries (%d bytes)",
		memory.rows,
		memory.row_bytes,
		memory.index_entries,
		memory.index_bytes,
	)
}

check :: proc(store: ^db.Store) {
	tx := db.tx_begin_read(store)
	defer db.tx_end(tx)
	names := db.store_table_names(store, context.temp_allocator)
	total := 0
	for name in names {
		count, count_err := db.tx_row_count(tx, name)
		if !db.error_ok(count_err) do fail(count_err)
		total += count
	}
	fmt.printfln("commit sequence: %d", store.commit_seq)
	fmt.printfln("tables: %d", len(names))
	fmt.printfln("rows: %d", total)
	fmt.printfln("log: %s", store.path)
}

// savepoint_name reads the savepoint named by a SAVEPOINT or RELEASE line.
@(private)
savepoint_name :: proc(line_in: string) -> string {
	line := strings.trim_right(line_in, "; \t")
	words := strings.fields(line, context.temp_allocator)
	if len(words) == 0 do return ""
	return words[len(words) - 1]
}

// --- REPL ------------------------------------------------------------------

repl :: proc(store: ^db.Store) {
	fmt.printfln("miraidb - %s", store.path)
	fmt.println("Type .help for help, .quit to leave.")
	session: ^db.Tx = nil
	defer if session != nil do db.tx_rollback(session)

	buffer := make([dynamic]u8)
	defer delete(buffer)

	for {
		if session != nil {
			fmt.print("miraidb*> ")
		} else {
			fmt.print("miraidb> ")
		}
		line, ok := read_line(&buffer)
		if !ok do break
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 do continue

		if trimmed[0] == '.' {
			handled, quit := repl_command(store, trimmed, &session)
			if quit do break
			if handled do continue
		}

		upper := strings.to_upper(trimmed)
		if strings.has_prefix(upper, "BEGIN") {
			if session != nil {
				fmt.eprintln("a transaction is already open")
				continue
			}
			session = db.tx_begin_write(store)
			fmt.println("begin")
			continue
		}
		if strings.has_prefix(upper, "COMMIT") || strings.has_prefix(upper, "END") {
			if session == nil {
				fmt.eprintln("no transaction is open")
				continue
			}
			err := db.tx_commit(session)
			session = nil
			if !db.error_ok(err) do fail(err)
			fmt.println("commit")
			continue
		}
		if strings.has_prefix(upper, "ROLLBACK") {
			if session == nil {
				fmt.eprintln("no transaction is open")
				continue
			}
			words := strings.fields(trimmed, context.temp_allocator)
			name := ""
			for word, index in words {
				if !strings.equal_fold(word, "to") do continue
				if index + 1 < len(words) do name = strings.trim_right(words[index + 1], ";")
				break
			}
			if len(name) > 0 {
				if err := db.tx_rollback_to_savepoint(session, name); !db.error_ok(err) {
					fmt.eprintfln("error: %s", err.message)
					continue
				}
				fmt.printfln("rollback to %s", name)
				continue
			}
			db.tx_rollback(session)
			session = nil
			fmt.println("rollback")
			continue
		}
		if strings.has_prefix(upper, "SAVEPOINT") {
			if session == nil {
				fmt.eprintln("no transaction is open")
				continue
			}
			name := savepoint_name(trimmed)
			if err := db.tx_savepoint(session, name); !db.error_ok(err) {
				fmt.eprintfln("error: %s", err.message)
				continue
			}
			fmt.printfln("savepoint %s", name)
			continue
		}
		if strings.has_prefix(upper, "RELEASE") {
			if session == nil {
				fmt.eprintln("no transaction is open")
				continue
			}
			name := savepoint_name(trimmed)
			if err := db.tx_release_savepoint(session, name); !db.error_ok(err) {
				fmt.eprintfln("error: %s", err.message)
				continue
			}
			fmt.printfln("release %s", name)
			continue
		}

		started := time.now()
		result: db.Sql_Result
		err: db.Error
		if session != nil {
			result, err = db.sql_execute_in_tx(session, trimmed)
		} else {
			result, err = db.sql_execute(store, trimmed)
		}
		if !db.error_ok(err) {
			fmt.eprintfln("error: %s", err.message)
			continue
		}
		print_result(result)
		// A piped session is often watched live, and an abort must not swallow
		// the statements that already succeeded.
		os.flush(os.stdout)
		db.sql_result_destroy(&result)
		if shell.timer {
			fmt.printfln("Run Time: real %.3f s", time.duration_seconds(time.since(started)))
		}
	}
}

repl_command :: proc(store: ^db.Store, line: string, session: ^^db.Tx) -> (handled: bool, quit: bool) {
	words := strings.fields(line, context.temp_allocator)
	if len(words) == 0 do return true, false
	switch words[0] {
	case ".quit", ".exit":
		return true, true
	case ".help":
		fmt.println(USAGE)
		return true, false
	case ".tables":
		names := db.store_table_names(store, context.temp_allocator)
		for name in names do fmt.println(name)
		return true, false
	case ".schema":
		if len(words) < 2 {
			fmt.println("usage: .schema <table>")
			return true, false
		}
		show_schema(store, words[1])
		return true, false
	case ".begin":
		if session^ == nil {
			session^ = db.tx_begin_write(store)
			fmt.println("begin")
		} else {
			fmt.eprintln("a transaction is already open")
		}
		return true, false
	case ".commit":
		if session^ != nil {
			err := db.tx_commit(session^)
			session^ = nil
			if !db.error_ok(err) do fail(err)
			fmt.println("commit")
		} else {
			fmt.eprintln("no transaction is open")
		}
		return true, false
	case ".rollback":
		if session^ != nil {
			db.tx_rollback(session^)
			session^ = nil
			fmt.println("rollback")
		} else {
			fmt.eprintln("no transaction is open")
		}
		return true, false
	case ".mode":
		if len(words) < 2 {
			fmt.printfln("mode: %s", shell_mode_name(shell.mode))
			return true, false
		}
		mode := strings.to_lower(words[1], context.temp_allocator)
		switch mode {
		case "column", "columns":
			shell.mode = .Column
		case "list":
			shell.mode = .List
		case "csv":
			shell.mode = .Csv
		case "tabs":
			shell.mode = .Tabs
		case "json":
			shell.mode = .Json
		case:
			fmt.eprintfln("unknown mode %q (column, list, csv, tabs, json)", words[1])
			return true, false
		}
		fmt.printfln("mode: %s", shell_mode_name(shell.mode))
		return true, false
	case ".headers":
		if len(words) < 2 {
			fmt.printfln("headers: %s", shell.headers ? "on" : "off")
			return true, false
		}
		shell.headers = strings.equal_fold(words[1], "on") || strings.equal_fold(words[1], "1") || strings.equal_fold(words[1], "true")
		fmt.printfln("headers: %s", shell.headers ? "on" : "off")
		return true, false
	case ".timer":
		if len(words) < 2 {
			fmt.printfln("timer: %s", shell.timer ? "on" : "off")
			return true, false
		}
		shell.timer = strings.equal_fold(words[1], "on") || strings.equal_fold(words[1], "1")
		fmt.printfln("timer: %s", shell.timer ? "on" : "off")
		return true, false
	case ".output":
		if len(words) < 2 || strings.equal_fold(words[1], "stdout") {
			if shell.output != nil {
				os.close(shell.output)
				shell.output = nil
				delete(shell.output_path)
				shell.output_path = ""
			}
			fmt.println("output: stdout")
			return true, false
		}
		file, open_err := os.open(words[1], {.Write, .Create, .Trunc})
		if open_err != nil {
			fmt.eprintfln("cannot open %s: %v", words[1], open_err)
			return true, false
		}
		if shell.output != nil do os.close(shell.output)
		if len(shell.output_path) > 0 do delete(shell.output_path)
		shell.output = file
		shell.output_path = strings.clone(words[1])
		fmt.printfln("output: %s", words[1])
		return true, false
	case ".dump":
		dump_table(store, len(words) > 1 ? words[1] : "")
		return true, false
	case ".import":
		if len(words) < 3 {
			fmt.println("usage: .import <file.csv> <table>")
			return true, false
		}
		import_csv(store, words[1], words[2], session)
		return true, false
	case ".read":
		if len(words) < 2 {
			fmt.println("usage: .read <file>")
			return true, false
		}
		read_script(store, words[1], session)
		return true, false
	}
	fmt.eprintfln("unknown command %q", words[0])
	return true, false
}

// sql_literal renders a value the way a dump writes it.
sql_literal :: proc(value: db.Value) -> string {
	#partial switch value.kind {
	case .Null, .Default:
		return "NULL"
	case .String:
		escaped, _ := strings.replace_all(value.s, "'", "''")
		return fmt.aprintf("'%s'", escaped)
	case .Bytes:
		builder := strings.builder_make()
		strings.write_string(&builder, "x'")
		for byte in value.bytes do fmt.sbprintf(&builder, "%02x", byte)
		strings.write_string(&builder, "'")
		out := strings.clone(strings.to_string(builder))
		strings.builder_destroy(&builder)
		return out
	case .Bool:
		return value.b ? "1" : "0"
	}
	return db.value_format(value, context.allocator)
}

// dump_table writes the schema and rows of one table (or every table) as SQL.
dump_table :: proc(store: ^db.Store, only: string) {
	tx := db.tx_begin_read(store)
	defer db.tx_end(tx)
	names := db.store_table_names(store, context.temp_allocator)
	for name in names {
		if db.is_system_table(name) do continue
		if len(only) > 0 && !strings.equal_fold(name, only) do continue
		table, table_err := db.tx_table(tx, name)
		if !db.error_ok(table_err) do continue
		shell_write("CREATE TABLE ")
		shell_write(name)
		shell_write(" (")
		for column, i in table.schema.columns {
			if i > 0 do shell_write(", ")
			shell_writef("%s %s", column.name, db.column_type_name(column.type))
			if column.unique do shell_write(" UNIQUE")
			if column.not_null do shell_write(" NOT NULL")
			if column.auto_increment do shell_write(" AUTOINCREMENT")
		}
		if len(table.schema.primary_key) > 0 {
			shell_write(", PRIMARY KEY (")
			for position, i in table.schema.primary_key {
				if i > 0 do shell_write(", ")
				shell_write(table.schema.columns[position].name)
			}
			shell_write(")")
		}
		shell_write(");\n")
		rows := make([dynamic]db.Row)
		defer delete(rows)
		if collect_err := db.tx_collect(tx, name, &rows); !db.error_ok(collect_err) do continue
		for row in rows {
			shell_write("INSERT INTO ")
			shell_write(name)
			shell_write(" VALUES (")
			for value, i in row.values {
				if i > 0 do shell_write(", ")
				shell_write(sql_literal(value))
			}
			shell_write(");\n")
		}
	}
}

// csv_fields splits one CSV line, honoring quotes and doubled quotes.
csv_fields :: proc(line: string, out: ^[dynamic]string) {
	builder := strings.builder_make()
	quoted := false
	i := 0
	field_started := false
	for i <= len(line) {
		if i == len(line) {
			append(out, strings.clone(strings.to_string(builder)))
			strings.builder_reset(&builder)
			break
		}
		c := line[i]
		if quoted {
			if c == '"' {
				if i + 1 < len(line) && line[i + 1] == '"' {
					strings.write_byte(&builder, '"')
					i += 2
					continue
				}
				quoted = false
				i += 1
				continue
			}
			strings.write_byte(&builder, c)
			i += 1
			continue
		}
		if c == '"' && !field_started {
			quoted = true
			field_started = true
			i += 1
			continue
		}
		if c == ',' {
			append(out, strings.clone(strings.to_string(builder)))
			strings.builder_reset(&builder)
			field_started = false
			i += 1
			continue
		}
		strings.write_byte(&builder, c)
		field_started = true
		i += 1
	}
	strings.builder_destroy(&builder)
}

// csv_value reads a CSV field as the column's type when the text allows it, the
// affinity a CSV import is expected to apply; anything else stays text.
csv_value :: proc(field: string, kind: db.Type_Kind) -> db.Value {
	#partial switch kind {
	case .Int:
		if parsed, ok := strconv.parse_int(field, 10); ok do return db.value_int(i64(parsed))
	case .Float:
		if parsed, ok := strconv.parse_f64(field); ok do return db.value_float(parsed)
	case .Bool:
		if field == "1" || strings.equal_fold(field, "true") do return db.value_bool(true)
		if field == "0" || strings.equal_fold(field, "false") do return db.value_bool(false)
	}
	return db.value_string(field)
}

// import_csv inserts the rows of a CSV file into a table, one statement per row
// with the fields as parameters, so the table's types and checks apply.
import_csv :: proc(store: ^db.Store, path, table_name: string, session: ^^db.Tx) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("cannot read %s: %v", path, read_err)
		return
	}
	tx := db.tx_begin_read(store)
	table, table_err := db.tx_table(tx, table_name)
	column_count := 0
	column_types: []db.Type_Kind
	if db.error_ok(table_err) {
		column_count = len(table.schema.columns)
		column_types = make([]db.Type_Kind, column_count, context.temp_allocator)
		for column, i in table.schema.columns do column_types[i] = column.type.kind
	}
	db.tx_end(tx)
	if column_count == 0 {
		fmt.eprintfln("table %s was not found", table_name)
		return
	}
	statement := strings.builder_make()
	defer strings.builder_destroy(&statement)
	fmt.sbprintf(&statement, "INSERT INTO %s VALUES (", table_name)
	for index in 0 ..< column_count {
		if index > 0 do strings.write_string(&statement, ", ")
		strings.write_string(&statement, "?")
	}
	strings.write_byte(&statement, ')')
	sql := strings.to_string(statement)

	text := string(data)
	start := 0
	line_number := 0
	inserted := 0
	for i in 0 ..= len(text) {
		if i < len(text) && text[i] != '\n' do continue
		line := strings.trim_right(text[start:i], "\r")
		start = i + 1
		line_number += 1
		if len(strings.trim_space(line)) == 0 do continue
		fields := make([dynamic]string, 0, column_count, context.temp_allocator)
		csv_fields(line, &fields)
		if len(fields) != column_count {
			fmt.eprintfln("line %d has %d fields, %s has %d", line_number, len(fields), table_name, column_count)
			continue
		}
		values := make([]db.Value, len(fields), context.temp_allocator)
		for field, index in fields do values[index] = csv_value(field, column_types[index])
		result: db.Sql_Result
		err: db.Error
		if session^ != nil {
			result, err = db.sql_execute_in_tx_params(session^, sql, values)
		} else {
			result, err = db.sql_execute_params(store, sql, values)
		}
		if !db.error_ok(err) {
			fmt.eprintfln("line %d: %s", line_number, err.message)
			db.sql_result_destroy(&result)
			continue
		}
		inserted += result.affected
		db.sql_result_destroy(&result)
	}
	fmt.printfln("imported %d rows into %s", inserted, table_name)
}

// read_script runs the statements of a file, one per line, as the prompt would.
read_script :: proc(store: ^db.Store, path: string, session: ^^db.Tx) {
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("cannot read %s: %v", path, read_err)
		return
	}
	text := string(data)
	start := 0
	for i in 0 ..= len(text) {
		if i < len(text) && text[i] != '\n' do continue
		line := strings.trim_space(text[start:i])
		start = i + 1
		if len(line) == 0 || strings.has_prefix(line, "--") do continue
		line = strings.trim_right(line, "; \t")
		if len(line) == 0 do continue
		result: db.Sql_Result
		err: db.Error
		if session^ != nil {
			result, err = db.sql_execute_in_tx(session^, line)
		} else {
			result, err = db.sql_execute(store, line)
		}
		if !db.error_ok(err) {
			fmt.eprintfln("error: %s", err.message)
			continue
		}
		print_result(result)
		db.sql_result_destroy(&result)
	}
}

show_schema :: proc(store: ^db.Store, name: string) {
	tx := db.tx_begin_read(store)
	defer db.tx_end(tx)
	table, err := db.tx_table(tx, name)
	if !db.error_ok(err) {
		fmt.eprintfln("error: %s", err.message)
		return
	}
	fmt.printf("CREATE TABLE %s (", name)
	for column, i in table.schema.columns {
		if i > 0 do fmt.print(", ")
		fmt.printf("%s %s", column.name, db.column_type_name(column.type))
		if column.unique do fmt.print(" UNIQUE")
		if column.not_null do fmt.print(" NOT NULL")
		if column.auto_increment do fmt.print(" AUTOINCREMENT")
	}
	if len(table.schema.primary_key) > 0 {
		fmt.print(", PRIMARY KEY (")
		for position, i in table.schema.primary_key {
			if i > 0 do fmt.print(", ")
			fmt.print(table.schema.columns[position].name)
		}
		fmt.print(")")
	}
	fmt.println(");")
}

// read_line reads one line from standard input, without its terminator.
read_line :: proc(buffer: ^[dynamic]u8) -> (string, bool) {
	clear(buffer)
	one: [1]u8
	for {
		n, err := os.read(os.stdin, one[:])
		if n <= 0 || err != nil {
			// A final statement without a trailing newline is still a statement:
			// a piped script must not lose its last line.
			return string(buffer[:]), len(buffer) > 0
		}
		if one[0] == '\n' {
			break
		}
		if one[0] == '\r' do continue
		append(buffer, one[0])
	}
	return string(buffer[:]), true
}
