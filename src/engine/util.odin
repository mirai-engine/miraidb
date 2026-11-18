package engine

import "base:runtime"

// map_erase removes one entry from a map. The standard library in this Odin
// release no longer ships a `delete(map, key)` builtin, so every removal goes
// through the runtime's erase primitive.
map_erase :: proc(m: ^map[$K]$V, key: K) -> bool {
	k := key
	_, _, ok := runtime.map_erase_static(m, &k)
	return ok
}

// ENGINE_VERSION_TEXT is what `miraidb_version()` and SQL's `version()` answer.
// scripts/package.py names the archive after it.
ENGINE_VERSION_TEXT :: "miraidb 0.15"

// rows_sort_by_id orders rows by row id. It replaces `slice.sort_by` on the hot
// paths: that sort is a smoothsort over raw bytes that copies both 80-byte rows
// into the comparison on every step, and ordering the 256 rows a table scan
// collects (a hash map hands them out in no order) took 84 us of a scan that
// otherwise costs 3. This one is typed, so the comparison is an integer compare
// and a move is one struct copy: an introsort (median-of-three quicksort,
// insertion sort under 24 rows, heapsort when the recursion runs too deep).
rows_sort_by_id :: proc(rows: []Row) {
	if len(rows) < 2 do return
	// A scan of a table written in order is often sorted already.
	sorted := true
	for i in 1 ..< len(rows) {
		if rows[i - 1].id > rows[i].id {
			sorted = false
			break
		}
	}
	if sorted do return
	depth := 0
	for n := len(rows); n > 0; n >>= 1 do depth += 2
	rows_introsort(rows, depth)
}

@(private)
rows_introsort :: proc(rows: []Row, depth: int) {
	data := rows
	limit := depth
	for len(data) > 24 {
		if limit == 0 {
			rows_heapsort(data)
			return
		}
		limit -= 1
		pivot := rows_partition(data)
		// Recurse into the smaller side, loop on the larger: the stack stays
		// logarithmic.
		if pivot < len(data) - pivot {
			rows_introsort(data[:pivot], limit)
			data = data[pivot + 1:]
		} else {
			rows_introsort(data[pivot + 1:], limit)
			data = data[:pivot]
		}
	}
	for i in 1 ..< len(data) {
		current := data[i]
		j := i
		for j > 0 && data[j - 1].id > current.id {
			data[j] = data[j - 1]
			j -= 1
		}
		data[j] = current
	}
}

@(private)
rows_partition :: proc(data: []Row) -> int {
	last := len(data) - 1
	middle := last / 2
	// Median of three, moved to the end as the pivot.
	if data[middle].id < data[0].id do data[middle], data[0] = data[0], data[middle]
	if data[last].id < data[0].id do data[last], data[0] = data[0], data[last]
	if data[middle].id < data[last].id do data[middle], data[last] = data[last], data[middle]
	pivot := data[last].id
	store := 0
	for i in 0 ..< last {
		if data[i].id < pivot {
			data[i], data[store] = data[store], data[i]
			store += 1
		}
	}
	data[store], data[last] = data[last], data[store]
	return store
}

@(private)
rows_heapsort :: proc(data: []Row) {
	n := len(data)
	sift :: proc(data: []Row, start, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child >= end do return
			if child + 1 < end && data[child].id < data[child + 1].id do child += 1
			if data[root].id >= data[child].id do return
			data[root], data[child] = data[child], data[root]
			root = child
		}
	}
	for start := n / 2 - 1; start >= 0; start -= 1 do sift(data, start, n)
	for end := n - 1; end > 0; end -= 1 {
		data[0], data[end] = data[end], data[0]
		sift(data, 0, end)
	}
}

// row_ids_sort orders row ids in place with the same introsort, specialised to
// plain ids: `slice.sort` on 256 of them took 42 us. It allocates nothing (an
// earlier version borrowed the temp allocator, which nothing frees in a server
// that runs for days, and every commit sorts its ids).
row_ids_sort :: proc(ids: []Row_Id) {
	if len(ids) < 2 do return
	sorted := true
	for i in 1 ..< len(ids) {
		if ids[i - 1] > ids[i] {
			sorted = false
			break
		}
	}
	if sorted do return
	depth := 0
	for n := len(ids); n > 0; n >>= 1 do depth += 2
	ids_introsort(ids, depth)
}

@(private)
ids_introsort :: proc(ids: []Row_Id, depth: int) {
	data := ids
	limit := depth
	for len(data) > 24 {
		if limit == 0 {
			ids_heapsort(data)
			return
		}
		limit -= 1
		last := len(data) - 1
		middle := last / 2
		if data[middle] < data[0] do data[middle], data[0] = data[0], data[middle]
		if data[last] < data[0] do data[last], data[0] = data[0], data[last]
		if data[middle] < data[last] do data[middle], data[last] = data[last], data[middle]
		pivot := data[last]
		store := 0
		for i in 0 ..< last {
			if data[i] < pivot {
				data[i], data[store] = data[store], data[i]
				store += 1
			}
		}
		data[store], data[last] = data[last], data[store]
		if store < len(data) - store {
			ids_introsort(data[:store], limit)
			data = data[store + 1:]
		} else {
			ids_introsort(data[store + 1:], limit)
			data = data[:store]
		}
	}
	for i in 1 ..< len(data) {
		current := data[i]
		j := i
		for j > 0 && data[j - 1] > current {
			data[j] = data[j - 1]
			j -= 1
		}
		data[j] = current
	}
}

@(private)
ids_heapsort :: proc(data: []Row_Id) {
	n := len(data)
	sift :: proc(data: []Row_Id, start, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child >= end do return
			if child + 1 < end && data[child] < data[child + 1] do child += 1
			if data[root] >= data[child] do return
			data[root], data[child] = data[child], data[root]
			root = child
		}
	}
	for start := n / 2 - 1; start >= 0; start -= 1 do sift(data, start, n)
	for end := n - 1; end > 0; end -= 1 {
		data[0], data[end] = data[end], data[0]
		sift(data, 0, end)
	}
}

// rows_sort_by_key orders rows by the values of some of their columns, the
// way SQLite walks a WITHOUT ROWID table: by its primary key. A stable merge
// sort, so rows the key does not tell apart keep their order.
rows_sort_by_key :: proc(rows: []Row, key: []int) {
	if len(rows) < 2 || len(key) == 0 do return
	less :: proc(a, b: Row, key: []int) -> bool {
		for column in key {
			left := column < len(a.values) ? a.values[column] : Value{}
			right := column < len(b.values) ? b.values[column] : Value{}
			order, ok := value_compare(left, right)
			if ok && order != .Equal do return order == .Less
		}
		return false
	}
	sorted := true
	for i in 1 ..< len(rows) {
		if less(rows[i], rows[i - 1], key) {
			sorted = false
			break
		}
	}
	if sorted do return
	scratch := make([]Row, len(rows), context.temp_allocator)
	for width := 1; width < len(rows); width *= 2 {
		for start := 0; start < len(rows); start += 2 * width {
			middle := min(start + width, len(rows))
			end := min(start + 2 * width, len(rows))
			i, j, k := start, middle, start
			for i < middle && j < end {
				if less(rows[j], rows[i], key) {
					scratch[k] = rows[j]
					j += 1
				} else {
					scratch[k] = rows[i]
					i += 1
				}
				k += 1
			}
			for i < middle {
				scratch[k] = rows[i]
				i += 1
				k += 1
			}
			for j < end {
				scratch[k] = rows[j]
				j += 1
				k += 1
			}
		}
		copy(rows, scratch)
	}
}
