package engine

import "core:fmt"
import "core:mem"
import "core:strings"

// META_TABLE carries module and schema metadata as key/value rows. It is
// ordinary data: logged, snapshotted and replayable like everything else.
META_TABLE :: "_meta"
META_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _meta (
		key TEXT PRIMARY KEY,
		value TEXT NOT NULL
	)`

// host_ensure_meta creates the metadata table and seeds the schema version.
host_ensure_meta :: proc(host: ^Host) -> Error {
	catalog_scope()
	result, create_err := sql_execute(host.store, META_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	existing, select_err := sql_execute_params(
		host.store,
		"SELECT 1 FROM _meta WHERE key = 'schema_version'",
		nil,
	)
	if select_err.kind != .None do return select_err
	found := len(existing.rows) > 0
	sql_result_destroy(&existing)
	if found do return ERROR_NONE
	discarded_16, insert_err := sql_execute_params(
		host.store,
		"INSERT INTO _meta (key, value) VALUES (?, ?)",
		[]Value{value_string("schema_version"), value_string("1")},
	)
	sql_result_destroy(&discarded_16)
	return insert_err
}

// store_meta reads one metadata value from a database, with or without a host.
// The value is copied into `alloc`: the result it comes from is freed on return,
// and the text used to point into it.
store_meta :: proc(store: ^Store, key: string, alloc := context.temp_allocator) -> (string, bool) {
	catalog_scope()
	result, query_err := sql_execute_params(
		store,
		"SELECT value FROM _meta WHERE key = ?",
		[]Value{value_string(key)},
	)
	if query_err.kind != .None do return "", false
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return "", false
	return strings.clone(result.rows[0][0].s, alloc), true
}

// host_meta reads one metadata value.
host_meta :: proc(host: ^Host, key: string, alloc := context.temp_allocator) -> (string, bool) {
	return store_meta(host.store, key, alloc)
}

// host_schema_text renders the user schema as plain text: one block per table
// with its columns and indexes. It is the reflection source for clients and
// for code generation.
host_schema_text :: proc(host: ^Host, alloc: mem.Allocator) -> string {
	// Only the order is needed: the names stay the catalog's.
	names := make([dynamic]string, 0, len(host.store.tables), context.temp_allocator)
	for name in host.store.tables {
		if len(name) > 0 && name[0] == '_' do continue
		append(&names, name)
	}
	slice_sort_strings(names[:])
	builder := strings.builder_make(alloc)
	for name in names {
		result, describe_err := sql_execute(host.store, fmt.tprintf("DESCRIBE %s", name))
		if describe_err.kind != .None do continue
		fmt.sbprintfln(&builder, "table %s", name)
		for row in result.rows {
			fmt.sbprintfln(&builder, "  %s %s %s", row[0].s, row[1].s, row[2].s)
		}
		sql_result_destroy(&result)
	}
	return strings.to_string(builder)
}
