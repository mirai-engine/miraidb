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
import "core:strings"
import "core:sync"

// sqlite_pragma_statement reports whether the text is a PRAGMA and returns its
// body (the part after the keyword).
sqlite_pragma_statement :: proc(sql: string) -> (body: string, is_pragma: bool) {
	trimmed := strings.trim_space(sql)
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
	return strings.trim_right(strings.trim_space(trimmed[6:]), "; \t\r\n"), true
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
	"application_id", "cache_size", "compile_options", "database_list", "data_version",
	"encoding",
	"foreign_key_list", "foreign_keys", "function_list", "index_info", "index_list",
	"foreign_key_check", "integrity_check", "journal_mode", "mmap_size", "page_size",
	"freelist_count", "page_count", "pragma_list", "quick_check", "schema_version",
	"sqlite_version", "stats",
	"synchronous", "table_info",
	"table_list", "table_xinfo", "temp_store", "user_version",
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
	"legacy_alter_table", "locking_mode", "query_only", "read_uncommitted",
	"recursive_triggers", "reverse_unordered_selects", "trusted_schema",
	"writable_schema",
}

@(private)
pragma_text :: proc(value: string) -> Value {
	return value_string(strings.clone(value))
}

@(private)
pragma_result :: proc(columns: []string, rows: [][]Value, commit_seq: u64) -> Sql_Result {
	result := Sql_Result{kind = .Rows, commit_seq = commit_seq}
	result.columns = make([]string, len(columns))
	for column, i in columns do result.columns[i] = strings.clone(column)
	result.rows = make([][]Value, len(rows))
	for row, i in rows do result.rows[i] = row
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
// the store lock (a transaction does).
sql_exec_pragma :: proc(store: ^Store, body: string, locked: bool) -> (Sql_Result, Error) {
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
	name = strings.to_lower(strings.trim_space(name))
	argument = strings.trim(argument, " \t\r\n\"'")
	if !locked {
		sync.shared_lock(&store.mutex)
		defer sync.shared_unlock(&store.mutex)
	}
	switch name {
	case "table_info", "table_xinfo":
		table, found := store.tables[argument]
		if !found {
			return pragma_result([]string{"cid", "name", "type", "notnull", "dflt_value", "pk"}, nil, store.commit_seq), ERROR_NONE
		}
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("cid", "name", "type", "notnull", "dflt_value", "pk")
		result.rows = make([][]Value, len(table.schema.columns))
		for column, i in table.schema.columns {
			row := make([]Value, 6)
			row[0] = value_int(i64(i))
			row[1] = pragma_text(column.name)
			row[2] = pragma_text(column_type_name(column.type))
			row[3] = value_int(column.not_null ? 1 : 0)
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
		table, found := store.tables[argument]
		if !found {
			return pragma_result([]string{"seq", "name", "unique", "origin", "partial"}, nil, store.commit_seq), ERROR_NONE
		}
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("seq", "name", "unique", "origin", "partial")
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
	case "index_info":
		for _, table in store.tables {
			for index in table.schema.indexes {
				if !strings.equal_fold(index.name, argument) do continue
				result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
				result.columns = pragma_columns("seqno", "cid", "name")
				result.rows = make([][]Value, len(index.columns))
				for column, i in index.columns {
					row := make([]Value, 3)
					row[0] = value_int(i64(i))
					row[1] = value_int(i64(column))
					if column >= 0 && column < len(table.schema.columns) {
						row[2] = pragma_text(table.schema.columns[column].name)
					} else {
						row[2] = value_null()
					}
					result.rows[i] = row
				}
				return result, ERROR_NONE
			}
		}
		return pragma_result([]string{"seqno", "cid", "name"}, nil, store.commit_seq), ERROR_NONE
	case "foreign_key_list":
		table, found := store.tables[argument]
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
		result.rows = make([][]Value, 1)
		row := make([]Value, 3)
		row[0] = value_int(0)
		row[1] = pragma_text("main")
		file := store.path
		if len(file) == 0 do file = store.sqlite_mirror
		row[2] = pragma_text(file)
		result.rows[0] = row
		return result, ERROR_NONE
	case "table_list":
		result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		result.columns = pragma_columns("schema", "name", "type", "ncol", "wr", "strict")
		names := store_table_names(store, context.allocator)
		defer {
			for n in names do delete(n)
			delete(names)
		}
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
	case "user_version", "application_id":
		if has_argument {
			value := pragma_text(argument)
			if set_err := store_set_variable_locked(store, name, value); set_err.kind != .None {
				return {}, set_err
			}
			return Sql_Result{kind = .Ack, message = strings.clone("ok"), commit_seq = store.commit_seq}, ERROR_NONE
		}
		if value, found := store_get_variable_locked(store, name); found {
			return pragma_single(name, value, store.commit_seq), ERROR_NONE
		}
		return pragma_single(name, value_int(0), store.commit_seq), ERROR_NONE
	case "schema_version":
		return pragma_single("schema_version", value_int(i64(store.commit_seq)), store.commit_seq), ERROR_NONE
	case "page_size":
		// The engine is a log, not a page file; this is the page size an export
		// uses, which is what a client reading it before a dump wants to know.
		return pragma_single("page_size", value_int(SQLITE_WRITE_PAGE_SIZE), store.commit_seq), ERROR_NONE
	case "encoding":
		return pragma_single("encoding", pragma_text("UTF-8"), store.commit_seq), ERROR_NONE
	case "journal_mode":
		// There is no rollback journal and no WAL: a commit is one durable log
		// record. The closest SQLite mode is `delete` (the durable default);
		// an ephemeral log reports `memory`. A set returns the mode in effect,
		// which is what SQLite does when it cannot switch.
		mode := store.log.memory_mode || !store.persistent ? "memory" : "delete"
		return pragma_single("journal_mode", pragma_text(mode), store.commit_seq), ERROR_NONE
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
		pages := (bytes + u64(SQLITE_WRITE_PAGE_SIZE) - 1) / u64(SQLITE_WRITE_PAGE_SIZE)
		return pragma_single("page_count", value_int(i64(pages)), store.commit_seq), ERROR_NONE
	case "freelist_count":
		return pragma_single("freelist_count", value_int(0), store.commit_seq), ERROR_NONE
	case "data_version":
		return pragma_single("data_version", value_int(i64(store.commit_seq)), store.commit_seq), ERROR_NONE
	case "max_page_count":
		return pragma_single("max_page_count", value_int(1073741823), store.commit_seq), ERROR_NONE
	case "foreign_keys":
		// Enforcement lives in the transaction layer and cannot be turned off, so
		// the honest answer to both forms is the state in effect.
		return pragma_single("foreign_keys", value_int(1), store.commit_seq), ERROR_NONE
	case "integrity_check", "quick_check":
		return pragma_check(store, name), ERROR_NONE
	case "foreign_key_check":
		return pragma_foreign_key_check(store), ERROR_NONE
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
	switch strings.to_lower(strings.trim_space(word)) {
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
pragma_check :: proc(store: ^Store, name: string) -> Sql_Result {
	problems := store_integrity_check(store, context.allocator)
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
pragma_foreign_key_check :: proc(store: ^Store) -> Sql_Result {
	problems := store_foreign_key_check(store, context.allocator)
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
		append_counts(&rows, fmt.aprintf("commit_us_lt_%d", bound), stats.commit_bucket[bucket])
		append_counts(&rows, fmt.aprintf("query_us_lt_%d", bound), stats.query_bucket[bucket])
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
