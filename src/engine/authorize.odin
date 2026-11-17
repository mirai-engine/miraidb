package engine

import "core:mem"
import "core:mem/virtual"
import "core:strings"

// --- The authorizer ---------------------------------------------------------
//
// sqlite3_set_authorizer lets a program decide, while a statement is prepared,
// whether each thing it is about to do is allowed: read this column, insert
// into that table, call this function, create an index. The engine walks the
// parsed statement once and asks the store's authorizer about each action, with
// the arguments SQLite passes for it. An answer of Deny fails the prepare. An
// answer of Ignore turns a column read into NULL, an assigned column of an
// UPDATE into no assignment, and any other refused action into a statement
// that does nothing.
//
// The order of the questions is not SQLite's (SQLite asks as its compiler
// meets things); which questions are asked, with which arguments, is.

// Auth_Action holds SQLite's action codes, so the facade passes them through.
Auth_Action :: enum i32 {
	Create_Index      = 1,
	Create_Table      = 2,
	Create_Temp_Table = 4,
	Create_Trigger    = 7,
	Create_View       = 8,
	Delete            = 9,
	Drop_Index        = 10,
	Drop_Table        = 11,
	Drop_Trigger      = 16,
	Drop_View         = 17,
	Insert            = 18,
	Pragma            = 19,
	Read              = 20,
	Select            = 21,
	Transaction       = 22,
	Update            = 23,
	Attach            = 24,
	Detach            = 25,
	Alter_Table       = 26,
	Reindex           = 27,
	Analyze           = 28,
	Function          = 31,
	Savepoint         = 32,
}

Auth_Answer :: enum u8 {
	Allow,
	Deny,
	Ignore,
}

// Auth_Request is one question: the action and SQLite's four text arguments,
// each of which may be absent (NULL in C).
Auth_Request :: struct {
	action:   Auth_Action,
	arg1:     Maybe(string),
	arg2:     Maybe(string),
	database: Maybe(string),
	inner:    Maybe(string),
}

Authorizer :: #type proc(ctx: rawptr, request: Auth_Request) -> Auth_Answer

// Auth_Walk is the state of one pass: the transaction the catalog is read in,
// the scopes of the queries the walk is inside, and what it decided.
@(private)
Auth_Walk :: struct {
	store:   ^Store,
	tx:      ^Tx,
	scopes:  [dynamic]Auth_Scope,
	err:     Error,
	ignored: bool,
	// alloc is the query's arena: what the walk rewrites lives as long as the
	// prepared statement.
	alloc:   mem.Allocator,
}

// Auth_Scope is one query's sources: the tables its FROM and JOINs name, and
// for each whether a column of it was read, since a table nothing is read from
// still gets one READ with an empty column.
@(private)
Auth_Scope :: struct {
	sources: [dynamic]Auth_Source,
}

@(private)
Auth_Source :: struct {
	table: ^Table,
	alias: string,
	read:  bool,
}

// sql_authorize asks the store's authorizer about every action of `prepared`.
// It returns the error of a denial, and whether an Ignore made the whole
// statement a no-op; column reads it ignores are rewritten to NULL in place.
sql_authorize :: proc(store: ^Store, tx: ^Tx, prepared: ^Stmt_Prepared) -> (ignored: bool, err: Error) {
	if store.hooks.authorizer == nil do return false, ERROR_NONE
	// The query was copied into the prepared statement, so its own `alloc` still
	// points at the arena where the parser left it: the allocator is made again
	// from the arena where it lives now.
	walk := Auth_Walk{store = store, tx = tx, alloc = virtual.arena_allocator(&prepared.query.arena)}
	walk.scopes = make([dynamic]Auth_Scope, 0, 4, context.temp_allocator)
	if prepared.is_pragma {
		auth_pragma(&walk, prepared.pragma_body)
	} else {
		auth_statement(&walk, &prepared.query.statement)
	}
	return walk.ignored, walk.err
}

// auth_ask asks one question. It answers whether the action may go on: false
// after a Deny (the walk stops) or an Ignore.
@(private)
auth_ask :: proc(walk: ^Auth_Walk, request: Auth_Request) -> Auth_Answer {
	if walk.err.kind != .None do return .Deny
	hooks := &walk.store.hooks
	answer := hooks.authorizer(hooks.authorizer_ctx, request)
	if answer == .Deny {
		if request.action == .Read {
			table, _ := request.arg1.?
			column, _ := request.arg2.?
			walk.err = errf(.Permission_Denied, "access to %s.%s is prohibited", table, column)
		} else if request.action == .Function {
			// SQLite reports a refused function as a plain error, in these words.
			name, _ := request.arg2.?
			walk.err = errf(.Sql_Unsupported, "not authorized to use function: %s", name)
		} else {
			walk.err = errf(.Permission_Denied, "not authorized")
		}
	}
	return answer
}

// auth_action asks about a statement-level action: an Ignore makes the whole
// statement do nothing.
@(private)
auth_action :: proc(walk: ^Auth_Walk, request: Auth_Request) {
	if auth_ask(walk, request) == .Ignore do walk.ignored = true
}

@(private)
auth_statement :: proc(walk: ^Auth_Walk, statement: ^Statement) {
	MAIN :: "main"
	#partial switch &s in statement^ {
	case Select_Stmt:
		auth_select(walk, &s)
	case With_Stmt:
		for &cte in s.ctes do auth_select(walk, &cte.select_stmt)
		auth_select(walk, &s.select_stmt, s.ctes)
	case Explain_Stmt:
		if s.inner != nil do auth_statement(walk, s.inner)
	case Insert_Stmt:
		auth_action(walk, {action = .Insert, arg1 = s.table, database = MAIN})
		for row in s.rows do for &expr in row do auth_expr(walk, &expr)
		if s.has_select do auth_select(walk, &s.select_stmt)
	case Update_Stmt:
		table := tx_table_probe(walk.tx, s.table)
		auth_push(walk, table, "")
		defer auth_pop(walk)
		kept := make([dynamic]Assignment, 0, len(s.assignments), walk.alloc)
		for &assignment in s.assignments {
			answer := auth_ask(walk, {action = .Update, arg1 = s.table, arg2 = assignment.column, database = MAIN})
			auth_expr(walk, &assignment.value)
			// An ignored column keeps its value: the assignment goes.
			if answer != .Ignore do append(&kept, assignment)
		}
		if len(kept) == 0 && len(s.assignments) > 0 {
			walk.ignored = true
		} else {
			s.assignments = kept[:]
		}
		auth_expr(walk, &s.where_clause)
		// The table being written is not a table this statement reads.
		if len(walk.scopes[len(walk.scopes) - 1].sources) > 0 do walk.scopes[len(walk.scopes) - 1].sources[0].read = true
	case Delete_Stmt:
		// An Ignore on a DELETE lets it run, as in SQLite, where it only turns off
		// the truncate optimization.
		_ = auth_ask(walk, {action = .Delete, arg1 = s.table, database = MAIN})
		table := tx_table_probe(walk.tx, s.table)
		auth_push(walk, table, "")
		defer auth_pop(walk)
		auth_expr(walk, &s.where_clause)
		if len(walk.scopes[len(walk.scopes) - 1].sources) > 0 do walk.scopes[len(walk.scopes) - 1].sources[0].read = true
	case Create_Table_Stmt:
		if s.ephemeral {
			auth_action(walk, {action = .Create_Temp_Table, arg1 = s.name, database = "temp"})
		} else {
			auth_action(walk, {action = .Create_Table, arg1 = s.name, database = MAIN})
		}
	case Create_Index_Stmt:
		auth_action(walk, {action = .Create_Index, arg1 = s.name, arg2 = s.table, database = MAIN})
		for column in s.columns {
			auth_ask(walk, {action = .Read, arg1 = s.table, arg2 = column, database = MAIN})
		}
		auth_action(walk, {action = .Reindex, arg1 = s.name, database = MAIN})
	case Drop_Index_Stmt:
		auth_action(walk, {action = .Drop_Index, arg1 = s.name, arg2 = auth_index_table(walk, s.name, s.table), database = MAIN})
	case Create_View_Stmt:
		auth_action(walk, {action = .Create_View, arg1 = s.name, database = MAIN})
	case Drop_View_Stmt:
		auth_action(walk, {action = .Drop_View, arg1 = s.name, database = MAIN})
		auth_action(walk, {action = .Delete, arg1 = s.name, database = MAIN})
	case Drop_Table_Stmt:
		auth_action(walk, {action = .Drop_Table, arg1 = s.name, database = MAIN})
		auth_action(walk, {action = .Delete, arg1 = s.name, database = MAIN})
	case Create_Trigger_Stmt:
		auth_action(walk, {action = .Create_Trigger, arg1 = s.name, arg2 = s.table, database = MAIN})
	case Drop_Trigger_Stmt:
		auth_action(walk, {action = .Drop_Trigger, arg1 = s.name, database = MAIN})
	case Alter_Table_Stmt:
		auth_action(walk, {action = .Alter_Table, arg1 = MAIN, arg2 = s.table})
	case Begin_Stmt:
		auth_action(walk, {action = .Transaction, arg1 = "BEGIN"})
	case Commit_Stmt:
		auth_action(walk, {action = .Transaction, arg1 = "COMMIT"})
	case Rollback_Stmt:
		auth_action(walk, {action = .Transaction, arg1 = "ROLLBACK"})
	case Savepoint_Stmt:
		operation := "BEGIN"
		if s.kind == .Release do operation = "RELEASE"
		if s.kind == .Rollback_To do operation = "ROLLBACK"
		auth_action(walk, {action = .Savepoint, arg1 = operation, arg2 = s.name})
	case Analyze_Stmt:
		if len(s.table) > 0 {
			auth_action(walk, {action = .Analyze, arg1 = s.table, database = MAIN})
		} else {
			for name, _ in walk.store.tables {
				if catalog_table_name(name) do continue
				auth_action(walk, {action = .Analyze, arg1 = name, database = MAIN})
			}
		}
	case Reindex_Stmt:
		if len(s.name) > 0 do auth_action(walk, {action = .Reindex, arg1 = s.name, database = MAIN})
	case Attach_Stmt:
		auth_action(walk, {action = .Attach, arg1 = s.path})
	case Detach_Stmt:
		auth_action(walk, {action = .Detach, arg1 = s.name})
	}
}

// auth_index_table is the table an index belongs to, which DROP INDEX does
// not name.
@(private)
auth_index_table :: proc(walk: ^Auth_Walk, index: string, named: string) -> Maybe(string) {
	if len(named) > 0 do return named
	for name, table in walk.store.tables {
		for candidate in table.schema.indexes {
			if strings.equal_fold(candidate.name, index) do return name
		}
	}
	return nil
}

// auth_pragma asks about `PRAGMA name`, `PRAGMA name = value` and
// `PRAGMA name(value)`, with the value as written.
@(private)
auth_pragma :: proc(walk: ^Auth_Walk, body: string) {
	text := strings.trim_space(body)
	text = strings.trim_right(text, ";")
	name := text
	value: Maybe(string)
	if at := strings.index_any(text, "=("); at >= 0 {
		name = strings.trim_space(text[:at])
		rest := strings.trim_space(text[at + 1:])
		rest = strings.trim_right(rest, ")")
		value = strings.trim_space(rest)
	}
	if dot := strings.index_byte(name, '.'); dot >= 0 do name = name[dot + 1:]
	auth_action(walk, {action = .Pragma, arg1 = name, arg2 = value})
}

@(private)
auth_push :: proc(walk: ^Auth_Walk, table: ^Table, alias: string) {
	scope := Auth_Scope{sources = make([dynamic]Auth_Source, 0, 2, context.temp_allocator)}
	if table != nil do append(&scope.sources, Auth_Source{table = table, alias = alias})
	append(&walk.scopes, scope)
}

// auth_pop closes a scope; a table of it nothing was read from gets its READ
// with an empty column and no database, as SQLite asks.
@(private)
auth_pop :: proc(walk: ^Auth_Walk) {
	scope := pop(&walk.scopes)
	for source in scope.sources {
		if source.read do continue
		auth_ask(walk, {action = .Read, arg1 = source.table.schema.name, arg2 = ""})
	}
}

@(private)
auth_select :: proc(walk: ^Auth_Walk, select: ^Select_Stmt, ctes: []Cte = nil) {
	if walk.err.kind != .None do return
	auth_action(walk, {action = .Select})
	scope := Auth_Scope{sources = make([dynamic]Auth_Source, 0, 2, context.temp_allocator)}
	refs := make([dynamic]^Table_Ref, 0, 1 + len(select.joins), context.temp_allocator)
	if len(select.from.name) > 0 || select.from.subquery != nil do append(&refs, &select.from)
	for &join in select.joins do append(&refs, &join.table)
	for ref in refs {
		// A derived table is a query of its own; a CTE, a view or a table
		// function is not a table whose columns this query reads.
		if ref.subquery != nil {
			auth_select(walk, ref.subquery)
			continue
		}
		is_cte := false
		for cte in ctes do if strings.equal_fold(cte.name, ref.name) do is_cte = true
		if is_cte || len(ref.args) > 0 do continue
		if table := tx_table_probe(walk.tx, ref.name); table != nil {
			append(&scope.sources, Auth_Source{table = table, alias = ref.alias})
		}
	}
	append(&walk.scopes, scope)
	defer auth_pop(walk)
	for &item in select.projections {
		if item.star {
			auth_star(walk, "")
			continue
		}
		if item.expr != nil {
			if star, is_star := item.expr^.(Star_Expr); is_star {
				auth_star(walk, star.table)
				continue
			}
		}
		auth_expr(walk, &item.expr)
	}
	for &join in select.joins do auth_expr(walk, &join.on)
	auth_expr(walk, &select.where_clause)
	for &expr in select.group_by do auth_expr(walk, &expr)
	auth_expr(walk, &select.having)
	for &item in select.order_by do auth_expr(walk, &item.expr)
	auth_expr(walk, &select.limit)
	auth_expr(walk, &select.offset)
	for &part in select.compound do auth_select(walk, &part.select_stmt, ctes)
}

// auth_star asks to read every column `*` (or `t.*`) expands to.
@(private)
auth_star :: proc(walk: ^Auth_Walk, qualifier: string) {
	scope := &walk.scopes[len(walk.scopes) - 1]
	for &source in scope.sources {
		if len(qualifier) > 0 && !auth_source_named(source, qualifier) do continue
		source.read = true
		for column in source.table.schema.columns {
			auth_ask(walk, {action = .Read, arg1 = source.table.schema.name, arg2 = column.name, database = "main"})
		}
	}
}

@(private)
auth_source_named :: proc(source: Auth_Source, name: string) -> bool {
	return strings.equal_fold(name, source.table.schema.name) ||
		(len(source.alias) > 0 && strings.equal_fold(name, source.alias))
}

// auth_column resolves a column reference through the scopes, innermost
// first, and asks to read it. An Ignore rewrites the reference to NULL.
@(private)
auth_column :: proc(walk: ^Auth_Walk, expr: ^^Expr, column: Column_Expr) {
	for i := len(walk.scopes) - 1; i >= 0; i -= 1 {
		for &source in walk.scopes[i].sources {
			if len(column.table) > 0 && !auth_source_named(source, column.table) do continue
			name := column.name
			index, exists := schema_column_index(&source.table.schema, name)
			rowid := false
			if !exists && rowid_alias_name(name) {
				// rowid names the INTEGER PRIMARY KEY when the table has one, and
				// reading it reads no other column.
				schema := &source.table.schema
				if len(schema.primary_key) != 1 do continue
				index = schema.primary_key[0]
				rowid = true
			} else if !exists {
				continue
			}
			if !rowid do source.read = true
			answer := auth_ask(walk, {
				action   = .Read,
				arg1     = source.table.schema.name,
				arg2     = source.table.schema.columns[index].name,
				database = "main",
			})
			if answer == .Ignore {
				replacement := new(Expr, walk.alloc)
				replacement^ = Literal_Expr{value = value_null()}
				expr^ = replacement
			}
			return
		}
	}
}

@(private)
auth_function :: proc(walk: ^Auth_Walk, name: string) {
	lowered := strings.to_lower(name, context.temp_allocator)
	auth_action(walk, {action = .Function, arg2 = lowered})
}

// auth_expr walks one expression: its columns, its functions, and the queries
// nested in it.
@(private)
auth_expr :: proc(walk: ^Auth_Walk, slot: ^^Expr) {
	expr := slot^
	if expr == nil || walk.err.kind != .None do return
	switch &e in expr^ {
	case Literal_Expr, Param_Expr, Star_Expr:
	case Column_Expr:
		auth_column(walk, slot, e)
	case Binary_Expr:
		auth_expr(walk, &e.left)
		auth_expr(walk, &e.right)
	case Unary_Expr:
		auth_expr(walk, &e.operand)
	case Is_Null_Expr:
		auth_expr(walk, &e.operand)
	case Between_Expr:
		auth_expr(walk, &e.operand)
		auth_expr(walk, &e.low)
		auth_expr(walk, &e.high)
	case In_Expr:
		auth_expr(walk, &e.operand)
		for &item in e.items do auth_expr(walk, &item)
		if e.subquery != nil do auth_select(walk, e.subquery)
	case Call_Expr:
		auth_function(walk, e.name)
		for &arg in e.args do auth_expr(walk, &arg)
	case Window_Expr:
		auth_function(walk, e.name)
		for &arg in e.args do auth_expr(walk, &arg)
		for &part in e.partition do auth_expr(walk, &part)
		for &item in e.order_by do auth_expr(walk, &item.expr)
	case Like_Expr:
		auth_function(walk, e.glob ? "glob" : "like")
		auth_expr(walk, &e.operand)
		auth_expr(walk, &e.pattern)
	case Match_Expr:
		auth_expr(walk, &e.operand)
		auth_expr(walk, &e.pattern)
	case Cast_Expr:
		auth_expr(walk, &e.operand)
	case Collate_Expr:
		auth_expr(walk, &e.operand)
	case Subquery_Expr:
		if e.select != nil do auth_select(walk, e.select)
	case Case_Expr:
		auth_expr(walk, &e.operand)
		for &branch in e.branches {
			auth_expr(walk, &branch.condition)
			auth_expr(walk, &branch.result)
		}
		auth_expr(walk, &e.fallback)
	}
}
