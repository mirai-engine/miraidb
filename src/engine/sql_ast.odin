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
	// Is and Is_Not compare with NULL as an ordinary value: `NULL IS NULL` is true
	// and `1 IS NOT NULL` is true, where `=` would answer NULL. `IS [NOT] DISTINCT
	// FROM` parses to them.
	Is,
	Is_Not,
	// The bitwise operators work on 64-bit integers, as SQLite's do.
	Bit_And,
	Bit_Or,
	Shift_Left,
	Shift_Right,
}

Unary_Op :: enum u8 {
	Neg,
	Plus,
	Not,
	Bit_Not,
}

// MAX_EXPRESSION_DEPTH bounds how deeply an expression may nest. Parsing and
// evaluating are both recursive, so depth is stack: measured on a release build,
// this engine dies at 166 nested parentheses, 178 terms in one `+` chain and 155
// nested `CASE`s, and it dies by overflow (the process disappears) rather than
// answering an error. 100 leaves the margin and is the number both the parser and
// the evaluator enforce, so a tree built by a path that skipped the parser (a
// stored view, a generated column) is refused rather than trusted.
MAX_EXPRESSION_DEPTH :: 100

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
	Case_Expr,
}

// Case_Expr is CASE [operand] WHEN ... THEN ... [ELSE ...] END. With an operand
// every WHEN is compared against it; without one every WHEN is a condition.
Case_When :: struct {
	condition: ^Expr,
	result:    ^Expr,
}

Case_Expr :: struct {
	operand:  ^Expr,
	branches: []Case_When,
	fallback: ^Expr,
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

// Frame_Unit says what a frame counts: rows, peer groups, or a range of the
// ORDER BY value.
Frame_Unit :: enum u8 {
	Rows,
	Groups,
	Range,
}

// Window_Frame is an explicit frame. Without one the engine keeps the default:
// from the partition start to the last peer of the row, which is `RANGE UNBOUNDED
// PRECEDING AND CURRENT ROW`.
Window_Frame :: struct {
	has:   bool,
	unit:  Frame_Unit,
	start: Frame_Bound,
	end:   Frame_Bound,
}

Window_Expr :: struct {
	name:      string,
	args:      []^Expr,
	star:      bool,
	// is_distinct records `count(DISTINCT x) OVER (…)`. It was parsed and dropped,
	// so the window counted every row while the same call without OVER counted the
	// distinct ones.
	is_distinct: bool,
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
	// text is the expression as the statement wrote it, which is what SQLite
	// names an unaliased expression column.
	text:  string,
}

// Nulls_Order is an explicit NULLS FIRST / NULLS LAST. Without one NULL sorts as
// the smallest value: first ascending, last descending, as in SQLite.
Nulls_Order :: enum u8 {
	Default,
	First,
	Last,
}

Order_Item :: struct {
	expr:       ^Expr,
	descending: bool,
	nulls:      Nulls_Order,
}

Table_Ref :: struct {
	// lateral marks a derived table that may read the row before it: it is
	// evaluated once per row of the sources to its left, not once per statement.
	lateral:   bool,
	name:  string,
	// schema is the qualifier of `schema.table`: an attached database name.
	schema: string,
	alias: string,
	// args are the view parameters: `FROM v(1, 2)` binds them to the view's `?`.
	args:  []^Expr,
	// as_of is `FROM t AS OF <seq>`: read the rows as they were at that commit.
	// The scan then uses the versions the table keeps instead of the live rows.
	as_of: ^Expr,
	// subquery is a derived table, `FROM (SELECT …) AS name` or `FROM (VALUES …)`:
	// it is materialized under `name` before the statement reads it.
	subquery: ^Select_Stmt,
	// indexed_by is SQLite's `INDEXED BY name` hint, and no_index its `NOT
	// INDEXED`: the name is checked against the table's indexes and the plan is
	// left to the planner, which already prices every step.
	indexed_by: string,
	no_index:   bool,
}

// Join_Clause chains one table onto the query. `left` turns the inner join into
// a left outer join, and `on` is the join predicate (nil for a cross join).
// Join_Kind is which rows a join keeps when nothing matches.
Join_Kind :: enum u8 {
	Inner,
	Left,
	Right,
	Full,
	Cross,
}

Join_Clause :: struct {
	table: Table_Ref,
	kind:  Join_Kind,
	on:    ^Expr,
	// using_columns holds the columns of `JOIN ... USING (a, b)`. They are also
	// turned into the equality in `on`, so the rest of the engine sees one
	// condition; the list stays because `SELECT *` prints a merged column once, as
	// SQL says.
	using_columns: []string,
}

Select_Stmt :: struct {
	is_distinct: bool,
	projections: []Select_Item,
	from:        Table_Ref,
	joins:       []Join_Clause,
	where_clause: ^Expr,
	group_by:    []^Expr,
	// group_sets is what a ROLLUP, CUBE or GROUPING SETS asks for: one entry per
	// set, each listing the positions in `group_by` it groups by. Empty means the
	// clause was a plain list, which is one set with every expression.
	group_sets:  [][]int,
	having:      ^Expr,
	order_by:    []Order_Item,
	limit:       ^Expr,
	offset:      ^Expr,
	// compound holds the UNION [ALL] terms that follow this select.
	compound:    []Compound_Select,
}

// Compound_Op joins a term to everything before it, left to right.
Compound_Op :: enum u8 {
	Union,
	Union_All,
	Intersect,
	Except,
}

// Compound_Select is one term of a compound query and the operator that joins
// it to the terms before it. `all` is set for UNION ALL.
Compound_Select :: struct {
	all:         bool,
	op:          Compound_Op,
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
	// INSERT OR REPLACE: the rows the new one collides with are deleted first.
	conflict_replace: bool,
	// INSERT OR IGNORE skips a row that breaks a UNIQUE, PRIMARY KEY, NOT NULL or
	// CHECK constraint. OR FAIL stops at that row and keeps the rows before it.
	// OR ROLLBACK also ends the transaction, which is only possible when the
	// statement owns it.
	conflict_ignore:   bool,
	conflict_fail:     bool,
	conflict_rollback: bool,
	// ctes are the common table expressions of `WITH ... INSERT|UPDATE|DELETE`
	// (and of `INSERT INTO t WITH ... SELECT`), materialized before the write.
	ctes:           []Cte,
	ctes_recursive: bool,
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
	// ctes are the common table expressions of `WITH ... INSERT|UPDATE|DELETE`
	// (and of `INSERT INTO t WITH ... SELECT`), materialized before the write.
	ctes:           []Cte,
	ctes_recursive: bool,
}

// Merge_When_Kind is what one WHEN clause of a MERGE does.
Merge_When_Kind :: enum u8 {
	Matched_Update,
	Matched_Delete,
	Not_Matched_Insert,
}

// Merge_When is one WHEN clause: an optional condition over the two rows, and the
// work it does.
Merge_When :: struct {
	kind:        Merge_When_Kind,
	condition:   ^Expr,
	assignments: []Assignment,
	columns:     []string,
	values:      []^Expr,
}

// Merge_Stmt is `MERGE INTO target AS t USING source AS s ON ... WHEN ...`: one row
// per target that matches the source (updated or deleted) and one per source that
// matches nothing (inserted).
Merge_Stmt :: struct {
	target:       string,
	target_alias: string,
	source:       string,
	source_alias: string,
	on:           ^Expr,
	clauses:      []Merge_When,
}

Delete_Stmt :: struct {
	table:        string,
	where_clause: ^Expr,
	// using is the DELETE ... USING source, joined to the target for the WHERE.
	using_ref:    Table_Ref,
	returning:    ^Returning,
	// ctes are the common table expressions of `WITH ... INSERT|UPDATE|DELETE`
	// (and of `INSERT INTO t WITH ... SELECT`), materialized before the write.
	ctes:           []Cte,
	ctes_recursive: bool,
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
	// default_sql is the DEFAULT's text, kept for a default that has to be
	// evaluated per row (one that calls a function, like CURRENT_TIMESTAMP).
	default_sql: string,
	// checks are the column's CHECK clauses.
	checks: []Check_Constraint,
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
	deferred:    bool,
	// A table-level CHECK uses check_sql instead of columns.
	is_check:    bool,
	check_sql:   string,
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
	// alter_column names the column whose declared type changes, and alter_type is
	// the type it will have. The change is a rewrite: every stored value is
	// converted with the same rules as CAST.
	alter_column: string,
	alter_type:   Column_Type,
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
	// columns names each key part; exprs holds the text of a part that is an
	// expression (empty for a plain column), and where_sql a partial index's WHERE.
	columns:       []string,
	exprs:         []string,
	where_sql:     string,
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
	// query_plan marks `EXPLAIN QUERY PLAN`, SQLite's form: the same plan as four
	// columns a tool reads, rather than one line per step.
	query_plan: bool,
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

// Listen_Stmt is `LISTEN channel`: this connection hears every NOTIFY on it.
Listen_Stmt :: struct {
	channel: string,
}

// Unlisten_Stmt is `UNLISTEN channel` or `UNLISTEN *`.
Unlisten_Stmt :: struct {
	channel: string,
	all:     bool,
}

// Notify_Stmt is `NOTIFY channel [, payload]`.
Notify_Stmt :: struct {
	channel: string,
	payload: string,
}

// Cursor is a query a session reads a few rows at a time. It belongs to the
// transaction that declared it, as PostgreSQL's cursors do: a commit closes them.
Cursor :: struct {
	columns: []string,
	rows:    [][]Value,
	// position is how many rows have been handed out: the cursor sits before
	// `rows[position]`.
	position: int,
}

// Fetch_Direction is where a FETCH starts reading and which way it goes.
Fetch_Direction :: enum u8 {
	Next,
	Prior,
	First,
	Last,
	Absolute,
	Relative,
	Forward,
	Backward,
	All,
}

Declare_Cursor_Stmt :: struct {
	name:     string,
	query:    Select_Stmt,
	hold:     bool,
	scroll:   bool,
	no_scroll: bool,
}

Fetch_Stmt :: struct {
	name:      string,
	direction: Fetch_Direction,
	// count is the row count of ABSOLUTE, RELATIVE, FORWARD and BACKWARD; zero with
	// Forward or Backward means ALL.
	count:     int,
	// move is MOVE: the cursor moves and no rows come back.
	move:      bool,
}

Close_Cursor_Stmt :: struct {
	name: string,
	all:  bool,
}

// Reindex_Stmt is `REINDEX [name]`. Every index is rebuilt from the log when the
// database opens, so there is never one that is out of date here; the statement is
// accepted so a maintenance script runs unchanged.
Reindex_Stmt :: struct {
	name: string,
}

Truncate_Stmt :: struct {
	name: string,
}

// Copy_Target says where a COPY's bytes come from or go to: a file on the
// server's machine, or one of the client's streams.
Copy_Target :: enum u8 {
	File,
	Stdin,
	Stdout,
}

// Copy_Format is the two text formats PostgreSQL defines.
Copy_Format :: enum u8 {
	Text,
	Csv,
}

// Copy_Stmt is `COPY table [(columns)] {FROM|TO} {STDIN|STDOUT|'path'} [(opts)]`.
// `from` is the direction; `target` says where the bytes come from or go.
Copy_Stmt :: struct {
	table:     string,
	columns:   []string,
	from:      bool,
	target:    Copy_Target,
	path:      string,
	format:    Copy_Format,
	delimiter: u8,
	header:    bool,
	// null_text is resolved when the statement is parsed: the formats default to
	// `\N` and to an empty unquoted field.
	null_text: string,
}

// Analyze_Stmt measures the statistics a plan reads. An empty table means every
// table.
Analyze_Stmt :: struct {
	table: string,
}

Statement :: union {
	Select_Stmt,
	Insert_Stmt,
	Update_Stmt,
	Delete_Stmt,
	Merge_Stmt,
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
	Reindex_Stmt,
	Declare_Cursor_Stmt,
	Fetch_Stmt,
	Close_Cursor_Stmt,
	Listen_Stmt,
	Unlisten_Stmt,
	Notify_Stmt,
	Copy_Stmt,
	Analyze_Stmt,
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
	// param_count is how many positional parameters ("?") the statement binds, in
	// the order they appear. It is what the embedding layers check an index
	// against, so a bind of 99 is a range error instead of a growth (D29).
	param_count: int,
	// param_names has one entry per parameter: its name as written ("?3", ":id",
	// "@id", "$id") or "" for a bare `?`. It lives in the query's arena.
	param_names: []string,
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
	case Merge_Stmt:
		return "MERGE"
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
	case Reindex_Stmt:
		return "REINDEX"
	case Copy_Stmt:
		return "COPY"
	case Declare_Cursor_Stmt:
		return "DECLARE CURSOR"
	case Fetch_Stmt:
		return "FETCH"
	case Close_Cursor_Stmt:
		return "CLOSE"
	case Listen_Stmt:
		return "LISTEN"
	case Unlisten_Stmt:
		return "UNLISTEN"
	case Notify_Stmt:
		return "NOTIFY"
	case Analyze_Stmt:
		return "ANALYZE"
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


