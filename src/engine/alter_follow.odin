package engine

import "core:mem"
import "core:strings"

// What ALTER TABLE carries along, as SQLite does: renaming a table moves its
// triggers to the new name and rewrites the names views and trigger bodies
// read it by; renaming a column rewrites the CHECK constraints, generated
// columns, trigger bodies, UPDATE OF lists and views that name it. The
// statements are text (views, trigger bodies), so the rewrite works on their
// tokens: a table is renamed where a name is read as a table (after FROM,
// JOIN, INTO, UPDATE, TABLE or ON, or as the qualifier of a column), a column
// where it is read as one of this table's columns. SQLite resolves every name
// with its parser; a body that reads two tables with a column of the same
// name has only its qualified mentions renamed here.

@(private)
table_ref_keywords := []string{"from", "join", "into", "update", "table", "on"}

// sql_rename_table_refs renames the table `from` where the text reads it as a
// table, quoting the new name as SQLite writes it.
sql_rename_table_refs :: proc(text, from, to: string, alloc: mem.Allocator) -> string {
	tokens := sql_text_tokens(text)
	builder := strings.builder_make(alloc)
	last := 0
	for token, i in tokens {
		if !sql_token_is_name(token, from) do continue
		qualifier := i + 1 < len(tokens) && tokens[i + 1].kind == .Punct && tokens[i + 1].text == "."
		after_keyword := false
		if i > 0 && tokens[i - 1].kind == .Ident {
			for keyword in table_ref_keywords {
				after_keyword ||= strings.equal_fold(tokens[i - 1].text, keyword)
			}
		}
		// A column of another table that happens to share the name is read
		// after a dot.
		after_dot := i > 0 && tokens[i - 1].kind == .Punct && tokens[i - 1].text == "."
		if after_dot || !(qualifier || after_keyword) do continue
		strings.write_string(&builder, text[last:token.start])
		strings.write_string(&builder, sql_text_quote(to, context.temp_allocator))
		last = token.end
	}
	strings.write_string(&builder, text[last:])
	return strings.to_string(builder)
}

// sql_tables_read lists the names a text reads as tables: after FROM, JOIN,
// INTO, UPDATE, TABLE or ON, and after a comma in a FROM list.
@(private)
sql_tables_read :: proc(tokens: []Sql_Token) -> [dynamic]string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	in_from := false
	depth := 0
	from_depth := 0
	for token, i in tokens {
		if token.kind == .Punct && token.text == "(" do depth += 1
		if token.kind == .Punct && token.text == ")" {
			if in_from && depth == from_depth do in_from = false
			depth -= 1
		}
		if token.kind == .Ident {
			for keyword in ([]string{"where", "group", "order", "limit", "having", "union", "except", "intersect", "on", "using", "set", "values", "select", "window"}) {
				if strings.equal_fold(token.text, keyword) && depth == from_depth do in_from = false
			}
			if strings.equal_fold(token.text, "from") || strings.equal_fold(token.text, "join") {
				in_from = true
				from_depth = depth
			}
		}
		if i == 0 || (token.kind != .Ident && token.kind != .Quoted_Ident) do continue
		previous := tokens[i - 1]
		if previous.kind == .Ident {
			for keyword in table_ref_keywords {
				if strings.equal_fold(previous.text, keyword) do append(&out, token.text)
			}
		} else if in_from && previous.kind == .Punct && previous.text == "," {
			append(&out, token.text)
		}
	}
	return out
}

// sql_rename_column_refs renames the column `from` of table `table` in a
// statement's text. `own` says the text belongs to that table (a CHECK, a
// generated column, or a trigger on it, whose NEW and OLD are its rows).
// Every mention is renamed when no other table the text reads has a column
// of that name; otherwise only the mentions qualified by the table (or by
// NEW and OLD) are, and an UPDATE OF list on the table.
sql_rename_column_refs :: proc(tx: ^Tx, text, table, from, to: string, own: bool, alloc: mem.Allocator) -> string {
	tokens := sql_text_tokens(text)
	read := sql_tables_read(tokens[:])
	mentions := own
	ambiguous := false
	for name in read {
		if strings.equal_fold(name, table) {
			mentions = true
			continue
		}
		if other := tx_table_probe(tx, name); other != nil {
			if _, found := schema_column_index(&other.schema, from); found do ambiguous = true
		}
	}
	if !mentions do return strings.clone(text, alloc)
	builder := strings.builder_make(alloc)
	last := 0
	in_of := false
	for token, i in tokens {
		if token.kind == .Ident && strings.equal_fold(token.text, "of") do in_of = own
		if token.kind == .Ident && strings.equal_fold(token.text, "on") do in_of = false
		if !sql_token_is_name(token, from) do continue
		// A function of that name is not the column.
		if i + 1 < len(tokens) && tokens[i + 1].kind == .Punct && tokens[i + 1].text == "(" do continue
		// Nor is a table of that name.
		if i + 1 < len(tokens) && tokens[i + 1].kind == .Punct && tokens[i + 1].text == "." do continue
		qualified := i > 1 && tokens[i - 1].kind == .Punct && tokens[i - 1].text == "."
		rename := false
		if qualified {
			qualifier := tokens[i - 2].text
			rename = strings.equal_fold(qualifier, table) || (own && (strings.equal_fold(qualifier, "new") || strings.equal_fold(qualifier, "old")))
			if !rename && !ambiguous {
				// An alias of the table: any qualifier that is not another table.
				is_other := false
				for name in read do is_other ||= strings.equal_fold(name, qualifier) && !strings.equal_fold(name, table)
				rename = !is_other && !strings.equal_fold(qualifier, "new") && !strings.equal_fold(qualifier, "old")
			}
		} else {
			rename = !ambiguous || in_of
		}
		if !rename do continue
		strings.write_string(&builder, text[last:token.start])
		strings.write_string(&builder, to)
		last = token.end
	}
	strings.write_string(&builder, text[last:])
	return strings.to_string(builder)
}

// alter_follow_rename_table moves the triggers of a renamed table and
// rewrites the views and trigger bodies that read it.
alter_follow_rename_table :: proc(tx: ^Tx, from, to: string) -> Error {
	saved_last, saved_total := tx.store.last_changes, tx.store.total_changes
	defer tx.store.last_changes, tx.store.total_changes = saved_last, saved_total
	for trigger in tx_triggers(tx, context.temp_allocator) {
		table_name := strings.equal_fold(trigger.table, from) ? to : trigger.table
		body := sql_rename_table_refs(trigger.body, from, to, context.temp_allocator)
		when_text := sql_rename_table_refs(trigger.when_text, from, to, context.temp_allocator)
		if table_name == trigger.table && body == trigger.body && when_text == trigger.when_text do continue
		result, err := sql_execute_in_tx_params(
			tx,
			"UPDATE _triggers SET table_name = ?, body = ?, when_text = ? WHERE name = ?",
			[]Value{value_string(table_name), value_string(body), value_string(when_text), value_string(trigger.name)},
		)
		if err.kind != .None do return err
		sql_result_destroy(&result)
	}
	for view in tx_views(tx, context.temp_allocator) {
		body := sql_rename_table_refs(view[1], from, to, context.temp_allocator)
		if body == view[1] do continue
		result, err := sql_execute_in_tx_params(tx, "UPDATE _view SET sql = ? WHERE name = ?", []Value{value_string(body), value_string(view[0])})
		if err.kind != .None do return err
		sql_result_destroy(&result)
	}
	return ERROR_NONE
}

// alter_follow_rename_column rewrites the trigger bodies, UPDATE OF lists and
// views that name a renamed column.
alter_follow_rename_column :: proc(tx: ^Tx, table, from, to: string) -> Error {
	saved_last, saved_total := tx.store.last_changes, tx.store.total_changes
	defer tx.store.last_changes, tx.store.total_changes = saved_last, saved_total
	// A trigger catalog from before UPDATE OF gains its column first.
	if tx_table_probe(tx, TRIGGER_TABLE) != nil {
		if ensure_err := trigger_ensure(tx); ensure_err.kind != .None do return ensure_err
	}
	for trigger in tx_triggers(tx, context.temp_allocator) {
		own := strings.equal_fold(trigger.table, table)
		body := sql_rename_column_refs(tx, trigger.body, table, from, to, own, context.temp_allocator)
		when_text := sql_rename_column_refs(tx, trigger.when_text, table, from, to, own, context.temp_allocator)
		columns := trigger.columns
		if own && len(columns) > 0 {
			names := strings.split(columns, ",", context.temp_allocator)
			for &name in names {
				if strings.equal_fold(name, from) do name = to
			}
			columns = strings.join(names, ",", context.temp_allocator)
		}
		if body == trigger.body && when_text == trigger.when_text && columns == trigger.columns do continue
		result, err := sql_execute_in_tx_params(
			tx,
			"UPDATE _triggers SET body = ?, when_text = ?, columns = ? WHERE name = ?",
			[]Value{value_string(body), value_string(when_text), value_string(columns), value_string(trigger.name)},
		)
		if err.kind != .None do return err
		sql_result_destroy(&result)
	}
	for view in tx_views(tx, context.temp_allocator) {
		body := sql_rename_column_refs(tx, view[1], table, from, to, false, context.temp_allocator)
		if body == view[1] do continue
		result, err := sql_execute_in_tx_params(tx, "UPDATE _view SET sql = ? WHERE name = ?", []Value{value_string(body), value_string(view[0])})
		if err.kind != .None do return err
		sql_result_destroy(&result)
	}
	return ERROR_NONE
}
