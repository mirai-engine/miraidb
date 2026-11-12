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
	// locked is true when the transaction holds the store lock (write
	// transactions and pinned reads).
	state:     Tx_State,
	arena:     virtual.Arena,
	alloc:     mem.Allocator,
	// read_seq is the commit sequence the transaction started from and
	// read_tables is the set of tables it touched.
	read_seq:    u64,
	read_tables: map[string]bool,
	// A read transaction that uses snapshots owns frozen copies of every table
	// and does not hold the store lock; `locked` records whether it does.
	use_frozen:   bool,
	locked:       bool,
	frozen:       map[string]^Table,
	frozen_list:  [dynamic]^Table,
	// frozen_shared says the snapshot belongs to the store's read cache, so this
	// transaction must not destroy it.
	frozen_shared: bool,
	// cte_tables holds the common table expressions materialized for the current
	// statement; they live in temp_tables and are destroyed with the transaction.
	// work_units is what this transaction spent, summed from each statement's
	// price (rows touched plus payload). A host budget compares it before commit.
	work_units: u64,
	// fts_cache holds the document set of each MATCH pattern for this
	// transaction, so a scan asks the shadow table once per pattern.
	fts_cache:           map[string]map[Row_Id]bool,
	cte_tables:  map[string]^Table,
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
}

Table_Writes :: struct {
	inserts:     map[Row_Id]Row,
	updates:     map[Row_Id][]Value,
	deletes:     map[Row_Id]bool,
	truncated:   bool,
	unique_keys: map[string]Row_Id,
	next_row_id: u64,
	next_sequence: i64,
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
		copied := new(Table_Writes, tx.alloc)
		copied^ = writes^
		copied.inserts = make(map[Row_Id]Row, len(writes.inserts), tx.alloc)
		for id, row in writes.inserts do copied.inserts[id] = row
		copied.updates = make(map[Row_Id][]Value, len(writes.updates), tx.alloc)
		for id, values in writes.updates do copied.updates[id] = values
		copied.deletes = make(map[Row_Id]bool, len(writes.deletes), tx.alloc)
		for id in writes.deletes do copied.deletes[id] = true
		copied.unique_keys = make(map[string]Row_Id, len(writes.unique_keys), tx.alloc)
		for key, id in writes.unique_keys do copied.unique_keys[key] = id
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
	// The map headers and the struct live in the transaction arena: the maps are
	// released, and the arena reclaims the rest with the transaction.
	for _, writes in snapshot.writes {
		delete(writes.inserts)
		delete(writes.updates)
		delete(writes.deletes)
		delete(writes.unique_keys)
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
	return ERROR_NONE
}

// tx_release_savepoint drops the named savepoint and every one nested inside it.
tx_release_savepoint :: proc(tx: ^Tx, name: string) -> Error {
	for i := len(tx.savepoints) - 1; i >= 0; i -= 1 {
		if !strings.equal_fold(tx.savepoints[i].name, name) do continue
		for j := len(tx.savepoints) - 1; j >= i; j -= 1 do tx_snapshot_destroy(tx, &tx.savepoints[j].snapshot)
		resize(&tx.savepoints, i)
		return ERROR_NONE
	}
	return errf(.Invalid_Argument, "no such savepoint: %s", name)
}

// tx_rollback_to_savepoint undoes the work staged after the savepoint and keeps
// it open. Savepoints opened after it are discarded, and tables created after it
// are destroyed.
tx_rollback_to_savepoint :: proc(tx: ^Tx, name: string) -> Error {
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
		return ERROR_NONE
	}
	return errf(.Invalid_Argument, "no such savepoint: %s", name)
}

tx_begin_write :: proc(store: ^Store) -> ^Tx {
	tx := new(Tx)
	tx.store = store
	tx.active = true
	if arena_err := virtual.arena_init_growing(&tx.arena); arena_err != .None {
		panic("miraidb: cannot allocate the transaction arena")
	}
	tx.alloc = virtual.arena_allocator(&tx.arena)
	tx.read_seq = store.commit_seq
	tx.read_tables = make(map[string]bool)
	tx.cte_tables = make(map[string]^Table)
	tx.state.writes = make(map[string]^Table_Writes)
	tx.state.created = make(map[string]^Table)
	tx.state.altered = make(map[string]^Table)
	tx.state.dropped = make(map[string]bool)
	tx.state.index_ops = make([dynamic]Tx_Index_Op)
	tx.locked = true
	sync.lock(&store.mutex)
	return tx
}

tx_begin_read :: proc(store: ^Store) -> ^Tx {
	tx := new(Tx)
	tx.store = store
	tx.active = true
	tx.read_only = true
	if arena_err := virtual.arena_init_growing(&tx.arena); arena_err != .None {
		panic("miraidb: cannot allocate the transaction arena")
	}
	tx.alloc = virtual.arena_allocator(&tx.arena)
	tx.read_tables = make(map[string]bool)
	tx.cte_tables = make(map[string]^Table)
	tx.use_frozen = true
	// The lock is held only while the snapshot is taken or borrowed; the
	// statement then runs without it, so a long read never blocks a commit.
	sync.shared_lock(&store.mutex)
	tx.read_seq = store.commit_seq
	// Reuse the snapshot published for this exact commit sequence: when nothing
	// committed in between, opening a read is O(1) and copies nothing.
	if store.read_cache != nil && store.read_cache.seq == store.commit_seq {
		tx.frozen = store.read_cache.frozen
		tx.frozen_list = store.read_cache.list
		tx.frozen_shared = true
		sync.shared_unlock(&store.mutex)
		return tx
	}
	tx.frozen = make(map[string]^Table)
	for name, table in store.tables {
		clone := table_snapshot(table)
		if clone == nil do continue
		tx.frozen[name] = clone
		append(&tx.frozen_list, clone)
	}
	// Publish this snapshot for later readers; the cache owns it now, so the
	// transaction must not destroy it.
	if len(store.retired) < READ_CACHE_LIMIT {
		if store.read_cache != nil do append(&store.retired, store.read_cache)
		cache := new(Frozen_Cache)
		cache.seq = tx.read_seq
		cache.frozen = tx.frozen
		cache.list = tx.frozen_list
		store.read_cache = cache
		tx.frozen_shared = true
	}
	sync.shared_unlock(&store.mutex)
	return tx
}

// READ_CACHE_LIMIT bounds how many read snapshots stay alive; past it, reads
// copy again instead of pinning more memory.
READ_CACHE_LIMIT :: 16

// Frozen_Cache is one published read snapshot, owned by the store.
Frozen_Cache :: struct {
	seq:    u64,
	frozen: map[string]^Table,
	list:   [dynamic]^Table,
}

frozen_cache_destroy :: proc(cache: ^Frozen_Cache) {
	if cache == nil do return
	for table in cache.list do table_destroy(table)
	delete(cache.list)
	delete(cache.frozen)
	free(cache)
}

// tx_begin_read_at starts a read transaction pinned to an older sequence. It is
// how a caller reads consistently at a snapshot it captured earlier; the row
// versions still hold that view until store_prune_versions runs.
tx_begin_read_at :: proc(store: ^Store, seq: u64) -> ^Tx {
	// A pinned read uses the live tables with versions instead of a snapshot.
	tx := tx_begin_read(store)
	if !tx.frozen_shared {
		for table in tx.frozen_list do table_destroy(table)
		delete(tx.frozen_list)
		delete(tx.frozen)
	}
	tx.frozen_shared = false
	tx.frozen_list = nil
	tx.use_frozen = false
	sync.shared_lock(&store.mutex)
	tx.locked = true
	if seq < tx.read_seq do tx.read_seq = seq
	return tx
}

// tx_end releases a transaction that was neither committed nor rolled back.
tx_end :: proc(tx: ^Tx) {
	if tx == nil || !tx.active do return
	tx_discard(tx)
}

tx_rollback :: proc(tx: ^Tx) {
	if tx == nil || !tx.active do return
	tx_discard(tx)
}

@(private)
tx_discard :: proc(tx: ^Tx) {
	tx.active = false
	for table in tx.temp_tables {
		table_destroy(table)
	}
	delete(tx.temp_tables)
	for _, table in tx.state.created {
		table_destroy(table)
	}
	for _, writes in tx.state.writes {
		delete(writes.inserts)
		delete(writes.updates)
		delete(writes.deletes)
		delete(writes.unique_keys)
	}
	for i in 0 ..< len(tx.savepoints) do tx_snapshot_destroy(tx, &tx.savepoints[i].snapshot)
	delete(tx.savepoints)
	for _, docs in tx.fts_cache do delete(docs)
	delete(tx.fts_cache)
	delete(tx.cte_tables)
	delete(tx.state.index_ops)
	delete(tx.state.writes)
	delete(tx.state.created)
	delete(tx.state.dropped)
	if !tx.frozen_shared {
		for table in tx.frozen_list do table_destroy(table)
		delete(tx.frozen_list)
		delete(tx.frozen)
	}
	tx.frozen_shared = false
	virtual.arena_destroy(&tx.arena)
	if tx.locked {
		if tx.read_only {
			sync.shared_unlock(&tx.store.mutex)
		} else {
			sync.unlock(&tx.store.mutex)
		}
	}
	free(tx)
}

// --- Lookup ----------------------------------------------------------------

tx_table :: proc(tx: ^Tx, name: string) -> (^Table, Error) {
	// The key must outlive the statement's query arena.
	tx.read_tables[strings.clone(name, tx.alloc)] = true
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

// tx_alter_table stages a schema change. The replacement table already carries
// the extra columns for every existing row, so the commit only records the
// schema and the store rebuilds the same way on replay.
tx_alter_table :: proc(tx: ^Tx, name: string, next_schema: Table_Schema) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot alter a table in a read transaction")
	if _, created := tx.state.created[name]; created {
		return errf(.Sql_Unsupported, "alter a table outside the transaction that created it")
	}
	current, current_err := tx_table(tx, name)
	if current_err.kind != .None do return current_err
	schema := next_schema
	replacement, create_err := table_create(&schema)
	if create_err.kind != .None do return create_err
	for id, row in current.rows {
		values := make([]Value, len(next_schema.columns), tx.alloc)
		// Columns are matched by name, so a drop and an addition both work.
		for column, i in next_schema.columns {
			old_index, found := schema_column_index(&current.schema, column.name)
			if found && old_index < len(row.values) {
				values[i] = row.values[old_index]
			} else {
				values[i] = column.has_default ? column.default_value : value_null()
			}
		}
		if insert_err := table_insert(replacement, id, values); insert_err.kind != .None {
			return insert_err
		}
	}
	replacement.next_row_id = current.next_row_id
	replacement.next_sequence = current.next_sequence
	tx.state.altered[strings.clone(name, tx.alloc)] = replacement
	return ERROR_NONE
}

// tx_drop_column removes a column from a table and every row, including the
// rows staged in this transaction. Keys and auto-increment columns cannot go:
// their identity is part of how the table is written.
tx_drop_column :: proc(tx: ^Tx, name, column_name: string) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot alter a table in a read transaction")
	if _, created := tx.state.created[name]; created {
		return errf(.Sql_Unsupported, "alter a table outside the transaction that created it")
	}
	current, current_err := tx_table(tx, name)
	if current_err.kind != .None do return current_err
	index, found := schema_column_index(&current.schema, column_name)
	if !found do return errf(.Column_Not_Found, "column %s does not exist in %s", column_name, name)
	if current.schema.columns[index].unique || current.schema.columns[index].auto_increment {
		return errf(.Sql_Unsupported, "cannot drop the key column %s", column_name)
	}
	for key in current.schema.primary_key {
		if key == index do return errf(.Sql_Unsupported, "cannot drop the key column %s", column_name)
	}
	// An index stores column positions; removing a column would shift them, so a
	// table with secondary indexes must lose them first.
	for index_def in current.schema.indexes {
		if !index_def.implicit {
			return errf(
				.Sql_Unsupported,
				"cannot drop %s while %s has secondary indexes",
				column_name,
				name,
			)
		}
		for position in index_def.columns {
			if position > index {
				return errf(.Sql_Unsupported, "cannot drop %s before an indexed column", column_name)
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
	schema := next_schema
	replacement, create_err := table_create(&schema)
	if create_err.kind != .None do return create_err
	for id, row in current.rows {
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
		for id, row in writes.inserts {
			next := make([]Value, len(row.values) - 1, tx.alloc)
			copy(next, row.values[:index])
			copy(next[index:], row.values[index + 1:])
			writes.inserts[id] = Row {
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
	}
	tx.state.altered[strings.clone(name, tx.alloc)] = replacement
	return ERROR_NONE
}

// tx_rename_table moves a table to a new name. The rows keep their ids; the
// staged writes follow the table, so a commit applies the rename before them.
tx_rename_table :: proc(tx: ^Tx, from, to: string) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot alter a table in a read transaction")
	if _, created := tx.state.created[from]; created {
		return errf(.Sql_Unsupported, "alter a table outside the transaction that created it")
	}
	current, current_err := tx_table(tx, from)
	if current_err.kind != .None do return current_err
	if _, clash := tx_table(tx, to); clash.kind == .None {
		return errf(.Table_Exists, "table %s already exists", to)
	}
	next_schema := current.schema
	next_schema.name = strings.clone(to, tx.alloc)
	schema := next_schema
	replacement, create_err := table_create(&schema)
	if create_err.kind != .None do return create_err
	for id, row in current.rows {
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

@(private)
tx_writes :: proc(tx: ^Tx, name: string, table: ^Table) -> ^Table_Writes {
	if writes, ok := tx.state.writes[name]; ok {
		return writes
	}
	writes := new(Table_Writes)
	writes.inserts = make(map[Row_Id]Row)
	writes.updates = make(map[Row_Id][]Value)
	writes.deletes = make(map[Row_Id]bool)
	writes.unique_keys = make(map[string]Row_Id)
	writes.next_row_id = table.next_row_id
	writes.next_sequence = table.next_sequence
	// The map key must outlive the caller's statement buffer, so it lives in the
	// transaction arena.
	tx.state.writes[strings.clone(name, tx.alloc)] = writes
	return writes
}

tx_get :: proc(tx: ^Tx, name: string, id: Row_Id) -> (Row, bool) {
	if writes, ok := tx.state.writes[name]; ok {
		if row, inserted := writes.inserts[id]; inserted do return row, true
		if values, updated := writes.updates[id]; updated do return Row{id = id, values = values}, true
		if writes.deletes[id] do return {}, false
		if writes.truncated do return {}, false
	}
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return {}, false
	if row, exists := table.rows[id]; exists {
		return row, true
	}
	return {}, false
}

// tx_collect fills `out` with the visible rows of one table, ordered by row id.
tx_collect :: proc(tx: ^Tx, name: string, out: ^[dynamic]Row) -> Error {
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return table_err
	writes := tx.state.writes[name]
	if !tx.state.dropped[name] && (writes == nil || !writes.truncated) {
		table_collect(table, out, tx.read_seq)
	}
	if writes == nil do return ERROR_NONE
	seen := make(map[Row_Id]bool, len(writes.inserts) + len(out))
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
	for id, row in writes.inserts {
		if seen[id] do continue
		append(out, row)
	}
	// Remove the tombstoned slots the delete pass marked.
	write := 0
	for i in 0 ..< len(out) {
		if out[i].id == Row_Id(0xffff_ffff_ffff_ffff) do continue
		out[write] = out[i]
		write += 1
	}
	if write < len(out) do resize(out, write)
	slice.sort_by(out[:], proc(a, b: Row) -> bool {
		return u64(a.id) < u64(b.id)
	})
	return ERROR_NONE
}

tx_row_count :: proc(tx: ^Tx, name: string) -> (int, Error) {
	rows := make([dynamic]Row)
	defer delete(rows)
	if err := tx_collect(tx, name, &rows); err.kind != .None {
		return 0, err
	}
	return len(rows), ERROR_NONE
}

// --- DDL -------------------------------------------------------------------

tx_create_table :: proc(tx: ^Tx, schema: ^Table_Schema) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot create a table in a read transaction")
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
	map_erase(&tx.state.dropped, schema.name)
	return ERROR_NONE
}

tx_drop_table :: proc(tx: ^Tx, name: string) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot drop a table in a read transaction")
	if created, ok := tx.state.created[name]; ok {
		table_destroy(created)
		map_erase(&tx.state.created, name)
		// Rows staged for a table created in this transaction disappear with it.
		if writes, has_writes := tx.state.writes[name]; has_writes {
			delete(writes.inserts)
			delete(writes.updates)
			delete(writes.deletes)
			delete(writes.unique_keys)
			free(writes)
			map_erase(&tx.state.writes, name)
		}
		return ERROR_NONE
	}
	if _, exists := tx.store.tables[name]; !exists {
		return errf(.Table_Not_Found, "table %s does not exist", name)
	}
	tx.state.dropped[strings.clone(name, tx.alloc)] = true
	return ERROR_NONE
}

// --- DML -------------------------------------------------------------------

// tx_insert coerces `values` to the table schema, assigns the row id, validates
// uniqueness and stages the row. Columns not supplied are filled with their
// default; pass a value vector of exactly one entry per column.
tx_insert :: proc(tx: ^Tx, name: string, values: []Value) -> (Row_Id, Error) {
	if tx.read_only do return 0, errf(.Transaction_Read_Only, "cannot insert in a read transaction")
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return 0, table_err
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
	writes := tx_writes(tx, name, table)
	id := Row_Id(writes.next_row_id)

	row_values := make([]Value, len(values), tx.alloc)
	// SQLite's INTEGER PRIMARY KEY is the rowid: an omitted value is assigned.
	pk_position := -1
	if len(table.schema.primary_key) == 1 {
		position := table.schema.primary_key[0]
		if table.schema.columns[position].type.kind == .Int do pk_position = position
	}
	for column, i in table.schema.columns {
		v := values[i]
		if i == pk_position && !column.auto_increment && (v.kind == .Default || v.kind == .Null) {
			// Assign max(pk) + 1 over the stored rows and the staged ones.
			next := i64(1)
			for _, row in table.rows {
				if row.values[i].kind == .Int && row.values[i].i >= next do next = row.values[i].i + 1
			}
			for _, row in writes.inserts {
				if row.values[i].kind == .Int && row.values[i].i >= next do next = row.values[i].i + 1
			}
			v = value_int(next)
		}
		if v.kind == .Default {
			if column.auto_increment {
				v = value_int(writes.next_sequence)
			} else {
				v = column_default(column)
			}
		} else if v.kind == .Null && column.auto_increment {
			v = value_int(writes.next_sequence)
		}
		coerced, coerce_err := value_coerce(v, column.type)
		if coerce_err.kind != .None do return 0, coerce_err
		if coerced.kind == .Null && column.not_null {
			return 0, errf(.Not_Null_Violation, "column %s.%s cannot be NULL", name, column.name)
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
			if next > writes.next_sequence do writes.next_sequence = next
		}
		row_values[i] = value_clone(coerced, tx.alloc)
	}

	if fk_err := fk_check_child(tx, table, row_values); fk_err.kind != .None {
		return 0, fk_err
	}
	if err := tx_check_unique(tx, name, table, row_values, INVALID_ROW_ID); err.kind != .None {
		return 0, err
	}

	writes.inserts[id] = Row{id = id, values = row_values}
	writes.next_row_id = u64(id) + 1
	tx_register_unique(tx, name, table, row_values, id)
	if trigger_err := trigger_fire(tx, name, .Insert, Row{}, Row{id = id, values = row_values}, table.schema); trigger_err.kind != .None {
		return 0, trigger_err
	}
	return id, ERROR_NONE
}

INVALID_ROW_ID :: Row_Id(max(u64))

// tx_update replaces the whole row. `values` must have one entry per column.
tx_update :: proc(tx: ^Tx, name: string, id: Row_Id, values: []Value) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot update in a read transaction")
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return table_err
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
	writes := tx_writes(tx, name, table)
	previous, exists := tx_get(tx, name, id)
	if !exists {
		return errf(.Invalid_Argument, "row %d does not exist in table %s", u64(id), name)
	}
	row_values := make([]Value, len(values), tx.alloc)
	// SQLite's INTEGER PRIMARY KEY is the rowid: an omitted value is assigned.
	pk_position := -1
	if len(table.schema.primary_key) == 1 {
		position := table.schema.primary_key[0]
		if table.schema.columns[position].type.kind == .Int do pk_position = position
	}
	for column, i in table.schema.columns {
		v := values[i]
		if i == pk_position && !column.auto_increment && (v.kind == .Default || v.kind == .Null) {
			// Assign max(pk) + 1 over the stored rows and the staged ones.
			next := i64(1)
			for _, row in table.rows {
				if row.values[i].kind == .Int && row.values[i].i >= next do next = row.values[i].i + 1
			}
			for _, row in writes.inserts {
				if row.values[i].kind == .Int && row.values[i].i >= next do next = row.values[i].i + 1
			}
			v = value_int(next)
		}
		if v.kind == .Default {
			v = column_default(column)
		} else if v.kind == .Null && column.auto_increment {
			v = value_uint(u64(id))
		}
		coerced, coerce_err := value_coerce(v, column.type)
		if coerce_err.kind != .None do return coerce_err
		if coerced.kind == .Null && column.not_null {
			return errf(.Not_Null_Violation, "column %s.%s cannot be NULL", name, column.name)
		}
		row_values[i] = value_clone(coerced, tx.alloc)
	}
	if fk_err := fk_check_child(tx, table, row_values); fk_err.kind != .None {
		return fk_err
	}
	tx_unregister_unique(tx, name, table, previous.values, id)
	if err := tx_check_unique(tx, name, table, row_values, id); err.kind != .None {
		tx_register_unique(tx, name, table, previous.values, id)
		return err
	}
	if _, staged := writes.inserts[id]; staged {
		writes.inserts[id] = Row{id = id, values = row_values}
	} else {
		writes.updates[id] = row_values
	}
	tx_register_unique(tx, name, table, row_values, id)
	// ON UPDATE cascades run after the new key is staged, so the children see it.
	if fk_err := fk_parent_update(tx, name, previous.values, row_values); fk_err.kind != .None {
		return fk_err
	}
	if trigger_err := trigger_fire(tx, name, .Update, previous, Row{id = id, values = row_values}, table.schema); trigger_err.kind != .None {
		return trigger_err
	}
	return ERROR_NONE
}

tx_delete :: proc(tx: ^Tx, name: string, id: Row_Id) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot delete in a read transaction")
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
	writes := tx_writes(tx, name, table)
	tx_unregister_unique(tx, name, table, previous.values, id)
	if _, staged := writes.inserts[id]; staged {
		map_erase(&writes.inserts, id)
	} else {
		if _, updated := writes.updates[id]; updated {
			map_erase(&writes.updates, id)
		}
		writes.deletes[id] = true
	}
	if trigger_err := trigger_fire(tx, name, .Delete, previous, Row{}, table.schema); trigger_err.kind != .None {
		return trigger_err
	}
	return ERROR_NONE
}

tx_truncate :: proc(tx: ^Tx, name: string) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot truncate in a read transaction")
	table, table_err := tx_table(tx, name)
	if table_err.kind != .None do return table_err
	if table.schema.event do return errf(.Sql_Unsupported, "event table %s is append-only", name)
	if permission_err := tx_check_permission(tx, name, "delete"); permission_err.kind != .None {
		return permission_err
	}
	writes := tx_writes(tx, name, table)
	clear(&writes.inserts)
	clear(&writes.updates)
	clear(&writes.deletes)
	clear(&writes.unique_keys)
	writes.truncated = true
	return ERROR_NONE
}

// --- Index DDL -------------------------------------------------------------

// tx_create_index stages an index alongside the rows of the same transaction.
// The index is built when the transaction is applied, after the rows it covers:
// a table created here, rows inserted here and an index on them still land in one
// atomic commit.
tx_create_index :: proc(tx: ^Tx, table_name: string, index: Index_Schema) -> Error {
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot create an index in a read transaction")
	table, table_err := tx_table(tx, table_name)
	if table_err.kind != .None do return table_err
	stored := Index_Schema {
		name      = strings.clone(index.name, tx.alloc),
		unique    = index.unique,
		implicit  = false,
		algorithm = index.algorithm,
		columns   = slice.clone(index.columns, tx.alloc),
	}
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
	for col in stored.columns {
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
	if tx.read_only do return errf(.Transaction_Read_Only, "cannot drop an index in a read transaction")
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
	key := index_prefix_temp(table, index, values)
	defer delete(key)
	return strings.concatenate({table.indexes[index].schema.name, "\x00", key}, tx.alloc)
}

@(private)
tx_check_unique :: proc(tx: ^Tx, name: string, table: ^Table, values: []Value, ignore: Row_Id) -> Error {
	writes := tx.state.writes[name]
	for idx, i in table.indexes {
		if !idx.unique do continue
		key := unique_key(tx, table, i, values)
		if writes != nil {
			if holder, taken := writes.unique_keys[key]; taken && holder != ignore {
				return errf(
					index_is_primary(table, i) ? .Duplicate_Primary_Key : .Duplicate_Unique,
					"duplicate key for index %s",
					idx.schema.name,
				)
			}
		}
		if committed, ok := tx.store.tables[name]; ok {
			ids := table_index_lookup(committed, i, values)
			defer delete(ids)
			for id in ids {
				if id == ignore do continue
				if writes != nil {
					if writes.deletes[id] do continue
					if _, changed := writes.updates[id]; changed do continue
				}
				return errf(
					index_is_primary(table, i) ? .Duplicate_Primary_Key : .Duplicate_Unique,
					"duplicate key for index %s",
					idx.schema.name,
				)
			}
		}
	}
	return ERROR_NONE
}

@(private)
tx_register_unique :: proc(tx: ^Tx, name: string, table: ^Table, values: []Value, id: Row_Id) {
	writes, ok := tx.state.writes[name]
	if !ok do return
	for idx, i in table.indexes {
		if !idx.unique do continue
		writes.unique_keys[unique_key(tx, table, i, values)] = id
	}
}

@(private)
tx_unregister_unique :: proc(tx: ^Tx, name: string, table: ^Table, values: []Value, id: Row_Id) {
	writes, ok := tx.state.writes[name]
	if !ok do return
	for idx, i in table.indexes {
		if !idx.unique do continue
		key := unique_key(tx, table, i, values)
		if holder, present := writes.unique_keys[key]; present && holder == id {
			map_erase(&writes.unique_keys, key)
		}
	}
}

// --- Commit ----------------------------------------------------------------

// tx_commit makes the transaction durable and visible. On failure nothing is
// applied and the transaction is rolled back.
tx_commit :: proc(tx: ^Tx) -> Error {
	if tx == nil || !tx.active do return errf(.Transaction_Closed, "transaction is already closed")
	if tx.read_only {
		tx_discard(tx)
		return ERROR_NONE
	}
	started_us := now_microseconds()
	ops := tx_build_ops(tx)
	defer delete(ops)
	// Ephemeral operations are applied to the live store but never logged, so
	// temporary tables and their rows vanish on reopen.
	logged := make([dynamic]Store_Op, 0, len(ops))
	for op in ops {
		if tx_op_is_ephemeral(tx, op) do continue
		append(&logged, op)
	}
	logged_count := len(logged)
	payload := tx_encode_ops(logged[:])
	delete(logged)
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
	for op in ops {
		if apply_err := store_apply(tx.store, op); apply_err.kind != .None {
			// Applying a validated transaction must not fail. If it does, undo
			// the log record so the file still matches the live state.
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
			return errf(.Internal, "commit %d failed to apply: %s", next_seq, apply_err.message)
		}
	}
	committed_us := now_microseconds()
	tx.store.last_commit_us = committed_us
	if started_us > 0 do store_record_commit_latency(tx.store, committed_us - started_us)
	if has_log_record do tx.store.commit_seq = next_seq
	notify := tx.store.on_commit
	notify_ctx := tx.store.on_commit_ctx
	store := tx.store
	// The staged values die with the transaction, so the hook gets a copy.
	notify_ops := tx_clone_ops(ops)
	defer tx_free_ops(notify_ops)
	tx_discard(tx)
	// A database opened from a .sqlite file keeps that file current, so a client
	// reading it with any SQLite driver sees the commit. O(state) per commit, by
	// design: the file is a materialized export, the log is the truth.
	if mirror_err := store_sqlite_mirror_flush(store); mirror_err.kind != .None {
		store.last_error = mirror_err
	}
	if notify != nil {
		notify(notify_ctx, store, notify_ops)
	}
	return ERROR_NONE
}

@(private)
tx_clone_ops :: proc(ops: []Store_Op) -> []Store_Op {
	out := make([]Store_Op, len(ops))
	for op, i in ops {
		out[i] = op
		out[i].name = strings.clone(op.name)
		out[i].values = clone_values(op.values)
	}
	return out
}

@(private)
tx_op_is_ephemeral :: proc(tx: ^Tx, op: Store_Op) -> bool {
	if op.kind == .Create_Table do return op.schema.ephemeral
	if table, ok := tx.state.created[op.name]; ok do return table.schema.ephemeral
	if table, ok := tx.store.tables[op.name]; ok do return table.schema.ephemeral
	return false
}

@(private)
tx_free_ops :: proc(ops: []Store_Op) {
	for op in ops {
		delete(op.name)
		free_values(op.values)
	}
	delete(ops)
}

@(private)
tx_build_ops :: proc(tx: ^Tx) -> []Store_Op {
	ops := make([dynamic]Store_Op)
	for name in tx.state.created {
		append(
			&ops,
			Store_Op{kind = .Create_Table, name = name, schema = tx.state.created[name].schema},
		)
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
		return strings.compare(a, b) < 0
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
		insert_ids := map_keys_sorted(writes.inserts)
		for id in insert_ids {
			append(
				&ops,
				Store_Op{kind = .Insert, name = name, row_id = id, values = writes.inserts[id].values},
			)
		}
		delete(insert_ids)
	}
	for op in tx.state.index_ops {
		if op.drop {
			append(&ops, Store_Op{kind = .Drop_Index, name = op.table, index = op.index})
		} else {
			append(&ops, Store_Op{kind = .Create_Index, name = op.table, index = op.index})
		}
	}
	for name in tx.state.dropped {
		append(&ops, Store_Op{kind = .Drop_Table, name = name})
	}
	out := make([]Store_Op, len(ops))
	copy(out, ops[:])
	delete(ops)
	return out
}

@(private)
map_keys_sorted :: proc(m: map[$K]$V) -> [dynamic]K where intrinsics.type_is_ordered(K) {
	keys := make([dynamic]K)
	for key in m do append(&keys, key)
	slice.sort_by(keys[:], proc(a, b: K) -> bool {
		return a < b
	})
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
	ops:     []Store_Op,
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
	ops := tx_build_ops(tx)
	stable := tx_clone_ops(ops)
	logged: [dynamic]Store_Op
	for op in ops {
		if tx_op_is_ephemeral(tx, op) do continue
		append(&logged, op)
	}
	payload := tx_encode_ops(logged[:])
	delete(logged)
	delete(ops)
	tx_discard(tx)
	prepared := new(Prepared_Tx)
	prepared.ops = stable
	prepared.payload = payload
	return prepared, ERROR_NONE
}

prepared_destroy :: proc(prepared: ^Prepared_Tx) {
	if prepared == nil do return
	tx_free_ops(prepared.ops)
	delete(prepared.payload)
	free(prepared)
}
