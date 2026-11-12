package engine

import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:strings"
import "core:slice"
import "core:container/rbtree"

// Row_Id identifies a row inside one table. It is stable for the life of the
// row and is never reused.
Row_Id :: distinct u64

// NO_ROW_ID marks an output row that does not come from one stored row (joins,
// aggregates, SELECT without FROM).
NO_ROW_ID :: Row_Id(max(u64))

// Row_Version is one superseded value set. The live values stay on Row; history
// grows only when a row is updated or deleted, so a read at an older sequence
// can still see what it saw before.
Row_Version :: struct {
	values:      []Value,
	created_seq: u64,
	deleted_seq: u64,
}

Row :: struct {
	id:     Row_Id,
	values: []Value,
	// created_seq and deleted_seq bound the latest version; deleted_seq zero
	// means the row is live. A deleted row stays as a tombstone until versions
	// are pruned, so older snapshots keep seeing it.
	created_seq: u64,
	deleted_seq: u64,
	versions:    [dynamic]Row_Version,
}

Index_Tree :: rbtree.Tree(string, Row_Id)

// Index is one ordered index. The key is the order-preserving encoding of the
// indexed columns. A unique index stores the key alone; a non-unique index
// appends the row id, so every entry is distinct and range scans stay ordered.
Index :: struct {
	schema: Index_Schema,
	unique: bool,
	tree:   Index_Tree,
	// lookup is the equality map for HASH and DIRECT indexes. The tree is still
	// maintained so ordering, range scans and the primary-key path keep working.
	lookup: map[string]^Index_Bucket,
}

// Index_Bucket holds the rows that share one indexed key.
Index_Bucket :: struct {
	ids: [dynamic]Row_Id,
}

// Table is one relation. Rows and index trees live on the heap; the schema and
// the stored index keys live in a per-table arena released when the table is
// dropped.
// Table_Memory estimates what one table holds: row storage plus the index
// entries. Sizes are the encoded value widths, not the allocator's bookkeeping.
Table_Memory :: struct {
	rows:          int,
	row_bytes:     int,
	index_entries: int,
	index_bytes:   int,
}

// Row_Store owns the values of one table and of every snapshot taken from it.
// A snapshot shares values instead of cloning them, so the last one out frees
// them: that is what makes freezing a table O(rows) pointers instead of a deep
// copy of every string.
Row_Store :: struct {
	refs:    int,
	mutex:   sync.Mutex,
	pending: [dynamic]Row,
}

Table :: struct {
	schema:          Table_Schema,
	rows:            map[Row_Id]Row,
	next_row_id:     u64,
	next_sequence:   i64,
	indexes:         []Index,
	// apply_seq is the commit sequence of the change being applied, stamped on
	// the versions it creates.
	apply_seq:       u64,
	arena:           virtual.Arena,
	arena_allocator: mem.Allocator,
	store:           ^Row_Store,
	// borrowed is true for a snapshot: it reads another table's values and must
	// not free them.
	borrowed:        bool,
	// paged holds the rows in a page file. When it is set the map above stays
	// empty: the page file is the storage, not a copy of a map, which is what
	// keeps a table larger than the pool out of RAM. A paged table keeps one
	// version of each row and no tombstones, so it cannot answer an older
	// sequence; the executor refuses AS OF on it and its read transactions hold
	// the store lock.
	paged: ^Page_Rows,
}

@(private)
index_cmp :: proc(a, b: string) -> slice.Ordering {
	return slice.Ordering(strings.compare(a, b))
}

table_create :: proc(schema: ^Table_Schema) -> (^Table, Error) {
	normalized := schema^
	if err := schema_normalize(&normalized); err.kind != .None {
		return nil, err
	}
	if err := schema_validate(&normalized); err.kind != .None {
		return nil, err
	}
	t := new(Table)
	if arena_err := virtual.arena_init_growing(&t.arena); arena_err != .None {
		free(t)
		return nil, errf(.Out_Of_Memory, "cannot create the table arena: %v", arena_err)
	}
	t.arena_allocator = virtual.arena_allocator(&t.arena)
	t.schema = schema_copy(&normalized, t.arena_allocator)
	t.store = new(Row_Store)
	t.store.refs = 1
	t.rows = make(map[Row_Id]Row)
	t.next_row_id = 0
	if t.schema.auto_increment_column != NO_COLUMN {
		t.next_sequence = t.schema.columns[t.schema.auto_increment_column].sequence.start
	}
	t.indexes = make([]Index, len(t.schema.indexes))
	for _, i in t.schema.indexes {
		t.indexes[i] = Index {
			schema = t.schema.indexes[i],
			unique = t.schema.indexes[i].unique,
			lookup = make(map[string]^Index_Bucket),
		}
		rbtree.init_cmp(&t.indexes[i].tree, index_cmp)
	}
	return t, ERROR_NONE
}

table_destroy :: proc(t: ^Table) {
	if t == nil do return
	shared := t.store != nil && row_store_shared(t.store)
	for _, row in t.rows {
		if t.borrowed {
			// The values belong to the store that this snapshot borrowed from.
			continue
		}
		if shared {
			append(&t.store.pending, row)
			continue
		}
		table_free_row(row)
	}
	delete(t.rows)
	for i in 0 ..< len(t.indexes) {
		rbtree.destroy(&t.indexes[i].tree)
		table_index_map_free(t, i)
	}
	delete(t.indexes)
	// A paged table is closed, not deleted: the caller removes the file when the
	// table is dropped. Dirty frames are dropped with it, which is safe because
	// the log holds every committed change.
	page_rows_close(t.paged)
	virtual.arena_destroy(&t.arena)
	if t.store != nil do row_store_release(t.store)
	free(t)
}

// row_store_shared reports whether anyone but this table can read the values.
row_store_shared :: proc(store: ^Row_Store) -> bool {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	return store.refs > 1
}

row_store_acquire :: proc(store: ^Row_Store) {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	store.refs += 1
}

// row_store_release drops one owner. The last one frees the rows that were
// deferred because a snapshot could still read them.
row_store_release :: proc(store: ^Row_Store) {
	sync.lock(&store.mutex)
	store.refs -= 1
	last := store.refs == 0
	pending := store.pending
	if last do store.pending = nil
	sync.unlock(&store.mutex)
	if !last do return
	for row in pending do table_free_row(row)
	delete(pending)
	free(store)
}

@(private)
table_free_row :: proc(row: Row) {
	free_values(row.values)
	for version in row.versions do free_values(version.values)
	delete(row.versions)
}

// row_values_at returns the values a row showed at `seq`. The second result is
// false when the row did not exist yet or was already deleted at that point.
row_values_at :: proc(row: Row, seq: u64) -> ([]Value, bool) {
	if row.created_seq <= seq && (row.deleted_seq == 0 || row.deleted_seq > seq) {
		return row.values, true
	}
	for i := len(row.versions) - 1; i >= 0; i -= 1 {
		version := row.versions[i]
		if version.created_seq <= seq && (version.deleted_seq == 0 || version.deleted_seq > seq) {
			return version.values, true
		}
	}
	return nil, false
}

// table_prune_versions drops history that no reader at `before_seq` or later
// can ask for, and removes tombstones older than that.
table_prune_versions :: proc(t: ^Table, before_seq: u64) {
	dead := make([dynamic]Row_Id)
	defer delete(dead)
	for id, stored_row in t.rows {
		row := stored_row
		write := 0
		versions := row.versions
		for version in row.versions {
			if version.deleted_seq != 0 && version.deleted_seq <= before_seq {
				free_values(version.values)
				continue
			}
			versions[write] = version
			write += 1
		}
		resize(&versions, write)
		row.versions = versions
		t.rows[id] = row
		if row.deleted_seq != 0 && row.deleted_seq <= before_seq do append(&dead, id)
	}
	for id in dead do map_erase(&t.rows, id)
}

// schema_normalize adds the implicit unique indexes for the primary key and for
// UNIQUE columns.
schema_normalize :: proc(schema: ^Table_Schema) -> Error {
	extra := make([dynamic]Index_Schema)
	defer delete(extra)
	if len(schema.primary_key) > 0 {
		covered := false
		for i in 0 ..< len(schema.indexes) {
			if schema.indexes[i].unique && schema_index_matches(&schema.indexes[i], schema.primary_key) {
				covered = true
				break
			}
		}
		if !covered {
			append(
				&extra,
				Index_Schema {
					name = strings.concatenate({schema.name, "_pkey"}),
					columns = slice.clone(schema.primary_key),
					unique = true,
					implicit = true,
				},
			)
		}
	}
	for col, i in schema.columns {
		if !col.unique do continue
		covered := false
		for j in 0 ..< len(schema.indexes) {
			idx := schema.indexes[j]
			if len(idx.columns) == 1 && idx.columns[0] == i && idx.unique {
				covered = true
				break
			}
		}
		if !covered && len(schema.primary_key) == 1 && schema.primary_key[0] == i {
			covered = true
		}
		if covered do continue
		index_columns := make([]int, 1)
		index_columns[0] = i
		append(
			&extra,
			Index_Schema {
				name = strings.concatenate({schema.name, "_", col.name, "_key"}),
				columns = index_columns,
				unique = true,
				implicit = true,
			},
		)
	}
	if len(extra) > 0 {
		merged := make([]Index_Schema, len(schema.indexes) + len(extra))
		copy(merged, schema.indexes)
		copy(merged[len(schema.indexes):], extra[:])
		schema.indexes = merged
	}
	return ERROR_NONE
}

clone_values :: proc(values: []Value) -> []Value {
	out := make([]Value, len(values))
	for value, i in values {
		out[i] = value_clone(value, context.allocator)
	}
	return out
}

free_values :: proc(values: []Value) {
	for value in values {
		value_deep_free(value, context.allocator)
	}
	delete(values)
}

// --- Key building ----------------------------------------------------------

// index_encode_value writes one index component, folding text the way a
// column-declared collation compares it so the index is case-insensitive too.
@(private)
index_encode_value :: proc(w: ^Byte_Writer, t: ^Table, col: int, values: []Value) {
	value := values[col]
	if col < len(t.schema.columns) && len(t.schema.columns[col].collation) > 0 {
		value = collate_ordered_value(value, t.schema.columns[col].collation)
	}
	value_encode_key(w, value)
}

// index_prefix builds the encoded key of the indexed columns on the heap. The
// caller frees it.
@(private)
index_prefix_temp :: proc(t: ^Table, index: int, values: []Value) -> string {
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for col in t.indexes[index].schema.columns {
		index_encode_value(&w, t, col, values)
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	return string(out)
}

// index_entry_key builds the full key stored in the tree: the prefix, plus the
// row id for a non-unique index. It lives in the table arena.
@(private)
index_entry_key :: proc(t: ^Table, index: int, values: []Value, id: Row_Id) -> string {
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for col in t.indexes[index].schema.columns {
		index_encode_value(&w, t, col, values)
	}
	if !t.indexes[index].unique {
		append_be_u64(&w, u64(id))
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw), t.arena_allocator)
	copy(out, raw)
	return string(out)
}

// --- Hash buckets ----------------------------------------------------------

@(private)
table_index_map_add :: proc(t: ^Table, index: int, values: []Value, id: Row_Id) -> Error {
	if t.indexes[index].schema.algorithm == .Btree do return ERROR_NONE
	probe := index_prefix_temp(t, index, values)
	defer delete(probe)
	if bucket, found := t.indexes[index].lookup[probe]; found {
		for existing in bucket.ids do if existing == id do return ERROR_NONE
		append(&bucket.ids, id)
		return ERROR_NONE
	}
	bucket := new(Index_Bucket)
	bucket.ids = make([dynamic]Row_Id, 0, 1)
	append(&bucket.ids, id)
	t.indexes[index].lookup[strings.clone(probe)] = bucket
	return ERROR_NONE
}

@(private)
table_index_map_remove :: proc(t: ^Table, index: int, values: []Value, id: Row_Id) {
	if t.indexes[index].schema.algorithm == .Btree do return
	probe := index_prefix_temp(t, index, values)
	defer delete(probe)
	bucket, found := t.indexes[index].lookup[probe]
	if !found do return
	found_row := false
	for existing, i in bucket.ids {
		if existing == id {
			unordered_remove(&bucket.ids, i)
			found_row = true
			break
		}
	}
	if !found_row do return
	if len(bucket.ids) == 0 {
		for key in t.indexes[index].lookup {
			if strings.compare(key, probe) == 0 {
				delete_key(&t.indexes[index].lookup, key)
				delete(key)
				break
			}
		}
		delete(bucket.ids)
		free(bucket)
	}
}

@(private)
table_index_map_free :: proc(t: ^Table, index: int) {
	for _, bucket in t.indexes[index].lookup {
		if bucket == nil do continue
		delete(bucket.ids)
		free(bucket)
	}
	for key in t.indexes[index].lookup do delete(key)
	delete(t.indexes[index].lookup)
}

@(private)
value_storage_size :: proc(v: Value) -> int {
	#partial switch v.kind {
	case .Null, .Default:
		return 1
	case .Bool:
		return 2
	case .Int, .Uint, .Float, .Timestamp, .Duration, .Connection:
		return 9
	case .Int128, .Uint128:
		return 17
	case .Uuid:
		return 17
	case .Identity:
		return 33
	case .String:
		return 5 + len(v.s)
	case .Bytes:
		return 5 + len(v.bytes)
	}
	return 16
}

@(private)
index_key_len :: proc(t: ^Table, index: int, values: []Value, id: Row_Id) -> int {
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for col in t.indexes[index].schema.columns {
		index_encode_value(&w, t, col, values)
	}
	if !t.indexes[index].unique {
		append_be_u64(&w, u64(id))
	}
	return len(w.data)
}

// table_memory walks the rows and indexes. It is meant for diagnostics, not for
// the hot path.
table_memory :: proc(t: ^Table) -> Table_Memory {
	memory: Table_Memory
	if t.paged != nil {
		// The values live in the page file and the index keys still live here.
		memory.rows = int(t.paged.rows)
		for _ in t.indexes {
			memory.index_entries += memory.rows
			memory.index_bytes += 40 * memory.rows
		}
		return memory
	}
	for _, row in t.rows {
		memory.rows += 1
		memory.row_bytes += 48 // map entry, slice header and row header
		for value in row.values {
			memory.row_bytes += value_storage_size(value)
		}
	}
	for _, position in t.indexes {
		for _, row in t.rows {
			memory.index_entries += 1
			memory.index_bytes += 40 + index_key_len(t, position, row.values, row.id)
		}
	}
	return memory
}

@(private)
append_be_u64 :: proc(w: ^Byte_Writer, v: u64) {
	append(
		&w.data,
		u8(v >> 56),
		u8(v >> 48),
		u8(v >> 40),
		u8(v >> 32),
		u8(v >> 24),
		u8(v >> 16),
		u8(v >> 8),
		u8(v),
	)
}

// node_next returns the in-order successor of a node.
@(private)
node_next :: proc(n: ^rbtree.Node(string, Row_Id)) -> ^rbtree.Node(string, Row_Id) {
	if n._right != nil {
		next := n._right
		for next._left != nil do next = next._left
		return next
	}
	current := n
	parent := current._parent
	for parent != nil && current == parent._right {
		current = parent
		parent = parent._parent
	}
	return parent
}

// lower_bound returns the first node whose key is >= `key`.
@(private)
lower_bound :: proc(tree: ^Index_Tree, key: string) -> ^rbtree.Node(string, Row_Id) {
	n := tree._root
	best: ^rbtree.Node(string, Row_Id) = nil
	for n != nil {
		if tree._cmp_fn(key, n.key) != .Greater {
			best = n
			n = n._left
		} else {
			n = n._right
		}
	}
	return best
}

// --- Lookup ----------------------------------------------------------------

// table_index_lookup returns every row whose indexed columns equal `values`.
table_index_lookup :: proc(t: ^Table, index: int, values: []Value) -> [dynamic]Row_Id {
	if t.indexes[index].schema.algorithm != .Btree {
		ids := make([dynamic]Row_Id)
		probe := index_prefix_temp(t, index, values)
		defer delete(probe)
		if bucket, found := t.indexes[index].lookup[probe]; found {
			append(&ids, ..bucket.ids[:])
		}
		return ids
	}
	ids := make([dynamic]Row_Id)
	prefix := index_prefix_temp(t, index, values)
	defer delete(prefix)
	node := lower_bound(&t.indexes[index].tree, prefix)
	for node != nil {
		if !strings.has_prefix(node.key, prefix) do break
		append(&ids, node.value)
		node = node_next(node)
	}
	return ids
}

// table_index_scan_prefix returns the rows whose index key starts with
// `prefix`. It is the equality lookup for a non-unique index, whose stored keys
// carry the row id after the tuple.
table_index_scan_prefix :: proc(t: ^Table, index: int, prefix: string) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id)
	tree := &t.indexes[index].tree
	node := lower_bound(tree, prefix)
	for node != nil {
		if !strings.has_prefix(node.key, prefix) do break
		append(&ids, node.value)
		node = node_next(node)
	}
	return ids
}

// table_index_scan returns the rows whose index key falls in [start, end]. An
// empty `start` means "from the beginning"; an empty `end` means "to the end".
// The end comparison ignores the row-id suffix of a non-unique entry.
table_index_scan :: proc(
	t: ^Table,
	index: int,
	start: string,
	end: string,
	inclusive_end: bool,
) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id)
	tree := &t.indexes[index].tree
	node := start == "" ? rbtree.first(tree) : lower_bound(tree, start)
	for node != nil {
		if end != "" {
			order := index_cmp(node.key, end)
			if strings.has_prefix(node.key, end) do order = .Equal
			if order == .Greater do break
			if order == .Equal && !inclusive_end do break
		}
		append(&ids, node.value)
		node = node_next(node)
	}
	return ids
}

table_primary_key_index :: proc(t: ^Table) -> (int, bool) {
	if len(t.schema.primary_key) == 0 do return -1, false
	for i in 0 ..< len(t.indexes) {
		if t.indexes[i].schema.unique &&
		   schema_index_matches(&t.indexes[i].schema, t.schema.primary_key) {
			return i, true
		}
	}
	return -1, false
}

table_find_primary_key :: proc(t: ^Table, pk_values: []Value) -> (Row_Id, bool) {
	idx, ok := table_primary_key_index(t)
	if !ok do return 0, false
	ids := table_index_lookup(t, idx, pk_values)
	defer delete(ids)
	if len(ids) == 0 do return 0, false
	return ids[0], true
}

// table_check_unique verifies that no other row holds the key of `values` in a
// unique index. `ignore` is the row being replaced or updated.
table_check_unique :: proc(t: ^Table, values: []Value, ignore: Row_Id = Row_Id(max(u64))) -> Error {
	for idx, i in t.indexes {
		if !idx.unique do continue
		ids := table_index_lookup(t, i, values)
		defer delete(ids)
		for id in ids {
			if id == ignore do continue
			return errf(
				index_is_primary(t, i) ? .Duplicate_Primary_Key : .Duplicate_Unique,
				"duplicate key for index %s",
				idx.schema.name,
			)
		}
	}
	return ERROR_NONE
}

@(private)
index_is_primary :: proc(t: ^Table, index: int) -> bool {
	if len(t.schema.primary_key) == 0 do return false
	return schema_index_matches(&t.indexes[index].schema, t.schema.primary_key)
}

// --- Maintenance -----------------------------------------------------------

// table_get_row returns one row. A memory table lends its values; a paged table
// decodes them into `alloc`, and the caller owns them.
table_get_row :: proc(t: ^Table, id: Row_Id, alloc: mem.Allocator) -> (Row, bool) {
	if t.paged != nil do return page_rows_get(t.paged, id, alloc)
	row, exists := t.rows[id]
	return row, exists
}

// table_row_exists answers without decoding the values.
table_row_exists :: proc(t: ^Table, id: Row_Id) -> bool {
	if t.paged != nil do return page_rows_contains(t.paged, id)
	_, exists := t.rows[id]
	return exists
}

@(private)
table_touch_sequence :: proc(t: ^Table, values: []Value) {
	if t.schema.auto_increment_column == NO_COLUMN do return
	column := t.schema.auto_increment_column
	if number, ok := value_to_i64(values[column]); ok {
		next := number + t.schema.columns[column].sequence.increment
		if next > t.next_sequence do t.next_sequence = next
	}
}

@(private)
table_index_add_all :: proc(t: ^Table, values: []Value, id: Row_Id) -> Error {
	for _, i in t.indexes {
		key := index_entry_key(t, i, values, id)
		_, _, insert_err := rbtree.upsert(&t.indexes[i].tree, key, id)
		if insert_err != nil {
			return errf(.Out_Of_Memory, "cannot grow index %s", t.indexes[i].schema.name)
		}
		if map_err := table_index_map_add(t, i, values, id); map_err.kind != .None {
			return map_err
		}
	}
	return ERROR_NONE
}

@(private)
table_index_remove_all :: proc(t: ^Table, values: []Value, id: Row_Id) {
	for _, i in t.indexes {
		key := index_entry_key(t, i, values, id)
		rbtree.remove_key(&t.indexes[i].tree, key)
		table_index_map_remove(t, i, values, id)
	}
}

table_insert :: proc(t: ^Table, id: Row_Id, values: []Value) -> Error {
	if t.paged != nil {
		if page_rows_contains(t.paged, id) {
			return errf(.Internal, "row id %d already exists in table %s", u64(id), t.schema.name)
		}
		if err := table_check_unique(t, values); err.kind != .None {
			return err
		}
		if put_err := page_rows_put(t.paged, id, values); put_err.kind != .None {
			return put_err
		}
		table_touch_sequence(t, values)
		return table_index_add_all(t, values, id)
	}
	if _, exists := t.rows[id]; exists {
		return errf(.Internal, "row id %d already exists in table %s", u64(id), t.schema.name)
	}
	if err := table_check_unique(t, values); err.kind != .None {
		return err
	}
	stored := clone_values(values)
	if t.schema.auto_increment_column != NO_COLUMN {
		column := t.schema.auto_increment_column
		if number, ok := value_to_i64(stored[column]); ok {
			next := number + t.schema.columns[column].sequence.increment
			if next > t.next_sequence do t.next_sequence = next
		}
	}
	t.rows[id] = Row{id = id, values = stored, created_seq = t.apply_seq}
	for _, i in t.indexes {
		key := index_entry_key(t, i, stored, id)
		_, _, insert_err := rbtree.upsert(&t.indexes[i].tree, key, id)
		if insert_err != nil {
			return errf(.Out_Of_Memory, "cannot grow index %s", t.indexes[i].schema.name)
		}
		if map_err := table_index_map_add(t, i, stored, id); map_err.kind != .None {
			return map_err
		}
	}
	return ERROR_NONE
}

table_update :: proc(t: ^Table, id: Row_Id, values: []Value) -> Error {
	if t.paged != nil {
		old, exists := page_rows_get(t.paged, id, context.allocator)
		if !exists {
			return errf(.Internal, "row id %d is missing from table %s", u64(id), t.schema.name)
		}
		defer free_values(old.values)
		if err := table_check_unique(t, values, id); err.kind != .None {
			return err
		}
		table_index_remove_all(t, old.values, id)
		if put_err := page_rows_put(t.paged, id, values); put_err.kind != .None {
			return put_err
		}
		table_touch_sequence(t, values)
		return table_index_add_all(t, values, id)
	}
	row, exists := t.rows[id]
	if !exists {
		return errf(.Internal, "row id %d is missing from table %s", u64(id), t.schema.name)
	}
	if err := table_check_unique(t, values, id); err.kind != .None {
		return err
	}
	for _, i in t.indexes {
		key := index_entry_key(t, i, row.values, id)
		rbtree.remove_key(&t.indexes[i].tree, key)
		table_index_map_remove(t, i, row.values, id)
	}
	// The current values become a version, so a reader that started earlier
	// keeps its view.
	append(&row.versions, Row_Version {
		values = row.values,
		created_seq = row.created_seq,
		deleted_seq = t.apply_seq,
	})
	stored := clone_values(values)
	if t.schema.auto_increment_column != NO_COLUMN {
		column := t.schema.auto_increment_column
		if number, ok := value_to_i64(stored[column]); ok {
			next := number + t.schema.columns[column].sequence.increment
			if next > t.next_sequence do t.next_sequence = next
		}
	}
	t.rows[id] = Row{
		id = id,
		values = stored,
		created_seq = t.apply_seq,
		versions = row.versions,
	}
	for _, i in t.indexes {
		key := index_entry_key(t, i, stored, id)
		_, _, insert_err := rbtree.upsert(&t.indexes[i].tree, key, id)
		if insert_err != nil {
			return errf(.Out_Of_Memory, "cannot grow index %s", t.indexes[i].schema.name)
		}
		if map_err := table_index_map_add(t, i, stored, id); map_err.kind != .None {
			return map_err
		}
	}
	return ERROR_NONE
}

table_delete :: proc(t: ^Table, id: Row_Id) -> bool {
	if t.paged != nil {
		if !page_rows_contains(t.paged, id) do return false
		old, decoded := page_rows_get(t.paged, id, context.allocator)
		if !decoded do return false
		defer free_values(old.values)
		table_index_remove_all(t, old.values, id)
		return page_rows_delete(t.paged, id)
	}
	row, exists := t.rows[id]
	if !exists do return false
	for _, i in t.indexes {
		key := index_entry_key(t, i, row.values, id)
		rbtree.remove_key(&t.indexes[i].tree, key)
		table_index_map_remove(t, i, row.values, id)
	}
	// Tombstone instead of erasing: the live values stay owned by the row and are
	// visible to snapshots taken before this sequence, so no extra version is
	// recorded (that would share the values and double free them).
	row.deleted_seq = t.apply_seq
	t.rows[id] = row
	return true
}

table_truncate :: proc(t: ^Table) {
	if t.paged != nil {
		_ = page_rows_truncate(t.paged)
		for _, i in t.indexes {
			rbtree.destroy(&t.indexes[i].tree, false)
			rbtree.init_cmp(&t.indexes[i].tree, index_cmp)
			table_index_map_free(t, i)
			t.indexes[i].lookup = make(map[string]^Index_Bucket)
		}
		return
	}
	for _, row in t.rows {
		// Truncating while a snapshot reads the same values cannot free them: they
		// are handed to the shared store, which frees them when the last reader is
		// gone.
		if t.store != nil && row_store_shared(t.store) {
			append(&t.store.pending, row)
			continue
		}
		table_free_row(row)
	}
	clear(&t.rows)
	for _, i in t.indexes {
		rbtree.destroy(&t.indexes[i].tree, false)
		rbtree.init_cmp(&t.indexes[i].tree, index_cmp)
		table_index_map_free(t, i)
		t.indexes[i].lookup = make(map[string]^Index_Bucket)
	}
}

// table_insert_borrowed stores a row whose values belong to another table. The
// indexes are built as usual; the values are not cloned.
table_insert_borrowed :: proc(t: ^Table, id: Row_Id, values: []Value) -> Error {
	if _, exists := t.rows[id]; exists do return errf(.Internal, "row id %d already exists", u64(id))
	t.rows[id] = Row{id = id, values = values, created_seq = t.apply_seq}
	for _, i in t.indexes {
		key := index_entry_key(t, i, values, id)
		_, _, insert_err := rbtree.upsert(&t.indexes[i].tree, key, id)
		if insert_err != nil do return errf(.Out_Of_Memory, "cannot grow index %s", t.indexes[i].schema.name)
		if map_err := table_index_map_add(t, i, values, id); map_err.kind != .None do return map_err
	}
	return ERROR_NONE
}

// table_snapshot copies a table for a read transaction: structure and indexes are
// its own, the values are borrowed from the source through a shared Row_Store.
// That turns freezing into one map build and index fill per table instead of a
// deep copy of every value, which is what made the first read of a large database
// slow. The source defers freeing values while a snapshot that shares them lives.
table_snapshot :: proc(source: ^Table) -> ^Table {
	// A paged table can be copied, but the copy has to hold the values: it has no
	// page file to read them from. Reads of a store with pages take the lock for
	// the whole transaction instead, so this path is only a safety net.
	if source.paged != nil {
		schema := source.schema
		clone, create_err := table_create(&schema)
		if create_err.kind != .None do return nil
		rows := make([dynamic]Row)
		table_collect(source, &rows, max(u64))
		defer table_collect_release(source, &rows)
		for row in rows {
			if insert_err := table_insert(clone, row.id, row.values); insert_err.kind != .None {
				table_destroy(clone)
				return nil
			}
		}
		clone.next_row_id = source.next_row_id
		clone.next_sequence = source.next_sequence
		return clone
	}
	schema := source.schema
	clone, create_err := table_create(&schema)
	if create_err.kind != .None do return nil
	// table_create opened its own store; hand it to the source's instead.
	row_store_release(clone.store)
	clone.store = source.store
	row_store_acquire(clone.store)
	clone.borrowed = true
	clone.next_row_id = source.next_row_id
	clone.next_sequence = source.next_sequence
	for _, row in source.rows {
		if row.deleted_seq != 0 do continue
		_ = table_insert_borrowed(clone, row.id, row.values)
	}
	return clone
}

table_row_count :: proc(t: ^Table) -> int {
	if t.paged != nil do return int(t.paged.rows)
	live := 0
	for _, row in t.rows {
		if row.deleted_seq == 0 do live += 1
	}
	return live
}

// paged_row_put appends one decoded row for table_collect. The values are the
// ones page_rows_scan decoded into the collect context's allocator.
@(private)
paged_collect_visit :: proc(ctx: rawptr, row: Row) -> bool {
	collect := cast(^Paged_Collect_Ctx)ctx
	append(collect.out, Row{id = row.id, values = row.values})
	return true
}

@(private)
Paged_Collect_Ctx :: struct {
	out: ^[dynamic]Row,
}

// table_collect fills `out` with the visible rows, ordered by row id. A memory
// table hands out its own values; a paged table decodes them into `alloc`, so the
// caller owns them (table_collect_release frees a paged collect).
table_collect :: proc(
	t: ^Table,
	out: ^[dynamic]Row,
	seq: u64 = max(u64),
	alloc: mem.Allocator = context.allocator,
) {
	if t.paged != nil {
		ctx := Paged_Collect_Ctx{out = out}
		_ = page_rows_scan(t.paged, alloc, &ctx, paged_collect_visit)
		slice.sort_by(out[:], proc(a, b: Row) -> bool {
			return u64(a.id) < u64(b.id)
		})
		return
	}
	reserve(out, len(out) + len(t.rows))
	for _, row in t.rows {
		values, visible := row_values_at(row, seq)
		if !visible do continue
		append(out, Row{id = row.id, values = values})
	}
	slice.sort_by(out[:], proc(a, b: Row) -> bool {
		return u64(a.id) < u64(b.id)
	})
}

// table_max_int returns the largest Int value in one column, or 0 when the
// column holds none. It answers the INTEGER PRIMARY KEY assignment for both
// backends: a paged table has no map to walk, so the pages are streamed and no
// value is copied.
table_max_int :: proc(t: ^Table, column: int) -> i64 {
	best := i64(0)
	if t.paged != nil {
		ctx := Max_Column_Ctx{column = column}
		_ = page_rows_each(t.paged, &ctx, max_column_visit)
		return ctx.best
	}
	for _, row in t.rows {
		if column >= len(row.values) do continue
		if row.values[column].kind == .Int && row.values[column].i > best {
			best = row.values[column].i
		}
	}
	return best
}

@(private)
Max_Column_Ctx :: struct {
	column: int,
	best:   i64,
}

@(private)
max_column_visit :: proc(ctx: rawptr, row: Row) -> bool {
	state := cast(^Max_Column_Ctx)ctx
	if state.column < len(row.values) && row.values[state.column].kind == .Int {
		if row.values[state.column].i > state.best do state.best = row.values[state.column].i
	}
	return true
}

// table_collect_release frees a collect from a paged table. A memory table's
// values belong to the table, so only the list goes.
table_collect_release :: proc(t: ^Table, rows: ^[dynamic]Row) {
	if t.paged != nil {
		for row in rows^ do free_values(row.values)
	}
	delete(rows^)
}

// alter_row_values lays one stored row out for the schema an ALTER produced.
// When the column count is unchanged the statement is a rename, and only
// positions identify the columns: matching by name would find nothing and turn
// every value into its default. An added or dropped column changes the count, so
// names decide there, which is what makes the surviving columns keep their data.
alter_row_values :: proc(
	old: ^Table_Schema,
	next: Table_Schema,
	values: []Value,
	alloc: mem.Allocator,
) -> []Value {
	out := make([]Value, len(next.columns), alloc)
	same_width := len(old.columns) == len(next.columns)
	for column, i in next.columns {
		old_index := -1
		if same_width {
			old_index = i
		} else {
			if at, found := schema_column_index(old, column.name); found do old_index = at
		}
		if old_index >= 0 && old_index < len(values) {
			out[i] = values[old_index]
		} else {
			out[i] = column.has_default ? column.default_value : value_null()
		}
	}
	return out
}

// --- Index maintenance for DDL ---------------------------------------------

// table_add_index creates a new index over the existing rows.
table_add_index :: proc(t: ^Table, index: Index_Schema) -> Error {
	if len(index.name) == 0 {
		return errf(.Invalid_Argument, "an index needs a name")
	}
	for existing in t.schema.indexes {
		if strings.equal_fold(existing.name, index.name) {
			return errf(.Index_Exists, "index %s already exists", index.name)
		}
	}
	for col in index.columns {
		if col < 0 || col >= len(t.schema.columns) {
			return errf(.Invalid_Argument, "index %s refers to a missing column", index.name)
		}
	}
	if len(index.columns) == 0 {
		return errf(.Invalid_Argument, "index %s has no columns", index.name)
	}
	stored := schema_index_copy(index, t.arena_allocator)
	merged := make([]Index_Schema, len(t.schema.indexes) + 1, t.arena_allocator)
	copy(merged, t.schema.indexes)
	merged[len(t.schema.indexes)] = stored
	t.schema.indexes = merged
	grown := make([]Index, len(t.indexes) + 1)
	copy(grown, t.indexes)
	delete(t.indexes)
	t.indexes = grown
	position := len(t.indexes) - 1
	t.indexes[position] = Index {
		schema = stored,
		unique = stored.unique,
		lookup = make(map[string]^Index_Bucket),
	}
	rbtree.init_cmp(&t.indexes[position].tree, index_cmp)
	if t.paged != nil {
		ctx := Add_Index_Ctx{position = position}
		if scan_err := page_rows_each(t.paged, &ctx, add_index_visit); scan_err.kind != .None {
			return scan_err
		}
		return ERROR_NONE
	}
	for _, row in t.rows {
		key := index_entry_key(t, position, row.values, row.id)
		if _, _, insert_err := rbtree.upsert(&t.indexes[position].tree, key, row.id); insert_err != nil {
			return errf(.Out_Of_Memory, "cannot grow index %s", index.name)
		}
		if map_err := table_index_map_add(t, position, row.values, row.id); map_err.kind != .None {
			return map_err
		}
	}
	return ERROR_NONE
}

@(private)
Add_Index_Ctx :: struct {
	table:    ^Table,
	position: int,
	err:      Error,
}

@(private)
add_index_visit :: proc(ctx: rawptr, row: Row) -> bool {
	add := cast(^Add_Index_Ctx)ctx
	key := index_entry_key(add.table, add.position, row.values, row.id)
	if _, _, insert_err := rbtree.upsert(&add.table.indexes[add.position].tree, key, row.id); insert_err != nil {
		add.err = errf(.Out_Of_Memory, "cannot grow index")
		return false
	}
	if map_err := table_index_map_add(add.table, add.position, row.values, row.id); map_err.kind != .None {
		add.err = map_err
		return false
	}
	return true
}

// table_drop_index removes an index. Implicit indexes (the primary key and
// UNIQUE columns) cannot be dropped.
table_drop_index :: proc(t: ^Table, name: string) -> Error {
	for index, i in t.indexes {
		if !strings.equal_fold(index.schema.name, name) do continue
		if index.schema.implicit {
			return errf(.Invalid_Argument, "index %s comes from a constraint and cannot be dropped", name)
		}
		rbtree.destroy(&t.indexes[i].tree)
		table_index_map_free(t, i)
		shorter := make([]Index, len(t.indexes) - 1)
		copy(shorter[:i], t.indexes[:i])
		copy(shorter[i:], t.indexes[i + 1:])
		delete(t.indexes)
		t.indexes = shorter
		remaining := make([]Index_Schema, len(t.schema.indexes) - 1, t.arena_allocator)
		write := 0
		for existing in t.schema.indexes {
			if strings.equal_fold(existing.name, name) do continue
			remaining[write] = existing
			write += 1
		}
		t.schema.indexes = remaining
		return ERROR_NONE
	}
	return errf(.Index_Not_Found, "index %s does not exist in %s", name, t.schema.name)
}

@(private)
schema_index_copy :: proc(index: Index_Schema, alloc: mem.Allocator) -> Index_Schema {
	out := index
	out.name = strings.clone(index.name, alloc)
	out.columns = slice.clone(index.columns, alloc)
	return out
}
