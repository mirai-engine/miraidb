package engine

import "core:fmt"
import "core:strings"

@(private)
types_ensure_table :: proc(tx: ^Tx) -> Error {
	if _, table_err := tx_table(tx, TYPE_TABLE); table_err.kind == .None {
		return ERROR_NONE
	} else {
		error_free(&table_err)
	}
	result, create_err := sql_execute_in_tx(tx, TYPE_SCHEMA_SQL)
	if create_err.kind != .None do return create_err
	sql_result_destroy(&result)
	return ERROR_NONE
}

// resolve_named_type looks a named type up in the catalog and returns its base.
@(private)
resolve_named_type :: proc(tx: ^Tx, name: string) -> (Column_Type, Error) {
	if _, table_err := tx_table(tx, TYPE_TABLE); table_err.kind != .None {
		error_free(&table_err)
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
	discarded_20, insert_err := sql_execute_in_tx_params(
		tx,
		"INSERT INTO _type (name, base) VALUES (?, ?)",
		[]Value{value_string(stmt.name), value_string(base_text)},
	)
	sql_result_destroy(&discarded_20)
	if insert_err.kind != .None do return {}, insert_err
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

sql_exec_alter_table :: proc(tx: ^Tx, stmt: Alter_Table_Stmt) -> (Sql_Result, Error) {
	// A program's module renames its own table.
	if len(stmt.rename_to) > 0 && len(stmt.rename_column) == 0 {
		if handled, rename_err := vtab_rename(tx, stmt.table, stmt.rename_to); handled {
			if rename_err.kind != .None do return {}, rename_err
			return Sql_Result{kind = .Ack}, ERROR_NONE
		}
	}
	stmt := stmt
	// Through the SQLite face an added column's type is an affinity too.
	if tx.store.sqlite_names && len(stmt.column.name) > 0 {
		stmt.column.type = sqlite_affinity_type(stmt.add_declared)
	}
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
		if follow_err := alter_follow_rename_column(tx, stmt.table, stmt.rename_column, stmt.rename_to); follow_err.kind != .None {
			return {}, follow_err
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	if len(stmt.rename_to) > 0 {
		if rename_err := tx_rename_table(tx, stmt.table, stmt.rename_to); rename_err.kind != .None {
			return {}, rename_err
		}
		if follow_err := alter_follow_rename_table(tx, stmt.table, stmt.rename_to); follow_err.kind != .None {
			return {}, follow_err
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
	if stmt.ephemeral do tx.store.temp_used = true
	schema.event = stmt.event
	columns := make([]Column, len(stmt.columns), tx.alloc)
	inline_primary := NO_COLUMN
	for definition, i in stmt.columns {
		column_type := definition.type
		named_type := definition.type_name
		if len(definition.type_name) > 0 {
			resolved, resolve_err := resolve_named_type(tx, definition.type_name)
			if resolve_err.kind == .Invalid_Type {
				// A name no CREATE TYPE defined is read the way SQLite reads any
				// type name: by its affinity.
				error_free(&resolve_err)
				column_type = sqlite_affinity_type(definition.type_name)
				named_type = ""
			} else if resolve_err.kind != .None {
				return {}, resolve_err
			} else {
				column_type = resolved
			}
		}
		if stmt.strict {
			// A STRICT table names one of SQLite's five types, and holds it.
			strict_type, known := sqlite_strict_type(definition.declared)
			if !known {
				return {}, errf(.Invalid_Argument, "unknown datatype for %s.%s: \"%s\"", stmt.name, definition.name, definition.declared)
			}
			column_type = strict_type
			named_type = ""
		} else if tx.store.sqlite_names && len(named_type) == 0 && !definition.autoinc {
			// Through the SQLite face a declared type means what it means to
			// SQLite: an affinity, not a storage type.
			column_type = sqlite_affinity_type(definition.declared)
		}
		collation := ""
		if len(definition.collation) > 0 {
			if !collation_known(definition.collation) {
				// A host comparison may be a column's collation: comparisons, ORDER BY,
				// grouping and keys read it (a key compares rows with it,
				// tx_host_key_taken).
				if _, is_host := store_collation(tx.store, definition.collation); !is_host {
					return {}, errf(.Invalid_Argument, "no such collation sequence: %s", definition.collation)
				}
			}
			collation = strings.clone(definition.collation, tx.alloc)
		}
		if definition.generated && definition.default != nil {
			return {}, errf(.Invalid_Argument, "generated column %s cannot have a DEFAULT", definition.name)
		}
		column := Column {
			name           = strings.clone(definition.name, tx.alloc),
			type           = column_type,
			named_type     = named_type,
			unique         = definition.unique,
			not_null       = definition.not_null || (definition.primary && !sqlite_key_takes_null(tx.store, stmt.without_rowid, definition.declared)),
			not_null_conflict = definition.not_null_conflict,
			unique_conflict   = definition.unique_conflict,
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
		schema.pk_conflict = stmt.columns[inline_primary].primary_conflict
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
					error_free(&parent_err)
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
			// A key that names no unique key of its parent is declared all the
			// same, as SQLite declares it; enforcing it is what fails, with
			// "foreign key mismatch" (foreign.odin).
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
			schema.pk_conflict = constraint.conflict
			for position in positions {
				if sqlite_key_takes_null(tx.store, stmt.without_rowid, "", len(positions) > 1) do continue
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
			Index_Schema{name = name, columns = positions, unique = true, implicit = false, on_conflict = constraint.conflict},
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

	schema.strict = stmt.strict
	schema.without_rowid = stmt.without_rowid
	if stmt.without_rowid && len(schema.primary_key) == 0 {
		return {}, errf(.Invalid_Argument, "PRIMARY KEY missing on table %s", stmt.name)
	}
	if create_err := tx_create_table(tx, &schema); create_err.kind != .None {
		if create_err.kind == .Table_Exists && stmt.if_not_exists {
			error_free(&create_err)
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
	// A program's module destroys its own table.
	if handled, vtab_err := vtab_drop(tx, stmt.name); handled {
		if vtab_err.kind != .None do return {}, vtab_err
		return Sql_Result{kind = .Ack}, ERROR_NONE
	}
	// A virtual table owns a shadow table and a catalog row: dropping it drops all
	// three, so nothing is left behind to be reindexed later.
	if virtual, virtual_err := fts_drop_if_virtual(tx, stmt.name, stmt.if_exists); virtual {
		if virtual_err.kind != .None do return {}, virtual_err
		return Sql_Result{kind = .Ack}, ERROR_NONE
	}
	if drop_err := tx_drop_table(tx, stmt.name); drop_err.kind != .None {
		if drop_err.kind == .Table_Not_Found && stmt.if_exists {
			error_free(&drop_err)
			return Sql_Result{kind = .Ack}, ERROR_NONE
		}
		return {}, drop_err
	}
	// The table's triggers go with it, as in SQLite: they stayed, and fired on
	// the next table of that name.
	if trigger_err := triggers_drop_on(tx, stmt.name); trigger_err.kind != .None do return {}, trigger_err
	if policy_err := policies_drop_on(tx, stmt.name); policy_err.kind != .None do return {}, policy_err
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
	// An index holds what its expressions answered, so they have to answer the
	// same every time, as SQLite requires.
	if len(stmt.where_sql) > 0 {
		if parsed, parsed_expr, parse_err := sql_parse_expression(stmt.where_sql); parse_err.kind == .None {
			_, nondeterministic := expr_nondeterministic(tx.store, parsed_expr)
			problem, problem_kind := index_host_problem(tx.store, parsed_expr)
			missing := index_unknown_column(table, parsed_expr)
			query_destroy(&parsed)
			if len(missing) > 0 do return {}, errf(.Column_Not_Found, "no such column: %s", missing)
			if nondeterministic do return {}, errf(.Sql_Unsupported, "non-deterministic functions prohibited in partial index WHERE clauses")
			if len(problem) > 0 do return {}, errf(problem_kind, "%s", problem)
		} else {
			error_free(&parse_err)
		}
	}
	for text in stmt.exprs {
		if len(text) == 0 do continue
		if parsed, parsed_expr, parse_err := sql_parse_expression(text); parse_err.kind == .None {
			_, nondeterministic := expr_nondeterministic(tx.store, parsed_expr)
			problem, problem_kind := index_host_problem(tx.store, parsed_expr)
			missing := index_unknown_column(table, parsed_expr)
			query_destroy(&parsed)
			if len(missing) > 0 do return {}, errf(.Column_Not_Found, "no such column: %s", missing)
			if nondeterministic do return {}, errf(.Sql_Unsupported, "non-deterministic functions prohibited in index expressions")
			if len(problem) > 0 do return {}, errf(problem_kind, "%s", problem)
		} else {
			error_free(&parse_err)
		}
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

// index_unknown_column names a column an index expression reads that its table
// does not have, or answers "": the expression was accepted, and only a row
// made it fail. The name is the temp allocator's.
@(private)
index_unknown_column :: proc(table: ^Table, expr: ^Expr) -> string {
	Probe :: struct {
		table:   ^Table,
		missing: string,
	}
	probe := Probe{table = table}
	expr_walk(expr, proc(node: ^Expr, user: rawptr) -> bool {
		probe := (^Probe)(user)
		if column, ok := node^.(Column_Expr); ok && len(probe.missing) == 0 {
			if _, found := schema_column_index(&probe.table.schema, column.name); !found && !rowid_alias_name(column.name) {
				probe.missing = strings.clone(column.name, context.temp_allocator)
			}
		}
		return true
	}, &probe)
	return probe.missing
}

// index_host_problem says why an index cannot hold an expression, or answers
// "": a collation nobody registered is refused as SQLite refuses it, since an
// index ordered by BINARY under another name is one SQLite finds out of order
// (D24). The message is the temp allocator's, so it outlives the parsed
// expression.
@(private)
index_host_problem :: proc(store: ^Store, expr: ^Expr) -> (string, Error_Kind) {
	Probe :: struct {
		store:   ^Store,
		problem: string,
		kind:    Error_Kind,
	}
	probe := Probe{store = store}
	expr_walk(expr, proc(node: ^Expr, user: rawptr) -> bool {
		probe := (^Probe)(user)
		if len(probe.problem) > 0 do return false
		#partial switch e in node^ {
		case Collate_Expr:
			if len(e.name) == 0 || collation_is_builtin(e.name) do break
			if _, found := store_collation(probe.store, e.name); !found {
				probe.problem = fmt.tprintf("no such collation sequence: %s", e.name)
				probe.kind = .Invalid_Argument
			}
		}
		return true
	}, &probe)
	return probe.problem, probe.kind
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
