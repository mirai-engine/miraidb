package engine

// PRAGMA statements.
//
// SQLite clients lean on PRAGMA for introspection and for a handful of settings.
// The engine keeps its catalog in ordinary tables, so most pragmas are simply a
// projection of that catalog; the ones that change a setting store it in the
// session variables, exactly like SET.
//
// The statement is recognised before parsing because PRAGMA is not part of the
// engine's own grammar: `PRAGMA name`, `PRAGMA name = value` and
// `PRAGMA name(arg)` all reach `sql_exec_pragma`.

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"

// sqlite_pragma_statement reports whether the text is a PRAGMA and returns its
// body (the part after the keyword).
sqlite_pragma_statement :: proc(sql: string) -> (body: string, is_pragma: bool) {
	// Comments may come first, as SQLite reads them: `-- note` on a line of
	// its own, or `/* note */`, before PRAGMA.
	trimmed := strings.trim_space(sql)
	for {
		if strings.has_prefix(trimmed, "--") {
			end := strings.index_byte(trimmed, '\n')
			if end < 0 do return "", false
			trimmed = strings.trim_space(trimmed[end + 1:])
		} else if strings.has_prefix(trimmed, "/*") {
			end := strings.index(trimmed[2:], "*/")
			if end < 0 do return "", false
			trimmed = strings.trim_space(trimmed[end + 4:])
		} else {
			break
		}
	}
	upper := strings.to_upper(trimmed, context.temp_allocator)
	if !strings.has_prefix(upper, "PRAGMA") do return "", false
	if len(trimmed) > 6 {
		next := trimmed[6]
		if next != ' ' && next != '\t' && next != '(' && next != '=' && next != '\n' {
			return "", false
		}
	}
	// A statement usually arrives with its terminator: `PRAGMA name;` means the
	// same as `PRAGMA name`.
	body = strings.trim_right(strings.trim_space(trimmed[6:]), "; \t\r\n")
	// `PRAGMA main.name` (or "main", temp) asks the database itself, as
	// `PRAGMA name` does: the shell writes the schema quoted.
	for prefix in ([]string{"main.", "\"main\".", "temp.", "\"temp\"."}) {
		if len(body) > len(prefix) && strings.equal_fold(body[:len(prefix)], prefix) {
			body = strings.trim_space(body[len(prefix):])
			break
		}
	}
	return body, true
}

// pragma_sqlite_table_list is PRAGMA table_list as SQLite answers it: every
// table, view, virtual table and shadow table of main, then sqlite_schema,
// then temp's (which this makes, as SQLite's does: database_list lists it from
// here on), each with its column count, WITHOUT ROWID and STRICT. The engine's
// own catalogs (a leading underscore) are not SQLite's and are left out.
@(private)
pragma_sqlite_table_list :: proc(store: ^Store, tx: ^Tx) -> Sql_Result {
	reader := tx
	if reader == nil do reader = tx_begin_read(store)
	defer if tx == nil do tx_end(reader)
	store.temp_used = true
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = pragma_columns("schema", "name", "type", "ncol", "wr", "strict")
	rows := make([dynamic][]Value)
	add :: proc(rows: ^[dynamic][]Value, schema, name, kind: string, ncol: int, without_rowid, strict: bool) {
		row := make([]Value, 6)
		row[0] = pragma_text(schema)
		row[1] = pragma_text(name)
		row[2] = pragma_text(kind)
		row[3] = value_int(i64(ncol))
		row[4] = value_int(without_rowid ? 1 : 0)
		row[5] = value_int(strict ? 1 : 0)
		append(rows, row)
	}
	shadows := make(map[string]bool, 8, context.temp_allocator)
	virtuals := make(map[string]bool, 8, context.temp_allocator)
	for name in tx_table_names(reader, context.temp_allocator) {
		if table, found := fts_virtual_lookup(reader, name); found {
			virtuals[strings.to_lower(table.name, context.temp_allocator)] = true
			for suffix in fts_shadow_suffixes(table.module) {
				shadows[strings.to_lower(strings.concatenate({table.name, suffix}, context.temp_allocator), context.temp_allocator)] = true
			}
		}
	}
	for temp in ([]bool{false, true}) {
		schema_name := temp ? "temp" : "main"
		for name in tx_table_names(reader, context.temp_allocator) {
			if strings.has_prefix(name, "_") do continue
			table := tx_table_probe(reader, name)
			if table == nil || table.schema.ephemeral != temp do continue
			lower := strings.to_lower(name, context.temp_allocator)
			kind := virtuals[lower] ? "virtual" : shadows[lower] ? "shadow" : "table"
			add(&rows, schema_name, table.schema.name, kind, len(table.schema.columns), table.schema.without_rowid, table.schema.strict)
		}
		if !temp {
			if views, views_err := view_names(reader, context.temp_allocator); views_err.kind == .None {
				for view in views {
					count := 0
					if info, is_view := pragma_view_info(store, reader, view); is_view {
						count = len(info.rows)
						sql_result_destroy(&info)
					}
					add(&rows, "main", view, "view", count, false, false)
				}
			} else {
				error_free(&views_err)
			}
		}
		add(&rows, schema_name, temp ? "sqlite_temp_schema" : "sqlite_schema", "table", 5, false, false)
	}
	result.rows = rows[:]
	return result
}

// pragma_catalog_info is PRAGMA table_info of SQLite's own tables, which the
// engine answers from its catalog rather than keeping as tables:
// sqlite_schema (and its other names) with SQLite's declared types, and
// sqlite_sequence, declared without types, when a table counts AUTOINCREMENT.
// The shell's .dump reads the columns of sqlite_sequence this way.
@(private)
pragma_catalog_info :: proc(store: ^Store, tx: ^Tx, name: string) -> (Sql_Result, bool) {
	names: []string
	types: []string
	if is_schema, _ := sqlite_schema_name(name); is_schema {
		names = {"type", "name", "tbl_name", "rootpage", "sql"}
		types = {"TEXT", "TEXT", "TEXT", "INT", "TEXT"}
	} else if strings.equal_fold(name, "sqlite_sequence") {
		reader := tx
		if reader == nil do reader = tx_begin_read(store)
		defer if tx == nil do tx_end(reader)
		if !sqlite_sequence_exists(reader) do return {}, false
		names = {"name", "seq"}
		types = {"", ""}
	} else {
		return {}, false
	}
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = pragma_columns("cid", "name", "type", "notnull", "dflt_value", "pk")
	result.rows = make([][]Value, len(names))
	for column, i in names {
		row := make([]Value, 6)
		row[0] = value_int(i64(i))
		row[1] = pragma_text(column)
		row[2] = pragma_text(types[i])
		row[3] = value_int(0)
		row[4] = value_null()
		row[5] = value_int(0)
		result.rows[i] = row
	}
	return result, true
}

// pragma_view_info is PRAGMA table_info of a view, as SQLite answers it: the
// view's result columns, each with the declared type of the table column it
// reads ("" for an expression), nullable and no key.
@(private)
pragma_view_info :: proc(store: ^Store, tx: ^Tx, name: string) -> (Sql_Result, bool) {
	reader := tx
	if reader == nil do reader = tx_begin_read(store)
	defer if tx == nil do tx_end(reader)
	body, is_view := view_sql(reader, name)
	if !is_view do return {}, false
	probe := strings.concatenate({"SELECT * FROM ", name, " LIMIT 0"}, context.temp_allocator)
	shape, shape_err := sql_execute_in_tx(reader, probe)
	if shape_err.kind != .None {
		error_free(&shape_err)
		return {}, false
	}
	defer sql_result_destroy(&shape)
	types := make([]string, len(shape.columns), context.temp_allocator)
	if query, parse_err := sql_parse(body); parse_err.kind == .None {
		defer query_destroy(&query)
		if origins, described := sql_describe_origins(reader, query.statement, context.temp_allocator); described && len(origins) == len(types) {
			for origin, i in origins do types[i] = strings.clone(origin.decltype, context.temp_allocator)
		}
	} else {
		error_free(&parse_err)
	}
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = pragma_columns("cid", "name", "type", "notnull", "dflt_value", "pk")
	result.rows = make([][]Value, len(shape.columns))
	for column, i in shape.columns {
		row := make([]Value, 6)
		row[0] = value_int(i64(i))
		row[1] = pragma_text(column)
		row[2] = pragma_text(types[i])
		row[3] = value_int(0)
		row[4] = value_null()
		row[5] = value_int(0)
		result.rows[i] = row
	}
	return result, true
}

// pragma_columns clones literal column names: sql_result_destroy frees them.
@(private)
pragma_columns :: proc(names: ..string) -> []string {
	columns := make([]string, len(names))
	for name, i in names do columns[i] = strings.clone(name)
	return columns
}

// pragma_text clones a borrowed catalog string, because result values are
// freed by sql_result_destroy.
// PRAGMA_NAMES lists the pragmas the engine answers; pragma_list reports them.
PRAGMA_NAMES := []string{
	"application_id", "cache_size", "collation_list", "compile_options",
	"data_store_directory", "database_list", "data_version",
	"encoding",
	"foreign_key_list", "foreign_keys", "function_list", "index_info", "index_list",
	"incremental_vacuum", "legacy_file_format", "module_list",
	"foreign_key_check", "integrity_check", "journal_mode", "locking_mode", "mmap_size", "page_size",
	"freelist_count", "page_count", "pragma_list", "quick_check", "schema_version",
	"shrink_memory", "soft_heap_limit64",
	"sqlite_version", "stats",
	"synchronous", "table_info",
	"table_list", "table_xinfo", "temp_store", "temp_store_directory", "user_version",
}

// PRAGMA_FUNCTIONS lists the built-in functions for function_list.
PRAGMA_FUNCTIONS := []string{
	"abs", "avg", "ceil", "char", "coalesce", "concat", "count", "floor", "format",
	"hex", "iif", "ifnull", "instr", "length", "lower", "ltrim", "max", "min", "mod",
	"nullif", "pow", "printf", "quote", "replace", "round", "rtrim", "sign", "sqrt",
	"sqlite_version", "substr", "sum", "total", "trim", "typeof", "upper",
}

// PRAGMA_ACCEPTED are tuning knobs the engine has no equivalent for. They are
// accepted so a tool that sets them does not fail, and a read answers neutrally.
PRAGMA_ACCEPTED := []string{
	"auto_vacuum", "automatic_index", "busy_timeout", "cache_spill", "cell_size_check",
	"checkpoint_fullfsync", "count_changes", "default_cache_size", "fullfsync",
	"full_column_names", "hard_heap_limit", "journal_size_limit", "optimize",
	"secure_delete", "short_column_names", "soft_heap_limit", "threads",
	"wal_autocheckpoint", "wal_checkpoint",
}

// PRAGMA_REFUSED name knobs that change what a statement does. Accepting one
// silently would make a caller believe a guarantee the engine does not give, so
// a read answers the truth and a write is an error.
PRAGMA_REFUSED := []string{
	"case_sensitive_like", "defer_foreign_keys", "ignore_check_constraints",
	"legacy_alter_table", "query_only", "read_uncommitted",
	"recursive_triggers", "reverse_unordered_selects", "trusted_schema",
	"writable_schema",
}

@(private)
pragma_text :: proc(value: string) -> Value {
	return value_string(strings.clone(value))
}

// pragma_attached splits `schema.rest` off a PRAGMA body when `schema` names
// a database attached to `store`; main and temp were taken off before.
@(private)
pragma_attached :: proc(store: ^Store, body: string) -> (schema, rest: string, attached: ^Store) {
	if len(store.attached) == 0 do return "", body, nil
	end := len(body)
	if open := strings.index_any(body, "(="); open >= 0 do end = open
	dot := -1
	if len(body) > 0 && (body[0] == '"' || body[0] == '`' || body[0] == '[') {
		closing := body[0] == '[' ? u8(']') : body[0]
		quote_end := strings.index_byte(body[1:], closing)
		if quote_end < 0 do return "", body, nil
		schema = body[1:1 + quote_end]
		after := strings.trim_left_space(body[2 + quote_end:])
		if !strings.has_prefix(after, ".") do return "", body, nil
		rest = strings.trim_space(after[1:])
	} else {
		dot = strings.index_byte(body[:end], '.')
		if dot < 0 do return "", body, nil
		schema = strings.trim_space(body[:dot])
		rest = strings.trim_space(body[dot + 1:])
	}
	for name, candidate in store.attached {
		if strings.equal_fold(name, schema) do return name, rest, candidate
	}
	return "", body, nil
}

@(private)
pragma_result :: proc(columns: []string, rows: [][]Value, commit_seq: u64) -> Sql_Result {
	result := Sql_Result{kind = .Rows, commit_seq = commit_seq}
	result.columns = make([]string, len(columns))
	for column, i in columns do result.columns[i] = strings.clone(column)
	result.rows = make([][]Value, len(rows))
	for row, i in rows do result.rows[i] = row
	// Every caller builds `rows` for this call and never looks at it again: the row
	// slices belong to the result now, the array that held them does not.
	if rows != nil do delete(rows)
	return result
}

@(private)
pragma_single :: proc(column: string, value: Value, commit_seq: u64) -> Sql_Result {
	row := make([]Value, 1)
	row[0] = value
	rows := make([][]Value, 1)
	rows[0] = row
	return pragma_result([]string{column}, rows, commit_seq)
}

// sql_exec_pragma runs a PRAGMA. `locked` says whether the caller already holds
// the store lock (a transaction does); `tx` is the transaction it runs in, if
// any.
sql_exec_pragma :: proc(store: ^Store, body: string, locked: bool, tx: ^Tx = nil) -> (Sql_Result, Error) {
	// `PRAGMA aux.name` asks the attached database: through the transaction
	// that writes it, when there is one, as SQLite reads it there.
	if schema, rest, attached := pragma_attached(store, body); attached != nil {
		if tx != nil {
			if writer, open := tx.attached_txs[schema]; open do return sql_exec_pragma(attached, rest, writer.locked, writer)
		}
		// One that describes the schema reads it in a transaction of that
		// database, where the declared text is.
		end := len(rest)
		if open := strings.index_any(rest, "(="); open >= 0 do end = open
		switch strings.to_lower(strings.trim_space(rest[:end]), context.temp_allocator) {
		case "table_info", "table_xinfo", "index_list", "index_info", "index_xinfo", "foreign_key_list":
			reader := tx_begin_read(attached)
			defer tx_end(reader)
			return sql_exec_pragma(attached, rest, reader.locked, reader)
		}
		return sql_exec_pragma(attached, rest, false)
	}
	name := body
	argument := ""
	has_argument := false
	if open := strings.index_byte(body, '('); open >= 0 {
		close := strings.index_byte(body[open:], ')')
		if close > 0 {
			argument = strings.trim_space(body[open + 1:open + close])
			name = strings.trim_space(body[:open])
			has_argument = true
		}
	} else if assign := strings.index_byte(body, '='); assign >= 0 {
		argument = strings.trim_space(body[assign + 1:])
		name = strings.trim_space(body[:assign])
		has_argument = true
	}
	trimmed_name := strings.trim_space(name)
	lowered_name := strings.to_lower(trimmed_name)
	// `to_lower` answers its own argument when the text is already lowercase, so only
	// a copy of its own may be freed (trap 53): the statement text outlives this call.
	lowered_owned := raw_data(lowered_name) != raw_data(trimmed_name)
	defer if lowered_owned do delete(lowered_name)
	name = lowered_name
	argument = pragma_unquote(argument)
	// These two are stored data, written and read through a transaction, so
	// they are taken before the catalog lock the others read under.
	if name == "user_version" || name == "application_id" {
		return pragma_header_value(store, tx, name, argument, has_argument)
	}
	if name == "page_size" && has_argument {
		return pragma_page_size_set(store, tx, argument)
	}
	if !locked {
		sync.shared_lock(&store.mutex)
		defer sync.shared_unlock(&store.mutex)
	}
	switch name {
	case "table_info", "table_xinfo":
		table, found := pragma_table(store, tx, argument)
		if !found {
			if store.sqlite_rules {
				if view_result, is_view := pragma_view_info(store, tx, argument); is_view do return view_result, ERROR_NONE
				if catalog_result, is_catalog := pragma_catalog_info(store, tx, argument); is_catalog do return catalog_result, ERROR_NONE
			}
			return pragma_result([]string{"cid", "name", "type", "notnull", "dflt_value", "pk"}, nil, store.commit_seq), ERROR_NONE
		}
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("cid", "name", "type", "notnull", "dflt_value", "pk")
		result.rows = make([][]Value, len(table.schema.columns))
		// The type is the one the column was declared with, as SQLite answers:
		// from the text the table was created with, or the file's own text
		// for an imported table; the engine's type name otherwise.
		declared: map[string]string
		table_text, has_text := store_sql_texts(store, context.temp_allocator)[argument]
		if !has_text {
			if kept, imported := store_mirror_kept_lookup(store, argument); imported && kept.kind == "table" {
				table_text, has_text = kept.sql, true
			}
		}
		if has_text do declared = sql_text_declared_types(table_text, context.temp_allocator)
		for column, i in table.schema.columns {
			row := make([]Value, 6)
			row[0] = value_int(i64(i))
			row[1] = pragma_text(column.name)
			if type_text, has_type := declared[strings.to_lower(column.name, context.temp_allocator)]; has_type {
				row[2] = pragma_text(type_text)
			} else {
				row[2] = pragma_text(column_type_name(column.type))
			}
			// The rowid alias (one INTEGER key) reads 0, as SQLite reports it:
			// its NULL becomes the next rowid rather than a refusal.
			rowid_alias := len(table.schema.primary_key) == 1 && table.schema.primary_key[0] == i &&
				column.type.kind == .Int && !table.schema.without_rowid
			row[3] = value_int(column.not_null && !rowid_alias ? 1 : 0)
			if column.has_default {
				row[4] = value_string(value_format(column.default_value, context.allocator))
			} else {
				row[4] = value_null()
			}
			row[5] = value_int(is_pragma_pk(table.schema.primary_key, i) ? 1 : 0)
			result.rows[i] = row
		}
		return result, ERROR_NONE
	case "index_list":
		table, found := pragma_table(store, tx, argument)
		if !found {
			return pragma_result([]string{"seq", "name", "unique", "origin", "partial"}, nil, store.commit_seq), ERROR_NONE
		}
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("seq", "name", "unique", "origin", "partial")
		if store.sqlite_rules {
			reader := tx
			if reader == nil do reader = tx_begin_read(store)
			defer if tx == nil do tx_end(reader)
			entries := sqlite_index_list(reader, table, context.temp_allocator)
			result.rows = make([][]Value, len(entries))
			for entry, i in entries {
				row := make([]Value, 5)
				row[0] = value_int(i64(i))
				row[1] = pragma_text(entry.name)
				row[2] = value_int(entry.unique ? 1 : 0)
				row[3] = pragma_text(entry.origin)
				row[4] = value_int(entry.partial ? 1 : 0)
				result.rows[i] = row
			}
			return result, ERROR_NONE
		}
		result.rows = make([][]Value, len(table.schema.indexes))
		for index, i in table.schema.indexes {
			row := make([]Value, 5)
			row[0] = value_int(i64(i))
			row[1] = pragma_text(index.name)
			row[2] = value_int(index.unique ? 1 : 0)
			row[3] = pragma_text(is_pragma_pk(index.columns, 0) ? "pk" : "c")
			row[4] = value_int(0)
			result.rows[i] = row
		}
		return result, ERROR_NONE
	case "index_info", "index_xinfo":
		extended := name == "index_xinfo"
		columns := extended ? []string{"seqno", "cid", "name", "desc", "coll", "key"} : []string{"seqno", "cid", "name"}
		table, position, found := pragma_find_index(store, tx, argument)
		if !found do return pragma_result(columns, nil, store.commit_seq), ERROR_NONE
		return pragma_index_info(table, position, extended, columns, store.commit_seq), ERROR_NONE
	case "foreign_key_list":
		table, found := pragma_table(store, tx, argument)
		if !found {
			return pragma_result([]string{"id", "seq", "table", "from", "to", "on_update", "on_delete"}, nil, store.commit_seq), ERROR_NONE
		}
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("id", "seq", "table", "from", "to", "on_update", "on_delete")
		result.rows = make([][]Value, len(table.schema.foreign_keys))
		for key, i in table.schema.foreign_keys {
			row := make([]Value, 7)
			row[0] = value_int(i64(i))
			row[1] = value_int(0)
			row[2] = pragma_text(key.ref_table)
			// The catalog stores column positions; the pragma wants names.
			row[3] = pragma_text(pragma_column_name(table, key.columns[0]))
			row[4] = pragma_text(pragma_referenced_name(store, key, 0))
			row[5] = pragma_text(pragma_action_name(key.on_update))
			row[6] = pragma_text(pragma_action_name(key.on_delete))
			result.rows[i] = row
		}
		return result, ERROR_NONE
	case "database_list":
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("seq", "name", "file")
		rows := make([dynamic][]Value, 0, 2 + len(store.attached))
		file := store.path
		if len(file) == 0 do file = store.sqlite_mirror
		// SQLite names the file by its full path, lists temp once it has been
		// used, and then each attached database.
		if store.sqlite_rules && len(file) > 0 {
			if absolute, abs_err := filepath.abs(file, context.temp_allocator); abs_err == nil do file = absolute
		}
		main_row := make([]Value, 3)
		main_row[0] = value_int(0)
		main_row[1] = pragma_text("main")
		main_row[2] = pragma_text(file)
		append(&rows, main_row)
		if store.sqlite_rules {
			if store.temp_used {
				temp_row := make([]Value, 3)
				temp_row[0] = value_int(1)
				temp_row[1] = pragma_text("temp")
				temp_row[2] = pragma_text("")
				append(&rows, temp_row)
			}
			names := make([dynamic]string, 0, len(store.attached), context.temp_allocator)
			for attached_name in store.attached do append(&names, attached_name)
			slice_sort_strings(names[:])
			for attached_name, k in names {
				attached := store.attached[attached_name]
				path := attached.path
				if len(path) == 0 do path = attached.sqlite_mirror
				if len(path) > 0 {
					if absolute, abs_err := filepath.abs(path, context.temp_allocator); abs_err == nil do path = absolute
				}
				row := make([]Value, 3)
				row[0] = value_int(i64(k + 2))
				row[1] = pragma_text(attached_name)
				row[2] = pragma_text(path)
				append(&rows, row)
			}
		}
		result.rows = rows[:]
		return result, ERROR_NONE
	case "table_list":
		if store.sqlite_rules do return pragma_sqlite_table_list(store, tx), ERROR_NONE
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("schema", "name", "type", "ncol", "wr", "strict")
		// The names are the map's keys, which the tables own: only the slice
		// is this call's.
		names := store_table_names(store, context.allocator)
		defer delete(names)
		result.rows = make([][]Value, len(names))
		for table_name, i in names {
			table := store.tables[table_name]
			row := make([]Value, 6)
			row[0] = pragma_text("main")
			row[1] = pragma_text(table_name)
			row[2] = pragma_text("table")
			row[3] = value_int(i64(len(table.schema.columns)))
			row[4] = value_int(0)
			row[5] = value_int(0)
			result.rows[i] = row
		}
		return result, ERROR_NONE
	case "schema_version":
		return pragma_single("schema_version", value_int(i64(store.commit_seq)), store.commit_seq), ERROR_NONE
	case "page_size":
		// The engine is a log, not a page file; this is the page size its SQLite
		// form uses: the file's, or the one a VACUUM set (pragma_page_size_set).
		return pragma_single("page_size", value_int(i64(store_sqlite_page_size(store))), store.commit_seq), ERROR_NONE
	case "encoding":
		return pragma_single("encoding", pragma_text("UTF-8"), store.commit_seq), ERROR_NONE
	case "journal_mode":
		// There is no rollback journal and no WAL: a commit is one durable log
		// record. The closest SQLite mode is `delete` (the durable default);
		// an ephemeral log reports `memory`. A set returns the mode in effect,
		// which is what SQLite does when it cannot switch.
		mode := store.log.memory_mode || !store.persistent ? "memory" : "delete"
		return pragma_single("journal_mode", pragma_text(mode), store.commit_seq), ERROR_NONE
	case "locking_mode":
		// A connection takes and drops the file's locks per transaction, which is
		// SQLite's `normal`. Like journal_mode, a set answers the mode in effect
		// rather than failing: SQLite itself answers that way when it cannot
		// switch, and an application that asks for `exclusive` still runs.
		return pragma_single("locking_mode", pragma_text("normal"), store.commit_seq), ERROR_NONE
	case "synchronous":
		if has_argument {
			level, known := pragma_sync_level(argument)
			if !known {
				return {}, errf(.Invalid_Argument, "unknown synchronous level %s", argument)
			}
			if !store.log.memory_mode do store.log.durability = level
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		return pragma_single(
			"synchronous",
			value_int(pragma_sync_number(store.log.durability)),
			store.commit_seq,
		), ERROR_NONE
	case "cache_size":
		// No page cache: read snapshots are cached separately and the number of
		// slots is not a size a client can set here.
		if has_argument {
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		return pragma_single("cache_size", value_int(0), store.commit_seq), ERROR_NONE
	case "mmap_size":
		return pragma_single("mmap_size", value_int(0), store.commit_seq), ERROR_NONE
	case "page_count":
		bytes := store_log_bytes(store)
		size := u64(store_sqlite_page_size(store))
		pages := (bytes + size - 1) / size
		return pragma_single("page_count", value_int(i64(pages)), store.commit_seq), ERROR_NONE
	case "freelist_count":
		return pragma_single("freelist_count", value_int(0), store.commit_seq), ERROR_NONE
	case "data_version":
		return pragma_single("data_version", value_int(i64(store.commit_seq)), store.commit_seq), ERROR_NONE
	case "max_page_count":
		return pragma_single("max_page_count", value_int(1073741823), store.commit_seq), ERROR_NONE
	case "foreign_keys":
		// Inside a transaction the setting is left alone, as SQLite leaves it.
		if has_argument && tx == nil {
			switch strings.to_lower(argument, context.temp_allocator) {
			case "on", "1", "true", "yes":
				store.foreign_keys_off = false
			case "off", "0", "false", "no":
				store.foreign_keys_off = true
			}
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		if has_argument do return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		return pragma_single("foreign_keys", value_int(store.foreign_keys_off ? 0 : 1), store.commit_seq), ERROR_NONE
	case "integrity_check", "quick_check":
		return pragma_check(store, name, tx), ERROR_NONE
	case "foreign_key_check":
		return pragma_foreign_key_check(store, tx), ERROR_NONE
	case "stats":
		return pragma_stats(store), ERROR_NONE
	case "sqlite_version":
		return pragma_single("sqlite_version", pragma_text("3.54.1"), store.commit_seq), ERROR_NONE
	case "pragma_list":
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("name")
		result.rows = make([][]Value, len(PRAGMA_NAMES))
		for listed, i in PRAGMA_NAMES {
			row := make([]Value, 1)
			row[0] = pragma_text(listed)
			result.rows[i] = row
		}
		return result, ERROR_NONE
	case "function_list":
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("name", "builtin", "type", "enc", "narg")
		result.rows = make([][]Value, len(PRAGMA_FUNCTIONS))
		for listed, i in PRAGMA_FUNCTIONS {
			row := make([]Value, 5)
			row[0] = pragma_text(listed)
			row[1] = value_int(1)
			row[2] = pragma_text("s")
			row[3] = pragma_text("utf8")
			row[4] = value_int(-1)
			result.rows[i] = row
		}
		return result, ERROR_NONE
	case "collation_list":
		// The three the engine implements, then any a program registered. SQLite
		// numbers them in registration order; this is that order.
		builtin := [3]string{"BINARY", "NOCASE", "RTRIM"}
		host_names := make([dynamic]string, 0, len(store.collations))
		for host_name in store.collations do append(&host_names, host_name)
		slice.sort_by(host_names[:], proc(a, b: string) -> bool {
			return strings.compare(a, b) < 0
		})
		defer delete(host_names)
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("seq", "name")
		result.rows = make([][]Value, len(builtin) + len(host_names))
		for builtin_name, i in builtin {
			row := make([]Value, 2)
			row[0] = value_int(i64(i))
			row[1] = pragma_text(builtin_name)
			result.rows[i] = row
		}
		for host_name, i in host_names {
			row := make([]Value, 2)
			row[0] = value_int(i64(len(builtin) + i))
			row[1] = pragma_text(host_name)
			result.rows[len(builtin) + i] = row
		}
		return result, ERROR_NONE
	case "module_list":
		// The virtual table modules this engine implements, which is what
		// `CREATE VIRTUAL TABLE ... USING <module>` accepts.
		modules := [6]string{"fts4", "fts5", "json_each", "json_tree", "rtree", "rtree_i32"}
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("seq", "name")
		result.rows = make([][]Value, len(modules))
		for module, i in modules {
			row := make([]Value, 2)
			row[0] = value_int(i64(i))
			row[1] = pragma_text(module)
			result.rows[i] = row
		}
		return result, ERROR_NONE
	case "legacy_file_format":
		// This engine never writes SQLite's old file format, and its own log is
		// not a page file at all: the answer is the one that means "no".
		return pragma_single("legacy_file_format", value_int(0), store.commit_seq), ERROR_NONE
	case "temp_store":
		// There is no page cache and no temporary store to put in memory: a read
		// answers SQLite's default (file) and a write is acknowledged.
		if has_argument {
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		return pragma_single("temp_store", value_int(0), store.commit_seq), ERROR_NONE
	case "soft_heap_limit64":
		if has_argument {
			// The limit a caller sets is acknowledged: the engine meters memory by
			// rows and bytes, not by an allocator cap.
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		return pragma_single("soft_heap_limit64", value_int(0), store.commit_seq), ERROR_NONE
	case "shrink_memory", "incremental_vacuum":
		// Both ask the engine to give memory back. VACUUM compacts the log; these
		// are the no-ops SQLite makes them when there is nothing to give back.
		if has_argument && name != "incremental_vacuum" {
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
	case "temp_store_directory", "data_store_directory":
		// Deprecated in SQLite, and meaningless here: a read answers the empty
		// string (no directory is set) and a write is acknowledged.
		if has_argument {
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		return pragma_single(name, pragma_text(""), store.commit_seq), ERROR_NONE
	case "compile_options":
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("compile_options")
		result.rows = make([][]Value, 1)
		row := make([]Value, 1)
		row[0] = pragma_text("MIRAIDB")
		result.rows[0] = row
		return result, ERROR_NONE
	}
	for refused in PRAGMA_REFUSED {
		if name != refused do continue
		if has_argument {
			return {}, errf(
				.Sql_Unsupported,
				"PRAGMA %s cannot be changed: the engine does not support that mode",
				name,
			)
		}
		return pragma_single(name, value_int(0), store.commit_seq), ERROR_NONE
	}
	// SQLite clients set and read a long list of tuning pragmas. The engine has
	// no equivalent knob for most of them, so they are accepted and answered
	// without error: settings acknowledge, reads return a neutral value.
	for accepted in PRAGMA_ACCEPTED {
		if name != accepted do continue
		if has_argument {
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		return pragma_single(name, value_int(0), store.commit_seq), ERROR_NONE
	}
	return {}, errf(.Sql_Unsupported, "unknown pragma %s", name)
}

// pragma_sync_level maps a PRAGMA synchronous word to the durability it means.
pragma_sync_level :: proc(word: string) -> (Durability, bool) {
	switch strings.to_lower(strings.trim_space(word), context.temp_allocator) {
	case "0", "off", "none": return .None, true
	case "1", "normal", "batched": return .Batched, true
	case "2", "full", "3", "extra": return .Full, true
	}
	return .Full, false
}

// pragma_sync_number is the SQLite number for a durability mode.
pragma_sync_number :: proc(durability: Durability) -> i64 {
	switch durability {
	case .None: return 0
	case .Batched: return 1
	case .Full: return 2
	}
	return 2
}

// pragma_check answers integrity_check with the problems the checker found, or
// with the single row `ok`.
@(private)
pragma_check :: proc(store: ^Store, name: string, tx: ^Tx = nil) -> Sql_Result {
	problems := store_integrity_check(store, context.allocator, tx)
	defer delete(problems)
	if len(problems) == 0 {
		return pragma_single(name, pragma_text("ok"), store.commit_seq)
	}
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = pragma_columns(name)
	result.rows = make([][]Value, len(problems))
	for message, i in problems {
		row := make([]Value, 1)
		row[0] = pragma_text(message)
		result.rows[i] = row
		delete(message)
	}
	return result
}

@(private)
pragma_foreign_key_check :: proc(store: ^Store, tx: ^Tx = nil) -> Sql_Result {
	problems := store_foreign_key_check(store, context.allocator, tx)
	defer delete(problems)
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = pragma_columns("table", "rowid", "parent", "fkid")
	result.rows = make([][]Value, len(problems))
	for problem, i in problems {
		row := make([]Value, 4)
		row[0] = pragma_text(problem.table)
		row[1] = value_int(i64(problem.row_id))
		row[2] = pragma_text(problem.parent)
		row[3] = value_int(i64(problem.index))
		result.rows[i] = row
		delete(problem.table)
		delete(problem.parent)
	}
	return result
}

// pragma_stats reports the latency histograms: the operation counts and one
// bucket per upper bound, in microseconds.
@(private)
pragma_stats :: proc(store: ^Store) -> Sql_Result {
	stats := store_latency_stats(store)
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = pragma_columns("metric", "value")
	rows := make([dynamic][]Value, 0, 2 + 2 * LATENCY_BUCKETS)
	append_counts :: proc(rows: ^[dynamic][]Value, metric: string, value: u64) {
		row := make([]Value, 2)
		row[0] = pragma_text(metric)
		row[1] = value_int(i64(value))
		append(rows, row)
	}
	append_counts(&rows, "commits", stats.commits)
	append_counts(&rows, "queries", stats.queries)
	// A scan counts every row it visits: the number a plan is judged by.
	append_counts(&rows, "rows_scanned", store.rows_scanned)
	append_counts(&rows, "stream_scans", store.stream_scans)
	// What keeping a .sqlite mirror current cost: pages written and the number
	// of commits that had to re-encode the whole file.
	append_counts(&rows, "mirror_pages", u64(store.mirror_pages_written))
	append_counts(&rows, "mirror_rewrites", u64(store.mirror_full_writes))
	bound: u64 = 1
	for bucket in 0 ..< LATENCY_BUCKETS {
		append_counts(&rows, fmt.tprintf("commit_us_lt_%d", bound), stats.commit_bucket[bucket])
		append_counts(&rows, fmt.tprintf("query_us_lt_%d", bound), stats.query_bucket[bucket])
		bound *= 2
	}
	result.rows = rows[:]
	return result
}

@(private)
pragma_column_name :: proc(table: ^Table, position: int) -> string {
	if position < 0 || position >= len(table.schema.columns) do return ""
	return table.schema.columns[position].name
}

@(private)
pragma_referenced_name :: proc(store: ^Store, key: Foreign_Key, position: int) -> string {
	parent, found := store.tables[key.ref_table]
	if !found || position >= len(key.ref_columns) do return ""
	column := key.ref_columns[position]
	if column < 0 || column >= len(parent.schema.columns) do return ""
	return parent.schema.columns[column].name
}

@(private)
is_pragma_pk :: proc(positions: []int, position: int) -> bool {
	for value in positions {
		if value == position do return true
	}
	return false
}

@(private)
pragma_action_name :: proc(action: Foreign_Key_Action) -> string {
	switch action {
	case .Cascade:
		return "CASCADE"
	case .Restrict:
		return "RESTRICT"
	}
	return "RESTRICT"
}

// HEADER_TABLE holds what SQLite keeps in its file header for the program:
// `user_version` and `application_id`. Rows of a table, so a value is logged,
// survives a reopen, is seen by every connection, and is set or undone with
// the transaction it is written in, as the header page is in SQLite.
HEADER_TABLE :: "_sqlite_header"

// pragma_header_value reads or writes one of the header integers. SQLite
// stores a 32-bit signed integer.
@(private)
pragma_header_value :: proc(store: ^Store, tx: ^Tx, name, argument: string, has_argument: bool) -> (Sql_Result, Error) {
	if !has_argument {
		reader := tx
		if reader == nil do reader = tx_begin_read(store)
		value := header_value(reader, name)
		if tx == nil do tx_end(reader)
		return pragma_single(name, value_int(value), store.commit_seq), ERROR_NONE
	}
	// A value that is not a 32-bit integer is 0, as SQLite stores it.
	value, parsed := strconv.parse_i64(argument)
	if !parsed || value < i64(min(i32)) || value > i64(max(i32)) do value = 0
	writer := tx
	if writer == nil do writer = tx_begin_write(store)
	if set_err := header_set(writer, name, value); set_err.kind != .None {
		if tx == nil do tx_rollback(writer)
		return {}, set_err
	}
	if tx == nil {
		if commit_err := tx_commit(writer); commit_err.kind != .None do return {}, commit_err
	}
	return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
}

// pragma_page_size_set is SQLite's rule for a new page size: it is noted for the
// connection and takes effect at the next VACUUM, or at once on a database that
// holds no table yet. A size that is not a power of two from 512 to 65536 is
// ignored, as SQLite ignores it; either way the set answers no row.
@(private)
pragma_page_size_set :: proc(store: ^Store, tx: ^Tx, argument: string) -> (Sql_Result, Error) {
	answer := pragma_result([]string{"page_size"}, nil, store.commit_seq)
	size, parsed := strconv.parse_int(argument)
	if !parsed || !sqlite_page_size_valid(size) do return answer, ERROR_NONE
	store.sqlite_page_size_pending = size
	empty := true
	{
		sync.shared_lock(&store.mutex)
		defer sync.shared_unlock(&store.mutex)
		for name in store.tables {
			if len(name) > 0 && name[0] != '_' {
				empty = false
				break
			}
		}
	}
	if empty {
		if apply_err := store_apply_page_size(store, tx); apply_err.kind != .None {
			sql_result_destroy(&answer)
			return {}, apply_err
		}
	}
	return answer, ERROR_NONE
}

// store_apply_page_size makes the noted page size the store's: a header
// integer, so the commit rewrites a mirrored SQLite file at that size (a change
// to the header table is one the page patcher leaves to a full write).
store_apply_page_size :: proc(store: ^Store, tx: ^Tx) -> Error {
	size := store.sqlite_page_size_pending
	if size == 0 do return ERROR_NONE
	store.sqlite_page_size_pending = 0
	if size == store_sqlite_page_size(store) do return ERROR_NONE
	writer := tx
	if writer == nil do writer = tx_begin_write(store)
	if set_err := header_set(writer, "page_size", i64(size)); set_err.kind != .None {
		if tx == nil do tx_rollback(writer)
		return set_err
	}
	if tx == nil do return tx_commit(writer)
	return ERROR_NONE
}

// header_value is one header integer as the transaction sees it, 0 when unset.
header_value :: proc(tx: ^Tx, name: string) -> i64 {
	if tx_table_probe(tx, HEADER_TABLE) == nil do return 0
	result, err := sql_execute_in_tx_params(tx, "SELECT value FROM _sqlite_header WHERE name = ?", []Value{value_string(name)})
	if err.kind != .None {
		error_drop(err)
		return 0
	}
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 || len(result.rows[0]) == 0 || result.rows[0][0].kind != .Int do return 0
	return result.rows[0][0].i
}

// header_set writes one header integer in the transaction.
header_set :: proc(tx: ^Tx, name: string, value: i64) -> Error {
	// The engine's own rows are not the program's changes: changes() and
	// total_changes() do not count them.
	saved_last, saved_total := tx.store.last_changes, tx.store.total_changes
	defer tx.store.last_changes, tx.store.total_changes = saved_last, saved_total
	if tx_table_probe(tx, HEADER_TABLE) == nil {
		created, create_err := sql_execute_in_tx(tx, "CREATE TABLE _sqlite_header (name TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL)")
		if create_err.kind != .None do return create_err
		sql_result_destroy(&created)
	}
	result, err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _sqlite_header (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value",
		[]Value{value_string(name), value_int(value)},
	)
	if err.kind != .None do return err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// PRAGMA_TABLE_FUNCTIONS are the pragmas a query can read as a table, as
// SQLite offers them: `SELECT * FROM pragma_table_info('t')`. They are the ones
// that answer rows and change nothing.
PRAGMA_TABLE_FUNCTIONS := []string {
	"application_id", "collation_list", "compile_options", "data_version",
	"database_list", "encoding", "foreign_key_check", "foreign_key_list",
	"freelist_count", "function_list", "index_info", "index_list",
	"index_xinfo", "integrity_check", "journal_mode", "module_list",
	"page_count", "page_size", "pragma_list", "quick_check",
	"schema_version", "table_info", "table_list", "table_xinfo",
	"user_version",
}

// is_pragma_function reports a `pragma_<name>` table function.
is_pragma_function :: proc(name: string) -> bool {
	if len(name) <= 7 || !strings.equal_fold(name[:7], "pragma_") do return false
	for candidate in PRAGMA_TABLE_FUNCTIONS {
		if strings.equal_fold(name[7:], candidate) do return true
	}
	return false
}

// tx_materialize_pragma runs the pragma a `pragma_<name>(arg)` names, with
// its first argument as the pragma's, and reads the answer as a temporary
// table the statement scans like a view.
tx_materialize_pragma :: proc(tx: ^Tx, name: string, args: []Value) -> (^Table, Error) {
	body := name[7:]
	// The argument is the call's first, or what a WHERE or ON term asks of the
	// hidden column `arg`, as SQLite reads `pragma_table_info WHERE arg = 't'`.
	argument := value_null()
	schema_name := value_null()
	if len(args) > 0 do argument = args[0]
	if len(args) > 1 do schema_name = args[1]
	if len(args) == 0 {
		if value, found := pragma_arg_term(tx, name, "arg"); found do argument = value
		if value, found := pragma_arg_term(tx, name, "schema"); found do schema_name = value
	}
	if argument.kind != .Null {
		text := sqlite_value_text(argument, context.temp_allocator)
		body = strings.concatenate({body, "(", text, ")"}, context.temp_allocator)
	}
	result, pragma_err := sql_exec_pragma(tx.store, body, tx.locked, tx)
	if pragma_err.kind != .None do return nil, pragma_err
	defer sql_result_destroy(&result)
	// The answer's columns, then SQLite's hidden `arg` and `schema`, which
	// `SELECT *` leaves out.
	width := len(result.columns)
	// A pragma whose answer already has a column of that name (table_list's
	// `schema`) keeps its own: SQLite's hidden column is not added twice.
	has_column :: proc(names: []string, wanted: string) -> bool {
		for name in names do if strings.equal_fold(name, wanted) do return true
		return false
	}
	add_arg := !has_column(result.columns, "arg")
	add_schema := !has_column(result.columns, "schema")
	total := width + (add_arg ? 1 : 0) + (add_schema ? 1 : 0)
	columns := make([]Column, total, tx.alloc)
	for column_name, i in result.columns {
		columns[i] = Column {
			name = strings.clone(column_name, tx.alloc),
			type = view_column_type(result.rows, i),
		}
	}
	text := Column_Type{kind = .Any}
	next := width
	if add_arg {
		columns[next] = Column{name = "arg", type = text, hidden = true}
		next += 1
	}
	if add_schema do columns[next] = Column{name = "schema", type = text, hidden = true}
	schema := Table_Schema {
		name    = strings.clone(name, tx.alloc),
		columns = columns,
	}
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	for row, i in result.rows {
		values := make([]Value, total, tx.alloc)
		copy(values, row)
		next = width
		if add_arg {
			values[next] = argument
			next += 1
		}
		if add_schema do values[next] = schema_name
		if insert_err := table_insert(table, Row_Id(i + 1), values); insert_err.kind != .None {
			table_destroy(table)
			return nil, insert_err
		}
	}
	append(&tx.temp_tables, table)
	return table, ERROR_NONE
}

// pragma_arg_term finds `column = value` in the WHERE or the ON being read,
// for a hidden column of a pragma function, and evaluates the value against
// the rows bound before the function.
@(private)
pragma_arg_term :: proc(tx: ^Tx, name, column: string) -> (Value, bool) {
	terms := make([dynamic]^Expr, 0, 4, context.temp_allocator)
	if tx.vtab_where != nil do split_and(tx.vtab_where, &terms)
	if tx.vtab_join != nil do split_and(tx.vtab_join, &terms)
	names_it :: proc(tx: ^Tx, name, qualifier: string) -> bool {
		if len(qualifier) == 0 do return true
		if strings.equal_fold(qualifier, name) do return true
		return len(tx.vtab_alias) > 0 && strings.equal_fold(qualifier, tx.vtab_alias)
	}
	for term in terms {
		binary, is_binary := term^.(Binary_Expr)
		if !is_binary || binary.op != .Eq || binary.left == nil || binary.right == nil do continue
		for side in 0 ..< 2 {
			target, other := binary.left, binary.right
			if side == 1 do target, other = binary.right, binary.left
			reference, is_column := target^.(Column_Expr)
			if !is_column || !strings.equal_fold(reference.name, column) || !names_it(tx, name, reference.table) do continue
			// The value may not read the function's own row.
			if other_column, other_is_column := other^.(Column_Expr); other_is_column && names_it(tx, name, other_column.table) && len(other_column.table) > 0 do continue
			ctx := Eval_Ctx{tx = tx, params = tx.vtab_params, sources = tx.vtab_sources, outer = tx.outer, now_us = now_microseconds()}
			value, eval_err := eval_expr(&ctx, other)
			if eval_err.kind != .None {
				error_free(&eval_err)
				continue
			}
			return value, true
		}
	}
	return {}, false
}

// pragma_unquote reads a pragma's argument: a quoted name ("a""b", 'x',
// [y], `z`) is the name it spells, as SQLite reads it.
@(private)
pragma_unquote :: proc(text: string) -> string {
	trimmed := strings.trim_space(text)
	if len(trimmed) >= 2 {
		first, last := trimmed[0], trimmed[len(trimmed) - 1]
		quoted := (first == '"' && last == '"') || (first == '\'' && last == '\'') || (first == '`' && last == '`') || (first == '[' && last == ']')
		if quoted {
			inner := trimmed[1:len(trimmed) - 1]
			if first == '[' do return inner
			doubled := first == '"' ? "\"\"" : first == '\'' ? "''" : "``"
			single := doubled[:1]
			unescaped, _ := strings.replace_all(inner, doubled, single, context.temp_allocator)
			return unescaped
		}
	}
	return strings.trim(trimmed, "\"'")
}

// pragma_table is a table as the pragma's transaction sees it, so a table the
// connection created and has not committed is there, as in SQLite.
// pragma_find_index finds an index by the name SQLite gives it
// (sqlite_autoindex_T_N for one a constraint made) or by its own name.
@(private)
pragma_find_index :: proc(store: ^Store, tx: ^Tx, name: string) -> (^Table, int, bool) {
	reader := tx
	if reader == nil do reader = tx_begin_read(store)
	defer if tx == nil do tx_end(reader)
	for table_name in tx_table_names(reader, context.temp_allocator) {
		table := tx_table_probe(reader, table_name)
		if table == nil do continue
		if store.sqlite_rules {
			for entry in sqlite_index_list(reader, table, context.temp_allocator) {
				if strings.equal_fold(entry.name, name) do return table, entry.index, true
			}
			continue
		}
		for index, i in table.schema.indexes do if strings.equal_fold(index.name, name) do return table, i, true
	}
	return nil, 0, false
}

// pragma_index_info is PRAGMA index_info, or index_xinfo when `extended`: the
// key columns, then (xinfo) what the index entry carries after the key, the
// rowid or, without one, the primary key columns the key leaves out (all the
// other columns, for the primary key's own index).
@(private)
pragma_index_info :: proc(table: ^Table, position: int, extended: bool, columns: []string, commit_seq: u64) -> Sql_Result {
	schema := &table.schema
	index := &schema.indexes[position]
	rows := make([dynamic][]Value, 0, len(index.columns) + 1)
	add :: proc(rows: ^[dynamic][]Value, schema: ^Table_Schema, column: int, extended, key: bool) {
		row := make([]Value, extended ? 6 : 3)
		row[0] = value_int(i64(len(rows)))
		row[1] = value_int(i64(column))
		row[2] = value_null()
		collation := "BINARY"
		if column >= 0 && column < len(schema.columns) {
			row[2] = pragma_text(schema.columns[column].name)
			// SQLite answers the collation as the declaration spells it.
			if declared := schema.columns[column].collation; len(declared) > 0 do collation = declared
		}
		if extended {
			row[3] = value_int(0)
			row[4] = pragma_text(collation)
			row[5] = value_int(key ? 1 : 0)
		}
		append(rows, row)
	}
	for column, i in index.columns {
		part := column
		if i < len(index.exprs) && len(index.exprs[i]) > 0 do part = -2
		add(&rows, schema, part, extended, true)
	}
	if extended {
		if !schema.without_rowid {
			add(&rows, schema, -1, extended, false)
		} else {
			is_primary := len(schema.primary_key) > 0 && schema_index_matches(index, schema.primary_key)
			if is_primary {
				for _, column in schema.columns do if !slice.contains(index.columns, column) do add(&rows, schema, column, extended, false)
			} else {
				for column in schema.primary_key do if !slice.contains(index.columns, column) do add(&rows, schema, column, extended, false)
			}
		}
	}
	return pragma_result(columns, rows[:], commit_seq)
}

@(private)
pragma_table :: proc(store: ^Store, tx: ^Tx, name: string) -> (^Table, bool) {
	if tx != nil {
		table := tx_table_probe(tx, name)
		if table == nil && store.sqlite_rules {
			// SQLite matches a table's name without regard to case.
			for candidate in tx_table_names(tx, context.temp_allocator) {
				if strings.equal_fold(candidate, name) do return tx_table_probe(tx, candidate), true
			}
		}
		return table, table != nil
	}
	table, found := store.tables[name]
	if !found && store.sqlite_rules {
		for candidate, held in store.tables do if strings.equal_fold(candidate, name) do return held, true
	}
	return table, found
}
