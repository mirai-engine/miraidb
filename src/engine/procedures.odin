package engine

import "core:mem"
import "core:strings"
import "core:time"

// A procedure is a reducer that owns its transaction phases: it can commit the
// current transaction, open a new one and continue. Between phases it holds no
// store lock, so a long procedure does not block readers or other writers.
//
// Procedures are not idempotent: a request id retry would run the whole body
// again. Use a reducer when at-most-once matters.

Procedure_Handler :: proc(ctx: ^Procedure_Ctx, args: []Value) -> Error

Procedure_Def :: struct {
	name:    string,
	params:  []Column_Type,
	handler: Procedure_Handler,
}

Procedure_Ctx :: struct {
	host:      ^Host,
	tx:        ^Tx,
	now_us:    i64,
	committed: int,
	logs:      ^[dynamic]string,
}

// procedure_log records one message for the caller. Messages are not durable
// state: they are handed back with the call and dropped on the next one.
procedure_log :: proc(ctx: ^Procedure_Ctx, message: string) {
	if ctx.logs == nil do return
	append(ctx.logs, strings.clone(message))
}

// procedure_now_us is the call's fixed time, for timers and deadlines.
procedure_now_us :: proc(ctx: ^Procedure_Ctx) -> i64 {
	return ctx.now_us
}

// procedure_commit makes the current phase durable and opens the next one.
procedure_commit :: proc(ctx: ^Procedure_Ctx) -> Error {
	if commit_err := tx_commit(ctx.tx); commit_err.kind != .None do return commit_err
	ctx.tx = tx_begin_write(ctx.host.store)
	ctx.committed += 1
	return ERROR_NONE
}

// procedure_sleep commits, sleeps and opens the next phase. G8 extends it with
// precise scheduling; sleeping zero is the common "yield" case.
procedure_sleep :: proc(ctx: ^Procedure_Ctx, duration_us: i64) -> Error {
	if commit_err := procedure_commit(ctx); commit_err.kind != .None do return commit_err
	if duration_us > 0 {
		time.sleep(time.Duration(duration_us * 1000))
	}
	return ERROR_NONE
}

host_register_procedure :: proc(
	host: ^Host,
	name: string,
	params: []Column_Type,
	handler: Procedure_Handler,
) -> Error {
	if _, exists := host.procedures[name]; exists {
		return errf(.Invalid_Argument, "procedure %s is already registered", name)
	}
	host.procedures[name] = Procedure_Def {
		name    = strings.clone(name),
		params  = make([]Column_Type, len(params)),
		handler = handler,
	}
	copy(host.procedures[name].params, params)
	return host_catalog_record(host, name, "procedure", params)
}

// host_call_procedure runs one procedure, committing the final phase on success
// and rolling back only the phase that failed.
host_call_procedure :: proc(host: ^Host, name: string, args: []Value) -> Error {
	procedure, found := host.procedures[name]
	if !found {
		return errf(.Invalid_Argument, "no procedure named %s", name)
	}
	if len(args) != len(procedure.params) {
		return errf(
			.Invalid_Argument,
			"procedure %s takes %d arguments but %d were given",
			name,
			len(procedure.params),
			len(args),
		)
	}
	coerced := make([]Value, len(args))
	defer delete(coerced)
	for param, i in procedure.params {
		value, coerce_err := value_coerce(args[i], param)
		if coerce_err.kind != .None do return coerce_err
		coerced[i] = value
	}
	host_clear_procedure_logs(host)
	logs := make([dynamic]string)
	defer {
		host.procedure_logs = logs[:]
	}
	ctx := Procedure_Ctx {
		host   = host,
		tx     = tx_begin_write(host.store),
		now_us = host_now(host),
		logs   = &logs,
	}
	if call_err := procedure.handler(&ctx, coerced); call_err.kind != .None {
		tx_rollback(ctx.tx)
		return call_err
	}
	return tx_commit(ctx.tx)
}

// host_procedure_logs returns the messages of the last procedure call.
host_procedure_logs :: proc(host: ^Host) -> []string {
	return host.procedure_logs
}

@(private)
host_clear_procedure_logs :: proc(host: ^Host) {
	for message in host.procedure_logs do delete(message)
	delete(host.procedure_logs)
	host.procedure_logs = nil
}

host_procedure_names :: proc(host: ^Host, alloc: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, len(host.procedures), alloc)
	for name in host.procedures do append(&names, name)
	slice_sort_strings(names[:])
	return names[:]
}
