package engine

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "base:intrinsics"

// --- Expressions -----------------------------------------------------------

eval_expr :: proc(ctx: ^Eval_Ctx, expr: ^Expr) -> (Value, Error) {
	if expr == nil do return value_null(), ERROR_NONE
	ctx.depth += 1
	defer ctx.depth -= 1
	if ctx.depth > MAX_EXPRESSION_DEPTH {
		return value_null(), errf(
			.Sql_Unsupported,
			"expression nests deeper than %d levels",
			MAX_EXPRESSION_DEPTH,
		)
	}
	if _, is_window := expr^.(Window_Expr); is_window && ctx.window_slots != nil {
		if slot, found := ctx.window_slots[expr]; found {
			if slot >= 0 && slot < len(ctx.window_values) {
				return ctx.window_values[slot], ERROR_NONE
			}
		}
	}
	// By reference: the node copied into `e` on every evaluation was a few
	// percent of a scan, and grew with every field a node kind gains. Nothing
	// below writes through it.
	switch &e in expr^ {
	case Literal_Expr:
		return e.value, ERROR_NONE
	case Column_Expr:
		// A column the grouping set leaves out is NULL in its row, which is what
		// ROLLUP and CUBE show for a level that was rolled up.
		if ctx.grouped && grouping_column_missing(ctx, e.name, e.table) {
			return value_null(), ERROR_NONE
		}
		// An aggregate over no row still answers one row (count 0, sum NULL), and
		// a bare column in it has no row to come from: it is NULL, as in SQLite,
		// unless it names a column of an enclosing query.
		if ctx.grouped && len(ctx.group) == 0 && len(ctx.sources) == 0 {
			if value, ok := outer_column(ctx, e.name, e.table); ok do return value, ERROR_NONE
			return value_null(), ERROR_NONE
		}
		// The column the resolution linked the reference to, read in place.
		if source, column, bound := column_bound(ctx, e.id); bound {
			if column >= len(source.row.values) do return value_null(), ERROR_NONE
			return source.row.values[column], ERROR_NONE
		}
		if len(e.table) > 0 {
			// Inside a trigger body NEW and OLD name the rows of the event.
			if ctx.tx != nil && ctx.tx.trigger_active {
				// The column its resolution linked it to (res_bind_trigger_column).
				if index, linked_new, linked := trigger_column_bound(ctx, e.id); linked {
					present := linked_new ? ctx.tx.trigger_new_present : ctx.tx.trigger_old_present
					if !present do return value_null(), ERROR_NONE
					row := linked_new ? ctx.tx.trigger_new : ctx.tx.trigger_old
					if index >= len(row.values) do return value_null(), ERROR_NONE
					return row.values[index], ERROR_NONE
				}
				is_new := strings.equal_fold(e.table, "new")
				if is_new || strings.equal_fold(e.table, "old") {
					index, found := schema_column_index(&ctx.tx.trigger_schema, e.name)
					// NEW.rowid, _rowid_ and oid name the row itself, unless the
					// table declares a column with that name, as for a source.
					// They used to fail as a column the table has not.
					if !found && rowid_alias_name(e.name) {
						present := is_new ? ctx.tx.trigger_new_present : ctx.tx.trigger_old_present
						if !present do return value_null(), ERROR_NONE
						row := is_new ? ctx.tx.trigger_new : ctx.tx.trigger_old
						if rowid, has_rowid := schema_rowid_value(&ctx.tx.trigger_schema, row); has_rowid {
							return rowid, ERROR_NONE
						}
					}
					if !found {
						return {}, errf(
							.Column_Not_Found,
							"column %s does not exist in %s",
							e.name,
							is_new ? "NEW" : "OLD",
						)
					}
					present := is_new ? ctx.tx.trigger_new_present : ctx.tx.trigger_old_present
					if !present do return value_null(), ERROR_NONE
					row := is_new ? ctx.tx.trigger_new : ctx.tx.trigger_old
					if index >= len(row.values) do return value_null(), ERROR_NONE
					return row.values[index], ERROR_NONE
				}
			}
			if source, index, single := single_source_column(ctx, expr, e); single {
				if index >= len(source.row.values) do return value_null(), ERROR_NONE
				return source.row.values[index], ERROR_NONE
			}
			for source in ctx.sources {
				// A source the caller has not bound yet has no columns.
				if source.table == nil do continue
				if !qualifier_names(e.table, source.table.schema.name, source.alias) do continue
				index, found := schema_column_index(&source.table.schema, e.name)
				if !found {
					// rank is a hidden column of a full-text table: it is the
					// score of the MATCH that this query ran.
					if strings.equal_fold(e.name, "rank") {
						if score, scored := fts_rank_value(ctx.tx, source.table.schema.name, source.row.id); scored {
							return value_float(score), ERROR_NONE
						}
					}
					// rowid, _rowid_ and oid name the row itself, unless the
					// table declares a column with that name (the lookup above
					// already won in that case).
					if rowid_alias_name(e.name) {
						if rowid, has_rowid := rowid_value(source); has_rowid {
							return rowid, ERROR_NONE
						}
					}
					return {}, errf(
						.Column_Not_Found,
						"column %s does not exist in %s",
						e.name,
						source.table.schema.name,
					)
				}
				if index >= len(source.row.values) do return value_null(), ERROR_NONE
				return source.row.values[index], ERROR_NONE
			}
			if value, ok := outer_column(ctx, e.name, e.table); ok do return value, ERROR_NONE
			return {}, errf(.Column_Not_Found, "table %s is not in the query", e.table)
		}
		if source, index, single := single_source_column(ctx, expr, e); single {
			if index >= len(source.row.values) do return value_null(), ERROR_NONE
			return source.row.values[index], ERROR_NONE
		}
		found_value: Value
		found := false
		for source in ctx.sources {
			if source.table == nil || source.hidden_unqualified do continue
			index, exists := schema_column_index(&source.table.schema, e.name)
			if !exists do continue
			if found && column_in_names(e.name, ctx.using_names) {
				// A shared column is the join's: the left side's value, or the
				// right side's where an outer join left the left one NULL.
				if found_value.kind == .Null && index < len(source.row.values) do found_value = source.row.values[index]
				continue
			}
			if found {
				return {}, errf(.Column_Not_Found, "column %s is ambiguous; qualify it with a table", e.name)
			}
			found = true
			if index < len(source.row.values) {
				found_value = source.row.values[index]
			} else {
				found_value = value_null()
			}
		}
		if !found && strings.equal_fold(e.name, "rank") {
			for source in ctx.sources {
				if source.table == nil do continue
				if score, scored := fts_rank_value(ctx.tx, source.table.schema.name, source.row.id); scored {
					return value_float(score), ERROR_NONE
				}
			}
		}
		if !found && rowid_alias_name(e.name) {
			// One reachable table with a rowid answers; two make the name
			// ambiguous, as they do in SQLite.
			rowid: Value
			reachable := 0
			for source in ctx.sources {
				if source.table == nil || source.hidden_unqualified do continue
				candidate, has_rowid := rowid_value(source)
				if !has_rowid do continue
				rowid = candidate
				reachable += 1
			}
			if reachable == 1 do return rowid, ERROR_NONE
			if reachable > 1 {
				return {}, errf(.Column_Not_Found, "column %s is ambiguous; qualify it with a table", e.name)
			}
		}
		if !found && len(e.table) == 0 && ctx.having_aliases != nil {
			for item in ctx.having_aliases {
				if len(item.alias) == 0 || !strings.equal_fold(item.alias, e.name) do continue
				// The projection is evaluated in the group, without the aliases,
				// so an alias cannot stand for itself.
				saved := ctx.having_aliases
				ctx.having_aliases = nil
				value, err := eval_expr(ctx, item.expr)
				ctx.having_aliases = saved
				return value, err
			}
		}
		if !found {
			if value, ok := outer_column(ctx, e.name, ""); ok do return value, ERROR_NONE
			return {}, errf(.Column_Not_Found, "column %s does not exist", e.name)
		}
		return found_value, ERROR_NONE
	case Star_Expr:
		return {}, errf(.Sql_Syntax, "* is only allowed in a projection")
	case Collate_Expr:
		return eval_expr(ctx, e.operand)
	case Binary_Expr:
		return eval_binary_expr(ctx, &e)
	case Unary_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		// The answer lives in the statement's memory (eval_call).
		outer := context.allocator
		context.allocator = ctx.tx != nil ? ctx.tx.alloc : outer
		value, err := eval_unary(e.op, operand)
		if len(err.message) > 0 do err.message = strings.clone(err.message, outer)
		return value, err
	case Is_Null_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		is_null := operand.kind == .Null
		return value_bool(e.negated ? !is_null : is_null), ERROR_NONE
	case Between_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		low, low_err := eval_expr(ctx, e.low)
		if low_err.kind != .None do return {}, low_err
		high, high_err := eval_expr(ctx, e.high)
		if high_err.kind != .None do return {}, high_err
		if operand.kind == .Null || low.kind == .Null || high.kind == .Null {
			return value_null(), ERROR_NONE
		}
		// `x BETWEEN a AND b` is `x >= a AND x <= b`, collation included: the
		// one each comparison's link decided, else worked out by name.
		store := ctx.tx != nil ? ctx.tx.store : nil
		low_order, high_order: slice.Ordering
		low_ok, high_ok: bool
		if link, linked := compare_collated(ctx, e.low_id); linked {
			low_order, low_ok = value_compare_decided(operand, low, "", store, &link.collation)
		} else {
			low_order, low_ok = value_compare_collated(operand, low, comparison_collation(ctx, e.operand, e.low), store)
		}
		if link, linked := compare_collated(ctx, e.high_id); linked {
			high_order, high_ok = value_compare_decided(operand, high, "", store, &link.collation)
		} else {
			high_order, high_ok = value_compare_collated(operand, high, comparison_collation(ctx, e.operand, e.high), store)
		}
		if !low_ok || !high_ok {
			return {}, errf(.Invalid_Type, "BETWEEN mixes incompatible types")
		}
		inside := low_order != .Less && high_order != .Greater
		return value_bool(e.negated ? !inside : inside), ERROR_NONE
	case Subquery_Expr:
		if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
		if e.select == nil do return value_null(), ERROR_NONE
		sub, sub_err := subquery_run(ctx, e.select^)
		if sub_err.kind != .None do return {}, sub_err
		defer sql_result_destroy(&sub)
		if e.exists do return value_bool(len(sub.rows) > 0), ERROR_NONE
		if len(sub.rows) == 0 || len(sub.rows[0]) == 0 do return value_null(), ERROR_NONE
		// The result is destroyed on return: a text or blob it owns (an
		// aggregate's, a function's) is copied into the transaction first.
		return value_clone(sub.rows[0][0], ctx.tx.alloc), ERROR_NONE
	case In_Expr:
		if row, is_row := row_value_items(e.operand); is_row {
			if e.subquery == nil do return {}, errf(.Sql_Syntax, "row value misused")
			return eval_row_in_subquery(ctx, row, e.subquery, e.negated)
		}
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		if operand.kind == .Null do return value_null(), ERROR_NONE
		// The left operand's collation decides, as in SQLite: the one its link
		// decided, else worked out by name.
		in_store := ctx.tx != nil ? ctx.tx.store : nil
		in_collation := ""
		in_ref: ^Collation_Ref
		if link, linked := compare_collated(ctx, e.id); linked {
			in_ref = &link.collation
		} else {
			in_collation, _ = collate_name(e.operand)
			if len(in_collation) == 0 do in_collation, _ = column_collation(ctx, e.operand)
		}
		if e.subquery != nil {
			if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
			sub, sub_err := subquery_run(ctx, e.subquery^)
			if sub_err.kind != .None do return {}, sub_err
			defer sql_result_destroy(&sub)
			found := false
			unknown := false
			for row in sub.rows {
				if len(row) == 0 do continue
				if row[0].kind == .Null {
					unknown = true
					continue
				}
				if in_equal_decided(operand, row[0], in_collation, in_store, in_ref) {
					found = true
					break
				}
			}
			// A NULL in the set makes a non-match unknown, not false: neither
			// IN nor NOT IN can answer TRUE for a row it did not find.
			if !found && unknown do return value_null(), ERROR_NONE
			return value_bool(e.negated ? !found : found), ERROR_NONE
		}
		found := false
		unknown := false
		for item in e.items {
			value, item_err := eval_expr(ctx, item)
			if item_err.kind != .None do return {}, item_err
			if value.kind == .Null {
				unknown = true
				continue
			}
			if in_equal_decided(operand, value, in_collation, in_store, in_ref) {
				found = true
				break
			}
		}
		if !found && unknown do return value_null(), ERROR_NONE
		return value_bool(e.negated ? !found : found), ERROR_NONE
	case Case_Expr:
		return eval_case(ctx, e)
	case Call_Expr:
		return eval_call(ctx, e)
	case Window_Expr:
		return {}, errf(
			.Sql_Unsupported,
			"window function %s() cannot be evaluated here",
			e.name,
		)
	case Match_Expr:
		pattern, pattern_err := eval_expr(ctx, e.pattern)
		if pattern_err.kind != .None do return {}, pattern_err
		if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "MATCH needs a transaction")
		return fts_match_eval(ctx.tx, ctx, e.operand, pattern)
	case Like_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		pattern, pattern_err := eval_expr(ctx, e.pattern)
		if pattern_err.kind != .None do return {}, pattern_err
		if operand.kind == .Null || pattern.kind == .Null do return value_null(), ERROR_NONE
		if operand.kind != .String || pattern.kind != .String {
			return {}, errf(.Invalid_Type, "LIKE needs text on both sides")
		}
		// SQLite's LIKE ignores ASCII case; GLOB does not.
		matched := e.glob ? glob_match(operand.s, pattern.s) : like_match(operand.s, pattern.s, true, e.escape)
		return value_bool(e.negated ? !matched : matched), ERROR_NONE
	case Cast_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		// The converted value lives in the statement's memory (eval_call).
		outer := context.allocator
		context.allocator = ctx.tx != nil ? ctx.tx.alloc : outer
		if sqlite_rules_on() && len(e.type_name) > 0 do return sqlite_cast(operand, e.type_name), ERROR_NONE
		value, err := value_cast(operand, e.target)
		if len(err.message) > 0 do err.message = strings.clone(err.message, outer)
		return value, err
	case Param_Expr:
		if e.index < 0 || e.index >= len(ctx.params) {
			return {}, errf(
				.Invalid_Argument,
				"bind parameter %d was not supplied (the statement has %d)",
				e.index + 1,
				len(ctx.params),
			)
		}
		return ctx.params[e.index], ERROR_NONE
	}
	return {}, errf(.Internal, "unknown expression")
}

// eval_binary_expr evaluates an operator over its operands. It is its own
// frame, out of eval_expr's: eval_expr recurses for every node, and what a
// comparison keeps (its link, its collation) made every level of it bigger.
@(private)
eval_binary_expr :: #force_no_inline proc(ctx: ^Eval_Ctx, e: ^Binary_Expr) -> (Value, Error) {
	comparison := false
	#partial switch e.op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge, .Is, .Is_Not:
		comparison = true
	}
	left, left_err := eval_expr(ctx, e.left)
	if left_err.kind != .None do return {}, left_err
	right, right_err := eval_expr(ctx, e.right)
	if right_err.kind != .None do return {}, right_err
	// Two integers compare as numbers whatever the collation and the
	// affinities: neither applies to them (value_compare_collated,
	// comparison_affinity), so neither is worked out.
	if comparison && left.kind == .Int && right.kind == .Int {
		x, y := left.i, right.i
		#partial switch e.op {
		case .Eq, .Is:
			return value_bool(x == y), ERROR_NONE
		case .Ne, .Is_Not:
			return value_bool(x != y), ERROR_NONE
		case .Lt:
			return value_bool(x < y), ERROR_NONE
		case .Le:
			return value_bool(x <= y), ERROR_NONE
		case .Gt:
			return value_bool(x > y), ERROR_NONE
		case .Ge:
			return value_bool(x >= y), ERROR_NONE
		}
	}
	// A comparison its resolution linked takes its collation and its
	// operands' affinities from the link (A1.8e).
	link: ^Compare_Link
	if comparison do link, _ = compare_bound(ctx, e.id)
	// A COLLATE on either side decides how the comparison treats text; only
	// a comparison reads it.
	collation := ""
	if comparison && link == nil do collation = comparison_collation(ctx, e.left, e.right)
	if link != nil {
		left, right = affinity_apply(link.left_affinity, link.right_affinity, left, right)
	} else if comparison {
		left, right = comparison_affinity(ctx, e.left, e.right, left, right)
	}
	ref := link != nil ? &link.collation : nil
	if ctx.tx == nil do return eval_binary(e.op, left, right, collation, nil, ref)
	// An operator's answer (the text `||` makes) lives in the statement's
	// memory, as a function's does (eval_call).
	outer := context.allocator
	value: Value
	err: Error
	{
		context.allocator = ctx.tx.alloc
		value, err = eval_binary(e.op, left, right, collation, ctx.tx.store, ref)
	}
	if len(err.message) > 0 do err.message = strings.clone(err.message, outer)
	return value, err
}

// eval_row_in_subquery answers `(a, b) IN (SELECT x, y …)`: true when a row of
// the subquery equals the tuple, NULL when no row does but one could (a NULL on
// either side of a column that decides it), false otherwise.
@(private)
eval_row_in_subquery :: proc(ctx: ^Eval_Ctx, row: []^Expr, subquery: ^Select_Stmt, negated: bool) -> (Value, Error) {
	if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
	tuple := make([]Value, len(row), context.temp_allocator)
	for item, i in row {
		value, err := eval_expr(ctx, item)
		if err.kind != .None do return {}, err
		tuple[i] = value
	}
	sub, sub_err := subquery_run(ctx, subquery^)
	if sub_err.kind != .None do return {}, sub_err
	defer sql_result_destroy(&sub)
	if len(sub.columns) != len(tuple) {
		return {}, errf(.Sql_Syntax, "sub-select returns %d columns - expected %d", len(sub.columns), len(tuple))
	}
	found := false
	unknown := false
	for candidate in sub.rows {
		match := true
		maybe := false
		for value, i in tuple {
			if value.kind == .Null || candidate[i].kind == .Null {
				maybe = true
				continue
			}
			if !value_equal(value, candidate[i]) {
				match = false
				break
			}
		}
		if !match do continue
		if maybe {
			unknown = true
			continue
		}
		found = true
		break
	}
	if !found && unknown do return value_null(), ERROR_NONE
	return value_bool(negated ? !found : found), ERROR_NONE
}

eval_binary :: proc(
	op: Binary_Op,
	left: Value,
	right: Value,
	collation: string = "",
	store: ^Store = nil,
	// ref is the collation decided when the statement was resolved
	// (Compare_Link); `collation` is the name, decided at the row, otherwise.
	ref: ^Collation_Ref = nil,
) -> (Value, Error) {
	#partial switch op {
	case .And:
		if !value_is_null(left) && !value_is_truthy(left) do return value_bool(false), ERROR_NONE
		if !value_is_null(right) && !value_is_truthy(right) do return value_bool(false), ERROR_NONE
		if value_is_null(left) || value_is_null(right) do return value_null(), ERROR_NONE
		return value_bool(true), ERROR_NONE
	case .Or:
		if value_is_truthy(left) do return value_bool(true), ERROR_NONE
		if value_is_truthy(right) do return value_bool(true), ERROR_NONE
		if value_is_null(left) || value_is_null(right) do return value_null(), ERROR_NONE
		return value_bool(false), ERROR_NONE
	case .Is, .Is_Not:
		same: bool
		if value_is_null(left) || value_is_null(right) {
			same = value_is_null(left) && value_is_null(right)
		} else {
			order, ok := value_compare_decided(left, right, collation, store, ref)
			// Values of different classes are never the same value.
			same = ok && order == .Equal
		}
		return value_bool(op == .Is ? same : !same), ERROR_NONE
	case:
	}
	if value_is_null(left) || value_is_null(right) {
		return value_null(), ERROR_NONE
	}
	switch op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		// A driver that did not know a parameter's type sends an array as text,
		// `{a,b}`. PostgreSQL parses it against the column's type; here the array
		// on the other side says what the elements are.
		compared_left, compared_right := arrays_from_text(left, right)
		order, ok := value_compare_decided(compared_left, compared_right, collation, store, ref)
		if !ok {
			return {}, errf(
				.Invalid_Type,
				"cannot compare %s with %s",
				value_kind_name(left.kind),
				value_kind_name(right.kind),
			)
		}
		result := false
		#partial switch op {
		case .Eq:
			result = order == .Equal
		case .Ne:
			result = order != .Equal
		case .Lt:
			result = order == .Less
		case .Le:
			result = order != .Greater
		case .Gt:
			result = order == .Greater
		case .Ge:
			result = order != .Less
		}
		return value_bool(result), ERROR_NONE
	case .Concat:
		// PostgreSQL's `||` concatenates arrays as well as text, and appends or
		// prepends a single element when only one side is an array.
		if left.kind == .Array || right.kind == .Array {
			return array_concat(left, right)
		}
		// Under SQLite's rules a real reads `1.0`, a blob its bytes.
		if sqlite_rules_on() {
			return value_string(strings.concatenate({sqlite_cast(left, "TEXT").s, sqlite_cast(right, "TEXT").s})), ERROR_NONE
		}
		left_text := value_to_text(left)
		right_text := value_to_text(right)
		return value_string(strings.concatenate({left_text, right_text})), ERROR_NONE
	case .Add, .Sub, .Mul, .Div, .Mod:
		return eval_arithmetic(op, left, right)
	case .Bit_And, .Bit_Or, .Shift_Left, .Shift_Right:
		a, a_ok := value_bit_operand(left)
		b, b_ok := value_bit_operand(right)
		if !a_ok || !b_ok do return {}, errf(.Invalid_Type, "bitwise operators need integers")
		#partial switch op {
		case .Bit_And:
			return value_int(a & b), ERROR_NONE
		case .Bit_Or:
			return value_int(a | b), ERROR_NONE
		case .Shift_Left:
			return value_int(bit_shift(a, b)), ERROR_NONE
		case .Shift_Right:
			// A negative count shifts the other way, as in SQLite.
			return value_int(bit_shift(a, b == min(i64) ? max(i64) : -b)), ERROR_NONE
		}
	case .And, .Or, .Is, .Is_Not:
	}
	return {}, errf(.Internal, "unknown binary operator")
}

@(private)
eval_arithmetic :: proc(op: Binary_Op, left, right: Value) -> (Value, Error) {
	// SQLite reads a text or a blob operand as the number it starts with.
	left, right := left, right
	if sqlite_rules_on() {
		if left.kind == .String || left.kind == .Bytes do left = sqlite_cast(left, "NUMERIC")
		if right.kind == .String || right.kind == .Bytes do right = sqlite_cast(right, "NUMERIC")
	}
	if !value_is_numeric(left) || !value_is_numeric(right) {
		return {}, errf(.Invalid_Type, "arithmetic needs numbers")
	}
	if sqlite_rules_on() && (left.kind == .Int || left.kind == .Float || left.kind == .Bool) && (right.kind == .Int || right.kind == .Float || right.kind == .Bool) {
		return sqlite_arithmetic(op, left, right), ERROR_NONE
	}
	if left.kind == .Int128 ||
	   left.kind == .Uint128 ||
	   right.kind == .Int128 ||
	   right.kind == .Uint128 {
		return eval_arithmetic_128(op, left, right)
	}
	if left.kind == .Float || right.kind == .Float {
		a, _ := value_to_f64(left)
		b, _ := value_to_f64(right)
		if (op == .Div || op == .Mod) && b == 0 {
			return {}, errf(.Invalid_Argument, "division by zero")
		}
		#partial switch op {
		case .Add:
			return value_float(a + b), ERROR_NONE
		case .Sub:
			return value_float(a - b), ERROR_NONE
		case .Mul:
			return value_float(a * b), ERROR_NONE
		case .Div:
			return value_float(a / b), ERROR_NONE
		case .Mod:
			return value_float(fmod(a, b)), ERROR_NONE
		case:
		}
	}
	if left.kind == .Uint || right.kind == .Uint {
		a, a_ok := value_to_u64(left)
		b, b_ok := value_to_u64(right)
		if !a_ok || !b_ok {
			return {}, errf(.Invalid_Type, "unsigned arithmetic needs non-negative values")
		}
		#partial switch op {
		case .Add:
			sum, overflow := intrinsics.overflow_add(a, b)
			if overflow do return {}, integer_overflow_error()
			return value_uint(sum), ERROR_NONE
		case .Sub:
			if b > a do return {}, errf(.Invalid_Argument, "unsigned subtraction underflows")
			return value_uint(a - b), ERROR_NONE
		case .Mul:
			product, overflow := intrinsics.overflow_mul(a, b)
			if overflow do return {}, integer_overflow_error()
			return value_uint(product), ERROR_NONE
		case .Div:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint(a / b), ERROR_NONE
		case .Mod:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint(a % b), ERROR_NONE
		case:
		}
	}
	a, _ := value_to_i64(left)
	b, _ := value_to_i64(right)
	#partial switch op {
	case .Add:
		sum, overflow := intrinsics.overflow_add(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int(sum), ERROR_NONE
	case .Sub:
		difference, overflow := intrinsics.overflow_sub(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int(difference), ERROR_NONE
	case .Mul:
		product, overflow := intrinsics.overflow_mul(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int(product), ERROR_NONE
	case .Div:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		// The one quotient that does not fit: min(i64) / -1. Answering it would
		// fault in the hardware division, so it is an error like any other
		// overflow.
		if a == min(i64) && b == -1 do return {}, integer_overflow_error()
		return value_int(a / b), ERROR_NONE
	case .Mod:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		// min(i64) % -1 is zero, but the hardware division behind it traps.
		if a == min(i64) && b == -1 do return value_int(0), ERROR_NONE
		return value_int(a % b), ERROR_NONE
	case:
	}
	return {}, errf(.Internal, "unknown arithmetic operator")
}

@(private)
eval_arithmetic_128 :: proc(op: Binary_Op, left, right: Value) -> (Value, Error) {
	unsigned := is_unsigned_kind(left.kind) || is_unsigned_kind(right.kind)
	if unsigned {
		for operand in ([]Value{left, right}) {
			if !is_unsigned_kind(operand.kind) && value_as_i128(operand) < 0 {
				return {}, errf(.Invalid_Argument, "negative value in unsigned arithmetic")
			}
		}
		a := value_as_u128(left)
		b := value_as_u128(right)
		#partial switch op {
		case .Add:
			sum, overflow := intrinsics.overflow_add(a, b)
			if overflow do return {}, integer_overflow_error()
			return value_uint128(sum), ERROR_NONE
		case .Sub:
			if b > a do return {}, errf(.Invalid_Argument, "unsigned subtraction underflows")
			return value_uint128(a - b), ERROR_NONE
		case .Mul:
			product, overflow := intrinsics.overflow_mul(a, b)
			if overflow do return {}, integer_overflow_error()
			return value_uint128(product), ERROR_NONE
		case .Div:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint128(a / b), ERROR_NONE
		case .Mod:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint128(a % b), ERROR_NONE
		}
		return {}, errf(.Internal, "unknown arithmetic operator")
	}
	a := value_as_i128(left)
	b := value_as_i128(right)
	#partial switch op {
	case .Add:
		sum, overflow := intrinsics.overflow_add(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int128(sum), ERROR_NONE
	case .Sub:
		difference, overflow := intrinsics.overflow_sub(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int128(difference), ERROR_NONE
	case .Mul:
		product, overflow := intrinsics.overflow_mul(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int128(product), ERROR_NONE
	case .Div:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		if a == min(i128) && b == -1 do return {}, integer_overflow_error()
		return value_int128(a / b), ERROR_NONE
	case .Mod:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		if a == min(i128) && b == -1 do return value_int128(0), ERROR_NONE
		return value_int128(a % b), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown arithmetic operator")
}

// integer_overflow_error is the one answer every arithmetic path gives when the
// result does not fit: `+`, `-`, `*` and the two quotients that trap. SQLite
// would promote a 64-bit result to a real; this engine refuses instead, which is
// what PostgreSQL does and what the rest of this engine does with a CAST.
@(private)
integer_overflow_error :: proc() -> Error {
	return errf(.Invalid_Argument, "integer overflow")
}

@(private)
fmod :: proc(a, b: f64) -> f64 {
	return a - b * f64(i64(a / b))
}

@(private)
eval_unary :: proc(op: Unary_Op, operand: Value) -> (Value, Error) {
	switch op {
	case .Neg:
		if operand.kind == .Null do return value_null(), ERROR_NONE
		if operand.kind == .Float do return value_float(-operand.f), ERROR_NONE
		if operand.kind == .Uint128 {
			if value_big(operand) > u128(max(i128)) + 1 {
				return {}, errf(.Invalid_Argument, "cannot negate this uint128")
			}
			return value_int128(0 - i128(value_big(operand))), ERROR_NONE
		}
		if operand.kind == .Int128 {
			if i128(value_big(operand)) == min(i128) {
				return {}, errf(.Invalid_Argument, "integer overflow negating int128")
			}
			return value_int128(0 - i128(value_big(operand))), ERROR_NONE
		}
		if operand.kind == .Uint {
			if operand.u > u64(max(i64)) + 1 {
				return {}, errf(.Invalid_Argument, "cannot negate this uint")
			}
			big := i128(0) - i128(operand.u)
			if big >= i128(min(i64)) && big <= i128(max(i64)) {
				return value_int(i64(big)), ERROR_NONE
			}
			return value_int128(big), ERROR_NONE
		}
		// SQLite negates the one integer that has no negative as a REAL.
		if sqlite_rules_on() && operand.kind == .Int && operand.i == min(i64) do return value_float(-f64(operand.i)), ERROR_NONE
		value, ok := value_to_i64(operand)
		if !ok do return {}, errf(.Invalid_Type, "cannot negate a %s", value_kind_name(operand.kind))
		if value == min(i64) {
			return value_int128(0 - i128(value)), ERROR_NONE
		}
		return value_int(-value), ERROR_NONE
	case .Plus:
		if !value_is_numeric(operand) && operand.kind != .Null {
			return {}, errf(.Invalid_Type, "cannot apply + to a %s", value_kind_name(operand.kind))
		}
		return operand, ERROR_NONE
	case .Not:
		if operand.kind == .Null do return value_null(), ERROR_NONE
		return value_bool(!value_is_truthy(operand)), ERROR_NONE
	case .Bit_Not:
		if operand.kind == .Null do return value_null(), ERROR_NONE
		v, ok := value_bit_operand(operand)
		if !ok do return {}, errf(.Invalid_Type, "~ needs an integer")
		return value_int(~v), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown unary operator")
}

// value_bit_operand converts an operand of a bitwise operator to the 64-bit
// integer SQLite works on: a real is truncated, numeric text is read as a
// number (text that is not a number is 0), and a blob is not an integer.
@(private)
value_bit_operand :: proc(v: Value) -> (i64, bool) {
	if v.kind == .String {
		parsed, ok := value_parse_number(strings.trim_space(v.s))
		if !ok do return 0, true
		return value_to_i64(parsed)
	}
	if !value_is_numeric(v) do return 0, false
	return value_to_i64(v)
}

// bit_shift moves `a` left by `count` bits (right when negative); a count of 64
// or more empties it, keeping the sign on a right shift as SQLite does.
@(private)
bit_shift :: proc(a: i64, count: i64) -> i64 {
	if count >= 64 do return 0
	if count <= -64 do return a < 0 ? -1 : 0
	if count >= 0 do return i64(u64(a) << u64(count))
	return a >> u64(-count)
}

@(private)
value_to_text :: proc(v: Value) -> string {
	#partial switch v.kind {
	case .String:
		return v.s
	case .Null:
		return ""
	}
	return value_format(v, context.temp_allocator)
}

// value_cast implements CAST and the implicit conversions SQL expressions need.
value_cast :: proc(v: Value, target: Column_Type) -> (Value, Error) {
	if v.kind == .Null do return value_null(), ERROR_NONE
	if target.kind == .String {
		if v.kind == .String do return v, ERROR_NONE
		return value_string(value_format(v, context.allocator)), ERROR_NONE
	}
	if coerced, coerce_err := value_coerce(v, target); coerce_err.kind == .None {
		return coerced, ERROR_NONE
	} else {
		// The direct coercion failed; the fallbacks below answer instead.
		error_free(&coerce_err)
	}
	if v.kind == .String {
		if parsed, ok := value_parse_number(v.s); ok {
			return value_coerce(parsed, target)
		}
		if target.kind == .Bool {
			// `t` and `f` are how PostgreSQL writes a bool in its text formats,
			// which COPY reads back; the words and the digits are the SQL forms.
			if strings.equal_fold(v.s, "true") || v.s == "1" || strings.equal_fold(v.s, "t") {
				return value_bool(true), ERROR_NONE
			}
			if strings.equal_fold(v.s, "false") || v.s == "0" || strings.equal_fold(v.s, "f") {
				return value_bool(false), ERROR_NONE
			}
		}
	}
	return {}, errf(
		.Invalid_Type,
		"cannot cast a %s to %s",
		value_kind_name(v.kind),
		type_kind_name(target.kind),
	)
}

// unistr_decode reads the escapes unistr documents. An escape that names no
// character is refused rather than dropped, as SQLite refuses it.
@(private)
unistr_decode :: proc(text: string) -> string {
	out := make([dynamic]u8, 0, len(text))
	i := 0
	for i < len(text) {
		c := text[i]
		if c != '\\' {
			append(&out, c)
			i += 1
			continue
		}
		i += 1
		if i >= len(text) {
			append(&out, '\\')
			break
		}
		escape := text[i]
		i += 1
		digits := 0
		switch escape {
		case '\\':
			append(&out, '\\')
			continue
		case 'u':
			digits = 4
		case '+':
			digits = 6
		case 'U':
			digits = 8
		case:
			// No other escape: the backslash is literal, as SQLite keeps it.
			append(&out, '\\')
			append(&out, escape)
			continue
		}
		if i + digits > len(text) {
			append(&out, '\\')
			append(&out, escape)
			continue
		}
		code: u32
		valid := true
		for _ in 0 ..< digits {
			digit := text[i]
			i += 1
			value: u32
			switch {
			case digit >= '0' && digit <= '9':
				value = u32(digit - '0')
			case digit >= 'a' && digit <= 'f':
				value = u32(digit - 'a') + 10
			case digit >= 'A' && digit <= 'F':
				value = u32(digit - 'A') + 10
			case:
				valid = false
			}
			code = code * 16 + value
		}
		if !valid || code > 0x10FFFF {
			append(&out, '\\')
			append(&out, escape)
			continue
		}
		// A UTF-16 surrogate pair says nothing on its own: it is written as the
		// replacement character, which is what a broken escape earns.
		if code >= 0xD800 && code <= 0xDFFF {
			code = 0xFFFD
		}
		buffer, length := utf8.encode_rune(cast(rune)code)
		append(&out, ..buffer[:length])
	}
	return string(out[:])
}

// unistr_quote writes a text so that unistr reads it back: the quotes SQL wants
// and the escapes for a control character or a lone surrogate.
@(private)
unistr_quote :: proc(text: string) -> string {
	out := make([dynamic]u8, 0, len(text) + 2)
	// SQLite answers the call that would read the text back, not a bare literal.
	append(&out, ..transmute([]u8)string("unistr('"))
	for i := 0; i < len(text); {
		c := text[i]
		if c == '\'' {
			append(&out, '\'')
			append(&out, '\'')
			i += 1
			continue
		}
		if c < 0x20 || c == 0x7F {
			append(&out, ..transmute([]u8)fmt.aprintf("\\u%04x", c))
			i += 1
			continue
		}
		decoded, size := utf8.decode_rune(text[i:])
		if decoded == utf8.RUNE_ERROR && size <= 1 {
			out_text := fmt.aprintf("\\u%04x", c)
			append(&out, ..transmute([]u8)out_text)
			i += 1
			continue
		}
		append(&out, text[i:i + size])
		i += size
	}
	append(&out, ..transmute([]u8)string("')"))
	return string(out[:])
}

// timediff_text is `first - second` as SQLite writes it: a sign, then years,
// months, days and the time of day.
@(private)
timediff_text :: proc(first, second: Db_Time) -> string {
	negative := second.jd > first.jd
	from := negative ? first : second
	to := negative ? second : first
	years, months, days, hours, minutes, seconds, millis := timediff_parts(from, to)
	return fmt.aprintf(
		"%s%04d-%02d-%02d %02d:%02d:%02d.%03d",
		negative ? "-" : "+",
		years,
		months,
		days,
		hours,
		minutes,
		seconds,
		millis,
	)
}

@(private)
timediff_parts :: proc(from, to: Db_Time) -> (years, months, days, hours, minutes, seconds, millis: int) {
	fy, fm, fd, fh, fmin, fs := db_time_civil(from)
	ty, tm, td, th, tmin, ts := db_time_civil(to)
	years = ty - fy
	months = tm - fm
	days = td - fd
	hours = th - fh
	minutes = tmin - fmin
	seconds = ts - fs
	// Borrow the way a calendar does: a negative lower field takes one from the
	// field above it. A month is the month before, and a day is the length of the
	// month it lands in.
	if seconds < 0 {
		seconds += 60
		minutes -= 1
	}
	if minutes < 0 {
		minutes += 60
		hours -= 1
	}
	if hours < 0 {
		hours += 24
		days -= 1
	}
	if days < 0 {
		month := tm - 1
		year := ty
		if month < 1 {
			month = 12
			year -= 1
		}
		days += db_days_in_month(year, month)
		months -= 1
	}
	if months < 0 {
		months += 12
		years -= 1
	}
	return
}

// soundex_encode is SQLite's SOUNDEX: the first letter in upper case, then one
// digit per consonant class for three digits, zero-padded. The classes are
// SQLite's, and a letter that repeats the class of the one before it (with only
// vowels, h, w or y in between) counts once.
@(private)
soundex_encode :: proc(text: string) -> string {
	classify :: proc(c: u8) -> u8 {
		switch c {
		case 'B', 'F', 'P', 'V', 'b', 'f', 'p', 'v':
			return '1'
		case 'C', 'G', 'J', 'K', 'Q', 'S', 'X', 'Z', 'c', 'g', 'j', 'k', 'q', 's', 'x', 'z':
			return '2'
		case 'D', 'T', 'd', 't':
			return '3'
		case 'L', 'l':
			return '4'
		case 'M', 'N', 'm', 'n':
			return '5'
		case 'R', 'r':
			return '6'
		}
		return 0
	}
	digits := make([dynamic]u8, 0, 8)
	previous: u8 = 0
	first := true
	first_letter: u8 = 0
	for i in 0 ..< len(text) {
		c := text[i]
		is_letter := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
		if !is_letter do continue
		upper := c >= 'a' && c <= 'z' ? c - 32 : c
		if first {
			first_letter = upper
			first = false
			previous = classify(upper)
			continue
		}
		code := classify(upper)
		if code == 0 {
			// A vowel, or h, w, y: it separates two groups but does not end them
			// for h, w and y, which SQLite skips without resetting.
			if upper != 'H' && upper != 'W' && upper != 'Y' do previous = 0
			continue
		}
		if code == previous do continue
		append(&digits, code)
		previous = code
		if len(digits) == 3 do break
	}
	if first_letter == 0 do return "?000"
	out := make([dynamic]u8, 0, 4)
	append(&out, first_letter)
	for i in 0 ..< 3 {
		if i < len(digits) {
			append(&out, digits[i])
		} else {
			append(&out, '0')
		}
	}
	return string(out[:])
}

// scalar_minmax reports a min()/max() call that takes its value from two or more
// arguments: SQLite answers that as a scalar function, not as a group aggregate.
@(private)
scalar_minmax :: proc(call: Call_Expr) -> bool {
	if len(call.args) < 2 do return false
	return strings.equal_fold(call.name, "min") || strings.equal_fold(call.name, "max")
}

@(private)
expr_is_aggregate :: proc(expr: ^Expr) -> bool {
	if expr == nil do return false
	switch e in expr^ {
	case Window_Expr:
		// A window aggregate is not a group aggregate: it is computed once every
		// row is known, not while scanning.
		return false
	case Case_Expr:
		if expr_is_aggregate(e.operand) do return true
		for branch in e.branches {
			if expr_is_aggregate(branch.condition) do return true
			if expr_is_aggregate(branch.result) do return true
		}
		return expr_is_aggregate(e.fallback)
	case Call_Expr:
		if scalar_minmax(e) do return false
		if is_aggregate_name(e.name) do return true
		for arg in e.args {
			if expr_is_aggregate(arg) do return true
		}
	case Binary_Expr:
		return expr_is_aggregate(e.left) || expr_is_aggregate(e.right)
	case Unary_Expr:
		return expr_is_aggregate(e.operand)
	case Is_Null_Expr:
		return expr_is_aggregate(e.operand)
	case Between_Expr:
		return expr_is_aggregate(e.operand) || expr_is_aggregate(e.low) || expr_is_aggregate(e.high)
	case In_Expr:
		if expr_is_aggregate(e.operand) do return true
		for item in e.items {
			if expr_is_aggregate(item) do return true
		}
	case Match_Expr:
		return false
	case Like_Expr:
		return expr_is_aggregate(e.operand) || expr_is_aggregate(e.pattern)
	case Cast_Expr:
		return expr_is_aggregate(e.operand)
	case Collate_Expr:
		return expr_is_aggregate(e.operand)
	case Subquery_Expr:
		return false
	case Literal_Expr, Column_Expr, Star_Expr, Param_Expr:
	}
	return false
}

// sq_literal renders a value as SQLite's quote() does.
@(private)
sq_literal :: proc(value: Value) -> string {
	#partial switch value.kind {
	case .Null:
		return "NULL"
	case .Int:
		return fmt.aprintf("%d", value.i)
	case .Uint:
		return fmt.aprintf("%d", value.u)
	case .Float:
		// SQLite's quote() writes a real with %!0.17g, which reads back as the
		// same double (sqlite3QuoteValue).
		text, _ := sqlite_printf_values("%!0.17g", []Value{value})
		return text
	case .Bool:
		return value.b ? "1" : "0"
	case .Bytes:
		builder := strings.builder_make()
		strings.write_string(&builder, "X'")
		for byte in value.bytes do strings.write_string(&builder, fmt.aprintf("%02X", byte, allocator = context.temp_allocator))
		strings.write_byte(&builder, '\'')
		return strings.to_string(builder)
	case .String:
		escaped, _ := strings.replace_all(value.s, "'", "''", context.temp_allocator)
		return fmt.aprintf("'%s'", escaped)
	}
	return value_format(value, context.allocator)
}

@(private)
sq_hex :: proc(value: Value) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	#partial switch value.kind {
	case .Bytes:
		for byte in value.bytes do fmt.sbprintf(&builder, "%02X", byte)
	case .String:
		// Iterate the bytes: `for c in text` would yield runes, so hex('é')
		// answered the code point E9 instead of the UTF-8 bytes C3A9 (D32).
		for i in 0 ..< len(value.s) do fmt.sbprintf(&builder, "%02X", value.s[i])
	}
	return strings.clone(strings.to_string(builder))
}


@(private)
sq_float :: proc(value: Value) -> f64 {
	#partial switch value.kind {
	case .Float:
		return value.f
	case .Int:
		return f64(value.i)
	case .Uint:
		return f64(value.u)
	}
	return 0
}

@(private)
sq_truthy :: proc(value: Value) -> (bool, Error) {
	#partial switch value.kind {
	case .Null:
		return false, ERROR_NONE
	case .Bool:
		return value.b, ERROR_NONE
	case .Int:
		return value.i != 0, ERROR_NONE
	case .Uint:
		return value.u != 0, ERROR_NONE
	case .Float:
		return value.f != 0, ERROR_NONE
	case .String:
		return len(value.s) > 0, ERROR_NONE
	}
	return true, ERROR_NONE
}

// is_aggregate_name reports a call that aggregates: one of the engine's own, or
// a host aggregate of the store the running statement belongs to.
@(private)
is_aggregate_name :: proc(name: string) -> bool {
	return builtin_aggregate_name(name) || host_aggregate_name(name)
}

// builtin_aggregate_name reports one of the engine's own aggregates.
builtin_aggregate_name :: proc(name: string) -> bool {
	for candidate in ([]string{"count", "sum", "avg", "min", "max", "total", "group_concat", "string_agg", "array_agg", "json_group_array", "json_group_object", "jsonb_group_array", "jsonb_group_object", "median", "percentile", "percentile_cont", "percentile_disc"}) {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}

// eval_host_aggregate_values runs a host aggregate over a frame of values that
// are already evaluated, one argument per row: a host aggregate used as a window
// function, which SQLite allows for every aggregate.
@(private)
eval_host_aggregate_values :: proc(ctx: ^Eval_Ctx, call: Call_Expr, values: []Value) -> (Value, Error) {
	def, found := store_aggregate(ctx.tx.store, call.name, len(call.args))
	if !found do return {}, errf(.Invalid_Argument, "wrong number of arguments to function %s()", call.name)
	if len(call.args) > 1 {
		return {}, errf(.Sql_Unsupported, "%s() takes more than one argument and cannot be a window function here", call.name)
	}
	group := Aggregate_Group{user = def.user}
	failure: Error
	for value in values {
		args := [1]Value{value}
		if step_err := def.step(&group, args[:len(call.args)]); step_err.kind != .None {
			failure = step_err
			break
		}
	}
	answer, final_err := def.final(&group)
	if failure.kind != .None {
		error_free(&final_err)
		value_deep_free(answer, context.allocator)
		return {}, failure
	}
	return answer, final_err
}

// eval_host_aggregate runs a host aggregate over the rows of a group: the
// arguments of each row go to its step, and its final answers. The final runs
// once whatever happens, so the host can always release its state.
@(private)
eval_host_aggregate :: proc(ctx: ^Eval_Ctx, call: Call_Expr, rows: [][]Source) -> (Value, Error) {
	def, found := store_aggregate(ctx.tx.store, call.name, len(call.args))
	if !found do return {}, errf(.Invalid_Argument, "wrong number of arguments to function %s()", call.name)
	group := Aggregate_Group{user = def.user}
	keys: map[string]bool
	if call.is_distinct do keys = make(map[string]bool)
	defer agg_distinct_destroy(&keys)
	args := make([]Value, len(call.args))
	defer delete(args)
	failure: Error
	rows_loop: for sources in rows {
		sub := ctx^
		sub.sources = sources
		for arg, i in call.args {
			value, arg_err := eval_expr(&sub, arg)
			if arg_err.kind != .None {
				failure = arg_err
				break rows_loop
			}
			args[i] = value
		}
		if call.is_distinct && len(args) > 0 {
			key := agg_distinct_key(collation_key_value(&sub, call.args[0], args[0]))
			if key in keys {
				delete(key)
				continue
			}
			keys[key] = true
		}
		if step_err := def.step(&group, args); step_err.kind != .None {
			failure = step_err
			break
		}
	}
	value, final_err := def.final(&group)
	if failure.kind != .None {
		error_free(&final_err)
		value_deep_free(value, context.allocator)
		return {}, failure
	}
	return value, final_err
}

// eval_case is CASE [operand] WHEN ... THEN ... [ELSE ...] END. With an operand
// every WHEN is compared against it (a NULL on either side never matches); with
// no operand every WHEN is a condition and only TRUE takes the branch. The first
// match wins and the branch is evaluated only then, which is what makes
// `CASE WHEN d = 0 THEN NULL ELSE n / d END` safe.
@(private)
eval_case :: proc(ctx: ^Eval_Ctx, e: Case_Expr) -> (Value, Error) {
	searched := e.operand == nil
	operand: Value
	if !searched {
		value, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		operand = value
	}
	for branch in e.branches {
		condition, condition_err := eval_expr(ctx, branch.condition)
		if condition_err.kind != .None do return {}, condition_err
		matched := false
		if searched {
			matched = value_is_truthy(condition)
		} else if condition.kind != .Null && operand.kind != .Null {
			matched = value_equal(operand, condition)
		}
		if matched do return eval_expr(ctx, branch.result)
	}
	if e.fallback != nil do return eval_expr(ctx, e.fallback)
	return value_null(), ERROR_NONE
}

// grouping_column_missing reports whether `name` is a GROUP BY entry the current
// set left out. Matching is by name, with a table when both sides name one, which
// is how a projection finds the entry it groups by.
@(private)
grouping_column_missing :: proc(ctx: ^Eval_Ctx, name, table: string) -> bool {
	for expr, index in ctx.grouping_exprs {
		if index >= len(ctx.grouping_missing) || !ctx.grouping_missing[index] do continue
		column, is_column := expr^.(Column_Expr)
		if !is_column || !strings.equal_fold(column.name, name) do continue
		if len(table) > 0 && len(column.table) > 0 && !strings.equal_fold(column.table, table) {
			continue
		}
		return true
	}
	return false
}

// eval_grouping answers GROUPING(a, b): one bit per argument, most significant
// first, 1 when the set left that column out. GROUPING_ID is the same function
// under its other name.
@(private)
eval_grouping :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	if !ctx.grouped || len(ctx.grouping_exprs) == 0 {
		return {}, errf(.Invalid_Argument, "GROUPING() needs GROUP BY with ROLLUP, CUBE or GROUPING SETS")
	}
	mask: i64
	for arg in call.args {
		column, is_column := arg^.(Column_Expr)
		if !is_column {
			return {}, errf(.Invalid_Argument, "GROUPING() takes a column of the GROUP BY list")
		}
		missing := false
		found := false
		for expr, index in ctx.grouping_exprs {
			other, other_is_column := expr^.(Column_Expr)
			if !other_is_column || !strings.equal_fold(other.name, column.name) do continue
			if len(column.table) > 0 && len(other.table) > 0 &&
			   !strings.equal_fold(column.table, other.table) {
				continue
			}
			found = true
			missing = index < len(ctx.grouping_missing) && ctx.grouping_missing[index]
			break
		}
		if !found {
			return {}, errf(
				.Invalid_Argument,
				"GROUPING() takes a column of the GROUP BY list, not %s",
				column.name,
			)
		}
		mask = mask << 1
		if missing do mask |= 1
	}
	return value_int(mask), ERROR_NONE
}

// select_group_sets is the sets a statement groups by: the ones a construct asked
// for, or the single set of the whole GROUP BY list.
@(private)
select_group_sets :: proc(stmt: Select_Stmt, alloc: mem.Allocator) -> [][]int {
	if len(stmt.group_sets) > 0 do return stmt.group_sets
	if len(stmt.group_by) == 0 do return nil
	one := make([]int, len(stmt.group_by), alloc)
	for i in 0 ..< len(stmt.group_by) do one[i] = i
	sets := make([][]int, 1, alloc)
	sets[0] = one
	return sets
}

// grouping_missing_for marks the GROUP BY entries one set leaves out.
@(private)
grouping_missing_for :: proc(set: []int, count: int, alloc: mem.Allocator) -> []bool {
	missing := make([]bool, count, alloc)
	for i in 0 ..< count do missing[i] = true
	for index in set {
		if index >= 0 && index < count do missing[index] = false
	}
	return missing
}

// eval_raise answers a trigger's RAISE. IGNORE skips the row that fired the
// trigger; ABORT takes the statement back, FAIL keeps its rows before this one
// and ROLLBACK ends the transaction, each failing with the message.
@(private)
eval_raise :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	tx := ctx.tx
	if tx == nil || !tx.trigger_active do return {}, errf(.Sql_Syntax, "RAISE() may only be used within a trigger-program")
	action := call.args[0].(Literal_Expr).value.s
	if action == "ignore" do return {}, Error{kind = .Trigger_Ignore}
	message, message_err := eval_expr(ctx, call.args[1])
	if message_err.kind != .None do return {}, message_err
	// Not a switch: scripts/function_table.py reads a switch's labels as the
	// names of functions.
	if action == "fail" do tx.keep_partial = true
	if action == "rollback" do tx.rollback_requested = true
	return {}, errf(.Trigger_Raise, "%s", value_to_text(message))
}

// --- Collations ------------------------------------------------------------

// collation_known reports whether a column may be declared with this collation.
collation_known :: proc(name: string) -> bool {
	return strings.equal_fold(name, "binary") ||
		strings.equal_fold(name, "nocase") ||
		strings.equal_fold(name, "rtrim")
}

// column_collation resolves a column expression to the collation its column
// declares, so a comparison or a sort without an explicit COLLATE still honours
// it. An unqualified name reads the first source that has the column.
column_collation :: proc(ctx: ^Eval_Ctx, expr: ^Expr) -> (string, bool) {
	if expr == nil do return "", false
	operand := expr
	if collate, ok := operand^.(Collate_Expr); ok do operand = collate.operand
	column, ok := operand^.(Column_Expr)
	if !ok do return "", false
	if source, index, bound := column_bound(ctx, column.id); bound {
		collation := source.table.schema.columns[index].collation
		return collation, len(collation) > 0
	}
	if source, index, single := single_source_column(ctx, operand, column); single {
		collation := source.table.schema.columns[index].collation
		return collation, len(collation) > 0
	}
	for source in ctx.sources {
		if len(column.table) > 0 {
			if !qualifier_names(column.table, source.table.schema.name, source.alias) do continue
		}
		index, found := schema_column_index(&source.table.schema, column.name)
		if !found do continue
		if len(source.table.schema.columns[index].collation) > 0 {
			return source.table.schema.columns[index].collation, true
		}
		return "", false
	}
	return "", false
}

// Column_Affinity is what SQLite's comparison reads from an operand: a column
// of a numeric or a text type has that affinity, anything else has none.
Column_Affinity :: enum u8 {
	None,
	Numeric,
	Text,
}

// column_affinity is the affinity of an operand that names a column.
@(private)
column_affinity :: proc(ctx: ^Eval_Ctx, expr: ^Expr) -> Column_Affinity {
	if expr == nil do return .None
	operand := expr
	if collate, ok := operand^.(Collate_Expr); ok do operand = collate.operand
	column, ok := operand^.(Column_Expr)
	if !ok do return .None
	if source, index, bound := column_bound(ctx, column.id); bound {
		return declared_affinity(source.table.schema.columns[index].type)
	}
	if source, index, single := single_source_column(ctx, operand, column); single {
		return declared_affinity(source.table.schema.columns[index].type)
	}
	for source in ctx.sources {
		if source.table == nil do continue
		if len(column.table) > 0 {
			if !qualifier_names(column.table, source.table.schema.name, source.alias) do continue
		}
		index, found := schema_column_index(&source.table.schema, column.name)
		if !found do continue
		return declared_affinity(source.table.schema.columns[index].type)
	}
	return .None
}

// declared_affinity is the affinity a column's declared type gives a comparison.
@(private)
declared_affinity :: proc(declared: Column_Type) -> Column_Affinity {
	#partial switch declared.kind {
	case .Int, .Uint, .Float:
		return .Numeric
	case .String:
		return .Text
	case .Any:
		return declared.width == SQLITE_NUMERIC_WIDTH ? .Numeric : .None
	}
	return .None
}

// comparison_affinity applies SQLite's rule before a comparison: a numeric
// column makes a text on the other side a number when it reads as one, and a
// text column makes a number on a side without affinity text.
@(private)
comparison_affinity :: proc(ctx: ^Eval_Ctx, left_expr, right_expr: ^Expr, left, right: Value) -> (Value, Value) {
	if left.kind == right.kind || left.kind == .Null || right.kind == .Null do return left, right
	return affinity_apply(column_affinity(ctx, left_expr), column_affinity(ctx, right_expr), left, right)
}

// affinity_apply is comparison_affinity once each side's affinity is known.
@(private)
affinity_apply :: proc(left_affinity, right_affinity: Column_Affinity, left, right: Value) -> (Value, Value) {
	if left.kind == right.kind || left.kind == .Null || right.kind == .Null do return left, right
	if left_affinity == .None && right_affinity == .None do return left, right
	convert :: proc(v: Value, affinity: Column_Affinity) -> Value {
		switch affinity {
		case .Numeric:
			if v.kind == .String {
				if number, ok := sqlite_text_number(v.s); ok do return number
			}
		case .Text:
			if sqlite_class(v) == 1 && v.kind != .Bool do return value_string(sqlite_value_text(v, context.temp_allocator))
		case .None:
		}
		return v
	}
	if left_affinity == .Numeric || right_affinity == .Numeric {
		return convert(left, .Numeric), convert(right, .Numeric)
	}
	// Text affinity converts only the side that has none.
	if left_affinity == .Text && right_affinity == .None do return left, convert(right, .Text)
	if right_affinity == .Text && left_affinity == .None do return convert(left, .Text), right
	return left, right
}

// collation_key_value is the value a key is built from when equality goes by
// a collation: NOCASE and RTRIM fold the text, and a host collation answers
// the first text of its class (collation_class). Anything else is the value.
collation_key_value :: proc(ctx: ^Eval_Ctx, expr: ^Expr, value: Value) -> Value {
	if value.kind != .String || expr == nil do return value
	name, has := collate_name(expr)
	if !has do name, has = column_collation(ctx, expr)
	if !has || len(name) == 0 || strings.equal_fold(name, "binary") do return value
	if collation_folds(ctx.tx != nil ? ctx.tx.store : nil, name) do return collate_ordered_value(value, name)
	if ctx.tx == nil do return value
	return value_string(collation_class(ctx.tx, name, value.s))
}

// collation_class is the first text this transaction saw that the host
// collation `name` calls equal to `text`: the classes are found by comparing
// with each one's first member, which a collation that is an equivalence
// makes the same answer whichever member is asked.
@(private)
collation_class :: proc(tx: ^Tx, name: string, text: string) -> string {
	if tx.collation_classes == nil do tx.collation_classes = make(map[string][dynamic]string, 2, tx.alloc)
	key := strings.to_lower(name, context.temp_allocator)
	classes, found := tx.collation_classes[key]
	if !found {
		key = strings.clone(key, tx.alloc)
		classes = make([dynamic]string, 0, 8, tx.alloc)
	}
	for member in classes {
		if order, known := collation_compare(tx.store, name, member, text); known && order == 0 do return member
	}
	append(&classes, strings.clone(text, tx.alloc))
	tx.collation_classes[key] = classes
	return classes[len(classes) - 1]
}

// distinct_key_values are a row's values as DISTINCT compares them: each
// under its projection's collation.
@(private)
distinct_key_values :: proc(ctx: ^Eval_Ctx, projections: []^Expr, values: []Value) -> []Value {
	keyed := make([]Value, len(values), context.temp_allocator)
	for value, i in values {
		keyed[i] = i < len(projections) ? collation_key_value(ctx, projections[i], value) : value
	}
	return keyed
}

// WINDOW_ORDER_TERM numbers a window's ORDER BY terms apart from the
// statement's, so their values are ranked among their own.
WINDOW_ORDER_TERM :: 1 << 20

// host_slot_append writes an order key slot for a host collation: the NULLS
// marker when there is one, then eight bytes the rank fills.
@(private)
host_slot_append :: proc(ctx: ^Eval_Ctx, w: ^Byte_Writer, item: Order_Item, term: int, value: Value, collation: string) {
	if ctx.host_slots == nil {
		ctx.host_slots = new([dynamic]Host_Order_Slot, ctx.tx.alloc)
		ctx.host_slots^ = make([dynamic]Host_Order_Slot, 0, 16, ctx.tx.alloc)
	}
	if item.nulls != .Default {
		marker: u8 = 1
		if value.kind == .Null do marker = item.nulls == .First ? 0 : 2
		append(&w.data, marker)
	}
	append(ctx.host_slots, Host_Order_Slot {
		offset     = len(w.data),
		term       = term,
		value      = value_clone(value, ctx.tx.alloc),
		collation  = collation,
		descending = item.descending,
	})
	for _ in 0 ..< 8 do append(&w.data, 0)
}

// column_host_collated reports a column declared with a host collation.
@(private)
column_host_collated :: proc(store: ^Store, column: Column) -> bool {
	if len(column.collation) == 0 || collation_folds(store, column.collation) do return false
	_, found := store_collation(store, column.collation)
	return found
}
