package engine

import "core:mem"
import "core:strings"

import "base:intrinsics"

// --- Window functions ------------------------------------------------------

// Window_Cell holds what one output row needs for one window expression: the
// keys that decide its partition and its position, and the evaluated arguments
// that lag/lead/first_value read from other rows.
Window_Cell :: struct {
	partition: []u8,
	order:     []u8,
	args:      []Value,
	// filtered_out is a grouped row the call's FILTER leaves out of every
	// frame, decided when the row's values are captured.
	filtered_out: bool,
}

// window_partition_key encodes the PARTITION BY values of the current row.
window_partition_key :: proc(ctx: ^Eval_Ctx, window: Window_Expr) -> ([]u8, Error) {
	if len(window.partition) == 0 do return nil, ERROR_NONE
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for expr in window.partition {
		value, eval_err := eval_expr(ctx, expr)
		if eval_err.kind != .None do return nil, eval_err
		value_encode_key(&w, collation_key_value(ctx, expr, value))
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	return out, ERROR_NONE
}

// window_order_key encodes the ORDER BY clause inside OVER ().
window_order_key :: proc(ctx: ^Eval_Ctx, window: Window_Expr) -> ([]u8, Error) {
	if len(window.order_by) == 0 do return nil, ERROR_NONE
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	first_slot := ctx.host_slots != nil ? len(ctx.host_slots^) : 0
	for item, term in window.order_by {
		value, eval_err := eval_expr(ctx, item.expr)
		if eval_err.kind != .None do return nil, eval_err
		// A host collation leaves a slot for the value's rank, filled before
		// the windows are sorted (collations.odin).
		if host, is_host := host_order_collation(ctx, item.expr); is_host {
			host_slot_append(ctx, &w, item, WINDOW_ORDER_TERM + term, value, host)
			continue
		}
		collation, has := collate_name(item.expr)
		if !has {
			collation, has = column_collation(ctx, item.expr)
		}
		if has && len(collation) > 0 {
			value = collate_ordered_value(value, collation)
		}
		order_key_append(&w, value, item)
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	if ctx.host_slots != nil {
		for &slot in ctx.host_slots^[first_slot:] do slot.key = out
	}
	return out, ERROR_NONE
}

// window_is_known tells whether a function name has a window implementation.
window_is_known :: proc(name: string) -> bool {
	return strings.equal_fold(name, "row_number") ||
		strings.equal_fold(name, "rank") ||
		strings.equal_fold(name, "dense_rank") ||
		strings.equal_fold(name, "percent_rank") ||
		strings.equal_fold(name, "cume_dist") ||
		strings.equal_fold(name, "ntile") ||
		strings.equal_fold(name, "lag") ||
		strings.equal_fold(name, "lead") ||
		strings.equal_fold(name, "first_value") ||
		strings.equal_fold(name, "last_value") ||
		strings.equal_fold(name, "nth_value") ||
		is_aggregate_name(name)
}

// window_fill computes one window expression over the rows of one partition.
// `order_keys` is already sorted alongside `indexes`; with an ORDER BY clause
// the frame runs from the partition start to the last peer of each row.
window_fill :: proc(
	ctx: ^Eval_Ctx,
	window: Window_Expr,
	position: int,
	indexes: []int,
	order_keys: []string,
	rows: []Output_Row,
	cells: [][dynamic]Window_Cell,
	cell_index: int,
	sources: [][]Source,
) -> Error {
	running := len(window.order_by) > 0
	name := window.name
	if window.filter != nil && !is_aggregate_name(name) {
		return errf(.Sql_Syntax, "FILTER clause may only be used with aggregate window functions")
	}
	// A RANGE frame with an offset runs from one ORDER BY *value* to another, so the
	// values are read once for the partition. The slice lives until the function
	// ends: a `defer` inside the block below would free it as soon as the block
	// exits, which is before any frame reads it.
	order_numbers: []f64
	defer delete(order_numbers)
	if window_frame_reads_values(window.frame) {
		if len(window.order_by) != 1 {
			return errf(.Sql_Unsupported, "a RANGE frame with an offset needs exactly one ORDER BY term")
		}
		order_numbers = make([]f64, len(indexes))
		saved := ctx.sources
		for index, j in indexes {
			ctx.sources = sources[index]
			value, eval_err := eval_expr(ctx, window.order_by[0].expr)
			if eval_err.kind != .None {
				ctx.sources = saved
				return eval_err
			}
			number, is_number := value_as_f64(value)
			if !is_number {
				ctx.sources = saved
				return errf(.Sql_Unsupported, "a RANGE frame with an offset needs a numeric ORDER BY term")
			}
			order_numbers[j] = number
		}
		ctx.sources = saved
	}
	assign :: proc(rows: []Output_Row, row: int, position: int, value: Value) {
		rows[row].values[position] = value_clone(value, context.allocator)
	}
	arg_of :: proc(cells: [][dynamic]Window_Cell, row, cell_index, arg: int) -> Value {
		cell_values := cells[row][cell_index].args
		if arg < 0 || arg >= len(cell_values) do return value_null()
		return cell_values[arg]
	}
	if strings.equal_fold(name, "row_number") {
		for index, j in indexes do assign(rows, index, position, value_int(i64(j + 1)))
		return ERROR_NONE
	}
	if strings.equal_fold(name, "lag") || strings.equal_fold(name, "lead") {
		forward := strings.equal_fold(name, "lead")
		for index, j in indexes {
			offset := i64(1)
			if offset_value := arg_of(cells, index, cell_index, 1); offset_value.kind != .Null {
				if parsed, ok := value_to_i64(offset_value); ok do offset = parsed
			}
			target := i64(j) + (forward ? offset : -offset)
			if target < 0 || target >= i64(len(indexes)) {
				fallback := arg_of(cells, index, cell_index, 2)
				assign(rows, index, position, fallback)
				continue
			}
			assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
		}
		return ERROR_NONE
	}
	// Rank family: walk peer groups, which need the ORDER BY keys.
	peer_end :: proc(order_keys: []string, j: int) -> int {
		end := j
		for end + 1 < len(order_keys) && order_keys[end + 1] == order_keys[j] do end += 1
		return end
	}
	if strings.equal_fold(name, "rank") || strings.equal_fold(name, "dense_rank") ||
	   strings.equal_fold(name, "percent_rank") || strings.equal_fold(name, "cume_dist") {
		group := 0
		j := 0
		for j < len(indexes) {
			end := running ? peer_end(order_keys, j) : len(indexes) - 1
			group += 1
			for f in j ..= end {
				index := indexes[f]
				switch {
				case strings.equal_fold(name, "rank"):
					assign(rows, index, position, value_int(i64(j + 1)))
				case strings.equal_fold(name, "dense_rank"):
					assign(rows, index, position, value_int(i64(group)))
				case strings.equal_fold(name, "percent_rank"):
					denominator := len(indexes) - 1
					percent := denominator <= 0 ? 0.0 : f64(j) / f64(denominator)
					assign(rows, index, position, value_float(percent))
				case:
					assign(rows, index, position, value_float(f64(end + 1) / f64(len(indexes))))
				}
			}
			j = end + 1
		}
		return ERROR_NONE
	}
	if strings.equal_fold(name, "ntile") {
		buckets := i64(1)
		if len(indexes) > 0 {
			if value := arg_of(cells, indexes[0], cell_index, 0); value.kind != .Null {
				if parsed, ok := value_to_i64(value); ok && parsed > 0 do buckets = parsed
			}
		}
		for index, j in indexes {
			bucket := i64(j) * buckets / i64(len(indexes)) + 1
			assign(rows, index, position, value_int(bucket))
		}
		return ERROR_NONE
	}
	if strings.equal_fold(name, "first_value") || strings.equal_fold(name, "last_value") ||
	   strings.equal_fold(name, "nth_value") {
		if window.frame.has {
			for index, j in indexes {
				lo, hi, frame_err := window_frame_bounds(window.frame, j, len(indexes), ctx.params, order_keys, order_numbers)
				if frame_err.kind != .None do return frame_err
				target := lo
				switch {
				case strings.equal_fold(name, "last_value"):
					target = hi
				case strings.equal_fold(name, "nth_value"):
					wanted := i64(1)
					if value := arg_of(cells, index, cell_index, 1); value.kind != .Null {
						if parsed, ok := value_to_i64(value); ok do wanted = parsed
					}
					if wanted < 1 || lo > hi || int(wanted) > hi - lo + 1 {
						assign(rows, index, position, value_null())
						continue
					}
					target = lo + int(wanted) - 1
				}
				if lo > hi {
					assign(rows, index, position, value_null())
					continue
				}
				assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
			}
			return ERROR_NONE
		}
		for index, j in indexes {
			target := 0
			switch {
			case strings.equal_fold(name, "last_value"):
				target = running ? peer_end(order_keys, j) : len(indexes) - 1
			case strings.equal_fold(name, "nth_value"):
				wanted := i64(1)
				if value := arg_of(cells, index, cell_index, 1); value.kind != .Null {
					if parsed, ok := value_to_i64(value); ok do wanted = parsed
				}
				if wanted < 1 || wanted > i64(len(indexes)) do continue
				target = int(wanted - 1)
			}
			assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
		}
		return ERROR_NONE
	}
	// Aggregate windows reuse the group aggregate: the frame is a group.
	call := Call_Expr {
		name        = window.name,
		args        = window.args,
		star        = window.star,
		is_distinct = window.is_distinct,
		filter      = window.filter,
	}
	// A program's window function is fed incrementally, as SQLite feeds it.
	if def, is_host := store_aggregate(ctx.tx.store, window.name, len(window.args)); is_host && def.value != nil && def.inverse != nil && window.filter == nil && !window.is_distinct {
		return window_host_frames(ctx, window, def, cells, indexes, cell_index, sources, order_keys, order_numbers, running, rows, position)
	}
	if window.frame.has {
		for j in 0 ..< len(indexes) {
			lo, hi, frame_err := window_frame_bounds(window.frame, j, len(indexes), ctx.params, order_keys, order_numbers)
			if frame_err.kind != .None do return frame_err
			window_frames += 1
			value, agg_err := window_aggregate_frame(ctx, window, call, cells, indexes, lo, hi, cell_index, sources)
			window_frames -= 1
			if agg_err.kind != .None do return agg_err
			assign(rows, indexes[j], position, value)
		}
		return ERROR_NONE
	}
	j := 0
	for j < len(indexes) {
		end := running ? peer_end(order_keys, j) : len(indexes) - 1
		// The frame of a running window is the partition up to the last peer of this
		// row, not the row alone: `sum(n) OVER (ORDER BY k)` is cumulative.
		window_frames += 1
		value, agg_err := window_aggregate_frame(ctx, window, call, cells, indexes, 0, end, cell_index, sources)
		window_frames -= 1
		if agg_err.kind != .None do return agg_err
		for f in j ..= end do assign(rows, indexes[f], position, value)
		j = end + 1
	}
	return ERROR_NONE
}

// window_host_frames feeds a program's window function as SQLite does: one
// group for the partition, xStep for each row that enters the frame, xInverse
// for each row that leaves it, xValue for each row's answer, and xFinal once
// at the end, also after an error, so the program can free its state.
@(private)
window_host_frames :: proc(
	ctx: ^Eval_Ctx,
	window: Window_Expr,
	def: Aggregate_Function_Def,
	cells: [][dynamic]Window_Cell,
	indexes: []int,
	cell_index: int,
	sources: [][]Source,
	order_keys: []string,
	order_numbers: []f64,
	running: bool,
	rows: []Output_Row,
	position: int,
) -> Error {
	group := Aggregate_Group{user = def.user, window = true}
	args := make([]Value, len(window.args))
	defer delete(args)
	// row_args reads the arguments of the partition's row f.
	row_args :: proc(ctx: ^Eval_Ctx, window: Window_Expr, cells: [][dynamic]Window_Cell, indexes: []int, cell_index: int, sources: [][]Source, f: int, args: []Value) -> Error {
		if len(sources) != 0 {
			sub := ctx^
			sub.sources = sources[indexes[f]]
			for arg, i in window.args {
				value, err := eval_expr(&sub, arg)
				if err.kind != .None do return err
				args[i] = value
			}
			return ERROR_NONE
		}
		captured := cells[indexes[f]][cell_index].args
		for i in 0 ..< len(args) do args[i] = i < len(captured) ? captured[i] : value_null()
		return ERROR_NONE
	}
	failure: Error
	// The rows [first, last] are in the group.
	first, last := 0, -1
	rows_loop: for j in 0 ..< len(indexes) {
		lo, hi: int
		switch {
		case window.frame.has:
			frame_err: Error
			lo, hi, frame_err = window_frame_bounds(window.frame, j, len(indexes), ctx.params, order_keys, order_numbers)
			if frame_err.kind != .None {
				failure = frame_err
				break rows_loop
			}
		case running:
			lo, hi = 0, j
			for hi + 1 < len(order_keys) && order_keys[hi + 1] == order_keys[j] do hi += 1
		case:
			lo, hi = 0, len(indexes) - 1
		}
		if first > last do first = max(lo, last + 1)
		for f in max(last + 1, lo) ..= hi {
			if err := row_args(ctx, window, cells, indexes, cell_index, sources, f, args); err.kind != .None {
				failure = err
				break rows_loop
			}
			if err := def.step(&group, args); err.kind != .None {
				failure = err
				break rows_loop
			}
			last = f
		}
		for f in first ..= min(last, lo - 1) {
			if err := row_args(ctx, window, cells, indexes, cell_index, sources, f, args); err.kind != .None {
				failure = err
				break rows_loop
			}
			if err := def.inverse(&group, args); err.kind != .None {
				failure = err
				break rows_loop
			}
			first = f + 1
		}
		answer, value_err := def.value(&group)
		if value_err.kind != .None {
			failure = value_err
			break rows_loop
		}
		assign_value := value_clone(answer, context.allocator)
		value_deep_free(answer, context.allocator)
		rows[indexes[j]].values[position] = assign_value
	}
	if failure.kind != .None do group.failed = true
	// SQLite drops the final's answer and its error over a window.
	closing, final_err := def.final(&group)
	value_deep_free(closing, context.allocator)
	error_free(&final_err)
	return failure
}

// window_frame_reads_values reports whether a frame is measured in the ORDER BY
// value rather than in rows or peer groups.
@(private)
window_frame_reads_values :: proc(frame: Window_Frame) -> bool {
	if !frame.has || frame.unit != .Range do return false
	return frame.start.offset != nil || frame.end.offset != nil
}

// window_peer_start and window_peer_end find the first and last position that sort
// equally with `j`, which is what CURRENT ROW means in a RANGE or GROUPS frame.
@(private)
window_peer_start :: proc(order_keys: []string, j: int) -> int {
	start := j
	for start > 0 && order_keys[start - 1] == order_keys[j] do start -= 1
	return start
}

@(private)
window_peer_end :: proc(order_keys: []string, j: int) -> int {
	end := j
	for end + 1 < len(order_keys) && order_keys[end + 1] == order_keys[j] do end += 1
	return end
}

// window_frame_bounds turns a frame into the inclusive range of partition
// positions it covers for row `j`. An empty frame (lo > hi) is legal: the
// aggregate over no rows still has a value (count 0, sum NULL).
//
// ROWS counts rows. GROUPS counts peer groups, so 1 PRECEDING is the group before
// this one. RANGE without an offset means the peers of the row; with an offset it
// runs from the ORDER BY value that far below to the value that far above, which
// is why it needs one numeric ordering term.
@(private)
window_frame_bounds :: proc(
	frame: Window_Frame,
	j: int,
	count: int,
	params: []Value,
	order_keys: []string,
	order_numbers: []f64,
) -> (lo: int, hi: int, err: Error) {
	rows_offset :: proc(bound: Frame_Bound, params: []Value) -> (int, Error) {
		offset := i64(1)
		if bound.offset != nil {
			value, constant := eval_constant(bound.offset, params)
			if !constant do return 0, errf(.Invalid_Argument, "a frame offset must be a constant")
			parsed, ok := value_to_i64(value)
			if !ok || parsed < 0 {
				return 0, errf(.Invalid_Argument, "a frame offset must be a non-negative integer")
			}
			offset = parsed
		}
		return int(offset), ERROR_NONE
	}
	value_offset :: proc(bound: Frame_Bound, params: []Value) -> (f64, Error) {
		if bound.offset == nil do return 1, ERROR_NONE
		value, constant := eval_constant(bound.offset, params)
		if !constant do return 0, errf(.Invalid_Argument, "a frame offset must be a constant")
		number, ok := value_as_f64(value)
		if !ok || number < 0 {
			return 0, errf(.Invalid_Argument, "a frame offset must be a non-negative number")
		}
		return number, ERROR_NONE
	}
	if count == 0 do return 0, -1, ERROR_NONE
	if !frame.has do return 0, count - 1, ERROR_NONE

	switch frame.unit {
	case .Rows:
		bound_position :: proc(bound: Frame_Bound, j: int, is_start: bool, count: int, params: []Value) -> (int, Error) {
			switch bound.kind {
			case .Unbounded_Preceding:
				if !is_start do return 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
				return 0, ERROR_NONE
			case .Unbounded_Following:
				if is_start do return 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
				return count, ERROR_NONE
			case .Current_Row:
				return j, ERROR_NONE
			case .Preceding, .Following:
				offset, offset_err := rows_offset(bound, params)
				if offset_err.kind != .None do return 0, offset_err
				if bound.kind == .Preceding do return j - offset, ERROR_NONE
				return j + offset, ERROR_NONE
			}
			return 0, ERROR_NONE
		}
		start, lo_err := bound_position(frame.start, j, true, count, params)
		if lo_err.kind != .None do return 0, 0, lo_err
		end, hi_err := bound_position(frame.end, j, false, count, params)
		if hi_err.kind != .None do return 0, 0, hi_err
		lo = start
		hi = end
		if lo < 0 do lo = 0
		if hi > count - 1 do hi = count - 1
		return lo, hi, ERROR_NONE

	case .Groups:
		// Where each peer group starts, so a bound can name a group instead of a row.
		group_index := make([]int, count)
		defer delete(group_index)
		group_first := make([dynamic]int, 0, count)
		defer delete(group_first)
		for k in 0 ..< count {
			if k == 0 || order_keys[k] != order_keys[k - 1] do append(&group_first, k)
			group_index[k] = len(group_first) - 1
		}
		group_end :: proc(group_first: []int, group: int, count: int) -> int {
			if group + 1 < len(group_first) do return group_first[group + 1] - 1
			return count - 1
		}
		current := group_index[j]
		switch frame.start.kind {
		case .Unbounded_Preceding:
			lo = 0
		case .Current_Row:
			lo = group_first[current]
		case .Preceding:
			offset, offset_err := rows_offset(frame.start, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			lo = group_first[max(current - offset, 0)]
		case .Following:
			offset, offset_err := rows_offset(frame.start, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			target := current + offset
			lo = target < len(group_first) ? group_first[target] : count
		case .Unbounded_Following:
			return 0, 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
		}
		switch frame.end.kind {
		case .Unbounded_Following:
			hi = count - 1
		case .Current_Row:
			hi = group_end(group_first[:], current, count)
		case .Preceding:
			offset, offset_err := rows_offset(frame.end, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			target := current - offset
			hi = target >= 0 ? group_end(group_first[:], target, count) : -1
		case .Following:
			offset, offset_err := rows_offset(frame.end, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			hi = group_end(group_first[:], min(current + offset, len(group_first) - 1), count)
		case .Unbounded_Preceding:
			return 0, 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
		}
		if lo < 0 do lo = 0
		if hi > count - 1 do hi = count - 1
		return lo, hi, ERROR_NONE

	case .Range:
		if frame.start.offset == nil && frame.end.offset == nil {
			// No offsets: the frame is made of peers.
			switch frame.start.kind {
			case .Unbounded_Preceding:
				lo = 0
			case .Current_Row:
				lo = window_peer_start(order_keys, j)
			case .Unbounded_Following:
				return 0, 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
			case .Preceding, .Following:
				return 0, 0, errf(.Sql_Syntax, "a RANGE frame in this position needs an offset")
			}
			switch frame.end.kind {
			case .Unbounded_Following:
				hi = count - 1
			case .Current_Row:
				hi = window_peer_end(order_keys, j)
			case .Unbounded_Preceding:
				return 0, 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
			case .Preceding, .Following:
				return 0, 0, errf(.Sql_Syntax, "a RANGE frame in this position needs an offset")
			}
			return lo, hi, ERROR_NONE
		}
		if len(order_numbers) != count {
			return 0, 0, errf(.Sql_Unsupported, "a RANGE frame with an offset needs one numeric ORDER BY term")
		}
		ascending := count < 2 || order_numbers[count - 1] >= order_numbers[0]
		// The first position whose value is on the wanted side of `target`, walking
		// the partition in its own direction.
		find_first :: proc(values: []f64, target: f64, ascending: bool, at_least: bool) -> int {
			low, high := 0, len(values)
			for low < high {
				middle := (low + high) / 2
				value := values[middle]
				before := ascending ? value < target : value > target
				after := ascending ? value > target : value < target
				// before < target < after, in the partition's direction.
				reached := at_least ? !before : after
				if reached {
					high = middle
				} else {
					low = middle + 1
				}
			}
			return low
		}
		current := order_numbers[j]
		switch frame.start.kind {
		case .Unbounded_Preceding:
			lo = 0
		case .Current_Row:
			lo = window_peer_start(order_keys, j)
		case .Preceding:
			offset, offset_err := value_offset(frame.start, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			lo = find_first(order_numbers, ascending ? current - offset : current + offset, ascending, true)
		case .Following:
			offset, offset_err := value_offset(frame.start, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			lo = find_first(order_numbers, ascending ? current + offset : current - offset, ascending, true)
		case .Unbounded_Following:
			return 0, 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
		}
		switch frame.end.kind {
		case .Unbounded_Following:
			hi = count - 1
		case .Current_Row:
			hi = window_peer_end(order_keys, j)
		case .Preceding:
			offset, offset_err := value_offset(frame.end, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			hi = find_first(order_numbers, ascending ? current - offset : current + offset, ascending, false) - 1
		case .Following:
			offset, offset_err := value_offset(frame.end, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			hi = find_first(order_numbers, ascending ? current + offset : current - offset, ascending, false) - 1
		case .Unbounded_Preceding:
			return 0, 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
		}
		if lo < 0 do lo = 0
		if hi > count - 1 do hi = count - 1
		return lo, hi, ERROR_NONE
	}
	return 0, count - 1, ERROR_NONE
}

// window_aggregate_over evaluates an aggregate over positions [lo, hi] of the
// partition. An empty range is an empty group, not an error.
@(private)
// window_frames counts the window frames being aggregated on this thread: a
// program's window function answers a frame with its xValue
// (sqlite3_create_window_function).
@(thread_local)
window_frames: int

// window_frame_running reports an aggregate computed for a window frame.
window_frame_running :: proc() -> bool {
	return window_frames > 0
}

window_aggregate_over :: proc(
	ctx: ^Eval_Ctx,
	call: Call_Expr,
	sources: [][]Source,
	indexes: []int,
	lo: int,
	hi: int,
) -> (Value, Error) {
	if lo > hi {
		ctx.group = nil
		ctx.grouped = true
		defer ctx.grouped = false
		return eval_aggregate(ctx, call)
	}
	frame := make([][]Source, hi - lo + 1)
	defer delete(frame)
	for f in lo ..= hi do frame[f - lo] = sources[indexes[f]]
	ctx.group = frame
	ctx.grouped = true
	value, agg_err := eval_aggregate(ctx, call)
	ctx.group = nil
	ctx.grouped = false
	return value, agg_err
}

// eval_aggregate_values is eval_aggregate over values instead of sources. A
// grouped row has no row behind it - its window argument is an aggregate that was
// already evaluated for the group - so the frame is the captured values, and the
// rules are the ones eval_aggregate applies (same comparisons, same integer versus
// float accumulation, same DISTINCT keys) so `sum(count(*)) OVER ()` answers what
// `sum(n)` over a subquery of the same groups answers.
@(private)
eval_aggregate_values :: proc(ctx: ^Eval_Ctx, call: Call_Expr, values: []Value) -> (Value, Error) {
	name := strings.to_lower(call.name)
	defer delete(name)
	if !builtin_aggregate_name(name) do return eval_host_aggregate_values(ctx, call, values)
	if plain, is_jsonb := jsonb_aggregate_plain(call); is_jsonb {
		text, err := eval_aggregate_values(ctx, plain, values)
		if err.kind != .None do return {}, err
		return jsonb_from_text(text)
	}
	if name == "count" {
		if call.star || len(call.args) == 0 do return value_int(i64(len(values))), ERROR_NONE
		count := 0
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		for value in values {
			if value.kind == .Null do continue
			if call.is_distinct {
				key := agg_distinct_key(collation_key_value(ctx, call.args[0], value))
				_, repeated := keys[key]
				if repeated {
					delete(key)
				} else {
					keys[key] = true
				}
				if repeated do continue
			}
			count += 1
		}
		return value_int(i64(count)), ERROR_NONE
	}
	if name == "group_concat" || name == "string_agg" {
		separator := ","
		separator_text: string
		if len(call.args) == 2 {
			value, eval_err := eval_expr(ctx, call.args[1])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind != .Null {
				separator_text = value_format(value, context.allocator)
				separator = separator_text
			}
		}
		defer if len(separator_text) > 0 do delete(separator_text)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		seen := 0
		for value in values {
			if value.kind == .Null do continue
			if seen > 0 do strings.write_string(&builder, separator)
			strings.write_string(&builder, value_format(value, context.allocator))
			seen += 1
		}
		if seen == 0 do return value_null(), ERROR_NONE
		return value_string(strings.clone(strings.to_string(builder), context.allocator)), ERROR_NONE
	}
	if name == "array_agg" {
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		list := make([dynamic]Value, 0, len(values))
		defer delete(list)
		for value in values {
			if call.is_distinct {
				key := agg_distinct_key(collation_key_value(ctx, call.args[0], value))
				_, repeated := keys[key]
				if repeated {
					delete(key)
					continue
				}
				keys[key] = true
			}
			append(&list, value_clone(value, context.allocator))
		}
		if len(list) == 0 do return value_null(), ERROR_NONE
		items := make([]Value, len(list))
		copy(items, list[:])
		return Value{kind = .Array, list = items}, ERROR_NONE
	}
	if name != "min" && name != "max" && name != "sum" && name != "total" && name != "avg" {
		return {}, errf(.Internal, "unknown aggregate %s", name)
	}
	accumulator := value_null()
	seen := 0
	sum_int: i64
	sum_float: f64
	sum_128: i128
	// total() adds as reals from the first value, as SQLite's does: it never
	// overflows and is never an integer.
	uses_float := name == "total"
	uses_128: bool
	keys: map[string]bool
	if call.is_distinct do keys = make(map[string]bool)
	defer agg_distinct_destroy(&keys)
	for value in values {
		if value.kind == .Null do continue
		if call.is_distinct {
			key := agg_distinct_key(collation_key_value(ctx, call.args[0], value))
			_, repeated := keys[key]
			if repeated {
				delete(key)
			} else {
				keys[key] = true
			}
			if repeated do continue
		}
		seen += 1
		switch name {
		case "min":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "min() mixes incompatible types")
				if order == .Less do accumulator = value
			}
		case "max":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "max() mixes incompatible types")
				if order == .Greater do accumulator = value
			}
		case "sum", "total", "avg":
			// SQLite adds a boolean as its integer and a text by its number.
			operand := sqlite_rules_on() ? sqlite_sum_operand(value) : value
			if !value_is_numeric(operand) {
				return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			}
			if operand.kind == .Float && !uses_float {
				// The integers added before the first REAL are part of the sum: SQLite's
				// sum() of 1 and 2.5 is 3.5. It used to answer 2.5.
				uses_float = true
				sum_float = uses_128 ? f64(sum_128) : f64(sum_int)
			}
			if uses_float {
				number, _ := value_to_f64(operand)
				sum_float += number
			} else if operand.kind == .Int128 || operand.kind == .Uint128 {
				if !uses_128 {
					uses_128 = true
					sum_128 = i128(sum_int)
				}
				sum_128 += value_as_i128(operand)
			} else if uses_128 {
				number, _ := value_to_i64(operand)
				sum_128 += i128(number)
			} else {
				number, _ := value_to_i64(operand)
				// A sum that leaves 64 bits is an error, as in SQLite: it used to wrap.
				total, overflow := intrinsics.overflow_add(sum_int, number)
				if overflow do return {}, integer_overflow_error()
				sum_int = total
			}
		}
	}
	switch name {
	case "min", "max":
		return value_clone(accumulator, context.allocator), ERROR_NONE
	case "total":
		return value_float(sum_float), ERROR_NONE
	case "sum":
		if seen == 0 do return value_null(), ERROR_NONE
		if uses_float do return value_float(sum_float), ERROR_NONE
		if uses_128 do return value_int128(sum_128), ERROR_NONE
		return value_int(sum_int), ERROR_NONE
	case "avg":
		if seen == 0 do return value_null(), ERROR_NONE
		total := uses_float ? sum_float : (uses_128 ? f64(sum_128) : f64(sum_int))
		return value_float(total / f64(seen)), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown aggregate %s", name)
}

// window_aggregate_frame aggregates rows [lo, hi] of one window. When the row has
// a source the aggregate is evaluated over it exactly as before; when it has none
// (a grouped row) the frame is the argument values the group captured.
@(private)
window_aggregate_frame :: proc(
	ctx: ^Eval_Ctx,
	window: Window_Expr,
	call: Call_Expr,
	cells: [][dynamic]Window_Cell,
	indexes: []int,
	lo, hi, cell_index: int,
	sources: [][]Source,
) -> (Value, Error) {
	if len(sources) != 0 {
		return window_aggregate_over(ctx, call, sources, indexes, lo, hi)
	}
	// Over grouped rows a frame holds values; a FILTER was decided when they
	// were captured, so a row it leaves out is skipped here.
	if lo > hi do return value_null(), ERROR_NONE
	values := make([dynamic]Value, 0, hi - lo + 1)
	defer delete(values)
	for f in lo ..= hi {
		cell := cells[indexes[f]][cell_index]
		if cell.filtered_out do continue
		if window.star || len(cell.args) == 0 {
			// count(*) over the frame: one non-null stand-in per row.
			append(&values, value_int(1))
			continue
		}
		append(&values, cell.args[0])
	}
	plain := call
	plain.filter = nil
	return eval_aggregate_values(ctx, plain, values[:])
}

// window_sort orders the row indexes of a partition by their ORDER BY keys.
// Insertion sort keeps equal keys in row order, which the peer logic relies on.
window_sort :: proc(indexes: []int, order_keys: []string) {
	for j in 1 ..< len(indexes) {
		current := indexes[j]
		current_key := order_keys[j]
		at := j
		for at > 0 && order_keys[at - 1] > current_key {
			indexes[at] = indexes[at - 1]
			order_keys[at] = order_keys[at - 1]
			at -= 1
		}
		indexes[at] = current
		order_keys[at] = current_key
	}
}

// apply_windows fills every window projection once all output rows exist.
apply_windows :: proc(
	ctx: ^Eval_Ctx,
	nodes: []^Expr,
	slots: []int,
	cells: [][dynamic]Window_Cell,
	rows: []Output_Row,
	sources: [][]Source,
) -> Error {
	for node, cell_index in nodes {
		position := slots[cell_index]
		window := node^.(Window_Expr)
		if !window_is_known(window.name) {
			return errf(.Sql_Unsupported, "unknown window function %s()", window.name)
		}
		if len(window.partition) == 0 {
			indexes := make([]int, len(rows))
			order_keys := make([]string, len(rows))
			for _, i in rows {
				indexes[i] = i
				order_keys[i] = string(cells[i][cell_index].order)
			}
			window_sort(indexes, order_keys)
			if fill_err := window_fill(ctx, window, position, indexes, order_keys, rows, cells, cell_index, sources); fill_err.kind != .None {
				delete(indexes)
				delete(order_keys)
				return fill_err
			}
			delete(indexes)
			delete(order_keys)
			continue
		}
		buckets := make(map[string][dynamic]int)
		keys := make([dynamic]string)
		for _, i in rows {
			key := string(cells[i][cell_index].partition)
			bucket, exists := buckets[key]
			if !exists do append(&keys, strings.clone(key))
			append(&bucket, i)
			buckets[key] = bucket
		}
		for key in keys {
			indexes := buckets[key]
			order_keys := make([]string, len(indexes))
			for index, j in indexes do order_keys[j] = string(cells[index][cell_index].order)
			window_sort(indexes[:], order_keys)
			fill_err := window_fill(ctx, window, position, indexes[:], order_keys, rows, cells, cell_index, sources)
			delete(order_keys)
			delete(indexes)
			delete(key)
			if fill_err.kind != .None {
				for other in keys {
					if other == key do continue
					delete(other)
				}
				return fill_err
			}
		}
		delete(keys)
		delete(buckets)
	}
	return ERROR_NONE
}

// window_row_cells evaluates one row's window cells: the partition key, the order
// key and the arguments, each with the context the row is being read under, so a
// grouped row answers an aggregate and an ungrouped one answers a column. The
// statement's windows are metadata, so this runs before the projection: the
// projection is what puts the result in its slot.
window_row_cells :: proc(
	ctx: ^Eval_Ctx,
	nodes: []^Expr,
	has_windows: bool,
) -> ([dynamic]Window_Cell, Error) {
	cells := make([dynamic]Window_Cell, 0, len(nodes))
	if !has_windows do return cells, ERROR_NONE
	for node in nodes {
		window := node^.(Window_Expr)
		partition_key, partition_err := window_partition_key(ctx, window)
		if partition_err.kind != .None do return cells, partition_err
		order_key, order_err := window_order_key(ctx, window)
		if order_err.kind != .None {
			delete(partition_key)
			return cells, order_err
		}
		args := make([]Value, len(window.args))
		for arg, a in window.args {
			arg_value, arg_err := eval_expr(ctx, arg)
			if arg_err.kind != .None {
				delete(partition_key)
				delete(order_key)
				free_values(args)
				return cells, arg_err
			}
			args[a] = value_clone(arg_value, context.allocator)
		}
		filtered_out := false
		if window.filter != nil {
			kept, filter_err := eval_expr(ctx, window.filter)
			if filter_err.kind != .None {
				delete(partition_key)
				delete(order_key)
				free_values(args)
				return cells, filter_err
			}
			filtered_out = !value_is_truthy(kept)
		}
		append(&cells, Window_Cell{partition = partition_key, order = order_key, args = args, filtered_out = filtered_out})
	}
	return cells, ERROR_NONE
}

@(private)
free_values_over_rows :: proc(rows: ^[dynamic]Output_Row) {
	for &row in rows {
		free_values(row.values)
		delete(row.sort_key)
		row.sort_key = nil
	}
}

// select_drop_rows frees what a SELECT built before it failed: its rows, and
// the window state they were waiting on.
@(private)
select_drop_rows :: proc(
	output: ^[dynamic]Output_Row,
	window_cells: ^[dynamic][dynamic]Window_Cell,
	window_sources: ^[dynamic][]Source,
	group_keep: ^[dynamic][dynamic][]Source,
) {
	free_values_over_rows(output)
	delete(output^)
	window_cell_rows_destroy(window_cells)
	delete(window_sources^)
	for kept in group_keep do delete(kept)
	delete(group_keep^)
}

// select_drop_groups is select_drop_rows for a grouped SELECT that failed on
// group `from`: that group and the ones after it were not handed on, and the
// lists of groups go too. (The three error paths of the grouping loop freed
// the rows but kept the output array, the window sources and every group.)
@(private)
select_drop_groups :: proc(
	output: ^[dynamic]Output_Row,
	window_cells: ^[dynamic][dynamic]Window_Cell,
	window_sources: ^[dynamic][]Source,
	group_keep: ^[dynamic][dynamic][]Source,
	groups: ^[dynamic][dynamic][]Source,
	group_set_of: ^[dynamic]int,
	from: int,
) {
	select_drop_rows(output, window_cells, window_sources, group_keep)
	for group in groups[from:] do delete(group)
	delete(groups^)
	delete(group_set_of^)
}

// window_cells_destroy frees one cell list: the keys it holds and the list itself.
@(private)
window_cells_destroy :: proc(cells: [dynamic]Window_Cell) {
	for cell in cells {
		delete(cell.partition)
		delete(cell.order)
		free_values(cell.args)
	}
	delete(cells)
}

// window_cell_rows_destroy frees the cell list of every output row.
@(private)
window_cell_rows_destroy :: proc(rows: ^[dynamic][dynamic]Window_Cell) {
	for cells in rows do window_cells_destroy(cells)
	delete(rows^)
}

// select_minmax_calls lists the query's min() and max() aggregates (calls
// with one argument): with any, SQLite reads a bare column from a row they
// chose (minmax_row).
@(private)
select_minmax_calls :: proc(projections: []^Expr, having: ^Expr, alloc: mem.Allocator) -> []^Call_Expr {
	found := make([dynamic]^Call_Expr, 0, 2, alloc)
	visit := proc(expr: ^Expr, user: rawptr) -> bool {
		found := cast(^[dynamic]^Call_Expr)user
		#partial switch &e in expr^ {
		case Call_Expr:
			if len(e.args) == 1 && !e.star && (strings.equal_fold(e.name, "min") || strings.equal_fold(e.name, "max")) {
				append(found, &e)
			}
		case Subquery_Expr:
			return false
		}
		return true
	}
	for projection in projections do expr_walk(projection, visit, &found)
	expr_walk(having, visit, &found)
	return found[:]
}

// minmax_row is the row of a group a bare column reads beside min() and
// max(), as SQLite picks it: each row is loaded unless one of them kept its
// value there (a value that is not better, or a NULL once it has one), so
// the answer is the last row every one of them took, or with a single one,
// the first row that reaches its extreme.
@(private)
minmax_row :: proc(ctx: ^Eval_Ctx, calls: []^Call_Expr, group: [][]Source) -> int {
	best := make([]Value, len(calls), context.temp_allocator)
	have := make([]bool, len(calls), context.temp_allocator)
	chosen := 0
	saved := ctx.sources
	defer ctx.sources = saved
	for row, k in group {
		ctx.sources = row
		hit := true
		for call, i in calls {
			value, err := eval_expr(ctx, call.args[0])
			if err.kind != .None {
				error_drop(err)
				hit = false
				continue
			}
			if value.kind == .Null {
				if have[i] do hit = false
				continue
			}
			if have[i] {
				order, ok := value_compare(value, best[i])
				better := ok && order != .Equal && (order == .Greater) == strings.equal_fold(call.name, "max")
				if !better {
					hit = false
					continue
				}
			}
			best[i], have[i] = value, true
		}
		if hit do chosen = k
	}
	return chosen
}

// Expr_Visit returns whether the walk should descend into the node it was given.
Expr_Visit :: #type proc(expr: ^Expr, user: rawptr) -> bool

// expr_walk visits every expression of a tree, parents before children, and is the
// one place that knows the shape of every node: a new expression type must be added
// here, or everything built on the walk silently misses its subtree. A window's
// arguments are not descended into - SQL does not put a window inside a window -
// and a subquery's windows belong to the SELECT of the subquery.
expr_walk :: proc(expr: ^Expr, visit: Expr_Visit, user: rawptr) {
	if expr == nil do return
	if !visit(expr, user) do return
	#partial switch e in expr^ {
	case Binary_Expr:
		expr_walk(e.left, visit, user)
		expr_walk(e.right, visit, user)
	case Unary_Expr:
		expr_walk(e.operand, visit, user)
	case Is_Null_Expr:
		expr_walk(e.operand, visit, user)
	case Between_Expr:
		expr_walk(e.operand, visit, user)
		expr_walk(e.low, visit, user)
		expr_walk(e.high, visit, user)
	case In_Expr:
		expr_walk(e.operand, visit, user)
		for item in e.items do expr_walk(item, visit, user)
	case Like_Expr:
		expr_walk(e.operand, visit, user)
		expr_walk(e.pattern, visit, user)
	case Match_Expr:
		expr_walk(e.operand, visit, user)
		expr_walk(e.pattern, visit, user)
	case Cast_Expr:
		expr_walk(e.operand, visit, user)
	case Collate_Expr:
		expr_walk(e.operand, visit, user)
	case Call_Expr:
		for arg in e.args do expr_walk(arg, visit, user)
		expr_walk(e.filter, visit, user)
		for item in e.order_by do expr_walk(item.expr, visit, user)
	case Case_Expr:
		expr_walk(e.operand, visit, user)
		for branch in e.branches {
			expr_walk(branch.condition, visit, user)
			expr_walk(branch.result, visit, user)
		}
		expr_walk(e.fallback, visit, user)
	}
}

@(private)
collect_window_visit :: proc(expr: ^Expr, user: rawptr) -> bool {
	if _, is_window := expr^.(Window_Expr); is_window {
		append(cast(^[dynamic]^Expr)user, expr)
		return false
	}
	return true
}

// expr_collect_windows appends every window expression inside `expr`, outermost
// first. It is what gives a window nested in a larger projection a slot of its own.
expr_collect_windows :: proc(expr: ^Expr, out: ^[dynamic]^Expr) {
	expr_walk(expr, collect_window_visit, rawptr(out))
}

@(private)
has_window_visit :: proc(expr: ^Expr, user: rawptr) -> bool {
	if _, is_window := expr^.(Window_Expr); is_window {
		found := cast(^bool)user
		found^ = true
		return false
	}
	return true
}

// expr_has_window reports whether a projection needs the whole scan, which a window
// anywhere in it does: its frame is the table.
expr_has_window :: proc(expr: ^Expr) -> bool {
	found := false
	expr_walk(expr, has_window_visit, rawptr(&found))
	return found
}

// window_positions lists the projection indexes that hold a window expression.
window_positions_of :: proc(expanded: []^Expr) -> []int {
	positions := make([dynamic]int)
	for expr, i in expanded {
		if _, is_window := expr^.(Window_Expr); is_window do append(&positions, i)
	}
	return positions[:]
}

// window_cell_for reports whether a projection index holds a window expression.
window_cell_for :: proc(positions: []int, index: int) -> int {
	for position, at in positions {
		if position == index do return at
	}
	return -1
}
