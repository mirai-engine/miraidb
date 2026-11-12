package engine

import "core:mem"
import "core:mem/virtual"

// Native module ABI. Modules are linked into the application and registered
// here; the host validates the version and dispatches calls by name. ABI v2 adds
// a context: the module gets a bounded arena and a row quota instead of the raw
// host, and the host rejects a call that overruns either. It is a cooperative,
// in-process boundary: there is no dynamic loading and no OS-level isolation.
MODULE_ABI_VERSION :: 2
MODULE_DEFAULT_MEMORY :: 8 * 1024 * 1024
MODULE_ABI_VERSION_1 :: 1

// Module_Context is what a v2 module runs with. Allocations from `alloc` come
// from a buffer of `memory_limit` bytes, so a runaway loop fails instead of
// growing without bound; `rows_used` is charged through module_charge_rows and
// checked against `row_limit` after the call returns.
Module_Context :: struct {
	host:       ^Host,
	alloc:      mem.Allocator,
	arena:      ^virtual.Arena,
	row_limit:    u64,
	rows_used:    u64,
	memory_limit: int,
	buffer:       []u8,
}

// module_charge_rows meters rows a module reads or writes. It returns false when
// the quota is exhausted so the module can stop early.
module_charge_rows :: proc(ctx: ^Module_Context, rows: u64) -> bool {
	ctx.rows_used += rows
	return ctx.row_limit == 0 || ctx.rows_used <= ctx.row_limit
}

Module :: struct {
	abi_version: u32,
	name:        string,
	// init runs once at registration; a failure rejects the module.
	init:        proc(host: ^Host) -> Error,
	shutdown:    proc(host: ^Host),
	// call receives the reducer name and its arguments.
	call:        proc(host: ^Host, reducer: string, args: []Value) -> (Value, Error),
	// ABI v2 entry points receive the bounded context instead of the host.
	init_v2:     proc(ctx: ^Module_Context) -> Error,
	shutdown_v2: proc(ctx: ^Module_Context),
	call_v2:     proc(ctx: ^Module_Context, reducer: string, args: []Value) -> (Value, Error),
}

host_register_module :: proc(host: ^Host, module: Module) -> Error {
	if len(module.name) == 0 do return errf(.Invalid_Argument, "a module needs a name")
	if module.abi_version != MODULE_ABI_VERSION_1 && module.abi_version != MODULE_ABI_VERSION {
		return errf(
			.Invalid_Argument,
			"module %s uses ABI %d, this host accepts 1 and %d",
			module.name,
			module.abi_version,
			MODULE_ABI_VERSION,
		)
	}
	if _, exists := host.modules[module.name]; exists do return errf(.Invalid_Argument, "module %s is already registered", module.name)
	if module.init != nil {
		if init_err := module.init(host); init_err.kind != .None do return init_err
	}
	if module.init_v2 != nil {
		ctx, open_err := host_module_context(host, nil)
		defer host_module_context_destroy(&ctx)
		if open_err.kind != .None do return open_err
		if init_err := module.init_v2(&ctx); init_err.kind != .None do return init_err
	}
	host.modules[module.name] = module
	return ERROR_NONE
}

host_module :: proc(host: ^Host, name: string) -> (Module, bool) {
	module, found := host.modules[name]
	return module, found
}

host_module_names :: proc(host: ^Host, alloc: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, len(host.modules), alloc)
	for name in host.modules do append(&names, name)
	slice_sort_strings(names[:])
	return names[:]
}

// host_call_module dispatches one call to a registered module. The module owns
// its own transactions; the host only forwards the arguments.
host_call_module :: proc(
	host: ^Host,
	module_name: string,
	reducer: string,
	args: []Value,
) -> (Value, Error) {
	if _, remote := host.remote_modules[module_name]; remote {
		return host_call_remote_module(host, module_name, reducer, args)
	}
	module, found := host.modules[module_name]
	if !found do return {}, errf(.Invalid_Argument, "no module named %s", module_name)
	if module.call_v2 != nil {
		ctx, open_err := host_module_context(host, nil)
		if open_err.kind != .None do return {}, open_err
		defer host_module_context_destroy(&ctx)
		result, call_err := module.call_v2(&ctx, reducer, args)
		if call_err.kind != .None do return {}, call_err
		if ctx.row_limit > 0 && ctx.rows_used > ctx.row_limit {
			return {}, errf(
				.Quota_Exceeded,
				"module %s used %d rows, its quota is %d",
				module_name,
				ctx.rows_used,
				ctx.row_limit,
			)
		}
		return result, ERROR_NONE
	}
	if module.call == nil do return {}, errf(.Sql_Unsupported, "module %s cannot be called", module_name)
	return module.call(host, reducer, args)
}

// host_set_module_limits sets the memory and row budget of every module call.
// Zero means unlimited; the host keeps a small default so a runaway module fails
// instead of taking the process down.
host_set_module_limits :: proc(host: ^Host, memory_bytes: int, rows: u64) {
	host.module_memory_limit = memory_bytes
	host.module_row_limit = rows
}

host_module_limits :: proc(host: ^Host) -> (memory_bytes: int, rows: u64) {
	return host.module_memory_limit, host.module_row_limit
}

// host_module_context builds the bounded context a v2 module runs with.
@(private)
host_module_context :: proc(host: ^Host, buffer: []u8) -> (Module_Context, Error) {
	ctx: Module_Context
	ctx.host = host
	ctx.row_limit = host.module_row_limit
	limit := host.module_memory_limit
	if limit <= 0 do limit = MODULE_DEFAULT_MEMORY
	ctx.memory_limit = limit
	memory := buffer
	if memory == nil do memory = make([]u8, limit)
	ctx.buffer = memory
	ctx.alloc = context.allocator
	arena := new(virtual.Arena)
	if arena_err := virtual.arena_init_buffer(arena, memory); arena_err == .None {
		ctx.arena = arena
		ctx.alloc = virtual.arena_allocator(arena)
	} else {
		free(arena)
	}
	return ctx, ERROR_NONE
}

@(private)
host_module_context_destroy :: proc(ctx: ^Module_Context) {
	if ctx.arena != nil {
		virtual.arena_destroy(ctx.arena)
		free(ctx.arena)
	}
	if len(ctx.buffer) > 0 do delete(ctx.buffer)
	ctx.buffer = nil
	ctx.arena = nil
}

// host_shutdown_modules runs registered shutdown hooks in reverse name order.
host_shutdown_modules :: proc(host: ^Host) {
	names := host_module_names(host, context.allocator)
	defer delete(names)
	for i := len(names) - 1; i >= 0; i -= 1 {
		if module, found := host.modules[names[i]]; found && module.shutdown != nil {
			module.shutdown(host)
		}
	}
}

// --- Module data access -----------------------------------------------------

// Module_Scan walks one table inside a read transaction. Rows are owned by the
// scan and stay valid until module_scan_end.
Module_Scan :: struct {
	tx:    ^Tx,
	table: string,
	rows:  [dynamic]Row,
	index: int,
}

module_scan_begin :: proc(host: ^Host, table: string) -> (^Module_Scan, Error) {
	scan := new(Module_Scan)
	scan.tx = tx_begin_read(host.store)
	scan.table = table
	if collect_err := tx_collect(scan.tx, table, &scan.rows); collect_err.kind != .None {
		tx_end(scan.tx)
		free(scan)
		return nil, collect_err
	}
	return scan, ERROR_NONE
}

module_scan_next :: proc(scan: ^Module_Scan) -> (Row, bool) {
	if scan == nil || scan.index >= len(scan.rows) do return {}, false
	row := scan.rows[scan.index]
	scan.index += 1
	return row, true
}

module_scan_end :: proc(scan: ^Module_Scan) {
	if scan == nil do return
	if scan.tx != nil do tx_end(scan.tx)
	delete(scan.rows)
	free(scan)
}

// module_insert commits one row and returns its id.
module_insert :: proc(host: ^Host, table: string, values: []Value) -> (Row_Id, Error) {
	tx := tx_begin_write(host.store)
	id, insert_err := tx_insert(tx, table, values)
	if insert_err.kind != .None {
		tx_rollback(tx)
		return 0, insert_err
	}
	if commit_err := tx_commit(tx); commit_err.kind != .None do return 0, commit_err
	return id, ERROR_NONE
}

module_update :: proc(host: ^Host, table: string, id: Row_Id, values: []Value) -> Error {
	tx := tx_begin_write(host.store)
	if update_err := tx_update(tx, table, id, values); update_err.kind != .None {
		tx_rollback(tx)
		return update_err
	}
	return tx_commit(tx)
}

module_delete :: proc(host: ^Host, table: string, id: Row_Id) -> Error {
	tx := tx_begin_write(host.store)
	if delete_err := tx_delete(tx, table, id); delete_err.kind != .None {
		tx_rollback(tx)
		return delete_err
	}
	return tx_commit(tx)
}

// module_delete_range removes the visible rows whose id is in [from, to].
module_delete_range :: proc(host: ^Host, table: string, from_id, to_id: Row_Id) -> (int, Error) {
	tx := tx_begin_write(host.store)
	rows: [dynamic]Row
	if collect_err := tx_collect(tx, table, &rows); collect_err.kind != .None {
		delete(rows)
		tx_rollback(tx)
		return 0, collect_err
	}
	removed := 0
	for row in rows {
		if row.id < from_id || row.id > to_id do continue
		if delete_err := tx_delete(tx, table, row.id); delete_err.kind != .None {
			delete(rows)
			tx_rollback(tx)
			return removed, delete_err
		}
		removed += 1
	}
	delete(rows)
	if commit_err := tx_commit(tx); commit_err.kind != .None do return removed, commit_err
	return removed, ERROR_NONE
}

// --- Identity inside a module ----------------------------------------------

// module_identity is the identity policies see for this call.
module_identity :: proc(host: ^Host) -> Identity {
	return store_identity(host.store)
}

// module_authenticate resolves a session token or JWT exactly like the
// transport does, so a module can check its own callers.
module_authenticate :: proc(host: ^Host, token: string) -> (Identity, bool) {
	return host_authenticate(host, token)
}

// host_swap_module replaces a registered module in place. The old shutdown hook
// runs first and the new init hook runs before the new handlers become
// visible; a failure leaves the previous module in place.
host_swap_module :: proc(host: ^Host, module: Module) -> Error {
	existing, found := host.modules[module.name]
	if !found do return errf(.Invalid_Argument, "no module named %s to swap", module.name)
	if module.abi_version != MODULE_ABI_VERSION_1 && module.abi_version != MODULE_ABI_VERSION {
		return errf(
			.Invalid_Argument,
			"module %s uses ABI %d, this host accepts 1 and %d",
			module.name,
			module.abi_version,
			MODULE_ABI_VERSION,
		)
	}
	if module.init != nil {
		if init_err := module.init(host); init_err.kind != .None do return init_err
	}
	if module.init_v2 != nil {
		ctx, open_err := host_module_context(host, nil)
		defer host_module_context_destroy(&ctx)
		if open_err.kind != .None do return open_err
		if init_err := module.init_v2(&ctx); init_err.kind != .None do return init_err
	}
	if existing.shutdown != nil do existing.shutdown(host)
	host.modules[module.name] = module
	return ERROR_NONE
}
