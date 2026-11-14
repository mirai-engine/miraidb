package engine

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:fmt"

Parser :: struct {
	lexer:       Lexer,
	current:     Token,
	alloc:       mem.Allocator,
	query:       ^Query,
	err:         Error,
	param_count: int,
}

// sql_parse turns one SQL statement into a Query tree. The Query owns an arena
// with every node; destroy it with query_destroy.
sql_parse :: proc(source: string) -> (Query, Error) {
	q: Query
	if arena_err := virtual.arena_init_growing(&q.arena); arena_err != .None {
		return q, errf(.Out_Of_Memory, "cannot allocate the query arena")
	}
	q.alloc = virtual.arena_allocator(&q.arena)
	q.source = strings.clone(source, q.alloc)
	p := Parser {
		lexer   = lexer_init(source),
		alloc   = q.alloc,
		query   = &q,
	}
	p.current = lexer_next(&p.lexer)
	statement := parse_statement(&p)
	if p.err.kind != .None {
		virtual.arena_destroy(&q.arena)
		return {}, p.err
	}
	if p.current.kind != .EOF {
		if p.current.text == ";" {
			p.current = lexer_next(&p.lexer)
		}
		if p.current.kind != .EOF {
			virtual.arena_destroy(&q.arena)
			return {}, p_fail(&p, .Sql_Syntax, "unexpected token %q", p.current.text)
		}
	}
	q.statement = statement
	return q, ERROR_NONE
}

// --- Token helpers ---------------------------------------------------------

@(private)
p_fail :: proc(p: ^Parser, kind: Error_Kind, format: string, args: ..any) -> Error {
	if p.err.kind == .None {
		detail := fmt.aprintf(format, ..args)
		p.err = errf(kind, "line %d, column %d: %s", p.current.line, p.current.column, detail)
	}
	return p.err
}

// p_is_clause_keyword reports whether the current token starts the next clause
// of a SELECT, so it cannot be an implicit alias.
@(private)
p_is_clause_keyword :: proc(p: ^Parser) -> bool {
	if p.current.kind != .Ident do return false
	for keyword in ([]string{"from", "where", "group", "order", "limit", "offset", "having", "union", "returning"}) {
		if strings.equal_fold(p.current.text, keyword) do return true
	}
	return false
}

@(private)
p_advance :: proc(p: ^Parser) {
	p.current = lexer_next(&p.lexer)
}

@(private)
p_is_keyword :: proc(p: ^Parser, keyword: string) -> bool {
	return p.current.kind == .Ident && strings.equal_fold(p.current.text, keyword)
}

@(private)
p_match_keyword :: proc(p: ^Parser, keyword: string) -> bool {
	if p_is_keyword(p, keyword) {
		p_advance(p)
		return true
	}
	return false
}

@(private)
p_is_punct :: proc(p: ^Parser, text: string) -> bool {
	return p.current.kind == .Punct && p.current.text == text
}

@(private)
p_match_punct :: proc(p: ^Parser, text: string) -> bool {
	if p_is_punct(p, text) {
		p_advance(p)
		return true
	}
	return false
}

@(private)
p_expect_punct :: proc(p: ^Parser, text: string) -> bool {
	if p_match_punct(p, text) do return true
	p_fail(p, .Sql_Syntax, "expected %q, found %q", text, p.current.text)
	return false
}

@(private)
p_expect_keyword :: proc(p: ^Parser, keyword: string) -> bool {
	if p_match_keyword(p, keyword) do return true
	p_fail(p, .Sql_Syntax, "expected %s, found %q", keyword, p.current.text)
	return false
}

// p_ident accepts a bare or quoted identifier.
@(private)
p_ident :: proc(p: ^Parser) -> string {
	if p.current.kind == .Ident || p.current.kind == .Quoted_Ident {
		name := strings.clone(p.current.text, p.alloc)
		p_advance(p)
		return name
	}
	p_fail(p, .Sql_Syntax, "expected a name, found %q", p.current.text)
	return ""
}

@(private)
p_ident_or_keyword :: proc(p: ^Parser) -> string {
	if p.current.kind != .Ident && p.current.kind != .Quoted_Ident {
		p_fail(p, .Sql_Syntax, "expected a name, found %q", p.current.text)
		return ""
	}
	name := strings.clone(p.current.text, p.alloc)
	p_advance(p)
	return name
}

// --- Statements ------------------------------------------------------------

@(private)
parse_statement :: proc(p: ^Parser) -> Statement {
	if p.current.kind != .Ident {
		p_fail(p, .Sql_Syntax, "expected a statement, found %q", p.current.text)
		return nil
	}
	if p_match_keyword(p, "load") do return parse_load_extension(p, false)
	if p_match_keyword(p, "unload") do return parse_load_extension(p, true)
	if p_is_keyword(p, "explain") {
		p_advance(p)
		inner := new(Statement, p.alloc)
		inner^ = parse_statement(p)
		return Explain_Stmt{inner = inner}
	}
	if p_is_keyword(p, "alter") {
		return parse_alter_table(p)
	}
	if p_is_keyword(p, "set") {
		p_advance(p)
		stmt: Set_Stmt
		stmt.name = p_ident(p)
		p_expect_punct(p, "=")
		stmt.value = parse_expression(p)
		return stmt
	}
	if p_is_keyword(p, "show") {
		p_advance(p)
		stmt: Show_Stmt
		if p.current.kind == .Ident || p.current.kind == .Quoted_Ident {
			stmt.name = p_ident(p)
		}
		return stmt
	}
	if p_match_keyword(p, "vacuum") {
		stmt: Vacuum_Stmt
		if p_match_keyword(p, "into") {
			if p.current.kind != .String {
				p_fail(p, .Sql_Syntax, "VACUUM INTO needs a file path")
				return stmt
			}
			stmt.path = p.current.text
			p_advance(p)
		}
		return stmt
	}
	if p_match_keyword(p, "attach") {
		stmt: Attach_Stmt
		p_match_keyword(p, "database")
		if p.current.kind != .String {
			p_fail(p, .Sql_Syntax, "ATTACH needs a database path")
			return stmt
		}
		stmt.path = p.current.text
		p_advance(p)
		if !p_expect_keyword(p, "as") do return stmt
		stmt.name = p_ident(p)
		return stmt
	}
	if p_match_keyword(p, "detach") {
		stmt: Detach_Stmt
		p_match_keyword(p, "database")
		stmt.name = p_ident(p)
		return stmt
	}
	if p_match_keyword(p, "truncate") {
		stmt: Truncate_Stmt
		p_match_keyword(p, "table")
		stmt.name = p_ident(p)
		return stmt
	}
	if p_match_keyword(p, "analyze") {
		analyze: Analyze_Stmt
		// ANALYZE with no table measures every table, which is what the SQL
		// statement means when the name is left out.
		if p.current.kind == .Ident || p.current.kind == .Quoted_Ident {
			analyze.table = p_ident(p)
		}
		return analyze
	}
	if p_match_keyword(p, "describe") || p_match_keyword(p, "desc") {
		stmt: Describe_Stmt
		stmt.name = p_ident(p)
		return stmt
	}
	if p_is_keyword(p, "select") do return parse_select(p)
	if p_match_keyword(p, "with") {
		with: With_Stmt
		if p_match_keyword(p, "recursive") do with.recursive = true
		ctes := make([dynamic]Cte, 0, 2, p.alloc)
		for {
			cte: Cte
			cte.name = p_ident(p)
			if p_match_punct(p, "(") {
				names := make([dynamic]string, 0, 2, p.alloc)
				for {
					append(&names, p_ident(p))
					if !p_match_punct(p, ",") do break
				}
				p_expect_punct(p, ")")
				cte.columns = names[:]
			}
			p_expect_keyword(p, "as")
			p_expect_punct(p, "(")
			if select_stmt, ok := parse_select(p).(Select_Stmt); ok {
				cte.select_stmt = select_stmt
			}
			p_expect_punct(p, ")")
			append(&ctes, cte)
			if !p_match_punct(p, ",") do break
		}
		with.ctes = ctes[:]
		if select_stmt, ok := parse_select(p).(Select_Stmt); ok {
			with.select_stmt = select_stmt
		}
		return with
	}
	if p_is_keyword(p, "insert") do return parse_insert(p)
	if p_is_keyword(p, "update") do return parse_update(p)
	if p_is_keyword(p, "delete") do return parse_delete(p)
	if p_is_keyword(p, "grant") do return parse_grant(p, false)
	if p_is_keyword(p, "revoke") do return parse_grant(p, true)
	if p_is_keyword(p, "create") do return parse_create(p)
	if p_is_keyword(p, "drop") do return parse_drop(p)
	if p_match_keyword(p, "begin") {
		p_match_keyword(p, "transaction")
		return Begin_Stmt{}
	}
	if p_match_keyword(p, "commit") {
		p_match_keyword(p, "transaction")
		return Commit_Stmt{}
	}
	if p_match_keyword(p, "rollback") {
		p_match_keyword(p, "transaction")
		if p_match_keyword(p, "to") {
			p_match_keyword(p, "savepoint")
			return Savepoint_Stmt{name = p_ident(p), kind = .Rollback_To}
		}
		return Rollback_Stmt{}
	}
	if p_match_keyword(p, "savepoint") {
		return Savepoint_Stmt{name = p_ident(p), kind = .Set}
	}
	if p_match_keyword(p, "release") {
		p_match_keyword(p, "savepoint")
		return Savepoint_Stmt{name = p_ident(p), kind = .Release}
	}
	p_fail(p, .Sql_Syntax, "unknown statement %q", p.current.text)
	return nil
}

@(private)
parse_alter_table :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "alter")
	p_expect_keyword(p, "table")
	stmt: Alter_Table_Stmt
	stmt.table = p_ident(p)
	if p_match_keyword(p, "rename") {
		if p_match_keyword(p, "column") {
			stmt.rename_column = p_ident(p)
			p_expect_keyword(p, "to")
			stmt.rename_to = p_ident(p)
			return stmt
		}
		// `RENAME a TO b` is the same statement without the optional COLUMN.
		if !p_is_keyword(p, "to") {
			stmt.rename_column = p_ident(p)
			p_expect_keyword(p, "to")
			stmt.rename_to = p_ident(p)
			return stmt
		}
		p_expect_keyword(p, "to")
		stmt.rename_to = p_ident(p)
		return stmt
	}
	if p_match_keyword(p, "drop") {
		p_match_keyword(p, "column")
		stmt.drop_column = p_ident(p)
		return stmt
	}
	if p_expect_keyword(p, "add") == false do return stmt
	p_match_keyword(p, "column")
	stmt.column.name = p_ident(p)
	type_name := p_ident_or_keyword(p)
	kind, width, type_ok := type_kind_from_name(type_name)
	if !type_ok {
		p_fail(p, .Sql_Syntax, "unknown column type %q", type_name)
		return stmt
	}
	stmt.column.type = Column_Type{kind = kind, width = width}
	if p_match_keyword(p, "not") {
		p_expect_keyword(p, "null")
		stmt.column.not_null = true
	}
	if p_match_keyword(p, "default") {
		expr := parse_primary(p)
		if literal, is_literal := expr^.(Literal_Expr); is_literal {
			stmt.column.has_default = true
			stmt.column.default_value = literal.value
			if stmt.column.not_null && literal.value.kind == .Null {
				p_fail(p, .Sql_Syntax, "a NOT NULL column cannot default to NULL")
			}
		} else {
			p_fail(p, .Sql_Syntax, "the default of an added column must be a literal")
		}
	}
	return stmt
}

@(private)
parse_scalar_subquery :: proc(p: ^Parser) -> ^Select_Stmt {
	statement := parse_select(p)
	if select, ok := statement.(Select_Stmt); ok {
		out := new(Select_Stmt, p.alloc)
		out^ = select
		return out
	}
	p_fail(p, .Sql_Syntax, "a subquery must be a SELECT")
	return nil
}

parse_select :: proc(p: ^Parser) -> Statement {
	select: Select_Stmt
	p_expect_keyword(p, "select")
	if p_match_keyword(p, "distinct") do select.is_distinct = true
	projections := make([dynamic]Select_Item, 0, 4, p.alloc)
	for {
		item: Select_Item
		if p_is_punct(p, "*") {
			p_advance(p)
			item.star = true
		} else {
			item.expr = parse_expression(p)
		}
		if p_match_keyword(p, "as") {
			item.alias = p_ident(p)
		} else if (p.current.kind == .Ident || p.current.kind == .Quoted_Ident) && !p_is_clause_keyword(p) {
			// A trailing bare name is the alias, as SQL allows.
			item.alias = p_ident(p)
		}
		append(&projections, item)
		if !p_match_punct(p, ",") do break
	}
	select.projections = projections[:]
	// FROM is optional: without it the projections evaluate once, as in
	// `SELECT 1 + 2`.
	if p_match_keyword(p, "from") {
		select.from = parse_table_ref(p)
		joins := make([dynamic]Join_Clause, 0, 1, p.alloc)
		for {
			// `FROM a, b` is a cross join; SQLite accepts it and clients use it
			// to attach a table-valued function to a table.
			if p_match_punct(p, ",") {
				cross: Join_Clause
				cross.table = parse_table_ref(p)
				append(&joins, cross)
				continue
			}
			left := false
			if p_match_keyword(p, "inner") {
				if !p_expect_keyword(p, "join") do break
			} else if p_is_keyword(p, "left") {
				p_advance(p)
				p_match_keyword(p, "outer")
				left = true
				if !p_expect_keyword(p, "join") do break
			} else if p_is_keyword(p, "cross") {
				p_advance(p)
				if !p_expect_keyword(p, "join") do break
			} else if p_is_keyword(p, "natural") || p_is_keyword(p, "right") || p_is_keyword(p, "full") {
				// Read as an alias, these turn the join into a cross join or an
				// inner join and answer a different question than SQLite would.
				// Refusing is the only honest answer until they exist.
				upper := strings.to_upper(p.current.text)
				defer delete(upper)
				p_fail(p, .Sql_Syntax, "%v join is not supported: write an inner or left join with an ON condition", upper)
				break
			} else if !p_match_keyword(p, "join") {
				break
			}
			join: Join_Clause
			join.left = left
			join.table = parse_table_ref(p)
			if p_match_keyword(p, "on") {
				join.on = parse_expression(p)
			} else if p_is_keyword(p, "using") {
				p_advance(p)
				join.using_columns = parse_using_columns(p)
				join.on = parse_using_condition(p, select.from, joins[:], join.table, join.using_columns)
			}
			append(&joins, join)
		}
		select.joins = joins[:]
	}
	if p_match_keyword(p, "where") {
		select.where_clause = parse_expression(p)
	}
	if p_match_keyword(p, "group") {
		p_expect_keyword(p, "by")
		groups := make([dynamic]^Expr, 0, 2, p.alloc)
		for {
			append(&groups, parse_expression(p))
			if !p_match_punct(p, ",") do break
		}
		select.group_by = groups[:]
	}
	if p_match_keyword(p, "having") {
		select.having = parse_expression(p)
	}
	if p_match_keyword(p, "order") {
		p_expect_keyword(p, "by")
		orders := make([dynamic]Order_Item, 0, 2, p.alloc)
		for {
			item: Order_Item
			item.expr = parse_expression(p)
			if p_match_keyword(p, "desc") {
				item.descending = true
			} else {
				p_match_keyword(p, "asc")
			}
			append(&orders, item)
			if !p_match_punct(p, ",") do break
		}
		select.order_by = orders[:]
	}
	if p_match_keyword(p, "limit") {
		select.limit = parse_expression(p)
	}
	if p_match_keyword(p, "offset") {
		select.offset = parse_expression(p)
	}
		// UNION [ALL | DISTINCT] chains more terms. ORDER BY, LIMIT and OFFSET of
	// any term apply to the compound as a whole, so they move to this select.
	parts := make([dynamic]Compound_Select, 0, 2, p.alloc)
	for {
		if !p_match_keyword(p, "union") do break
		all := p_match_keyword(p, "all")
		if !all do p_match_keyword(p, "distinct")
		select_stmt, ok := parse_select(p).(Select_Stmt)
		if !ok do break
		if len(select_stmt.order_by) > 0 && len(select.order_by) == 0 {
			select.order_by = select_stmt.order_by
			select_stmt.order_by = nil
		}
		if select_stmt.limit != nil && select.limit == nil {
			select.limit = select_stmt.limit
			select_stmt.limit = nil
		}
		if select_stmt.offset != nil && select.offset == nil {
			select.offset = select_stmt.offset
			select_stmt.offset = nil
		}
		// Flatten a chain the nested parse may have collected, so every term ends
		// up in one list.
		inner := select_stmt.compound
		select_stmt.compound = nil
		append(&parts, Compound_Select{all = all, select_stmt = select_stmt})
		for extra in inner do append(&parts, extra)
	}
	select.compound = parts[:]
return select
}

@(private)
p_is_table_clause_keyword :: proc(p: ^Parser) -> bool {
	if p.current.kind != .Ident do return false
	for keyword in ([]string{"where", "group", "having", "order", "limit", "offset", "join", "inner", "left", "cross", "outer", "natural", "right", "full", "on", "union", "using", "set", "values", "returning"}) {
		if strings.equal_fold(p.current.text, keyword) do return true
	}
	return false
}

@(private)
p_sequence_number :: proc(p: ^Parser) -> (i64, bool) {
	negative := p_match_punct(p, "-")
	if p.current.kind != .Number {
		p_fail(p, .Sql_Syntax, "expected a number, found %q", p.current.text)
		return 0, false
	}
	value, ok := value_parse_number(p.current.text)
	p_advance(p)
	number, number_ok := value_to_i64(value)
	if !ok || !number_ok {
		p_fail(p, .Sql_Syntax, "invalid sequence number")
		return 0, false
	}
	return negative ? -number : number, true
}

// parse_using_columns reads `(a, b, ...)` after `USING`.
@(private)
parse_using_columns :: proc(p: ^Parser) -> []string {
	columns := make([dynamic]string, 0, 2, p.alloc)
	if !p_expect_punct(p, "(") do return columns[:]
	if !p_is_punct(p, ")") {
		for {
			append(&columns, p_ident(p))
			if !p_match_punct(p, ",") do break
		}
	}
	p_expect_punct(p, ")")
	if len(columns) == 0 {
		p_fail(p, .Sql_Syntax, "USING needs at least one column")
	}
	return columns[:]
}

// parse_using_condition turns `JOIN b USING (x, y)` into the condition the rest of
// the engine already understands, `left.x = b.x AND left.y = b.y`. The left side is
// the relation written before the join: SQL resolves a USING column in the earlier
// joined tables, and the one immediately before is the only one that can hold it
// without being ambiguous.
@(private)
parse_using_condition :: proc(
	p: ^Parser,
	from: Table_Ref,
	previous: []Join_Clause,
	right: Table_Ref,
	columns: []string,
) -> ^Expr {
	left := from
	if len(previous) > 0 do left = previous[len(previous) - 1].table
	left_name := left.name
	if len(left.alias) > 0 do left_name = left.alias
	right_name := right.name
	if len(right.alias) > 0 do right_name = right.alias
	condition: ^Expr
	for column in columns {
		equality := new(Expr, p.alloc)
		equality^ = Binary_Expr {
			op    = .Eq,
			left  = column_expr(p, left_name, column),
			right = column_expr(p, right_name, column),
		}
		if condition == nil {
			condition = equality
			continue
		}
		both := new(Expr, p.alloc)
		both^ = Binary_Expr{op = .And, left = condition, right = equality}
		condition = both
	}
	return condition
}

@(private)
column_expr :: proc(p: ^Parser, table: string, column: string) -> ^Expr {
	expr := new(Expr, p.alloc)
	expr^ = Column_Expr{table = strings.clone(table, p.alloc), name = strings.clone(column, p.alloc)}
	return expr
}

parse_table_ref :: proc(p: ^Parser) -> Table_Ref {
	ref: Table_Ref
	ref.name = p_ident(p)
	if p_match_punct(p, ".") {
		// schema.table: keep the qualifier, `name` is the table.
		ref.schema = ref.name
		ref.name = p_ident(p)
	}
	if p_match_punct(p, "(") {
		args := make([dynamic]^Expr, 0, 2, p.alloc)
		if !p_is_punct(p, ")") {
			for {
				append(&args, parse_expression(p))
				if !p_match_punct(p, ",") do break
			}
		}
		p_expect_punct(p, ")")
		ref.args = args[:]
	}
	if p_match_keyword(p, "as") {
		// `AS OF <seq>` is the historical read; `AS <alias>` is a name.
		if p_match_keyword(p, "of") {
			ref.as_of = parse_expression(p)
			return ref
		}
		ref.alias = p_ident(p)
	} else if (p.current.kind == .Ident || p.current.kind == .Quoted_Ident) && !p_is_table_clause_keyword(p) {
		ref.alias = p_ident(p)
	}
	return ref
}

// parse_frame_bound reads one end of a ROWS frame:
// UNBOUNDED PRECEDING|FOLLOWING, CURRENT ROW, or <n> PRECEDING|FOLLOWING.
@(private)
parse_frame_bound :: proc(p: ^Parser) -> Frame_Bound {
	if p_match_keyword(p, "unbounded") {
		if p_match_keyword(p, "preceding") do return Frame_Bound{kind = .Unbounded_Preceding}
		if p_match_keyword(p, "following") do return Frame_Bound{kind = .Unbounded_Following}
		p_fail(p, .Sql_Syntax, "a frame bound needs PRECEDING or FOLLOWING after UNBOUNDED")
		return {}
	}
	if p_match_keyword(p, "current") {
		if !p_expect_keyword(p, "row") do return {}
		return Frame_Bound{kind = .Current_Row}
	}
	offset := parse_expression(p)
	if p_match_keyword(p, "preceding") {
		return Frame_Bound{kind = .Preceding, offset = offset}
	}
	if p_match_keyword(p, "following") {
		return Frame_Bound{kind = .Following, offset = offset}
	}
	p_fail(p, .Sql_Syntax, "a frame bound needs PRECEDING or FOLLOWING")
	return {}
}

@(private)
parse_insert :: proc(p: ^Parser) -> Statement {
	insert: Insert_Stmt
	p_expect_keyword(p, "insert")
	p_expect_keyword(p, "into")
	insert.table = p_ident(p)
	if p_is_punct(p, ".") {
		// An attached database is read-only: say so instead of a syntax error.
		p_fail(p, .Sql_Unsupported, "writes to an attached database are read-only")
		return insert
	}
	columns := make([dynamic]string, 0, 4, p.alloc)
	if p_match_punct(p, "(") {
		for {
			append(&columns, p_ident(p))
			if !p_match_punct(p, ",") do break
		}
		p_expect_punct(p, ")")
	}
	insert.columns = columns[:]
	// INSERT INTO t (cols) SELECT ...: the rows come from a query.
	if p_is_keyword(p, "select") {
		if select_stmt, ok := parse_select(p).(Select_Stmt); ok {
			insert.select_stmt = select_stmt
			insert.has_select = true
		}
		insert.returning = parse_returning(p)
		return insert
	}
	if !p_expect_keyword(p, "values") do return insert
	rows := make([dynamic][]^Expr, 0, 4, p.alloc)
	for {
		if !p_expect_punct(p, "(") do break
		values := make([dynamic]^Expr, 0, len(columns), p.alloc)
		if !p_is_punct(p, ")") {
			for {
				append(&values, parse_expression(p))
				if !p_match_punct(p, ",") do break
			}
		}
		p_expect_punct(p, ")")
		append(&rows, values[:])
		if !p_match_punct(p, ",") do break
	}
	insert.rows = rows[:]
	// UPSERT: ON CONFLICT [(columns)] DO NOTHING | DO UPDATE SET ...
	if p_match_keyword(p, "on") {
		p_expect_keyword(p, "conflict")
		if p_match_punct(p, "(") {
			for !p_is_punct(p, ")") && p.current.kind != .EOF {
				p_advance(p)
			}
			p_expect_punct(p, ")")
		}
		if !p_expect_keyword(p, "do") do return insert
		if p_match_keyword(p, "nothing") {
			insert.conflict_do_nothing = true
		} else if p_match_keyword(p, "update") {
			if !p_expect_keyword(p, "set") do return insert
			assignments := make([dynamic]Assignment, 0, 2, p.alloc)
			for {
				assignment: Assignment
				assignment.column = p_ident(p)
				p_expect_punct(p, "=")
				assignment.value = parse_expression(p)
				append(&assignments, assignment)
				if !p_match_punct(p, ",") do break
			}
			insert.conflict_assignments = assignments[:]
		}
	}
	insert.returning = parse_returning(p)
	return insert
}

// parse_returning reads the optional RETURNING clause of a mutation.
@(private)
parse_returning :: proc(p: ^Parser) -> ^Returning {
	if !p_match_keyword(p, "returning") do return nil
	returning := new(Returning, p.alloc)
	if p_match_punct(p, "*") {
		returning.star = true
		return returning
	}
	columns := make([dynamic]string, 0, 2, p.alloc)
	for {
		append(&columns, p_ident(p))
		if !p_match_punct(p, ",") do break
	}
	returning.columns = columns[:]
	return returning
}

@(private)
parse_update :: proc(p: ^Parser) -> Statement {
	update: Update_Stmt
	p_expect_keyword(p, "update")
	update.table = p_ident(p)
	if p_is_punct(p, ".") {
		p_fail(p, .Sql_Unsupported, "writes to an attached database are read-only")
		return update
	}
	p_expect_keyword(p, "set")
	assignments := make([dynamic]Assignment, 0, 4, p.alloc)
	for {
		assignment: Assignment
		assignment.column = p_ident(p)
		p_expect_punct(p, "=")
		assignment.value = parse_expression(p)
		append(&assignments, assignment)
		if !p_match_punct(p, ",") do break
	}
	update.assignments = assignments[:]
	if p_match_keyword(p, "from") {
		update.from = parse_table_ref(p)
	}
	if p_match_keyword(p, "where") {
		update.where_clause = parse_expression(p)
	}
	update.returning = parse_returning(p)
	return update
}

@(private)
parse_delete :: proc(p: ^Parser) -> Statement {
	delete_stmt: Delete_Stmt
	p_expect_keyword(p, "delete")
	p_expect_keyword(p, "from")
	delete_stmt.table = p_ident(p)
	if p_is_punct(p, ".") {
		p_fail(p, .Sql_Unsupported, "writes to an attached database are read-only")
		return delete_stmt
	}
	if p_match_keyword(p, "using") {
		delete_stmt.using_ref = parse_table_ref(p)
	}
	if p_match_keyword(p, "where") {
		delete_stmt.where_clause = parse_expression(p)
	}
	delete_stmt.returning = parse_returning(p)
	return delete_stmt
}

@(private)
parse_create :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "create")
	temporary := false
	if p_match_keyword(p, "temporary") {
		temporary = true
	} else if p_match_keyword(p, "temp") {
		temporary = true
	}
	event := false
	if p_match_keyword(p, "event") {
		event = true
	}
	or_replace := false
	if p_match_keyword(p, "or") {
		p_expect_keyword(p, "replace")
		or_replace = true
	}
	unique := p_match_keyword(p, "unique")
	if p_match_keyword(p, "trigger") {
		if or_replace || temporary || event || unique {
			p_fail(p, .Sql_Syntax, "CREATE TRIGGER takes no modifiers")
			return nil
		}
		return parse_create_trigger(p)
	}
	if p_match_keyword(p, "type") {
		if or_replace || temporary || event || unique {
			p_fail(p, .Sql_Syntax, "CREATE TYPE takes no modifiers")
			return nil
		}
		return parse_create_type(p)
	}
	if p_match_keyword(p, "virtual") {
		if or_replace || temporary || event || unique {
			p_fail(p, .Sql_Syntax, "CREATE VIRTUAL TABLE takes no modifiers")
			return nil
		}
		return parse_create_virtual_table(p)
	}
	if p_match_keyword(p, "table") {
		if or_replace {
			p_fail(p, .Sql_Unsupported, "CREATE OR REPLACE TABLE is not supported")
			return nil
		}
		if unique {
			p_fail(p, .Sql_Syntax, "CREATE UNIQUE TABLE is not a statement")
			return nil
		}
		return parse_create_table(p, temporary, event)
	}
	if p_match_keyword(p, "index") {
		if temporary {
			p_fail(p, .Sql_Unsupported, "CREATE TEMPORARY INDEX is not supported")
			return nil
		}
		return parse_create_index(p, unique)
	}
	if p_match_keyword(p, "view") {
		if unique {
			p_fail(p, .Sql_Syntax, "CREATE UNIQUE VIEW is not a statement")
			return nil
		}
		return parse_create_view(p, or_replace)
	}
	if p_match_keyword(p, "policy") {
		if unique {
			p_fail(p, .Sql_Syntax, "CREATE UNIQUE POLICY is not a statement")
			return nil
		}
		return parse_create_policy(p)
	}
	p_fail(p, .Sql_Syntax, "expected TABLE, INDEX, TRIGGER, VIEW or POLICY after CREATE")
	return nil
}

// parse_grant reads both GRANT shapes:
//
//	GRANT role TO identity
//	GRANT action ON table TO role
parse_grant :: proc(p: ^Parser, revoke: bool) -> Statement {
	p_advance(p)
	stmt: Grant_Stmt
	stmt.revoke = revoke
	first := p_ident(p)
	// A quoted literal is always an identity; a bare word may start either shape.
	if p_current_is_string(p) {
		stmt.identity = first
		p_match_keyword(p, "to")
		stmt.role = ""
		p_fail(p, .Sql_Syntax, "GRANT expects a role name")
		return stmt
	}
	if p_match_keyword(p, "on") {
		stmt.action = first
		stmt.table = p_ident(p)
		if revoke {
			p_expect_keyword(p, "from")
		} else {
			p_expect_keyword(p, "to")
		}
		stmt.role = p_ident(p)
		return stmt
	}
	stmt.role = first
	if revoke {
		p_expect_keyword(p, "from")
	} else {
		p_expect_keyword(p, "to")
	}
	if p.current.kind != .String {
		p_fail(p, .Sql_Syntax, "GRANT needs an identity as a quoted string")
		return stmt
	}
	stmt.identity = p.current.text
	p_advance(p)
	return stmt
}

@(private)
p_current_is_string :: proc(p: ^Parser) -> bool {
	return p.current.kind == .String
}

// parse_create_trigger reads the trigger header and keeps the body as text: the
// statements are parsed again when the trigger fires, with NEW and OLD in scope.
parse_create_trigger :: proc(p: ^Parser) -> Statement {
	stmt: Create_Trigger_Stmt
	if p_match_keyword(p, "if") {
		p_expect_keyword(p, "not")
		p_expect_keyword(p, "exists")
		stmt.if_not_exists = true
	}
	stmt.name = p_ident(p)
	if p_match_keyword(p, "before") {
		stmt.before = true
	} else {
		_ = p_match_keyword(p, "after")
	}
	if p_match_keyword(p, "insert") {
		stmt.event = "insert"
	} else if p_match_keyword(p, "update") {
		stmt.event = "update"
	} else if p_match_keyword(p, "delete") {
		stmt.event = "delete"
	} else {
		p_fail(p, .Sql_Syntax, "a trigger needs INSERT, UPDATE or DELETE")
		return stmt
	}
	if p_match_keyword(p, "of") {
		p_fail(p, .Sql_Unsupported, "column-specific triggers are not supported")
		return stmt
	}
	p_expect_keyword(p, "on")
	stmt.table = p_ident(p)
	if p_match_keyword(p, "for") {
		p_expect_keyword(p, "each")
		p_expect_keyword(p, "row")
	}
	if p_match_keyword(p, "when") {
		// The condition is kept as text, like the body, and parsed when it fires:
		// that is the only place NEW and OLD exist. It is parsed here too, so a
		// syntax error is reported at CREATE TRIGGER.
		when_start := p.lexer.pos - len(p.current.text)
		_ = parse_expression(p)
		when_end := p.lexer.pos - len(p.current.text)
		if when_end <= when_start {
			p_fail(p, .Sql_Syntax, "WHEN needs a condition")
			return stmt
		}
		stmt.when_text = strings.clone(
			strings.trim_space(p.query.source[when_start:when_end]),
			p.alloc,
		)
		check, _, check_err := sql_parse_expression(stmt.when_text)
		if !error_ok(check_err) {
			p_fail(p, check_err.kind, "trigger WHEN: %s", check_err.message)
			return stmt
		}
		query_destroy(&check)
	}
	p_expect_keyword(p, "begin")
	body_start := p.lexer.pos - len(p.current.text)
	for !p_is_keyword(p, "end") && p.current.kind != .EOF && p.err.kind == .None {
		_ = parse_statement(p)
		_ = p_match_punct(p, ";")
	}
	if !p_is_keyword(p, "end") {
		p_fail(p, .Sql_Syntax, "CREATE TRIGGER needs END")
		return stmt
	}
	body_end := p.lexer.pos - len(p.current.text)
	p_advance(p)
	if body_end > body_start {
		stmt.body = strings.clone(strings.trim_space(p.query.source[body_start:body_end]), p.alloc)
	}
	return stmt
}

// parse_type_ref reads a column type. `builtin` is false when the name is
// unknown, in which case the caller defers to the type catalog.
@(private)
parse_type_ref :: proc(p: ^Parser) -> (t: Column_Type, builtin: bool, name: string) {
	name = p_ident_or_keyword(p)
	upper := strings.to_upper(name)
	if upper == "OPTION" {
		if !p_expect_punct(p, "(") do return {}, true, name
		inner, inner_ok, inner_name := parse_type_ref(p)
		if !inner_ok {
			p_fail(p, .Sql_Syntax, "named types cannot be nested: %q", inner_name)
			return {}, true, name
		}
		p_expect_punct(p, ")")
		return Column_Type{kind = .Option, inner_kind = inner.kind, inner_width = inner.width}, true, name
	}
	if upper == "ARRAY" {
		if !p_expect_punct(p, "(") do return {}, true, name
		inner, inner_ok, inner_name := parse_type_ref(p)
		if !inner_ok {
			p_fail(p, .Sql_Syntax, "named types cannot be nested: %q", inner_name)
			return {}, true, name
		}
		p_expect_punct(p, ")")
		return Column_Type{kind = .Array, inner_kind = inner.kind, inner_width = inner.width}, true, name
	}
	if upper == "PRODUCT" {
		if !p_expect_punct(p, "(") do return {}, true, name
		components := make([dynamic]Column_Type, 0, 2, p.alloc)
		for {
			component, component_ok, component_name := parse_type_ref(p)
			if !component_ok {
				p_fail(p, .Sql_Syntax, "named types cannot be nested: %q", component_name)
				return {}, true, name
			}
			append(&components, component)
			if !p_match_punct(p, ",") do break
		}
		p_expect_punct(p, ")")
		if len(components) < 2 {
			p_fail(p, .Sql_Syntax, "PRODUCT needs at least two components")
			return {}, true, name
		}
		return Column_Type{kind = .Product, components = components[:]}, true, name
	}
	if upper == "RESULT" {
		if !p_expect_punct(p, "(") do return {}, true, name
		ok_type, ok_ok, ok_name := parse_type_ref(p)
		if !ok_ok {
			p_fail(p, .Sql_Syntax, "named types cannot be nested: %q", ok_name)
			return {}, true, name
		}
		p_expect_punct(p, ",")
		err_type, err_ok, err_name := parse_type_ref(p)
		if !err_ok {
			p_fail(p, .Sql_Syntax, "named types cannot be nested: %q", err_name)
			return {}, true, name
		}
		p_expect_punct(p, ")")
		return Column_Type {
			kind = .Result,
			inner_kind = ok_type.kind,
			inner_width = ok_type.width,
			right_kind = err_type.kind,
			right_width = err_type.width,
		}, true, name
	}
	if kind, width, found := type_kind_from_name(name); found {
		return Column_Type{kind = kind, width = width}, true, name
	}
	return {}, false, name
}

@(private)
parse_create_type :: proc(p: ^Parser) -> Statement {
	stmt: Create_Type_Stmt
	if p_match_keyword(p, "if") {
		p_expect_keyword(p, "not")
		p_expect_keyword(p, "exists")
		stmt.if_not_exists = true
	}
	stmt.name = p_ident(p)
	if !p_expect_keyword(p, "as") do return stmt
	base, base_ok, base_name := parse_type_ref(p)
	if !base_ok {
		p_fail(p, .Sql_Syntax, "unknown base type %q", base_name)
		return stmt
	}
	stmt.base = base
	return stmt
}

@(private)
parse_fk_action :: proc(p: ^Parser) -> Foreign_Key_Action {
	if p_match_keyword(p, "cascade") do return .Cascade
	if p_match_keyword(p, "restrict") do return .Restrict
	p_fail(p, .Sql_Syntax, "expected CASCADE or RESTRICT")
	return .Restrict
}

@(private)
// parse_load_extension reads `LOAD EXTENSION name AT 'host:port' [USING a, b]`
// and `UNLOAD EXTENSION [IF EXISTS] name`.
parse_load_extension :: proc(p: ^Parser, unload: bool) -> Statement {
	stmt: Load_Extension_Stmt
	stmt.unload = unload
	p_expect_keyword(p, "extension")
	if unload && p_match_keyword(p, "if") {
		p_expect_keyword(p, "exists")
		stmt.if_exists = true
	}
	stmt.name = p_ident(p)
	if unload do return stmt
	p_expect_keyword(p, "at")
	if p.current.kind != .String {
		p_fail(p, .Sql_Syntax, "LOAD EXTENSION needs a 'host:port' string")
		return stmt
	}
	stmt.address = p.current.text
	p_advance(p)
	if p_match_keyword(p, "using") {
		reducers := make([dynamic]string, 0, 2, p.alloc)
		for {
			append(&reducers, p_ident(p))
			if !p_match_punct(p, ",") do break
		}
		stmt.reducers = reducers[:]
	}
	return stmt
}

// parse_create_virtual_table reads `CREATE VIRTUAL TABLE [IF NOT EXISTS] name
// USING module(column, ...)`.
parse_create_virtual_table :: proc(p: ^Parser) -> Statement {
	stmt: Create_Virtual_Table_Stmt
	p_expect_keyword(p, "table")
	if p_match_keyword(p, "if") {
		p_expect_keyword(p, "not")
		p_expect_keyword(p, "exists")
		stmt.if_not_exists = true
	}
	stmt.name = p_ident(p)
	p_expect_keyword(p, "using")
	stmt.module = p_ident(p)
	if !p_expect_punct(p, "(") do return stmt
	columns := make([dynamic]string, 0, 2, p.alloc)
	for {
		append(&columns, p_ident(p))
		// Options after a column (tokenize=..., prefix=...) are accepted and
		// ignored: this implementation has one tokenizer.
		if p_match_punct(p, ",") do continue
		break
	}
	p_expect_punct(p, ")")
	stmt.columns = columns[:]
	return stmt
}

parse_create_table :: proc(p: ^Parser, ephemeral: bool, event: bool) -> Statement {
	stmt: Create_Table_Stmt
	stmt.ephemeral = ephemeral
	stmt.event = event
	if p_match_keyword(p, "if") {
		p_expect_keyword(p, "not")
		p_expect_keyword(p, "exists")
		stmt.if_not_exists = true
	}
	stmt.name = p_ident(p)
	if !p_expect_punct(p, "(") do return stmt
	columns := make([dynamic]Column_Def, 0, 4, p.alloc)
	constraints := make([dynamic]Table_Constraint, 0, 1, p.alloc)
	for {
		constraint_name := ""
		if p_match_keyword(p, "constraint") {
			constraint_name = p_ident(p)
		}
		if p_is_keyword(p, "foreign") {
			constraint: Table_Constraint
			constraint.name = constraint_name
			constraint.is_foreign = true
			p_expect_keyword(p, "foreign")
			p_expect_keyword(p, "key")
			p_expect_punct(p, "(")
			cols := make([dynamic]string, 0, 2, p.alloc)
			for {
				append(&cols, p_ident(p))
				if !p_match_punct(p, ",") do break
			}
			p_expect_punct(p, ")")
			constraint.columns = cols[:]
			p_expect_keyword(p, "references")
			constraint.ref_table = p_ident(p)
			p_expect_punct(p, "(")
			refs := make([dynamic]string, 0, 2, p.alloc)
			for {
				append(&refs, p_ident(p))
				if !p_match_punct(p, ",") do break
			}
			p_expect_punct(p, ")")
			constraint.ref_columns = refs[:]
			for p_match_keyword(p, "on") {
				if p_match_keyword(p, "delete") {
					constraint.on_delete = parse_fk_action(p)
				} else if p_match_keyword(p, "update") {
					constraint.on_update = parse_fk_action(p)
				} else {
					p_fail(p, .Sql_Syntax, "expected DELETE or UPDATE after ON")
					break
				}
			}
			append(&constraints, constraint)
			if !p_match_punct(p, ",") do break
			continue
		}
		if p_is_keyword(p, "primary") || p_is_keyword(p, "unique") || len(constraint_name) > 0 {
			constraint: Table_Constraint
			constraint.name = constraint_name
			constraint.primary = p_match_keyword(p, "primary")
			if constraint.primary {
				p_expect_keyword(p, "key")
			} else {
				if !p_expect_keyword(p, "unique") do break
			}
			p_expect_punct(p, "(")
			cols := make([dynamic]string, 0, 2, p.alloc)
			for {
				append(&cols, p_ident(p))
				if !p_match_punct(p, ",") do break
			}
			p_expect_punct(p, ")")
			constraint.columns = cols[:]
			append(&constraints, constraint)
			if !p_match_punct(p, ",") do break
			continue
		}
		column: Column_Def
		column.name = p_ident(p)
		parsed, builtin, type_name := parse_type_ref(p)
		if builtin {
			column.type = parsed
		} else {
			// Not a builtin: defer to the type catalog when the statement runs.
			column.type_name = type_name
		}
		if p_match_punct(p, "(") {
			// Length or precision is accepted and ignored.
			for !p_is_punct(p, ")") && p.current.kind != .EOF {
				p_advance(p)
			}
			p_expect_punct(p, ")")
		}
		for {
			if p_match_keyword(p, "primary") {
				p_expect_keyword(p, "key")
				column.primary = true
				continue
			}
			if p_match_keyword(p, "autoincrement") || p_match_keyword(p, "auto_increment") {
				column.autoinc = true
				column.sequence = default_sequence()
				for {
					if p_match_keyword(p, "start") {
						if number, ok := p_sequence_number(p); ok do column.sequence.start = number
						continue
					}
					if p_match_keyword(p, "increment") {
						if number, ok := p_sequence_number(p); ok do column.sequence.increment = number
						continue
					}
					if p_match_keyword(p, "minvalue") {
						if number, ok := p_sequence_number(p); ok do column.sequence.min = number
						continue
					}
					if p_match_keyword(p, "maxvalue") {
						if number, ok := p_sequence_number(p); ok do column.sequence.max = number
						continue
					}
					break
				}
				continue
			}
			if p_match_keyword(p, "unique") {
				column.unique = true
				continue
			}
			if p_match_keyword(p, "not") {
				p_expect_keyword(p, "null")
				column.not_null = true
				continue
			}
			if p_match_keyword(p, "null") {
				continue
			}
			if p_match_keyword(p, "default") {
				column.default = parse_primary(p)
				continue
			}
			if p_match_keyword(p, "collate") {
				column.collation = p_ident_or_keyword(p)
				continue
			}
			if p_match_keyword(p, "generated") || (p_is_keyword(p, "as")) {
				if p_is_keyword(p, "as") {
					p_advance(p)
				} else {
					p_match_keyword(p, "always")
					if !p_expect_keyword(p, "as") do break
				}
				if !p_is_punct(p, "(") {
					p_fail(p, .Sql_Syntax, "GENERATED AS needs a parenthesized expression")
					break
				}
				column.generated = true
				column.generated_sql = p_capture_paren_text(p)
				p_match_keyword(p, "stored")
				p_match_keyword(p, "virtual")
				continue
			}
			break
		}
		append(&columns, column)
		if !p_match_punct(p, ",") do break
	}
	stmt.constraints = constraints[:]
	p_expect_punct(p, ")")
	stmt.columns = columns[:]
	// Table options after the closing parenthesis.
	for {
		if p_match_keyword(p, "strict") {
			stmt.strict = true
			continue
		}
		if p_match_keyword(p, "without") {
			p_expect_keyword(p, "rowid")
			p_fail(p, .Sql_Unsupported, "WITHOUT ROWID tables are not supported")
			break
		}
		break
	}
	return stmt
}

// sql_parse_expression parses one expression in isolation. The result points
// into the returned query arena, so the caller destroys the query when done.
sql_parse_expression :: proc(text: string) -> (Query, ^Expr, Error) {
	source := fmt.aprintf("SELECT %s", text)
	defer delete(source)
	query, parse_err := sql_parse(source)
	if parse_err.kind != .None do return {}, nil, parse_err
	select_stmt, ok := query.statement.(Select_Stmt)
	if !ok || len(select_stmt.projections) == 0 {
		query_destroy(&query)
		return {}, nil, errf(.Sql_Syntax, "cannot parse the expression %s", text)
	}
	return query, select_stmt.projections[0].expr, ERROR_NONE
}

// p_capture_paren_text reads a parenthesized expression as SQL text, which is
// what a GENERATED column stores. Tokens are joined with single spaces and a
// string token is re-quoted, because the lexer keeps only its contents.
@(private)
p_capture_paren_text :: proc(p: ^Parser) -> string {
	depth := 0
	builder := strings.builder_make(p.alloc)
	for p.current.kind != .EOF {
		token := p.current
		if token.kind == .Punct && token.text == "(" {
			depth += 1
			if depth == 1 {
				p_advance(p)
				continue
			}
		}
		if token.kind == .Punct && token.text == ")" {
			depth -= 1
			if depth == 0 {
				p_advance(p)
				break
			}
		}
		if strings.builder_len(builder) > 0 && !(token.kind == .Punct && (token.text == ")" || token.text == ",")) do strings.write_byte(&builder, ' ')
		if token.kind == .String {
			strings.write_byte(&builder, '\'')
			for c in transmute([]u8)token.text {
				if c == '\'' do strings.write_byte(&builder, '\'')
				strings.write_byte(&builder, c)
			}
			strings.write_byte(&builder, '\'')
		} else {
			strings.write_string(&builder, token.text)
		}
		p_advance(p)
	}
	return strings.to_string(builder)
}

@(private)
parse_create_index :: proc(p: ^Parser, unique: bool) -> Statement {
	stmt: Create_Index_Stmt
	stmt.unique = unique
	if p_match_keyword(p, "if") {
		p_expect_keyword(p, "not")
		p_expect_keyword(p, "exists")
		stmt.if_not_exists = true
	}
	stmt.name = p_ident(p)
	p_expect_keyword(p, "on")
	stmt.table = p_ident(p)
	if p_match_keyword(p, "using") {
		method := p_ident_or_keyword(p)
		switch strings.to_upper(method) {
		case "BTREE":
			stmt.algorithm = .Btree
		case "HASH":
			stmt.algorithm = .Hash
		case "DIRECT":
			stmt.algorithm = .Direct
		case:
			p_fail(p, .Sql_Syntax, "unknown index method %q", method)
			return stmt
		}
	}
	p_expect_punct(p, "(")
	columns := make([dynamic]string, 0, 2, p.alloc)
	for {
		append(&columns, p_ident(p))
		if !p_match_punct(p, ",") do break
	}
	p_expect_punct(p, ")")
	stmt.columns = columns[:]
	return stmt
}

@(private)
parse_create_view :: proc(p: ^Parser, or_replace: bool) -> Statement {
	stmt: Create_View_Stmt
	stmt.or_replace = or_replace
	if p_match_keyword(p, "if") {
		p_expect_keyword(p, "not")
		p_expect_keyword(p, "exists")
		stmt.if_not_exists = true
	}
	stmt.name = p_ident(p)
	p_expect_keyword(p, "as")
	// The body is stored as SQL: replaying it through the parser keeps the view
	// definition independent from the AST layout.
	start := token_offset(p.query.source, p.current.line, p.current.column)
	parse_select(p)
	end := token_offset(p.query.source, p.current.line, p.current.column)
	stmt.sql = strings.trim_space(p.query.source[start:end])
	return stmt
}

@(private)
token_offset :: proc(source: string, line, column: int) -> int {
	if line <= 1 do return clamp(column - 1, 0, len(source))
	offset := 0
	current := 1
	for offset < len(source) && current < line {
		if source[offset] == '\n' do current += 1
		offset += 1
	}
	return clamp(offset + column - 1, 0, len(source))
}

parse_create_policy :: proc(p: ^Parser) -> Statement {
	stmt: Create_Policy_Stmt
	stmt.name = p_ident(p)
	p_expect_keyword(p, "on")
	stmt.table = p_ident(p)
	for {
		if p_match_keyword(p, "using") {
			p_expect_punct(p, "(")
			start := token_offset(p.query.source, p.current.line, p.current.column)
			parse_expression(p)
			end := token_offset(p.query.source, p.current.line, p.current.column)
			stmt.using_sql = strings.trim_space(p.query.source[start:end])
			p_expect_punct(p, ")")
			continue
		}
		if p_match_keyword(p, "check") {
			p_expect_punct(p, "(")
			start := token_offset(p.query.source, p.current.line, p.current.column)
			parse_expression(p)
			end := token_offset(p.query.source, p.current.line, p.current.column)
			stmt.check_sql = strings.trim_space(p.query.source[start:end])
			p_expect_punct(p, ")")
			continue
		}
		break
	}
	return stmt
}

parse_drop :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "drop")
	if p_match_keyword(p, "trigger") {
		stmt: Drop_Trigger_Stmt
		if p_match_keyword(p, "if") {
			p_expect_keyword(p, "exists")
			stmt.if_exists = true
		}
		stmt.name = p_ident(p)
		return stmt
	}
	if p_match_keyword(p, "policy") {
		stmt: Drop_Policy_Stmt
		if p_match_keyword(p, "if") {
			p_expect_keyword(p, "exists")
			stmt.if_exists = true
		}
		stmt.name = p_ident(p)
		return stmt
	}
	if p_match_keyword(p, "view") {
		stmt: Drop_View_Stmt
		if p_match_keyword(p, "if") {
			p_expect_keyword(p, "exists")
			stmt.if_exists = true
		}
		stmt.name = p_ident(p)
		return stmt
	}
	if p_match_keyword(p, "index") {
		stmt: Drop_Index_Stmt
		if p_match_keyword(p, "if") {
			p_expect_keyword(p, "exists")
			stmt.if_exists = true
		}
		stmt.name = p_ident(p)
		if p_match_keyword(p, "on") do stmt.table = p_ident(p)
		return stmt
	}
	p_expect_keyword(p, "table")
	stmt: Drop_Table_Stmt
	if p_match_keyword(p, "if") {
		p_expect_keyword(p, "exists")
		stmt.if_exists = true
	}
	stmt.name = p_ident(p)
	return stmt
}

// --- Expressions -----------------------------------------------------------

parse_expression :: proc(p: ^Parser) -> ^Expr {
	return parse_or(p)
}

@(private)
parse_or :: proc(p: ^Parser) -> ^Expr {
	left := parse_and(p)
	for p_match_keyword(p, "or") {
		right := parse_and(p)
		left = expr_binary(p, .Or, left, right)
	}
	return left
}

@(private)
parse_and :: proc(p: ^Parser) -> ^Expr {
	left := parse_not(p)
	for p_match_keyword(p, "and") {
		right := parse_not(p)
		left = expr_binary(p, .And, left, right)
	}
	return left
}

@(private)
parse_not :: proc(p: ^Parser) -> ^Expr {
	if p_match_keyword(p, "not") {
		operand := parse_not(p)
		return expr_unary(p, .Not, operand)
	}
	return parse_comparison(p)
}

// parse_operand parses an additive expression and any COLLATE that follows it.
@(private)
parse_operand :: proc(p: ^Parser) -> ^Expr {
	expr := parse_additive(p)
	for p_match_keyword(p, "collate") {
		name := p_ident_or_keyword(p)
		e := new(Expr, p.alloc)
		e^ = Collate_Expr{operand = expr, name = name}
		expr = e
	}
	return expr
}

parse_comparison :: proc(p: ^Parser) -> ^Expr {
	left := parse_operand(p)
	for {
		if p_match_punct(p, "=") || p_match_punct(p, "==") {
			left = expr_binary(p, .Eq, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "!=") || p_match_punct(p, "<>") {
			left = expr_binary(p, .Ne, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "<=") {
			left = expr_binary(p, .Le, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, ">=") {
			left = expr_binary(p, .Ge, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "<") {
			left = expr_binary(p, .Lt, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, ">") {
			left = expr_binary(p, .Gt, left, parse_operand(p))
			continue
		}
		if p_match_keyword(p, "is") {
			negated := p_match_keyword(p, "not")
			p_expect_keyword(p, "null")
			e := new(Expr, p.alloc)
			e^ = Is_Null_Expr{operand = left, negated = negated}
			left = e
			continue
		}
		negated := false
		if p_is_keyword(p, "not") {
			// NOT BETWEEN / NOT IN / NOT LIKE
			p_advance(p)
			negated = true
			if !p_is_keyword(p, "between") && !p_is_keyword(p, "in") && !p_is_keyword(p, "like") && !p_is_keyword(p, "ilike") && !p_is_keyword(p, "glob") {
				p_fail(p, .Sql_Syntax, "expected BETWEEN, IN or LIKE after NOT")
				return left
			}
		}
		if p_match_keyword(p, "between") {
			low := parse_operand(p)
			p_expect_keyword(p, "and")
			high := parse_operand(p)
			e := new(Expr, p.alloc)
			e^ = Between_Expr{operand = left, low = low, high = high, negated = negated}
			left = e
			continue
		}
		if p_match_keyword(p, "in") {
			p_expect_punct(p, "(")
			if p_is_keyword(p, "select") {
				subquery := parse_scalar_subquery(p)
				p_expect_punct(p, ")")
				e := new(Expr, p.alloc)
				e^ = In_Expr{operand = left, subquery = subquery, negated = negated}
				left = e
				continue
			}
			items := make([dynamic]^Expr, 0, 4, p.alloc)
			if !p_is_punct(p, ")") {
				for {
					append(&items, parse_expression(p))
					if !p_match_punct(p, ",") do break
				}
			}
			p_expect_punct(p, ")")
			e := new(Expr, p.alloc)
			e^ = In_Expr{operand = left, items = items[:], negated = negated}
			left = e
			continue
		}
		if p_is_keyword(p, "match") {
			p_advance(p)
			pattern := parse_operand(p)
			e := new(Expr, p.alloc)
			e^ = Match_Expr{operand = left, pattern = pattern}
			left = e
			continue
		}
		if p_is_keyword(p, "like") || p_is_keyword(p, "ilike") || p_is_keyword(p, "glob") {
			case_insensitive := p_is_keyword(p, "ilike")
			is_glob := p_is_keyword(p, "glob")
			p_advance(p)
			pattern := parse_operand(p)
			escape: u8 = 0
			if p_match_keyword(p, "escape") {
				if p.current.kind != .String || len(p.current.text) != 1 {
					p_fail(p, .Sql_Syntax, "ESCAPE needs a one-character string")
					return left
				}
				escape = p.current.text[0]
				p_advance(p)
			}
			e := new(Expr, p.alloc)
			e^ = Like_Expr {
				glob             = is_glob,
				operand          = left,
				pattern          = pattern,
				negated          = negated,
				case_insensitive = case_insensitive,
				escape           = escape,
			}
			left = e
			continue
		}
		if negated {
			p_fail(p, .Sql_Syntax, "unexpected NOT")
		}
		break
	}
	return left
}

@(private)
parse_additive :: proc(p: ^Parser) -> ^Expr {
	left := parse_multiplicative(p)
	for {
		if p_match_punct(p, "+") {
			left = expr_binary(p, .Add, left, parse_multiplicative(p))
			continue
		}
		if p_match_punct(p, "-") {
			left = expr_binary(p, .Sub, left, parse_multiplicative(p))
			continue
		}
		if p_match_punct(p, "||") {
			left = expr_binary(p, .Concat, left, parse_multiplicative(p))
			continue
		}
		break
	}
	return left
}

@(private)
parse_multiplicative :: proc(p: ^Parser) -> ^Expr {
	left := parse_unary(p)
	for {
		if p_match_punct(p, "*") {
			left = expr_binary(p, .Mul, left, parse_unary(p))
			continue
		}
		if p_match_punct(p, "/") {
			left = expr_binary(p, .Div, left, parse_unary(p))
			continue
		}
		if p_match_punct(p, "%") {
			left = expr_binary(p, .Mod, left, parse_unary(p))
			continue
		}
		break
	}
	return left
}

@(private)
parse_unary :: proc(p: ^Parser) -> ^Expr {
	if p_match_punct(p, "-") {
		return expr_unary(p, .Neg, parse_unary(p))
	}
	if p_match_punct(p, "+") {
		return expr_unary(p, .Plus, parse_unary(p))
	}
	return parse_primary(p)
}

@(private)
parse_primary :: proc(p: ^Parser) -> ^Expr {
	token := p.current
	switch token.kind {
	case .Number:
		p_advance(p)
		value, ok := value_parse_number(token.text)
		if !ok {
			p_fail(p, .Sql_Syntax, "invalid number %q", token.text)
			return nil
		}
		return expr_literal(p, value)
	case .String:
		p_advance(p)
		return expr_literal(p, value_string(strings.clone(token.text, p.alloc)))
	case .Blob:
		p_advance(p)
		bytes := make([]u8, len(token.text) / 2)
		for i in 0 ..< len(bytes) {
			high, high_ok := hex_digit_value(rune(token.text[i * 2]))
			low, low_ok := hex_digit_value(rune(token.text[i * 2 + 1]))
			if !high_ok || !low_ok {
				p_fail(p, .Sql_Syntax, "invalid blob literal")
				return nil
			}
			bytes[i] = u8(high << 4 | low)
		}
		return expr_literal(p, value_bytes(bytes))
	case .Ident:
		if p_is_keyword(p, "null") {
			p_advance(p)
			return expr_literal(p, value_null())
		}
		if p_is_keyword(p, "true") {
			p_advance(p)
			return expr_literal(p, value_bool(true))
		}
		if p_is_keyword(p, "false") {
			p_advance(p)
			return expr_literal(p, value_bool(false))
		}
		if p_is_keyword(p, "cast") {
			p_advance(p)
			p_expect_punct(p, "(")
			operand := parse_expression(p)
			p_expect_keyword(p, "as")
			type_name := p_ident_or_keyword(p)
			kind, width, type_ok := type_kind_from_name(type_name)
			if !type_ok {
				p_fail(p, .Sql_Syntax, "unknown cast target %q", type_name)
				return nil
			}
			if p_match_punct(p, "(") {
				for !p_is_punct(p, ")") && p.current.kind != .EOF do p_advance(p)
				p_expect_punct(p, ")")
			}
			p_expect_punct(p, ")")
			e := new(Expr, p.alloc)
			e^ = Cast_Expr{operand = operand, target = Column_Type{kind = kind, width = width}}
			return e
		}
		if p_is_keyword(p, "exists") {
			p_advance(p)
			p_expect_punct(p, "(")
			subquery := parse_scalar_subquery(p)
			p_expect_punct(p, ")")
			e := new(Expr, p.alloc)
			e^ = Subquery_Expr{select = subquery, exists = true}
			return e
		}
		if p_is_keyword(p, "case") {
			return parse_case_expression(p)
		}
		name := p_ident(p)
		if p_is_punct(p, "(") {
			// Function call.
			p_advance(p)
			call := new(Expr, p.alloc)
			call_expr: Call_Expr
			call_expr.name = name
			if p_match_punct(p, "*") {
				call_expr.star = true
			} else if !p_is_punct(p, ")") {
				if p_match_keyword(p, "distinct") do call_expr.is_distinct = true
				args := make([dynamic]^Expr, 0, 2, p.alloc)
				for {
					append(&args, parse_expression(p))
					if !p_match_punct(p, ",") do break
				}
				call_expr.args = args[:]
			}
			p_expect_punct(p, ")")
			if p_match_keyword(p, "over") {
				window := new(Expr, p.alloc)
				window_expr: Window_Expr
				window_expr.name = call_expr.name
				window_expr.args = call_expr.args
				window_expr.star = call_expr.star
				p_expect_punct(p, "(")
				if p_match_keyword(p, "partition") {
					p_expect_keyword(p, "by")
					parts := make([dynamic]^Expr, 0, 2, p.alloc)
					for {
						append(&parts, parse_expression(p))
						if !p_match_punct(p, ",") do break
					}
					window_expr.partition = parts[:]
				}
				if p_match_keyword(p, "order") {
					p_expect_keyword(p, "by")
					items := make([dynamic]Order_Item, 0, 2, p.alloc)
					for {
						item: Order_Item
						item.expr = parse_expression(p)
						if p_match_keyword(p, "desc") {
							item.descending = true
						} else {
							_ = p_match_keyword(p, "asc")
						}
						append(&items, item)
						if !p_match_punct(p, ",") do break
					}
					window_expr.order_by = items[:]
				}
				// An explicit frame over rows, or the default one when it is
				// absent. RANGE and GROUPS need value arithmetic between rows and
				// are refused instead of approximated.
				if p_is_keyword(p, "range") || p_is_keyword(p, "groups") {
					p_fail(p, .Sql_Unsupported, "RANGE and GROUPS frames are not supported; use ROWS")
				}
				if p_match_keyword(p, "rows") {
					frame: Window_Frame
					frame.has = true
					if p_match_keyword(p, "between") {
						frame.start = parse_frame_bound(p)
						p_expect_keyword(p, "and")
						frame.end = parse_frame_bound(p)
					} else {
						frame.start = parse_frame_bound(p)
						frame.end = Frame_Bound{kind = .Current_Row}
					}
					window_expr.frame = frame
				}
				p_expect_punct(p, ")")
				window^ = window_expr
				return window
			}
			call^ = call_expr
			return call
		}
		if p_match_punct(p, ".") {
			if p_match_punct(p, "*") {
				e := new(Expr, p.alloc)
				e^ = Star_Expr{table = name}
				return e
			}
			column_name := p_ident(p)
			// A dotted chain is a qualified column: `database.table.column`
			// keeps everything before the last part as the table name, which is
			// how an attached table is named (`side.other_items.name`).
			table := name
			for p_match_punct(p, ".") {
				table = strings.concatenate({table, ".", column_name}, p.alloc)
				column_name = p_ident(p)
			}
			column := new(Expr, p.alloc)
			column^ = Column_Expr{table = table, name = column_name}
			return column
		}
		column := new(Expr, p.alloc)
		column^ = Column_Expr{name = name}
		return column
	case .Quoted_Ident:
		name := p_ident(p)
		if p_match_punct(p, ".") {
			if p_match_punct(p, "*") {
				e := new(Expr, p.alloc)
				e^ = Star_Expr{table = name}
				return e
			}
			column_name := p_ident(p)
			table := name
			for p_match_punct(p, ".") {
				table = strings.concatenate({table, ".", column_name}, p.alloc)
				column_name = p_ident(p)
			}
			column := new(Expr, p.alloc)
			column^ = Column_Expr{table = table, name = column_name}
			return column
		}
		column := new(Expr, p.alloc)
		column^ = Column_Expr{name = name}
		return column
	case .Punct:
		if token.text == "?" {
			p_advance(p)
			e := new(Expr, p.alloc)
			e^ = Param_Expr{index = p.param_count}
			p.param_count += 1
			return e
		}
		if token.text == "*" {
			p_advance(p)
			e := new(Expr, p.alloc)
			e^ = Star_Expr{}
			return e
		}
		if token.text == "(" {
			p_advance(p)
			if p_is_keyword(p, "select") {
				subquery := parse_scalar_subquery(p)
				p_expect_punct(p, ")")
				e := new(Expr, p.alloc)
				e^ = Subquery_Expr{select = subquery}
				return e
			}
			inner := parse_expression(p)
			p_expect_punct(p, ")")
			return inner
		}
		p_fail(p, .Sql_Syntax, "unexpected token %q", token.text)
		return nil
	case .EOF:
		p_fail(p, .Sql_Syntax, "unexpected end of statement")
		return nil
	}
	p_fail(p, .Sql_Syntax, "unexpected token %q", token.text)
	return nil
}

@(private)
expr_literal :: proc(p: ^Parser, value: Value) -> ^Expr {
	e := new(Expr, p.alloc)
	e^ = Literal_Expr{value = value}
	return e
}

@(private)
expr_binary :: proc(p: ^Parser, op: Binary_Op, left, right: ^Expr) -> ^Expr {
	if left == nil || right == nil do return left
	e := new(Expr, p.alloc)
	e^ = Binary_Expr{op = op, left = left, right = right}
	return e
}

@(private)
expr_unary :: proc(p: ^Parser, op: Unary_Op, operand: ^Expr) -> ^Expr {
	if operand == nil do return nil
	e := new(Expr, p.alloc)
	e^ = Unary_Expr{op = op, operand = operand}
	return e
}

// parse_case_expression parses CASE [operand] WHEN ... THEN ... [ELSE ...] END.
// Both forms go through the same expression evaluator, so a CASE works in a
// projection, a WHERE clause, a policy, a trigger or a generated column.
@(private)
parse_case_expression :: proc(p: ^Parser) -> ^Expr {
	p_advance(p) // CASE
	operand: ^Expr
	if !p_is_keyword(p, "when") {
		operand = parse_expression(p)
	}
	branches := make([dynamic]Case_When, 0, 2, p.alloc)
	for p_match_keyword(p, "when") {
		condition := parse_expression(p)
		p_expect_keyword(p, "then")
		result := parse_expression(p)
		append(&branches, Case_When{condition = condition, result = result})
	}
	if len(branches) == 0 {
		p_fail(p, .Sql_Syntax, "CASE needs at least one WHEN branch")
		return nil
	}
	fallback: ^Expr
	if p_match_keyword(p, "else") {
		fallback = parse_expression(p)
	}
	p_expect_keyword(p, "end")
	expression := new(Expr, p.alloc)
	expression^ = Case_Expr{operand = operand, branches = branches[:], fallback = fallback}
	return expression
}
