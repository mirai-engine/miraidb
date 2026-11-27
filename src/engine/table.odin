package engine

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:strings"
import "core:slice"

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

// Index_Slot is what one key of a memory index holds: the rows under it, the
// lowest id inline and the others ascending in `more`, which stays empty (and
// allocates nothing) for a key one row has. A key held one node per row before
// (the row id appended to it), so an equality lookup that met 256 rows walked
// 256 nodes of the tree; it walks one now and copies its ids (R2).
Index_Slot :: struct {
	first: Row_Id,
	more:  [dynamic]Row_Id,
}

// index_slot_append adds a slot's rows to `ids`, ascending.
@(private)
index_slot_append :: proc(ids: ^[dynamic]Row_Id, slot: Index_Slot) {
	append(ids, slot.first)
	if len(slot.more) > 0 do append(ids, ..slot.more[:])
}

// index_slot_add puts `id` among a slot's rows, keeping them ascending. A row
// already there is left alone.
@(private)
index_slot_add :: proc(slot: ^Index_Slot, id: Row_Id) {
	if id == slot.first do return
	if id < slot.first {
		inject_at(&slot.more, 0, slot.first)
		slot.first = id
		return
	}
	n := len(slot.more)
	if n == 0 || slot.more[n - 1] < id {
		append(&slot.more, id)
		return
	}
	low, high := 0, n
	for low < high {
		middle := (low + high) / 2
		if slot.more[middle] < id {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low < n && slot.more[low] == id do return
	inject_at(&slot.more, low, id)
}

// index_slot_remove takes `id` out of a slot and answers whether the slot is now
// empty.
@(private)
index_slot_remove :: proc(slot: ^Index_Slot, id: Row_Id) -> (empty: bool) {
	if id == slot.first {
		if len(slot.more) == 0 do return true
		slot.first = slot.more[0]
		index_ids_remove_at(&slot.more, 0)
		return false
	}
	for other, i in slot.more {
		if other == id {
			index_ids_remove_at(&slot.more, i)
			break
		}
	}
	return false
}

// index_ids_remove_at removes one id keeping the order (the engine's own
// ordered_remove, of the paged index, hides the builtin one here).
@(private)
index_ids_remove_at :: proc(ids: ^[dynamic]Row_Id, at: int) {
	copy(ids[at:], ids[at + 1:])
	resize(ids, len(ids) - 1)
}

// index_tree_free lets go of an index's tree: the nodes no other table shares
// go, with the row lists of their slots.
@(private)
index_tree_free :: proc(index: ^Index) {
	int_keys_destroy(&index.ints)
	ib_free(&index.tree)
}

// index_tree_init gives a memory index an empty tree.
@(private)
index_tree_init :: proc(index: ^Index) {
	index.tree = {}
	index.int_keyed = index_int_eligible(index)
}

// index_tree_key encodes the key a memory index files `values` under: the indexed
// columns alone, into the table's scratch buffer (overwritten by the next key).
@(private)
index_tree_key :: proc(t: ^Table, index: int, values: []Value) -> (key: string, has_null: bool) {
	w := Byte_Writer{data = t.key_scratch}
	clear(&w.data)
	has_null = index_encode_parts(&w, t, index, values)
	t.key_scratch = w.data
	return string(w.data[:]), has_null
}

// Index is one ordered index. The key is the order-preserving encoding of the
// indexed columns. A unique index stores the key alone; a non-unique index
// appends the row id, so every entry is distinct and range scans stay ordered.
Index :: struct {
	schema: Index_Schema,
	unique: bool,
	// tree is the memory index, shared with the tables readers keep (Index_Tree).
	tree:   Index_Tree,
	// lookup is the equality map for HASH and DIRECT indexes. The tree is still
	// maintained so ordering, range scans and the primary-key path keep working.
	lookup: map[string]^Index_Bucket,
	// pages holds the same keys in a B+tree of pages. It is set for the indexes
	// of a paged table: the keys then live in the index file and the pool bounds
	// what a lookup costs, instead of every key staying in RAM.
	pages: ^Ordered_Pages,
	// exprs holds the parsed WHERE and key expressions of a partial or
	// expression index; nil for an index over plain columns.
	exprs: ^Index_Exprs,
	// ints files, beside the tree, the row that holds each integer key of a
	// UNIQUE index over one plain column (index_int_key), when the index lives in
	// memory. The unique check and an equality lookup of an integer are then one
	// hash probe, where a descent of the tree met a node per level (R2). It holds
	// exactly the rows whose value has an integer key; the tree still holds every
	// row and answers everything else. An index that cannot grow it drops it and
	// answers from the tree (`int_keyed` false).
	ints:      Int_Keys,
	int_keyed: bool,
}

// index_int_key is a value's key among the integer keys of an index, in the key
// spaces value_encode_key gives it: an unsigned integer in its own, and a signed
// integer or a real that holds one exactly in the space numbers share, where 5
// and 5.0 are one key. Two values have the same integer key exactly when they
// have the same encoded key. Any other value has none.
@(private)
index_int_key :: proc(v: Value) -> (key: [2]u64, ok: bool) {
	#partial switch v.kind {
	case .Uint:
		return {1, v.u}, true
	case .Int:
		return {0, u64(v.i)}, true
	case .Float:
		// -0.0 is 0, as in the encoded key; NaN fails the range test.
		if v.f >= -9223372036854775808.0 && v.f < 9223372036854775808.0 && f64(i64(v.f)) == v.f {
			return {0, u64(i64(v.f))}, true
		}
	}
	return {}, false
}

// index_int_eligible reports an index that files integer keys: a UNIQUE index
// over one plain column.
index_int_eligible :: proc(index: ^Index) -> bool {
	return index.unique && index_is_plain(index.schema) && len(index.schema.columns) == 1 && index.schema.columns[0] >= 0
}

// index_int_holder answers, for an index that files integer keys, which row
// holds the key of `values`. `known` is false when the index or the value has no
// integer key, and the tree has to answer.
@(private)
index_int_holder :: proc(t: ^Table, index: int, values: []Value) -> (id: Row_Id, held: bool, known: bool) {
	idx := &t.indexes[index]
	if !idx.int_keyed || idx.pages != nil do return
	column := idx.schema.columns[0]
	if column < 0 || column >= len(values) do return
	key, ok := index_int_key(values[column])
	if !ok do return
	id, held = int_keys_get(&idx.ints, key)
	return id, held, true
}

// index_ints_put files a row under its integer key. When the map cannot grow,
// the index gives it up and answers from its tree.
@(private)
index_ints_put :: proc(index: ^Index, values: []Value, id: Row_Id) {
	key, ok := index_int_key(values[index.schema.columns[0]])
	if !ok do return
	if int_keys_put(&index.ints, key, id) == nil do return
	int_keys_destroy(&index.ints)
	index.int_keyed = false
}

// index_ints_remove takes a row's integer key out, when the row holds it.
@(private)
index_ints_remove :: proc(index: ^Index, values: []Value, id: Row_Id) {
	key, ok := index_int_key(values[index.schema.columns[0]])
	if !ok do return
	int_keys_remove(&index.ints, key, id)
}

// index_ints_clone copies the integer keys of an index; a copy that cannot be
// made leaves the target answering from its tree.
@(private)
index_ints_clone :: proc(source: ^Index, target: ^Index) {
	int_keys_destroy(&target.ints)
	target.int_keyed = source.int_keyed
	if !target.int_keyed || int_keys_len(&source.ints) == 0 do return
	// One copy of the slots, where an Odin map filed every key again (Int_Keys).
	if int_keys_clone(&target.ints, &source.ints, context.allocator) != nil {
		int_keys_destroy(&target.ints)
		target.int_keyed = false
	}
}

// Index_Exprs is what a partial or expression index evaluates for each row. The
// values an evaluation produces live in `scratch` only until the key is encoded;
// the mutex keeps two readers of one table (an integrity check) apart.
Index_Exprs :: struct {
	where_expr: ^Expr,
	parts:      []^Expr,
	queries:    [dynamic]Query,
	scratch:    virtual.Arena,
	mutex:      sync.Mutex,
}

// index_exprs_make parses a partial or expression index's texts once, when the
// index is built in memory. A plain index needs none and gets nil.
index_exprs_make :: proc(schema: Index_Schema) -> (^Index_Exprs, Error) {
	if index_is_plain(schema) do return nil, ERROR_NONE
	exprs := new(Index_Exprs)
	if arena_err := virtual.arena_init_growing(&exprs.scratch); arena_err != .None {
		free(exprs)
		return nil, errf(.Out_Of_Memory, "cannot create the scratch of index %s", schema.name)
	}
	if len(schema.where_sql) > 0 {
		query, expr, err := sql_parse_expression(schema.where_sql)
		if err.kind != .None {
			index_exprs_destroy(exprs)
			return nil, err
		}
		append(&exprs.queries, query)
		exprs.where_expr = expr
	}
	exprs.parts = make([]^Expr, len(schema.exprs))
	for text, i in schema.exprs {
		if len(text) == 0 do continue
		query, expr, err := sql_parse_expression(text)
		if err.kind != .None {
			index_exprs_destroy(exprs)
			return nil, err
		}
		append(&exprs.queries, query)
		exprs.parts[i] = expr
	}
	return exprs, ERROR_NONE
}

index_exprs_destroy :: proc(exprs: ^Index_Exprs) {
	if exprs == nil do return
	for &query in exprs.queries do query_destroy(&query)
	delete(exprs.queries)
	delete(exprs.parts)
	virtual.arena_destroy(&exprs.scratch)
	free(exprs)
}

// index_eval evaluates one expression of an index against a row. The answer is
// in the index's scratch arena: the caller encodes it before the scratch is
// emptied. An error makes the value NULL here; the write path asks
// index_validate_row first, so a row whose expression fails never gets this far.
@(private)
index_eval :: proc(t: ^Table, exprs: ^Index_Exprs, expr: ^Expr, values: []Value) -> Value {
	sources: [1]Source
	sources[0] = Source{table = t, row = Row{values = values}}
	// The program's functions are the running statement's store's (a commit
	// keeps that scope, tx_commit): without them a call to one answered NULL
	// for every row, its index held NULL keys, a UNIQUE one enforced nothing,
	// and SQLite found the file's index missing every row (D24).
	ctx := eval_context(Eval_Ctx{sources = sources[:], index_store = statement_store()})
	context.allocator = arena_allocator_guarded(&exprs.scratch)
	value, err := eval_expr(&ctx, expr)
	if err.kind != .None {
		error_free(&err)
		return value_null()
	}
	return value
}

// index_row_included reports whether a row belongs to an index: always for a
// full index, and for a partial one when its WHERE is true.
index_row_included :: proc(t: ^Table, index: int, values: []Value) -> bool {
	exprs := t.indexes[index].exprs
	if exprs == nil || exprs.where_expr == nil do return true
	sync.mutex_lock(&exprs.mutex)
	defer sync.mutex_unlock(&exprs.mutex)
	defer virtual.arena_free_all(&exprs.scratch)
	value := index_eval(t, exprs, exprs.where_expr, values)
	return value.kind != .Null && value_is_truthy(value)
}

// index_encode_parts writes the key of a row for one index: each plain column
// folded by its collation, each expression by the COLLATE it carries. It reports
// whether a part is NULL: such a key constrains nothing in a UNIQUE index, since
// SQL holds no two NULLs equal.
index_encode_parts :: proc(w: ^Byte_Writer, t: ^Table, index: int, values: []Value) -> (has_null: bool) {
	exprs := t.indexes[index].exprs
	if exprs == nil || len(exprs.parts) == 0 {
		for col in t.indexes[index].schema.columns {
			if values[col].kind == .Null do has_null = true
			index_encode_value(w, t, col, values)
		}
		return
	}
	sync.mutex_lock(&exprs.mutex)
	defer sync.mutex_unlock(&exprs.mutex)
	defer virtual.arena_free_all(&exprs.scratch)
	for col, i in t.indexes[index].schema.columns {
		if i >= len(exprs.parts) || exprs.parts[i] == nil {
			if values[col].kind == .Null do has_null = true
			index_encode_value(w, t, col, values)
			continue
		}
		value := index_eval(t, exprs, exprs.parts[i], values)
		if value.kind == .Null do has_null = true
		if collation, has := collate_name(exprs.parts[i]); has && len(collation) > 0 {
			value = collate_ordered_value(value, collation)
		}
		value_encode_key(w, value)
	}
	return
}

// index_part_values gives the key parts of a row for an index as values, each
// expression evaluated and cloned into `alloc`: what the `.sqlite` export writes
// into an index b-tree, where SQLite reads them back.
index_part_values :: proc(t: ^Table, index: int, values: []Value, alloc: mem.Allocator) -> []Value {
	columns := t.indexes[index].schema.columns
	out := make([]Value, len(columns), alloc)
	exprs := t.indexes[index].exprs
	for col, i in columns {
		if exprs == nil || i >= len(exprs.parts) || exprs.parts[i] == nil {
			if col >= 0 && col < len(values) do out[i] = values[col]
			continue
		}
		sync.mutex_lock(&exprs.mutex)
		value := index_eval(t, exprs, exprs.parts[i], values)
		out[i] = value_clone(value, alloc)
		virtual.arena_free_all(&exprs.scratch)
		sync.mutex_unlock(&exprs.mutex)
	}
	return out
}

// index_parts_text names an index's key parts, comma separated, in `alloc`: a
// column by its name and an expression part by its text. (Both readers of it
// concatenated the names and lost every intermediate string, and indexed the
// columns by an expression part's NO_COLUMN.)
index_parts_text :: proc(t: ^Table, index: Index_Schema, alloc: mem.Allocator) -> string {
	parts := make([]string, len(index.columns), context.temp_allocator)
	for column, i in index.columns {
		switch {
		case column >= 0 && column < len(t.schema.columns):
			parts[i] = t.schema.columns[column].name
		case i < len(index.exprs):
			parts[i] = index.exprs[i]
		}
	}
	return strings.join(parts, ", ", alloc)
}

// table_index_position finds an index of the table by name.
table_index_position :: proc(t: ^Table, name: string) -> (int, bool) {
	for index, i in t.indexes do if index.schema.name == name do return i, true
	return -1, false
}

// index_key_has_null reports whether a row's key for an index has a NULL part.
// A plain index answers from the row's columns; only an expression part has to
// be evaluated, and so encoded.
index_key_has_null :: proc(t: ^Table, index: int, values: []Value) -> bool {
	exprs := t.indexes[index].exprs
	if exprs == nil || len(exprs.parts) == 0 {
		for col in t.indexes[index].schema.columns do if values[col].kind == .Null do return true
		return false
	}
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	return index_encode_parts(&w, t, index, values)
}

// index_key_unchanged reports whether two versions of a row have the same key
// under a plain index: every key column holds an identical value, so the encoded
// key is the same and the index already files the row under it. An index with an
// expression or a WHERE answers false, since its key is not read from the
// columns alone.
index_key_unchanged :: proc(t: ^Table, index: int, old, new: []Value) -> bool {
	if t.indexes[index].exprs != nil do return false
	for col in t.indexes[index].schema.columns {
		if col < 0 || col >= len(old) || col >= len(new) do return false
		if !value_identical(old[col], new[col]) do return false
	}
	return true
}

// index_validate_row evaluates every WHERE and key expression of the table's
// indexes for a row about to be written, so an expression that fails (a type it
// cannot take) is the statement's error instead of a NULL key at apply time.
index_validate_row :: proc(tx: ^Tx, t: ^Table, values: []Value) -> Error {
	for index in t.indexes {
		if index.exprs == nil do continue
		sources: [1]Source
		sources[0] = Source{table = t, row = Row{values = values}}
		ctx := eval_context(Eval_Ctx{tx = tx, sources = sources[:]})
		if index.exprs.where_expr != nil {
			if _, err := eval_expr(&ctx, index.exprs.where_expr); err.kind != .None do return err
		}
		for part in index.exprs.parts {
			if part == nil do continue
			if _, err := eval_expr(&ctx, part); err.kind != .None do return err
		}
	}
	return ERROR_NONE
}

// table_index_put_row adds a row to one index, when it belongs there.
@(private)
table_index_put_row :: proc(t: ^Table, index: int, values: []Value, id: Row_Id) -> Error {
	if !index_row_included(t, index, values) do return ERROR_NONE
	if t.indexes[index].pages != nil {
		key := index_entry_key(t, index, values, id)
		if put_err := table_index_put(t, index, key, id); put_err.kind != .None do return put_err
	} else {
		key, _ := index_tree_key(t, index, values)
		// One descent files the key or finds it: a new key is copied into the key
		// store at its exact length, and a row joins the slot of a key others
		// hold.
		slot, inserted, insert_err := ib_upsert(&t.indexes[index].tree, key, t.keys.allocator)
		if insert_err != nil do return errf(.Out_Of_Memory, "cannot grow index %s", t.indexes[index].schema.name)
		if inserted {
			slot^ = Index_Slot{first = id}
		} else {
			index_slot_add(slot, id)
		}
		if t.indexes[index].int_keyed do index_ints_put(&t.indexes[index], values, id)
	}
	return table_index_map_add(t, index, values, id)
}

// table_index_remove_row takes a row out of one index, when it was there.
@(private)
table_index_remove_row :: proc(t: ^Table, index: int, values: []Value, id: Row_Id) {
	if !index_row_included(t, index, values) do return
	if t.indexes[index].pages != nil {
		key := index_entry_key(t, index, values, id)
		table_index_remove_key(t, index, key)
	} else {
		key, _ := index_tree_key(t, index, values)
		// A failed copy leaves the row filed; the next write that reaches the key
		// copies it again.
		_ = ib_remove_id(&t.indexes[index].tree, key, id)
		if t.indexes[index].int_keyed do index_ints_remove(&t.indexes[index], values, id)
	}
	table_index_map_remove(t, index, values, id)
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
	// rows holds every row of a memory table, tombstones included, in ascending id
	// order (R1), in blocks a reader's table shares with the copy a commit writes
	// (Row_Blocks, R7). A scan walks the blocks; a lookup by id tries the place
	// the id would have if no id were missing, then searches (rows_find).
	rows:            Row_Blocks,
	// history holds the id of every row that keeps a version or is a tombstone,
	// once each: the only rows a prune has anything to drop from (R3). A prune
	// walked every row of every table after each statement; it now visits these.
	history:         [dynamic]Row_Id,
	// prune_visited counts the rows prunes of this table looked at, so a test can
	// tell a prune that visited only what changed from one that walked the table.
	prune_visited:   u64,
	// key_scratch is where index_entry_key encodes a key before copying it into
	// the arena at its exact length. Every caller mutates the table, which only
	// the writer (or the transaction that owns a private table) does, so one
	// buffer per table is never used twice at once.
	key_scratch:     [dynamic]u8,
	next_row_id:     u64,
	next_sequence:   i64,
	// next_int_key is the highest value an INTEGER PRIMARY KEY has held in a
	// paged table. It is an upper bound that keeps a bulk load linear; a memory
	// table keeps computing max+1 over its rows, which is what SQLite does.
	next_int_key:    i64,
	indexes:         []Index,
	// apply_seq is the commit sequence of the change being applied, stamped on
	// the versions it creates.
	apply_seq:       u64,
	// shared_before is the sequence of the commit that last copied this table
	// for a reader (table_cow_clone): values stored before it may be a reader's
	// too, so the table does not free them while the store is shared.
	shared_before:   u64,
	// arena_allocator is the table's arena (the schema, the index keys), kept
	// by `keys` and shared with every table that shares the trees (Key_Store).
	arena_allocator: mem.Allocator,
	keys:            ^Key_Store,
	store:           ^Row_Store,
	// refs counts the owners of this table object: the store, and every read
	// transaction that opened while it was current. A commit that has to change
	// a table with more than one owner copies it first (table_cow_clone), so a
	// reader always reads a table nobody writes.
	refs:            int,
	// borrowed is true for a table whose rows belong to someone else: it reads
	// the values and must not free them.
	borrowed:        bool,
	// index_dir, index_vfs and index_frames are what an index created after the
	// table needs to open its own page file. A table without them (an in-memory
	// store, or a test that made the page file itself) keeps its indexes in RAM.
	index_dir:    string,
	index_vfs:    ^Vfs,
	index_frames: int,
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
	return slice.Ordering(text_compare(a, b))
}

table_create :: proc(schema: ^Table_Schema) -> (^Table, Error) {
	normalized := schema^
	// The table keeps a copy in its arena; what normalizing added is freed here.
	defer schema_normalize_free(&normalized, schema)
	if err := schema_normalize(&normalized); err.kind != .None {
		return nil, err
	}
	if err := schema_validate(&normalized); err.kind != .None {
		return nil, err
	}
	t := new(Table)
	t.refs = 1
	keys, keys_err := key_store_make()
	if keys_err != nil {
		free(t)
		return nil, errf(.Out_Of_Memory, "cannot create the table arena: %v", keys_err)
	}
	t.keys = keys
	t.arena_allocator = keys.allocator
	t.schema = schema_copy(&normalized, t.arena_allocator)
	t.schema.ident = schema_ident_next()
	t.store = new(Row_Store)
	t.store.refs = 1
	// Row ids start at one, as SQLite's rowid does: a program that names a row by
	// its rowid -- sqlite3_blob_open's iRow, or ORDER BY rowid with a literal --
	// then finds the same row here as it did there.
	t.next_row_id = 1
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
		index_tree_init(&t.indexes[i])
		exprs, exprs_err := index_exprs_make(t.schema.indexes[i])
		if exprs_err.kind != .None {
			table_destroy(t)
			return nil, exprs_err
		}
		t.indexes[i].exprs = exprs
	}
	return t, ERROR_NONE
}

// table_share adds one owner and returns the same table. A read transaction
// takes one reference per table instead of a copy, which is what makes opening a
// read cost the number of tables and not the number of rows.
table_share :: proc(t: ^Table) -> ^Table {
	if t == nil do return nil
	sync.atomic_add(&t.refs, 1)
	return t
}

// table_release drops one owner; the last one frees the table.
table_release :: proc(t: ^Table) {
	if t == nil do return
	if sync.atomic_add(&t.refs, -1) == 1 do table_destroy(t)
}

table_destroy :: proc(t: ^Table) {
	if t == nil do return
	// The values belong to the table that stored them: a borrowed one (the table
	// a reader kept) frees none. The blocks free the history arrays of their rows
	// when the last table that lists them lets go.
	if !t.borrowed do table_drop_values(t)
	rows_destroy(&t.rows)
	delete(t.history)
	for i in 0 ..< len(t.indexes) {
		index_tree_free(&t.indexes[i])
		table_index_map_free(t, i)
		ordered_close(t.indexes[i].pages)
		index_exprs_destroy(t.indexes[i].exprs)
	}
	delete(t.indexes)
	// A paged table is closed, not deleted: the caller removes the file when the
	// table is dropped. Dirty frames are dropped with it, which is safe because
	// the log holds every committed change.
	page_rows_close(t.paged)
	if len(t.index_dir) > 0 do delete(t.index_dir)
	delete(t.key_scratch)
	key_store_release(t.keys)
	if t.store != nil do row_store_release(t.store)
	free(t)
}

// row_store_shared reports whether anyone but this table can read the values.
row_store_shared :: proc(store: ^Row_Store) -> bool {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	return store.refs > 1
}

// row_store_defer hands the store a row whose values a snapshot may still
// read; the last owner frees it. The list is taken under the lock, by a reader
// ending on its own thread, so it is added to under the lock too.
row_store_defer :: proc(store: ^Row_Store, row: Row) {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	append(&store.pending, row)
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

// table_drop_values frees the values of every row and version this table
// holds, or hands them to the shared store while a reader may read them.
@(private)
table_drop_values :: proc(t: ^Table) {
	shared := t.store != nil && row_store_shared(t.store)
	it := rows_iter(&t.rows)
	for row in rows_next(&it) {
		if shared {
			row_store_defer(t.store, Row{values = row.values})
			for version in row.versions do row_store_defer(t.store, Row{values = version.values})
			continue
		}
		row_values_free(row.values)
		for version in row.versions do row_values_free(version.values)
	}
}

@(private)
table_free_row :: proc(row: Row) {
	row_values_free(row.values)
	for version in row.versions do row_values_free(version.values)
	delete(row.versions)
}

// A row a memory table keeps lives in one allocation: its value array, then
// the bytes of its texts and blobs and the items of its lists (R4). A commit
// copied each row out of the transaction arena with one allocation for the
// array and one more per text, blob or list, and freed them one by one; that
// copy was a tenth of a 256-row insert. Only the table makes and frees these
// rows (table_insert, table_update, and the frees in this file), so nothing
// frees one value of a stored row on its own.
@(private)
row_values_pack :: proc(values: []Value) -> []Value {
	if len(values) == 0 do return nil
	extra := 0
	for value in values do extra += value_packed_size(value)
	if extra == 0 {
		// Nothing to place after the array: the array is the row.
		out := make([]Value, len(values))
		copy(out, values)
		return out
	}
	size := len(values) * size_of(Value) + extra
	block, alloc_err := mem.alloc_bytes_non_zeroed(size, align_of(Value))
	if alloc_err != nil do return nil
	out := ([^]Value)(raw_data(block))[:len(values)]
	at := len(values) * size_of(Value)
	for value, i in values do out[i] = value_pack(value, block, &at)
	return out
}

// row_values_free releases a row row_values_pack made: the one allocation.
@(private)
row_values_free :: proc(values: []Value) {
	if values == nil do return
	mem.free(raw_data(values))
}

// value_packed_size is what a value needs after the row's value array: its
// bytes, or its list's items (aligned) and what they need in turn.
@(private)
value_packed_size :: proc(value: Value) -> int {
	#partial switch value.kind {
	case .String:
		return len(value.s)
	case .Bytes:
		return len(value.bytes)
	case .Array, .Product:
		size := align_of(Value) - 1 + len(value.list) * size_of(Value)
		for item in value.list do size += value_packed_size(item)
		return size
	}
	return 0
}

@(private)
value_pack :: proc(value: Value, block: []u8, at: ^int) -> Value {
	out := value
	#partial switch value.kind {
	case .String:
		n := len(value.s)
		copy(block[at^:at^ + n], value.s)
		out.s = string(block[at^:at^ + n])
		at^ += n
	case .Bytes:
		n := len(value.bytes)
		copy(block[at^:at^ + n], value.bytes)
		out.bytes = block[at^:at^ + n]
		at^ += n
	case .Array, .Product:
		if len(value.list) == 0 {
			out.list = nil
			return out
		}
		at^ = mem.align_forward_int(at^, align_of(Value))
		list := ([^]Value)(&block[at^])[:len(value.list)]
		at^ += len(value.list) * size_of(Value)
		for item, i in value.list do list[i] = value_pack(item, block, at)
		out.list = list
	}
	return out
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
// can ask for, and removes tombstones older than that. It visits the rows in
// `history` only; the slice is compacted from the first tombstone that leaves,
// so a commit that deleted nothing moves no row.
table_prune_versions :: proc(t: ^Table, before_seq: u64) {
	if len(t.history) == 0 do return
	// A commit while a reader was open gave the reader the table as it was and
	// kept writing a copy that borrows the same values (table_cow_clone): the
	// values an update then moved into history are the ones that reader reads.
	// No read pins its sequence, so the prune can drop that history while the
	// reader is still reading; the values go to the shared store then, freed
	// when the last reader of them is gone. They were freed here, and a reader
	// read freed memory. Values stored after the last copy (`shared_before`)
	// are this table's alone and are freed as before.
	shared := t.store != nil && t.shared_before > 0 && row_store_shared(t.store)
	kept := 0
	// The blocks that hold a tombstone the prune frees, to compact after.
	emptied := make([dynamic]int, context.temp_allocator)
	for id in t.history {
		at := rows_find(&t.rows, id)
		if at < 0 do continue
		t.prune_visited += 1
		// A block a reader's table still lists is copied before it changes.
		row := rows_mut(&t.rows, at)
		write := 0
		for version in row.versions {
			if version.deleted_seq != 0 && version.deleted_seq <= before_seq {
				if shared && version.created_seq < t.shared_before {
					row_store_defer(t.store, Row{values = version.values})
				} else {
					row_values_free(version.values)
				}
				continue
			}
			row.versions[write] = version
			write += 1
		}
		resize(&row.versions, write)
		if row.deleted_seq != 0 && row.deleted_seq <= before_seq {
			// A tombstone nobody can read any more owns nothing: its values and the
			// array that held their history are freed with it. Forgetting them is
			// what made INSERT OR REPLACE leave the replaced row behind for the life
			// of the process (tools/leakcheck counted 48 bytes per statement).
			if shared && row.created_seq < t.shared_before {
				row_store_defer(t.store, Row{values = row.values})
			} else {
				row_values_free(row.values)
			}
			delete(row.versions)
			row.values = nil
			row.versions = nil
			block := at >> ROW_BLOCK_SHIFT
			if len(emptied) == 0 || emptied[len(emptied) - 1] != block do append(&emptied, block)
			continue
		}
		if len(row.versions) > 0 || row.deleted_seq != 0 {
			t.history[kept] = id
			kept += 1
		}
	}
	resize(&t.history, kept)
	if len(emptied) == 0 do return
	// Every tombstone old enough was in the list and is freed: the blocks that
	// held one keep the rest, in order, from the last so the earlier places hold.
	slice.sort(emptied[:])
	gone :: proc(row: ^Row, user: rawptr) -> bool {
		before := (^u64)(user)^
		return row.deleted_seq != 0 && row.deleted_seq <= before
	}
	cutoff := before_seq
	for i := len(emptied) - 1; i >= 0; i -= 1 {
		if i < len(emptied) - 1 && emptied[i] == emptied[i + 1] do continue
		t.prune_visited += u64(rows_compact(&t.rows, emptied[i], gone, &cutoff))
	}
}

// schema_normalize adds the implicit unique indexes for the primary key and for
// UNIQUE columns.
schema_normalize :: proc(schema: ^Table_Schema) -> Error {
	extra := make([dynamic]Index_Schema)
	defer delete(extra)
	if len(schema.primary_key) > 0 {
		covered := false
		for i in 0 ..< len(schema.indexes) {
			// A partial or expression index does not hold every key, so it cannot
			// stand in for the primary key or a UNIQUE column.
			if schema.indexes[i].unique && index_is_plain(schema.indexes[i]) && schema_index_matches(&schema.indexes[i], schema.primary_key) {
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
					on_conflict = schema.pk_conflict,
				},
			)
		}
	}
	for col, i in schema.columns {
		if !col.unique do continue
		covered := false
		for j in 0 ..< len(schema.indexes) {
			idx := schema.indexes[j]
			if len(idx.columns) == 1 && idx.columns[0] == i && idx.unique && index_is_plain(idx) {
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
				on_conflict = col.unique_conflict,
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

// schema_normalize_free frees what schema_normalize added to a copy of
// `original`: the implicit indexes and the slice that holds them.
@(private)
schema_normalize_free :: proc(normalized: ^Table_Schema, original: ^Table_Schema) {
	if raw_data(normalized.indexes) == raw_data(original.indexes) do return
	for idx in normalized.indexes[len(original.indexes):] {
		delete(idx.name)
		delete(idx.columns)
	}
	delete(normalized.indexes)
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
	// The writer's buffer is the result: one allocation sized for a typical key,
	// no copy. The caller deletes it as before.
	return index_prefix_in(t, index, values, context.allocator)
}

// index_prefix_in encodes the key columns of `values` into a buffer from `alloc`.
// With a transaction arena it costs a bump allocation and nothing to free.
index_prefix_in :: proc(t: ^Table, index: int, values: []Value, alloc: mem.Allocator) -> string {
	w := Byte_Writer{data = make([dynamic]u8, 0, 32, alloc)}
	index_encode_parts(&w, t, index, values)
	return string(w.data[:])
}

// index_entry_key builds the full key stored in the tree: the prefix, plus the
// row id for a non-unique index. It lives in the table arena.
@(private)
index_entry_key :: proc(t: ^Table, index: int, values: []Value, id: Row_Id) -> string {
	// Encoded into the table's scratch buffer, which keeps its capacity between
	// keys, and copied into the arena at its exact length: one bump allocation
	// per key, where a heap buffer was allocated and freed for each.
	w := Byte_Writer{data = t.key_scratch}
	clear(&w.data)
	has_null := index_encode_parts(&w, t, index, values)
	// Two rows may both hold NULL in a UNIQUE column; the row id keeps their
	// entries apart, as it does in a non-unique index.
	if !t.indexes[index].unique || has_null {
		append_be_u64(&w, u64(id))
	}
	t.key_scratch = w.data
	out := make([]u8, len(w.data), t.arena_allocator)
	copy(out, w.data[:])
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
			if text_compare(key, probe) == 0 {
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

// --- Index backends --------------------------------------------------------

// table_index_put stores one entry. A paged index writes it to the B+tree of
// pages; a memory index files the key in its tree.
@(private)
table_index_put :: proc(t: ^Table, index: int, key: string, id: Row_Id) -> Error {
	if t.indexes[index].pages != nil {
		if put_err := ordered_put(t.indexes[index].pages, key, u64(id)); put_err.kind != .None {
			return error_wrap(put_err, put_err.kind, "cannot grow index %s: %s", t.indexes[index].schema.name, put_err.message)
		}
		return ERROR_NONE
	}
	return ERROR_NONE
}

@(private)
table_index_remove_key :: proc(t: ^Table, index: int, key: string) {
	if t.indexes[index].pages != nil {
		_ = ordered_remove(t.indexes[index].pages, key)
	}
}

// table_index_count is how many entries an index holds.
table_index_count :: proc(t: ^Table, index: int) -> u64 {
	if t.indexes[index].pages != nil do return ordered_entries(t.indexes[index].pages)
	count: u64
	for c := ib_first(&t.indexes[index].tree); c.valid; c.valid = ib_advance(&c) do count += 1 + u64(len(ib_slot(&c).more))
	return count
}

// table_index_path is the file an index of this table lives in. It is empty when
// the table has no index directory, which is the signal to stay in memory.
table_index_path :: proc(t: ^Table, name: string) -> string {
	if len(t.index_dir) == 0 do return ""
	file := store_paged_file_name(name)
	defer delete(file)
	return fmt.aprintf("%s/%s", t.index_dir, file)
}

@(private)
table_index_attach_pages :: proc(t: ^Table, index: int) -> Error {
	if t.paged == nil || len(t.index_dir) == 0 do return ERROR_NONE
	path := table_index_path(t, t.indexes[index].schema.name)
	if len(path) == 0 do return ERROR_NONE
	defer delete(path)
	frames := t.index_frames
	if frames <= 0 do frames = INDEX_PAGE_FRAMES
	pages, create_err := ordered_create(t.index_vfs, path, frames)
	if create_err.kind != .None do return create_err
	t.indexes[index].pages = pages
	return ERROR_NONE
}

// table_index_open_pages attaches an index whose file already exists, which is
// the other half of table_index_attach_pages: opening a paged database reads the
// tree the last commit left instead of building it from the table's rows.
@(private)
table_index_open_pages :: proc(t: ^Table, index: int) -> Error {
	if t.paged == nil || len(t.index_dir) == 0 do return ERROR_NONE
	path := table_index_path(t, t.indexes[index].schema.name)
	if len(path) == 0 do return ERROR_NONE
	defer delete(path)
	frames := t.index_frames
	if frames <= 0 do frames = INDEX_PAGE_FRAMES
	pages, open_err := ordered_open(t.index_vfs, path, frames)
	if open_err.kind != .None do return open_err
	t.indexes[index].pages = pages
	return ERROR_NONE
}

@(private)
table_index_detach_pages :: proc(t: ^Table, index: int, remove_file: bool) {
	pages := t.indexes[index].pages
	if pages == nil do return
	path := strings.clone(pages.path)
	ordered_close(pages)
	t.indexes[index].pages = nil
	defer delete(path)
	if remove_file {
		system := log_vfs_or_os(t.index_vfs)
		_ = system.ops.remove(system, path)
	}
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
	has_null := index_encode_parts(&w, t, index, values)
	if !t.indexes[index].unique || has_null {
		append_be_u64(&w, u64(id))
	}
	return len(w.data)
}

// table_memory walks the rows and indexes. It is meant for diagnostics, not for
// the hot path.
table_memory :: proc(t: ^Table) -> Table_Memory {
	memory: Table_Memory
	if t.paged != nil {
		// The values live in the page file and so do the index keys: what an
		// index costs here is its buffer pool, not one entry per row.
		memory.rows = int(t.paged.rows)
		for index in t.indexes {
			if index.pages != nil {
				memory.index_entries += int(ordered_entries(index.pages))
				memory.index_bytes += page_resident(index.pages.file) * PAGE_SIZE
			}
		}
		return memory
	}
	it := rows_iter(&t.rows)
	for row in rows_next(&it) {
		memory.rows += 1
		memory.row_bytes += 48 // slot, slice header and row header
		for value in row.values {
			memory.row_bytes += value_storage_size(value)
		}
	}
	for _, position in t.indexes {
		each := rows_iter(&t.rows)
		for row in rows_next(&each) {
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

// --- Lookup ----------------------------------------------------------------

// table_index_lookup returns every row whose indexed columns equal `values`.
table_index_lookup :: proc(t: ^Table, index: int, values: []Value) -> [dynamic]Row_Id {
	if id, held, known := index_int_holder(t, index, values); known {
		ids := make([dynamic]Row_Id)
		if held do append(&ids, id)
		return ids
	}
	if t.indexes[index].schema.algorithm != .Btree {
		ids := make([dynamic]Row_Id)
		probe := index_prefix_temp(t, index, values)
		defer delete(probe)
		if bucket, found := t.indexes[index].lookup[probe]; found {
			append(&ids, ..bucket.ids[:])
		}
		return ids
	}
	prefix := index_prefix_temp(t, index, values)
	defer delete(prefix)
	if t.indexes[index].pages != nil {
		return ordered_lookup_prefix(t.indexes[index].pages, prefix)
	}
	ids := make([dynamic]Row_Id)
	for c := ib_lower_bound(&t.indexes[index].tree, prefix); c.valid; c.valid = ib_advance(&c) {
		if !strings.has_prefix(ib_key(&c), prefix) do break
		index_slot_append(&ids, ib_slot(&c)^)
	}
	return ids
}

// table_index_scan_prefix returns the rows whose index key starts with
// `prefix`. It is the equality lookup for a non-unique index, whose stored keys
// carry the row id after the tuple.
table_index_scan_prefix :: proc(t: ^Table, index: int, prefix: string) -> [dynamic]Row_Id {
	if t.indexes[index].pages != nil {
		return ordered_lookup_prefix(t.indexes[index].pages, prefix)
	}
	ids := make([dynamic]Row_Id)
	for c := ib_lower_bound(&t.indexes[index].tree, prefix); c.valid; c.valid = ib_advance(&c) {
		if !strings.has_prefix(ib_key(&c), prefix) do break
		index_slot_append(&ids, ib_slot(&c)^)
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
	if t.indexes[index].pages != nil {
		return ordered_scan(t.indexes[index].pages, start, end, inclusive_end)
	}
	ids := make([dynamic]Row_Id)
	tree := &t.indexes[index].tree
	for c := start == "" ? ib_first(tree) : ib_lower_bound(tree, start); c.valid; c.valid = ib_advance(&c) {
		key := ib_key(&c)
		if end != "" {
			order := index_cmp(key, end)
			if strings.has_prefix(key, end) do order = .Equal
			if order == .Greater do break
			if order == .Equal && !inclusive_end do break
		}
		index_slot_append(&ids, ib_slot(&c)^)
	}
	return ids
}

table_primary_key_index :: proc(t: ^Table) -> (int, bool) {
	if len(t.schema.primary_key) == 0 do return -1, false
	for i in 0 ..< len(t.indexes) {
		if t.indexes[i].schema.unique && index_is_plain(t.indexes[i].schema) &&
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
// unique index. `ignore` is the row being replaced or updated, and `skip` names
// the indexes whose key it keeps.
table_check_unique :: proc(t: ^Table, values: []Value, ignore: Row_Id = Row_Id(max(u64)), skip: bit_set[0 ..< 64] = {}) -> Error {
	for idx, i in t.indexes {
		if !idx.unique do continue
		if i < 64 && i in skip do continue
		if holder, held, known := index_int_holder(t, i, values); known {
			if held && holder != ignore do return unique_violation(t, i)
			continue
		}
		if !index_row_included(t, i, values) do continue
		if index_key_has_null(t, i, values) do continue
		ids := table_index_lookup(t, i, values)
		defer delete(ids)
		for id in ids {
			if id == ignore do continue
			return unique_violation(t, i)
		}
	}
	return ERROR_NONE
}

// unique_violation is the error a row that repeats a unique key gets, in
// SQLite's words: the table and the key's columns, or the index for a key
// over an expression.
unique_violation :: proc(t: ^Table, i: int) -> Error {
	kind := index_is_primary(t, i) ? Error_Kind.Duplicate_Primary_Key : Error_Kind.Duplicate_Unique
	index := t.indexes[i].schema
	for expr in index.exprs {
		if len(expr) > 0 do return errf(kind, "UNIQUE constraint failed: index '%s'", index.name)
	}
	columns := strings.builder_make(context.temp_allocator)
	for position, n in index.columns {
		if n > 0 do strings.write_string(&columns, ", ")
		strings.write_string(&columns, t.schema.name)
		strings.write_byte(&columns, '.')
		if position >= 0 && position < len(t.schema.columns) do strings.write_string(&columns, t.schema.columns[position].name)
	}
	return errf(kind, "UNIQUE constraint failed: %s", strings.to_string(columns))
}

@(private)
index_is_primary :: proc(t: ^Table, index: int) -> bool {
	if len(t.schema.primary_key) == 0 do return false
	return schema_index_matches(&t.indexes[index].schema, t.schema.primary_key)
}

// --- Maintenance -----------------------------------------------------------

// table_get_row returns one row. A memory table lends its values; a paged table
// decodes them into `alloc`, and the caller owns them.
table_get_row :: #force_inline proc(t: ^Table, id: Row_Id, alloc: mem.Allocator) -> (Row, bool) {
	if t.paged != nil do return page_rows_get(t.paged, id, alloc)
	at := rows_find(&t.rows, id)
	if at < 0 do return {}, false
	return t.rows.blocks[at >> ROW_BLOCK_SHIFT].rows[at & (ROW_BLOCK - 1)], true
}

// table_row_exists answers without decoding the values.
table_row_exists :: proc(t: ^Table, id: Row_Id) -> bool {
	if t.paged != nil do return page_rows_contains(t.paged, id)
	return table_row_index(t, id) >= 0
}

// table_row_index is where row `id` sits in t.rows (a Row_Pos), or -1. Ids are
// handed out in increasing order, so with none missing the row is at `id -
// first`: that place is tried first, and a search answers when ids are missing.
table_row_index :: proc(t: ^Table, id: Row_Id) -> int {
	return rows_find(&t.rows, id)
}

// table_memory_row is row `id` of a memory table, as the slice holds it (a paged
// table holds none there and answers false), without decoding anything.
table_memory_row :: proc(t: ^Table, id: Row_Id) -> (Row, bool) {
	at := table_row_index(t, id)
	if at < 0 do return {}, false
	return rows_at(&t.rows, at)^, true
}

// table_row_find is row `id` in place, to change, or nil: its block is this
// table's own (a block a reader's table lists is copied first). The pointer is
// good until a row is put or taken out (an insert, a prune, a truncate).
table_row_find :: proc(t: ^Table, id: Row_Id) -> ^Row {
	at := table_row_index(t, id)
	return at < 0 ? nil : rows_mut(&t.rows, at)
}

// table_row_put adds a row that is not there, at its place: an append when the
// id is the highest, which is every id the table hands out itself.
@(private)
table_row_put :: proc(t: ^Table, row: Row) {
	rows_put(&t.rows, row)
}

// table_touch_int_key remembers the largest integer primary key a paged table
// has seen. It is read by the insert path, so a bulk load does not walk every
// page to find the maximum.
@(private)
table_touch_int_key :: proc(t: ^Table, values: []Value) {
	if len(t.schema.primary_key) != 1 do return
	column := t.schema.primary_key[0]
	if column >= len(values) do return
	if values[column].kind == .Int && values[column].i > t.next_int_key {
		t.next_int_key = values[column].i
	}
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
		if put_err := table_index_put_row(t, i, values, id); put_err.kind != .None do return put_err
	}
	return ERROR_NONE
}

@(private)
table_index_remove_all :: proc(t: ^Table, values: []Value, id: Row_Id) {
	for _, i in t.indexes {
		table_index_remove_row(t, i, values, id)
	}
}

// `validated` says the caller already proved the unique keys free (a staged
// insert applied by its own commit), so the indexes are not probed again.
table_insert :: proc(t: ^Table, id: Row_Id, values: []Value, validated := false) -> Error {
	if t.paged != nil {
		if page_rows_contains(t.paged, id) {
			return errf(.Internal, "row id %d already exists in table %s", u64(id), t.schema.name)
		}
		if !validated {
			if err := table_check_unique(t, values); err.kind != .None do return err
		}
		if put_err := page_rows_put(t.paged, id, values); put_err.kind != .None {
			return put_err
		}
		table_touch_sequence(t, values)
		table_touch_int_key(t, values)
		return table_index_add_all(t, values, id)
	}
	at := table_row_index(t, id)
	if at >= 0 && rows_at(&t.rows, at).deleted_seq == 0 {
		return errf(.Internal, "row id %d already exists in table %s", u64(id), t.schema.name)
	}
	if !validated {
		if err := table_check_unique(t, values); err.kind != .None do return err
	}
	stored := row_values_pack(values)
	// A value kept in a table has no subtype, as in SQLite: a JSON text read
	// back from a table, or from a subquery in FROM, is text.
	for &value in stored do value.subtype = 0
	if t.schema.auto_increment_column != NO_COLUMN {
		column := t.schema.auto_increment_column
		if number, ok := value_to_i64(stored[column]); ok {
			next := number + t.schema.columns[column].sequence.increment
			if next > t.next_sequence do t.next_sequence = next
		}
	}
	if at >= 0 {
		// The id names a row deleted before a prune came: the tombstone becomes a
		// version of the new row, so a read older than the delete still finds it.
		// It is in `history` already, as every tombstone is.
		slot := rows_mut(&t.rows, at)
		old := slot^
		versions := old.versions
		append(&versions, Row_Version{values = old.values, created_seq = old.created_seq, deleted_seq = old.deleted_seq})
		slot^ = Row{id = id, values = stored, created_seq = t.apply_seq, versions = versions}
	} else {
		table_row_put(t, Row{id = id, values = stored, created_seq = t.apply_seq})
	}
	for _, i in t.indexes {
		if put_err := table_index_put_row(t, i, stored, id); put_err.kind != .None do return put_err
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
		table_touch_int_key(t, values)
		return table_index_add_all(t, values, id)
	}
	at := table_row_index(t, id)
	if at < 0 {
		return errf(.Internal, "row id %d is missing from table %s", u64(id), t.schema.name)
	}
	// The history array the update appends to is the block's: a block a
	// reader's table lists is copied before it (rows_mut).
	row := rows_mut(&t.rows, at)^
	// An index whose key the update leaves as it was keeps its entry: the row is
	// filed under the same key and id, and a unique key it held is still its own,
	// so it is neither checked nor removed and put back.
	unchanged: bit_set[0 ..< 64]
	if len(t.indexes) <= 64 {
		for _, i in t.indexes do if index_key_unchanged(t, i, row.values, values) do unchanged += {i}
	}
	if err := table_check_unique(t, values, id, unchanged); err.kind != .None {
		return err
	}
	for _, i in t.indexes {
		if i < 64 && i in unchanged do continue
		table_index_remove_row(t, i, row.values, id)
	}
	// The current values become a version, so a reader that started earlier
	// keeps its view.
	if len(row.versions) == 0 do append(&t.history, id)
	append(&row.versions, Row_Version {
		values = row.values,
		created_seq = row.created_seq,
		deleted_seq = t.apply_seq,
	})
	stored := row_values_pack(values)
	// A value kept in a table has no subtype, as in SQLite: a JSON text read
	// back from a table, or from a subquery in FROM, is text.
	for &value in stored do value.subtype = 0
	if t.schema.auto_increment_column != NO_COLUMN {
		column := t.schema.auto_increment_column
		if number, ok := value_to_i64(stored[column]); ok {
			next := number + t.schema.columns[column].sequence.increment
			if next > t.next_sequence do t.next_sequence = next
		}
	}
	rows_mut(&t.rows, at)^ = Row{
		id = id,
		values = stored,
		created_seq = t.apply_seq,
		versions = row.versions,
	}
	for _, i in t.indexes {
		if i < 64 && i in unchanged do continue
		if put_err := table_index_put_row(t, i, stored, id); put_err.kind != .None do return put_err
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
	row := table_row_find(t, id)
	if row == nil do return false
	for _, i in t.indexes {
		table_index_remove_row(t, i, row.values, id)
	}
	// Tombstone instead of erasing: the live values stay owned by the row and are
	// visible to snapshots taken before this sequence, so no extra version is
	// recorded (that would share the values and double free them).
	if len(row.versions) == 0 && row.deleted_seq == 0 do append(&t.history, id)
	row.deleted_seq = t.apply_seq
	return true
}

table_truncate :: proc(t: ^Table) {
	if t.paged != nil {
		error_drop(page_rows_truncate(t.paged))
		t.next_int_key = 0
		for _, i in t.indexes {
			if t.indexes[i].pages != nil {
				error_drop(ordered_clear(t.indexes[i].pages))
			} else {
				index_tree_free(&t.indexes[i])
				index_tree_init(&t.indexes[i])
			}
			table_index_map_free(t, i)
			t.indexes[i].lookup = make(map[string]^Index_Bucket)
		}
		return
	}
	// Truncating while a snapshot reads the same values cannot free them: they
	// are handed to the shared store, which frees them when the last reader is
	// gone (table_drop_values).
	table_drop_values(t)
	rows_clear(&t.rows)
	clear(&t.history)
	for _, i in t.indexes {
		index_tree_free(&t.indexes[i])
		index_tree_init(&t.indexes[i])
		table_index_map_free(t, i)
		t.indexes[i].lookup = make(map[string]^Index_Bucket)
	}
}

// table_insert_borrowed stores a row whose values belong to another table. The
// indexes are built as usual; the values are not cloned.
table_insert_borrowed :: proc(t: ^Table, id: Row_Id, values: []Value) -> Error {
	if table_row_index(t, id) >= 0 do return errf(.Internal, "row id %d already exists", u64(id))
	table_row_put(t, Row{id = id, values = values, created_seq = t.apply_seq})
	for _, i in t.indexes {
		if put_err := table_index_put_row(t, i, values, id); put_err.kind != .None do return put_err
	}
	return ERROR_NONE
}

// index_lookup_clone copies the equality map of a HASH or DIRECT index. The keys
// and the buckets are allocated the way table_index_map_add allocates them, so
// table_index_map_free frees them the same way; the clone is independent of the
// source, which may be dropped while a snapshot reads it.
@(private)
index_lookup_clone :: proc(source: ^Index, target: ^Index, keys: mem.Allocator) {
	if len(source.lookup) == 0 do return
	target.lookup = make(map[string]^Index_Bucket, len(source.lookup))
	for key, bucket in source.lookup {
		copied := new(Index_Bucket)
		copied.ids = make([dynamic]Row_Id, 0, len(bucket.ids))
		append(&copied.ids, ..bucket.ids[:])
		target.lookup[strings.clone(key, keys)] = copied
	}
}

// table_snapshot copies a table for a read transaction: structure and indexes are
// its own, the values are borrowed from the source through a shared Row_Store.
// The rows are copied as a map (presized) and the index trees shape for shape, so
// freezing is one allocation and one copy per entry instead of a lookup, an
// encoding and an insert. The source defers freeing values while a snapshot that
// shares them lives.
table_snapshot :: proc(source: ^Table) -> ^Table {
	// A paged table can be copied, but the copy has to hold the values: it has no
	// page file to read them from. Reads of a store with pages take the lock for
	// the whole transaction instead, so this path is only a safety net.
	if source.paged != nil {
		schema := source.schema
		clone, create_err := table_create(&schema)
		if create_err.kind != .None {
			error_free(&create_err)
			return nil
		}
		// The same columns as its source: the same shape.
		clone.schema.ident = source.schema.ident
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
	// The copy shares what it can and builds nothing it would throw away: the
	// arena (its schema, its index keys), the row store, the blocks and the
	// trees. Going through table_create made a new arena and a key store for it,
	// 0.9-2.1 ms of a commit with a reader open, where the sharing took 12 us.
	clone := new(Table)
	if clone == nil do return nil
	clone.refs = 1
	clone.schema = source.schema
	clone.keys = source.keys
	key_store_acquire(clone.keys)
	clone.arena_allocator = clone.keys.allocator
	clone.store = source.store
	row_store_acquire(clone.store)
	clone.borrowed = true
	clone.next_row_id = source.next_row_id
	clone.next_sequence = source.next_sequence
	clone.next_int_key = source.next_int_key
	clone.indexes = make([]Index, len(source.indexes))
	for &target, index in clone.indexes {
		from := &source.indexes[index]
		target = Index {
			schema    = from.schema,
			unique    = from.unique,
			lookup    = make(map[string]^Index_Bucket),
			int_keyed = from.int_keyed,
		}
		// A partial or expression index evaluates its own parsed copy.
		if from.exprs != nil {
			exprs, exprs_err := index_exprs_make(from.schema)
			if exprs_err.kind != .None {
				error_free(&exprs_err)
				table_destroy(clone)
				return nil
			}
			target.exprs = exprs
		}
		// The tree is shared: the clone copies a node when it first writes one.
		ib_share(&target.tree, &from.tree)
		index_lookup_clone(from, &target, context.allocator)
		index_ints_clone(from, &target)
	}
	// The rows are shared, block by block: the copy lists the same blocks and
	// copies one only when it changes it (Row_Blocks).
	rows_share(&clone.rows, &source.rows)
	return clone
}

// table_cow_clone gives the store a writable table and leaves `source` to the
// readers that hold it. The index trees are copied (a copy per entry); the rows
// are shared by block, and the clone copies a block when it first writes to it.
// The source is read-only for the rest of its life, because every value it shows
// now belongs to the clone: a borrowed table never frees anything. The history
// goes with the clone, which prunes it once no reader can ask for it; it was
// freed here, and a reader's own rows dropped it, which cost a pass over every
// row of the table.
table_cow_clone :: proc(source: ^Table) -> ^Table {
	// A paged table has no rows to copy and no reader can hold one: reads of a
	// store with pages keep the lock for their whole life.
	if source.paged != nil do return nil
	clone := table_snapshot(source)
	if clone == nil do return nil
	clone.borrowed = false
	source.borrowed = true
	// The history lists ids of rows the blocks hold, so the clone's is the
	// source's; only a prune reads it, and only the store's table is pruned.
	clone.history = source.history
	source.history = nil
	return clone
}

table_row_count :: proc(t: ^Table) -> int {
	if t.paged != nil do return int(t.paged.rows)
	live := 0
	it := rows_iter(&t.rows)
	for row in rows_next(&it) {
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
		// A page it cannot load is the statement's failure (page_note_failure).
		error_drop(page_rows_scan(t.paged, alloc, &ctx, paged_collect_visit))
		rows_sort_by_id(out[:])
		return
	}
	reserve(out, len(out) + rows_len(&t.rows))
	// The blocks are in id order, so the rows come out sorted.
	it := rows_iter(&t.rows)
	for row in rows_next(&it) {
		values, visible := row_values_at(row^, seq)
		if !visible do continue
		append(out, Row{id = row.id, values = values})
	}
}

// table_max_int returns the largest Int value in one column, or 0 when the
// column holds none. It answers the INTEGER PRIMARY KEY assignment for both
// backends: a paged table has no map to walk, so the pages are streamed and no
// value is copied.
table_max_int :: proc(t: ^Table, column: int) -> i64 {
	best := i64(0)
	if t.paged != nil {
		ctx := Max_Column_Ctx{column = column}
		error_drop(page_rows_each(t.paged, &ctx, max_column_visit))
		return ctx.best
	}
	it := rows_iter(&t.rows)
	for row in rows_next(&it) {
		if column >= len(row.values) do continue
		if row.values[column].kind == .Int && row.values[column].i > best {
			best = row.values[column].i
		}
	}
	return best
}

// table_largest_int_indexed answers table_largest_int from an index over the
// column alone, when the table has one: its keys are in order, numbers under
// tag 0x02 (write_key_number) and every other kind after them or before, so
// the largest integer is found walking back from the first key past the
// numbers. Every INSERT that left an INTEGER PRIMARY KEY out walked all the
// rows for it: 1 ms over 50 000 rows, the whole cost of such a commit, where
// SQLite reads the last entry of its tree. `ok` is false without such an
// index, or when the walk meets more than a few keys it cannot use (reals, or
// rows the transaction changed), and the caller scans.
table_largest_int_indexed :: proc(t: ^Table, column: int, skip: proc(id: Row_Id, user: rawptr) -> bool = nil, user: rawptr = nil) -> (largest: i64, found: bool, ok: bool) {
	if t.paged != nil do return
	for &index in t.indexes {
		if index.pages != nil || index.schema.algorithm != .Btree || !index_is_plain(index.schema) do continue
		if len(index.schema.columns) != 1 || index.schema.columns[0] != column do continue
		if column < len(t.schema.columns) && len(t.schema.columns[column].collation) > 0 do continue
		// The first key past the numbers: the first of any kind tagged above 0x02.
		past_numbers := [1]u8{0x03}
		c := ib_lower_bound(&index.tree, string(past_numbers[:]))
		if c.valid {
			ib_prev(&c)
		} else {
			c = ib_last(&index.tree)
		}
		for steps := 0; c.valid; steps += 1 {
			if steps == 64 do return 0, false, false
			key := ib_key(&c)
			if len(key) == 0 || key[0] != 0x02 do return 0, false, true
			slot := ib_slot(&c)
			best: i64
			held := false
			consider :: proc(t: ^Table, column: int, id: Row_Id, skip: proc(id: Row_Id, user: rawptr) -> bool, user: rawptr, best: ^i64, held: ^bool) {
				if skip != nil && skip(id, user) do return
				row, exists := table_memory_row(t, id)
				if !exists || row.deleted_seq != 0 || column >= len(row.values) || row.values[column].kind != .Int do return
				if !held^ || row.values[column].i > best^ do best^ = row.values[column].i
				held^ = true
			}
			consider(t, column, slot.first, skip, user, &best, &held)
			for id in slot.more do consider(t, column, id, skip, user, &best, &held)
			if held do return best, true, true
			ib_prev(&c)
		}
		return 0, false, true
	}
	return
}

// table_largest_int is the largest integer a memory table's live rows hold in
// a column, negative ones included, and whether any row holds one. `skip` is
// called with each row's id first: a transaction leaves out the rows it
// deleted or changed, and weighs its own versions itself.
table_largest_int :: proc(t: ^Table, column: int, skip: proc(id: Row_Id, user: rawptr) -> bool = nil, user: rawptr = nil) -> (largest: i64, found: bool) {
	it := rows_iter(&t.rows)
	for row in rows_next(&it) {
		if row.deleted_seq != 0 || column >= len(row.values) || row.values[column].kind != .Int do continue
		if skip != nil && skip(row.id, user) do continue
		if !found || row.values[column].i > largest do largest = row.values[column].i
		found = true
	}
	return
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
// Table_Scan walks a table's visible rows in id order without collecting them:
// a memory table's rows are read in place, which is what a scan of the
// reference's tables does. A paged table has no rows in memory, so its rows are
// decoded once into the scan and freed by table_scan_end.
Table_Scan :: struct {
	table:  ^Table,
	seq:    u64,
	// at is the next row of a paged scan's list; rows walks a memory table.
	at:     int,
	rows:   Rows_Iter,
	paged:  [dynamic]Row,
}

// table_scan starts a scan of the rows visible at `seq`. The values it hands out
// are the table's (a paged table's: the scan's) and stay good until
// table_scan_end, or until the table is written.
table_scan :: proc(t: ^Table, seq: u64 = max(u64)) -> Table_Scan {
	scan := Table_Scan{table = t, seq = seq, rows = rows_iter(&t.rows)}
	if t.paged != nil do table_collect(t, &scan.paged, seq)
	return scan
}

// table_scan_next answers the next visible row, or false at the end.
table_scan_next :: #force_inline proc(scan: ^Table_Scan) -> (id: Row_Id, values: []Value, ok: bool) {
	t := scan.table
	if t.paged != nil {
		if scan.at >= len(scan.paged) do return 0, nil, false
		row := scan.paged[scan.at]
		scan.at += 1
		return row.id, row.values, true
	}
	for row in rows_next(&scan.rows) {
		if visible, shown := row_values_at(row^, scan.seq); shown do return row.id, visible, true
	}
	return 0, nil, false
}

// table_scan_end frees what a scan of a paged table decoded.
table_scan_end :: proc(scan: ^Table_Scan) {
	if scan.table != nil && scan.table.paged != nil do table_collect_release(scan.table, &scan.paged)
	scan^ = {}
}

table_collect_release :: proc(t: ^Table, rows: ^[dynamic]Row) {
	if t.paged != nil {
		for row in rows^ do free_values(row.values)
	}
	delete(rows^)
}

// alter_row_values lays one stored row out for the schema an ALTER produced, and
// converts a value whose column changed type. The conversion is CAST's: a row that
// a CAST would refuse refuses the whole ALTER instead of being stored as the old
// type under the new declaration. Both the statement and the replay of its log
// record go through here, so a database reopened after an ALTER holds converted
// values; the statement path is what proves the conversion is possible before the
// record is written, so the replay cannot meet a value it cannot convert.
//
// When the column count is unchanged the statement is a rename, and only positions
// identify the columns: matching by name would find nothing and turn every value
// into its default. An added or dropped column changes the count, so names decide
// there, which is what makes the surviving columns keep their data.
alter_row_values :: proc(
	old: ^Table_Schema,
	next: Table_Schema,
	values: []Value,
	alloc: mem.Allocator,
) -> ([]Value, Error) {
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
			stored := values[old_index]
			if stored.kind != .Null && !type_equal(old.columns[old_index].type, column.type) {
				// What a conversion makes lives with the row, in `alloc`: in the heap
				// it outlived the row, which a commit copies anyway.
				caller := context.allocator
				context.allocator = alloc
				converted, cast_err := value_cast(stored, column.type)
				if cast_err.kind != .None {
					// The error is the caller's to free, in its allocator; the cast's
					// own message stays in `alloc`.
					context.allocator = caller
					return nil, errf(
						.Invalid_Type,
						"column %s cannot become %s: %s",
						column.name,
						column_type_name(column.type),
						cast_err.message,
					)
				}
				out[i] = converted
			} else {
				out[i] = stored
			}
		} else {
			out[i] = column.has_default ? column.default_value : value_null()
		}
	}
	return out, ERROR_NONE
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
	for col, i in index.columns {
		is_expression := i < len(index.exprs) && len(index.exprs[i]) > 0
		if is_expression && col == NO_COLUMN do continue
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
	index_tree_init(&t.indexes[position])
	exprs, exprs_err := index_exprs_make(stored)
	if exprs_err.kind != .None do return exprs_err
	t.indexes[position].exprs = exprs
	if attach_err := table_index_attach_pages(t, position); attach_err.kind != .None {
		return attach_err
	}
	if t.paged != nil {
		// The visitor needs the table, not only its position: the previous version
		// left this field nil and only worked when the stack happened to hold the
		// right pointer, which is exactly what a reopened database did not.
		ctx := Add_Index_Ctx{table = t, position = position}
		if scan_err := page_rows_each(t.paged, &ctx, add_index_visit); scan_err.kind != .None {
			return scan_err
		}
		return ERROR_NONE
	}
	it := rows_iter(&t.rows)
	for row in rows_next(&it) {
		if row.deleted_seq != 0 do continue
		if put_err := table_index_put_row(t, position, row.values, row.id); put_err.kind != .None {
			return error_wrap(put_err, put_err.kind, "cannot grow index %s: %s", index.name, put_err.message)
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
	if put_err := table_index_put_row(add.table, add.position, row.values, row.id); put_err.kind != .None {
		add.err = put_err
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
		index_tree_free(&t.indexes[i])
		table_index_map_free(t, i)
		table_index_detach_pages(t, i, true)
		index_exprs_destroy(t.indexes[i].exprs)
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
	if len(index.where_sql) > 0 do out.where_sql = strings.clone(index.where_sql, alloc)
	if len(index.exprs) > 0 {
		out.exprs = make([]string, len(index.exprs), alloc)
		for text, i in index.exprs do out.exprs[i] = strings.clone(text, alloc)
	}
	return out
}
