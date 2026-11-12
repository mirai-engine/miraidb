package engine

import "core:mem"
import "core:mem/virtual"

// --- Expressions -----------------------------------------------------------

Binary_Op :: enum u8 {
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
	And,
	Or,
	Concat,
}

Unary_Op :: enum u8 {
	Neg,
	Plus,
	Not,
}

Expr :: union {
	Literal_Expr,
	Column_Expr,
	Star_Expr,
	Binary_Expr,
	Unary_Expr,
	Is_Null_Expr,
	Between_Expr,
	In_Expr,
	Call_Expr,
	Like_Expr,
	Match_Expr,
	Cast_Expr,
	Param_Expr,
	Subquery_Expr,
	Collate_Expr,
	Window_Expr,
}

// Window_Expr is a function call with an OVER clause. It cannot be evaluated
// row by row: it reads its whole partition, so the executor computes it after
// every row exists.
// Frame_Bound_Kind names one end of a window frame.
Frame_Bound_Kind :: enum u8 {
	Unbounded_Preceding,
	Preceding,
	Current_Row,
	Following,
	Unbounded_Following,
}

// Frame_Bound is one end of `ROWS BETWEEN ... AND ...`; `offset` is the row
// count of a PRECEDING/FOLLOWING bound and nil for the others.
Frame_Bound :: struct {
	kind:   Frame_Bound_Kind,
	offset: ^Expr,
}

// Window_Frame is an explicit frame over rows. Without one the engine keeps the
// default: from the partition start to the last peer of the row.
Window_Frame :: struct {
	has:   bool,
	start: Frame_Bound,
	end:   Frame_Bound,
}

Window_Expr :: struct {
	name:      string,
	args:      []^Expr,
	star:      bool,
	partition: []^Expr,
	order_by:  []Order_Item,
	frame:     Window_Frame,
}

// Collate_Expr attaches a collation to an operand. It changes how comparisons
// treat text; the value itself passes through unchanged.
Collate_Expr :: struct {
	operand: ^Expr,
	name:    string,
}

Literal_Expr :: struct {
	value: Value,
}

Column_Expr :: struct {
	table: string,
	name:  string,
}

Star_Expr :: struct {
	table: string,
}

Binary_Expr :: struct {
	op:    Binary_Op,
	left:  ^Expr,
	right: ^Expr,
}

Unary_Expr :: struct {
	op:      Unary_Op,
	operand: ^Expr,
}

Is_Null_Expr :: struct {
	operand: ^Expr,
	negated: bool,
}

Between_Expr :: struct {
	operand: ^Expr,
	low:     ^Expr,
	high:    ^Expr,
	negated: bool,
}

In_Expr :: struct {
	operand:  ^Expr,
	items:    []^Expr,
	subquery: ^Select_Stmt,
	negated:  bool,
}

// Subquery_Expr is a parenthesized SELECT in expression position: a scalar
// subquery, or an EXISTS test when `exists` is set.
Subquery_Expr :: struct {
	select: ^Select_Stmt,
	exists: bool,
}

Call_Expr :: struct {
	name:        string,
	args:        []^Expr,
	star:        bool,
	is_distinct: bool,
}

Like_Expr :: struct {
	operand:          ^Expr,
	pattern:          ^Expr,
	negated:          bool,
	case_insensitive: bool,
	// glob switches the operator to SQLite's GLOB: case sensitive, with * and ?
	// wildcards and [...] character classes.
	glob:             bool,
	escape:           u8,
}

// Match_Expr is `table MATCH 'query'` over a full-text table. The left side
// names the table, not a column: the row's own id decides the answer.
Match_Expr :: struct {
	operand: ^Expr,
	pattern: ^Expr,
}

Cast_Expr :: struct {
	operand: ^Expr,
	target:  Column_Type,
}

// Param_Expr is a positional bind parameter (`?`). Indexes start at zero in
// the order the placeholders appear in the statement.
Param_Expr :: struct {
	index: int,
}

// --- Statements ------------------------------------------------------------

Select_Item :: struct {
	expr:  ^Expr,
	alias: string,
	star:  bool,
}

Order_Item :: struct {
	expr:       ^Expr,
	descending: bool,
}

Table_Ref :: struct {
	name:  string,
	// schema is the qualifier of `schema.table`: an attached database name.
	schema: string,
	alias: string,
	// args are the view parameters: `FROM v(1, 2)` binds them to the view's `?`.
	args:  []^Expr,
	// as_of is `FROM t AS OF <seq>`: read the rows as they were at that commit.
	// The scan then uses the versions the table keeps instead of the live rows.
	as_of: ^Expr,
}

// Join_Clause chains one table onto the query. `left` turns the inner join into
// a left outer join, and `on` is the join predicate (nil for a cross join).
Join_Clause :: struct {
	table: Table_Ref,
	left:  bool,
	on:    ^Expr,
}

Select_Stmt :: struct {
	is_distinct: bool,
	projections: []Select_Item,
	from:        Table_Ref,
	joins:       []Join_Clause,
	where_clause: ^Expr,
	group_by:    []^Expr,
	having:      ^Expr,
	order_by:    []Order_Item,
	limit:       ^Expr,
	offset:      ^Expr,
	// compound holds the UNION [ALL] terms that follow this select.
	compound:    []Compound_Select,
}

// Compound_Select is one term of a compound query. `all` keeps duplicates.
Compound_Select :: struct {
	all:         bool,
	select_stmt: Select_Stmt,
}

Insert_Stmt :: struct {
	table:     string,
	columns:   []string,
	rows:      [][]^Expr,
	// INSERT ... SELECT: the source query, when has_select is set.
	select_stmt: Select_Stmt,
	has_select:  bool,
	returning: ^Returning,
	// UPSERT: DO NOTHING, or DO UPDATE SET over the conflicting row.
	conflict_do_nothing: bool,
	conflict_assignments: []Assignment,
}

// Returning lists the rows a mutation reports back: every column with `*`, or
// the named columns in the requested order.
Returning :: struct {
	star:    bool,
	columns: []string,
}

Assignment :: struct {
	column: string,
	value:  ^Expr,
}

Update_Stmt :: struct {
	table:        string,
	assignments:  []Assignment,
	where_clause: ^Expr,
	// from is the UPDATE ... FROM source, joined to the target for the WHERE and
	// the assignments.
	from:         Table_Ref,
	returning:    ^Returning,
}

Delete_Stmt :: struct {
	table:        string,
	where_clause: ^Expr,
	// using is the DELETE ... USING source, joined to the target for the WHERE.
	using_ref:    Table_Ref,
	returning:    ^Returning,
}

Column_Def :: struct {
	name:      string,
	type:      Column_Type,
	// type_name holds a named type when it is not a builtin; it is resolved
	// against the type catalog when the statement runs.
	type_name: string,
	primary: bool,
	unique:  bool,
	not_null: bool,
	autoinc:  bool,
	sequence: Sequence,
	// collation is the column's declared COLLATE, if any.
	collation: string,
	// generated marks a GENERATED ALWAYS AS (expr) column; the expression is
	// kept as SQL text and evaluated when a row is written.
	generated:     bool,
	generated_sql: string,
	default:  ^Expr,
}

// Table_Constraint is a table-level PRIMARY KEY or UNIQUE clause. Columns are
// names at parse time and positions once the statement runs.
Table_Constraint :: struct {
	primary: bool,
	name:    string,
	columns: []string,
	// foreign keys use the reference fields instead of `primary`.
	is_foreign:  bool,
	ref_table:   string,
	ref_columns: []string,
	on_delete:   Foreign_Key_Action,
	on_update:   Foreign_Key_Action,
}

Create_Type_Stmt :: struct {
	name:          string,
	base:          Column_Type,
	if_not_exists: bool,
}

Alter_Table_Stmt :: struct {
	rename_to: string,
	// rename_column is the old name of `rename_to` when the statement renames a
	// column instead of the table.
	rename_column: string,
	drop_column:   string,
	table:  string,
	column: Column,
}

Create_Table_Stmt :: struct {
	// strict records the STRICT table option; the engine already enforces the
	// declared types, so it changes nothing at run time.
	strict: bool,
	name:          string,
	if_not_exists: bool,
	ephemeral:     bool,
	event:         bool,
	columns:       []Column_Def,
	constraints:   []Table_Constraint,
}

Drop_Table_Stmt :: struct {
	name:     string,
	if_exists: bool,
}

Create_Index_Stmt :: struct {
	name:          string,
	table:         string,
	columns:       []string,
	unique:        bool,
	algorithm:     Index_Algorithm,
	if_not_exists: bool,
}

Drop_Index_Stmt :: struct {
	name:     string,
	table:    string,
	if_exists: bool,
}

Begin_Stmt :: struct {}
Commit_Stmt :: struct {}
Rollback_Stmt :: struct {}

// Cte is one common table expression: a named query the statement can read as
// if it were a table.
Cte :: struct {
	name:        string,
	columns:     []string,
	select_stmt: Select_Stmt,
}

// With_Stmt prefixes a query with its common table expressions.
With_Stmt :: struct {
	recursive:   bool,
	ctes:        []Cte,
	select_stmt: Select_Stmt,
}

// Savepoint_Kind distinguishes the three savepoint statements: SAVEPOINT sets
// one, RELEASE drops it with the ones nested inside it, and ROLLBACK TO undoes
// the work staged after it while keeping it active.
Savepoint_Kind :: enum {
	Set,
	Release,
	Rollback_To,
}

Savepoint_Stmt :: struct {
	name: string,
	kind: Savepoint_Kind,
}

Set_Stmt :: struct {
	name:  string,
	value: ^Expr,
}

Show_Stmt :: struct {
	name: string,
}

Explain_Stmt :: struct {
	inner: ^Statement,
}

Create_View_Stmt :: struct {
	name:          string,
	sql:           string,
	if_not_exists: bool,
	or_replace:    bool,
}

Drop_View_Stmt :: struct {
	name:      string,
	if_exists: bool,
}

Create_Policy_Stmt :: struct {
	name:       string,
	table:      string,
	using_sql:  string,
	check_sql:  string,
}

Drop_Policy_Stmt :: struct {
	name:      string,
	if_exists: bool,
}

Describe_Stmt :: struct {
	name: string,
}

Truncate_Stmt :: struct {
	name: string,
}

Statement :: union {
	Select_Stmt,
	Insert_Stmt,
	Update_Stmt,
	Delete_Stmt,
	Create_Table_Stmt,
	Alter_Table_Stmt,
	Create_Type_Stmt,
	Drop_Table_Stmt,
	Create_Index_Stmt,
	Drop_Index_Stmt,
	Begin_Stmt,
	Commit_Stmt,
	Rollback_Stmt,
	Savepoint_Stmt,
	With_Stmt,
	Set_Stmt,
	Show_Stmt,
	Explain_Stmt,
	Create_View_Stmt,
	Drop_View_Stmt,
	Create_Policy_Stmt,
	Drop_Policy_Stmt,
	Describe_Stmt,
	Truncate_Stmt,
	Vacuum_Stmt,
	Create_Trigger_Stmt,
	Drop_Trigger_Stmt,
	Create_Virtual_Table_Stmt,
	Load_Extension_Stmt,
	Grant_Stmt,
	Attach_Stmt,
	Detach_Stmt,
}

// Create_Virtual_Table_Stmt is `CREATE VIRTUAL TABLE name USING module(cols)`.
// The module decides what the table is; the columns are the indexed ones.
Create_Virtual_Table_Stmt :: struct {
	name:          string,
	module:        string,
	columns:       []string,
	if_not_exists: bool,
}

// Load_Extension_Stmt is `LOAD EXTENSION name AT 'host:port' [USING reducers]`, or
// its inverse `UNLOAD EXTENSION name`. An extension is a process that speaks the
// wire protocol, not a shared library.
Load_Extension_Stmt :: struct {
	name:     string,
	address:  string,
	reducers: []string,
	unload:   bool,
	if_exists: bool,
}

// Attach_Stmt makes a second database readable as `name.table`. Attached
// databases are read-only and their catalog entry lives in `_attach`.
Attach_Stmt :: struct {
	path: string,
	name: string,
}

Detach_Stmt :: struct {
	name: string,
}

// Grant_Stmt covers GRANT and REVOKE in both their shapes: a role granted to an
// identity (no table), or a table permission granted to a role.
Grant_Stmt :: struct {
	action:   string,
	table:    string,
	role:     string,
	identity: string,
	revoke:   bool,
}

// Create_Trigger_Stmt stores an AFTER trigger: its body runs once per row the
// event touches, with NEW and OLD bound to the row.
Create_Trigger_Stmt :: struct {
	name:          string,
	table:         string,
	event:         string, // insert | update | delete
	before:        bool,
	body:          string,
	// when_text is the optional WHEN expression, kept as text and parsed when
	// the trigger fires with NEW and OLD in scope.
	when_text:     string,
	if_not_exists: bool,
}

Drop_Trigger_Stmt :: struct {
	name:      string,
	if_exists: bool,
}

// Vacuum_Stmt rebuilds the database. With a path, it writes a compacted copy
// there instead of rewriting the live log.
Vacuum_Stmt :: struct {
	path: string,
}

// Query owns the memory of one parsed statement. Destroy it when done.
Query :: struct {
	arena:     virtual.Arena,
	alloc:     mem.Allocator,
	statement: Statement,
	source:    string,
}

query_destroy :: proc(q: ^Query) {
	virtual.arena_destroy(&q.arena)
	q^ = {}
}

// statement_name is the leading keyword of a statement, used by the CLI and by
// the error messages.
statement_name :: proc(statement: Statement) -> string {
	switch s in statement {
	case Select_Stmt:
		return "SELECT"
	case Insert_Stmt:
		return "INSERT"
	case Update_Stmt:
		return "UPDATE"
	case Delete_Stmt:
		return "DELETE"
	case Create_Table_Stmt:
		return "CREATE TABLE"
	case Alter_Table_Stmt:
		return "ALTER TABLE"
	case Create_Type_Stmt:
		return "CREATE TYPE"
	case Drop_Table_Stmt:
		return "DROP TABLE"
	case Create_Index_Stmt:
		return "CREATE INDEX"
	case Drop_Index_Stmt:
		return "DROP INDEX"
	case Begin_Stmt:
		return "BEGIN"
	case Commit_Stmt:
		return "COMMIT"
	case Rollback_Stmt:
		return "ROLLBACK"
	case Savepoint_Stmt:
		return "SAVEPOINT"
	case With_Stmt:
		return "WITH"
	case Set_Stmt:
		return "SET"
	case Show_Stmt:
		return "SHOW"
	case Explain_Stmt:
		return "EXPLAIN"
	case Create_View_Stmt:
		return "CREATE VIEW"
	case Drop_View_Stmt:
		return "DROP VIEW"
	case Create_Policy_Stmt:
		return "CREATE POLICY"
	case Drop_Policy_Stmt:
		return "DROP POLICY"
	case Describe_Stmt:
		return "DESCRIBE"
	case Truncate_Stmt:
		return "TRUNCATE"
	case Vacuum_Stmt:
		return "VACUUM"
	case Create_Trigger_Stmt:
		return "CREATE TRIGGER"
	case Drop_Trigger_Stmt:
		return "DROP TRIGGER"
	case Create_Virtual_Table_Stmt:
		return "CREATE VIRTUAL TABLE"
	case Load_Extension_Stmt:
		return "LOAD EXTENSION"
	case Grant_Stmt:
		return "GRANT"
	case Attach_Stmt:
		return "ATTACH"
	case Detach_Stmt:
		return "DETACH"
	}
	return "UNKNOWN"
}


