package engine

import "core:strings"

// --- Where a result column comes from --------------------------------------
//
// A program that reads a result through the classic embedded API asks, for
// each column, which table and column it is and what type that column was
// declared with (sqlite3_column_table_name, _origin_name, _decltype). The
// answer only exists for a column that names a table's column directly: an
// expression has no origin, and SQLite answers NULL for it too.
//
// The description reads the statement and the catalog and runs nothing. It
// answers for a SELECT (or the SELECT of a WITH) whose FROM and JOINs are tables
// of the database; when a source is anything else (a derived table, a CTE, a
// view, a table function, an attached database), it does not guess and every
// column answers NULL.

// Column_Origin is one result column's source. A zero value means the column
// is an expression, or the description could not tell.
Column_Origin :: struct {
	database: string,
	table:    string,
	column:   string,
	// decltype is the engine's name for the column's type, as the .sqlite
	// export writes it: INTEGER, REAL, TEXT or BLOB. The text a CREATE TABLE
	// spelled (VARCHAR(10)) is not kept, so it reads as its affinity's name.
	decltype: string,
}

// sql_describe_origins describes the result columns of `statement` in `tx`.
// The strings point into the catalog: a caller that keeps them copies them.
// The second answer is false when the statement is not a SELECT or one of its
// sources is not a table, and then there is nothing to read.
sql_describe_origins :: proc(tx: ^Tx, statement: Statement, alloc := context.allocator) -> ([]Column_Origin, bool) {
	select: Select_Stmt
	ctes: []Cte
	#partial switch s in statement {
	case Select_Stmt:
		select = s
	case With_Stmt:
		select = s.select_stmt
		ctes = s.ctes
	case:
		return nil, false
	}

	refs := make([dynamic]Table_Ref, 0, 1 + len(select.joins), context.temp_allocator)
	if len(select.from.name) > 0 || select.from.subquery != nil do append(&refs, select.from)
	for join in select.joins do append(&refs, join.table)

	sources := make([dynamic]Source, 0, len(refs), context.temp_allocator)
	for ref in refs {
		if ref.subquery != nil || len(ref.args) > 0 || len(ref.schema) > 0 do return nil, false
		for cte in ctes {
			if strings.equal_fold(cte.name, ref.name) do return nil, false
		}
		table := tx_table_probe(tx, ref.name)
		if table == nil do return nil, false
		append(&sources, Source{table = table, alias = ref.alias})
	}

	// expand_projections clones each column name; the names are not needed here.
	names := make([dynamic]string, 0, len(select.projections), context.temp_allocator)
	previous := context.allocator
	context.allocator = context.temp_allocator
	exprs := expand_projections(sources[:], select.joins, select.projections, &names, context.temp_allocator)
	context.allocator = previous

	origins := make([]Column_Origin, len(exprs), alloc)
	for expr, i in exprs {
		target := expr
		// A COLLATE changes how a column compares, not where it comes from.
		for target != nil {
			collate, is_collate := target^.(Collate_Expr)
			if !is_collate do break
			target = collate.operand
		}
		if target == nil do continue
		column, is_column := target^.(Column_Expr)
		if !is_column do continue
		source, index, found := describe_column_source(sources[:], column)
		if !found do continue
		declared := source.table.schema.columns[index]
		origins[i] = Column_Origin {
			database = "main",
			table    = source.table.schema.name,
			column   = declared.name,
			decltype = sqlite_type_name(declared.type),
		}
	}
	return origins, true
}

// describe_column_source finds the one source a column reference reads, by its
// qualifier or, unqualified, by being the only source that has the column. An
// ambiguous or missing name has no source.
@(private)
describe_column_source :: proc(sources: []Source, column: Column_Expr) -> (Source, int, bool) {
	match: Source
	match_index := -1
	for source in sources {
		if source.table == nil || source.hidden_unqualified && len(column.table) == 0 do continue
		if len(column.table) > 0 {
			qualified := strings.equal_fold(column.table, source.table.schema.name) ||
				(len(source.alias) > 0 && strings.equal_fold(column.table, source.alias))
			if !qualified do continue
		}
		index, exists := schema_column_index(&source.table.schema, column.name)
		if !exists do continue
		if match_index >= 0 do return {}, -1, false
		match = source
		match_index = index
	}
	return match, match_index, match_index >= 0
}
