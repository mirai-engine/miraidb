package engine

import "core:strings"

// Row-level security is declarative data: `_policy` holds one row per policy
// with the visibility predicate (`USING`) and the write predicate (`CHECK`) as
// SQL text. Enforcement parses a predicate once per statement and evaluates it
// against the bound row, so policies run through the same expression evaluator
// as user queries and can call `current_identity()`.
//
// Several policies on one table are combined with AND. Policies never apply to
// the internal tables (their names start with `_`).

POLICY_TABLE :: "_policy"
POLICY_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _policy (
		name TEXT PRIMARY KEY,
		table_name TEXT NOT NULL,
		using_sql TEXT NOT NULL DEFAULT '',
		check_sql TEXT NOT NULL DEFAULT ''
	)`

// Policy_Set owns the parsed predicates and the query arenas behind them.
Policy_Set :: struct {
	using_exprs: [dynamic]^Expr,
	check_exprs: [dynamic]^Expr,
	queries:     [dynamic]^Query,
}

sql_exec_create_policy :: proc(tx: ^Tx, stmt: Create_Policy_Stmt) -> (Sql_Result, Error) {
	if len(stmt.using_sql) == 0 && len(stmt.check_sql) == 0 {
		return {}, errf(.Sql_Syntax, "a policy needs USING, CHECK or both")
	}
	if _, table_err := tx_table(tx, stmt.table); table_err.kind != .None {
		return {}, table_err
	}
	if validate_err := policy_validate(tx, stmt.table, stmt.using_sql); validate_err.kind != .None {
		return {}, validate_err
	}
	if validate_err := policy_validate(tx, stmt.table, stmt.check_sql); validate_err.kind != .None {
		return {}, validate_err
	}
	if err := policies_ensure_table(tx); err.kind != .None do return {}, err
	existing, check_err := sql_execute_in_tx_params(
		tx,
		"SELECT 1 FROM _policy WHERE name = ?",
		[]Value{value_string(stmt.name)},
	)
	if check_err.kind != .None do return {}, check_err
	found := len(existing.rows) > 0
	sql_result_destroy(&existing)
	if found {
		return {}, errf(.Table_Exists, "policy %s already exists", stmt.name)
	}
	params := []Value{
		value_string(stmt.name),
		value_string(stmt.table),
		value_string(stmt.using_sql),
		value_string(stmt.check_sql),
	}
	if _, insert_err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _policy (name, table_name, using_sql, check_sql) VALUES (?, ?, ?, ?)",
		params,
	); insert_err.kind != .None {
		return {}, insert_err
	}
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

sql_exec_drop_policy :: proc(tx: ^Tx, stmt: Drop_Policy_Stmt) -> (Sql_Result, Error) {
	if _, err := tx_table(tx, POLICY_TABLE); err.kind != .None {
		if stmt.if_exists do return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
		return {}, errf(.Table_Not_Found, "policy %s does not exist", stmt.name)
	}
	result, delete_err := sql_execute_in_tx_params(
		tx,
		"DELETE FROM _policy WHERE name = ?",
		[]Value{value_string(stmt.name)},
	)
	if delete_err.kind != .None do return {}, delete_err
	affected := result.affected
	sql_result_destroy(&result)
	if affected == 0 && !stmt.if_exists {
		return {}, errf(.Table_Not_Found, "policy %s does not exist", stmt.name)
	}
	return Sql_Result{kind = .Ack, affected = affected, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

@(private)
policies_ensure_table :: proc(tx: ^Tx) -> Error {
	if _, err := tx_table(tx, POLICY_TABLE); err.kind == .None do return ERROR_NONE
	result, create_err := sql_execute_in_tx(tx, POLICY_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	return ERROR_NONE
}

@(private)
policy_validate :: proc(tx: ^Tx, table, sql: string) -> Error {
	if len(sql) == 0 do return ERROR_NONE
	set: Policy_Set
	defer policy_set_destroy(&set)
	_, err := policy_parse(tx, table, sql, &set)
	return err
}

@(private)
policy_parse :: proc(tx: ^Tx, table, sql: string, set: ^Policy_Set) -> (^Expr, Error) {
	source := strings.concatenate({"SELECT 1 FROM ", table, " WHERE (", sql, ")"})
	defer delete(source)
	query := new(Query)
	parsed, parse_err := sql_parse(source)
	query^ = parsed
	append(&set.queries, query)
	if parse_err.kind != .None do return nil, parse_err
	select_stmt, is_select := query.statement.(Select_Stmt)
	if !is_select || select_stmt.where_clause == nil {
		return nil, errf(.Sql_Syntax, "policy %s is not a predicate", sql)
	}
	return select_stmt.where_clause, ERROR_NONE
}

// policy_load parses every policy that applies to `table`. An absent `_policy`
// table or an unconstrained table yields an empty set.
policy_load :: proc(tx: ^Tx, table: string) -> (Policy_Set, Error) {
	set: Policy_Set
	if strings.has_prefix(table, "_") do return set, ERROR_NONE
	rows := make([dynamic]Row)
	defer delete(rows)
	if collect_err := tx_collect(tx, POLICY_TABLE, &rows); collect_err.kind != .None {
		if collect_err.kind == .Table_Not_Found do return set, ERROR_NONE
		return set, collect_err
	}
	for row in rows {
		if row.values[1].kind != .String || row.values[1].s != table do continue
		using_sql := row.values[2].s
		check_sql := row.values[3].s
		if len(using_sql) > 0 {
			expr, parse_err := policy_parse(tx, table, using_sql, &set)
			if parse_err.kind != .None {
				policy_set_destroy(&set)
				return {}, parse_err
			}
			append(&set.using_exprs, expr)
		}
		if len(check_sql) > 0 {
			expr, parse_err := policy_parse(tx, table, check_sql, &set)
			if parse_err.kind != .None {
				policy_set_destroy(&set)
				return {}, parse_err
			}
			append(&set.check_exprs, expr)
		}
	}
	return set, ERROR_NONE
}

// policy_allows evaluates the set against the currently bound sources. An empty
// set allows everything, which is what an UNCONSTRAINED table means.
policy_allows :: proc(set: ^Policy_Set, ctx: ^Eval_Ctx, check: bool) -> (bool, Error) {
	exprs := check ? set.check_exprs : set.using_exprs
	for expr in exprs {
		value, eval_err := eval_expr(ctx, expr)
		if eval_err.kind != .None do return false, eval_err
		if !value_is_truthy(value) do return false, ERROR_NONE
	}
	return true, ERROR_NONE
}

policy_set_destroy :: proc(set: ^Policy_Set) {
	for query in set.queries {
		query_destroy(query)
		free(query)
	}
	delete(set.queries)
	delete(set.using_exprs)
	delete(set.check_exprs)
}

policy_sets_destroy :: proc(sets: ^[dynamic]Policy_Set) {
	for &set in sets do policy_set_destroy(&set)
	delete(sets^)
}
