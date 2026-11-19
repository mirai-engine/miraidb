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
	// cast_type is, for a column that is a CAST, the type it names: what a
	// CREATE TABLE ... AS SELECT reads the column's affinity from.
	cast_type: string,
}

// sql_describe_declared answers, for each result column of `select`, the type
// SQLite reads its affinity from: a table column's declared type, a CAST's
// type, or "" for any other expression. The strings are the temporary
// allocator's.
sql_describe_declared :: proc(tx: ^Tx, select: Select_Stmt) -> []string {
	origins, ok := sql_describe_origins(tx, Statement(select), context.temp_allocator)
	if !ok do return nil
	declared := make([]string, len(origins), context.temp_allocator)
	for origin, i in origins {
		declared[i] = len(origin.table) > 0 ? origin.decltype : origin.cast_type
	}
	return declared
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
		if cast_expr, is_cast := target^.(Cast_Expr); is_cast {
			origins[i].cast_type = strings.clone(cast_expr.type_name, context.temp_allocator)
			continue
		}
		column, is_column := target^.(Column_Expr)
		if !is_column do continue
		source, index, found := describe_column_source(sources[:], column)
		if !found do continue
		declared := source.table.schema.columns[index]
		// The type as the column was declared, as SQLite answers it ("" for a
		// column declared without one); the engine's name when the table has
		// no text to read it from.
		decltype := sqlite_type_name(declared.type)
		if types, has_text := tx_table_declared_types(tx, source.table.schema.name, false, context.temp_allocator); has_text {
			decltype = types[strings.to_lower(declared.name, context.temp_allocator)] or_else ""
			decltype = strings.clone(decltype, context.temp_allocator)
		}
		origins[i] = Column_Origin {
			database = "main",
			table    = source.table.schema.name,
			column   = declared.name,
			decltype = decltype,
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

// Column_Metadata is what sqlite3_table_column_metadata answers for a column of
// a table: its declared type, its collation, NOT NULL, whether it is part of
// the primary key and whether it is an AUTOINCREMENT key.
Column_Metadata :: struct {
	decltype:       string,
	collation:      string,
	not_null:       bool,
	primary_key:    bool,
	auto_increment: bool,
}

// embed_column_metadata looks the column up as the connection sees it (inside
// its transaction when it has one). The rowid of a table that has no column of
// that name answers as SQLite's does: INTEGER, BINARY, the primary key. The
// strings live in the temporary allocator.
embed_column_metadata :: proc(conn: ^Embed_Conn, schema, table_name, column_name: string) -> (meta: Column_Metadata, has_table: bool, has_column: bool) {
	if conn == nil || conn.store == nil do return {}, false, false
	// A schema names the database to look in; without one, main is first and
	// then each attached database, as SQLite searches.
	if len(schema) == 0 || strings.equal_fold(schema, "main") || strings.equal_fold(schema, "temp") {
		tx := conn.tx
		if tx == nil {
			tx = tx_begin_read(conn.store)
			defer tx_end(tx)
			meta, has_table, has_column = column_metadata_in(tx, table_name, column_name)
		} else {
			meta, has_table, has_column = column_metadata_in(tx, table_name, column_name)
		}
		if has_table || len(schema) > 0 do return
	}
	for name, attached in conn.store.attached {
		if len(schema) > 0 && !strings.equal_fold(name, schema) do continue
		if conn.tx != nil {
			if writer, open := conn.tx.attached_txs[name]; open {
				meta, has_table, has_column = column_metadata_in(writer, table_name, column_name)
				if has_table do return
				continue
			}
		}
		reader := tx_begin_read(attached)
		meta, has_table, has_column = column_metadata_in(reader, table_name, column_name)
		tx_end(reader)
		if has_table do return
	}
	return {}, false, false
}

@(private)
column_metadata_in :: proc(tx: ^Tx, table_name: string, column_name: string) -> (meta: Column_Metadata, has_table: bool, has_column: bool) {
	table := tx_table_probe(tx, table_name)
	if table == nil {
		for name in tx_table_names(tx, context.temp_allocator) {
			if strings.has_prefix(name, "_") || !strings.equal_fold(name, table_name) do continue
			table = tx_table_probe(tx, name)
			break
		}
	}
	if table == nil || strings.has_prefix(table.schema.name, "_") do return {}, false, false
	if len(column_name) == 0 do return {}, true, false
	schema := &table.schema
	index := -1
	for column, k in schema.columns {
		if strings.equal_fold(column.name, column_name) {
			index = k
			break
		}
	}
	if index < 0 {
		lower := strings.to_lower(column_name, context.temp_allocator)
		if !schema.without_rowid && (lower == "rowid" || lower == "oid" || lower == "_rowid_") {
			alias, has_alias := rowid_alias_column(schema)
			if !has_alias do return Column_Metadata{decltype = "INTEGER", collation = "BINARY", primary_key = true}, true, true
			index = alias
		} else {
			return {}, true, false
		}
	}
	column := schema.columns[index]
	meta.decltype = sqlite_type_name(column.type)
	if types, has_text := tx_table_declared_types(tx, schema.name, false, context.temp_allocator); has_text {
		meta.decltype = strings.clone(types[strings.to_lower(column.name, context.temp_allocator)] or_else "", context.temp_allocator)
	}
	meta.collation = len(column.collation) > 0 ? strings.to_upper(column.collation, context.temp_allocator) : "BINARY"
	meta.not_null = column.not_null
	for key in schema.primary_key do if key == index do meta.primary_key = true
	meta.auto_increment = column.auto_increment || schema.auto_increment_column == index
	return meta, true, true
}
