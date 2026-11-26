package engine

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// ATTACH makes a second database reachable as `name.table`, for reading and,
// as in SQLite, for writing: a statement that writes `name.t` runs in a
// transaction of the attached database that the connection's transaction opens
// the first time it needs it, and commits or rolls back with it (the attached
// one first). The commit is two commits, not one: a crash between them keeps the
// attached database's and loses the main one's, as SQLite's WAL mode does
// across files. Its name and path live in the `_attach` catalog, which travels
// with the commit log like any other data, so a reopen restores the set without
// a format change.

ATTACH_TABLE :: "_attach"

// ATTACHED_SEPARATOR joins an attached database's name to an object's in the
// names the parser hands over (`side.t` becomes "side" + this + "t"); no
// identifier the lexer reads holds it.
ATTACHED_SEPARATOR :: "\x1f"

// attach_split splits a name the parser qualified with an attached database.
attach_split :: proc(name: string) -> (schema: string, object: string, qualified: bool) {
	at := strings.index(name, ATTACHED_SEPARATOR)
	if at < 0 do return "", name, false
	return name[:at], name[at + len(ATTACHED_SEPARATOR):], true
}

// attach_display is a name as the user wrote it, for a message.
attach_display :: proc(name: string, alloc := context.temp_allocator) -> string {
	schema, object, qualified := attach_split(name)
	if !qualified do return name
	return strings.concatenate({schema, ".", object}, alloc)
}

// statement_attached reports a statement that writes an attached database and
// gives it back naming the object without the database.
@(private)
statement_attached :: proc(statement: Statement) -> (schema: string, local: Statement, attached: bool) {
	schema, _, local, attached = statement_attached_object(statement)
	return
}

// statement_attached_object is statement_attached that also names the object
// the statement writes, without its database.
@(private)
statement_attached_object :: proc(statement: Statement) -> (schema: string, object: string, local: Statement, attached: bool) {
	s, l, ok := statement_attached_split(statement)
	if !ok do return "", "", statement, false
	#partial switch stmt in l {
	case Insert_Stmt:
		object = stmt.table
	case Update_Stmt:
		object = stmt.table
	case Delete_Stmt:
		object = stmt.table
	case Create_Table_Stmt:
		object = stmt.name
	case Drop_Table_Stmt:
		object = stmt.name
	case Create_Index_Stmt:
		object = stmt.table
	}
	return s, object, l, true
}

@(private)
statement_attached_split :: proc(statement: Statement) -> (schema: string, local: Statement, attached: bool) {
	#partial switch stmt in statement {
	case Insert_Stmt:
		if s, object, ok := attach_split(stmt.table); ok {
			copy := stmt
			copy.table = object
			return s, copy, true
		}
	case Update_Stmt:
		if s, object, ok := attach_split(stmt.table); ok {
			copy := stmt
			copy.table = object
			return s, copy, true
		}
	case Delete_Stmt:
		if s, object, ok := attach_split(stmt.table); ok {
			copy := stmt
			copy.table = object
			return s, copy, true
		}
	case Create_Table_Stmt:
		if s, object, ok := attach_split(stmt.name); ok {
			copy := stmt
			copy.name = object
			return s, copy, true
		}
	case Drop_Table_Stmt:
		if s, object, ok := attach_split(stmt.name); ok {
			copy := stmt
			copy.name = object
			return s, copy, true
		}
	case Create_Index_Stmt:
		// `CREATE INDEX side.i ON t`: the table is side's.
		if s, object, ok := attach_split(stmt.name); ok {
			copy := stmt
			copy.name = object
			return s, copy, true
		}
	case Drop_Index_Stmt:
		if s, object, ok := attach_split(stmt.name); ok {
			copy := stmt
			copy.name = object
			return s, copy, true
		}
	}
	return "", statement, false
}

// tx_attached is the transaction of attached database `schema` that `tx`
// writes it through, begun the first time.
@(private)
tx_attached :: proc(tx: ^Tx, schema: string) -> (^Tx, Error) {
	if attached, open := tx.attached_txs[schema]; open do return attached, ERROR_NONE
	store := tx.store.attached[schema]
	if store == nil do return nil, errf(.Table_Not_Found, "unknown database %s", schema)
	if tx.read_only do return nil, errf(.Transaction_Read_Only, "cannot write %s in a read transaction", schema)
	attached := tx_begin_write(store)
	if attached.read_only {
		tx_end(attached)
		return nil, errf(.Transaction_Read_Only, "attempt to write a readonly database")
	}
	attached.attach_parent = tx
	attached.attach_name = strings.clone(schema, attached.alloc)
	if tx.attached_txs == nil do tx.attached_txs = make(map[string]^Tx, runtime.heap_allocator())
	tx.attached_txs[strings.clone(schema, runtime.heap_allocator())] = attached
	return attached, ERROR_NONE
}

// tx_attached_commit commits what the transaction wrote to attached databases.
// One that fails rolls the rest back; the caller rolls its own back.
@(private)
tx_attached_commit :: proc(tx: ^Tx) -> Error {
	failure := ERROR_NONE
	for name, attached in tx.attached_txs {
		if failure.kind == .None {
			failure = tx_commit(attached)
		} else {
			tx_rollback(attached)
		}
		delete(name, runtime.heap_allocator())
	}
	delete(tx.attached_txs)
	tx.attached_txs = nil
	return failure
}

// tx_attached_rollback undoes what the transaction wrote to attached databases.
@(private)
tx_attached_rollback :: proc(tx: ^Tx) {
	for name, attached in tx.attached_txs {
		tx_rollback(attached)
		delete(name, runtime.heap_allocator())
	}
	delete(tx.attached_txs)
	tx.attached_txs = nil
}

// attach_ensure creates the catalog on first use.
attach_ensure :: proc(tx: ^Tx) -> Error {
	if tx_table_probe(tx, ATTACH_TABLE) != nil do return ERROR_NONE
	discarded_1, create_err := sql_execute_in_tx(
		tx,
		"CREATE TABLE _attach (name TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL)",
	)
	sql_result_destroy(&discarded_1)
	return create_err
}

// attach_recorded reports whether the catalog already holds `name`.
attach_recorded :: proc(tx: ^Tx, name: string) -> bool {
	if tx_table_probe(tx, ATTACH_TABLE) == nil do return false
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
	attached, open_err := attach_open(store, path)
	if open_err.kind != .None {
		defer error_free(&open_err)
		return errf(open_err.kind, "cannot attach %s: %s", path, open_err.message)
	}
	store.attached[strings.clone(name, context.allocator)] = attached
	attached.catalog_parent = store
	store_catalog_changed(store)
	return ERROR_NONE
}

// attach_open opens the database ATTACH names. A SQLite file is read into a
// store that mirrors back to it, as sqlite3_open reads one; under SQLite's
// rules a path that does not exist becomes an empty SQLite file, as SQLite
// creates it. Anything else is an engine database. The attached store answers
// with the rules of the store it is attached to.
@(private)
attach_open :: proc(parent: ^Store, path: string) -> (^Store, Error) {
	opened: ^Store
	if !os.exists(path) && parent.sqlite_rules {
		if parent.read_only || !sqlite_create_empty_file(path) do return nil, errf(.Io, "unable to open database: %s", path)
	}
	switch {
	case sqlite_is_empty_file(path):
		memory, memory_err := store_open("", {persistent = false})
		if memory_err.kind != .None do return nil, memory_err
		store_set_sqlite_mirror(memory, path)
		opened = memory
	case sqlite_is_file(path):
		file, file_err := sqlite_file_open(path)
		if file_err.kind != .None do return nil, file_err
		defer sqlite_file_destroy(&file)
		memory, memory_err := store_open("", {persistent = false})
		if memory_err.kind != .None do return nil, memory_err
		if _, _, import_err := sqlite_import(&file, memory); import_err.kind != .None {
			store_close(memory)
			return nil, import_err
		}
		store_set_sqlite_mirror(memory, path)
		opened = memory
	case:
		engine, engine_err := store_open(path, {persistent = true, create = false, durable = false})
		if engine_err.kind != .None do return nil, engine_err
		opened = engine
	}
	attach_inherit_rules(parent, opened)
	return opened, ERROR_NONE
}

// attach_inherit_rules gives an attached store the rules of its parent.
@(private)
attach_inherit_rules :: proc(parent, attached: ^Store) {
	attached.sqlite_rules = parent.sqlite_rules
	attached.sqlite_names = parent.sqlite_names
	attached.foreign_keys_off = parent.foreign_keys_off
	// A read-only connection attaches read-only, as SQLite passes its open
	// flags on to every database it attaches.
	if parent.read_only do attached.read_only = true
}

// store_attach_remove closes an attached database and forgets its handle.
store_attach_remove :: proc(store: ^Store, name: string) -> Error {
	sync.lock(&store.mutex)
	attached, exists := store.attached[name]
	if !exists {
		sync.unlock(&store.mutex)
		return errf(.Table_Not_Found, "database %s is not attached", name)
	}
	// The key is the copy ATTACH made of the name.
	key, _ := delete_key(&store.attached, name)
	attached.catalog_parent = nil
	store_catalog_changed(store)
	sync.unlock(&store.mutex)
	delete(key)
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
	defer table_collect_release(table, &rows)
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

// tx_parent_source resolves, in the transaction of an attached database, a
// name that belongs to another database of the connection, and answers
// handled = false for one that is this database's own. Under SQLite's rules an
// unqualified name is main's (or temp's) when main has it, else this
// database's; the table the statement writes is always this database's. What
// the parent answers is copied into this transaction, which owns it for the
// statement.
@(private)
tx_parent_source :: proc(tx: ^Tx, name: string, args: []Value, schema: string) -> (table: ^Table, handled: bool, err: Error) {
	parent := tx.attach_parent
	if parent == nil do return nil, false, ERROR_NONE
	if len(schema) > 0 && strings.equal_fold(schema, tx.attach_name) do return nil, false, ERROR_NONE
	if len(schema) == 0 {
		if strings.equal_fold(name, tx.attach_target) do return nil, false, ERROR_NONE
		_, parent_view := view_sql(parent, name)
		if tx_table_probe(parent, name) == nil && !parent_view do return nil, false, ERROR_NONE
	}
	source, is_view, source_err := tx_source_table(parent, name, args, schema)
	if source_err.kind != .None do return nil, true, source_err
	if is_view do return source, true, ERROR_NONE
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := tx_collect(parent, name, &rows); collect_err.kind != .None do return nil, true, collect_err
	copied, copy_err := attach_copy_table(tx, len(schema) > 0 ? schema : "main", name, source, rows[:])
	return copied, true, copy_err
}

// tx_parent_probe is the table an unqualified name means in the transaction
// of an attached database when it is another database's (tx_parent_source).
@(private)
tx_parent_probe :: proc(tx: ^Tx, name: string) -> ^Table {
	if tx.attach_parent == nil || strings.equal_fold(name, tx.attach_target) do return nil
	return tx_table_probe(tx.attach_parent, name)
}

// tx_materialize_attached copies one table of an attached database into a
// temporary table. The rows keep their ids and are visible at any sequence,
// because the attached log's commit sequence has nothing to do with this one.
tx_materialize_attached :: proc(tx: ^Tx, schema, name: string) -> (^Table, Error) {
	// Inside a transaction that wrote the database, it is read through that
	// transaction, which sees its own writes.
	if writer, open := tx.attached_txs[schema]; open {
		if attach_is_catalog(writer, name) do return attach_copy_catalog(tx, writer, schema, name)
		source, source_err := tx_table(writer, name)
		if source_err.kind != .None {
			error_free(&source_err)
			return nil, errf(.Table_Not_Found, "no such table: %s.%s", schema, name)
		}
		rows := make([dynamic]Row)
		defer delete(rows)
		if collect_err := tx_collect(writer, name, &rows); collect_err.kind != .None do return nil, collect_err
		return attach_copy_table(tx, schema, name, source, rows[:])
	}
	attached := tx.store.attached[schema]
	if attached == nil {
		return nil, errf(.Table_Not_Found, "database %s is not attached", schema)
	}
	if is_schema, temp := sqlite_schema_name(name); is_schema && !temp {
		if _, real := attached.tables[name]; !real {
			reader := tx_begin_read(attached)
			defer tx_end(reader)
			return attach_copy_catalog(tx, reader, schema, name)
		}
	}
	sync.shared_lock(&attached.mutex)
	defer sync.shared_unlock(&attached.mutex)
	source, found := attached.tables[name]
	if !found {
		return nil, errf(.Table_Not_Found, "table %s.%s does not exist", schema, name)
	}
	rows := make([dynamic]Row)
	table_collect(source, &rows, max(u64))
	defer table_collect_release(source, &rows)
	return attach_copy_table(tx, schema, name, source, rows[:])
}

// attach_is_catalog says `name` is SQLite's catalog in the database `reader`
// reads, rather than a table of that name.
@(private)
attach_is_catalog :: proc(reader: ^Tx, name: string) -> bool {
	is_schema, temp := sqlite_schema_name(name)
	return is_schema && !temp && tx_table_probe(reader, name) == nil
}

// attach_copy_catalog is `schema.sqlite_schema`: the attached database's
// catalog, built in `reader` (a transaction of that database) and copied into
// one `tx` owns, as an attached table is.
@(private)
attach_copy_catalog :: proc(tx, reader: ^Tx, schema, name: string) -> (^Table, Error) {
	catalog, catalog_err := tx_materialize_sqlite_schema(reader, name, false)
	if catalog_err.kind != .None do return nil, catalog_err
	rows := make([dynamic]Row)
	table_collect(catalog, &rows, max(u64))
	defer table_collect_release(catalog, &rows)
	return attach_copy_table(tx, schema, name, catalog, rows[:])
}

// attach_copy_table copies an attached table into one the transaction owns and
// scans like a view: the attached store may disappear while the statement
// runs, so nothing here may point into its arena.
@(private)
attach_copy_table :: proc(tx: ^Tx, schema, name: string, source: ^Table, rows: []Row) -> (^Table, Error) {
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
	if table_err.kind != .None do return nil, table_err
	for row in rows {
		if insert_err := table_insert(copied, row.id, row.values); insert_err.kind != .None {
			table_destroy(copied)
			return nil, insert_err
		}
	}
	append(&tx.temp_tables, copied)
	return copied, ERROR_NONE
}

// sql_exec_attach records the database in the catalog and opens it read-only.
sql_exec_attach :: proc(store: ^Store, stmt: Attach_Stmt) -> (Sql_Result, Error) {
	if len(stmt.name) == 0 {
		return {}, errf(.Sql_Syntax, "ATTACH needs a database name: ATTACH 'path' AS name")
	}
	if len(stmt.path) == 0 do return {}, errf(.Sql_Syntax, "ATTACH needs a database path")
	// ':memory:' (or an empty path) attaches a new, empty database in memory, as
	// in SQLite; it is not recorded, since there is nothing to open again.
	if store_path_is_memory(stmt.path) {
		if _, exists := store.attached[stmt.name]; exists {
			return {}, errf(.Invalid_Argument, "database %s is already in use", stmt.name)
		}
		memory, open_err := store_open("", {persistent = false})
		if open_err.kind != .None do return {}, open_err
		attach_inherit_rules(store, memory)
		sync.lock(&store.mutex)
		store.attached[strings.clone(stmt.name, context.allocator)] = memory
		memory.catalog_parent = store
		store_catalog_changed(store)
		sync.unlock(&store.mutex)
		return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
	}
	// SQLite creates a file that is not there (attach_open); the engine's own
	// rules refuse it.
	if !os.exists(stmt.path) && !store.sqlite_rules {
		return {}, errf(.Io, "cannot attach %s: it does not exist", stmt.path)
	}
	// A read-only store cannot record the attachment: it lasts as long as the
	// connection, which is all SQLite's ATTACH ever does.
	if store.read_only {
		if add_err := store_attach_add(store, stmt.name, stmt.path); add_err.kind != .None do return {}, add_err
		return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
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
	// A database in memory has no catalog row: it is only closed.
	if attached := store.attached[stmt.name]; attached != nil && (!attached.persistent || store.read_only) {
		if remove_err := store_attach_remove(store, stmt.name); remove_err.kind != .None do return {}, remove_err
		return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
	}
	tx := tx_begin_write(store)
	if attach_recorded(tx, stmt.name) {
		discarded_2, delete_err := sql_execute_in_tx_params(
			tx,
			"DELETE FROM _attach WHERE name = ?",
			[]Value{value_string(stmt.name)},
		)
		sql_result_destroy(&discarded_2)
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
