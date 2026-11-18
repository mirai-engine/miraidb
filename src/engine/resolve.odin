package engine

import "core:strings"

// --- Names are resolved before a statement runs (D37) ----------------------
//
// The executor resolves a column reference when it evaluates it against a row,
// so a misspelled name on an empty table used to answer "0 rows" and fail only
// once the table had one: the same statement passed its tests and failed in
// production. SQLite refuses it when the statement is prepared. This pass reads
// the statement against the catalog before it runs, with the scopes the
// executor uses, and refuses a table or a column that is not there.
//
// It refuses only what it is sure of. A reference is unknown -- and allowed --
// when any relation in reach has columns the pass cannot list (a table
// function, an attached or system table, a view or CTE whose columns it cannot
// tell), when it could be a projection alias, or when it names NEW, OLD or
// excluded. A wrong refusal would break a statement that works; a missed one
// leaves the old behaviour.

@(private)
Res_Walk :: struct {
	tx:     ^Tx,
	scopes: [dynamic]Res_Scope,
	ctes:   [dynamic]Res_Cte,
	depth:  int,
	err:    Error,
	// where_projections are the select list a WHERE may name by its aliases,
	// as SQLite allows, while that WHERE (scope where_scope) is walked.
	where_projections: []Select_Item,
	where_scope:       int,
}

// Res_Scope is one query's relations and the aliases its projections give,
// which its own clauses (and the queries nested in them) may name.
@(private)
Res_Scope :: struct {
	sources: [dynamic]Res_Source,
	aliases: []string,
}

// Res_Source is one relation: its name, alias and columns. `known` is false
// when its columns cannot be listed, and then any name may be its.
@(private)
Res_Source :: struct {
	name:    string,
	alias:   string,
	columns: []string,
	known:   bool,
	// table is set for a table of the database: its row id and a full-text
	// table's hidden columns are names too; no_rowid for one WITHOUT ROWID.
	table:   bool,
	no_rowid: bool,
}

@(private)
Res_Cte :: struct {
	name:    string,
	columns: []string,
	known:   bool,
}

// sql_resolve_names checks every table and column `statement` names against
// what `tx` sees, and answers the error SQLite gives at prepare for the first
// one that is not there.
sql_resolve_names :: proc(tx: ^Tx, statement: ^Statement) -> Error {
	if tx == nil || statement == nil do return ERROR_NONE
	walk := Res_Walk{tx = tx}
	walk.scopes = make([dynamic]Res_Scope, 0, 4, context.temp_allocator)
	walk.ctes = make([dynamic]Res_Cte, 0, 2, context.temp_allocator)
	res_statement(&walk, statement)
	return walk.err
}

@(private)
res_no_table :: proc(walk: ^Res_Walk, name: string) {
	if walk.err.kind != .None do return
	if walk.tx.store != nil && walk.tx.store.sqlite_names {
		walk.err = errf(.Table_Not_Found, "no such table: %s", name)
	} else {
		walk.err = errf(.Table_Not_Found, "table %s does not exist", name)
	}
}

@(private)
res_no_column :: proc(walk: ^Res_Walk, column: Column_Expr) {
	if walk.err.kind != .None do return
	shown := column.name
	if len(column.table) > 0 do shown = strings.concatenate({column.table, ".", column.name}, context.temp_allocator)
	if walk.tx.store != nil && walk.tx.store.sqlite_names {
		walk.err = errf(.Column_Not_Found, "no such column: %s", shown)
	} else {
		walk.err = errf(.Column_Not_Found, "column %s does not exist", shown)
	}
}

@(private)
res_statement :: proc(walk: ^Res_Walk, statement: ^Statement) {
	#partial switch &s in statement^ {
	case Select_Stmt:
		res_select(walk, &s)
	case With_Stmt:
		res_with(walk, s.ctes, s.recursive, &s.select_stmt)
	case Insert_Stmt:
		base := res_push_ctes(walk, s.ctes, s.ctes_recursive)
		defer resize(&walk.ctes, base)
		target, found := res_write_target(walk, s.table)
		if !found do return
		if target.known {
			for column in s.columns {
				if !res_has_column(target, column) {
					if walk.tx.store != nil && walk.tx.store.sqlite_names {
						walk.err = errf(.Column_Not_Found, "table %s has no column named %s", s.table, column)
					} else {
						walk.err = errf(.Column_Not_Found, "column %s does not exist in %s", column, s.table)
					}
					return
				}
			}
		}
		for row in s.rows do for expr in row do res_expr(walk, expr)
		if s.has_select do res_select(walk, &s.select_stmt)
		if len(s.conflict_assignments) > 0 {
			// DO UPDATE reads the target row and the proposed one as excluded.
			scope := Res_Scope{sources = make([dynamic]Res_Source, 0, 2, context.temp_allocator)}
			append(&scope.sources, target)
			excluded := target
			excluded.alias = "excluded"
			append(&scope.sources, excluded)
			append(&walk.scopes, scope)
			for assignment in s.conflict_assignments do res_expr(walk, assignment.value)
			pop(&walk.scopes)
		}
	case Update_Stmt:
		base := res_push_ctes(walk, s.ctes, s.ctes_recursive)
		defer resize(&walk.ctes, base)
		target, found := res_write_target(walk, s.table)
		if !found do return
		scope := Res_Scope{sources = make([dynamic]Res_Source, 0, 2, context.temp_allocator)}
		append(&scope.sources, target)
		if len(s.from.name) > 0 || s.from.subquery != nil do res_ref(walk, &scope, &s.from)
		append(&walk.scopes, scope)
		defer pop(&walk.scopes)
		for assignment in s.assignments {
			if target.known && !res_has_column(target, assignment.column) {
				res_no_column(walk, Column_Expr{name = assignment.column})
				return
			}
			res_expr(walk, assignment.value)
		}
		res_expr(walk, s.where_clause)
	case Create_Table_Stmt, Create_View_Stmt, Create_Index_Stmt, Drop_Table_Stmt, Drop_View_Stmt, Drop_Index_Stmt, Create_Trigger_Stmt, Alter_Table_Stmt:
		res_ddl(walk, statement)
	case Delete_Stmt:
		base := res_push_ctes(walk, s.ctes, s.ctes_recursive)
		defer resize(&walk.ctes, base)
		target, found := res_write_target(walk, s.table)
		if !found do return
		scope := Res_Scope{sources = make([dynamic]Res_Source, 0, 2, context.temp_allocator)}
		append(&scope.sources, target)
		if len(s.using_ref.name) > 0 || s.using_ref.subquery != nil do res_ref(walk, &scope, &s.using_ref)
		append(&walk.scopes, scope)
		defer pop(&walk.scopes)
		res_expr(walk, s.where_clause)
	}
}

// res_write_target is the table a write names. A name that is not a table may
// still be written through something the pass does not model (a view with a
// trigger), so only a name that is nothing at all is refused.
@(private)
res_write_target :: proc(walk: ^Res_Walk, name: string) -> (Res_Source, bool) {
	if table := tx_table_probe(walk.tx, name); table != nil {
		return res_table_source(table, ""), true
	}
	if _, is_view := view_sql(walk.tx, name); is_view || is_system_table(name) || res_internal(name) || (strings.equal_fold(name, "sqlite_sequence") && sqlite_sequence_exists(walk.tx)) {
		return Res_Source{name = name}, true
	}
	if vtab, is_vtab, _ := vtab_find(walk.tx, name); is_vtab {
		return res_vtab_source(vtab, ""), true
	}
	res_no_table(walk, name)
	return {}, false
}

// res_internal reports a catalog table the engine creates on first use: a
// statement may name it before it exists.
@(private)
res_internal :: proc(name: string) -> bool {
	return len(name) > 0 && name[0] == '_'
}

@(private)
res_table_source :: proc(table: ^Table, alias: string) -> Res_Source {
	columns := make([]string, len(table.schema.columns), context.temp_allocator)
	for column, i in table.schema.columns do columns[i] = column.name
	return Res_Source{name = table.schema.name, alias = alias, columns = columns, known = true, table = true, no_rowid = table.schema.without_rowid}
}

// res_vtab_source is a program's virtual table: its declared columns, hidden
// ones included, and its row id.
@(private)
res_vtab_source :: proc(vtab: ^Vtab, alias: string) -> Res_Source {
	columns := make([]string, len(vtab.columns), context.temp_allocator)
	for column, i in vtab.columns do columns[i] = column.name
	return Res_Source{name = vtab.name, alias = alias, columns = columns, known = true, table = true}
}

@(private)
res_has_column :: proc(source: Res_Source, name: string) -> bool {
	for column in source.columns do if strings.equal_fold(column, name) do return true
	if source.table {
		// The row id, and a full-text table's score and its own name (`t MATCH`).
		if rowid_alias_name(name) && !source.no_rowid do return true
		if strings.equal_fold(name, "rank") || strings.equal_fold(name, source.name) do return true
	}
	return false
}

@(private)
res_push_ctes :: proc(walk: ^Res_Walk, ctes: []Cte, recursive: bool) -> int {
	base := len(walk.ctes)
	for &cte in ctes {
		// A recursive CTE reads itself: its name is in scope in its own body,
		// with the columns it declares or none known.
		append(&walk.ctes, Res_Cte{name = cte.name, columns = cte.columns, known = len(cte.columns) > 0})
		if !recursive {
			pop(&walk.ctes)
		}
		names := make([dynamic]string, 0, 4, context.temp_allocator)
		complete := res_select(walk, &cte.select_stmt, &names)
		if recursive do pop(&walk.ctes)
		entry := Res_Cte{name = cte.name, columns = cte.columns, known = len(cte.columns) > 0}
		if !entry.known && complete {
			entry.columns = names[:]
			entry.known = true
		}
		append(&walk.ctes, entry)
		if walk.err.kind != .None do break
	}
	return base
}

@(private)
res_with :: proc(walk: ^Res_Walk, ctes: []Cte, recursive: bool, select: ^Select_Stmt, names: ^[dynamic]string = nil) -> bool {
	base := res_push_ctes(walk, ctes, recursive)
	defer resize(&walk.ctes, base)
	if walk.err.kind != .None do return false
	return res_select(walk, select, names)
}

// res_ref adds the relation one FROM or JOIN entry names to `scope`, and
// refuses a name that is no relation at all.
@(private)
res_ref :: proc(walk: ^Res_Walk, scope: ^Res_Scope, ref: ^Table_Ref) {
	source := Res_Source{name = ref.name, alias = ref.alias}
	defer append(&scope.sources, source)
	if ref.subquery != nil {
		names := make([dynamic]string, 0, 4, context.temp_allocator)
		// A LATERAL subquery reads the relations to its left.
		if ref.lateral do append(&walk.scopes, scope^)
		source.known = res_select(walk, ref.subquery, &names)
		if ref.lateral do pop(&walk.scopes)
		// The parser keeps a derived table's name in `name` or `alias`.
		if len(ref.alias) > 0 do source.name = ref.alias
		source.columns = names[:]
		return
	}
	if ref.as_of != nil do res_expr(walk, ref.as_of)
	if len(ref.args) > 0 {
		// Arguments of a table function may read the relations to their left.
		append(&walk.scopes, scope^)
		for arg in ref.args do res_expr(walk, arg)
		pop(&walk.scopes)
	}
	for i := len(walk.ctes) - 1; i >= 0; i -= 1 {
		cte := walk.ctes[i]
		if !strings.equal_fold(cte.name, ref.name) do continue
		source.columns = cte.columns
		source.known = cte.known
		return
	}
	if len(ref.schema) > 0 || is_json_table_function(ref.name) || is_pragma_function(ref.name) || is_system_table(ref.name) do return
	if strings.equal_fold(ref.name, "sqlite_sequence") && tx_table_probe(walk.tx, ref.name) == nil && sqlite_sequence_exists(walk.tx) {
		source.columns = SEQUENCE_COLUMNS
		source.known = true
		return
	}
	if is_schema, _ := sqlite_schema_name(ref.name); is_schema && tx_table_probe(walk.tx, ref.name) == nil {
		source.columns = SQLITE_SCHEMA_COLUMNS
		source.known = true
		return
	}
	if table := tx_table_probe(walk.tx, ref.name); table != nil {
		// A table given arguments is refused by the executor, in its words.
		if len(ref.args) > 0 do return
		source = res_table_source(table, ref.alias)
		return
	}
	if vtab, is_vtab, vtab_err := vtab_find(walk.tx, ref.name); is_vtab || vtab_err.kind != .None {
		if vtab_err.kind != .None {
			walk.err = vtab_err
			return
		}
		source = res_vtab_source(vtab, ref.alias)
		return
	}
	if sql, found := view_sql(walk.tx, ref.name); found {
		// A view with parameters is read with them; its columns are left unknown.
		if len(ref.args) == 0 do source.columns, source.known = res_view_columns(walk, sql)
		return
	}
	if res_internal(ref.name) do return
	res_no_table(walk, ref.name)
}

// res_view_columns lists a view's columns from its query. A view whose query
// fails here is not this statement's mistake: its columns are just unknown.
@(private)
res_view_columns :: proc(walk: ^Res_Walk, sql: string) -> ([]string, bool) {
	if walk.depth >= VIEW_MAX_DEPTH do return nil, false
	query, parse_err := sql_parse(sql)
	defer query_destroy(&query)
	if parse_err.kind != .None do return nil, false
	inner := Res_Walk{tx = walk.tx, depth = walk.depth + 1}
	inner.scopes = make([dynamic]Res_Scope, 0, 4, context.temp_allocator)
	inner.ctes = make([dynamic]Res_Cte, 0, 2, context.temp_allocator)
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	complete := false
	#partial switch &s in query.statement {
	case Select_Stmt:
		complete = res_select(&inner, &s, &names)
	case With_Stmt:
		complete = res_with(&inner, s.ctes, s.recursive, &s.select_stmt, &names)
	}
	if !error_drop(inner.err) || !complete do return nil, false
	for &name in names do name = strings.clone(name, context.temp_allocator)
	return names[:], true
}

// res_select checks one query and collects its result column names in
// `names`; it answers whether that list is complete.
@(private)
res_select :: proc(walk: ^Res_Walk, select: ^Select_Stmt, names: ^[dynamic]string = nil) -> bool {
	if walk.err.kind != .None do return false
	scope := Res_Scope{sources = make([dynamic]Res_Source, 0, 2, context.temp_allocator)}
	if len(select.from.name) > 0 || select.from.subquery != nil do res_ref(walk, &scope, &select.from)
	for &join in select.joins do res_ref(walk, &scope, &join.table)
	if walk.err.kind != .None do return false
	aliases := make([dynamic]string, 0, len(select.projections), context.temp_allocator)
	for item in select.projections do if len(item.alias) > 0 do append(&aliases, item.alias)
	scope.aliases = aliases[:]
	append(&walk.scopes, scope)
	defer pop(&walk.scopes)

	complete := true
	for item in select.projections {
		qualifier := ""
		is_star := item.star
		if !is_star && item.expr != nil {
			if star, ok := item.expr^.(Star_Expr); ok {
				is_star = true
				qualifier = star.table
			}
		}
		if !is_star {
			res_expr(walk, item.expr)
			if names != nil do append(names, res_item_name(item))
			continue
		}
		for source in scope.sources {
			if len(qualifier) > 0 && !res_source_named(source, qualifier) do continue
			if !source.known {
				complete = false
				continue
			}
			if names != nil do for column in source.columns do append(names, column)
		}
	}
	for join in select.joins do res_expr(walk, join.on)
	// A name in WHERE that no source has may be an alias of the select list:
	// the reference becomes the projection's expression, as SQLite reads it.
	saved_projections, saved_scope := walk.where_projections, walk.where_scope
	walk.where_projections, walk.where_scope = select.projections, len(walk.scopes) - 1
	res_expr(walk, select.where_clause)
	walk.where_projections, walk.where_scope = saved_projections, saved_scope
	for expr in select.group_by do res_expr(walk, expr)
	res_expr(walk, select.having)
	// A compound's ORDER BY names the result columns of its first term, which
	// is resolved elsewhere: its terms are checked, its ordering is not.
	if len(select.compound) == 0 {
		for item in select.order_by do res_expr(walk, item.expr)
	}
	res_expr(walk, select.limit)
	res_expr(walk, select.offset)
	for &part in select.compound do res_select(walk, &part.select_stmt)
	return complete && walk.err.kind == .None
}

@(private)
res_item_name :: proc(item: Select_Item) -> string {
	if len(item.alias) > 0 do return item.alias
	if item.expr != nil {
		if column, ok := item.expr^.(Column_Expr); ok do return column.name
	}
	return item.text
}

@(private)
res_source_named :: proc(source: Res_Source, name: string) -> bool {
	return strings.equal_fold(name, source.name) || (len(source.alias) > 0 && strings.equal_fold(name, source.alias))
}

// res_column decides one column reference, innermost scope first.
@(private)
res_column :: proc(walk: ^Res_Walk, column: Column_Expr) {
	if len(column.table) > 0 {
		// NEW and OLD in a trigger body, excluded in an upsert.
		for special in ([]string{"new", "old", "excluded"}) {
			if strings.equal_fold(column.table, special) do return
		}
		for i := len(walk.scopes) - 1; i >= 0; i -= 1 {
			for source in walk.scopes[i].sources {
				if !res_source_named(source, column.table) do continue
				if !source.known || res_has_column(source, column.name) do return
				res_no_column(walk, column)
				return
			}
		}
		// The qualifier names nothing in reach: a relation the pass could not
		// list may still answer to it.
		if res_any_unknown(walk) do return
		res_no_column(walk, column)
		return
	}
	for i := len(walk.scopes) - 1; i >= 0; i -= 1 {
		scope := walk.scopes[i]
		for source in scope.sources {
			if !source.known || res_has_column(source, column.name) do return
		}
		for alias in scope.aliases do if strings.equal_fold(alias, column.name) do return
	}
	res_no_column(walk, column)
}

// res_where_alias replaces a WHERE's reference to a select-list alias with
// the expression it names, when no source of the query has the name.
@(private)
res_where_alias :: proc(walk: ^Res_Walk, expr: ^Expr, column: Column_Expr) -> bool {
	if walk.where_projections == nil || len(column.table) > 0 do return false
	if walk.where_scope != len(walk.scopes) - 1 do return false
	scope := walk.scopes[walk.where_scope]
	for source in scope.sources {
		if !source.known || res_has_column(source, column.name) do return false
	}
	for item in walk.where_projections {
		if len(item.alias) == 0 || !strings.equal_fold(item.alias, column.name) || item.expr == nil do continue
		if expr_is_aggregate(item.expr) {
			if walk.err.kind == .None {
				name := column.name
				if call, is_call := item.expr^.(Call_Expr); is_call do name = call.name
				walk.err = errf(.Invalid_Argument, "misuse of aggregate: %s()", name)
			}
			return true
		}
		expr^ = item.expr^
		res_expr(walk, expr)
		return true
	}
	return false
}

@(private)
res_any_unknown :: proc(walk: ^Res_Walk) -> bool {
	for scope in walk.scopes {
		for source in scope.sources do if !source.known do return true
	}
	return false
}

@(private)
res_expr :: proc(walk: ^Res_Walk, expr: ^Expr) {
	// A chain of binary operators (`a OR b OR c ...`, a long `||`) is built
	// left-deep without the parser nesting, so it can be thousands deep: the
	// left side is walked in a loop, not by recursion.
	expr := expr
	for expr != nil && walk.err.kind == .None {
		binary, is_binary := expr^.(Binary_Expr)
		if !is_binary do break
		res_expr(walk, binary.right)
		expr = binary.left
	}
	if expr == nil || walk.err.kind != .None do return
	switch e in expr^ {
	case Literal_Expr, Param_Expr, Star_Expr:
	case Column_Expr:
		if res_where_alias(walk, expr, e) do return
		res_column(walk, e)
	case Binary_Expr:
		res_expr(walk, e.left)
		res_expr(walk, e.right)
	case Unary_Expr:
		res_expr(walk, e.operand)
	case Is_Null_Expr:
		res_expr(walk, e.operand)
	case Between_Expr:
		res_expr(walk, e.operand)
		res_expr(walk, e.low)
		res_expr(walk, e.high)
	case In_Expr:
		res_expr(walk, e.operand)
		for item in e.items do res_expr(walk, item)
		if e.subquery != nil do res_select(walk, e.subquery)
	case Call_Expr:
		if limit := walk.tx.store.function_arg_limit; limit > 0 && len(e.args) > limit && walk.err.kind == .None {
			walk.err = errf(.Invalid_Argument, "too many arguments on function %s", e.name)
		}
		for arg in e.args do res_expr(walk, arg)
		res_expr(walk, e.filter)
		for item in e.order_by do res_expr(walk, item.expr)
	case Window_Expr:
		for arg in e.args do res_expr(walk, arg)
		res_expr(walk, e.filter)
		for part in e.partition do res_expr(walk, part)
		for item in e.order_by do res_expr(walk, item.expr)
	case Like_Expr:
		res_expr(walk, e.operand)
		res_expr(walk, e.pattern)
	case Match_Expr:
		res_expr(walk, e.operand)
		res_expr(walk, e.pattern)
	case Cast_Expr:
		res_expr(walk, e.operand)
	case Collate_Expr:
		res_expr(walk, e.operand)
		// A collation nobody knows is refused at prepare, as in SQLite; a
		// program may register it then (collation_needed).
		if len(e.name) > 0 && !collation_is_builtin(e.name) {
			if _, found := store_collation(walk.tx.store, e.name); !found && walk.err.kind == .None {
				if walk.tx.store != nil && walk.tx.store.sqlite_names {
					walk.err = errf(.Invalid_Argument, "no such collation sequence: %s", e.name)
				} else {
					walk.err = errf(.Invalid_Argument, "no such collation: %s", e.name)
				}
			}
		}
	case Subquery_Expr:
		if e.select != nil do res_select(walk, e.select)
	case Case_Expr:
		res_expr(walk, e.operand)
		for branch in e.branches {
			res_expr(walk, branch.condition)
			res_expr(walk, branch.result)
		}
		res_expr(walk, e.fallback)
	}
}

// --- DDL -------------------------------------------------------------------
//
// SQLite refuses at prepare a CREATE of a name that exists, a DROP of one
// that does not or of the wrong kind, and an index or trigger on a table that
// is not there. These are the same checks, in SQLite's words.

@(private)
res_fail :: proc(walk: ^Res_Walk, kind: Error_Kind, format: string, args: ..any) {
	if walk.err.kind != .None do return
	walk.err = errf(kind, format, ..args)
}

// res_relation_kind says what a name is: a table (any kind of it), a view, or
// nothing.
@(private)
res_relation_kind :: proc(walk: ^Res_Walk, name: string) -> string {
	if tx_table_probe(walk.tx, name) != nil do return "table"
	if _, is_view := view_sql(walk.tx, name); is_view do return "view"
	if _, is_virtual := fts_virtual_lookup(walk.tx, name); is_virtual do return "table"
	if _, is_vtab, _ := vtab_find(walk.tx, name); is_vtab do return "table"
	return ""
}

// res_index_exists answers whether the transaction sees index `name`: one in
// the catalog that it did not drop, or one it created itself.
@(private)
res_index_exists :: proc(walk: ^Res_Walk, name: string) -> bool {
	found := false
	for _, table in walk.tx.store.tables {
		for index in table.schema.indexes do if strings.equal_fold(index.name, name) do found = true
	}
	for op in walk.tx.state.index_ops {
		if strings.equal_fold(op.index.name, name) do found = !op.drop
	}
	return found
}

@(private)
res_ddl :: proc(walk: ^Res_Walk, statement: ^Statement) {
	#partial switch &s in statement^ {
	case Create_Table_Stmt:
		if !s.if_not_exists {
			if kind := res_relation_kind(walk, s.name); len(kind) > 0 {
				res_fail(walk, .Table_Exists, "%s %s already exists", kind, s.name)
				return
			}
		}
		for column, i in s.columns {
			for other in s.columns[:i] {
				if strings.equal_fold(other.name, column.name) {
					res_fail(walk, .Invalid_Argument, "duplicate column name: %s", column.name)
					return
				}
			}
			if len(column.collation) > 0 && !collation_is_builtin(column.collation) {
				if _, found := store_collation(walk.tx.store, column.collation); !found {
					res_fail(walk, .Invalid_Argument, "no such collation sequence: %s", column.collation)
					return
				}
			}
			if s.strict {
				if _, known := sqlite_strict_type(column.declared); !known {
					res_fail(walk, .Invalid_Argument, "unknown datatype for %s.%s: \"%s\"", s.name, column.name, column.declared)
					return
				}
			}
		}
		if s.without_rowid {
			has_key := false
			for column in s.columns do if column.primary do has_key = true
			for constraint in s.constraints do if constraint.primary do has_key = true
			if !has_key do res_fail(walk, .Invalid_Argument, "PRIMARY KEY missing on table %s", s.name)
		}
	case Create_View_Stmt:
		if s.if_not_exists || s.or_replace do return
		if kind := res_relation_kind(walk, s.name); len(kind) > 0 {
			res_fail(walk, .Table_Exists, "%s %s already exists", kind, s.name)
		}
	case Create_Index_Stmt:
		if !s.if_not_exists && res_index_exists(walk, s.name) {
			res_fail(walk, .Table_Exists, "index %s already exists", s.name)
			return
		}
		table := tx_table_probe(walk.tx, s.table)
		if table == nil {
			res_fail(walk, .Table_Not_Found, "no such table: main.%s", s.table)
			return
		}
		for column in s.columns {
			// An expression term has no column name.
			if len(column) == 0 do continue
			if _, found := schema_column_index(&table.schema, column); !found {
				res_fail(walk, .Column_Not_Found, "no such column: %s", column)
				return
			}
		}
	case Drop_Table_Stmt:
		kind := res_relation_kind(walk, s.name)
		if kind == "view" {
			res_fail(walk, .Invalid_Argument, "use DROP VIEW to delete view %s", s.name)
		} else if len(kind) == 0 && !s.if_exists && !res_internal(s.name) {
			res_fail(walk, .Table_Not_Found, "no such table: %s", s.name)
		}
	case Drop_View_Stmt:
		kind := res_relation_kind(walk, s.name)
		if kind == "table" {
			res_fail(walk, .Invalid_Argument, "use DROP TABLE to delete table %s", s.name)
		} else if len(kind) == 0 && !s.if_exists {
			res_fail(walk, .Table_Not_Found, "no such view: %s", s.name)
		}
	case Drop_Index_Stmt:
		if !s.if_exists && !res_index_exists(walk, s.name) {
			res_fail(walk, .Index_Not_Found, "no such index: %s", s.name)
		}
	case Create_Trigger_Stmt:
		if kind := res_relation_kind(walk, s.table); kind != "table" && kind != "view" {
			res_fail(walk, .Table_Not_Found, "no such table: main.%s", s.table)
		}
	case Alter_Table_Stmt:
		table := tx_table_probe(walk.tx, s.table)
		if table == nil && res_relation_kind(walk, s.table) == "table" do return
		if table == nil {
			res_fail(walk, .Table_Not_Found, "no such table: %s", s.table)
			return
		}
		if len(s.column.name) > 0 && len(s.rename_to) == 0 && len(s.drop_column) == 0 && len(s.alter_column) == 0 {
			if _, found := schema_column_index(&table.schema, s.column.name); found {
				res_fail(walk, .Invalid_Argument, "duplicate column name: %s", s.column.name)
			}
		}
	}
}

// relation_columns are the column names one FROM or JOIN entry has, as the
// name pass sees them; false when they cannot be listed.
relation_columns :: proc(tx: ^Tx, ref: ^Table_Ref) -> ([]string, bool) {
	walk := Res_Walk{tx = tx}
	walk.scopes = make([dynamic]Res_Scope, 0, 2, context.temp_allocator)
	walk.ctes = make([dynamic]Res_Cte, 0, 1, context.temp_allocator)
	scope := Res_Scope{sources = make([dynamic]Res_Source, 0, 1, context.temp_allocator)}
	res_ref(&walk, &scope, ref)
	if walk.err.kind != .None || len(scope.sources) == 0 || !scope.sources[0].known do return nil, false
	source := scope.sources[0]
	// A table's own name, the row id and hidden columns are not columns a
	// natural join compares.
	if tx_table := tx_table_probe(tx, ref.name); tx_table != nil && ref.subquery == nil {
		names := make([dynamic]string, 0, len(tx_table.schema.columns), context.temp_allocator)
		for column in tx_table.schema.columns do if !column.hidden do append(&names, column.name)
		return names[:], true
	}
	return source.columns, true
}
