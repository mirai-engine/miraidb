package engine

// Triggers are stored as rows in an internal table, so they travel with the
// commit log like any other data and need no new format version. The body is
// kept as text and parsed again when it fires, with NEW and OLD in scope.

import "core:mem"
import "core:strings"

TRIGGER_TABLE :: "_triggers"
// TRIGGER_MAX_DEPTH stops a trigger that fires itself from looping forever.
TRIGGER_MAX_DEPTH :: 8

Trigger_Fire_Event :: enum {
	Insert,
	Update,
	Delete,
}

// trigger_ensure creates the catalog on first use.
trigger_ensure :: proc(tx: ^Tx) -> Error {
	if _, table_err := tx_table(tx, TRIGGER_TABLE); table_err.kind == .None do return ERROR_NONE
	_, create_err := sql_execute_in_tx(
		tx,
		"CREATE TABLE _triggers (name TEXT PRIMARY KEY NOT NULL, table_name TEXT NOT NULL, event TEXT NOT NULL, timing TEXT NOT NULL, body TEXT NOT NULL)",
	)
	return create_err
}

// trigger_create records a trigger, replacing one with the same name.
trigger_create :: proc(tx: ^Tx, stmt: Create_Trigger_Stmt) -> Error {
	if stmt.before {
		return errf(.Sql_Unsupported, "only AFTER triggers are supported")
	}
	if stmt.event != "insert" && stmt.event != "update" && stmt.event != "delete" {
		return errf(.Sql_Syntax, "unknown trigger event %q", stmt.event)
	}
	if len(stmt.body) == 0 {
		return errf(.Sql_Syntax, "a trigger needs at least one statement")
	}
	if ensure_err := trigger_ensure(tx); ensure_err.kind != .None do return ensure_err
	if table, table_err := tx_table(tx, stmt.table); table_err.kind != .None {
		return errf(.Table_Not_Found, "trigger table %s does not exist", stmt.table)
	} else if table.schema.ephemeral {
		return errf(.Sql_Unsupported, "triggers need a persistent table")
	}
	if !stmt.if_not_exists {
		// CREATE TRIGGER without IF NOT EXISTS replaces the previous definition.
		if exists_err := trigger_drop(tx, stmt.name, true); exists_err.kind != .None {
			return exists_err
		}
	} else if _, found := trigger_lookup(tx, stmt.name); found {
		return ERROR_NONE
	}
	values := []Value {
		value_string(stmt.name),
		value_string(stmt.table),
		value_string(stmt.event),
		value_string("after"),
		value_string(stmt.body),
	}
	_, insert_err := tx_insert(tx, TRIGGER_TABLE, values)
	return insert_err
}

@(private)
trigger_lookup :: proc(tx: ^Tx, name: string) -> (row: []Value, found: bool) {
	result, err := sql_execute_in_tx_params(
		tx,
		"SELECT name, table_name, event, timing, body FROM _triggers WHERE name = ?",
		[]Value{value_string(name)},
	)
	if err.kind != .None do return nil, false
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return nil, false
	return result.rows[0], true
}

trigger_drop :: proc(tx: ^Tx, name: string, if_exists: bool) -> Error {
	if _, table_err := tx_table(tx, TRIGGER_TABLE); table_err.kind != .None {
		if if_exists do return ERROR_NONE
		return errf(.Table_Not_Found, "trigger %s does not exist", name)
	}
	if _, found := trigger_lookup(tx, name); !found {
		if if_exists do return ERROR_NONE
		return errf(.Table_Not_Found, "trigger %s does not exist", name)
	}
	_, delete_err := sql_execute_in_tx_params(
		tx,
		"DELETE FROM _triggers WHERE name = ?",
		[]Value{value_string(name)},
	)
	return delete_err
}

// trigger_split cuts a body into statements, ignoring the semicolons inside
// string literals.
trigger_split :: proc(body: string, alloc: mem.Allocator) -> [dynamic]string {
	parts := make([dynamic]string, 0, 2, alloc)
	start := 0
	quote: u8
	for index in 0 ..< len(body) {
		at := body[index]
		if quote != 0 {
			if at == quote do quote = 0
			continue
		}
		switch at {
		case '\'', '"':
			quote = at
		case ';':
			append(&parts, body[start:index])
			start = index + 1
		}
	}
	append(&parts, body[start:])
	return parts
}

// trigger_fire runs the AFTER triggers of one row event. The rows carry the
// values NEW and OLD name; the absent side of an event reports NULL.
trigger_fire :: proc(
	tx: ^Tx,
	table_name: string,
	event: Trigger_Fire_Event,
	old_row: Row,
	new_row: Row,
	schema: Table_Schema,
) -> Error {
	// Internal tables have no triggers, and a transaction that never created one
	// never pays for the catalog lookup.
	if len(table_name) > 0 && table_name[0] == '_' do return ERROR_NONE
	if _, table_err := tx_table(tx, TRIGGER_TABLE); table_err.kind != .None do return ERROR_NONE
	if tx.trigger_depth >= TRIGGER_MAX_DEPTH {
		return errf(.Sql_Unsupported, "triggers nest more than %d deep", TRIGGER_MAX_DEPTH)
	}
	event_name := "insert"
	switch event {
	case .Insert:
	case .Update:
		event_name = "update"
	case .Delete:
		event_name = "delete"
	}
	result, query_err := sql_execute_in_tx_params(
		tx,
		"SELECT body FROM _triggers WHERE table_name = ? AND event = ? AND timing = 'after' ORDER BY name",
		[]Value{value_string(table_name), value_string(event_name)},
	)
	if query_err.kind != .None do return query_err
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return ERROR_NONE
	for row in result.rows {
		if len(row) == 0 || row[0].kind != .String do continue
		saved_active := tx.trigger_active
		saved_schema := tx.trigger_schema
		saved_new := tx.trigger_new
		saved_old := tx.trigger_old
		saved_new_present := tx.trigger_new_present
		saved_old_present := tx.trigger_old_present
		saved_depth := tx.trigger_depth
		tx.trigger_active = true
		tx.trigger_schema = schema
		tx.trigger_new = new_row
		tx.trigger_old = old_row
		tx.trigger_new_present = event != .Delete
		tx.trigger_old_present = event != .Insert
		tx.trigger_depth = saved_depth + 1
		statements := trigger_split(row[0].s, tx.alloc)
		body_err := ERROR_NONE
		for statement in statements {
			text := strings.trim_space(statement)
			if len(text) == 0 do continue
			_, exec_err := sql_execute_in_tx(tx, text)
			if exec_err.kind != .None {
				body_err = exec_err
				break
			}
		}
		tx.trigger_active = saved_active
		tx.trigger_schema = saved_schema
		tx.trigger_new = saved_new
		tx.trigger_old = saved_old
		tx.trigger_new_present = saved_new_present
		tx.trigger_old_present = saved_old_present
		tx.trigger_depth = saved_depth
		if body_err.kind != .None do return body_err
	}
	return ERROR_NONE
}
