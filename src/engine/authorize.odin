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
	// ctes are the common table expressions in scope, innermost last.
	ctes:    [dynamic]Auth_Cte,
	err:     Error,
	ignored: bool,
	// inner is the trigger or view whose body the walk is in: SQLite's sixth
	// argument, absent at the statement's own level.
	inner:   Maybe(string),
	depth:   int,
	// ignores counts the Ignore answers, so a view can tell one was given
	// inside it.
	ignores:  int,
	prepared: ^Stmt_Prepared,
	// trigger is the trigger whose body the walk is in, and top the one the
	// walk started in: nil for a statement, the trigger itself when a firing
	// trigger's statement is replayed (auth_replay_statement).
	trigger:  Maybe(string),
	top:      Maybe(string),
	// replay holds the answers to give instead of asking: a replaying walk
	// never calls the authorizer.
	replay:   []Auth_Key,
	replaying: bool,
	// alloc is the query's arena: what the walk rewrites lives as long as the
	// prepared statement.
	alloc:   mem.Allocator,
}

// Auth_Scope is one query's sources: what its FROM and JOINs name.
@(private)
Auth_Scope :: struct {
	sources: [dynamic]Auth_Source,
}

// Auth_Source is one relation a query reads: a table or a view, whose columns
// are asked about, or a derived table or CTE, whose columns are not (`silent`).
// A table nothing is read from still gets one READ with an empty column. NEW
// and OLD in a trigger body are sources only a qualified name reaches.
@(private)
Auth_Source :: struct {
	name:      string,
	alias:     string,
	columns:   []string,
	// rowid is the column `rowid` names (the INTEGER PRIMARY KEY), or -1.
	rowid:     int,
	// merged are the columns `JOIN ... USING` merges: `*` lists them once.
	merged:    []string,
	read:      bool,
	silent:    bool,
	qualified: bool,
	// known is false for a relation whose columns the walk cannot list (a table
	// function, an attached table): `*` over it cannot be expanded.
	known:     bool,
}

@(private)
Auth_Cte :: struct {
	name:    string,
	columns: []string,
	known:   bool,
	// body is walked when a query first reads the CTE, as SQLite codes it
	// where it is used, with the CTE's name as the sixth argument.
	body:    ^Select_Stmt,
	walked:  bool,
}

// sql_authorize asks the store's authorizer about every action of `prepared`.
// It returns the error of a denial, and whether an Ignore made the whole
// statement a no-op; column reads it ignores are rewritten to NULL in place.
sql_authorize :: proc(store: ^Store, tx: ^Tx, prepared: ^Stmt_Prepared) -> (ignored: bool, err: Error) {
	if store.hooks.authorizer == nil do return false, ERROR_NONE
	// The query was copied into the prepared statement, so its own `alloc` still
	// points at the arena where the parser left it: the allocator is made again
	// from the arena where it lives now.
	walk := Auth_Walk{store = store, tx = tx, prepared = prepared, alloc = virtual.arena_allocator(&prepared.query.arena)}
	walk.scopes = make([dynamic]Auth_Scope, 0, 4, context.temp_allocator)
	walk.ctes = make([dynamic]Auth_Cte, 0, 2, context.temp_allocator)
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
	request := request
	if request.inner == nil do request.inner = walk.inner
	hooks := &walk.store.hooks
	if walk.replaying {
		trigger, _ := walk.trigger.?
		if auth_key_find(walk.replay, trigger, request) {
			walk.ignores += 1
			return .Ignore
		}
		return .Allow
	}
	answer := hooks.authorizer(hooks.authorizer_ctx, request)
	if answer == .Ignore {
		walk.ignores += 1
		// A trigger body runs from its text when it fires: the answer is kept
		// with the statement and given again then.
		if trigger, in_trigger := walk.trigger.?; in_trigger {
			append(&walk.prepared.trigger_ignores, auth_key_make(trigger, request, walk.alloc))
		}
	}
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
// statement do nothing. Inside a trigger body it only answers, since the
// statement being prepared is not the trigger's.
@(private)
auth_action :: proc(walk: ^Auth_Walk, request: Auth_Request) {
	if auth_ask(walk, request) == .Ignore && auth_at_top(walk) do walk.ignored = true
}

@(private)
auth_statement :: proc(walk: ^Auth_Walk, statement: ^Statement) {
	MAIN :: "main"
	#partial switch &s in statement^ {
	case Select_Stmt:
		auth_select(walk, &s)
	case With_Stmt:
		auth_with(walk, &s)
	case Explain_Stmt:
		if s.inner != nil do auth_statement(walk, s.inner)
	case Insert_Stmt:
		base := auth_push_ctes(walk, s.ctes)
		defer resize(&walk.ctes, base)
		auth_action(walk, {action = .Insert, arg1 = s.table, database = MAIN})
		for row in s.rows do for &expr in row do auth_expr(walk, &expr)
		if s.has_select do auth_select(walk, &s.select_stmt)
		auth_triggers(walk, s.table, "insert")
	case Update_Stmt:
		base := auth_push_ctes(walk, s.ctes)
		defer resize(&walk.ctes, base)
		table := tx_table_probe(walk.tx, s.table)
		auth_push_table(walk, table)
		kept := make([dynamic]Assignment, 0, len(s.assignments), walk.alloc)
		for &assignment in s.assignments {
			answer := auth_ask(walk, {action = .Update, arg1 = s.table, arg2 = assignment.column, database = MAIN})
			auth_expr(walk, &assignment.value)
			// An ignored column keeps its value: the assignment goes.
			if answer != .Ignore do append(&kept, assignment)
		}
		if len(kept) == 0 && len(s.assignments) > 0 {
			if auth_at_top(walk) do walk.ignored = true
		} else {
			s.assignments = kept[:]
		}
		auth_expr(walk, &s.where_clause)
		auth_pop_written(walk)
		auth_triggers(walk, s.table, "update")
	case Delete_Stmt:
		// An Ignore on a DELETE lets it run, as in SQLite, where it only turns off
		// the truncate optimization.
		base := auth_push_ctes(walk, s.ctes)
		defer resize(&walk.ctes, base)
		_ = auth_ask(walk, {action = .Delete, arg1 = s.table, database = MAIN})
		table := tx_table_probe(walk.tx, s.table)
		auth_push_table(walk, table)
		auth_expr(walk, &s.where_clause)
		auth_pop_written(walk)
		auth_triggers(walk, s.table, "delete")
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

// auth_with puts the common table expressions in scope and walks the main
// query; a CTE's body is walked where a query reads it (auth_cte). It reports
// the main query's column names, as auth_select does.
@(private)
auth_with :: proc(walk: ^Auth_Walk, with: ^With_Stmt, names: ^[dynamic]string = nil) -> bool {
	base := len(walk.ctes)
	defer resize(&walk.ctes, base)
	auth_push_ctes(walk, with.ctes)
	return auth_select(walk, &with.select_stmt, names)
}

// auth_push_ctes puts CTEs in scope and returns the scope's size before them.
@(private)
auth_push_ctes :: proc(walk: ^Auth_Walk, ctes: []Cte) -> int {
	base := len(walk.ctes)
	for &cte in ctes {
		append(&walk.ctes, Auth_Cte{name = cte.name, columns = cte.columns, known = len(cte.columns) > 0, body = &cte.select_stmt})
	}
	return base
}

// auth_cte walks the body of CTE `index` the first time a query reads it.
@(private)
auth_cte :: proc(walk: ^Auth_Walk, index: int) {
	if walk.ctes[index].walked do return
	walk.ctes[index].walked = true
	saved := walk.inner
	walk.inner = walk.ctes[index].name
	body_names := make([dynamic]string, 0, 4, context.temp_allocator)
	complete := auth_select(walk, walk.ctes[index].body, &body_names)
	walk.inner = saved
	entry := &walk.ctes[index]
	if !entry.known && complete {
		entry.columns = body_names[:]
		entry.known = true
	}
}

// auth_triggers walks the body of every trigger the write to `table` fires,
// with the trigger's name as the sixth argument and NEW and OLD in scope, as
// SQLite does when it compiles them into the statement.
@(private)
auth_triggers :: proc(walk: ^Auth_Walk, table_name: string, event: string) {
	if walk.err.kind != .None || walk.replaying || walk.depth >= TRIGGER_MAX_DEPTH do return
	if len(table_name) > 0 && table_name[0] == '_' do return
	if tx_table_probe(walk.tx, TRIGGER_TABLE) == nil do return
	table := tx_table_probe(walk.tx, table_name)
	if table == nil do return
	rows := make([dynamic]Row, 0, 4, context.temp_allocator)
	if collect_err := tx_collect(walk.tx, TRIGGER_TABLE, &rows); collect_err.kind != .None do return
	for row in rows {
		if len(row.values) < 5 do continue
		name, on, fires, body := row.values[0], row.values[1], row.values[2], row.values[4]
		if name.kind != .String || on.kind != .String || fires.kind != .String || body.kind != .String do continue
		if !strings.equal_fold(on.s, table_name) || fires.s != event do continue
		saved := walk.inner
		saved_trigger := walk.trigger
		walk.inner = name.s
		walk.trigger = name.s
		walk.depth += 1
		scope := Auth_Scope{sources = make([dynamic]Auth_Source, 0, 2, context.temp_allocator)}
		for side in ([]string{"new", "old"}) {
			source := auth_table_source(table, side)
			source.qualified = true
			source.read = true
			append(&scope.sources, source)
		}
		append(&walk.scopes, scope)
		if len(row.values) > 5 && row.values[5].kind == .String && len(row.values[5].s) > 0 {
			condition, condition_expr, condition_err := sql_parse_expression(row.values[5].s)
			if condition_err.kind == .None do auth_expr(walk, &condition_expr)
			query_destroy(&condition)
		}
		for statement in trigger_split(body.s, context.temp_allocator) {
			text := strings.trim_space(statement)
			if len(text) == 0 do continue
			query, parse_err := sql_parse(text)
			if parse_err.kind == .None do auth_statement(walk, &query.statement)
			query_destroy(&query)
		}
		auth_pop(walk)
		walk.depth -= 1
		walk.inner = saved
		walk.trigger = saved_trigger
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

// auth_table_source is a table as a source, its columns named as declared.
@(private)
auth_table_source :: proc(table: ^Table, alias: string) -> Auth_Source {
	schema := &table.schema
	columns := make([]string, len(schema.columns), context.temp_allocator)
	for column, i in schema.columns do columns[i] = column.name
	rowid := -1
	if len(schema.primary_key) == 1 do rowid = schema.primary_key[0]
	return Auth_Source{name = schema.name, alias = alias, columns = columns, rowid = rowid, known = true}
}

// auth_push_table opens the scope of an UPDATE or DELETE: the table it writes.
@(private)
auth_push_table :: proc(walk: ^Auth_Walk, table: ^Table) {
	scope := Auth_Scope{sources = make([dynamic]Auth_Source, 0, 1, context.temp_allocator)}
	if table != nil do append(&scope.sources, auth_table_source(table, ""))
	append(&walk.scopes, scope)
}

// auth_pop_written closes the scope auth_push_table opened. The table being
// written is not a table the statement reads, so it gets no empty READ.
@(private)
auth_pop_written :: proc(walk: ^Auth_Walk) {
	scope := &walk.scopes[len(walk.scopes) - 1]
	for &source in scope.sources do source.read = true
	auth_pop(walk)
}

// auth_pop closes a scope; a table of it nothing was read from gets its READ
// with an empty column and no database, as SQLite asks.
@(private)
auth_pop :: proc(walk: ^Auth_Walk) {
	scope := pop(&walk.scopes)
	for source in scope.sources {
		if source.read || source.silent || !source.known do continue
		auth_ask(walk, {action = .Read, arg1 = source.name, arg2 = ""})
	}
}

// auth_ref adds the source one FROM or JOIN entry names to `scope`.
@(private)
auth_ref :: proc(walk: ^Auth_Walk, scope: ^Auth_Scope, ref: ^Table_Ref, merged: []string) {
	source: Auth_Source
	source.rowid = -1
	defer {
		source.merged = merged
		append(&scope.sources, source)
	}
	// A derived table is a query of its own: its columns are not a table's, so
	// reading them asks nothing.
	if ref.subquery != nil {
		names := make([dynamic]string, 0, 4, context.temp_allocator)
		source.known = auth_select(walk, ref.subquery, &names)
		source.name = ref.alias
		source.columns = names[:]
		source.silent = true
		return
	}
	for i := len(walk.ctes) - 1; i >= 0; i -= 1 {
		if !strings.equal_fold(walk.ctes[i].name, ref.name) do continue
		auth_cte(walk, i)
		cte := walk.ctes[i]
		source.name = cte.name
		source.alias = ref.alias
		source.columns = cte.columns
		source.known = cte.known
		source.silent = true
		return
	}
	for &arg in ref.args do auth_expr(walk, &arg)
	source.name = ref.name
	source.alias = ref.alias
	source.silent = true
	if len(ref.schema) > 0 || is_json_table_function(ref.name) do return
	if table := tx_table_probe(walk.tx, ref.name); table != nil {
		source = auth_table_source(table, ref.alias)
		return
	}
	if sql, found := view_sql(walk.tx, ref.name); found {
		source = auth_view(walk, ref, sql)
		source.alias = ref.alias
	}
}

// auth_view walks a view's query, as SQLite does when a statement reads it,
// with the view's name as the sixth argument. The view is then a source whose
// columns are asked about under its own name. When an answer inside it was
// Ignore, the reference becomes a derived table over the rewritten query, so
// the ignored columns read as NULL there too.
@(private)
auth_view :: proc(walk: ^Auth_Walk, ref: ^Table_Ref, sql: string) -> Auth_Source {
	name := ref.name
	source := Auth_Source{name = name, rowid = -1}
	if walk.depth >= VIEW_MAX_DEPTH do return source
	query := new(Query)
	parse_err: Error
	query^, parse_err = sql_parse(sql)
	kept := false
	defer if !kept {
		query_destroy(query)
		free(query)
	}
	if parse_err.kind != .None do return source
	ignores := walk.ignores
	saved := walk.inner
	walk.inner = name
	walk.depth += 1
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	complete := false
	#partial switch &s in query.statement {
	case Select_Stmt:
		complete = auth_select(walk, &s, &names)
	case With_Stmt:
		complete = auth_with(walk, &s, &names)
	}
	walk.depth -= 1
	walk.inner = saved
	if select, is_select := &query.statement.(Select_Stmt); is_select && walk.prepared != nil && walk.ignores > ignores && len(ref.args) == 0 && walk.err.kind == .None {
		ref.subquery = select
		append(&walk.prepared.views, query)
		kept = true
	}
	// The names live in the view's query, which goes when this returns.
	for &column in names do column = strings.clone(column, context.temp_allocator)
	source.columns = names[:]
	source.known = complete
	// A view nothing is read from gets no empty READ, as in SQLite.
	source.read = true
	return source
}

// auth_select walks one query. It collects the names of its result columns in
// `names` and answers whether that list is complete: false when a `*` covers a
// relation whose columns the walk cannot list.
@(private)
auth_select :: proc(walk: ^Auth_Walk, select: ^Select_Stmt, names: ^[dynamic]string = nil) -> bool {
	if walk.err.kind != .None do return false
	auth_action(walk, {action = .Select})
	scope := Auth_Scope{sources = make([dynamic]Auth_Source, 0, 2, context.temp_allocator)}
	if len(select.from.name) > 0 || select.from.subquery != nil do auth_ref(walk, &scope, &select.from, nil)
	for &join in select.joins do auth_ref(walk, &scope, &join.table, join.using_columns)
	append(&walk.scopes, scope)
	defer auth_pop(walk)

	complete := true
	// rewritten replaces the projections once a `*` has a column the answer
	// ignored: the `*` becomes its columns, that one a NULL under its name.
	rewritten: [dynamic]Select_Item
	is_rewritten := false
	for &item, i in select.projections {
		qualifier := ""
		is_star := item.star
		if !is_star && item.expr != nil {
			if star, ok := item.expr^.(Star_Expr); ok {
				is_star = true
				qualifier = star.table
			}
		}
		if !is_star {
			column: Column_Expr
			is_column := false
			if item.expr != nil do column, is_column = item.expr^.(Column_Expr)
			auth_expr(walk, &item.expr)
			// A column read as NULL keeps the column's name.
			if is_column && len(item.alias) == 0 {
				if _, now_null := item.expr^.(Literal_Expr); now_null do item.alias = column.name
			}
			if is_rewritten do append(&rewritten, item)
			if names != nil do append(names, auth_item_name(item))
			continue
		}
		items, ignored, star_complete := auth_star(walk, qualifier)
		complete = complete && star_complete
		if names != nil do for expanded in items do append(names, expanded.text)
		if ignored && star_complete && !is_rewritten {
			rewritten = make([dynamic]Select_Item, 0, len(select.projections) + len(items), walk.alloc)
			append(&rewritten, ..select.projections[:i])
			is_rewritten = true
		}
		if is_rewritten {
			if star_complete do append(&rewritten, ..items)
			else do append(&rewritten, item)
		}
	}
	if is_rewritten do select.projections = rewritten[:]
	for &join in select.joins do auth_expr(walk, &join.on)
	auth_expr(walk, &select.where_clause)
	for &expr in select.group_by do auth_expr(walk, &expr)
	auth_expr(walk, &select.having)
	for &item in select.order_by do auth_expr(walk, &item.expr)
	auth_expr(walk, &select.limit)
	auth_expr(walk, &select.offset)
	for &part in select.compound do auth_select(walk, &part.select_stmt)
	return complete
}

// auth_item_name is the name a result column gets, as the executor names it.
@(private)
auth_item_name :: proc(item: Select_Item) -> string {
	if len(item.alias) > 0 do return item.alias
	if item.expr != nil {
		if column, ok := item.expr^.(Column_Expr); ok do return column.name
	}
	return item.text
}

// auth_star asks to read every column `*` (or `t.*`) expands to, and returns
// those columns as projections: a column the answer ignores is a NULL under
// the column's name. `ignored` says whether one was; `complete` is false when
// a source's columns are not known, and then the list is not the whole `*`.
@(private)
auth_star :: proc(walk: ^Auth_Walk, qualifier: string) -> (items: []Select_Item, ignored: bool, complete: bool) {
	scope := &walk.scopes[len(walk.scopes) - 1]
	out := make([dynamic]Select_Item, 0, 8, walk.alloc)
	complete = true
	for &source in scope.sources {
		if len(qualifier) > 0 && !auth_source_named(source, qualifier) do continue
		if !source.known {
			complete = false
			continue
		}
		if !source.silent do source.read = true
		reference := len(source.alias) > 0 ? source.alias : source.name
		for column in source.columns {
			answer := Auth_Answer.Allow
			if !source.silent {
				answer = auth_ask(walk, {action = .Read, arg1 = source.name, arg2 = column, database = "main"})
			}
			// `JOIN ... USING (c)` merges c: an unqualified `*` lists it once.
			if len(qualifier) == 0 && column_in_names(column, source.merged) do continue
			expr := new(Expr, walk.alloc)
			item := Select_Item{expr = expr, text = column}
			if answer == .Ignore {
				expr^ = Literal_Expr{value = value_null()}
				item.alias = column
				ignored = true
			} else {
				expr^ = Column_Expr{table = reference, name = column}
			}
			append(&out, item)
		}
	}
	return out[:], ignored, complete
}

@(private)
auth_source_named :: proc(source: Auth_Source, name: string) -> bool {
	if len(source.alias) > 0 && strings.equal_fold(name, source.alias) do return true
	return !source.qualified && strings.equal_fold(name, source.name)
}

// auth_column resolves a column reference through the scopes, innermost
// first, and asks to read it. An Ignore rewrites the reference to NULL.
@(private)
auth_column :: proc(walk: ^Auth_Walk, expr: ^^Expr, column: Column_Expr) {
	for i := len(walk.scopes) - 1; i >= 0; i -= 1 {
		for &source in walk.scopes[i].sources {
			if len(column.table) > 0 {
				if !auth_source_named(source, column.table) do continue
			} else if source.qualified {
				continue
			}
			if !source.known {
				// Its columns are unknown: a qualified name is its, an unqualified
				// one may be anyone's.
				if len(column.table) > 0 do return
				continue
			}
			index := -1
			for candidate, at in source.columns {
				if strings.equal_fold(candidate, column.name) {
					index = at
					break
				}
			}
			rowid := false
			if index < 0 && rowid_alias_name(column.name) {
				// rowid names the INTEGER PRIMARY KEY when the table has one, and
				// reading it reads no other column.
				if source.rowid < 0 do continue
				index = source.rowid
				rowid = true
			} else if index < 0 {
				continue
			}
			if source.silent do return
			if !rowid do source.read = true
			answer := auth_ask(walk, {action = .Read, arg1 = source.name, arg2 = source.columns[index], database = "main"})
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

// --- Trigger bodies -----------------------------------------------------------
//
// SQLite compiles the triggers a statement fires into the statement, so an
// Ignore given about a trigger's body changes what the trigger does each time
// it fires. Here a body runs from its text when it fires, so the Ignore
// answers are kept with the prepared statement (Stmt_Prepared.trigger_ignores)
// and, while it runs, each statement of a trigger they concern is rewritten
// with them before it runs. The authorizer is not asked again.

// Auth_Key is one Ignore answer given inside a trigger's body.
Auth_Key :: struct {
	trigger: string,
	request: Auth_Request,
}

// auth_replay is the Ignore answers of the statement this thread is running.
@(thread_local, private)
auth_replay: []Auth_Key

// auth_replay_begin installs the answers of `prepared` while it runs and
// returns the ones to restore after.
auth_replay_begin :: proc(prepared: ^Stmt_Prepared) -> []Auth_Key {
	saved := auth_replay
	auth_replay = prepared.trigger_ignores[:] if prepared != nil else nil
	return saved
}

auth_replay_end :: proc(saved: []Auth_Key) {
	auth_replay = saved
}

// auth_replay_concerns reports whether trigger `name` has answers to replay.
auth_replay_concerns :: proc(name: string) -> bool {
	for key in auth_replay do if key.trigger == name do return true
	return false
}

// auth_replay_statement runs one statement of trigger `name`'s body rewritten
// with the answers given about it.
auth_replay_statement :: proc(tx: ^Tx, name: string, text: string) -> Error {
	prepared, parse_err := sql_prepare(tx.store, text)
	if parse_err.kind != .None do return parse_err
	defer stmt_prepared_destroy(prepared)
	if prepared.is_pragma {
		_, err := sql_execute_in_tx(tx, text)
		return err
	}
	walk := auth_replay_walk(tx, prepared, name)
	auth_statement(&walk, &prepared.query.statement)
	if walk.ignored do return ERROR_NONE
	result, err := sql_run_statement_in_tx(tx, prepared.query.statement, nil)
	if err.kind == .None do sql_result_destroy(&result)
	return err
}

// auth_replay_condition rewrites a trigger's WHEN condition the same way.
auth_replay_condition :: proc(tx: ^Tx, name: string, condition: ^Query, expr: ^^Expr) {
	// A view the condition reads is not rewritten: nothing would keep its query.
	walk := auth_replay_walk(tx, nil, name)
	walk.alloc = virtual.arena_allocator(&condition.arena)
	auth_expr(&walk, expr)
}

// auth_replay_walk is a walk that answers from the kept Ignore answers, inside
// trigger `name` with NEW and OLD in scope.
@(private)
auth_replay_walk :: proc(tx: ^Tx, prepared: ^Stmt_Prepared, name: string) -> Auth_Walk {
	walk := Auth_Walk {
		store     = tx.store,
		tx        = tx,
		prepared  = prepared,
		inner     = name,
		trigger   = name,
		top       = name,
		replay    = auth_replay,
		replaying = true,
		depth     = 1,
	}
	if prepared != nil do walk.alloc = virtual.arena_allocator(&prepared.query.arena)
	walk.scopes = make([dynamic]Auth_Scope, 0, 4, context.temp_allocator)
	walk.ctes = make([dynamic]Auth_Cte, 0, 2, context.temp_allocator)
	scope := Auth_Scope{sources = make([dynamic]Auth_Source, 0, 2, context.temp_allocator)}
	if table := tx_table_probe(tx, tx.trigger_schema.name); table != nil {
		for side in ([]string{"new", "old"}) {
			source := auth_table_source(table, side)
			source.qualified = true
			source.read = true
			append(&scope.sources, source)
		}
	}
	append(&walk.scopes, scope)
	return walk
}

// auth_at_top reports a walk at the level it started: the statement itself,
// or the trigger statement being replayed, whose own action an Ignore skips.
@(private)
auth_at_top :: proc(walk: ^Auth_Walk) -> bool {
	return auth_maybe_equal(walk.trigger, walk.top)
}

@(private)
auth_maybe_equal :: proc(a, b: Maybe(string)) -> bool {
	x, has_x := a.?
	y, has_y := b.?
	return has_x == has_y && x == y
}

@(private)
auth_key_make :: proc(trigger: string, request: Auth_Request, alloc: mem.Allocator) -> Auth_Key {
	clone :: proc(text: Maybe(string), alloc: mem.Allocator) -> Maybe(string) {
		value, ok := text.?
		if !ok do return nil
		return strings.clone(value, alloc)
	}
	return Auth_Key {
		trigger = strings.clone(trigger, alloc),
		request = Auth_Request {
			action = request.action,
			arg1 = clone(request.arg1, alloc),
			arg2 = clone(request.arg2, alloc),
			database = clone(request.database, alloc),
			inner = clone(request.inner, alloc),
		},
	}
}

@(private)
auth_key_find :: proc(keys: []Auth_Key, trigger: string, request: Auth_Request) -> bool {
	for key in keys {
		if key.trigger != trigger || key.request.action != request.action do continue
		if !auth_maybe_equal(key.request.arg1, request.arg1) || !auth_maybe_equal(key.request.arg2, request.arg2) do continue
		if !auth_maybe_equal(key.request.inner, request.inner) do continue
		return true
	}
	return false
}
