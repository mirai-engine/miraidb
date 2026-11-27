package engine

import "core:strings"

// Partial and expression indexes in the planner (D36, A2.5).
//
// A partial index holds only the rows its WHERE is true for, so it can answer
// a query only when the query's own terms imply that WHERE: each of the
// index's terms is one of the query's, written the same way, or is
// `x IS NOT NULL` where the query compares x (a NULL x makes every comparison
// but IS false). That is SQLite's rule.
//
// An expression index files each row under the value of its expression. It
// answers an equality whose one side is that expression, written the same way,
// and whose other side is a constant. The rows come back under every key the
// constant equals: a number is filed by its kind (an integer and an unsigned
// integer of the same value are two keys), and the index does not know which
// kind the expression gave. The WHERE runs on every row the index hands over,
// as it does for a column index, so a key too many costs a probe, never an
// answer.

// plan_index_for_column is the index that answers a term over `column`: a
// full index of that one column first, as before, then a partial one whose
// WHERE the query's terms imply.
plan_index_for_column :: proc(table: ^Table, ref: Table_Ref, column: int, conjuncts: []^Expr) -> (int, bool) {
	for i in 0 ..< len(table.indexes) {
		schema := table_index_schema(table, i)
		if !index_is_plain(schema^) || len(schema.columns) != 1 || schema.columns[0] != column do continue
		return i, true
	}
	for i in 0 ..< len(table.indexes) {
		schema := table_index_schema(table, i)
		if len(schema.exprs) > 0 || len(schema.where_sql) == 0 do continue
		if len(schema.columns) != 1 || schema.columns[0] != column do continue
		if plan_partial_implied(table, ref, i, conjuncts) do return i, true
	}
	return -1, false
}

// plan_expression_index is the index over one expression that answers `expr`,
// an equality between that expression and a constant.
plan_expression_index :: proc(
	store: ^Store,
	table: ^Table,
	ref: Table_Ref,
	expr: ^Expr,
	conjuncts: []^Expr,
	params: []Value,
) -> (int, bool) {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary || binary.op != .Eq do return -1, false
	for i in 0 ..< len(table.indexes) {
		schema := table_index_schema(table, i)
		if len(schema.columns) != 1 || len(schema.exprs) != 1 do continue
		part := table_index_part_expr(table, i, 0)
		if part == nil do continue
		value, matched := plan_part_value(table, ref, binary, part)
		if !matched || !plan_part_probe_ready(store, part, value, params) do continue
		if len(schema.where_sql) > 0 && !plan_partial_implied(table, ref, i, conjuncts) do continue
		return i, true
	}
	return -1, false
}

// plan_part_value is the side of `binary` that is not the index's expression,
// when the other side is it.
@(private)
plan_part_value :: proc(table: ^Table, ref: Table_Ref, binary: Binary_Expr, part: ^Expr) -> (^Expr, bool) {
	if plan_expr_same(table, ref, binary.left, part) do return binary.right, true
	if plan_expr_same(table, ref, binary.right, part) do return binary.left, true
	return nil, false
}

// plan_part_probe_ready reports whether an equality of the index's expression
// with `value` compares the way the index filed its keys. The comparison's
// collation is then the expression's own COLLATE, or none: the constant
// carries no COLLATE and names no column (collation_precedence). A bare column
// is a column index's business, and brings its declared collation. A
// collation a program defines or replaced is not the one the keys were folded
// by.
@(private)
plan_part_probe_ready :: proc(store: ^Store, part: ^Expr, value: ^Expr, params: []Value) -> bool {
	if _, is_column := part^.(Column_Expr); is_column do return false
	if _, collated := collate_name(value); collated do return false
	if name, has := collate_name(part); has && len(name) > 0 && !collation_folds(store, name) do return false
	_, constant := eval_constant(value, params)
	return constant
}

// plan_partial_implied reports whether the query's terms imply the WHERE of
// the partial index at `index`.
plan_partial_implied :: proc(table: ^Table, ref: Table_Ref, index: int, conjuncts: []^Expr) -> bool {
	where_expr := table_index_where_expr(table, index)
	if where_expr == nil do return len(table_index_schema(table, index).where_sql) == 0
	terms := make([dynamic]^Expr, context.temp_allocator)
	split_and(where_expr, &terms)
	for term in terms {
		if !plan_term_implied(table, ref, term, conjuncts) do return false
	}
	return true
}

// plan_term_implied reports whether one term of an index's WHERE holds for
// every row the query's terms keep.
@(private)
plan_term_implied :: proc(table: ^Table, ref: Table_Ref, term: ^Expr, conjuncts: []^Expr) -> bool {
	for conjunct in conjuncts {
		if plan_expr_same(table, ref, conjunct, term) do return true
	}
	operand := plan_not_null_operand(term)
	if operand == nil do return false
	for conjunct in conjuncts {
		#partial switch e in conjunct^ {
		case Binary_Expr:
			#partial switch e.op {
			case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
				if plan_expr_same(table, ref, e.left, operand) || plan_expr_same(table, ref, e.right, operand) do return true
			}
		case Between_Expr:
			if !e.negated && plan_expr_same(table, ref, e.operand, operand) do return true
		case In_Expr:
			if !e.negated && plan_expr_same(table, ref, e.operand, operand) do return true
		case Like_Expr:
			if !e.negated && plan_expr_same(table, ref, e.operand, operand) do return true
		}
	}
	return false
}

// plan_not_null_operand is x for a term `x IS NOT NULL` (or `x NOTNULL`),
// nil for any other term.
@(private)
plan_not_null_operand :: proc(term: ^Expr) -> ^Expr {
	#partial switch e in term^ {
	case Is_Null_Expr:
		if e.negated do return e.operand
	case Binary_Expr:
		if e.op != .Is_Not do return nil
		if literal, is_literal := e.right^.(Literal_Expr); is_literal && literal.value.kind == .Null do return e.left
	}
	return nil
}

// plan_expr_same reports whether `query`, an expression of a query over
// `ref`, is `index`, an expression of an index of `table`, written the same
// way: the same operators, functions and literals, and the same columns, the
// query's qualified or not. SQLite matches an index's expression the same
// way, by its form.
plan_expr_same :: proc(table: ^Table, ref: Table_Ref, query: ^Expr, index: ^Expr) -> bool {
	if query == nil || index == nil do return query == nil && index == nil
	switch q in query^ {
	case Literal_Expr:
		i, ok := index^.(Literal_Expr)
		return ok && q.value.kind == i.value.kind && value_equal(q.value, i.value)
	case Column_Expr:
		i, ok := index^.(Column_Expr)
		if !ok || !strings.equal_fold(q.name, i.name) do return false
		if !plan_names_relation(q.table, ref) do return false
		if len(i.table) > 0 && !strings.equal_fold(i.table, table.schema.name) do return false
		_, found := schema_column_index(&table.schema, q.name)
		return found
	case Binary_Expr:
		i, ok := index^.(Binary_Expr)
		return ok && q.op == i.op && plan_expr_same(table, ref, q.left, i.left) && plan_expr_same(table, ref, q.right, i.right)
	case Unary_Expr:
		i, ok := index^.(Unary_Expr)
		return ok && q.op == i.op && plan_expr_same(table, ref, q.operand, i.operand)
	case Is_Null_Expr:
		i, ok := index^.(Is_Null_Expr)
		return ok && q.negated == i.negated && plan_expr_same(table, ref, q.operand, i.operand)
	case Between_Expr:
		i, ok := index^.(Between_Expr)
		return(
			ok &&
			q.negated == i.negated &&
			plan_expr_same(table, ref, q.operand, i.operand) &&
			plan_expr_same(table, ref, q.low, i.low) &&
			plan_expr_same(table, ref, q.high, i.high) \
		)
	case In_Expr:
		i, ok := index^.(In_Expr)
		if !ok || q.negated != i.negated || q.subquery != nil || i.subquery != nil do return false
		if len(q.items) != len(i.items) || !plan_expr_same(table, ref, q.operand, i.operand) do return false
		for item, n in q.items do if !plan_expr_same(table, ref, item, i.items[n]) do return false
		return true
	case Call_Expr:
		i, ok := index^.(Call_Expr)
		if !ok || !strings.equal_fold(q.name, i.name) || q.star != i.star || q.is_distinct != i.is_distinct do return false
		if q.filter != nil || i.filter != nil || len(q.order_by) > 0 || len(i.order_by) > 0 do return false
		if len(q.args) != len(i.args) do return false
		for arg, n in q.args do if !plan_expr_same(table, ref, arg, i.args[n]) do return false
		return true
	case Like_Expr:
		i, ok := index^.(Like_Expr)
		return(
			ok &&
			q.negated == i.negated &&
			q.case_insensitive == i.case_insensitive &&
			q.glob == i.glob &&
			q.escape == i.escape &&
			plan_expr_same(table, ref, q.operand, i.operand) &&
			plan_expr_same(table, ref, q.pattern, i.pattern) \
		)
	case Cast_Expr:
		i, ok := index^.(Cast_Expr)
		return ok && strings.equal_fold(q.type_name, i.type_name) && plan_expr_same(table, ref, q.operand, i.operand)
	case Collate_Expr:
		i, ok := index^.(Collate_Expr)
		return ok && strings.equal_fold(q.name, i.name) && plan_expr_same(table, ref, q.operand, i.operand)
	case Case_Expr:
		i, ok := index^.(Case_Expr)
		if !ok || len(q.branches) != len(i.branches) do return false
		if !plan_expr_same(table, ref, q.operand, i.operand) || !plan_expr_same(table, ref, q.fallback, i.fallback) do return false
		for branch, n in q.branches {
			if !plan_expr_same(table, ref, branch.condition, i.branches[n].condition) do return false
			if !plan_expr_same(table, ref, branch.result, i.branches[n].result) do return false
		}
		return true
	case Star_Expr, Match_Expr, Param_Expr, Subquery_Expr, Window_Expr:
		// A parameter's value is not known when the index's text is, and the
		// others are never an index's.
		return false
	}
	return false
}

// candidates_from_expression answers an equality of an index's expression with
// a constant: the rows filed under each key the constant equals.
candidates_from_expression :: proc(
	tx: ^Tx,
	expr: ^Expr,
	table: ^Table,
	table_alias: string,
	index: int,
	params: []Value,
) -> ([dynamic]Row_Id, bool) {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary || binary.op != .Eq do return nil, false
	part := table_index_part_expr(table, index, 0)
	if part == nil do return nil, false
	ref := Table_Ref{name = table.schema.name, alias = table_alias}
	value_expr, matched := plan_part_value(table, ref, binary, part)
	if !matched || !plan_part_probe_ready(tx.store, part, value_expr, params) do return nil, false
	value, constant := eval_constant(value_expr, params)
	if !constant do return nil, false
	ids := make([dynamic]Row_Id)
	// No row equals NULL.
	if value.kind == .Null do return ids, true
	collation, _ := collate_name(part)
	keys := make([dynamic]string, context.temp_allocator)
	probes := 0
	for probe in expression_probe_values(table, part, value) {
		folded := probe
		if len(collation) > 0 do folded = collate_ordered_value(folded, collation)
		key := value_key_bytes(folded)
		seen := false
		for earlier in keys do if earlier == string(key) do seen = true
		if seen {
			delete(key)
			continue
		}
		append(&keys, strings.clone(string(key), context.temp_allocator))
		found := table_index_scan_prefix(table, index, string(key))
		delete(key)
		if len(found) > 0 do probes += 1
		append(&ids, ..found[:])
		delete(found)
	}
	// Rows under two keys come back in row order, as one key's do.
	if probes > 1 do row_ids_sort(ids[:])
	return ids, true
}

// expression_probe_values is every value an expression's key can hold for a
// row whose expression equals `value`: the value; for a COLLATE over a column,
// the value under that column's affinity too (column_affinity); and for a
// number, the same number in each numeric kind, whose keys differ.
@(private)
expression_probe_values :: proc(table: ^Table, part: ^Expr, value: Value) -> []Value {
	bases := make([dynamic]Value, 0, 2, context.temp_allocator)
	append(&bases, value)
	if collate, is_collate := part^.(Collate_Expr); is_collate {
		if column, is_column := collate.operand^.(Column_Expr); is_column {
			if position, found := schema_column_index(&table.schema, column.name); found {
				if converted, changed := affinity_convert_side(declared_affinity(table.schema.columns[position].type), value); changed {
					append(&bases, converted)
				}
			}
		}
	}
	out := make([dynamic]Value, 0, 12, context.temp_allocator)
	for base in bases {
		append(&out, base)
		if value_is_numeric(base) || base.kind == .Bool do numeric_twins(base, &out)
	}
	return out[:]
}

// affinity_convert_side is the constant side of affinity_apply: what a
// comparison with a column of `affinity` makes of `value`.
@(private)
affinity_convert_side :: proc(affinity: Column_Affinity, value: Value) -> (Value, bool) {
	switch affinity {
	case .Numeric:
		if value.kind == .String {
			if number, ok := sqlite_text_number(value.s); ok do return number, true
		}
	case .Text:
		if sqlite_class(value) == 1 && value.kind != .Bool {
			return value_string(sqlite_value_text(value, context.temp_allocator)), true
		}
	case .None:
	}
	return value, false
}

// numeric_twins appends the values of the other numeric kinds that equal the
// number `value` (and the boolean that does): each kind encodes its own key
// (value_encode_key).
@(private)
numeric_twins :: proc(value: Value, out: ^[dynamic]Value) {
	number := value
	if number.kind == .Bool do number = value_int(number.b ? 1 : 0)
	twins := make([dynamic]Value, 0, 12, context.temp_allocator)
	append(&twins, number)
	if f, ok := value_to_f64(number); ok do append(&twins, value_float(f))
	if i, ok := value_to_i64(number); ok {
		append(&twins, value_int(i), value_duration(Duration(i)), value_timestamp(Timestamp(i)))
	}
	if u, ok := value_to_u64(number); ok do append(&twins, value_uint(u), value_connection(u))
	big := value_as_i128(number)
	append(&twins, value_int128(big))
	if big >= 0 do append(&twins, value_uint128(u128(big)))
	if number.kind == .Uint128 do append(&twins, number)
	append(&twins, value_bool(false), value_bool(true))
	for twin in twins {
		if twin.kind == value.kind do continue
		order, ok := value_compare(twin, value)
		if ok && order == .Equal do append(out, twin)
	}
}
