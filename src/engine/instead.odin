package engine

// INSTEAD OF triggers make a view writable. An INSERT, UPDATE or DELETE on a
// view writes nothing itself: each row it would touch fires the view's INSTEAD
// OF trigger for that event, with NEW and OLD bound to the view's columns, and
// the trigger's body does the writing. As in SQLite, those rows are not counted
// as the statement's changes, and a view without such a trigger is refused.

// trigger_exists reports a trigger on `table_name` for one event and timing.
@(private)
trigger_exists :: proc(tx: ^Tx, table_name: string, event: string, timing: string) -> bool {
	if !tx_system_table_exists(tx, TRIGGER_TABLE, &tx.trigger_probe) do return false
	result, err := sql_execute_in_tx_params(
		tx,
		"SELECT 1 FROM _triggers WHERE table_name = ? AND event = ? AND timing = ?",
		[]Value{value_string(table_name), value_string(event), value_string(timing)},
	)
	if err.kind != .None {
		error_free(&err)
		return false
	}
	defer sql_result_destroy(&result)
	return len(result.rows) > 0
}

// triggers_drop_on removes every trigger defined on `table_name`: they go with
// the view (or table) they belong to.
@(private)
triggers_drop_on :: proc(tx: ^Tx, table_name: string) -> Error {
	if !tx_system_table_exists(tx, TRIGGER_TABLE, &tx.trigger_probe) do return ERROR_NONE
	// A name is matched as SQLite matches it, without regard to case.
	result, err := sql_execute_in_tx_params(tx, "DELETE FROM _triggers WHERE lower(table_name) = lower(?)", []Value{value_string(table_name)})
	if err.kind != .None do return err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// view_write runs an INSERT, UPDATE or DELETE on view `name` through its
// INSTEAD OF trigger.
view_write :: proc(tx: ^Tx, name: string, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	event := "insert"
	#partial switch _ in statement {
	case Update_Stmt:
		event = "update"
	case Delete_Stmt:
		event = "delete"
	}
	if !trigger_exists(tx, name, event, "instead") {
		return {}, errf(.Sql_Unsupported, "cannot modify %s because it is a view", name)
	}
	view, _, view_err := tx_source_table(tx, name, nil)
	if view_err.kind != .None do return {}, view_err
	schema := view.schema
	width := len(schema.columns)
	ctx := eval_context(Eval_Ctx{tx = tx, params = params})
	result := Sql_Result{kind = .Affected}
	returned := make([dynamic][]Value, 0, 4)
	returning: ^Returning
	#partial switch s in statement {
	case Insert_Stmt:
		returning = s.returning
		if s.conflict_do_nothing || len(s.conflict_assignments) > 0 {
			return {}, errf(.Sql_Unsupported, "cannot UPSERT a view")
		}
		positions := make([]int, len(s.columns) > 0 ? len(s.columns) : width, tx.alloc)
		if len(s.columns) == 0 {
			for i in 0 ..< width do positions[i] = i
		} else {
			for column, i in s.columns {
				index, found := schema_column_index(&schema, column)
				if !found do return {}, errf(.Column_Not_Found, "table %s has no column named %s", name, column)
				positions[i] = index
			}
		}
		rows := make([dynamic][]Value, 0, len(s.rows), tx.alloc)
		if s.has_select {
			query, query_err := sql_exec_select(tx, s.select_stmt, params)
			if query_err.kind != .None do return {}, query_err
			for row in query.rows do append(&rows, row)
		} else {
			for exprs in s.rows {
				values := make([]Value, len(exprs), tx.alloc)
				for expr, i in exprs {
					value, eval_err := eval_expr(&ctx, expr)
					if eval_err.kind != .None do return {}, eval_err
					values[i] = value
				}
				append(&rows, values)
			}
		}
		for row in rows {
			if len(row) != len(positions) {
				return {}, errf(.Invalid_Argument, "table %s has %d columns but %d values were supplied", name, len(positions), len(row))
			}
			new_values := make([]Value, width, tx.alloc)
			for i in 0 ..< width do new_values[i] = value_null()
			for value, i in row do new_values[positions[i]] = value
			if err := trigger_fire(tx, name, .Insert, .Instead, Row{}, Row{values = new_values}, schema); err.kind != .None {
				return {}, err
			}
			if err := returning_append(tx, &result, &returned, returning, view, Row{values = new_values}); err.kind != .None do return {}, err
		}
	case Update_Stmt, Delete_Stmt:
		where_clause: ^Expr
		assignments: []Assignment
		update, is_update := s.(Update_Stmt)
		if is_update {
			if len(update.from.name) > 0 || update.from.subquery != nil {
				return {}, errf(.Sql_Unsupported, "UPDATE ... FROM is not supported on a view")
			}
			where_clause, assignments, returning = update.where_clause, update.assignments, update.returning
			for assignment in assignments {
				if _, found := schema_column_index(&schema, assignment.column); !found {
					return {}, errf(.Column_Not_Found, "no such column: %s", assignment.column)
				}
			}
		} else {
			remove := s.(Delete_Stmt)
			if len(remove.using_ref.name) > 0 || remove.using_ref.subquery != nil {
				return {}, errf(.Sql_Unsupported, "DELETE ... USING is not supported on a view")
			}
			where_clause, returning = remove.where_clause, remove.returning
		}
		rows := make([dynamic]Row, 0, 8, tx.alloc)
		table_collect(view, &rows, max(u64), tx.alloc)
		// The rows are chosen before any trigger runs, so a body that writes
		// the tables under the view does not change which rows it sees.
		chosen := make([dynamic]Row, 0, len(rows), tx.alloc)
		for row in rows {
			sources := []Source{{table = view, row = row}}
			ctx.sources = sources
			if where_clause != nil {
				value, eval_err := eval_expr(&ctx, where_clause)
				if eval_err.kind != .None do return {}, eval_err
				if !value_is_truthy(value) do continue
			}
			if !is_update {
				append(&chosen, row)
				continue
			}
			new_values := make([]Value, width, tx.alloc)
			copy(new_values, row.values)
			for assignment in assignments {
				index, _ := schema_column_index(&schema, assignment.column)
				value, eval_err := eval_expr(&ctx, assignment.value)
				if eval_err.kind != .None do return {}, eval_err
				new_values[index] = value
			}
			// An UPDATE's chosen row carries OLD and NEW side by side.
			pair := make([]Value, 2 * width, tx.alloc)
			copy(pair, row.values)
			copy(pair[width:], new_values)
			append(&chosen, Row{id = row.id, values = pair})
		}
		ctx.sources = nil
		for row in chosen {
			if !is_update {
				if err := trigger_fire(tx, name, .Delete, .Instead, row, Row{}, schema); err.kind != .None do return {}, err
				if err := returning_append(tx, &result, &returned, returning, view, row); err.kind != .None do return {}, err
				continue
			}
			old_row := Row{id = row.id, values = row.values[:width]}
			new_row := Row{id = row.id, values = row.values[width:]}
			saved_set := tx.update_set
			tx.update_set = assignment_columns(tx, assignments)
			fire_err := trigger_fire(tx, name, .Update, .Instead, old_row, new_row, schema)
			tx.update_set = saved_set
			if fire_err.kind != .None do return {}, fire_err
			if err := returning_append(tx, &result, &returned, returning, view, new_row); err.kind != .None do return {}, err
		}
	}
	tx.store.last_changes = 0
	if returning != nil {
		if prepare_err := returning_prepare(&result, returning, view); prepare_err.kind != .None do return {}, prepare_err
		result.rows = returned[:]
	} else {
		delete(returned)
	}
	return result, ERROR_NONE
}
