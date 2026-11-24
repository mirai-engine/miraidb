package sqlite_compat

// Virtual table modules: sqlite3_create_module registers a sqlite3_module, and
// the engine's vtab.odin calls it through the adapter below. A table is read
// whole each time a statement names it: xBestIndex is offered the arguments
// written after the name (`FROM series(1, 10)`) as equality constraints on the
// HIDDEN columns, xFilter gets the ones it asked for, and the rows come from
// xOpen/xEof/xNext/xRowid/xColumn. A constraint the module did not mark
// `omit` is checked again on the rows, as SQLite does. Writes call xUpdate with
// SQLite's arguments. xBegin/xSync/xCommit/xRollback, savepoints, xRename and
// xFindFunction are not called.

import "core:c"
import "core:strings"

import engine "../engine"

Vtab_Constructor :: #type proc "c" (db: rawptr, aux: rawptr, argc: c.int, argv: [^]cstring, vtab: ^^Sqlite3_Vtab, err: ^cstring) -> c.int

Sqlite3_Module :: struct {
	iVersion:      c.int,
	xCreate:       Vtab_Constructor,
	xConnect:      Vtab_Constructor,
	xBestIndex:    proc "c" (vtab: ^Sqlite3_Vtab, info: ^Sqlite3_Index_Info) -> c.int,
	xDisconnect:   proc "c" (vtab: ^Sqlite3_Vtab) -> c.int,
	xDestroy:      proc "c" (vtab: ^Sqlite3_Vtab) -> c.int,
	xOpen:         proc "c" (vtab: ^Sqlite3_Vtab, cursor: ^^Sqlite3_Vtab_Cursor) -> c.int,
	xClose:        proc "c" (cursor: ^Sqlite3_Vtab_Cursor) -> c.int,
	xFilter:       proc "c" (cursor: ^Sqlite3_Vtab_Cursor, idx_num: c.int, idx_str: cstring, argc: c.int, argv: [^]rawptr) -> c.int,
	xNext:         proc "c" (cursor: ^Sqlite3_Vtab_Cursor) -> c.int,
	xEof:          proc "c" (cursor: ^Sqlite3_Vtab_Cursor) -> c.int,
	xColumn:       proc "c" (cursor: ^Sqlite3_Vtab_Cursor, ctx: rawptr, column: c.int) -> c.int,
	xRowid:        proc "c" (cursor: ^Sqlite3_Vtab_Cursor, rowid: ^i64) -> c.int,
	xUpdate:       proc "c" (vtab: ^Sqlite3_Vtab, argc: c.int, argv: [^]rawptr, rowid: ^i64) -> c.int,
	xBegin:        proc "c" (vtab: ^Sqlite3_Vtab) -> c.int,
	xSync:         proc "c" (vtab: ^Sqlite3_Vtab) -> c.int,
	xCommit:       proc "c" (vtab: ^Sqlite3_Vtab) -> c.int,
	xRollback:     proc "c" (vtab: ^Sqlite3_Vtab) -> c.int,
	xFindFunction: proc "c" (vtab: ^Sqlite3_Vtab, argc: c.int, name: cstring, func: ^Function_Callback, arg: ^rawptr) -> c.int,
	xRename:       proc "c" (vtab: ^Sqlite3_Vtab, new_name: cstring) -> c.int,
	xSavepoint:    proc "c" (vtab: ^Sqlite3_Vtab, level: c.int) -> c.int,
	xRelease:      proc "c" (vtab: ^Sqlite3_Vtab, level: c.int) -> c.int,
	xRollbackTo:   proc "c" (vtab: ^Sqlite3_Vtab, level: c.int) -> c.int,
	xShadowName:   rawptr,
	xIntegrity:    rawptr,
}

Sqlite3_Vtab :: struct {
	pModule: ^Sqlite3_Module,
	nRef:    c.int,
	zErrMsg: cstring,
}

Sqlite3_Vtab_Cursor :: struct {
	pVtab: ^Sqlite3_Vtab,
}

Sqlite3_Index_Constraint :: struct {
	iColumn:     c.int,
	op:          u8,
	usable:      u8,
	iTermOffset: c.int,
}

Sqlite3_Index_Orderby :: struct {
	iColumn: c.int,
	desc:    u8,
}

Sqlite3_Index_Constraint_Usage :: struct {
	argvIndex: c.int,
	omit:      u8,
}

Sqlite3_Index_Info :: struct {
	nConstraint:      c.int,
	aConstraint:      [^]Sqlite3_Index_Constraint,
	nOrderBy:         c.int,
	aOrderBy:         [^]Sqlite3_Index_Orderby,
	aConstraintUsage: [^]Sqlite3_Index_Constraint_Usage,
	idxNum:           c.int,
	idxStr:           cstring,
	needToFreeIdxStr: c.int,
	orderByConsumed:  c.int,
	estimatedCost:    f64,
	estimatedRows:    i64,
	idxFlags:         c.int,
	colUsed:          u64,
}

SQLITE_NOTFOUND :: c.int(12)
SQLITE_CONSTRAINT_VTAB :: c.int(19)
SQLITE_ABORT_CONFLICT :: c.int(4)

// Module_Entry is one module registered on one connection.
Module_Entry :: struct {
	db:      ^Database,
	name:    string,
	module:  ^Sqlite3_Module,
	aux:     rawptr,
	destroy: Destroy_Callback,
	// overloads are the functions xFindFunction answered, kept so each call
	// does not make a new one.
	overloads: [dynamic]^Function,
}

// index_values are the right-hand values of the constraints of the xBestIndex
// call running on this thread, for sqlite3_vtab_rhs_value.
@(private, thread_local)
index_values: []engine.Value

// index_collations are the constraints' collations for the same call, for
// sqlite3_vtab_collation.
@(private, thread_local)
index_collations: []engine.Vtab_Constraint

@(private)
vtab_error :: proc(vtab: ^Sqlite3_Vtab, code: c.int, fallback: string) -> engine.Error {
	message := fallback
	if vtab != nil && vtab.zErrMsg != nil {
		message = strings.clone(string(vtab.zErrMsg), context.temp_allocator)
		sqlite3_free(rawptr(vtab.zErrMsg))
		vtab.zErrMsg = nil
	}
	return engine.errf(code == SQLITE_CONSTRAINT ? .Check_Violation : .Invalid_Argument, "%s", message)
}

@(private)
module_connect :: proc(ctx: rawptr, create: bool, table: string, args: []string) -> (rawptr, string, engine.Error) {
	entry := (^Module_Entry)(ctx)
	db := entry.db
	constructor := create && entry.module.xCreate != nil ? entry.module.xCreate : entry.module.xConnect
	if constructor == nil do return nil, "", engine.errf(.Sql_Unsupported, "no such module: %s", entry.name)
	argv := make([]cstring, len(args) + 3, context.temp_allocator)
	argv[0] = strings.clone_to_cstring(entry.name, context.temp_allocator)
	argv[1] = "main"
	argv[2] = strings.clone_to_cstring(table, context.temp_allocator)
	for arg, i in args do argv[i + 3] = strings.clone_to_cstring(arg, context.temp_allocator)
	delete(db.pending_declaration)
	db.pending_declaration = ""
	vtab: ^Sqlite3_Vtab
	message: cstring
	db.in_vtab_constructor = true
	code := constructor(rawptr(db), entry.aux, c.int(len(argv)), raw_data(argv), &vtab, &message)
	db.in_vtab_constructor = false
	if code != SQLITE_OK || vtab == nil {
		text := "vtable constructor failed"
		if message != nil do text = strings.clone(string(message), context.temp_allocator)
		if message != nil do sqlite3_free(rawptr(message))
		return nil, "", engine.errf(.Invalid_Argument, "%s", text)
	}
	if len(db.pending_declaration) == 0 {
		if entry.module.xDisconnect != nil do entry.module.xDisconnect(vtab)
		return nil, "", engine.errf(.Invalid_Argument, "vtable constructor did not declare schema: %s", table)
	}
	vtab.pModule = entry.module
	declaration := db.pending_declaration
	db.pending_declaration = ""
	return rawptr(vtab), declaration, engine.ERROR_NONE
}

@(private)
module_disconnect :: proc(ctx: rawptr, handle: rawptr, destroy: bool) -> engine.Error {
	entry := (^Module_Entry)(ctx)
	vtab := (^Sqlite3_Vtab)(handle)
	method := destroy && entry.module.xDestroy != nil ? entry.module.xDestroy : entry.module.xDisconnect
	if method == nil do return engine.ERROR_NONE
	if code := method(vtab); code != SQLITE_OK do return vtab_error(vtab, code, "vtable destructor failed")
	return engine.ERROR_NONE
}

// boxes makes sqlite3_value handles for `values`; the caller frees the boxes'
// text forms with boxes_release.
@(private)
boxes_of :: proc(values: []engine.Value) -> ([]Value_Box, []rawptr) {
	boxes := make([]Value_Box, len(values), context.temp_allocator)
	handles := make([]rawptr, len(values), context.temp_allocator)
	for value, i in values {
		boxes[i] = Value_Box{value = value}
		handles[i] = rawptr(&boxes[i])
	}
	return boxes, handles
}

@(private)
boxes_release :: proc(boxes: []Value_Box) {
	for box in boxes {
		delete(box.text)
		delete(box.text16)
	}
}

@(private)
module_scan :: proc(
	ctx: rawptr,
	handle: rawptr,
	constraints: []engine.Vtab_Constraint,
	values: []engine.Value,
	order: []engine.Vtab_Order,
	columns: int,
	rows: ^[dynamic]engine.Vtab_Row,
) -> engine.Error {
	entry := (^Module_Entry)(ctx)
	module := entry.module
	vtab := (^Sqlite3_Vtab)(handle)
	if module.xBestIndex == nil || module.xOpen == nil || module.xFilter == nil || module.xEof == nil || module.xNext == nil || module.xColumn == nil {
		return engine.errf(.Sql_Unsupported, "module %s cannot be read", entry.name)
	}
	n := len(constraints)
	offered := make([]Sqlite3_Index_Constraint, max(n, 1), context.temp_allocator)
	usage := make([]Sqlite3_Index_Constraint_Usage, max(n, 1), context.temp_allocator)
	for constraint, i in constraints {
		offered[i] = Sqlite3_Index_Constraint {
			iColumn = c.int(constraint.column),
			op      = constraint.op,
			usable  = constraint.usable ? 1 : 0,
		}
	}
	orders := make([]Sqlite3_Index_Orderby, max(len(order), 1), context.temp_allocator)
	for term, i in order do orders[i] = Sqlite3_Index_Orderby{iColumn = c.int(term.column), desc = term.descending ? 1 : 0}
	info := Sqlite3_Index_Info {
		nConstraint      = c.int(n),
		aConstraint      = raw_data(offered),
		nOrderBy         = c.int(len(order)),
		aOrderBy         = raw_data(orders),
		aConstraintUsage = raw_data(usage),
		estimatedCost    = 5e98,
		estimatedRows    = 25,
		colUsed          = max(u64),
	}
	index_values = values
	index_collations = constraints
	code := module.xBestIndex(vtab, &info)
	index_values = nil
	index_collations = nil
	if code != SQLITE_OK {
		if code == SQLITE_CONSTRAINT do return engine.errf(.Invalid_Argument, "no query solution")
		return vtab_error(vtab, code, "xBestIndex failed")
	}
	defer if info.needToFreeIdxStr != 0 && info.idxStr != nil do sqlite3_free(rawptr(info.idxStr))

	// The values xFilter receives, in the order xBestIndex numbered them.
	count := 0
	for i in 0 ..< n do count = max(count, int(usage[i].argvIndex))
	arguments := make([]engine.Value, count, context.temp_allocator)
	for i in 0 ..< n {
		if index := int(usage[i].argvIndex); index > 0 do arguments[index - 1] = values[i]
	}
	cursor: ^Sqlite3_Vtab_Cursor
	if code = module.xOpen(vtab, &cursor); code != SQLITE_OK || cursor == nil {
		return vtab_error(vtab, code, "xOpen failed")
	}
	cursor.pVtab = vtab
	defer if module.xClose != nil do module.xClose(cursor)
	boxes, handles := boxes_of(arguments)
	code = module.xFilter(cursor, info.idxNum, info.idxStr, c.int(count), raw_data(handles))
	boxes_release(boxes)
	if code != SQLITE_OK do return vtab_error(vtab, code, "xFilter failed")
	for module.xEof(cursor) == 0 {
		row := engine.Vtab_Row{values = make([]engine.Value, columns, rows.allocator)}
		if module.xRowid != nil {
			if code = module.xRowid(cursor, &row.rowid); code != SQLITE_OK do return vtab_error(vtab, code, "xRowid failed")
		}
		for column in 0 ..< columns {
			call := Context{}
			code = module.xColumn(cursor, rawptr(&call), c.int(column))
			if call.has_error || code != SQLITE_OK {
				message := len(call.error_message) > 0 ? strings.clone(call.error_message, context.temp_allocator) : "xColumn failed"
				context_release(&call)
				engine.value_deep_free(call.result, context.allocator)
				if !call.has_error do return vtab_error(vtab, code, message)
				return engine.errf(.Invalid_Argument, "%s", message)
			}
			row.values[column] = engine.value_clone(call.result, rows.allocator)
			engine.value_deep_free(call.result, context.allocator)
			context_release(&call)
		}
		// A constraint the module did not take on is checked here.
		keep := true
		for constraint, i in constraints {
			if usage[i].omit != 0 || constraint.column < 0 || constraint.column >= columns do continue
			order, ok := engine.value_compare(row.values[constraint.column], values[i])
			if !ok || order != .Equal do keep = false
		}
		if keep do append(rows, row)
		if code = module.xNext(cursor); code != SQLITE_OK do return vtab_error(vtab, code, "xNext failed")
	}
	return engine.ERROR_NONE
}

@(private)
module_update :: proc(ctx: rawptr, handle: rawptr, argv: []engine.Value, rowid: ^i64) -> engine.Error {
	entry := (^Module_Entry)(ctx)
	vtab := (^Sqlite3_Vtab)(handle)
	boxes, handles := boxes_of(argv)
	defer boxes_release(boxes)
	out: i64
	code := entry.module.xUpdate(vtab, c.int(len(argv)), raw_data(handles), &out)
	if code != SQLITE_OK do return vtab_error(vtab, code, "xUpdate failed")
	if rowid != nil do rowid^ = out
	return engine.ERROR_NONE
}

@(private)
module_release :: proc(ctx: rawptr) {
	entry := (^Module_Entry)(ctx)
	if entry.destroy != nil do entry.destroy(entry.aux)
	for overload in entry.overloads {
		delete(overload.name)
		free(overload)
	}
	delete(entry.overloads)
	delete(entry.name)
	free(entry)
}

// module_transaction calls the transaction method of a step; savepoints need
// a module of version 2 or later, as in SQLite.
@(private)
module_transaction :: proc(ctx: rawptr, handle: rawptr, step: engine.Vtab_Tx_Step, level: int) -> engine.Error {
	entry := (^Module_Entry)(ctx)
	module := entry.module
	vtab := (^Sqlite3_Vtab)(handle)
	code := SQLITE_OK
	switch step {
	case .Begin:
		if module.xBegin != nil do code = module.xBegin(vtab)
	case .Sync:
		if module.xSync != nil do code = module.xSync(vtab)
	case .Commit:
		if module.xCommit != nil do code = module.xCommit(vtab)
	case .Rollback:
		if module.xRollback != nil do code = module.xRollback(vtab)
	case .Savepoint:
		if module.iVersion >= 2 && module.xSavepoint != nil do code = module.xSavepoint(vtab, c.int(level))
	case .Release:
		if module.iVersion >= 2 && module.xRelease != nil do code = module.xRelease(vtab, c.int(level))
	case .Rollback_To:
		if module.iVersion >= 2 && module.xRollbackTo != nil do code = module.xRollbackTo(vtab, c.int(level))
	}
	if code != SQLITE_OK do return vtab_error(vtab, code, "virtual table transaction failed")
	return engine.ERROR_NONE
}

@(private)
module_rename :: proc(ctx: rawptr, handle: rawptr, new_name: string) -> engine.Error {
	entry := (^Module_Entry)(ctx)
	vtab := (^Sqlite3_Vtab)(handle)
	name := strings.clone_to_cstring(new_name, context.temp_allocator)
	if code := entry.module.xRename(vtab, name); code != SQLITE_OK do return vtab_error(vtab, code, "xRename failed")
	return engine.ERROR_NONE
}

// module_find_function asks xFindFunction about a call; an answer becomes a
// function the engine calls like any registered one.
@(private)
module_find_function :: proc(ctx: rawptr, handle: rawptr, name: string, arity: int) -> (engine.Scalar_Function, rawptr, bool) {
	entry := (^Module_Entry)(ctx)
	vtab := (^Sqlite3_Vtab)(handle)
	func: Function_Callback
	arg: rawptr
	text := strings.clone_to_cstring(name, context.temp_allocator)
	if entry.module.xFindFunction(vtab, c.int(arity), text, &func, &arg) == 0 || func == nil do return nil, nil, false
	for overload in entry.overloads {
		if overload.func == func && overload.user == arg && overload.arity == arity && strings.equal_fold(overload.name, name) {
			return facade_scalar, rawptr(overload), true
		}
	}
	overload := new(Function)
	overload^ = Function{db = entry.db, name = strings.clone(name), arity = arity, user = arg, func = func}
	append(&entry.overloads, overload)
	return facade_scalar, rawptr(overload), true
}

@(private)
create_module :: proc(handle: rawptr, name: cstring, module: ^Sqlite3_Module, aux: rawptr, destroy: Destroy_Callback) -> c.int {
	db := db_of(handle)
	if db == nil || name == nil {
		if destroy != nil do destroy(aux)
		return SQLITE_MISUSE
	}
	if module == nil {
		// A NULL module drops the name.
		engine.store_unregister_vtab_module(db.conn.store, string(name))
		if destroy != nil do destroy(aux)
		return SQLITE_OK
	}
	entry := new(Module_Entry)
	entry^ = Module_Entry{db = db, name = strings.clone(string(name)), module = module, aux = aux, destroy = destroy}
	registration := engine.Vtab_Module {
		ctx            = rawptr(entry),
		eponymous      = module.xCreate == nil || module.xCreate == module.xConnect,
		eponymous_only = module.xCreate == nil,
		connect        = module_connect,
		disconnect     = module_disconnect,
		scan           = module_scan,
		release        = module_release,
	}
	if module.xUpdate != nil do registration.update = module_update
	if module.xBegin != nil || module.xSync != nil || module.xCommit != nil || module.xRollback != nil || (module.iVersion >= 2 && (module.xSavepoint != nil || module.xRelease != nil || module.xRollbackTo != nil)) {
		registration.transaction = module_transaction
	}
	if module.xRename != nil do registration.rename = module_rename
	if module.xFindFunction != nil do registration.find_function = module_find_function
	if err := engine.store_register_vtab_module(db.conn.store, string(name), registration); err.kind != .None {
		engine.error_free(&err)
		module_release(rawptr(entry))
		return SQLITE_ERROR
	}
	return SQLITE_OK
}

@(export)
sqlite3_create_module :: proc "c" (handle: rawptr, name: cstring, module: ^Sqlite3_Module, aux: rawptr) -> c.int {
	context = engine.oom_context()
	return create_module(handle, name, module, aux, nil)
}

@(export)
sqlite3_create_module_v2 :: proc "c" (handle: rawptr, name: cstring, module: ^Sqlite3_Module, aux: rawptr, destroy: Destroy_Callback) -> c.int {
	context = engine.oom_context()
	return create_module(handle, name, module, aux, destroy)
}

// sqlite3_drop_modules drops every module whose name is not in the
// NULL-terminated list `keep` (all of them when it is NULL).
@(export)
sqlite3_drop_modules :: proc "c" (handle: rawptr, keep: [^]cstring) -> c.int {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil do return SQLITE_MISUSE
	names := engine.store_vtab_names(db.conn.store, context.temp_allocator)
	outer: for name in names {
		if keep != nil {
			for i := 0; keep[i] != nil; i += 1 {
				if strings.equal_fold(string(keep[i]), name) do continue outer
			}
		}
		engine.store_unregister_vtab_module(db.conn.store, name)
	}
	return SQLITE_OK
}

// sqlite3_declare_vtab is called by xCreate or xConnect with the table's
// columns, as a CREATE TABLE statement.
@(export)
sqlite3_declare_vtab :: proc "c" (handle: rawptr, sql: cstring) -> c.int {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil || sql == nil do return SQLITE_MISUSE
	text := strings.trim_space(string(sql))
	if !strings.has_prefix(strings.to_upper(text, context.temp_allocator), "CREATE TABLE") {
		return set_error_code(db, SQLITE_ERROR, "vtable declaration is not a CREATE TABLE")
	}
	if _, err := engine.vtab_parse_declaration(text); err.kind != .None {
		message := strings.clone(err.message, context.temp_allocator)
		engine.error_free(&err)
		return set_error_code(db, SQLITE_ERROR, message)
	}
	delete(db.pending_declaration)
	db.pending_declaration = strings.clone(text)
	return SQLITE_OK
}

// sqlite3_vtab_config accepts SQLite's options from inside xCreate or
// xConnect, as SQLite does; none changes how a table is read here.
@(export)
sqlite3_vtab_config :: proc "c" (handle: rawptr, op: c.int) -> c.int {
	context = engine.oom_context()
	db := db_of(handle)
	if db == nil || !db.in_vtab_constructor do return SQLITE_MISUSE
	if op < 1 || op > 4 do return SQLITE_MISUSE
	return SQLITE_OK
}

// sqlite3_vtab_on_conflict is the statement's conflict mode: ABORT, the
// default, is the only one a module write sees here.
@(export)
sqlite3_vtab_on_conflict :: proc "c" (handle: rawptr) -> c.int {
	return SQLITE_ABORT_CONFLICT
}

@(export)
sqlite3_vtab_nochange :: proc "c" (ctx: rawptr) -> c.int {
	return 0
}

// sqlite3_vtab_collation names the comparison a constraint asks for while
// xBestIndex runs: the term's COLLATE, else the column's, else BINARY.
@(export)
sqlite3_vtab_collation :: proc "c" (info: ^Sqlite3_Index_Info, constraint: c.int) -> cstring {
	context = engine.oom_context()
	if constraint < 0 || int(constraint) >= len(index_collations) do return "BINARY"
	name := index_collations[constraint].collation
	if len(name) == 0 do return "BINARY"
	return strings.clone_to_cstring(name, context.temp_allocator)
}

@(export)
sqlite3_vtab_distinct :: proc "c" (info: ^Sqlite3_Index_Info) -> c.int {
	return 0
}

@(export)
sqlite3_vtab_in :: proc "c" (info: ^Sqlite3_Index_Info, constraint: c.int, handle: c.int) -> c.int {
	return 0
}

@(export)
sqlite3_vtab_in_first :: proc "c" (value: rawptr, out: ^rawptr) -> c.int {
	if out != nil do out^ = nil
	return SQLITE_ERROR
}

@(export)
sqlite3_vtab_in_next :: proc "c" (value: rawptr, out: ^rawptr) -> c.int {
	if out != nil do out^ = nil
	return SQLITE_ERROR
}

// sqlite3_vtab_rhs_value answers the value of an argument constraint while
// xBestIndex runs; the box lives until the scan ends.
@(export)
sqlite3_vtab_rhs_value :: proc "c" (info: ^Sqlite3_Index_Info, constraint: c.int, out: ^rawptr) -> c.int {
	context = engine.oom_context()
	if out != nil do out^ = nil
	if info == nil || out == nil || constraint < 0 || constraint >= info.nConstraint do return SQLITE_MISUSE
	if int(constraint) >= len(index_values) do return SQLITE_NOTFOUND
	box := new(Value_Box, context.temp_allocator)
	box^ = Value_Box{value = index_values[constraint]}
	out^ = rawptr(box)
	return SQLITE_OK
}
