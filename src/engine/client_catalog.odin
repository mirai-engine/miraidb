package engine

// The client catalog is persisted data: one row per known client identity.
// Credentials live in `_token`; this table records who a client is.
CLIENT_TABLE :: "_client"
CLIENT_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _client (
		identity IDENTITY PRIMARY KEY,
		name TEXT NOT NULL,
		created_us INTEGER NOT NULL
	)`

@(private)
clients_ensure_table :: proc(host: ^Host) -> Error {
	if _, exists := host.store.tables[CLIENT_TABLE]; exists do return ERROR_NONE
	result, create_err := sql_execute(host.store, CLIENT_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// host_register_client records or renames a client.
host_register_client :: proc(host: ^Host, identity: Identity, name: string) -> Error {
	if len(name) == 0 do return errf(.Invalid_Argument, "a client needs a name")
	if err := clients_ensure_table(host); err.kind != .None do return err
	existing, select_err := sql_execute_params(
		host.store,
		"SELECT 1 FROM _client WHERE identity = ?",
		[]Value{value_identity(identity)},
	)
	if select_err.kind != .None do return select_err
	found := len(existing.rows) > 0
	sql_result_destroy(&existing)
	if found {
		_, update_err := sql_execute_params(
			host.store,
			"UPDATE _client SET name = ? WHERE identity = ?",
			[]Value{value_string(name), value_identity(identity)},
		)
		return update_err
	}
	_, insert_err := sql_execute_params(
		host.store,
		"INSERT INTO _client (identity, name, created_us) VALUES (?, ?, ?)",
		[]Value{value_identity(identity), value_string(name), value_int(host_now(host))},
	)
	return insert_err
}

// host_client_catalog reads one client record.
host_client_catalog :: proc(host: ^Host, identity: Identity) -> (name: string, created_us: i64, found: bool) {
	result, query_err := sql_execute_params(
		host.store,
		"SELECT name, created_us FROM _client WHERE identity = ?",
		[]Value{value_identity(identity)},
	)
	if query_err.kind != .None do return "", 0, false
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return "", 0, false
	return result.rows[0][0].s, result.rows[0][1].i, true
}

host_client_count_catalog :: proc(host: ^Host) -> int {
	result, query_err := sql_execute(host.store, "SELECT count(*) FROM _client")
	if query_err.kind != .None do return 0
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return 0
	return int(result.rows[0][0].i)
}
