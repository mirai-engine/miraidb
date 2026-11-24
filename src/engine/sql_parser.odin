package engine

import "core:mem"
import "core:mem/virtual"
import "core:fmt"
import "core:strconv"
import "core:strings"

Parser :: struct {
	lexer:       Lexer,
	current:     Token,
	alloc:       mem.Allocator,
	query:       ^Query,
	err:         Error,
	param_count: int,
	// param_names names each parameter slot: "?3", ":id", "@id", "$id", or ""
	// for a bare `?`. It lives in the query's arena.
	param_names: [dynamic]string,
	// prev_end is where the token before the current one ended: the end of the
	// text a construct that just finished was written with.
	prev_end: int,
	// ident_start is where the last name p_ident read begins, and object_start
	// where a CREATE's object name (or ADD COLUMN's column) begins: the text
	// SQLite keeps starts there (sqlite_text.odin).
	ident_start:  int,
	object_start: int,
	// cast_name is the type name the last CAST target was written with.
	cast_name:    string,
	// expression_depth is how many expressions are open right now. It is one
	// counter for the whole parser, not one per rule, because every nesting that
	// costs stack goes through parse_expression.
	expression_depth: int,
	// derived_count numbers the derived tables a statement does not name.
	derived_count: int,
	// windows are the window calls that name a window of a WINDOW clause, in
	// the order they were read; the SELECT that owns them resolves them.
	windows: [dynamic]Pending_Window,
	// binary_depth is how deep each binary node's subtree is. A chain such as
	// `1+1+...` nests one level per operator without any parenthesis, and the
	// tree is walked recursively before it is evaluated.
	binary_depth: map[^Expr]int,
}

// Pending_Window is a window call that names a window of a WINDOW clause:
// `OVER name` takes it whole, `OVER (name ...)` (parenthesized) adds to it.
Pending_Window :: struct {
	expr:          ^Expr,
	base:          string,
	parenthesized: bool,
}

// sql_parse turns one SQL statement into a Query tree. The Query owns an arena
// with every node; destroy it with query_destroy.
sql_parse :: proc(source: string) -> (Query, Error) {
	q: Query
	if !query_arena_take(&q.arena) {
		return q, errf(.Out_Of_Memory, "cannot allocate the query arena")
	}
	q.alloc = virtual.arena_allocator(&q.arena)
	q.source = strings.clone(source, q.alloc)
	p := Parser {
		lexer       = lexer_init(source, q.alloc),
		alloc       = q.alloc,
		query       = &q,
		param_names = make([dynamic]string, q.alloc),
		// In the query's arena like the rest: left empty, it grew in the heap
		// and nothing freed it.
		windows     = make([dynamic]Pending_Window, q.alloc),
	}
	p.current = lexer_next(&p.lexer)
	statement := parse_statement(&p)
	// A window name outside any SELECT that defines it.
	if p.err.kind == .None {
		if len(p.windows) > 0 do p_fail(&p, .Sql_Syntax, "no such window: %s", p.windows[0].base)
	}
	if p.err.kind != .None {
		query_arena_give(&q.arena)
		return {}, p.err
	}
	sqlite_text_capture(&p, &statement)
	if p.current.kind != .EOF {
		if p.current.text == ";" {
			p.current = lexer_next(&p.lexer)
		}
		if p.current.kind != .EOF {
			query_arena_give(&q.arena)
			return {}, p_fail(&p, .Sql_Syntax, "unexpected token %q", p.current.text)
		}
	}
	q.statement = statement
	q.param_count = p.param_count
	for len(p.param_names) < p.param_count do append(&p.param_names, "")
	q.param_names = p.param_names[:]
	return q, ERROR_NONE
}

// --- Token helpers ---------------------------------------------------------

// SQL_MAX_PARAMETER is the highest `?NNN` a statement may name: SQLite's default
// SQLITE_MAX_VARIABLE_NUMBER.
SQL_MAX_PARAMETER :: 32766

// p_param_slot records that the statement binds parameter `index` (0-based),
// under `name` when it has one, and grows the count to cover it.
@(private)
p_param_slot :: proc(p: ^Parser, index: int, name: string) {
	for len(p.param_names) <= index do append(&p.param_names, "")
	if len(name) > 0 do p.param_names[index] = strings.clone(name, p.alloc)
	if index + 1 > p.param_count do p.param_count = index + 1
}

@(private)
p_fail :: proc(p: ^Parser, kind: Error_Kind, format: string, args: ..any) -> Error {
	if p.err.kind == .None {
		detail := fmt.aprintf(format, ..args, allocator = context.temp_allocator)
		p.err = errf(kind, "line %d, column %d: %s", p.current.line, p.current.column, detail)
	}
	return p.err
}

// p_is_clause_keyword reports whether the current token starts the next clause
// of a SELECT, so it cannot be an implicit alias.
@(private)
p_is_clause_keyword :: proc(p: ^Parser) -> bool {
	if p.current.kind != .Ident do return false
	for keyword in ([]string{"from", "where", "group", "order", "limit", "offset", "having", "union", "intersect", "except", "returning", "window"}) {
		if strings.equal_fold(p.current.text, keyword) do return true
	}
	return false
}

@(private)
p_advance :: proc(p: ^Parser) {
	p.prev_end = p.current.end
	p.current = lexer_next(&p.lexer)
}

// p_text_since is the source text from `start` to the end of the last token
// consumed, with the spaces in front of it skipped, kept in the query's arena.
@(private)
p_text_since :: proc(p: ^Parser, start: int) -> string {
	src := p.lexer.src
	begin := start
	for begin < p.prev_end && (src[begin] == ' ' || src[begin] == '\t' || src[begin] == '\n' || src[begin] == '\r') do begin += 1
	if begin >= p.prev_end || p.prev_end > len(src) do return ""
	return strings.clone(src[begin:p.prev_end], p.alloc)
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

// p_ident accepts a bare or quoted identifier. A string literal where a name
// is required is that name, as SQLite reads it: `CREATE TABLE 't'('c')` is what
// SQLite's own full-text module writes for its shadow tables.
@(private)
p_ident :: proc(p: ^Parser) -> string {
	if p.current.kind == .Ident || p.current.kind == .Quoted_Ident || p.current.kind == .String {
		name := strings.clone(p.current.text, p.alloc)
		p.ident_start = p.current.start
		p_advance(p)
		// `main.x` names x in the database itself, as SQLite reads it; a name
		// qualified by anything else is left to the caller.
		if strings.equal_fold(name, "main") && p_is_punct(p, ".") {
			lexer, token := p_mark(p)
			p_advance(p)
			if p.current.kind == .Ident || p.current.kind == .Quoted_Ident {
				qualified := strings.clone(p.current.text, p.alloc)
				p.ident_start = p.current.start
				p_advance(p)
				return qualified
			}
			p_reset(p, lexer, token)
		}
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
		query_plan := false
		if p_match_keyword(p, "query") {
			p_expect_keyword(p, "plan")
			query_plan = true
		}
		inner := new(Statement, p.alloc)
		inner^ = parse_statement(p)
		return Explain_Stmt{inner = inner, query_plan = query_plan}
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
		with.ctes, with.recursive = parse_with_ctes(p)
		// WITH in front of a write: the CTEs belong to the write, as in SQLite.
		if p_is_keyword(p, "insert") || p_is_keyword(p, "replace") || p_is_keyword(p, "update") || p_is_keyword(p, "delete") {
			return parse_write_with(p, with.ctes, with.recursive)
		}
		if select_stmt, ok := parse_select(p).(Select_Stmt); ok {
			with.select_stmt = select_stmt
		}
		return with
	}
	if p_is_keyword(p, "values") {
		values := parse_values_select(p)
		// ORDER BY and LIMIT may follow, as after any query.
		return values
	}
	if p_is_keyword(p, "copy") do return parse_copy(p)
	if p_is_keyword(p, "insert") || p_is_keyword(p, "replace") do return parse_insert(p)
	if p_is_keyword(p, "update") do return parse_update(p)
	if p_is_keyword(p, "delete") do return parse_delete(p)
	if p_is_keyword(p, "merge") do return parse_merge(p)
	if p_match_keyword(p, "reindex") {
		stmt: Reindex_Stmt
		if p.current.kind == .Ident || p.current.kind == .Quoted_Ident {
			stmt.name = p_ident(p)
		}
		return stmt
	}
	if p_is_keyword(p, "declare") do return parse_declare_cursor(p)
	if p_is_keyword(p, "fetch") || p_is_keyword(p, "move") do return parse_fetch(p)
	if p_is_keyword(p, "close") do return parse_close_cursor(p)
	if p_is_keyword(p, "listen") do return parse_listen(p)
	if p_is_keyword(p, "unlisten") do return parse_unlisten(p)
	if p_is_keyword(p, "notify") do return parse_notify(p)
	if p_is_keyword(p, "grant") do return parse_grant(p, false)
	if p_is_keyword(p, "revoke") do return parse_grant(p, true)
	if p_is_keyword(p, "create") do return parse_create(p)
	if p_is_keyword(p, "drop") do return parse_drop(p)
	if p_match_keyword(p, "begin") {
		// SQLite's lock modes: one writer at a time is the engine's only mode, so
		// all three open the same transaction.
		if !p_match_keyword(p, "deferred") && !p_match_keyword(p, "immediate") {
			p_match_keyword(p, "exclusive")
		}
		p_match_keyword(p, "transaction")
		return Begin_Stmt{}
	}
	// END is SQLite's (and PostgreSQL's) other spelling of COMMIT.
	if p_match_keyword(p, "commit") || p_match_keyword(p, "end") {
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

// COPY_OPTION is one option a COPY statement accepts.
@(private)
Copy_Option :: enum {
	Format,
	Header,
	Delimiter,
	Null,
}

@(private)
copy_option_from_name :: proc(name: string) -> (Copy_Option, bool) {
	switch {
	case strings.equal_fold(name, "format"):
		return .Format, true
	case strings.equal_fold(name, "header"):
		return .Header, true
	case strings.equal_fold(name, "delimiter"):
		return .Delimiter, true
	case strings.equal_fold(name, "null"):
		return .Null, true
	}
	return .Format, false
}

// parse_copy reads `COPY table [(cols)] {FROM|TO} {STDIN|STDOUT|'path'} [(opts)]`.
// PostgreSQL's old option syntax (`CSV HEADER`, `DELIMITER ','`) is accepted next
// to the parenthesized one, because both are in the field.
@(private)
parse_copy :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "copy")
	stmt: Copy_Stmt
	if p.current.kind == .Punct && p.current.text == "(" {
		p_fail(
			p,
			.Sql_Unsupported,
			"COPY of a query is not supported: copy a table, or run a SELECT and write its rows",
		)
		return stmt
	}
	stmt.table = p_ident(p)
	if p_match_punct(p, "(") {
		names := make([dynamic]string, 0, 4, p.alloc)
		for {
			append(&names, p_ident(p))
			if !p_match_punct(p, ",") do break
		}
		p_expect_punct(p, ")")
		stmt.columns = names[:]
	}
	if p_match_keyword(p, "from") {
		stmt.from = true
	} else if p_match_keyword(p, "to") {
		stmt.from = false
	} else {
		p_fail(p, .Sql_Syntax, "COPY needs FROM or TO")
		return stmt
	}
	if p_match_keyword(p, "stdin") {
		stmt.target = .Stdin
	} else if p_match_keyword(p, "stdout") {
		stmt.target = .Stdout
	} else if p.current.kind == .String {
		stmt.target = .File
		stmt.path = strings.clone(p.current.text, p.alloc)
		p_advance(p)
	} else {
		p_fail(p, .Sql_Syntax, "COPY needs STDIN, STDOUT or a file path")
		return stmt
	}
	if stmt.from && stmt.target == .Stdout {
		p_fail(p, .Sql_Syntax, "COPY ... FROM cannot read STDOUT")
		return stmt
	}
	if !stmt.from && stmt.target == .Stdin {
		p_fail(p, .Sql_Syntax, "COPY ... TO cannot write STDIN")
		return stmt
	}
	p_match_keyword(p, "with")
	parenthesized := p_match_punct(p, "(")
	has_null := false
	for {
		if p.current.kind != .Ident && p.current.kind != .Quoted_Ident do break
		option, known := copy_option_from_name(p.current.text)
		if !known do break
		p_advance(p)
		#partial switch option {
		case .Format:
			format := p_ident_or_keyword(p)
			switch {
			case strings.equal_fold(format, "text"):
				stmt.format = .Text
			case strings.equal_fold(format, "csv"):
				stmt.format = .Csv
			case:
				p_fail(p, .Sql_Unsupported, "COPY format %q is not supported: text or csv", format)
				return stmt
			}
		case .Header:
			// `HEADER` alone means true; `HEADER true` and `HEADER false` are the
			// explicit forms.
			stmt.header = true
			if p_is_keyword(p, "true") || p_is_keyword(p, "on") || p_is_keyword(p, "1") {
				p_advance(p)
			} else if p_is_keyword(p, "false") || p_is_keyword(p, "off") || p_is_keyword(p, "0") {
				stmt.header = false
				p_advance(p)
			}
		case .Delimiter:
			p_match_keyword(p, "as")
			if p.current.kind != .String {
				p_fail(p, .Sql_Syntax, "DELIMITER needs a string")
				return stmt
			}
			if len(p.current.text) != 1 {
				p_fail(p, .Sql_Syntax, "DELIMITER must be one byte, found %q", p.current.text)
				return stmt
			}
			stmt.delimiter = p.current.text[0]
			p_advance(p)
		case .Null:
			p_match_keyword(p, "as")
			if p.current.kind != .String {
				p_fail(p, .Sql_Syntax, "NULL needs a string")
				return stmt
			}
			stmt.null_text = strings.clone(p.current.text, p.alloc)
			has_null = true
			p_advance(p)
		}
		if parenthesized && !p_match_punct(p, ",") do break
	}
	if parenthesized do p_expect_punct(p, ")")
	if !has_null {
		// The format decides the default, and an option could have changed the
		// format after another one was read.
		stmt.null_text = stmt.format == .Csv ? "" : "\\N"
	}
	return stmt
}

// parse_declare_cursor reads `DECLARE name [[NO] SCROLL] CURSOR [WITH HOLD] FOR
// query`. The modes PostgreSQL allows (BINARY, INSENSITIVE, WITH HOLD) are read
// and refused, except SCROLL and NO SCROLL, which only say how the client may
// move the cursor and are both answered (the cursor always can).
@(private)
parse_declare_cursor :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "declare")
	stmt: Declare_Cursor_Stmt
	stmt.name = p_ident(p)
	for {
		if p_match_keyword(p, "scroll") {
			stmt.scroll = true
			continue
		}
		if p_match_keyword(p, "no") {
			if p_expect_keyword(p, "scroll") == false do return stmt
			stmt.no_scroll = true
			continue
		}
		if p_match_keyword(p, "binary") {
			p_fail(p, .Sql_Unsupported, "a BINARY cursor is not supported")
			return stmt
		}
		if p_match_keyword(p, "insensitive") {
			continue
		}
		break
	}
	if p_expect_keyword(p, "cursor") == false do return stmt
	if p_match_keyword(p, "with") {
		if p_expect_keyword(p, "hold") == false do return stmt
		stmt.hold = true
	}
	if p_match_keyword(p, "without") {
		if p_expect_keyword(p, "hold") == false do return stmt
	}
	if p_expect_keyword(p, "for") == false do return stmt
	if select_stmt, ok := parse_select(p).(Select_Stmt); ok {
		stmt.query = select_stmt
	}
	return stmt
}

// parse_fetch reads `FETCH [direction] [FROM|IN] name` and its MOVE twin.
@(private)
parse_fetch :: proc(p: ^Parser) -> Statement {
	stmt: Fetch_Stmt
	stmt.move = p_is_keyword(p, "move")
	p_advance(p)
	stmt.direction = .Next
	// The direction is optional; `FETCH FROM c` is one row.
	if p_is_keyword(p, "next") {
		p_advance(p)
		stmt.direction = .Next
	} else if p_is_keyword(p, "prior") {
		p_advance(p)
		stmt.direction = .Prior
	} else if p_is_keyword(p, "first") {
		p_advance(p)
		stmt.direction = .First
	} else if p_is_keyword(p, "last") {
		p_advance(p)
		stmt.direction = .Last
	} else if p_is_keyword(p, "absolute") {
		p_advance(p)
		stmt.direction = .Absolute
		stmt.count = parse_fetch_count(p)
	} else if p_is_keyword(p, "relative") {
		p_advance(p)
		stmt.direction = .Relative
		stmt.count = parse_fetch_count(p)
	} else if p_is_keyword(p, "forward") || p_is_keyword(p, "backward") {
		stmt.direction = p_is_keyword(p, "forward") ? .Forward : .Backward
		p_advance(p)
		if p_match_keyword(p, "all") do stmt.count = 0
		else do stmt.count = parse_fetch_count(p, false)
	} else if p_match_keyword(p, "all") {
		stmt.direction = .All
	} else if p.current.kind == .Number {
		// `FETCH 10 FROM c` is FORWARD 10.
		stmt.direction = .Forward
		stmt.count = parse_fetch_count(p)
	}
	p_match_keyword(p, "from")
	p_match_keyword(p, "in")
	stmt.name = p_ident(p)
	return stmt
}

// parse_fetch_count reads the number a direction or a position takes. A negative
// position is legal (`FETCH ABSOLUTE -1`); `required` is false for FORWARD and
// BACKWARD, where the number may be left out.
@(private)
parse_fetch_count :: proc(p: ^Parser, required := true) -> int {
	if p.current.kind != .Number {
		if required {
			p_fail(p, .Sql_Syntax, "expected a number, found %q", p.current.text)
		}
		return 0
	}
	text := p.current.text
	p_advance(p)
	value: i64
	negative := false
	if len(text) > 0 && text[0] == '-' {
		negative = true
		text = text[1:]
	}
	for c in text {
		if c < '0' || c > '9' {
			p_fail(p, .Sql_Syntax, "%q is not a row count", p.current.text)
			return 0
		}
		value = value * 10 + i64(c - '0')
	}
	return int(negative ? -value : value)
}

// parse_listen and its two neighbours read the channel and its payload. A channel
// is an identifier or a text literal, as PostgreSQL accepts both.
@(private)
parse_channel :: proc(p: ^Parser) -> string {
	if p.current.kind == .String {
		text := strings.clone(p.current.text, p.alloc)
		p_advance(p)
		return text
	}
	return p_ident(p)
}

@(private)
parse_listen :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "listen")
	return Listen_Stmt{channel = parse_channel(p)}
}

@(private)
parse_unlisten :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "unlisten")
	if p_match_punct(p, "*") do return Unlisten_Stmt{all = true}
	return Unlisten_Stmt{channel = parse_channel(p)}
}

@(private)
parse_notify :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "notify")
	stmt: Notify_Stmt
	stmt.channel = parse_channel(p)
	if p_match_punct(p, ",") {
		if p.current.kind == .String {
			stmt.payload = strings.clone(p.current.text, p.alloc)
			p_advance(p)
		}
	}
	return stmt
}

@(private)
parse_close_cursor :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "close")
	stmt: Close_Cursor_Stmt
	if p_match_keyword(p, "all") {
		stmt.all = true
		return stmt
	}
	stmt.name = p_ident(p)
	return stmt
}

// p_next_is reports whether the token after the current one is `keyword`. The
// parser keeps one token, and the lexer is a value, so two tokens of lookahead
// cost nothing: `GROUPING` may start `GROUPING SETS` or a function call.
// p_next_punct reports whether the token after the current one is `text`.
@(private)
p_next_punct :: proc(p: ^Parser, text: string) -> bool {
	saved_lexer := p.lexer
	saved := p.current
	p_advance(p)
	matched := p_is_punct(p, text)
	p.lexer = saved_lexer
	p.current = saved
	return matched
}

@(private)
p_next_is :: proc(p: ^Parser, keyword: string) -> bool {
	saved_lexer := p.lexer
	saved := p.current
	p_advance(p)
	matched := p_is_keyword(p, keyword)
	p.lexer = saved_lexer
	p.current = saved
	return matched
}

// group_expression_add appends an expression to the GROUP BY list unless an
// equal one is already there, and answers its position. The sets index into that
// list, so the same column in two sets has to be one entry: two entries would
// make the projection look up the wrong one.
@(private)
group_expression_add :: proc(p: ^Parser, groups: ^[dynamic]^Expr, expr: ^Expr) -> int {
	if column, is_column := expr^.(Column_Expr); is_column {
		for other, index in groups^ {
			other_column, other_is_column := other^.(Column_Expr)
			if !other_is_column do continue
			if !strings.equal_fold(other_column.name, column.name) do continue
			if !strings.equal_fold(other_column.table, column.table) do continue
			return index
		}
	}
	append(groups, expr)
	return len(groups) - 1
}

// parse_group_by reads the GROUP BY list. A plain list is one set of every
// expression; `ROLLUP`, `CUBE` and `GROUPING SETS` add their own sets, and
// anything beside them multiplies them: `GROUP BY a, ROLLUP(b, c)` groups by
// (a, b, c), (a, b) and (a).
@(private)
parse_group_by :: proc(p: ^Parser, select: ^Select_Stmt) {
	groups := make([dynamic]^Expr, 0, 2, p.alloc)
	// current is the list of sets built so far; it starts as the one empty set.
	current := make([dynamic][dynamic]int, 0, 8, p.alloc)
	append(&current, make([dynamic]int, 0, 4, p.alloc))
	grouping := false
	for {
		if p_is_keyword(p, "rollup") || p_is_keyword(p, "cube") {
			grouping = true
			cube := p_is_keyword(p, "cube")
			p_advance(p)
			p_expect_punct(p, "(")
			positions := make([dynamic]int, 0, 2, p.alloc)
			for {
				append(&positions, group_expression_add(p, &groups, parse_expression(p)))
				if !p_match_punct(p, ",") do break
			}
			p_expect_punct(p, ")")
			produced := make([dynamic][dynamic]int, 0, len(positions) + 1, p.alloc)
			if cube {
				// Every subset, smallest first, which is the order PostgreSQL
				// answers them: () first, then each single column, then the pairs.
				for mask in 0 ..< 1 << uint(len(positions)) {
					set := make([dynamic]int, 0, len(positions), p.alloc)
					for position, bit in positions {
						if mask & (1 << uint(bit)) != 0 do append(&set, position)
					}
					append(&produced, set)
				}
			} else {
				// The prefixes, from every expression down to none.
				for size := len(positions); size >= 0; size -= 1 {
					set := make([dynamic]int, 0, size, p.alloc)
					append(&set, ..positions[:size])
					append(&produced, set)
				}
			}
			current = group_sets_multiply(current, produced, p.alloc)
			if !p_match_punct(p, ",") do break
			continue
		}
		if p_is_keyword(p, "grouping") && p_next_is(p, "sets") {
			grouping = true
			p_advance(p)
			p_advance(p)
			p_expect_punct(p, "(")
			produced := make([dynamic][dynamic]int, 0, 4, p.alloc)
			for {
				set := make([dynamic]int, 0, 2, p.alloc)
				if p_match_punct(p, "(") {
					// `(a, b)` is one set; `()` is the empty one.
					if !p_match_punct(p, ")") {
						for {
							append(&set, group_expression_add(p, &groups, parse_expression(p)))
							if !p_match_punct(p, ",") do break
						}
						p_expect_punct(p, ")")
					}
				} else {
					append(&set, group_expression_add(p, &groups, parse_expression(p)))
				}
				append(&produced, set)
				if !p_match_punct(p, ",") do break
			}
			p_expect_punct(p, ")")
			current = group_sets_multiply(current, produced, p.alloc)
			if !p_match_punct(p, ",") do break
			continue
		}
		index := group_expression_add(p, &groups, parse_expression(p))
		for k in 0 ..< len(current) do append(&current[k], index)
		if !p_match_punct(p, ",") do break
	}
	select.group_by = groups[:]
	if !grouping do return
	sets := make([][]int, len(current), p.alloc)
	for set, k in current do sets[k] = set[:]
	select.group_sets = sets
}

// group_sets_multiply crosses the sets gathered so far with the ones a construct
// produced.
@(private)
group_sets_multiply :: proc(
	current: [dynamic][dynamic]int,
	produced: [dynamic][dynamic]int,
	alloc: mem.Allocator,
) -> [dynamic][dynamic]int {
	out := make([dynamic][dynamic]int, 0, len(current) * len(produced), alloc)
	for left in current {
		for right in produced {
			merged := make([dynamic]int, 0, len(left) + len(right), alloc)
			append(&merged, ..left[:])
			append(&merged, ..right[:])
			append(&out, merged)
		}
	}
	return out
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
	// ALTER [COLUMN] name [SET DATA] TYPE type. SQLite has no such statement (it
	// asks for a table rebuild), Standard SQL spells it `SET DATA TYPE` and
	// PostgreSQL spells it `TYPE`; both are accepted rather than one of them.
	if p_match_keyword(p, "alter") {
		p_match_keyword(p, "column")
		stmt.alter_column = p_ident(p)
		if !p_match_keyword(p, "type") {
			p_match_keyword(p, "set")
			p_match_keyword(p, "data")
			p_expect_keyword(p, "type")
		}
		type_name := p_ident_or_keyword(p)
		kind, width, type_ok := type_kind_from_name(type_name)
		if !type_ok {
			p_fail(p, .Sql_Syntax, "unknown column type %q", type_name)
			return stmt
		}
		stmt.alter_type = Column_Type{kind = kind, width = width}
		return stmt
	}
	if p_expect_keyword(p, "add") == false do return stmt
	p_match_keyword(p, "column")
	stmt.column.name = p_ident(p)
	p.object_start = p.ident_start
	// The type may be absent, or any words SQLite reads by affinity.
	type_start := p.prev_end
	words := make([dynamic]string, 0, 2, context.temp_allocator)
	for (p.current.kind == .Ident || p.current.kind == .Quoted_Ident) && !p_column_constraint_ahead(p) {
		append(&words, p.current.text)
		p_advance(p)
	}
	if len(words) > 0 && p_match_punct(p, "(") {
		for !p_is_punct(p, ")") && p.current.kind != .EOF do p_advance(p)
		p_expect_punct(p, ")")
	}
	if len(words) > 0 do stmt.add_declared = p_text_since(p, type_start)
	if len(words) == 1 {
		if kind, width, type_ok := type_kind_from_name(words[0]); type_ok {
			stmt.column.type = Column_Type{kind = kind, width = width}
		} else {
			stmt.column.type = sqlite_affinity_type(words[0])
		}
	} else {
		stmt.column.type = sqlite_affinity_type(strings.join(words[:], " ", context.temp_allocator))
	}
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
	windows_mark := len(p.windows)
	p_expect_keyword(p, "select")
	if p_match_keyword(p, "distinct") do select.is_distinct = true
	projections := make([dynamic]Select_Item, 0, 4, p.alloc)
	for {
		item: Select_Item
		if p_is_punct(p, "*") {
			p_advance(p)
			item.star = true
		} else {
			start := p.prev_end
			item.expr = parse_expression(p)
			item.text = p_text_since(p, start)
		}
		// `*` and `t.*` take no alias, as in SQLite: `SELECT * FRM t` fails at
		// FRM rather than naming the star.
		star_expr := false
		if item.expr != nil do _, star_expr = item.expr^.(Star_Expr)
		if item.star || star_expr {
		} else if p_match_keyword(p, "as") {
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
			kind := Join_Kind.Inner
			natural := false
			if p_match_keyword(p, "inner") {
				if !p_expect_keyword(p, "join") do break
			} else if p_is_keyword(p, "left") || p_is_keyword(p, "right") || p_is_keyword(p, "full") {
				switch {
				case strings.equal_fold(p.current.text, "left"):
					kind = .Left
				case strings.equal_fold(p.current.text, "right"):
					kind = .Right
				case:
					kind = .Full
				}
				p_advance(p)
				p_match_keyword(p, "outer")
				if !p_expect_keyword(p, "join") do break
			} else if p_is_keyword(p, "cross") {
				p_advance(p)
				kind = .Cross
				if !p_expect_keyword(p, "join") do break
			} else if p_match_keyword(p, "natural") {
				// NATURAL [LEFT | RIGHT | FULL | INNER] JOIN: the columns come when
				// the tables are known.
				natural = true
				if p_match_keyword(p, "left") {
					kind = .Left
				} else if p_match_keyword(p, "right") {
					kind = .Right
				} else if p_match_keyword(p, "full") {
					kind = .Full
				} else {
					_ = p_match_keyword(p, "inner")
				}
				if kind != .Inner do p_match_keyword(p, "outer")
				if !p_expect_keyword(p, "join") do break
			} else if !p_match_keyword(p, "join") {
				break
			}
			join: Join_Clause
			join.kind = kind
			join.natural = natural
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
		parse_group_by(p, &select)
	}
	if p_match_keyword(p, "having") {
		select.having = parse_expression(p)
	}
	// WINDOW name AS (spec), ...: windows the calls of this select name.
	definitions := make([dynamic]Window_Definition, 0, 0, p.alloc)
	if p_match_keyword(p, "window") {
		for p.err.kind == .None {
			definition: Window_Definition
			definition.name = p_ident(p)
			p_expect_keyword(p, "as")
			p_expect_punct(p, "(")
			if base := parse_window_spec(p, &definition.spec); len(base) > 0 {
				// A definition may build on one defined before it.
				_ = window_chain(p, &definition.spec, base, true, definitions[:])
			}
			append(&definitions, definition)
			if !p_match_punct(p, ",") do break
		}
	}
	if p_match_keyword(p, "order") {
		p_expect_keyword(p, "by")
		select.order_by = parse_order_items(p)
	}
	// The windows of this select's projection, HAVING and ORDER BY take their
	// definitions; a subquery's were resolved by its own select.
	for i in windows_mark ..< len(p.windows) {
		if p.err.kind != .None do break
		pending := p.windows[i]
		if window, is_window := &pending.expr.(Window_Expr); is_window {
			_ = window_chain(p, window, pending.base, pending.parenthesized, definitions[:])
		}
	}
	resize(&p.windows, windows_mark)
	if p_match_keyword(p, "limit") {
		select.limit = parse_expression(p)
		// SQLite's `LIMIT <offset>, <count>`: the first number is the offset.
		if p_match_punct(p, ",") {
			select.offset = select.limit
			select.limit = parse_expression(p)
		}
	}
	if select.offset == nil && p_match_keyword(p, "offset") {
		select.offset = parse_expression(p)
	}
	// UNION [ALL | DISTINCT], INTERSECT and EXCEPT chain more terms, applied left
	// to right. ORDER BY, LIMIT and OFFSET of any term apply to the compound as a
	// whole, so they move to this select.
	parts := make([dynamic]Compound_Select, 0, 2, p.alloc)
	for {
		op: Compound_Op
		all := false
		if p_match_keyword(p, "union") {
			all = p_match_keyword(p, "all")
			if !all do p_match_keyword(p, "distinct")
			op = all ? .Union_All : .Union
		} else if p_match_keyword(p, "intersect") {
			op = .Intersect
		} else if p_match_keyword(p, "except") {
			op = .Except
		} else {
			break
		}
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
		append(&parts, Compound_Select{all = all, op = op, select_stmt = select_stmt})
		for extra in inner do append(&parts, extra)
	}
	select.compound = parts[:]
return select
}

// parse_fk_clauses reads what may follow REFERENCES t (cols): ON DELETE / ON
// UPDATE actions, MATCH (accepted; SQLite ignores it too) and the deferral.
@(private)
parse_fk_clauses :: proc(p: ^Parser) -> (on_delete, on_update: Foreign_Key_Action, deferred: bool) {
	for {
		if p_match_keyword(p, "on") {
			if p_match_keyword(p, "delete") {
				on_delete = parse_fk_action(p)
			} else if p_match_keyword(p, "update") {
				on_update = parse_fk_action(p)
			} else {
				p_fail(p, .Sql_Syntax, "expected DELETE or UPDATE after ON")
				return
			}
			continue
		}
		if p_match_keyword(p, "match") {
			p_ident(p)
			continue
		}
		break
	}
	// [NOT] DEFERRABLE [INITIALLY DEFERRED | INITIALLY IMMEDIATE]
	not_deferrable := false
	if p_is_keyword(p, "not") {
		p_advance(p)
		if !p_expect_keyword(p, "deferrable") do return
		not_deferrable = true
	} else if !p_match_keyword(p, "deferrable") {
		return
	}
	if p_match_keyword(p, "initially") {
		if p_match_keyword(p, "deferred") {
			deferred = !not_deferrable
		} else {
			p_expect_keyword(p, "immediate")
		}
	}
	return
}

// p_conflict_clause reads a constraint's `ON CONFLICT <resolution>`, which
// decides what a row that breaks it does when the statement names none.
@(private)
p_conflict_clause :: proc(p: ^Parser) -> Conflict_Resolution {
	if !p_match_keyword(p, "on") do return .Abort
	p_expect_keyword(p, "conflict")
	switch {
	case p_match_keyword(p, "rollback"):
		return .Rollback
	case p_match_keyword(p, "abort"):
		return .Abort
	case p_match_keyword(p, "fail"):
		return .Fail
	case p_match_keyword(p, "ignore"):
		return .Ignore
	case p_match_keyword(p, "replace"):
		return .Replace
	}
	p_fail(p, .Sql_Syntax, "expected ROLLBACK, ABORT, FAIL, IGNORE or REPLACE after ON CONFLICT")
	return .Abort
}

// parse_values_select reads `VALUES (a, b), (c, d)` as the query SQLite makes of
// it: one row per tuple, columns named column1, column2, …, and every tuple the
// same width.
@(private)
parse_values_select :: proc(p: ^Parser) -> Select_Stmt {
	p_expect_keyword(p, "values")
	first: Select_Stmt
	parts := make([dynamic]Compound_Select, 0, 2, p.alloc)
	width := -1
	for row := 0; ; row += 1 {
		if !p_expect_punct(p, "(") do break
		items := make([dynamic]Select_Item, 0, 4, p.alloc)
		for {
			item := Select_Item{expr = parse_expression(p)}
			if row == 0 do item.alias = fmt.aprintf("column%d", len(items) + 1, allocator = p.alloc)
			append(&items, item)
			if !p_match_punct(p, ",") do break
		}
		p_expect_punct(p, ")")
		if width < 0 do width = len(items)
		if len(items) != width {
			p_fail(p, .Sql_Syntax, "all VALUES must have the same number of terms")
			break
		}
		if row == 0 {
			first.projections = items[:]
		} else {
			append(&parts, Compound_Select{all = true, op = .Union_All, select_stmt = Select_Stmt{projections = items[:]}})
		}
		if !p_match_punct(p, ",") do break
	}
	first.compound = parts[:]
	return first
}

// parse_nulls_order reads an optional NULLS FIRST / NULLS LAST.
@(private)
parse_nulls_order :: proc(p: ^Parser) -> Nulls_Order {
	if !p_match_keyword(p, "nulls") do return .Default
	if p_match_keyword(p, "first") do return .First
	if p_match_keyword(p, "last") do return .Last
	p_fail(p, .Sql_Syntax, "expected FIRST or LAST after NULLS")
	return .Default
}

@(private)
p_is_table_clause_keyword :: proc(p: ^Parser) -> bool {
	if p.current.kind != .Ident do return false
	for keyword in ([]string{"where", "group", "having", "order", "limit", "offset", "join", "inner", "left", "cross", "outer", "natural", "right", "full", "on", "union", "intersect", "except", "using", "set", "values", "returning", "window"}) {
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
	// `LATERAL` may precede a derived table, in the FROM list or after a join: the
	// subquery then reads the rows before it, one evaluation per row.
	if p_match_keyword(p, "lateral") do ref.lateral = true
	// A derived table: `(SELECT …) [AS] name` or `(VALUES …) [AS] name`. SQLite
	// names an unaliased one itself, and so does this.
	if p_match_punct(p, "(") {
		sub := new(Select_Stmt, p.alloc)
		if p_is_keyword(p, "values") {
			sub^ = parse_values_select(p)
		} else if select_stmt, ok := parse_select(p).(Select_Stmt); ok {
			sub^ = select_stmt
		}
		p_expect_punct(p, ")")
		ref.subquery = sub
		p.derived_count += 1
		ref.name = fmt.aprintf("(subquery-%d)", p.derived_count, allocator = p.alloc)
		if p_match_keyword(p, "as") {
			ref.name = p_ident(p)
		} else if (p.current.kind == .Ident || p.current.kind == .Quoted_Ident) && !p_is_table_clause_keyword(p) {
			ref.name = p_ident(p)
		}
		return ref
	}
	ref.name = p_ident(p)
	if p_match_keyword(p, "not") {
		if p_expect_keyword(p, "indexed") == false do return ref
		ref.no_index = true
		return ref
	}
	if p_match_keyword(p, "indexed") {
		if p_expect_keyword(p, "by") == false do return ref
		ref.indexed_by = p_ident(p)
		return ref
	}
	if p_match_punct(p, ".") {
		// schema.table: keep the qualifier, `name` is the table.
		ref.schema = ref.name
		ref.name = p_ident(p)
		// PostgreSQL's schemas: `public` is this database, and the catalog views a
		// client reads (`information_schema.tables`, `pg_catalog.pg_tables`) are
		// system tables built from the live schema. The written name stays the
		// alias so `tables.table_name` still resolves.
		if mapped, is_catalog := pg_catalog_table(ref.schema, ref.name); is_catalog {
			ref.alias = ref.name
			ref.name = mapped
			ref.schema = ""
		}
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

// parse_with_ctes reads the common table expressions after WITH, up to the
// statement they belong to.
@(private)
parse_with_ctes :: proc(p: ^Parser) -> (ctes: []Cte, recursive: bool) {
	if p_match_keyword(p, "recursive") do recursive = true
	list := make([dynamic]Cte, 0, 2, p.alloc)
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
		// SQLite's materialization hints change nothing here.
		if p_match_keyword(p, "not") {
			p_expect_keyword(p, "materialized")
		} else {
			_ = p_match_keyword(p, "materialized")
		}
		p_expect_punct(p, "(")
		if p_is_keyword(p, "values") {
			// A CTE's body may be a VALUES list, its columns named by the CTE.
			cte.select_stmt = parse_values_select(p)
		} else if select_stmt, ok := parse_select(p).(Select_Stmt); ok {
			cte.select_stmt = select_stmt
		}
		p_expect_punct(p, ")")
		append(&list, cte)
		if !p_match_punct(p, ",") || p.err.kind != .None do break
	}
	return list[:], recursive
}

// parse_write_with reads the INSERT, UPDATE or DELETE a WITH prefixes and
// gives it the CTEs. An INSERT whose SELECT has a WITH of its own sees both,
// the outer ones first.
@(private)
parse_write_with :: proc(p: ^Parser, ctes: []Cte, recursive: bool) -> Statement {
	statement: Statement
	if p_is_keyword(p, "update") {
		statement = parse_update(p)
	} else if p_is_keyword(p, "delete") {
		statement = parse_delete(p)
	} else {
		statement = parse_insert(p)
	}
	#partial switch &s in statement {
	case Insert_Stmt:
		inner := s.ctes
		joined := make([]Cte, len(ctes) + len(inner), p.alloc)
		copy(joined, ctes)
		copy(joined[len(ctes):], inner)
		s.ctes = joined
		s.ctes_recursive = s.ctes_recursive || recursive
	case Update_Stmt:
		s.ctes = ctes
		s.ctes_recursive = recursive
	case Delete_Stmt:
		s.ctes = ctes
		s.ctes_recursive = recursive
	}
	return statement
}

@(private)
parse_insert :: proc(p: ^Parser) -> Statement {
	insert: Insert_Stmt
	// `REPLACE INTO` is SQLite's short form of `INSERT OR REPLACE INTO`.
	if p_match_keyword(p, "replace") {
		insert.conflict_replace = true
		insert.conflict_explicit = true
	} else {
		p_expect_keyword(p, "insert")
	}
	// INSERT OR <action> INTO: what a constraint violation does to the statement.
	if !insert.conflict_replace && p_match_keyword(p, "or") {
		insert.conflict_explicit = true
		switch {
		case p_match_keyword(p, "replace"):
			insert.conflict_replace = true
		case p_match_keyword(p, "abort"):
			// The default resolution: the statement is undone, the transaction survives.
		case p_match_keyword(p, "ignore"):
			insert.conflict_ignore = true
		case p_match_keyword(p, "fail"):
			insert.conflict_fail = true
		case p_match_keyword(p, "rollback"):
			insert.conflict_rollback = true
		case:
			p_fail(p, .Sql_Syntax, "expected replace, abort, rollback, fail or ignore after OR")
			return insert
		}
	}
	p_expect_keyword(p, "into")
	insert.table = p_write_target(p)
	if p.err.kind != .None do return insert
	columns := make([dynamic]string, 0, 4, p.alloc)
	if p_match_punct(p, "(") {
		for {
			append(&columns, p_ident(p))
			if !p_match_punct(p, ",") do break
		}
		p_expect_punct(p, ")")
	}
	insert.columns = columns[:]
	// INSERT INTO t WITH c AS (...) SELECT ...: the query has CTEs, which the
	// statement materializes before it writes.
	if p_match_keyword(p, "with") {
		insert.ctes, insert.ctes_recursive = parse_with_ctes(p)
		if !p_is_keyword(p, "select") && !p_is_keyword(p, "values") {
			p_fail(p, .Sql_Syntax, "expected SELECT after WITH, found %s", p.current.text)
			return insert
		}
	}
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
	items := make([dynamic]Select_Item, 0, 2, p.alloc)
	for {
		item: Select_Item
		if p_is_punct(p, "*") {
			p_advance(p)
			item.star = true
		} else {
			start := p.prev_end
			item.expr = parse_expression(p)
			item.text = p_text_since(p, start)
			if p_match_keyword(p, "as") {
				item.alias = p_ident(p)
			} else if (p.current.kind == .Ident || p.current.kind == .Quoted_Ident) && !p_is_clause_keyword(p) {
				item.alias = p_ident(p)
			}
		}
		append(&items, item)
		if !p_match_punct(p, ",") do break
	}
	returning.items = items[:]
	return returning
}

@(private)
parse_update :: proc(p: ^Parser) -> Statement {
	update: Update_Stmt
	p_expect_keyword(p, "update")
	// UPDATE OR <action>: what a row that breaks a constraint does.
	if p_match_keyword(p, "or") {
		update.conflict_explicit = true
		switch {
		case p_match_keyword(p, "abort"):
		case p_match_keyword(p, "fail"):
			update.conflict = .Fail
		case p_match_keyword(p, "ignore"):
			update.conflict = .Ignore
		case p_match_keyword(p, "replace"):
			update.conflict = .Replace
		case p_match_keyword(p, "rollback"):
			update.conflict = .Rollback
		case:
			p_fail(p, .Sql_Syntax, "expected replace, abort, rollback, fail or ignore after OR")
			return update
		}
	}
	update.table = p_write_target(p)
	if p.err.kind != .None do return update
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

// parse_merge reads `MERGE INTO target [AS t] USING source [AS s] ON condition
// WHEN [MATCHED | NOT MATCHED] [AND condition] THEN ...`. The clauses a MERGE
// accepts here are UPDATE, DELETE for a matched row and INSERT for a source row
// that matched nothing.
@(private)
parse_merge :: proc(p: ^Parser) -> Statement {
	p_expect_keyword(p, "merge")
	stmt: Merge_Stmt
	p_match_keyword(p, "into")
	stmt.target = p_ident(p)
	if p_match_keyword(p, "as") do stmt.target_alias = p_ident(p)
	if p_expect_keyword(p, "using") == false do return stmt
	stmt.source = p_ident(p)
	if p_match_keyword(p, "as") do stmt.source_alias = p_ident(p)
	if p_expect_keyword(p, "on") == false do return stmt
	stmt.on = parse_expression(p)
	clauses := make([dynamic]Merge_When, 0, 2, p.alloc)
	for p_match_keyword(p, "when") {
		clause: Merge_When
		if p_match_keyword(p, "matched") {
			if p_match_keyword(p, "and") do clause.condition = parse_expression(p)
			p_expect_keyword(p, "then")
			if p_match_keyword(p, "update") {
				clause.kind = .Matched_Update
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
				clause.assignments = assignments[:]
			} else if p_match_keyword(p, "delete") {
				clause.kind = .Matched_Delete
			} else {
				p_fail(p, .Sql_Syntax, "a matched MERGE row is updated or deleted")
				return stmt
			}
		} else if p_match_keyword(p, "not") {
			if p_expect_keyword(p, "matched") == false do return stmt
			if p_match_keyword(p, "by") {
				p_fail(
					p,
					.Sql_Unsupported,
					"MERGE ... WHEN NOT MATCHED BY SOURCE is not supported",
				)
				return stmt
			}
			clause.kind = .Not_Matched_Insert
			if p_match_keyword(p, "and") do clause.condition = parse_expression(p)
			p_expect_keyword(p, "then")
			p_expect_keyword(p, "insert")
			if p_match_punct(p, "(") {
				columns := make([dynamic]string, 0, 4, p.alloc)
				for {
					append(&columns, p_ident(p))
					if !p_match_punct(p, ",") do break
				}
				p_expect_punct(p, ")")
				clause.columns = columns[:]
			}
			p_expect_keyword(p, "values")
			p_expect_punct(p, "(")
			values := make([dynamic]^Expr, 0, 4, p.alloc)
			for {
				append(&values, parse_expression(p))
				if !p_match_punct(p, ",") do break
			}
			p_expect_punct(p, ")")
			clause.values = values[:]
		} else {
			p_fail(p, .Sql_Syntax, "MERGE needs WHEN MATCHED or WHEN NOT MATCHED")
			return stmt
		}
		append(&clauses, clause)
	}
	if len(clauses) == 0 {
		p_fail(p, .Sql_Syntax, "MERGE needs at least one WHEN clause")
	}
	stmt.clauses = clauses[:]
	return stmt
}

// p_object_name reads the name of a table or an index a statement writes or
// makes. `main.t` and `temp.t` are the database itself (p_ident reads `main.`);
// any other qualifier names an attached database, and the name comes back as
// `schema` ATTACHED_SEPARATOR `t` for the executor to route (attach_split).
@(private)
p_object_name :: proc(p: ^Parser) -> string {
	name := p_ident(p)
	if p.err.kind != .None || !p_is_punct(p, ".") do return name
	p_advance(p)
	table := p_ident(p)
	if strings.equal_fold(name, "temp") do return table
	return strings.concatenate({name, ATTACHED_SEPARATOR, table}, p.alloc)
}

// p_write_target reads the table an INSERT, UPDATE or DELETE writes.
@(private)
p_write_target :: proc(p: ^Parser) -> string {
	return p_object_name(p)
}

@(private)
parse_delete :: proc(p: ^Parser) -> Statement {
	delete_stmt: Delete_Stmt
	p_expect_keyword(p, "delete")
	p_expect_keyword(p, "from")
	delete_stmt.table = p_write_target(p)
	if p.err.kind != .None do return delete_stmt
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
	p.object_start = p.ident_start
	if p_match_keyword(p, "before") {
		stmt.before = true
	} else if p_match_keyword(p, "instead") {
		p_expect_keyword(p, "of")
		stmt.instead = true
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
		if stmt.event != "update" {
			p_fail(p, .Sql_Syntax, "OF names the columns of an UPDATE trigger")
			return stmt
		}
		columns := make([dynamic]string, 0, 2, p.alloc)
		for {
			append(&columns, p_ident(p))
			if !p_match_punct(p, ",") do break
		}
		stmt.columns = columns[:]
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

// p_mark and p_reset remember one token, so a word that is a keyword in one
// place and a column name in another can be tried and put back.
@(private)
p_mark :: proc(p: ^Parser) -> (Lexer, Token) {
	return p.lexer, p.current
}

@(private)
p_reset :: proc(p: ^Parser, lexer: Lexer, token: Token) {
	p.lexer = lexer
	p.current = token
}

// parse_type_ref reads a column type. `builtin` is false when the name is
// unknown, in which case the caller defers to the type catalog.
// p_column_constraint_ahead reports a column constraint where a type could
// be: the column was declared without one.
@(private)
p_column_constraint_ahead :: proc(p: ^Parser) -> bool {
	if p.current.kind != .Ident do return false
	for word in ([]string{"primary", "not", "null", "unique", "check", "default", "collate", "references", "generated", "as", "constraint", "autoincrement"}) {
		if strings.equal_fold(p.current.text, word) do return true
	}
	return false
}

@(private)
parse_type_ref :: proc(p: ^Parser) -> (t: Column_Type, builtin: bool, name: string) {
	t, builtin, name = parse_type_base(p)
	if !builtin do return
	// `TEXT[]` is ARRAY(TEXT). One level: the type record holds one element kind,
	// so an array of arrays is refused rather than stored as something else.
	for p_match_punct(p, "[") {
		p_expect_punct(p, "]")
		if t.kind == .Array {
			p_fail(p, .Sql_Unsupported, "an array of arrays is not supported")
			return
		}
		t = Column_Type{kind = .Array, inner_kind = t.kind, inner_width = t.width}
	}
	return
}

@(private)
parse_type_base :: proc(p: ^Parser) -> (t: Column_Type, builtin: bool, name: string) {
	name = p_ident_or_keyword(p)
	upper := strings.to_upper(name, context.temp_allocator)
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
		p_skip_type_words(p, upper)
		return Column_Type{kind = kind, width = width}, true, name
	}
	if serial_width := pg_serial_width(upper); serial_width > 0 {
		return Column_Type{kind = .Int, width = serial_width}, true, name
	}
	return {}, false, name
}

// p_skip_type_words reads the words that finish a type the SQL standard spells
// in more than one: `DOUBLE PRECISION`, `CHARACTER VARYING`, `TIMESTAMP WITH TIME
// ZONE`, `TIME WITHOUT TIME ZONE`. The words change nothing the engine stores.
@(private)
p_skip_type_words :: proc(p: ^Parser, upper: string) {
	switch upper {
	case "DOUBLE":
		p_match_keyword(p, "precision")
	case "CHARACTER", "CHAR", "NCHAR":
		p_match_keyword(p, "varying")
	case "TIMESTAMP", "TIME", "TIMESTAMPTZ", "TIMETZ":
		if p_is_keyword(p, "with") || p_is_keyword(p, "without") {
			p_advance(p)
			p_expect_keyword(p, "time")
			p_expect_keyword(p, "zone")
		}
	}
}

// pg_serial_width is the integer width a PostgreSQL SERIAL type stands for, or 0
// when the name is not one. SERIAL is an integer column with a sequence behind
// it; the column definition turns the sequence on.
pg_serial_width :: proc(upper: string) -> u8 {
	switch upper {
	case "SMALLSERIAL", "SERIAL2":
		return 2
	case "SERIAL", "SERIAL4", "BIGSERIAL", "SERIAL8":
		return 8
	}
	return 0
}

// parse_cast_target reads the type after `CAST(x AS` or `x::`, with the length or
// precision PostgreSQL and SQLite both allow and ignore: `VARCHAR(20)`,
// `NUMERIC(10, 2)`.
@(private)
parse_cast_target :: proc(p: ^Parser) -> (Column_Type, bool) {
	type_name := p_ident_or_keyword(p)
	p.cast_name = type_name
	upper := strings.to_upper(type_name, context.temp_allocator)
	kind, width, type_ok := type_kind_from_name(type_name)
	if !type_ok {
		if serial := pg_serial_width(upper); serial > 0 {
			kind, width, type_ok = .Int, serial, true
		}
	}
	if !type_ok {
		p_fail(p, .Sql_Syntax, "unknown cast target %q", type_name)
		return {}, false
	}
	p_skip_type_words(p, upper)
	if p_match_punct(p, "(") {
		for !p_is_punct(p, ")") && p.current.kind != .EOF do p_advance(p)
		p_expect_punct(p, ")")
	}
	target := Column_Type{kind = kind, width = width}
	// `::TEXT[]` is a cast to an array, the same spelling a column uses.
	for p_match_punct(p, "[") {
		p_expect_punct(p, "]")
		if target.kind == .Array {
			p_fail(p, .Sql_Unsupported, "an array of arrays is not supported")
			return {}, false
		}
		target = Column_Type{kind = .Array, inner_kind = target.kind, inner_width = target.width}
	}
	return target, true
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
	p.object_start = p.ident_start
	p_expect_keyword(p, "using")
	stmt.module = p_ident(p)
	// Without arguments the module gets none.
	if !p_match_punct(p, "(") do return stmt
	columns := make([dynamic]string, 0, 2, p.alloc)
	arguments := make([dynamic]string, 0, 2, p.alloc)
	// An argument is any text up to a comma outside parentheses, as SQLite
	// passes it; its first word is a column for fts5 and rtree. Options there
	// (tokenize=..., prefix=...) are accepted and ignored: one tokenizer.
	for p.err.kind == .None && p.current.kind != .EOF {
		start := p.prev_end
		depth := 0
		for p.current.kind != .EOF {
			if depth == 0 && (p_is_punct(p, ",") || p_is_punct(p, ")")) do break
			if p_is_punct(p, "(") do depth += 1
			if p_is_punct(p, ")") do depth -= 1
			p_advance(p)
		}
		argument := p_text_since(p, start)
		if len(argument) > 0 {
			append(&arguments, argument)
			first := argument
			if space := strings.index_any(first, " \t\n\r="); space >= 0 do first = first[:space]
			append(&columns, strings.trim(first, "\"`[]'"))
		}
		if p_match_punct(p, ",") do continue
		break
	}
	p_expect_punct(p, ")")
	stmt.columns = columns[:]
	stmt.arguments = arguments[:]
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
	stmt.name = p_object_name(p)
	p.object_start = p.ident_start
	// CREATE TABLE name AS SELECT ...: the columns come from the query.
	if p_match_keyword(p, "as") {
		if !p_is_keyword(p, "select") {
			p_fail(p, .Sql_Syntax, "near \"%s\": syntax error", p.current.text)
			return stmt
		}
		if select_stmt, ok := parse_select(p).(Select_Stmt); ok {
			stmt.as_select = new_clone(select_stmt, p.alloc)
		}
		return stmt
	}
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
			constraint.on_delete, constraint.on_update, constraint.deferred = parse_fk_clauses(p)
			append(&constraints, constraint)
			if !p_match_punct(p, ",") do break
			continue
		}
		if p_match_keyword(p, "check") {
			if !p_is_punct(p, "(") {
				p_fail(p, .Sql_Syntax, "CHECK needs a parenthesized expression")
				break
			}
			append(&constraints, Table_Constraint{name = constraint_name, is_check = true, check_sql = p_capture_paren_source(p)})
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
				// A key column may carry a direction; it orders the key's storage in
				// SQLite and changes no answer, so it is accepted.
				if !p_match_keyword(p, "asc") do p_match_keyword(p, "desc")
				if !p_match_punct(p, ",") do break
			}
			p_expect_punct(p, ")")
			constraint.columns = cols[:]
			constraint.conflict = p_conflict_clause(p)
			if p.err.kind != .None do break
			append(&constraints, constraint)
			if !p_match_punct(p, ",") do break
			continue
		}
		column: Column_Def
		column.name = p_ident(p)
		type_start := p.prev_end
		// A column may have no type at all, as SQLite allows: it then keeps any
		// value as it arrives.
		untyped := p_is_punct(p, ",") || p_is_punct(p, ")") || p_column_constraint_ahead(p)
		parsed, builtin, type_name := Column_Type{kind = .Any}, true, ""
		if !untyped do parsed, builtin, type_name = parse_type_ref(p)
		if !builtin {
			// A type SQLite reads by its words (UNSIGNED BIG INT, VARYING
			// CHARACTER) takes every word up to the length or a constraint.
			words := make([dynamic]string, 0, 3, context.temp_allocator)
			append(&words, type_name)
			for (p.current.kind == .Ident || p.current.kind == .Quoted_Ident) && !p_column_constraint_ahead(p) {
				append(&words, p.current.text)
				p_advance(p)
			}
			if len(words) > 1 do type_name = strings.join(words[:], " ", p.alloc)
		}
		if builtin {
			column.type = parsed
			if pg_serial_width(strings.to_upper(type_name, context.temp_allocator)) > 0 {
				column.autoinc = true
				column.sequence = default_sequence()
			}
		} else {
			// Not a builtin: defer to the type catalog when the statement runs.
			column.type_name = type_name
		}
		if !untyped && p_match_punct(p, "(") {
			// Length or precision is accepted and ignored.
			for !p_is_punct(p, ")") && p.current.kind != .EOF {
				p_advance(p)
			}
			p_expect_punct(p, ")")
		}
		if !untyped do column.declared = p_text_since(p, type_start)
		column_checks := make([dynamic]Check_Constraint, 0, 0, p.alloc)
		pending_name := ""
		for {
			// `CONSTRAINT name` may precede any column constraint; it names a CHECK
			// in error messages and is otherwise only a label.
			if p_match_keyword(p, "constraint") {
				pending_name = p_ident(p)
				continue
			}
			if p_match_keyword(p, "primary") {
				p_expect_keyword(p, "key")
				column.primary = true
				if !p_match_keyword(p, "asc") do p_match_keyword(p, "desc")
				column.primary_conflict = p_conflict_clause(p)
				continue
			}
			if p_match_keyword(p, "check") {
				if !p_is_punct(p, "(") {
					p_fail(p, .Sql_Syntax, "CHECK needs a parenthesized expression")
					break
				}
				append(&column_checks, Check_Constraint{name = pending_name, sql = p_capture_paren_source(p), column = column.name})
				pending_name = ""
				continue
			}
			if p_match_keyword(p, "references") {
				// A column-level foreign key: the same as FOREIGN KEY (column).
				fk: Table_Constraint
				fk.name = pending_name
				pending_name = ""
				fk.is_foreign = true
				cols := make([]string, 1, p.alloc)
				cols[0] = column.name
				fk.columns = cols
				fk.ref_table = p_ident(p)
				if p_match_punct(p, "(") {
					refs := make([dynamic]string, 0, 1, p.alloc)
					for {
						append(&refs, p_ident(p))
						if !p_match_punct(p, ",") do break
					}
					p_expect_punct(p, ")")
					fk.ref_columns = refs[:]
				}
				fk.on_delete, fk.on_update, fk.deferred = parse_fk_clauses(p)
				append(&constraints, fk)
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
				column.unique_conflict = p_conflict_clause(p)
				continue
			}
			if p_match_keyword(p, "not") {
				p_expect_keyword(p, "null")
				column.not_null = true
				column.not_null_conflict = p_conflict_clause(p)
				continue
			}
			if p_match_keyword(p, "null") {
				continue
			}
			if p_match_keyword(p, "default") {
				start := token_offset(p.lexer.src, p.current.line, p.current.column)
				column.default = parse_unary(p)
				end := p.current.kind == .EOF ? len(p.lexer.src) : token_offset(p.lexer.src, p.current.line, p.current.column)
				if start >= 0 && end >= start && end <= len(p.lexer.src) {
					column.default_sql = strings.trim_space(p.lexer.src[start:end])
				}
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
					if !p_match_keyword(p, "always") && p_match_keyword(p, "by") {
						p_expect_keyword(p, "default")
					}
					if !p_expect_keyword(p, "as") do break
				}
				// `GENERATED { ALWAYS | BY DEFAULT } AS IDENTITY` is the standard
				// spelling of an autoincrement column. BY DEFAULT and ALWAYS both
				// give a value when the insert names none; ALWAYS does not refuse an
				// explicit one here.
				if p_match_keyword(p, "identity") {
					column.autoinc = true
					column.sequence = default_sequence()
					if p_match_punct(p, "(") {
						for !p_is_punct(p, ")") && p.current.kind != .EOF do p_advance(p)
						p_expect_punct(p, ")")
					}
					continue
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
		column.checks = column_checks[:]
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
			stmt.without_rowid = true
			_ = p_match_punct(p, ",")
			continue
		}
		if p_match_punct(p, ",") do continue
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

// p_capture_paren_source returns the source text between a `(` and its matching
// `)`, exactly as written: quotes, case and spacing included. A CHECK keeps this
// text, because SQLite's error message quotes it and a quoted identifier has to
// survive being parsed again.
@(private)
p_capture_paren_source :: proc(p: ^Parser) -> string {
	if !p_is_punct(p, "(") do return ""
	open := token_offset(p.lexer.src, p.current.line, p.current.column)
	depth := 0
	for p.current.kind != .EOF {
		if p.current.kind == .Punct && p.current.text == "(" do depth += 1
		if p.current.kind == .Punct && p.current.text == ")" {
			depth -= 1
			if depth == 0 {
				close := token_offset(p.lexer.src, p.current.line, p.current.column)
				p_advance(p)
				if open + 1 > close do return ""
				return strings.clone(strings.trim_space(p.lexer.src[open + 1:close]), p.alloc)
			}
		}
		p_advance(p)
	}
	p_fail(p, .Sql_Syntax, "unbalanced parentheses")
	return ""
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
	stmt.name = p_object_name(p)
	p.object_start = p.ident_start
	p_expect_keyword(p, "on")
	stmt.table = p_ident(p)
	if p_match_keyword(p, "using") {
		method := p_ident_or_keyword(p)
		switch strings.to_upper(method, context.temp_allocator) {
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
	exprs := make([dynamic]string, 0, 2, p.alloc)
	any_expression := false
	for {
		// A key part is a column or an expression. It is parsed as an expression
		// and kept as a column when that is all it is; otherwise its text is kept.
		start := token_offset(p.lexer.src, p.current.line, p.current.column)
		part := parse_expression(p)
		end := p.current.kind == .EOF ? len(p.lexer.src) : token_offset(p.lexer.src, p.current.line, p.current.column)
		if part == nil do return stmt
		if column, is_column := part^.(Column_Expr); is_column && len(column.table) == 0 {
			append(&columns, column.name)
			append(&exprs, "")
		} else {
			append(&columns, "")
			append(&exprs, strings.trim_space(p.lexer.src[start:end]))
			any_expression = true
		}
		// ASC/DESC order an index's storage, which answers no query differently:
		// every ORDER BY is applied by the executor or matched to the walk.
		if !p_match_keyword(p, "asc") do p_match_keyword(p, "desc")
		if !p_match_punct(p, ",") do break
	}
	p_expect_punct(p, ")")
	stmt.columns = columns[:]
	if any_expression do stmt.exprs = exprs[:]
	// A partial index: `WHERE <expression>` to the end of the statement.
	if p_is_keyword(p, "where") {
		p_advance(p)
		start := token_offset(p.lexer.src, p.current.line, p.current.column)
		if parse_expression(p) == nil do return stmt
		end := p.current.kind == .EOF ? len(p.lexer.src) : token_offset(p.lexer.src, p.current.line, p.current.column)
		stmt.where_sql = strings.trim_right(strings.trim_space(p.lexer.src[start:end]), ";")
	}
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
	p.object_start = p.ident_start
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
		stmt.name = p_object_name(p)
		if p_match_keyword(p, "on") do stmt.table = p_ident(p)
		return stmt
	}
	p_expect_keyword(p, "table")
	stmt: Drop_Table_Stmt
	if p_match_keyword(p, "if") {
		p_expect_keyword(p, "exists")
		stmt.if_exists = true
	}
	stmt.name = p_object_name(p)
	return stmt
}

// --- Expressions -----------------------------------------------------------

parse_expression :: proc(p: ^Parser) -> ^Expr {
	// The outermost expression is level one: the check runs before the counter
	// moves, so `MAX_EXPRESSION_DEPTH` nested parentheses parse and one more does
	// not, which is the boundary the test states.
	if p.expression_depth >= MAX_EXPRESSION_DEPTH {
		p_fail(
			p,
			.Sql_Unsupported,
			"expression nests deeper than %d levels",
			MAX_EXPRESSION_DEPTH,
		)
		return nil
	}
	p.expression_depth += 1
	defer p.expression_depth -= 1
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

// p_call2 builds a two-argument call, which is what the array operators parse to.
@(private)
p_call2 :: proc(p: ^Parser, name: string, first, second: ^Expr) -> ^Expr {
	args := make([]^Expr, 2, p.alloc)
	args[0] = first
	args[1] = second
	e := new(Expr, p.alloc)
	e^ = Call_Expr{name = name, args = args}
	return e
}

// p_quantified reads `ANY|SOME|ALL (array)` after a comparison. `x = ANY (a)` is
// "x is one of the elements"; `x <> ALL (a)` is "x is none of them".
@(private)
p_quantified :: proc(p: ^Parser, left: ^Expr, op: Binary_Op) -> ^Expr {
	every := p_is_keyword(p, "all")
	if op == .Eq && every {
		p_fail(p, .Sql_Unsupported, "x = ALL (array) is not supported: write NOT (x <> ANY (array))")
		p_advance(p)
		return left
	}
	if op == .Ne && !every {
		p_fail(p, .Sql_Unsupported, "x <> ANY (array) is not supported: write NOT (x = ALL (array))")
		p_advance(p)
		return left
	}
	p_advance(p)
	p_expect_punct(p, "(")
	operand := parse_expression(p)
	p_expect_punct(p, ")")
	call := p_call2(p, "array_contains", operand, left)
	if every {
		e := new(Expr, p.alloc)
		e^ = Unary_Expr{op = .Not, operand = call}
		return e
	}
	return call
}

// parse_operand parses an additive expression and any COLLATE that follows it.
@(private)
parse_operand :: proc(p: ^Parser) -> ^Expr {
	expr := parse_bitwise(p)
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
		// PostgreSQL's array operators are set relations: contains, is contained
		// by, overlaps. They parse to calls so the expression tree keeps its
		// shape, and so a NULL operand answers NULL like every other operator.
		if p_match_punct(p, "@>") {
			left = p_call2(p, "array_contains", left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "<@") {
			left = p_call2(p, "array_contained", left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "&&") {
			left = p_call2(p, "array_overlap", left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "=") || p_match_punct(p, "==") {
			// `x = ANY (array)` is the quantified comparison; other operators
			// would need a matrix of them, so they are refused with the spelling
			// that works.
			if p_is_keyword(p, "any") || p_is_keyword(p, "some") || p_is_keyword(p, "all") {
				left = p_quantified(p, left, .Eq)
				continue
			}
			left = p_compare(p, .Eq, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "!=") || p_match_punct(p, "<>") {
			if p_is_keyword(p, "all") {
				left = p_quantified(p, left, .Ne)
				continue
			}
			left = p_compare(p, .Ne, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "<=") {
			left = p_compare(p, .Le, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, ">=") {
			left = p_compare(p, .Ge, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, "<") {
			left = p_compare(p, .Lt, left, parse_operand(p))
			continue
		}
		if p_match_punct(p, ">") {
			left = p_compare(p, .Gt, left, parse_operand(p))
			continue
		}
		// SQLite's postfix spellings: `x ISNULL`, `x NOTNULL`, `x NOT NULL`.
		if p_is_keyword(p, "isnull") || p_is_keyword(p, "notnull") {
			negated := p_is_keyword(p, "notnull")
			p_advance(p)
			e := new(Expr, p.alloc)
			e^ = Is_Null_Expr{operand = left, negated = negated}
			left = e
			continue
		}
		if p_is_keyword(p, "not") {
			lexer, token := p_mark(p)
			p_advance(p)
			if p_match_keyword(p, "null") {
				e := new(Expr, p.alloc)
				e^ = Is_Null_Expr{operand = left, negated = true}
				left = e
				continue
			}
			p_reset(p, lexer, token)
		}
		if p_match_keyword(p, "is") {
			negated := p_match_keyword(p, "not")
			if p_match_keyword(p, "null") {
				e := new(Expr, p.alloc)
				e^ = Is_Null_Expr{operand = left, negated = negated}
				left = e
				continue
			}
			// `a IS [NOT] DISTINCT FROM b` is `a IS NOT b` (or `a IS b`) by
			// definition; any other right side is SQLite's null-safe comparison.
			if p_match_keyword(p, "distinct") {
				p_expect_keyword(p, "from")
				negated = !negated
			}
			left = p_compare(p, negated ? .Is_Not : .Is, left, parse_operand(p))
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
			if _, is_row := row_value_items(left); is_row {
				// `(a, b) IN ((1, 2), (3, 4))` is `(a, b) = (1, 2) OR (a, b) = (3, 4)`.
				any: ^Expr
				for item in items {
					term := p_compare(p, .Eq, left, item)
					any = any == nil ? term : expr_binary(p, .Or, any, term)
				}
				if any == nil do any = expr_literal(p, value_bool(false))
				left = negated ? expr_unary(p, .Not, any) : any
				continue
			}
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

// parse_bitwise reads `& | << >>`, which SQLite binds looser than `+` and
// tighter than the comparisons, all at one level, left to right.
@(private)
parse_bitwise :: proc(p: ^Parser) -> ^Expr {
	left := parse_additive(p)
	for {
		if p_match_punct(p, "&") {
			left = expr_binary(p, .Bit_And, left, parse_additive(p))
			continue
		}
		if p_match_punct(p, "|") {
			left = expr_binary(p, .Bit_Or, left, parse_additive(p))
			continue
		}
		if p_match_punct(p, "<<") {
			left = expr_binary(p, .Shift_Left, left, parse_additive(p))
			continue
		}
		if p_match_punct(p, ">>") {
			left = expr_binary(p, .Shift_Right, left, parse_additive(p))
			continue
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
	if p_match_punct(p, "~") {
		return expr_unary(p, .Bit_Not, parse_unary(p))
	}
	expr := parse_primary(p)
	// `x[i]` is PostgreSQL's array element, one-based as in PostgreSQL. It binds
	// like a cast, tighter than any operator.
	for expr != nil && p_match_punct(p, "[") {
		index := parse_expression(p)
		p_expect_punct(p, "]")
		args := make([]^Expr, 2, p.alloc)
		args[0] = expr
		args[1] = index
		e := new(Expr, p.alloc)
		e^ = Call_Expr{name = "array_get", args = args}
		expr = e
	}
	// `x::type` is PostgreSQL's cast. It binds tighter than any operator, so
	// `-1::text` is `-(1::text)` and `a::int + 1` casts `a` alone.
	for expr != nil && p_match_punct(p, "::") {
		target, target_ok := parse_cast_target(p)
		if !target_ok do return nil
		e := new(Expr, p.alloc)
		e^ = Cast_Expr{operand = expr, target = target, type_name = p.cast_name}
		expr = e
	}
	// `json -> path` and `json ->> path` are SQLite's spellings of a JSON lookup:
	// the first answers JSON text, the second the SQL value json_extract gives.
	for expr != nil && (p_is_punct(p, "->") || p_is_punct(p, "->>")) {
		name := p_is_punct(p, "->") ? "json_arrow" : "json_arrow_value"
		p_advance(p)
		path := parse_primary(p)
		args := make([]^Expr, 2, p.alloc)
		args[0] = expr
		args[1] = path
		e := new(Expr, p.alloc)
		e^ = Call_Expr{name = name, args = args}
		expr = e
	}
	return expr
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
		// In the query's arena, like a text literal: in the heap every x'..' stayed.
		bytes := make([]u8, len(token.text) / 2, p.alloc)
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
		// `$1`, `$2`, … are PostgreSQL's numbered parameters: `$n` binds the n-th
		// value, may repeat, and the statement takes as many as the largest n.
		if len(token.text) > 1 && token.text[0] == '$' {
			number, number_ok := strconv.parse_int(token.text[1:], 10)
			if number_ok && number >= 1 {
				p_advance(p)
				e := new(Expr, p.alloc)
				e^ = Param_Expr{index = number - 1}
				p_param_slot(p, number - 1, token.text)
				return e
			}
		}
		// A trigger's RAISE(IGNORE) or RAISE(ABORT | FAIL | ROLLBACK, message). The
		// action is a keyword, not a column, so it is kept as text.
		if p_is_keyword(p, "raise") && p_next_punct(p, "(") {
			p_advance(p)
			p_expect_punct(p, "(")
			action := strings.to_lower(p.current.text, p.alloc)
			if action != "ignore" && action != "rollback" && action != "abort" && action != "fail" {
				p_fail(p, .Sql_Syntax, "near %q: syntax error", p.current.text)
				return nil
			}
			p_advance(p)
			args := make([]^Expr, action == "ignore" ? 1 : 2, p.alloc)
			args[0] = expr_literal(p, value_string(action))
			if action != "ignore" {
				p_expect_punct(p, ",")
				// The message is a string literal, as SQLite's grammar has it.
				if p.current.kind != .String {
					p_fail(p, .Sql_Syntax, "near %q: syntax error", p.current.text)
					return nil
				}
				args[1] = expr_literal(p, value_string(strings.clone(p.current.text, p.alloc)))
				p_advance(p)
				if !p_is_punct(p, ")") {
					p_fail(p, .Sql_Syntax, "near %q: syntax error", p.current.text)
					return nil
				}
			}
			p_expect_punct(p, ")")
			e := new(Expr, p.alloc)
			e^ = Call_Expr{name = RAISE_CALL, args = args}
			return e
		}
		// SQLite's time keywords: the current UTC moment as text, as datetime(),
		// date() and time() of 'now' give it.
		if p_is_keyword(p, "current_timestamp") || p_is_keyword(p, "current_date") || p_is_keyword(p, "current_time") {
			function := "datetime"
			if p_is_keyword(p, "current_date") do function = "date"
			if p_is_keyword(p, "current_time") do function = "time"
			p_advance(p)
			if p_match_punct(p, "(") do p_expect_punct(p, ")")
			args := make([]^Expr, 1, p.alloc)
			args[0] = expr_literal(p, value_string("now"))
			e := new(Expr, p.alloc)
			e^ = Call_Expr{name = function, args = args}
			return e
		}
		// The SQL-standard session values are written without parentheses:
		// `SELECT current_user`. They are calls, not column names.
		if p_is_keyword(p, "current_user") || p_is_keyword(p, "session_user") ||
		   p_is_keyword(p, "current_schema") || p_is_keyword(p, "current_catalog") {
			name := strings.to_lower(p.current.text, p.alloc)
			p_advance(p)
			if p_match_punct(p, "(") do p_expect_punct(p, ")")
			e := new(Expr, p.alloc)
			e^ = Call_Expr{name = name}
			return e
		}
		// `ARRAY[...]` builds an array from its elements. `array` is also a
		// perfectly good column name, so the bracket decides: without one the
		// token is put back and read as a name.
		if p_is_keyword(p, "array") {
			lexer, saved := p_mark(p)
			p_advance(p)
			if p_match_punct(p, "[") {
				items := make([dynamic]^Expr, 0, 2, p.alloc)
				if !p_is_punct(p, "]") {
					for {
						append(&items, parse_expression(p))
						if !p_match_punct(p, ",") do break
					}
				}
				p_expect_punct(p, "]")
				e := new(Expr, p.alloc)
				e^ = Call_Expr{name = "array_make", args = items[:]}
				return e
			}
			p_reset(p, lexer, saved)
		}
		if p_is_keyword(p, "cast") {
			p_advance(p)
			p_expect_punct(p, "(")
			operand := parse_expression(p)
			p_expect_keyword(p, "as")
			target, target_ok := parse_cast_target(p)
			if !target_ok do return nil
			p_expect_punct(p, ")")
			e := new(Expr, p.alloc)
			e^ = Cast_Expr{operand = operand, target = target, type_name = p.cast_name}
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
		// A call has its own frame: its locals would otherwise sit in every
		// level of a nested expression.
		if p_is_punct(p, "(") do return parse_call(p, name)
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
			p_param_slot(p, p.param_count, "")
			return e
		}
		// `?NNN` binds the n-th value; it may repeat, and a bare `?` after it
		// takes the next number, as in SQLite.
		if len(token.text) > 1 && token.text[0] == '?' {
			number, number_ok := strconv.parse_int(token.text[1:], 10)
			if !number_ok || number < 1 || number > SQL_MAX_PARAMETER {
				p_fail(p, .Sql_Syntax, "variable number must be between ?1 and ?%d", SQL_MAX_PARAMETER)
				return nil
			}
			p_advance(p)
			e := new(Expr, p.alloc)
			e^ = Param_Expr{index = number - 1}
			p_param_slot(p, number - 1, token.text)
			return e
		}
		// `:name`, `@name` and `$name` take the next number the first time a name
		// appears and the same number every time after.
		if len(token.text) > 1 && (token.text[0] == ':' || token.text[0] == '@' || token.text[0] == '$') {
			p_advance(p)
			index := p.param_count
			for name, slot in p.param_names {
				if name == token.text {
					index = slot
					break
				}
			}
			e := new(Expr, p.alloc)
			e^ = Param_Expr{index = index}
			p_param_slot(p, index, token.text)
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
			if p_is_punct(p, ",") {
				// A row value, `(a, b)`. Comparisons and IN take it apart into
				// scalar terms; anywhere else it is refused when evaluated.
				items := make([dynamic]^Expr, 0, 2, p.alloc)
				append(&items, inner)
				for p_match_punct(p, ",") do append(&items, parse_expression(p))
				p_expect_punct(p, ")")
				e := new(Expr, p.alloc)
				e^ = Call_Expr{name = ROW_VALUE_CALL, args = items[:]}
				return e
			}
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

// ROW_VALUE_CALL names the node a row value `(a, b)` parses to. It has a space,
// so no function a statement can call has this name.
ROW_VALUE_CALL :: "row value"

// RAISE_CALL names the node a trigger's RAISE(...) parses to; like
// ROW_VALUE_CALL it has a space, so no function a program registers is it.
RAISE_CALL :: "raise action"

row_value_items :: proc(e: ^Expr) -> ([]^Expr, bool) {
	if e == nil do return nil, false
	call, is_call := e^.(Call_Expr)
	if !is_call || call.name != ROW_VALUE_CALL do return nil, false
	return call.args, true
}

// p_compare builds a comparison, taking row values apart into the scalar terms
// SQL defines them by: `(a, b) = (c, d)` is `a = c AND b = d`, `(a, b) < (c, d)`
// is `a < c OR (a = c AND b < d)`, and IS / IS NOT likewise. NULL then behaves as
// it does in SQLite, because it does in each term.
@(private)
p_compare :: proc(p: ^Parser, op: Binary_Op, left, right: ^Expr) -> ^Expr {
	l, left_row := row_value_items(left)
	r, right_row := row_value_items(right)
	if !left_row && !right_row do return expr_binary(p, op, left, right)
	if left_row != right_row || len(l) != len(r) {
		p_fail(p, .Sql_Syntax, "row value misused")
		return nil
	}
	#partial switch op {
	case .Eq, .Is:
		all: ^Expr
		for i in 0 ..< len(l) {
			term := expr_binary(p, op, l[i], r[i])
			all = all == nil ? term : expr_binary(p, .And, all, term)
		}
		return all
	case .Ne, .Is_Not:
		any: ^Expr
		for i in 0 ..< len(l) {
			term := expr_binary(p, op, l[i], r[i])
			any = any == nil ? term : expr_binary(p, .Or, any, term)
		}
		return any
	case .Lt, .Le, .Gt, .Ge:
		// Built from the last column back: the last term uses the operator as
		// written, every earlier one its strict form or equality and the rest.
		strict := op == .Le ? Binary_Op.Lt : op == .Ge ? Binary_Op.Gt : op
		result := expr_binary(p, op, l[len(l) - 1], r[len(r) - 1])
		for i := len(l) - 2; i >= 0; i -= 1 {
			equal_then := expr_binary(p, .And, expr_binary(p, .Eq, l[i], r[i]), result)
			result = expr_binary(p, .Or, expr_binary(p, strict, l[i], r[i]), equal_then)
		}
		return result
	}
	p_fail(p, .Sql_Syntax, "row value misused")
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
	// A chain nests without parentheses: it is held to the same depth as
	// they are, which is also the depth evaluation allows.
	if p.binary_depth == nil do p.binary_depth = make(map[^Expr]int, 16, p.alloc)
	depth := 1 + max(p.binary_depth[left], p.binary_depth[right])
	if p.expression_depth + depth > MAX_EXPRESSION_DEPTH {
		p_fail(p, .Sql_Unsupported, "expression nests deeper than %d levels", MAX_EXPRESSION_DEPTH)
		return nil
	}
	e := new(Expr, p.alloc)
	e^ = Binary_Expr{op = op, left = left, right = right}
	p.binary_depth[e] = depth
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

// Window_Definition is one `name AS (spec)` of a WINDOW clause.
Window_Definition :: struct {
	name: string,
	spec: Window_Expr,
}

// parse_order_items reads the terms of an ORDER BY, after BY.
@(private)
parse_order_items :: proc(p: ^Parser) -> []Order_Item {
	items := make([dynamic]Order_Item, 0, 2, p.alloc)
	for p.err.kind == .None {
		item: Order_Item
		item.expr = parse_expression(p)
		if p_match_keyword(p, "desc") {
			item.descending = true
		} else {
			_ = p_match_keyword(p, "asc")
		}
		item.nulls = parse_nulls_order(p)
		append(&items, item)
		if !p_match_punct(p, ",") do break
	}
	return items[:]
}

// parse_window_spec reads a window's parentheses after the opening one:
// [base] [PARTITION BY ...] [ORDER BY ...] [frame], and the closing one. It
// answers the name of the window it builds on, if any.
@(private)
parse_window_spec :: proc(p: ^Parser, window: ^Window_Expr) -> (base: string) {
	if p.current.kind == .Ident || p.current.kind == .Quoted_Ident {
		is_clause := false
		for keyword in ([]string{"partition", "order", "rows", "range", "groups"}) {
			if p_is_keyword(p, keyword) do is_clause = true
		}
		if !is_clause do base = p_ident(p)
	}
	if p_match_keyword(p, "partition") {
		p_expect_keyword(p, "by")
		parts := make([dynamic]^Expr, 0, 2, p.alloc)
		for p.err.kind == .None {
			append(&parts, parse_expression(p))
			if !p_match_punct(p, ",") do break
		}
		window.partition = parts[:]
	}
	if p_match_keyword(p, "order") {
		p_expect_keyword(p, "by")
		window.order_by = parse_order_items(p)
	}
	// An explicit frame, or the default one when it is absent: from the
	// partition start to the last peer of each row.
	frame: Window_Frame
	if p_match_keyword(p, "rows") {
		frame.has = true
		frame.unit = .Rows
	} else if p_match_keyword(p, "range") {
		frame.has = true
		frame.unit = .Range
	} else if p_match_keyword(p, "groups") {
		frame.has = true
		frame.unit = .Groups
	}
	if frame.has {
		if p_match_keyword(p, "between") {
			frame.start = parse_frame_bound(p)
			p_expect_keyword(p, "and")
			frame.end = parse_frame_bound(p)
		} else {
			frame.start = parse_frame_bound(p)
			frame.end = Frame_Bound{kind = .Current_Row}
		}
		window.frame = frame
	}
	p_expect_punct(p, ")")
	return
}

// window_chain gives a window that names a defined one what it takes from it,
// with SQLite's rules: `OVER name` takes the definition whole; `OVER (name
// ...)` keeps its PARTITION BY, may add an ORDER BY it lacks and a frame, and
// may not build on a definition that has a frame.
@(private)
window_chain :: proc(
	p: ^Parser,
	window: ^Window_Expr,
	name: string,
	parenthesized: bool,
	definitions: []Window_Definition,
) -> bool {
	base: ^Window_Expr
	for &definition in definitions {
		if strings.equal_fold(definition.name, name) do base = &definition.spec
	}
	if base == nil {
		p_fail(p, .Sql_Syntax, "no such window: %s", name)
		return false
	}
	if !parenthesized {
		window.partition = base.partition
		window.order_by = base.order_by
		window.frame = base.frame
		return true
	}
	if len(window.partition) > 0 {
		p_fail(p, .Sql_Syntax, "cannot override PARTITION clause of window: %s", name)
		return false
	}
	if len(window.order_by) > 0 && len(base.order_by) > 0 {
		p_fail(p, .Sql_Syntax, "cannot override ORDER BY clause of window: %s", name)
		return false
	}
	if base.frame.has {
		p_fail(p, .Sql_Syntax, "cannot override frame specification of window: %s", name)
		return false
	}
	window.partition = base.partition
	if len(window.order_by) == 0 do window.order_by = base.order_by
	return true
}

// parse_call reads a function call after its name: the arguments, an
// aggregate's ORDER BY and FILTER, and a window's OVER.
@(private)
parse_call :: #force_no_inline proc(p: ^Parser, name: string) -> ^Expr {
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
		// An aggregate's own ORDER BY: `group_concat(x, ',' ORDER BY y)`.
		if p_match_keyword(p, "order") {
			p_expect_keyword(p, "by")
			call_expr.order_by = parse_order_items(p)
		}
	}
	p_expect_punct(p, ")")
	// FILTER (WHERE ...) only when a parenthesis follows: `filter` is
	// also a name a column or an alias may have.
	if p_is_keyword(p, "filter") {
		lexer, saved := p_mark(p)
		p_advance(p)
		if p_match_punct(p, "(") {
			p_expect_keyword(p, "where")
			call_expr.filter = parse_expression(p)
			p_expect_punct(p, ")")
		} else {
			p_reset(p, lexer, saved)
		}
	}
	if p_match_keyword(p, "over") {
		window := new(Expr, p.alloc)
		window_expr: Window_Expr
		window_expr.name = call_expr.name
		window_expr.args = call_expr.args
		window_expr.star = call_expr.star
		window_expr.is_distinct = call_expr.is_distinct
		window_expr.filter = call_expr.filter
		if len(call_expr.order_by) > 0 {
			p_fail(p, .Sql_Syntax, "ORDER BY may not be used with window function %s()", call_expr.name)
			return nil
		}
		if !p_is_punct(p, "(") {
			// OVER name: a window of the WINDOW clause, whole.
			base := p_ident(p)
			window^ = window_expr
			append(&p.windows, Pending_Window{expr = window, base = base})
			return window
		}
		p_expect_punct(p, "(")
		base := parse_window_spec(p, &window_expr)
		window^ = window_expr
		if len(base) > 0 do append(&p.windows, Pending_Window{expr = window, base = base, parenthesized = true})
		return window
	}
	call^ = call_expr
	return call
}
