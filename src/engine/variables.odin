package engine

import "core:mem"

// Module variables live in `_var` as key/value text. Unlike the process-local
// `SET`/`SHOW` variables, they are committed data: a module can publish state
// that survives a restart and is visible through SQL.
VAR_TABLE :: "_var"
VAR_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _var (
		key TEXT PRIMARY KEY,
		value TEXT NOT NULL
	)`

@(private)
variables_ensure_table :: proc(host: ^Host) -> Error {
	result, create_err := sql_execute(host.store, VAR_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// host_set_module_variable stores or replaces one module variable.
host_set_module_variable :: proc(host: ^Host, key, value: string) -> Error {
	if len(key) == 0 do return errf(.Invalid_Argument, "a module variable needs a key")
	if err := variables_ensure_table(host); err.kind != .None do return err
	existing, select_err := sql_execute_params(
		host.store,
		"SELECT 1 FROM _var WHERE key = ?",
		[]Value{value_string(key)},
	)
	if select_err.kind != .None do return select_err
	found := len(existing.rows) > 0
	sql_result_destroy(&existing)
	if found {
		_, update_err := sql_execute_params(
			host.store,
			"UPDATE _var SET value = ? WHERE key = ?",
			[]Value{value_string(value), value_string(key)},
		)
		return update_err
	}
	_, insert_err := sql_execute_params(
		host.store,
		"INSERT INTO _var (key, value) VALUES (?, ?)",
		[]Value{value_string(key), value_string(value)},
	)
	return insert_err
}

host_get_module_variable :: proc(host: ^Host, key: string) -> (string, bool) {
	result, query_err := sql_execute_params(
		host.store,
		"SELECT value FROM _var WHERE key = ?",
		[]Value{value_string(key)},
	)
	if query_err.kind != .None do return "", false
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return "", false
	return result.rows[0][0].s, true
}

host_module_variable_names :: proc(host: ^Host, alloc: mem.Allocator) -> []string {
	result, query_err := sql_execute(host.store, "SELECT key FROM _var")
	if query_err.kind != .None do return nil
	defer sql_result_destroy(&result)
	names := make([dynamic]string, 0, len(result.rows), alloc)
	for row in result.rows do append(&names, row[0].s)
	slice_sort_strings(names[:])
	return names[:]
}
