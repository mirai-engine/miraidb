package engine

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"

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
	// The counters are atomic, not under the store's lock: a statement ends
	// while its connection may hold the write lock (a BEGIN a function ran).
	result.work = statement_work(&result)
	sync.atomic_add(&store.work_used, result.work)
	budget := sync.atomic_load(&store.max_work_per_call)
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
	// A query run by its text again is not parsed again: the parse depends on
	// the text alone (names are resolved at every run), and was 2 µs of a point
	// lookup's 15. The resolution rewrites names in the tree (a table's stored
	// spelling), so what it writes lives in the query's own arena, as long as
	// the tree: in the transaction's it would be freed under the cached tree.
	// A tree resolved against another catalog is parsed again (the generation
	// is read before the parse, so a change in between makes it older, never
	// newer, than what it was resolved against).
	generation := store_catalog_generation(store)
	query := statement_cache_take(store, sql, generation)
	if query == nil {
		parsed, parse_err := sql_parse(sql)
		if parse_err.kind != .None do return {}, parse_err
		query = new(Query)
		query^ = parsed
	}
	defer statement_cache_give(store, sql, query, generation)
	return sql_run_statement(store, query.statement, params, query)
}

// STATEMENT_CACHE_SIZE is how many parsed queries a store keeps by their text.
// Each keeps its arena (pooled, QUERY_ARENA_POOL), so the number stays small.
STATEMENT_CACHE_SIZE :: 16

// Statement_Entry is one kept parse; `running` says a statement has it out,
// and `generation` is the catalog generation its names were resolved at.
Statement_Entry :: struct {
	query:      ^Query,
	running:    bool,
	generation: u64,
}

// statement_cache_take hands out the parse of `sql`, which is marked as running
// until it is given back: two threads running the same text never share one
// tree, the second parses its own. Nil when there is none or it is out. A
// parse resolved at another catalog generation is dropped: its names were
// rewritten for a catalog that changed.
@(private)
statement_cache_take :: proc(store: ^Store, sql: string, generation: u64) -> ^Query {
	if store == nil do return nil
	sync.mutex_lock(&store.statement_cache_mutex)
	defer sync.mutex_unlock(&store.statement_cache_mutex)
	entry, found := &store.statement_cache[sql]
	if !found || entry.running do return nil
	if entry.generation != generation {
		key, dropped := delete_key(&store.statement_cache, sql)
		delete(key)
		query_destroy(dropped.query)
		free(dropped.query)
		return nil
	}
	entry.running = true
	return entry.query
}

// statement_cache_give keeps a query's parse for the next run of its text, or
// frees it: only queries are kept (a write's text usually carries its values,
// and repeats less), and a full cache keeps what it has.
@(private)
statement_cache_give :: proc(store: ^Store, sql: string, query: ^Query, generation: u64) {
	keep := false
	#partial switch _ in query.statement {
	case Select_Stmt, With_Stmt:
		keep = store != nil
	}
	if keep {
		sync.mutex_lock(&store.statement_cache_mutex)
		entry, found := &store.statement_cache[sql]
		// The kept parse comes back under the key it already has.
		returned := found && entry.query == query
		if returned do entry.running = false
		else if !found && len(store.statement_cache) < STATEMENT_CACHE_SIZE {
			store.statement_cache[strings.clone(sql)] = Statement_Entry{query = query, generation = generation}
			returned = true
		}
		sync.mutex_unlock(&store.statement_cache_mutex)
		if returned do return
	}
	query_destroy(query)
	free(query)
}

// statement_cache_clear frees every parse the store keeps.
statement_cache_clear :: proc(store: ^Store) {
	sync.mutex_lock(&store.statement_cache_mutex)
	defer sync.mutex_unlock(&store.statement_cache_mutex)
	for key, entry in store.statement_cache {
		delete(key)
		query_destroy(entry.query)
		free(entry.query)
	}
	delete(store.statement_cache)
	store.statement_cache = nil
}

// sql_run_statement dispatches an already parsed statement; prepared statements
// reuse it to avoid parsing on every execution.
@(private)
// `query` is the parse `statement` is the tree of, when the caller has it: what
// its resolution rewrites and the links it makes (Statement_Bindings) live in
// the query's arena, as long as the tree. Without it they live in the
// transaction's and the run makes no links.
sql_run_statement :: proc(store: ^Store, statement: Statement, params: []Value, query: ^Query = nil) -> (Sql_Result, Error) {
	// A statement runs once the ballast is held again (D23).
	if !oom_settle() do return {}, oom_error()
	if refusal := store_refusal(store); refusal.kind != .None do return {}, refusal
	page_failure_clear()
	previous := aggregate_scope_enter(store)
	defer aggregate_scope_leave(previous)
	switch stmt in statement {
	case Select_Stmt, With_Stmt:
		tx := tx_begin_read(store)
		result, exec_err := sql_run_query(tx, stmt, params, query)
		if exec_err.kind == .None {
			if short := statement_shortfall(); short.kind != .None {
				sql_result_destroy(&result)
				exec_err = short
			}
		}
		tx_end(tx)
		result.commit_seq = store.commit_seq
		return result, exec_err
	case Insert_Stmt, Update_Stmt, Delete_Stmt, Merge_Stmt, Copy_Stmt, Create_Table_Stmt, Alter_Table_Stmt, Create_Type_Stmt, Drop_Table_Stmt, Create_Index_Stmt, Drop_Index_Stmt, Create_View_Stmt, Drop_View_Stmt, Create_Policy_Stmt, Drop_Policy_Stmt, Truncate_Stmt, Create_Trigger_Stmt, Drop_Trigger_Stmt, Grant_Stmt, Create_Virtual_Table_Stmt, Load_Extension_Stmt:
		tx := tx_begin_write(store)
		// OR FAIL undoes the failing row alone, which needs the statement journal
		// even here, where a plain failure simply discards the transaction.
		fail_mode := statement_fails_partially(stmt)
		mark := fail_mode ? tx_statement_begin(tx) : 0
		// A statement a function runs on this connection meanwhile runs in
		// this transaction, as SQLite runs it: waiting for its lock waited on
		// this very thread.
		outer_tx, outer_thread := store.statement_tx, store.statement_thread
		store.statement_tx, store.statement_thread = tx, sync.current_thread_id()
		result, exec_err := sql_exec_mutation(tx, stmt, params, query)
		store.statement_tx, store.statement_thread = outer_tx, outer_thread
		// A statement that needed the ballast (D23), or that could not read a
		// page (D8), is taken back whole.
		taken_back := false
		if exec_err.kind == .None {
			if short := statement_shortfall(); short.kind != .None {
				sql_result_destroy(&result)
				exec_err = short
				taken_back = true
			}
		}
		if exec_err.kind == .Out_Of_Memory do taken_back = true
		if fail_mode do tx_statement_end(tx, mark, false)
		if exec_err.kind != .None {
			// A constraint's ON CONFLICT FAIL keeps the rows before the failing
			// one, as an OR FAIL does.
			if (fail_mode || tx.keep_partial) && !taken_back {
				// The rows before the failing one stay, as SQLite keeps them.
				if commit_err := tx_commit(tx); commit_err.kind != .None {
					error_free(&exec_err)
					return {}, commit_err
				}
				return {}, exec_err
			}
			tx_rollback(tx)
			// The statement owned its transaction, so its failure rolls that
			// transaction back, which a rollback hook hears, as in SQLite.
			store_fire_rollback(store)
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
	case Reindex_Stmt:
		tx := tx_begin_write(store)
		result, reindex_err := sql_exec_mutation(tx, stmt, params)
		if reindex_err.kind != .None {
			tx_rollback(tx)
			return {}, reindex_err
		}
		if commit_err := tx_commit(tx); commit_err.kind != .None do return {}, commit_err
		result.commit_seq = store.commit_seq
		return result, ERROR_NONE
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
		return sql_exec_pragma(tx.store, body, tx.locked, tx)
	}
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None do return {}, parse_err
	defer query_destroy(&query)
	result, exec_err := sql_run_statement_in_tx(tx, query.statement, params, &query)
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
// statement_ctes are the CTEs a write carries.
@(private)
statement_ctes :: proc(statement: Statement) -> (ctes: []Cte, recursive: bool) {
	#partial switch s in statement {
	case Insert_Stmt:
		return s.ctes, s.ctes_recursive
	case Update_Stmt:
		return s.ctes, s.ctes_recursive
	case Delete_Stmt:
		return s.ctes, s.ctes_recursive
	}
	return nil, false
}

@(private)
statement_without_ctes :: proc(statement: Statement) -> Statement {
	#partial switch s in statement {
	case Insert_Stmt:
		inner := s
		inner.ctes = nil
		return inner
	case Update_Stmt:
		inner := s
		inner.ctes = nil
		return inner
	case Delete_Stmt:
		inner := s
		inner.ctes = nil
		return inner
	}
	return statement
}

@(private)
statement_fails_partially :: proc(statement: Statement) -> bool {
	#partial switch s in statement {
	case Insert_Stmt:
		return s.conflict_fail
	case Update_Stmt:
		return s.conflict == .Fail
	}
	return false
}

// insert_without_statement_journal reports an INSERT SQLite runs without a
// journal of its own, which an error inside a transaction the program opened
// does not take back: the rows before the failing one stay, as under OR FAIL.
// SQLite journals a statement that writes more than one row only when
// something in it may abort (vdbeaux.c, usesStmtJournal): a constraint whose
// resolution is ABORT, a function call, a trigger, a foreign key. OR IGNORE and
// OR REPLACE over a VALUES list of plain values have none, so a datatype
// mismatch in their third row keeps the first two. They were taken back.
@(private)
insert_without_statement_journal :: proc(tx: ^Tx, statement: Statement) -> bool {
	insert, is_insert := statement.(Insert_Stmt)
	if !is_insert || !insert.conflict_explicit || !(insert.conflict_ignore || insert.conflict_replace) do return false
	if insert.has_select || len(insert.rows) < 2 do return false
	table := tx_table_probe(tx, insert.table)
	if table == nil do return false
	if !tx.store.foreign_keys_off && len(table.schema.foreign_keys) > 0 do return false
	if insert.conflict_replace {
		// REPLACE on a NOT NULL column with no default aborts; NULL for the
		// INTEGER PRIMARY KEY is a new rowid instead.
		alias, _ := rowid_alias_column(&table.schema)
		for column, i in table.schema.columns do if i != alias && column.not_null && !column.has_default do return false
	}
	for trigger in tx_triggers(tx, context.temp_allocator) {
		if strings.equal_fold(trigger.table, insert.table) do return false
	}
	calls := false
	for row in insert.rows {
		for expr in row {
			expr_walk(expr, proc(node: ^Expr, user: rawptr) -> bool {
				if _, is_call := node^.(Call_Expr); is_call do (^bool)(user)^ = true
				return true
			}, &calls)
		}
	}
	return !calls
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

// as_of_sequence evaluates the commit an AS OF names: a constant, not negative,
// and no later than the last commit.
@(private)
as_of_sequence :: proc(tx: ^Tx, expr: ^Expr, params: []Value) -> (u64, Error) {
	moment, constant := eval_constant(expr, params)
	if !constant do return 0, errf(.Invalid_Argument, "AS OF needs a constant commit sequence")
	sequence, ok := value_to_i64(moment)
	if !ok || sequence < 0 do return 0, errf(.Invalid_Argument, "AS OF needs a non-negative commit sequence")
	return min(u64(sequence), tx.store.commit_seq), ERROR_NONE
}

// statement_shortfall is what a statement that did its work without an error
// still fails with: it ran out of memory (D23), or a page it read could not be
// loaded by a reader with no error to hand back (D8).
@(private)
statement_shortfall :: proc() -> Error {
	if oom_short() do return oom_error()
	return page_failure_take()
}

// sql_run_statement_in_tx dispatches an already parsed statement inside a
// transaction.
@(private)
// `query` is as sql_run_statement takes it.
sql_run_statement_in_tx :: proc(tx: ^Tx, statement: Statement, params: []Value, query: ^Query = nil) -> (Sql_Result, Error) {
	if !oom_settle() do return {}, oom_error()
	if refusal := store_refusal(tx.store); refusal.kind != .None do return {}, refusal
	// A statement a trigger runs leaves the failure to the one that fired it,
	// and keeps its time; any other has its own, and gives the time of the one
	// it ran inside back to it.
	outer_now := tx.statement_now_us
	defer tx.statement_now_us = outer_now
	if tx.trigger_depth == 0 {
		page_failure_clear()
		tx.statement_now_us = 0
	}
	previous := aggregate_scope_enter(tx.store)
	defer aggregate_scope_leave(previous)
	switch stmt in statement {
	case Select_Stmt, With_Stmt:
		result, err := sql_run_query(tx, stmt, params, query)
		if err.kind == .None {
			if short := statement_shortfall(); short.kind != .None {
				sql_result_destroy(&result)
				err = short
			}
		}
		return result, err
	case Insert_Stmt, Update_Stmt, Delete_Stmt, Merge_Stmt, Copy_Stmt:
		// A data statement that fails is taken back as a unit (SQLite's ABORT): the
		// transaction keeps the work of the statements before it and none of this
		// one's. OR FAIL keeps the rows before the failing one instead.
		mark := tx_statement_begin(tx)
		// A statement a trigger runs leaves the flag to the one that fired it: a
		// RAISE(FAIL) under it keeps the rows of that outer statement.
		outer := tx.trigger_depth == 0
		if outer do tx.keep_partial = false
		result, err := sql_exec_mutation(tx, stmt, params, query)
		taken_back := err.kind == .Out_Of_Memory
		if err.kind == .None {
			if short := statement_shortfall(); short.kind != .None {
				sql_result_destroy(&result)
				err = short
				taken_back = true
			}
		}
		keeps := err.kind != .None && insert_without_statement_journal(tx, stmt)
		tx_statement_end(tx, mark, taken_back || (err.kind != .None && !statement_fails_partially(stmt) && !tx.keep_partial && !keeps))
		if outer do tx.keep_partial = false
		// OR ROLLBACK: a broken constraint ends the whole transaction, which the
		// connection that holds it rolls back (embed_run).
		if err.kind != .None && conflict_skippable(err.kind) {
			insert, is_insert := stmt.(Insert_Stmt)
			update, is_update := stmt.(Update_Stmt)
			if (is_insert && insert.conflict_rollback) || (is_update && update.conflict == .Rollback) do tx.rollback_requested = true
		}
		return result, err
	case Create_Table_Stmt, Alter_Table_Stmt, Create_Type_Stmt, Drop_Table_Stmt, Create_Index_Stmt, Drop_Index_Stmt, Create_View_Stmt, Drop_View_Stmt, Create_Policy_Stmt, Drop_Policy_Stmt, Truncate_Stmt, Create_Trigger_Stmt, Drop_Trigger_Stmt, Grant_Stmt, Create_Virtual_Table_Stmt, Load_Extension_Stmt:
		return sql_exec_mutation(tx, stmt, params, query)
	case Listen_Stmt:
		store_listen(tx.store, tx.store.session_owner, stmt.channel)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Unlisten_Stmt:
		store_unlisten(tx.store, tx.store.session_owner, stmt.channel, stmt.all)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Notify_Stmt:
		store_notify(tx.store, tx.store.session_owner, stmt.channel, stmt.payload)
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Reindex_Stmt:
		// The indexes are rebuilt from the log when the database opens, so there is
		// never one that is stale; the name is checked so a typo is not accepted.
		if len(stmt.name) > 0 {
			named := false
			if _, is_table := tx.store.tables[stmt.name]; is_table do named = true
			for _, table in tx.store.tables {
				for index in table.schema.indexes {
					if strings.equal_fold(index.name, stmt.name) {
						named = true
						break
					}
				}
				if named do break
			}
			if !named {
				return {}, errf(.Index_Not_Found, "no such index: %s", stmt.name)
			}
		}
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
		// A page size set since the last VACUUM takes effect now, as in SQLite:
		// a mirrored SQLite file is written again at that size.
		if size_err := store_apply_page_size(store, nil); size_err.kind != .None do return {}, size_err
		// A database in memory has no file to compact: VACUUM does nothing, as
		// in SQLite.
		if !store.persistent || store.log.memory_mode {
			return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
		}
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

sql_exec_mutation :: proc(tx: ^Tx, statement: Statement, params: []Value, query: ^Query = nil) -> (Sql_Result, Error) {
	// The statement's links are the transaction's while it runs (statement_resolve).
	outer_bindings := tx.bindings
	defer tx.bindings = outer_bindings
	// A statement that writes an attached database runs in that database's
	// transaction, which this one opens and ends.
	if schema, object, local, attached := statement_attached_object(statement); attached {
		writer, writer_err := tx_attached(tx, schema)
		if writer_err.kind != .None do return {}, writer_err
		// A statement that fails is undone there as a unit, as it is here.
		mark := tx_statement_begin(writer)
		saved_target := writer.attach_target
		writer.attach_target = object
		result, err := sql_exec_mutation(writer, local, params, query)
		writer.attach_target = saved_target
		tx_statement_end(writer, mark, err.kind != .None)
		return result, err
	}
	// A write statement makes the transaction a write transaction even when it
	// changes no row, which is when SQLite calls its commit hook.
	tx.wrote = true
	#partial switch _ in statement {
	case Insert_Stmt, Update_Stmt, Delete_Stmt, Create_Table_Stmt, Create_View_Stmt, Create_Index_Stmt, Drop_Table_Stmt, Drop_View_Stmt, Drop_Index_Stmt, Create_Trigger_Stmt, Alter_Table_Stmt:
		// A name that is not there (or is already there, for a CREATE) is
		// refused before anything is written (D37).
		// The names it rewrites live in the transaction's arena (the heap kept
		// them for good), or in the tree's own when the tree outlives the run.
		statement := statement
		if resolve_err := statement_resolve(tx, &statement, query); resolve_err.kind != .None do return {}, resolve_err
	}
	// A write with CTEs materializes them for its own life, then runs as a
	// plain write that reads them by name.
	if ctes, recursive := statement_ctes(statement); len(ctes) > 0 {
		scope := cte_scope_begin(tx)
		defer cte_scope_end(tx, &scope)
		for cte in ctes {
			table, cte_err := tx_materialize_cte(tx, cte, params, recursive)
			if cte_err.kind != .None do return {}, cte_err
			cte_scope_bind(tx, &scope, cte.name, table)
		}
		return sql_exec_mutation(tx, statement_without_ctes(statement), params, query)
	}
	// A write to a table a program's module serves goes to the module.
	target := ""
	#partial switch s in statement {
	case Insert_Stmt:
		target = s.table
	case Update_Stmt:
		target = s.table
	case Delete_Stmt:
		target = s.table
	}
	// A STRICT table refuses what its columns cannot convert.
	saved_strict := affinity_strict
	defer affinity_strict = saved_strict
	if len(target) > 0 {
		if written := tx_table_probe(tx, target); written != nil do affinity_strict = written.schema.strict
	}
	if len(target) > 0 && tx_table_probe(tx, target) == nil {
		vtab, is_vtab, vtab_err := vtab_find(tx, target)
		if vtab_err.kind != .None do return {}, vtab_err
		if is_vtab do return vtab_write(tx, vtab, statement, params)
		// A view is written through its INSTEAD OF triggers.
		if _, is_view := view_sql(tx, target); is_view do return view_write(tx, target, statement, params)
		// SQLite's table of AUTOINCREMENT counters (sqlite_sequence.odin).
		if strings.equal_fold(target, "sqlite_sequence") && sqlite_sequence_exists(tx) do return sqlite_sequence_write(tx, statement, params)
	}
	switch stmt in statement {
	case Reindex_Stmt:
		// Every index is rebuilt from the log when the database opens, so there is
		// nothing out of date to rebuild. The name, when there is one, is checked
		// so a typo is not silently accepted.
		if len(stmt.name) > 0 {
			named := false
			if _, is_table := tx.store.tables[stmt.name]; is_table {
				named = true
			}
			for _, table in tx.store.tables {
				for index in table.schema.indexes {
					if strings.equal_fold(index.name, stmt.name) {
						named = true
						break
					}
				}
				if named do break
			}
			if !named {
				return {}, errf(.Index_Not_Found, "no such index: %s", stmt.name)
			}
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
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
		if stmt.as_select != nil do return sql_exec_create_table_as(tx, stmt, params)
		existed := tx_table_probe(tx, stmt.name) != nil
		result, err := sql_exec_create_table(tx, stmt, params)
		if err.kind == .None && !existed && len(stmt.text) > 0 {
			if text_err := sql_text_set(tx, stmt.name, stmt.text); text_err.kind != .None do return {}, text_err
		}
		return result, err
	case Alter_Table_Stmt:
		indexes := sql_text_index_names(tx, stmt.table)
		result, err := sql_exec_alter_table(tx, stmt)
		if err.kind == .None {
			if text_err := sql_text_on_alter(tx, stmt, indexes); text_err.kind != .None do return {}, text_err
		}
		return result, err
	case Create_Type_Stmt:
		return sql_exec_create_type(tx, stmt)
	case Drop_Table_Stmt:
		indexes := sql_text_index_names(tx, stmt.name)
		result, err := sql_exec_drop_table(tx, stmt)
		if err.kind == .None {
			if text_err := sql_text_forget(tx, stmt.name); text_err.kind != .None do return {}, text_err
			for index in indexes {
				if text_err := sql_text_forget(tx, index); text_err.kind != .None do return {}, text_err
			}
		}
		return result, err
	case Create_Index_Stmt:
		_, had_text := sql_text_of(tx, stmt.name)
		result, err := sql_exec_create_index(tx, stmt)
		if err.kind == .None && !(stmt.if_not_exists && had_text) && len(stmt.text) > 0 {
			if text_err := sql_text_set(tx, stmt.name, stmt.text); text_err.kind != .None do return {}, text_err
		}
		return result, err
	case Drop_Index_Stmt:
		result, err := sql_exec_drop_index(tx, stmt)
		if err.kind == .None {
			if text_err := sql_text_forget(tx, stmt.name); text_err.kind != .None do return {}, text_err
		}
		return result, err
	case Create_View_Stmt:
		_, existed := view_sql(tx, stmt.name)
		result, err := sql_exec_create_view(tx, stmt)
		if err.kind == .None && !(existed && stmt.if_not_exists) && len(stmt.text) > 0 {
			if text_err := sql_text_set(tx, stmt.name, stmt.text); text_err.kind != .None do return {}, text_err
		}
		return result, err
	case Drop_View_Stmt:
		result, err := sql_exec_drop_view(tx, stmt)
		if err.kind == .None {
			if text_err := sql_text_forget(tx, stmt.name); text_err.kind != .None do return {}, text_err
		}
		return result, err
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
		existed := trigger_lookup(tx, stmt.name)
		if trigger_err := trigger_create(tx, stmt); trigger_err.kind != .None {
			return {}, trigger_err
		}
		if !(existed && stmt.if_not_exists) && len(stmt.text) > 0 {
			if text_err := sql_text_set(tx, stmt.name, stmt.text); text_err.kind != .None do return {}, text_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Drop_Trigger_Stmt:
		if trigger_err := trigger_drop(tx, stmt.name, stmt.if_exists); trigger_err.kind != .None {
			return {}, trigger_err
		}
		if text_err := sql_text_forget(tx, stmt.name); text_err.kind != .None do return {}, text_err
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Grant_Stmt:
		return sql_exec_grant(tx, stmt)
	case Create_Virtual_Table_Stmt:
		if handled, vtab_err := vtab_create(tx, stmt); handled {
			if vtab_err.kind != .None do return {}, vtab_err
			return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
		}
		if stmt.if_not_exists {
			if _, found := fts_virtual_lookup(tx, stmt.name); found {
				return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
			}
		}
		if fts_err := fts_create(tx, stmt.name, stmt.module, stmt.columns); fts_err.kind != .None {
			return {}, fts_err
		}
		// sqlite_master shows the statement as written, as SQLite keeps it.
		if len(stmt.text) > 0 {
			if text_err := sql_text_set(tx, stmt.name, stmt.text); text_err.kind != .None do return {}, text_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	case Select_Stmt, With_Stmt, Set_Stmt, Show_Stmt, Explain_Stmt, Describe_Stmt, Vacuum_Stmt, Attach_Stmt, Detach_Stmt, Begin_Stmt, Commit_Stmt, Rollback_Stmt, Savepoint_Stmt:
	}
	return {}, errf(.Sql_Unsupported, "statement does not modify data")
}


// --- Prepared statements ---------------------------------------------------

// Prepared keeps the parsed statement so repeated executions do not parse
// again, and is safe to reuse with new params. Its tree is resolved against one
// catalog generation: a run at another one parses `sql` again first
// (prepared_stale, prepared_reprepare), as SQLite prepares a statement again
// after a schema change.
Stmt_Prepared :: struct {
	query:       Query,
	// sql is the statement's text, which a new catalog parses again.
	sql:         string,
	// generation is the catalog generation the tree was parsed at; `fresh` says
	// no run has resolved it yet.
	generation:  u64,
	fresh:       bool,
	is_pragma:   bool,
	pragma_body: string,
	// param_count is how many positional parameters the statement binds, so a
	// caller can refuse an index before it becomes a silent growth (D29).
	param_count: int,
	// ignored is set when the authorizer answered Ignore to the statement's own
	// action: it prepares, and running it does nothing.
	ignored: bool,
	// views holds the queries of views a statement reads through a column the
	// authorizer ignored: the reference became a derived table over the
	// rewritten query, which lives as long as the statement.
	views:   [dynamic]^Query,
	// trigger_ignores are the Ignore answers given about the bodies of the
	// triggers it fires, given again when they fire (authorize.odin).
	trigger_ignores: [dynamic]Auth_Key,
}

sql_prepare :: proc(store: ^Store, sql: string) -> (^Stmt_Prepared, Error) {
	prepared := new(Stmt_Prepared)
	if body, is_pragma := sqlite_pragma_statement(sql); is_pragma {
		prepared.is_pragma = true
		prepared.pragma_body = strings.clone(body)
		return prepared, ERROR_NONE
	}
	generation := store_catalog_generation(store)
	query, parse_err := sql_parse(sql)
	if parse_err.kind != .None {
		free(prepared)
		return nil, parse_err
	}
	prepared.query = query
	prepared.sql = strings.clone(sql)
	prepared.generation = generation
	prepared.fresh = true
	prepared.param_count = query.param_count
	return prepared, ERROR_NONE
}

// prepared_stale says the statement's tree cannot run as it is in `tx` (nil for
// a run in its own transaction): the catalog moved on since it was parsed, or
// the transaction staged a change to it and the tree was resolved before.
prepared_stale :: proc(store: ^Store, prepared: ^Stmt_Prepared, tx: ^Tx = nil) -> bool {
	if prepared == nil || prepared.is_pragma || prepared.fresh do return false
	return prepared.generation != store_catalog_generation(store) || tx_changes_catalog(tx)
}

// prepared_reprepare parses the statement's text again, for the catalog as it
// is now. What an authorizer made of the old tree goes with it: a connection
// that asks one asks it again (embed_authorize).
prepared_reprepare :: proc(store: ^Store, prepared: ^Stmt_Prepared) -> Error {
	generation := store_catalog_generation(store)
	query, parse_err := sql_parse(prepared.sql)
	if parse_err.kind != .None do return parse_err
	query_destroy(&prepared.query)
	for view in prepared.views {
		query_destroy(view)
		free(view)
	}
	clear(&prepared.views)
	clear(&prepared.trigger_ignores)
	prepared.ignored = false
	prepared.query = query
	prepared.param_count = query.param_count
	prepared.generation = generation
	prepared.fresh = true
	return ERROR_NONE
}

// prepared_settle marks a run done: a tree resolved under a catalog change the
// transaction has not committed holds for no other run.
@(private)
prepared_settle :: proc(prepared: ^Stmt_Prepared, tx: ^Tx = nil) {
	prepared.fresh = false
	if tx_changes_catalog(tx) do prepared.generation = max(u64)
}

stmt_prepared_destroy :: proc(prepared: ^Stmt_Prepared) {
	if prepared == nil do return
	if prepared.is_pragma {
		delete(prepared.pragma_body)
	} else {
		query_destroy(&prepared.query)
		delete(prepared.sql)
	}
	for view in prepared.views {
		query_destroy(view)
		free(view)
	}
	delete(prepared.views)
	delete(prepared.trigger_ignores)
	free(prepared)
}

@(private)
sql_price :: proc(store: ^Store, result: ^Sql_Result) -> Error {
	// The counters are atomic, not under the store's lock: a statement ends
	// while its connection may hold the write lock (a BEGIN a function ran).
	result.work = statement_work(result)
	sync.atomic_add(&store.work_used, result.work)
	budget := sync.atomic_load(&store.max_work_per_call)
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
	if prepared_stale(store, prepared) {
		if reprepare_err := prepared_reprepare(store, prepared); reprepare_err.kind != .None do return {}, reprepare_err
	}
	defer prepared_settle(prepared)
	// The tree runs again: the names its resolution rewrites live with it.
	result, exec_err := sql_run_statement(store, prepared.query.statement, params, &prepared.query)
	if exec_err.kind != .None do return {}, exec_err
	if price_err := sql_price(store, &result); price_err.kind != .None do return {}, price_err
	return result, ERROR_NONE
}

// prepared_execute_in_tx runs a prepared statement inside an existing
// transaction (the path benchmarks and reducers use).
prepared_execute_in_tx :: proc(tx: ^Tx, prepared: ^Stmt_Prepared, params: []Value) -> (Sql_Result, Error) {
	if prepared == nil do return {}, errf(.Invalid_Argument, "no prepared statement")
	if prepared.is_pragma do return sql_exec_pragma(tx.store, prepared.pragma_body, tx.locked, tx)
	if prepared_stale(tx.store, prepared, tx) {
		if reprepare_err := prepared_reprepare(tx.store, prepared); reprepare_err.kind != .None do return {}, reprepare_err
	}
	defer prepared_settle(prepared, tx)
	return sql_run_statement_in_tx(tx, prepared.query.statement, params, &prepared.query)
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
	set_ctx := eval_context(Eval_Ctx{params = params})
	value, eval_err := eval_expr(&set_ctx, stmt.value)
	if eval_err.kind != .None do return {}, eval_err
	if strings.equal_fold(stmt.name, "identity") {
		// A client is the identity its token proved; naming another is the host's.
		if client_untrusted(store) do return {}, client_authority_refusal("SET identity")
		coerced, coerce_err := value_coerce(value, Column_Type{kind = .Identity})
		if coerce_err.kind != .None {
			return {}, error_wrap(coerce_err, .Invalid_Type, "SET identity needs a 32-byte hex string")
		}
		store_set_identity(store, value_identity_of(coerced))
		return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
	}
	if set_err := store_set_variable_locked(store, stmt.name, value); set_err.kind != .None {
		return {}, set_err
	}
	return Sql_Result{kind = .Ack, commit_seq = store.commit_seq}, ERROR_NONE
}

// show_columns gives a result its column names, the array and each name its
// own: a slice literal there lived on the stack of the proc that returned it,
// and the result's destroy freed string literals.
@(private)
show_columns :: proc(names: ..string) -> []string {
	out := make([]string, len(names))
	for name, i in names do out[i] = result_own(name)
	return out
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
		delete(result.columns[0])
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
		delete(rows)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		out.columns = show_columns("name", "base")
		if _, exists := store.tables[TYPE_TABLE]; !exists do return out, ERROR_NONE
		catalog := store.tables[TYPE_TABLE]
		entries := make([dynamic]Row)
		defer delete(entries)
		table_collect(catalog, &entries, max(u64))
		slice.sort_by(entries[:], proc(a, b: Row) -> bool {
			return text_compare(a.values[0].s, b.values[0].s) < 0
		})
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
		delete(rows)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		out.columns = show_columns("table")
		names := event_tables(store, context.allocator)
		defer delete(names)
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
		delete(rows)
		out := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		out.columns = show_columns("table", "index", "columns")
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
				row[2] = value_string(index_parts_text(table, idx, context.allocator))
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
	case Reindex_Stmt:
		return {}, errf(.Sql_Not_A_Query, "EXPLAIN does not apply to REINDEX")
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
			// A view or CTE on the inner side is no stored table: that refusal only
			// means no index can answer, and it is freed.
			inner_table, inner_err := store_table(store, step.ref.name)
			stored := inner_err.kind == .None
			error_free(&inner_err)
			if stored {
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
			append(&lines, fmt.aprintf("join order: %s", strings.join(names[:], ", ", context.temp_allocator)))
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
	if stmt.query_plan {
		// EXPLAIN QUERY PLAN is SQLite's shape of the same answer: one row per
		// step, with an id, the id of its parent, an unused column, and the step
		// in SQLite's words, which is what a database browser prints.
		plan := Sql_Result{kind = .Rows, commit_seq = store.commit_seq}
		// make, not a slice literal: the result owns its columns and frees them,
		// and a literal's backing array is not the heap.
		plan.columns = make([]string, 4)
		plan.columns[0] = result_own("id")
		plan.columns[1] = result_own("parent")
		plan.columns[2] = result_own("notused")
		plan.columns[3] = result_own("detail")
		plan.rows = make([][]Value, len(lines))
		for line, i in lines {
			row := make([]Value, 4)
			row[0] = value_int(i64(i + 1))
			row[1] = value_int(i == 0 ? 0 : 1)
			row[2] = value_int(0)
			row[3] = value_string(explain_query_plan_detail(line))
			plan.rows[i] = row
			// The detail is a copy in SQLite's words; this engine's line goes.
			delete(line)
		}
		return plan, ERROR_NONE
	}
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

// explain_query_plan_detail rewrites one step of this engine's plan in the words
// SQLite uses, so a tool that reads the detail column shows something familiar.
@(private)
explain_query_plan_detail :: proc(line: string) -> string {
	if strings.has_prefix(line, "scan ") {
		rest := line[len("scan "):]
		// `scan emp using index by_dept (est. …)` names the index it reads.
		if cut := strings.index(rest, " using index "); cut >= 0 {
			table := rest[:cut]
			index_part := rest[cut + len(" using index "):]
			index_end := strings.index(index_part, " (")
			index := index_end >= 0 ? index_part[:index_end] : index_part
			return fmt.aprintf("SEARCH %s USING INDEX %s", table, index)
		}
		if cut := strings.index(rest, " ("); cut >= 0 do rest = rest[:cut]
		if len(rest) == 0 do return strings.clone("SCAN CONSTANT ROW")
		return fmt.aprintf("SCAN %s", rest)
	}
	if strings.has_prefix(line, "join ") {
		rest := line[len("join "):]
		if cut := strings.index(rest, " ("); cut >= 0 do rest = rest[:cut]
		return fmt.aprintf("SEARCH %s", rest)
	}
	if strings.has_prefix(line, "order by") {
		return strings.clone("USE TEMP B-TREE FOR ORDER BY")
	}
	if strings.has_prefix(line, "group by") {
		return strings.clone("USE TEMP B-TREE FOR GROUP BY")
	}
	return strings.clone(line)
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
