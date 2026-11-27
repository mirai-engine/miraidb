package engine

import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "base:intrinsics"

// A Tx is one transaction. A write transaction holds the store's write lock for
// its whole life: one writer at a time, readers never see partial work. A read
// transaction holds the read lock and rejects every write.
//
// Writes are staged: reads inside the transaction see its own changes, and
// nothing reaches the committed state (or the log) until commit succeeds.
Tx :: struct {
	store:     ^Store,
	active:    bool,
	read_only: bool,
	// temp_only is a write transaction on a read-only store: it writes TEMP tables
	// and nothing else, as SQLite's temp database is writable when main is not.
	temp_only: bool,
	// wrote is set when a write statement ran in the transaction, whether or
	// not it changed a row: the commit hook runs for it.
	wrote:     bool,
	// locked is true when the transaction holds the store lock (write
	// transactions and pinned reads).
	state:     Tx_State,
	// replaced holds every table an ALTER built for this transaction. The commit
	// logs only the new schema and the store builds its own table from it, so
	// these are the transaction's to free, including one a later ALTER or a
	// ROLLBACK TO left out of state.altered.
	replaced:  [dynamic]^Table,
	// attached_txs are the transactions of the attached databases this one
	// wrote, by database name (attach.odin): they commit before it and roll back
	// with it.
	attached_txs: map[string]^Tx,
	// attach_parent is set on the transaction of an attached database: the
	// connection's transaction it writes for. A statement that writes the
	// attached database reads the others through it, as SQLite resolves
	// names across every database of the connection (attach.odin).
	// attach_name is this database's name there, and attach_target the
	// table the running statement writes.
	attach_parent: ^Tx,
	attach_name:   string,
	attach_target: string,
	arena:     virtual.Arena,
	alloc:     mem.Allocator,
	// read_seq is the commit sequence the transaction started from and
	// read_tables is the set of tables it touched.
	read_seq:    u64,
	// pinned records a read started with tx_begin_read_at: it reads the live tables
	// filtered by version stamps, so the versions it can see must be kept until it
	// ends.
	pinned:      bool,
	pinned_seq:  u64,
	// outer is the stack of frames a subquery evaluates inside: a correlated
	// reference reads the row of the statement it is written in from here.
	outer:       ^Outer_Frame,
	// cursors are the queries this transaction declared and the client reads a few
	// rows at a time. They belong to the transaction, as PostgreSQL's do: a commit
	// or a rollback closes them.
	cursors:     map[string]^Cursor,
	read_tables: map[string]bool,
	// A read transaction shares every table instead of copying it: it holds one
	// reference per table and does not hold the store lock; `locked` records
	// whether it does. A commit that has to change a table a reader holds copies
	// that table first, so what this transaction reads cannot change under it.
	use_frozen:   bool,
	locked:       bool,
	frozen:       map[string]^Table,
	frozen_list:  [dynamic]^Table,
	// cte_tables holds the common table expressions materialized for the current
	// statement; they live in temp_tables and are destroyed with the transaction.
	// work_units is what this transaction spent, summed from each statement's
	// price (rows touched plus payload). A host budget compares it before commit.
	work_units: u64,
	// rows_scanned counts the rows a scan visited. It is diagnostic: a test turns
	// it into a statement about cost (a MATCH visits its matches, not the corpus).
	rows_scanned: u64,
	// fts_cache holds the match of each (table, pattern) for this transaction, so
	// a scan and an ORDER BY rank ask the shadow tables once, not once per row.
	fts_cache: map[string]^Fts_Match,
	// fts_rank names, per virtual table, the cache entry that rank reads: the
	// last MATCH on that table in this transaction.
	fts_rank: map[string]string,
	// fts_new_docs remembers, per full-text table, the documents this transaction
	// inserted. A fresh row id cannot have postings from an earlier commit, so the
	// maintenance skips the lookup for it: a bulk load costs its tokens, not the
	// size of the index.
	fts_new_docs: map[string]map[Row_Id]bool,
	cte_tables:  map[string]^Table,
	// vtab_where and vtab_params are the WHERE of the query whose sources are
	// being read, so a program's virtual table is offered its terms
	// (vtab_materialize).
	// collation_classes groups the texts a host collation calls equal, per
	// collation, for GROUP BY, DISTINCT and PARTITION BY (collation_class).
	collation_classes: map[string][dynamic]string,
	vtab_where:  ^Expr,
	vtab_params: []Value,
	// vtab_order is the ORDER BY of a query whose only source is being read.
	vtab_order:  []Order_Item,
	// vtab_join, vtab_sources and vtab_alias are the ON clause, the sources
	// bound so far and the alias of a join step that reads a program's virtual
	// table once per outer row.
	vtab_join:    ^Expr,
	// vtabs_written are the program's virtual tables this transaction wrote
	// to; they hear its commit or its rollback (vtab_transaction_step).
	vtabs_written: [dynamic]^Vtab,
	// keep_partial says the failing statement's rows before the failing one
	// stay (a constraint's ON CONFLICT FAIL), and rollback_requested that it
	// ends the transaction (ON CONFLICT ROLLBACK).
	keep_partial:       bool,
	rollback_requested: bool,
	vtabs_done:    bool,
	vtab_sources: []Source,
	vtab_alias:   string,
	// savepoints is the open savepoint stack, innermost last.
	savepoints:  [dynamic]Savepoint,
	// Views materialize into temporary tables owned by the transaction.
	temp_tables: [dynamic]^Table,
	view_depth:  int,
	view_stack:  [VIEW_MAX_DEPTH]string,
	// Trigger firing state: the rows NEW and OLD name, the schema they belong to
	// and the nesting depth.
	trigger_active:      bool,
	trigger_schema:      Table_Schema,
	trigger_new:         Row,
	trigger_old:         Row,
	trigger_new_present: bool,
	trigger_old_present: bool,
	trigger_depth:       int,
	// statement_now_us is the time of the statement running in the
	// transaction, read from the clock once, at its first use
	// (statement_now): every row, default and trigger of one statement sees
	// the same now, as in SQLite. Zero until a statement asks for it.
	statement_now_us:    i64,
	// bindings are the links of the statement running in the transaction
	// (statement_resolve): every context it makes reads them (eval_context).
	// A node of another query is outside their block.
	bindings:            ^Statement_Bindings,
	// select_scope is the select whose rows the statement is reading now
	// (Select_Stmt.id; sql_exec_select sets it), which every context it makes
	// takes (Eval_Ctx.scope). select_plans are the join plans of the selects
	// of the running statement, by their number: a subquery run for every row
	// of the query around it plans once (A1.8g).
	select_scope:        Node_Id,
	select_plans:        map[Node_Id]Plan_Order,
	// catalog_seen is the catalog generation (store_catalog_generation) the
	// transaction began at, read under the store's lock with its view of the
	// catalog: a tree resolved in it holds for another transaction that began
	// at the same one (tx_catalog_generation).
	catalog_seen:        u64,
	// no_triggers loads rows that another connection already wrote (catching up
	// with a shared SQLite file): its triggers ran there, and must not run twice.
	no_triggers:         bool,
	// grant_probe and trigger_probe remember whether `_grant` and `_trigger`
	// exist for this transaction. Every inserted row asked both (four times in
	// all, each through half a dozen maps keyed by name) and the answer changes
	// only when this transaction creates, drops or renames a table or rolls back
	// to a savepoint, which reset them.
	grant_probe:         Probe_State,
	trigger_probe:       Probe_State,
	// insert_name, insert_table and insert_writes are the table the last insert
	// or update resolved and its staging record: a statement that writes many
	// rows names one table, and resolving it went through six maps keyed by name
	// per row. The same changes that reset the probes reset these.
	insert_name:         string,
	insert_table:        ^Table,
	insert_writes:       ^Table_Writes,
	// insert_committed is the committed table of that name a unique key may
	// collide with: nil when there is none or this transaction dropped it.
	insert_committed:    ^Table,
	// explicit_row_id is the rowid an INSERT names (`INSERT INTO t (rowid, x)`)
	// for the next row it stores, when has_explicit_row_id is set.
	explicit_row_id:     Row_Id,
	has_explicit_row_id: bool,
	// undo records what each change to the staged rows replaced, while a
	// statement is open (undo_depth > 0), so a statement that fails halfway can
	// be taken back without touching the work of the statements before it. A
	// trigger's statement nests inside the one that fired it.
	undo:                [dynamic]Stage_Undo,
	undo_depth:          int,
	// deferred_fks names the child tables whose DEFERRABLE INITIALLY DEFERRED
	// keys this transaction may have broken; COMMIT verifies them.
	deferred_fks:        map[string]bool,
	// update_set names the columns the SET of the UPDATE running now writes,
	// for the UPDATE OF triggers it fires; nil when the write has no SET.
	update_set:          []string,
}

Table_Writes :: struct {
	inserts:     Staged_Rows,
	updates:     map[Row_Id][]Value,
	deletes:     map[Row_Id]bool,
	truncated:   bool,
	unique_keys: map[string]Row_Id,
	// unique_ints holds the staged keys of the indexes that file integer keys
	// (Staged_Key); `unique_keys` every other.
	unique_ints: Staged_Ints,
	next_row_id: u64,
	next_sequence: i64,
	// int_key_* is the largest integer the staged inserts hold in an INTEGER
	// PRIMARY KEY (tx_next_int_key): `int_key_column` is its position plus one,
	// 0 when not known. A row appended is weighed into it; any other change to
	// the staged inserts forgets it (writes_int_key_forget), and the next key
	// walks them again. Walking them at every insert made a load of n rows that
	// leave the key out cost n²/2 row reads.
	int_key_column: int,
	int_key_top:    i64,
	int_key_found:  bool,
}

// writes_int_key_forget drops what Table_Writes knows of its inserts' largest
// integer key: a staged insert was replaced, taken out or reshaped.
@(private)
writes_int_key_forget :: #force_inline proc(writes: ^Table_Writes) {
	writes.int_key_column = 0
}

// writes_int_key_weigh counts an appended insert's key into the largest known.
@(private)
writes_int_key_weigh :: #force_inline proc(writes: ^Table_Writes, values: []Value) {
	if writes.int_key_column == 0 do return
	position := writes.int_key_column - 1
	if position >= len(values) || values[position].kind != .Int do return
	if !writes.int_key_found || values[position].i > writes.int_key_top {
		writes.int_key_top = values[position].i
		writes.int_key_found = true
	}
}

// Stage_Undo is one change to a transaction's staged rows, as it was before the
// change: whether the slot was filled and what it held.
Stage_Undo_Kind :: enum u8 {
	Insert,
	Update,
	Delete,
	Unique,
	Unique_Int,
	Counters,
}

Stage_Undo :: struct {
	kind:          Stage_Undo_Kind,
	writes:        ^Table_Writes,
	id:            Row_Id,
	key:           string,
	int_key:       [3]u64,
	had:           bool,
	row:           Row,
	values:        []Value,
	holder:        Row_Id,
	next_row_id:   u64,
	next_sequence: i64,
}

// tx_statement_begin opens a statement whose staged changes can be taken back
// as a unit, and returns the mark tx_statement_end needs. Statements nest.
tx_statement_begin :: proc(tx: ^Tx) -> int {
	if tx.undo == nil do tx.undo = make([dynamic]Stage_Undo, 0, 16, tx.alloc)
	tx.undo_depth += 1
	return len(tx.undo)
}

// tx_statement_end closes a statement. A failed one has every change it staged
// since `mark` undone, newest first, so the transaction holds exactly what it
// held before the statement began; SQLite calls this ABORT.
tx_statement_end :: proc(tx: ^Tx, mark: int, failed: bool) {
	if failed do tx_statement_undo(tx, mark)
	tx.undo_depth -= 1
	if tx.undo_depth == 0 do clear(&tx.undo)
}

// tx_statement_undo takes back the changes staged since `mark`, newest first.
tx_statement_undo :: proc(tx: ^Tx, mark: int) {
	for i := len(tx.undo) - 1; i >= mark; i -= 1 {
		u := tx.undo[i]
		w := u.writes
		switch u.kind {
		case .Insert:
			writes_int_key_forget(w)
			if u.had do srows_set(&w.inserts, u.row)
			else do srows_erase(&w.inserts, u.id)
		case .Update:
			if u.had do w.updates[u.id] = u.values
			else do map_erase(&w.updates, u.id)
		case .Delete:
			if u.had do w.deletes[u.id] = true
			else do map_erase(&w.deletes, u.id)
		case .Unique:
			if u.had do w.unique_keys[u.key] = u.holder
			else do map_erase(&w.unique_keys, u.key)
		case .Unique_Int:
			if u.had do staged_ints_put(&w.unique_ints, u.int_key, u.holder)
			else do staged_ints_erase(&w.unique_ints, u.int_key)
		case .Counters:
			w.next_row_id = u.next_row_id
			w.next_sequence = u.next_sequence
		}
	}
	resize(&tx.undo, mark)
	// The cached table and staging record are still right: undo changes rows,
	// not which table a name resolves to.
}

@(private)
undo_note_insert :: #force_inline proc(tx: ^Tx, w: ^Table_Writes, id: Row_Id) {
	if tx.undo_depth == 0 do return
	row, had := srows_get(&w.inserts, id)
	append(&tx.undo, Stage_Undo{kind = .Insert, writes = w, id = id, had = had, row = row})
}

@(private)
undo_note_update :: #force_inline proc(tx: ^Tx, w: ^Table_Writes, id: Row_Id) {
	if tx.undo_depth == 0 do return
	values, had := w.updates[id]
	append(&tx.undo, Stage_Undo{kind = .Update, writes = w, id = id, had = had, values = values})
}

@(private)
undo_note_delete :: #force_inline proc(tx: ^Tx, w: ^Table_Writes, id: Row_Id) {
	if tx.undo_depth == 0 do return
	_, had := w.deletes[id]
	append(&tx.undo, Stage_Undo{kind = .Delete, writes = w, id = id, had = had})
}

@(private)
undo_note_unique :: #force_inline proc(tx: ^Tx, w: ^Table_Writes, key: Staged_Key) {
	if tx.undo_depth == 0 do return
	holder, had := staged_holder(w, key)
	if key.is_int {
		append(&tx.undo, Stage_Undo{kind = .Unique_Int, writes = w, int_key = key.int, had = had, holder = holder})
	} else {
		append(&tx.undo, Stage_Undo{kind = .Unique, writes = w, key = key.text, had = had, holder = holder})
	}
}

// Staged_Key is a unique key a transaction stages: the integer key of an index
// that files them (index_int_key), named by the index's position in its table,
// or the encoded key of any other index. A position changes only under an ALTER
// in the transaction, which clears both maps. An integer key is two words to
// hash, where the encoded key was the index's name and the value's bytes,
// built in the arena for every row (R2).
Staged_Key :: struct {
	text:   string,
	int:    [3]u64,
	is_int: bool,
}

// staged_key is the key under which `values` holds index `index` of `table`.
staged_key :: proc(tx: ^Tx, table: ^Table, index: int, values: []Value) -> Staged_Key {
	if key, ok := table_index_int_key(table, index, values); ok {
		return Staged_Key{int = {u64(index), key[0], key[1]}, is_int = true}
	}
	return Staged_Key{text = unique_key(tx, table, index, values)}
}

// staged_holder answers which staged row holds a key.
staged_holder :: proc(w: ^Table_Writes, key: Staged_Key) -> (Row_Id, bool) {
	if key.is_int {
		holder, ok := staged_ints_get(&w.unique_ints, key.int)
		return holder, ok
	}
	holder, ok := w.unique_keys[key.text]
	return holder, ok
}

// staged_set files a staged key under `id`, noted for a statement's undo.
@(private)
staged_set :: proc(tx: ^Tx, w: ^Table_Writes, key: Staged_Key, id: Row_Id) {
	undo_note_unique(tx, w, key)
	if key.is_int do staged_ints_put(&w.unique_ints, key.int, id)
	else do w.unique_keys[key.text] = id
}

@(private)
undo_note_counters :: #force_inline proc(tx: ^Tx, w: ^Table_Writes) {
	if tx.undo_depth == 0 do return
	append(&tx.undo, Stage_Undo{kind = .Counters, writes = w, next_row_id = w.next_row_id, next_sequence = w.next_sequence})
}

// Tx_Index_Op is index DDL staged by a transaction. It is applied after the rows
// of the same commit, so an index over rows inserted in the transaction is built
// once, from the final rows, before any reader sees the commit.
Tx_Index_Op :: struct {
	drop:  bool,
	table: string,
	index: Index_Schema,
}

// Tx_Snapshot is the staged state a savepoint remembers. The map containers are
// copied so restoring cannot disturb the live state; the values they hold live
// in the transaction arena and are shared.
Tx_Snapshot :: struct {
	writes:    map[string]^Table_Writes,
	created:   map[string]^Table,
	altered:   map[string]^Table,
	dropped:   map[string]bool,
	index_ops: [dynamic]Tx_Index_Op,
}

// Savepoint names a point in the transaction a ROLLBACK TO can return to.
Savepoint :: struct {
	name:     string,
	snapshot: Tx_Snapshot,
}

Tx_State :: struct {
	writes:    map[string]^Table_Writes,
	created:   map[string]^Table,
	altered:   map[string]^Table,
	dropped:   map[string]bool,
	index_ops: [dynamic]Tx_Index_Op,
}

@(private)
tx_state_view :: proc(tx: ^Tx) -> Tx_Snapshot {
	return Tx_Snapshot {
		writes = tx.state.writes,
		created = tx.state.created,
		altered = tx.state.altered,
		dropped = tx.state.dropped,
		index_ops = tx.state.index_ops,
	}
}

@(private)
tx_snapshot_clone :: proc(tx: ^Tx, from: Tx_Snapshot) -> Tx_Snapshot {
	snapshot: Tx_Snapshot
	snapshot.writes = make(map[string]^Table_Writes, len(from.writes), tx.alloc)
	for name, writes in from.writes {
		// The struct is the heap's, as tx_writes makes it: a snapshot that a
		// ROLLBACK TO restores becomes the live state, which tx_discard frees.
		copied := new(Table_Writes)
		copied^ = writes^
		srows_copy(&copied.inserts, &writes.inserts, tx.alloc)
		copied.updates = make(map[Row_Id][]Value, len(writes.updates), tx.alloc)
		for id, values in writes.updates do copied.updates[id] = values
		copied.deletes = make(map[Row_Id]bool, len(writes.deletes), tx.alloc)
		for id in writes.deletes do copied.deletes[id] = true
		copied.unique_keys = make(map[string]Row_Id, len(writes.unique_keys), tx.alloc)
		for key, id in writes.unique_keys do copied.unique_keys[key] = id
		staged_ints_copy(&copied.unique_ints, &writes.unique_ints, tx.alloc)
		snapshot.writes[name] = copied
	}
	snapshot.created = make(map[string]^Table, len(from.created), tx.alloc)
	for name, table in from.created do snapshot.created[name] = table
	snapshot.altered = make(map[string]^Table, len(from.altered), tx.alloc)
	for name, table in from.altered do snapshot.altered[name] = table
	snapshot.dropped = make(map[string]bool, len(from.dropped), tx.alloc)
	for name in from.dropped do snapshot.dropped[name] = true
	snapshot.index_ops = make([dynamic]Tx_Index_Op, 0, len(from.index_ops), tx.alloc)
	for op in from.index_ops do append(&snapshot.index_ops, op)
	return snapshot
}

@(private)
tx_snapshot_destroy :: proc(tx: ^Tx, snapshot: ^Tx_Snapshot) {
	// The maps carry their own allocator; the struct is the heap's (tx_writes,
	// tx_snapshot_clone).
	for _, writes in snapshot.writes {
		srows_destroy(&writes.inserts)
		delete(writes.updates)
		delete(writes.deletes)
		delete(writes.unique_keys)
		staged_ints_destroy(&writes.unique_ints)
		free(writes)
	}
	delete(snapshot.writes)
	delete(snapshot.created)
	delete(snapshot.altered)
	delete(snapshot.dropped)
	delete(snapshot.index_ops)
	snapshot^ = {}
}

// tx_state_replace disposes the live containers and adopts the snapshot's.
@(private)
tx_state_replace :: proc(tx: ^Tx, snapshot: Tx_Snapshot) {
	tx_forget_catalog_cache(tx)
	current := tx_state_view(tx)
	tx_snapshot_destroy(tx, &current)
	tx.state.writes = snapshot.writes
	tx.state.created = snapshot.created
	tx.state.altered = snapshot.altered
	tx.state.dropped = snapshot.dropped
	tx.state.index_ops = snapshot.index_ops
}

// tx_savepoint records everything the transaction has staged so far.
tx_savepoint :: proc(tx: ^Tx, name: string) -> Error {
	if !tx.active do return errf(.Transaction_Closed, "transaction is not active")
	// Reusing a name replaces the older savepoint, as SQLite does.
	for i := 0; i < len(tx.savepoints); i += 1 {
		if !strings.equal_fold(tx.savepoints[i].name, name) do continue
		tx_snapshot_destroy(tx, &tx.savepoints[i].snapshot)
		for j := i; j + 1 < len(tx.savepoints); j += 1 do tx.savepoints[j] = tx.savepoints[j + 1]
		resize(&tx.savepoints, len(tx.savepoints) - 1)
		break
	}
	snapshot := tx_snapshot_clone(tx, tx_state_view(tx))
	append(&tx.savepoints, Savepoint{name = strings.clone(name, tx.alloc), snapshot = snapshot})
	return vtab_transaction_step(tx, .Savepoint, len(tx.savepoints) - 1)
}

// tx_release_savepoint drops the named savepoint and every one nested inside it.
tx_release_savepoint :: proc(tx: ^Tx, name: string) -> Error {
	for i := len(tx.savepoints) - 1; i >= 0; i -= 1 {
		if !strings.equal_fold(tx.savepoints[i].name, name) do continue
		for j := len(tx.savepoints) - 1; j >= i; j -= 1 do tx_snapshot_destroy(tx, &tx.savepoints[j].snapshot)
		resize(&tx.savepoints, i)
		return vtab_transaction_step(tx, .Release, i)
	}
	return errf(.Invalid_Argument, "no such savepoint: %s", name)
}

// tx_rollback_to_savepoint undoes the work staged after the savepoint and keeps
// it open. Savepoints opened after it are discarded, and tables created after it
// are destroyed.
tx_rollback_to_savepoint :: proc(tx: ^Tx, name: string) -> Error {
	tx_forget_catalog_cache(tx)
	for i := len(tx.savepoints) - 1; i >= 0; i -= 1 {
		if !strings.equal_fold(tx.savepoints[i].name, name) do continue
		for j := len(tx.savepoints) - 1; j > i; j -= 1 do tx_snapshot_destroy(tx, &tx.savepoints[j].snapshot)
		resize(&tx.savepoints, i + 1)
		for created_name, table in tx.state.created {
			if _, keep := tx.savepoints[i].snapshot.created[created_name]; keep do continue
			table_destroy(table)
		}
		restored := tx_snapshot_clone(tx, tx.savepoints[i].snapshot)
		tx_state_replace(tx, restored)
		return vtab_transaction_step(tx, .Rollback_To, i)
	}
	return errf(.Invalid_Argument, "no such savepoint: %s", name)
}

Probe_State :: enum u8 {
	Unknown,
	Absent,
	Present,
}

// tx_system_table_exists answers "does this system table exist" from the
// transaction's cache, filling it on the first question. A CTE can shadow any
// name, so while one is in scope the question goes to the catalog every time.
tx_system_table_exists :: proc(tx: ^Tx, name: string, state: ^Probe_State) -> bool {
	if len(tx.cte_tables) > 0 do return tx_table_probe(tx, name) != nil
	switch state^ {
	case .Absent:
		return false
	case .Present:
		return true
	case .Unknown:
	}
	exists := tx_table_probe(tx, name) != nil
	state^ = exists ? .Present : .Absent
	return exists
}

// tx_forget_catalog_cache drops the cached answers after a change that can
// create, remove, rename or replace a table, or restore a savepoint.
tx_forget_catalog_cache :: proc(tx: ^Tx) {
	tx.grant_probe = .Unknown
	tx.trigger_probe = .Unknown
	tx.insert_name = ""
	tx.insert_table = nil
	tx.insert_writes = nil
	tx.insert_committed = nil
}

// TX_ARENA_POOL is how many emptied arenas a store keeps: one per transaction
// that can be open at once in practice (a writer and a few readers). An arena
// that grew past its first block gives the extra blocks back when it is emptied,
// so the pool holds at most this many first blocks.
TX_ARENA_POOL :: 4

// tx_arena_take gives a transaction an empty arena: one a closed transaction
// returned when there is one, a new one otherwise.
@(private)
tx_arena_take :: proc(store: ^Store, arena: ^virtual.Arena) {
	sync.mutex_lock(&store.arena_mutex)
	if len(store.arenas) > 0 {
		arena^ = pop(&store.arenas)
		sync.mutex_unlock(&store.arena_mutex)
		return
	}
	sync.mutex_unlock(&store.arena_mutex)
	if arena_err := virtual.arena_init_growing(arena); arena_err != .None {
		panic("miraidb: cannot allocate the transaction arena")
	}
}

// tx_arena_give empties a transaction's arena and keeps it for the next one, or
// releases it when the pool is full. Emptying frees every block but the first
// and zeroes what the transaction used of it, so nothing of one transaction is
// readable by the next.
@(private)
tx_arena_give :: proc(store: ^Store, arena: ^virtual.Arena) {
	virtual.arena_free_all(arena)
	sync.mutex_lock(&store.arena_mutex)
	if len(store.arenas) < TX_ARENA_POOL {
		append(&store.arenas, arena^)
		sync.mutex_unlock(&store.arena_mutex)
		arena^ = {}
		return
	}
	sync.mutex_unlock(&store.arena_mutex)
	virtual.arena_destroy(arena)
}

tx_begin_write :: proc(store: ^Store) -> ^Tx {
	tx := new(Tx)
	// A read-only store writes its TEMP tables: every write path asks
	// tx_write_refused, which refuses any other table with the read error.
	tx.temp_only = store.read_only
	tx.store = store
	tx.active = true
	tx_arena_take(store, &tx.arena)
	tx.alloc = arena_allocator_guarded(&tx.arena)
	tx.read_seq = store.commit_seq
	tx.read_tables = make(map[string]bool)
	tx.cte_tables = make(map[string]^Table)
	tx.cursors = make(map[string]^Cursor)
	tx.state.writes = make(map[string]^Table_Writes)
	tx.state.created = make(map[string]^Table)
	tx.state.altered = make(map[string]^Table)
	tx.state.dropped = make(map[string]bool)
	tx.state.index_ops = make([dynamic]Tx_Index_Op)
	tx.locked = true
	sync.lock(&store.mutex)
	tx.catalog_seen = store_catalog_generation(store)
	return tx
}

tx_begin_read :: proc(store: ^Store) -> ^Tx {
	tx := new(Tx)
	tx.store = store
	tx.active = true
	tx.read_only = true
	tx_arena_take(store, &tx.arena)
	tx.alloc = arena_allocator_guarded(&tx.arena)
	// A read's maps live in its arena, as everything it keeps does: they are
	// made by bumping a pointer and go with the arena, where a statement made
	// and freed five of them in the heap (A1.9).
	tx.read_tables = make(map[string]bool, tx.alloc)
	tx.cte_tables = make(map[string]^Table, tx.alloc)
	tx.cursors = make(map[string]^Cursor, tx.alloc)
	tx.use_frozen = true
	// The lock is held only while the snapshot is taken or borrowed; the
	// statement then runs without it, so a long read never blocks a commit.
	sync.shared_lock(&store.mutex)
	tx.read_seq = store.commit_seq
	tx.catalog_seen = store_catalog_generation(store)
	// A store with page-backed tables cannot take a snapshot without decoding
	// every row, which is exactly what pages exist to avoid. Such a read holds
	// the shared lock for its whole life and reads the live tables: writers wait,
	// and no commit can land between its statements, so it still sees one state.
	if store.has_paged {
		tx.use_frozen = false
		tx.locked = true
		return tx
	}
	// Share every table instead of copying it. One commit cannot land between
	// two statements of this transaction either: the shared lock is held until
	// the references are taken, and a commit that later changes one of these
	// tables copies it first (store_table_writable), so this view never moves.
	tx.frozen = make(map[string]^Table, len(store.tables), tx.alloc)
	tx.frozen_list = make([dynamic]^Table, 0, len(store.tables), tx.alloc)
	for name, table in store.tables {
		shared := table_share(table)
		tx.frozen[name] = shared
		append(&tx.frozen_list, shared)
	}
	sync.shared_unlock(&store.mutex)
	return tx
}

// tx_begin_read_at starts a read transaction pinned to an older sequence. It is
// how a caller reads consistently at a snapshot it captured earlier; the row
// versions still hold that view until store_prune_versions runs.
tx_begin_read_at :: proc(store: ^Store, seq: u64) -> ^Tx {
	// A pinned read uses the live tables with versions instead of a snapshot.
	tx := tx_begin_read(store)
	// The shared tables are no longer needed: a pinned read walks the live ones
	// and filters by the version stamps, which is what keeps an older view.
	for table in tx.frozen_list do table_release(table)
	delete(tx.frozen_list)
	delete(tx.frozen)
	tx.frozen = nil
	tx.frozen_list = nil
	tx.use_frozen = false
	tx.pinned = true
	tx.pinned_seq = seq
	if seq < tx.read_seq do tx.read_seq = seq
	// Announce the pin before taking the read lock: the write side prunes history
	// while it holds the store's lock, and a pin nobody can see is history gone.
	store_pin_read(store, seq)
	sync.shared_lock(&store.mutex)
	tx.locked = true
	return tx
}

// tx_end releases a transaction that was neither committed nor rolled back.
tx_end :: proc(tx: ^Tx) {
	if tx == nil || !tx.active do return
	if tx.rows_scanned > 0 {
		sync.atomic_add(&tx.store.rows_scanned, tx.rows_scanned)
	}
	tx_discard(tx)
}

tx_rollback :: proc(tx: ^Tx) {
	if tx == nil || !tx.active do return
	tx_discard(tx)
}

@(private)
tx_discard :: proc(tx: ^Tx) {
	// What a commit did not take is undone with the transaction.
	if tx.attached_txs != nil do tx_attached_rollback(tx)
	// A virtual table written in a transaction that did not commit rolls back.
	if len(tx.vtabs_written) > 0 && !tx.vtabs_done {
		tx.vtabs_done = true
		error_drop(vtab_transaction_step(tx, .Rollback))
	}
	tx.active = false
	// Cursors, their rows and their column names live in the transaction's arena:
	// dropping the map is the whole cleanup.
	delete(tx.cursors)
	for table in tx.temp_tables {
		table_destroy(table)
	}
	delete(tx.temp_tables)
	for _, table in tx.state.created {
		table_destroy(table)
	}
	for _, writes in tx.state.writes {
		// The staged values may live in the transaction arena (a statement that
		// validates against a typed column builds them there), so this frees the maps
		// and the struct, and the arena reclaims the values with the transaction.
		srows_destroy(&writes.inserts)
		delete(writes.updates)
		delete(writes.deletes)
		delete(writes.unique_keys)
		staged_ints_destroy(&writes.unique_ints)
		// tx_writes allocates the struct with `new`, not from the arena: a statement
		// that wrote one table left 152 bytes behind for every commit.
		free(writes)
	}
	for i in 0 ..< len(tx.savepoints) do tx_snapshot_destroy(tx, &tx.savepoints[i].snapshot)
	delete(tx.savepoints)
	for _, match in tx.fts_cache {
		if match == nil do continue
		delete(match.docs)
		delete(match.scores)
		free(match)
	}
	delete(tx.fts_cache)
	delete(tx.fts_rank)
	for _, documents in tx.fts_new_docs do delete(documents)
	delete(tx.fts_new_docs)
	delete(tx.cte_tables)
	delete(tx.read_tables)
	delete(tx.state.index_ops)
	delete(tx.state.writes)
	delete(tx.state.created)
	delete(tx.state.altered)
	for table in tx.replaced do table_release(table)
	delete(tx.replaced)
	delete(tx.state.dropped)
	for table in tx.frozen_list do table_release(table)
	delete(tx.frozen_list)
	delete(tx.frozen)
	tx_arena_give(tx.store, &tx.arena)
	pinned := tx.pinned
	pinned_seq := tx.pinned_seq
	// How much row history stays is the store's retention, applied after each
	// commit (retention.odin, D3); a pinned read keeps what it reads.
	store := tx.store
	if tx.locked {
		if tx.read_only {
			sync.shared_unlock(&store.mutex)
		} else {
			sync.unlock(&store.mutex)
		}
	}
	free(tx)
	if pinned do store_unpin_read(store, pinned_seq)
}

// --- Lookup ----------------------------------------------------------------

tx_table :: proc(tx: ^Tx, name: string) -> (^Table, Error) {
	if client_untrusted(tx.store) && credential_table(name) do return nil, client_credential_refusal(name)
	// The key must outlive the statement's query arena. It is cloned once per
	// table: an insert looks up four tables (its own, grants and triggers twice),
	// and cloning the name on every lookup cost more than the lookup.
	if name not_in tx.read_tables do tx.read_tables[strings.clone(name, tx.alloc)] = true
	if table, ok := tx.cte_tables[name]; ok {
		return table, ERROR_NONE
	}
	if table, ok := tx.state.altered[name]; ok {
		return table, ERROR_NONE
	}
	if table, ok := tx.state.created[name]; ok {
		return table, ERROR_NONE
	}
	if tx.state.dropped[name] {
		return nil, errf(.Table_Not_Found, "table %s was dropped in this transaction", name)
	}
	if tx.use_frozen {
		if table, found := tx.frozen[name]; found do return table, ERROR_NONE
		return nil, errf(.Table_Not_Found, "table %s is not visible to this transaction", name)
	}
	return store_table(tx.store, name)
}

// tx_table_probe answers "can this transaction see that table?" and returns nil
// when it cannot. `tx_table` builds an error message to explain the miss, and a
// caller that only checks the kind and drops the error leaks that message: a
// SELECT asked whether `_view` exists and whether its (empty) FROM named a table on
// every statement, which `tools/leakcheck` counted as two live allocations per
// statement. Ask with this when the answer is a bool.
tx_table_probe :: proc(tx: ^Tx, name: string) -> ^Table {
	if client_untrusted(tx.store) && credential_table(name) do return nil
	// The key must outlive the statement's query arena. It is cloned once per
	// table: an insert looks up four tables (its own, grants and triggers twice),
	// and cloning the name on every lookup cost more than the lookup.
	if name not_in tx.read_tables do tx.read_tables[strings.clone(name, tx.alloc)] = true
	if table, ok := tx.cte_tables[name]; ok do return table
	if table, ok := tx.state.altered[name]; ok do return table
	if table, ok := tx.state.created[name]; ok do return table
	if tx.state.dropped[name] do return nil
	if tx.use_frozen do return tx.frozen[name]
	table, ok := tx.store.tables[name]
	return table if ok else nil
}

// tx_read_any reports whether the transaction has read one of the program's
// tables, which is when SQLite's deferred transaction starts reading.
tx_read_any :: proc(tx: ^Tx) -> bool {
	for name in tx.read_tables {
		if len(name) > 0 && name[0] != '_' do return true
	}
	return false
}

// tx_read_seq is the commit the transaction reads from.
tx_read_seq :: proc(tx: ^Tx) -> u64 {
	return tx.read_seq
}

// tx_read_tables lists the tables the transaction touched, sorted.
tx_read_tables :: proc(tx: ^Tx, alloc: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, len(tx.read_tables), alloc)
	for name in tx.read_tables do append(&names, name)
	slice_sort_strings(names[:])
	return names[:]
}

// tx_paged_alter_guard refuses a schema change on a paged table. The change
// rewrites every row through the in-memory map, which a paged table does not
// have; until the rewrite can stream over pages, refusing is the honest answer.
@(private)
tx_paged_alter_guard :: proc(tx: ^Tx, name: string) -> Error {
	if table, exists := tx.store.tables[name]; exists && table.paged != nil {
		return errf(.Sql_Unsupported, "alter a table that uses the page store")
	}
	return ERROR_NONE
}

// tx_reshape_staged gives the rows a transaction staged for `name` the shape
// of `next_schema`.
@(private)
tx_reshape_staged :: proc(tx: ^Tx, name: string, current: ^Table_Schema, next_schema: Table_Schema) -> Error {
	writes, has_writes := tx.state.writes[name]
	if !has_writes do return ERROR_NONE
	for row in srows_ptrs(&writes.inserts) {
		values, convert_err := alter_row_values(current, next_schema, row.values, tx.alloc)
		if convert_err.kind != .None do return convert_err
		row.values = values
	}
	for _, &values in writes.updates {
		converted, convert_err := alter_row_values(current, next_schema, values, tx.alloc)
		if convert_err.kind != .None do return convert_err
		values = converted
	}
	return ERROR_NONE
}

// tx_alter_created alters a table this transaction created: the created table
// is replaced by one of the new shape, which the commit creates as it is. It
// was refused, where SQLite runs it.
@(private)
tx_alter_created :: proc(tx: ^Tx, name: string, created: ^Table, next_schema: Table_Schema) -> Error {
	schema := next_schema
	replacement, create_err := table_create(&schema)
	if create_err.kind != .None do return create_err
	row_rows := rows_iter(&created.rows)
	for row in rows_next(&row_rows) {
		if row.deleted_seq != 0 do continue
		values, convert_err := alter_row_values(&created.schema, next_schema, row.values, tx.alloc)
		if convert_err.kind == .None do convert_err = table_insert(replacement, row.id, values)
		if convert_err.kind != .None {
			table_destroy(replacement)
			return convert_err
		}
	}
	replacement.next_row_id = created.next_row_id
	replacement.next_sequence = created.next_sequence
	if reshape_err := tx_reshape_staged(tx, name, &created.schema, next_schema); reshape_err.kind != .None {
		table_destroy(replacement)
		return reshape_err
	}
	// The map's key is the created table's own name: erase before re-keying, and
	// free the old table with the transaction (its writes may name it).
	map_erase(&tx.state.created, name)
	tx.state.created[replacement.schema.name] = replacement
	append(&tx.replaced, created)
	return ERROR_NONE
}

// tx_alter_table stages a schema change. The replacement table already carries
// the extra columns for every existing row, so the commit only records the
// schema and the store rebuilds the same way on replay.
tx_alter_table :: proc(tx: ^Tx, name: string, next_schema: Table_Schema) -> Error {
	if refusal := client_authority_check(tx.store, name); refusal.kind != .None do return refusal
	tx_forget_catalog_cache(tx)
	if tx_write_refused(tx, name) do return errf(.Transaction_Read_Only, "cannot alter a table in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, name); kept_err.kind != .None do return kept_err
	}
	if guard_err := tx_paged_alter_guard(tx, name); guard_err.kind != .None do return guard_err
	if created, is_created := tx.state.created[name]; is_created {
		// A savepoint keeps the created table it saw: replacing it under one
		// would leave the savepoint naming a table this one frees.
		if len(tx.savepoints) > 0 {
			return errf(.Sql_Unsupported, "alter a table created in this transaction under a savepoint")
		}
		return tx_alter_created(tx, name, created, next_schema)
	}
	current, current_err := tx_table(tx, name)
	if current_err.kind != .None do return current_err
	schema := next_schema
	replacement, create_err := table_create(&schema)
	if create_err.kind != .None do return create_err
	append(&tx.replaced, replacement)
	row_rows := rows_iter(&current.rows)
	for row in rows_next(&row_rows) {
		// A deleted row stays as a tombstone for older readers: copied, it came
		// back to life in the altered table.
		if row.deleted_seq != 0 do continue
		id := row.id
		values, convert_err := alter_row_values(&current.schema, next_schema, row.values, tx.alloc)
		if convert_err.kind != .None do return convert_err
		if insert_err := table_insert(replacement, id, values); insert_err.kind != .None {
			return insert_err
		}
	}
	// The rows this transaction staged take the new shape too: they kept the old
	// one, read NULL for an added column instead of its DEFAULT, and an UPDATE of
	// one indexed past its values.
	if reshape_err := tx_reshape_staged(tx, name, &current.schema, next_schema); reshape_err.kind != .None do return reshape_err
	replacement.next_row_id = current.next_row_id
	replacement.next_sequence = current.next_sequence
	tx.state.altered[strings.clone(name, tx.alloc)] = replacement
	return ERROR_NONE
}

// tx_alter_column_type changes the declared type of one column and converts every
// stored value to it, with CAST's rules. A value the conversion refuses refuses the
// statement, so the table is either wholly the new type or untouched; duplicates a
// conversion creates (two texts that become the same integer) are caught by the
// uniqueness check of the rebuilt table.
tx_alter_column_type :: proc(tx: ^Tx, name, column_name: string, next_type: Column_Type) -> Error {
	tx_forget_catalog_cache(tx)
	if tx_write_refused(tx, name) do return errf(.Transaction_Read_Only, "cannot alter a table in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, name); kept_err.kind != .None do return kept_err
	}
	if guard_err := tx_paged_alter_guard(tx, name); guard_err.kind != .None do return guard_err
	if _, created := tx.state.created[name]; created {
		return errf(.Sql_Unsupported, "alter a table outside the transaction that created it")
	}
	current, current_err := tx_table(tx, name)
	if current_err.kind != .None do return current_err
	index, found := schema_column_index(&current.schema, column_name)
	if !found do return errf(.Column_Not_Found, "column %s does not exist in %s", column_name, name)
	if current.schema.columns[index].generated {
		return errf(.Sql_Unsupported, "cannot change the type of the generated column %s", column_name)
	}
	columns := make([]Column, len(current.schema.columns), tx.alloc)
	copy(columns, current.schema.columns)
	unchanged := type_equal(columns[index].type, next_type)
	if !unchanged {
		columns[index].type = next_type
		// The name of a CREATE TYPE declaration described the old type; the column
		// now carries the type this statement named.
		columns[index].named_type = ""
	}
	next_schema := current.schema
	next_schema.columns = columns
	if validate_err := schema_validate(&next_schema); validate_err.kind != .None {
		return validate_err
	}
	// An unchanged type is a no-op that still validates, so a caller can run a
	// migration twice without copying the table the second time.
	if unchanged do return ERROR_NONE
	return tx_alter_table(tx, name, next_schema)
}

// tx_drop_column removes a column from a table and every row, including the
// rows staged in this transaction. Keys and auto-increment columns cannot go:
// their identity is part of how the table is written.
tx_drop_column :: proc(tx: ^Tx, name, column_name: string) -> Error {
	tx_forget_catalog_cache(tx)
	if tx_write_refused(tx, name) do return errf(.Transaction_Read_Only, "cannot alter a table in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, name); kept_err.kind != .None do return kept_err
	}
	if guard_err := tx_paged_alter_guard(tx, name); guard_err.kind != .None do return guard_err
	if _, created := tx.state.created[name]; created {
		return errf(.Sql_Unsupported, "alter a table outside the transaction that created it")
	}
	current, current_err := tx_table(tx, name)
	if current_err.kind != .None do return current_err
	index, found := schema_column_index(&current.schema, column_name)
	if !found do return errf(.Column_Not_Found, "column %s does not exist in %s", column_name, name)
	// SQLite's rules, in its words: a key column stays, and so does one a
	// table CHECK or an index reads.
	for key in current.schema.primary_key {
		if key == index do return errf(.Sql_Unsupported, "cannot drop PRIMARY KEY column: \"%s\"", column_name)
	}
	if current.schema.columns[index].unique || current.schema.columns[index].auto_increment {
		return errf(.Sql_Unsupported, "cannot drop UNIQUE column: \"%s\"", column_name)
	}
	if checks_use_column(&current.schema, column_name, skip_own = true) {
		return errf(.Sql_Unsupported, "error in table %s after drop column: no such column: %s", name, column_name)
	}
	// The other indexes keep working: their positions after the column shift.
	shifted_indexes := make([]Index_Schema, len(current.schema.indexes), tx.alloc)
	for index_def, n in current.schema.indexes {
		positions := make([]int, len(index_def.columns), tx.alloc)
		for position, k in index_def.columns {
			if position == index {
				if index_def.implicit {
					return errf(.Sql_Unsupported, "cannot drop UNIQUE column: \"%s\"", column_name)
				}
				return errf(.Sql_Unsupported, "error in index %s after drop column: no such column: %s", index_def.name, column_name)
			}
			positions[k] = position > index ? position - 1 : position
		}
		shifted_indexes[n] = index_def
		shifted_indexes[n].columns = positions
	}
	// A table whose columns another table's key names by position keeps them.
	for other_name in tx_table_names(tx, context.temp_allocator) {
		other := tx_table_probe(tx, other_name)
		if other == nil || other_name == name do continue
		for key_def in other.schema.foreign_keys {
			if !strings.equal_fold(key_def.ref_table, name) do continue
			for position in key_def.ref_columns {
				if position >= index {
					return errf(.Sql_Unsupported, "cannot drop column %s: the foreign key of %s names the columns of %s after it", column_name, other_name, name)
				}
			}
		}
	}
	// Foreign keys name column positions too.
	for key_def in current.schema.foreign_keys {
		for position in key_def.columns {
			if position == index {
				return errf(.Sql_Unsupported, "cannot drop the referenced column %s", column_name)
			}
		}
	}
	columns := make([dynamic]Column, 0, len(current.schema.columns) - 1, tx.alloc)
	for column, i in current.schema.columns {
		if i == index do continue
		append(&columns, column)
	}
	next_schema := current.schema
	next_schema.columns = columns[:]
	next_schema.indexes = shifted_indexes
	// The table's own keys name positions too.
	shifted_keys := make([]Foreign_Key, len(current.schema.foreign_keys), tx.alloc)
	for key_def, n in current.schema.foreign_keys {
		positions := make([]int, len(key_def.columns), tx.alloc)
		for position, k in key_def.columns do positions[k] = position > index ? position - 1 : position
		shifted_keys[n] = key_def
		shifted_keys[n].columns = positions
	}
	next_schema.foreign_keys = shifted_keys
	// The primary key and auto-increment positions shift after the removed slot.
	keys := make([dynamic]int, 0, len(current.schema.primary_key), tx.alloc)
	for key in current.schema.primary_key {
		if key == index do continue
		append(&keys, key > index ? key - 1 : key)
	}
	next_schema.primary_key = keys[:]
	if current.schema.auto_increment_column > index {
		next_schema.auto_increment_column = current.schema.auto_increment_column - 1
	}
	// The column's own CHECK constraints go with it.
	kept_checks := make([dynamic]Check_Constraint, 0, len(current.schema.checks), tx.alloc)
	for check in current.schema.checks {
		if strings.equal_fold(check.column, column_name) do continue
		append(&kept_checks, check)
	}
	next_schema.checks = kept_checks[:]
	schema := next_schema
	replacement, create_err := table_create(&schema)
	if create_err.kind != .None do return create_err
	append(&tx.replaced, replacement)
	row_rows := rows_iter(&current.rows)
	for row in rows_next(&row_rows) {
		id := row.id
		values := make([]Value, len(row.values) - 1, tx.alloc)
		copy(values, row.values[:index])
		copy(values[index:], row.values[index + 1:])
		if insert_err := table_insert(replacement, id, values); insert_err.kind != .None {
			return insert_err
		}
	}
	replacement.next_row_id = current.next_row_id
	replacement.next_sequence = current.next_sequence
	// Staged rows lose the column as well, so later statements see the new shape.
	if writes, ok := tx.state.writes[name]; ok {
		writes_int_key_forget(writes)
		for row in srows_ptrs(&writes.inserts) {
			next := make([]Value, len(row.values) - 1, tx.alloc)
			copy(next, row.values[:index])
			copy(next[index:], row.values[index + 1:])
			row^ = Row {
				id           = row.id,
				values       = next,
				created_seq  = row.created_seq,
				deleted_seq  = row.deleted_seq,
				versions     = row.versions,
			}
		}
		for id, values in writes.updates {
			next := make([]Value, len(values) - 1, tx.alloc)
			copy(next, values[:index])
			copy(next[index:], values[index + 1:])
			writes.updates[id] = next
		}
		// The unique keys were built over the old shape; rebuild them.
		clear(&writes.unique_keys)
		staged_ints_clear(&writes.unique_ints)
	}
	tx.state.altered[strings.clone(name, tx.alloc)] = replacement
	return ERROR_NONE
}

// tx_rename_table moves a table to a new name. The rows keep their ids; the
// staged writes follow the table, so a commit applies the rename before them.
tx_rename_table :: proc(tx: ^Tx, from, to: string) -> Error {
	if refusal := client_authority_check(tx.store, from); refusal.kind != .None do return refusal
	if refusal := client_authority_check(tx.store, to); refusal.kind != .None do return refusal
	tx_forget_catalog_cache(tx)
	if tx_write_refused(tx, from) do return errf(.Transaction_Read_Only, "cannot alter a table in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, from); kept_err.kind != .None do return kept_err
	}
	if guard_err := tx_paged_alter_guard(tx, from); guard_err.kind != .None do return guard_err
	if _, created := tx.state.created[from]; created {
		return errf(.Sql_Unsupported, "alter a table outside the transaction that created it")
	}
	current, current_err := tx_table(tx, from)
	if current_err.kind != .None do return current_err
	_, clash := tx_table(tx, to)
	if clash.kind == .None do return errf(.Table_Exists, "table %s already exists", to)
	error_free(&clash)
	next_schema := current.schema
	next_schema.name = strings.clone(to, tx.alloc)
	schema := next_schema
	replacement, create_err := table_create(&schema)
	if create_err.kind != .None do return create_err
	append(&tx.replaced, replacement)
	row_rows := rows_iter(&current.rows)
	for row in rows_next(&row_rows) {
		id := row.id
		if insert_err := table_insert(replacement, id, row.values); insert_err.kind != .None {
			return insert_err
		}
	}
	replacement.next_row_id = current.next_row_id
	replacement.next_sequence = current.next_sequence
	if writes, ok := tx.state.writes[from]; ok {
		tx.state.writes[strings.clone(to, tx.alloc)] = writes
		map_erase(&tx.state.writes, from)
	}
	tx.state.altered[strings.clone(from, tx.alloc)] = replacement
	return ERROR_NONE
}

// tx_rename_column renames one column. Indexes refer to columns by position, so
// they keep working; text that names the column (a generated expression, a
// trigger body, a policy) is not rewritten, which is noted in the docs.
tx_rename_column :: proc(tx: ^Tx, table_name, from, to: string) -> Error {
	if tx_write_refused(tx, table_name) do return errf(.Transaction_Read_Only, "cannot alter a table in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, table_name); kept_err.kind != .None do return kept_err
	}
	if guard_err := tx_paged_alter_guard(tx, table_name); guard_err.kind != .None do return guard_err
	if _, created := tx.state.created[table_name]; created {
		return errf(.Sql_Unsupported, "alter a table outside the transaction that created it")
	}
	if _, is_virtual := fts_virtual_lookup(tx, table_name); is_virtual {
		return errf(.Sql_Unsupported, "a virtual table keeps its column names")
	}
	current, current_err := tx_table(tx, table_name)
	if current_err.kind != .None do return current_err
	if strings.equal_fold(from, to) do return ERROR_NONE
	for existing in current.schema.columns {
		if strings.equal_fold(existing.name, to) {
			return errf(.Invalid_Argument, "column %s already exists in %s", to, table_name)
		}
	}
	found := false
	columns := make([]Column, len(current.schema.columns), tx.alloc)
	for column, i in current.schema.columns {
		columns[i] = column
		if strings.equal_fold(column.name, from) {
			columns[i].name = strings.clone(to, tx.alloc)
			found = true
		}
	}
	if !found do return errf(.Column_Not_Found, "column %s does not exist in %s", from, table_name)
	// The CHECK constraints and generated columns that name it are rewritten,
	// as SQLite rewrites them (alter_follow.odin).
	for &column in columns {
		if len(column.generated_sql) > 0 {
			column.generated_sql = sql_rename_column_refs(tx, column.generated_sql, table_name, from, to, true, tx.alloc)
		}
		if len(column.default_sql) > 0 {
			column.default_sql = sql_rename_column_refs(tx, column.default_sql, table_name, from, to, true, tx.alloc)
		}
	}
	checks := make([]Check_Constraint, len(current.schema.checks), tx.alloc)
	for check, i in current.schema.checks {
		checks[i] = check
		checks[i].sql = sql_rename_column_refs(tx, check.sql, table_name, from, to, true, tx.alloc)
		if strings.equal_fold(check.column, from) do checks[i].column = strings.clone(to, tx.alloc)
	}
	next_schema := current.schema
	next_schema.columns = columns
	next_schema.checks = checks
	if validate_err := schema_validate(&next_schema); validate_err.kind != .None {
		return validate_err
	}
	return tx_alter_table(tx, table_name, next_schema)
}

@(private)
tx_writes :: proc(tx: ^Tx, name: string, table: ^Table) -> ^Table_Writes {
	if writes, ok := tx.state.writes[name]; ok {
		return writes
	}
	writes := new(Table_Writes)
	// Sized for a statement that writes a batch (Staged_Rows).
	srows_init(&writes.inserts, 64)
	writes.updates = make(map[Row_Id][]Value)
	writes.deletes = make(map[Row_Id]bool)
	writes.unique_keys = make(map[string]Row_Id, 64)
	staged_ints_init(&writes.unique_ints)
	writes.next_row_id = table.next_row_id
	writes.next_sequence = table.next_sequence
	// The map key must outlive the caller's statement buffer, so it lives in the
	// transaction arena.
	tx.state.writes[strings.clone(name, tx.alloc)] = writes
	return writes
}

tx_get :: proc(tx: ^Tx, name: string, id: Row_Id) -> (Row, bool) {
	writes := tx.state.writes[name] or_else nil
	if writes != nil {
		if row, found, staged := tx_get_staged(writes, id); staged do return row, found
	}
	return tx_get_in(tx, tx_table_probe(tx, name), nil, id)
}

// tx_get_staged answers from what the transaction staged for the row, when it
// staged anything (`staged`).
@(private)
tx_get_staged :: proc(writes: ^Table_Writes, id: Row_Id) -> (row: Row, found: bool, staged: bool) {
	if row := srows_ptr(&writes.inserts, id); row != nil do return row^, true, true
	if values, updated := writes.updates[id]; updated do return Row{id = id, values = values}, true, true
	if writes.deletes[id] do return {}, false, true
	if writes.truncated do return {}, false, true
	return {}, false, false
}

// tx_get_in is tx_get for a table and its staged writes already resolved.
@(private)
tx_get_in :: proc(tx: ^Tx, table: ^Table, writes: ^Table_Writes, id: Row_Id) -> (Row, bool) {
	if writes != nil {
		if row, found, staged := tx_get_staged(writes, id); staged do return row, found
	}
	if table == nil do return {}, false
	row, found := table_get_row(table, id, tx.alloc)
	if !found || table.paged != nil do return row, found
	// A memory table keeps tombstones and older versions until a prune: the row
	// is the one this transaction's sequence sees. Returned as stored, a deleted
	// row answered `WHERE rowid = k` until the next prune (which the C ABI never
	// runs), and a pinned read saw the current values instead of its own.
	values, visible := row_values_at(row, tx.read_seq)
	if !visible do return {}, false
	return Row{id = row.id, values = values, created_seq = row.created_seq}, true
}

// tx_collect fills `out` with the visible rows of one table, ordered by row id.
tx_collect :: proc(tx: ^Tx, name: string, out: ^[dynamic]Row) -> Error {
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return table_err
	writes := tx.state.writes[name]
	if !tx.state.dropped[name] && (writes == nil || !writes.truncated) {
		// A paged table decodes its rows into the transaction arena: they stay
		// valid until the statement (and the transaction) ends.
		table_collect(table, out, tx.read_seq, tx.alloc)
	}
	if writes == nil do return ERROR_NONE
	seen := make(map[Row_Id]bool, srows_len(&writes.inserts) + len(out))
	defer delete(seen)
	// Replace updated rows and drop deleted ones.
	for i in 0 ..< len(out) {
		id := out[i].id
		if writes.deletes[id] {
			out[i].id = Row_Id(0xffff_ffff_ffff_ffff)
			continue
		}
		if values, updated := writes.updates[id]; updated {
			out[i].values = values
		}
		seen[id] = true
	}
	for row in srows_ptrs(&writes.inserts) {
		if seen[row.id] do continue
		append(out, row^)
	}
	// Remove the tombstoned slots the delete pass marked.
	write := 0
	for i in 0 ..< len(out) {
		if out[i].id == Row_Id(0xffff_ffff_ffff_ffff) do continue
		out[write] = out[i]
		write += 1
	}
	if write < len(out) do resize(out, write)
	rows_sort_by_id(out[:])
	return ERROR_NONE
}

// tx_collect_at reads the rows as they were at one commit sequence. It reads the
// live table, not the transaction's frozen snapshot: the snapshot is built for
// the present and drops the versions a past read needs. The read lock the
// transaction holds keeps the table stable for the statement.
tx_collect_at :: proc(tx: ^Tx, name: string, out: ^[dynamic]Row, seq: u64) -> Error {
	if table, exists := tx.store.tables[name]; exists {
		if table.paged != nil {
			return errf(.Sql_Unsupported, "AS OF is not available on a table that uses the page store")
		}
		table_collect(table, out, seq)
		return ERROR_NONE
	}
	if _, dropped := tx.state.dropped[name]; dropped {
		return errf(.Table_Not_Found, "table %s was dropped in this transaction", name)
	}
	return errf(.Table_Not_Found, "table %s does not exist", name)
}

// Tx_Scan_Visitor sees one row at a time. The values are only valid during the
// call: a paged table decodes into an arena that is reset after each row.
Tx_Scan_Visitor :: proc(ctx: rawptr, row: Row) -> bool

@(private)
Tx_Scan_Ctx :: struct {
	ctx:   rawptr,
	visit: Tx_Scan_Visitor,
}

@(private)
tx_scan_trampoline :: proc(ctx: rawptr, row: Row) -> bool {
	scan := cast(^Tx_Scan_Ctx)ctx
	return scan.visit(scan.ctx, row)
}

// tx_scan_visit walks the visible rows of one table without collecting them.
// A paged table streams page by page (the pool bounds the memory); a memory
// table walks its map. When the transaction staged changes for the table the
// collect path runs instead, because the overlay has to be merged and that
// materializes.
tx_scan_visit :: proc(tx: ^Tx, name: string, ctx: rawptr, visit: Tx_Scan_Visitor) -> Error {
	// A table the transaction dropped and created again is here, not gone: its
	// rows are the ones it staged.
	if tx.state.dropped[name] && tx.state.created[name] == nil do return ERROR_NONE
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return table_err
	overlay := false
	if writes, has := tx.state.writes[name]; has {
		overlay = writes.truncated ||
			srows_len(&writes.inserts) > 0 ||
			len(writes.updates) > 0 ||
			len(writes.deletes) > 0
	}
	if overlay || table.paged == nil {
		rows := make([dynamic]Row)
		if collect_err := tx_collect(tx, name, &rows); collect_err.kind != .None {
			delete(rows)
			return collect_err
		}
		for row in rows {
			if !visit(ctx, row) do break
		}
		delete(rows)
		return ERROR_NONE
	}
	scan := Tx_Scan_Ctx{ctx = ctx, visit = visit}
	return page_rows_each(table.paged, &scan, tx_scan_trampoline)
}

tx_row_count :: proc(tx: ^Tx, name: string) -> (int, Error) {
	rows := make([dynamic]Row)
	defer delete(rows)
	if err := tx_collect(tx, name, &rows); err.kind != .None {
		return 0, err
	}
	return len(rows), ERROR_NONE
}

// tx_table_is_temp reports a TEMP table, made in this transaction or before.
@(private)
tx_table_is_temp :: proc(tx: ^Tx, name: string) -> bool {
	if table, ok := tx.state.created[name]; ok do return table.schema.ephemeral
	if table, ok := tx.store.tables[name]; ok do return table.schema.ephemeral
	return false
}

// tx_write_refused is whether a write to `name` is refused here: always in a read
// transaction, and on a read-only store unless the table is a TEMP one.
@(private)
tx_write_refused :: proc(tx: ^Tx, name: string) -> bool {
	if tx.read_only do return true
	return tx.temp_only && !tx_table_is_temp(tx, name)
}

// tx_kept_index_refusal answers why a write to `name` cannot run while the
// table has an index the engine could not build from the file it imported
// (store_mirror_keep): its entries would stop matching the rows, and SQLite
// refuses the same write for want of the function or collation the index
// needs. The index is tried again first, in this transaction: a program that
// registered what it needs since the open gets it built, and the write runs.
@(private)
tx_kept_index_refusal :: proc(tx: ^Tx, name: string) -> Error {
	for kept in tx.store.mirror_kept {
		if kept.kind != "index" || !strings.equal_fold(kept.table, name) do continue
		// Built in this transaction, or by an earlier one on a store whose
		// catalog no rewrite has read again since.
		built := false
		for op in tx.state.index_ops {
			if !op.drop && strings.equal_fold(op.table, name) && strings.equal_fold(op.index.name, kept.name) do built = true
		}
		if table := tx_table_probe(tx, name); table != nil {
			for index in table.schema.indexes do built ||= strings.equal_fold(index.name, kept.name)
		}
		if built do continue
		created, create_err := sql_execute_in_tx(tx, kept.sql)
		sql_result_destroy(&created)
		if create_err.kind == .None do continue
		return create_err
	}
	return ERROR_NONE
}

// --- DDL -------------------------------------------------------------------

tx_create_table :: proc(tx: ^Tx, schema: ^Table_Schema) -> Error {
	if refusal := client_authority_check(tx.store, schema.name); refusal.kind != .None do return refusal
	tx_forget_catalog_cache(tx)
	if tx.read_only || (tx.temp_only && !schema.ephemeral) {
		return errf(.Transaction_Read_Only, "cannot create a table in a read transaction")
	}
	if _, exists := tx.state.created[schema.name]; exists {
		return errf(.Table_Exists, "table %s was already created in this transaction", schema.name)
	}
	if _, exists := tx.store.tables[schema.name]; exists && !tx.state.dropped[schema.name] {
		return errf(.Table_Exists, "table %s already exists", schema.name)
	}
	table, table_err := table_create(schema)
	if table_err.kind != .None do return table_err
	// The table arena owns its schema name; use that as the map key so the entry
	// stays valid for the whole transaction.
	tx.state.created[table.schema.name] = table
	// The drop of the old table stays recorded: the commit has to apply it
	// before the create, or the create meets the table it was meant to replace
	// (`DROP TABLE t; CREATE TABLE t (...)` is what every migration does). The
	// lookups ask `created` before `dropped`, so the new table is the one a
	// statement sees.
	return ERROR_NONE
}

tx_drop_table :: proc(tx: ^Tx, name: string) -> Error {
	if refusal := client_authority_check(tx.store, name); refusal.kind != .None do return refusal
	tx_forget_catalog_cache(tx)
	if tx_write_refused(tx, name) do return errf(.Transaction_Read_Only, "cannot drop a table in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, name); kept_err.kind != .None do return kept_err
	}
	if created, ok := tx.state.created[name]; ok {
		// Erase before destroying: the map's key is the name in the table's own
		// arena, so a destroy first leaves the map comparing against freed
		// memory (a crash with no message, which a release build reports as heap
		// corruption).
		map_erase(&tx.state.created, name)
		table_destroy(created)
		// Rows staged for a table created in this transaction disappear with it.
		tx_discard_writes(tx, name)
		tx_discard_schema_changes(tx, name)
		return ERROR_NONE
	}
	if _, exists := tx.store.tables[name]; !exists {
		return errf(.Table_Not_Found, "table %s does not exist", name)
	}
	// What the transaction wrote to the table goes with it: the commit applies
	// the drop first, and a staged row left behind made it fail ("table does
	// not exist"), losing the whole transaction.
	tx_discard_writes(tx, name)
	tx_discard_schema_changes(tx, name)
	tx.state.dropped[strings.clone(name, tx.alloc)] = true
	return ERROR_NONE
}

// tx_discard_schema_changes forgets the indexes and the ALTER the transaction
// staged for a table it drops: the commit applies the drop first, and an index
// or an ALTER left for the dropped table failed the whole commit ("table does
// not exist").
@(private)
tx_discard_schema_changes :: proc(tx: ^Tx, name: string) {
	for i := len(tx.state.index_ops) - 1; i >= 0; i -= 1 {
		if strings.equal_fold(tx.state.index_ops[i].table, name) do mirror_list_remove(&tx.state.index_ops, i)
	}
	// The altered table itself is in `replaced`, released with the transaction.
	if _, altered := tx.state.altered[name]; altered do delete_key(&tx.state.altered, name)
}

// tx_discard_writes forgets the rows the transaction staged for one table.
@(private)
tx_discard_writes :: proc(tx: ^Tx, name: string) {
	writes, has_writes := tx.state.writes[name]
	if !has_writes do return
	srows_destroy(&writes.inserts)
	delete(writes.updates)
	delete(writes.deletes)
	delete(writes.unique_keys)
	staged_ints_destroy(&writes.unique_ints)
	free(writes)
	map_erase(&tx.state.writes, name)
}

// --- DML -------------------------------------------------------------------

// tx_insert coerces `values` to the table schema, assigns the row id, validates
// uniqueness and stages the row. Columns not supplied are filled with their
// default; pass a value vector of exactly one entry per column.
tx_insert :: proc(tx: ^Tx, name: string, values: []Value) -> (Row_Id, Error) {
	id, err := tx_insert_row(tx, name, values)
	if err.kind == .None && tx.store.hooks.row_change != nil {
		hook_row_change(tx, .Insert, name, hook_rowid(tx, name, id))
	}
	return id, err
}

// tx_next_int_key is the INTEGER PRIMARY KEY an omitted value gets: one past
// the largest over the stored rows and the staged ones, as SQLite gives it,
// negative too (after -5 comes -4), and 1 in a table with none.
tx_next_int_key :: proc(table: ^Table, writes: ^Table_Writes, position: int) -> i64 {
	largest: i64
	found: bool
	if table.paged != nil {
		largest, found = table.next_int_key, table.next_int_key >= 1
	} else {
		staged := proc(id: Row_Id, user: rawptr) -> bool {
			writes := (^Table_Writes)(user)
			_, deleted := writes.deletes[id]
			_, updated := writes.updates[id]
			return deleted || updated
		}
		indexed: bool
		largest, found, indexed = table_largest_int_indexed(table, position, writes != nil ? staged : nil, writes)
		if !indexed do largest, found = table_largest_int(table, position, writes != nil ? staged : nil, writes)
	}
	if writes != nil {
		weigh := proc(values: []Value, position: int, largest: ^i64, found: ^bool) {
			if position >= len(values) || values[position].kind != .Int do return
			if !found^ || values[position].i > largest^ do largest^ = values[position].i
			found^ = true
		}
		// The staged inserts' largest is kept as they are appended; it is walked
		// for again only after another change to them.
		if writes.int_key_column != position + 1 {
			writes.int_key_column = position + 1
			writes.int_key_top, writes.int_key_found = 0, false
			for row in srows_ptrs(&writes.inserts) do weigh(row.values, position, &writes.int_key_top, &writes.int_key_found)
		}
		if writes.int_key_found && (!found || writes.int_key_top > largest) {
			largest, found = writes.int_key_top, true
		}
		for _, values in writes.updates do weigh(values, position, &largest, &found)
	}
	return found ? largest + 1 : 1
}

@(private)
tx_insert_row :: proc(tx: ^Tx, name: string, values: []Value) -> (Row_Id, Error) {
	if tx_write_refused(tx, name) do return 0, errf(.Transaction_Read_Only, "cannot insert in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, name); kept_err.kind != .None do return 0, kept_err
	}
	table: ^Table
	cached := tx.insert_table != nil && len(tx.cte_tables) == 0 && tx.insert_name == name
	if cached {
		table = tx.insert_table
	} else {
		table_err: Error
		table, table_err = tx_table(tx, name)
		if table_err.kind != .None do return 0, table_err
	}
	if permission_err := tx_check_permission(tx, name, "insert"); permission_err.kind != .None {
		return 0, permission_err
	}
	if len(values) != len(table.schema.columns) {
		return 0, errf(
			.Invalid_Argument,
			"table %s has %d columns but %d values were given",
			name,
			len(table.schema.columns),
			len(values),
		)
	}
	writes := cached ? tx.insert_writes : tx_writes(tx, name, table)
	committed := cached ? tx.insert_committed : tx_unique_committed(tx, name)
	if !cached && len(tx.cte_tables) == 0 {
		// The name may live in the caller's statement buffer; the arena copy
		// outlives it.
		tx.insert_name = strings.clone(name, tx.alloc)
		tx.insert_table = table
		tx.insert_writes = writes
		tx.insert_committed = committed
	}
	id := Row_Id(writes.next_row_id)
	if tx.has_explicit_row_id {
		// The row the statement names its rowid for; a trigger's rows get their own.
		tx.has_explicit_row_id = false
		if _, taken := tx_get(tx, name, tx.explicit_row_id); taken {
			return 0, errf(.Duplicate_Unique, "UNIQUE constraint failed: %s.rowid", name)
		}
		id = tx.explicit_row_id
	}

	row_values := make([]Value, len(values), tx.alloc)
	// SQLite's INTEGER PRIMARY KEY is the rowid: an omitted value is assigned.
	pk_position := -1
	// A WITHOUT ROWID table has no rowid for its key to stand for.
	if len(table.schema.primary_key) == 1 && !table.schema.without_rowid {
		position := table.schema.primary_key[0]
		if table.schema.columns[position].type.kind == .Int do pk_position = position
	}
	for &column, i in table.schema.columns {
		v := values[i]
		if i == pk_position && !column.auto_increment && (v.kind == .Default || v.kind == .Null) {
			v = value_int(tx_next_int_key(table, writes, i))
		}
		if v.kind == .Default {
			if column.auto_increment {
				v = value_int(writes.next_sequence)
			} else {
				default_value, default_err := column_default_for_row(tx, column)
				if default_err.kind != .None do return 0, default_err
				v = default_value
			}
		} else if v.kind == .Null && column.auto_increment {
			v = value_int(writes.next_sequence)
		}
		coerced, coerce_err := value_coerce_into(v, &table.schema, i)
		if coerce_err.kind != .None do return 0, coerce_err
		// SQLite's INTEGER PRIMARY KEY is the rowid: what its affinity cannot
		// make an integer is refused, where another INTEGER column keeps it (a
		// real key used to reach the file as a rowid nobody wrote).
		if i == pk_position && coerced.kind != .Int && coerced.kind != .Uint && coerced.kind != .Null {
			return 0, errf(.Invalid_Type, "datatype mismatch")
		}
		if coerced.kind == .Null && column.not_null {
			return 0, errf(.Not_Null_Violation, "NOT NULL constraint failed: %s.%s", name, column.name)
		}
		if column.auto_increment {
			number, number_ok := value_to_i64(coerced)
			if !number_ok {
				return 0, errf(.Invalid_Type, "column %s.%s needs an integer sequence value", name, column.name)
			}
			if number < column.sequence.min || number > column.sequence.max {
				return 0, errf(.Invalid_Argument, "column %s.%s is outside its sequence range", name, column.name)
			}
			next := number + column.sequence.increment
			if next > writes.next_sequence {
				undo_note_counters(tx, writes)
				writes.next_sequence = next
			}
		}
		row_values[i] = value_clone(coerced, tx.alloc)
	}

	// CHECK runs on the final row, before anything is staged, so a refused row
	// leaves nothing behind (INSERT OR IGNORE relies on that).
	if check_err := checks_enforce(tx, table, row_values); check_err.kind != .None {
		return 0, check_err
	}
	if index_err := index_validate_row(tx, table, row_values); index_err.kind != .None {
		return 0, index_err
	}
	if fk_err := fk_check_child(tx, table, row_values); fk_err.kind != .None {
		return 0, fk_err
	}
	keys := make([dynamic]Staged_Key, 0, 2, tx.alloc)
	unique := Unique_Context{writes = writes, committed = committed}
	if err := tx_check_unique(tx, name, table, row_values, INVALID_ROW_ID, &keys, &unique); err.kind != .None {
		return 0, err
	}
	// With no trigger table, nothing runs between the check and the registration,
	// so the keys the check encoded are the keys to register.
	has_triggers := tx_system_table_exists(tx, TRIGGER_TABLE, &tx.trigger_probe)

	// A BEFORE trigger sees the row that is about to be written, while nothing has
	// been staged: if its body fails, there is nothing to roll back and the insert
	// stops here.
	if trigger_err := trigger_fire(
		tx,
		name,
		.Insert,
		.Before,
		Row{},
		Row{id = id, values = row_values},
		table.schema,
	); trigger_err.kind != .None {
		return 0, trigger_err
	}
	undo_note_insert(tx, writes, id)
	undo_note_counters(tx, writes)
	if srows_has(&writes.inserts, id) do writes_int_key_forget(writes)
	srows_set(&writes.inserts, Row{id = id, values = row_values})
	writes_int_key_weigh(writes, row_values)
	// A named rowid below the next one leaves the next one where it was.
	writes.next_row_id = max(writes.next_row_id, u64(id) + 1)
	if has_triggers {
		tx_register_unique(tx, name, table, row_values, id)
	} else {
		tx_register_keys(tx, writes, keys[:], id)
	}
	if trigger_err := trigger_fire(
		tx,
		name,
		.Insert,
		.After,
		Row{},
		Row{id = id, values = row_values},
		table.schema,
	); trigger_err.kind != .None {
		return 0, trigger_err
	}
	return id, ERROR_NONE
}

INVALID_ROW_ID :: Row_Id(max(u64))

// tx_update replaces the whole row. `values` must have one entry per column.
tx_update :: proc(tx: ^Tx, name: string, id: Row_Id, values: []Value) -> Error {
	err := tx_update_row(tx, name, id, values)
	if err.kind == .None && tx.store.hooks.row_change != nil {
		hook_row_change(tx, .Update, name, hook_rowid(tx, name, id))
	}
	return err
}

@(private)
tx_update_row :: proc(tx: ^Tx, name: string, id: Row_Id, values: []Value) -> Error {
	if tx_write_refused(tx, name) do return errf(.Transaction_Read_Only, "cannot update in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, name); kept_err.kind != .None do return kept_err
	}
	table: ^Table
	cached := tx.insert_table != nil && len(tx.cte_tables) == 0 && tx.insert_name == name
	if cached {
		table = tx.insert_table
	} else {
		table_err: Error
		table, table_err = tx_table(tx, name)
		if table_err.kind != .None do return table_err
	}
	if table.schema.event do return errf(.Sql_Unsupported, "event table %s is append-only", name)
	if permission_err := tx_check_permission(tx, name, "update"); permission_err.kind != .None {
		return permission_err
	}
	if len(values) != len(table.schema.columns) {
		return errf(
			.Invalid_Argument,
			"table %s has %d columns but %d values were given",
			name,
			len(table.schema.columns),
			len(values),
		)
	}
	writes := cached ? tx.insert_writes : tx_writes(tx, name, table)
	committed := cached ? tx.insert_committed : tx_unique_committed(tx, name)
	if !cached && len(tx.cte_tables) == 0 {
		tx.insert_name = strings.clone(name, tx.alloc)
		tx.insert_table = table
		tx.insert_writes = writes
		tx.insert_committed = committed
	}
	previous, exists := tx_get_in(tx, table, writes, id)
	if !exists {
		return errf(.Invalid_Argument, "row %d does not exist in table %s", u64(id), name)
	}
	row_values := make([]Value, len(values), tx.alloc)
	// SQLite's INTEGER PRIMARY KEY is the rowid: an omitted value is assigned.
	pk_position := -1
	// A WITHOUT ROWID table has no rowid for its key to stand for.
	if len(table.schema.primary_key) == 1 && !table.schema.without_rowid {
		position := table.schema.primary_key[0]
		if table.schema.columns[position].type.kind == .Int do pk_position = position
	}
	for &column, i in table.schema.columns {
		v := values[i]
		if i == pk_position && !column.auto_increment && (v.kind == .Default || v.kind == .Null) {
			v = value_int(tx_next_int_key(table, writes, i))
		}
		if v.kind == .Default {
			default_value, default_err := column_default_for_row(tx, column)
			if default_err.kind != .None do return default_err
			v = default_value
		} else if v.kind == .Null && column.auto_increment {
			v = value_uint(u64(id))
		}
		coerced, coerce_err := value_coerce_into(v, &table.schema, i)
		if coerce_err.kind != .None do return coerce_err
		if i == pk_position && coerced.kind != .Int && coerced.kind != .Uint && coerced.kind != .Null {
			return errf(.Invalid_Type, "datatype mismatch")
		}
		if coerced.kind == .Null && column.not_null {
			return errf(.Not_Null_Violation, "NOT NULL constraint failed: %s.%s", name, column.name)
		}
		row_values[i] = value_clone(coerced, tx.alloc)
	}
	if check_err := checks_enforce(tx, table, row_values); check_err.kind != .None {
		return check_err
	}
	if index_err := index_validate_row(tx, table, row_values); index_err.kind != .None {
		return index_err
	}
	if fk_err := fk_check_child(tx, table, row_values); fk_err.kind != .None {
		return fk_err
	}
	// An update that keeps every unique key of the row checks none and moves
	// none: the keys are still the row's own, a committed one in the committed
	// index (tx_rewrite_keeps_key) and a staged one in `unique_keys`.
	keys_kept := tx_unique_keys_kept(tx, table, previous.values, row_values)
	if !keys_kept {
		tx_unregister_unique(tx, name, table, previous.values, id)
		unique := Unique_Context{writes = writes, committed = committed}
		if err := tx_check_unique(tx, name, table, row_values, id, nil, &unique); err.kind != .None {
			tx_register_unique(tx, name, table, previous.values, id)
			return err
		}
	}
	if trigger_err := trigger_fire(
		tx,
		name,
		.Update,
		.Before,
		previous,
		Row{id = id, values = row_values},
		table.schema,
	); trigger_err.kind != .None {
		return trigger_err
	}
	if srows_has(&writes.inserts, id) {
		undo_note_insert(tx, writes, id)
		writes_int_key_forget(writes)
		srows_set(&writes.inserts, Row{id = id, values = row_values})
	} else {
		undo_note_update(tx, writes, id)
		writes.updates[id] = row_values
	}
	if !keys_kept do tx_register_unique(tx, name, table, row_values, id)
	// ON UPDATE cascades run after the new key is staged, so the children see it.
	if fk_err := fk_parent_update(tx, name, previous.values, row_values); fk_err.kind != .None {
		return fk_err
	}
	if trigger_err := trigger_fire(
		tx,
		name,
		.Update,
		.After,
		previous,
		Row{id = id, values = row_values},
		table.schema,
	); trigger_err.kind != .None {
		return trigger_err
	}
	return ERROR_NONE
}

tx_delete :: proc(tx: ^Tx, name: string, id: Row_Id) -> Error {
	if tx.store.hooks.row_change == nil do return tx_delete_impl(tx, name, id, true)
	// The row's id is read before the row is gone.
	rowid := hook_rowid(tx, name, id)
	err := tx_delete_impl(tx, name, id, true)
	if err.kind == .None do hook_row_change(tx, .Delete, name, rowid)
	return err
}

// tx_delete_without_triggers stages a delete and runs no trigger program. INSERT
// OR REPLACE uses it: SQLite fires delete triggers for the rows a REPLACE
// removes only when recursive triggers are enabled, and they are off by default.
tx_delete_without_triggers :: proc(tx: ^Tx, name: string, id: Row_Id) -> Error {
	return tx_delete_impl(tx, name, id, false)
}

@(private)
tx_delete_impl :: proc(tx: ^Tx, name: string, id: Row_Id, fire_triggers: bool) -> Error {
	if tx_write_refused(tx, name) do return errf(.Transaction_Read_Only, "cannot delete in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, name); kept_err.kind != .None do return kept_err
	}
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return table_err
	if table.schema.event do return errf(.Sql_Unsupported, "event table %s is append-only", name)
	if permission_err := tx_check_permission(tx, name, "delete"); permission_err.kind != .None {
		return permission_err
	}
	previous, exists := tx_get(tx, name, id)
	if !exists {
		return errf(.Invalid_Argument, "row %d does not exist in table %s", u64(id), name)
	}
	if fk_err := fk_parent_delete(tx, name, previous.values); fk_err.kind != .None {
		return fk_err
	}
	if fire_triggers {
		if trigger_err := trigger_fire(tx, name, .Delete, .Before, previous, Row{}, table.schema); trigger_err.kind != .None {
			return trigger_err
		}
	}
	writes := tx_writes(tx, name, table)
	tx_unregister_unique(tx, name, table, previous.values, id)
	if srows_has(&writes.inserts, id) {
		undo_note_insert(tx, writes, id)
		writes_int_key_forget(writes)
		srows_erase(&writes.inserts, id)
	} else {
		if _, updated := writes.updates[id]; updated {
			undo_note_update(tx, writes, id)
			map_erase(&writes.updates, id)
		}
		undo_note_delete(tx, writes, id)
		writes.deletes[id] = true
	}
	if fire_triggers {
		if trigger_err := trigger_fire(tx, name, .Delete, .After, previous, Row{}, table.schema); trigger_err.kind != .None {
			return trigger_err
		}
	}
	return ERROR_NONE
}

tx_truncate :: proc(tx: ^Tx, name: string) -> Error {
	if refusal := client_authority_check(tx.store, name); refusal.kind != .None do return refusal
	if tx_write_refused(tx, name) do return errf(.Transaction_Read_Only, "cannot truncate in a read transaction")
	if tx.store.mirror_kept_indexes > 0 {
		if kept_err := tx_kept_index_refusal(tx, name); kept_err.kind != .None do return kept_err
	}
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return table_err
	if table.schema.event do return errf(.Sql_Unsupported, "event table %s is append-only", name)
	if permission_err := tx_check_permission(tx, name, "delete"); permission_err.kind != .None {
		return permission_err
	}
	if tx.undo_depth > 0 {
		// TRUNCATE empties the staging maps wholesale; recording every entry to
		// put it back is not done, so it is refused where a statement could need
		// to take it back.
		return errf(.Sql_Unsupported, "TRUNCATE cannot run inside another statement")
	}
	writes := tx_writes(tx, name, table)
	writes_int_key_forget(writes)
	srows_clear(&writes.inserts)
	clear(&writes.updates)
	clear(&writes.deletes)
	clear(&writes.unique_keys)
	staged_ints_clear(&writes.unique_ints)
	writes.truncated = true
	return ERROR_NONE
}

// --- Index DDL -------------------------------------------------------------

// tx_create_index stages an index alongside the rows of the same transaction.
// The index is built when the transaction is applied, after the rows it covers:
// a table created here, rows inserted here and an index on them still land in one
// atomic commit.
tx_create_index :: proc(tx: ^Tx, table_name: string, index: Index_Schema) -> Error {
	if tx_write_refused(tx, table_name) do return errf(.Transaction_Read_Only, "cannot create an index in a read transaction")
	table, table_err := tx_table(tx, table_name)
	if table_err.kind != .None do return table_err
	// A full copy, so a partial index keeps its WHERE and an expression index
	// its expressions.
	stored := schema_index_copy(index, tx.alloc)
	stored.implicit = false
	for existing in table.schema.indexes {
		if strings.equal_fold(existing.name, stored.name) {
			return errf(.Index_Exists, "index %s already exists", stored.name)
		}
	}
	// An index created earlier in this same transaction is not in the schema yet.
	for op in tx.state.index_ops {
		if op.drop || !strings.equal_fold(op.table, table_name) do continue
		if strings.equal_fold(op.index.name, stored.name) {
			return errf(.Index_Exists, "index %s already exists", stored.name)
		}
	}
	for col, part in stored.columns {
		if col == NO_COLUMN && part < len(stored.exprs) && len(stored.exprs[part]) > 0 do continue
		if col < 0 || col >= len(table.schema.columns) {
			return errf(.Invalid_Argument, "index %s refers to a missing column", stored.name)
		}
	}
	append(
		&tx.state.index_ops,
		Tx_Index_Op{drop = false, table = strings.clone(table_name, tx.alloc), index = stored},
	)
	return ERROR_NONE
}

tx_drop_index :: proc(tx: ^Tx, table_name: string, name: string) -> Error {
	if tx_write_refused(tx, table_name) do return errf(.Transaction_Read_Only, "cannot drop an index in a read transaction")
	table, table_err := tx_table(tx, table_name)
	if table_err.kind != .None do return table_err
	// The index may already be gone because this transaction created it: the
	// drop is then a no-op in the same atomic commit, not an error.
	dropped_already := false
	for op in tx.state.index_ops {
		if !op.drop || !strings.equal_fold(op.table, table_name) do continue
		if strings.equal_fold(op.index.name, name) {
			dropped_already = true
		}
	}
	if dropped_already {
		return errf(.Index_Not_Found, "index %s does not exist in %s", name, table_name)
	}
	for existing in table.schema.indexes {
		if !strings.equal_fold(existing.name, name) do continue
		if existing.implicit {
			return errf(.Invalid_Argument, "index %s comes from a constraint and cannot be dropped", name)
		}
		append(
			&tx.state.index_ops,
			Tx_Index_Op {
				drop = true,
				table = strings.clone(table_name, tx.alloc),
				index = Index_Schema{name = strings.clone(name, tx.alloc)},
			},
		)
		return ERROR_NONE
	}
	for op in tx.state.index_ops {
		if op.drop || !strings.equal_fold(op.table, table_name) do continue
		if !strings.equal_fold(op.index.name, name) do continue
		append(
			&tx.state.index_ops,
			Tx_Index_Op {
				drop = true,
				table = strings.clone(table_name, tx.alloc),
				index = Index_Schema{name = strings.clone(name, tx.alloc)},
			},
		)
		return ERROR_NONE
	}
	return errf(.Index_Not_Found, "index %s does not exist in %s", name, table_name)
}

// --- Uniqueness ------------------------------------------------------------

@(private)
unique_key :: proc(tx: ^Tx, table: ^Table, index: int, values: []Value) -> string {
	// Encoded straight into the transaction arena: one bump allocation, where the
	// key used to go through a heap buffer, a heap copy and a concatenation.
	name := table_index_schema(table, index).name
	w := Byte_Writer{data = make([dynamic]u8, 0, len(name) + 40, tx.alloc)}
	append(&w.data, ..transmute([]u8)name)
	append(&w.data, 0)
	index_encode_parts(&w, table, index, values)
	return string(w.data[:])
}

// tx_check_unique proves no other row holds a unique key of `values`. When `keys`
// is given it receives the keys it computed, one per unique index in index
// order, so the caller can register them without encoding them again.
@(private)
tx_check_unique :: proc(
	tx: ^Tx,
	name: string,
	table: ^Table,
	values: []Value,
	ignore: Row_Id,
	keys: ^[dynamic]Staged_Key = nil,
	resolved: ^Unique_Context = nil,
) -> Error {
	writes: ^Table_Writes
	committed: ^Table
	if resolved != nil {
		writes = resolved.writes
		committed = resolved.committed
	} else {
		writes = tx.state.writes[name] or_else nil
		committed = tx_unique_committed(tx, name)
	}
	for idx, i in table.indexes {
		if !idx.unique do continue
		// An index this transaction dropped holds nothing to its rows: the rows
		// after `DROP INDEX` were refused by the index they had just dropped.
		if len(tx.state.index_ops) > 0 && tx_index_dropped(tx, name, idx.schema.name) do continue
		// A row outside a partial index is not constrained by it, and a key with a
		// NULL constrains nothing.
		if !index_row_included(table, i, values) do continue
		if index_key_has_null(table, i, values) do continue
		key := staged_key(tx, table, i, values)
		if keys != nil do append(keys, key)
		// A key over a column with a program's collation: two values the
		// comparison calls equal are the same key, which folded bytes cannot
		// tell, so the rows are compared with it.
		if index_host_collated(tx.store, table, i) {
			if tx_host_key_taken(tx, name, table, i, values, ignore) do return unique_violation(table, i)
			continue
		}
		if writes != nil {
			if holder, taken := staged_holder(writes, key); taken && holder != ignore {
				return unique_violation(table, i)
			}
		}
		// A table this transaction dropped (and perhaps made again) or emptied
		// with TRUNCATE has no committed rows left to collide with.
		if committed != nil && (writes == nil || !writes.truncated) {
			if tx_committed_key_taken(tx, committed, i, values, ignore, writes) {
				return unique_violation(table, i)
			}
		}
	}
	if len(tx.state.index_ops) > 0 do return tx_staged_unique_check(tx, name, table, values, ignore)
	return ERROR_NONE
}

// tx_index_dropped reports whether the transaction's last word on an index of
// `table` is a DROP.
@(private)
tx_index_dropped :: proc(tx: ^Tx, table: string, index: string) -> bool {
	dropped := false
	for op in tx.state.index_ops {
		if strings.equal_fold(op.table, table) && strings.equal_fold(op.index.name, index) do dropped = op.drop
	}
	return dropped
}

// tx_staged_unique_check holds a row to the UNIQUE indexes this transaction
// created on its table, which are not in the table until the commit: the rows
// after `CREATE UNIQUE INDEX` in the same transaction were never checked, two
// equal keys committed, and SQLite found the file's index not unique. It reads
// every row the transaction sees, which only a transaction that changes a
// table's indexes and then writes to it pays.
@(private)
tx_staged_unique_check :: proc(tx: ^Tx, name: string, table: ^Table, values: []Value, ignore: Row_Id) -> Error {
	for op, k in tx.state.index_ops {
		if op.drop || !op.index.unique || !strings.equal_fold(op.table, name) do continue
		dropped := false
		for later in tx.state.index_ops[k + 1:] {
			dropped ||= later.drop && strings.equal_fold(later.table, name) && strings.equal_fold(later.index.name, op.index.name)
		}
		if dropped do continue
		exprs, exprs_err := index_exprs_make(op.index)
		if exprs_err.kind != .None {
			error_free(&exprs_err)
			continue
		}
		defer index_exprs_destroy(exprs)
		mine, included, has_null := tx_staged_index_key(table, op.index, exprs, values)
		if !included || has_null do continue
		rows := make([dynamic]Row, context.temp_allocator)
		if collect_err := tx_collect(tx, name, &rows); collect_err.kind != .None {
			error_drop(collect_err)
			continue
		}
		for row in rows {
			if row.id == ignore do continue
			theirs, row_included, row_null := tx_staged_index_key(table, op.index, exprs, row.values)
			if !row_included || row_null || theirs != mine do continue
			for expr in op.index.exprs {
				if len(expr) > 0 do return errf(.Duplicate_Unique, "UNIQUE constraint failed: index '%s'", op.index.name)
			}
			columns := strings.builder_make(context.temp_allocator)
			for position, part in op.index.columns {
				if part > 0 do strings.write_string(&columns, ", ")
				strings.write_string(&columns, table.schema.name)
				strings.write_byte(&columns, '.')
				if position >= 0 && position < len(table.schema.columns) do strings.write_string(&columns, table.schema.columns[position].name)
			}
			return errf(.Duplicate_Unique, "UNIQUE constraint failed: %s", strings.to_string(columns))
		}
	}
	return ERROR_NONE
}

// tx_staged_index_key is a row's key under an index that is not in its table
// yet, folded as the table would fold it: `included` is false for a row a
// partial index leaves out, and `has_null` says a part is NULL.
@(private)
tx_staged_index_key :: proc(table: ^Table, index: Index_Schema, exprs: ^Index_Exprs, values: []Value) -> (key: string, included: bool, has_null: bool) {
	defer if exprs != nil do virtual.arena_free_all(&exprs.scratch)
	if exprs != nil && exprs.where_expr != nil {
		held := index_eval(table, exprs, exprs.where_expr, values)
		if held.kind == .Null || !value_is_truthy(held) do return "", false, false
	}
	w := Byte_Writer{data = make([dynamic]u8, 0, 32, context.temp_allocator)}
	for column, part in index.columns {
		value: Value
		if exprs != nil && part < len(exprs.parts) && exprs.parts[part] != nil {
			value = index_eval(table, exprs, exprs.parts[part], values)
			if collation, has := collate_name(exprs.parts[part]); has && len(collation) > 0 do value = collate_ordered_value(value, collation)
		} else if column >= 0 && column < len(values) {
			value = values[column]
			if len(table.schema.columns[column].collation) > 0 do value = collate_ordered_value(value, table.schema.columns[column].collation)
		}
		if value.kind == .Null do has_null = true
		value_encode_key(&w, value)
	}
	return string(w.data[:]), true, has_null
}

// index_host_collated reports an index over a column whose collation is a
// program's.
index_host_collated :: proc(store: ^Store, table: ^Table, index: int) -> bool {
	for column in table_index_schema(table, index).columns {
		if column >= 0 && column < len(table.schema.columns) && column_host_collated(store, table.schema.columns[column]) do return true
	}
	return false
}

// tx_host_key_taken reports whether a row the transaction sees, other than
// `ignore`, holds the same key under the columns' collations. It reads every
// row, which is what a comparison without folded bytes costs.
@(private)
tx_host_key_taken :: proc(tx: ^Tx, name: string, table: ^Table, index: int, values: []Value, ignore: Row_Id) -> bool {
	rows := make([dynamic]Row, context.temp_allocator)
	if collect_err := tx_collect(tx, name, &rows); collect_err.kind != .None {
		error_drop(collect_err)
		return false
	}
	for row in rows {
		if row.id == ignore do continue
		same := true
		for column in table_index_schema(table, index).columns {
			a, b := values[column], row.values[column]
			collation := table.schema.columns[column].collation
			if a.kind == .String && b.kind == .String && len(collation) > 0 {
				order, ok := collation_compare(tx.store, collation, a.s, b.s)
				if !ok || order != 0 {
					same = false
					break
				}
				continue
			}
			if !value_equal(a, b) {
				same = false
				break
			}
		}
		if same do return true
	}
	return false
}

// tx_host_key_holders lists the rows the transaction sees that hold the same
// key under the columns' collations (tx_host_key_taken, every holder).
tx_host_key_holders :: proc(tx: ^Tx, name: string, table: ^Table, index: int, values: []Value) -> []Row_Id {
	holders := make([dynamic]Row_Id, context.temp_allocator)
	rows := make([dynamic]Row, context.temp_allocator)
	if collect_err := tx_collect(tx, name, &rows); collect_err.kind != .None {
		error_drop(collect_err)
		return nil
	}
	for row in rows {
		same := true
		for column in table_index_schema(table, index).columns {
			a, b := values[column], row.values[column]
			collation := table.schema.columns[column].collation
			if a.kind == .String && b.kind == .String && len(collation) > 0 {
				order, ok := collation_compare(tx.store, collation, a.s, b.s)
				if !ok || order != 0 {
					same = false
					break
				}
				continue
			}
			if !value_equal(a, b) {
				same = false
				break
			}
		}
		if same do append(&holders, row.id)
	}
	return holders[:]
}

// tx_committed_key_taken reports whether a committed row other than `ignore`
// holds this key and still holds it in this transaction (not deleted, not
// rewritten). An ordered in-memory index is walked in place: the answer needs no
// list of ids and no heap key, which is what a lookup per insert used to cost.
@(private)
tx_committed_key_taken :: proc(
	tx: ^Tx,
	committed: ^Table,
	index: int,
	values: []Value,
	ignore: Row_Id,
	writes: ^Table_Writes,
) -> bool {
	holds :: proc(tx: ^Tx, committed: ^Table, index: int, values: []Value, id: Row_Id, ignore: Row_Id, writes: ^Table_Writes) -> bool {
		if id == ignore do return false
		if writes != nil {
			if writes.deletes[id] do return false
			if staged, changed := writes.updates[id]; changed do return tx_rewrite_keeps_key(tx, committed, index, staged, values)
		}
		return true
	}
	// An index that files integer keys answers with one hash probe.
	if holder, held, known := index_int_holder(committed, index, values); known {
		return held && holds(tx, committed, index, values, holder, ignore, writes)
	}
	if table_index_walks(committed, index) {
		walk := table_index_walk_prefix(committed, index, index_prefix_in(committed, index, values, tx.alloc))
		for id in index_walk_next(&walk) do if holds(tx, committed, index, values, id, ignore, writes) do return true
		return false
	}
	ids := table_index_lookup(committed, index, values)
	defer delete(ids)
	for id in ids do if holds(tx, committed, index, values, id, ignore, writes) do return true
	return false
}

// tx_rewrite_keeps_key reports whether a committed row the transaction rewrote
// still holds the key `values` has under a unique index. An update that keeps
// the row's unique keys registers none (tx_update_row): its row is still found
// under its key in the committed index, and is asked here. Only a row the
// committed index files under the key is asked, so a lookup that finds none
// pays nothing.
tx_rewrite_keeps_key :: proc(tx: ^Tx, table: ^Table, index: int, staged: []Value, values: []Value) -> bool {
	if !index_row_included(table, index, staged) || index_key_has_null(table, index, staged) do return false
	return unique_key(tx, table, index, staged) == unique_key(tx, table, index, values)
}

// tx_unique_keys_kept reports an update that leaves every unique key of the row
// as it was, under plain indexes, in a transaction that changed no index.
@(private)
tx_unique_keys_kept :: proc(tx: ^Tx, table: ^Table, old: []Value, new: []Value) -> bool {
	if len(tx.state.index_ops) > 0 do return false
	for idx, i in table.indexes {
		if idx.unique && !index_key_unchanged(table, i, old, new) do return false
	}
	return true
}

// tx_register_keys records keys tx_check_unique computed for the same values.
@(private)
tx_register_keys :: proc(tx: ^Tx, writes: ^Table_Writes, keys: []Staged_Key, id: Row_Id) {
	if writes == nil do return
	for key in keys do staged_set(tx, writes, key, id)
}

// Unique_Context is what a unique check reads about its table that a caller
// resolved already: its staged writes and the committed table its keys may
// collide with (nil when there is none, or the transaction dropped it).
Unique_Context :: struct {
	writes:    ^Table_Writes,
	committed: ^Table,
}

// tx_unique_committed is the committed table of `name` a unique key may collide
// with: nil when there is none or this transaction dropped it.
@(private)
tx_unique_committed :: proc(tx: ^Tx, name: string) -> ^Table {
	committed, ok := tx.store.tables[name]
	if !ok || tx.state.dropped[name] do return nil
	return committed
}

@(private)
tx_register_unique :: proc(tx: ^Tx, name: string, table: ^Table, values: []Value, id: Row_Id) {
	writes, ok := tx.state.writes[name]
	if !ok do return
	for idx, i in table.indexes {
		if !idx.unique do continue
		// A row outside a partial index is not constrained by it, and a key with a
		// NULL constrains nothing.
		if !index_row_included(table, i, values) do continue
		if index_key_has_null(table, i, values) do continue
		staged_set(tx, writes, staged_key(tx, table, i, values), id)
	}
}

@(private)
tx_unregister_unique :: proc(tx: ^Tx, name: string, table: ^Table, values: []Value, id: Row_Id) {
	writes, ok := tx.state.writes[name]
	if !ok do return
	for idx, i in table.indexes {
		if !idx.unique do continue
		// A row outside a partial index is not constrained by it, and a key with a
		// NULL constrains nothing.
		if !index_row_included(table, i, values) do continue
		if index_key_has_null(table, i, values) do continue
		key := staged_key(tx, table, i, values)
		if holder, present := staged_holder(writes, key); present && holder == id {
			undo_note_unique(tx, writes, key)
			if key.is_int do staged_ints_erase(&writes.unique_ints, key.int)
			else do map_erase(&writes.unique_keys, key.text)
		}
	}
}

// --- Commit ----------------------------------------------------------------

// tx_commit makes the transaction durable and visible. On failure nothing is
// applied and the transaction is rolled back.
tx_commit :: proc(tx: ^Tx) -> Error {
	if tx == nil || !tx.active do return errf(.Transaction_Closed, "transaction is already closed")
	if refusal := store_refusal(tx.store); refusal.kind != .None {
		tx_discard(tx)
		return refusal
	}
	// An index the commit builds or fills evaluates its expressions with the
	// program's functions of this store (index_eval).
	previous_scope := aggregate_scope_enter(tx.store)
	defer aggregate_scope_leave(previous_scope)
	if tx.read_only {
		tx_discard(tx)
		return ERROR_NONE
	}
	if len(tx.deferred_fks) > 0 {
		if fk_err := fk_check_deferred(tx); fk_err.kind != .None {
			tx_discard(tx)
			return fk_err
		}
	}
	// The virtual tables the transaction wrote sync first: one that refuses
	// turns the commit into a rollback, as in SQLite.
	if len(tx.vtabs_written) > 0 {
		if sync_err := vtab_transaction_step(tx, .Sync); sync_err.kind != .None {
			tx_discard(tx)
			return sync_err
		}
	}
	// The attached databases commit first; one that fails is the transaction's
	// failure.
	if tx.attached_txs != nil {
		if attached_err := tx_attached_commit(tx); attached_err.kind != .None {
			tx_discard(tx)
			return attached_err
		}
	}
	started_us := now_microseconds()
	ops := tx_build_ops(tx)
	defer delete(ops)
	// A commit hook may turn the commit of a transaction that changed something
	// into a rollback, which SQLite reports as a failed constraint.
	if (len(ops) > 0 || tx.wrote) && tx.store.hooks.commit != nil && tx.store.hooks.commit(tx.store.hooks.commit_ctx) {
		// The discard frees the transaction, so the store is read before it.
		store := tx.store
		tx_discard(tx)
		store_fire_rollback(store)
		return errf(.Check_Violation, "constraint failed")
	}
	// Ephemeral operations are applied to the live store but never logged, so
	// temporary tables and their rows vanish on reopen.
	// Which ops are TEMP is asked now, before the apply: a dropped TEMP table is
	// gone afterwards, and its drop would look like a main table's. The rows of
	// one table follow each other, so the answer is asked once per table, not
	// once per row.
	ephemeral := make([]bool, len(ops), context.temp_allocator)
	logged_count := 0
	asked_name: string
	asked_answer, asked := false, false
	for op, i in ops {
		row_op := op.kind == .Insert || op.kind == .Update || op.kind == .Delete
		if row_op && asked && op.name == asked_name {
			ephemeral[i] = asked_answer
		} else {
			ephemeral[i] = tx_op_is_ephemeral(tx, op)
			asked = row_op
			asked_name, asked_answer = op.name, ephemeral[i]
		}
		if !ephemeral[i] do logged_count += 1
	}
	// A store without a log (in memory, not recording) gets no payload: encoding
	// every value of the commit to throw the bytes away was a third of the cost
	// of a small write. Nor does it get the list of logged ops, a copy of every
	// op.
	payload: []u8
	if log_records(&tx.store.log) {
		logged := make([dynamic]Store_Op, 0, logged_count)
		for op, i in ops do if !ephemeral[i] do append(&logged, op)
		payload = tx_encode_ops(logged[:])
		delete(logged)
	}
	defer delete(payload)
	next_seq := tx.store.commit_seq + 1
	log_before := tx.store.log.size
	has_log_record := logged_count > 0
	if has_log_record {
		if log_err := log_append(&tx.store.log, next_seq, payload); log_err.kind != .None {
			tx_discard(tx)
			return log_err
		}
	}
	// Ephemeral-only commits do not advance the sequence, so their versions are
	// stamped with the current one and are visible to the next reader.
	tx.store.apply_seq = has_log_record ? next_seq : tx.store.commit_seq
	// Every insert was checked against the committed rows and the transaction's
	// own keys when it was staged, and the write lock has been held since, so
	// applying it does not probe the unique indexes again. Updates are still
	// checked: two rows that swap keys collide halfway through the apply.
	// The flag is cleared through the store, not through `tx`: tx_discard frees
	// the transaction before this procedure returns, and a deferred `tx.store`
	// read the freed block (a heap corruption in roughly one commit in ten).
	validating_store := tx.store
	validating_store.apply_validated = true
	defer validating_store.apply_validated = false
	apply_cache: Apply_Cache
	for op in ops {
		if apply_err := store_apply(tx.store, op, &apply_cache); apply_err.kind != .None {
			// Applying a validated transaction must not fail. If it does, undo
			// the log record so the file still matches the live state, and
			// refuse the half-applied rows until the database is reopened.
			store_damage(tx.store, apply_err)
			rewind_err := log_rewind(&tx.store.log, log_before)
			tx_discard(tx)
			if rewind_err.kind != .None {
				return errf(
					.Internal,
					"commit %d failed to apply (%s) and the log could not be rewound (%s)",
					next_seq,
					apply_err.message,
					rewind_err.message,
				)
			}
			return error_wrap(apply_err, .Internal, "commit %d failed to apply: %s", next_seq, apply_err.message)
		}
	}
	committed_us := now_microseconds()
	tx.store.last_commit_us = committed_us
	if has_log_record do store_note_commit_time(tx.store, next_seq, committed_us)
	if started_us > 0 do store_record_commit_latency(tx.store, committed_us - started_us)
	if has_log_record do tx.store.commit_seq = next_seq
	notify := tx.store.on_commit
	store := tx.store
	// The staged values die with the transaction, so the hook and the mirror get
	// a copy - and only they do: a store nobody watches skips the copy of every
	// value it just wrote.
	changes: Commit_Changes
	if notify != nil || len(store.sqlite_mirror) > 0 do changes = commit_changes_make(ops, ephemeral)
	changes.seq = store.commit_seq
	defer commit_changes_free(&changes)
	notify_ops := changes.ops
	// A TEMP table is not in the file: the mirror hears only the rest. A temp
	// table's write used to reach it as an unknown table and rewrite the whole
	// file at every commit.
	mirror_ops := notify_ops
	if len(store.sqlite_mirror) > 0 && notify_ops != nil do mirror_ops = commit_changes_durable(&changes, context.temp_allocator)
	// The engine's part is durable: the virtual tables commit theirs.
	if len(tx.vtabs_written) > 0 {
		tx.vtabs_done = true
		error_drop(vtab_transaction_step(tx, .Commit))
	}
	tx_discard(tx)
	// A database opened from a .sqlite file keeps that file current, so a client
	// reading it with any SQLite driver sees the commit. Opened that way, the
	// file is the database's only copy, so a commit it did not take fails.
	guard, guard_ctx := store.mirror_guard, store.mirror_guard_ctx
	// A commit that changed only TEMP tables leaves the file alone: no lock on
	// it, no write.
	// A commit that changed nothing leaves it alone too, as SQLite's: a
	// BEGIN IMMEDIATE that only read took EXCLUSIVE at its COMMIT and waited for
	// every reader of the file (mptest polls for its tasks that way).
	writes_file := len(store.sqlite_mirror) > 0 && len(ops) > 0 && (notify_ops == nil || len(mirror_ops) > 0)
	// The flush takes EXCLUSIVE (the guard) only when it has worked out what
	// to write and is about to write it, as SQLite does: holding it while the
	// pages were patched kept every reader of the file waiting that long too.
	guarded := false
	mirror_err := writes_file ? store_sqlite_mirror_flush(store, mirror_ops, &guarded) : ERROR_NONE
	// A store with no log of its own has the file as its only copy: the file
	// goes back to the state before this commit while the lock is still held.
	if mirror_err.kind != .None && !store.persistent {
		if guard != nil && !guarded {
			guard(guard_ctx, true)
			guarded = true
		}
		store_mirror_failed(store)
	}
	if guard != nil && guarded do guard(guard_ctx, false)
	// A file other connections share: what this commit changed is news to the
	// hashes its connection keeps of the file (sqlite_share.odin).
	if guard != nil && writes_file do store_mirror_note_touched(store, mirror_ops, mirror_err.kind != .None)
	if mirror_err.kind != .None {
		if !store.persistent {
			// The commit is what the file holds, and the file did not take it: it
			// failed, and the rows it applied in memory are read back from the
			// file before the next statement, or, with no connection to do that,
			// refused until the database is opened again (D8).
			if guard == nil do store_damage(store, mirror_err)
			return mirror_err
		}
		store_note_error(store, mirror_err)
	}
	if notify != nil do store_publish(store, &changes)
	// The history the retention no longer keeps goes now (D3).
	store_retain(store)
	return ERROR_NONE
}

@(private)
// Op_Copy is a commit's changes copied out of its transaction, which frees
// what they point at when it ends: every name, value, schema and index of the
// copy is in its own arena. The copy kept the names and the values only, and a
// Create_Table's or an Alter_Table's schema still pointed into the
// transaction's memory once it was gone (A3).
Op_Copy :: struct {
	ops:   []Store_Op,
	arena: ^virtual.Arena,
}

tx_clone_ops :: proc(ops: []Store_Op) -> Op_Copy {
	arena := new(virtual.Arena)
	if virtual.arena_init_growing(arena) != .None {
		free(arena)
		return {}
	}
	alloc := arena_allocator_guarded(arena)
	out := make([]Store_Op, len(ops), alloc)
	for op, i in ops {
		out[i] = op
		out[i].name = strings.clone(op.name, alloc)
		if len(op.values) > 0 {
			values := make([]Value, len(op.values), alloc)
			for value, v in op.values do values[v] = value_clone(value, alloc)
			out[i].values = values
		}
		#partial switch op.kind {
		case .Create_Table, .Alter_Table:
			schema := op.schema
			out[i].schema = schema_copy(&schema, alloc)
		case .Create_Index, .Drop_Index:
			out[i].index = schema_index_copy(op.index, alloc)
		}
	}
	return Op_Copy{ops = out, arena = arena}
}

@(private)
tx_op_is_ephemeral :: proc(tx: ^Tx, op: Store_Op) -> bool {
	if op.kind == .Create_Table do return op.schema.ephemeral
	if table, ok := tx.state.created[op.name]; ok do return table.schema.ephemeral
	if table, ok := tx.store.tables[op.name]; ok do return table.schema.ephemeral
	return false
}

@(private)
tx_free_ops :: proc(copied: ^Op_Copy) {
	if copied.arena != nil {
		virtual.arena_destroy(copied.arena)
		free(copied.arena)
	}
	copied^ = {}
}

// Commit_Changes is what a commit changed, as it publishes it (store_publish):
// its sequence, its list of changes in the order the log has them, and which
// of them are a TEMP table's, which the log and the file never see. It owns a
// copy of the list (Op_Copy), so it outlives the transaction (A3).
Commit_Changes :: struct {
	seq:    u64,
	ops:    []Store_Op,
	temp:   []bool,
	copied: Op_Copy,
}

// commit_changes_make copies `ops` and their TEMP marks out of the
// transaction.
commit_changes_make :: proc(ops: []Store_Op, temp: []bool) -> Commit_Changes {
	copied := tx_clone_ops(ops)
	if copied.arena == nil do return {}
	marks := make([]bool, len(ops), arena_allocator_guarded(copied.arena))
	copy(marks, temp)
	return Commit_Changes{ops = copied.ops, temp = marks, copied = copied}
}

commit_changes_free :: proc(changes: ^Commit_Changes) {
	tx_free_ops(&changes.copied)
	changes^ = {}
}

// commit_changes_durable is the part of the changes the log and the file
// have: every change but a TEMP table's, in `alloc`.
commit_changes_durable :: proc(changes: ^Commit_Changes, alloc: mem.Allocator) -> []Store_Op {
	kept := make([dynamic]Store_Op, 0, len(changes.ops), alloc)
	for op, i in changes.ops do if !changes.temp[i] do append(&kept, op)
	return kept[:]
}

@(private)
tx_build_ops :: proc(tx: ^Tx) -> []Store_Op {
	// An op is 240 bytes; the array is sized once, for every op the commit has,
	// instead of doubling its way there and being copied again at the end.
	count := len(tx.state.dropped) + len(tx.state.created) + len(tx.state.altered) + len(tx.state.index_ops)
	for _, writes in tx.state.writes {
		count += len(writes.deletes) + len(writes.updates) + srows_len(&writes.inserts) + 1
	}
	ops := make([dynamic]Store_Op, 0, count)
	// Drops go first: a table this transaction dropped and created again is
	// applied in that order, on replay and at commit alike. Each kind goes in
	// name order, as the alters do: in the order of the map, two stores that ran
	// the same transaction listed the same changes differently, and a follower
	// replaying another's log could not tell its own changes from them (A3).
	// A commit that drops or creates nothing sorts nothing.
	if len(tx.state.dropped) > 0 {
		dropped_names := map_keys_sorted(tx.state.dropped)
		for name in dropped_names {
			append(&ops, Store_Op{kind = .Drop_Table, name = name})
		}
		delete(dropped_names)
	}
	if len(tx.state.created) > 0 {
		created_names := map_keys_sorted(tx.state.created)
		for name in created_names {
			append(
				&ops,
				Store_Op{kind = .Create_Table, name = name, schema = tx.state.created[name].schema},
			)
		}
		delete(created_names)
	}
	altered_names := map_keys_sorted(tx.state.altered)
	for name in altered_names {
		append(
			&ops,
			Store_Op{kind = .Alter_Table, name = name, schema = tx.state.altered[name].schema},
		)
	}
	delete(altered_names)
	names := make([dynamic]string)
	for name in tx.state.writes do append(&names, name)
	for name in tx.state.created do append(&names, name)
	slice.sort_by(names[:], proc(a, b: string) -> bool {
		return text_compare(a, b) < 0
	})
	defer delete(names)
	emitted := make(map[string]bool)
	defer delete(emitted)
	for name in names {
		if emitted[name] do continue
		emitted[name] = true
		writes, ok := tx.state.writes[name]
		if !ok do continue
		if writes.truncated {
			append(&ops, Store_Op{kind = .Truncate, name = name})
		}
		delete_ids := map_keys_sorted(writes.deletes)
		for id in delete_ids {
			append(&ops, Store_Op{kind = .Delete, name = name, row_id = id})
		}
		delete(delete_ids)
		update_ids := map_keys_sorted(writes.updates)
		for id in update_ids {
			append(
				&ops,
				Store_Op{kind = .Update, name = name, row_id = id, values = writes.updates[id]},
			)
		}
		delete(update_ids)
		// The staged rows a transaction numbered itself are in id order
		// already; only the ones a statement named need a sort.
		if len(writes.inserts.sparse) == 0 {
			for row in writes.inserts.dense {
				if row.id == INVALID_ROW_ID do continue
				append(&ops, Store_Op{kind = .Insert, name = name, row_id = row.id, values = row.values})
			}
		} else {
			insert_ids := srows_ids_sorted(&writes.inserts)
			for id in insert_ids {
				row, _ := srows_get(&writes.inserts, id)
				append(&ops, Store_Op{kind = .Insert, name = name, row_id = id, values = row.values})
			}
			delete(insert_ids)
		}
	}
	for op in tx.state.index_ops {
		if op.drop {
			append(&ops, Store_Op{kind = .Drop_Index, name = op.table, index = op.index})
		} else {
			append(&ops, Store_Op{kind = .Create_Index, name = op.table, index = op.index})
		}
	}
	// The slice keeps the array's block, which the caller deletes.
	return ops[:]
}

@(private)
map_keys_sorted :: proc(m: map[$K]$V) -> [dynamic]K where intrinsics.type_is_ordered(K) {
	keys := make([dynamic]K, 0, len(m))
	for key in m do append(&keys, key)
	// Every commit sorts the ids it inserts, updates and deletes; the generic
	// sort spent 42 us on 256 of them.
	when K == Row_Id {
		row_ids_sort(keys[:])
	} else {
		slice.sort_by(keys[:], proc(a, b: K) -> bool {
			return a < b
		})
	}
	return keys
}

@(private)
tx_encode_ops :: proc(ops: []Store_Op) -> []u8 {
	w: Byte_Writer
	bw_init(&w)
	bw_write_u32(&w, u32(len(ops)))
	for op in ops {
		store_op_encode(&w, op)
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	bw_destroy(&w)
	return out
}

// --- Prepared transactions -------------------------------------------------

// Prepared_Tx is a validated transaction whose log record has not been written
// yet. Preparing releases the store lock, so several transactions can be
// prepared and then committed together with one fsync.
Prepared_Tx :: struct {
	changes: Commit_Changes,
	payload: []u8,
}

// tx_prepare closes the transaction and returns its operations. The caller owns
// the result and must pass it to store_commit_prepared or prepared_destroy.
tx_prepare :: proc(tx: ^Tx) -> (^Prepared_Tx, Error) {
	if tx == nil || !tx.active do return nil, errf(.Transaction_Closed, "transaction is already closed")
	if tx.read_only {
		tx_discard(tx)
		return nil, errf(.Transaction_Read_Only, "a read transaction cannot be prepared")
	}
	// A group commit publishes what each transaction changed (store_publish),
	// and does nothing else tx_commit does around the apply: a commit hook that
	// may refuse it, a .sqlite file kept current, virtual tables that commit
	// their part. A transaction that needs one commits by itself; it used to be
	// grouped and skip them.
	if tx.store.hooks.commit != nil || len(tx.store.sqlite_mirror) > 0 || len(tx.vtabs_written) > 0 {
		tx_discard(tx)
		return nil, errf(.Sql_Unsupported, "a transaction with a commit hook, a .sqlite file or virtual tables commits by itself, not in a group")
	}
	ops := tx_build_ops(tx)
	temp := make([]bool, len(ops), context.temp_allocator)
	logged: [dynamic]Store_Op
	for op, i in ops {
		temp[i] = tx_op_is_ephemeral(tx, op)
		if temp[i] do continue
		append(&logged, op)
	}
	stable := commit_changes_make(ops, temp)
	payload := tx_encode_ops(logged[:])
	delete(logged)
	delete(ops)
	tx_discard(tx)
	prepared := new(Prepared_Tx)
	prepared.changes = stable
	prepared.payload = payload
	return prepared, ERROR_NONE
}

prepared_destroy :: proc(prepared: ^Prepared_Tx) {
	if prepared == nil do return
	commit_changes_free(&prepared.changes)
	delete(prepared.payload)
	free(prepared)
}

// tx_catalog_generation is the catalog generation a resolution made in the
// transaction holds for, and false when it holds for this transaction alone:
// the transaction staged a change to the catalog, or the catalog moved since it
// began (an ATTACH, or a change to an attached database, which it reads live).
tx_catalog_generation :: proc(tx: ^Tx) -> (generation: u64, ok: bool) {
	if tx == nil || tx.store == nil do return 0, false
	if tx.catalog_seen != store_catalog_generation(tx.store) do return 0, false
	if tx_changes_catalog(tx) do return 0, false
	return tx.catalog_seen, true
}

// tx_changes_catalog says whether the transaction staged a change to what a
// statement's names resolve to, which nothing committed yet: a tree resolved in
// it holds for it alone.
tx_changes_catalog :: proc(tx: ^Tx) -> bool {
	if tx == nil || tx.read_only do return false
	if len(tx.state.created) > 0 || len(tx.state.altered) > 0 || len(tx.state.dropped) > 0 || len(tx.state.index_ops) > 0 do return true
	for name in ([]string{VIEW_TABLE, POLICY_TABLE, TRIGGER_TABLE, TYPE_TABLE, VIRTUAL_TABLE}) {
		if name in tx.state.writes do return true
	}
	return false
}
