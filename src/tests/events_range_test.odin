package tests

import "core:fmt"
import "core:testing"

import db "../engine"

// An event read answers what the query of its cursor answers, from any cursor
// (before the first event, inside a block of rows, on a block's edge, past the
// last) and with any limit, on a memory table and on a paged one; the rows it
// hands back are its caller's, strings included, after the read is gone.
@(test)
test_an_event_read_starts_at_its_cursor :: proc(t: ^testing.T) {
	for paged in ([]bool{false, true}) {
		name := paged ? "events_range_paged" : "events_range"
		path := fmt.tprintf("_test_%s", name)
		db.remove_tree(path)
		options := db.Store_Options{persistent = true, create = true, durable = false}
		if paged {
			options.paged_tables = true
			options.page_frames = 8
		}
		store, err := db.store_open(path, options)
		if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do continue
		host := db.host_init(store)
		run_done(t, store, "CREATE EVENT TABLE ev (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER, s TEXT)")
		for batch in 0 ..< 4 {
			run_done(t, store, fmt.tprintf("WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r WHERE i < 250) INSERT INTO ev (n, s) SELECT %d + i, 'event ' || (%d + i) FROM r", batch * 250, batch * 250))
		}
		testing.expectf(t, (store.tables["ev"].paged != nil) == paged, "%s: the event table is paged: %v", name, store.tables["ev"].paged != nil)
		for from in ([]int{0, 1, 2, 255, 256, 257, 500, 999, 1000, 1001, 5000}) {
			for limit in ([]int{0, 1, 7, 300}) {
				rows, read_err := db.events_read(host, "ev", db.Row_Id(from), limit, context.allocator)
				if !testing.expectf(t, db.error_ok(read_err), "%s from %d: %s", name, from, read_err.message) do continue
				sql := fmt.tprintf("SELECT id, n, s FROM ev WHERE id >= %d ORDER BY id%s", from, limit > 0 ? fmt.tprintf(" LIMIT %d", limit) : "")
				want := run(t, store, sql)
				same := len(rows) == len(want.rows)
				for row, i in rows {
					if !same do break
					same = i64(row.id) == want.rows[i][0].i && len(row.values) == 3 && row.values[1].i == want.rows[i][1].i && row.values[2].s == want.rows[i][2].s
				}
				testing.expectf(t, same, "%s: events_read from %d, limit %d: %d rows, the query has %d", name, from, limit, len(rows), len(want.rows))
				db.sql_result_destroy(&want)
				// The strings are the caller's: they outlive the read and what the
				// table does after it.
				run_done(t, store, "INSERT INTO ev (n, s) VALUES (-1, 'later')")
				for row in rows {
					text := row.values[1].i < 0 ? "later" : fmt.tprintf("event %d", row.values[1].i)
					if row.values[2].kind != .String || row.values[2].s != text {
						testing.expectf(t, false, "%s: a row read from %d lost its text", name, from)
						break
					}
				}
				for row in rows do db.free_values(row.values)
				delete(rows)
			}
		}
		db.host_destroy(host)
		db.store_close(store)
		db.remove_tree(path)
	}
}
