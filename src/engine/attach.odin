package engine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// ATTACH makes a second database readable as `name.table`. The attached
// database is opened read-only and never written; its name and path live in the
// `_attach` catalog, which travels with the commit log like any other data, so a
// reopen restores the set without a format change.

ATTACH_TABLE :: "_attach"

// attach_ensure creates the catalog on first use.
attach_ensure :: proc(tx: ^Tx) -> Error {
	if _, table_err := tx_table(tx, ATTACH_TABLE); table_err.kind == .None do return ERROR_NONE
	_, create_err := sql_execute_in_tx(
		tx,
		"CREATE TABLE _attach (name TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL)",
	)
	return create_err
}

// attach_recorded reports whether the catalog already holds `name`.
attach_recorded :: proc(tx: ^Tx, name: string) -> bool {
	if _, table_err := tx_table(tx, ATTACH_TABLE); table_err.kind != .None do return false
	result, err := sql_execute_in_tx_params(
		tx,
		"SELECT name FROM _attach WHERE name = ?",
		[]Value{value_string(name)},
	)
	if err.kind != .None do return false
	defer sql_result_destroy(&result)
	return len(result.rows) > 0
}

// store_attach_add opens a database read-only and registers it in memory.
store_attach_add :: proc(store: ^Store, name, path: string) -> Error {
	sync.lock(&store.mutex)
	defer sync.unlock(&store.mutex)
	if _, exists := store.attached[name]; exists {
		return errf(.Invalid_Argument, "database %s is already attached", name)
	}
	if strings.equal_fold(path, store.path) {
		return errf(.Invalid_Argument, "cannot attach %s to itself", name)
	}
	attached, open_err := store_open(path, {persistent = true, create = false, durable = false})
	if open_err.kind != .None {
		return errf(open_err.kind, "cannot attach %s: %s", path, open_err.message)
	}
	store.attached[strings.clone(name, context.allocator)] = attached
	return ERROR_NONE
}

// store_attach_remove closes an attached database and forgets its handle.
store_attach_remove :: proc(store: ^Store, name: string) -> Error {
	sync.lock(&store.mutex)
	attached, exists := store.attached[name]
	if !exists {
		sync.unlock(&store.mutex)
		return errf(.Table_Not_Found, "database %s is not attached", name)
	}
	map_erase(&store.attached, name)
	sync.unlock(&store.mutex)
	store_close(attached)
	return ERROR_NONE
}

// store_attach_restore reopens the databases the catalog lists. A missing path
// is not fatal: the principal stays usable and the reason lands in last_error.
store_attach_restore :: proc(store: ^Store) -> Error {
	table, found := store.tables[ATTACH_TABLE]
	if !found do return ERROR_NONE
	rows := make([dynamic]Row)
	table_collect(table, &rows, max(u64))
	defer delete(rows)
	if len(rows) == 0 do return ERROR_NONE
	names := make([]string, len(rows))
	paths := make([]string, len(rows))
	for row, i in rows {
		if len(row.values) < 2 do continue
		names[i] = strings.clone(row.values[0].s)
		paths[i] = strings.clone(row.values[1].s)
	}
	defer {
		for i in 0 ..< len(rows) {
			delete(names[i])
			delete(paths[i])
		}
		delete(names)
		delete(paths)
	}
	first_err: Error
	for name, i in names {
		if len(name) == 0 do continue
		if add_err := store_attach_add(store, name, paths[i]); add_err.kind != .None {
			if first_err.kind == .None do first_err = add_err
		}
	}
	return first_err
}

// tx_materialize_attached copies one table of an attached database into a
// temporary table. The rows keep their ids and are visible at any sequence,
// because the attached log's commit sequence has nothing to do with this one.
tx_materialize_attached :: proc(tx: ^Tx, schema, name: string) -> (^Table, Error) {
	attached := tx.store.attached[schema]
	if attached == nil {
		return nil, errf(.Table_Not_Found, "database %s is not attached", schema)
	}
	sync.shared_lock(&attached.mutex)
	source, found := attached.tables[name]
	if !found {
		sync.shared_unlock(&attached.mutex)
		return nil, errf(.Table_Not_Found, "table %s.%s does not exist", schema, name)
	}
	rows := make([dynamic]Row)
	table_collect(source, &rows, max(u64))
	// Copy the schema: the attached store may disappear while the statement
	// runs, so nothing here may point into its arena.
	columns := make([]Column, len(source.schema.columns), tx.alloc)
	for column, i in source.schema.columns {
		columns[i] = column
		columns[i].name = strings.clone(column.name, tx.alloc)
		columns[i].named_type = strings.clone(column.named_type, tx.alloc)
	}
	copied_schema := Table_Schema {
		name    = strings.clone(fmt.tprintf("%s.%s", schema, name), tx.alloc),
		columns = columns,
	}
	copied, table_err := table_create(&copied_schema)
	if table_err.kind != .None {
		sync.shared_unlock(&attached.mutex)
		delete(rows)
		return nil, table_err
	}
	for row in rows {
		if insert_err := table_insert(copied, row.id, row.values); insert_err.kind != .None {
			sync.shared_unlock(&attached.mutex)
			table_destroy(copied)
			delete(rows)
			return nil, insert_err
		}
	}
	delete(rows)
	sync.shared_unlock(&attached.mutex)
	append(&tx.temp_tables, copied)
	return copied, ERROR_NONE
}

// sql_exec_attach records the database in the catalog and opens it read-only.
sql_exec_attach :: proc(store: ^Store, stmt: Attach_Stmt) -> (Sql_Result, Error) {
	if len(stmt.name) == 0 {
		return {}, errf(.Sql_Syntax, "ATTACH needs a database name: ATTACH 'path' AS name")
	}
	if len(stmt.path) == 0 do return {}, errf(.Sql_Syntax, "ATTACH needs a database path")
	if !os.exists(stmt.path) {
		return {}, errf(.Io, "cannot attach %s: it does not exist", stmt.path)
	}
	tx := tx_begin_write(store)
	if attach_recorded(tx, stmt.name) {
		tx_rollback(tx)
		return {}, errf(.Invalid_Argument, "database %s is already attached", stmt.name)
	}
	if ensure_err := attach_ensure(tx); ensure_err.kind != .None {
		tx_rollback(tx)
		return {}, ensure_err
	}
	values := []Value{value_string(strings.clone(stmt.name, tx.alloc)), value_string(strings.clone(stmt.path, tx.alloc))}
	if _, insert_err := tx_insert(tx, ATTACH_TABLE, values); insert_err.kind != .None {
		tx_rollback(tx)
		return {}, insert_err
	}
	if commit_err := tx_commit(tx); commit_err.kind != .None do return {}, commit_err
	if add_err := store_attach_add(store, stmt.name, stmt.path); add_err.kind != .None {
		return {}, add_err
	}
	return Sql_Result {
			kind = .Ack,
			message = strings.clone(fmt.tprintf("attached %s as %s", stmt.path, stmt.name)),
			commit_seq = store.commit_seq,
		},
		ERROR_NONE
}

// sql_exec_detach forgets a database: the catalog row goes, then the handle.
sql_exec_detach :: proc(store: ^Store, stmt: Detach_Stmt) -> (Sql_Result, Error) {
	if len(stmt.name) == 0 do return {}, errf(.Sql_Syntax, "DETACH needs a database name")
	if _, exists := store.attached[stmt.name]; !exists {
		return {}, errf(.Table_Not_Found, "database %s is not attached", stmt.name)
	}
	tx := tx_begin_write(store)
	if attach_recorded(tx, stmt.name) {
		_, delete_err := sql_execute_in_tx_params(
			tx,
			"DELETE FROM _attach WHERE name = ?",
			[]Value{value_string(stmt.name)},
		)
		if delete_err.kind != .None {
			tx_rollback(tx)
			return {}, delete_err
		}
	}
	if commit_err := tx_commit(tx); commit_err.kind != .None do return {}, commit_err
	if remove_err := store_attach_remove(store, stmt.name); remove_err.kind != .None {
		return {}, remove_err
	}
	return Sql_Result {
			kind = .Ack,
			message = strings.clone(fmt.tprintf("detached %s", stmt.name)),
			commit_seq = store.commit_seq,
		},
		ERROR_NONE
}
