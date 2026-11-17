package engine

import "core:fmt"
import "core:slice"
import "core:mem"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

import "base:intrinsics"

// --- Results ---------------------------------------------------------------

Sql_Result_Kind :: enum u8 {
	Rows,
	Affected,
	Ack,
}

Sql_Result :: struct {
	kind:       Sql_Result_Kind,
	columns:    []string,
	rows:       [][]Value,
	affected:   int,
	message:    string,
	commit_seq: u64,
	// row_bytes is the sum of the value sizes in `rows`: a hint for buffers and
	// quotas.
	row_bytes:  u64,
	// work prices the work the statement did: rows touched plus a fraction of
	// the payload. The store meters it and enforces a per-call budget.
	work:     u64,
	// row_ids parallels rows for a single-table projection: it identifies the
	// stored row each output row came from, which incremental consumers use.
	row_ids:    []Row_Id,
}

sql_result_destroy :: proc(result: ^Sql_Result) {
	for column in result.columns do delete(column)
	delete(result.columns)
	for row in result.rows do free_values(row)
	delete(result.rows)
	delete(result.row_ids)
	delete(result.message)
	result^ = {}
}

// sql_execute parses and runs one statement in its own transaction. SELECT runs
// in a read transaction; everything else in a write transaction that commits on
// success. BEGIN/COMMIT/ROLLBACK need a session and are rejected here.
// sql_execute runs one statement and feeds the query latency histogram. Every
// public entry point funnels through here, so the count matches the statements
// a host issued.
sql_execute :: proc(store: ^Store, sql: string) -> (Sql_Result, Error) {
	started := now_microseconds()
	result, err := sql_execute_params(store, sql, nil)
	store_record_query_latency(store, now_microseconds() - started)
	return result, err
}

// sql_execute_params runs one statement with positional bind parameters for its
// `?` placeholders. It prices the statement, accumulates the store's work
// total and enforces the per-call budget. The budget is a post-condition: a
// statement that overspends is refused rather than truncated.
sql_execute_params :: proc(store: ^Store, sql: string, params: []Value) -> (Sql_Result, Error) {
	result, exec_err := sql_execute_priced(store, sql, params)
	if exec_err.kind != .None do return {}, exec_err
	sync.lock(&store.mutex)
	result.work = statement_work(&result)
	store.work_used += result.work
	budget := store.max_work_per_call
	sync.unlock(&store.mutex)
	if budget > 0 && result.work > budget {
		// Read the spend before the destroy zeroes the result, or the message
		// reports 0 work for a statement that spent 3 (the CLI's --budget showed
		// it as soon as the cap was reachable).
		spent := result.work
		sql_result_destroy(&result)
		return {}, errf(.Quota_Exceeded, "statement spends %d work, budget is %d", spent, budget)
	}
	return result, ERROR_NONE
}

@(private)
sql_execute_priced :: proc(store: ^Store, sql: string, params: []Value) -> (Sql_Result, Error) {
	if body, is_pragma := sqlite_pragma_statement(sql); is_pragma {
		return sql_exec_pragma(store, body, false)
	}
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None do return {}, parse_err
	defer query_destroy(&query)
	return sql_run_statement(store, query.statement, params)
}

// sql_run_statement dispatches an already parsed statement; prepared statements
// reuse it to avoid parsing on every execution.
@(private)
sql_run_statement :: proc(store: ^Store, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	switch stmt in statement {
	case Select_Stmt, With_Stmt:
		tx := tx_begin_read(store)
		result, exec_err := sql_run_query(tx, stmt, params)
		tx_end(tx)
		result.commit_seq = store.commit_seq
		return result, exec_err
	case Insert_Stmt, Update_Stmt, Delete_Stmt, Merge_Stmt, Copy_Stmt, Create_Table_Stmt, Alter_Table_Stmt, Create_Type_Stmt, Drop_Table_Stmt, Create_Index_Stmt, Drop_Index_Stmt, Create_View_Stmt, Drop_View_Stmt, Create_Policy_Stmt, Drop_Policy_Stmt, Truncate_Stmt, Create_Trigger_Stmt, Drop_Trigger_Stmt, Grant_Stmt, Create_Virtual_Table_Stmt, Load_Extension_Stmt:
		tx := tx_begin_write(store)
		// OR FAIL undoes the failing row alone, which needs the statement journal
		// even here, where a plain failure simply discards the transaction.
		fail_mode := statement_fails_partially(stmt)
		mark := fail_mode ? tx_statement_begin(tx) : 0
		result, exec_err := sql_exec_mutation(tx, stmt, params)
		if fail_mode do tx_statement_end(tx, mark, false)
		if exec_err.kind != .None {
			if fail_mode {
				// The rows before the failing one stay, as SQLite keeps them.
				if commit_err := tx_commit(tx); commit_err.kind != .None {
					error_free(&exec_err)
					return {}, commit_err
				}
				return {}, exec_err
			}
			tx_rollback(tx)
			return {}, exec_err
		}
		if commit_err := tx_commit(tx); commit_err.kind != .None {
			return {}, commit_err
		}
		result.commit_seq = store.commit_seq
		return result, ERROR_NONE
	case Set_Stmt:
		return sql_exec_set(store, stmt, params)
	case Show_Stmt:
		return sql_exec_show(store, stmt)
	case Explain_Stmt:
		tx := tx_begin_read(store)
		result, explain_err := sql_exec_explain(tx, stmt, params)
		tx_end(tx)
		return result, explain_err
	case Describe_Stmt:
		tx := tx_begin_read(store)
		result, describe_err := sql_exec_describe(tx, stmt)
		tx_end(tx)
		return result, describe_err
	case Analyze_Stmt:
		return sql_exec_analyze(store, stmt)
	case Vacuum_Stmt:
		return sql_exec_vacuum(store, stmt)
	case Attach_Stmt:
		if !store.host_access do return {}, host_access_refusal("ATTACH")
		return sql_exec_attach(store, stmt)
	case Detach_Stmt:
		return sql_exec_detach(store, stmt)
	case Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
		return {}, errf(
			.Sql_Not_A_Query,
			"%s only makes sense in a session that keeps a transaction open",
			statement_name(stmt),
		)
	case Declare_Cursor_Stmt, Fetch_Stmt, Close_Cursor_Stmt:
		return {}, errf(
			.Sql_Not_A_Query,
			"%s belongs to a session: open a transaction, or use the wire protocol",
			statement_name(stmt),
		)
	case Listen_Stmt, Unlisten_Stmt, Notify_Stmt:
		// These belong to the database, not to a transaction: an embedded call
		// with no connection identity is the only listener it can have.
		tx := tx_begin_write(store)
		result, exec_err := sql_exec_mutation(tx, stmt, params)
		if exec_err.kind != .None {
			tx_rollback(tx)
			return {}, exec_err
		}
		if commit_err := tx_commit(tx); commit_err.kind != .None do return {}, commit_err
		result.commit_seq = store.commit_seq
		return result, ERROR_NONE
	}
	return {}, errf(.Sql_Unsupported, "unsupported statement")
}

// sql_execute_in_tx runs a data statement inside an existing transaction. It is
// what reducers use to mutate the database atomically.
sql_execute_in_tx :: proc(tx: ^Tx, sql: string) -> (Sql_Result, Error) {
	return sql_execute_in_tx_params(tx, sql, nil)
}

sql_execute_in_tx_params :: proc(tx: ^Tx, sql: string, params: []Value) -> (Sql_Result, Error) {
	if body, is_pragma := sqlite_pragma_statement(sql); is_pragma {
		return sql_exec_pragma(tx.store, body, tx.locked)
	}
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None do return {}, parse_err
	defer query_destroy(&query)
	result, exec_err := sql_run_statement_in_tx(tx, query.statement, params)
	if exec_err.kind != .None do return {}, exec_err
	// Price the statement inside the transaction too: the transaction owns the
	// store lock here, so this uses the same units without touching the mutex.
	result.work = statement_work(&result)
	if tx != nil do tx.work_units += result.work
	budget := tx.store.max_work_per_call
	if budget > 0 && result.work > budget {
		// Read the spend before the destroy zeroes the result, or the message
		// reports 0 work for a statement that spent 3 (the CLI's --budget showed
		// it as soon as the cap was reachable).
		spent := result.work
		sql_result_destroy(&result)
		return {}, errf(.Quota_Exceeded, "statement spends %d work, budget is %d", spent, budget)
	}
	return result, ERROR_NONE
}

// statement_fails_partially reports INSERT OR FAIL, the one resolution that
// keeps a statement's rows before the one that failed.
@(private)
statement_fails_partially :: proc(statement: Statement) -> bool {
	insert, ok := statement.(Insert_Stmt)
	return ok && insert.conflict_fail
}

// conflict_skippable reports the failures INSERT OR IGNORE and OR FAIL act on:
// the constraints a row breaks by itself, checked before anything is staged.
@(private)
conflict_skippable :: proc(kind: Error_Kind) -> bool {
	#partial switch kind {
	case .Duplicate_Primary_Key, .Duplicate_Unique, .Not_Null_Violation, .Check_Violation:
		return true
	}
	return false
}

// sql_run_statement_in_tx dispatches an already parsed statement inside a
// transaction.
@(private)
sql_run_statement_in_tx :: proc(tx: ^Tx, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	switch stmt in statement {
	case Select_Stmt, With_Stmt:
		return sql_run_query(tx, stmt, params)
	case Insert_Stmt, Update_Stmt, Delete_Stmt, Merge_Stmt, Copy_Stmt:
		if insert, is_insert := stmt.(Insert_Stmt); is_insert && insert.conflict_rollback {
			return {}, errf(
				.Sql_Unsupported,
				"INSERT OR ROLLBACK cannot end a transaction the caller opened: use OR ABORT and ROLLBACK",
			)
		}
		// A data statement that fails is taken back as a unit (SQLite's ABORT): the
		// transaction keeps the work of the statements before it and none of this
		// one's. OR FAIL keeps the rows before the failing one instead.
		mark := tx_statement_begin(tx)
		result, err := sql_exec_mutation(tx, stmt, params)
		tx_statement_end(tx, mark, err.kind != .None && !statement_fails_partially(stmt))
		return result, err
	case Create_Table_Stmt, Alter_Table_Stmt, Create_Type_Stmt, Drop_Table_Stmt, Create_Index_Stmt, Drop_Index_Stmt, Create_View_Stmt, Drop_View_Stmt, Create_Policy_Stmt, Drop_Policy_Stmt, Truncate_Stmt, Create_Trigger_Stmt, Drop_Trigger_Stmt, Grant_Stmt, Create_Virtual_Table_Stmt, Load_Extension_Stmt:
		return sql_exec_mutation(tx, stmt, params)
	case Listen_Stmt:
		store_listen(tx.store, tx.store.session_owner, stmt.channel)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Unlisten_Stmt:
		store_unlisten(tx.store, tx.store.session_owner, stmt.channel, stmt.all)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Notify_Stmt:
		store_notify(tx.store, tx.store.session_owner, stmt.channel, stmt.payload)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Declare_Cursor_Stmt:
		return sql_exec_declare_cursor(tx, stmt, params)
	case Fetch_Stmt:
		return sql_exec_fetch(tx, stmt)
	case Close_Cursor_Stmt:
		return sql_exec_close_cursor(tx, stmt)
	case Set_Stmt:
		return sql_exec_set(tx.store, stmt, params, tx.locked)
	case Show_Stmt:
		return sql_exec_show(tx.store, stmt, tx.locked)
	case Explain_Stmt:
		return sql_exec_explain(tx, stmt, params)
	case Describe_Stmt:
		return sql_exec_describe(tx, stmt)
	case Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
		return {}, errf(.Sql_Not_A_Query, "transaction control is not allowed inside a transaction")
	case Vacuum_Stmt:
		return {}, errf(.Sql_Not_A_Query, "VACUUM is not allowed inside a transaction")
	case Analyze_Stmt:
		return {}, errf(.Sql_Not_A_Query, "ANALYZE is not allowed inside a transaction")
	case Attach_Stmt, Detach_Stmt:
		return {}, errf(
			.Sql_Not_A_Query,
			"%s is not allowed inside a transaction",
			statement_name(statement),
		)
	}
	return {}, errf(.Sql_Unsupported, "unsupported statement")
}

// sql_exec_declare_cursor materializes the query and keeps it under its name for
// the rest of the transaction. The rows are the statement's answer at the moment
// it was declared, which is what a non-hold cursor is: the transaction sees one
// state anyway.
@(private)
sql_exec_declare_cursor :: proc(tx: ^Tx, stmt: Declare_Cursor_Stmt, params: []Value) -> (Sql_Result, Error) {
	if stmt.hold {
		return {}, errf(
			.Sql_Unsupported,
			"DECLARE ... WITH HOLD is not supported: a cursor here lives as long as its transaction",
		)
	}
	if _, exists := tx.cursors[stmt.name]; exists {
		return {}, errf(
			.Duplicate_Primary_Key,
			"cursor %s already exists in this transaction",
			stmt.name,
		)
	}
	result, exec_err := sql_exec_select(tx, stmt.query, params)
	if exec_err.kind != .None do return {}, exec_err
	cursor := new(Cursor, tx.alloc)
	cursor.columns = make([]string, len(result.columns), tx.alloc)
	for column, i in result.columns do cursor.columns[i] = strings.clone(column, tx.alloc)
	cursor.rows = make([][]Value, len(result.rows), tx.alloc)
	for row, i in result.rows {
		values := make([]Value, len(row), tx.alloc)
		for value, v in row do values[v] = value_clone(value, tx.alloc)
		cursor.rows[i] = values
	}
	tx.cursors[strings.clone(stmt.name, tx.alloc)] = cursor
	sql_result_destroy(&result)
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

// sql_exec_fetch hands out the rows a direction names and leaves the cursor after
// them. FETCH answers the rows; MOVE moves and answers only the count.
@(private)
sql_exec_fetch :: proc(tx: ^Tx, stmt: Fetch_Stmt) -> (Sql_Result, Error) {
	cursor, found := tx.cursors[stmt.name]
	if !found do return {}, errf(.Table_Not_Found, "cursor %s does not exist", stmt.name)
	total := len(cursor.rows)
	// start and count are the slice the direction names; position is where the
	// cursor sits afterwards, counted in rows handed out.
	start := 0
	count := 0
	position := cursor.position
	switch stmt.direction {
	case .Next:
		start = position
		count = 1
		position = min(position + 1, total)
	case .Prior:
		start = max(position - 1, 0) - 1
		if position <= 0 {
			start = 0
			count = 0
			position = 0
		} else {
			start = position - 1
			count = 1
			position = position - 1
		}
	case .First:
		start = 0
		count = total > 0 ? 1 : 0
		position = count
	case .Last:
		start = max(total - 1, 0)
		count = total > 0 ? 1 : 0
		position = total
	case .Absolute:
		target := stmt.count > 0 ? stmt.count - 1 : total + stmt.count
		if target < 0 || target >= total {
			position = target < 0 ? 0 : total
			count = 0
		} else {
			start = target
			count = 1
			position = target + 1
		}
	case .Relative:
		target := stmt.count > 0 ? position + stmt.count - 1 : position - 1 + stmt.count
		if target < 0 || target >= total {
			position = target < 0 ? 0 : total
			count = 0
		} else {
			start = target
			count = 1
			position = target + 1
		}
	case .Forward:
		start = min(position, total)
		wanted := stmt.count == 0 ? total - start : stmt.count
		count = clamp(wanted, 0, total - start)
		position = start + count
	case .Backward:
		end := min(position, total)
		wanted := stmt.count == 0 ? end : stmt.count
		count = clamp(wanted, 0, end)
		start = end - count
		position = start
	case .All:
		start = min(position, total)
		count = total - start
		position = total
	}
	cursor.position = position
	result := Sql_Result {
		kind       = .Rows,
		affected   = count,
		commit_seq = tx.store.commit_seq,
	}
	if !stmt.move {
		result.columns = make([]string, len(cursor.columns))
		for column, i in cursor.columns do result.columns[i] = strings.clone(column)
		result.rows = make([][]Value, count)
		for row, i in cursor.rows[start:][:count] {
			values := make([]Value, len(row))
			for value, v in row do values[v] = value_clone(value, context.allocator)
			result.rows[i] = values
		}
	}
	return result, ERROR_NONE
}

@(private)
sql_exec_close_cursor :: proc(tx: ^Tx, stmt: Close_Cursor_Stmt) -> (Sql_Result, Error) {
	if stmt.all {
		// CLOSE ALL drops every cursor of the transaction. The rows live in its
		// arena, so the map is all there is to drop.
		clear(&tx.cursors)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	if _, found := tx.cursors[stmt.name]; !found {
		return {}, errf(.Table_Not_Found, "cursor %s does not exist", stmt.name)
	}
	map_erase(&tx.cursors, stmt.name)
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

// sql_exec_copy moves rows between a table and the text or CSV form. A file is
// read or written here; STDIN and STDOUT belong to a client, so the wire front
// end answers those before the statement gets this far (only the standalone CLI
// lands in the STDOUT branch, which hands the text back for printing).
@(private)
sql_exec_copy :: proc(tx: ^Tx, stmt: Copy_Stmt) -> (Sql_Result, Error) {
	if stmt.from && stmt.target == .Stdin {
		return {}, errf(
			.Sql_Unsupported,
			"COPY ... FROM STDIN needs a client that speaks the wire protocol; COPY ... FROM 'file' works here",
		)
	}
	if !stmt.from && stmt.target == .Stdout {
		text, count, text_err := copy_rows_to_text(tx, stmt, context.allocator)
		if text_err.kind != .None do return {}, text_err
		return Sql_Result {
				kind = .Ack,
				message = text,
				affected = count,
				commit_seq = tx.store.commit_seq,
			},
			ERROR_NONE
	}
	if !tx.store.host_access do return {}, host_access_refusal("COPY")
	if stmt.from {
		count, copy_err := copy_file_insert(tx, stmt)
		if copy_err.kind != .None do return {}, copy_err
		return Sql_Result {
				kind = .Affected,
				affected = count,
				commit_seq = tx.store.commit_seq,
			},
			ERROR_NONE
	}
	count, copy_err := copy_file_write(tx, stmt)
	if copy_err.kind != .None do return {}, copy_err
	return Sql_Result {
			kind = .Affected,
			affected = count,
			commit_seq = tx.store.commit_seq,
		},
		ERROR_NONE
}

// sql_exec_vacuum compacts the live log, or writes a compacted copy.
@(private)
sql_exec_vacuum :: proc(store: ^Store, stmt: Vacuum_Stmt) -> (Sql_Result, Error) {
	if len(stmt.path) != 0 && !store.host_access {
		return {}, host_access_refusal("VACUUM INTO")
	}
	if len(stmt.path) == 0 {
		if compact_err := store_compact(store); compact_err.kind != .None {
			return {}, compact_err
		}
		return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
	}
	if write_err := store_vacuum_into(store, stmt.path); write_err.kind != .None {
		return {}, write_err
	}
	return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
}

sql_exec_mutation :: proc(tx: ^Tx, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	switch stmt in statement {
	case Declare_Cursor_Stmt, Fetch_Stmt, Close_Cursor_Stmt:
		// A cursor needs the transaction object, which the caller of this switch
		// already has: the in-transaction dispatch answers these.
		return {}, errf(.Internal, "%s is answered by the transaction", statement_name(stmt))
	case Listen_Stmt:
		store_listen(tx.store, tx.store.session_owner, stmt.channel)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Unlisten_Stmt:
		store_unlisten(tx.store, tx.store.session_owner, stmt.channel, stmt.all)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Notify_Stmt:
		store_notify(tx.store, tx.store.session_owner, stmt.channel, stmt.payload)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Analyze_Stmt:
		// ANALYZE needs the tables, not the transaction: it belongs to the store.
		return {}, errf(.Sql_Not_A_Query, "ANALYZE does not run inside a transaction")
	case Load_Extension_Stmt:
		if !stmt.unload && !tx.store.host_access {
			return {}, host_access_refusal("LOAD EXTENSION")
		}
		if stmt.unload {
			if unload_err := extension_unload(tx, stmt.name, stmt.if_exists); unload_err.kind != .None {
				return {}, unload_err
			}
		} else {
			if load_err := extension_load(tx, stmt.name, stmt.address, stmt.reducers); load_err.kind != .None {
				return {}, load_err
			}
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Insert_Stmt:
		return sql_exec_insert(tx, stmt, params)
	case Copy_Stmt:
		return sql_exec_copy(tx, stmt)
	case Update_Stmt:
		return sql_exec_update(tx, stmt, params)
	case Delete_Stmt:
		return sql_exec_delete(tx, stmt, params)
	case Merge_Stmt:
		return sql_exec_merge(tx, stmt, params)
	case Create_Table_Stmt:
		return sql_exec_create_table(tx, stmt, params)
	case Alter_Table_Stmt:
		return sql_exec_alter_table(tx, stmt)
	case Create_Type_Stmt:
		return sql_exec_create_type(tx, stmt)
	case Drop_Table_Stmt:
		return sql_exec_drop_table(tx, stmt)
	case Create_Index_Stmt:
		return sql_exec_create_index(tx, stmt)
	case Drop_Index_Stmt:
		return sql_exec_drop_index(tx, stmt)
	case Create_View_Stmt:
		return sql_exec_create_view(tx, stmt)
	case Drop_View_Stmt:
		return sql_exec_drop_view(tx, stmt)
	case Create_Policy_Stmt:
		return sql_exec_create_policy(tx, stmt)
	case Drop_Policy_Stmt:
		return sql_exec_drop_policy(tx, stmt)
	case Truncate_Stmt:
		if truncate_err := tx_truncate(tx, stmt.name); truncate_err.kind != .None {
			return {}, truncate_err
		}
		return Sql_Result{kind = .Affected, affected = 1, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Create_Trigger_Stmt:
		if trigger_err := trigger_create(tx, stmt); trigger_err.kind != .None {
			return {}, trigger_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Drop_Trigger_Stmt:
		if trigger_err := trigger_drop(tx, stmt.name, stmt.if_exists); trigger_err.kind != .None {
			return {}, trigger_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Grant_Stmt:
		return sql_exec_grant(tx, stmt)
	case Create_Virtual_Table_Stmt:
		if stmt.if_not_exists {
			if _, found := fts_virtual_lookup(tx, stmt.name); found {
				return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
			}
		}
		if fts_err := fts_create(tx, stmt.name, stmt.module, stmt.columns); fts_err.kind != .None {
			return {}, fts_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Select_Stmt, With_Stmt, Set_Stmt, Show_Stmt, Explain_Stmt, Describe_Stmt, Vacuum_Stmt, Attach_Stmt, Detach_Stmt, Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
	}
	return {}, errf(.Sql_Unsupported, "statement does not modify data")
}


// --- Prepared statements ---------------------------------------------------

// Prepared keeps the parsed statement so repeated executions do not parse
// again. It is immutable after `sql_prepare` and safe to reuse with new params.
Stmt_Prepared :: struct {
	query:       Query,
	is_pragma:   bool,
	pragma_body: string,
	// param_count is how many positional parameters the statement binds, so a
	// caller can refuse an index before it becomes a silent growth (D29).
	param_count: int,
}

sql_prepare :: proc(store: ^Store, sql: string) -> (^Stmt_Prepared, Error) {
	prepared := new(Stmt_Prepared)
	if body, is_pragma := sqlite_pragma_statement(sql); is_pragma {
		prepared.is_pragma = true
		prepared.pragma_body = strings.clone(body)
		return prepared, ERROR_NONE
	}
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None {
		free(prepared)
		return nil, parse_err
	}
	prepared.query = query
	prepared.param_count = query.param_count
	return prepared, ERROR_NONE
}

stmt_prepared_destroy :: proc(prepared: ^Stmt_Prepared) {
	if prepared == nil do return
	if prepared.is_pragma {
		delete(prepared.pragma_body)
	} else {
		query_destroy(&prepared.query)
	}
	free(prepared)
}

@(private)
sql_price :: proc(store: ^Store, result: ^Sql_Result) -> Error {
	sync.lock(&store.mutex)
	result.work = statement_work(result)
	store.work_used += result.work
	budget := store.max_work_per_call
	sync.unlock(&store.mutex)
	if budget > 0 && result.work > budget {
		sql_result_destroy(result)
		return errf(.Quota_Exceeded, "statement spends %d work, budget is %d", result.work, budget)
	}
	return ERROR_NONE
}

// prepared_execute runs a prepared statement against the store, pricing it like
// sql_execute does.
prepared_execute :: proc(store: ^Store, prepared: ^Stmt_Prepared, params: []Value) -> (Sql_Result, Error) {
	if prepared == nil do return {}, errf(.Invalid_Argument, "no prepared statement")
	if prepared.is_pragma do return sql_exec_pragma(store, prepared.pragma_body, false)
	result, exec_err := sql_run_statement(store, prepared.query.statement, params)
	if exec_err.kind != .None do return {}, exec_err
	if price_err := sql_price(store, &result); price_err.kind != .None do return {}, price_err
	return result, ERROR_NONE
}

// prepared_execute_in_tx runs a prepared statement inside an existing
// transaction (the path benchmarks and reducers use).
prepared_execute_in_tx :: proc(tx: ^Tx, prepared: ^Stmt_Prepared, params: []Value) -> (Sql_Result, Error) {
	if prepared == nil do return {}, errf(.Invalid_Argument, "no prepared statement")
	if prepared.is_pragma do return sql_exec_pragma(tx.store, prepared.pragma_body, tx.locked)
	return sql_run_statement_in_tx(tx, prepared.query.statement, params)
}

// --- DESCRIBE --------------------------------------------------------------

// sql_exec_describe lists one table's columns and indexes as rows, so clients and
// the CLI can inspect the catalog without reading internal structures.
sql_exec_describe :: proc(tx: ^Tx, stmt: Describe_Stmt) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.name)
	if table_err.kind != .None do return {}, table_err
	result := Sql_Result{kind = .Rows, commit_seq = tx.store.commit_seq}
	result.columns = make([]string, 6)
	result.columns[0] = result_own("kind")
	result.columns[1] = result_own("name")
	result.columns[2] = result_own("type")
	result.columns[3] = result_own("not_null")
	result.columns[4] = result_own("unique")
	result.columns[5] = result_own("default")
	rows := make([dynamic][]Value)
	for column in table.schema.columns {
		row := make([]Value, 6)
		row[0] = value_string(result_own("column"))
		row[1] = value_string(strings.clone(column.name))
		row[2] = value_string(strings.clone(column_type_name(column.type)))
		row[3] = value_bool(column.not_null)
		row[4] = value_bool(column.unique)
		if column.has_default {
			row[5] = value_string(strings.clone(value_format(column.default_value, context.temp_allocator)))
		} else {
			row[5] = value_null()
		}
		append(&rows, row)
	}
	for index in table.schema.indexes {
		names := strings.builder_make()
		defer strings.builder_destroy(&names)
		for position, i in index.columns {
			if i > 0 do strings.write_string(&names, ", ")
			if position >= 0 && position < len(table.schema.columns) {
				strings.write_string(&names, table.schema.columns[position].name)
			}
		}
		row := make([]Value, 6)
		row[0] = value_string(result_own("index"))
		row[1] = value_string(strings.clone(index.name))
		row[2] = value_string(strings.clone(strings.to_string(names)))
		row[3] = value_bool(false)
		row[4] = value_bool(index.unique)
		row[5] = value_null()
		append(&rows, row)
	}
	result.rows = make([][]Value, len(rows))
	copy(result.rows, rows[:])
	delete(rows)
	return result, ERROR_NONE
}

// --- SET, SHOW and EXPLAIN -------------------------------------------------

sql_exec_set :: proc(store: ^Store, stmt: Set_Stmt, params: []Value, locked := false) -> (Sql_Result, Error) {
	// SET writes the session variable map, so it takes the exclusive lock and
	// uses the unlocked store helpers (the lock is not re-entrant).
	if !locked {
		sync.lock(&store.mutex)
		defer sync.unlock(&store.mutex)
	}
	value, eval_err := eval_expr(
		&Eval_Ctx{params = params, now_us = now_microseconds()},
		stmt.value,
	)
	if eval_err.kind != .None do return {}, eval_err
	if strings.equal_fold(stmt.name, "identity") {
		coerced, coerce_err := value_coerce(value, Column_Type{kind = .Identity})
		if coerce_err.kind != .None {
			return {}, errf(.Invalid_Type, "SET identity needs a 32-byte hex string")
		}
		store_set_identity(store, value_identity_of(coerced))
		return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
	}
	if set_err := store_set_variable_locked(store, stmt.name, value); set_err.kind != .None {
		return {}, set_err
	}
	return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
}

sql_exec_show :: proc(store: ^Store, stmt: Show_Stmt, locked := false) -> (Sql_Result, Error) {
	if !locked {
		sync.shared_lock(&store.mutex)
		defer sync.shared_unlock(&store.mutex)
	}
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = make([]string, 2)
	result.columns[0] = result_own("name")
	result.columns[1] = result_own("value")
	rows := make([dynamic][]Value)
	if len(stmt.name) > 0 && strings.equal_fold(stmt.name, "tables") {
		names := store_table_names(store, context.allocator)
		defer delete(names)
		rows_out := make([dynamic][]Value)
		for name in names {
			if strings.has_prefix(name, "_") do continue
			row := make([]Value, 1)
			row[0] = value_string(strings.clone(name))
			append(&rows_out, row)
		}
		result.columns[0] = result_own("table")
		delete(result.columns[1])
		result.columns = result.columns[:1]
		result.rows = make([][]Value, len(rows_out))
		copy(result.rows, rows_out[:])
		delete(rows_out)
		return result, ERROR_NONE
	}
	if len(stmt.name) > 0 && strings.equal_fold(stmt.name, "types") {
		sql_result_destroy(&result)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		if _, exists := store.tables[TYPE_TABLE]; !exists {
			out.columns = []string{result_own("name"), result_own("base")}
			return out, ERROR_NONE
		}
		catalog := store.tables[TYPE_TABLE]
		entries := make([dynamic]Row)
		defer delete(entries)
		table_collect(catalog, &entries, max(u64))
		slice.sort_by(entries[:], proc(a, b: Row) -> bool {
			return strings.compare(a.values[0].s, b.values[0].s) < 0
		})
		out.columns = []string{result_own("name"), result_own("base")}
		out.rows = make([][]Value, len(entries))
		for entry, i in entries {
			row := make([]Value, 2)
			row[0] = value_string(strings.clone(entry.values[0].s))
			row[1] = value_string(strings.clone(entry.values[1].s))
			out.rows[i] = row
		}
		return out, ERROR_NONE
	}
	if len(stmt.name) > 0 && strings.equal_fold(stmt.name, "events") {
		sql_result_destroy(&result)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		out.columns = []string{result_own("table")}
		names := event_tables(store, context.allocator)
		rows_out := make([][]Value, len(names))
		for name, i in names {
			row := make([]Value, 1)
			row[0] = value_string(strings.clone(name))
			rows_out[i] = row
		}
		out.rows = rows_out
		return out, ERROR_NONE
	}
	if len(stmt.name) > 0 && strings.equal_fold(stmt.name, "indexes") {
		sql_result_destroy(&result)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		out.columns = []string{result_own("table"), result_own("index"), result_own("columns")}
		rows_out := make([dynamic][]Value)
		names := store_table_names(store, context.allocator)
		defer delete(names)
		for table_name in names {
			table, exists := store.tables[table_name]
			if !exists || strings.has_prefix(table_name, "_") do continue
			for idx in table.schema.indexes {
				row := make([]Value, 3)
				row[0] = value_string(strings.clone(table_name))
				row[1] = value_string(strings.clone(idx.name))
				column_list := ""
				for col, i in idx.columns {
					if i > 0 do column_list = strings.concatenate({column_list, ", "})
					column_list = strings.concatenate({column_list, table.schema.columns[col].name})
				}
				row[2] = value_string(column_list)
				append(&rows_out, row)
			}
		}
		out.rows = make([][]Value, len(rows_out))
		copy(out.rows, rows_out[:])
		delete(rows_out)
		return out, ERROR_NONE
	}
	if len(stmt.name) > 0 {
		if strings.equal_fold(stmt.name, "identity") {
			row := make([]Value, 2)
			row[0] = value_string(result_own("identity"))
			row[1] = value_identity(store_identity(store))
			append(&rows, row)
			result.rows = make([][]Value, len(rows))
			copy(result.rows, rows[:])
			delete(rows)
			return result, ERROR_NONE
		}
		value, found := store_get_variable_locked(store, stmt.name)
		if !found {
			sql_result_destroy(&result)
			return {}, errf(.Invalid_Argument, "variable %s is not set", stmt.name)
		}
		row := make([]Value, 2)
		row[0] = value_string(strings.clone(stmt.name))
		row[1] = value
		append(&rows, row)
	} else {
		names := store_variable_names_locked(store, context.allocator)
		defer delete(names)
		for name in names {
			if value, found := store_get_variable_locked(store, name); found {
				row := make([]Value, 2)
				row[0] = value_string(strings.clone(name))
				row[1] = value
				append(&rows, row)
			}
		}
	}
	result.rows = make([][]Value, len(rows))
	copy(result.rows, rows[:])
	delete(rows)
	return result, ERROR_NONE
}

sql_exec_explain :: proc(tx: ^Tx, stmt: Explain_Stmt, params: []Value) -> (Sql_Result, Error) {
	store := tx.store
	if stmt.inner == nil do return {}, errf(.Invalid_Argument, "EXPLAIN needs a statement")
	lines := make([dynamic]string)
	defer delete(lines)
	switch inner in stmt.inner^ {
	case Copy_Stmt:
		return {}, errf(.Sql_Not_A_Query, "EXPLAIN does not apply to COPY")
	case Merge_Stmt:
		return {}, errf(.Sql_Not_A_Query, "EXPLAIN does not apply to MERGE")
	case Declare_Cursor_Stmt, Fetch_Stmt, Close_Cursor_Stmt:
		return {}, errf(.Sql_Not_A_Query, "EXPLAIN does not apply to a cursor statement")
	case Listen_Stmt, Unlisten_Stmt, Notify_Stmt:
		return {}, errf(.Sql_Not_A_Query, "EXPLAIN does not apply to LISTEN or NOTIFY")
	case Select_Stmt:
		order := plan_join_order(store, tx, inner, params)
		first := order.steps[0]
		// Asking whether the FROM names a table is a bool question: the probe answers
		// it without building the error message that says it does not.
		base_table := tx_table_probe(tx, order.from.name)
		if base_table != nil {
			// explain_access builds a fragment and the line copies it, so the fragment
			// is freed here: EXPLAIN used to leave one behind per statement.
			suffix := explain_access(store, base_table, order.from, inner.where_clause, params)
			append(&lines, fmt.aprintf("scan %s%s", first.name, suffix))
			delete(suffix)
		} else if _, is_view := view_sql(tx, order.from.name); is_view {
			// The number is the view's own FROM: it has no rows to measure yet.
			append(&lines, fmt.aprintf(
				"scan %s (a view; est. %d rows from the relation it reads)",
				first.name,
				first.rows,
			))
		} else {
			append(&lines, strings.concatenate({"scan ", first.name}))
		}
		for step in order.steps[1:] {
			// A RIGHT or FULL join scans the inner side even when an index could
			// answer the ON clause: it has to know which inner rows matched at
			// all, and a probe only ever sees the ones that did.
			if step.kind == .Right || step.kind == .Full {
				append(&lines, fmt.aprintf("join %s (nested loop, full scan, est. %d rows)", step.name, step.rows))
				continue
			}
			if inner_table, inner_err := store_table(store, step.ref.name); inner_err.kind == .None {
				probe, probed := join_index_probe(inner_table, step.ref.alias, step.predicate)
				if probed {
					append(&lines, fmt.aprintf(
						"join %s using index %s (nested loop, est. %d rows)",
						step.name,
						inner_table.indexes[probe.index].schema.name,
						step.rows,
					))
					continue
				}
			}
			append(&lines, fmt.aprintf("join %s (nested loop, est. %d rows)", step.name, step.rows))
		}
		if order.reordered {
			names := make([dynamic]string, 0, len(order.steps))
			defer delete(names)
			for step in order.steps do append(&names, step.name)
			append(&lines, fmt.aprintf("join order: %s", strings.join(names[:], ", ")))
		}
		if inner.where_clause != nil do append(&lines, result_own("filter"))
		if len(inner.group_by) > 0 do append(&lines, result_own("group by"))
		if inner.having != nil do append(&lines, result_own("having"))
		if len(inner.order_by) > 0 {
			ordered := false
			if ordered_table := tx_table_probe(tx, order.from.name); ordered_table != nil {
				if index, _, ordered_ok := index_order_for(tx, ordered_table, order.from, inner); ordered_ok {
					append(&lines, fmt.aprintf(
						"order by (index %s)",
						ordered_table.indexes[index].schema.name,
					))
					ordered = true
				}
			}
			if !ordered do append(&lines, result_own("order by (sort)"))
		}
		if inner.limit != nil || inner.offset != nil do append(&lines, result_own("limit/offset"))
	case Update_Stmt:
		suffix := explain_index_suffix(store, Table_Ref{name = inner.table}, inner.where_clause, params)
		append(&lines, strings.concatenate({"update ", inner.table, suffix}))
		// The suffix is a built fragment, and the line it went into copied it: free it
		// here (an absent table answers the empty literal, which nothing owns).
		if len(suffix) > 0 do delete(suffix)
	case Delete_Stmt:
		suffix := explain_index_suffix(store, Table_Ref{name = inner.table}, inner.where_clause, params)
		append(&lines, strings.concatenate({"delete ", inner.table, suffix}))
		if len(suffix) > 0 do delete(suffix)
	case Insert_Stmt:
		append(&lines, strings.concatenate({"insert into ", inner.table}))
	case Create_Table_Stmt:
		append(&lines, strings.concatenate({"create table ", inner.name}))
	case Alter_Table_Stmt:
		append(&lines, strings.concatenate({"alter table ", inner.table}))
	case Create_Type_Stmt:
		append(&lines, strings.concatenate({"create type ", inner.name}))
	case Drop_Table_Stmt:
		append(&lines, strings.concatenate({"drop table ", inner.name}))
	case Create_Index_Stmt:
		append(&lines, strings.concatenate({"create index ", inner.name, " on ", inner.table}))
	case Drop_Index_Stmt:
		append(&lines, strings.concatenate({"drop index ", inner.name}))
	case Set_Stmt:
		append(&lines, strings.concatenate({"set ", inner.name}))
	case Show_Stmt:
		append(&lines, strings.concatenate({"show ", inner.name}))
	case Create_View_Stmt:
		append(&lines, strings.concatenate({"create view ", inner.name}))
	case Drop_View_Stmt:
		append(&lines, strings.concatenate({"drop view ", inner.name}))
	case Create_Policy_Stmt:
		append(&lines, strings.concatenate({"create policy ", inner.name, " on ", inner.table}))
	case Drop_Policy_Stmt:
		append(&lines, strings.concatenate({"drop policy ", inner.name}))
	case Describe_Stmt:
		append(&lines, strings.concatenate({"describe ", inner.name}))
	case Truncate_Stmt:
		append(&lines, strings.concatenate({"truncate ", inner.name}))
	case Vacuum_Stmt:
		append(&lines, result_own(len(inner.path) > 0 ? "write a compacted copy" : "compact the log"))
	case Analyze_Stmt:
		append(&lines, result_own(len(inner.table) > 0 ? "analyze one table" : "analyze every table"))
	case Create_Trigger_Stmt:
		append(&lines, strings.concatenate({"create trigger ", inner.name, " on ", inner.table}))
	case Drop_Trigger_Stmt:
		append(&lines, strings.concatenate({"drop trigger ", inner.name}))
	case Grant_Stmt:
		append(&lines, result_own(inner.revoke ? "revoke" : "grant"))
	case Create_Virtual_Table_Stmt:
		append(&lines, strings.concatenate({"create virtual table ", inner.name, " using ", inner.module}))
	case Load_Extension_Stmt:
		append(&lines, strings.concatenate({inner.unload ? "unload extension " : "load extension ", inner.name}))
	case Attach_Stmt:
		append(&lines, strings.concatenate({"attach ", inner.path, " as ", inner.name}))
	case Detach_Stmt:
		append(&lines, strings.concatenate({"detach ", inner.name}))
	case Explain_Stmt, With_Stmt, Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
		append(&lines, result_own("no plan"))
	}
	if note := explain_staleness(store); len(note) > 0 do append(&lines, note)
	result := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
	result.columns = make([]string, 1)
	result.columns[0] = result_own("plan")
	rows := make([][]Value, len(lines))
	for line, i in lines {
		rows[i] = make([]Value, 1)
		rows[i][0] = value_string(line)
	}
	result.rows = rows
	return result, ERROR_NONE
}

// sql_exec_analyze measures the statistics a plan reads, under the write lock so
// ANALYZE is not interleaved with a commit, and answers with the number of tables
// it measured.
@(private)
sql_exec_analyze :: proc(store: ^Store, stmt: Analyze_Stmt) -> (Sql_Result, Error) {
	measured, analyze_err := stats_analyze(store, stmt.table)
	if analyze_err.kind != .None do return {}, analyze_err
	result := Sql_Result{kind = .Ack, commit_seq = store.commit_seq}
	result.affected = measured
	result.message = fmt.aprintf("analyzed %d table(s)", measured)
	return result, ERROR_NONE
}

// result_own makes a string the result owns. A cell or a column name is handed to
// the caller, and the caller frees it, so it cannot be a literal: `strings.clone`
// hands a constant back unchanged when it lives in read-only memory, and freeing
// that is a bad free. This always allocates.
@(private)
result_own :: proc(text: string) -> string {
	out := make([]u8, len(text), context.allocator)
	copy(out, text)
	return string(out)
}

// explain_staleness names the gap between the numbers the planner used and the
// data it plans against. A plan built on an old measurement is still the best
// guess available, but the reader is told it is a guess: without the note an
// estimate looks like a fact.
@(private)
explain_staleness :: proc(store: ^Store) -> string {
	if store.stats_seq == 0 {
		return result_own("note: no statistics measured; run ANALYZE to price this plan")
	}
	if store.stats_seq < store.commit_seq {
		return fmt.aprintf(
			"note: statistics measured at commit %d, data at commit %d",
			store.stats_seq,
			store.commit_seq,
		)
	}
	return ""
}

// explain_access prints the same choice the executor makes, with the estimate and
// the cost it made it with.
@(private)
explain_access :: proc(
	store: ^Store,
	table: ^Table,
	ref: Table_Ref,
	predicate: ^Expr,
	params: []Value,
) -> string {
	access := plan_access(store, table, ref, predicate, params)
	if access.kind == .Index && access.index >= 0 && access.index < len(table.indexes) {
		return fmt.aprintf(
			" using index %s (est. %d rows, cost %.1f)",
			table.indexes[access.index].schema.name,
			access.rows,
			access.cost,
		)
	}
	return fmt.aprintf(" (full scan, est. %d rows, cost %.1f)", access.rows, access.cost)
}

@(private)
explain_index_suffix :: proc(store: ^Store, ref: Table_Ref, predicate: ^Expr, params: []Value) -> string {
	table, found := store.tables[ref.name]
	if !found do return ""
	return explain_access(store, table, ref, predicate, params)
}

@(private)
comparison_details :: proc(expr: ^Expr) -> (qualifier: string, column: string, op: Binary_Op, ok: bool) {
	if binary, is_binary := expr^.(Binary_Expr); is_binary {
		#partial switch binary.op {
		case .Eq, .Lt, .Le, .Gt, .Ge:
			side_qualifier, side_column, _, _, sides_ok := comparison_sides(binary)
			return side_qualifier, side_column, binary.op, sides_ok
		}
	}
	if between, is_between := expr^.(Between_Expr); is_between && !between.negated {
		if column_ref, is_column := between.operand^.(Column_Expr); is_column {
			return column_ref.table, column_ref.name, .Ge, true
		}
	}
	return "", "", .Eq, false
}

// --- SELECT ----------------------------------------------------------------

Source :: struct {
	table: ^Table,
	row:   Row,
	alias: string,
	// hidden_unqualified sources only answer qualified references. UPSERT uses
	// it for `excluded`, so a bare column still means the stored row.
	hidden_unqualified: bool,
}

// quota_reached reports whether `produced` rows are already past the store's row
// quota. It is checked where rows are produced, not when the result is finished,
// because a quota read after the fact cannot prevent the spike it exists to cap.
@(private)
quota_reached :: proc(tx: ^Tx, produced: int) -> bool {
	if tx == nil do return false
	quota := tx.store.max_rows_per_query
	return quota > 0 && u64(produced) > quota
}

// select_output_may_shrink reports whether the projection can emit fewer rows
// than the rows it reads: DISTINCT, GROUP BY/HAVING, an aggregate and a window
// all decide rows after the join. When none of them is present every kept row is
// an output row, so the row quota may fire while the join is still building,
// which is where the memory spike is (D23).
select_output_may_shrink :: proc(stmt: Select_Stmt) -> bool {
	if stmt.is_distinct || len(stmt.group_by) > 0 || stmt.having != nil do return true
	for item in stmt.projections {
		if item.star || item.expr == nil do continue
		if expr_is_aggregate(item.expr) do return true
		// Anywhere, not only at the top: `sum(v) OVER () + 1` needs every row just
		// as `sum(v) OVER ()` does, and a pushed-down LIMIT would stop the scan and
		// let the window answer from the rows it was allowed to read.
		if expr_has_window(item.expr) do return true
	}
	return false
}

// Outer_Frame is one level of a query written inside another: the sources of the
// statement the subquery belongs to. A correlated subquery, and a LATERAL
// subquery, read a column there when its own sources do not have it.
Outer_Frame :: struct {
	sources: []Source,
	next:    ^Outer_Frame,
}

Eval_Ctx :: struct {
	// order_err is the first error an ORDER BY expression raised while the sort
	// keys were built; the statement returns it instead of sorting.
	order_err: Error,
	tx:      ^Tx,
	sources: []Source,
	group:   [][]Source,
	grouped: bool,
	// grouping_missing marks the GROUP BY entries the current grouping set left
	// out, in the order of `group_by`, and grouping_exprs are those entries. A
	// projection column that is one of them reads NULL, and GROUPING() answers the
	// mask; both are empty outside a grouped row.
	grouping_missing: []bool,
	grouping_exprs:   []^Expr,
	params:  []Value,
	now_us:  i64,
	// stream is set only while a streaming scan evaluates its final projection:
	// an aggregate then answers from its running accumulator instead of walking
	// a materialized group.
	stream: ^Agg_Stream,
	// window_values and window_slots are set while a projection that contains a
	// window is evaluated after the windows were filled: the node maps to the slot
	// that holds its answer, so `sum(n) OVER () + 1` reads the answer instead of
	// refusing. Both are nil everywhere else.
	window_values: []Value,
	window_slots:  map[^Expr]int,
	// outer is the stack of frames the query is written inside, innermost first.
	outer: ^Outer_Frame,
	// depth is how deep the evaluation is. The parser refuses a tree deeper than
	// MAX_EXPRESSION_DEPTH, so this only fires for a tree that arrived another way
	// (a stored view, a generated column, a policy); it is here so the failure is
	// an error instead of an overflow.
	depth:  int,
}

// rowid_alias_name reports SQLite's three spellings of a rowid, none of which is
// a column of the table unless the schema says so.
@(private)
rowid_alias_name :: proc(name: string) -> bool {
	return strings.equal_fold(name, "rowid") ||
		strings.equal_fold(name, "_rowid_") ||
		strings.equal_fold(name, "oid")
}

// rowid_value answers a rowid alias for one source. A single-column INTEGER
// PRIMARY KEY is the rowid in SQLite, and `last_insert_rowid` already makes that
// choice here, so `rowid` answers that column's value when there is one.
// Otherwise it is the engine's row id, which starts at zero where SQLite starts
// at one (docs/sqlite.md declares the difference). A source with no stored row
// behind it -- a join, an aggregate, SELECT without FROM -- has no rowid.
@(private)
rowid_value :: proc(source: Source) -> (Value, bool) {
	if source.table == nil do return {}, false
	if source.row.id == NO_ROW_ID do return {}, false
	schema := &source.table.schema
	if len(schema.primary_key) == 1 {
		key := schema.primary_key[0]
		if key >= 0 && key < len(schema.columns) && schema.columns[key].type.kind == .Int {
			if key < len(source.row.values) {
				if key_value, ok := value_to_i64(source.row.values[key]); ok {
					return value_int(key_value), true
				}
			}
		}
	}
	return value_int(i64(source.row.id)), true
}

@(private)
free_partials :: proc(items: ^[dynamic][]Source) {
	for item in items do delete(item)
	delete(items^)
}

// sql_run_query executes a plain query or one prefixed with common table
// expressions, which are materialized for the life of the statement.
sql_run_query :: proc(tx: ^Tx, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	if select_stmt, ok := statement.(Select_Stmt); ok {
		return sql_exec_select(tx, select_stmt, params)
	}
	with_stmt, is_with := statement.(With_Stmt)
	if !is_with do return {}, errf(.Sql_Unsupported, "not a query")
	// A CTE's name lasts for its statement: inside a transaction the next
	// statement must see the table of that name again, not this query.
	scope := cte_scope_begin(tx)
	defer cte_scope_end(tx, &scope)
	for cte in with_stmt.ctes {
		table, cte_err := tx_materialize_cte(tx, cte, params, with_stmt.recursive)
		if cte_err.kind != .None do return {}, cte_err
		cte_scope_bind(tx, &scope, cte.name, table)
	}
	return sql_exec_select(tx, with_stmt.select_stmt, params)
}

@(private)
select_has_derived_join :: proc(stmt: Select_Stmt) -> bool {
	for join in stmt.joins {
		if join.table.subquery != nil && !join.table.lateral do return true
	}
	return false
}

// Cte_Scope remembers what each name a statement bound in `cte_tables` meant
// before, so the end of the statement puts it back.
Cte_Scope :: struct {
	names:    [dynamic]string,
	previous: [dynamic]^Table,
}

@(private)
cte_scope_begin :: proc(tx: ^Tx) -> Cte_Scope {
	return Cte_Scope{names = make([dynamic]string, 0, 2, tx.alloc), previous = make([dynamic]^Table, 0, 2, tx.alloc)}
}

@(private)
cte_scope_bind :: proc(tx: ^Tx, scope: ^Cte_Scope, name: string, table: ^Table) {
	key := strings.clone(name, tx.alloc)
	append(&scope.names, key)
	append(&scope.previous, tx.cte_tables[key] or_else nil)
	tx.cte_tables[key] = table
}

@(private)
cte_scope_end :: proc(tx: ^Tx, scope: ^Cte_Scope) {
	for i := len(scope.names) - 1; i >= 0; i -= 1 {
		if scope.previous[i] != nil {
			tx.cte_tables[scope.names[i]] = scope.previous[i]
		} else {
			delete_key(&tx.cte_tables, scope.names[i])
		}
	}
}

// tx_materialize_cte evaluates a common table expression into a temporary table
// the statement can read, the same way a view is materialized.
@(private)
tx_materialize_cte :: proc(tx: ^Tx, cte: Cte, params: []Value, recursive: bool) -> (^Table, Error) {
	if recursive && len(cte.select_stmt.compound) == 1 {
		return tx_materialize_recursive_cte(tx, cte, params)
	}
	result, exec_err := sql_exec_select(tx, cte.select_stmt, params)
	if exec_err.kind != .None do return nil, exec_err
	defer sql_result_destroy(&result)
	return materialize_result_table(tx, cte.name, cte.columns, &result)
}

// materialize_result_table turns a query result into a temporary table the rest of
// the statement can read, with the column names the statement gave it.
@(private)
materialize_result_table :: proc(
	tx: ^Tx,
	name: string,
	override: []string,
	result: ^Sql_Result,
) -> (^Table, Error) {
	columns := make([]Column, len(result.columns), tx.alloc)
	for column_name, i in result.columns {
		column := column_name
		if i < len(override) do column = override[i]
		columns[i] = Column {
			name = strings.clone(column, tx.alloc),
			type = view_column_type(result.rows, i),
		}
	}
	schema := Table_Schema {
		name    = strings.clone(name, tx.alloc),
		columns = columns,
	}
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	for row, i in result.rows {
		if insert_err := table_insert(table, Row_Id(i + 1), row); insert_err.kind != .None {
			table_destroy(table)
			return nil, insert_err
		}
	}
	append(&tx.temp_tables, table)
	return table, ERROR_NONE
}

// tx_materialize_lateral runs a LATERAL subquery with one row of the sources to
// its left bound, and answers it as a table.
@(private)
tx_materialize_lateral :: proc(
	tx: ^Tx,
	ref: Table_Ref,
	params: []Value,
	partial: []Source,
) -> (^Table, Error) {
	frame := Outer_Frame{sources = partial, next = tx.outer}
	saved := tx.outer
	tx.outer = &frame
	result, exec_err := sql_exec_select(tx, ref.subquery^, params)
	tx.outer = saved
	if exec_err.kind != .None do return nil, exec_err
	defer sql_result_destroy(&result)
	return materialize_result_table(tx, ref.name, nil, &result)
}

// clone_row_values copies a row onto the caller's allocator.
@(private)
clone_row_values :: proc(values: []Value, alloc: mem.Allocator) -> []Value {
	out := make([]Value, len(values), alloc)
	for value, i in values do out[i] = value_clone(value, alloc)
	return out
}

// compound_apply joins the rows of one more term to the result so far. Every
// operator but UNION ALL answers distinct rows; the result keeps the order in
// which its rows first appeared.
@(private)
compound_apply :: proc(rows: ^[dynamic][]Value, term: [][]Value, op: Compound_Op) {
	if op == .Union_All {
		for row in term do append(rows, clone_row_values(row, context.allocator))
		return
	}
	in_term := make(map[string]bool)
	defer {
		for key in in_term do delete(key)
		delete(in_term)
	}
	if op != .Union {
		for row in term {
			key := encode_output_key(row)
			if key in in_term {
				delete(key)
				continue
			}
			in_term[key] = true
		}
	}
	seen := make(map[string]bool)
	defer {
		for key in seen do delete(key)
		delete(seen)
	}
	kept := make([dynamic][]Value, 0, len(rows))
	for row in rows {
		key := encode_output_key(row)
		keep := !(key in seen)
		switch op {
		case .Intersect:
			keep = keep && key in in_term
		case .Except:
			keep = keep && !(key in in_term)
		case .Union, .Union_All:
		}
		if keep {
			seen[key] = true
			append(&kept, row)
		} else {
			delete(key)
			free_values(row)
		}
	}
	if op == .Union {
		for row in term {
			key := encode_output_key(row)
			if key in seen {
				delete(key)
				continue
			}
			seen[key] = true
			append(&kept, clone_row_values(row, context.allocator))
		}
	}
	delete(rows^)
	rows^ = kept
}

// sql_exec_compound evaluates a compound query left to right, as SQLite does:
// `a UNION b` keeps the distinct rows of both, `a UNION ALL b` appends b,
// `a INTERSECT b` keeps the distinct rows of a that b has, and `a EXCEPT b` the
// distinct rows of a that b lacks. The tail clauses (ORDER BY, LIMIT, OFFSET)
// apply to the result. When a tail exists the rows pass through a temporary
// table, which lets the ordinary select path order them.
@(private)
sql_exec_compound :: proc(tx: ^Tx, stmt: Select_Stmt, params: []Value) -> (Sql_Result, Error) {
	base := stmt
	base.compound = nil
	base.order_by = nil
	base.limit = nil
	base.offset = nil
	base.is_distinct = false
	first, first_err := sql_exec_select(tx, base, params)
	if first_err.kind != .None do return {}, first_err
	defer sql_result_destroy(&first)
	if len(first.columns) == 0 do return {}, errf(.Internal, "compound query without columns")

	rows := make([dynamic][]Value, 0, len(first.rows))
	defer {
		for row in rows do free_values(row)
		delete(rows)
	}
	for row in first.rows do append(&rows, clone_row_values(row, context.allocator))

	for part in stmt.compound {
		term := part.select_stmt
		term.compound = nil
		term.order_by = nil
		term.limit = nil
		term.offset = nil
		term.is_distinct = false
		result, term_err := sql_exec_select(tx, term, params)
		if term_err.kind != .None do return {}, term_err
		if len(result.columns) != len(first.columns) {
			sql_result_destroy(&result)
			return {}, errf(
				.Invalid_Argument,
				"each term of a compound query must return %d columns",
				len(first.columns),
			)
		}
		compound_apply(&rows, result.rows, part.op)
		sql_result_destroy(&result)
	}

	if len(stmt.order_by) == 0 && stmt.limit == nil && stmt.offset == nil {
		result := Sql_Result{kind = .Rows}
		result.columns = make([]string, len(first.columns))
		for name, i in first.columns do result.columns[i] = strings.clone(name, context.allocator)
		result.rows = make([][]Value, len(rows))
		copy(result.rows, rows[:])
		resize(&rows, 0)
		return result, ERROR_NONE
	}

	// Tail clauses: materialize the merged rows, then let the select path order
	// and cut them by reading the temporary table.
	name := fmt.aprintf("_union_%d", len(tx.temp_tables), allocator = tx.alloc)
	columns := make([]Column, len(first.columns), tx.alloc)
	for column_name, i in first.columns {
		columns[i] = Column {
			name = strings.clone(column_name, tx.alloc),
			type = view_column_type(rows[:], i),
		}
	}
	table, table_err := table_create(&Table_Schema{name = name, columns = columns})
	if table_err.kind != .None do return {}, table_err
	for row, i in rows {
		if insert_err := table_insert(table, Row_Id(i + 1), row); insert_err.kind != .None {
			table_destroy(table)
			return {}, insert_err
		}
	}
	append(&tx.temp_tables, table)
	tx.cte_tables[name] = table
	outer := Select_Stmt {
		projections = make([]Select_Item, 1, tx.alloc),
		from        = Table_Ref{name = name},
		order_by    = stmt.order_by,
		limit       = stmt.limit,
		offset      = stmt.offset,
	}
	outer.projections[0] = Select_Item{star = true}
	return sql_exec_select(tx, outer, params)
}

// recursion_limit bounds WITH RECURSIVE: a query that never stops adding rows
// fails instead of running forever. It is a variable so tests can lower it.
recursion_limit: int = 10000

@(private)
recursive_insert :: proc(table: ^Table, seen: ^map[string]bool, values: []Value, next_id: ^Row_Id) -> (bool, Error) {
	key := encode_output_key(values)
	if key in seen^ {
		delete(key)
		return false, ERROR_NONE
	}
	seen^[key] = true
	if err := table_insert(table, next_id^, values); err.kind != .None do return false, err
	next_id^ += 1
	return true, ERROR_NONE
}

// tx_materialize_recursive_cte evaluates `base UNION [ALL] step`: the base fills
// the table, then the step runs against the accumulated rows until it adds
// nothing. Rows are deduplicated, which also makes UNION ALL terminate.
@(private)
tx_materialize_recursive_cte :: proc(tx: ^Tx, cte: Cte, params: []Value) -> (^Table, Error) {
	base := cte.select_stmt
	parts := base.compound
	base.compound = nil
	base.order_by = nil
	base.limit = nil
	base.offset = nil
	first, first_err := sql_exec_select(tx, base, params)
	if first_err.kind != .None do return nil, first_err
	defer sql_result_destroy(&first)
	if len(first.columns) == 0 do return nil, errf(.Internal, "recursive query without columns")

	columns := make([]Column, len(first.columns), tx.alloc)
	for column_name, i in first.columns {
		name := column_name
		if i < len(cte.columns) do name = cte.columns[i]
		columns[i] = Column {
			name = strings.clone(name, tx.alloc),
			type = view_column_type(first.rows, i),
		}
	}
	table, table_err := table_create(&Table_Schema {
		name    = strings.clone(cte.name, tx.alloc),
		columns = columns,
	})
	if table_err.kind != .None do return nil, table_err
	append(&tx.temp_tables, table)
	tx.cte_tables[strings.clone(cte.name, tx.alloc)] = table

	seen := make(map[string]bool)
	defer {
		for key in seen do delete(key)
		delete(seen)
	}
	next_id := Row_Id(1)
	for row in first.rows {
		if _, insert_err := recursive_insert(table, &seen, row, &next_id); insert_err.kind != .None {
			return nil, insert_err
		}
	}

	steps := 0
	for steps < recursion_limit {
		term := parts[0].select_stmt
		term.compound = nil
		term.order_by = nil
		term.limit = nil
		term.offset = nil
		result, term_err := sql_exec_select(tx, term, params)
		if term_err.kind != .None do return nil, term_err
		added := 0
		for row in result.rows {
			inserted, insert_err := recursive_insert(table, &seen, row, &next_id)
			if insert_err.kind != .None {
				sql_result_destroy(&result)
				return nil, insert_err
			}
			if inserted do added += 1
		}
		sql_result_destroy(&result)
		if added == 0 do break
		steps += 1
	}
	if steps >= recursion_limit {
		return nil, errf(.Cancelled, "WITH RECURSIVE %s exceeded %d steps", cte.name, recursion_limit)
	}
	return table, ERROR_NONE
}


// --- Window functions ------------------------------------------------------

// Window_Cell holds what one output row needs for one window expression: the
// keys that decide its partition and its position, and the evaluated arguments
// that lag/lead/first_value read from other rows.
Window_Cell :: struct {
	partition: []u8,
	order:     []u8,
	args:      []Value,
}

// window_partition_key encodes the PARTITION BY values of the current row.
window_partition_key :: proc(ctx: ^Eval_Ctx, window: Window_Expr) -> ([]u8, Error) {
	if len(window.partition) == 0 do return nil, ERROR_NONE
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for expr in window.partition {
		value, eval_err := eval_expr(ctx, expr)
		if eval_err.kind != .None do return nil, eval_err
		value_encode_key(&w, value)
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	return out, ERROR_NONE
}

// window_order_key encodes the ORDER BY clause inside OVER ().
window_order_key :: proc(ctx: ^Eval_Ctx, window: Window_Expr) -> ([]u8, Error) {
	if len(window.order_by) == 0 do return nil, ERROR_NONE
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for item in window.order_by {
		value, eval_err := eval_expr(ctx, item.expr)
		if eval_err.kind != .None do return nil, eval_err
		collation, has := collate_name(item.expr)
		if !has {
			collation, has = column_collation(ctx, item.expr)
		}
		if has && len(collation) > 0 {
			value = collate_ordered_value(value, collation)
		}
		order_key_append(&w, value, item)
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	return out, ERROR_NONE
}

// window_is_known tells whether a function name has a window implementation.
window_is_known :: proc(name: string) -> bool {
	return strings.equal_fold(name, "row_number") ||
		strings.equal_fold(name, "rank") ||
		strings.equal_fold(name, "dense_rank") ||
		strings.equal_fold(name, "percent_rank") ||
		strings.equal_fold(name, "cume_dist") ||
		strings.equal_fold(name, "ntile") ||
		strings.equal_fold(name, "lag") ||
		strings.equal_fold(name, "lead") ||
		strings.equal_fold(name, "first_value") ||
		strings.equal_fold(name, "last_value") ||
		strings.equal_fold(name, "nth_value") ||
		is_aggregate_name(name)
}

// window_fill computes one window expression over the rows of one partition.
// `order_keys` is already sorted alongside `indexes`; with an ORDER BY clause
// the frame runs from the partition start to the last peer of each row.
window_fill :: proc(
	ctx: ^Eval_Ctx,
	window: Window_Expr,
	position: int,
	indexes: []int,
	order_keys: []string,
	rows: []Output_Row,
	cells: [][dynamic]Window_Cell,
	cell_index: int,
	sources: [][]Source,
) -> Error {
	running := len(window.order_by) > 0
	name := window.name
	// A RANGE frame with an offset runs from one ORDER BY *value* to another, so the
	// values are read once for the partition. The slice lives until the function
	// ends: a `defer` inside the block below would free it as soon as the block
	// exits, which is before any frame reads it.
	order_numbers: []f64
	defer delete(order_numbers)
	if window_frame_reads_values(window.frame) {
		if len(window.order_by) != 1 {
			return errf(.Sql_Unsupported, "a RANGE frame with an offset needs exactly one ORDER BY term")
		}
		order_numbers = make([]f64, len(indexes))
		saved := ctx.sources
		for index, j in indexes {
			ctx.sources = sources[index]
			value, eval_err := eval_expr(ctx, window.order_by[0].expr)
			if eval_err.kind != .None {
				ctx.sources = saved
				return eval_err
			}
			number, is_number := value_as_f64(value)
			if !is_number {
				ctx.sources = saved
				return errf(.Sql_Unsupported, "a RANGE frame with an offset needs a numeric ORDER BY term")
			}
			order_numbers[j] = number
		}
		ctx.sources = saved
	}
	assign :: proc(rows: []Output_Row, row: int, position: int, value: Value) {
		rows[row].values[position] = value_clone(value, context.allocator)
	}
	arg_of :: proc(cells: [][dynamic]Window_Cell, row, cell_index, arg: int) -> Value {
		cell_values := cells[row][cell_index].args
		if arg < 0 || arg >= len(cell_values) do return value_null()
		return cell_values[arg]
	}
	if strings.equal_fold(name, "row_number") {
		for index, j in indexes do assign(rows, index, position, value_int(i64(j + 1)))
		return ERROR_NONE
	}
	if strings.equal_fold(name, "lag") || strings.equal_fold(name, "lead") {
		forward := strings.equal_fold(name, "lead")
		for index, j in indexes {
			offset := i64(1)
			if offset_value := arg_of(cells, index, cell_index, 1); offset_value.kind != .Null {
				if parsed, ok := value_to_i64(offset_value); ok do offset = parsed
			}
			target := i64(j) + (forward ? offset : -offset)
			if target < 0 || target >= i64(len(indexes)) {
				fallback := arg_of(cells, index, cell_index, 2)
				assign(rows, index, position, fallback)
				continue
			}
			assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
		}
		return ERROR_NONE
	}
	// Rank family: walk peer groups, which need the ORDER BY keys.
	peer_end :: proc(order_keys: []string, j: int) -> int {
		end := j
		for end + 1 < len(order_keys) && order_keys[end + 1] == order_keys[j] do end += 1
		return end
	}
	if strings.equal_fold(name, "rank") || strings.equal_fold(name, "dense_rank") ||
	   strings.equal_fold(name, "percent_rank") || strings.equal_fold(name, "cume_dist") {
		group := 0
		j := 0
		for j < len(indexes) {
			end := running ? peer_end(order_keys, j) : len(indexes) - 1
			group += 1
			for f in j ..= end {
				index := indexes[f]
				switch {
				case strings.equal_fold(name, "rank"):
					assign(rows, index, position, value_int(i64(j + 1)))
				case strings.equal_fold(name, "dense_rank"):
					assign(rows, index, position, value_int(i64(group)))
				case strings.equal_fold(name, "percent_rank"):
					denominator := len(indexes) - 1
					percent := denominator <= 0 ? 0.0 : f64(j) / f64(denominator)
					assign(rows, index, position, value_float(percent))
				case:
					assign(rows, index, position, value_float(f64(end + 1) / f64(len(indexes))))
				}
			}
			j = end + 1
		}
		return ERROR_NONE
	}
	if strings.equal_fold(name, "ntile") {
		buckets := i64(1)
		if len(indexes) > 0 {
			if value := arg_of(cells, indexes[0], cell_index, 0); value.kind != .Null {
				if parsed, ok := value_to_i64(value); ok && parsed > 0 do buckets = parsed
			}
		}
		for index, j in indexes {
			bucket := i64(j) * buckets / i64(len(indexes)) + 1
			assign(rows, index, position, value_int(bucket))
		}
		return ERROR_NONE
	}
	if strings.equal_fold(name, "first_value") || strings.equal_fold(name, "last_value") ||
	   strings.equal_fold(name, "nth_value") {
		if window.frame.has {
			for index, j in indexes {
				lo, hi, frame_err := window_frame_bounds(window.frame, j, len(indexes), ctx.params, order_keys, order_numbers)
				if frame_err.kind != .None do return frame_err
				target := lo
				switch {
				case strings.equal_fold(name, "last_value"):
					target = hi
				case strings.equal_fold(name, "nth_value"):
					wanted := i64(1)
					if value := arg_of(cells, index, cell_index, 1); value.kind != .Null {
						if parsed, ok := value_to_i64(value); ok do wanted = parsed
					}
					if wanted < 1 || lo > hi || int(wanted) > hi - lo + 1 {
						assign(rows, index, position, value_null())
						continue
					}
					target = lo + int(wanted) - 1
				}
				if lo > hi {
					assign(rows, index, position, value_null())
					continue
				}
				assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
			}
			return ERROR_NONE
		}
		for index, j in indexes {
			target := 0
			switch {
			case strings.equal_fold(name, "last_value"):
				target = running ? peer_end(order_keys, j) : len(indexes) - 1
			case strings.equal_fold(name, "nth_value"):
				wanted := i64(1)
				if value := arg_of(cells, index, cell_index, 1); value.kind != .Null {
					if parsed, ok := value_to_i64(value); ok do wanted = parsed
				}
				if wanted < 1 || wanted > i64(len(indexes)) do continue
				target = int(wanted - 1)
			}
			assign(rows, index, position, arg_of(cells, indexes[target], cell_index, 0))
		}
		return ERROR_NONE
	}
	// Aggregate windows reuse the group aggregate: the frame is a group.
	call := Call_Expr {
		name        = window.name,
		args        = window.args,
		star        = window.star,
		is_distinct = window.is_distinct,
	}
	if window.frame.has {
		for j in 0 ..< len(indexes) {
			lo, hi, frame_err := window_frame_bounds(window.frame, j, len(indexes), ctx.params, order_keys, order_numbers)
			if frame_err.kind != .None do return frame_err
			value, agg_err := window_aggregate_frame(ctx, window, call, cells, indexes, lo, hi, cell_index, sources)
			if agg_err.kind != .None do return agg_err
			assign(rows, indexes[j], position, value)
		}
		return ERROR_NONE
	}
	j := 0
	for j < len(indexes) {
		end := running ? peer_end(order_keys, j) : len(indexes) - 1
		// The frame of a running window is the partition up to the last peer of this
		// row, not the row alone: `sum(n) OVER (ORDER BY k)` is cumulative.
		value, agg_err := window_aggregate_frame(ctx, window, call, cells, indexes, 0, end, cell_index, sources)
		if agg_err.kind != .None do return agg_err
		for f in j ..= end do assign(rows, indexes[f], position, value)
		j = end + 1
	}
	return ERROR_NONE
}

// window_frame_reads_values reports whether a frame is measured in the ORDER BY
// value rather than in rows or peer groups.
@(private)
window_frame_reads_values :: proc(frame: Window_Frame) -> bool {
	if !frame.has || frame.unit != .Range do return false
	return frame.start.offset != nil || frame.end.offset != nil
}

// window_peer_start and window_peer_end find the first and last position that sort
// equally with `j`, which is what CURRENT ROW means in a RANGE or GROUPS frame.
@(private)
window_peer_start :: proc(order_keys: []string, j: int) -> int {
	start := j
	for start > 0 && order_keys[start - 1] == order_keys[j] do start -= 1
	return start
}

@(private)
window_peer_end :: proc(order_keys: []string, j: int) -> int {
	end := j
	for end + 1 < len(order_keys) && order_keys[end + 1] == order_keys[j] do end += 1
	return end
}

// window_frame_bounds turns a frame into the inclusive range of partition
// positions it covers for row `j`. An empty frame (lo > hi) is legal: the
// aggregate over no rows still has a value (count 0, sum NULL).
//
// ROWS counts rows. GROUPS counts peer groups, so 1 PRECEDING is the group before
// this one. RANGE without an offset means the peers of the row; with an offset it
// runs from the ORDER BY value that far below to the value that far above, which
// is why it needs one numeric ordering term.
@(private)
window_frame_bounds :: proc(
	frame: Window_Frame,
	j: int,
	count: int,
	params: []Value,
	order_keys: []string,
	order_numbers: []f64,
) -> (lo: int, hi: int, err: Error) {
	rows_offset :: proc(bound: Frame_Bound, params: []Value) -> (int, Error) {
		offset := i64(1)
		if bound.offset != nil {
			value, constant := eval_constant(bound.offset, params)
			if !constant do return 0, errf(.Invalid_Argument, "a frame offset must be a constant")
			parsed, ok := value_to_i64(value)
			if !ok || parsed < 0 {
				return 0, errf(.Invalid_Argument, "a frame offset must be a non-negative integer")
			}
			offset = parsed
		}
		return int(offset), ERROR_NONE
	}
	value_offset :: proc(bound: Frame_Bound, params: []Value) -> (f64, Error) {
		if bound.offset == nil do return 1, ERROR_NONE
		value, constant := eval_constant(bound.offset, params)
		if !constant do return 0, errf(.Invalid_Argument, "a frame offset must be a constant")
		number, ok := value_as_f64(value)
		if !ok || number < 0 {
			return 0, errf(.Invalid_Argument, "a frame offset must be a non-negative number")
		}
		return number, ERROR_NONE
	}
	if count == 0 do return 0, -1, ERROR_NONE
	if !frame.has do return 0, count - 1, ERROR_NONE

	switch frame.unit {
	case .Rows:
		bound_position :: proc(bound: Frame_Bound, j: int, is_start: bool, count: int, params: []Value) -> (int, Error) {
			switch bound.kind {
			case .Unbounded_Preceding:
				if !is_start do return 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
				return 0, ERROR_NONE
			case .Unbounded_Following:
				if is_start do return 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
				return count, ERROR_NONE
			case .Current_Row:
				return j, ERROR_NONE
			case .Preceding, .Following:
				offset, offset_err := rows_offset(bound, params)
				if offset_err.kind != .None do return 0, offset_err
				if bound.kind == .Preceding do return j - offset, ERROR_NONE
				return j + offset, ERROR_NONE
			}
			return 0, ERROR_NONE
		}
		start, lo_err := bound_position(frame.start, j, true, count, params)
		if lo_err.kind != .None do return 0, 0, lo_err
		end, hi_err := bound_position(frame.end, j, false, count, params)
		if hi_err.kind != .None do return 0, 0, hi_err
		lo = start
		hi = end
		if lo < 0 do lo = 0
		if hi > count - 1 do hi = count - 1
		return lo, hi, ERROR_NONE

	case .Groups:
		// Where each peer group starts, so a bound can name a group instead of a row.
		group_index := make([]int, count)
		defer delete(group_index)
		group_first := make([dynamic]int, 0, count)
		defer delete(group_first)
		for k in 0 ..< count {
			if k == 0 || order_keys[k] != order_keys[k - 1] do append(&group_first, k)
			group_index[k] = len(group_first) - 1
		}
		group_end :: proc(group_first: []int, group: int, count: int) -> int {
			if group + 1 < len(group_first) do return group_first[group + 1] - 1
			return count - 1
		}
		current := group_index[j]
		switch frame.start.kind {
		case .Unbounded_Preceding:
			lo = 0
		case .Current_Row:
			lo = group_first[current]
		case .Preceding:
			offset, offset_err := rows_offset(frame.start, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			lo = group_first[max(current - offset, 0)]
		case .Following:
			offset, offset_err := rows_offset(frame.start, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			target := current + offset
			lo = target < len(group_first) ? group_first[target] : count
		case .Unbounded_Following:
			return 0, 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
		}
		switch frame.end.kind {
		case .Unbounded_Following:
			hi = count - 1
		case .Current_Row:
			hi = group_end(group_first[:], current, count)
		case .Preceding:
			offset, offset_err := rows_offset(frame.end, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			target := current - offset
			hi = target >= 0 ? group_end(group_first[:], target, count) : -1
		case .Following:
			offset, offset_err := rows_offset(frame.end, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			hi = group_end(group_first[:], min(current + offset, len(group_first) - 1), count)
		case .Unbounded_Preceding:
			return 0, 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
		}
		if lo < 0 do lo = 0
		if hi > count - 1 do hi = count - 1
		return lo, hi, ERROR_NONE

	case .Range:
		if frame.start.offset == nil && frame.end.offset == nil {
			// No offsets: the frame is made of peers.
			switch frame.start.kind {
			case .Unbounded_Preceding:
				lo = 0
			case .Current_Row:
				lo = window_peer_start(order_keys, j)
			case .Unbounded_Following:
				return 0, 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
			case .Preceding, .Following:
				return 0, 0, errf(.Sql_Syntax, "a RANGE frame in this position needs an offset")
			}
			switch frame.end.kind {
			case .Unbounded_Following:
				hi = count - 1
			case .Current_Row:
				hi = window_peer_end(order_keys, j)
			case .Unbounded_Preceding:
				return 0, 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
			case .Preceding, .Following:
				return 0, 0, errf(.Sql_Syntax, "a RANGE frame in this position needs an offset")
			}
			return lo, hi, ERROR_NONE
		}
		if len(order_numbers) != count {
			return 0, 0, errf(.Sql_Unsupported, "a RANGE frame with an offset needs one numeric ORDER BY term")
		}
		ascending := count < 2 || order_numbers[count - 1] >= order_numbers[0]
		// The first position whose value is on the wanted side of `target`, walking
		// the partition in its own direction.
		find_first :: proc(values: []f64, target: f64, ascending: bool, at_least: bool) -> int {
			low, high := 0, len(values)
			for low < high {
				middle := (low + high) / 2
				value := values[middle]
				before := ascending ? value < target : value > target
				after := ascending ? value > target : value < target
				// before < target < after, in the partition's direction.
				reached := at_least ? !before : after
				if reached {
					high = middle
				} else {
					low = middle + 1
				}
			}
			return low
		}
		current := order_numbers[j]
		switch frame.start.kind {
		case .Unbounded_Preceding:
			lo = 0
		case .Current_Row:
			lo = window_peer_start(order_keys, j)
		case .Preceding:
			offset, offset_err := value_offset(frame.start, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			lo = find_first(order_numbers, ascending ? current - offset : current + offset, ascending, true)
		case .Following:
			offset, offset_err := value_offset(frame.start, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			lo = find_first(order_numbers, ascending ? current + offset : current - offset, ascending, true)
		case .Unbounded_Following:
			return 0, 0, errf(.Invalid_Argument, "UNBOUNDED FOLLOWING cannot start a frame")
		}
		switch frame.end.kind {
		case .Unbounded_Following:
			hi = count - 1
		case .Current_Row:
			hi = window_peer_end(order_keys, j)
		case .Preceding:
			offset, offset_err := value_offset(frame.end, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			hi = find_first(order_numbers, ascending ? current - offset : current + offset, ascending, false) - 1
		case .Following:
			offset, offset_err := value_offset(frame.end, params)
			if offset_err.kind != .None do return 0, 0, offset_err
			hi = find_first(order_numbers, ascending ? current + offset : current - offset, ascending, false) - 1
		case .Unbounded_Preceding:
			return 0, 0, errf(.Invalid_Argument, "UNBOUNDED PRECEDING cannot end a frame")
		}
		if lo < 0 do lo = 0
		if hi > count - 1 do hi = count - 1
		return lo, hi, ERROR_NONE
	}
	return 0, count - 1, ERROR_NONE
}

// window_aggregate_over evaluates an aggregate over positions [lo, hi] of the
// partition. An empty range is an empty group, not an error.
@(private)
window_aggregate_over :: proc(
	ctx: ^Eval_Ctx,
	call: Call_Expr,
	sources: [][]Source,
	indexes: []int,
	lo: int,
	hi: int,
) -> (Value, Error) {
	if lo > hi {
		ctx.group = nil
		ctx.grouped = true
		defer ctx.grouped = false
		return eval_aggregate(ctx, call)
	}
	frame := make([][]Source, hi - lo + 1)
	defer delete(frame)
	for f in lo ..= hi do frame[f - lo] = sources[indexes[f]]
	ctx.group = frame
	ctx.grouped = true
	value, agg_err := eval_aggregate(ctx, call)
	ctx.group = nil
	ctx.grouped = false
	return value, agg_err
}

// eval_aggregate_values is eval_aggregate over values instead of sources. A
// grouped row has no row behind it - its window argument is an aggregate that was
// already evaluated for the group - so the frame is the captured values, and the
// rules are the ones eval_aggregate applies (same comparisons, same integer versus
// float accumulation, same DISTINCT keys) so `sum(count(*)) OVER ()` answers what
// `sum(n)` over a subquery of the same groups answers.
@(private)
eval_aggregate_values :: proc(ctx: ^Eval_Ctx, call: Call_Expr, values: []Value) -> (Value, Error) {
	name := strings.to_lower(call.name)
	defer delete(name)
	if name == "count" {
		if call.star || len(call.args) == 0 do return value_int(i64(len(values))), ERROR_NONE
		count := 0
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		for value in values {
			if value.kind == .Null do continue
			if call.is_distinct {
				key := agg_distinct_key(value)
				_, repeated := keys[key]
				if repeated {
					delete(key)
				} else {
					keys[key] = true
				}
				if repeated do continue
			}
			count += 1
		}
		return value_int(i64(count)), ERROR_NONE
	}
	if name == "group_concat" || name == "string_agg" {
		separator := ","
		separator_text: string
		if len(call.args) == 2 {
			value, eval_err := eval_expr(ctx, call.args[1])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind != .Null {
				separator_text = value_format(value, context.allocator)
				separator = separator_text
			}
		}
		defer if len(separator_text) > 0 do delete(separator_text)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		seen := 0
		for value in values {
			if value.kind == .Null do continue
			if seen > 0 do strings.write_string(&builder, separator)
			strings.write_string(&builder, value_format(value, context.allocator))
			seen += 1
		}
		if seen == 0 do return value_null(), ERROR_NONE
		return value_string(strings.clone(strings.to_string(builder), context.allocator)), ERROR_NONE
	}
	if name == "array_agg" {
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		list := make([dynamic]Value, 0, len(values))
		defer delete(list)
		for value in values {
			if call.is_distinct {
				key := agg_distinct_key(value)
				_, repeated := keys[key]
				if repeated {
					delete(key)
					continue
				}
				keys[key] = true
			}
			append(&list, value_clone(value, context.allocator))
		}
		if len(list) == 0 do return value_null(), ERROR_NONE
		items := make([]Value, len(list))
		copy(items, list[:])
		return Value{kind = .Array, list = items}, ERROR_NONE
	}
	if name != "min" && name != "max" && name != "sum" && name != "total" && name != "avg" {
		return {}, errf(.Internal, "unknown aggregate %s", name)
	}
	accumulator := value_null()
	seen := 0
	sum_int: i64
	sum_float: f64
	sum_128: i128
	uses_float: bool
	uses_128: bool
	keys: map[string]bool
	if call.is_distinct do keys = make(map[string]bool)
	defer agg_distinct_destroy(&keys)
	for value in values {
		if value.kind == .Null do continue
		if call.is_distinct {
			key := agg_distinct_key(value)
			_, repeated := keys[key]
			if repeated {
				delete(key)
			} else {
				keys[key] = true
			}
			if repeated do continue
		}
		seen += 1
		switch name {
		case "min":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "min() mixes incompatible types")
				if order == .Less do accumulator = value
			}
		case "max":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "max() mixes incompatible types")
				if order == .Greater do accumulator = value
			}
		case "sum", "total", "avg":
			if !value_is_numeric(value) {
				return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			}
			if value.kind == .Float {
				uses_float = true
				number, _ := value_to_f64(value)
				sum_float += number
			} else if value.kind == .Int128 || value.kind == .Uint128 {
				if !uses_128 {
					uses_128 = true
					sum_128 = i128(sum_int)
				}
				sum_128 += value_as_i128(value)
			} else if uses_float {
				number, _ := value_to_f64(value)
				sum_float += number
			} else if uses_128 {
				number, _ := value_to_i64(value)
				sum_128 += i128(number)
			} else {
				number, _ := value_to_i64(value)
				sum_int += number
			}
		}
	}
	switch name {
	case "min", "max":
		return value_clone(accumulator, context.allocator), ERROR_NONE
	case "sum", "total":
		if seen == 0 do return value_null(), ERROR_NONE
		if uses_float do return value_float(sum_float), ERROR_NONE
		if uses_128 do return value_int128(sum_128), ERROR_NONE
		return value_int(sum_int), ERROR_NONE
	case "avg":
		if seen == 0 do return value_null(), ERROR_NONE
		total := uses_float ? sum_float : (uses_128 ? f64(sum_128) : f64(sum_int))
		return value_float(total / f64(seen)), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown aggregate %s", name)
}

// window_aggregate_frame aggregates rows [lo, hi] of one window. When the row has
// a source the aggregate is evaluated over it exactly as before; when it has none
// (a grouped row) the frame is the argument values the group captured.
@(private)
window_aggregate_frame :: proc(
	ctx: ^Eval_Ctx,
	window: Window_Expr,
	call: Call_Expr,
	cells: [][dynamic]Window_Cell,
	indexes: []int,
	lo, hi, cell_index: int,
	sources: [][]Source,
) -> (Value, Error) {
	if len(sources) != 0 {
		return window_aggregate_over(ctx, call, sources, indexes, lo, hi)
	}
	if lo > hi do return value_null(), ERROR_NONE
	values := make([]Value, hi - lo + 1)
	defer delete(values)
	for f in lo ..= hi {
		cell := cells[indexes[f]][cell_index]
		if window.star || len(cell.args) == 0 {
			// count(*) over the frame: one non-null stand-in per row.
			values[f - lo] = value_int(1)
			continue
		}
		values[f - lo] = cell.args[0]
	}
	return eval_aggregate_values(ctx, call, values)
}

// window_sort orders the row indexes of a partition by their ORDER BY keys.
// Insertion sort keeps equal keys in row order, which the peer logic relies on.
window_sort :: proc(indexes: []int, order_keys: []string) {
	for j in 1 ..< len(indexes) {
		current := indexes[j]
		current_key := order_keys[j]
		at := j
		for at > 0 && order_keys[at - 1] > current_key {
			indexes[at] = indexes[at - 1]
			order_keys[at] = order_keys[at - 1]
			at -= 1
		}
		indexes[at] = current
		order_keys[at] = current_key
	}
}

// apply_windows fills every window projection once all output rows exist.
apply_windows :: proc(
	ctx: ^Eval_Ctx,
	nodes: []^Expr,
	slots: []int,
	cells: [][dynamic]Window_Cell,
	rows: []Output_Row,
	sources: [][]Source,
) -> Error {
	for node, cell_index in nodes {
		position := slots[cell_index]
		window := node^.(Window_Expr)
		if !window_is_known(window.name) {
			return errf(.Sql_Unsupported, "unknown window function %s()", window.name)
		}
		if len(window.partition) == 0 {
			indexes := make([]int, len(rows))
			order_keys := make([]string, len(rows))
			for _, i in rows {
				indexes[i] = i
				order_keys[i] = string(cells[i][cell_index].order)
			}
			window_sort(indexes, order_keys)
			if fill_err := window_fill(ctx, window, position, indexes, order_keys, rows, cells, cell_index, sources); fill_err.kind != .None {
				delete(indexes)
				delete(order_keys)
				return fill_err
			}
			delete(indexes)
			delete(order_keys)
			continue
		}
		buckets := make(map[string][dynamic]int)
		keys := make([dynamic]string)
		for _, i in rows {
			key := string(cells[i][cell_index].partition)
			bucket, exists := buckets[key]
			if !exists do append(&keys, strings.clone(key))
			append(&bucket, i)
			buckets[key] = bucket
		}
		for key in keys {
			indexes := buckets[key]
			order_keys := make([]string, len(indexes))
			for index, j in indexes do order_keys[j] = string(cells[index][cell_index].order)
			window_sort(indexes[:], order_keys)
			fill_err := window_fill(ctx, window, position, indexes[:], order_keys, rows, cells, cell_index, sources)
			delete(order_keys)
			delete(indexes)
			delete(key)
			if fill_err.kind != .None {
				for other in keys {
					if other == key do continue
					delete(other)
				}
				return fill_err
			}
		}
		delete(keys)
		delete(buckets)
	}
	return ERROR_NONE
}

// window_row_cells evaluates one row's window cells: the partition key, the order
// key and the arguments, each with the context the row is being read under, so a
// grouped row answers an aggregate and an ungrouped one answers a column. The
// statement's windows are metadata, so this runs before the projection: the
// projection is what puts the result in its slot.
window_row_cells :: proc(
	ctx: ^Eval_Ctx,
	nodes: []^Expr,
	has_windows: bool,
) -> ([dynamic]Window_Cell, Error) {
	cells := make([dynamic]Window_Cell, 0, len(nodes))
	if !has_windows do return cells, ERROR_NONE
	for node in nodes {
		window := node^.(Window_Expr)
		partition_key, partition_err := window_partition_key(ctx, window)
		if partition_err.kind != .None do return cells, partition_err
		order_key, order_err := window_order_key(ctx, window)
		if order_err.kind != .None {
			delete(partition_key)
			return cells, order_err
		}
		args := make([]Value, len(window.args))
		for arg, a in window.args {
			arg_value, arg_err := eval_expr(ctx, arg)
			if arg_err.kind != .None {
				delete(partition_key)
				delete(order_key)
				free_values(args)
				return cells, arg_err
			}
			args[a] = value_clone(arg_value, context.allocator)
		}
		append(&cells, Window_Cell{partition = partition_key, order = order_key, args = args})
	}
	return cells, ERROR_NONE
}

@(private)
free_values_over_rows :: proc(rows: ^[dynamic]Output_Row) {
	for row in rows do free_values(row.values)
}

// window_cells_destroy frees one cell list: the keys it holds and the list itself.
@(private)
window_cells_destroy :: proc(cells: [dynamic]Window_Cell) {
	for cell in cells {
		delete(cell.partition)
		delete(cell.order)
		free_values(cell.args)
	}
	delete(cells)
}

// window_cell_rows_destroy frees the cell list of every output row.
@(private)
window_cell_rows_destroy :: proc(rows: ^[dynamic][dynamic]Window_Cell) {
	for cells in rows do window_cells_destroy(cells)
	delete(rows^)
}

// Expr_Visit returns whether the walk should descend into the node it was given.
Expr_Visit :: #type proc(expr: ^Expr, user: rawptr) -> bool

// expr_walk visits every expression of a tree, parents before children, and is the
// one place that knows the shape of every node: a new expression type must be added
// here, or everything built on the walk silently misses its subtree. A window's
// arguments are not descended into - SQL does not put a window inside a window -
// and a subquery's windows belong to the SELECT of the subquery.
expr_walk :: proc(expr: ^Expr, visit: Expr_Visit, user: rawptr) {
	if expr == nil do return
	if !visit(expr, user) do return
	#partial switch e in expr^ {
	case Binary_Expr:
		expr_walk(e.left, visit, user)
		expr_walk(e.right, visit, user)
	case Unary_Expr:
		expr_walk(e.operand, visit, user)
	case Is_Null_Expr:
		expr_walk(e.operand, visit, user)
	case Between_Expr:
		expr_walk(e.operand, visit, user)
		expr_walk(e.low, visit, user)
		expr_walk(e.high, visit, user)
	case In_Expr:
		expr_walk(e.operand, visit, user)
		for item in e.items do expr_walk(item, visit, user)
	case Like_Expr:
		expr_walk(e.operand, visit, user)
		expr_walk(e.pattern, visit, user)
	case Match_Expr:
		expr_walk(e.operand, visit, user)
		expr_walk(e.pattern, visit, user)
	case Cast_Expr:
		expr_walk(e.operand, visit, user)
	case Collate_Expr:
		expr_walk(e.operand, visit, user)
	case Call_Expr:
		for arg in e.args do expr_walk(arg, visit, user)
	case Case_Expr:
		expr_walk(e.operand, visit, user)
		for branch in e.branches {
			expr_walk(branch.condition, visit, user)
			expr_walk(branch.result, visit, user)
		}
		expr_walk(e.fallback, visit, user)
	}
}

@(private)
collect_window_visit :: proc(expr: ^Expr, user: rawptr) -> bool {
	if _, is_window := expr^.(Window_Expr); is_window {
		append(cast(^[dynamic]^Expr)user, expr)
		return false
	}
	return true
}

// expr_collect_windows appends every window expression inside `expr`, outermost
// first. It is what gives a window nested in a larger projection a slot of its own.
expr_collect_windows :: proc(expr: ^Expr, out: ^[dynamic]^Expr) {
	expr_walk(expr, collect_window_visit, rawptr(out))
}

@(private)
has_window_visit :: proc(expr: ^Expr, user: rawptr) -> bool {
	if _, is_window := expr^.(Window_Expr); is_window {
		found := cast(^bool)user
		found^ = true
		return false
	}
	return true
}

// expr_has_window reports whether a projection needs the whole scan, which a window
// anywhere in it does: its frame is the table.
expr_has_window :: proc(expr: ^Expr) -> bool {
	found := false
	expr_walk(expr, has_window_visit, rawptr(&found))
	return found
}

// window_positions lists the projection indexes that hold a window expression.
window_positions_of :: proc(expanded: []^Expr) -> []int {
	positions := make([dynamic]int)
	for expr, i in expanded {
		if _, is_window := expr^.(Window_Expr); is_window do append(&positions, i)
	}
	return positions[:]
}

// window_cell_for reports whether a projection index holds a window expression.
window_cell_for :: proc(positions: []int, index: int) -> int {
	for position, at in positions {
		if position == index do return at
	}
	return -1
}

// --- Streaming scan ---------------------------------------------------------

// Agg_Acc is one aggregate accumulated as rows stream past. It mirrors what
// eval_aggregate does over a materialized group, with the group replaced by a
// running value: count, sum, total, avg, min, max and group_concat.
Agg_Acc :: struct {
	call:       Call_Expr,
	name:       string,
	seen:       int,
	best:       Value,
	sum_int:    i64,
	sum_float:  f64,
	sum_128:    i128,
	uses_float: bool,
	uses_128:   bool,
	builder:    strings.Builder,
	list:       [dynamic]Value,
	has_text:   bool,
	separator:  string,
	sep_owned:  bool,
	// keys remembers the values a DISTINCT aggregate has already seen, so a
	// repeated one is skipped instead of folded twice. `fold_distinct` is a
	// separate flag because a map value cannot be compared against nil in Odin.
	keys:          map[string]bool,
	fold_distinct: bool,
}

// Agg_Stream is the set of aggregates a streaming scan is accumulating, plus the
// first row that passed the filter: a projection that mixes an aggregate with a
// plain column reads that row, the way a group aggregate reads the group.
Agg_Stream :: struct {
	accs:         [dynamic]Agg_Acc,
	first_values: []Value,
	first_id:     Row_Id,
	have_first:   bool,
}

@(private)
agg_stream_destroy :: proc(stream: ^Agg_Stream) {
	for &acc in stream.accs {
		value_deep_free(acc.best, context.allocator)
		for item in acc.list do value_deep_free(item, context.allocator)
		delete(acc.list)
		if acc.builder.buf != nil do strings.builder_destroy(&acc.builder)
		if acc.sep_owned do delete(acc.separator)
		agg_distinct_destroy(&acc.keys)
	}
	delete(stream.accs)
	free_values(stream.first_values)
}

@(private)
agg_stream_lookup :: proc(stream: ^Agg_Stream, call: Call_Expr) -> ^Agg_Acc {
	for &acc in stream.accs {
		if !strings.equal_fold(acc.name, call.name) do continue
		if acc.call.star != call.star do continue
		if len(acc.call.args) != len(call.args) do continue
		if len(call.args) == 0 do return &acc
		if acc.call.args[0] == call.args[0] do return &acc
	}
	return nil
}

// agg_stream_add folds one row into every accumulator. The row context is the
// one the WHERE clause just used, so the aggregate argument sees the same values.
@(private)
agg_stream_add :: proc(row_ctx: ^Eval_Ctx, stream: ^Agg_Stream) -> Error {
	for &acc in stream.accs {
		if acc.call.star || len(acc.call.args) == 0 {
			acc.seen += 1
			continue
		}
		value, value_err := eval_expr(row_ctx, acc.call.args[0])
		if value_err.kind != .None do return value_err
		// array_agg keeps NULLs: they are elements of the array, as in
		// PostgreSQL. Every other aggregate skips them.
		if value.kind == .Null && acc.name != "array_agg" do continue
		if acc.fold_distinct {
			key := agg_distinct_key(value)
			_, repeated := acc.keys[key]
			if repeated {
				delete(key)
			} else {
				acc.keys[key] = true
			}
			if repeated do continue
		}
		acc.seen += 1
		switch acc.name {
		case "count":
		// counted above
		case "min", "max":
			if acc.best.kind == .Null {
				acc.best = value_clone(value, context.allocator)
			} else {
				order, comparable := value_compare(value, acc.best)
				if !comparable do return errf(.Invalid_Type, "%s() mixes incompatible types", acc.name)
				if (acc.name == "min" && order == .Less) || (acc.name == "max" && order == .Greater) {
					value_deep_free(acc.best, context.allocator)
					acc.best = value_clone(value, context.allocator)
				}
			}
		case "sum", "total", "avg":
			if !value_is_numeric(value) {
				return errf(.Invalid_Type, "%s() expects numbers", acc.name)
			}
			if value.kind == .Float {
				acc.uses_float = true
				number, _ := value_to_f64(value)
				acc.sum_float += number
			} else if value.kind == .Int128 || value.kind == .Uint128 {
				if !acc.uses_128 {
					acc.uses_128 = true
					acc.sum_128 = i128(acc.sum_int)
				}
				acc.sum_128 += value_as_i128(value)
			} else if acc.uses_float {
				number, _ := value_to_f64(value)
				acc.sum_float += number
			} else if acc.uses_128 {
				number, _ := value_to_i64(value)
				acc.sum_128 += i128(number)
			} else {
				number, _ := value_to_i64(value)
				acc.sum_int += number
			}
		case "array_agg":
			append(&acc.list, value_clone(value, context.allocator))
		case "group_concat", "string_agg":
			if !acc.has_text {
				if acc.builder.buf == nil do strings.builder_init(&acc.builder, context.allocator)
				acc.separator = ","
				if len(acc.call.args) == 2 {
					separator_value, sep_err := eval_expr(row_ctx, acc.call.args[1])
					if sep_err.kind != .None do return sep_err
					if separator_value.kind != .Null {
						acc.separator = value_format(separator_value, context.allocator)
						acc.sep_owned = true
					}
				}
				acc.has_text = true
			} else if len(acc.separator) > 0 {
				strings.write_string(&acc.builder, acc.separator)
			}
			piece := value_format(value, context.allocator)
			strings.write_string(&acc.builder, piece)
			delete(piece)
		}
	}
	return ERROR_NONE
}

@(private)
agg_stream_value :: proc(acc: ^Agg_Acc) -> (Value, Error) {
	switch acc.name {
	case "count":
		return value_int(i64(acc.seen)), ERROR_NONE
	case "min", "max":
		return value_clone(acc.best, context.allocator), ERROR_NONE
	case "sum", "total":
		if acc.seen == 0 do return value_null(), ERROR_NONE
		if acc.uses_float do return value_float(acc.sum_float), ERROR_NONE
		if acc.uses_128 do return value_int128(acc.sum_128), ERROR_NONE
		return value_int(acc.sum_int), ERROR_NONE
	case "avg":
		if acc.seen == 0 do return value_null(), ERROR_NONE
		total := acc.uses_float ? acc.sum_float : (acc.uses_128 ? f64(acc.sum_128) : f64(acc.sum_int))
		return value_float(total / f64(acc.seen)), ERROR_NONE
	case "group_concat", "string_agg":
		if !acc.has_text do return value_null(), ERROR_NONE
		return value_string(strings.clone(strings.to_string(acc.builder))), ERROR_NONE
	case "array_agg":
		if len(acc.list) == 0 do return value_null(), ERROR_NONE
		items := make([]Value, len(acc.list))
		for item, i in acc.list do items[i] = value_clone(item, context.allocator)
		return Value{kind = .Array, list = items}, ERROR_NONE
	}
	return {}, errf(.Internal, "unknown aggregate %s", acc.name)
}

Stream_Scan_Ctx :: struct {
	tx:       ^Tx,
	stmt:     ^Select_Stmt,
	params:   []Value,
	expanded: []^Expr,
	policies: ^[dynamic]Policy_Set,
	stream:   ^Agg_Stream,
	aggregate: bool,
	limit:    int,
	offset:   int,
	skipped:  int,
	rows:     ^[dynamic][]Value,
	base:     ^Table,
	alias:    string,
	err:      Error,
	now_us:   i64,
}

@(private)
stream_row_visit :: proc(raw: rawptr, row: Row) -> bool {
	scan := cast(^Stream_Scan_Ctx)raw
	if scan.err.kind != .None do return false
	// The slice lives on this frame: one allocation per row in the transaction
	// arena would make a streamed scan cost the table again in memory.
	one: [1]Source
	one[0] = Source{table = scan.base, row = row, alias = scan.alias}
	ctx := Eval_Ctx {
		tx      = scan.tx,
		sources = one[:],
		params  = scan.params,
		now_us  = scan.now_us,
	}
	for &set in scan.policies^ {
		allowed, policy_err := policy_allows(&set, &ctx, false)
		if policy_err.kind != .None {
			scan.err = policy_err
			return false
		}
		if !allowed do return true
	}
	if scan.stmt.where_clause != nil {
		value, where_err := eval_expr(&ctx, scan.stmt.where_clause)
		if where_err.kind != .None {
			scan.err = where_err
			return false
		}
		if !value_is_truthy(value) do return true
	}
	scan.tx.rows_scanned += 1
	if scan.aggregate {
		if !scan.stream.have_first {
			// The accumulator outlives the row arena, so the row is cloned with
			// the same allocator the stream is destroyed with.
			clones := make([]Value, len(row.values))
			for value, i in row.values do clones[i] = value_clone(value, context.allocator)
			scan.stream.first_values = clones
			scan.stream.first_id = row.id
			scan.stream.have_first = true
		}
		if add_err := agg_stream_add(&ctx, scan.stream); add_err.kind != .None {
			scan.err = add_err
			return false
		}
		return true
	}
	if scan.limit == 0 do return false
	values := make([]Value, len(scan.expanded))
	for expr, i in scan.expanded {
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None {
			free_values(values[:i])
			scan.err = eval_err
			return false
		}
		values[i] = value_clone(value, context.allocator)
	}
	if scan.skipped < scan.offset {
		scan.skipped += 1
		free_values(values)
		return true
	}
	append(scan.rows, values)
	return !(scan.limit >= 0 && len(scan.rows^) >= scan.limit)
}

// sql_exec_stream_select answers the shapes a page scan can stream: one paged
// table, no join, no ORDER BY, no GROUP BY, no DISTINCT, no window and nothing
// staged in the transaction. Rows are filtered and projected as they leave the
// pages, so the table never sits in memory; LIMIT stops the scan early. When the
// first aggregate is not a plain projection call the query falls back to the
// materializing path (handled is false).
@(private)
sql_exec_stream_select :: proc(
	tx: ^Tx,
	stmt: Select_Stmt,
	params: []Value,
	base: ^Table,
	base_is_view: bool,
	system_name: bool,
) -> (result: Sql_Result, handled: bool, err: Error) {
	if base == nil || base.paged == nil || base_is_view || system_name do return {}, false, ERROR_NONE
	if len(stmt.joins) != 0 || len(stmt.group_by) != 0 || len(stmt.order_by) != 0 do return {}, false, ERROR_NONE
	if stmt.is_distinct || stmt.having != nil || stmt.from.as_of != nil do return {}, false, ERROR_NONE
	if tx.state.dropped[stmt.from.name] do return {}, false, ERROR_NONE
	if writes, has := tx.state.writes[stmt.from.name]; has {
		if writes.truncated ||
		   len(writes.inserts) > 0 ||
		   len(writes.updates) > 0 ||
		   len(writes.deletes) > 0 {
			return {}, false, ERROR_NONE
		}
	}
	// An index answers a point or range query with a handful of rows, which is
	// cheaper than walking every page. The probe is the same one the main path
	// runs; only the answer is used here.
	if ids, indexed := index_candidates(tx, base, stmt.from.name, stmt.from.alias, stmt.where_clause, params); indexed {
		delete(ids)
		return {}, false, ERROR_NONE
	}

	now_us := now_microseconds()
	statement := stmt
	stream := Agg_Stream{}
	defer agg_stream_destroy(&stream)
	probe := make([]Source, 1, tx.alloc)
	probe[0] = Source{table = base, alias = stmt.from.alias}
	columns := make([dynamic]string, 0, len(stmt.projections), tx.alloc)
	expanded := expand_projections(probe, stmt.joins, stmt.projections, &columns, tx.alloc)
	if len(expanded) == 0 do return {}, false, ERROR_NONE
	aggregate := false
	for expr in expanded {
		if _, is_window := expr^.(Window_Expr); is_window do return {}, false, ERROR_NONE
		if !expr_is_aggregate(expr) do continue
		call, direct := expr^.(Call_Expr)
		if !direct || !is_aggregate_name(call.name) || call.is_distinct {
			return {}, false, ERROR_NONE
		}
		if len(call.args) > 2 {
			return {}, false, ERROR_NONE
		}
		if len(call.args) == 2 {
			// Only group_concat/string_agg take a second argument.
			if !strings.equal_fold(call.name, "group_concat") &&
			   !strings.equal_fold(call.name, "string_agg") {
				return {}, false, ERROR_NONE
			}
		}
		if strings.equal_fold(call.name, "json_group_array") ||
		   strings.equal_fold(call.name, "json_group_object") ||
		   strings.equal_fold(call.name, "median") ||
		   strings.equal_fold(call.name, "percentile") ||
		   strings.equal_fold(call.name, "percentile_cont") ||
		   strings.equal_fold(call.name, "percentile_disc") {
			// The streaming path folds one value per row; these build a document
			// from the whole group, so the materializing path answers them.
			return {}, false, ERROR_NONE
		}
		aggregate = true
		acc := Agg_Acc{call = call, name = strings.to_lower(call.name), fold_distinct = call.is_distinct}
		if acc.fold_distinct do acc.keys = make(map[string]bool)
		append(&stream.accs, acc)
	}

	limit := -1
	offset := 0
	if stmt.offset != nil {
		value, value_err := eval_expr(&Eval_Ctx{tx = tx, params = params, now_us = now_us}, stmt.offset)
		if value_err.kind != .None do return {}, false, value_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 do return {}, false, errf(.Invalid_Argument, "OFFSET must be a non-negative integer")
		offset = int(parsed)
	}
	if stmt.limit != nil {
		value, value_err := eval_expr(&Eval_Ctx{tx = tx, params = params, now_us = now_us}, stmt.limit)
		if value_err.kind != .None do return {}, false, value_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 do return {}, false, errf(.Invalid_Argument, "LIMIT must be a non-negative integer")
		limit = int(parsed)
	}

	policies := make([dynamic]Policy_Set)
	defer policy_sets_destroy(&policies)
	if !is_system_table(stmt.from.name) {
		set, policy_err := policy_load(tx, stmt.from.name)
		if policy_err.kind != .None do return {}, false, policy_err
		append(&policies, set)
	}

	rows := make([dynamic][]Value)
	defer {
		if err.kind != .None {
			for row in rows do free_values(row)
		}
		delete(rows)
	}
	scan_ctx := Stream_Scan_Ctx {
		tx        = tx,
		stmt      = &statement,
		params    = params,
		expanded  = expanded,
		policies  = &policies,
		stream    = &stream,
		aggregate = aggregate,
		limit     = limit,
		offset    = offset,
		rows      = &rows,
		base      = base,
		alias     = stmt.from.alias,
		now_us    = now_us,
	}
	if scan_err := tx_scan_visit(tx, stmt.from.name, &scan_ctx, stream_row_visit); scan_err.kind != .None {
		return {}, false, scan_err
	}
	if scan_ctx.err.kind != .None do return {}, false, scan_ctx.err

	// One aggregate row is still subject to OFFSET and LIMIT, the same way the
	// materializing path cuts the single row it built.
	if aggregate && offset == 0 && limit != 0 {
		final := Eval_Ctx{tx = tx, params = params, now_us = now_us, stream = &stream}
		if stream.have_first {
			final.sources = make([]Source, 1, tx.alloc)
			final.sources[0] = Source {
				table = base,
				row   = Row{id = stream.first_id, values = stream.first_values},
				alias = stmt.from.alias,
			}
		}
		values := make([]Value, len(expanded))
		for expr, i in expanded {
			value, eval_err := eval_expr(&final, expr)
			if eval_err.kind != .None {
				free_values(values[:i])
				return {}, false, eval_err
			}
			values[i] = value_clone(value, context.allocator)
		}
		append(&rows, values)
	}

	out := Sql_Result{kind = .Rows}
	out.columns = make([]string, len(columns))
	for column, i in columns do out.columns[i] = strings.clone(column)
	out.rows = make([][]Value, len(rows))
	copy(out.rows, rows[:])
	resize(&rows, 0)
	out.row_ids = make([]Row_Id, len(out.rows))
	for row in out.rows {
		for value in row do out.row_bytes += value_wire_size(value)
	}
	if quota := tx.store.max_rows_per_query; quota > 0 && u64(len(out.rows)) > quota {
		sql_result_destroy(&out)
		return {}, false, errf(.Quota_Exceeded, "query returns more than %d rows", quota)
	}
	// A statement is a unit of work: the host budget and the statement counter
	// see the same row count the materializing path reports.
	tx.store.stream_scans += 1
	return out, true, ERROR_NONE
}

sql_exec_select :: proc(tx: ^Tx, stmt: Select_Stmt, params: []Value) -> (Sql_Result, Error) {
	// Derived tables are materialized first, under their names, for this select.
	if stmt.from.subquery != nil || select_has_derived_join(stmt) {
		scope := cte_scope_begin(tx)
		defer cte_scope_end(tx, &scope)
		refs := make([dynamic]Table_Ref, 0, 1 + len(stmt.joins), tx.alloc)
		append(&refs, stmt.from)
		for join in stmt.joins do append(&refs, join.table)
		for ref in refs {
			// A LATERAL derived table is not materialized here: it is evaluated
			// once per row of the sources to its left, in the join loop.
			if ref.subquery == nil || ref.lateral do continue
			table, derived_err := tx_materialize_cte(tx, Cte{name = ref.name, select_stmt = ref.subquery^}, params, false)
			if derived_err.kind != .None do return {}, derived_err
			cte_scope_bind(tx, &scope, ref.name, table)
		}
		inner := stmt
		inner.from.subquery = nil
		inner.joins = make([]Join_Clause, len(stmt.joins), tx.alloc)
		for join, i in stmt.joins {
			inner.joins[i] = join
			inner.joins[i].table.subquery = nil
		}
		return sql_exec_select(tx, inner, params)
	}
	if len(stmt.compound) > 0 do return sql_exec_compound(tx, stmt, params)
	// A collation the statement cannot honour is refused before a row exists: an
	// unknown name, or a host comparison where a folded key is required.
	if guard_err := select_collation_guard(tx, stmt); guard_err.kind != .None do return {}, guard_err
	// The planner may run the relations of a join in another order. The output
	// order of `SELECT *` stays the written one (star_sources below reads the
	// statement), so only what is executed moves.
	exec := stmt
	order := plan_join_order(tx.store, tx, stmt, params)
	if order.reordered {
		exec.from = order.from
		exec.joins = order.joins
	}
	// A SELECT without FROM evaluates its projections once against an empty row.
	// System tables are synthesized from the catalog instead of being scanned.
	empty_row := len(exec.from.name) == 0
	system_name := is_system_table(exec.from.name)
	synthetic: Table
	base: ^Table
	base_is_view := false
	if !empty_row && !system_name {
		base_args, args_err := view_args(tx, exec.from, params)
		if args_err.kind != .None do return {}, args_err
		source_table, source_view, table_err := tx_source_table(
			tx,
			exec.from.name,
			base_args,
			exec.from.schema,
		)
		if table_err.kind != .None do return {}, table_err
		base = source_table
		base_is_view = source_view
	}
	if system_name do base = &synthetic
	ctx := Eval_Ctx {
		tx     = tx,
		params = params,
		now_us = now_microseconds(),
		outer  = tx.outer,
	}

	// A page-backed table can answer a simple single-table query without ever
	// holding it in memory: the scan streams, the projection runs per row and
	// LIMIT stops the scan. Anything the stream cannot answer exactly falls
	// through to the materializing path below.
	if stream_result, streamed, stream_err := sql_exec_stream_select(
		tx,
		stmt,
		params,
		base,
		base_is_view,
		system_name,
	); streamed {
		return stream_result, stream_err
	}

	// Row-level policies load once per statement. A denied row never reaches the
	// projection, an aggregate or the join output. They load before the join
	// because they also decide whether LIMIT can stop the scan (D23).
	policies := make([dynamic]Policy_Set)
	defer policy_sets_destroy(&policies)
	policy_tables := make([dynamic]string)
	defer delete(policy_tables)
	append(&policy_tables, stmt.from.name)
	for join in stmt.joins do append(&policy_tables, join.table.name)
	has_policies := false
	for name in policy_tables {
		if len(name) == 0 || is_system_table(name) do continue
		set, policy_err := policy_load(tx, name)
		if policy_err.kind != .None do return {}, policy_err
		if len(set.using_exprs) > 0 do has_policies = true
		append(&policies, set)
	}

	// LIMIT n, on a statement that neither filters nor shrinks, means the scan can
	// stop as soon as it has n rows: nothing later in the scan can appear in the
	// answer. Zero means no pushdown (D23).
	limit_rows := 0
	if stmt.where_clause == nil && !has_policies && len(stmt.order_by) == 0 &&
	   !select_output_may_shrink(stmt) {
		limit_rows = select_row_limit(stmt, params)
	}

	// Base rows. A usable index narrows the scan; the WHERE clause is still
	// re-checked below.
	partials := make([dynamic][]Source)
	used_index := false
	if system_name {
		synthetic.schema = system_table_schema(exec.from.name, tx.alloc)
		catalog_rows := system_table_rows(tx, exec.from.name, tx.alloc)
		for row in catalog_rows {
			// The source slice is freed by the filter below, so it cannot come
			// from the transaction arena (the row values inside still do: they
			// are only read, never freed here).
			one := make([]Source, 1)
			one[0] = Source{table = base, row = row, alias = exec.from.alias}
			append(&partials, one)
		}
		used_index = true
	}
	if empty_row {
		append(&partials, make([]Source, 0))
		used_index = true
	}
	// A historical read asks for the rows as they were at one commit. It cannot
	// use an index (the keys of that commit are not the live ones) and it ignores
	// the staged writes: it reads what committed.
	as_of_seq: u64 = 0
	if exec.from.as_of != nil {
		if base_is_view {
			return {}, errf(.Sql_Unsupported, "AS OF reads a table, not a view")
		}
		moment, constant := eval_constant(exec.from.as_of, params)
		if !constant {
			return {}, errf(.Invalid_Argument, "AS OF needs a constant commit sequence")
		}
		sequence, ok := value_to_i64(moment)
		if !ok || sequence < 0 {
			return {}, errf(.Invalid_Argument, "AS OF needs a non-negative commit sequence")
		}
		as_of_seq = u64(sequence)
		if as_of_seq > tx.store.commit_seq do as_of_seq = tx.store.commit_seq
	}
	// An index that matches the ORDER BY hands the rows over in order, so the sort
	// that follows has nothing to do.
	ordered_ids: [dynamic]Row_Id
	ordered := false
	if !base_is_view && !empty_row && as_of_seq == 0 && !system_name {
		if index, descending, ordered_ok := index_order_for(tx, base, exec.from, stmt); ordered_ok {
			// LIMIT lets the walk stop as soon as it has the rows the statement can
			// use, but only when nothing else can drop one: a filter or a policy is
			// applied after the walk, so it would leave the answer short.
			stop := 0
			if stmt.where_clause == nil && !select_filters_rows(tx, exec.from.name) {
				stop = select_row_limit(stmt, params)
			}
			ordered_ids = index_order_ids(base, index, descending, stop)
			ordered = true
			exec.order_by = nil
		}
	}
	if ordered {
		defer delete(ordered_ids)
		for id in ordered_ids {
			tx.rows_scanned += 1
			if row, exists := tx_get(tx, exec.from.name, id); exists {
				one := make([]Source, 1)
				one[0] = Source{table = base, row = row, alias = exec.from.alias}
				append(&partials, one)
			}
		}
		used_index = true
	}
	// A view already holds a materialized table: scan it directly.
	if !base_is_view && !empty_row && as_of_seq == 0 && !ordered {
		if candidate_ids, used, fts_err := fts_scan_candidates(
			tx,
			exec.from.name,
			exec.from.alias,
			stmt.where_clause,
			params,
		); used {
			if fts_err.kind != .None {
				free_partials(&partials)
				return {}, fts_err
			}
			defer delete(candidate_ids)
			for id in candidate_ids {
				tx.rows_scanned += 1
				if row, exists := tx_get(tx, exec.from.name, id); exists {
					one := make([]Source, 1)
					one[0] = Source{table = base, row = row, alias = exec.from.alias}
					append(&partials, one)
				}
			}
			used_index = true
		} else if indexed_ids, indexed := index_candidates(tx, base, exec.from.name, exec.from.alias, stmt.where_clause, params); indexed {
			defer delete(indexed_ids)
			for id in indexed_ids {
				tx.rows_scanned += 1
				if row, exists := tx_get(tx, exec.from.name, id); exists {
					one := make([]Source, 1)
					one[0] = Source{table = base, row = row, alias = exec.from.alias}
					append(&partials, one)
				}
			}
			used_index = true
		}
	}
	if !used_index {
		rows := make([dynamic]Row)
		if base_is_view {
			table_collect(base, &rows, tx.read_seq)
		} else if as_of_seq > 0 {
			if collect_err := tx_collect_at(tx, exec.from.name, &rows, as_of_seq); collect_err.kind != .None {
				return {}, collect_err
			}
		} else if collect_err := tx_collect(tx, exec.from.name, &rows); collect_err.kind != .None {
			return {}, collect_err
		}
		for row in rows {
			tx.rows_scanned += 1
			one := make([]Source, 1)
			one[0] = Source{table = base, row = row, alias = exec.from.alias}
			append(&partials, one)
			if limit_rows > 0 && len(partials) >= limit_rows do break
		}
		delete(rows)
	}
	if !empty_row && !ordered {
		slice.sort_by(partials[:], proc(a, b: []Source) -> bool {
			return u64(a[0].row.id) < u64(b[0].row.id)
		})
	}

	// Nested-loop joins. Each partial is one bound combination of rows, and each
	// step carries the ON conditions that become answerable when it runs (which is
	// what lets the planner move a relation ahead of the join it was written in).
	join_counts_quota := !select_output_may_shrink(stmt)
	// The tables and aliases bound so far, so a RIGHT or FULL join can build a
	// row whose left side is NULL: every column of those sources is absent,
	// which is what the outer side of a join means.
	bound_tables := make([dynamic]^Table, 0, len(order.steps))
	bound_aliases := make([dynamic]string, 0, len(order.steps))
	defer {
		delete(bound_tables)
		delete(bound_aliases)
	}
	append(&bound_tables, base)
	append(&bound_aliases, exec.from.alias)
	for step, step_index in order.steps[1:] {
		// Only the last step can stop early: the rows it drops are rows later
		// steps would have joined.
		stop_at_limit := limit_rows > 0 && step_index == len(order.steps) - 2
		if step.ref.as_of != nil {
			free_partials(&partials)
			return {}, errf(.Sql_Unsupported, "AS OF is only supported on the first table of a join")
		}
		// A JSON table function may take a column of the table before it, so it
		// is materialized once per outer row (a lateral join). Everything else is
		// collected once. The materialized tables stay in tx.temp_tables until the
		// statement ends, because the rows the join reads point into them.
		lateral := is_json_table_function(step.ref.name) ||
			(step.ref.lateral && step.ref.subquery != nil)
		if lateral && (step.kind == .Right || step.kind == .Full) {
			free_partials(&partials)
			return {}, errf(
				.Sql_Unsupported,
				"a RIGHT or FULL join cannot take a table function that depends on the row before it",
			)
		}
		table: ^Table
		join_is_view: bool
		rows := make([dynamic]Row)
		if !lateral {
			join_args, join_args_err := view_args(tx, step.ref, params)
			if join_args_err.kind != .None {
				free_partials(&partials)
				return {}, join_args_err
			}
			resolved, resolved_is_view, join_err := tx_source_table(
				tx,
				step.ref.name,
				join_args,
				step.ref.schema,
			)
			if join_err.kind != .None {
				free_partials(&partials)
				return {}, join_err
			}
			table = resolved
			join_is_view = resolved_is_view
			if join_is_view {
				table_collect(table, &rows, tx.read_seq)
			} else if collect_err := tx_collect(tx, step.ref.name, &rows); collect_err.kind != .None {
				free_partials(&partials)
				return {}, collect_err
			}
		}
		// The inner side is probed when its ON clause binds a column that leads an
		// index: a nested loop then reads the rows the outer row matches instead
		// of the whole relation, once per outer row.
		probe: Index_Probe
		probe.index = -1
		if !lateral && !join_is_view {
			_, staged := tx.state.writes[step.ref.name]
			_, created := tx.state.created[step.ref.name]
			if !staged && !created {
				probe, _ = join_index_probe(table, step.ref.alias, step.predicate)
			}
		}
		next := make([dynamic][]Source)
		// A RIGHT or FULL join keeps a row of the inner side that nothing
		// matched, so the step remembers which rows those were.
		kept_inner: []bool
		if step.kind == .Right || step.kind == .Full {
			kept_inner = make([]bool, len(rows))
		}
		defer delete(kept_inner)
		for partial in partials {
			if store_cancelled(tx.store) {
				delete(rows)
				free_partials(&partials)
				free_partials(&next)
				return {}, errf(.Cancelled, "query cancelled")
			}
			lateral_rows := rows
			probe_rows: [dynamic]Row
			using_probe := false
			if probe.index >= 0 && step.kind != .Right && step.kind != .Full {
				if candidates, probed := join_probe_rows(
					tx,
					table,
					step.ref.name,
					probe,
					partial,
					&ctx,
				); probed {
					probe_rows = candidates
					lateral_rows = probe_rows
					using_probe = true
				}
			}
			if lateral && step.ref.subquery != nil {
				lateral_table, lateral_err := tx_materialize_lateral(tx, step.ref, params, partial)
				if lateral_err.kind != .None {
					free_partials(&partials)
					free_partials(&next)
					return {}, lateral_err
				}
				table = lateral_table
				lateral_rows = make([dynamic]Row)
				table_collect(lateral_table, &lateral_rows, tx.read_seq)
			} else if lateral {
				lateral_args, lateral_args_err := view_args(tx, step.ref, params, partial)
				if lateral_args_err.kind != .None {
					free_partials(&partials)
					free_partials(&next)
					return {}, lateral_args_err
				}
				lateral_table, _, lateral_err := tx_source_table(
					tx,
					step.ref.name,
					lateral_args,
					step.ref.schema,
				)
				if lateral_err.kind != .None {
					free_partials(&partials)
					free_partials(&next)
					return {}, lateral_err
				}
				table = lateral_table
				lateral_rows = make([dynamic]Row)
				table_collect(lateral_table, &lateral_rows, tx.read_seq)
			}
			matched := false
			for row, row_index in lateral_rows {
				tx.rows_scanned += 1
				candidate := make([]Source, len(partial) + 1)
				copy(candidate, partial)
				candidate[len(partial)] = Source{table = table, row = row, alias = step.ref.alias}
				if step.predicate != nil {
					ctx.sources = candidate
					value, eval_err := eval_expr(&ctx, step.predicate)
					if eval_err.kind != .None {
						delete(candidate)
						delete(rows)
						free_partials(&partials)
						free_partials(&next)
						return {}, eval_err
					}
					if !value_is_truthy(value) {
						delete(candidate)
						continue
					}
				}
				append(&next, candidate)
				matched = true
				if kept_inner != nil do kept_inner[row_index] = true
				if stop_at_limit && len(next) >= limit_rows do break
				if join_counts_quota && quota_reached(tx, len(next)) {
					// A cross join materialises its intermediate before the
					// projection can count anything, so the quota has to fire
					// here: the rows being produced are the rows the query asked
					// for (D23).
					if lateral do delete(lateral_rows)
					if using_probe do delete(probe_rows)
					delete(rows)
					free_partials(&partials)
					free_partials(&next)
					return {}, errf(
						.Quota_Exceeded,
						"query builds more than %d rows",
						tx.store.max_rows_per_query,
					)
				}
			}
			if (step.kind == .Left || step.kind == .Full) && !matched {
				candidate := make([]Source, len(partial) + 1)
				copy(candidate, partial)
				candidate[len(partial)] = Source{table = table, row = Row{}, alias = step.ref.alias}
				append(&next, candidate)
			}
			if lateral do delete(lateral_rows)
			if using_probe do delete(probe_rows)
			if stop_at_limit && len(next) >= limit_rows do break
		}
		// The other half of an outer join: every row of the inner side that no
		// left row matched answers with the left columns NULL.
		if step.kind == .Right || step.kind == .Full {
			for row, row_index in rows {
				if kept_inner[row_index] do continue
				candidate := make([]Source, len(bound_tables) + 1)
				for bound, i in bound_tables {
					candidate[i] = Source{table = bound, row = Row{}, alias = bound_aliases[i]}
				}
				candidate[len(bound_tables)] = Source{table = table, row = row, alias = step.ref.alias}
				append(&next, candidate)
				if stop_at_limit && len(next) >= limit_rows do break
				if join_counts_quota && quota_reached(tx, len(next)) {
					delete(rows)
					free_partials(&partials)
					free_partials(&next)
					return {}, errf(
						.Quota_Exceeded,
						"query builds more than %d rows",
						tx.store.max_rows_per_query,
					)
				}
			}
		}
		append(&bound_tables, table)
		append(&bound_aliases, step.ref.alias)
		delete(rows)
		free_partials(&partials)
		partials = next
	}

	// WHERE
	filtered := make([dynamic][]Source)
	for partial, index in partials {
		if store_cancelled(tx.store) {
			// The rows before this one were either kept (and freed through
			// filtered) or freed in place, so only the pending ones are left.
			for pending in partials[index:] do delete(pending)
			for kept in filtered do delete(kept)
			delete(partials)
			delete(filtered)
			return {}, errf(.Cancelled, "query cancelled")
		}
		keep := true
		ctx.sources = partial
		for &set in policies {
			allowed, policy_err := policy_allows(&set, &ctx, false)
			if policy_err.kind != .None {
				for pending in partials[index:] do delete(pending)
				for kept in filtered do delete(kept)
				delete(partials)
				delete(filtered)
				return {}, policy_err
			}
			if !allowed {
				keep = false
				break
			}
		}
		if keep && stmt.where_clause != nil {
			value, eval_err := eval_expr(&ctx, stmt.where_clause)
			if eval_err.kind != .None {
				// A rejected row frees its sources in place, so the pending
				// ones and the kept ones are all that is left.
				for pending in partials[index:] do delete(pending)
				for kept in filtered do delete(kept)
				delete(partials)
				delete(filtered)
				return {}, eval_err
			}
			keep = value_is_truthy(value)
		}
		if keep {
			append(&filtered, partial)
		} else {
			delete(partial)
		}
	}
	delete(partials)

	// The written order, not the execution order: `SELECT *` must emit columns in
	// the order the query asked for, and a projection resolves names, not slots. The
	// first source is therefore resolved from the statement: `base` follows the
	// plan, which may have started at a different relation.
	star_sources := make([dynamic]Source)
	if !empty_row {
		from_table := base
		if !system_name && !strings.equal_fold(stmt.from.name, exec.from.name) {
			from_args, from_args_err := view_args(tx, stmt.from, params)
			if from_args_err.kind == .None {
				resolved, _, resolve_err := tx_source_table(
					tx,
					stmt.from.name,
					from_args,
					stmt.from.schema,
				)
				if resolve_err.kind == .None do from_table = resolved
			}
		}
		append(&star_sources, Source{table = from_table, alias = stmt.from.alias})
	}
	for join in stmt.joins {
		if table, ok := tx_table(tx, join.table.name); ok.kind == .None {
			append(&star_sources, Source{table = table, alias = join.table.alias})
		}
	}
	columns := make([dynamic]string, 0, len(stmt.projections))
	expanded := expand_projections(star_sources[:], stmt.joins, stmt.projections, &columns, tx.alloc)
	// The GROUP BY list is resolved here, while the sources are still around: it
	// may name a projection alias, and telling an alias from a column needs them.
	group_exprs := group_by_expressions(stmt, star_sources[:], tx.alloc)
	delete(star_sources)
	if len(expanded) == 0 {
		free_partials(&filtered)
		return {}, errf(.Invalid_Argument, "SELECT has no projection")
	}

	aggregate := len(stmt.group_by) > 0
	if !aggregate {
		for expr in expanded {
			if expr_is_aggregate(expr) {
				aggregate = true
				break
			}
		}
	}
	if stmt.having != nil && !aggregate {
		free_partials(&filtered)
		return {}, errf(.Sql_Unsupported, "HAVING needs GROUP BY or an aggregate")
	}
	window_positions := window_positions_of(expanded)
	defer delete(window_positions)
	// A window can also sit inside a larger projection, `sum(n) OVER () + 1`: its
	// answer then needs a slot of its own, behind the visible columns, and the
	// projection is evaluated after the windows are filled.
	nested_windows := make([dynamic]^Expr)
	for expr in expanded {
		if _, top := expr^.(Window_Expr); top do continue
		expr_collect_windows(expr, &nested_windows)
	}
	defer delete(nested_windows)
	has_windows := len(window_positions) > 0 || len(nested_windows) > 0
	// window_nodes is every window that needs filling, in cell order: the top-level
	// ones first (their slot is the projection index), then the nested ones (their
	// slot is behind the visible columns).
	window_nodes := make([dynamic]^Expr, 0, len(window_positions) + len(nested_windows))
	window_slot_list := make([dynamic]int, 0, len(window_positions) + len(nested_windows))
	window_slots := make(map[^Expr]int)
	defer {
		delete(window_nodes)
		delete(window_slot_list)
		delete(window_slots)
	}
	// needs_outer marks a projection that has to be evaluated once its windows are
	// filled, because evaluating it earlier would reach an unfilled window.
	needs_outer := make([]bool, len(expanded))
	defer delete(needs_outer)
	// Two passes, so a slot does not depend on the order the projections are walked:
	// every nested window is numbered behind the visible columns first, then the
	// list is built top-level windows first, nested ones after.
	for expr, position in expanded {
		if _, top := expr^.(Window_Expr); top {
			append(&window_nodes, expr)
			append(&window_slot_list, position)
			window_slots[expr] = position
			continue
		}
		inner := make([dynamic]^Expr)
		expr_collect_windows(expr, &inner)
		if len(inner) == 0 {
			delete(inner)
			continue
		}
		needs_outer[position] = true
		for node in inner {
			slot := len(expanded) + len(nested_windows)
			append(&nested_windows, node)
			append(&window_nodes, node)
			append(&window_slot_list, slot)
			window_slots[node] = slot
		}
		delete(inner)
	}
	if has_windows && aggregate {
		// A window reads its ORDER BY value once per partition to place a RANGE
		// frame, and beside GROUP BY that value may be an aggregate, which needs the
		// group rather than a row: the group is gone by the time a window is filled.
		// Every other frame shape reads keys that were captured per group.
		for node in window_nodes {
			window := node^.(Window_Expr)
			if window_frame_reads_values(window.frame) {
				free_partials(&filtered)
				return {}, errf(
					.Sql_Unsupported,
					"a RANGE frame with an offset beside GROUP BY is not supported",
				)
			}
		}
	}
	window_cells := make([dynamic][dynamic]Window_Cell, 0, len(filtered))
	window_sources := make([dynamic][]Source, 0, len(filtered))
	// group_keep holds the groups whose windows are still pending: a grouped row
	// has no source behind it, and rebuilding its ORDER BY key after the windows
	// need the group the row came from.
	group_keep := make([dynamic][dynamic][]Source, 0, len(filtered))

	output := make([dynamic]Output_Row, 0, len(filtered))
	if aggregate {
		groups := make([dynamic][dynamic][]Source)
		// group_set_of says which set each group came from, so its row knows which
		// columns the set left out.
		group_set_of := make([dynamic]int)
		sets := select_group_sets(stmt, tx.alloc)
		if len(stmt.group_by) == 0 {
			group := make([dynamic][]Source, 0, len(filtered))
			for partial in filtered do append(&group, partial)
			append(&groups, group)
			append(&group_set_of, -1)
		} else {
			for set, set_index in sets {
				buckets := make(map[string][dynamic][]Source)
				keys := make([dynamic]string)
				// `SELECT dept AS d ... GROUP BY d` groups by what the projection
				// names; a name that is a column of a source still means the column.
				for partial in filtered {
					ctx.sources = partial
					w: Byte_Writer
					bw_init(&w)
					group_ok := true
					for expr_index in set {
						value, eval_err := eval_expr(&ctx, group_exprs[expr_index])
						if eval_err.kind != .None {
							bw_destroy(&w)
							group_ok = false
							break
						}
						value_encode_key(&w, value)
					}
					if !group_ok {
						for key in keys do delete(key)
						delete(keys)
						delete(buckets)
						free_partials(&filtered)
						return {}, errf(.Invalid_Type, "GROUP BY expression failed")
					}
					key := strings.clone(string(bw_bytes(&w)))
					bw_destroy(&w)
					bucket, exists := buckets[key]
					if !exists do append(&keys, key)
					append(&bucket, partial)
					buckets[key] = bucket
				}
				slice.sort_by(keys[:], proc(a, b: string) -> bool {
					return strings.compare(a, b) < 0
				})
				for key in keys {
					append(&groups, buckets[key])
					append(&group_set_of, set_index)
					delete(key)
				}
				delete(keys)
				delete(buckets)
			}
		}
		for group, group_number in groups {
			ctx.group = group[:]
			ctx.grouped = true
			ctx.grouping_exprs = group_exprs
			if set_index := group_set_of[group_number]; set_index >= 0 {
				ctx.grouping_missing = grouping_missing_for(sets[set_index], len(stmt.group_by), tx.alloc)
			} else {
				ctx.grouping_missing = nil
			}
			if len(group) > 0 {
				ctx.sources = group[0]
			} else {
				ctx.sources = nil
			}
			cells, cells_err := window_row_cells(&ctx, window_nodes[:], has_windows)
			if cells_err.kind != .None {
				free_values_over_rows(&output)
				window_cell_rows_destroy(&window_cells)
				for kept in group_keep do delete(kept)
				delete(group_keep)
				free_partials(&filtered)
				return {}, cells_err
			}
			values := make([]Value, len(expanded) + len(nested_windows))
			for expr, i in expanded {
				// A top-level window, or a projection whose windows are still
				// unfilled, is a null here and is written after apply_windows.
				if needs_outer[i] || (has_windows && window_cell_for(window_positions, i) >= 0) {
					values[i] = value_null()
					continue
				}
				value, eval_err := eval_expr(&ctx, expr)
				if eval_err.kind != .None {
					free_values(values)
					window_cells_destroy(cells)
					free_values_over_rows(&output)
					window_cell_rows_destroy(&window_cells)
					for kept in group_keep do delete(kept)
					delete(group_keep)
					free_partials(&filtered)
					return {}, eval_err
				}
				values[i] = value_clone(value, context.allocator)
			}
			if stmt.having != nil {
				having, having_err := eval_expr(&ctx, stmt.having)
				if having_err.kind != .None {
					free_values(values)
					window_cells_destroy(cells)
					free_values_over_rows(&output)
					window_cell_rows_destroy(&window_cells)
					for kept in group_keep do delete(kept)
					delete(group_keep)
					free_partials(&filtered)
					return {}, having_err
				}
				if !value_is_truthy(having) {
					free_values(values)
					window_cells_destroy(cells)
					delete(group)
					continue
				}
			}
			// A group has no row behind it: every group key answers the same
			// tiebreak, which is what "unspecified order among equal groups" means.
			// With a window in the projection the keys are rebuilt once the window
			// values exist, which is why the group is kept.
			sort_key: []u8
			if !has_windows {
				sort_key = build_order_key(&ctx, stmt.order_by, expanded, values, columns[:], NO_ROW_ID)
			}
			append(
				&output,
				Output_Row{values = values, sort_key = sort_key, row_id = NO_ROW_ID},
			)
			if has_windows {
				append(&window_cells, cells)
				append(&group_keep, group)
			} else {
				ctx.grouped = false
				delete(group)
			}
		}
		delete(groups)
		delete(group_set_of)
		ctx.group = nil
		// A pending window owns its partials: they are freed with the group below.
		if !has_windows {
			for partial in filtered do delete(partial)
		}
	} else {
		for partial, index in filtered {
			ctx.sources = partial
			values := make([]Value, len(expanded) + len(nested_windows))
			cells, cells_err := window_row_cells(&ctx, window_nodes[:], has_windows)
			if cells_err.kind != .None {
				free_values(values)
				free_partials(&filtered)
				return {}, cells_err
			}
			for expr, i in expanded {
				// A top-level window, or a projection whose windows are still
				// unfilled, is a null here and is written after apply_windows.
				if needs_outer[i] || (has_windows && window_cell_for(window_positions, i) >= 0) {
					values[i] = value_null()
					continue
				}
				value, eval_err := eval_expr(&ctx, expr)
				if eval_err.kind != .None {
					free_values(values)
					// Earlier rows already released their sources, so only the
					// pending ones are freed here.
					for pending in filtered[index:] do delete(pending)
					delete(filtered)
					return {}, eval_err
				}
				values[i] = value_clone(value, context.allocator)
			}
			// The row id comes from the sources, which the non-window branch
			// frees below: read it first, never after the delete.
			row_id := len(partial) == 1 ? partial[0].row.id : NO_ROW_ID
			sort_key := build_order_key(&ctx, stmt.order_by, expanded, values, columns[:], row_id)
			if has_windows {
				// The keys are rebuilt once the window values exist, so the
				// sources have to outlive the loop.
				sort_key = nil
				append(&window_cells, cells)
				append(&window_sources, partial)
			} else {
				delete(cells)
				delete(partial)
			}
			append(&output, Output_Row{values = values, sort_key = sort_key, row_id = row_id})
			// A statement with LIMIT or OFFSET bounds its own rows, and it asks
			// for fewer than it produces, so the quota cannot judge it here: the
			// post-check after the projection is the one that applies. Without
			// either, the rows being produced are the answer.
			if stmt.limit == nil && stmt.offset == nil && quota_reached(tx, len(output)) {
				// Stop where the rows appear: the rest of the scan is work the
				// caller has already said it does not want. Neither `values` nor
				// `partial` is freed here: the row was already appended to `output`
				// and the loop below frees what output holds, and the sources went
				// either to the row loop (freed) or to window_sources (freed below).
				// Freeing either a second time corrupts the heap, which a release
				// build reports as exit 116 with no message at all.
				free_values_over_rows(&output)
				window_cell_rows_destroy(&window_cells)
				for pending_sources in window_sources do delete(pending_sources)
				delete(window_sources)
				for kept in group_keep do delete(kept)
				delete(group_keep)
				delete(output)
				delete(filtered)
				return {}, errf(
					.Quota_Exceeded,
					"query returns more than %d rows",
					tx.store.max_rows_per_query,
				)
			}
		}
	}
	delete(filtered)

	if has_windows {
		if window_err := apply_windows(&ctx, window_nodes[:], window_slot_list[:], window_cells[:], output[:], window_sources[:]); window_err.kind != .None {
			free_values_over_rows(&output)
			window_cell_rows_destroy(&window_cells)
			for sources in window_sources do delete(sources)
			delete(window_sources)
			for kept in group_keep do delete(kept)
			delete(group_keep)
			delete(output)
			return {}, window_err
		}
		// A projection that carried a window inside it is evaluated now, with the
		// answers in place: `sum(n) OVER () + 1` reads the slot instead of refusing.
		has_outer := false
		for needed in needs_outer do if needed do has_outer = true
		if has_outer {
			for &row, i in output {
				if aggregate {
					ctx.group = group_keep[i][:]
					ctx.grouped = true
					ctx.sources = len(group_keep[i]) > 0 ? group_keep[i][0] : nil
				} else {
					ctx.sources = window_sources[i]
				}
				ctx.window_slots = window_slots
				ctx.window_values = row.values
				for expr, position in expanded {
					if !needs_outer[position] do continue
					value, eval_err := eval_expr(&ctx, expr)
					if eval_err.kind != .None {
						ctx.window_values = nil
						ctx.window_slots = nil
						ctx.group = nil
						ctx.grouped = false
						ctx.sources = nil
						free_values_over_rows(&output)
						window_cell_rows_destroy(&window_cells)
						for sources in window_sources do delete(sources)
						delete(window_sources)
						for kept in group_keep do delete(kept)
						delete(group_keep)
						delete(output)
						return {}, eval_err
					}
					row.values[position] = value_clone(value, context.allocator)
				}
				ctx.window_values = nil
				ctx.window_slots = nil
			}
			ctx.group = nil
			ctx.grouped = false
			ctx.sources = nil
		}
		// The slots behind the visible columns held the windows' answers for the
		// projections that read them. They are not columns of the result: free
		// them and cut the row back to what the statement projects, before ORDER
		// BY, DISTINCT and the answer are built. `--json` publishes every value a
		// row holds, so leaving them in made `sum(v) OVER () + 1` answer three
		// columns; the table renderer masked the extras with the column count.
		if len(nested_windows) > 0 {
			for &row in output {
				for i := len(expanded); i < len(row.values); i += 1 {
					value_deep_free(row.values[i], context.allocator)
				}
				row.values = row.values[:len(expanded)]
			}
		}
		// ORDER BY runs on the completed rows, so an alias that names a window
		// projection sorts on its value. A grouped row has no source behind it: its
		// group answers, which is what lets `ORDER BY count(*)` beside a window read
		// the aggregate rather than one row of the group.
		for &row, i in output {
			if aggregate {
				ctx.group = group_keep[i][:]
				ctx.grouped = true
				ctx.sources = len(group_keep[i]) > 0 ? group_keep[i][0] : nil
			} else {
				ctx.sources = window_sources[i]
			}
			row.sort_key = build_order_key(&ctx, stmt.order_by, expanded, row.values, columns[:], row.row_id)
		}
		ctx.group = nil
		ctx.grouped = false
		ctx.sources = nil
		window_cell_rows_destroy(&window_cells)
		for sources in window_sources do delete(sources)
		delete(window_sources)
		for kept in group_keep do delete(kept)
		delete(group_keep)
	} else {
		// No window was filled, so none of these took an element: their headers are
		// the only thing left, and they were allocated with the statement.
		delete(window_cells)
		delete(window_sources)
		delete(group_keep)
	}

	if ctx.order_err.kind != .None {
		for row in output {
			free_values(row.values)
			delete(row.sort_key)
		}
		delete(output)
		return {}, ctx.order_err
	}
	if len(stmt.order_by) > 0 {
		slice.sort_by(output[:], proc(a, b: Output_Row) -> bool {
			return string(sort_key_bytes(a.sort_key)) < string(sort_key_bytes(b.sort_key))
		})
	}

	if stmt.is_distinct {
		seen := make(map[string]bool)
		defer delete(seen)
		kept := make([dynamic]Output_Row, 0, len(output))
		for row in output {
			key := encode_output_key(row.values)
			if key in seen {
				delete(key)
				free_values(row.values)
				delete(row.sort_key)
				continue
			}
			seen[key] = true
			append(&kept, row)
		}
		delete(output)
		output = kept
	}

	offset := 0
	limit := -1
	if stmt.offset != nil {
		value, eval_err := eval_expr(&ctx, stmt.offset)
		if eval_err.kind != .None do return {}, eval_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 {
			return {}, errf(.Invalid_Argument, "OFFSET must be a non-negative integer")
		}
		offset = int(parsed)
	}
	if stmt.limit != nil {
		value, eval_err := eval_expr(&ctx, stmt.limit)
		if eval_err.kind != .None do return {}, eval_err
		parsed, ok := value_to_i64(value)
		if !ok || parsed < 0 {
			return {}, errf(.Invalid_Argument, "LIMIT must be a non-negative integer")
		}
		limit = int(parsed)
	}

	result := Sql_Result{kind = .Rows}
	// The projection names live in the transaction arena, and the result
	// outlives the transaction: clone them or the caller prints freed bytes.
	// The names in `columns` are owned by the statement - projection_name clones a
	// name or hands back an allocation - and the result keeps its own copy of each,
	// so both the strings and the array are freed here.
	result.columns = make([]string, len(columns))
	for column, i in columns {
		result.columns[i] = strings.clone(column)
		delete(column)
	}
	delete(columns)
	rows_out := make([dynamic][]Value, 0, len(output))
	ids_out := make([dynamic]Row_Id, 0, len(output))
	for row, i in output {
		delete(row.sort_key)
		if i < offset {
			free_values(row.values)
			continue
		}
		if limit >= 0 && len(rows_out) >= limit {
			free_values(row.values)
			continue
		}
		append(&rows_out, row.values)
		append(&ids_out, row.row_id)
	}
	result.rows = make([][]Value, len(rows_out))
	copy(result.rows, rows_out[:])
	result.row_ids = make([]Row_Id, len(ids_out))
	copy(result.row_ids, ids_out[:])
	delete(rows_out)
	delete(ids_out)
	delete(output)
	for row in result.rows {
		for value in row do result.row_bytes += value_wire_size(value)
	}
	if quota := tx.store.max_rows_per_query; quota > 0 && u64(len(result.rows)) > quota {
		sql_result_destroy(&result)
		return {}, errf(.Quota_Exceeded, "query returns more than %d rows", quota)
	}
	return result, ERROR_NONE
}

Output_Row :: struct {
	values:   []Value,
	sort_key: []u8,
	// row_id is the stored row behind this output row (zero for joins,
	// aggregates and SELECT without FROM).
	row_id:   Row_Id,
}

@(private)
sort_key_bytes :: proc(key: []u8) -> []u8 {
	return key
}

expand_projections :: proc(
	sources: []Source,
	joins: []Join_Clause,
	projections: []Select_Item,
	columns: ^[dynamic]string,
	alloc: mem.Allocator,
) -> []^Expr {
	expanded := make([dynamic]^Expr, 0, len(projections), alloc)
	for item in projections {
		star_qualifier := ""
		is_star := item.star
		if !is_star && item.expr != nil {
			if star, ok := item.expr^.(Star_Expr); ok {
				is_star = true
				star_qualifier = star.table
			}
		}
		if is_star {
			for source, index in sources {
				qualifier := len(source.alias) > 0 ? source.alias : source.table.schema.name
				if len(star_qualifier) > 0 {
					matches := strings.equal_fold(star_qualifier, source.table.schema.name) ||
						(len(source.alias) > 0 && strings.equal_fold(star_qualifier, source.alias))
					if !matches do continue
				}
				// A `JOIN ... USING (c)` merges c: the right side does not repeat
				// it in `SELECT *`. A qualified `b.*` still lists every column of b.
				merged: []string
				if len(star_qualifier) == 0 && index > 0 && index - 1 < len(joins) {
					merged = joins[index - 1].using_columns
				}
				for column in source.table.schema.columns {
					if column_in_names(column.name, merged) do continue
					expr := new(Expr, alloc)
					expr^ = Column_Expr{table = qualifier, name = column.name}
					append(&expanded, expr)
					append(columns, strings.clone(column.name))
				}
			}
			continue
		}
		append(&expanded, item.expr)
		append(columns, projection_name(item))
	}
	return expanded[:]
}

// column_in_names reports whether a column appears in a list of names, the way
// SQL compares them: without case.
@(private)
column_in_names :: proc(name: string, names: []string) -> bool {
	for candidate in names {
		if strings.equal_fold(candidate, name) do return true
	}
	return false
}

@(private)
projection_name :: proc(item: Select_Item) -> string {
	if len(item.alias) > 0 do return strings.clone(item.alias)
	if item.expr != nil {
		if column, ok := item.expr^.(Column_Expr); ok {
			return strings.clone(column.name)
		}
	}
	return result_own("?column?")
}

// build_order_key turns the ORDER BY clause of one output row into one byte
// string: ascending parts keep their order-preserving encoding, descending parts
// get every byte inverted. Comparing the strings then gives the requested order.
// The row id comes last as a tiebreaker, so rows that compare equal come back in
// the order they are stored -- the same row every run, which is what SQLite does
// and what a test needs.
@(private)
build_order_key :: proc(
	ctx: ^Eval_Ctx,
	order_by: []Order_Item,
	projections: []^Expr,
	values: []Value,
	names: []string,
	row_id: Row_Id,
) -> []u8 {
	if len(order_by) == 0 do return nil
	w: Byte_Writer
	bw_init(&w)
	for item in order_by {
		value := eval_order_value(ctx, item.expr, projections, values, names)
		// ORDER BY x COLLATE NOCASE sorts on the folded key.
		collation, has := collate_name(item.expr)
		if !has {
			collation, has = column_collation(ctx, item.expr)
		}
		if has && len(collation) > 0 {
			value = collate_ordered_value(value, collation)
		}
		order_key_append(&w, value, item)
	}
	write_be_u64(&w, u64(row_id))
	raw := bw_bytes(&w)
	out := make([]u8, len(raw))
	copy(out, raw)
	bw_destroy(&w)
	return out
}

// order_key_append encodes one ORDER BY value so that comparing keys byte by
// byte gives the requested order: descending inverts the value's bytes, and an
// explicit NULLS FIRST/LAST puts a leading byte that decides where NULL goes,
// whatever the direction.
@(private)
order_key_append :: proc(w: ^Byte_Writer, value: Value, item: Order_Item) {
	if item.nulls != .Default {
		is_null := value.kind == .Null
		marker: u8 = 1
		if is_null do marker = item.nulls == .First ? 0 : 2
		append(&w.data, marker)
	}
	start := len(w.data)
	value_encode_key(w, value)
	if item.descending {
		for i in start ..< len(w.data) do w.data[i] = ~w.data[i]
	}
}

// collate_ordered_value folds a text value the way a collation sorts it.
@(private)
collate_ordered_value :: proc(v: Value, collation: string) -> Value {
	if v.kind != .String do return v
	if strings.equal_fold(collation, "nocase") {
		return value_string(strings.to_lower(v.s, context.temp_allocator))
	}
	if strings.equal_fold(collation, "rtrim") {
		return value_string(strings.trim_right(v.s, " "))
	}
	return v
}

@(private)
eval_order_value :: proc(
	ctx: ^Eval_Ctx,
	expr: ^Expr,
	projections: []^Expr,
	values: []Value,
	names: []string,
) -> Value {
	// An ordinal (ORDER BY 1) or an alias refers to the projection.
	if literal, ok := expr^.(Literal_Expr); ok {
		if index, int_ok := value_to_i64(literal.value); int_ok && index >= 1 && index <= i64(len(values)) {
			return values[index - 1]
		}
	}
	if column, ok := expr^.(Column_Expr); ok && len(column.table) == 0 {
		// The output name first: it is the alias when the projection has one,
		// and the column name otherwise.
		for name, i in names {
			if strings.equal_fold(name, column.name) {
				return values[i]
			}
		}
		for projected, i in projections {
			if other, other_ok := projected^.(Column_Expr); other_ok {
				if strings.equal_fold(other.name, column.name) {
					return values[i]
				}
			}
		}
	}
	value, eval_err := eval_expr(ctx, expr)
	if eval_err.kind != .None {
		// The statement answers this error once the keys are built. Sorting the
		// row as NULL instead made `ORDER BY no_such_column` (or a window function
		// in ORDER BY) return the rows unsorted with no word of why.
		if ctx.order_err.kind == .None {
			ctx.order_err = eval_err
		} else {
			error_free(&eval_err)
		}
		return value_null()
	}
	return value
}

// Output_Key is the exported form of the row identity used by diffs.
Output_Key :: proc(values: []Value) -> string {
	return encode_output_key(values)
}

@(private)
encode_output_key :: proc(values: []Value) -> string {
	return encode_output_key_alloc(values, context.allocator)
}

// agg_distinct_key encodes one aggregate argument so a value a DISTINCT
// aggregate already folded can be skipped. Numbers that compare equal key the
// same even across kinds: an integral float keys as its integer, the way SQLite
// compares them, so count(DISTINCT x) over 1 and 1.0 answers one.
@(private)
agg_distinct_key :: proc(value: Value) -> string {
	INTEGRAL_LIMIT :: f64(9.0e18)
	switch value.kind {
	case .Float:
		if value.f >= -INTEGRAL_LIMIT && value.f <= INTEGRAL_LIMIT {
			whole := i64(value.f)
			if f64(whole) == value.f do return encode_output_key([]Value{value_int(whole)})
		}
	case .Uint:
		if value.u <= u64(0x7fff_ffff_ffff_ffff) do return encode_output_key([]Value{value_int(i64(value.u))})
	case .Null, .Default, .Int, .Int128, .Uint128, .Bool, .String, .Bytes, .Timestamp, .Duration, .Uuid, .Identity, .Connection, .Array, .Product:
	}
	return encode_output_key([]Value{value})
}

// agg_distinct_destroy frees what a DISTINCT aggregate's key map owns. The map
// stores the string header only, so the bytes handed to it must outlive every
// lookup: freeing a key right after inserting it leaves the map pointing at freed
// memory, and a later comparison reads it.
@(private)
agg_distinct_destroy :: proc(keys: ^map[string]bool) {
	if keys^ == nil do return
	for key in keys do delete(key)
	delete(keys^)
}

// encode_output_key_alloc is encode_output_key with an explicit allocator, so a
// subscription can keep the key of a cached row next to its arena.
encode_output_key_alloc :: proc(values: []Value, alloc: mem.Allocator) -> string {
	w: Byte_Writer
	bw_init(&w)
	defer bw_destroy(&w)
	for value in values {
		value_encode_key(&w, value)
	}
	raw := bw_bytes(&w)
	out := make([]u8, len(raw), alloc)
	copy(out, raw)
	return string(out)
}

// group_by_expressions resolves the GROUP BY list, replacing a name that is only a
// projection alias with the expression it stands for. A name that is a column of a
// source keeps meaning the column, which is what SQL says and what a reader
// expects from `GROUP BY dept` once a projection happens to alias itself `dept`.
@(private)
group_by_expressions :: proc(
	stmt: Select_Stmt,
	sources: []Source,
	alloc: mem.Allocator,
) -> []^Expr {
	out := make([]^Expr, len(stmt.group_by), alloc)
	for expr, i in stmt.group_by {
		out[i] = expr
		reference, is_column := expr^.(Column_Expr)
		if !is_column do continue
		if len(reference.table) > 0 do continue
		// A column of a source wins over an alias of the same name.
		named_by_a_column := false
		for source in sources {
			if source.table == nil do continue
			if _, found := schema_column_index(&source.table.schema, reference.name); found {
				named_by_a_column = true
				break
			}
		}
		if named_by_a_column do continue
		for projection in stmt.projections {
			if len(projection.alias) > 0 {
				if strings.equal_fold(projection.alias, reference.name) {
					out[i] = projection.expr
					break
				}
			}
			// An unaliased projection names its column after the expression, so
			// `SELECT dept ... GROUP BY dept` needs no substitution.
		}
	}
	return out
}

// outer_column answers a column the inner sources do not have, by looking in the
// frames of the statement the query is written inside. The nearest frame wins, as
// SQL scoping says.
@(private)
outer_column :: proc(ctx: ^Eval_Ctx, name, table: string) -> (Value, bool) {
	frame := ctx.outer
	for frame != nil {
		found_value: Value
		found := false
		for source in frame.sources {
			if source.table == nil do continue
			if len(table) > 0 {
				matches := strings.equal_fold(table, source.table.schema.name) ||
					(len(source.alias) > 0 && strings.equal_fold(table, source.alias))
				if !matches do continue
			} else if source.hidden_unqualified {
				continue
			}
			index, exists := schema_column_index(&source.table.schema, name)
			if !exists do continue
			if found {
				// Ambiguous in this frame: the caller answers with its own error.
				return {}, false
			}
			found = true
			if index < len(source.row.values) {
				found_value = source.row.values[index]
			} else {
				found_value = value_null()
			}
		}
		if found do return found_value, true
		frame = frame.next
	}
	return {}, false
}

// subquery_run runs a subquery with the caller's row as an outer frame.
@(private)
subquery_run :: proc(ctx: ^Eval_Ctx, stmt: Select_Stmt) -> (Sql_Result, Error) {
	if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
	frame := Outer_Frame{sources = ctx.sources, next = ctx.outer}
	saved := ctx.tx.outer
	ctx.tx.outer = &frame
	result, err := sql_exec_select(ctx.tx, stmt, ctx.params)
	ctx.tx.outer = saved
	return result, err
}

// --- Expressions -----------------------------------------------------------

eval_expr :: proc(ctx: ^Eval_Ctx, expr: ^Expr) -> (Value, Error) {
	if expr == nil do return value_null(), ERROR_NONE
	ctx.depth += 1
	defer ctx.depth -= 1
	if ctx.depth > MAX_EXPRESSION_DEPTH {
		return value_null(), errf(
			.Sql_Unsupported,
			"expression nests deeper than %d levels",
			MAX_EXPRESSION_DEPTH,
		)
	}
	if _, is_window := expr^.(Window_Expr); is_window && ctx.window_slots != nil {
		if slot, found := ctx.window_slots[expr]; found {
			if slot >= 0 && slot < len(ctx.window_values) {
				return ctx.window_values[slot], ERROR_NONE
			}
		}
	}
	switch e in expr^ {
	case Literal_Expr:
		return e.value, ERROR_NONE
	case Column_Expr:
		// A column the grouping set leaves out is NULL in its row, which is what
		// ROLLUP and CUBE show for a level that was rolled up.
		if ctx.grouped && grouping_column_missing(ctx, e.name, e.table) {
			return value_null(), ERROR_NONE
		}
		if len(e.table) > 0 {
			// Inside a trigger body NEW and OLD name the rows of the event.
			if ctx.tx != nil && ctx.tx.trigger_active {
				is_new := strings.equal_fold(e.table, "new")
				if is_new || strings.equal_fold(e.table, "old") {
					index, found := schema_column_index(&ctx.tx.trigger_schema, e.name)
					if !found {
						return {}, errf(
							.Column_Not_Found,
							"column %s does not exist in %s",
							e.name,
							is_new ? "NEW" : "OLD",
						)
					}
					present := is_new ? ctx.tx.trigger_new_present : ctx.tx.trigger_old_present
					if !present do return value_null(), ERROR_NONE
					row := is_new ? ctx.tx.trigger_new : ctx.tx.trigger_old
					if index >= len(row.values) do return value_null(), ERROR_NONE
					return row.values[index], ERROR_NONE
				}
			}
			for source in ctx.sources {
				// A source the caller has not bound yet has no columns.
				if source.table == nil do continue
				matches := strings.equal_fold(e.table, source.table.schema.name) ||
					(len(source.alias) > 0 && strings.equal_fold(e.table, source.alias))
				if !matches do continue
				index, found := schema_column_index(&source.table.schema, e.name)
				if !found {
					// rank is a hidden column of a full-text table: it is the
					// score of the MATCH that this query ran.
					if strings.equal_fold(e.name, "rank") {
						if score, scored := fts_rank_value(ctx.tx, source.table.schema.name, source.row.id); scored {
							return value_float(score), ERROR_NONE
						}
					}
					// rowid, _rowid_ and oid name the row itself, unless the
					// table declares a column with that name (the lookup above
					// already won in that case).
					if rowid_alias_name(e.name) {
						if rowid, has_rowid := rowid_value(source); has_rowid {
							return rowid, ERROR_NONE
						}
					}
					return {}, errf(
						.Column_Not_Found,
						"column %s does not exist in %s",
						e.name,
						source.table.schema.name,
					)
				}
				if index >= len(source.row.values) do return value_null(), ERROR_NONE
				return source.row.values[index], ERROR_NONE
			}
			if value, ok := outer_column(ctx, e.name, e.table); ok do return value, ERROR_NONE
			return {}, errf(.Column_Not_Found, "table %s is not in the query", e.table)
		}
		found_value: Value
		found := false
		for source in ctx.sources {
			if source.table == nil || source.hidden_unqualified do continue
			index, exists := schema_column_index(&source.table.schema, e.name)
			if !exists do continue
			if found {
				return {}, errf(.Column_Not_Found, "column %s is ambiguous; qualify it with a table", e.name)
			}
			found = true
			if index < len(source.row.values) {
				found_value = source.row.values[index]
			} else {
				found_value = value_null()
			}
		}
		if !found && strings.equal_fold(e.name, "rank") {
			for source in ctx.sources {
				if source.table == nil do continue
				if score, scored := fts_rank_value(ctx.tx, source.table.schema.name, source.row.id); scored {
					return value_float(score), ERROR_NONE
				}
			}
		}
		if !found && rowid_alias_name(e.name) {
			// One reachable table with a rowid answers; two make the name
			// ambiguous, as they do in SQLite.
			rowid: Value
			reachable := 0
			for source in ctx.sources {
				if source.table == nil || source.hidden_unqualified do continue
				candidate, has_rowid := rowid_value(source)
				if !has_rowid do continue
				rowid = candidate
				reachable += 1
			}
			if reachable == 1 do return rowid, ERROR_NONE
			if reachable > 1 {
				return {}, errf(.Column_Not_Found, "column %s is ambiguous; qualify it with a table", e.name)
			}
		}
		if !found {
			if value, ok := outer_column(ctx, e.name, ""); ok do return value, ERROR_NONE
			return {}, errf(.Column_Not_Found, "column %s does not exist", e.name)
		}
		return found_value, ERROR_NONE
	case Star_Expr:
		return {}, errf(.Sql_Syntax, "* is only allowed in a projection")
	case Collate_Expr:
		return eval_expr(ctx, e.operand)
	case Binary_Expr:
		// A COLLATE on either side decides how the comparison treats text.
		collation := ""
		if collate, ok := collate_name(e.left); ok do collation = collate
		if collate, ok := collate_name(e.right); ok do collation = collate
		if len(collation) == 0 {
			if declared, ok := column_collation(ctx, e.left); ok do collation = declared
			if len(collation) == 0 {
				if declared, ok := column_collation(ctx, e.right); ok do collation = declared
			}
		}
		left, left_err := eval_expr(ctx, e.left)
		if left_err.kind != .None do return {}, left_err
		right, right_err := eval_expr(ctx, e.right)
		if right_err.kind != .None do return {}, right_err
		return eval_binary(e.op, left, right, collation, ctx.tx != nil ? ctx.tx.store : nil)
	case Unary_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		return eval_unary(e.op, operand)
	case Is_Null_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		is_null := operand.kind == .Null
		return value_bool(e.negated ? !is_null : is_null), ERROR_NONE
	case Between_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		low, low_err := eval_expr(ctx, e.low)
		if low_err.kind != .None do return {}, low_err
		high, high_err := eval_expr(ctx, e.high)
		if high_err.kind != .None do return {}, high_err
		if operand.kind == .Null || low.kind == .Null || high.kind == .Null {
			return value_null(), ERROR_NONE
		}
		low_order, low_ok := value_compare(operand, low)
		high_order, high_ok := value_compare(operand, high)
		if !low_ok || !high_ok {
			return {}, errf(.Invalid_Type, "BETWEEN mixes incompatible types")
		}
		inside := low_order != .Less && high_order != .Greater
		return value_bool(e.negated ? !inside : inside), ERROR_NONE
	case Subquery_Expr:
		if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
		if e.select == nil do return value_null(), ERROR_NONE
		sub, sub_err := subquery_run(ctx, e.select^)
		if sub_err.kind != .None do return {}, sub_err
		defer sql_result_destroy(&sub)
		if e.exists do return value_bool(len(sub.rows) > 0), ERROR_NONE
		if len(sub.rows) == 0 || len(sub.rows[0]) == 0 do return value_null(), ERROR_NONE
		return sub.rows[0][0], ERROR_NONE
	case In_Expr:
		if row, is_row := row_value_items(e.operand); is_row {
			if e.subquery == nil do return {}, errf(.Sql_Syntax, "row value misused")
			return eval_row_in_subquery(ctx, row, e.subquery, e.negated)
		}
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		if operand.kind == .Null do return value_null(), ERROR_NONE
		if e.subquery != nil {
			if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
			sub, sub_err := subquery_run(ctx, e.subquery^)
			if sub_err.kind != .None do return {}, sub_err
			defer sql_result_destroy(&sub)
			found := false
			unknown := false
			for row in sub.rows {
				if len(row) == 0 do continue
				if row[0].kind == .Null {
					unknown = true
					continue
				}
				if value_equal(operand, row[0]) {
					found = true
					break
				}
			}
			// A NULL in the set makes a non-match unknown, not false: neither
			// IN nor NOT IN can answer TRUE for a row it did not find.
			if !found && unknown do return value_null(), ERROR_NONE
			return value_bool(e.negated ? !found : found), ERROR_NONE
		}
		found := false
		unknown := false
		for item in e.items {
			value, item_err := eval_expr(ctx, item)
			if item_err.kind != .None do return {}, item_err
			if value.kind == .Null {
				unknown = true
				continue
			}
			if value_equal(operand, value) {
				found = true
				break
			}
		}
		if !found && unknown do return value_null(), ERROR_NONE
		return value_bool(e.negated ? !found : found), ERROR_NONE
	case Case_Expr:
		return eval_case(ctx, e)
	case Call_Expr:
		return eval_call(ctx, e)
	case Window_Expr:
		return {}, errf(
			.Sql_Unsupported,
			"window function %s() cannot be evaluated here",
			e.name,
		)
	case Match_Expr:
		pattern, pattern_err := eval_expr(ctx, e.pattern)
		if pattern_err.kind != .None do return {}, pattern_err
		if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "MATCH needs a transaction")
		return fts_match_eval(ctx.tx, ctx, e.operand, pattern)
	case Like_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		pattern, pattern_err := eval_expr(ctx, e.pattern)
		if pattern_err.kind != .None do return {}, pattern_err
		if operand.kind == .Null || pattern.kind == .Null do return value_null(), ERROR_NONE
		if operand.kind != .String || pattern.kind != .String {
			return {}, errf(.Invalid_Type, "LIKE needs text on both sides")
		}
		// SQLite's LIKE ignores ASCII case; GLOB does not.
		matched := e.glob ? glob_match(operand.s, pattern.s) : like_match(operand.s, pattern.s, true, e.escape)
		return value_bool(e.negated ? !matched : matched), ERROR_NONE
	case Cast_Expr:
		operand, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		return value_cast(operand, e.target)
	case Param_Expr:
		if e.index < 0 || e.index >= len(ctx.params) {
			return {}, errf(
				.Invalid_Argument,
				"bind parameter %d was not supplied (the statement has %d)",
				e.index + 1,
				len(ctx.params),
			)
		}
		return ctx.params[e.index], ERROR_NONE
	}
	return {}, errf(.Internal, "unknown expression")
}

// eval_row_in_subquery answers `(a, b) IN (SELECT x, y …)`: true when a row of
// the subquery equals the tuple, NULL when no row does but one could (a NULL on
// either side of a column that decides it), false otherwise.
@(private)
eval_row_in_subquery :: proc(ctx: ^Eval_Ctx, row: []^Expr, subquery: ^Select_Stmt, negated: bool) -> (Value, Error) {
	if ctx.tx == nil do return {}, errf(.Sql_Unsupported, "subqueries need a transaction")
	tuple := make([]Value, len(row), context.temp_allocator)
	for item, i in row {
		value, err := eval_expr(ctx, item)
		if err.kind != .None do return {}, err
		tuple[i] = value
	}
	sub, sub_err := subquery_run(ctx, subquery^)
	if sub_err.kind != .None do return {}, sub_err
	defer sql_result_destroy(&sub)
	if len(sub.columns) != len(tuple) {
		return {}, errf(.Sql_Syntax, "sub-select returns %d columns - expected %d", len(sub.columns), len(tuple))
	}
	found := false
	unknown := false
	for candidate in sub.rows {
		match := true
		maybe := false
		for value, i in tuple {
			if value.kind == .Null || candidate[i].kind == .Null {
				maybe = true
				continue
			}
			if !value_equal(value, candidate[i]) {
				match = false
				break
			}
		}
		if !match do continue
		if maybe {
			unknown = true
			continue
		}
		found = true
		break
	}
	if !found && unknown do return value_null(), ERROR_NONE
	return value_bool(negated ? !found : found), ERROR_NONE
}

eval_binary :: proc(
	op: Binary_Op,
	left: Value,
	right: Value,
	collation: string = "",
	store: ^Store = nil,
) -> (Value, Error) {
	#partial switch op {
	case .And:
		if !value_is_null(left) && !value_is_truthy(left) do return value_bool(false), ERROR_NONE
		if !value_is_null(right) && !value_is_truthy(right) do return value_bool(false), ERROR_NONE
		if value_is_null(left) || value_is_null(right) do return value_null(), ERROR_NONE
		return value_bool(true), ERROR_NONE
	case .Or:
		if value_is_truthy(left) do return value_bool(true), ERROR_NONE
		if value_is_truthy(right) do return value_bool(true), ERROR_NONE
		if value_is_null(left) || value_is_null(right) do return value_null(), ERROR_NONE
		return value_bool(false), ERROR_NONE
	case .Is, .Is_Not:
		same: bool
		if value_is_null(left) || value_is_null(right) {
			same = value_is_null(left) && value_is_null(right)
		} else {
			order, ok := value_compare_collated(left, right, collation, store)
			// Values of different classes are never the same value.
			same = ok && order == .Equal
		}
		return value_bool(op == .Is ? same : !same), ERROR_NONE
	case:
	}
	if value_is_null(left) || value_is_null(right) {
		return value_null(), ERROR_NONE
	}
	switch op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		// A driver that did not know a parameter's type sends an array as text,
		// `{a,b}`. PostgreSQL parses it against the column's type; here the array
		// on the other side says what the elements are.
		compared_left, compared_right := arrays_from_text(left, right)
		order, ok := value_compare_collated(compared_left, compared_right, collation, store)
		if !ok {
			return {}, errf(
				.Invalid_Type,
				"cannot compare %s with %s",
				value_kind_name(left.kind),
				value_kind_name(right.kind),
			)
		}
		result := false
		#partial switch op {
		case .Eq:
			result = order == .Equal
		case .Ne:
			result = order != .Equal
		case .Lt:
			result = order == .Less
		case .Le:
			result = order != .Greater
		case .Gt:
			result = order == .Greater
		case .Ge:
			result = order != .Less
		}
		return value_bool(result), ERROR_NONE
	case .Concat:
		// PostgreSQL's `||` concatenates arrays as well as text, and appends or
		// prepends a single element when only one side is an array.
		if left.kind == .Array || right.kind == .Array {
			return array_concat(left, right)
		}
		left_text := value_to_text(left)
		right_text := value_to_text(right)
		return value_string(strings.concatenate({left_text, right_text})), ERROR_NONE
	case .Add, .Sub, .Mul, .Div, .Mod:
		return eval_arithmetic(op, left, right)
	case .Bit_And, .Bit_Or, .Shift_Left, .Shift_Right:
		a, a_ok := value_bit_operand(left)
		b, b_ok := value_bit_operand(right)
		if !a_ok || !b_ok do return {}, errf(.Invalid_Type, "bitwise operators need integers")
		#partial switch op {
		case .Bit_And:
			return value_int(a & b), ERROR_NONE
		case .Bit_Or:
			return value_int(a | b), ERROR_NONE
		case .Shift_Left:
			return value_int(bit_shift(a, b)), ERROR_NONE
		case .Shift_Right:
			// A negative count shifts the other way, as in SQLite.
			return value_int(bit_shift(a, b == min(i64) ? max(i64) : -b)), ERROR_NONE
		}
	case .And, .Or, .Is, .Is_Not:
	}
	return {}, errf(.Internal, "unknown binary operator")
}

@(private)
eval_arithmetic :: proc(op: Binary_Op, left, right: Value) -> (Value, Error) {
	if !value_is_numeric(left) || !value_is_numeric(right) {
		return {}, errf(.Invalid_Type, "arithmetic needs numbers")
	}
	if left.kind == .Int128 ||
	   left.kind == .Uint128 ||
	   right.kind == .Int128 ||
	   right.kind == .Uint128 {
		return eval_arithmetic_128(op, left, right)
	}
	if left.kind == .Float || right.kind == .Float {
		a, _ := value_to_f64(left)
		b, _ := value_to_f64(right)
		if (op == .Div || op == .Mod) && b == 0 {
			return {}, errf(.Invalid_Argument, "division by zero")
		}
		#partial switch op {
		case .Add:
			return value_float(a + b), ERROR_NONE
		case .Sub:
			return value_float(a - b), ERROR_NONE
		case .Mul:
			return value_float(a * b), ERROR_NONE
		case .Div:
			return value_float(a / b), ERROR_NONE
		case .Mod:
			return value_float(fmod(a, b)), ERROR_NONE
		case:
		}
	}
	if left.kind == .Uint || right.kind == .Uint {
		a, a_ok := value_to_u64(left)
		b, b_ok := value_to_u64(right)
		if !a_ok || !b_ok {
			return {}, errf(.Invalid_Type, "unsigned arithmetic needs non-negative values")
		}
		#partial switch op {
		case .Add:
			sum, overflow := intrinsics.overflow_add(a, b)
			if overflow do return {}, integer_overflow_error()
			return value_uint(sum), ERROR_NONE
		case .Sub:
			if b > a do return {}, errf(.Invalid_Argument, "unsigned subtraction underflows")
			return value_uint(a - b), ERROR_NONE
		case .Mul:
			product, overflow := intrinsics.overflow_mul(a, b)
			if overflow do return {}, integer_overflow_error()
			return value_uint(product), ERROR_NONE
		case .Div:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint(a / b), ERROR_NONE
		case .Mod:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint(a % b), ERROR_NONE
		case:
		}
	}
	a, _ := value_to_i64(left)
	b, _ := value_to_i64(right)
	#partial switch op {
	case .Add:
		sum, overflow := intrinsics.overflow_add(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int(sum), ERROR_NONE
	case .Sub:
		difference, overflow := intrinsics.overflow_sub(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int(difference), ERROR_NONE
	case .Mul:
		product, overflow := intrinsics.overflow_mul(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int(product), ERROR_NONE
	case .Div:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		// The one quotient that does not fit: min(i64) / -1. Answering it would
		// fault in the hardware division, so it is an error like any other
		// overflow.
		if a == min(i64) && b == -1 do return {}, integer_overflow_error()
		return value_int(a / b), ERROR_NONE
	case .Mod:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		// min(i64) % -1 is zero, but the hardware division behind it traps.
		if a == min(i64) && b == -1 do return value_int(0), ERROR_NONE
		return value_int(a % b), ERROR_NONE
	case:
	}
	return {}, errf(.Internal, "unknown arithmetic operator")
}

@(private)
eval_arithmetic_128 :: proc(op: Binary_Op, left, right: Value) -> (Value, Error) {
	unsigned := is_unsigned_kind(left.kind) || is_unsigned_kind(right.kind)
	if unsigned {
		for operand in ([]Value{left, right}) {
			if !is_unsigned_kind(operand.kind) && value_as_i128(operand) < 0 {
				return {}, errf(.Invalid_Argument, "negative value in unsigned arithmetic")
			}
		}
		a := value_as_u128(left)
		b := value_as_u128(right)
		#partial switch op {
		case .Add:
			sum, overflow := intrinsics.overflow_add(a, b)
			if overflow do return {}, integer_overflow_error()
			return value_uint128(sum), ERROR_NONE
		case .Sub:
			if b > a do return {}, errf(.Invalid_Argument, "unsigned subtraction underflows")
			return value_uint128(a - b), ERROR_NONE
		case .Mul:
			product, overflow := intrinsics.overflow_mul(a, b)
			if overflow do return {}, integer_overflow_error()
			return value_uint128(product), ERROR_NONE
		case .Div:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint128(a / b), ERROR_NONE
		case .Mod:
			if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
			return value_uint128(a % b), ERROR_NONE
		}
		return {}, errf(.Internal, "unknown arithmetic operator")
	}
	a := value_as_i128(left)
	b := value_as_i128(right)
	#partial switch op {
	case .Add:
		sum, overflow := intrinsics.overflow_add(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int128(sum), ERROR_NONE
	case .Sub:
		difference, overflow := intrinsics.overflow_sub(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int128(difference), ERROR_NONE
	case .Mul:
		product, overflow := intrinsics.overflow_mul(a, b)
		if overflow do return {}, integer_overflow_error()
		return value_int128(product), ERROR_NONE
	case .Div:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		if a == min(i128) && b == -1 do return {}, integer_overflow_error()
		return value_int128(a / b), ERROR_NONE
	case .Mod:
		if b == 0 do return {}, errf(.Invalid_Argument, "division by zero")
		if a == min(i128) && b == -1 do return value_int128(0), ERROR_NONE
		return value_int128(a % b), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown arithmetic operator")
}

// integer_overflow_error is the one answer every arithmetic path gives when the
// result does not fit: `+`, `-`, `*` and the two quotients that trap. SQLite
// would promote a 64-bit result to a real; this engine refuses instead, which is
// what PostgreSQL does and what the rest of this engine does with a CAST.
@(private)
integer_overflow_error :: proc() -> Error {
	return errf(.Invalid_Argument, "integer overflow")
}

@(private)
fmod :: proc(a, b: f64) -> f64 {
	return a - b * f64(i64(a / b))
}

@(private)
eval_unary :: proc(op: Unary_Op, operand: Value) -> (Value, Error) {
	switch op {
	case .Neg:
		if operand.kind == .Null do return value_null(), ERROR_NONE
		if operand.kind == .Float do return value_float(-operand.f), ERROR_NONE
		if operand.kind == .Uint128 {
			if value_big(operand) > u128(max(i128)) + 1 {
				return {}, errf(.Invalid_Argument, "cannot negate this uint128")
			}
			return value_int128(0 - i128(value_big(operand))), ERROR_NONE
		}
		if operand.kind == .Int128 {
			if i128(value_big(operand)) == min(i128) {
				return {}, errf(.Invalid_Argument, "integer overflow negating int128")
			}
			return value_int128(0 - i128(value_big(operand))), ERROR_NONE
		}
		if operand.kind == .Uint {
			if operand.u > u64(max(i64)) + 1 {
				return {}, errf(.Invalid_Argument, "cannot negate this uint")
			}
			big := i128(0) - i128(operand.u)
			if big >= i128(min(i64)) && big <= i128(max(i64)) {
				return value_int(i64(big)), ERROR_NONE
			}
			return value_int128(big), ERROR_NONE
		}
		value, ok := value_to_i64(operand)
		if !ok do return {}, errf(.Invalid_Type, "cannot negate a %s", value_kind_name(operand.kind))
		if value == min(i64) {
			return value_int128(0 - i128(value)), ERROR_NONE
		}
		return value_int(-value), ERROR_NONE
	case .Plus:
		if !value_is_numeric(operand) && operand.kind != .Null {
			return {}, errf(.Invalid_Type, "cannot apply + to a %s", value_kind_name(operand.kind))
		}
		return operand, ERROR_NONE
	case .Not:
		if operand.kind == .Null do return value_null(), ERROR_NONE
		return value_bool(!value_is_truthy(operand)), ERROR_NONE
	case .Bit_Not:
		if operand.kind == .Null do return value_null(), ERROR_NONE
		v, ok := value_bit_operand(operand)
		if !ok do return {}, errf(.Invalid_Type, "~ needs an integer")
		return value_int(~v), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown unary operator")
}

// value_bit_operand converts an operand of a bitwise operator to the 64-bit
// integer SQLite works on: a real is truncated, numeric text is read as a
// number (text that is not a number is 0), and a blob is not an integer.
@(private)
value_bit_operand :: proc(v: Value) -> (i64, bool) {
	if v.kind == .String {
		parsed, ok := value_parse_number(strings.trim_space(v.s))
		if !ok do return 0, true
		return value_to_i64(parsed)
	}
	if !value_is_numeric(v) do return 0, false
	return value_to_i64(v)
}

// bit_shift moves `a` left by `count` bits (right when negative); a count of 64
// or more empties it, keeping the sign on a right shift as SQLite does.
@(private)
bit_shift :: proc(a: i64, count: i64) -> i64 {
	if count >= 64 do return 0
	if count <= -64 do return a < 0 ? -1 : 0
	if count >= 0 do return i64(u64(a) << u64(count))
	return a >> u64(-count)
}

@(private)
value_to_text :: proc(v: Value) -> string {
	#partial switch v.kind {
	case .String:
		return v.s
	case .Null:
		return ""
	}
	return value_format(v, context.temp_allocator)
}

// value_cast implements CAST and the implicit conversions SQL expressions need.
value_cast :: proc(v: Value, target: Column_Type) -> (Value, Error) {
	if v.kind == .Null do return value_null(), ERROR_NONE
	if target.kind == .String {
		if v.kind == .String do return v, ERROR_NONE
		return value_string(value_format(v, context.allocator)), ERROR_NONE
	}
	if coerced, coerce_err := value_coerce(v, target); coerce_err.kind == .None {
		return coerced, ERROR_NONE
	}
	if v.kind == .String {
		if parsed, ok := value_parse_number(v.s); ok {
			return value_coerce(parsed, target)
		}
		if target.kind == .Bool {
			// `t` and `f` are how PostgreSQL writes a bool in its text formats,
			// which COPY reads back; the words and the digits are the SQL forms.
			if strings.equal_fold(v.s, "true") || v.s == "1" || strings.equal_fold(v.s, "t") {
				return value_bool(true), ERROR_NONE
			}
			if strings.equal_fold(v.s, "false") || v.s == "0" || strings.equal_fold(v.s, "f") {
				return value_bool(false), ERROR_NONE
			}
		}
	}
	return {}, errf(
		.Invalid_Type,
		"cannot cast a %s to %s",
		value_kind_name(v.kind),
		type_kind_name(target.kind),
	)
}

// unistr_decode reads the escapes unistr documents. An escape that names no
// character is refused rather than dropped, as SQLite refuses it.
@(private)
unistr_decode :: proc(text: string) -> string {
	out := make([dynamic]u8, 0, len(text))
	i := 0
	for i < len(text) {
		c := text[i]
		if c != '\\' {
			append(&out, c)
			i += 1
			continue
		}
		i += 1
		if i >= len(text) {
			append(&out, '\\')
			break
		}
		escape := text[i]
		i += 1
		digits := 0
		switch escape {
		case '\\':
			append(&out, '\\')
			continue
		case 'u':
			digits = 4
		case '+':
			digits = 6
		case 'U':
			digits = 8
		case:
			// No other escape: the backslash is literal, as SQLite keeps it.
			append(&out, '\\')
			append(&out, escape)
			continue
		}
		if i + digits > len(text) {
			append(&out, '\\')
			append(&out, escape)
			continue
		}
		code: u32
		valid := true
		for _ in 0 ..< digits {
			digit := text[i]
			i += 1
			value: u32
			switch {
			case digit >= '0' && digit <= '9':
				value = u32(digit - '0')
			case digit >= 'a' && digit <= 'f':
				value = u32(digit - 'a') + 10
			case digit >= 'A' && digit <= 'F':
				value = u32(digit - 'A') + 10
			case:
				valid = false
			}
			code = code * 16 + value
		}
		if !valid || code > 0x10FFFF {
			append(&out, '\\')
			append(&out, escape)
			continue
		}
		// A UTF-16 surrogate pair says nothing on its own: it is written as the
		// replacement character, which is what a broken escape earns.
		if code >= 0xD800 && code <= 0xDFFF {
			code = 0xFFFD
		}
		buffer, length := utf8.encode_rune(cast(rune)code)
		append(&out, ..buffer[:length])
	}
	return string(out[:])
}

// unistr_quote writes a text so that unistr reads it back: the quotes SQL wants
// and the escapes for a control character or a lone surrogate.
@(private)
unistr_quote :: proc(text: string) -> string {
	out := make([dynamic]u8, 0, len(text) + 2)
	// SQLite answers the call that would read the text back, not a bare literal.
	append(&out, ..transmute([]u8)string("unistr('"))
	for i := 0; i < len(text); {
		c := text[i]
		if c == '\'' {
			append(&out, '\'')
			append(&out, '\'')
			i += 1
			continue
		}
		if c < 0x20 || c == 0x7F {
			append(&out, ..transmute([]u8)fmt.aprintf("\\u%04x", c))
			i += 1
			continue
		}
		decoded, size := utf8.decode_rune(text[i:])
		if decoded == utf8.RUNE_ERROR && size <= 1 {
			out_text := fmt.aprintf("\\u%04x", c)
			append(&out, ..transmute([]u8)out_text)
			i += 1
			continue
		}
		append(&out, text[i:i + size])
		i += size
	}
	append(&out, ..transmute([]u8)string("')"))
	return string(out[:])
}

// timediff_text is `first - second` as SQLite writes it: a sign, then years,
// months, days and the time of day.
@(private)
timediff_text :: proc(first, second: Db_Time) -> string {
	negative := second.jd > first.jd
	from := negative ? first : second
	to := negative ? second : first
	years, months, days, hours, minutes, seconds, millis := timediff_parts(from, to)
	return fmt.aprintf(
		"%s%04d-%02d-%02d %02d:%02d:%02d.%03d",
		negative ? "-" : "+",
		years,
		months,
		days,
		hours,
		minutes,
		seconds,
		millis,
	)
}

@(private)
timediff_parts :: proc(from, to: Db_Time) -> (years, months, days, hours, minutes, seconds, millis: int) {
	fy, fm, fd, fh, fmin, fs := db_time_civil(from)
	ty, tm, td, th, tmin, ts := db_time_civil(to)
	years = ty - fy
	months = tm - fm
	days = td - fd
	hours = th - fh
	minutes = tmin - fmin
	seconds = ts - fs
	// Borrow the way a calendar does: a negative lower field takes one from the
	// field above it. A month is the month before, and a day is the length of the
	// month it lands in.
	if seconds < 0 {
		seconds += 60
		minutes -= 1
	}
	if minutes < 0 {
		minutes += 60
		hours -= 1
	}
	if hours < 0 {
		hours += 24
		days -= 1
	}
	if days < 0 {
		month := tm - 1
		year := ty
		if month < 1 {
			month = 12
			year -= 1
		}
		days += db_days_in_month(year, month)
		months -= 1
	}
	if months < 0 {
		months += 12
		years -= 1
	}
	return
}

// soundex_encode is SQLite's SOUNDEX: the first letter in upper case, then one
// digit per consonant class for three digits, zero-padded. The classes are
// SQLite's, and a letter that repeats the class of the one before it (with only
// vowels, h, w or y in between) counts once.
@(private)
soundex_encode :: proc(text: string) -> string {
	classify :: proc(c: u8) -> u8 {
		switch c {
		case 'B', 'F', 'P', 'V', 'b', 'f', 'p', 'v':
			return '1'
		case 'C', 'G', 'J', 'K', 'Q', 'S', 'X', 'Z', 'c', 'g', 'j', 'k', 'q', 's', 'x', 'z':
			return '2'
		case 'D', 'T', 'd', 't':
			return '3'
		case 'L', 'l':
			return '4'
		case 'M', 'N', 'm', 'n':
			return '5'
		case 'R', 'r':
			return '6'
		}
		return 0
	}
	digits := make([dynamic]u8, 0, 8)
	previous: u8 = 0
	first := true
	first_letter: u8 = 0
	for i in 0 ..< len(text) {
		c := text[i]
		is_letter := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
		if !is_letter do continue
		upper := c >= 'a' && c <= 'z' ? c - 32 : c
		if first {
			first_letter = upper
			first = false
			previous = classify(upper)
			continue
		}
		code := classify(upper)
		if code == 0 {
			// A vowel, or h, w, y: it separates two groups but does not end them
			// for h, w and y, which SQLite skips without resetting.
			if upper != 'H' && upper != 'W' && upper != 'Y' do previous = 0
			continue
		}
		if code == previous do continue
		append(&digits, code)
		previous = code
		if len(digits) == 3 do break
	}
	if first_letter == 0 do return "?000"
	out := make([dynamic]u8, 0, 4)
	append(&out, first_letter)
	for i in 0 ..< 3 {
		if i < len(digits) {
			append(&out, digits[i])
		} else {
			append(&out, '0')
		}
	}
	return string(out[:])
}

// scalar_minmax reports a min()/max() call that takes its value from two or more
// arguments: SQLite answers that as a scalar function, not as a group aggregate.
@(private)
scalar_minmax :: proc(call: Call_Expr) -> bool {
	if len(call.args) < 2 do return false
	return strings.equal_fold(call.name, "min") || strings.equal_fold(call.name, "max")
}

@(private)
expr_is_aggregate :: proc(expr: ^Expr) -> bool {
	if expr == nil do return false
	switch e in expr^ {
	case Window_Expr:
		// A window aggregate is not a group aggregate: it is computed once every
		// row is known, not while scanning.
		return false
	case Case_Expr:
		if expr_is_aggregate(e.operand) do return true
		for branch in e.branches {
			if expr_is_aggregate(branch.condition) do return true
			if expr_is_aggregate(branch.result) do return true
		}
		return expr_is_aggregate(e.fallback)
	case Call_Expr:
		if scalar_minmax(e) do return false
		if is_aggregate_name(e.name) do return true
		for arg in e.args {
			if expr_is_aggregate(arg) do return true
		}
	case Binary_Expr:
		return expr_is_aggregate(e.left) || expr_is_aggregate(e.right)
	case Unary_Expr:
		return expr_is_aggregate(e.operand)
	case Is_Null_Expr:
		return expr_is_aggregate(e.operand)
	case Between_Expr:
		return expr_is_aggregate(e.operand) || expr_is_aggregate(e.low) || expr_is_aggregate(e.high)
	case In_Expr:
		if expr_is_aggregate(e.operand) do return true
		for item in e.items {
			if expr_is_aggregate(item) do return true
		}
	case Match_Expr:
		return false
	case Like_Expr:
		return expr_is_aggregate(e.operand) || expr_is_aggregate(e.pattern)
	case Cast_Expr:
		return expr_is_aggregate(e.operand)
	case Collate_Expr:
		return expr_is_aggregate(e.operand)
	case Subquery_Expr:
		return false
	case Literal_Expr, Column_Expr, Star_Expr, Param_Expr:
	}
	return false
}

// sq_literal renders a value as SQLite's quote() does.
@(private)
sq_literal :: proc(value: Value) -> string {
	#partial switch value.kind {
	case .Null:
		return "NULL"
	case .Int:
		return fmt.aprintf("%d", value.i)
	case .Uint:
		return fmt.aprintf("%d", value.u)
	case .Float:
		return fmt.aprintf("%.15g", value.f)
	case .Bool:
		return value.b ? "1" : "0"
	case .Bytes:
		builder := strings.builder_make()
		strings.write_string(&builder, "X'")
		for byte in value.bytes do strings.write_string(&builder, fmt.aprintf("%02X", byte, allocator = context.temp_allocator))
		strings.write_byte(&builder, '\'')
		return strings.to_string(builder)
	case .String:
		escaped, _ := strings.replace_all(value.s, "'", "''", context.temp_allocator)
		return fmt.aprintf("'%s'", escaped)
	}
	return value_format(value, context.allocator)
}

@(private)
sq_hex :: proc(value: Value) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	#partial switch value.kind {
	case .Bytes:
		for byte in value.bytes do fmt.sbprintf(&builder, "%02X", byte)
	case .String:
		// Iterate the bytes: `for c in text` would yield runes, so hex('é')
		// answered the code point E9 instead of the UTF-8 bytes C3A9 (D32).
		for i in 0 ..< len(value.s) do fmt.sbprintf(&builder, "%02X", value.s[i])
	}
	return strings.clone(strings.to_string(builder))
}

// sq_format implements SQLite's printf/format:
//
//	%[flags][width][.precision]conversion
//
// over d i u o x X f F e E g G s c q and %%. A conversion this does not know is
// written back as it came, so a pattern is never silently mangled: the earlier
// version dropped the "%" of "%05.2f" and answered "05.2f" (found by the
// differential corpus in D30).
@(private)
sq_format :: proc(pattern: string, args: []Value) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	next := 0
	at := 0
	for at < len(pattern) {
		if pattern[at] != '%' {
			strings.write_byte(&builder, pattern[at])
			at += 1
			continue
		}
		start := at
		if at + 1 < len(pattern) && pattern[at + 1] == '%' {
			strings.write_byte(&builder, '%')
			at += 2
			continue
		}
		scan := at + 1
		left, zero, plus, space := false, false, false, false
		flags: for scan < len(pattern) {
			switch pattern[scan] {
			case '-':
				left = true
			case '0':
				zero = true
			case '+':
				plus = true
			case ' ':
				space = true
			case:
				break flags
			}
			scan += 1
		}
		width := 0
		for scan < len(pattern) && pattern[scan] >= '0' && pattern[scan] <= '9' {
			width = width * 10 + int(pattern[scan] - '0')
			scan += 1
		}
		precision := -1
		if scan < len(pattern) && pattern[scan] == '.' {
			scan += 1
			precision = 0
			for scan < len(pattern) && pattern[scan] >= '0' && pattern[scan] <= '9' {
				precision = precision * 10 + int(pattern[scan] - '0')
				scan += 1
			}
		}
		if scan >= len(pattern) {
			// A trailing "%" is not a conversion: write it as it came.
			strings.write_string(&builder, pattern[start:scan])
			at = scan
			continue
		}
		conversion := pattern[scan]
		at = scan + 1
		arg := next < len(args) ? args[next] : value_null()
		if next < len(args) do next += 1
		core := ""
		sign := ""
		signed := false
		switch conversion {
		case 'd', 'i', 'u', 'o', 'x', 'X':
			number := sq_int(arg)
			square := number
			if conversion == 'u' || conversion == 'o' || conversion == 'x' || conversion == 'X' {
				square = i64(u64(number))
			}
			magnitude := number
			if (conversion == 'd' || conversion == 'i') && number < 0 do magnitude = -number
			switch conversion {
			case 'd', 'i':
				core = fmt.aprintf("%d", magnitude, allocator = context.temp_allocator)
			case 'u':
				core = fmt.aprintf("%d", u64(number), allocator = context.temp_allocator)
			case 'o':
				core = fmt.aprintf("%o", u64(square), allocator = context.temp_allocator)
			case 'x':
				core = fmt.aprintf("%x", u64(square), allocator = context.temp_allocator)
			case 'X':
				core = fmt.aprintf("%X", u64(square), allocator = context.temp_allocator)
			}
			// A precision is the fewest digits, not a rounding.
			for precision > len(core) {
				core = fmt.aprintf("0%s", core, allocator = context.temp_allocator)
			}
			if conversion == 'd' || conversion == 'i' {
				signed = true
				if number < 0 {
					sign = "-"
				} else if plus {
					sign = "+"
				} else if space {
					sign = " "
				}
			}
		case 'f', 'F', 'e', 'E', 'g', 'G':
			specification := sq_float_spec(conversion, precision)
			core = fmt.aprintf(specification, sq_float(arg), allocator = context.temp_allocator)
			signed = true
		case 's':
			if arg.kind != .Null do core = value_format(arg, context.temp_allocator)
			if precision >= 0 && precision < len(core) do core = core[:precision]
		case 'c':
			// SQLite takes the first character of the text, not the code point.
			if arg.kind != .Null {
				text := value_format(arg, context.temp_allocator)
				if len(text) > 0 do core = text[:1]
			}
		case 'q':
			// "%q doubles a single quote and adds no quoting of its own.
			if arg.kind != .Null {
				text := value_format(arg, context.temp_allocator)
				core, _ = strings.replace_all(text, "'", "''", context.temp_allocator)
			}
		case:
			strings.write_string(&builder, pattern[start:at])
			continue
		}
		// A sign belongs in front of the padding when zeros were asked for.
		if signed && len(core) > 0 && (core[0] == '-' || core[0] == '+') {
			if len(sign) == 0 {
				sign = core[:1]
				core = core[1:]
			}
		} else if signed && len(sign) == 0 && len(core) > 0 {
			if plus {
				sign = "+"
			} else if space {
				sign = " "
			}
		}
		total := len(sign) + len(core)
		pad := width > total ? width - total : 0
		if !left && !zero {
			for _ in 0 ..< pad do strings.write_byte(&builder, ' ')
		}
		strings.write_string(&builder, sign)
		if !left && zero {
			for _ in 0 ..< pad do strings.write_byte(&builder, '0')
		}
		strings.write_string(&builder, core)
		if left {
			for _ in 0 ..< pad do strings.write_byte(&builder, ' ')
		}
	}
	return strings.clone(strings.to_string(builder))
}

// sq_float_spec builds the Odin format string for a float conversion, with the
// precision the pattern asked for (six digits when it asked for none).
@(private)
sq_float_spec :: proc(conversion: byte, precision: int) -> string {
	letter := conversion
	if letter == 'F' do letter = 'f'
	if letter == 'G' do letter = 'g'
	if precision < 0 do return fmt.aprintf("%%%c", letter, allocator = context.temp_allocator)
	return fmt.aprintf("%%.%d%c", precision, letter, allocator = context.temp_allocator)
}

@(private)
sq_int :: proc(value: Value) -> i64 {
	#partial switch value.kind {
	case .Int:
		return value.i
	case .Uint:
		return i64(value.u)
	case .Float:
		return i64(value.f)
	case .Bool:
		return value.b ? 1 : 0
	}
	return 0
}

@(private)
sq_float :: proc(value: Value) -> f64 {
	#partial switch value.kind {
	case .Float:
		return value.f
	case .Int:
		return f64(value.i)
	case .Uint:
		return f64(value.u)
	}
	return 0
}

@(private)
sq_truthy :: proc(value: Value) -> (bool, Error) {
	#partial switch value.kind {
	case .Null:
		return false, ERROR_NONE
	case .Bool:
		return value.b, ERROR_NONE
	case .Int:
		return value.i != 0, ERROR_NONE
	case .Uint:
		return value.u != 0, ERROR_NONE
	case .Float:
		return value.f != 0, ERROR_NONE
	case .String:
		return len(value.s) > 0, ERROR_NONE
	}
	return true, ERROR_NONE
}

@(private)
is_aggregate_name :: proc(name: string) -> bool {
	for candidate in ([]string{"count", "sum", "avg", "min", "max", "total", "group_concat", "string_agg", "array_agg", "json_group_array", "json_group_object", "median", "percentile", "percentile_cont", "percentile_disc"}) {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}

// eval_case is CASE [operand] WHEN ... THEN ... [ELSE ...] END. With an operand
// every WHEN is compared against it (a NULL on either side never matches); with
// no operand every WHEN is a condition and only TRUE takes the branch. The first
// match wins and the branch is evaluated only then, which is what makes
// `CASE WHEN d = 0 THEN NULL ELSE n / d END` safe.
@(private)
eval_case :: proc(ctx: ^Eval_Ctx, e: Case_Expr) -> (Value, Error) {
	searched := e.operand == nil
	operand: Value
	if !searched {
		value, operand_err := eval_expr(ctx, e.operand)
		if operand_err.kind != .None do return {}, operand_err
		operand = value
	}
	for branch in e.branches {
		condition, condition_err := eval_expr(ctx, branch.condition)
		if condition_err.kind != .None do return {}, condition_err
		matched := false
		if searched {
			matched = value_is_truthy(condition)
		} else if condition.kind != .Null && operand.kind != .Null {
			matched = value_equal(operand, condition)
		}
		if matched do return eval_expr(ctx, branch.result)
	}
	if e.fallback != nil do return eval_expr(ctx, e.fallback)
	return value_null(), ERROR_NONE
}

// grouping_column_missing reports whether `name` is a GROUP BY entry the current
// set left out. Matching is by name, with a table when both sides name one, which
// is how a projection finds the entry it groups by.
@(private)
grouping_column_missing :: proc(ctx: ^Eval_Ctx, name, table: string) -> bool {
	for expr, index in ctx.grouping_exprs {
		if index >= len(ctx.grouping_missing) || !ctx.grouping_missing[index] do continue
		column, is_column := expr^.(Column_Expr)
		if !is_column || !strings.equal_fold(column.name, name) do continue
		if len(table) > 0 && len(column.table) > 0 && !strings.equal_fold(column.table, table) {
			continue
		}
		return true
	}
	return false
}

// eval_grouping answers GROUPING(a, b): one bit per argument, most significant
// first, 1 when the set left that column out. GROUPING_ID is the same function
// under its other name.
@(private)
eval_grouping :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	if !ctx.grouped || len(ctx.grouping_exprs) == 0 {
		return {}, errf(.Invalid_Argument, "GROUPING() needs GROUP BY with ROLLUP, CUBE or GROUPING SETS")
	}
	mask: i64
	for arg in call.args {
		column, is_column := arg^.(Column_Expr)
		if !is_column {
			return {}, errf(.Invalid_Argument, "GROUPING() takes a column of the GROUP BY list")
		}
		missing := false
		found := false
		for expr, index in ctx.grouping_exprs {
			other, other_is_column := expr^.(Column_Expr)
			if !other_is_column || !strings.equal_fold(other.name, column.name) do continue
			if len(column.table) > 0 && len(other.table) > 0 &&
			   !strings.equal_fold(column.table, other.table) {
				continue
			}
			found = true
			missing = index < len(ctx.grouping_missing) && ctx.grouping_missing[index]
			break
		}
		if !found {
			return {}, errf(
				.Invalid_Argument,
				"GROUPING() takes a column of the GROUP BY list, not %s",
				column.name,
			)
		}
		mask = mask << 1
		if missing do mask |= 1
	}
	return value_int(mask), ERROR_NONE
}

// select_group_sets is the sets a statement groups by: the ones a construct asked
// for, or the single set of the whole GROUP BY list.
@(private)
select_group_sets :: proc(stmt: Select_Stmt, alloc: mem.Allocator) -> [][]int {
	if len(stmt.group_sets) > 0 do return stmt.group_sets
	if len(stmt.group_by) == 0 do return nil
	one := make([]int, len(stmt.group_by), alloc)
	for i in 0 ..< len(stmt.group_by) do one[i] = i
	sets := make([][]int, 1, alloc)
	sets[0] = one
	return sets
}

// grouping_missing_for marks the GROUP BY entries one set leaves out.
@(private)
grouping_missing_for :: proc(set: []int, count: int, alloc: mem.Allocator) -> []bool {
	missing := make([]bool, count, alloc)
	for i in 0 ..< count do missing[i] = true
	for index in set {
		if index >= 0 && index < count do missing[index] = false
	}
	return missing
}

eval_call :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	// A row value is taken apart by the comparison that holds it; reaching it
	// here means it stands alone, which SQLite refuses with the same words.
	if call.name == ROW_VALUE_CALL do return {}, errf(.Sql_Syntax, "row value misused")
	if scalar_minmax(call) {
		return eval_scalar_minmax(ctx, call)
	}
	if strings.equal_fold(call.name, "grouping") || strings.equal_fold(call.name, "grouping_id") {
		return eval_grouping(ctx, call)
	}
	if is_aggregate_name(call.name) {
		return eval_aggregate(ctx, call)
	}
	args := make([dynamic]Value, 0, len(call.args))
	defer delete(args)
	for arg in call.args {
		value, arg_err := eval_expr(ctx, arg)
		if arg_err.kind != .None do return {}, arg_err
		append(&args, value)
	}

	// JSON functions parse the document in json.odin.
	if json_call_name(call.name) {
		value, handled, json_err := json_call(call.name, args[:])
		if !handled do return {}, errf(.Internal, "unhandled JSON function %s", call.name)
		return value, json_err
	}
	// Date and time functions share the argument parsing in datetime.odin.
	if db_time_has_functions(call.name) {
		if strings.equal_fold(call.name, "strftime") {
			if len(args) < 2 {
				return {}, errf(.Invalid_Argument, "strftime() takes a format and a time")
			}
			if args[0].kind != .String {
				return {}, errf(.Invalid_Type, "strftime() expects a text format")
			}
			moment, ok := db_time_parse(args[1:])
			if !ok do return value_null(), ERROR_NONE
			return value_string(db_time_strftime(args[0].s, moment)), ERROR_NONE
		}
		value, _ := db_time_call(call.name, args[:])
		return value, ERROR_NONE
	}
	lowered := strings.to_lower(call.name)
	defer delete(lowered)
	// SQLite's other spellings of functions the engine has.
	dispatch := lowered
	switch lowered {
	case "if":
		dispatch = "iif"
	case "ceiling":
		dispatch = "ceil"
	case "power":
		dispatch = "pow"
	}
	switch dispatch {
	case "ln":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "ln() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "ln() expects a number")
		// SQLite answers NULL outside the domain.
		if number <= 0 do return value_null(), ERROR_NONE
		return value_float(math.ln(number)), ERROR_NONE
	case "likely", "unlikely", "likelihood":
		// Planner hints in SQLite: the value passes through unchanged.
		if len(args) < 1 do return {}, errf(.Invalid_Argument, "%s() needs an argument", call.name)
		return args[0], ERROR_NONE
	case "array_make":
		// ARRAY[...] in PostgreSQL: the elements keep their own kinds, and a
		// column of ARRAY(T) coerces them when the value is stored.
		items := make([]Value, len(args))
		for arg, i in args do items[i] = value_clone(arg, context.allocator)
		return Value{kind = .Array, list = items}, ERROR_NONE
	case "array_get":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "[] takes an array and an index")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .Array do return {}, errf(.Invalid_Type, "[] needs an array, got %s", value_kind_name(args[0].kind))
		index, index_ok := value_to_i64(args[1])
		if !index_ok do return {}, errf(.Invalid_Type, "[] needs an integer index")
		// One-based, as in PostgreSQL; an index outside the array is NULL rather
		// than an error, which is what a query with a computed index expects.
		if index < 1 || index > i64(len(args[0].list)) do return value_null(), ERROR_NONE
		return value_clone(args[0].list[int(index) - 1], context.allocator), ERROR_NONE
	case "array_length":
		if len(args) < 1 || len(args) > 2 {
			return {}, errf(.Invalid_Argument, "array_length takes an array and an optional dimension")
		}
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .Array {
			return {}, errf(.Invalid_Type, "array_length needs an array, got %s", value_kind_name(args[0].kind))
		}
		if len(args) == 2 {
			// Only one dimension exists here, so asking for another is NULL, as
			// PostgreSQL answers for a dimension the array does not have.
			if args[1].kind == .Null do return value_null(), ERROR_NONE
			dimension, dimension_ok := value_to_i64(args[1])
			if !dimension_ok do return {}, errf(.Invalid_Type, "array_length needs an integer dimension")
			if dimension != 1 do return value_null(), ERROR_NONE
		}
		return value_int(i64(len(args[0].list))), ERROR_NONE
	case "cardinality":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "cardinality takes one array")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .Array {
			return {}, errf(.Invalid_Type, "cardinality needs an array, got %s", value_kind_name(args[0].kind))
		}
		return value_int(i64(len(args[0].list))), ERROR_NONE
	case "array_contains", "array_contained", "array_overlap":
		return eval_array_relation(call.name, args[:])
	case "array_append", "array_prepend":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "%s takes an array and a value", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .Array {
			return {}, errf(.Invalid_Type, "%s needs an array", call.name)
		}
		items := make([]Value, len(args[0].list) + 1)
		offset := 0
		if call.name == "array_prepend" {
			items[0] = value_clone(args[1], context.allocator)
			offset = 1
		}
		for item, i in args[0].list do items[i + offset] = value_clone(item, context.allocator)
		if call.name == "array_append" {
			items[len(args[0].list)] = value_clone(args[1], context.allocator)
		}
		return Value{kind = .Array, list = items}, ERROR_NONE
	case "snippet", "highlight":
		if len(args) != 2 {
			return {}, errf(.Invalid_Argument, "%s() takes text and a pattern", call.name)
		}
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "%s() expects text for both arguments", call.name)
		}
		window := strings.equal_fold(call.name, "snippet")
		return value_string(fts_mark(args[0].s, args[1].s, window)), ERROR_NONE
	case "lower":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "lower() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "lower() expects text")
		return value_string(strings.to_lower(args[0].s)), ERROR_NONE
	case "upper":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "upper() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "upper() expects text")
		return value_string(strings.to_upper(args[0].s)), ERROR_NONE
	case "length", "char_length":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "length() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .String do return value_int(i64(text_char_count(args[0].s))), ERROR_NONE
		if args[0].kind == .Bytes do return value_int(i64(len(args[0].bytes))), ERROR_NONE
		return {}, errf(.Invalid_Type, "length() expects text or bytes")
	case "abs":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "abs() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .Float {
			return value_float(abs_f64(args[0].f)), ERROR_NONE
		}
		number, ok := value_to_i64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "abs() expects a number")
		// abs(min(i64)) has no answer in 64 bits; SQLite answers "integer
		// overflow" and so does this engine rather than return a negative.
		if number == min(i64) do return {}, integer_overflow_error()
		return value_int(number < 0 ? -number : number), ERROR_NONE
	case "substr", "substring":
		if len(args) < 2 || len(args) > 3 {
			return {}, errf(.Invalid_Argument, "substr() takes two or three arguments")
		}
		// NULL is not text and is not an error: SQLite answers NULL.
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if len(args) == 3 && args[2].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "substr() expects text")
		text := args[0].s
		start_value, ok := value_to_i64(args[1])
		if !ok do return {}, errf(.Invalid_Type, "substr() expects an integer start")
		chars := text_char_count(text)
		begin := int(start_value)
		if len(args) == 2 {
			// No length asks for the rest of the text. A start at or before the
			// first character (including zero) takes the whole string.
			if begin > 0 {
				begin -= 1
			} else if begin < 0 {
				begin += chars
			}
			if begin < 0 do begin = 0
			if begin > chars do begin = chars
			return value_string(text[text_byte_at(text, begin):]), ERROR_NONE
		}
		count_value, count_ok := value_to_i64(args[2])
		if !count_ok do return {}, errf(.Invalid_Type, "substr() expects an integer length")
		count := int(count_value)
		from_end := false
		if count < 0 {
			// A negative length is the number of characters before the start.
			count = -count
			from_end = true
		}
		if begin < 0 {
			begin += chars
			if begin < 0 {
				count += begin
				if count < 0 do count = 0
				begin = 0
			}
		} else if begin > 0 {
			begin -= 1
		} else if count > 0 {
			// A start of zero names the character before the first one, so a
			// positive length loses one character.
			count -= 1
		}
		if from_end {
			begin -= count
			if begin < 0 {
				count += begin
				begin = 0
			}
		}
		if begin > chars do begin = chars
		if count > chars do count = chars
		if begin + count > chars do count = chars - begin
		if count < 0 do count = 0
		return value_string(text[text_byte_at(text, begin):text_byte_at(text, begin + count)]), ERROR_NONE
	case "trim", "ltrim", "rtrim":
		if len(args) < 1 || len(args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes one or two arguments", call.name)
		}
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "%s() expects text", call.name)
		// The second argument is the set of characters to remove; the default is
		// the space, as in SQLite (not every whitespace).
		set := " "
		if len(args) == 2 {
			if args[1].kind == .Null do return value_null(), ERROR_NONE
			if args[1].kind != .String do return {}, errf(.Invalid_Type, "%s() expects a text set", call.name)
			set = args[1].s
		}
		text := args[0].s
		begin := 0
		end := len(text)
		lower := strings.to_lower(call.name)
		defer delete(lower)
		if lower != "rtrim" {
			for begin < end && strings.index_byte(set, text[begin]) >= 0 do begin += 1
		}
		if lower != "ltrim" {
			for end > begin && strings.index_byte(set, text[end - 1]) >= 0 do end -= 1
		}
		return value_string(strings.clone(text[begin:end])), ERROR_NONE
	case "replace":
		if len(args) != 3 do return {}, errf(.Invalid_Argument, "replace() takes three arguments")
		for arg in args do if arg.kind == .Null do return value_null(), ERROR_NONE
		for arg in args {
			if arg.kind != .String do return {}, errf(.Invalid_Type, "replace() expects text")
		}
		replaced, _ := strings.replace_all(args[0].s, args[1].s, args[2].s)
		return value_string(replaced), ERROR_NONE
	case "concat":
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		for arg in args {
			if arg.kind == .Null do continue
			strings.write_string(&builder, value_format(arg, context.temp_allocator))
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "sign":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sign() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if number, ok := value_to_f64(args[0]); ok {
			if number > 0 do return value_int(1), ERROR_NONE
			if number < 0 do return value_int(-1), ERROR_NONE
			return value_int(0), ERROR_NONE
		}
		return {}, errf(.Invalid_Type, "sign() expects a number")
	case "round":
		if len(args) < 1 || len(args) > 2 do return {}, errf(.Invalid_Argument, "round() takes one or two arguments")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "round() expects a number")
		digits := i64(0)
		if len(args) == 2 {
			parsed, digits_ok := value_to_i64(args[1])
			if !digits_ok do return {}, errf(.Invalid_Type, "round() expects an integer digit count")
			digits = parsed
		}
		scale := math.pow(10, f64(digits))
		return value_float(math.round(number * scale) / scale), ERROR_NONE
	case "floor", "ceil":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects a number", call.name)
		if strings.equal_fold(call.name, "floor") do return value_float(math.floor(number)), ERROR_NONE
		return value_float(math.ceil(number)), ERROR_NONE
	case "sqrt":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sqrt() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "sqrt() expects a number")
		if number < 0 do return {}, errf(.Invalid_Argument, "sqrt() needs a non-negative number")
		return value_float(math.sqrt(number)), ERROR_NONE
	case "sinh", "cosh", "tanh", "asinh", "acosh", "atanh":
		// The hyperbolic family, one argument. Outside its domain acosh and atanh
		// answer NULL, as SQLite does for a number with no answer.
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects a number", call.name)
		switch dispatch {
		case "sinh":
			return value_float(math.sinh(number)), ERROR_NONE
		case "cosh":
			return value_float(math.cosh(number)), ERROR_NONE
		case "tanh":
			return value_float(math.tanh(number)), ERROR_NONE
		case "asinh":
			return value_float(math.asinh(number)), ERROR_NONE
		case "acosh":
			if number < 1 do return value_null(), ERROR_NONE
			return value_float(math.acosh(number)), ERROR_NONE
		case "atanh":
			if number <= -1 || number >= 1 do return value_null(), ERROR_NONE
			return value_float(math.atanh(number)), ERROR_NONE
		}
		return value_null(), ERROR_NONE
	case "affinity":
		// SQLite's affinity() names the storage class the value has.
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "affinity() takes one argument")
		#partial switch args[0].kind {
		case .Int:
			return value_string(strings.clone("INTEGER", context.allocator)), ERROR_NONE
		case .Float:
			return value_string(strings.clone("REAL", context.allocator)), ERROR_NONE
		case .String:
			return value_string(strings.clone("TEXT", context.allocator)), ERROR_NONE
		case .Bytes:
			return value_string(strings.clone("BLOB", context.allocator)), ERROR_NONE
		}
		return value_string(strings.clone("BLOB", context.allocator)), ERROR_NONE
	case "unistr":
		// `\XXXX` is a UTF-16 code unit, `\+XXXXXX` and `\UXXXXXXXX` a code point,
		// and a doubled backslash is one backslash: what unistr_quote writes, unistr
		// reads.
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unistr() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		return value_string(unistr_decode(value_to_text(args[0]))), ERROR_NONE
	case "unistr_quote":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unistr_quote() takes one argument")
		if args[0].kind == .Null do return value_string(strings.clone("NULL", context.allocator)), ERROR_NONE
		return value_string(unistr_quote(value_to_text(args[0]))), ERROR_NONE
	case "timediff":
		// The difference as a signed calendar span, which is the form SQLite
		// answers: +YYYY-MM-DD HH:MM:SS.SSS.
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "timediff() takes two times")
		first, first_ok := db_time_parse(args[0:1])
		second, second_ok := db_time_parse(args[1:2])
		if !first_ok || !second_ok do return value_null(), ERROR_NONE
		return value_string(timediff_text(first, second)), ERROR_NONE
	case "soundex":
		// SQLite's soundex: the first letter, then one digit per consonant group,
		// three of them, zero-padded. Vowels and h, w, y separate groups without
		// earning a digit of their own.
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "soundex() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		text := value_to_text(args[0])
		return value_string(soundex_encode(text)), ERROR_NONE
	case "sqlite_source_id":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "sqlite_source_id() takes no arguments")
		return value_string(strings.clone("miraidb", context.allocator)), ERROR_NONE
	case "sqlite_compileoption_used":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sqlite_compileoption_used() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		option := value_to_text(args[0])
		used := strings.equal_fold(option, "MIRAIDB") || strings.equal_fold(option, "SQLITE_ENABLE_JSON1") ? 1 : 0
		return value_int(i64(used)), ERROR_NONE
	case "sqlite_compileoption_get":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "sqlite_compileoption_get() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		index, index_ok := value_to_i64(args[0])
		if !index_ok do return {}, errf(.Invalid_Type, "sqlite_compileoption_get() expects a number")
		// The one option there is, then nothing: a list ends the way a list ends.
		if index == 0 do return value_string(strings.clone("MIRAIDB", context.allocator)), ERROR_NONE
		return value_null(), ERROR_NONE
	case "pow":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "pow() takes two arguments")
		base, base_ok := value_to_f64(args[0])
		exponent, exponent_ok := value_to_f64(args[1])
		if !base_ok || !exponent_ok do return {}, errf(.Invalid_Type, "pow() expects numbers")
		return value_float(math.pow(base, exponent)), ERROR_NONE
	case "mod":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "mod() takes two arguments")
		left, left_ok := value_to_i64(args[0])
		right, right_ok := value_to_i64(args[1])
		if !left_ok || !right_ok do return {}, errf(.Invalid_Type, "mod() expects integers")
		if right == 0 do return {}, errf(.Invalid_Argument, "mod() by zero")
		return value_int(left % right), ERROR_NONE
	case "nullif":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "nullif() takes two arguments")
		if value_equal(args[0], args[1]) do return value_null(), ERROR_NONE
		return args[0], ERROR_NONE
	case "coalesce", "ifnull":
		for value in args {
			if value.kind != .Null do return value, ERROR_NONE
		}
		return value_null(), ERROR_NONE
	// The session functions a PostgreSQL client asks for on connect. The answers
	// name this engine, so a driver that logs them says what it talks to.
	case "version":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "version() takes no arguments")
		return value_string(ENGINE_VERSION_TEXT), ERROR_NONE
	case "current_database", "current_catalog":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "%s() takes no arguments", lowered)
		return value_string("miraidb"), ERROR_NONE
	case "current_schema":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "current_schema() takes no arguments")
		return value_string("public"), ERROR_NONE
	case "current_user", "session_user", "user":
		// The role name. An identity is not a role, so this is the one name a
		// session has; `current_identity()` is the caller the policies see.
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "%s takes no arguments", lowered)
		return value_string("miraidb"), ERROR_NONE
	case "pg_backend_pid":
		return value_int(0), ERROR_NONE
	case "now", "current_timestamp":
		if len(args) != 0 {
			return {}, errf(.Invalid_Argument, "now() takes no arguments")
		}
		return value_timestamp(Timestamp(ctx.now_us)), ERROR_NONE
	case "has_role":
		if len(args) != 1 {
			return {}, errf(.Invalid_Argument, "has_role() takes one argument")
		}
		if args[0].kind != .String {
			return {}, errf(.Invalid_Type, "has_role() expects a role name")
		}
		if ctx.tx == nil do return value_bool(false), ERROR_NONE
		holds, role_err := has_role(ctx.tx, args[0].s)
		if role_err.kind != .None do return {}, role_err
		return value_bool(holds), ERROR_NONE
	case "current_identity", "sender":
		if len(args) != 0 {
			return {}, errf(.Invalid_Argument, "current_identity() takes no arguments")
		}
		if ctx.tx == nil do return value_identity(Identity{}), ERROR_NONE
		return value_identity(ctx.tx.store.identity), ERROR_NONE
	case "uuid":
		return {}, errf(.Sql_Unsupported, "uuid() needs a randomness source the engine does not have")
	case "typeof":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "typeof() takes one argument")
		#partial switch args[0].kind {
		case .Null:
			return value_string("null"), ERROR_NONE
		case .Int, .Uint, .Bool, .Int128, .Uint128:
			return value_string("integer"), ERROR_NONE
		case .Float:
			return value_string("real"), ERROR_NONE
		case .Bytes:
			return value_string("blob"), ERROR_NONE
		}
		return value_string("text"), ERROR_NONE
	case "quote":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "quote() takes one argument")
		return value_string(sq_literal(args[0])), ERROR_NONE
	case "hex":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "hex() takes one argument")
		return value_string(sq_hex(args[0])), ERROR_NONE
	case "iif":
		if len(args) != 3 do return {}, errf(.Invalid_Argument, "iif() takes three arguments")
		truth, truth_err := sq_truthy(args[0])
		if truth_err.kind != .None do return {}, truth_err
		return args[1] if truth else args[2], ERROR_NONE
	case "sqlite_version":
		return value_string("3.54.1"), ERROR_NONE
	case "instr":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "instr() takes two arguments")
		// NULL first: the check after the type test could never be reached.
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "instr() expects text")
		}
		at := strings.index(args[0].s, args[1].s)
		if at < 0 do return value_int(0), ERROR_NONE
		// The answer is a character position, the offset found is a byte one.
		return value_int(i64(text_char_count(args[0].s[:at])) + 1), ERROR_NONE
	case "char":
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		for arg in args {
			// SQLite reads a NULL argument as code point 0.
			if arg.kind == .Null {
				strings.write_byte(&builder, 0)
				continue
			}
			if arg.kind != .Int do return {}, errf(.Invalid_Type, "char() expects integers")
			strings.write_rune(&builder, rune(arg.i))
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "changes":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "changes() takes no arguments")
		return value_int(ctx.tx.store.last_changes), ERROR_NONE
	case "last_insert_rowid":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "last_insert_rowid() takes no arguments")
		return value_int(ctx.tx.store.last_row_id), ERROR_NONE
	case "total_changes":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "total_changes() takes no arguments")
		return value_int(ctx.tx.store.total_changes), ERROR_NONE
	case "log", "log10", "log2", "exp", "sin", "cos", "tan", "asin", "acos", "atan", "degrees", "radians", "trunc":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		number, ok := value_to_f64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects a number", call.name)
		inner_lower := strings.to_lower(call.name)
		defer delete(inner_lower)
		switch inner_lower {
		case "log", "log10":
			if number <= 0 do return value_null(), ERROR_NONE
			return value_float(math.log10(number)), ERROR_NONE
		case "log2":
			if number <= 0 do return value_null(), ERROR_NONE
			return value_float(math.log2(number)), ERROR_NONE
		case "exp":
			return value_float(math.exp(number)), ERROR_NONE
		case "sin":
			return value_float(math.sin(number)), ERROR_NONE
		case "cos":
			return value_float(math.cos(number)), ERROR_NONE
		case "tan":
			return value_float(math.tan(number)), ERROR_NONE
		case "asin":
			return value_float(math.asin(number)), ERROR_NONE
		case "acos":
			return value_float(math.acos(number)), ERROR_NONE
		case "atan":
			return value_float(math.atan(number)), ERROR_NONE
		case "degrees":
			return value_float(number * 180 / math.PI), ERROR_NONE
		case "radians":
			return value_float(number * math.PI / 180), ERROR_NONE
		case "trunc":
			return value_float(math.trunc(number)), ERROR_NONE
		case:
		}
		return {}, errf(.Internal, "unknown math function %s", call.name)
	case "atan2":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "atan2() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		y, y_ok := value_to_f64(args[0])
		x, x_ok := value_to_f64(args[1])
		if !y_ok || !x_ok do return {}, errf(.Invalid_Type, "atan2() expects numbers")
		return value_float(math.atan2(y, x)), ERROR_NONE
	case "pi":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "pi() takes no arguments")
		return value_float(math.PI), ERROR_NONE
	case "octet_length":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "octet_length() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind == .String do return value_int(i64(len(args[0].s))), ERROR_NONE
		if args[0].kind == .Bytes do return value_int(i64(len(args[0].bytes))), ERROR_NONE
		text := value_format(args[0], context.allocator)
		defer delete(text)
		return value_int(i64(len(text))), ERROR_NONE
	case "unicode":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unicode() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		text := args[0].kind == .String ? strings.clone(args[0].s) : value_format(args[0], context.allocator)
		defer delete(text)
		if len(text) == 0 do return value_null(), ERROR_NONE
		char, _ := utf8.decode_rune_in_string(text)
		return value_int(i64(char)), ERROR_NONE
	case "unhex":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "unhex() takes one argument")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		text := args[0].kind == .String ? args[0].s : value_format(args[0], context.allocator)
		cloned := args[0].kind != .String
		defer if cloned do delete(text)
		if len(text) % 2 != 0 do return value_null(), ERROR_NONE
		out := make([]u8, len(text) / 2, context.allocator)
		for i in 0 ..< len(out) {
			high, high_ok := sql_hex_digit(text[i * 2])
			low, low_ok := sql_hex_digit(text[i * 2 + 1])
			if !high_ok || !low_ok do return value_null(), ERROR_NONE
			out[i] = u8(high << 4 | low)
		}
		return value_bytes(out), ERROR_NONE
	case "zeroblob", "randomblob":
		if len(args) != 1 do return {}, errf(.Invalid_Argument, "%s() takes one argument", call.name)
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		size, ok := value_to_i64(args[0])
		if !ok do return {}, errf(.Invalid_Type, "%s() expects an integer", call.name)
		if size < 0 do return value_null(), ERROR_NONE
		if size > 1 << 20 do size = 1 << 20
		buffer := make([]u8, int(size), context.allocator)
		if strings.equal_fold(call.name, "randomblob") {
			for i in 0 ..< len(buffer) do buffer[i] = u8(rng_next())
		}
		return value_bytes(buffer), ERROR_NONE
	case "random":
		if len(args) != 0 do return {}, errf(.Invalid_Argument, "random() takes no arguments")
		return value_int(i64(rng_next())), ERROR_NONE
	case "concat_ws":
		if len(args) < 2 do return {}, errf(.Invalid_Argument, "concat_ws() takes a separator and values")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		separator := value_format(args[0], context.allocator)
		defer delete(separator)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		first := true
		for arg in args[1:] {
			if arg.kind == .Null do continue
			if !first do strings.write_string(&builder, separator)
			piece := value_format(arg, context.allocator)
			strings.write_string(&builder, piece)
			delete(piece)
			first = false
		}
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	case "like":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "like() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "like() expects text")
		}
		return value_bool(like_match(args[1].s, args[0].s, true, 0)), ERROR_NONE
	case "glob":
		if len(args) != 2 do return {}, errf(.Invalid_Argument, "glob() takes two arguments")
		if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String || args[1].kind != .String {
			return {}, errf(.Invalid_Type, "glob() expects text")
		}
		return value_bool(glob_match(args[1].s, args[0].s)), ERROR_NONE
	case "format", "printf":
		if len(args) == 0 do return {}, errf(.Invalid_Argument, "format() needs a pattern")
		if args[0].kind == .Null do return value_null(), ERROR_NONE
		if args[0].kind != .String do return {}, errf(.Invalid_Type, "format() expects a text pattern")
		return value_string(sq_format(args[0].s, args[1:])), ERROR_NONE
	}
	// A host function answers last, so the builtins keep their names. The count is
	// checked here rather than in the handler: a wrong number of arguments is the
	// caller's mistake, and every handler would have to write the same check.
	if ctx.tx != nil && ctx.tx.store != nil {
		if def, found := store_function(ctx.tx.store, call.name); found {
			if def.arity >= 0 && len(args) != def.arity {
				return {}, errf(
					.Invalid_Argument,
					"%s() takes %d arguments",
					call.name,
					def.arity,
				)
			}
			return def.handler(args[:], def.user)
		}
	}
	return {}, errf(.Sql_Unsupported, "unknown function %s", call.name)
}

@(private)
abs_f64 :: proc(f: f64) -> f64 {
	return f < 0 ? -f : f
}

// eval_scalar_minmax is min(a, b, ...) as SQLite answers it: NULL if any
// argument is NULL, otherwise the smallest or largest of them.
// arrays_from_text turns a text operand into an array when the other side is
// one and the text is written as PostgreSQL's array input. Anything else is left
// alone, so a text column compared with text still compares as text.
@(private)
arrays_from_text :: proc(left, right: Value) -> (Value, Value) {
	if left.kind == .Array && right.kind == .String {
		if parsed, err := array_parse_text(right.s, array_element_type(left)); err.kind == .None {
			return left, parsed
		}
	}
	if right.kind == .Array && left.kind == .String {
		if parsed, err := array_parse_text(left.s, array_element_type(right)); err.kind == .None {
			return parsed, right
		}
	}
	return left, right
}

// array_element_type is the type of an array's elements, read from the elements
// themselves: the engine stores kinds, not a declared element type.
@(private)
array_element_type :: proc(array: Value) -> Column_Type {
	for item in array.list {
		#partial switch item.kind {
		case .Null:
			continue
		case .Int:
			return Column_Type{kind = .Int, width = 8}
		case .Uint:
			return Column_Type{kind = .Uint, width = 8}
		case .Float:
			return Column_Type{kind = .Float, width = 8}
		case .Bool:
			return Column_Type{kind = .Bool}
		case .Bytes:
			return Column_Type{kind = .Bytes}
		case:
			return Column_Type{kind = .String}
		}
	}
	return Column_Type{kind = .String}
}

// array_concat implements `||` when either side is an array: two arrays join
// their elements, and a single value is appended or prepended.
@(private)
array_concat :: proc(left, right: Value) -> (Value, Error) {
	if left.kind == .Null || right.kind == .Null do return value_null(), ERROR_NONE
	if left.kind != .Array && right.kind != .Array {
		return {}, errf(.Invalid_Type, "|| needs text or an array")
	}
	left_items := left.kind == .Array ? left.list : ([]Value{left})
	right_items := right.kind == .Array ? right.list : ([]Value{right})
	items := make([]Value, len(left_items) + len(right_items))
	for item, i in left_items do items[i] = value_clone(item, context.allocator)
	for item, i in right_items do items[i + len(left_items)] = value_clone(item, context.allocator)
	return Value{kind = .Array, list = items}, ERROR_NONE
}

// array_relation answers PostgreSQL's set operators: `@>` contains, `<@` is
// contained by, `&&` overlaps. One function for all three, because the only
// difference is which side is searched.
@(private)
eval_array_relation :: proc(name: string, args: []Value) -> (Value, Error) {
	if len(args) != 2 do return {}, errf(.Invalid_Argument, "%s takes two arrays", name)
	if args[0].kind == .Null || args[1].kind == .Null do return value_null(), ERROR_NONE
	// A driver that did not know the parameter's type sends `{b}` as text; the
	// array on the other side says what its elements are.
	first, second := args[0], args[1]
	if first.kind == .Array && second.kind == .String {
		if parsed, err := array_parse_text(second.s, array_element_type(first)); err.kind == .None {
			second = parsed
		}
	}
	if second.kind == .Array && first.kind == .String {
		if parsed, err := array_parse_text(first.s, array_element_type(second)); err.kind == .None {
			first = parsed
		}
	}
	container := first
	needle := second
	if name == "array_contained" {
		container = args[1]
		needle = args[0]
	}
	if container.kind != .Array || (needle.kind != .Array && needle.kind == .Null) {
		if container.kind != .Array {
			return {}, errf(.Invalid_Type, "%s needs an array on both sides", name)
		}
	}
	if name == "array_overlap" {
		if first.kind != .Array || second.kind != .Array {
			return {}, errf(.Invalid_Type, "&& needs an array on both sides")
		}
		for one in first.list {
			for other in second.list {
				if value_equal(one, other) do return value_bool(true), ERROR_NONE
			}
		}
		return value_bool(false), ERROR_NONE
	}
	// `a @> b` is b a subset of a, and `a @> scalar` is a holding that value.
	candidates := needle.kind == .Array ? needle.list : ([]Value{needle})
	for candidate in candidates {
		found := false
		for element in container.list {
			if value_equal(element, candidate) {
				found = true
				break
			}
		}
		if !found do return value_bool(false), ERROR_NONE
	}
	return value_bool(true), ERROR_NONE
}

@(private)
eval_scalar_minmax :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	want_min := strings.equal_fold(call.name, "min")
	best: Value
	have := false
	for arg in call.args {
		value, eval_err := eval_expr(ctx, arg)
		if eval_err.kind != .None do return {}, eval_err
		if value.kind == .Null do return value_null(), ERROR_NONE
		if !have {
			best = value
			have = true
			continue
		}
		order, comparable := value_compare(value, best)
		if !comparable {
			return {}, errf(.Invalid_Type, "%s() mixes incompatible types", call.name)
		}
		if (want_min && order == .Less) || (!want_min && order == .Greater) do best = value
	}
	return value_clone(best, context.allocator), ERROR_NONE
}

eval_aggregate :: proc(ctx: ^Eval_Ctx, call: Call_Expr) -> (Value, Error) {
	if ctx.stream != nil {
		acc := agg_stream_lookup(ctx.stream, call)
		if acc == nil {
			return {}, errf(.Internal, "aggregate %s was not accumulated by the scan", call.name)
		}
		return agg_stream_value(acc)
	}
	name := strings.to_lower(call.name)
	defer delete(name)
	rows := ctx.group
	single_rows: [1][]Source
	if !ctx.grouped {
		single_rows[0] = ctx.sources
		rows = single_rows[:]
	}

	if name == "count" {
		if call.star || len(call.args) == 0 {
			return value_int(i64(len(rows))), ERROR_NONE
		}
		count := 0
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, eval_err := eval_expr(&sub, call.args[0])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind == .Null do continue
			if call.is_distinct {
				key := agg_distinct_key(value)
				_, repeated := keys[key]
				if repeated {
					delete(key)
				} else {
					keys[key] = true
				}
				if repeated do continue
			}
			count += 1
		}
		return value_int(i64(count)), ERROR_NONE
	}

	if name == "json_group_array" {
		if call.star || len(call.args) != 1 {
			return {}, errf(.Invalid_Argument, "json_group_array() takes one argument")
		}
		items := make([dynamic]Json_Value, 0, len(rows))
		defer delete(items)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, value_err := eval_expr(&sub, call.args[0])
			if value_err.kind != .None do return {}, value_err
			append(&items, json_from_value(value, context.temp_allocator))
		}
		text := json_write(Json_Value{kind = .Array, items = items[:]}, context.allocator)
		return value_string(text), ERROR_NONE
	}
	if name == "median" || name == "percentile" || name == "percentile_cont" ||
	   name == "percentile_disc" {
		// The ordered aggregates SQLite 3.51 added: median(Y) is the 0.5
		// percentile, percentile_cont interpolates between two values and
		// percentile_disc takes one, and percentile() reads its argument as a
		// percentage where the other two read a fraction.
		if call.star || len(call.args) < 1 || len(call.args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes a value and a fraction", name)
		}
		fraction := 0.5
		if len(call.args) == 2 {
			value, value_err := eval_expr(ctx, call.args[1])
			if value_err.kind != .None do return {}, value_err
			number, ok := value_to_f64(value)
			if !ok do return {}, errf(.Invalid_Type, "%s() expects a number as its fraction", name)
			fraction = strings.equal_fold(name, "percentile") ? number / 100 : number
			if fraction < 0 || fraction > 1 {
				return {}, errf(
					.Invalid_Argument,
					"the fraction argument to %s() is not between 0.0 and 1.0",
					name,
				)
			}
		}
		numbers := make([dynamic]f64, 0, len(rows))
		defer delete(numbers)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, value_err := eval_expr(&sub, call.args[0])
			if value_err.kind != .None do return {}, value_err
			if value.kind == .Null do continue
			number, ok := value_to_f64(value)
			if !ok do return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			append(&numbers, number)
		}
		if len(numbers) == 0 do return value_null(), ERROR_NONE
		slice.sort(numbers[:])
		if strings.equal_fold(name, "percentile_disc") {
			index := int(math.floor(fraction * f64(len(numbers) - 1)))
			return value_float(numbers[index]), ERROR_NONE
		}
		position := fraction * f64(len(numbers) - 1)
		low := int(math.floor(position))
		high := int(math.ceil(position))
		if low == high do return value_float(numbers[low]), ERROR_NONE
		weight := position - f64(low)
		return value_float(numbers[low] * (1 - weight) + numbers[high] * weight), ERROR_NONE
	}
	if name == "json_group_object" {
		if len(call.args) != 2 {
			return {}, errf(.Invalid_Argument, "json_group_object() takes a key and a value")
		}
		keys := make([dynamic]string, 0, len(rows))
		defer delete(keys)
		items := make([dynamic]Json_Value, 0, len(rows))
		defer delete(items)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			key, key_err := eval_expr(&sub, call.args[0])
			if key_err.kind != .None do return {}, key_err
			if key.kind == .Null do continue
			value, value_err := eval_expr(&sub, call.args[1])
			if value_err.kind != .None do return {}, value_err
			append(&keys, value_to_text(key))
			append(&items, json_from_value(value, context.temp_allocator))
		}
		text := json_write(Json_Value{kind = .Object, keys = keys[:], values = items[:]}, context.allocator)
		return value_string(text), ERROR_NONE
	}
	if name == "median" || name == "percentile" || name == "percentile_cont" ||
	   name == "percentile_disc" {
		// The ordered aggregates SQLite 3.51 added: median(Y) is the 0.5
		// percentile, percentile_cont interpolates between two values and
		// percentile_disc takes one, and percentile() reads its argument as a
		// percentage where the other two read a fraction.
		if call.star || len(call.args) < 1 || len(call.args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes a value and a fraction", name)
		}
		fraction := 0.5
		if len(call.args) == 2 {
			value, value_err := eval_expr(ctx, call.args[1])
			if value_err.kind != .None do return {}, value_err
			number, ok := value_to_f64(value)
			if !ok do return {}, errf(.Invalid_Type, "%s() expects a number as its fraction", name)
			fraction = strings.equal_fold(name, "percentile") ? number / 100 : number
			if fraction < 0 || fraction > 1 {
				return {}, errf(
					.Invalid_Argument,
					"the fraction argument to %s() is not between 0.0 and 1.0",
					name,
				)
			}
		}
		numbers := make([dynamic]f64, 0, len(rows))
		defer delete(numbers)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, value_err := eval_expr(&sub, call.args[0])
			if value_err.kind != .None do return {}, value_err
			if value.kind == .Null do continue
			number, ok := value_to_f64(value)
			if !ok do return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			append(&numbers, number)
		}
		if len(numbers) == 0 do return value_null(), ERROR_NONE
		slice.sort(numbers[:])
		if strings.equal_fold(name, "percentile_disc") {
			index := int(math.floor(fraction * f64(len(numbers) - 1)))
			return value_float(numbers[index]), ERROR_NONE
		}
		position := fraction * f64(len(numbers) - 1)
		low := int(math.floor(position))
		high := int(math.ceil(position))
		if low == high do return value_float(numbers[low]), ERROR_NONE
		weight := position - f64(low)
		return value_float(numbers[low] * (1 - weight) + numbers[high] * weight), ERROR_NONE
	}
	if name == "json_group_object" {
		// One document from the group: the first argument is the key, the second
		// the value, and a NULL key is skipped as SQLite skips it.
		if len(call.args) != 2 {
			return {}, errf(.Invalid_Argument, "json_group_object() takes a key and a value")
		}
		keys := make([dynamic]string, 0, len(rows))
		defer delete(keys)
		items := make([dynamic]Json_Value, 0, len(rows))
		defer delete(items)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			key, key_err := eval_expr(&sub, call.args[0])
			if key_err.kind != .None do return {}, key_err
			if key.kind == .Null do continue
			value, value_err := eval_expr(&sub, call.args[1])
			if value_err.kind != .None do return {}, value_err
			append(&keys, value_to_text(key))
			append(&items, json_from_value(value, context.temp_allocator))
		}
		text := json_write(Json_Value{kind = .Object, keys = keys[:], values = items[:]}, context.allocator)
		return value_string(text), ERROR_NONE
	}

	if name == "group_concat" || name == "string_agg" {
		if call.star || len(call.args) < 1 || len(call.args) > 2 {
			return {}, errf(.Invalid_Argument, "%s() takes one or two arguments", name)
		}
		separator := ","
		separator_text: string
		if len(call.args) == 2 {
			value, eval_err := eval_expr(ctx, call.args[1])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind != .Null {
				separator_text = value_format(value, context.allocator)
				separator = separator_text
			}
		}
		defer if len(separator_text) > 0 do delete(separator_text)
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		seen_any := false
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			value, eval_err := eval_expr(&sub, call.args[0])
			if eval_err.kind != .None do return {}, eval_err
			if value.kind == .Null do continue
			if call.is_distinct {
				key := agg_distinct_key(value)
				_, repeated := keys[key]
				if repeated {
					delete(key)
				} else {
					keys[key] = true
				}
				if repeated do continue
			}
			if seen_any do strings.write_string(&builder, separator)
			piece := value_format(value, context.allocator)
			strings.write_string(&builder, piece)
			delete(piece)
			seen_any = true
		}
		if !seen_any do return value_null(), ERROR_NONE
		return value_string(strings.clone(strings.to_string(builder))), ERROR_NONE
	}

	if name == "array_agg" {
		// The same aggregate over sources: every row's value, NULLs included,
		// and NULL for an empty set.
		keys: map[string]bool
		if call.is_distinct do keys = make(map[string]bool)
		defer agg_distinct_destroy(&keys)
		list := make([dynamic]Value, 0, len(rows))
		defer {
			for item in list do value_deep_free(item, context.allocator)
			delete(list)
		}
		for sources in rows {
			sub := ctx^
			sub.sources = sources
			if len(call.args) != 1 {
				return {}, errf(.Invalid_Argument, "%s() takes exactly one argument", name)
			}
			value, eval_err := eval_expr(&sub, call.args[0])
			if eval_err.kind != .None do return {}, eval_err
			if call.is_distinct {
				key := agg_distinct_key(value)
				_, repeated := keys[key]
				if repeated {
					delete(key)
					continue
				}
				keys[key] = true
			}
			append(&list, value_clone(value, context.allocator))
		}
		if len(list) == 0 do return value_null(), ERROR_NONE
		items := make([]Value, len(list))
		for item, i in list do items[i] = item
		// The list's buffer is freed above; the values moved into `items`.
		clear(&list)
		return Value{kind = .Array, list = items}, ERROR_NONE
	}

	accumulator: Value = value_null()
	seen := 0
	sum_float := f64(0)
	sum_int := i64(0)
	sum_128 := i128(0)
	uses_float := false
	uses_128 := false
	keys: map[string]bool
	if call.is_distinct do keys = make(map[string]bool)
	defer agg_distinct_destroy(&keys)
	for sources in rows {
		sub := ctx^
		sub.sources = sources
		if len(call.args) != 1 {
			return {}, errf(.Invalid_Argument, "%s() takes exactly one argument", name)
		}
		value, eval_err := eval_expr(&sub, call.args[0])
		if eval_err.kind != .None do return {}, eval_err
		if value.kind == .Null do continue
		if call.is_distinct {
			key := agg_distinct_key(value)
			_, repeated := keys[key]
			if repeated {
				delete(key)
			} else {
				keys[key] = true
			}
			if repeated do continue
		}
		seen += 1
		switch name {
		case "min":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "min() mixes incompatible types")
				if order == .Less do accumulator = value
			}
		case "max":
			if accumulator.kind == .Null {
				accumulator = value
			} else {
				order, ok := value_compare(value, accumulator)
				if !ok do return {}, errf(.Invalid_Type, "max() mixes incompatible types")
				if order == .Greater do accumulator = value
			}
		case "sum", "total", "avg":
			if !value_is_numeric(value) {
				return {}, errf(.Invalid_Type, "%s() expects numbers", name)
			}
			if value.kind == .Float {
				uses_float = true
				number, _ := value_to_f64(value)
				sum_float += number
			} else if value.kind == .Int128 || value.kind == .Uint128 {
				if !uses_128 {
					uses_128 = true
					sum_128 = i128(sum_int)
				}
				sum_128 += value_as_i128(value)
			} else if uses_float {
				number, _ := value_to_f64(value)
				sum_float += number
			} else if uses_128 {
				number, _ := value_to_i64(value)
				sum_128 += i128(number)
			} else {
				number, _ := value_to_i64(value)
				sum_int += number
			}
		}
	}
	switch name {
	case "min", "max":
		return value_clone(accumulator, context.allocator), ERROR_NONE
	case "sum", "total":
		if seen == 0 do return value_null(), ERROR_NONE
		if uses_float do return value_float(sum_float), ERROR_NONE
		if uses_128 do return value_int128(sum_128), ERROR_NONE
		return value_int(sum_int), ERROR_NONE
	case "avg":
		if seen == 0 do return value_null(), ERROR_NONE
		total := uses_float ? sum_float : (uses_128 ? f64(sum_128) : f64(sum_int))
		return value_float(total / f64(seen)), ERROR_NONE
	}
	return {}, errf(.Internal, "unknown aggregate %s", name)
}

// glob_match implements SQLite's GLOB: case sensitive, * matches any run, ?
// matches one character and [...] is a character class (^ negates it).
glob_match :: proc(text, pattern: string) -> bool {
	return glob_here(text, pattern)
}

@(private)
glob_here :: proc(text_in, pattern_in: string) -> bool {
	text := text_in
	pattern := pattern_in
	for len(pattern) > 0 {
		switch pattern[0] {
		case '*':
			for len(pattern) > 0 && pattern[0] == '*' {
				pattern = pattern[1:]
			}
			if len(pattern) == 0 do return true
			for i in 0 ..= len(text) {
				if glob_here(text[i:], pattern) do return true
			}
			return false
		case '?':
			if len(text) == 0 do return false
			text = text[1:]
			pattern = pattern[1:]
		case '[':
			if len(text) == 0 do return false
			closing := strings.index_byte(pattern, ']')
			if closing < 0 {
				if text[0] != '[' do return false
				text = text[1:]
				pattern = pattern[1:]
				continue
			}
			body := pattern[1:closing]
			negate := len(body) > 0 && body[0] == '^'
			if negate do body = body[1:]
			member := false
			i := 0
			for i < len(body) {
				if i + 2 < len(body) && body[i + 1] == '-' {
					if text[0] >= body[i] && text[0] <= body[i + 2] do member = true
					i += 3
				} else {
					if text[0] == body[i] do member = true
					i += 1
				}
			}
			if member == negate do return false
			text = text[1:]
			pattern = pattern[closing + 1:]
		case:
			if len(text) == 0 || text[0] != pattern[0] do return false
			text = text[1:]
			pattern = pattern[1:]
		}
	}
	return len(text) == 0
}

// like_match implements SQL LIKE with % and _, an optional escape character,
// and case folding. The pattern is tokenized first so an escaped wildcard is a
// literal even when the matcher backtracks.
like_match :: proc(text, pattern: string, case_insensitive: bool, escape: u8 = 0) -> bool {
	t := text
	p := pattern
	if case_insensitive {
		t = strings.to_lower(text)
		p = strings.to_lower(pattern)
	}
	Like_Token_Kind :: enum u8 {
		Literal,
		Any,
		Star,
	}
	Like_Token :: struct {
		kind: Like_Token_Kind,
		ch:   u8,
	}
	tokens := make([dynamic]Like_Token, 0, len(p))
	defer delete(tokens)
	for i := 0; i < len(p); i += 1 {
		ch := p[i]
		if escape != 0 && ch == escape && i + 1 < len(p) {
			i += 1
			append(&tokens, Like_Token{kind = .Literal, ch = p[i]})
			continue
		}
		switch ch {
		case '%':
			append(&tokens, Like_Token{kind = .Star})
		case '_':
			append(&tokens, Like_Token{kind = .Any})
		case:
			append(&tokens, Like_Token{kind = .Literal, ch = ch})
		}
	}
	ti := 0
	pi := 0
	star := -1
	match := 0
	for ti < len(t) {
		if pi < len(tokens) {
			token := tokens[pi]
			if token.kind == .Any || (token.kind == .Literal && token.ch == t[ti]) {
				ti += 1
				pi += 1
				continue
			}
			if token.kind == .Star {
				star = pi
				match = ti
				pi += 1
				continue
			}
		}
		if star != -1 {
			pi = star + 1
			match += 1
			ti = match
			continue
		}
		return false
	}
	for pi < len(tokens) && tokens[pi].kind == .Star do pi += 1
	return pi == len(tokens)
}

// --- INSERT / UPDATE / DELETE ----------------------------------------------

// find_conflict_row locates the row an UPSERT collided with: the primary key
// columns compared against the incoming values.
@(private)
find_conflict_row :: proc(tx: ^Tx, table: ^Table, values: []Value) -> (Row, bool) {
	if len(table.schema.primary_key) == 0 do return {}, false
	// A paged table has no row map, so both backends answer through a collect.
	// The values live in the transaction arena and stay valid for the statement.
	rows := make([dynamic]Row)
	defer delete(rows)
	table_collect(table, &rows, max(u64), tx.alloc)
	for row in rows {
		matches := true
		for position in table.schema.primary_key {
			if position >= len(row.values) || position >= len(values) {
				matches = false
				break
			}
			if !value_equal(row.values[position], values[position]) {
				matches = false
				break
			}
		}
		if matches do return row, true
	}
	return {}, false
}


// unique_conflicts collects the rows an INSERT OR REPLACE deletes: every row
// that shares a key with the proposed values in a unique index. One row can
// collide under two indexes, so it is listed once.
@(private)
unique_conflicts :: proc(tx: ^Tx, table: ^Table, values: []Value) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id, 0, 2, tx.alloc)
	for idx, i in table.indexes {
		if !idx.unique do continue
		if !index_row_included(table, i, values) do continue
		found := table_index_lookup(table, i, values)
		for id in found {
			seen := false
			for existing in ids {
				if existing == id {
					seen = true
					break
				}
			}
			if !seen do append(&ids, id)
		}
		delete(found)
	}
	return ids
}

// row_with_defaults gives a row with every DEFAULT the statement left implicit
// filled in, coerced to the column's type, as tx_insert would store it.
@(private)
row_with_defaults :: proc(tx: ^Tx, table: ^Table, values: []Value) -> []Value {
	out := make([]Value, len(values), tx.alloc)
	for value, i in values {
		out[i] = value
		if value.kind != .Default || i >= len(table.schema.columns) do continue
		column := table.schema.columns[i]
		filled, fill_err := column_default_for_row(tx, column)
		if fill_err.kind != .None {
			error_free(&fill_err)
			out[i] = value_null()
			continue
		}
		coerced, coerce_err := value_coerce(filled, column.type)
		if coerce_err.kind != .None {
			error_free(&coerce_err)
			out[i] = filled
			continue
		}
		out[i] = coerced
	}
	return out
}

@(private)
returning_append :: proc(
	result: ^Sql_Result,
	rows: ^[dynamic][]Value,
	returning: ^Returning,
	table: ^Table,
	row: Row,
) -> Error {
	if returning == nil do return ERROR_NONE
	if result.kind != .Rows {
		result.kind = .Rows
		if returning.star {
			result.columns = make([]string, len(table.schema.columns))
			for column, i in table.schema.columns {
				result.columns[i] = strings.clone(column.name)
			}
		} else {
			result.columns = make([]string, len(returning.columns))
			for name, i in returning.columns {
				if _, found := schema_column_index(&table.schema, name); !found {
					return errf(.Column_Not_Found, "column %s does not exist in %s", name, table.schema.name)
				}
				result.columns[i] = strings.clone(name)
			}
		}
	}
	values := make([]Value, len(result.columns))
	if returning.star {
		for value, i in row.values {
			if i >= len(values) do break
			values[i] = value_clone(value, context.allocator)
		}
	} else {
		for name, i in returning.columns {
			index, _ := schema_column_index(&table.schema, name)
			values[i] = value_clone(row.values[index], context.allocator)
		}
	}
	append(rows, values)
	return ERROR_NONE
}


sql_exec_insert :: proc(tx: ^Tx, stmt: Insert_Stmt, params: []Value) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	column_count := len(table.schema.columns)
	positions: []int
	if len(stmt.columns) == 0 {
		positions = make([]int, column_count, tx.alloc)
		for i in 0 ..< column_count do positions[i] = i
	} else {
		positions = make([]int, len(stmt.columns), tx.alloc)
		for name, i in stmt.columns {
			index, found := schema_column_index(&table.schema, name)
			if !found {
				return {}, errf(.Column_Not_Found, "column %s does not exist in %s", name, stmt.table)
			}
			if table.schema.columns[index].generated {
				return {}, errf(
					.Invalid_Argument,
					"column %s is generated: it cannot be written directly",
					name,
				)
			}
			positions[i] = index
		}
	}
	ctx := Eval_Ctx {
		tx     = tx,
		params = params,
		now_us = now_microseconds(),
	}
	policies, policy_err := policy_load(tx, stmt.table)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	generated, generated_err := generated_plan_make(tx, table)
	if generated_err.kind != .None do return {}, generated_err
	defer generated_plan_destroy(&generated)
	insert_rows := stmt.rows
	if stmt.has_select {
		// The VALUES path is reused: each row the query produces becomes a row
		// of literals, so coercion, policies, UPSERT and RETURNING are shared.
		query, query_err := sql_exec_select(tx, stmt.select_stmt, params)
		if query_err.kind != .None do return {}, query_err
		rows := make([dynamic][]^Expr, 0, len(query.rows), tx.alloc)
		for row in query.rows {
			if len(row) != len(positions) {
				return {}, errf(
					.Invalid_Argument,
					"INSERT has %d columns but SELECT produced %d",
					len(positions),
					len(row),
				)
			}
			exprs := make([]^Expr, len(row), tx.alloc)
			for value, i in row {
				literal := new(Expr, tx.alloc)
				literal^ = Literal_Expr{value = value}
				exprs[i] = literal
			}
			append(&rows, exprs)
		}
		insert_rows = rows[:]
	}
	result := Sql_Result{kind = .Affected}
	returned := make([dynamic][]Value, 0, len(insert_rows))
	// A statement without RETURNING builds this and never fills it: the array is the
	// statement's, not the result's, unless the result takes it at the end.
	if stmt.returning == nil do defer delete(returned)
	for values_expr in insert_rows {
		if len(values_expr) != len(positions) {
			return {}, errf(
				.Invalid_Argument,
				"INSERT has %d columns but %d values",
				len(positions),
				len(values_expr),
			)
		}
		values := make([]Value, column_count, tx.alloc)
		for i in 0 ..< column_count do values[i] = value_default()
		for expr, i in values_expr {
			value, eval_err := eval_expr(&ctx, expr)
			if eval_err.kind != .None do return {}, eval_err
			values[positions[i]] = value
		}
		// Generated columns are computed from the row about to be stored, so a
		// caller never supplies them and CHECK sees the final values.
		if apply_err := generated_plan_apply(&ctx, &generated, table, values); apply_err.kind != .None {
			return {}, apply_err
		}
		// The stored row is already coerced, so the CHECK predicate sees the
		// values the table would hold. Under OR FAIL a row is its own unit: if it
		// fails, what it staged (a trigger's work included) is taken back and the
		// rows before it stay.
		row_mark := stmt.conflict_fail ? tx_statement_begin(tx) : 0
		row_id, insert_err := tx_insert(tx, stmt.table, values)
		if stmt.conflict_fail do tx_statement_end(tx, row_mark, insert_err.kind != .None)
		if insert_err.kind != .None && stmt.conflict_ignore && conflict_skippable(insert_err.kind) {
			// INSERT OR IGNORE: the row breaks a constraint by itself and is skipped;
			// nothing of it was staged.
			error_free(&insert_err)
			continue
		}
		if insert_err.kind == .None {
			if fts_err := fts_index_if_virtual(tx, stmt.table, row_id, values, true); fts_err.kind != .None {
				return {}, fts_err
			}
		}
		if insert_err.kind != .None && stmt.conflict_replace {
			// INSERT OR REPLACE: delete what the new row collides with, on any
			// unique index, and insert again. SQLite counts one affected row and
			// fires no delete trigger, which is what happens here: the deletes go
			// through the staging layer, not through the DELETE statement.
			//
			// The duplicate-key answer explained the first attempt, and this branch
			// answers the statement instead: its message is freed here.
			// The conflicts are looked up with the row as it would be stored: a
			// column the statement left out holds its default, which a key or a
			// partial index's WHERE may read.
			conflicts := unique_conflicts(tx, table, row_with_defaults(tx, table, values))
			defer delete(conflicts)
			// Without a row to replace the failure stands; it used to be freed first
			// and the statement reported a row it never inserted.
			if len(conflicts) > 0 do error_free(&insert_err)
			for id in conflicts {
				if fts_err := fts_delete_if_virtual(tx, stmt.table, id); fts_err.kind != .None {
					return {}, fts_err
				}
				if delete_err := tx_delete_without_triggers(tx, stmt.table, id); delete_err.kind != .None {
					return {}, delete_err
				}
			}
			if len(conflicts) > 0 {
				row_id, insert_err = tx_insert(tx, stmt.table, values)
				if insert_err.kind == .None {
					if fts_err := fts_index_if_virtual(tx, stmt.table, row_id, values, true); fts_err.kind != .None {
						return {}, fts_err
					}
				}
			}
		}
		if insert_err.kind != .None {
			// UPSERT: a collision on the target columns is not an error.
			conflict, found := find_conflict_row(tx, table, values)
			if !found do return {}, insert_err
			if stmt.conflict_do_nothing {
				error_free(&insert_err)
				continue
			}
			if len(stmt.conflict_assignments) == 0 do return {}, insert_err
			new_values := make([]Value, len(table.schema.columns), tx.alloc)
			for value, i in conflict.values do new_values[i] = value
			// Expressions see the stored row; `excluded` is the proposed row. The
			// excluded source is hidden from bare column names so `col` keeps
			// meaning the stored value, as SQLite does.
			conflict_source: [2]Source
			conflict_source[0] = Source{table = table, row = conflict}
			conflict_source[1] = Source{table = table, row = Row{values = values}, alias = "excluded", hidden_unqualified = true}
			ctx.sources = conflict_source[:]
			for assignment in stmt.conflict_assignments {
				index, found_column := schema_column_index(&table.schema, assignment.column)
				if !found_column {
					return {}, errf(.Column_Not_Found, "column %s does not exist in %s", assignment.column, stmt.table)
				}
				value, eval_err := eval_expr(&ctx, assignment.value)
				if eval_err.kind != .None do return {}, eval_err
				coerced, coerce_err := value_coerce(value, table.schema.columns[index].type)
				if coerce_err.kind != .None do return {}, coerce_err
				new_values[index] = coerced
			}
			if update_err := tx_update(tx, stmt.table, conflict.id, new_values); update_err.kind != .None {
				return {}, update_err
			}
			if fts_err := fts_index_if_virtual(tx, stmt.table, conflict.id, new_values, false); fts_err.kind != .None {
				return {}, fts_err
			}
			if returning := stmt.returning; returning != nil {
				if returning_err := returning_append(&result, &returned, returning, table, Row{values = new_values}); returning_err.kind != .None {
					return {}, returning_err
				}
			}
			result.affected += 1
			continue
		}
		// last_insert_rowid reports the INTEGER PRIMARY KEY when there is one,
		// and the internal row id otherwise. The staged row carries the key the
		// engine assigned, which the proposed values may not.
		tx.store.last_row_id = i64(row_id)
		if len(table.schema.primary_key) == 1 {
			pk := table.schema.primary_key[0]
			if staged, exists := tx_get(tx, stmt.table, row_id); exists {
				if pk < len(staged.values) && table.schema.columns[pk].type.kind == .Int {
					if pk_value, pk_ok := value_to_i64(staged.values[pk]); pk_ok {
						tx.store.last_row_id = pk_value
					}
				}
			}
		}
		if len(policies.check_exprs) > 0 {
			if staged, exists := tx_get(tx, stmt.table, row_id); exists {
				check_source: [1]Source
				check_source[0] = Source{table = table, row = staged}
				ctx.sources = check_source[:]
				allowed, allow_err := policy_allows(&policies, &ctx, true)
				if allow_err.kind != .None do return {}, allow_err
				if !allowed {
					return {}, errf(.Permission_Denied, "insert into %s violates a policy", stmt.table)
				}
			}
		}
		if returning := stmt.returning; returning != nil {
			if staged, exists := tx_get(tx, stmt.table, row_id); exists {
				if returning_err := returning_append(&result, &returned, returning, table, staged); returning_err.kind != .None {
					return {}, returning_err
				}
			}
		}
		result.affected += 1
	}
	if stmt.returning != nil do result.rows = returned[:]
	tx.store.last_changes = i64(result.affected)
	tx.store.total_changes += i64(result.affected)
	return result, ERROR_NONE
}

// Merge_Change is one row a MERGE will write, kept until the scan is done: a
// mutation during the scan would move the rows the scan is reading.
@(private)
Merge_Change :: struct {
	delete: bool,
	id:     Row_Id,
	values: []Value,
}

// sql_exec_merge runs a MERGE: one row per target that the source matches (the
// first WHEN MATCHED clause whose condition holds updates or deletes it) and one
// per source row that matches no target (the first WHEN NOT MATCHED clause
// inserts it). A target row that two source rows would change is refused, as
// PostgreSQL refuses it: the same row cannot be affected twice by one statement.
@(private)
sql_exec_merge :: proc(tx: ^Tx, stmt: Merge_Stmt, params: []Value) -> (Sql_Result, Error) {
	target, target_err := tx_table(tx, stmt.target)
	if target_err.kind != .None do return {}, target_err
	source_table, source_is_view, source_err := tx_source_table(tx, stmt.source, nil)
	if source_err.kind != .None do return {}, source_err
	target_rows := make([dynamic]Row)
	defer delete(target_rows)
	if collect_err := tx_collect(tx, stmt.target, &target_rows); collect_err.kind != .None {
		return {}, collect_err
	}
	source_rows := make([dynamic]Row)
	defer delete(source_rows)
	if source_is_view {
		table_collect(source_table, &source_rows, tx.read_seq)
	} else if collect_err := tx_collect(tx, stmt.source, &source_rows); collect_err.kind != .None {
		return {}, collect_err
	}
	ctx := Eval_Ctx {
		tx     = tx,
		params = params,
		now_us = now_microseconds(),
	}
	policies, policy_err := policy_load(tx, stmt.target)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	generated, generated_err := generated_plan_make(tx, target)
	if generated_err.kind != .None do return {}, generated_err
	defer generated_plan_destroy(&generated)
	// The two rows are bound under the names the statement gave them.
	target_source := Source{table = target, alias = stmt.target_alias}
	source_source := Source{table = source_table, alias = stmt.source_alias}
	pair: [2]Source
	source_matched := make([]bool, len(source_rows), tx.alloc)
	changes := make([dynamic]Merge_Change, 0, len(target_rows), tx.alloc)
	inserts := make([dynamic][]Value, 0, len(source_rows), tx.alloc)
	affected := 0
	touched := make(map[Row_Id]bool, len(target_rows), tx.alloc)
	for target_row in target_rows {
		if store_cancelled(tx.store) do return {}, errf(.Cancelled, "statement cancelled")
		pair[0] = target_source
		pair[0].row = target_row
		for source_row, source_index in source_rows {
			pair[1] = source_source
			pair[1].row = source_row
			ctx.sources = pair[:]
			matches, match_err := eval_expr(&ctx, stmt.on)
			if match_err.kind != .None do return {}, match_err
			if !value_is_truthy(matches) do continue
			source_matched[source_index] = true
			for clause in stmt.clauses {
				if clause.kind == .Not_Matched_Insert do continue
				if clause.condition != nil {
					holds, holds_err := eval_expr(&ctx, clause.condition)
					if holds_err.kind != .None do return {}, holds_err
					if !value_is_truthy(holds) do continue
				}
				if clause.kind == .Matched_Delete {
					allowed, allow_err := policy_allows(&policies, &ctx, false)
					if allow_err.kind != .None do return {}, allow_err
					if !allowed {
						return {}, errf(.Permission_Denied, "delete from %s violates a policy", stmt.target)
					}
					if touched[target_row.id] {
						return {}, errf(
							.Invalid_Argument,
							"MERGE cannot affect row %d twice",
							target_row.id,
						)
					}
					touched[target_row.id] = true
					append(&changes, Merge_Change{delete = true, id = target_row.id})
					break
				}
				new_values := make([]Value, len(target.schema.columns), tx.alloc)
				for _, i in target.schema.columns do new_values[i] = target_row.values[i]
				for assignment in clause.assignments {
					index, found := schema_column_index(&target.schema, assignment.column)
					if !found {
						return {}, errf(
							.Column_Not_Found,
							"column %s does not exist in %s",
							assignment.column,
							stmt.target,
						)
					}
					value, value_err := eval_expr(&ctx, assignment.value)
					if value_err.kind != .None do return {}, value_err
					coerced, coerce_err := value_coerce(value, target.schema.columns[index].type)
					if coerce_err.kind != .None do return {}, coerce_err
					new_values[index] = coerced
				}
				if apply_err := generated_plan_apply(&ctx, &generated, target, new_values); apply_err.kind != .None {
					return {}, apply_err
				}
				checked: [1]Source
				checked[0] = Source{table = target, row = Row{values = new_values}}
				ctx.sources = checked[:]
				allowed, allow_err := policy_allows(&policies, &ctx, true)
				ctx.sources = pair[:]
				if allow_err.kind != .None do return {}, allow_err
				if !allowed {
					return {}, errf(.Permission_Denied, "update of %s violates a policy", stmt.target)
				}
				if touched[target_row.id] {
					return {}, errf(
						.Invalid_Argument,
						"MERGE cannot affect row %d twice",
						target_row.id,
					)
				}
				touched[target_row.id] = true
				append(&changes, Merge_Change{id = target_row.id, values = new_values})
				break
			}
		}
	}
	for source_row, source_index in source_rows {
		if source_matched[source_index] do continue
		// No target matched this source row: the NOT MATCHED clauses see it alone.
		pair[0] = Source{}
		pair[1] = source_source
		pair[1].row = source_row
		ctx.sources = pair[1:]
		for clause in stmt.clauses {
			if clause.kind != .Not_Matched_Insert do continue
			if clause.condition != nil {
				holds, holds_err := eval_expr(&ctx, clause.condition)
				if holds_err.kind != .None do return {}, holds_err
				if !value_is_truthy(holds) do continue
			}
			values := make([]Value, len(target.schema.columns), tx.alloc)
			for _, i in target.schema.columns do values[i] = value_default()
			if len(clause.columns) == 0 {
				if len(clause.values) != len(target.schema.columns) {
					return {}, errf(
						.Invalid_Argument,
						"MERGE inserts %d values into %s, which has %d columns",
						len(clause.values),
						stmt.target,
						len(target.schema.columns),
					)
				}
				for expression, i in clause.values {
					value, value_err := eval_expr(&ctx, expression)
					if value_err.kind != .None do return {}, value_err
					coerced, coerce_err := value_coerce(value, target.schema.columns[i].type)
					if coerce_err.kind != .None do return {}, coerce_err
					values[i] = coerced
				}
			} else {
				if len(clause.columns) != len(clause.values) {
					return {}, errf(
						.Invalid_Argument,
						"MERGE INSERT names %d columns but gives %d values",
						len(clause.columns),
						len(clause.values),
					)
				}
				for column, i in clause.columns {
					index, found := schema_column_index(&target.schema, column)
					if !found {
						return {}, errf(
							.Column_Not_Found,
							"column %s does not exist in %s",
							column,
							stmt.target,
						)
					}
					value, value_err := eval_expr(&ctx, clause.values[i])
					if value_err.kind != .None do return {}, value_err
					coerced, coerce_err := value_coerce(value, target.schema.columns[index].type)
					if coerce_err.kind != .None do return {}, coerce_err
					values[index] = coerced
				}
			}
			checked: [1]Source
			checked[0] = Source{table = target, row = Row{values = values}}
			ctx.sources = checked[:]
			allowed, allow_err := policy_allows(&policies, &ctx, true)
			ctx.sources = pair[1:]
			if allow_err.kind != .None do return {}, allow_err
			if !allowed {
				return {}, errf(.Permission_Denied, "insert into %s violates a policy", stmt.target)
			}
			append(&inserts, values)
			break
		}
	}
	// The changes land now, with the table no longer being scanned.
	for change in changes {
		if change.delete {
			if delete_err := tx_delete(tx, stmt.target, change.id); delete_err.kind != .None {
				return {}, delete_err
			}
			affected += 1
			continue
		}
		if update_err := tx_update(tx, stmt.target, change.id, change.values); update_err.kind != .None {
			return {}, update_err
		}
		if fts_err := fts_index_if_virtual(tx, stmt.target, change.id, change.values, false); fts_err.kind != .None {
			return {}, fts_err
		}
		affected += 1
	}
	for values in inserts {
		if _, insert_err := tx_insert(tx, stmt.target, values); insert_err.kind != .None {
			return {}, insert_err
		}
		affected += 1
	}
	tx.store.last_changes = i64(affected)
	tx.store.total_changes += i64(affected)
	return Sql_Result{kind = .Affected, affected = affected, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

sql_exec_update :: proc(tx: ^Tx, stmt: Update_Stmt, params: []Value) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	// With FROM, every target row is a candidate and the join decides.
	collect_where := stmt.where_clause
	if len(stmt.from.name) > 0 do collect_where = nil
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := collect_target_rows(tx, table, stmt.table, collect_where, params, &rows); collect_err.kind != .None {
		return {}, collect_err
	}
	join_table: ^Table = nil
	join_rows := make([dynamic]Row)
	defer delete(join_rows)
	update_generated, update_generated_err := generated_plan_make(tx, table)
	if update_generated_err.kind != .None do return {}, update_generated_err
	defer generated_plan_destroy(&update_generated)
	if len(stmt.from.name) > 0 {
		resolved, is_view, join_err := tx_source_table(tx, stmt.from.name, nil)
		if join_err.kind != .None do return {}, join_err
		join_table = resolved
		if is_view {
			table_collect(join_table, &join_rows, tx.read_seq)
		} else if collect_join_err := tx_collect(tx, stmt.from.name, &join_rows); collect_join_err.kind != .None {
			return {}, collect_join_err
		}
	}
	ctx := Eval_Ctx{tx = tx, params = params, now_us = now_microseconds()}
	policies, policy_err := policy_load(tx, stmt.table)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	affected := 0
	returned := make([dynamic][]Value, 0, len(rows))
	if stmt.returning == nil do defer delete(returned)
	result := Sql_Result{kind = .Affected}
	for row in rows {
		if store_cancelled(tx.store) {
			return {}, errf(.Cancelled, "statement cancelled")
		}
		source: [2]Source
		source[0] = Source{table = table, row = row}
		if join_table != nil {
			// The first join row that satisfies the WHERE updates the target row.
			matched := false
			for join_row in join_rows {
				source[1] = Source{table = join_table, row = join_row, alias = stmt.from.alias}
				ctx.sources = source[:]
				if stmt.where_clause != nil {
					value, eval_err := eval_expr(&ctx, stmt.where_clause)
					if eval_err.kind != .None do return {}, eval_err
					if !value_is_truthy(value) do continue
				}
				matched = true
				break
			}
			if !matched do continue
		} else {
			ctx.sources = source[:1]
			matched := true
			if stmt.where_clause != nil {
				value, eval_err := eval_expr(&ctx, stmt.where_clause)
				if eval_err.kind != .None do return {}, eval_err
				matched = value_is_truthy(value)
			}
			if !matched do continue
		}
		allowed, allow_err := policy_allows(&policies, &ctx, false)
		if allow_err.kind != .None do return {}, allow_err
		if !allowed do continue
		new_values := make([]Value, len(table.schema.columns), tx.alloc)
		for _, i in table.schema.columns {
			new_values[i] = row.values[i]
		}
		for assignment in stmt.assignments {
			index, found := schema_column_index(&table.schema, assignment.column)
			if !found {
				return {}, errf(
					.Column_Not_Found,
					"column %s does not exist in %s",
					assignment.column,
					stmt.table,
				)
			}
			if table.schema.columns[index].generated {
				return {}, errf(
					.Invalid_Argument,
					"column %s is generated: it cannot be written directly",
					assignment.column,
				)
			}
			value, eval_err := eval_expr(&ctx, assignment.value)
			if eval_err.kind != .None do return {}, eval_err
			coerced, coerce_err := value_coerce(value, table.schema.columns[index].type)
			if coerce_err.kind != .None do return {}, coerce_err
			new_values[index] = coerced
		}
		if apply_err := generated_plan_apply(&ctx, &update_generated, table, new_values); apply_err.kind != .None {
			return {}, apply_err
		}
		check_source: [1]Source
		check_source[0] = Source{table = table, row = Row{values = new_values}}
		ctx.sources = check_source[:]
		allowed, allow_err = policy_allows(&policies, &ctx, true)
		if allow_err.kind != .None do return {}, allow_err
		if !allowed {
			return {}, errf(.Permission_Denied, "update of %s violates a policy", stmt.table)
		}
		if update_err := tx_update(tx, stmt.table, row.id, new_values); update_err.kind != .None {
			return {}, update_err
		}
		if fts_err := fts_index_if_virtual(tx, stmt.table, row.id, new_values, false); fts_err.kind != .None {
			return {}, fts_err
		}
		if returning_err := returning_append(&result, &returned, stmt.returning, table, Row{values = new_values}); returning_err.kind != .None {
			return {}, returning_err
		}
		affected += 1
	}
	result.affected = affected
	tx.store.last_changes = i64(affected)
	tx.store.total_changes += i64(affected)
	if stmt.returning != nil {
		result.kind = .Rows
		result.rows = returned[:]
	}
	return result, ERROR_NONE
}

sql_exec_delete :: proc(tx: ^Tx, stmt: Delete_Stmt, params: []Value) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	// With USING, every target row is a candidate and the join decides.
	collect_where := stmt.where_clause
	if len(stmt.using_ref.name) > 0 do collect_where = nil
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := collect_target_rows(tx, table, stmt.table, collect_where, params, &rows); collect_err.kind != .None {
		return {}, collect_err
	}
	using_table: ^Table = nil
	using_rows := make([dynamic]Row)
	defer delete(using_rows)
	if len(stmt.using_ref.name) > 0 {
		resolved, is_view, using_err := tx_source_table(tx, stmt.using_ref.name, nil)
		if using_err.kind != .None do return {}, using_err
		using_table = resolved
		if is_view {
			table_collect(using_table, &using_rows, tx.read_seq)
		} else if collect_using_err := tx_collect(tx, stmt.using_ref.name, &using_rows); collect_using_err.kind != .None {
			return {}, collect_using_err
		}
	}
	ctx := Eval_Ctx{tx = tx, params = params, now_us = now_microseconds()}
	policies, policy_err := policy_load(tx, stmt.table)
	if policy_err.kind != .None do return {}, policy_err
	defer policy_set_destroy(&policies)
	affected := 0
	returned := make([dynamic][]Value, 0, len(rows))
	if stmt.returning == nil do defer delete(returned)
	result := Sql_Result{kind = .Affected}
	for row in rows {
		if store_cancelled(tx.store) {
			return {}, errf(.Cancelled, "statement cancelled")
		}
		source: [2]Source
		source[0] = Source{table = table, row = row}
		if using_table != nil {
			matched := false
			for using_row in using_rows {
				source[1] = Source{table = using_table, row = using_row, alias = stmt.using_ref.alias}
				ctx.sources = source[:]
				if stmt.where_clause != nil {
					value, eval_err := eval_expr(&ctx, stmt.where_clause)
					if eval_err.kind != .None do return {}, eval_err
					if !value_is_truthy(value) do continue
				}
				matched = true
				break
			}
			if !matched do continue
		} else {
			ctx.sources = source[:1]
			matched := true
			if stmt.where_clause != nil {
				value, eval_err := eval_expr(&ctx, stmt.where_clause)
				if eval_err.kind != .None do return {}, eval_err
				matched = value_is_truthy(value)
			}
			if !matched do continue
		}
		allowed, allow_err := policy_allows(&policies, &ctx, false)
		if allow_err.kind != .None do return {}, allow_err
		if !allowed do continue
		if returning_err := returning_append(&result, &returned, stmt.returning, table, row); returning_err.kind != .None {
			return {}, returning_err
		}
		if fts_err := fts_delete_if_virtual(tx, stmt.table, row.id); fts_err.kind != .None {
			return {}, fts_err
		}
		if delete_err := tx_delete(tx, stmt.table, row.id); delete_err.kind != .None {
			return {}, delete_err
		}
		affected += 1
	}
	result.affected = affected
	tx.store.last_changes = i64(affected)
	tx.store.total_changes += i64(affected)
	if stmt.returning != nil {
		result.kind = .Rows
		result.rows = returned[:]
	}
	return result, ERROR_NONE
}

// collect_target_rows gathers the rows an UPDATE or DELETE must consider. It
// narrows the scan through an index when the WHERE clause allows it.
@(private)
collect_target_rows :: proc(
	tx: ^Tx,
	table: ^Table,
	table_name: string,
	predicate: ^Expr,
	params: []Value,
	out: ^[dynamic]Row,
) -> Error {
	if candidate_ids, used := index_candidates(tx, table, table_name, "", predicate, params); used {
		defer delete(candidate_ids)
		for id in candidate_ids {
			if row, exists := tx_get(tx, table_name, id); exists {
				append(out, row)
			}
		}
		rows_sort_by_id(out[:])
		return ERROR_NONE
	}
	return tx_collect(tx, table_name, out)
}

// --- DDL -------------------------------------------------------------------

TYPE_TABLE :: "_type"
TYPE_SCHEMA_SQL :: "CREATE TABLE IF NOT EXISTS _type (name TEXT PRIMARY KEY, base TEXT NOT NULL)"

@(private)
types_ensure_table :: proc(tx: ^Tx) -> Error {
	if _, table_err := tx_table(tx, TYPE_TABLE); table_err.kind == .None do return ERROR_NONE
	result, create_err := sql_execute_in_tx(tx, TYPE_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// resolve_named_type looks a named type up in the catalog and returns its base.
@(private)
resolve_named_type :: proc(tx: ^Tx, name: string) -> (Column_Type, Error) {
	if _, table_err := tx_table(tx, TYPE_TABLE); table_err.kind != .None {
		return {}, errf(.Invalid_Type, "type %s is not defined", name)
	}
	result, query_err := sql_execute_in_tx_params(
		tx,
		"SELECT base FROM _type WHERE name = ?",
		[]Value{value_string(name)},
	)
	if query_err.kind != .None do return {}, query_err
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 do return {}, errf(.Invalid_Type, "type %s is not defined", name)
	base, base_ok := type_parse_text(result.rows[0][0].s)
	if !base_ok do return {}, errf(.Invalid_Type, "type %s has an invalid base", name)
	return base, ERROR_NONE
}

sql_exec_create_type :: proc(tx: ^Tx, stmt: Create_Type_Stmt) -> (Sql_Result, Error) {
	if err := types_ensure_table(tx); err.kind != .None do return {}, err
	existing, query_err := sql_execute_in_tx_params(
		tx,
		"SELECT 1 FROM _type WHERE name = ?",
		[]Value{value_string(stmt.name)},
	)
	if query_err.kind != .None do return {}, query_err
	found := len(existing.rows) > 0
	sql_result_destroy(&existing)
	if found {
		if stmt.if_not_exists do return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
		return {}, errf(.Table_Exists, "type %s already exists", stmt.name)
	}
	base_text := column_type_name(stmt.base)
	_, insert_err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _type (name, base) VALUES (?, ?)",
		[]Value{value_string(stmt.name), value_string(base_text)},
	)
	if insert_err.kind != .None do return {}, insert_err
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

sql_exec_alter_table :: proc(tx: ^Tx, stmt: Alter_Table_Stmt) -> (Sql_Result, Error) {
	if len(stmt.alter_column) > 0 {
		if type_err := tx_alter_column_type(tx, stmt.table, stmt.alter_column, stmt.alter_type); type_err.kind != .None {
			return {}, type_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	if len(stmt.drop_column) > 0 {
		if drop_err := tx_drop_column(tx, stmt.table, stmt.drop_column); drop_err.kind != .None {
			return {}, drop_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	if len(stmt.rename_to) > 0 && len(stmt.rename_column) > 0 {
		if rename_err := tx_rename_column(tx, stmt.table, stmt.rename_column, stmt.rename_to); rename_err.kind != .None {
			return {}, rename_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	if len(stmt.rename_to) > 0 {
		if rename_err := tx_rename_table(tx, stmt.table, stmt.rename_to); rename_err.kind != .None {
			return {}, rename_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	for existing in table.schema.columns {
		if strings.equal_fold(existing.name, stmt.column.name) {
			return {}, errf(
				.Invalid_Argument,
				"column %s already exists in %s",
				stmt.column.name,
				stmt.table,
			)
		}
	}
	columns := make([]Column, len(table.schema.columns) + 1, tx.alloc)
	copy(columns, table.schema.columns)
	columns[len(columns) - 1] = stmt.column
	next_schema := table.schema
	next_schema.columns = columns
	if validate_err := schema_validate(&next_schema); validate_err.kind != .None {
		return {}, validate_err
	}
	if alter_err := tx_alter_table(tx, stmt.table, next_schema); alter_err.kind != .None {
		return {}, alter_err
	}
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

sql_exec_create_table :: proc(tx: ^Tx, stmt: Create_Table_Stmt, params: []Value) -> (Sql_Result, Error) {
	schema := Table_Schema{}
	schema.name = strings.clone(stmt.name, tx.alloc)
	schema.auto_increment_column = NO_COLUMN
	schema.ephemeral = stmt.ephemeral
	schema.event = stmt.event
	columns := make([]Column, len(stmt.columns), tx.alloc)
	inline_primary := NO_COLUMN
	for definition, i in stmt.columns {
		column_type := definition.type
		if len(definition.type_name) > 0 {
			resolved, resolve_err := resolve_named_type(tx, definition.type_name)
			if resolve_err.kind != .None do return {}, resolve_err
			column_type = resolved
		}
		collation := ""
		if len(definition.collation) > 0 {
			if !collation_known(definition.collation) {
				// A registered host comparison cannot be a column's collation: the
				// column's text is folded into the keys that index it and order it, and
				// a host comparison has no fold. Comparing against it explicitly is fine.
				if _, is_host := store_collation(tx.store, definition.collation); is_host {
					return {}, errf(
						.Sql_Unsupported,
						"collation %s cannot be a column's collation on %s: it has no folded key to index or order by; use COLLATE %s in a comparison instead",
						definition.collation,
						definition.name,
						definition.collation,
					)
				}
				return {}, errf(
					.Sql_Unsupported,
					"unknown collation %s on column %s",
					definition.collation,
					definition.name,
				)
			}
			collation = strings.clone(definition.collation, tx.alloc)
		}
		if definition.generated && definition.default != nil {
			return {}, errf(.Invalid_Argument, "generated column %s cannot have a DEFAULT", definition.name)
		}
		column := Column {
			name           = strings.clone(definition.name, tx.alloc),
			type           = column_type,
			named_type     = definition.type_name,
			unique         = definition.unique,
			not_null       = definition.not_null || definition.primary,
			auto_increment = definition.autoinc,
			sequence       = definition.sequence,
			collation      = collation,
			generated      = definition.generated,
			generated_sql  = strings.clone(definition.generated_sql, tx.alloc),
		}
		if definition.primary {
			if inline_primary != NO_COLUMN {
				return {}, errf(.Invalid_Argument, "table %s declares more than one primary key", stmt.name)
			}
			inline_primary = i
		}
		if column.auto_increment {
			schema.auto_increment_column = i
		}
		if definition.default != nil && expr_calls_a_function(definition.default) && len(definition.default_sql) > 0 {
			// A default that calls a function (CURRENT_TIMESTAMP, random(), …)
			// is evaluated for each row, as SQLite does, not once now. Parse it
			// here so a bad one is refused when the table is created.
			check_query, _, check_err := sql_parse_expression(definition.default_sql)
			if check_err.kind != .None do return {}, check_err
			query_destroy(&check_query)
			column.default_sql = strings.clone(definition.default_sql, tx.alloc)
		} else if definition.default != nil {
			value, eval_err := eval_expr(
				&Eval_Ctx{params = params, now_us = now_microseconds()},
				definition.default,
			)
			if eval_err.kind != .None do return {}, eval_err
			coerced, coerce_err := value_coerce(value, column.type)
			if coerce_err.kind != .None do return {}, coerce_err
			column.has_default = true
			column.default_value = value_clone(coerced, tx.alloc)
		}
		columns[i] = column
	}
	schema.columns = columns
	if inline_primary != NO_COLUMN {
		pk := make([]int, 1, tx.alloc)
		pk[0] = inline_primary
		schema.primary_key = pk
	}

	checks := make([dynamic]Check_Constraint, 0, 0, tx.alloc)
	for definition in stmt.columns {
		for check in definition.checks do append(&checks, check)
	}
	for constraint in stmt.constraints {
		if constraint.is_check do append(&checks, Check_Constraint{name = constraint.name, sql = constraint.check_sql})
	}
	for check, i in checks {
		// Parsed now so a malformed CHECK is refused with the table.
		check_query, _, check_err := sql_parse_expression(check.sql)
		if check_err.kind != .None do return {}, check_err
		query_destroy(&check_query)
		checks[i] = Check_Constraint{name = strings.clone(check.name, tx.alloc), sql = strings.clone(check.sql, tx.alloc), column = strings.clone(check.column, tx.alloc)}
	}
	schema.checks = checks[:]

	indexes := make([dynamic]Index_Schema, 0, len(stmt.constraints), tx.alloc)
	foreign_keys := make([dynamic]Foreign_Key, 0, len(stmt.constraints), tx.alloc)
	for constraint in stmt.constraints {
		if constraint.is_check do continue
		positions := make([]int, len(constraint.columns), tx.alloc)
		for name, i in constraint.columns {
			position, found := schema_column_index(&schema, name)
			if !found {
				return {}, errf(.Column_Not_Found, "column %s does not exist in %s", name, stmt.name)
			}
			positions[i] = position
		}
		if constraint.is_foreign {
			// Resolve the referenced columns against the parent schema, which
			// must already exist and key the columns uniquely. A table may
			// reference itself, before it exists.
			parent_schema: ^Table_Schema
			if strings.equal_fold(constraint.ref_table, stmt.name) {
				parent_schema = &schema
			} else {
				parent, parent_err := tx_table(tx, constraint.ref_table)
				if parent_err.kind != .None {
					return {}, errf(
						.Table_Not_Found,
						"foreign key %s references missing table %s",
						stmt.name,
						constraint.ref_table,
					)
				}
				parent_schema = &parent.schema
			}
			ref_names := constraint.ref_columns
			if len(ref_names) == 0 {
				// `REFERENCES parent` with no columns names the parent's primary key.
				if len(parent_schema.primary_key) == 0 {
					return {}, errf(.Invalid_Argument, "foreign key on %s references %s, which has no primary key", stmt.name, constraint.ref_table)
				}
				names := make([]string, len(parent_schema.primary_key), tx.alloc)
				for position, i in parent_schema.primary_key do names[i] = parent_schema.columns[position].name
				ref_names = names
			}
			if len(ref_names) != len(positions) {
				return {}, errf(
					.Invalid_Argument,
					"foreign key on %s lists %d columns but references %d",
					stmt.name,
					len(positions),
					len(ref_names),
				)
			}
			ref_positions := make([]int, len(ref_names), tx.alloc)
			for name, i in ref_names {
				position, found := schema_column_index(parent_schema, name)
				if !found {
					return {}, errf(
						.Column_Not_Found,
						"column %s does not exist in %s",
						name,
						constraint.ref_table,
					)
				}
				ref_positions[i] = position
			}
			if !schema_columns_unique(parent_schema, ref_positions) {
				return {}, errf(
					.Invalid_Argument,
					"foreign key on %s must reference a unique key of %s",
					stmt.name,
					constraint.ref_table,
				)
			}
			name := constraint.name
			if len(name) == 0 {
				name = strings.concatenate({stmt.name, "_fkey"}, tx.alloc)
			} else {
				name = strings.clone(name, tx.alloc)
			}
			append(
				&foreign_keys,
				Foreign_Key {
					name = name,
					columns = positions,
					ref_table = strings.clone(constraint.ref_table, tx.alloc),
					ref_columns = ref_positions,
					on_delete = constraint.on_delete,
					on_update = constraint.on_update,
					deferred = constraint.deferred,
				},
			)
			continue
		}
		if constraint.primary {
			if len(schema.primary_key) > 0 {
				return {}, errf(.Invalid_Argument, "table %s declares more than one primary key", stmt.name)
			}
			schema.primary_key = positions
			for position in positions {
				schema.columns[position].not_null = true
			}
			continue
		}
		name := constraint.name
		if len(name) == 0 {
			name = strings.concatenate({stmt.name, "_key"}, tx.alloc)
			for position in positions {
				name = strings.concatenate({name, "_", stmt.columns[position].name}, tx.alloc)
			}
		} else {
			name = strings.clone(name, tx.alloc)
		}
		append(
			&indexes,
			Index_Schema{name = name, columns = positions, unique = true, implicit = false},
		)
	}
	if len(indexes) > 0 {
		schema.indexes = make([]Index_Schema, len(indexes), tx.alloc)
		copy(schema.indexes, indexes[:])
	}
	delete(indexes)
	if len(foreign_keys) > 0 {
		schema.foreign_keys = make([]Foreign_Key, len(foreign_keys), tx.alloc)
		copy(schema.foreign_keys, foreign_keys[:])
	}
	delete(foreign_keys)

	if create_err := tx_create_table(tx, &schema); create_err.kind != .None {
		if create_err.kind == .Table_Exists && stmt.if_not_exists {
			// The result outlives the transaction: its arena is gone by the time
			// the caller prints the message.
			return Sql_Result{
				kind = .Ack,
				message = result_own("table already exists"),
			}, ERROR_NONE
		}
		return {}, create_err
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}

sql_exec_drop_table :: proc(tx: ^Tx, stmt: Drop_Table_Stmt) -> (Sql_Result, Error) {
	// A virtual table owns a shadow table and a catalog row: dropping it drops all
	// three, so nothing is left behind to be reindexed later.
	if virtual, virtual_err := fts_drop_if_virtual(tx, stmt.name, stmt.if_exists); virtual {
		if virtual_err.kind != .None do return {}, virtual_err
		return Sql_Result{kind = .Ack}, ERROR_NONE
	}
	if drop_err := tx_drop_table(tx, stmt.name); drop_err.kind != .None {
		if drop_err.kind == .Table_Not_Found && stmt.if_exists {
			return Sql_Result{kind = .Ack}, ERROR_NONE
		}
		return {}, drop_err
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}

sql_exec_create_index :: proc(tx: ^Tx, stmt: Create_Index_Stmt) -> (Sql_Result, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return {}, table_err
	columns := make([]int, len(stmt.columns), tx.alloc)
	for name, i in stmt.columns {
		if i < len(stmt.exprs) && len(stmt.exprs[i]) > 0 {
			columns[i] = NO_COLUMN
			continue
		}
		index, found := schema_column_index(&table.schema, name)
		if !found {
			return {}, errf(.Column_Not_Found, "column %s does not exist in %s", name, stmt.table)
		}
		columns[i] = index
		for prior in columns[:i] {
			if prior == index {
				return {}, errf(.Invalid_Argument, "index %s repeats column %s", stmt.name, name)
			}
		}
	}
	for existing in table.schema.indexes {
		if !strings.equal_fold(existing.name, stmt.name) do continue
		if stmt.if_not_exists do return Sql_Result{kind = .Ack}, ERROR_NONE
		return {}, errf(.Index_Exists, "index %s already exists", stmt.name)
	}
	// The schema does not carry an index staged earlier in this transaction.
	for op in tx.state.index_ops {
		if op.drop || !strings.equal_fold(op.table, stmt.table) do continue
		if !strings.equal_fold(op.index.name, stmt.name) do continue
		if stmt.if_not_exists do return Sql_Result{kind = .Ack}, ERROR_NONE
		return {}, errf(.Index_Exists, "index %s already exists", stmt.name)
	}
	if stmt.algorithm == .Direct && (!stmt.unique || len(columns) != 1) {
		return {}, errf(.Invalid_Argument, "a DIRECT index must be unique on one column")
	}
	index := Index_Schema {
		name      = stmt.name,
		columns   = columns,
		unique    = stmt.unique,
		algorithm = stmt.algorithm,
		where_sql = stmt.where_sql,
		exprs     = stmt.exprs,
	}
	if !index_is_plain(index) && stmt.algorithm != .Btree {
		return {}, errf(.Sql_Unsupported, "a partial or expression index is a btree index")
	}
	// Every row the index will hold is tried now: an expression that fails, and a
	// UNIQUE index the rows already break, are this statement's error rather than
	// a commit that cannot apply.
	if verify_err := index_verify_rows(tx, table, stmt.table, index); verify_err.kind != .None {
		return {}, verify_err
	}
	if add_err := tx_create_index(tx, stmt.table, index); add_err.kind != .None {
		return {}, add_err
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}

// INDEX_FORBIDDEN_CALLS are functions an index may not use: their answer
// changes from one evaluation to the next, so a key computed today would not be
// found tomorrow. SQLite refuses the same.
INDEX_FORBIDDEN_CALLS :: []string{
	"random", "randomblob", "now", "uuid", "changes", "total_changes", "last_insert_rowid",
	"current_identity", "has_role", "rank", "snippet", "highlight",
}

// index_expression_refusal names why an expression cannot be part of an index,
// or answers "" when it can.
@(private)
index_expression_refusal :: proc(expr: ^Expr) -> string {
	Probe :: struct {
		reason: string,
	}
	probe: Probe
	expr_walk(expr, proc(node: ^Expr, user: rawptr) -> bool {
		probe := (^Probe)(user)
		#partial switch e in node^ {
		case Subquery_Expr:
			probe.reason = "a subquery"
		case Param_Expr:
			probe.reason = "a parameter"
		case Window_Expr:
			probe.reason = "a window function"
		case In_Expr:
			if e.subquery != nil do probe.reason = "a subquery"
		case Call_Expr:
			for name in INDEX_FORBIDDEN_CALLS {
				if strings.equal_fold(e.name, name) do probe.reason = "a non-deterministic function"
			}
			if expr_is_aggregate(node) do probe.reason = "an aggregate"
			// date('now') and its siblings answer the current moment.
			for arg in e.args {
				if literal, ok := arg^.(Literal_Expr); ok && literal.value.kind == .String && strings.equal_fold(literal.value.s, "now") {
					probe.reason = "the current time"
				}
			}
		}
		return true
	}, &probe)
	return probe.reason
}

// index_verify_rows checks a partial or expression index, and any UNIQUE index,
// against the rows it is about to hold: an expression it cannot evaluate, a key
// two rows share. It answers before the index is staged.
@(private)
index_verify_rows :: proc(tx: ^Tx, table: ^Table, table_name: string, index: Index_Schema) -> Error {
	for text in index.exprs {
		if len(text) == 0 do continue
		query, expr, err := sql_parse_expression(text)
		if err.kind != .None do return err
		defer query_destroy(&query)
		if reason := index_expression_refusal(expr); len(reason) > 0 {
			return errf(.Sql_Unsupported, "index %s cannot use %s in a key expression", index.name, reason)
		}
	}
	if len(index.where_sql) > 0 {
		query, expr, err := sql_parse_expression(index.where_sql)
		if err.kind != .None do return err
		defer query_destroy(&query)
		if reason := index_expression_refusal(expr); len(reason) > 0 {
			return errf(.Sql_Unsupported, "index %s cannot use %s in its WHERE", index.name, reason)
		}
	}
	if index_is_plain(index) && !index.unique do return ERROR_NONE
	exprs, exprs_err := index_exprs_make(index)
	if exprs_err.kind != .None do return exprs_err
	defer index_exprs_destroy(exprs)
	// A table of one index, the one being created, so the key builders apply.
	probe := Table{schema = table.schema}
	probe_indexes := [1]Index{Index{schema = index, unique = index.unique, exprs = exprs}}
	probe.indexes = probe_indexes[:]
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := tx_collect(tx, table_name, &rows); collect_err.kind != .None do return collect_err
	seen := make(map[string]bool)
	defer {
		for key in seen do delete(key)
		delete(seen)
	}
	for row in rows {
		if validate_err := index_validate_row(tx, &probe, row.values); validate_err.kind != .None do return validate_err
		if !index.unique || !index_row_included(&probe, 0, row.values) do continue
		w: Byte_Writer
		bw_init(&w)
		has_null := index_encode_parts(&w, &probe, 0, row.values)
		key := string(bw_bytes(&w))
		if has_null || !(key in seen) {
			if !has_null do seen[strings.clone(key)] = true
			bw_destroy(&w)
			continue
		}
		bw_destroy(&w)
		return errf(.Duplicate_Unique, "UNIQUE constraint failed: index %s", index.name)
	}
	return ERROR_NONE
}

sql_exec_drop_index :: proc(tx: ^Tx, stmt: Drop_Index_Stmt) -> (Sql_Result, Error) {
	table_name := stmt.table
	if len(table_name) == 0 {
		for name in tx.store.tables {
			table := tx.store.tables[name]
			for existing in table.schema.indexes {
				if strings.equal_fold(existing.name, stmt.name) {
					table_name = name
					break
				}
			}
			if len(table_name) > 0 do break
		}
	}
	// An index created earlier in this transaction is not in the schema yet, so
	// DROP INDEX without ON has to look at the staged operations too.
	if len(table_name) == 0 {
		for op in tx.state.index_ops {
			if op.drop do continue
			if strings.equal_fold(op.index.name, stmt.name) {
				table_name = op.table
				break
			}
		}
	}
	if len(table_name) == 0 {
		if stmt.if_exists do return Sql_Result{kind = .Ack}, ERROR_NONE
		return {}, errf(.Index_Not_Found, "index %s does not exist", stmt.name)
	}
	if drop_err := tx_drop_index(tx, table_name, stmt.name); drop_err.kind != .None {
		if drop_err.kind == .Index_Not_Found && stmt.if_exists {
			return Sql_Result{kind = .Ack}, ERROR_NONE
		}
		return {}, drop_err
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}

// --- Index-assisted filtering ----------------------------------------------

// index_candidates tries to turn the WHERE clause into a small set of row ids
// using a single-column index. The caller still re-checks the whole predicate,
// so the result only has to be a superset of the matching rows.
@(private)
// fts_scan_candidates narrows a scan to the documents a MATCH selects. Without
// it the predicate would be evaluated on every row of the table; with it the scan
// visits the matches only, which is what makes the cost follow the answer instead
// of the corpus. The pattern has to be a constant (or a parameter), because a
// row-dependent pattern cannot be answered from one lookup.
fts_scan_candidates :: proc(
	tx: ^Tx,
	table_name: string,
	table_alias: string,
	predicate: ^Expr,
	params: []Value,
) -> (ids: [dynamic]Row_Id, used: bool, err: Error) {
	if predicate == nil do return nil, false, ERROR_NONE
	virtual, is_virtual := fts_virtual_lookup(tx, table_name)
	if !is_virtual || !fts_is_full_text(virtual) do return nil, false, ERROR_NONE
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		match, is_match := expr^.(Match_Expr)
		if !is_match do continue
		column, is_column := match.operand^.(Column_Expr)
		if !is_column do continue
		names_table := len(column.table) > 0 ? column.table : column.name
		named := strings.equal_fold(names_table, table_name) ||
			(len(table_alias) > 0 && strings.equal_fold(names_table, table_alias))
		if !named do continue
		pattern, constant := eval_constant(match.pattern, params)
		if !constant || pattern.kind != .String do continue
		result, match_err := fts_match_docs(tx, virtual, pattern.s)
		if match_err.kind != .None do return nil, true, match_err
		for doc in result.docs do append(&ids, doc)
		row_ids_sort(ids[:])
		return ids, true, ERROR_NONE
	}
	return nil, false, ERROR_NONE
}

index_candidates :: proc(
	tx: ^Tx,
	table: ^Table,
	table_name: string,
	table_alias: string,
	predicate: ^Expr,
	params: []Value,
) -> (ids: [dynamic]Row_Id, used: bool) {
	if predicate == nil do return nil, false
	// Staged writes are not in the index yet, so the scan would miss them.
	if _, staged := tx.state.writes[table_name]; staged do return nil, false
	if _, created := tx.state.created[table_name]; created do return nil, false
	// The planner compares every index the predicate could use against the scan
	// and hands back the cheapest one, or none when the scan wins.
	plan := plan_access(tx.store, table, Table_Ref{name = table_name, alias = table_alias}, predicate, params)
	if plan.kind != .Index do return nil, false
	// Both ends of a range travel together: `v >= 5 AND v < 9` is one scan over
	// [5, 9), which is what the plan priced.
	conjunct, companion := plan.conjunct, plan.conjunct2
	if candidates, ok := candidates_from_range(conjunct, companion, table, table_alias, plan.index, params); ok {
		return candidates, true
	}
	return nil, false
}

// candidates_from_range answers one comparison, or two that share a column, with
// one index scan: the lower bound is where it starts and the upper bound where it
// stops, each keeping the operator's own inclusivity. Anything else falls back to
// the single-comparison path.
@(private)
candidates_from_range :: proc(
	expr: ^Expr,
	companion: ^Expr,
	table: ^Table,
	table_alias: string,
	index_position: int,
	params: []Value,
) -> ([dynamic]Row_Id, bool) {
	if companion == nil {
		return candidates_from_conjunct(expr, table, table_alias, index_position, params)
	}
	first, first_ok := range_key(table, table_alias, expr, params)
	second, second_ok := range_key(table, table_alias, companion, params)
	if !first_ok || !second_ok {
		if first_ok do delete(first.key)
		if second_ok do delete(second.key)
		return nil, false
	}
	defer delete(first.key)
	defer delete(second.key)
	if first.lower == second.lower do return nil, false
	low := first
	high := second
	if !first.lower {
		low = second
		high = first
	}
	return table_index_scan(table, index_position, string(low.key), string(high.key), high.inclusive), true
}

// Range_Key is one end of a range as the index needs it: the encoded boundary, and
// whether it holds the rows above or below it.
@(private)
Range_Key :: struct {
	key:       []u8,
	lower:     bool,
	inclusive: bool,
}

@(private)
range_key :: proc(
	table: ^Table,
	table_alias: string,
	expr: ^Expr,
	params: []Value,
) -> (Range_Key, bool) {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary do return {}, false
	lower: bool
	inclusive: bool
	#partial switch binary.op {
	case .Gt:
		lower = true
	case .Ge:
		lower = true
		inclusive = true
	case .Lt:
		lower = false
	case .Le:
		lower = false
		inclusive = true
	case:
		return {}, false
	}
	qualifier, column_name, value_expr, reversed, sides_ok := comparison_sides(binary)
	if !sides_ok do return {}, false
	if len(qualifier) > 0 &&
	   !strings.equal_fold(qualifier, table.schema.name) &&
	   !(len(table_alias) > 0 && strings.equal_fold(qualifier, table_alias)) {
		return {}, false
	}
	column_index, found := schema_column_index(&table.schema, column_name)
	if !found do return {}, false
	value, constant := eval_constant(value_expr, params)
	if !constant do return {}, false
	coerced, coerce_err := value_coerce(value, table.schema.columns[column_index].type)
	if coerce_err.kind != .None do return {}, false
	if len(table.schema.columns[column_index].collation) > 0 {
		coerced = collate_ordered_value(coerced, table.schema.columns[column_index].collation)
	}
	// `5 < v` is the lower bound written the other way round.
	if reversed do lower = !lower
	return Range_Key{key = value_key_bytes(coerced), lower = lower, inclusive = inclusive}, true
}

// select_filters_rows reports whether the rows of a table can be dropped after the
// base scan, which is what stops a LIMIT from ending the ordered walk early.
@(private)
select_filters_rows :: proc(tx: ^Tx, name: string) -> bool {
	if len(name) == 0 || is_system_table(name) do return false
	set, err := policy_load(tx, name)
	if err.kind != .None do return true
	active := len(set.using_exprs) > 0
	policy_set_destroy(&set)
	return active
}

// select_row_limit is how many rows an ordered walk has to collect for LIMIT and
// OFFSET to have something to work with. Zero means "no limit".
@(private)
select_row_limit :: proc(stmt: Select_Stmt, params: []Value) -> int {
	if stmt.limit == nil do return 0
	offset := 0
	if stmt.offset != nil {
		if value, constant := eval_constant(stmt.offset, params); constant {
			if number, is_integer := value_to_i64(value); is_integer && number > 0 do offset = int(number)
		}
	}
	value, constant := eval_constant(stmt.limit, params)
	if !constant do return 0
	number, is_integer := value_to_i64(value)
	if !is_integer || number < 0 do return 0
	return int(number) + offset
}

// index_order_for finds an index that hands a statement its rows in the order the
// statement asks for, which lets the sort go. The ORDER BY has to name the whole
// key of one in-memory index, in the index's own order and all in one direction:
// a prefix would order the ties by the rest of the index instead of by row id, and
// the sequence would differ from the sorted one. Descending is served only by a
// unique index, where no two rows tie.
@(private)
index_order_for :: proc(
	tx: ^Tx,
	table: ^Table,
	ref: Table_Ref,
	stmt: Select_Stmt,
) -> (
	index: int,
	descending: bool,
	ok: bool,
) {
	index = -1
	if table == nil || table.paged != nil do return index, false, false
	if len(stmt.order_by) == 0 || len(stmt.joins) != 0 do return index, false, false
	if stmt.is_distinct || len(stmt.group_by) > 0 || stmt.having != nil do return index, false, false
	if len(stmt.compound) > 0 || stmt.is_distinct do return index, false, false
	for item in stmt.projections {
		if item.expr == nil do continue
		if expr_is_aggregate(item.expr) do return index, false, false
		if _, is_window := item.expr^.(Window_Expr); is_window do return index, false, false
	}
	// An index lags the staged writes of its table, and a table created in this
	// transaction has none worth reading.
	if _, staged := tx.state.writes[ref.name]; staged do return index, false, false
	if _, created := tx.state.created[ref.name]; created do return index, false, false
	direction := stmt.order_by[0].descending
	for item in stmt.order_by {
		if item.descending != direction do return index, false, false
		if item.nulls != .Default do return index, false, false
	}
	for &candidate, position in table.indexes {
		if candidate.pages != nil do continue
		// A partial or expression index does not hold every row by its columns.
		if !index_is_plain(candidate.schema) do continue
		if len(candidate.schema.columns) != len(stmt.order_by) do continue
		if direction && !candidate.unique do continue
		matched := true
		for item, i in stmt.order_by {
			reference, is_column := item.expr^.(Column_Expr)
			if !is_column {
				matched = false
				break
			}
			if len(reference.table) > 0 &&
			   !strings.equal_fold(reference.table, table.schema.name) &&
			   !(len(ref.alias) > 0 && strings.equal_fold(reference.table, ref.alias)) {
				matched = false
				break
			}
			column_index, found := schema_column_index(&table.schema, reference.name)
			if !found || column_index != candidate.schema.columns[i] {
				matched = false
				break
			}
		}
		if matched do return position, direction, true
	}
	return index, false, false
}

// index_order_ids lists the row ids of one index in key order, or in the reverse
// order when the statement is descending. `max_rows` stops the walk early, which
// is what turns `ORDER BY id LIMIT 5` into five reads instead of a pass over the
// whole table; zero means no stop.
@(private)
index_order_ids :: proc(
	table: ^Table,
	index: int,
	descending: bool,
	max_rows: int,
) -> [dynamic]Row_Id {
	ids := make([dynamic]Row_Id)
	node := table.indexes[index].tree._root
	if node == nil do return ids
	if descending {
		for node._right != nil do node = node._right
		for node != nil && (max_rows <= 0 || len(ids) < max_rows) {
			append(&ids, node.value)
			node = node_prev(node)
		}
		return ids
	}
	for node._left != nil do node = node._left
	for node != nil && (max_rows <= 0 || len(ids) < max_rows) {
		append(&ids, node.value)
		node = node_next(node)
	}
	return ids
}

// Index_Probe is how a nested loop finds the inner rows one outer row joins to:
// the equality binds one column of the inner table to an expression over the
// outer sources, and that column leads one of its indexes. index is -1 when the
// loop has to scan.
@(private)
Index_Probe :: struct {
	index:  int,
	column: int,
	value:  ^Expr,
}

// join_index_probe reads the ON clause of one join step and finds an equality it
// can answer with an index of the inner table: `inner.column = <outer
// expression>`. A multi-column index answers it when the bound column leads the
// index, because a prefix scan still narrows the tree.
@(private)
join_index_probe :: proc(
	table: ^Table,
	alias: string,
	predicate: ^Expr,
) -> (probe: Index_Probe, ok: bool) {
	probe.index = -1
	if table == nil || predicate == nil do return probe, false
	conjuncts := make([dynamic]^Expr)
	defer delete(conjuncts)
	split_and(predicate, &conjuncts)
	for expr in conjuncts {
		binary, is_binary := expr^.(Binary_Expr)
		if !is_binary || binary.op != .Eq do continue
		// Either side may be the inner column; the other is the value to probe.
		sides := [2][2]^Expr{{binary.left, binary.right}, {binary.right, binary.left}}
		for side in sides {
			reference, is_column := side[0]^.(Column_Expr)
			if !is_column do continue
			if len(reference.table) > 0 &&
			   !strings.equal_fold(reference.table, table.schema.name) &&
			   !(len(alias) > 0 && strings.equal_fold(reference.table, alias)) {
				continue
			}
			column_index, found := schema_column_index(&table.schema, reference.name)
			if !found do continue
			for &index, i in table.indexes {
				if len(index.schema.columns) == 0 do continue
				if !index_is_plain(index.schema) do continue
				// A probe answers an index that leads with the column it binds.
				if index.schema.columns[0] != column_index do continue
				return Index_Probe{index = i, column = column_index, value = side[1]}, true
			}
		}
	}
	return probe, false
}

// join_probe_rows evaluates the probe for one outer row and returns the rows its
// key names. It reports false when the value cannot be turned into a key (an
// error the scan will report, a value that does not coerce), so the caller scans
// instead of answering a query with fewer rows than it has.
@(private)
join_probe_rows :: proc(
	tx: ^Tx,
	table: ^Table,
	name: string,
	probe: Index_Probe,
	partial: []Source,
	ctx: ^Eval_Ctx,
) -> (rows: [dynamic]Row, ok: bool) {
	ctx.sources = partial
	value, eval_err := eval_expr(ctx, probe.value)
	if eval_err.kind != .None do return nil, false
	coerced, coerce_err := value_coerce(value, table.schema.columns[probe.column].type)
	if coerce_err.kind != .None do return nil, false
	if len(table.schema.columns[probe.column].collation) > 0 {
		coerced = collate_ordered_value(coerced, table.schema.columns[probe.column].collation)
	}
	key := value_key_bytes(coerced)
	defer delete(key)
	ids := table_index_scan_prefix(table, probe.index, string(key))
	defer delete(ids)
	for id in ids {
		if row, exists := tx_get(tx, name, id); exists do append(&rows, row)
	}
	return rows, true
}

@(private)
split_and :: proc(expr: ^Expr, out: ^[dynamic]^Expr) {
	if expr == nil do return
	if binary, ok := expr^.(Binary_Expr); ok && binary.op == .And {
		split_and(binary.left, out)
		split_and(binary.right, out)
		return
	}
	append(out, expr)
}

@(private)
candidates_from_conjunct :: proc(
	expr: ^Expr,
	table: ^Table,
	table_alias: string,
	index_position: int,
	params: []Value,
) -> ([dynamic]Row_Id, bool) {
	binary, is_binary := expr^.(Binary_Expr)
	if !is_binary do return nil, false
	if binary.op == .Eq || binary.op == .Lt || binary.op == .Le || binary.op == .Gt || binary.op == .Ge {
		qualifier, column_name, value_expr, reversed, ok := comparison_sides(binary)
		if !ok do return nil, false
		// A column of a joined table has its own index (and its own scan); only
		// the base table can use this shortcut.
		if len(qualifier) > 0 &&
		   !strings.equal_fold(qualifier, table.schema.name) &&
		   !(len(table_alias) > 0 && strings.equal_fold(qualifier, table_alias)) {
			return nil, false
		}
		column_index, found := schema_column_index(&table.schema, column_name)
		if !found do return nil, false
		value, constant := eval_constant(value_expr, params)
		if !constant do return nil, false
		coerced, coerce_err := value_coerce(value, table.schema.columns[column_index].type)
		if coerce_err.kind != .None do return nil, false
		// The index folded the text, so the probe must fold it the same way.
		if len(table.schema.columns[column_index].collation) > 0 {
			coerced = collate_ordered_value(coerced, table.schema.columns[column_index].collation)
		}
		key := value_key_bytes(coerced)
		defer delete(key)
		op := binary.op
		if reversed {
			#partial switch op {
			case .Lt:
				op = .Gt
			case .Le:
				op = .Ge
			case .Gt:
				op = .Lt
			case .Ge:
				op = .Le
			}
		}
		#partial switch op {
		case .Eq:
			return table_index_scan_prefix(table, index_position, string(key)), true
		case .Lt:
			return table_index_scan(table, index_position, "", string(key), false), true
		case .Le:
			return table_index_scan(table, index_position, "", string(key), true), true
		case .Gt, .Ge:
			// Include the boundary; the WHERE re-check drops it when needed.
			return table_index_scan(table, index_position, string(key), "", true), true
		case:
		}
		return nil, false
	}
	between, is_between := expr^.(Between_Expr)
	if is_between && !between.negated {
		column, ok := between.operand^.(Column_Expr)
		if !ok do return nil, false
		if len(column.table) > 0 &&
		   !strings.equal_fold(column.table, table.schema.name) &&
		   !(len(table_alias) > 0 && strings.equal_fold(column.table, table_alias)) {
			return nil, false
		}
		column_index, found := schema_column_index(&table.schema, column.name)
		if !found do return nil, false
		low, low_ok := eval_constant(between.low, params)
		high, high_ok := eval_constant(between.high, params)
		if !low_ok || !high_ok do return nil, false
		low_value, low_err := value_coerce(low, table.schema.columns[column_index].type)
		high_value, high_err := value_coerce(high, table.schema.columns[column_index].type)
		if low_err.kind != .None || high_err.kind != .None do return nil, false
		low_key := value_key_bytes(low_value)
		defer delete(low_key)
		high_key := value_key_bytes(high_value)
		defer delete(high_key)
		return table_index_scan(table, index_position, string(low_key), string(high_key), true), true
	}
	return nil, false
}

@(private)
comparison_sides :: proc(
	binary: Binary_Expr,
) -> (qualifier: string, column: string, value: ^Expr, reversed: bool, ok: bool) {
	if ref, is_column := binary.left^.(Column_Expr); is_column {
		return ref.table, ref.name, binary.right, false, true
	}
	if ref, is_column := binary.right^.(Column_Expr); is_column {
		return ref.table, ref.name, binary.left, true, true
	}
	return "", "", nil, false, false
}

@(private)
index_for_single_column :: proc(table: ^Table, column: int) -> (int, bool) {
	for index, i in table.indexes {
		if !index_is_plain(index.schema) do continue
		if len(index.schema.columns) == 1 && index.schema.columns[0] == column {
			return i, true
		}
	}
	return -1, false
}

// eval_constant evaluates an expression that does not depend on a row.
@(private)
eval_constant :: proc(expr: ^Expr, params: []Value) -> (Value, bool) {
	if expr == nil do return {}, false
	switch e in expr^ {
	case Literal_Expr:
		return e.value, true
	case Param_Expr:
		if e.index >= 0 && e.index < len(params) do return params[e.index], true
	case Collate_Expr:
		return eval_constant(e.operand, params)
	case Window_Expr:
		return {}, false
	case Unary_Expr:
		value, ok := eval_constant(e.operand, params)
		if !ok do return {}, false
		result, eval_err := eval_unary(e.op, value)
		return result, eval_err.kind == .None
	case Cast_Expr:
		value, ok := eval_constant(e.operand, params)
		if !ok do return {}, false
		result, cast_err := value_cast(value, e.target)
		return result, cast_err.kind == .None
	case Match_Expr:
		// MATCH reads the shadow table, so it is never a constant.
		return {}, false
	case Case_Expr:
		// A CASE is constant when every condition and every result is, but the
		// values still have to be evaluated in context, so it never folds here.
		return {}, false
	case Column_Expr, Star_Expr, Binary_Expr, Is_Null_Expr, Between_Expr, In_Expr, Call_Expr, Like_Expr, Subquery_Expr:
	}
	return {}, false
}

@(private)
now_microseconds :: proc() -> i64 {
	return time.now()._nsec / 1000
}

// sql_hex_digit decodes one hexadecimal character.
@(private)
sql_hex_digit :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9': return int(c - '0'), true
	case 'a' ..= 'f': return int(c - 'a') + 10, true
	case 'A' ..= 'F': return int(c - 'A') + 10, true
	}
	return 0, false
}

// rng_state backs random() and randomblob(); it starts from the clock and
// advances with xorshift64, so no global initialisation is required.
rng_state: u64 = 0

@(private)
rng_next :: proc() -> u64 {
	state := rng_state
	if state == 0 do state = u64(now_microseconds()) | 1
	state ~= state << 13
	state ~= state >> 7
	state ~= state << 17
	rng_state = state
	return state
}

// collate_name reports the collation an expression attaches, if any.
@(private)
collate_name :: proc(expr: ^Expr) -> (string, bool) {
	if expr == nil do return "", false
	if collate, ok := expr^.(Collate_Expr); ok do return collate.name, true
	return "", false
}

// value_compare_collated applies an expression-level collation to two texts. The
// three built-in names fold the text into a byte comparison; a host comparison is
// asked, which is the whole point of registering one. BINARY (the default) and an
// empty name are the plain comparison, and a name nobody knows was refused before
// the statement ran (collation_problem).
@(private)
value_compare_collated :: proc(
	a, b: Value,
	collation: string,
	store: ^Store,
) -> (order: slice.Ordering, ok: bool) {
	if len(collation) > 0 && a.kind == .String && b.kind == .String {
		if compared, known := collation_compare(store, collation, a.s, b.s); known {
			return string_ordering(compared), true
		}
	}
	return value_compare(a, b)
}

// --- Generated columns -----------------------------------------------------

// Generated_Plan holds the parsed expressions of a table's generated columns.
// It is built once per statement so a row only evaluates them.
// expr_calls_a_function reports whether an expression contains a function call,
// which makes a DEFAULT per-row rather than constant.
@(private)
expr_calls_a_function :: proc(e: ^Expr) -> bool {
	found := false
	expr_walk(e, proc(node: ^Expr, user: rawptr) -> bool {
		if _, is_call := node^.(Call_Expr); is_call do (^bool)(user)^ = true
		return true
	}, &found)
	return found
}

// store_expression parses an expression the engine evaluates per row (a CHECK,
// a per-row DEFAULT) once and keeps it for the life of the store: text that
// arrived with the schema is re-read on every write otherwise.
@(private)
store_expression :: proc(store: ^Store, text: string) -> (^Expr, Error) {
	sync.mutex_lock(&store.expr_cache_mutex)
	defer sync.mutex_unlock(&store.expr_cache_mutex)
	if cached, ok := store.expr_cache[text]; ok do return cached.expr, ERROR_NONE
	query, expr, err := sql_parse_expression(text)
	if err.kind != .None do return nil, err
	entry := new(Cached_Expression)
	entry.query = query
	entry.expr = expr
	store.expr_cache[strings.clone(text)] = entry
	return expr, ERROR_NONE
}

// checks_enforce evaluates a table's CHECK constraints against a row about to be
// written. NULL passes and false refuses, as in SQL.
checks_enforce :: proc(tx: ^Tx, table: ^Table, values: []Value) -> Error {
	if len(table.schema.checks) == 0 do return ERROR_NONE
	sources: [1]Source
	sources[0] = Source{table = table, row = Row{values = values}}
	ctx := Eval_Ctx{tx = tx, sources = sources[:], now_us = now_microseconds()}
	for check in table.schema.checks {
		expr, parse_err := store_expression(tx.store, check.sql)
		if parse_err.kind != .None do return parse_err
		value, eval_err := eval_expr(&ctx, expr)
		if eval_err.kind != .None do return eval_err
		if value.kind == .Null || value_is_truthy(value) do continue
		label := len(check.name) > 0 ? check.name : check.sql
		return errf(.Check_Violation, "CHECK constraint failed: %s", label)
	}
	return ERROR_NONE
}

// checks_use_column reports whether a CHECK constraint of the schema names the
// column, which an ALTER that drops or renames it has to respect.
checks_use_column :: proc(schema: ^Table_Schema, column: string, skip_own := false) -> bool {
	Probe :: struct {
		column: string,
		found:  bool,
	}
	for check in schema.checks {
		// A column's own CHECK goes with it when the column is dropped.
		if skip_own && strings.equal_fold(check.column, column) do continue
		query, expr, err := sql_parse_expression(check.sql)
		if err.kind != .None {
			error_free(&err)
			continue
		}
		probe := Probe{column = column}
		expr_walk(expr, proc(node: ^Expr, user: rawptr) -> bool {
			probe := (^Probe)(user)
			if reference, ok := node^.(Column_Expr); ok && strings.equal_fold(reference.name, probe.column) {
				probe.found = true
			}
			return true
		}, &probe)
		query_destroy(&query)
		if probe.found do return true
	}
	return false
}

// column_default_for_row gives a column's default for one row: a per-row DEFAULT
// is evaluated now, a constant one is the stored value.
column_default_for_row :: proc(tx: ^Tx, column: Column) -> (Value, Error) {
	if len(column.default_sql) == 0 do return column_default(column), ERROR_NONE
	expr, parse_err := store_expression(tx.store, column.default_sql)
	if parse_err.kind != .None do return {}, parse_err
	ctx := Eval_Ctx{tx = tx, now_us = now_microseconds()}
	value, eval_err := eval_expr(&ctx, expr)
	if eval_err.kind != .None do return {}, eval_err
	return value_clone(value, tx.alloc), ERROR_NONE
}

Generated_Plan :: struct {
	columns: [dynamic]int,
	queries: [dynamic]Query,
	exprs:   [dynamic]^Expr,
}

generated_plan_make :: proc(tx: ^Tx, table: ^Table) -> (plan: Generated_Plan, err: Error) {
	for column, i in table.schema.columns {
		if !column.generated do continue
		if len(column.generated_sql) == 0 {
			generated_plan_destroy(&plan)
			return plan, errf(.Corrupt_Log, "generated column %s has no expression", column.name)
		}
		query, expr, parse_err := sql_parse_expression(column.generated_sql)
		if parse_err.kind != .None {
			generated_plan_destroy(&plan)
			return plan, errf(.Corrupt_Log, "generated column %s: %s", column.name, parse_err.message)
		}
		append(&plan.columns, i)
		append(&plan.queries, query)
		append(&plan.exprs, expr)
	}
	return plan, ERROR_NONE
}

generated_plan_destroy :: proc(plan: ^Generated_Plan) {
	for &query in plan.queries do query_destroy(&query)
	delete(plan.queries)
	delete(plan.columns)
	delete(plan.exprs)
	plan^ = {}
}

// generated_plan_apply evaluates every generated expression against the row
// about to be stored and writes the result into its column.
generated_plan_apply :: proc(
	ctx: ^Eval_Ctx,
	plan: ^Generated_Plan,
	table: ^Table,
	values: []Value,
) -> Error {
	if len(plan.exprs) == 0 do return ERROR_NONE
	saved := ctx.sources
	synthetic: [1]Source
	synthetic[0] = Source{table = table, row = Row{values = values}}
	ctx.sources = synthetic[:]
	defer ctx.sources = saved
	for expr, i in plan.exprs {
		value, eval_err := eval_expr(ctx, expr)
		if eval_err.kind != .None do return eval_err
		target := plan.columns[i]
		coerced, coerce_err := value_coerce(value, table.schema.columns[target].type)
		if coerce_err.kind != .None {
			return errf(
				.Invalid_Type,
				"generated column %s: %s",
				table.schema.columns[target].name,
				coerce_err.message,
			)
		}
		values[target] = coerced
	}
	return ERROR_NONE
}

// --- Text positions --------------------------------------------------------

// text_char_count counts characters, not bytes: SQLite positions text by
// character, so length('héllo') is five. A malformed byte counts as one.
text_char_count :: proc(text: string) -> int {
	for c in text {
		if c >= 0x80 do return text_char_count_slow(text)
	}
	return len(text)
}

@(private)
text_char_count_slow :: proc(text: string) -> int {
	count, at := 0, 0
	for at < len(text) {
		_, size := utf8.decode_rune_in_string(text[at:])
		if size <= 0 do size = 1
		at += size
		count += 1
	}
	return count
}

// text_byte_at turns a character index into a byte offset. An index at or past
// the last character answers the length, so a slice end needs no special case.
text_byte_at :: proc(text: string, index: int) -> int {
	if index <= 0 do return 0
	ascii := true
	for c in text {
		if c >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii do return min(index, len(text))
	at, seen := 0, 0
	for at < len(text) {
		if seen == index do return at
		_, size := utf8.decode_rune_in_string(text[at:])
		if size <= 0 do size = 1
		at += size
		seen += 1
	}
	return at
}

// --- Collations ------------------------------------------------------------

// collation_known reports whether a column may be declared with this collation.
collation_known :: proc(name: string) -> bool {
	return strings.equal_fold(name, "binary") ||
		strings.equal_fold(name, "nocase") ||
		strings.equal_fold(name, "rtrim")
}

// column_collation resolves a column expression to the collation its column
// declares, so a comparison or a sort without an explicit COLLATE still honours
// it. An unqualified name reads the first source that has the column.
column_collation :: proc(ctx: ^Eval_Ctx, expr: ^Expr) -> (string, bool) {
	if expr == nil do return "", false
	operand := expr
	if collate, ok := operand^.(Collate_Expr); ok do operand = collate.operand
	column, ok := operand^.(Column_Expr)
	if !ok do return "", false
	for source in ctx.sources {
		if len(column.table) > 0 {
			matches := strings.equal_fold(column.table, source.table.schema.name) ||
				(len(source.alias) > 0 && strings.equal_fold(column.table, source.alias))
			if !matches do continue
		}
		index, found := schema_column_index(&source.table.schema, column.name)
		if !found do continue
		if len(source.table.schema.columns[index].collation) > 0 {
			return source.table.schema.columns[index].collation, true
		}
		return "", false
	}
	return "", false
}
