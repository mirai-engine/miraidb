package engine

import "core:strings"

// sqlite_sequence is SQLite's table of AUTOINCREMENT counters: one row per
// table that counts, holding the last rowid it handed out. A program reads it
// and writes it (`UPDATE sqlite_sequence SET seq = 0 WHERE name = 't'`, and
// Python's iterdump writes it back), so the engine answers it like a table:
// reading from the counters themselves, and writing a counter as SQLite uses
// one, the next rowid being one past the larger of the counter and the
// largest rowid. A write is kept in the internal table _sqlite_sequence, in
// the statement's transaction, and applied again when the log is replayed, so
// it survives a reopen.

SEQUENCE_TABLE :: "_sqlite_sequence"

@(private)
SEQUENCE_COLUMNS := []string{"name", "seq"}

// sqlite_sequence_exists reports whether the transaction sees a table that
// counts AUTOINCREMENT, which is when SQLite has created sqlite_sequence.
sqlite_sequence_exists :: proc(tx: ^Tx) -> bool {
	for name in tx_table_names(tx, context.temp_allocator) {
		table := tx_table_probe(tx, name)
		if table != nil && !strings.has_prefix(name, "_") && table.schema.auto_increment_column >= 0 do return true
	}
	return false
}

// sequence_next is the next AUTOINCREMENT value a table hands out in the
// transaction.
@(private)
sequence_next :: proc(tx: ^Tx, name: string, table: ^Table) -> i64 {
	if writes, staged := tx.state.writes[name]; staged do return writes.next_sequence
	return table.next_sequence
}

// tx_materialize_sqlite_sequence builds the table the statement reads.
tx_materialize_sqlite_sequence :: proc(tx: ^Tx, name: string) -> (^Table, Error) {
	text := Column_Type{kind = .Any}
	columns := make([]Column, 2, tx.alloc)
	columns[0] = Column{name = "name", type = text}
	columns[1] = Column{name = "seq", type = text}
	schema := Table_Schema{name = strings.clone(name, tx.alloc), columns = columns}
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	id := 1
	for table_name in tx_table_names(tx, context.temp_allocator) {
		counted := tx_table_probe(tx, table_name)
		if counted == nil || strings.has_prefix(table_name, "_") || counted.schema.auto_increment_column < 0 do continue
		next := sequence_next(tx, table_name, counted)
		seq := next - 1
		recorded, written := sequence_recorded(tx, table_name)
		if seq <= 0 && !written do continue
		// A deleted row stays away until the table hands out a value again.
		if written && recorded < 0 && next <= -recorded do continue
		values := []Value{value_string(counted.schema.name), value_int(max(seq, 0))}
		if insert_err := table_insert(table, Row_Id(id), values); insert_err.kind != .None {
			table_destroy(table)
			return nil, insert_err
		}
		id += 1
	}
	append(&tx.temp_tables, table)
	return table, ERROR_NONE
}

// sequence_recorded is what a program last wrote to a table's counter: the
// value, or for a deleted row minus the next value the table had then.
@(private)
sequence_recorded :: proc(tx: ^Tx, name: string) -> (i64, bool) {
	if tx_table_probe(tx, SEQUENCE_TABLE) == nil do return 0, false
	result, err := sql_execute_in_tx_params(tx, "SELECT seq FROM _sqlite_sequence WHERE name = ?", []Value{value_string(name)})
	if err.kind != .None {
		error_free(&err)
		return 0, false
	}
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 || result.rows[0][0].kind != .Int do return 0, false
	return result.rows[0][0].i, true
}

// sequence_largest is the largest value a table's AUTOINCREMENT column holds,
// its staged rows included.
@(private)
sequence_largest :: proc(tx: ^Tx, name: string, table: ^Table) -> i64 {
	column := table.schema.auto_increment_column
	largest := table_max_int(table, column)
	if writes, staged := tx.state.writes[name]; staged {
		for row in srows_ptrs(&writes.inserts) {
			if column < len(row.values) && row.values[column].kind == .Int do largest = max(largest, row.values[column].i)
		}
	}
	return largest
}

// sequence_set writes one counter: the next value becomes one past the larger
// of `seq` and the largest value the column holds.
@(private)
sequence_set :: proc(tx: ^Tx, name: string, seq: i64, deleted := false) -> Error {
	table := tx_table_probe(tx, name)
	if table == nil || table.schema.auto_increment_column < 0 do return ERROR_NONE
	writes := tx_writes(tx, name, table)
	writes.next_sequence = max(seq, sequence_largest(tx, name, table)) + 1
	// A deleted row is kept as minus the next value, so it shows again once
	// the table hands that value out.
	recorded := deleted ? -writes.next_sequence : seq
	// The write is data: logged, replayed, undone by a rollback.
	saved_last, saved_total := tx.store.last_changes, tx.store.total_changes
	defer tx.store.last_changes, tx.store.total_changes = saved_last, saved_total
	if tx_table_probe(tx, SEQUENCE_TABLE) == nil {
		created, create_err := sql_execute_in_tx(tx, "CREATE TABLE _sqlite_sequence (name TEXT PRIMARY KEY NOT NULL, seq INTEGER NOT NULL)")
		if create_err.kind != .None do return create_err
		sql_result_destroy(&created)
	}
	result, err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _sqlite_sequence (name, seq) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET seq = excluded.seq",
		[]Value{value_string(table.schema.name), value_int(recorded)},
	)
	if err.kind != .None do return err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// store_apply_sequence applies a counter a committed write recorded, on replay
// as at commit: the table hands out one past the larger of the counter and
// its largest value.
store_apply_sequence :: proc(store: ^Store, values: []Value) {
	if len(values) < 2 || values[0].kind != .String || values[1].kind != .Int do return
	table, found := store.tables[values[0].s]
	if !found || table.schema.auto_increment_column < 0 do return
	// A deleted row (a negative record) leaves the counter at the largest value.
	table.next_sequence = max(max(values[1].i, 0), table_max_int(table, table.schema.auto_increment_column)) + 1
}

// sqlite_sequence_write runs an INSERT, UPDATE or DELETE on sqlite_sequence.
sqlite_sequence_write :: proc(tx: ^Tx, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	view, view_err := tx_materialize_sqlite_sequence(tx, "sqlite_sequence")
	if view_err.kind != .None do return {}, view_err
	ctx := Eval_Ctx{tx = tx, params = params, now_us = now_microseconds()}
	affected := 0
	#partial switch s in statement {
	case Insert_Stmt:
		positions := [2]int{0, 1}
		if len(s.columns) > 0 {
			for column, i in s.columns {
				if i >= 2 do return {}, errf(.Invalid_Argument, "table sqlite_sequence has 2 columns")
				switch {
				case strings.equal_fold(column, "name"):
					positions[i] = 0
				case strings.equal_fold(column, "seq"):
					positions[i] = 1
				case:
					return {}, errf(.Column_Not_Found, "table sqlite_sequence has no column named %s", column)
				}
			}
		}
		rows := make([dynamic][]Value, 0, len(s.rows), tx.alloc)
		if s.has_select {
			query, query_err := sql_exec_select(tx, s.select_stmt, params)
			if query_err.kind != .None do return {}, query_err
			for row in query.rows do append(&rows, row)
		} else {
			for exprs in s.rows {
				row := make([]Value, len(exprs), tx.alloc)
				for expr, i in exprs {
					value, eval_err := eval_expr(&ctx, expr)
					if eval_err.kind != .None do return {}, eval_err
					row[i] = value
				}
				append(&rows, row)
			}
		}
		for row in rows {
			name, seq: Value
			for value, i in row {
				if i < 2 && positions[i] == 0 do name = value
				if i < 2 && positions[i] == 1 do seq = value
			}
			if name.kind != .String do continue
			number, _ := value_to_i64(seq)
			if err := sequence_set(tx, name.s, number); err.kind != .None do return {}, err
			affected += 1
		}
	case Update_Stmt, Delete_Stmt:
		where_clause: ^Expr
		assignments: []Assignment
		update, is_update := statement.(Update_Stmt)
		if is_update {
			where_clause, assignments = update.where_clause, update.assignments
		} else {
			where_clause = statement.(Delete_Stmt).where_clause
		}
		rows := make([dynamic]Row, 0, 8, tx.alloc)
		table_collect(view, &rows, max(u64), tx.alloc)
		for row in rows {
			sources := []Source{{table = view, row = row}}
			ctx.sources = sources
			if where_clause != nil {
				kept, eval_err := eval_expr(&ctx, where_clause)
				if eval_err.kind != .None do return {}, eval_err
				if !value_is_truthy(kept) do continue
			}
			seq := i64(0)
			if is_update {
				seq = row.values[1].kind == .Int ? row.values[1].i : 0
				for assignment in assignments {
					if !strings.equal_fold(assignment.column, "seq") do continue
					value, eval_err := eval_expr(&ctx, assignment.value)
					if eval_err.kind != .None do return {}, eval_err
					seq, _ = value_to_i64(value)
				}
			}
			if err := sequence_set(tx, row.values[0].s, seq, !is_update); err.kind != .None do return {}, err
			affected += 1
		}
	}
	tx.store.last_changes = i64(affected)
	tx.store.total_changes += i64(affected)
	return Sql_Result{kind = .Affected, affected = affected, commit_seq = tx.store.commit_seq}, ERROR_NONE
}
