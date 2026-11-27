package engine

// An index of a table (A2): its structures (the memory tree, the integer keys,
// the equality map of HASH and DIRECT, the pages of a paged table), the keys
// it files a row under, and the procedures that keep and read it. The rows
// themselves are table.odin's.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:strings"
import "core:slice"

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

@(private)
index_cmp :: proc(a, b: string) -> slice.Ordering {
	return slice.Ordering(text_compare(a, b))
}

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

// --- An index's life ---------------------------------------------------------

// index_make is a new, empty index for `schema`. An index that failed to parse
// its partial or expression parts comes back with what was made, for the
// caller's table to free with the rest.
index_make :: proc(schema: Index_Schema) -> (index: Index, err: Error) {
	index = Index {
		schema = schema,
		unique = schema.unique,
		lookup = make(map[string]^Index_Bucket),
	}
	index_tree_init(&index)
	exprs, exprs_err := index_exprs_make(schema)
	if exprs_err.kind != .None do return index, exprs_err
	index.exprs = exprs
	return index, ERROR_NONE
}

// index_share is a copy of `from` for the table a commit writes: the memory
// tree is shared, and the copy copies a node when it first writes one; the
// equality map and the integer keys are copied; a partial or expression index
// evaluates its own parsed copy.
index_share :: proc(from: ^Index) -> (target: Index, err: Error) {
	target = Index {
		schema    = from.schema,
		unique    = from.unique,
		lookup    = make(map[string]^Index_Bucket),
		int_keyed = from.int_keyed,
	}
	if from.exprs != nil {
		exprs, exprs_err := index_exprs_make(from.schema)
		if exprs_err.kind != .None do return target, exprs_err
		target.exprs = exprs
	}
	ib_share(&target.tree, &from.tree)
	index_lookup_clone(from, &target, context.allocator)
	index_ints_clone(from, &target)
	return target, ERROR_NONE
}

// table_index_free frees what the index at `index` of `t` holds: its tree, its
// integer keys, its equality map, its pages (and their file, with
// `remove_file`) and its parsed parts.
table_index_free :: proc(t: ^Table, index: int, remove_file: bool) {
	index_tree_free(&t.indexes[index])
	table_index_map_free(t, index)
	table_index_detach_pages(t, index, remove_file)
	index_exprs_destroy(t.indexes[index].exprs)
}

// table_index_clear empties the index at `index` of `t`, keeping what it is: a
// paged index clears its pages, a memory one starts a new tree.
table_index_clear :: proc(t: ^Table, index: int) {
	if t.indexes[index].pages != nil {
		error_drop(ordered_clear(t.indexes[index].pages))
	} else {
		index_tree_free(&t.indexes[index])
		index_tree_init(&t.indexes[index])
	}
	table_index_map_free(t, index)
	t.indexes[index].lookup = make(map[string]^Index_Bucket)
}

// index_paged_memory is what a paged index costs: its entries, and its buffer
// pool's resident pages. A memory index answers 0: its keys are counted with
// the rows (table_memory).
index_paged_memory :: proc(index: ^Index) -> (entries: int, bytes: int) {
	if index.pages == nil do return 0, 0
	return int(ordered_entries(index.pages)), page_resident(index.pages.file) * PAGE_SIZE
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
