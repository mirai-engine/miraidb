package tests

import "core:fmt"
import "core:slice"
import "core:testing"

import db "../engine"

// A commit's list of changes is the commit (A3): applied to a copy of the
// state before it, it gives the state after it, and two stores that run the
// same transactions produce the same list, byte for byte, which is what a
// follower that replays another store's log needs (D14).

@(private = "file")
Replica :: struct {
	target: ^db.Store,
	err:    string,
}

// replicate applies each commit's list to the replica as it is published.
@(private = "file")
replicate :: proc(ctx: rawptr, store: ^db.Store, ops: []db.Store_Op) {
	replica := (^Replica)(ctx)
	replica.target.apply_seq = store.commit_seq
	cache: db.Apply_Cache
	for op in ops {
		if err := db.store_apply(replica.target, op, &cache); err.kind != .None && len(replica.err) == 0 {
			replica.err = fmt.aprintf("commit %d, %v %s: %s", store.commit_seq, op.kind, op.name, err.message)
		}
	}
	replica.target.commit_seq = store.commit_seq
}

// The statements of the corpus: every kind of change a commit carries, each
// statement its own commit, and some transactions of several.
@(private = "file")
CORPUS := []string {
	"CREATE TABLE a (id INTEGER PRIMARY KEY, k INTEGER UNIQUE, v TEXT)",
	"CREATE TABLE b (x INTEGER, y TEXT)",
	"CREATE INDEX b_x ON b (x)",
	"INSERT INTO a (k, v) VALUES (1, 'one'), (2, 'two'), (3, 'three')",
	"INSERT INTO b VALUES (1, 'p'), (2, 'q'), (2, 'r')",
	"UPDATE a SET v = upper(v) WHERE k >= 2",
	"DELETE FROM b WHERE y = 'q'",
	"INSERT OR REPLACE INTO a (id, k, v) VALUES (1, 10, 'replaced')",
	"INSERT INTO a (k, v) VALUES (2, 'clash') ON CONFLICT (k) DO UPDATE SET v = 'upserted'",
	"CREATE TRIGGER a_log AFTER UPDATE ON a BEGIN INSERT INTO b VALUES (NEW.k, 'trigger'); END",
	"UPDATE a SET v = 'fired' WHERE k = 3",
	"ALTER TABLE b ADD COLUMN z INTEGER DEFAULT 7",
	"CREATE TEMP TABLE scratch (n INTEGER)",
	"INSERT INTO scratch VALUES (1), (2)",
	"DROP INDEX b_x",
	"CREATE TABLE c (n INTEGER)",
	"INSERT INTO c VALUES (1), (2), (3)",
	"DELETE FROM c",
	"DROP TABLE c",
}

@(private = "file")
TRANSACTIONS := [][]string {
	{"INSERT INTO b VALUES (9, 'tx', 1)", "UPDATE b SET y = 'tx2' WHERE x = 9", "DELETE FROM a WHERE k = 10"},
	{"INSERT INTO a (k, v) VALUES (40, 'kept')", "SAVEPOINT s", "INSERT INTO a (k, v) VALUES (41, 'undone')", "ROLLBACK TO s", "RELEASE s"},
	{"CREATE TABLE d1 (n INTEGER)", "CREATE TABLE d2 (n INTEGER)", "INSERT INTO d1 VALUES (1)", "INSERT INTO d2 VALUES (2)"},
	{"DROP TABLE d1", "DROP TABLE d2"},
}

@(private = "file")
run_in_tx :: proc(t: ^testing.T, store: ^db.Store, statements: []string) {
	tx := db.tx_begin_write(store)
	for sql in statements {
		result, err := db.sql_execute_in_tx(tx, sql)
		testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
		db.sql_result_destroy(&result)
		db.error_free(&err)
	}
	commit_err := db.tx_commit(tx)
	testing.expectf(t, db.error_ok(commit_err), "commit: %s", commit_err.message)
	db.error_free(&commit_err)
}

@(private = "file")
same_state :: proc(t: ^testing.T, a, b: ^db.Store) {
	names := make([dynamic]string, context.temp_allocator)
	for name in a.tables do append(&names, name)
	slice.sort(names[:])
	testing.expectf(t, len(a.tables) == len(b.tables), "%d tables, the replica has %d", len(a.tables), len(b.tables))
	for name in names {
		left := a.tables[name]
		right, found := b.tables[name]
		if !testing.expectf(t, found, "the replica has no table %s", name) do continue
		testing.expectf(t, len(left.schema.columns) == len(right.schema.columns), "%s: columns differ", name)
		testing.expectf(t, len(left.schema.indexes) == len(right.schema.indexes), "%s: indexes differ", name)
		lrows := make([dynamic]db.Row)
		rrows := make([dynamic]db.Row)
		db.table_collect(left, &lrows, max(u64))
		db.table_collect(right, &rrows, max(u64))
		if testing.expectf(t, len(lrows) == len(rrows), "%s: %d rows, the replica %d", name, len(lrows), len(rrows)) {
			for row, i in lrows {
				other := rrows[i]
				same := row.id == other.id && len(row.values) == len(other.values)
				if same do for v, c in row.values do if v.kind != other.values[c].kind || !db.value_equal(v, other.values[c]) do same = false
				testing.expectf(t, same, "%s: row %d differs", name, row.id)
			}
		}
		db.table_collect_release(left, &lrows)
		db.table_collect_release(right, &rrows)
	}
}

@(private = "file")
session_exec :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) {
	err := db.embed_exec(conn, sql)
	testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
	db.error_free(&err)
}

@(test)
test_a_commit_is_reproduced_from_its_list_of_changes :: proc(t: ^testing.T) {
	// A session, so a transaction can hold savepoints.
	conn, err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.embed_close(conn)
	source := conn.store
	target, target_err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(target_err), "open: %s", target_err.message) do return
	defer db.store_close(target)
	replica := Replica{target = target}
	defer delete(replica.err)
	source.on_commit = replicate
	source.on_commit_ctx = &replica
	for sql in CORPUS do session_exec(t, conn, sql)
	for statements in TRANSACTIONS {
		session_exec(t, conn, "BEGIN")
		for sql in statements do session_exec(t, conn, sql)
		session_exec(t, conn, "COMMIT")
	}
	source.on_commit = nil
	testing.expectf(t, len(replica.err) == 0, "applying the list failed: %s", replica.err)
	same_state(t, source, target)
}
