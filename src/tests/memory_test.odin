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
test_insert_select_leaves_nothing :: proc(t: ^testing.T) {
	// INSERT ... SELECT turns the query's rows into literals; the query's
	// result was never freed, so each one left every row it read behind.
	expect_nothing_left(t, .Memory, "_test_memory_insert_select", {
		"CREATE TABLE s (id INTEGER PRIMARY KEY, v TEXT)",
		"INSERT INTO s VALUES (1, 'ab'), (2, 'cd')",
		"INSERT INTO s SELECT id + 2, v || 'x' FROM s",
		"INSERT INTO s SELECT id + 10, upper(v) FROM s WHERE id > 2 RETURNING id",
	})
}

@(test)
test_a_file_read_into_another_allocator_leaves_nothing :: proc(t: ^testing.T) {
	// A file read with an allocator of its own keeps its lists there: the
	// catalog lists grew with the caller's context.allocator instead, and the
	// file's destroy freed them with its own.
	path := "_test_memory_validate.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	{
		conn, err := db.embed_open(path)
		if !testing.expect(t, db.error_ok(err)) do return
		for sql in ([]string{"CREATE TABLE t (a INTEGER PRIMARY KEY, b)", "CREATE INDEX i ON t (b)", "INSERT INTO t VALUES (1, 'x')"}) {
			exec_err := db.embed_exec(conn, sql)
			testing.expect(t, db.error_ok(exec_err))
			db.error_free(&exec_err)
		}
		db.embed_close(conn)
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		ok, reason := db.sqlite_mirror_validate(path, context.temp_allocator)
		testing.expectf(t, ok, "malformed: %s", reason)
	}
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "%d bytes left from %v", entry.size, entry.location)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free of %p at %v", entry.memory, entry.location)
	}
}

@(test)
test_two_connections_on_a_file_leave_nothing :: proc(t: ^testing.T) {
	// One connection catching up with the other's commits, table by table and
	// whole (a schema change): the hashes it keeps, the rows it reloads, the
	// names of what its own commits touched.
	path := "_test_memory_two.sqlite"
	os.remove(path)
	defer os.remove(path)
	_ = os.write_entire_file(path, []u8{})
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		a, a_err := db.embed_open(path)
		if !testing.expect(t, db.error_ok(a_err)) do return
		b, b_err := db.embed_open(path)
		if !testing.expect(t, db.error_ok(b_err)) do return
		for step in ([]struct {
				conn: ^db.Embed_Conn,
				sql:  string,
			}{
				{a, "CREATE TABLE t1 (k INTEGER PRIMARY KEY, v)"},
				{a, "CREATE TABLE t2 (k INTEGER PRIMARY KEY AUTOINCREMENT, v)"},
				{a, "INSERT INTO t1 VALUES (1, zeroblob(3000)), (2, 'b')"},
				{b, "SELECT count(*) FROM t1"},
				{a, "UPDATE t1 SET v = 'B' WHERE k = 2"},
				{b, "SELECT v FROM t1 WHERE k = 2"},
				{b, "INSERT INTO t2 (v) VALUES ('x')"},
				{a, "SELECT count(*) FROM t2"},
				{a, "DELETE FROM t1 WHERE k = 1"},
				{b, "SELECT count(*) FROM t1"},
				{a, "CREATE TABLE t3 (z)"},
				{b, "SELECT count(*) FROM t3"},
			}) {
			err := db.embed_exec(step.conn, step.sql)
			testing.expectf(t, db.error_ok(err), "%s: %s", step.sql, err.message)
			db.error_free(&err)
		}
		db.embed_close(b)
		db.embed_close(a)
		free_all(context.temp_allocator)
	}
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "%d bytes left from %v", entry.size, entry.location)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free of %p at %v", entry.memory, entry.location)
	}
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
	// Rows past a page: leaves split into many, overflow chains, a select
	// that reads them back.
	expect_nothing_left(t, .Sqlite_File, "_test_memory_big.sqlite", {
		"CREATE TABLE t1 (a INTEGER PRIMARY KEY, b)",
		"INSERT INTO t1 VALUES (1, zeroblob(2000)), (2, zeroblob(1000))",
		"INSERT INTO t1 SELECT a + 2, zeroblob(1500) FROM t1",
		"INSERT INTO t1 SELECT a + 4, zeroblob(1500) FROM t1",
		"INSERT INTO t1 SELECT a + 8, zeroblob(5000) FROM t1",
		"UPDATE t1 SET b = 'x' || a || 'y'",
		"SELECT count(*), sum(length(b)) FROM t1",
		"DELETE FROM t1 WHERE a > 10",
	})
	// A root that splits into a new root, rows that grow and shrink their
	// overflow chains, a row deleted from the first leaf.
	expect_nothing_left(t, .Sqlite_File, "_test_memory_root.sqlite", {
		"CREATE TABLE x (q)",
		"INSERT INTO x VALUES (1)",
		"CREATE TABLE t1 (a INTEGER PRIMARY KEY, b)",
		"INSERT INTO t1 VALUES (1, zeroblob(3000))",
		"INSERT INTO t1 VALUES (2, zeroblob(3000))",
		"INSERT INTO t1 VALUES (3, zeroblob(9000)), (4, zeroblob(20000))",
		"UPDATE t1 SET b = zeroblob(7000) WHERE a = 2",
		"DELETE FROM t1 WHERE a = 1",
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

@(test)
test_function_answers_leave_nothing :: proc(t: ^testing.T) {
	// A function that answers a new text or blob left it in the heap once per
	// call: the projection copied the value and nobody freed the original.
	expect_nothing_left(t, .Memory, "_test_memory_functions", {
		"CREATE TABLE t (a TEXT, n INT)",
		"INSERT INTO t VALUES ('one', 1), ('two', 2), ('three', 3)",
		"SELECT upper(a), lower(a), substr(a, 2), replace(a, 'o', '0'), hex(a), printf('%s-%d', a, n), quote(a) FROM t",
		"SELECT json_quote(a), json_array(a, n), json_object('k', a), json_set('{}', '$.x', n) FROM t",
		"SELECT date('2026-11-19', '+1 day'), datetime(0, 'unixepoch'), randomblob(4), zeroblob(2), char(65, 66) FROM t",
		"SELECT upper(a) FROM t ORDER BY upper(a)",
		"UPDATE t SET a = upper(a) || '!' WHERE n > 1",
		"SELECT count(*) FROM t WHERE lower(a) LIKE 't%'",
		"SELECT CAST(n AS TEXT), CAST(n AS REAL), -n, ~n, a || n, CASE WHEN n > 1 THEN upper(a) ELSE lower(a) END FROM t",
	})
}

@(test)
test_windows_with_an_order_leave_nothing :: proc(t: ^testing.T) {
	// A query with a window builds its order keys once the window values
	// exist; it also built one per row before, and dropped it.
	expect_nothing_left(t, .Memory, "_test_memory_windows", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT, n INTEGER)",
		"INSERT INTO t VALUES (1, 'a', 10), (2, 'a', 20), (3, 'a', 20), (4, 'b', 40)",
		"SELECT sum(n) OVER (ORDER BY n RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t ORDER BY id",
		"SELECT count(*) OVER (ORDER BY n GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM t ORDER BY id DESC",
		"SELECT g, sum(n) OVER (PARTITION BY g ORDER BY n ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t ORDER BY 2",
	})
}

@(test)
test_show_leaves_nothing :: proc(t: ^testing.T) {
	// SHOW types, events and indexes answered with a column array that was a
	// slice literal (on the stack of the proc that returned it) and string
	// literals for names: destroying such a result was a bad free.
	expect_nothing_left(t, .Memory, "_test_memory_show", {
		"CREATE TYPE money AS DECIMAL",
		"CREATE TABLE t (id INTEGER PRIMARY KEY, a INT, b INT)",
		"CREATE INDEX i ON t (a, b)",
		"CREATE EVENT TABLE e (n INT)",
		"SHOW tables",
		"SHOW types",
		"SHOW events",
		"SHOW indexes",
	})
}

@(test)
test_catalog_reads_leave_nothing :: proc(t: ^testing.T) {
	// _indexes named an index's columns by concatenating them, keeping every
	// partial string; PRAGMA stats formatted its bucket names and kept them.
	expect_nothing_left(t, .Memory, "_test_memory_catalog", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT, n INT)",
		"CREATE INDEX i ON t (v, n)",
		"CREATE INDEX e ON t (n + 1)",
		"SELECT name, type FROM _columns WHERE table = 't' ORDER BY name",
		"SELECT name, columns FROM _indexes WHERE table = 't' ORDER BY name",
		"SHOW indexes",
		"PRAGMA stats",
	})
}

@(test)
test_joins_leave_nothing :: proc(t: ^testing.T) {
	// Ordering a join kept each relation's dependency list, the positions and
	// the per-step conditions, and put the steps in the heap instead of the
	// statement's arena.
	expect_nothing_left(t, .Memory, "_test_memory_join", {
		"CREATE TABLE a (id INTEGER PRIMARY KEY, x INT)",
		"CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INT, x INT)",
		"CREATE TABLE c (id INTEGER PRIMARY KEY, b_id INT)",
		"INSERT INTO a VALUES (1, 1), (2, 2)",
		"INSERT INTO b VALUES (1, 1, 1), (2, 2, 2)",
		"SELECT a.x, b.x FROM a JOIN b ON b.a_id = a.id",
		"SELECT * FROM a JOIN b USING (x)",
		"EXPLAIN SELECT * FROM a, b, c WHERE b.a_id = a.id AND c.b_id = b.id AND a.x = 1",
	})
}
