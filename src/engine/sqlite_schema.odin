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
// for an imported table the engine has not changed, else the text it was
// created with (sqlite_text.odin) when that still describes what an export
// stores, else the engine's rendering. `kept` carries the automatic indexes a
// kept text implies.
@(private)
sqlite_table_sql :: proc(store: ^Store, table: ^Table, texts: map[string]string) -> (sql: string, kept: Mirror_Kept, keep_text: bool) {
	original, imported := store_mirror_kept_lookup(store, table.schema.name)
	signature := schema_signature(&table.schema)
	defer delete(signature)
	keep_text = imported && original.kind == "table" && original.can_keep && original.signature == signature
	if keep_text do return strings.clone(original.sql), original, true
	if text, has_text := texts[table.schema.name]; has_text {
		if written, ok := sql_text_table_kept(table, text); ok do return strings.clone(text), written, true
	}
	return sqlite_master_sql(table, store), original, false
}

// sql_text_table_kept reads a table's CREATE text the way an import reads a
// file's, and answers whether an export can keep it: the record it declares
// is the one the writer stores (the same columns, the same rowid alias, no
// WITHOUT ROWID or generated column) and each automatic index it implies is
// an engine index. The key names live in the temporary allocator.
@(private)
sql_text_table_kept :: proc(table: ^Table, text: string) -> (Mirror_Kept, bool) {
	parsed := Sqlite_Table{name = table.schema.name, sql = text, pk_position = -1}
	parsed.unique_groups = make([dynamic][]int, context.temp_allocator)
	parsed.key_order = make([dynamic][]int, context.temp_allocator)
	parsed.columns = sqlite_columns_from_sql(text, context.temp_allocator)
	parsed.without_rowid = sqlite_contains_word(text, "WITHOUT ROWID")
	sqlite_constraints_from_sql(text, &parsed, context.temp_allocator)
	if len(parsed.columns) != len(table.schema.columns) do return {}, false
	if !mirror_text_keepable(&parsed) do return {}, false
	alias := -1
	for column, i in parsed.columns {
		if parsed.without_rowid do break
		if column.primary_key && strings.equal_fold(column.declared, "INTEGER") {
			alias = i
			break
		}
	}
	if alias < 0 && !parsed.without_rowid && len(parsed.primary_group) == 1 && strings.equal_fold(parsed.columns[parsed.primary_group[0]].declared, "INTEGER") {
		alias = parsed.primary_group[0]
	}
	if alias != sqlite_rowid_alias(table) do return {}, false
	keys, keys_ok := mirror_key_indexes(&parsed, &table.schema)
	if !keys_ok do return {}, false
	temp_keys := make([]string, len(keys), context.temp_allocator)
	for name, i in keys {
		temp_keys[i] = strings.clone(name, context.temp_allocator)
		delete(name)
	}
	delete(keys)
	return Mirror_Kept{kind = "table", name = table.schema.name, table = table.schema.name, sql = text, can_keep = true, key_indexes = temp_keys}, true
}

// sqlite_view_sql renders a view: the file's text when it came from one and
// still says the same, else CREATE VIEW over the stored body.
@(private)
sqlite_view_sql :: proc(store: ^Store, name, body: string, texts: map[string]string, alloc: mem.Allocator) -> string {
	if text, has_text := texts[name]; has_text do return strings.clone(text, alloc)
	if original, imported := store_mirror_kept_lookup(store, name); imported && original.kind == "view" {
		if parsed, parse_err := sql_parse(original.sql); parse_err.kind == .None {
			defer query_destroy(&parsed)
			if stmt, ok := parsed.statement.(Create_View_Stmt); ok && stmt.sql == body {
				return strings.clone(original.sql, alloc)
			}
		} else {
			error_free(&parse_err)
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
sqlite_trigger_sql :: proc(store: ^Store, trigger: Sqlite_Trigger, texts: map[string]string, alloc: mem.Allocator) -> string {
	if text, has_text := texts[trigger.name]; has_text do return strings.clone(text, alloc)
	if original, imported := store_mirror_kept_lookup(store, trigger.name); imported && original.kind == "trigger" {
		if parsed, parse_err := sql_parse(original.sql); parse_err.kind == .None {
			defer query_destroy(&parsed)
			if stmt, ok := parsed.statement.(Create_Trigger_Stmt); ok && stmt.body == trigger.body &&
			   stmt.when_text == trigger.when_text && strings.equal_fold(stmt.table, trigger.table) &&
			   stmt.event == trigger.event {
				return strings.clone(original.sql, alloc)
			}
		} else {
			error_free(&parse_err)
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

// catalog_triggers reads rows of the trigger catalog, sorted by name. The
// text is cloned: a paged table's rows are released after the read.
@(private)
catalog_triggers :: proc(rows: []Row, schema: ^Table_Schema, alloc: mem.Allocator) -> []Sqlite_Trigger {
	text :: proc(row: Row, schema: ^Table_Schema, column: string, alloc: mem.Allocator) -> string {
		position, found := schema_column_index(schema, column)
		if !found || position >= len(row.values) || row.values[position].kind != .String do return ""
		return strings.clone(row.values[position].s, alloc)
	}
	out := make([dynamic]Sqlite_Trigger, 0, len(rows), alloc)
	for row in rows {
		append(&out, Sqlite_Trigger {
			name = text(row, schema, "name", alloc),
			table = text(row, schema, "table_name", alloc),
			event = text(row, schema, "event", alloc),
			timing = text(row, schema, "timing", alloc),
			body = text(row, schema, "body", alloc),
			when_text = text(row, schema, "when_text", alloc),
			columns = text(row, schema, "columns", alloc),
		})
	}
	slice.sort_by(out[:], proc(a, b: Sqlite_Trigger) -> bool { return a.name < b.name })
	return out[:]
}

// catalog_views reads rows of the view catalog as (name, body), sorted.
@(private)
catalog_views :: proc(rows: []Row, alloc: mem.Allocator) -> [][2]string {
	out := make([dynamic][2]string, 0, len(rows), alloc)
	for row in rows {
		if len(row.values) < 2 || row.values[0].kind != .String || row.values[1].kind != .String do continue
		append(&out, [2]string{strings.clone(row.values[0].s, alloc), strings.clone(row.values[1].s, alloc)})
	}
	slice.sort_by(out[:], proc(a, b: [2]string) -> bool { return a[0] < b[0] })
	return out[:]
}

// tx_triggers reads the trigger catalog as the transaction sees it.
tx_triggers :: proc(tx: ^Tx, alloc: mem.Allocator) -> []Sqlite_Trigger {
	catalog := tx_table_probe(tx, TRIGGER_TABLE)
	if catalog == nil do return nil
	rows := make([dynamic]Row, context.temp_allocator)
	if collect_err := tx_collect(tx, TRIGGER_TABLE, &rows); collect_err.kind != .None {
		error_drop(collect_err)
		return nil
	}
	return catalog_triggers(rows[:], &catalog.schema, alloc)
}

// tx_views reads the view catalog as the transaction sees it.
tx_views :: proc(tx: ^Tx, alloc: mem.Allocator) -> [][2]string {
	if tx_table_probe(tx, VIEW_TABLE) == nil do return nil
	rows := make([dynamic]Row, context.temp_allocator)
	if collect_err := tx_collect(tx, VIEW_TABLE, &rows); collect_err.kind != .None {
		error_drop(collect_err)
		return nil
	}
	return catalog_views(rows[:], alloc)
}

// catalog_object_rows lists the views and then the triggers, with the ones a
// SQLite file held that the engine could not read after them, as the file
// had them.
@(private)
catalog_object_rows :: proc(store: ^Store, views: [][2]string, triggers: []Sqlite_Trigger, texts: map[string]string, out: ^[dynamic]Sqlite_Schema_Row, alloc: mem.Allocator) {
	for view in views {
		append(out, Sqlite_Schema_Row{type = "view", name = view[0], tbl_name = view[0], sql = sqlite_view_sql(store, view[0], view[1], texts, alloc)})
	}
	for trigger in triggers {
		append(out, Sqlite_Schema_Row{type = "trigger", name = trigger.name, tbl_name = trigger.table, sql = sqlite_trigger_sql(store, trigger, texts, alloc)})
	}
	for kept in store.mirror_kept {
		if kept.kind != "view" && kept.kind != "trigger" do continue
		if kept.modelled do continue
		modelled := false
		if kept.kind == "view" {
			for view in views do modelled ||= view[0] == kept.name
		} else {
			for trigger in triggers do modelled ||= trigger.name == kept.name
		}
		if modelled do continue
		append(out, Sqlite_Schema_Row{type = kept.kind, name = kept.name, tbl_name = kept.table, sql = kept.sql})
	}
}

// store_catalog_objects is catalog_object_rows over the committed state, for
// an export.
store_catalog_objects :: proc(store: ^Store, alloc: mem.Allocator) -> []Sqlite_Schema_Row {
	views: [][2]string
	triggers: []Sqlite_Trigger
	if table, found := store.tables[VIEW_TABLE]; found {
		rows := make([dynamic]Row, context.temp_allocator)
		table_collect(table, &rows, max(u64))
		views = catalog_views(rows[:], alloc)
		table_collect_release(table, &rows)
	}
	if table, found := store.tables[TRIGGER_TABLE]; found {
		rows := make([dynamic]Row, context.temp_allocator)
		table_collect(table, &rows, max(u64))
		triggers = catalog_triggers(rows[:], &table.schema, alloc)
		table_collect_release(table, &rows)
	}
	out := make([dynamic]Sqlite_Schema_Row, 0, len(views) + len(triggers), alloc)
	catalog_object_rows(store, views, triggers, store_sql_texts(store, context.temp_allocator), &out, alloc)
	return out[:]
}

// store_header_value is user_version or application_id as committed, for an
// export's file header.
store_header_value :: proc(store: ^Store, name: string) -> i64 {
	table, found := store.tables[HEADER_TABLE]
	if !found do return 0
	rows := make([dynamic]Row, context.temp_allocator)
	table_collect(table, &rows, max(u64))
	defer table_collect_release(table, &rows)
	for row in rows {
		if len(row.values) < 2 || row.values[0].kind != .String || row.values[1].kind != .Int do continue
		if row.values[0].s == name do return row.values[1].i
	}
	return 0
}

// sqlite_schema_rows lists the catalog the way an export writes it: each
// table, then the indexes SQLite would hold for it, then sqlite_sequence when
// a table counts AUTOINCREMENT, then the views and the triggers.
sqlite_schema_rows :: proc(tx: ^Tx, temp: bool, alloc: mem.Allocator) -> [dynamic]Sqlite_Schema_Row {
	out := make([dynamic]Sqlite_Schema_Row, 0, 8, alloc)
	names := tx_table_names(tx, context.temp_allocator)
	texts := tx_sql_texts(tx, context.temp_allocator)
	sequence := false
	for name in names {
		if strings.has_prefix(name, "_") do continue
		table := tx_table_probe(tx, name)
		if table == nil || table.schema.ephemeral != temp do continue
		if _, is_cte := tx.cte_tables[name]; is_cte do continue
		sql, original, keep_text := sqlite_table_sql(tx.store, table, texts)
		append(&out, Sqlite_Schema_Row{type = "table", name = table.schema.name, tbl_name = table.schema.name, sql = strings.clone(sql, alloc)})
		delete(sql)
		if table.schema.auto_increment_column >= 0 do sequence = true
		if keep_text {
			for index_name, order in original.key_indexes {
				index, found := sqlite_index_by_name(&table.schema, index_name)
				if !found || sqlite_is_table_key(table, &index) do continue
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
			// A WITHOUT ROWID table's key is the table's own b-tree: no row.
			if sqlite_is_table_key(table, &index) do continue
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
			if text, has_text := texts[index.name]; has_text {
				append(&out, Sqlite_Schema_Row{type = "index", name = index.name, tbl_name = table.schema.name, sql = strings.clone(text, alloc)})
				continue
			}
			index_sql := sqlite_index_sql(table, index)
			append(&out, Sqlite_Schema_Row{type = "index", name = index.name, tbl_name = table.schema.name, sql = strings.clone(index_sql, alloc)})
			delete(index_sql)
		}
		// An index the engine could not build is still the file's, and the
		// catalog lists it as SQLite does (D24).
		if !temp && tx.store.mirror_kept_indexes > 0 {
			for kept in tx.store.mirror_kept {
				if kept.kind != "index" || !strings.equal_fold(kept.table, table.schema.name) do continue
				built := false
				for index in table.schema.indexes do built ||= strings.equal_fold(index.name, kept.name)
				if !built do append(&out, Sqlite_Schema_Row{type = "index", name = kept.name, tbl_name = table.schema.name, sql = strings.clone(kept.sql, alloc)})
			}
		}
	}
	if temp do return out
	if sequence {
		append(&out, Sqlite_Schema_Row{type = "table", name = "sqlite_sequence", tbl_name = "sqlite_sequence", sql = "CREATE TABLE sqlite_sequence(name,seq)"})
	}
	catalog_object_rows(tx.store, tx_views(tx, alloc), tx_triggers(tx, alloc), texts, &out, alloc)
	sqlite_schema_order(tx, out[:])
	return out
}

// sqlite_schema_order puts the catalog in the order its objects were made, as
// SQLite lists it: each object's place is the row its CREATE text has in
// _sqlite_sql. An automatic index follows its table, sqlite_sequence the
// first table that counts AUTOINCREMENT, and an object made before the texts
// were kept keeps its place after the ones that have one.
@(private)
sqlite_schema_order :: proc(tx: ^Tx, rows: []Sqlite_Schema_Row) {
	created := make(map[string]f64, len(rows), context.temp_allocator)
	if table := tx_table_probe(tx, SQL_TEXT_TABLE); table != nil {
		stored := make([dynamic]Row, context.temp_allocator)
		if collect_err := tx_collect(tx, SQL_TEXT_TABLE, &stored); collect_err.kind == .None {
			for row in stored {
				if len(row.values) > 0 && row.values[0].kind == .String do created[row.values[0].s] = f64(row.id)
			}
		} else {
			error_free(&collect_err)
		}
	}
	Keyed :: struct {
		key:   f64,
		index: int,
		row:   Sqlite_Schema_Row,
	}
	keyed := make([]Keyed, len(rows), context.temp_allocator)
	last := f64(1e15)
	previous := f64(0)
	for row, i in rows {
		key, found := created[row.name]
		switch {
		case found:
		case row.type == "index" && row.null_sql:
			// An automatic index: right after its table.
			key = (created[row.tbl_name] or_else previous) + 0.25
		case row.name == "sqlite_sequence":
			key = previous + 0.5
			for other in rows {
				if other.type != "table" do continue
				if table := tx_table_probe(tx, other.name); table != nil && table.schema.auto_increment_column >= 0 {
					if at, has := created[other.name]; has {
						key = at + 0.5
						break
					}
				}
			}
		case:
			key = last + f64(i)
		}
		if found do previous = key
		keyed[i] = Keyed{key = key, index = i, row = row}
	}
	slice.stable_sort_by(keyed, proc(a, b: Keyed) -> bool { return a.key < b.key })
	for item, i in keyed do rows[i] = item.row
}

// tx_materialize_sqlite_schema builds the catalog as a temporary table the
// statement reads like a view. rootpage numbers the tables and indexes in
// order from 2 (page 1 is the catalog's own); views and triggers have none.
tx_materialize_sqlite_schema :: proc(tx: ^Tx, name: string, temp: bool) -> (^Table, Error) {
	if temp do tx.store.temp_used = true
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

// Sqlite_Index_Entry is one index of a table as SQLite lists it.
Sqlite_Index_Entry :: struct {
	name:    string, // SQLite's name: sqlite_autoindex_T_N for one a constraint made
	unique:  bool,
	origin:  string, // "c" CREATE INDEX, "u" UNIQUE, "pk" PRIMARY KEY
	partial: bool,
	index:   int, // its place in the table's schema.indexes
}

// sqlite_index_list is PRAGMA index_list as SQLite answers it: the rowid
// alias has no index, an index a constraint made is sqlite_autoindex_T_N
// numbered in the order the constraints are written (the numbering an export
// writes), and the newest index comes first. The names live in `alloc`.
sqlite_index_list :: proc(tx: ^Tx, table: ^Table, alloc: mem.Allocator) -> []Sqlite_Index_Entry {
	schema := &table.schema
	texts := tx_sql_texts(tx, context.temp_allocator)
	// Only the kept text's indexes are read here; the text itself is ours to free.
	table_text, original, keep_text := sqlite_table_sql(tx.store, table, texts)
	delete(table_text)
	alias := sqlite_rowid_alias(table)
	// The number SQLite gives the index a constraint made: its place among the
	// constraints the declaration writes, or, without a declaration to read,
	// among the model's implicit indexes.
	constraint_number :: proc(schema: ^Table_Schema, original: ^Mirror_Kept, keep_text: bool, alias: int, index: ^Index_Schema) -> int {
		if keep_text {
			for name, order in original.key_indexes do if name == index.name do return order + 1
			return 0
		}
		if !index.implicit do return 0
		position := 0
		for &other in schema.indexes {
			if !other.implicit || (len(other.columns) == 1 && other.columns[0] == alias) do continue
			position += 1
			if other.name == index.name do return position
		}
		return 0
	}
	created := make([dynamic]Sqlite_Index_Entry, 0, len(schema.indexes), context.temp_allocator)
	constraints := make([dynamic]Sqlite_Index_Entry, 0, len(schema.indexes), context.temp_allocator)
	numbers := make([dynamic]int, 0, len(schema.indexes), context.temp_allocator)
	for k := len(schema.indexes) - 1; k >= 0; k -= 1 {
		index := &schema.indexes[k]
		if index.implicit && len(index.columns) == 1 && index.columns[0] == alias do continue
		entry := Sqlite_Index_Entry{unique = index.unique, partial = len(index.where_sql) > 0, origin = "c", index = k}
		if number := constraint_number(schema, &original, keep_text, alias, index); number > 0 {
			is_pk := len(schema.primary_key) > 0 && schema_index_matches(index, schema.primary_key)
			entry.origin = is_pk ? "pk" : "u"
			entry.name = fmt.aprintf("sqlite_autoindex_%s_%d", schema.name, number, allocator = alloc)
			append(&constraints, entry)
			append(&numbers, number)
			continue
		}
		entry.name = strings.clone(index.name, alloc)
		append(&created, entry)
	}
	// The indexes CREATE INDEX made are newer than the table's own; the ones
	// the declaration made come newest (the last written) first.
	for i in 1 ..< len(constraints) {
		for j := i; j > 0 && numbers[j - 1] < numbers[j]; j -= 1 {
			constraints[j - 1], constraints[j] = constraints[j], constraints[j - 1]
			numbers[j - 1], numbers[j] = numbers[j], numbers[j - 1]
		}
	}
	out := make([]Sqlite_Index_Entry, len(created) + len(constraints), alloc)
	copy(out, created[:])
	copy(out[len(created):], constraints[:])
	return out
}
