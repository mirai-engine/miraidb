package engine

import "core:mem"
import "core:strings"

// SQLite keeps every CREATE statement in sqlite_master as it was written:
// "CREATE TABLE " (or INDEX, UNIQUE INDEX, VIEW, TRIGGER) and then the text
// from the object's name on, without IF NOT EXISTS, a `main.` qualifier or the
// terminator, and ALTER TABLE edits that text. A program reads it back
// (`SELECT sql FROM sqlite_master`), and pragma table_info reads a column's
// declared type from it. The engine keeps the same text in the internal table
// `_sqlite_sql`, written in the transaction of the statement, so it is logged,
// survives a reopen and goes away with a rollback. An object made before this
// table existed has no row and is rendered from the engine's model.

SQL_TEXT_TABLE :: "_sqlite_sql"

// sqlite_text_capture fills a CREATE statement's text once it parsed, or ADD
// COLUMN's column definition.
@(private)
sqlite_text_capture :: proc(p: ^Parser, statement: ^Statement) {
	source := p.query.source
	end := clamp(p.prev_end, 0, len(source))
	if p.object_start <= 0 || p.object_start >= end do return
	tail := strings.trim_space(source[p.object_start:end])
	#partial switch &s in statement {
	case Create_Table_Stmt:
		if s.ephemeral || s.event do return
		s.text = strings.concatenate({"CREATE TABLE ", tail}, p.alloc)
	case Create_Index_Stmt:
		s.text = strings.concatenate({s.unique ? "CREATE UNIQUE INDEX " : "CREATE INDEX ", tail}, p.alloc)
	case Create_View_Stmt:
		s.text = strings.concatenate({"CREATE VIEW ", tail}, p.alloc)
	case Create_Trigger_Stmt:
		s.text = strings.concatenate({"CREATE TRIGGER ", tail}, p.alloc)
	case Create_Virtual_Table_Stmt:
		s.text = strings.concatenate({"CREATE VIRTUAL TABLE ", tail}, p.alloc)
	case Alter_Table_Stmt:
		if len(s.column.name) > 0 && len(s.rename_to) == 0 && len(s.drop_column) == 0 && len(s.alter_column) == 0 {
			s.add_text = strings.clone(tail, p.alloc)
		}
	}
}

// sql_text_of reads the stored text of one object, as the transaction sees it.
sql_text_of :: proc(tx: ^Tx, name: string) -> (string, bool) {
	if tx_table_probe(tx, SQL_TEXT_TABLE) == nil do return "", false
	result, err := sql_execute_in_tx_params(tx, "SELECT sql FROM _sqlite_sql WHERE name = ?", []Value{value_string(name)})
	if err.kind != .None {
		error_drop(err)
		return "", false
	}
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 || result.rows[0][0].kind != .String do return "", false
	return strings.clone(result.rows[0][0].s, tx.alloc), true
}

// sql_text_set stores (or replaces) one object's text.
sql_text_set :: proc(tx: ^Tx, name, text: string) -> Error {
	// The engine's own rows are not the program's changes: changes() and
	// total_changes() do not count them.
	saved_last, saved_total := tx.store.last_changes, tx.store.total_changes
	defer tx.store.last_changes, tx.store.total_changes = saved_last, saved_total
	if tx_table_probe(tx, SQL_TEXT_TABLE) == nil {
		created, create_err := sql_execute_in_tx(tx, "CREATE TABLE _sqlite_sql (name TEXT PRIMARY KEY NOT NULL, sql TEXT NOT NULL)")
		if create_err.kind != .None do return create_err
		sql_result_destroy(&created)
	}
	result, err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _sqlite_sql (name, sql) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET sql = excluded.sql",
		[]Value{value_string(name), value_string(text)},
	)
	if err.kind != .None do return err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// sql_text_forget drops one object's text.
sql_text_forget :: proc(tx: ^Tx, name: string) -> Error {
	// The engine's own rows are not the program's changes: changes() and
	// total_changes() do not count them.
	saved_last, saved_total := tx.store.last_changes, tx.store.total_changes
	defer tx.store.last_changes, tx.store.total_changes = saved_last, saved_total
	if tx_table_probe(tx, SQL_TEXT_TABLE) == nil do return ERROR_NONE
	result, err := sql_execute_in_tx_params(tx, "DELETE FROM _sqlite_sql WHERE name = ?", []Value{value_string(name)})
	if err.kind != .None do return err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// sql_texts reads every stored text, from rows of the table.
@(private)
sql_texts_from_rows :: proc(rows: []Row, alloc: mem.Allocator) -> map[string]string {
	out := make(map[string]string, len(rows), alloc)
	for row in rows {
		if len(row.values) < 2 || row.values[0].kind != .String || row.values[1].kind != .String do continue
		out[strings.clone(row.values[0].s, alloc)] = strings.clone(row.values[1].s, alloc)
	}
	return out
}

// tx_table_declared_types reads a table's declared types from the text it
// was created with, or from the file it was imported from; found is false
// when there is neither.
tx_table_declared_types :: proc(tx: ^Tx, table: string, normalize: bool, alloc: mem.Allocator) -> (map[string]string, bool) {
	text, has_text := sql_text_of(tx, table)
	if !has_text {
		if kept, imported := store_mirror_kept_lookup(tx.store, table); imported && kept.kind == "table" {
			text, has_text = kept.sql, true
		}
	}
	if !has_text do return nil, false
	return sql_text_declared_types(text, alloc, normalize), true
}

// tx_sql_texts is every stored text as the transaction sees it.
tx_sql_texts :: proc(tx: ^Tx, alloc: mem.Allocator) -> map[string]string {
	if tx_table_probe(tx, SQL_TEXT_TABLE) == nil do return nil
	rows := make([dynamic]Row, context.temp_allocator)
	if collect_err := tx_collect(tx, SQL_TEXT_TABLE, &rows); collect_err.kind != .None {
		error_drop(collect_err)
		return nil
	}
	return sql_texts_from_rows(rows[:], alloc)
}

// store_sql_texts is every stored text as committed, for an export.
store_sql_texts :: proc(store: ^Store, alloc: mem.Allocator) -> map[string]string {
	table, found := store.tables[SQL_TEXT_TABLE]
	if !found do return nil
	rows := make([dynamic]Row, context.temp_allocator)
	table_collect(table, &rows, max(u64))
	defer table_collect_release(table, &rows)
	return sql_texts_from_rows(rows[:], alloc)
}

// Sql_Token is one token of a stored text, with where it is.
@(private)
Sql_Token :: struct {
	kind:  Token_Kind,
	text:  string,
	start: int,
	end:   int,
}

@(private)
sql_text_tokens :: proc(text: string) -> [dynamic]Sql_Token {
	lexer := lexer_init(text, context.temp_allocator)
	out := make([dynamic]Sql_Token, 0, 16, context.temp_allocator)
	for {
		token := lexer_next(&lexer)
		if token.kind == .EOF do break
		append(&out, Sql_Token{kind = token.kind, text = token.text, start = token.start, end = token.end})
	}
	return out
}

@(private)
sql_token_is_name :: proc(token: Sql_Token, name: string) -> bool {
	return (token.kind == .Ident || token.kind == .Quoted_Ident) && strings.equal_fold(token.text, name)
}

// sql_text_quote spells a name as SQLite writes a name it puts in a text.
@(private)
sql_text_quote :: proc(name: string, alloc: mem.Allocator) -> string {
	escaped, _ := strings.replace_all(name, "\"", "\"\"", context.temp_allocator)
	return strings.concatenate({"\"", escaped, "\""}, alloc)
}

// sql_text_column_list finds the parentheses around a CREATE TABLE's column
// list: the first "(" and the ")" that closes it.
@(private)
sql_text_column_list :: proc(tokens: []Sql_Token) -> (open, close: int, ok: bool) {
	depth := 0
	open = -1
	for token, i in tokens {
		if token.kind != .Punct do continue
		if token.text == "(" {
			if depth == 0 && open < 0 do open = i
			depth += 1
		} else if token.text == ")" {
			depth -= 1
			if depth == 0 && open >= 0 do return open, i, true
		}
	}
	return -1, -1, false
}

// sql_text_add_column puts a column definition into a CREATE TABLE text after
// the last column's, as SQLite does: before the table constraints, or the
// parenthesis that closes the list. After a table constraint it is text SQLite
// cannot parse (`PRIMARY KEY (a, b), x INTEGER`), and the file was unreadable.
sql_text_add_column :: proc(text, definition: string, alloc: mem.Allocator) -> (string, bool) {
	tokens := sql_text_tokens(text)
	open, close, ok := sql_text_column_list(tokens[:])
	if !ok do return "", false
	at := tokens[close].start
	depth := 0
	item_start := true
	for i in open + 1 ..< close {
		token := tokens[i]
		if token.kind == .Punct && token.text == "(" do depth += 1
		if token.kind == .Punct && token.text == ")" do depth -= 1
		if depth == 0 && token.kind == .Punct && token.text == "," {
			item_start = true
			continue
		}
		if item_start && depth == 0 {
			item_start = false
			if sql_text_is_table_constraint(token.text) {
				// Back over the comma before this item: the definition goes there.
				at = tokens[i].start
				for j := i - 1; j > open; j -= 1 {
					if tokens[j].kind == .Punct && tokens[j].text == "," {
						at = tokens[j].start
						break
					}
				}
				break
			}
		}
	}
	return strings.concatenate({strings.trim_right_space(text[:at]), ", ", definition, text[at:]}, alloc), true
}

// sql_text_is_table_constraint is whether an item of a CREATE TABLE list that
// starts with `word` is a table constraint rather than a column.
@(private)
sql_text_is_table_constraint :: proc(word: string) -> bool {
	for keyword in ([]string{"constraint", "primary", "unique", "check", "foreign"}) {
		if strings.equal_fold(word, keyword) do return true
	}
	return false
}

// sql_text_drop_column removes a column's definition from a CREATE TABLE text.
sql_text_drop_column :: proc(text, column: string, alloc: mem.Allocator) -> (string, bool) {
	tokens := sql_text_tokens(text)
	open, close, ok := sql_text_column_list(tokens[:])
	if !ok do return "", false
	// The items of the list: the token ranges between top-level commas.
	items := make([dynamic][2]int, 0, 8, context.temp_allocator)
	depth := 0
	first := open + 1
	for i in open + 1 ..< close {
		token := tokens[i]
		if token.kind == .Punct && token.text == "(" do depth += 1
		if token.kind == .Punct && token.text == ")" do depth -= 1
		if depth == 0 && token.kind == .Punct && token.text == "," {
			append(&items, [2]int{first, i})
			first = i + 1
		}
	}
	append(&items, [2]int{first, close})
	for item, n in items {
		if item[0] >= item[1] || !sql_token_is_name(tokens[item[0]], column) do continue
		// The comma before the item goes with it; the first item takes the
		// comma after it instead.
		cut_from, cut_to: int
		if n > 0 {
			cut_from = tokens[item[0] - 1].start
			cut_to = tokens[item[1] - 1].end
		} else if len(items) > 1 {
			cut_from = tokens[item[0]].start
			cut_to = tokens[items[1][0]].start
		} else {
			return "", false
		}
		return strings.concatenate({text[:cut_from], text[cut_to:]}, alloc), true
	}
	return "", false
}

// sql_text_rename_column renames a column's every mention in a CREATE TABLE
// or CREATE INDEX text, except inside a REFERENCES clause, which names
// another table's columns.
sql_text_rename_column :: proc(text, from, to: string, alloc: mem.Allocator) -> string {
	tokens := sql_text_tokens(text)
	builder := strings.builder_make(alloc)
	last := 0
	skip_depth := -1
	depth := 0
	references := false
	for token, i in tokens {
		if token.kind == .Punct && token.text == "(" {
			depth += 1
			if references {
				skip_depth = depth
				references = false
			}
		} else if token.kind == .Punct && token.text == ")" {
			if depth == skip_depth do skip_depth = -1
			depth -= 1
		}
		if token.kind == .Ident && strings.equal_fold(token.text, "references") {
			references = true
			continue
		}
		// The table a REFERENCES names is not a column either.
		if references && i > 0 && tokens[i - 1].kind == .Ident && strings.equal_fold(tokens[i - 1].text, "references") do continue
		if skip_depth >= 0 do continue
		if i < 2 do continue
		if !sql_token_is_name(token, from) do continue
		strings.write_string(&builder, text[last:token.start])
		strings.write_string(&builder, to)
		last = token.end
	}
	strings.write_string(&builder, text[last:])
	return strings.to_string(builder)
}

// sql_text_rename_object puts a new name in place of the object's own name
// (the third token: CREATE TABLE name) or of the table an index or a trigger
// is on (the name after ON), quoted as SQLite writes it.
sql_text_rename_object :: proc(text, from, to: string, alloc: mem.Allocator) -> string {
	tokens := sql_text_tokens(text)
	builder := strings.builder_make(alloc)
	last := 0
	for token, i in tokens {
		own := i == 2 && strings.has_prefix(strings.to_upper(text[:min(len(text), 12)], context.temp_allocator), "CREATE TABLE")
		after_on := i > 0 && tokens[i - 1].kind == .Ident && strings.equal_fold(tokens[i - 1].text, "on")
		if !(own || after_on) || !sql_token_is_name(token, from) do continue
		strings.write_string(&builder, text[last:token.start])
		strings.write_string(&builder, sql_text_quote(to, context.temp_allocator))
		last = token.end
	}
	strings.write_string(&builder, text[last:])
	return strings.to_string(builder)
}

// sql_text_index_names lists the indexes of a table, before it is dropped
// or renamed.
@(private)
sql_text_index_names :: proc(tx: ^Tx, table_name: string) -> []string {
	table := tx_table_probe(tx, table_name)
	if table == nil do return nil
	names := make([dynamic]string, 0, len(table.schema.indexes), tx.alloc)
	for index in table.schema.indexes do append(&names, strings.clone(index.name, tx.alloc))
	return names[:]
}

// sql_text_on_alter keeps the stored texts true to an ALTER TABLE that
// succeeded: SQLite edits them the same way. A change it cannot express
// (a type change, which SQLite has no statement for) drops the table's text,
// which is then rendered from the model.
sql_text_on_alter :: proc(tx: ^Tx, stmt: Alter_Table_Stmt, indexes: []string) -> Error {
	if tx_table_probe(tx, SQL_TEXT_TABLE) == nil do return ERROR_NONE
	texts := tx_sql_texts(tx, context.temp_allocator)
	table_text, has_text := texts[stmt.table]
	switch {
	case len(stmt.rename_column) > 0:
		if has_text {
			if err := sql_text_set(tx, stmt.table, sql_text_rename_column(table_text, stmt.rename_column, stmt.rename_to, context.temp_allocator)); err.kind != .None do return err
		}
		for index in indexes {
			if text, found := texts[index]; found {
				if err := sql_text_set(tx, index, sql_text_rename_column(text, stmt.rename_column, stmt.rename_to, context.temp_allocator)); err.kind != .None do return err
			}
		}
		// The views and the triggers that name the column.
		trigger_tables := make(map[string]string, 8, context.temp_allocator)
		for trigger in tx_triggers(tx, context.temp_allocator) do trigger_tables[trigger.name] = trigger.table
		for view in tx_views(tx, context.temp_allocator) do trigger_tables[view[0]] = ""
		for name, text in texts {
			trigger_table, is_object := trigger_tables[name]
			if !is_object do continue
			own := strings.equal_fold(trigger_table, stmt.table)
			renamed := sql_rename_column_refs(tx, text, stmt.table, stmt.rename_column, stmt.rename_to, own, context.temp_allocator)
			if renamed == text do continue
			if err := sql_text_set(tx, name, renamed); err.kind != .None do return err
		}
	case len(stmt.rename_to) > 0:
		if has_text {
			if err := sql_text_forget(tx, stmt.table); err.kind != .None do return err
			if err := sql_text_set(tx, stmt.rename_to, sql_text_rename_object(table_text, stmt.table, stmt.rename_to, context.temp_allocator)); err.kind != .None do return err
		}
		for name, text in texts {
			if name == stmt.table do continue
			renamed := sql_rename_table_refs(text, stmt.table, stmt.rename_to, context.temp_allocator)
			if renamed == text do continue
			if err := sql_text_set(tx, name, renamed); err.kind != .None do return err
		}
	case len(stmt.drop_column) > 0:
		if has_text {
			if dropped, ok := sql_text_drop_column(table_text, stmt.drop_column, context.temp_allocator); ok {
				return sql_text_set(tx, stmt.table, dropped)
			}
			return sql_text_forget(tx, stmt.table)
		}
	case len(stmt.alter_column) > 0:
		if has_text do return sql_text_forget(tx, stmt.table)
	case len(stmt.add_text) > 0:
		if has_text {
			if added, ok := sql_text_add_column(table_text, stmt.add_text, context.temp_allocator); ok {
				return sql_text_set(tx, stmt.table, added)
			}
			return sql_text_forget(tx, stmt.table)
		}
	}
	return ERROR_NONE
}

// sql_text_declared_types reads each column's declared type from a CREATE
// TABLE text, as pragma table_info answers it: as written, except SQLite's
// own type names, which it spells in capitals (sqlite3_column_decltype keeps
// even those as written: `normalize` false).
sql_text_declared_types :: proc(text: string, alloc: mem.Allocator, normalize := true) -> map[string]string {
	out := make(map[string]string, 8, alloc)
	for column in sqlite_columns_from_sql(text, context.temp_allocator) {
		declared := column.declared
		if normalize {
			for standard in ([]string{"ANY", "BLOB", "INT", "INTEGER", "REAL", "TEXT"}) {
				if strings.equal_fold(declared, standard) do declared = standard
			}
		}
		out[strings.to_lower(column.name, alloc)] = strings.clone(declared, alloc)
	}
	return out
}
