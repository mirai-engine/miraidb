package tests

import "core:strings"
import "core:testing"

import db "../engine"

// Two modules written against the engine's interface: `numbers`, an eponymous
// table whose HIDDEN `upto` column takes the argument of `numbers(n)`, and
// `memo`, a writable table that keeps its rows in a list.

@(private = "file")
Memo :: struct {
	rows:   [dynamic]db.Vtab_Row,
	next:   i64,
	offers: int,
}

@(private = "file")
numbers_connect :: proc(ctx: rawptr, create: bool, table: string, args: []string) -> (rawptr, string, db.Error) {
	return nil, strings.clone("CREATE TABLE x(n, upto HIDDEN)"), db.ERROR_NONE
}

@(private = "file")
numbers_scan :: proc(
	ctx: rawptr,
	handle: rawptr,
	constraints: []db.Vtab_Constraint,
	values: []db.Value,
	order: []db.Vtab_Order,
	columns: int,
	rows: ^[dynamic]db.Vtab_Row,
) -> db.Error {
	upto: i64 = 0
	for constraint, i in constraints {
		if constraint.column == 1 && constraint.op == db.VTAB_OP_EQ do upto = values[i].i
	}
	for n in 1 ..= upto {
		row := db.Vtab_Row{rowid = n, values = make([]db.Value, columns, rows.allocator)}
		row.values[0] = db.value_int(n)
		row.values[1] = db.value_int(upto)
		append(rows, row)
	}
	return db.ERROR_NONE
}

@(private = "file")
memo_connect :: proc(ctx: rawptr, create: bool, table: string, args: []string) -> (rawptr, string, db.Error) {
	return ctx, strings.clone("CREATE TABLE x(word TEXT, size INTEGER)"), db.ERROR_NONE
}

@(private = "file")
memo_scan :: proc(
	ctx: rawptr,
	handle: rawptr,
	constraints: []db.Vtab_Constraint,
	values: []db.Value,
	order: []db.Vtab_Order,
	columns: int,
	rows: ^[dynamic]db.Vtab_Row,
) -> db.Error {
	memo := (^Memo)(handle)
	// The WHERE terms are offered: `size > 3` arrives as the GT code.
	for constraint in constraints do if constraint.op == 4 do memo.offers += 1
	for row in memo.rows {
		copy_row := db.Vtab_Row{rowid = row.rowid, values = make([]db.Value, columns, rows.allocator)}
		for value, i in row.values do copy_row.values[i] = db.value_clone(value, rows.allocator)
		append(rows, copy_row)
	}
	return db.ERROR_NONE
}

@(private = "file")
memo_update :: proc(ctx: rawptr, handle: rawptr, argv: []db.Value, rowid: ^i64) -> db.Error {
	memo := (^Memo)(handle)
	if len(argv) == 1 || argv[0].kind != .Null {
		for row, i in memo.rows {
			if row.rowid != argv[0].i do continue
			for value in row.values do db.value_deep_free(value, context.allocator)
			delete(row.values)
			ordered_remove(&memo.rows, i)
			break
		}
		if len(argv) == 1 do return db.ERROR_NONE
	}
	memo.next += 1
	id := argv[1].kind == .Null ? memo.next : argv[1].i
	values := make([]db.Value, 2)
	for i in 0 ..< 2 do values[i] = db.value_clone(argv[i + 2], context.allocator)
	append(&memo.rows, db.Vtab_Row{rowid = id, values = values})
	if rowid != nil do rowid^ = id
	return db.ERROR_NONE
}

@(private = "file")
vt_ints :: proc(t: ^testing.T, conn: ^db.Embed_Conn, sql: string) -> (out: [dynamic]i64) {
	out = make([dynamic]i64)
	stmt := db.embed_prepare(conn, sql)
	if !testing.expectf(t, stmt != nil, "prepare %s: %s", sql, db.embed_error(conn)) do return
	defer db.embed_finalize(stmt)
	for {
		has_row, err := db.embed_step(stmt)
		if !testing.expectf(t, db.error_drop(err), "%s: %s", sql, db.embed_error(conn)) || !has_row do break
		for i in 0 ..< db.embed_column_count(stmt) do append(&out, db.embed_column_int(stmt, i))
	}
	return
}

@(test)
test_program_virtual_tables :: proc(t: ^testing.T) {
	conn, open_err := db.embed_open(":memory:")
	if !testing.expectf(t, db.error_ok(open_err), "open: %s", open_err.message) do return
	defer db.embed_close(conn)
	memo := Memo{rows = make([dynamic]db.Vtab_Row)}
	defer {
		for row in memo.rows {
			for value in row.values do db.value_deep_free(value, context.allocator)
			delete(row.values)
		}
		delete(memo.rows)
	}
	testing.expect(t, db.error_drop(db.store_register_vtab_module(conn.store, "numbers", db.Vtab_Module {
		eponymous = true, eponymous_only = true, connect = numbers_connect, scan = numbers_scan,
	})))
	testing.expect(t, db.error_drop(db.store_register_vtab_module(conn.store, "memo", db.Vtab_Module {
		ctx = &memo, connect = memo_connect, scan = memo_scan, update = memo_update,
	})))

	// The argument binds the HIDDEN column, and `*` leaves it out.
	numbers := vt_ints(t, conn, "SELECT * FROM numbers(4)")
	testing.expect(t, len(numbers) == 4 && numbers[3] == 4)
	delete(numbers)
	total := vt_ints(t, conn, "SELECT sum(n), max(upto) FROM numbers(10) WHERE n % 2 = 0")
	testing.expect(t, len(total) == 2 && total[0] == 30 && total[1] == 10)
	delete(total)

	for sql in ([]string {
		"CREATE VIRTUAL TABLE words USING memo",
		"INSERT INTO words VALUES ('a', 1), ('abcd', 4), ('abcdef', 6)",
		"UPDATE words SET size = size * 10 WHERE word = 'a'",
		"DELETE FROM words WHERE size = 4",
	}) {
		testing.expectf(t, db.error_drop(db.embed_exec(conn, sql)), "%s: %s", sql, db.embed_error(conn))
	}
	sizes := vt_ints(t, conn, "SELECT size FROM words WHERE size > 3 ORDER BY size")
	testing.expect(t, len(sizes) == 2 && sizes[0] == 6 && sizes[1] == 10)
	delete(sizes)
	testing.expect(t, memo.offers > 0)
	// A name the module's table does not have is refused before it runs.
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "SELECT nope FROM words")))
	// An eponymous-only module cannot be created, and the table can be dropped.
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "CREATE VIRTUAL TABLE n2 USING numbers")))
	testing.expect(t, db.error_drop(db.embed_exec(conn, "DROP TABLE words")))
	testing.expect(t, !db.error_drop(db.embed_exec(conn, "SELECT * FROM words")))
}
