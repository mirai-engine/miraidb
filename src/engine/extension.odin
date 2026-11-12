package engine

import "core:strings"

// Extensions are processes, not shared libraries. `LOAD EXTENSION` records where
// the process listens and registers a remote module for it; calls then cross a
// socket through the same wire protocol as any other module. Nothing but bytes
// crosses the boundary, which is why an extension cannot corrupt the host's heap.
//
//	_extension (name, address, port, reducers)  what was loaded, so a restart
//	                                            registers it again
//
// The row is data like every other catalog entry: logged, replayed and dropped.

EXTENSION_TABLE :: "_extension"
EXTENSION_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _extension (
		name TEXT PRIMARY KEY,
		address TEXT NOT NULL,
		port INTEGER NOT NULL,
		reducers TEXT NOT NULL
	)
`

extension_ensure :: proc(tx: ^Tx) -> Error {
	_, err := sql_execute_in_tx(tx, EXTENSION_SCHEMA_SQL)
	return err
}

// remote_parse_address splits `host:port`. The port is required: an address
// without one would silently disable the extension.
remote_parse_address :: proc(address: string) -> (host: string, port: int, err: Error) {
	colon := strings.last_index_byte(address, ':')
	if colon <= 0 || colon == len(address) - 1 {
		return "", 0, errf(.Invalid_Argument, "extension address %q must be host:port", address)
	}
	host = address[:colon]
	digits := address[colon + 1:]
	value := 0
	for byte in digits {
		if byte < '0' || byte > '9' {
			return "", 0, errf(.Invalid_Argument, "extension address %q has a non-numeric port", address)
		}
		value = value * 10 + int(byte - '0')
		if value > 65535 do return "", 0, errf(.Invalid_Argument, "extension port is out of range")
	}
	if value == 0 do return "", 0, errf(.Invalid_Argument, "extension port must not be zero")
	return host, value, ERROR_NONE
}

extension_load :: proc(tx: ^Tx, name: string, address: string, reducers: []string) -> Error {
	if len(name) == 0 do return errf(.Invalid_Argument, "an extension needs a name")
	if err := extension_ensure(tx); err.kind != .None do return err
	host, port, parse_err := remote_parse_address(address)
	if parse_err.kind != .None do return parse_err
	reducers_text := strings.join(reducers, ",")
	delete_sql := strings.concatenate({"DELETE FROM ", EXTENSION_TABLE, " WHERE name = ?"}, tx.alloc)
	if err := fts_run(tx, delete_sql, []Value{value_string(strings.clone(name, tx.alloc))}); err.kind != .None {
		return err
	}
	values := []Value {
		value_string(strings.clone(name, tx.alloc)),
		value_string(strings.clone(address, tx.alloc)),
		value_int(i64(port)),
		value_string(strings.clone(reducers_text, tx.alloc)),
	}
	if _, insert_err := tx_insert(tx, EXTENSION_TABLE, values); insert_err.kind != .None do return insert_err
	// Register with the running host, if there is one: without a host the row is
	// still recorded and takes effect on the next host_init.
	if tx.store.host != nil {
		if register_err := host_load_extension(tx.store.host, name, host, port, reducers); register_err.kind != .None {
			return register_err
		}
	}
	return ERROR_NONE
}

extension_unload :: proc(tx: ^Tx, name: string, if_exists: bool) -> Error {
	if err := extension_ensure(tx); err.kind != .None do return err
	if found, find_err := extension_find(tx, name); find_err.kind != .None {
		return find_err
	} else if !found {
		if if_exists do return ERROR_NONE
		return errf(.Invalid_Argument, "no extension named %s", name)
	}
	sql := strings.concatenate({"DELETE FROM ", EXTENSION_TABLE, " WHERE name = ?"}, tx.alloc)
	if err := fts_run(tx, sql, []Value{value_string(strings.clone(name, tx.alloc))}); err.kind != .None do return err
	if tx.store.host != nil do host_unregister_remote_module(tx.store.host, name)
	return ERROR_NONE
}

@(private)
extension_find :: proc(tx: ^Tx, name: string) -> (bool, Error) {
	table, err := tx_table(tx, EXTENSION_TABLE)
	if err.kind != .None do return false, err
	rows := make([dynamic]Row, 0, 4)
	defer delete(rows)
	table_collect(table, &rows)
	for row in rows {
		if len(row.values) == 0 || row.values[0].kind != .String do continue
		if strings.equal_fold(row.values[0].s, name) do return true, ERROR_NONE
	}
	return false, ERROR_NONE
}

// host_load_extension registers a running extension, replacing any previous
// registration of the same name so a reload cannot leave two modules behind.
host_load_extension :: proc(host: ^Host, name: string, address: string, port: int, reducers: []string) -> Error {
	host_unregister_remote_module(host, name)
	return host_register_remote_module(host, name, address, port, reducers)
}

// host_replay_extensions registers every extension the database remembers. Called
// from host_init: an extension survives a restart because its row does.
host_replay_extensions :: proc(host: ^Host) -> Error {
	store := host.store
	result, err := sql_execute(store, EXTENSION_SCHEMA_SQL)
	if err.kind != .None do return err
	sql_result_destroy(&result)
	list, list_err := sql_execute(store, "SELECT name, address, port, reducers FROM _extension")
	if list_err.kind != .None do return list_err
	defer sql_result_destroy(&list)
	for row in list.rows {
		if len(row) < 4 || row[0].kind != .String || row[1].kind != .String do continue
		module_host, port, parse_err := remote_parse_address(row[1].s)
		if parse_err.kind != .None do continue
		reducers := make([dynamic]string, 0, 2, context.temp_allocator)
		if row[3].kind == .String {
			for piece in strings.split(row[3].s, ",") {
				trimmed := strings.trim_space(piece)
				if len(trimmed) > 0 do append(&reducers, trimmed)
			}
		}
		_ = host_load_extension(host, row[0].s, module_host, port, reducers[:])
	}
	return ERROR_NONE
}
