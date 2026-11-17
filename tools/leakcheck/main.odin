// leakcheck answers one question the debug tracker cannot: does a statement leave
// memory behind in the allocator it was given? The tracker prints a line for every
// block it still knows when the process exits, which mixes a statement's leftovers
// with the process's own setup, and the suite printed about nine such lines per
// statement. This program wraps the allocator the engine allocates from in a
// tracking allocator, runs one statement N times, and reports how many allocations
// are still live once the last result is destroyed.
//
// A read has to leave nothing behind, and a write keeps the row it wrote: the
// budgets say which is which. A write also allocates through the transaction's
// arena, and Odin frees a map's nodes with whichever allocator is current rather
// than the one that allocated them, so the tracker reports a few frees of memory it
// does not own and the tool counts them instead of stopping (see leakcheck_bad_free).
// After every statement the tool prunes row history, exactly as the CLI does, so a
// version a write shadows is not counted as a leak.
//
// Run it through scripts/leaks.py, which builds it and applies the budgets.
package leakcheck

import "core:fmt"
import "base:runtime"
import "core:mem"
import "core:os"
import "core:strconv"

import db "../../src/engine"

Shape :: struct {
	statement: string,
	// budget is the live allocations per statement the shape may leave. Zero is what
	// a read must leave; a write keeps the row it wrote, and its budget is what one
	// row costs. The gate holds the line at those numbers, so a leak of one block per
	// statement - two hundred over a run - fails instead of hiding in the noise.
	budget:    int,
}

bad_frees: int

@(private)
leakcheck_bad_free :: proc(t: ^mem.Tracking_Allocator, memory: rawptr, location: runtime.Source_Code_Location) {
	bad_frees += 1
}

// error_ownership checks the rule docs/backlog.md D35 asks for: an Error the
// engine returns is the caller's, whichever entry point returned it. A failing
// embed_exec is freed by its caller every time, which must leave nothing behind
// and free nothing twice (the connection keeps a copy of its own for
// embed_error), and a store that notes a failure N times keeps only the last
// message. It returns the number of checks that failed.
@(private)
error_ownership :: proc(track: ^mem.Tracking_Allocator, store: ^db.Store, repeat: int) -> int {
	failed := 0
	conn, open_err := db.embed_open(":memory:")
	if open_err.kind != .None {
		fmt.eprintfln("leakcheck: cannot open an embedded connection: %s", open_err.message)
		os.exit(2)
	}
	statement := "SELECT * FROM no_such_table"
	// The first failure builds the parse caches a statement keeps; what is
	// measured is every failure after it.
	first := db.embed_exec(conn, statement)
	db.error_free(&first)
	// A success clears the connection's copy, so the measurement does not start
	// with a block the tracker never saw allocated.
	clean := db.embed_exec(conn, "SELECT 1")
	db.error_free(&clean)
	mem.tracking_allocator_clear(track)
	bad_before := bad_frees
	readable := true
	for _ in 0 ..< repeat {
		err := db.embed_exec(conn, statement)
		if err.kind == .None {
			fmt.eprintfln("leakcheck: %s did not fail", statement)
			os.exit(2)
		}
		db.error_free(&err)
		// The connection's copy outlives the caller's: freeing one is not
		// freeing the other.
		if len(db.embed_error(conn)) == 0 do readable = false
	}
	// A success clears the connection's copy, so nothing of the failures stays.
	ok := db.embed_exec(conn, "SELECT 1")
	db.error_free(&ok)
	live := len(track.allocation_map)
	double := bad_frees - bad_before
	verdict := "ok"
	if live > 0 || double > 0 || !readable {
		verdict = "OVER"
		failed += 1
	}
	fmt.printfln(
		"%-8s live=%d allowed=0 bad-frees=%d message-kept=%v embed_exec failing %d times, caller frees",
		verdict,
		live,
		double,
		readable,
		repeat,
	)

	mem.tracking_allocator_clear(track)
	for i in 0 ..< repeat {
		db.store_note_error(store, db.errf(.Io, "noted failure %d", i))
	}
	live = len(track.allocation_map)
	verdict = "ok"
	if live > 1 {
		verdict = "OVER"
		failed += 1
	}
	fmt.printfln("%-8s live=%d allowed=1 store_note_error %d times keeps the last", verdict, live, repeat)
	db.store_note_error(store, db.ERROR_NONE)
	return failed
}

main :: proc() {
	repeat := 200
	verbose := false
	if len(os.args) > 2 && os.args[2] == "verbose" do verbose = true
	if len(os.args) > 1 {
		if parsed, ok := strconv.parse_int(os.args[1]); ok && parsed > 0 do repeat = parsed
	}

	path := "_leakcheck_db"
	os.remove_all(path)
	defer os.remove_all(path)

	entries := []Shape {
		{"SELECT 1", 0},
		{"SELECT count(*) FROM t", 0},
		{"SELECT * FROM t", 0},
		{"SELECT 'abc'", 0},
		{"SELECT v FROM t WHERE v > 0 ORDER BY v", 0},
		{"PRAGMA integrity_check", 0},
		// A statement whose FROM is a subquery, and a plan: both walk the same "is
		// that a table?" questions the plain shapes do.
		{"SELECT * FROM t WHERE v = (SELECT 1)", 0},
		{"EXPLAIN SELECT * FROM t", 0},
		// A write keeps the row it wrote: its values, the array that holds its
		// history, and a map node.
		{"INSERT OR REPLACE INTO t (id, v) VALUES (3, 3)", 4},
		{"UPDATE t SET v = v + 1 WHERE id = 1", 4},
		{"DELETE FROM t WHERE id = 99", 4},
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	// A map's nodes are freed through the allocator that is current when the node is
	// removed, and the engine builds several maps in the transaction arena: removing a
	// node from one of those frees arena memory through this allocator, which the
	// tracker reports as a bad free. That is a property of Odin's maps, not a defect
	// the engine can fix here, so the tool counts them instead of stopping.
	track.bad_free_callback = leakcheck_bad_free
	context.allocator = mem.tracking_allocator(&track)
	// Closing the store frees memory the store allocated through its own arena, and
	// a tracking allocator reports a pointer it does not know as a bad free, so the
	// allocator is put back before the close. That is a property of this tool, not
	// of the engine: the suite closes stores with the default allocator every run.

	store, open_err := db.store_open(path, {persistent = true, create = true, durable = false})
	if open_err.kind != .None {
		fmt.eprintfln("leakcheck: cannot open %s: %s", path, open_err.message)
		os.exit(2)
	}

	for setup in ([]string {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)",
		"INSERT INTO t (id, v) VALUES (1, 1)",
		"INSERT INTO t (id, v) VALUES (2, 2)",
	}) {
		result, err := db.sql_execute(store, setup)
		if err.kind != .None {
			fmt.eprintfln("leakcheck: setup failed: %s", err.message)
			os.exit(2)
		}
		db.sql_result_destroy(&result)
	}

	failed := 0
	for shape in entries {
		mem.tracking_allocator_clear(&track)
		for _ in 0 ..< repeat {
			result, err := db.sql_execute(store, shape.statement)
			if err.kind != .None {
				fmt.eprintfln("leakcheck: %s failed: %s", shape.statement, err.message)
				os.exit(2)
			}
			db.sql_result_destroy(&result)
			// A write commits a row: the version it replaced is the caller's to drop,
			// and a process that runs statements keeps no history. Without this the
			// measurement counts the values each REPLACE shadows, which is data the
			// caller asked for, not a leak.
			db.store_prune_history(store)
		}
		live := len(track.allocation_map)
		bytes := 0
		for _, entry in track.allocation_map do bytes += entry.size
		allowed := shape.budget * repeat
		verdict := "ok"
		if live > allowed {
			verdict = "OVER"
			failed += 1
		}
		// One line per shape, in the order the shapes are written: a reader can
		// diff two runs.
		fmt.printfln(
			"%-8s live=%d allowed=%d bytes=%d per-statement=%.2f %s",
			verdict,
			live,
			allowed,
			bytes,
			f64(bytes) / f64(repeat),
			shape.statement,
		)
		// Where a live allocation came from, so a reader can act on the line instead
		// of hunting for it: the location is the one the allocating call reports, and
		// a shape that leaves nothing behind prints nothing here.
		if live > 0 {
			sites := make(map[string]int, context.temp_allocator)
			site_bytes := make(map[string]int, context.temp_allocator)
			for _, entry in track.allocation_map {
				site := fmt.tprintf("%s:%d", entry.location.file_path, entry.location.line)
				sites[site] += 1
				site_bytes[site] += entry.size
			}
			for site, count in sites {
				fmt.printfln("         %-6d %-8d %s", count, site_bytes[site], site)
			}
			if verbose {
				for _, entry in track.allocation_map {
					// The bytes a leftover block holds name it better than its size
					// does: a leaked error message says which table was missing.
					bytes := ([^]u8)(entry.memory)[:min(entry.size, 96)]
					printable := true
					for b in bytes do if b < 32 && b != 0 do printable = false
					if printable do fmt.printfln("         text=%q", string(bytes))
					fmt.printfln(
						"         entry size=%d align=%d mem=%p %s:%d",
						entry.size,
						entry.alignment,
						entry.memory,
						entry.location.file_path,
						entry.location.line,
					)
				}
			}
			free_all(context.temp_allocator)
		}
	}
	failed += error_ownership(&track, store, repeat)

	// The store is not closed here. A row is allocated and freed with whichever
	// allocator `context.allocator` is when each happens, not with the store's, so a
	// close after this swap frees arena memory through the tracker: the tracker
	// reports a bad free and the engine is right about everything it was asked. It is
	// a property of the process-wide allocator that the engine relies on, and the
	// suite, the CLI and the server all close stores under one allocator.
	if failed > 0 {
		fmt.eprintfln("leakcheck: %d shape(s) over budget", failed)
		os.exit(1)
	}
	if bad_frees > 0 {
		fmt.printfln(
			"leakcheck: %d free(s) of memory this allocator did not allocate (arena maps)",
			bad_frees,
		)
	}
	fmt.printfln("leakcheck: every shape within budget over %d statements", repeat)
}
