package tests

import "core:fmt"
import "core:strings"
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

// replicate applies each commit's list to the replica as it is published. The
// changes say which are a TEMP table's (only `scratch` is) and which commit
// they are, and each update and delete carries the row it replaced: the row
// the replica, still at the state before the commit, holds under that id. A
// commit of rows only is also applied backwards, from the old rows, and has to
// give the state before it back.
@(private = "file")
replicate :: proc(ctx: rawptr, store: ^db.Store, changes: ^db.Commit_Changes) {
	replica := (^Replica)(ctx)
	fail :: proc(replica: ^Replica, message: string) {
		if len(replica.err) == 0 do replica.err = message
		else do delete(message)
	}
	if changes.seq != store.commit_seq do fail(replica, fmt.aprintf("published as commit %d, the store is at %d", changes.seq, store.commit_seq))
	target := replica.target
	target.apply_seq = changes.seq
	// The commit's changes were validated together: a key two rows swap
	// collides halfway through, as it does in the commit's own apply.
	target.apply_validated = true
	defer target.apply_validated = false
	before := dump(target)
	rows_only := true
	cache: db.Apply_Cache
	for op, i in changes.ops {
		if changes.temp[i] != (op.name == "scratch") {
			fail(replica, fmt.aprintf("commit %d, %v %s: TEMP is %v", changes.seq, op.kind, op.name, changes.temp[i]))
		}
		#partial switch op.kind {
		case .Update, .Delete:
			held, found := db.table_get_row(target.tables[op.name], op.row_id, context.temp_allocator)
			if !found || !same_values(held.values, changes.old[i]) {
				fail(replica, fmt.aprintf("commit %d, %v %s row %d: the old row is not the row replaced", changes.seq, op.kind, op.name, op.row_id))
			}
		case .Insert:
			if changes.old[i] != nil do fail(replica, fmt.aprintf("commit %d: an insert carries an old row", changes.seq))
		case:
			rows_only = false
		}
		if err := db.store_apply(target, op, &cache); err.kind != .None {
			fail(replica, fmt.aprintf("commit %d, %v %s: %s", changes.seq, op.kind, op.name, err.message))
		}
	}
	if rows_only && len(changes.ops) > 0 {
		after := dump(target)
		back: db.Apply_Cache
		for i := len(changes.ops) - 1; i >= 0; i -= 1 {
			op := changes.ops[i]
			undo := op
			#partial switch op.kind {
			case .Insert:
				undo.kind = .Delete
			case .Update:
				undo.values = changes.old[i]
			case .Delete:
				undo.kind = .Insert
				undo.values = changes.old[i]
			}
			if err := db.store_apply(target, undo, &back); err.kind != .None {
				fail(replica, fmt.aprintf("commit %d backwards, %v %s: %s", changes.seq, undo.kind, undo.name, err.message))
			}
		}
		if dump(target) != before do fail(replica, fmt.aprintf("commit %d applied backwards does not give the state before it", changes.seq))
		again: db.Apply_Cache
		for op in changes.ops do db.error_drop(db.store_apply(target, op, &again))
		if dump(target) != after do fail(replica, fmt.aprintf("commit %d applied again does not give the state after it", changes.seq))
	}
	target.commit_seq = changes.seq
}

@(private = "file")
same_values :: proc(a, b: []db.Value) -> bool {
	if len(a) != len(b) do return false
	for v, i in a do if v.kind != b[i].kind || !db.value_equal(v, b[i]) do return false
	return true
}

// dump is a store's tables and their live rows, as text.
@(private = "file")
dump :: proc(store: ^db.Store) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for name in store.tables do append(&names, name)
	slice.sort(names[:])
	b := strings.builder_make(context.temp_allocator)
	for name in names {
		table := store.tables[name]
		strings.write_string(&b, name)
		strings.write_byte(&b, '\n')
		rows := make([dynamic]db.Row)
		db.table_collect(table, &rows, max(u64))
		for row in rows {
			fmt.sbprintf(&b, "  %d:", row.id)
			for v in row.values do fmt.sbprintf(&b, " %s", db.value_format(v, context.temp_allocator))
			strings.write_byte(&b, '\n')
		}
		db.table_collect_release(table, &rows)
	}
	return strings.to_string(b)
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

@(private = "file")
Recorder :: struct {
	payloads: [dynamic][]u8,
}

@(private = "file")
record :: proc(ctx: rawptr, store: ^db.Store, changes: ^db.Commit_Changes) {
	recorder := (^Recorder)(ctx)
	w: db.Byte_Writer
	db.bw_init(&w)
	for op in changes.ops do db.store_op_encode(&w, op)
	append(&recorder.payloads, db.bw_bytes(&w))
}

// Two stores that run the same transactions publish the same changes in the
// same order: a commit that creates or drops several tables listed them in
// the order of a map, which differs from one store to the next.
@(test)
test_two_stores_publish_the_same_changes :: proc(t: ^testing.T) {
	recorders: [2]Recorder
	defer for &r in recorders {
		for payload in r.payloads do delete(payload)
		delete(r.payloads)
	}
	for &recorder in recorders {
		store, err := db.store_open("", {persistent = false})
		if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
		store.on_commit = record
		store.on_commit_ctx = &recorder
		created := make([dynamic]string, context.temp_allocator)
		dropped := make([dynamic]string, context.temp_allocator)
		for i in 0 ..< 16 {
			append(&created, fmt.tprintf("CREATE TABLE t%d (n INTEGER)", i))
			append(&created, fmt.tprintf("INSERT INTO t%d VALUES (%d)", i, i))
			append(&dropped, fmt.tprintf("DROP TABLE t%d", i))
		}
		run_in_tx(t, store, created[:])
		run_in_tx(t, store, dropped[:])
		store.on_commit = nil
		db.store_close(store)
	}
	if !testing.expect_value(t, len(recorders[0].payloads), len(recorders[1].payloads)) do return
	for payload, i in recorders[0].payloads {
		testing.expectf(t, slice.equal(payload, recorders[1].payloads[i]), "commit %d: the two stores listed different changes", i + 1)
	}
}

@(private = "file")
Published :: struct {
	seqs:   [dynamic]u64,
	tables: [dynamic]string,
}

@(private = "file")
note_published :: proc(ctx: rawptr, store: ^db.Store, changes: ^db.Commit_Changes) {
	published := (^Published)(ctx)
	append(&published.seqs, changes.seq)
	for op in changes.ops do if op.kind == .Create_Table do append(&published.tables, strings.clone(op.schema.name))
}

// A group commit publishes each of its transactions as a commit does, through
// the same step: its sequence, and its changes with their schemas, which a
// Create_Table's still pointed into the transaction freed before the apply
// read them. A transaction that needs what only a commit of its own runs (a
// commit hook here) is refused a place in a group.
@(test)
test_a_group_commit_publishes_each_transaction :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE kept (n INTEGER)")
	published: Published
	defer {
		for name in published.tables do delete(name)
		delete(published.tables)
		delete(published.seqs)
	}
	store.on_commit = note_published
	store.on_commit_ctx = &published
	first := db.tx_begin_write(store)
	created, create_err := db.sql_execute_in_tx(first, "CREATE TABLE fresh (n INTEGER)")
	db.sql_result_destroy(&created)
	testing.expect(t, db.error_ok(create_err))
	inserted, insert_err := db.sql_execute_in_tx(first, "INSERT INTO fresh VALUES (1)")
	db.sql_result_destroy(&inserted)
	testing.expect(t, db.error_ok(insert_err))
	prepared_first, first_err := db.tx_prepare(first)
	if !testing.expectf(t, db.error_ok(first_err), "prepare: %s", first_err.message) do return
	second := db.tx_begin_write(store)
	more, more_err := db.sql_execute_in_tx(second, "INSERT INTO kept VALUES (2)")
	db.sql_result_destroy(&more)
	testing.expect(t, db.error_ok(more_err))
	prepared_second, second_err := db.tx_prepare(second)
	if !testing.expectf(t, db.error_ok(second_err), "prepare: %s", second_err.message) do return
	before := store.commit_seq
	_, commit_err := db.store_commit_prepared(store, []^db.Prepared_Tx{prepared_first, prepared_second})
	db.prepared_destroy(prepared_first)
	db.prepared_destroy(prepared_second)
	store.on_commit = nil
	if !testing.expectf(t, db.error_ok(commit_err), "group commit: %s", commit_err.message) do return
	testing.expect_value(t, len(published.seqs), 2)
	if len(published.seqs) == 2 {
		testing.expect_value(t, published.seqs[0], before + 1)
		testing.expect_value(t, published.seqs[1], before + 2)
	}
	testing.expect(t, len(published.tables) == 1 && published.tables[0] == "fresh")
	testing.expect_value(t, scalar(t, store, "SELECT n FROM fresh").i, 1)
	testing.expect_value(t, scalar(t, store, "SELECT n FROM kept").i, 2)

	refuse :: proc(ctx: rawptr) -> bool { return false }
	store.hooks.commit = refuse
	hooked := db.tx_begin_write(store)
	_, hooked_err := db.tx_prepare(hooked)
	testing.expect_value(t, hooked_err.kind, db.Error_Kind.Sql_Unsupported)
	db.error_free(&hooked_err)
	store.hooks.commit = nil
}
