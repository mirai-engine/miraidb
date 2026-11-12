package engine

import "core:strings"

// Full-text search as data. A virtual FTS table is a normal table of documents
// plus an inverted index kept in a shadow table; `MATCH` reads the shadow table,
// not the documents, so the query cost follows the number of matching documents
// rather than the size of the text.
//
//	_virtual (name, module, settings)  what virtual tables exist
//	_fts_<name>_terms (term, doc)      one row per (token, document)
//
// Interior tables are ordinary tables: they are logged, replicated and dropped
// like any other, so FTS needs no format change.

VIRTUAL_TABLE :: "_virtual"
VIRTUAL_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _virtual (
		name TEXT PRIMARY KEY,
		module TEXT NOT NULL,
		settings TEXT NOT NULL
	)
`

FTS_MAX_TERMS :: 4096

Fts_Table :: struct {
	name:     string,
	// module is the virtual table module that made it: fts5/fts4 are inverted
	// indexes, rtree stores boxes. The name says which rules apply.
	module:   string,
	terms:    string,
	columns:  []string,
	settings: string,
}

// fts_is_full_text reports whether this virtual table maintains an inverted index.
fts_is_full_text :: proc(table: Fts_Table) -> bool {
	return strings.equal_fold(table.module, "fts5") || strings.equal_fold(table.module, "fts4")
}

// fts_is_spatial reports whether this virtual table stores bounding boxes.
fts_is_spatial :: proc(table: Fts_Table) -> bool {
	return strings.equal_fold(table.module, "rtree") || strings.equal_fold(table.module, "rtree_i32")
}

fts_ensure :: proc(tx: ^Tx) -> Error {
	_, err := sql_execute_in_tx(tx, VIRTUAL_SCHEMA_SQL)
	return err
}

// fts_run executes one statement inside the transaction and keeps only the error.
@(private)
fts_run :: proc(tx: ^Tx, sql: string, params: []Value = nil) -> Error {
	_, err := sql_execute_in_tx_params(tx, sql, params)
	return err
}

@(private)
fts_virtual_lookup :: proc(tx: ^Tx, name: string) -> (Fts_Table, bool) {
	table, err := tx_table(tx, VIRTUAL_TABLE)
	if err.kind != .None do return {}, false
	rows := make([dynamic]Row, 0, 8)
	defer delete(rows)
	table_collect(table, &rows)
	for row in rows {
		if len(row.values) < 3 do continue
		if row.values[0].kind != .String || !strings.equal_fold(row.values[0].s, name) do continue
		settings := ""
		if row.values[2].kind == .String do settings = row.values[2].s
		module := ""
		if len(row.values) > 1 && row.values[1].kind == .String do module = row.values[1].s
		columns := make([dynamic]string, 0, 4, tx.alloc)
		for piece in strings.split(settings, ",") {
			trimmed := strings.trim_space(piece)
			if len(trimmed) > 0 do append(&columns, trimmed)
		}
		return Fts_Table{name = row.values[0].s, module = module, terms = fts_terms_name(name), columns = columns[:], settings = settings}, true
	}
	return {}, false
}

@(private)
fts_terms_name :: proc(name: string, alloc := context.temp_allocator) -> string {
	return strings.concatenate({"_fts_", name, "_terms"}, alloc)
}

// fts_create makes the document table (when it does not exist), its shadow term
// table and the catalog row that links them.
fts_create :: proc(tx: ^Tx, name: string, module: string, columns: []string) -> Error {
	if len(name) == 0 do return errf(.Invalid_Argument, "a virtual table needs a name")
	if len(columns) == 0 do return errf(.Invalid_Argument, "virtual table %s needs at least one column", name)
	if strings.equal_fold(module, "rtree") || strings.equal_fold(module, "rtree_i32") {
		return rtree_create(tx, name, module, columns)
	}
	if !strings.equal_fold(module, "fts5") && !strings.equal_fold(module, "fts4") {
		return errf(.Sql_Unsupported, "virtual table module %s is not supported", module)
	}
	if err := fts_ensure(tx); err.kind != .None do return err
	if existing, found := fts_virtual_lookup(tx, name); found {
		return errf(.Table_Exists, "virtual table %s already exists", existing.name)
	}
	settings := strings.join(columns, ",")

	create := strings.concatenate({"CREATE TABLE IF NOT EXISTS ", name, " ("}, tx.alloc)
	for column, i in columns {
		if i > 0 do create = strings.concatenate({create, ", "}, tx.alloc)
		create = strings.concatenate({create, column, " TEXT"}, tx.alloc)
	}
	create = strings.concatenate({create, ")"}, tx.alloc)
	if err := fts_run(tx, create); err.kind != .None do return err

	terms := fts_terms_name(name, tx.alloc)
	terms_sql := strings.concatenate(
		{"CREATE TABLE IF NOT EXISTS ", terms, " (term TEXT NOT NULL, doc INTEGER NOT NULL)"},
		tx.alloc,
	)
	if err := fts_run(tx, terms_sql); err.kind != .None do return err
	// No index on `term`: CREATE INDEX must run in a transaction of its own, and a
	// virtual table is created inside one statement. MATCH therefore reads the
	// shadow table once per distinct pattern (see fts_match_docs) rather than once
	// per row, which is the cost that matters for a scan.

	values := []Value {
		value_string(strings.clone(name, tx.alloc)),
		value_string(strings.clone(module, tx.alloc)),
		value_string(strings.clone(settings, tx.alloc)),
	}
	row_id, insert_err := tx_insert(tx, VIRTUAL_TABLE, values)
	if insert_err.kind != .None do return insert_err
	_ = row_id
	return ERROR_NONE
}

fts_drop :: proc(tx: ^Tx, name: string, if_exists: bool) -> Error {
	if err := fts_ensure(tx); err.kind != .None do return err
	table, found := fts_virtual_lookup(tx, name)
	if !found {
		if if_exists do return ERROR_NONE
		return errf(.Table_Not_Found, "no virtual table named %s", name)
	}
	// The catalog row goes first: with it gone, dropping the tables below runs as
	// plain drops instead of re-entering this procedure.
	drop_row := strings.concatenate({"DELETE FROM ", VIRTUAL_TABLE, " WHERE name = ?"}, tx.alloc)
	if err := fts_run(tx, drop_row, []Value{value_string(strings.clone(name, tx.alloc))}); err.kind != .None {
		return err
	}
	if err := tx_drop_table(tx, table.terms); err.kind != .None && err.kind != .Table_Not_Found do return err
	return tx_drop_table(tx, table.name)
}

// fts_index_row maintains the inverted index for one document. Every indexed
// column is tokenized with the same rules MATCH uses, so what is stored and what
// is searched can never disagree.
fts_index_row :: proc(tx: ^Tx, table: Fts_Table, doc: Row_Id, values: []Value) -> Error {
	if err := fts_remove_row(tx, table, doc); err.kind != .None do return err
	seen := make(map[string]bool, 8, tx.alloc)
	defer delete(seen)
	insert := strings.concatenate(
		{"INSERT INTO ", table.terms, " (term, doc) VALUES (?, ?)"},
		tx.alloc,
	)
	count := 0
	for value in values {
		if value.kind != .String do continue
		term := strings.builder_make(tx.alloc)
		for b in transmute([]u8)value.s {
			if fts_is_word_byte(b) {
				strings.write_byte(&term, fts_fold_byte(b))
				continue
			}
			word := strings.to_string(term)
			count += fts_insert_term(tx, insert, &seen, word, doc)
			strings.builder_reset(&term)
			strings.builder_destroy(&term)
			term = strings.builder_make(tx.alloc)
		}
		word := strings.to_string(term)
		count += fts_insert_term(tx, insert, &seen, word, doc)
		strings.builder_destroy(&term)
	}
	_ = count
	return ERROR_NONE
}

@(private)
fts_insert_term :: proc(tx: ^Tx, insert: string, seen: ^map[string]bool, word: string, doc: Row_Id) -> int {
	if len(word) == 0 do return 0
	if _, exists := seen[word]; exists do return 0
	if len(seen) >= FTS_MAX_TERMS do return 0
	key := strings.clone(word, tx.alloc)
	seen[key] = true
	err := fts_run(tx, insert, []Value{value_string(word), value_int(i64(doc))})
	if err.kind != .None do return 0
	return 1
}

fts_remove_row :: proc(tx: ^Tx, table: Fts_Table, doc: Row_Id) -> Error {
	sql := strings.concatenate({"DELETE FROM ", table.terms, " WHERE doc = ?"}, tx.alloc)
	return fts_run(tx, sql, []Value{value_int(i64(doc))})
}

@(private)
fts_is_word_byte :: proc(byte: u8) -> bool {
	return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte >= 0x80 || byte == '_'
}

@(private)
fts_fold_byte :: proc(byte: u8) -> u8 {
	if byte >= 'A' && byte <= 'Z' do return byte + 32
	return byte
}

// fts_match_docs answers "which documents contain this query". The pattern is a
// list separated by spaces: terms in a row must all be present, OR separates
// alternatives, and NOT removes the documents that carry the next term. Results
// are cached per statement, because every row of a scan asks the same question.
fts_match_docs :: proc(tx: ^Tx, table: Fts_Table, pattern: string) -> (map[Row_Id]bool, Error) {
	key := strings.concatenate({table.name, "\x00", pattern}, tx.alloc)
	if tx.fts_cache == nil do tx.fts_cache = make(map[string]map[Row_Id]bool)
	if cached, found := tx.fts_cache[key]; found do return cached, ERROR_NONE

	docs := make(map[Row_Id]bool)
	group := make([dynamic]map[Row_Id]bool, 0, 4, context.temp_allocator)
	negatives := make([dynamic]map[Row_Id]bool, 0, 2, context.temp_allocator)
	defer {
		for set in group do delete(set)
		delete(group)
		for set in negatives do delete(set)
		delete(negatives)
	}
	negate_next := false
	for piece in strings.split(pattern, " ") {
		word := strings.trim_space(piece)
		if len(word) == 0 do continue
		if strings.equal_fold(word, "or") {
			fts_merge_group(&docs, group[:])
			clear(&group)
			continue
		}
		if strings.equal_fold(word, "not") {
			negate_next = true
			continue
		}
		set, set_err := fts_term_docs(tx, table, word)
		if set_err.kind != .None do return nil, set_err
		if negate_next {
			append(&negatives, set)
			negate_next = false
		} else {
			append(&group, set)
		}
	}
	fts_merge_group(&docs, group[:])
	for set in negatives {
		for doc in set do delete_key(&docs, doc)
	}
	tx.fts_cache[key] = docs
	return docs, ERROR_NONE
}

// fts_merge_group intersects the documents of one conjunction and adds them to the
// result: `a b` is narrower than `a`, and `a OR b` is wider.
@(private)
fts_merge_group :: proc(docs: ^map[Row_Id]bool, group: []map[Row_Id]bool) {
	if len(group) == 0 do return
	if len(group) == 1 {
		for doc in group[0] do docs[doc] = true
		return
	}
	first := group[0]
	outer: for doc in first {
		for set, i in group {
			if i == 0 do continue
			if _, found := set[doc]; !found do continue outer
		}
		docs[doc] = true
	}
}

@(private)
fts_term_docs :: proc(tx: ^Tx, table: Fts_Table, word: string) -> (map[Row_Id]bool, Error) {
	set := make(map[Row_Id]bool)
	sql := strings.concatenate({"SELECT doc FROM ", table.terms, " WHERE term = ?"}, tx.alloc)
	result, err := sql_execute_in_tx_params(tx, sql, []Value{value_string(fts_fold_word(word, tx.alloc))})
	if err.kind != .None do return set, err
	defer sql_result_destroy(&result)
	for row in result.rows {
		if len(row) > 0 do set[Row_Id(row[0].i)] = true
	}
	return set, ERROR_NONE
}

@(private)
fts_fold_word :: proc(word: string, alloc := context.temp_allocator) -> string {
	out := make([]u8, len(word), alloc)
	for byte, i in transmute([]u8)word do out[i] = fts_fold_byte(byte)
	return string(out)
}

// fts_match_eval evaluates `documents MATCH 'pattern'` against the row being
// examined: the operand names a virtual table, and the row's id decides whether
// it is in the matching set.
fts_match_eval :: proc(tx: ^Tx, ctx: ^Eval_Ctx, operand: ^Expr, pattern: Value) -> (Value, Error) {
	table_name := ""
	if column, ok := operand^.(Column_Expr); ok {
		if len(column.table) > 0 {
			table_name = column.table
		} else {
			table_name = column.name
		}
	}
	if len(table_name) == 0 {
		return {}, errf(.Sql_Syntax, "MATCH needs a table on its left")
	}
	virtual: Fts_Table
	found := false
	for source in ctx.sources {
		if strings.equal_fold(source.table.schema.name, table_name) ||
		   (len(source.alias) > 0 && strings.equal_fold(source.alias, table_name)) {
			if candidate, is_virtual := fts_virtual_lookup(tx, source.table.schema.name); is_virtual {
				virtual = candidate
				found = true
			}
		}
	}
	if !found {
		if candidate, is_virtual := fts_virtual_lookup(tx, table_name); is_virtual {
			virtual = candidate
			found = true
		}
	}
	if !found do return {}, errf(.Table_Not_Found, "%s is not a full-text table", table_name)
	if pattern.kind != .String do return {}, errf(.Sql_Syntax, "MATCH needs a text pattern")
	docs, docs_err := fts_match_docs(tx, virtual, pattern.s)
	if docs_err.kind != .None do return {}, docs_err
	for source in ctx.sources {
		if strings.equal_fold(source.table.schema.name, virtual.name) {
			return value_int(docs[source.row.id] ? 1 : 0), ERROR_NONE
		}
	}
	return value_int(0), ERROR_NONE
}

// fts_index_if_virtual maintains the index when `table_name` names a virtual
// table, and does nothing (without touching the catalog) otherwise. A plain table
// costs one lookup of a table whose size is the number of virtual tables.
fts_index_if_virtual :: proc(tx: ^Tx, table_name: string, doc: Row_Id, values: []Value) -> Error {
	virtual, found := fts_virtual_lookup(tx, table_name)
	if !found || !fts_is_full_text(virtual) do return ERROR_NONE
	return fts_index_row(tx, virtual, doc, values)
}

fts_delete_if_virtual :: proc(tx: ^Tx, table_name: string, doc: Row_Id) -> Error {
	virtual, found := fts_virtual_lookup(tx, table_name)
	if !found || !fts_is_full_text(virtual) do return ERROR_NONE
	return fts_remove_row(tx, virtual, doc)
}

// fts_drop_if_virtual drops a virtual table, its shadow table and its catalog
// row together, keeping them from drifting apart.
fts_drop_if_virtual :: proc(tx: ^Tx, table_name: string, if_exists: bool) -> (bool, Error) {
	if _, found := fts_virtual_lookup(tx, table_name); !found do return false, ERROR_NONE
	return true, fts_drop(tx, table_name, if_exists)
}

// rtree_create makes a spatial table: the columns are the boxes themselves, so an
// overlap query is a range predicate the executor already knows how to answer.
//
//	CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx, miny, maxy)
//	SELECT id FROM places WHERE maxx >= 5 AND minx <= 5 AND maxy >= 5 AND miny <= 5
//
// The stored layout is the table's own columns rather than an R-tree node file;
// range predicates decide what overlaps, which gives the same rows an R-tree
// would, with a scan instead of a tree descent. That difference is written down
// in docs/sql.md rather than hidden: a bounded query is cheap, an unbounded one
// is a scan.
rtree_create :: proc(tx: ^Tx, name: string, module: string, columns: []string) -> Error {
	if len(columns) < 5 do return errf(
		.Invalid_Argument,
		"an rtree needs an id and at least four coordinates, got %d columns",
		len(columns),
	)
	coordinates := len(columns) - 1
	if coordinates % 2 != 0 do return errf(
		.Invalid_Argument,
		"an rtree needs an even number of coordinates (min,max pairs), got %d",
		coordinates,
	)
	if err := fts_ensure(tx); err.kind != .None do return err
	integer := strings.equal_fold(module, "rtree_i32")
	create := strings.concatenate({"CREATE TABLE IF NOT EXISTS ", name, " ("}, tx.alloc)
	for column, i in columns {
		if i > 0 do create = strings.concatenate({create, ", "}, tx.alloc)
		if i == 0 {
			// SQLite names the first column `id`; it is the row handle.
			create = strings.concatenate({create, column, " INTEGER PRIMARY KEY AUTOINCREMENT"}, tx.alloc)
			continue
		}
		create = strings.concatenate({create, column, integer ? " INTEGER" : " REAL"}, tx.alloc)
	}
	create = strings.concatenate({create, ")"}, tx.alloc)
	if err := fts_run(tx, create); err.kind != .None do return err
	values := []Value {
		value_string(strings.clone(name, tx.alloc)),
		value_string(strings.clone(module, tx.alloc)),
		value_string(strings.clone(strings.join(columns, ","), tx.alloc)),
	}
	if _, insert_err := tx_insert(tx, VIRTUAL_TABLE, values); insert_err.kind != .None do return insert_err
	return ERROR_NONE
}
