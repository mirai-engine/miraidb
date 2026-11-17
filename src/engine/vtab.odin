package engine

import "base:runtime"
import "core:strings"

// --- Virtual tables a program implements ------------------------------------
//
// A module is code the program registers (sqlite3_create_module): it declares
// a table's columns, produces its rows and, when it can, takes writes. The
// engine reads such a table the way it reads a view: the rows the module
// produces are materialized into a temporary table for the statement, so every
// clause, join and function of the executor applies to them. Arguments written
// after the name (`FROM series(1, 10)`) reach the module as equality
// constraints on its HIDDEN columns, in order, which is how SQLite passes them;
// the rest of the WHERE is applied by the executor afterwards. A write calls
// the module's update with SQLite's argument layout.
//
// A table made with CREATE VIRTUAL TABLE is recorded in the `_virtual` catalog
// with its module and arguments, and connected again when a later connection
// that registered the module first reads it. A module whose name is a table
// (eponymous) needs no CREATE.

// Vtab_Constraint is one constraint the engine offers a module: a column
// (-1 for the row id), SQLite's operator code, and whether it can be used.
Vtab_Constraint :: struct {
	column: int,
	op:     u8,
	usable: bool,
}

VTAB_OP_EQ :: u8(2)

// Vtab_Row is one row a module produced: its row id and a value per declared
// column, owned by the caller's allocator.
Vtab_Row :: struct {
	rowid:  i64,
	values: []Value,
}

Vtab_Module :: struct {
	ctx:            rawptr,
	// eponymous: the module's own name is a table. eponymous_only: it has no
	// create step, so CREATE VIRTUAL TABLE cannot use it.
	eponymous:      bool,
	eponymous_only: bool,
	connect:        proc(ctx: rawptr, create: bool, table: string, args: []string) -> (handle: rawptr, declaration: string, err: Error),
	disconnect:     proc(ctx: rawptr, handle: rawptr, destroy: bool) -> Error,
	scan:           proc(ctx: rawptr, handle: rawptr, constraints: []Vtab_Constraint, values: []Value, columns: int, rows: ^[dynamic]Vtab_Row) -> Error,
	// update is nil for a read-only module.
	update:         proc(ctx: rawptr, handle: rawptr, argv: []Value, rowid: ^i64) -> Error,
	// release runs when the module is unregistered or the store closes.
	release:        proc(ctx: rawptr),
}

// Vtab is one connected table.
Vtab :: struct {
	name:    string,
	module:  string,
	handle:  rawptr,
	columns: []Column,
}

VTAB_ROWID_COLUMN :: "_vtab_rowid"

// store_register_vtab_module adds or replaces a module by name.
store_register_vtab_module :: proc(store: ^Store, name: string, module: Vtab_Module) -> Error {
	if store == nil do return errf(.Invalid_Argument, "no database")
	if len(name) == 0 do return errf(.Invalid_Argument, "a module needs a name")
	store_unregister_vtab_module(store, name)
	if store.vtab_modules == nil do store.vtab_modules = make(map[string]Vtab_Module, 4, runtime.heap_allocator())
	store.vtab_modules[strings.to_lower(name, runtime.heap_allocator())] = module
	return ERROR_NONE
}

// store_unregister_vtab_module drops a module, disconnecting the tables it
// serves, and reports whether it was there.
store_unregister_vtab_module :: proc(store: ^Store, name: string) -> bool {
	if store == nil || store.vtab_modules == nil do return false
	for key, module in store.vtab_modules {
		if !strings.equal_fold(key, name) do continue
		for i := len(store.vtabs) - 1; i >= 0; i -= 1 {
			vtab := store.vtabs[i]
			if !strings.equal_fold(vtab.module, key) do continue
			if module.disconnect != nil do error_drop(module.disconnect(module.ctx, vtab.handle, false))
			vtab_free(vtab)
			vtab_list_remove(&store.vtabs, i)
		}
		delete_key(&store.vtab_modules, key)
		delete(key, runtime.heap_allocator())
		if module.release != nil do module.release(module.ctx)
		return true
	}
	return false
}

// store_vtab_names lists the registered modules.
store_vtab_names :: proc(store: ^Store, allocator := context.allocator) -> []string {
	names := make([dynamic]string, 0, len(store.vtab_modules), allocator)
	for key, _ in store.vtab_modules do append(&names, key)
	return names[:]
}

// store_vtab_close disconnects every table and releases every module.
store_vtab_close :: proc(store: ^Store) {
	if store == nil do return
	for store.vtab_modules != nil && len(store.vtab_modules) > 0 {
		for key, _ in store.vtab_modules {
			store_unregister_vtab_module(store, key)
			break
		}
	}
	delete(store.vtab_modules)
	store.vtab_modules = nil
	delete(store.vtabs)
	store.vtabs = nil
}

@(private)
vtab_module :: proc(store: ^Store, name: string) -> (Vtab_Module, string, bool) {
	if store == nil || store.vtab_modules == nil do return {}, "", false
	for key, module in store.vtab_modules {
		if strings.equal_fold(key, name) do return module, key, true
	}
	return {}, "", false
}

@(private)
vtab_free :: proc(vtab: ^Vtab) {
	alloc := runtime.heap_allocator()
	for column in vtab.columns do delete(column.name, alloc)
	delete(vtab.columns, alloc)
	delete(vtab.name, alloc)
	delete(vtab.module, alloc)
	free(vtab, alloc)
}

// vtab_catalog_entry reads the module and arguments CREATE VIRTUAL TABLE
// recorded for `name`, for a module the engine does not implement itself.
@(private)
vtab_catalog_entry :: proc(tx: ^Tx, name: string) -> (module: string, args: []string, found: bool) {
	entry, is_virtual := fts_virtual_lookup(tx, name)
	if !is_virtual || fts_is_full_text(entry) || fts_is_spatial(entry) do return "", nil, false
	args = strings.split(entry.settings, "\x1f", tx.alloc)
	if len(entry.settings) == 0 do args = nil
	return entry.module, args, true
}

// vtab_find answers the connected table `name`, connecting it the first time
// a statement names it.
vtab_find :: proc(tx: ^Tx, name: string) -> (^Vtab, bool, Error) {
	store := tx.store
	if store == nil || store.vtab_modules == nil || len(store.vtab_modules) == 0 do return nil, false, ERROR_NONE
	for vtab in store.vtabs {
		if strings.equal_fold(vtab.name, name) do return vtab, true, ERROR_NONE
	}
	module_name, args, recorded := vtab_catalog_entry(tx, name)
	if !recorded {
		// An eponymous module is a table under its own name.
		module, key, registered := vtab_module(store, name)
		if !registered || !module.eponymous do return nil, false, ERROR_NONE
		vtab, err := vtab_connect(store, module, key, name, nil, false)
		return vtab, err.kind == .None, err
	}
	module, key, registered := vtab_module(store, module_name)
	if !registered do return nil, false, errf(.Sql_Unsupported, "no such module: %s", module_name)
	vtab, err := vtab_connect(store, module, key, name, args, false)
	return vtab, err.kind == .None, err
}

@(private)
vtab_connect :: proc(store: ^Store, module: Vtab_Module, module_name: string, name: string, args: []string, create: bool) -> (^Vtab, Error) {
	handle, declaration, err := module.connect(module.ctx, create, name, args)
	if err.kind != .None do return nil, err
	columns, parse_err := vtab_parse_declaration(declaration)
	delete(declaration)
	if parse_err.kind != .None {
		if module.disconnect != nil do error_drop(module.disconnect(module.ctx, handle, create))
		return nil, parse_err
	}
	alloc := runtime.heap_allocator()
	vtab := new(Vtab, alloc)
	vtab^ = Vtab {
		name    = strings.clone(name, alloc),
		module  = strings.clone(module_name, alloc),
		handle  = handle,
		columns = columns,
	}
	if store.vtabs == nil do store.vtabs = make([dynamic]^Vtab, 0, 4, alloc)
	append(&store.vtabs, vtab)
	return vtab, ERROR_NONE
}

// vtab_parse_declaration reads the CREATE TABLE a module declared: each
// column's name and whether its type says HIDDEN. Types are kept loose (any
// value), as a module answers what it answers.
vtab_parse_declaration :: proc(declaration: string) -> ([]Column, Error) {
	alloc := runtime.heap_allocator()
	open := strings.index_byte(declaration, '(')
	close := strings.last_index_byte(declaration, ')')
	if len(declaration) == 0 || open < 0 || close <= open {
		return nil, errf(.Sql_Syntax, "a virtual table declares its columns with CREATE TABLE x(...)")
	}
	body := declaration[open + 1:close]
	columns := make([dynamic]Column, 0, 4, alloc)
	depth := 0
	start := 0
	for i := 0; i <= len(body); i += 1 {
		at_end := i == len(body)
		if !at_end {
			switch body[i] {
			case '(':
				depth += 1
				continue
			case ')':
				depth -= 1
				continue
			case ',':
				if depth > 0 do continue
			case:
				continue
			}
		}
		definition := strings.trim_space(body[start:i])
		start = i + 1
		if len(definition) == 0 do continue
		words := strings.fields(definition, context.temp_allocator)
		first := strings.to_lower(words[0], context.temp_allocator)
		// A table constraint (PRIMARY KEY (...), UNIQUE, CHECK) is not a column.
		if first == "primary" || first == "unique" || first == "check" || first == "constraint" || first == "foreign" do continue
		name := strings.trim(words[0], "\"`[]'")
		hidden := false
		for word in words[1:] do if strings.equal_fold(word, "hidden") do hidden = true
		append(&columns, Column{name = strings.clone(name, alloc), type = Column_Type{kind = .Any}, hidden = hidden})
	}
	if len(columns) == 0 do return nil, errf(.Sql_Syntax, "a virtual table needs at least one column")
	return columns[:], ERROR_NONE
}

// vtab_create runs CREATE VIRTUAL TABLE for a module the program registered.
// It answers false when the module is not one, so the engine's own modules
// (fts5, rtree) take the statement.
vtab_create :: proc(tx: ^Tx, stmt: Create_Virtual_Table_Stmt) -> (bool, Error) {
	module, key, registered := vtab_module(tx.store, stmt.module)
	if !registered do return false, ERROR_NONE
	if module.eponymous_only {
		return true, errf(.Sql_Unsupported, "no such module: %s", stmt.module)
	}
	if existing, found := fts_virtual_lookup(tx, stmt.name); found {
		if stmt.if_not_exists do return true, ERROR_NONE
		return true, errf(.Table_Exists, "table %s already exists", existing.name)
	}
	if tx_table_probe(tx, stmt.name) != nil {
		if stmt.if_not_exists do return true, ERROR_NONE
		return true, errf(.Table_Exists, "table %s already exists", stmt.name)
	}
	if err := fts_ensure(tx); err.kind != .None do return true, err
	if _, err := vtab_connect(tx.store, module, key, stmt.name, stmt.arguments, true); err.kind != .None {
		return true, err
	}
	values := []Value {
		value_string(strings.clone(stmt.name, tx.alloc)),
		value_string(strings.clone(stmt.module, tx.alloc)),
		value_string(strings.join(stmt.arguments, "\x1f", tx.alloc)),
	}
	_, insert_err := tx_insert(tx, VIRTUAL_TABLE, values)
	return true, insert_err
}

// vtab_drop runs DROP TABLE for a module's table: the module destroys it.
vtab_drop :: proc(tx: ^Tx, name: string) -> (bool, Error) {
	if _, _, recorded := vtab_catalog_entry(tx, name); !recorded do return false, ERROR_NONE
	vtab, found, find_err := vtab_find(tx, name)
	if find_err.kind != .None do return true, find_err
	if found {
		module, _, _ := vtab_module(tx.store, vtab.module)
		if module.disconnect != nil {
			if err := module.disconnect(module.ctx, vtab.handle, true); err.kind != .None do return true, err
		}
		for candidate, i in tx.store.vtabs {
			if candidate != vtab do continue
			vtab_list_remove(&tx.store.vtabs, i)
			break
		}
		vtab_free(vtab)
	}
	drop_row := strings.concatenate({"DELETE FROM ", VIRTUAL_TABLE, " WHERE name = ?"}, tx.alloc)
	return true, fts_run(tx, drop_row, []Value{value_string(strings.clone(name, tx.alloc))})
}

// vtab_materialize asks the module for its rows and keeps them in a temporary
// table for the statement. Arguments bind the HIDDEN columns, in order.
vtab_materialize :: proc(tx: ^Tx, vtab: ^Vtab, args: []Value) -> (^Table, Error) {
	module, _, registered := vtab_module(tx.store, vtab.module)
	if !registered do return nil, errf(.Sql_Unsupported, "no such module: %s", vtab.module)
	constraints := make([dynamic]Vtab_Constraint, 0, len(args), tx.alloc)
	next := 0
	for column, i in vtab.columns {
		if next >= len(args) do break
		if !column.hidden do continue
		append(&constraints, Vtab_Constraint{column = i, op = VTAB_OP_EQ, usable = true})
		next += 1
	}
	if next < len(args) {
		return nil, errf(.Invalid_Argument, "too many arguments on %s - max %d", vtab.name, next)
	}
	// Then the query's terms on its columns against a constant, as SQLite
	// offers them. The executor applies the WHERE to the rows anyway, so a
	// module that ignores them answers the same.
	offered := make([dynamic]Value, 0, len(args) + 4, tx.alloc)
	append(&offered, ..args)
	vtab_where_terms(tx, vtab, &constraints, &offered)
	rows := make([dynamic]Vtab_Row, 0, 16, tx.alloc)
	if err := module.scan(module.ctx, vtab.handle, constraints[:], offered[:], len(vtab.columns), &rows); err.kind != .None {
		return nil, err
	}
	columns := make([]Column, len(vtab.columns) + 1, tx.alloc)
	for column, i in vtab.columns do columns[i] = Column{name = column.name, type = column.type, hidden = column.hidden}
	key := len(vtab.columns)
	columns[key] = Column{name = VTAB_ROWID_COLUMN, type = Column_Type{kind = .Int, width = 8}, hidden = true}
	schema := Table_Schema{name = vtab.name, columns = columns, primary_key = []int{key}, ephemeral = true}
	table, table_err := table_create(&schema)
	if table_err.kind != .None do return nil, table_err
	values := make([]Value, len(columns), tx.alloc)
	for row, i in rows {
		for column in 0 ..< len(vtab.columns) {
			values[column] = column < len(row.values) ? row.values[column] : value_null()
		}
		values[key] = value_int(row.rowid)
		if err := table_insert(table, Row_Id(i + 1), values, true); err.kind != .None {
			table_destroy(table)
			return nil, err
		}
	}
	append(&tx.temp_tables, table)
	return table, ERROR_NONE
}

// vtab_write runs an INSERT, UPDATE or DELETE on a module's table through its
// update, with SQLite's arguments: [old rowid or NULL, new rowid or NULL,
// every declared column].
vtab_write :: proc(tx: ^Tx, vtab: ^Vtab, statement: Statement, params: []Value) -> (Sql_Result, Error) {
	module, _, _ := vtab_module(tx.store, vtab.module)
	if module.update == nil do return {}, errf(.Sql_Unsupported, "table %s may not be modified", vtab.name)
	affected := 0
	width := len(vtab.columns)
	argv := make([]Value, width + 2, tx.alloc)
	#partial switch s in statement {
	case Insert_Stmt:
		if s.returning != nil do return {}, errf(.Sql_Unsupported, "RETURNING is not supported on a virtual table")
		// Without a column list the visible columns take the values, in order.
		targets := make([dynamic]int, 0, width, tx.alloc)
		rowid_target := -1
		if len(s.columns) > 0 {
			for name, i in s.columns {
				found := -1
				for column, index in vtab.columns do if strings.equal_fold(column.name, name) do found = index
				if found < 0 && rowid_alias_name(name) {
					rowid_target = i
					append(&targets, -1)
					continue
				}
				if found < 0 do return {}, errf(.Column_Not_Found, "table %s has no column named %s", vtab.name, name)
				append(&targets, found)
			}
		} else {
			for column, index in vtab.columns do if !column.hidden do append(&targets, index)
		}
		rows: [][]Value
		selected: Sql_Result
		defer sql_result_destroy(&selected)
		if s.has_select {
			select_err: Error
			selected, select_err = sql_exec_select(tx, s.select_stmt, params)
			if select_err.kind != .None do return {}, select_err
			rows = selected.rows
		} else {
			evaluated := make([][]Value, len(s.rows), tx.alloc)
			ctx := Eval_Ctx{tx = tx, params = params, now_us = now_microseconds()}
			for row, i in s.rows {
				evaluated[i] = make([]Value, len(row), tx.alloc)
				for expr, j in row {
					value, eval_err := eval_expr(&ctx, expr)
					if eval_err.kind != .None do return {}, eval_err
					evaluated[i][j] = value
				}
			}
			rows = evaluated
		}
		for row in rows {
			if len(row) != len(targets) {
				return {}, errf(.Invalid_Argument, "%d values for %d columns", len(row), len(targets))
			}
			for &value in argv do value = value_null()
			for value, i in row {
				if i == rowid_target {
					argv[1] = value
				} else {
					argv[targets[i] + 2] = value
				}
			}
			rowid: i64
			if err := module.update(module.ctx, vtab.handle, argv, &rowid); err.kind != .None do return {}, err
			affected += 1
		}
	case Update_Stmt, Delete_Stmt:
		// The rows to change are read through the table as a query would read
		// them: the row id and, for an UPDATE, every column after assignment.
		select := Select_Stmt{from = Table_Ref{name = vtab.name}}
		items := make([dynamic]Select_Item, 0, width + 2, tx.alloc)
		rowid_expr := new(Expr, tx.alloc)
		rowid_expr^ = Column_Expr{name = VTAB_ROWID_COLUMN}
		append(&items, Select_Item{expr = rowid_expr})
		new_rowid := rowid_expr
		if update, is_update := s.(Update_Stmt); is_update {
			if update.returning != nil do return {}, errf(.Sql_Unsupported, "RETURNING is not supported on a virtual table")
			select.where_clause = update.where_clause
			for assignment in update.assignments {
				if rowid_alias_name(assignment.column) do new_rowid = assignment.value
			}
			append(&items, Select_Item{expr = new_rowid})
			for column in vtab.columns {
				value := new(Expr, tx.alloc)
				value^ = Column_Expr{name = column.name}
				for assignment in update.assignments {
					if strings.equal_fold(assignment.column, column.name) do value = assignment.value
				}
				append(&items, Select_Item{expr = value})
			}
		} else {
			delete_stmt := s.(Delete_Stmt)
			if delete_stmt.returning != nil do return {}, errf(.Sql_Unsupported, "RETURNING is not supported on a virtual table")
			select.where_clause = delete_stmt.where_clause
		}
		select.projections = items[:]
		result, select_err := sql_exec_select(tx, select, params)
		if select_err.kind != .None do return {}, select_err
		defer sql_result_destroy(&result)
		for row in result.rows {
			if _, is_update := s.(Update_Stmt); is_update {
				if err := module.update(module.ctx, vtab.handle, row[:], nil); err.kind != .None do return {}, err
			} else {
				if err := module.update(module.ctx, vtab.handle, row[:1], nil); err.kind != .None do return {}, err
			}
			affected += 1
		}
	}
	return Sql_Result{kind = .Ack, affected = affected, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

// vtab_list_remove takes one table out of the connected list, keeping order.
@(private)
vtab_list_remove :: proc(list: ^[dynamic]^Vtab, index: int) {
	copy(list[index:], list[index + 1:])
	resize(list, len(list) - 1)
}

// vtab_where_terms adds the WHERE terms `column op constant` (and the same
// with the constant first) that name a column of `vtab`, with SQLite's codes.
@(private)
vtab_where_terms :: proc(tx: ^Tx, vtab: ^Vtab, constraints: ^[dynamic]Vtab_Constraint, values: ^[dynamic]Value) {
	if tx.vtab_where == nil do return
	terms := make([dynamic]^Expr, 0, 4, tx.alloc)
	split_and(tx.vtab_where, &terms)
	for term in terms {
		binary, is_binary := term^.(Binary_Expr)
		if !is_binary || binary.left == nil || binary.right == nil do continue
		op: u8
		#partial switch binary.op {
		case .Eq:
			op = VTAB_OP_EQ
		case .Gt:
			op = 4
		case .Le:
			op = 8
		case .Lt:
			op = 16
		case .Ge:
			op = 32
		case:
			continue
		}
		column_side, constant_side := binary.left, binary.right
		if _, left_is_column := column_side^.(Column_Expr); !left_is_column {
			column_side, constant_side = binary.right, binary.left
			// `5 > x` is `x < 5`.
			switch op {
			case 4:
				op = 16
			case 16:
				op = 4
			case 8:
				op = 32
			case 32:
				op = 8
			}
		}
		column, is_column := column_side^.(Column_Expr)
		if !is_column do continue
		if len(column.table) > 0 && !strings.equal_fold(column.table, vtab.name) do continue
		index := -1
		for candidate, i in vtab.columns do if strings.equal_fold(candidate.name, column.name) do index = i
		if index < 0 do continue
		constant: Value
		#partial switch c in constant_side^ {
		case Literal_Expr:
			constant = c.value
		case Param_Expr:
			if c.index < 0 || c.index >= len(tx.vtab_params) do continue
			constant = tx.vtab_params[c.index]
		case:
			continue
		}
		append(constraints, Vtab_Constraint{column = index, op = op, usable = true})
		append(values, constant)
	}
}
