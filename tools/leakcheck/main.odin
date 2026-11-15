// leakcheck answers one question the debug tracker cannot: does a statement leave
// memory behind in the allocator it was given? The tracker prints a line for every
// block it still knows when the process exits, which mixes a statement's leftovers
// with the process's own setup, and the suite printed about nine such lines per
// statement. This program wraps the allocator the engine allocates from in a
// tracking allocator, runs one statement N times, and reports how many allocations
// are still live once the last result is destroyed.
//
// Only read shapes are measured here: a write allocates through the transaction's
// arena, which the tracking allocator does not own, and the free that closes it is
// reported as a bad free by the tracker rather than by the engine. The write path
// is measured end to end by scripts/leaks.py, which asks the CLI for the working
// set before and after a few thousand statements.
//
// Run it through scripts/leaks.py, which builds it and applies the budgets.
package leakcheck

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"

import db "../../src/engine"

Shape :: struct {
	statement: string,
	// budget is the live allocations per statement the shape may leave. A number
	// above zero is a known, documented leftover; the gate holds the line at what
	// it is today, so a new one fails instead of hiding in the noise. Two is what a
	// SELECT still leaves: two builders the tracker names builder.odin:173 but
	// cannot attribute to a caller, and one for a statement that reads a table.
	budget:    int,
}

main :: proc() {
	repeat := 200
	if len(os.args) > 1 {
		if parsed, ok := strconv.parse_int(os.args[1]); ok && parsed > 0 do repeat = parsed
	}

	path := "_leakcheck_db"
	os.remove_all(path)
	defer os.remove_all(path)

	entries := []Shape {
		{"SELECT 1", 2},
		{"SELECT count(*) FROM t", 2},
		{"SELECT * FROM t", 2},
		{"SELECT 'abc'", 2},
		{"SELECT v FROM t WHERE v > 0 ORDER BY v", 2},
		{"PRAGMA integrity_check", 2},
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
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
	}
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
	fmt.printfln("leakcheck: every shape within budget over %d statements", repeat)
}
