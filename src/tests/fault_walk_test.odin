package tests

import "core:fmt"
import "core:os"
import "core:testing"

import db "../engine"

// Fault injection beyond the log (D8): every operation of a snapshot, a
// compaction, a log rotation and a page flush is broken in turn, and the
// database reopened without the fault holds exactly the commits that reported
// success.

@(private = "file")
FAULT_KINDS := [?]db.Fault_Kind{.Open, .Write, .Sync, .Truncate, .Remove, .Rename}

@(private = "file")
fault_exec :: proc(store: ^db.Store, sql: string) -> bool {
	result, err := db.sql_execute(store, sql)
	defer db.error_free(&err)
	defer db.sql_result_destroy(&result)
	return db.error_ok(err)
}

// fault_count reopens path on the plain file system and counts t; -1 when the
// database does not open or has no table t.
@(private = "file")
fault_count :: proc(memory: ^db.Vfs, path: string) -> i64 {
	store, open_err := db.store_open(path, {persistent = true, create = false, durable = false, vfs = memory})
	if !db.error_ok(open_err) {
		db.error_free(&open_err)
		return -1
	}
	defer db.store_close(store)
	result, err := db.sql_execute(store, "SELECT count(*) FROM t")
	defer db.error_free(&err)
	defer db.sql_result_destroy(&result)
	if !db.error_ok(err) do return -1
	return result.rows[0][0].i
}

// A snapshot or a compaction broken at any operation leaves every commit before
// it, and the commits after it land or fail as they report.
@(test)
test_snapshot_and_compaction_faults :: proc(t: ^testing.T) {
	memory := db.vfs_memory_new()
	defer db.vfs_memory_destroy(memory)
	fault := db.vfs_fault_new(memory)
	defer db.vfs_fault_destroy(fault)
	fired := 0
	for compact in ([?]bool{false, true}) {
		for kind in FAULT_KINDS {
			for nth in u64(1) ..< 200 {
				path := fmt.tprintf("_snapshot_fault_%v_%v_%d", compact, kind, nth)
				store, open_err := db.store_open(path, {persistent = true, create = true, durable = true, vfs = fault})
				if !testing.expectf(t, db.error_ok(open_err), "%s: open: %s", path, open_err.message) {
					db.error_free(&open_err)
					return
				}
				landed: i64 = 0
				testing.expect(t, fault_exec(store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"))
				for i in 0 ..< 5 {
					if fault_exec(store, fmt.tprintf("INSERT INTO t (v) VALUES ('before %d')", i)) do landed += 1
				}
				db.vfs_fault_arm(fault, kind, nth)
				step_err := compact ? db.store_compact(store) : db.store_snapshot(store)
				db.error_free(&step_err)
				for i in 0 ..< 3 {
					if fault_exec(store, fmt.tprintf("INSERT INTO t (v) VALUES ('after %d')", i)) do landed += 1
				}
				reached := db.vfs_fault_calls(fault) >= nth
				if db.vfs_fault_fired(fault) do fired += 1
				db.vfs_fault_arm(fault, .None, 0)
				db.store_close(store)
				got := fault_count(memory, path)
				testing.expectf(t, got == landed, "%s: %d rows after reopening, %d commits reported success", path, got, landed)
				if !reached || testing.failed(t) do break
			}
			if testing.failed(t) do return
		}
	}
	testing.expectf(t, fired > 0, "no fault was reached")
}

// A log that passes its segment size opens the next segment; breaking any
// operation of a workload that rotates twice loses no commit that reported
// success and keeps none that reported failure.
@(test)
test_log_rotation_faults :: proc(t: ^testing.T) {
	memory := db.vfs_memory_new()
	defer db.vfs_memory_destroy(memory)
	fault := db.vfs_fault_new(memory)
	defer db.vfs_fault_destroy(fault)
	fired := 0
	rotated := false
	for kind in ([?]db.Fault_Kind{.Open, .Write, .Sync}) {
		for nth in u64(1) ..< 200 {
			path := fmt.tprintf("_rotation_fault_%v_%d", kind, nth)
			store, open_err := db.store_open(path, {persistent = true, create = true, durable = true, vfs = fault})
			if !testing.expectf(t, db.error_ok(open_err), "%s: open: %s", path, open_err.message) {
				db.error_free(&open_err)
				return
			}
			testing.expect(t, fault_exec(store, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"))
			db.vfs_fault_arm(fault, kind, nth)
			landed: i64 = 0
			// Twenty records of 32 KiB fill more than two segments of 256 KiB.
			for i in 0 ..< 20 {
				if fault_exec(store, fmt.tprintf("INSERT INTO t (v) VALUES (printf('%%032768d', %d))", i)) do landed += 1
			}
			reached := db.vfs_fault_calls(fault) >= nth
			if db.vfs_fault_fired(fault) do fired += 1
			db.vfs_fault_arm(fault, .None, 0)
			if db.store_log_bytes(store) > 2 * 256 * 1024 do rotated = true
			db.store_close(store)
			got := fault_count(memory, path)
			testing.expectf(t, got == landed, "%s: %d rows after reopening, %d commits reported success", path, got, landed)
			if !reached || testing.failed(t) do break
		}
		if testing.failed(t) do return
	}
	testing.expect(t, rotated, "the workload never rotated its log")
	testing.expectf(t, fired > 0, "no fault was reached")
}

@(private = "file")
page_kill_summary :: proc(store: ^db.Store) -> string {
	result, err := db.sql_execute(store, "SELECT count(*), sum(id), sum(length(v)), (SELECT count(*) FROM t WHERE v > '00000000000000000000000000000000000000000000000000') FROM t")
	defer db.error_free(&err)
	defer db.sql_result_destroy(&result)
	if !db.error_ok(err) do return fmt.tprintf("(error %v)", err.kind)
	row := result.rows[0]
	return fmt.tprintf("%v|%v|%v|%v", row[0].i, row[1].i, row[2].i, row[3].i)
}

// A process killed while it writes the pages of a paged database, at any page
// of a commit's eviction or of the flush at close, reopens with every commit
// that reported success: the pages a header names are on disk before it, and
// a file whose header the flush never reached is rebuilt from the log.
@(test)
test_page_flush_kill :: proc(t: ^testing.T) {
	// The faults are injected, so syncing the log buys this test nothing.
	options := db.Store_Options{persistent = true, create = true, durable = false, paged_tables = true, page_frames = 8}
	workload := [?]string {
		"UPDATE t SET v = v || 'x' WHERE id % 3 = 0",
		"INSERT INTO t (v) SELECT printf('%0300d', id) FROM t WHERE id <= 50",
		"DELETE FROM t WHERE id % 7 = 0",
		"UPDATE t SET v = substr(v, 1, 120) WHERE id % 5 = 1",
	}
	killed := 0
	// Every write of the first commits, then one in thirteen: the flush at close is
	// a few hundred writes of the same kind.
	for nth := 1; nth < 2000; nth += nth < 30 ? 1 : 13 {
		path := fmt.tprintf("_test_page_kill_%d", nth)
		os.remove_all(path)
		defer os.remove_all(path)
		model, model_err := db.store_open("", {persistent = false})
		if !testing.expectf(t, db.error_ok(model_err), "model: %s", model_err.message) do return
		defer db.store_close(model)
		{
			store, open_err := db.store_open(path, options)
			if !testing.expectf(t, db.error_ok(open_err), "%s: open: %s", path, open_err.message) do return
			for setup in ([?]string{"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", "CREATE INDEX t_v ON t (v)", "INSERT INTO t (v) SELECT printf('%0200d', value) FROM generate_series(1, 300)"}) {
				testing.expect(t, fault_exec(store, setup))
				testing.expect(t, fault_exec(model, setup))
			}
			db.store_close(store)
		}
		store, open_err := db.store_open(path, options)
		if !testing.expectf(t, db.error_ok(open_err), "%s: reopen: %s", path, open_err.message) do return
		db.page_fault_arm(nth)
		for sql in workload {
			if fault_exec(store, sql) do testing.expect(t, fault_exec(model, sql))
		}
		// The close flushes the pages; the fault, armed through it, is the kill.
		db.store_close(store)
		reached := db.page_fault_calls() >= nth
		db.page_fault_arm(0)
		if reached do killed += 1
		reopened, reopen_err := db.store_open(path, options)
		if !testing.expectf(t, db.error_ok(reopen_err), "%s: open after the kill: %s", path, reopen_err.message) {
			db.error_free(&reopen_err)
			return
		}
		got, want := page_kill_summary(reopened), page_kill_summary(model)
		db.store_close(reopened)
		testing.expectf(t, got == want, "%s: got %s, want %s", path, got, want)
		if !reached || testing.failed(t) do break
	}
	testing.expectf(t, killed > 10, "only %d page writes were reached", killed)
}
