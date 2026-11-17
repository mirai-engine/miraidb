package tests

import "core:testing"

import db "../engine"

@(test)
test_listen_registry :: proc(t: ^testing.T) {
	store := fresh_db(t, "listen")
	if store == nil do return
	defer cleanup_db(store, "listen")

	delivered := 0
	ctx: rawptr = &delivered
	store.on_notify = proc(c: rawptr, owner: u64, channel, payload: string) {
		(cast(^int)c)^ += 1
	}
	store.on_notify_ctx = ctx
	db.store_listen(store, 1, "orders")
	testing.expect_value(t, len(store.listeners), 1)
	db.store_notify(store, 2, "orders", "first")
	testing.expect_value(t, delivered, 1)
	db.store_notify(store, 1, "orders", "self")
	testing.expect_value(t, delivered, 1)
	db.store_unlisten(store, 1, "orders", false)
	db.store_notify(store, 2, "orders", "after")
	testing.expect_value(t, delivered, 1)
}
