package engine

import "core:slice"
import "core:strings"
import "core:time"

// --- Index-assisted filtering ----------------------------------------------

// rowid_candidates answers a WHERE that holds `rowid = k` (or `_rowid_`, `oid`)
// among its conjuncts with the one row it names, read by its id: a scan used to
// evaluate the comparison on every row, so a point read cost more than counting
// the table. The WHERE is still evaluated on the row afterwards, as it is on any
// candidate. A real column of that name is the column, not the rowid, as SQLite
// reads it; a single-column INTEGER PRIMARY KEY is the rowid, and is looked up in
// its index. A rowid that is not an integer, a table this transaction has written
// (the key's index does not hold its staged rows) and a WITHOUT ROWID table are
// left to the other paths. With a join, only a name qualified by this table is
// its rowid: a bare `oid` may be a column of another table in the FROM.
rowid_candidates :: proc(
	tx: ^Tx,
	table: ^Table,
	table_name: string,
	table_alias: string,
	predicate: ^Expr,
	params: []Value,
	joined: bool,
) -> (ids: [dynamic]Row_Id, used: bool) {
	if predicate == nil || table == nil || table.schema.without_rowid do return nil, false
	conjuncts := make([dynamic]^Expr, context.temp_allocator)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		binary, is_binary := expr^.(Binary_Expr)
		if !is_binary || binary.op != .Eq do continue
		qualifier, column_name, value_expr, _, ok := comparison_sides(binary)
		if !ok || !rowid_alias_name(column_name) do continue
		if joined && len(qualifier) == 0 do continue
		if len(qualifier) > 0 && !strings.equal_fold(qualifier, table.schema.name) &&
		   !(len(table_alias) > 0 && strings.equal_fold(qualifier, table_alias)) {
			continue
		}
		if _, real := schema_column_index(&table.schema, column_name); real do continue
		value, constant := eval_constant(value_expr, params)
		if !constant do continue
		key: i64
		#partial switch value.kind {
		case .Int:
			key = value.i
		case .Float:
			if value.f != f64(i64(value.f)) do continue
			key = i64(value.f)
		case:
			continue
		}
		ids = make([dynamic]Row_Id)
		schema := &table.schema
		if len(schema.primary_key) == 1 && schema.columns[schema.primary_key[0]].type.kind == .Int {
			// The rowid is the key column: its index finds the row, unless this
			// transaction staged rows the index does not hold yet.
			if _, staged := tx.state.writes[table_name]; staged {
				delete(ids)
				return nil, false
			}
			if _, created := tx.state.created[table_name]; created {
				delete(ids)
				return nil, false
			}
			if id, found := table_find_int_key(table, key); found do append(&ids, id)
			return ids, true
		}
		if key > 0 do append(&ids, Row_Id(key))
		return ids, true
	}
	return nil, false
}

// table_find_int_key is the row whose single-column INTEGER PRIMARY KEY is `key`.
@(private)
table_find_int_key :: proc(table: ^Table, key: i64) -> (Row_Id, bool) {
	values := make([]Value, len(table.schema.columns), context.temp_allocator)
	values[table.schema.primary_key[0]] = value_int(key)
	return table_find_primary_key(table, values)
}

// index_candidates tries to turn the WHERE clause into a small set of row ids
// using a single-column index. The caller still re-checks the whole predicate,
// so the result only has to be a superset of the matching rows.
@(private)
// fts_scan_candidates narrows a scan to the documents a MATCH selects. Without
// it the predicate would be evaluated on every row of the table; with it the scan
// visits the matches only, which is what makes the cost follow the answer instead
// of the corpus. The pattern has to be a constant (or a parameter), because a
// row-dependent pattern cannot be answered from one lookup.
fts_scan_candidates :: proc(
	tx: ^Tx,
	table_name: string,
	table_alias: string,
	predicate: ^Expr,
	params: []Value,
) -> (ids: [dynamic]Row_Id, used: bool, err: Error) {
	if predicate == nil do return nil, false, ERROR_NONE
	virtual, is_virtual := fts_virtual_lookup(tx, table_name)
	if !is_virtual || !fts_is_full_text(virtual) do return nil, false, ERROR_NONE
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		match, is_match := expr^.(Match_Expr)
		if !is_match do continue
		column, is_column := match.operand^.(Column_Expr)
		if !is_column do continue
		names_table := len(column.table) > 0 ? column.table : column.name
		named := strings.equal_fold(names_table, table_name) ||
			(len(table_alias) > 0 && strings.equal_fold(names_table, table_alias))
		if !named do continue
		pattern, constant := eval_constant(match.pattern, params)
		if !constant || pattern.kind != .String do continue
		result, match_err := fts_match_docs(tx, virtual, pattern.s)
		if match_err.kind != .None do return nil, true, match_err
		for doc in result.docs do append(&ids, doc)
		row_ids_sort(ids[:])
		return ids, true, ERROR_NONE
	}
	return nil, false, ERROR_NONE
}

index_candidates :: proc(
	tx: ^Tx,
	table: ^Table,
	table_name: string,
	table_alias: string,
	predicate: ^Expr,
	params: []Value,
) -> (ids: [dynamic]Row_Id, used: bool) {
	if predicate == nil do return nil, false
	// Staged writes are not in the index yet, so the scan would miss them.
	if _, staged := tx.state.writes[table_name]; staged do return nil, false
	if _, created := tx.state.created[table_name]; created do return nil, false
	// The planner compares every index the predicate could use against the scan
	// and hands back the cheapest one, or none when the scan wins.
	plan := plan_access(tx.store, table, Table_Ref{name = table_name, alias = table_alias}, predicate, params)
	if plan.kind != .Index do return nil, false
	// Both ends of a range travel together: `v >= 5 AND v < 9` is one scan over
	// [5, 9), which is what the plan priced.
	conjunct, companion := plan.conjunct, plan.conjunct2
	if candidates, ok := candidates_from_range(conjunct, companion, table, table_alias, plan.index, params); ok {
		return candidates, true
	}
	return nil, false
}

// candidates_from_range answers one comparison, or two that share a column, with
// one index scan: the lower bound is where it starts and the upper bound where it
// stops, each keeping the operator's own inclusivity. Anything else falls back to
// the single-comparison path.
@(private)
candidates_from_range :: proc(
	expr: ^Expr,
	companion: ^Expr,
	table: ^Table,
	table_alias: string,
	index_position: int,
	params: []Value,
) -> ([dynamic]Row_Id, bool) {
	if companion == nil {
		return candidates_from_conjunct(expr, table, table_alias, index_position, params)
	}
	first, first_ok := range_key(table, table_alias, expr, params)
	second, second_ok := range_key(table, table_alias, companion, params)
	if !first_ok || !second_ok {
		if first_ok do delete(first.key)
		if second_ok do delete(second.key)
		return nil, false
	}
	defer delete(first.key)
	defer delete(second.key)
	if first.lower == second.lower do return nil, false
	low := first
	high := second
	if !first.lower {
		low = second
		high = first
	}
	return table_index_scan(table, index_position, string(low.key), string(high.key), high.inclusive), true
}

// Range_Key is one end of a range as the index needs it: the encoded boundary, and
// whether it holds the rows above or below it.
@(private)
Range_Key :: struct {
	key:       []u8,
	lower:     bool,
	inclusive: bool,
}

@(private)
range_key :: proc(
	table: ^Table,
	table_alias: string,
	expr: ^Expr,
	params: []Value,
) -> (Range_Key, bool) {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary do return {}, false
	lower: bool
	inclusive: bool
	#partial switch binary.op {
	case .Gt:
		lower = true
	case .Ge:
		lower = true
		inclusive = true
	case .Lt:
		lower = false
	case .Le:
		lower = false
		inclusive = true
	case:
		return {}, false
	}
	qualifier, column_name, value_expr, reversed, sides_ok := comparison_sides(binary)
	if !sides_ok do return {}, false
	if len(qualifier) > 0 &&
	   !strings.equal_fold(qualifier, table.schema.name) &&
	   !(len(table_alias) > 0 && strings.equal_fold(qualifier, table_alias)) {
		return {}, false
	}
	column_index, found := schema_column_index(&table.schema, column_name)
	if !found do return {}, false
	value, constant := eval_constant(value_expr, params)
	if !constant do return {}, false
	coerced, coerce_err := value_coerce(value, table.schema.columns[column_index].type)
	if coerce_err.kind != .None {
		error_free(&coerce_err)
		return {}, false
	}
	// An index cannot answer a collation the program replaced: it was folded
	// by the built-in rule.
	if column_host_collated(statement_store(), table.schema.columns[column_index]) do return {}, false
	if len(table.schema.columns[column_index].collation) > 0 {
		coerced = collate_ordered_value(coerced, table.schema.columns[column_index].collation)
	}
	// `5 < v` is the lower bound written the other way round.
	if reversed do lower = !lower
	return Range_Key{key = value_key_bytes(coerced), lower = lower, inclusive = inclusive}, true
}

// select_filters_rows reports whether the rows of a table can be dropped after the
// base scan, which is what stops a LIMIT from ending the ordered walk early.
@(private)
select_filters_rows :: proc(tx: ^Tx, name: string) -> bool {
	if len(name) == 0 || is_system_table(name) do return false
	set, err := policy_load(tx, name)
	if err.kind != .None do return true
	active := len(set.using_exprs) > 0
	policy_set_destroy(&set)
	return active
}

// select_row_limit is how many rows an ordered walk has to collect for LIMIT and
// OFFSET to have something to work with. Zero means "no limit".
@(private)
select_row_limit :: proc(stmt: Select_Stmt, params: []Value) -> int {
	if stmt.limit == nil do return 0
	offset := 0
	if stmt.offset != nil {
		if value, constant := eval_constant(stmt.offset, params); constant {
			if number, is_integer := value_to_i64(value); is_integer && number > 0 do offset = int(number)
		}
	}
	value, constant := eval_constant(stmt.limit, params)
	if !constant do return 0
	number, is_integer := value_to_i64(value)
	if !is_integer || number < 0 do return 0
	return int(number) + offset
}

// index_order_for finds an index that hands a statement its rows in the order the
// statement asks for, which lets the sort go. The ORDER BY has to name the whole
// key of one in-memory index, in the index's own order and all in one direction:
// a prefix would order the ties by the rest of the index instead of by row id, and
// the sequence would differ from the sorted one. Descending is served only by a
// unique index, where no two rows tie.
@(private)
index_order_for :: proc(
	tx: ^Tx,
	table: ^Table,
	ref: Table_Ref,
	stmt: Select_Stmt,
) -> (
	index: int,
	descending: bool,
	ok: bool,
) {
	index = -1
	if table == nil || table.paged != nil do return index, false, false
	if len(stmt.order_by) == 0 || len(stmt.joins) != 0 do return index, false, false
	if stmt.is_distinct || len(stmt.group_by) > 0 || stmt.having != nil do return index, false, false
	if len(stmt.compound) > 0 || stmt.is_distinct do return index, false, false
	for item in stmt.projections {
		if item.expr == nil do continue
		if expr_is_aggregate(item.expr) do return index, false, false
		if _, is_window := item.expr^.(Window_Expr); is_window do return index, false, false
	}
	// An index lags the staged writes of its table, and a table created in this
	// transaction has none worth reading.
	if _, staged := tx.state.writes[ref.name]; staged do return index, false, false
	if _, created := tx.state.created[ref.name]; created do return index, false, false
	direction := stmt.order_by[0].descending
	for item in stmt.order_by {
		if item.descending != direction do return index, false, false
		if item.nulls != .Default do return index, false, false
	}
	for &candidate, position in table.indexes {
		if candidate.pages != nil do continue
		// A partial or expression index does not hold every row by its columns.
		if !index_is_plain(candidate.schema) do continue
		if len(candidate.schema.columns) != len(stmt.order_by) do continue
		if direction && !candidate.unique do continue
		matched := true
		for item, i in stmt.order_by {
			reference, is_column := item.expr^.(Column_Expr)
			if !is_column {
				matched = false
				break
			}
			if len(reference.table) > 0 && !qualifier_names(reference.table, table.schema.name, ref.alias) {
				matched = false
				break
			}
			column_index, found := schema_column_index(&table.schema, reference.name)
			if !found || column_index != candidate.schema.columns[i] {
				matched = false
				break
			}
		}
		if matched do return position, direction, true
	}
	return index, false, false
}

// index_order_ids lists the row ids of one index in key order, or in the reverse
// order when the statement is descending. `max_rows` stops the walk early, which
// is what turns `ORDER BY id LIMIT 5` into five reads instead of a pass over the
// whole table; zero means no stop.
@(private)
index_order_ids :: proc(
	table: ^Table,
	index: int,
	descending: bool,
	max_rows: int,
) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id)
	tree := &table.indexes[index].tree
	// A key's rows come out ascending by id, or descending for a descending walk,
	// as they did when each row had its own entry.
	if descending {
		for c := ib_last(tree); c.valid && (max_rows <= 0 || len(ids) < max_rows); c.valid = ib_retreat(&c) {
			slot := ib_slot(&c)
			#reverse for id in slot.more do append(&ids, id)
			append(&ids, slot.first)
		}
	} else {
		for c := ib_first(tree); c.valid && (max_rows <= 0 || len(ids) < max_rows); c.valid = ib_advance(&c) {
			index_slot_append(&ids, ib_slot(&c)^)
		}
	}
	if max_rows > 0 && len(ids) > max_rows do resize(&ids, max_rows)
	return ids
}

// Index_Probe is how a nested loop finds the inner rows one outer row joins to:
// the equality binds one column of the inner table to an expression over the
// outer sources, and that column leads one of its indexes. index is -1 when the
// loop has to scan.
@(private)
Index_Probe :: struct {
	index:  int,
	column: int,
	value:  ^Expr,
}

// join_index_probe reads the ON clause of one join step and finds an equality it
// can answer with an index of the inner table: `inner.column = <outer
// expression>`. A multi-column index answers it when the bound column leads the
// index, because a prefix scan still narrows the tree.
@(private)
join_index_probe :: proc(
	table: ^Table,
	alias: string,
	predicate: ^Expr,
) -> (probe: Index_Probe, ok: bool) {
	probe.index = -1
	if table == nil || predicate == nil do return probe, false
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		binary, is_binary := expr^.(Binary_Expr)
		if !is_binary || binary.op != .Eq do continue
		// Either side may be the inner column; the other is the value to probe.
		sides := [2][2]^Expr{{binary.left, binary.right}, {binary.right, binary.left}}
		for side in sides {
			reference, is_column := side[0]^.(Column_Expr)
			if !is_column do continue
			if len(reference.table) > 0 && !qualifier_names(reference.table, table.schema.name, alias) do continue
			column_index, found := schema_column_index(&table.schema, reference.name)
			if !found do continue
			for &index, i in table.indexes {
				if len(index.schema.columns) == 0 do continue
				if !index_is_plain(index.schema) do continue
				// A probe answers an index that leads with the column it binds.
				if index.schema.columns[0] != column_index do continue
				return Index_Probe{index = i, column = column_index, value = side[1]}, true
			}
		}
	}
	return probe, false
}

// join_probe_rows evaluates the probe for one outer row and returns the rows its
// key names. It reports false when the value cannot be turned into a key (an
// error the scan will report, a value that does not coerce), so the caller scans
// instead of answering a query with fewer rows than it has.
@(private)
join_probe_rows :: proc(
	tx: ^Tx,
	table: ^Table,
	name: string,
	probe: Index_Probe,
	partial: []Source,
	ctx: ^Eval_Ctx,
) -> (rows: [dynamic]Row, ok: bool) {
	ctx.sources = partial
	value, eval_err := eval_expr(ctx, probe.value)
	if eval_err.kind != .None {
		error_free(&eval_err)
		return nil, false
	}
	coerced, coerce_err := value_coerce(value, table.schema.columns[probe.column].type)
	if coerce_err.kind != .None {
		error_free(&coerce_err)
		return nil, false
	}
	if column_host_collated(tx.store, table.schema.columns[probe.column]) do return nil, false
	if len(table.schema.columns[probe.column].collation) > 0 {
		coerced = collate_ordered_value(coerced, table.schema.columns[probe.column].collation)
	}
	key := value_key_bytes(coerced)
	defer delete(key)
	ids := table_index_scan_prefix(table, probe.index, string(key))
	defer delete(ids)
	for id in ids {
		if row, exists := tx_get(tx, name, id); exists do append(&rows, row)
	}
	return rows, true
}

@(private)
split_and :: proc(expr: ^Expr, out: ^[dynamic]^Expr) {
	if expr == nil do return
	if binary, ok := expr^.(Binary_Expr); ok && binary.op == .And {
		split_and(binary.left, out)
		split_and(binary.right, out)
		return
	}
	append(out, expr)
}

@(private)
candidates_from_conjunct :: proc(
	expr: ^Expr,
	table: ^Table,
	table_alias: string,
	index_position: int,
	params: []Value,
) -> ([dynamic]Row_Id, bool) {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary do return nil, false
	if binary.op == .Eq || binary.op == .Lt || binary.op == .Le || binary.op == .Gt || binary.op == .Ge {
		qualifier, column_name, value_expr, reversed, ok := comparison_sides(binary)
		if !ok do return nil, false
		// A column of a joined table has its own index (and its own scan); only
		// the base table can use this shortcut.
		if len(qualifier) > 0 &&
		   !strings.equal_fold(qualifier, table.schema.name) &&
		   !(len(table_alias) > 0 && strings.equal_fold(qualifier, table_alias)) {
			return nil, false
		}
		column_index, found := schema_column_index(&table.schema, column_name)
		if !found do return nil, false
		value, constant := eval_constant(value_expr, params)
		if !constant do return nil, false
		coerced, coerce_err := value_coerce(value, table.schema.columns[column_index].type)
		if coerce_err.kind != .None {
			error_free(&coerce_err)
			return nil, false
		}
		if column_host_collated(statement_store(), table.schema.columns[column_index]) do return nil, false
		// The index folded the text, so the probe must fold it the same way.
		if len(table.schema.columns[column_index].collation) > 0 {
			coerced = collate_ordered_value(coerced, table.schema.columns[column_index].collation)
		}
		key := value_key_bytes(coerced)
		defer delete(key)
		op := binary.op
		if reversed {
			#partial switch op {
			case .Lt:
				op = .Gt
			case .Le:
				op = .Ge
			case .Gt:
				op = .Lt
			case .Ge:
				op = .Le
			}
		}
		#partial switch op {
		case .Eq:
			return table_index_scan_prefix(table, index_position, string(key)), true
		case .Lt:
			return table_index_scan(table, index_position, "", string(key), false), true
		case .Le:
			return table_index_scan(table, index_position, "", string(key), true), true
		case .Gt, .Ge:
			// Include the boundary; the WHERE re-check drops it when needed.
			return table_index_scan(table, index_position, string(key), "", true), true
		case:
		}
		return nil, false
	}
	between, is_between := expr^.(Between_Expr)
	if is_between && !between.negated {
		column, ok := between.operand^.(Column_Expr)
		if !ok do return nil, false
		if len(column.table) > 0 && !qualifier_names(column.table, table.schema.name, table_alias) do return nil, false
		column_index, found := schema_column_index(&table.schema, column.name)
		if !found do return nil, false
		low, low_ok := eval_constant(between.low, params)
		high, high_ok := eval_constant(between.high, params)
		if !low_ok || !high_ok do return nil, false
		low_value, low_err := value_coerce(low, table.schema.columns[column_index].type)
		high_value, high_err := value_coerce(high, table.schema.columns[column_index].type)
		if low_err.kind != .None || high_err.kind != .None do return nil, false
		low_key := value_key_bytes(low_value)
		defer delete(low_key)
		high_key := value_key_bytes(high_value)
		defer delete(high_key)
		return table_index_scan(table, index_position, string(low_key), string(high_key), true), true
	}
	return nil, false
}

@(private)
comparison_sides :: proc(
	binary: Binary_Expr,
) -> (qualifier: string, column: string, value: ^Expr, reversed: bool, ok: bool) {
	if ref, is_column := binary.left^.(Column_Expr); is_column {
		return ref.table, ref.name, binary.right, false, true
	}
	if ref, is_column := binary.right^.(Column_Expr); is_column {
		return ref.table, ref.name, binary.left, true, true
	}
	return "", "", nil, false, false
}

@(private)
index_for_single_column :: proc(table: ^Table, column: int) -> (int, bool) {
	for index, i in table.indexes {
		if !index_is_plain(index.schema) do continue
		if len(index.schema.columns) == 1 && index.schema.columns[0] == column {
			return i, true
		}
	}
	return -1, false
}

// eval_constant evaluates an expression that does not depend on a row.
@(private)
eval_constant :: proc(expr: ^Expr, params: []Value) -> (Value, bool) {
	if expr == nil do return {}, false
	switch e in expr^ {
	case Literal_Expr:
		return e.value, true
	case Param_Expr:
		if e.index >= 0 && e.index < len(params) do return params[e.index], true
	case Collate_Expr:
		return eval_constant(e.operand, params)
	case Window_Expr:
		return {}, false
	case Unary_Expr:
		value, ok := eval_constant(e.operand, params)
		if !ok do return {}, false
		result, eval_err := eval_unary(e.op, value)
		return result, eval_err.kind == .None
	case Cast_Expr:
		value, ok := eval_constant(e.operand, params)
		if !ok do return {}, false
		result, cast_err := value_cast(value, e.target)
		return result, cast_err.kind == .None
	case Match_Expr:
		// MATCH reads the shadow table, so it is never a constant.
		return {}, false
	case Case_Expr:
		// A CASE is constant when every condition and every result is, but the
		// values still have to be evaluated in context, so it never folds here.
		return {}, false
	case Column_Expr, Star_Expr, Binary_Expr, Is_Null_Expr, Between_Expr, In_Expr, Call_Expr, Like_Expr, Subquery_Expr:
	}
	return {}, false
}

@(private)
now_microseconds :: proc() -> i64 {
	return time.now()._nsec / 1000
}

// sql_hex_digit decodes one hexadecimal character.
@(private)
sql_hex_digit :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9': return int(c - '0'), true
	case 'a' ..= 'f': return int(c - 'a') + 10, true
	case 'A' ..= 'F': return int(c - 'A') + 10, true
	}
	return 0, false
}

// rng_state backs random() and randomblob(); it starts from the clock and
// advances with xorshift64, so no global initialisation is required.
rng_state: u64 = 0

@(private)
rng_next :: proc() -> u64 {
	state := rng_state
	if state == 0 do state = u64(now_microseconds()) | 1
	state ~= state << 13
	state ~= state >> 7
	state ~= state << 17
	rng_state = state
	return state
}

// collate_name reports the collation an expression attaches, if any.
@(private)
collate_name :: proc(expr: ^Expr) -> (string, bool) {
	if expr == nil do return "", false
	if collate, ok := expr^.(Collate_Expr); ok do return collate.name, true
	return "", false
}

// in_equal is IN's test of one member: equality, under the operand's
// collation when it has one.
@(private)
in_equal :: proc(a, b: Value, collation: string, store: ^Store) -> bool {
	if len(collation) == 0 do return value_equal(a, b)
	order, ok := value_compare_collated(a, b, collation, store)
	return ok && order == .Equal
}

// comparison_collation is the collation a comparison of two operands uses
// (collation_precedence).
@(private)
comparison_collation :: proc(ctx: ^Eval_Ctx, left, right: ^Expr) -> string {
	return collation_precedence(collation_operand(ctx, left), collation_operand(ctx, right))
}

// value_compare_collated applies an expression-level collation to two texts. The
// three built-in names fold the text into a byte comparison; a host comparison is
// asked, which is the whole point of registering one. BINARY (the default) and an
// empty name are the plain comparison, and a name nobody knows was refused before
// the statement ran (collation_problem).
@(private)
value_compare_collated :: proc(
	a, b: Value,
	collation: string,
	store: ^Store,
) -> (order: slice.Ordering, ok: bool) {
	if len(collation) > 0 && a.kind == .String && b.kind == .String {
		if compared, known := collation_compare(store, collation, a.s, b.s); known {
			return string_ordering(compared), true
		}
	}
	return value_compare(a, b)
}

// value_compare_decided is value_compare_collated through a collation decided
// when the statement was resolved, when there is one.
@(private)
value_compare_decided :: #force_inline proc(a, b: Value, collation: string, store: ^Store, ref: ^Collation_Ref) -> (order: slice.Ordering, ok: bool) {
	if ref == nil do return value_compare_collated(a, b, collation, store)
	if a.kind == .String && b.kind == .String do return string_ordering(collation_ref_compare(ref, a.s, b.s)), true
	return value_compare(a, b)
}
