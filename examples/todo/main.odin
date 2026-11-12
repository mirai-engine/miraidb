// A small task board that shows the programmable layer: reducers mutate the
// database atomically and subscriptions stream the resulting rows.
//
//   odin run examples/todo -- todo.db
//
package main

import "core:fmt"
import "core:os"
import "core:strings"

import db "../../src/engine"

State :: struct {
	store: ^db.Store,
	host:  ^db.Host,
}

// add_task inserts a task. The reducer runs inside one transaction; returning an
// error rolls everything back.
add_task :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
	title := strings.trim_space(args[0].s)
	if len(title) == 0 {
		return db.errf(.Invalid_Argument, "a task needs a title")
	}
	// The dialect has no bind parameters yet, so the statement is built with the
	// title escaped.
	escaped, _ := strings.replace_all(title, "'", "''")
	statement := fmt.aprintf("INSERT INTO task (title) VALUES ('%s')", escaped)
	defer delete(statement)
	_, err := db.sql_execute_in_tx(ctx.tx, statement)
	return err
}

complete_task :: proc(ctx: ^db.Reducer_Ctx, args: []db.Value) -> db.Error {
	id, ok := db.value_to_i64(args[0])
	if !ok {
		return db.errf(.Invalid_Type, "task id must be an integer")
	}
	statement := fmt.aprintf("UPDATE task SET done = true WHERE id = %d", id)
	defer delete(statement)
	_, err := db.sql_execute_in_tx(ctx.tx, statement)
	return err
}

main :: proc() {
	path := "todo.db"
	if len(os.args) > 1 do path = os.args[1]

	store, open_err := db.store_open(path, {persistent = true, create = true, durable = true})
	if !db.error_ok(open_err) {
		fmt.eprintfln("cannot open %s: %s", path, open_err.message)
		os.exit(1)
	}
	defer db.store_close(store)

	host := db.host_init(store)
	defer db.host_destroy(host)

	_, schema_err := db.sql_execute(store, `
		CREATE TABLE IF NOT EXISTS task (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			title TEXT NOT NULL,
			done BOOLEAN NOT NULL DEFAULT false
		)`)
	if !db.error_ok(schema_err) {
		fmt.eprintfln("schema: %s", schema_err.message)
		os.exit(1)
	}

	if reg_err := db.host_register(host, "add_task", []db.Column_Type{db.type_string}, add_task); !db.error_ok(reg_err) {
		fmt.eprintfln("register: %s", reg_err.message)
		os.exit(1)
	}
	if reg_err := db.host_register(host, "complete_task", []db.Column_Type{db.type_int}, complete_task); !db.error_ok(reg_err) {
		fmt.eprintfln("register: %s", reg_err.message)
		os.exit(1)
	}

	// Subscribe before mutating so the program sees the deltas it causes.
	subscription, snapshot, sub_err := db.host_subscribe(host, "SELECT id, title, done FROM task")
	if !db.error_ok(sub_err) {
		fmt.eprintfln("subscribe: %s", sub_err.message)
		os.exit(1)
	}
	defer db.host_unsubscribe(host, subscription)
	fmt.printfln("initial snapshot: %d row(s)", len(snapshot))
	for row in snapshot do print_row(row)
	for row in snapshot do db.free_values(row)
	delete(snapshot)

	host.on_update = proc(ctx: rawptr, update: ^db.Subscription_Update) {
		for row in update.inserts {
			fmt.print("insert ")
			print_row(row)
		}
		for row in update.deletes {
			fmt.print("delete ")
			print_row(row)
		}
	}

	for title in ([]string{"write the RFC", "add ordered indexes", "ship it"}) {
		call_err := db.host_call(host, "add_task", []db.Value{db.value_string(title)})
		if !db.error_ok(call_err) {
			fmt.eprintfln("add_task: %s", call_err.message)
		}
	}
	if call_err := db.host_call(host, "complete_task", []db.Value{db.value_int(0)}); !db.error_ok(call_err) {
		fmt.eprintfln("complete_task: %s", call_err.message)
	}

	result, query_err := db.sql_execute(store, "SELECT id, title, done FROM task ORDER BY id")
	if !db.error_ok(query_err) {
		fmt.eprintfln("query: %s", query_err.message)
		os.exit(1)
	}
	defer db.sql_result_destroy(&result)
	fmt.println("\nfinal table:")
	for row in result.rows do print_row(row)
}

print_row :: proc(row: []db.Value) {
	line := strings.builder_make(context.temp_allocator)
	for value, i in row {
		if i > 0 do strings.write_string(&line, " | ")
		strings.write_string(&line, db.value_format(value, context.temp_allocator))
	}
	fmt.println(strings.to_string(line))
}
