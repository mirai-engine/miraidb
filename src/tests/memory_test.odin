package tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
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

@(test)
test_keys_and_attachments_leave_nothing :: proc(t: ^testing.T) {
	// A file's table-level key split its column list and kept the pieces;
	// PRAGMA index_xinfo read a table's text and dropped it; DETACH and a
	// closing store kept the attached database's name; a write or a query on
	// an attached table kept the names the resolver rewrote.
	expect_nothing_left(t, .Sqlite_File, "_test_memory_keys.sqlite", {
		"CREATE TABLE k (a TEXT, b INT, v, PRIMARY KEY (a, b))",
		"INSERT INTO k VALUES ('x', 1, 2)",
		"CREATE TABLE u (a INT, b TEXT, UNIQUE (a, b))",
		"INSERT INTO u VALUES (1, 'y')",
		"PRAGMA index_xinfo('sqlite_autoindex_k_1')",
		"UPDATE k SET v = 3",
	})
	expect_nothing_left(t, .Memory, "_test_memory_attach", {
		"ATTACH ':memory:' AS side",
		"CREATE TABLE side.s (a INT)",
		"INSERT INTO side.s VALUES (1)",
		"SELECT a FROM side.s",
		"DETACH side",
		"ATTACH ':memory:' AS kept",
	})
}

@(test)
test_failed_and_converted_statements_leave_nothing :: proc(t: ^testing.T) {
	// A grouped SELECT that fails (an aggregate that overflows, a HAVING or a
	// projection that errs) kept its output array, its window sources and every
	// group not yet reached.
	expect_nothing_left(t, .Memory, "_test_memory_aggregate_error", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT, n INT)",
		"INSERT INTO t VALUES (1, 'a', 9223372036854775807), (2, 'a', 1), (3, 'b', 5)",
		"SELECT g, sum(n) FROM t GROUP BY g",
	}, fails = true)
	expect_nothing_left(t, .Memory, "_test_memory_having_error", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, g TEXT, n INT)",
		"INSERT INTO t VALUES (1, 'a', 0), (2, 'b', 1)",
		"SELECT g FROM t GROUP BY g HAVING 10 / min(n) > 1",
	}, fails = true)
	// ALTER COLUMN TYPE converted each value in the heap, at the statement and
	// again at the commit, and kept the converted texts; a WINDOW clause's
	// pending names grew in the heap.
	expect_nothing_left(t, .Memory, "_test_memory_alter_type", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v INT)",
		"INSERT INTO t VALUES (1, 2), (2, 30)",
		"ALTER TABLE t ALTER COLUMN v TYPE TEXT",
		"SELECT v FROM t",
		"SELECT sum(id) OVER w FROM t WINDOW w AS (ORDER BY id)",
	})
}

@(test)
test_subscriptions_leave_nothing :: proc(t: ^testing.T) {
	// A subscription kept the array of every evaluation and the key of every
	// row it cached; plain, joined and grouped ones, kept current through
	// inserts, updates and deletes, then dropped.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		store, open_err := db.store_open("", {persistent = false})
		if !testing.expect(t, db.error_ok(open_err)) do return
		host := db.host_init(store)
		run :: proc(t: ^testing.T, store: ^db.Store, sql: string) {
			result, err := db.sql_execute(store, sql)
			testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
			db.error_free(&err)
			db.sql_result_destroy(&result)
		}
		run(t, store, "CREATE TABLE author (id INTEGER PRIMARY KEY, name TEXT)")
		run(t, store, "CREATE TABLE book (id INTEGER PRIMARY KEY, author_id INT, title TEXT)")
		run(t, store, "INSERT INTO author VALUES (1, 'ana'), (2, 'luis')")
		run(t, store, "INSERT INTO book VALUES (1, 1, 'a'), (2, 2, 'b')")
		id, snapshots, err := db.host_subscribe_many(host, []string{
			"SELECT id, name FROM author WHERE id > 0",
			"SELECT author.name, book.title FROM author JOIN book ON author.id = book.author_id",
			"SELECT author_id, count(*) FROM book GROUP BY author_id",
		})
		testing.expectf(t, db.error_ok(err), "subscribe: %s", err.message)
		db.host_snapshot_destroy(snapshots)
		run(t, store, "INSERT INTO book VALUES (3, 1, 'c')")
		run(t, store, "UPDATE author SET name = 'ANA' WHERE id = 1")
		run(t, store, "DELETE FROM book WHERE id = 2")
		run(t, store, "INSERT INTO author VALUES (3, 'eva')")
		db.host_unsubscribe(host, id)
		// Two equal rows (no DISTINCT) are one entry of the cache.
		run(t, store, "INSERT INTO book VALUES (5, 1, 'c')")
		_, again, again_err := db.host_subscribe(host, "SELECT title FROM book")
		testing.expect(t, db.error_ok(again_err))
		db.host_rows_destroy(again)
		run(t, store, "INSERT INTO book VALUES (4, 3, 'd')")
		run(t, store, "CREATE INDEX bt ON book (title)")
		run(t, store, "INSERT INTO book VALUES (6, 2, 'c')")
		db.host_destroy(host)
		db.store_close(store)
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
test_the_wire_leaves_nothing :: proc(t: ^testing.T) {
	// A subscription over the wire handed its snapshot to the encoder and kept
	// it, and every error the wire answered kept its message.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		store, open_err := db.store_open("", {persistent = false})
		if !testing.expect(t, db.error_ok(open_err)) do return
		host := db.host_init(store)
		for sql in ([]string{"CREATE TABLE t (id INTEGER PRIMARY KEY, v INT)", "INSERT INTO t VALUES (1, 5), (2, 6)"}) {
			result, err := db.sql_execute(store, sql)
			testing.expect(t, db.error_ok(err))
			db.sql_result_destroy(&result)
		}
		exchange :: proc(host: ^db.Host, request: []u8) -> []u8 {
			response := db.wire_request(host, request)
			delete(request)
			return response
		}
		failed := exchange(host, db.wire_encode_query("SELECT nope FROM t", nil))
		testing.expect_value(t, wire_message_kind(failed), db.WIRE_ERROR)
		delete(failed)
		subscribed := exchange(host, db.wire_encode_subscribe([]string{"SELECT v FROM t"}))
		testing.expect_value(t, wire_message_kind(subscribed), db.WIRE_SNAPSHOT)
		id, _, _, decode_err := db.wire_decode_snapshot(subscribed, context.temp_allocator)
		testing.expect(t, db.error_ok(decode_err))
		delete(subscribed)
		delete(exchange(host, db.wire_encode_unsubscribe(id)))
		db.host_destroy(host)
		db.store_close(store)
		free_all(context.temp_allocator)
	}
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "%d bytes left from %v", entry.size, entry.location)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free of %p at %v", entry.memory, entry.location)
	}
}

@(private = "file")
wire_message_kind :: proc(message: []u8) -> u32 {
	if len(message) < 4 do return 0
	return u32(message[0]) | u32(message[1]) << 8 | u32(message[2]) << 16 | u32(message[3]) << 24
}

@(test)
test_a_streamed_aggregate_leaves_nothing :: proc(t: ^testing.T) {
	// An aggregate over a paged table streams its rows; it cloned its column
	// names and kept them.
	path := "_test_memory_stream"
	os.remove_all(path)
	defer os.remove_all(path)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		store, open_err := db.store_open(path, {persistent = true, create = true, durable = false, paged_tables = true})
		if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
		for sql in ([]string{
			"CREATE TABLE item (id INTEGER PRIMARY KEY, qty INTEGER)",
			"INSERT INTO item VALUES (1, 2), (2, 3), (3, 0)",
			"SELECT count(*), sum(qty) AS total FROM item WHERE qty > 0",
		}) {
			result, err := db.sql_execute(store, sql)
			testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
			db.error_free(&err)
			db.sql_result_destroy(&result)
		}
		db.store_close(store)
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
test_grouped_windows_leave_nothing :: proc(t: ^testing.T) {
	// A window over a grouped query keeps the rows its groups point at until
	// the window is done; only the groups' lists were freed, and every row was
	// lost. Under GROUPING SETS one row sits in several groups.
	expect_nothing_left(t, .Memory, "_test_memory_grouped_windows", {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT)",
		"INSERT INTO t VALUES (1, 'a'), (2, 'a'), (3, 'b')",
		"SELECT k, count(*) AS n, sum(count(*)) OVER () AS total FROM t GROUP BY k ORDER BY k",
		"SELECT k, rank() OVER (ORDER BY count(*) DESC) AS r FROM t GROUP BY k ORDER BY k",
		"SELECT k, count(*), sum(count(*)) OVER () FROM t GROUP BY GROUPING SETS ((k), ())",
	})
}

@(test)
test_failed_writes_leave_nothing :: proc(t: ^testing.T) {
	// A write that fails at every point of a short workload, on the log and on
	// the page files: an error wrapped to say what failed kept the one it
	// wrapped, probing for a log segment kept the "no such file", and a log
	// that failed to open kept its path.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		memory := db.vfs_memory_new()
		fault := db.vfs_fault_new(memory)
		for n in 1 ..= 30 {
			for paged in ([]bool{false, true}) {
				path := fmt.tprintf("_test_memory_fault_%d_%v", n, paged)
				db.vfs_fault_arm(fault, .Write, u64(n))
				store, open_err := db.store_open(path, {persistent = true, create = true, durable = true, vfs = fault, paged_tables = paged, page_frames = 2})
				if !db.error_ok(open_err) {
					db.error_free(&open_err)
					continue
				}
				for sql in ([]string{"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", "INSERT INTO t (v) VALUES ('a'), ('b')", "INSERT INTO t (v) VALUES ('c')"}) {
					result, err := db.sql_execute(store, sql)
					db.sql_result_destroy(&result)
					db.error_free(&err)
				}
				db.vfs_fault_arm(fault, .Write, 0)
				db.store_close(store)
			}
		}
		db.vfs_fault_destroy(fault)
		db.vfs_memory_destroy(memory)
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
test_http_requests_leave_nothing :: proc(t: ^testing.T) {
	// Each request the server read kept its method and path, every partial
	// read kept an "incomplete" error, a plain endpoint's body was allocated
	// and dropped, and a compressed answer dropped the plain one.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		store, open_err := db.store_open("", {persistent = false})
		if !testing.expect(t, db.error_ok(open_err)) do return
		host := db.host_init(store)
		created, create_err := db.sql_execute(store, "CREATE TABLE t (v INT)")
		db.sql_result_destroy(&created)
		db.error_free(&create_err)
		query := db.wire_encode_query("SELECT v FROM t", nil)
		post := fmt.tprintf("POST /query HTTP/1.1\r\nAccept-Encoding: zlib\r\nContent-Length: %d\r\n\r\n%s", len(query), string(query))
		delete(query)
		for text in ([]string{
			"GET /health HTTP/1.1\r\n\r\n",
			"GET /metrics HTTP/1.1\r\n\r\n",
			"GET /schema HTTP/1.1\r\n\r\n",
			"GET /nowhere HTTP/1.1\r\n\r\n",
			"PUT /query HTTP/1.1\r\n\r\n",
			post,
			"POST /query HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc",
			"POST /query HTTP/1.1\r\nContent-Length: 1x\r\n\r\n",
			"GET /health HTTP/1.1\r\n",
		}) {
			request, _, parse_err := db.http_parse_request(transmute([]u8)text)
			if !db.error_ok(parse_err) {
				db.error_free(&parse_err)
				continue
			}
			response := db.http_handle(host, request)
			db.http_request_destroy(&request)
			delete(response)
		}
		db.host_destroy(host)
		db.store_close(store)
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
test_pgwire_sessions_leave_nothing :: proc(t: ^testing.T) {
	// Every message the PostgreSQL face built (a row, a row description, a
	// command tag, an error, ready-for-query) kept the body it copied.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		store, open_err := db.store_open("", {persistent = false})
		if !testing.expect(t, db.error_ok(open_err)) do return
		host := db.host_init(store)
		session := db.pg_session_init()
		for sql in ([]string{
			"CREATE TABLE k (id INTEGER PRIMARY KEY, v TEXT)",
			"INSERT INTO k VALUES (1, 'a'), (2, 'b')",
			"SELECT id, v FROM k ORDER BY id",
			"BEGIN; UPDATE k SET v = 'z' WHERE id = 1",
			"SELECT nope FROM k",
			"COMMIT",
			"LISTEN ch; NOTIFY ch, 'hi'",
		}) {
			body := make([dynamic]u8)
			append(&body, ..transmute([]u8)sql)
			append(&body, 0)
			message := pg_build_frontend('Q', body[:])
			delete(body)
			response, _ := db.pg_handle_session_message(host, session, message)
			delete(message)
			delete(response)
		}
		db.pg_session_destroy(session)
		db.host_destroy(host)
		db.store_close(store)
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
test_tokens_leave_nothing :: proc(t: ^testing.T) {
	// Issuing a token kept its secret, its hex text, its digest and the
	// insert's result; every check kept the digest it looked up; a JWT kept
	// every piece it encoded or decoded.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		store, open_err := db.store_open("", {persistent = false})
		if !testing.expect(t, db.error_ok(open_err)) do return
		host := db.host_init(store)
		who: db.Identity
		who[0] = 7
		token, issue_err := db.host_issue_token(host, who, 0)
		testing.expect(t, db.error_ok(issue_err))
		_, valid := db.host_authenticate(host, token)
		testing.expect(t, valid)
		_, forged := db.host_authenticate(host, "mt_00")
		testing.expect(t, !forged)
		testing.expect(t, db.host_revoke_token(host, token))
		delete(token)
		jwt := db.host_issue_jwt(host, who, 60_000_000)
		_, signed := db.host_authenticate(host, jwt)
		testing.expect(t, signed)
		_, tampered := db.host_authenticate(host, "eyJ.e30.nope")
		testing.expect(t, !tampered)
		delete(jwt)
		db.host_destroy(host)
		db.store_close(store)
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
test_plans_and_aggregates_leave_nothing :: proc(t: ^testing.T) {
	// EXPLAIN QUERY PLAN rewrote each line and kept the original; a builtin
	// aggregate's text (group_concat, json_group_array) stayed in the heap; an
	// R-tree's column list was joined twice.
	expect_nothing_left(t, .Memory, "_test_memory_plans_aggregates", {
		"CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept INT)",
		"CREATE INDEX by_dept ON emp (dept)",
		"INSERT INTO emp VALUES (1, 'a', 1), (2, 'b', 1), (3, 'c', 2)",
		"EXPLAIN QUERY PLAN SELECT * FROM emp WHERE dept = 1 ORDER BY name",
		"SELECT group_concat(name, ','), json_group_array(id), json_group_object(name, dept) FROM emp",
		"SELECT dept, group_concat(name) FROM emp GROUP BY dept ORDER BY dept",
		"CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx, miny, maxy)",
		"INSERT INTO places VALUES (1, 0, 10, 0, 10)",
	})
}

@(test)
test_internal_statements_leave_nothing :: proc(t: ^testing.T) {
	// Every internal statement whose result was dropped kept it: the CREATE
	// TABLE IF NOT EXISTS of a system table, a role's grant, a view's row.
	expect_nothing_left(t, .Memory, "_test_memory_internal_statements", {
		"CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT)",
		"GRANT insert ON emp TO writer",
		"GRANT writer TO '*'",
		"INSERT INTO emp VALUES (4, 'd')",
		"CREATE VIEW v AS SELECT name FROM emp",
		"SELECT * FROM v",
	})
}

@(test)
test_the_memory_vfs_leaves_nothing :: proc(t: ^testing.T) {
	// Opening with Trunc dropped the old contents, a truncate that grew a file
	// kept the old buffer, and the map named files with the caller's string
	// (freed with it) and never freed a name.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		vfs := db.vfs_memory_new()
		for name in ([]string{"a", "b"}) {
			path := strings.clone(name)
			file, open_err := vfs.ops.open(vfs, path, {.Read, .Write, .Create})
			testing.expect(t, db.error_ok(open_err))
			_, _ = vfs.ops.write(file, []u8{1, 2, 3})
			testing.expect(t, db.error_ok(vfs.ops.truncate(file, 64)))
			vfs.ops.close(file)
			again, again_err := vfs.ops.open(vfs, path, {.Read, .Write, .Trunc})
			testing.expect(t, db.error_ok(again_err))
			_, _ = vfs.ops.write(again, []u8{4})
			vfs.ops.close(again)
			delete(path)
		}
		testing.expect(t, db.error_ok(vfs.ops.remove(vfs, "a")))
		db.vfs_memory_destroy(vfs)
	}
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "%d bytes left from %v", entry.size, entry.location)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free of %p at %v", entry.memory, entry.location)
	}
}

@(test)
test_probes_for_a_table_leave_nothing :: proc(t: ^testing.T) {
	// Asking whether a table is there (to price a view over a view, to order a
	// join, to check a trigger's or a foreign key's table) kept the "not
	// visible" error each time it was not.
	expect_nothing_left(t, .Memory, "_test_memory_table_probes", {
		"CREATE TABLE base (id INTEGER PRIMARY KEY, v INT)",
		"CREATE TABLE other (id INTEGER PRIMARY KEY, base_id INT)",
		"INSERT INTO base VALUES (1, 2)",
		"CREATE VIEW inner_view AS SELECT id, v FROM base",
		"CREATE VIEW outer_view AS SELECT id FROM inner_view",
		"SELECT * FROM outer_view JOIN other ON other.base_id = outer_view.id",
		"SELECT * FROM other JOIN inner_view ON inner_view.id = other.base_id",
	})
	expect_nothing_left(t, .Memory, "_test_memory_missing_targets", {
		"CREATE TRIGGER g AFTER INSERT ON nowhere BEGIN SELECT 1; END",
	}, fails = true)
	expect_nothing_left(t, .Memory, "_test_memory_missing_parent", {
		"CREATE TABLE child (id INTEGER PRIMARY KEY, p INT REFERENCES nowhere (id))",
	}, fails = true)
}

@(test)
test_a_program_function_error_leaves_nothing :: proc(t: ^testing.T) {
	// A program's function answers in the caller's allocator; the statement
	// copied its error's message out and kept the program's copy.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		store, open_err := db.store_open("", {persistent = false})
		if !testing.expect(t, db.error_ok(open_err)) do return
		testing.expect(t, db.error_ok(db.store_register_function(store, "refuse", 1, refuse_function, nil)))
		for _ in 0 ..< 3 {
			result, err := db.sql_execute(store, "SELECT refuse(1)")
			testing.expect_value(t, err.kind, db.Error_Kind.Invalid_Argument)
			db.sql_result_destroy(&result)
			db.error_free(&err)
		}
		db.store_close(store)
		free_all(context.temp_allocator)
	}
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "%d bytes left from %v", entry.size, entry.location)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free of %p at %v", entry.memory, entry.location)
	}
}

@(private = "file")
refuse_function :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
	return {}, db.errf(.Invalid_Argument, "refuse() was called with %d", len(args))
}

@(test)
test_literals_and_set_answers_leave_nothing :: proc(t: ^testing.T) {
	// A blob literal's bytes, a scalar min/max's answer, DISTINCT's group keys,
	// a missing table dropped IF EXISTS, an array written as text and the rows
	// COPY TO formats.
	defer os.remove("_test_memory_copy.txt")
	expect_nothing_left(t, .Memory, "_test_memory_literals", {
		"SELECT x'0102ff', length(x'00')",
		"SELECT max('a', 'b'), min(3, 1, 2)",
		"CREATE TABLE t (id INT, b TEXT, v ARRAY(INT))",
		"INSERT INTO t VALUES (1, 'x', '{1,2}'), (2, 'x', '{3}'), (3, 'y', NULL)",
		"SELECT DISTINCT b FROM t",
		"DROP TABLE IF EXISTS nowhere",
		"COPY t TO '_test_memory_copy.txt'",
	})
}

@(test)
test_rtree_drop_and_compaction_leave_nothing :: proc(t: ^testing.T) {
	// Dropping an R-tree has no terms table to drop, whose refusal was kept;
	// compacting a database on disk named its log; reopening reads the
	// statistics ANALYZE saved; a rowid key read from a SQLite file went into
	// no list.
	expect_nothing_left(t, .Memory, "_test_memory_rtree", {
		"CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx, miny, maxy)",
		"INSERT INTO places (id, minx, maxx, miny, maxy) VALUES (1, 0, 10, 0, 10)",
		"DROP TABLE places",
	})
	expect_nothing_left(t, .Reopen, "_test_memory_compact", {
		"CREATE TABLE t (a INT PRIMARY KEY, b TEXT)",
		"INSERT INTO t VALUES (1, 'x'), (2, 'y')",
		"ANALYZE",
		"VACUUM",
	})
	expect_nothing_left(t, .Sqlite_File, "_test_memory_rowid_key.db", {
		"CREATE TABLE k (id INTEGER PRIMARY KEY, v TEXT UNIQUE)",
		"INSERT INTO k VALUES (1, 'a')",
	})
}
