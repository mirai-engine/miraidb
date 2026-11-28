package engine

import "core:sync"

// Row_Blocks holds a memory table's rows, tombstones included, in ascending id
// order, in blocks of up to ROW_BLOCK rows (R7). A block is shared between the
// table a reader holds and the copy a commit writes (table_cow_clone): the copy
// takes the list of blocks and a reference to each, and copies a block only
// when it changes one of its rows (rows_block_mut). The rows were one slice,
// and the commit copied all of it: 4 MB and 1.5-13 ms over 50 000 rows, most
// of it first touches of new memory; it copies a list of pointers now, and
// then the blocks it writes.
//
// A block owns the history arrays of its rows (Row.versions): a copy of the
// block copies them, and the last reference frees them. It owns none of the
// values: those belong to the table that stored them, which frees them, or
// hands them to the shared store while a reader may read them (Row_Store).
//
// No block is empty, and the blocks are in id order; one block may hold fewer
// than ROW_BLOCK rows wherever a row was put between two others or taken out.
Row_Blocks :: struct {
	blocks: [dynamic]^Row_Block,
	count:  int,
	// dense says every block is full but the last and no id is missing: row
	// `id` is then at `id - first`, found without reading a block first. A
	// lookup that read the first block and the row's block before the row took
	// twice the time of the slice it replaced (an index filter, R7).
	dense:  bool,
	first:  Row_Id,
}

ROW_BLOCK :: 256
ROW_BLOCK_SHIFT :: 8

#assert(1 << ROW_BLOCK_SHIFT == ROW_BLOCK)

Row_Block :: struct {
	// refs counts the tables that list this block. Only the writer adds one,
	// under the store's lock; a reader ending on its own thread drops one.
	refs:  int,
	count: int,
	rows:  [ROW_BLOCK]Row,
}

// A row's place: its block times ROW_BLOCK plus its slot, or -1 for none. It
// is good until the table puts a row between others or takes one out.
Row_Pos :: int

@(private)
row_block_new :: proc() -> ^Row_Block {
	block := new(Row_Block)
	if block != nil do block.refs = 1
	return block
}

@(private)
row_block_release :: proc(block: ^Row_Block) {
	if sync.atomic_sub(&block.refs, 1) != 1 do return
	for row in block.rows[:block.count] do delete(row.versions)
	free(block)
}

rows_len :: #force_inline proc "contextless" (r: ^Row_Blocks) -> int {
	return r.count
}

// rows_destroy drops this table's reference to each block.
rows_destroy :: proc(r: ^Row_Blocks) {
	for block in r.blocks do row_block_release(block)
	delete(r.blocks)
	r^ = {}
}

rows_clear :: proc(r: ^Row_Blocks) {
	for block in r.blocks do row_block_release(block)
	clear(&r.blocks)
	r.count = 0
	r.dense = false
	r.first = 0
}

// rows_share gives `target` the blocks of `source`, one more reference each.
rows_share :: proc(target: ^Row_Blocks, source: ^Row_Blocks) {
	target.blocks = make([dynamic]^Row_Block, len(source.blocks))
	for block, i in source.blocks {
		sync.atomic_add(&block.refs, 1)
		target.blocks[i] = block
	}
	target.count = source.count
	target.dense = source.dense
	target.first = source.first
}

// rows_block_mut is block `at`, this table's own to change: a block another
// table lists is copied first, with the history arrays of its rows.
@(private)
rows_block_mut :: proc(r: ^Row_Blocks, at: int) -> ^Row_Block {
	block := r.blocks[at]
	if sync.atomic_load(&block.refs) == 1 do return block
	own := new(Row_Block)
	own.refs = 1
	own.count = block.count
	copy(own.rows[:block.count], block.rows[:block.count])
	for &row in own.rows[:own.count] {
		if row.versions == nil do continue
		versions := make([dynamic]Row_Version, len(row.versions), max(cap(row.versions), 1))
		copy(versions[:], row.versions[:])
		row.versions = versions
	}
	r.blocks[at] = own
	row_block_release(block)
	return own
}

// rows_at is the row at `pos`, to read.
rows_at :: #force_inline proc "contextless" (r: ^Row_Blocks, pos: Row_Pos) -> ^Row {
	return &r.blocks[pos >> ROW_BLOCK_SHIFT].rows[pos & (ROW_BLOCK - 1)]
}

// rows_mut is the row at `pos`, to change in place.
rows_mut :: proc(r: ^Row_Blocks, pos: Row_Pos) -> ^Row {
	return &rows_block_mut(r, pos >> ROW_BLOCK_SHIFT).rows[pos & (ROW_BLOCK - 1)]
}

// rows_block_of is the block that holds or would hold `id`: the last one whose
// first id is not above it (the first block for an id below every row).
@(private)
rows_block_of :: proc "contextless" (r: ^Row_Blocks, id: Row_Id) -> int {
	n := len(r.blocks)
	// Ids handed out in order with none missing fill every block: try that
	// block first.
	guess := int((u64(id) - u64(r.blocks[0].rows[0].id)) >> ROW_BLOCK_SHIFT)
	if id >= r.blocks[0].rows[0].id && guess < n {
		block := r.blocks[guess]
		if block.rows[0].id <= id && (guess == n - 1 || r.blocks[guess + 1].rows[0].id > id) do return guess
	}
	low, high := 0, n
	for low < high {
		middle := (low + high) / 2
		if r.blocks[middle].rows[0].id <= id {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return max(low - 1, 0)
}

// rows_slot_of is where `id` sits in `block`, or where it would go.
@(private)
rows_slot_of :: proc "contextless" (block: ^Row_Block, id: Row_Id) -> (slot: int, found: bool) {
	guess := int(u64(id) - u64(block.rows[0].id))
	if id >= block.rows[0].id && guess < block.count && block.rows[guess].id == id do return guess, true
	low, high := 0, block.count
	for low < high {
		middle := (low + high) / 2
		if block.rows[middle].id < id {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low, low < block.count && block.rows[low].id == id
}

// rows_find is the place of row `id`, or -1. With no id missing before it, a
// row sits at `id - first`: its block and slot are read straight off that, and
// only a table with gaps searches (an index filter fetches each row it names
// this way).
rows_find :: #force_inline proc "contextless" (r: ^Row_Blocks, id: Row_Id) -> Row_Pos {
	if r.count == 0 do return -1
	if r.dense {
		at := u64(id) - u64(r.first)
		return id >= r.first && at < u64(r.count) ? int(at) : -1
	}
	return rows_find_search(r, id)
}

@(private)
rows_find_search :: proc "contextless" (r: ^Row_Blocks, id: Row_Id) -> Row_Pos {
	last := r.blocks[len(r.blocks) - 1]
	if id < r.blocks[0].rows[0].id || id > last.rows[last.count - 1].id do return -1
	at := rows_block_of(r, id)
	slot, found := rows_slot_of(r.blocks[at], id)
	return found ? at << ROW_BLOCK_SHIFT | slot : -1
}

// rows_put adds a row that is not there, at its place: an append when its id is
// the highest, which is every id the table hands out itself.
rows_put :: proc(r: ^Row_Blocks, row: Row) {
	r.count += 1
	n := len(r.blocks)
	if n == 0 {
		r.first = row.id
		r.dense = true
	} else if r.dense && row.id != r.first + Row_Id(r.count - 1) {
		r.dense = false
	}
	if n == 0 || r.blocks[n - 1].rows[r.blocks[n - 1].count - 1].id < row.id {
		if n > 0 && r.blocks[n - 1].count < ROW_BLOCK {
			block := rows_block_mut(r, n - 1)
			block.rows[block.count] = row
			block.count += 1
			return
		}
		block := row_block_new()
		block.rows[0] = row
		block.count = 1
		append(&r.blocks, block)
		return
	}
	at := rows_block_of(r, row.id)
	block := rows_block_mut(r, at)
	if block.count == ROW_BLOCK {
		// A full block gives its upper half to a new one after it.
		upper := row_block_new()
		half := ROW_BLOCK / 2
		copy(upper.rows[:half], block.rows[half:])
		upper.count = half
		block.count = half
		for &moved in block.rows[half:] do moved = {}
		inject_at(&r.blocks, at + 1, upper)
		if row.id > upper.rows[0].id do block = upper
	}
	slot, _ := rows_slot_of(block, row.id)
	copy(block.rows[slot + 1:block.count + 1], block.rows[slot:block.count])
	block.rows[slot] = row
	block.count += 1
}

// rows_compact takes out of block `at` the rows `gone` answers true for; it is
// this table's own already (the caller changed it). An emptied block leaves.
// Answers how many rows it looked at.
@(private)
rows_compact :: proc(r: ^Row_Blocks, at: int, gone: proc(row: ^Row, user: rawptr) -> bool, user: rawptr) -> int {
	block := rows_block_mut(r, at)
	write := 0
	for i in 0 ..< block.count {
		if gone(&block.rows[i], user) do continue
		block.rows[write] = block.rows[i]
		write += 1
	}
	visited := block.count
	r.count -= block.count - write
	if write < block.count do r.dense = false
	for &stale in block.rows[write:block.count] do stale = {}
	block.count = write
	if write == 0 {
		row_block_release(block)
		// (The engine's ordered_remove, of the paged index, hides the builtin.)
		copy(r.blocks[at:], r.blocks[at + 1:])
		resize(&r.blocks, len(r.blocks) - 1)
	}
	return visited
}

// Rows_Iter walks the rows of a Row_Blocks in id order. It keeps the block it
// is in and that block's row count, so the next row is one test away; reading
// the list of blocks for every row made a scan 7-14% slower than the slice.
Rows_Iter :: struct {
	r:     ^Row_Blocks,
	block: int,
	slot:  int,
	cur:   ^Row_Block,
	limit: int,
}

rows_iter :: #force_inline proc "contextless" (r: ^Row_Blocks) -> Rows_Iter {
	return Rows_Iter{r = r}
}

// rows_iter_from is an iterator that starts at the first row whose id is not
// below `id`: the block that would hold it, and its place there, found by the
// same search a lookup does.
rows_iter_from :: proc "contextless" (r: ^Row_Blocks, id: Row_Id) -> Rows_Iter {
	it := Rows_Iter{r = r}
	if r.count == 0 do return it
	at := rows_block_of(r, id)
	block := r.blocks[at]
	slot, _ := rows_slot_of(block, id)
	it.cur = block
	it.block = at + 1
	it.slot = slot
	it.limit = block.count
	return it
}

// rows_next is the next row, to read.
rows_next :: #force_inline proc "contextless" (it: ^Rows_Iter) -> (^Row, bool) {
	if it.slot < it.limit {
		row := &it.cur.rows[it.slot]
		it.slot += 1
		return row, true
	}
	return rows_next_block(it)
}

@(private)
rows_next_block :: proc "contextless" (it: ^Rows_Iter) -> (^Row, bool) {
	for it.block < len(it.r.blocks) {
		it.cur = it.r.blocks[it.block]
		it.block += 1
		it.limit = it.cur.count
		if it.limit > 0 {
			it.slot = 1
			return &it.cur.rows[0], true
		}
	}
	it.slot, it.limit = 0, 0
	return nil, false
}
