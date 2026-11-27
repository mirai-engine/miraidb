package engine

// Triggers are stored as rows in an internal table, so they travel with the
// commit log like any other data and need no new format version. The body is
// kept as text and parsed again when it fires, with NEW and OLD in scope.

import "core:mem"
import "core:strings"
import "core:sync"

TRIGGER_TABLE :: "_triggers"
// TRIGGER_MAX_DEPTH stops a trigger that fires itself from looping forever.
TRIGGER_MAX_DEPTH :: 8

Trigger_Fire_Event :: enum {
	Insert,
	Update,
	Delete,
}

// Trigger_Timing is when the body runs. A BEFORE trigger runs while the row is
// still only proposed, so a failing statement in it stops the write; an AFTER
// trigger runs once the row is staged, and its failure rolls the statement back.
Trigger_Timing :: enum {
	Before,
	After,
	// Instead runs in place of a write to a view (instead.odin).
	Instead,
}

@(private)
trigger_timing_name :: proc(timing: Trigger_Timing) -> string {
	switch timing {
	case .Before:
		return "before"
	case .After:
		return "after"
	case .Instead:
		return "instead"
	}
	return "after"
}

// trigger_ensure creates the catalog on first use.
trigger_ensure :: proc(tx: ^Tx) -> Error {
	if table := tx_table_probe(tx, TRIGGER_TABLE); table != nil {
		// A catalog written before WHEN existed gets the column on first use, so
		// an older database keeps its triggers instead of failing to open them.
		if _, found := schema_column_index(&table.schema, "when_text"); !found {
			discarded_22, alter_err := sql_execute_in_tx(tx, "ALTER TABLE _triggers ADD COLUMN when_text TEXT DEFAULT ''")
			sql_result_destroy(&discarded_22)
			if alter_err.kind != .None do return alter_err
		}
		// UPDATE OF's columns came later still, and the same way.
		if table = tx_table_probe(tx, TRIGGER_TABLE); table != nil {
			if _, found := schema_column_index(&table.schema, "columns"); !found {
				discarded_23, alter_err := sql_execute_in_tx(tx, "ALTER TABLE _triggers ADD COLUMN columns TEXT DEFAULT ''")
				sql_result_destroy(&discarded_23)
				return alter_err
			}
		}
		return ERROR_NONE
	}
	discarded_24, create_err := sql_execute_in_tx(
		tx,
		"CREATE TABLE _triggers (name TEXT PRIMARY KEY NOT NULL, table_name TEXT NOT NULL, event TEXT NOT NULL, timing TEXT NOT NULL, body TEXT NOT NULL, when_text TEXT DEFAULT '', columns TEXT DEFAULT '')",
	)
	sql_result_destroy(&discarded_24)
	return create_err
}

// trigger_create records a trigger, replacing one with the same name.
trigger_create :: proc(tx: ^Tx, stmt: Create_Trigger_Stmt) -> Error {
	if stmt.event != "insert" && stmt.event != "update" && stmt.event != "delete" {
		return errf(.Sql_Syntax, "unknown trigger event %q", stmt.event)
	}
	if len(stmt.body) == 0 {
		return errf(.Sql_Syntax, "a trigger needs at least one statement")
	}
	// The body is parsed now, as SQLite parses it: a statement it cannot read
	// used to be stored, and failed only when the trigger fired.
	for statement in trigger_split(stmt.body, context.temp_allocator) {
		if len(strings.trim_space(statement)) == 0 do continue
		parsed, parse_err := sql_parse(statement)
		query_destroy(&parsed)
		if parse_err.kind != .None do return parse_err
	}
	if ensure_err := trigger_ensure(tx); ensure_err.kind != .None do return ensure_err
	// A view takes only INSTEAD OF triggers, and a table never does.
	_, is_view := view_sql(tx, stmt.table)
	if is_view && !stmt.instead {
		return errf(.Sql_Unsupported, "cannot create %s trigger on view: %s", stmt.before ? "BEFORE" : "AFTER", stmt.table)
	}
	if !is_view && stmt.instead {
		return errf(.Sql_Unsupported, "cannot create INSTEAD OF trigger on table: %s", stmt.table)
	}
	if is_view {
	} else if table, table_err := tx_table(tx, stmt.table); table_err.kind != .None {
		error_free(&table_err)
		return errf(.Table_Not_Found, "trigger table %s does not exist", stmt.table)
	} else if table.schema.ephemeral {
		return errf(.Sql_Unsupported, "triggers need a persistent table")
	}
	if !stmt.if_not_exists {
		// CREATE TRIGGER without IF NOT EXISTS replaces the previous definition.
		if exists_err := trigger_drop(tx, stmt.name, true); exists_err.kind != .None {
			return exists_err
		}
	} else if trigger_lookup(tx, stmt.name) {
		return ERROR_NONE
	}
	values := []Value {
		value_string(stmt.name),
		value_string(stmt.table),
		value_string(stmt.event),
		value_string(stmt.instead ? "instead" : stmt.before ? "before" : "after"),
		value_string(stmt.body),
		value_string(stmt.when_text),
		value_string(strings.join(stmt.columns, ",", tx.alloc)),
	}
	_, insert_err := tx_insert(tx, TRIGGER_TABLE, values)
	return insert_err
}

// trigger_restore puts the transaction back the way it was before one trigger
// ran, whether it fired, was skipped by its WHEN, or failed.
// Trigger_Def is one trigger a write fires: its body, its WHEN, its name and
// the columns of an UPDATE OF ("" for none), as the catalog stores them.
Trigger_Def :: struct {
	body:      string,
	when_text: string,
	name:      string,
	columns:   string,
}

// Trigger_List is the triggers of one table, event and timing, in the order
// they fire, as the catalog of `generation` has them. Its strings are the
// store's, in the heap.
Trigger_List :: struct {
	generation: u64,
	defs:       []Trigger_Def,
}

// TRIGGER_LISTS_SIZE is how many lists a store keeps; past it a list is read
// from the catalog at every firing.
TRIGGER_LISTS_SIZE :: 256

// trigger_def_clone is `def` in `alloc`.
@(private)
trigger_def_clone :: proc(def: Trigger_Def, alloc: mem.Allocator) -> Trigger_Def {
	return Trigger_Def {
		body = strings.clone(def.body, alloc),
		when_text = strings.clone(def.when_text, alloc),
		name = strings.clone(def.name, alloc),
		columns = strings.clone(def.columns, alloc),
	}
}

// trigger_list is the triggers a write of `event_name` to `table_name` fires
// at `timing`, in the transaction's memory: the store's list for the
// transaction's catalog generation (tx_catalog_generation), else read from the
// catalog. A row read the catalog once per timing, the rows of a table with no
// trigger too (A1.10).
@(private)
trigger_list :: proc(tx: ^Tx, table_name, event_name: string, timing: Trigger_Timing) -> ([]Trigger_Def, Error) {
	timing_name := trigger_timing_name(timing)
	key := strings.concatenate({table_name, "\x00", event_name, "\x00", timing_name}, tx.alloc)
	generation, holds := tx_catalog_generation(tx)
	store := tx.store
	if holds {
		sync.mutex_lock(&store.trigger_lists_mutex)
		if list, found := store.trigger_lists[key]; found && list.generation == generation {
			// Copied out: another transaction, at another generation, may
			// replace the list while this one's bodies run.
			defs := make([]Trigger_Def, len(list.defs), tx.alloc)
			for def, i in list.defs do defs[i] = trigger_def_clone(def, tx.alloc)
			sync.mutex_unlock(&store.trigger_lists_mutex)
			return defs, ERROR_NONE
		}
		sync.mutex_unlock(&store.trigger_lists_mutex)
	}
	// A catalog written before UPDATE OF existed has no columns column until
	// the next CREATE TRIGGER adds it.
	query := "SELECT body, when_text, name, '' FROM _triggers WHERE table_name = ? AND event = ? AND timing = ? ORDER BY name"
	if catalog := tx_table_probe(tx, TRIGGER_TABLE); catalog != nil {
		if _, found := schema_column_index(&catalog.schema, "columns"); found {
			query = "SELECT body, when_text, name, columns FROM _triggers WHERE table_name = ? AND event = ? AND timing = ? ORDER BY name"
		}
	}
	result, query_err := sql_execute_in_tx_kept(
		tx,
		.Internal,
		query,
		[]Value{value_string(table_name), value_string(event_name), value_string(timing_name)},
	)
	if query_err.kind != .None do return nil, query_err
	defer sql_result_destroy(&result)
	defs := make([dynamic]Trigger_Def, 0, len(result.rows), tx.alloc)
	for row in result.rows {
		if len(row) == 0 || row[0].kind != .String do continue
		def := Trigger_Def{body = row[0].s}
		if len(row) > 1 && row[1].kind == .String do def.when_text = row[1].s
		if len(row) > 2 && row[2].kind == .String do def.name = row[2].s
		if len(row) > 3 && row[3].kind == .String do def.columns = row[3].s
		append(&defs, trigger_def_clone(def, tx.alloc))
	}
	if holds {
		sync.mutex_lock(&store.trigger_lists_mutex)
		defer sync.mutex_unlock(&store.trigger_lists_mutex)
		if _, found := store.trigger_lists[key]; found {
			old_key, old := delete_key(&store.trigger_lists, key)
			delete(old_key)
			trigger_list_free(old)
		}
		if len(store.trigger_lists) < TRIGGER_LISTS_SIZE {
			kept := make([]Trigger_Def, len(defs))
			for def, i in defs do kept[i] = trigger_def_clone(def, context.allocator)
			store.trigger_lists[strings.clone(key)] = Trigger_List{generation = generation, defs = kept}
		}
	}
	return defs[:], ERROR_NONE
}

@(private)
trigger_list_free :: proc(list: Trigger_List) {
	for def in list.defs {
		delete(def.body)
		delete(def.when_text)
		delete(def.name)
		delete(def.columns)
	}
	delete(list.defs)
}

// trigger_lists_clear frees every list the store keeps.
trigger_lists_clear :: proc(store: ^Store) {
	sync.mutex_lock(&store.trigger_lists_mutex)
	defer sync.mutex_unlock(&store.trigger_lists_mutex)
	for key, list in store.trigger_lists {
		delete(key)
		trigger_list_free(list)
	}
	delete(store.trigger_lists)
	store.trigger_lists = nil
}

@(private)
trigger_restore :: proc(
	tx: ^Tx,
	active: bool,
	schema: Table_Schema,
	new_row: Row,
	old_row: Row,
	new_present: bool,
	old_present: bool,
	depth: int,
) {
	tx.trigger_active = active
	tx.trigger_schema = schema
	tx.trigger_new = new_row
	tx.trigger_old = old_row
	tx.trigger_new_present = new_present
	tx.trigger_old_present = old_present
	tx.trigger_depth = depth
}

@(private)
trigger_lookup :: proc(tx: ^Tx, name: string) -> (found: bool) {
	result, err := sql_execute_in_tx_params(tx, "SELECT 1 FROM _triggers WHERE name = ?", []Value{value_string(name)})
	if err.kind != .None {
		error_free(&err)
		return false
	}
	defer sql_result_destroy(&result)
	return len(result.rows) > 0
}

trigger_drop :: proc(tx: ^Tx, name: string, if_exists: bool) -> Error {
	if !tx_system_table_exists(tx, TRIGGER_TABLE, &tx.trigger_probe) {
		if if_exists do return ERROR_NONE
		return errf(.Table_Not_Found, "trigger %s does not exist", name)
	}
	if !trigger_lookup(tx, name) {
		if if_exists do return ERROR_NONE
		return errf(.Table_Not_Found, "trigger %s does not exist", name)
	}
	discarded_25, delete_err := sql_execute_in_tx_params(
		tx,
		"DELETE FROM _triggers WHERE name = ?",
		[]Value{value_string(name)},
	)
	sql_result_destroy(&discarded_25)
	return delete_err
}

// trigger_columns_set reports whether an UPDATE's SET (`set`, nil when the
// write did not come from a SET) names one of an UPDATE OF trigger's columns.
@(private)
trigger_columns_set :: proc(columns: string, set: []string) -> bool {
	if set == nil do return true
	for column in strings.split(columns, ",", context.temp_allocator) {
		for assigned in set {
			if strings.equal_fold(column, assigned) do return true
		}
	}
	return false
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
	timing: Trigger_Timing,
	old_row: Row,
	new_row: Row,
	schema: Table_Schema,
) -> Error {
	// Internal tables have no triggers, and a transaction that never created one
	// never pays for the catalog lookup.
	if len(table_name) > 0 && table_name[0] == '_' do return ERROR_NONE
	if tx.no_triggers do return ERROR_NONE
	// Most databases have no triggers, and that is the answer to almost every call
	// here: a probe asks it without an error message to throw away.
	if !tx_system_table_exists(tx, TRIGGER_TABLE, &tx.trigger_probe) do return ERROR_NONE
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
	defs, list_err := trigger_list(tx, table_name, event_name, timing)
	if list_err.kind != .None do return list_err
	for def in defs {
		name := def.name
		// UPDATE OF fires only for an UPDATE whose SET names one of its columns.
		if event == .Update && len(def.columns) > 0 {
			if !trigger_columns_set(def.columns, tx.update_set) do continue
		}
		// An authorizer may have answered Ignore about this body when the
		// statement firing it was prepared (authorize.odin).
		replayed := auth_replay_concerns(name)
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
		// The WHEN condition runs with NEW and OLD bound; a false condition means
		// this trigger does not fire for this row, which is not an error.
		when_text := def.when_text
		if len(when_text) > 0 {
			// The condition is kept by the store, as a CHECK is (store_expression);
			// an authorizer's answers rewrite their own copy.
			condition: Query
			condition_expr: ^Expr
			condition_err: Error
			if replayed {
				condition, condition_expr, condition_err = sql_parse_expression(when_text)
			} else {
				condition_expr, condition_err = store_expression(tx.store, when_text)
			}
			if condition_err.kind != .None {
				trigger_restore(tx, saved_active, saved_schema, saved_new, saved_old, saved_new_present, saved_old_present, saved_depth)
				return condition_err
			}
			if replayed do auth_replay_condition(tx, name, &condition, &condition_expr)
			eval_ctx := eval_context(Eval_Ctx{tx = tx})
			value, value_err := eval_expr(&eval_ctx, condition_expr)
			if replayed do query_destroy(&condition)
			if value_err.kind != .None {
				trigger_restore(tx, saved_active, saved_schema, saved_new, saved_old, saved_new_present, saved_old_present, saved_depth)
				return trigger_ignored(value_err, timing)
			}
			if !value_is_truthy(value) {
				trigger_restore(tx, saved_active, saved_schema, saved_new, saved_old, saved_new_present, saved_old_present, saved_depth)
				continue
			}
		}
		statements := trigger_split(def.body, tx.alloc)
		body_err := ERROR_NONE
		for statement in statements {
			text := strings.trim_space(statement)
			if len(text) == 0 do continue
			exec_err: Error
			if replayed {
				exec_err = auth_replay_statement(tx, name, text)
			} else {
				// A SELECT in the body (a RAISE's, often) answers rows nobody reads,
				// which are freed here: they leaked.
				answered: Sql_Result
				answered, exec_err = sql_execute_in_tx_kept(tx, .Trigger_Body, text, nil, table_name)
				sql_result_destroy(&answered)
			}
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
		if body_err.kind != .None do return trigger_ignored(body_err, timing)
	}
	return ERROR_NONE
}

// trigger_ignored is what a trigger's error means to the write that fired it.
// RAISE(IGNORE) abandons this trigger and the ones after it; a BEFORE
// trigger's also skips the row, which the statement does on hearing it, while
// after an AFTER or INSTEAD OF trigger the row's write stands.
@(private)
trigger_ignored :: proc(err: Error, timing: Trigger_Timing) -> Error {
	if err.kind == .Trigger_Ignore && timing != .Before do return ERROR_NONE
	return err
}
