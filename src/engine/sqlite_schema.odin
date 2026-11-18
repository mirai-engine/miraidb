package engine

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

// sqlite_schema is SQLite's catalog table: one row per table, index, view and
// trigger, with the statement that makes it. A program asks it which tables
// exist (`SELECT name FROM sqlite_master WHERE type = 'table'`), so the engine
// answers it like a view, materialized per statement from the live catalog.
// The rows are the ones an export of the database writes to the file's own
// sqlite_master (sqlite_write.odin): what a program reads here is what SQLite
// reads after sqlite3_serialize. sqlite_temp_schema lists the temporary tables.
//
// The `sql` text is the engine's rendering of the object, except for an object
// imported from a SQLite file and not changed since, which keeps the text the
// file had: SQLite keeps the statement as it was written.

// SQLITE_SCHEMA_COLUMNS names the catalog's columns. It is a package variable,
// not a literal at the use: a slice literal lives in the frame that makes it.
SQLITE_SCHEMA_COLUMNS := []string{"type", "name", "tbl_name", "rootpage", "sql"}

// sqlite_schema_name reports one of the names SQLite gives its catalog, and
// whether it is the temporary one.
sqlite_schema_name :: proc(name: string) -> (is_schema: bool, temp: bool) {
	for candidate in ([]string{"sqlite_schema", "sqlite_master"}) {
		if strings.equal_fold(name, candidate) do return true, false
	}
	for candidate in ([]string{"sqlite_temp_schema", "sqlite_temp_master"}) {
		if strings.equal_fold(name, candidate) do return true, true
	}
	return false, false
}

// Sqlite_Schema_Row is one row of the catalog.
Sqlite_Schema_Row :: struct {
	type:     string,
	name:     string,
	tbl_name: string,
	// sql is empty for an automatic index, whose sql SQLite stores as NULL.
	sql:      string,
	null_sql: bool,
}

// tx_table_names lists the tables the transaction sees, sorted: the committed
// ones (or the snapshot a read holds), plus what it created, minus what it
// dropped.
@(private)
tx_table_names :: proc(tx: ^Tx, alloc: mem.Allocator) -> []string {
	seen := make(map[string]bool, 16, context.temp_allocator)
	names := make([dynamic]string, 0, len(tx.store.tables), alloc)
	add :: proc(seen: ^map[string]bool, names: ^[dynamic]string, name: string) {
		if name in seen do return
		seen[name] = true
		append(names, name)
	}
	if tx.use_frozen {
		for name in tx.frozen do add(&seen, &names, name)
	} else {
		for name in tx.store.tables do add(&seen, &names, name)
	}
	for name in tx.state.created do add(&seen, &names, name)
	kept := make([dynamic]string, 0, len(names), alloc)
	for name in names {
		if tx_table_probe(tx, name) != nil do append(&kept, name)
	}
	delete(names)
	slice_sort_strings(kept[:])
	return kept[:]
}

// sqlite_table_sql is the CREATE TABLE text of a table: the file's own text
// for an imported table the engine has not changed, else the engine's.
@(private)
sqlite_table_sql :: proc(store: ^Store, table: ^Table) -> (sql: string, kept: Mirror_Kept, keep_text: bool) {
	original, imported := store_mirror_kept_lookup(store, table.schema.name)
	keep_text = imported && original.kind == "table" && original.can_keep &&
		original.signature == schema_signature(&table.schema)
	if keep_text do return strings.clone(original.sql), original, true
	return sqlite_master_sql(table), original, false
}

// sqlite_view_sql renders a view: the file's text when it came from one and
// still says the same, else CREATE VIEW over the stored body.
@(private)
sqlite_view_sql :: proc(store: ^Store, name, body: string, alloc: mem.Allocator) -> string {
	if original, imported := store_mirror_kept_lookup(store, name); imported && original.kind == "view" {
		if parsed, parse_err := sql_parse(original.sql); parse_err.kind == .None {
			defer query_destroy(&parsed)
			if stmt, ok := parsed.statement.(Create_View_Stmt); ok && stmt.sql == body {
				return strings.clone(original.sql, alloc)
			}
		}
	}
	builder := strings.builder_make(alloc)
	strings.write_string(&builder, "CREATE VIEW ")
	sqlite_write_ident(&builder, name)
	strings.write_string(&builder, " AS ")
	strings.write_string(&builder, body)
	return strings.to_string(builder)
}

// Sqlite_Trigger is one row of the trigger catalog, as the SQL text needs it.
Sqlite_Trigger :: struct {
	name:      string,
	table:     string,
	event:     string,
	timing:    string,
	body:      string,
	when_text: string,
	columns:   string,
}

// sqlite_trigger_sql renders a trigger: the file's text when it came from one
// and still says the same, else a CREATE TRIGGER built from the catalog row.
@(private)
sqlite_trigger_sql :: proc(store: ^Store, trigger: Sqlite_Trigger, alloc: mem.Allocator) -> string {
	if original, imported := store_mirror_kept_lookup(store, trigger.name); imported && original.kind == "trigger" {
		if parsed, parse_err := sql_parse(original.sql); parse_err.kind == .None {
			defer query_destroy(&parsed)
			if stmt, ok := parsed.statement.(Create_Trigger_Stmt); ok && stmt.body == trigger.body &&
			   stmt.when_text == trigger.when_text && strings.equal_fold(stmt.table, trigger.table) &&
			   stmt.event == trigger.event {
				return strings.clone(original.sql, alloc)
			}
		}
	}
	builder := strings.builder_make(alloc)
	strings.write_string(&builder, "CREATE TRIGGER ")
	sqlite_write_ident(&builder, trigger.name)
	switch trigger.timing {
	case "before":
		strings.write_string(&builder, " BEFORE ")
	case "instead":
		strings.write_string(&builder, " INSTEAD OF ")
	case:
		strings.write_string(&builder, " AFTER ")
	}
	strings.write_string(&builder, strings.to_upper(trigger.event, context.temp_allocator))
	if len(trigger.columns) > 0 {
		strings.write_string(&builder, " OF ")
		for column, i in strings.split(trigger.columns, ",", context.temp_allocator) {
			if i > 0 do strings.write_string(&builder, ", ")
			sqlite_write_ident(&builder, column)
		}
	}
	strings.write_string(&builder, " ON ")
	sqlite_write_ident(&builder, trigger.table)
	if len(trigger.when_text) > 0 {
		strings.write_string(&builder, " WHEN ")
		strings.write_string(&builder, trigger.when_text)
	}
	strings.write_string(&builder, " BEGIN ")
	body := strings.trim_space(trigger.body)
	strings.write_string(&builder, body)
	if !strings.has_suffix(body, ";") do strings.write_byte(&builder, ';')
	strings.write_string(&builder, " END")
	return strings.to_string(builder)
}

// tx_triggers reads the trigger catalog, sorted by name.
tx_triggers :: proc(tx: ^Tx, alloc: mem.Allocator) -> []Sqlite_Trigger {
	if tx_table_probe(tx, TRIGGER_TABLE) == nil do return nil
	catalog := tx_table_probe(tx, TRIGGER_TABLE)
	rows := make([dynamic]Row, context.temp_allocator)
	if collect_err := tx_collect(tx, TRIGGER_TABLE, &rows); collect_err.kind != .None {
		error_drop(collect_err)
		return nil
	}
	text :: proc(row: Row, schema: ^Table_Schema, column: string) -> string {
		position, found := schema_column_index(schema, column)
		if !found || position >= len(row.values) || row.values[position].kind != .String do return ""
		return row.values[position].s
	}
	out := make([dynamic]Sqlite_Trigger, 0, len(rows), alloc)
	for row in rows {
		append(&out, Sqlite_Trigger {
			name = text(row, &catalog.schema, "name"),
			table = text(row, &catalog.schema, "table_name"),
			event = text(row, &catalog.schema, "event"),
			timing = text(row, &catalog.schema, "timing"),
			body = text(row, &catalog.schema, "body"),
			when_text = text(row, &catalog.schema, "when_text"),
			columns = text(row, &catalog.schema, "columns"),
		})
	}
	slice.sort_by(out[:], proc(a, b: Sqlite_Trigger) -> bool { return a.name < b.name })
	return out[:]
}

// tx_views reads the view catalog as (name, body) pairs, sorted by name.
tx_views :: proc(tx: ^Tx, alloc: mem.Allocator) -> [][2]string {
	if tx_table_probe(tx, VIEW_TABLE) == nil do return nil
	rows := make([dynamic]Row, context.temp_allocator)
	if collect_err := tx_collect(tx, VIEW_TABLE, &rows); collect_err.kind != .None {
		error_drop(collect_err)
		return nil
	}
	out := make([dynamic][2]string, 0, len(rows), alloc)
	for row in rows {
		if len(row.values) < 2 || row.values[0].kind != .String || row.values[1].kind != .String do continue
		append(&out, [2]string{row.values[0].s, row.values[1].s})
	}
	slice.sort_by(out[:], proc(a, b: [2]string) -> bool { return a[0] < b[0] })
	return out[:]
}

// sqlite_schema_rows lists the catalog the way an export writes it: each
// table, then the indexes SQLite would hold for it, then sqlite_sequence when
// a table counts AUTOINCREMENT, then the views and the triggers.
sqlite_schema_rows :: proc(tx: ^Tx, temp: bool, alloc: mem.Allocator) -> [dynamic]Sqlite_Schema_Row {
	out := make([dynamic]Sqlite_Schema_Row, 0, 8, alloc)
	names := tx_table_names(tx, context.temp_allocator)
	sequence := false
	for name in names {
		if strings.has_prefix(name, "_") do continue
		table := tx_table_probe(tx, name)
		if table == nil || table.schema.ephemeral != temp do continue
		if _, is_cte := tx.cte_tables[name]; is_cte do continue
		sql, original, keep_text := sqlite_table_sql(tx.store, table)
		append(&out, Sqlite_Schema_Row{type = "table", name = table.schema.name, tbl_name = table.schema.name, sql = strings.clone(sql, alloc)})
		delete(sql)
		if table.schema.auto_increment_column >= 0 do sequence = true
		if keep_text {
			for index_name, order in original.key_indexes {
				if _, found := sqlite_index_by_name(&table.schema, index_name); !found do continue
				append(&out, Sqlite_Schema_Row {
					type = "index",
					name = fmt.aprintf("sqlite_autoindex_%s_%d", table.schema.name, order + 1, allocator = alloc),
					tbl_name = table.schema.name,
					null_sql = true,
				})
			}
		}
		alias := sqlite_rowid_alias(table)
		for &index in table.schema.indexes {
			if index.implicit && len(index.columns) == 1 && index.columns[0] == alias do continue
			if keep_text && sqlite_name_in(original.key_indexes, index.name) do continue
			implied := !keep_text && index.unique && len(table.schema.primary_key) > 0 &&
				schema_index_matches(&index, table.schema.primary_key)
			if implied {
				append(&out, Sqlite_Schema_Row {
					type = "index",
					name = fmt.aprintf("sqlite_autoindex_%s_1", table.schema.name, allocator = alloc),
					tbl_name = table.schema.name,
					null_sql = true,
				})
				continue
			}
			index_sql := sqlite_index_sql(table, index)
			append(&out, Sqlite_Schema_Row{type = "index", name = index.name, tbl_name = table.schema.name, sql = strings.clone(index_sql, alloc)})
			delete(index_sql)
		}
	}
	if temp do return out
	if sequence {
		append(&out, Sqlite_Schema_Row{type = "table", name = "sqlite_sequence", tbl_name = "sqlite_sequence", sql = "CREATE TABLE sqlite_sequence(name,seq)"})
	}
	for view in tx_views(tx, context.temp_allocator) {
		append(&out, Sqlite_Schema_Row{type = "view", name = view[0], tbl_name = view[0], sql = sqlite_view_sql(tx.store, view[0], view[1], alloc)})
	}
	for trigger in tx_triggers(tx, context.temp_allocator) {
		append(&out, Sqlite_Schema_Row{type = "trigger", name = trigger.name, tbl_name = trigger.table, sql = sqlite_trigger_sql(tx.store, trigger, alloc)})
	}
	return out
}

// tx_materialize_sqlite_schema builds the catalog as a temporary table the
// statement reads like a view. rootpage numbers the tables and indexes in
// order from 2 (page 1 is the catalog's own); views and triggers have none.
tx_materialize_sqlite_schema :: proc(tx: ^Tx, name: string, temp: bool) -> (^Table, Error) {
	rows := sqlite_schema_rows(tx, temp, tx.alloc)
	text := Column_Type{kind = .String, width = 8}
	columns := make([]Column, 5, tx.alloc)
	columns[0] = Column{name = "type", type = text}
	columns[1] = Column{name = "name", type = text}
	columns[2] = Column{name = "tbl_name", type = text}
	columns[3] = Column{name = "rootpage", type = Column_Type{kind = .Int, width = 8}}
	columns[4] = Column{name = "sql", type = text}
	schema := Table_Schema{name = strings.clone(name, tx.alloc), columns = columns}
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	page := i64(2)
	for row, i in rows {
		values := make([]Value, 5, tx.alloc)
		values[0] = value_string(row.type)
		values[1] = value_string(row.name)
		values[2] = value_string(row.tbl_name)
		if row.type == "table" || row.type == "index" {
			values[3] = value_int(page)
			page += 1
		} else {
			values[3] = value_int(0)
		}
		values[4] = row.null_sql ? value_null() : value_string(row.sql)
		if insert_err := table_insert(table, Row_Id(i + 1), values); insert_err.kind != .None {
			table_destroy(table)
			return nil, insert_err
		}
	}
	append(&tx.temp_tables, table)
	return table, ERROR_NONE
}
