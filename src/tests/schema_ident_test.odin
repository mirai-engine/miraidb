package tests

import "core:testing"

import db "../engine"

// A resolved statement links a column to its table's schema by an identity,
// not a pointer (A1.8): a copy of the table keeps it, a change of its shape
// replaces it.
@(test)
test_a_table_keeps_its_schema_identity_until_its_shape_changes :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY, v TEXT)")
	run_done(t, store, "CREATE TABLE other (id INTEGER PRIMARY KEY)")
	ident_of :: proc(store: ^db.Store, name: string) -> u32 {
		return store.tables[name].schema.ident
	}
	first := ident_of(store, "s")
	testing.expect(t, first != 0)
	testing.expect(t, ident_of(store, "other") != first)
	// A reader holds the table, so the next commit copies it: the copy and the
	// reader's table have the same identity.
	reader := db.tx_begin_read(store)
	run_done(t, store, "INSERT INTO s VALUES (1, 'one')")
	held, _ := db.tx_table(reader, "s")
	testing.expect(t, held != store.tables["s"])
	testing.expect_value(t, held.schema.ident, first)
	testing.expect_value(t, ident_of(store, "s"), first)
	db.tx_end(reader)
	// Rows written keep it; a column added is another shape.
	run_done(t, store, "UPDATE s SET v = 'uno' WHERE id = 1")
	testing.expect_value(t, ident_of(store, "s"), first)
	run_done(t, store, "ALTER TABLE s ADD COLUMN w INTEGER")
	altered := ident_of(store, "s")
	testing.expect(t, altered != first && altered != 0)
	// Dropped and made again: a new one too.
	run_done(t, store, "DROP TABLE s")
	run_done(t, store, "CREATE TABLE s (id INTEGER PRIMARY KEY, v TEXT)")
	testing.expect(t, ident_of(store, "s") != altered)
}
