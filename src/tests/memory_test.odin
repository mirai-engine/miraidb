package tests

import "core:mem"
import "core:os"
import "core:testing"

import db "../engine"

// What a store, a connection or a SQLite file leaves behind once it is closed.
// Each test runs its statements under a tracking allocator of its own and
// expects every block it handed out back: the test runner's tracker only
// reports, and a leak that grows with every statement went unnoticed for as
// long as nobody read the report.

@(private = "file")
Session_Mode :: enum {
	// a store in memory
	Memory,
	// a database directory, closed
	Directory,
	// a database directory, closed and opened again (the log is replayed)
	Reopen,
	// a SQLite file through the embedded API, closed and opened again (the file
	// is imported, then mirrored on every commit)
	Sqlite_File,
}

@(private = "file")
Session_Failure :: struct {
	// statement is the index of the first statement that failed, -1 for the
	// open, NO_FAILURE when none did.
	statement: int,
	message:   [200]u8,
	length:    int,
}

@(private = "file")
NO_FAILURE :: -2

@(private = "file")
note_failure :: proc(failure: ^Session_Failure, statement: int, message: string) {
	if failure.statement != NO_FAILURE do return
	failure.statement = statement
	failure.length = copy(failure.message[:], message)
}

@(private = "file")
run_session :: proc(mode: Session_Mode, path: string, statements: []string, failure: ^Session_Failure) {
	switch mode {
	case .Memory, .Directory, .Reopen:
		persistent := mode != .Memory
		options := db.Store_Options{persistent = persistent, create = true, durable = false}
		store, open_err := db.store_open(persistent ? path : "", options)
		if open_err.kind != .None {
			note_failure(failure, -1, open_err.message)
			db.error_free(&open_err)
			return
		}
		for sql, k in statements {
			result, err := db.sql_execute(store, sql)
			if err.kind != .None do note_failure(failure, k, err.message)
			db.error_free(&err)
			db.sql_result_destroy(&result)
		}
		db.store_close(store)
		if mode != .Reopen do return
		again, again_err := db.store_open(path, options)
		if again_err.kind != .None {
			note_failure(failure, -1, again_err.message)
			db.error_free(&again_err)
			return
		}
		db.store_close(again)
	case .Sqlite_File:
		for round in 0 ..< 2 {
			conn, open_err := db.embed_open(path)
			if open_err.kind != .None {
				note_failure(failure, -1, open_err.message)
				db.error_free(&open_err)
				return
			}
			if round == 0 {
				for sql, k in statements {
					err := db.embed_exec(conn, sql)
					if err.kind != .None do note_failure(failure, k, err.message)
					db.error_free(&err)
				}
			}
			db.embed_close(conn)
		}
	}
}

// expect_nothing_left runs the statements in a fresh session and expects every
// block allocated on the way to be freed by the close. With `fails` set the
// statements are expected to be refused, and the refusal is what is measured.
@(private = "file")
expect_nothing_left :: proc(
	t: ^testing.T,
	mode: Session_Mode,
	name: string,
	statements: []string,
	fails := false,
	loc := #caller_location,
) {
	path := name
	os.remove_all(path)
	defer os.remove_all(path)
	if mode == .Sqlite_File do testing.expect(t, db.sqlite_create_empty_file(path), loc = loc)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	failure := Session_Failure{statement = NO_FAILURE}
	{
		context.allocator = mem.tracking_allocator(&track)
		run_session(mode, path, statements, &failure)
	}
	if fails {
		testing.expect(t, failure.statement != NO_FAILURE, "the statements were expected to fail", loc = loc)
	} else if failure.statement != NO_FAILURE {
		where_ := failure.statement >= 0 ? statements[failure.statement] : "open"
		testing.expectf(t, false, "%s: %s", where_, string(failure.message[:failure.length]), loc = loc)
	}
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "%d bytes left from %v", entry.size, entry.location, loc = loc)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free of %p at %v", entry.memory, entry.location, loc = loc)
	}
}

@(test)
test_a_closed_store_leaves_nothing :: proc(t: ^testing.T) {
	// The implicit indexes a key declares, the type names the parser reads, the
	// log and snapshot paths, the statistics cache that is not there yet and the
	// numbers ANALYZE gathers.
	expect_nothing_left(t, .Memory, "_test_memory_store", {
		"CREATE TABLE t (a INT PRIMARY KEY, b TEXT UNIQUE)",
		"INSERT INTO t VALUES (1, 'x'), (2, 'y')",
		"SELECT * FROM t ORDER BY b",
	})
	expect_nothing_left(t, .Directory, "_test_memory_directory", {
		"CREATE TABLE t (a INT PRIMARY KEY, b TEXT UNIQUE)",
		"INSERT INTO t VALUES (1, 'x'), (2, 'y'), (3, 'x2')",
		"ANALYZE",
		"ANALYZE t",
	})
}

@(test)
test_group_by_leaves_nothing :: proc(t: ^testing.T) {
	// Each row's group key is cloned once, for the group it opens.
	expect_nothing_left(t, .Memory, "_test_memory_group", {
		"CREATE TABLE s (level TEXT, amount INT)",
		"INSERT INTO s VALUES ('info', 1), ('warn', 2), ('info', 3), ('info', 4), ('warn', 5)",
		"SELECT level, count(*), sum(amount) FROM s GROUP BY level",
	})
}

@(test)
test_replay_leaves_nothing :: proc(t: ^testing.T) {
	// Opening a directory replays its log: every operation is decoded, applied
	// and dropped.
	expect_nothing_left(t, .Reopen, "_test_memory_replay", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT DEFAULT 'q' COLLATE NOCASE)",
		"CREATE INDEX i ON t (v) WHERE id > 0",
		"INSERT INTO t VALUES (1, 'ab'), (2, 'cd')",
		"UPDATE t SET v = 'ef' WHERE id = 1",
		"DELETE FROM t WHERE id = 2",
		"DROP INDEX i",
	})
}

@(test)
test_upsert_leaves_nothing :: proc(t: ^testing.T) {
	// DO UPDATE answers the collision the insert met; its message goes.
	expect_nothing_left(t, .Memory, "_test_memory_upsert", {
		"CREATE TABLE t (k INT PRIMARY KEY, n INT)",
		"INSERT INTO t VALUES (1, 1) ON CONFLICT (k) DO UPDATE SET n = n + 1",
		"INSERT INTO t VALUES (1, 1) ON CONFLICT (k) DO UPDATE SET n = n + 1",
		"INSERT INTO t VALUES (1, 1) ON CONFLICT (k) DO NOTHING",
	})
}

@(test)
test_alter_table_leaves_nothing :: proc(t: ^testing.T) {
	// Every table an ALTER builds for its transaction is the transaction's.
	expect_nothing_left(t, .Memory, "_test_memory_alter", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)",
		"INSERT INTO t VALUES (1, '7')",
		"ALTER TABLE t ADD COLUMN w INT",
		"ALTER TABLE t RENAME COLUMN v TO z",
		"ALTER TABLE t ALTER COLUMN z TYPE INT",
		"ALTER TABLE t DROP COLUMN w",
		"ALTER TABLE t RENAME TO q",
	})
}

@(test)
test_full_text_leaves_nothing :: proc(t: ^testing.T) {
	expect_nothing_left(t, .Memory, "_test_memory_fts", {
		"CREATE VIRTUAL TABLE d USING fts5(title, body)",
		"INSERT INTO d (title, body) VALUES ('one', 'the quick brown fox'), ('two', 'a lazy dog'), ('three', 'quick dogs run')",
		"SELECT title FROM d WHERE d MATCH 'quick'",
		"DELETE FROM d WHERE title = 'two'",
		"DROP TABLE d",
		"CREATE TABLE IF NOT EXISTS q (a)",
		"CREATE TABLE IF NOT EXISTS q (a)",
	})
}

@(test)
test_catalog_probes_leave_nothing :: proc(t: ^testing.T) {
	// Asking whether a catalog table exists yet (views, triggers, policies,
	// types) answers no without keeping the error that said so.
	expect_nothing_left(t, .Memory, "_test_memory_catalog", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)",
		"DROP VIEW IF EXISTS nowhere",
		"DROP POLICY IF EXISTS nowhere",
		"CREATE VIEW w AS SELECT * FROM t",
		"DROP VIEW w",
		"CREATE TRIGGER g AFTER INSERT ON t BEGIN SELECT 1; END",
		"DROP TRIGGER g",
	})
}

@(test)
test_a_sqlite_file_leaves_nothing :: proc(t: ^testing.T) {
	// Import, export and the mirror: the rows a file is read into, the
	// sqlite_master rows an export writes, the index keys it sorts, the views
	// and triggers it keeps.
	expect_nothing_left(t, .Sqlite_File, "_test_memory_file.sqlite", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT, n INT)",
		"INSERT INTO t VALUES (1, 'ab', 2), (2, 'cd', 3)",
		"CREATE VIEW w AS SELECT * FROM t",
		"CREATE INDEX i ON t (v)",
		"CREATE INDEX e ON t (n + 1) WHERE n > 2",
		"CREATE TABLE u (a INTEGER PRIMARY KEY AUTOINCREMENT, b TEXT UNIQUE)",
		"INSERT INTO u (b) VALUES ('x')",
		"CREATE TRIGGER g AFTER INSERT ON t BEGIN SELECT 1; END",
		"UPDATE t SET v = 'zz' WHERE id = 1",
	})
}

@(test)
test_a_parse_error_leaves_nothing :: proc(t: ^testing.T) {
	// The error names the line and column; the detail it wraps is not kept.
	expect_nothing_left(t, .Memory, "_test_memory_parse", {"SELECT FROM WHERE", "SELEC 1", "CREATE TABLE ("}, fails = true)
}

@(test)
test_catalog_pragmas_leave_nothing :: proc(t: ^testing.T) {
	// What SQLite's shell reads: the table and index lists, joined; a view's
	// columns; the temp schema; LIKE over the names.
	expect_nothing_left(t, .Memory, "_test_memory_pragmas", {
		"CREATE TABLE people (id INTEGER PRIMARY KEY, age INTEGER UNIQUE)",
		"CREATE INDEX people_age ON people (age)",
		"CREATE VIEW adults AS SELECT age FROM people",
		"SELECT i.name FROM pragma_table_list t, pragma_index_list(t.name, t.schema) i WHERE i.name NOT LIKE 'sqlite__%' ESCAPE '_'",
		"PRAGMA table_list",
		"PRAGMA database_list",
		"PRAGMA table_info(adults)",
		"PRAGMA index_list(people)",
		"SELECT name FROM temp.sqlite_master",
		"SELECT rowid, name FROM sqlite_schema",
	})
}

@(test)
test_json_function_names_leave_nothing :: proc(t: ^testing.T) {
	// Each JSON function lowered its name into the heap to pick itself, and
	// never gave it back; so did reading a variable and a PRAGMA's word.
	expect_nothing_left(t, .Memory, "_test_memory_json", {
		"SELECT json_extract('{\"a\": 1}', '$.a'), json_valid('[1]')",
	})
}

@(test)
test_a_failed_select_leaves_nothing :: proc(t: ^testing.T) {
	// A projection that fails partway: the rows already made, their sort keys,
	// the sources still pending and the column names all go back.
	expect_nothing_left(t, .Memory, "_test_memory_failed_select", {
		"CREATE TABLE t (a INT)",
		"INSERT INTO t VALUES (1), (2), (3), (4)",
		"SELECT a, CASE WHEN a < 3 THEN a ELSE json('{') END FROM t ORDER BY a",
	}, fails = true)
}
