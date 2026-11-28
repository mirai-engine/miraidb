package tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import db "../engine"

// Delta_Sets holds, per subscription, the rows its deltas built.
@(private = "file")
Delta_Sets :: struct {
	sets: map[u64][dynamic]string,
	t:    ^testing.T,
}

@(private = "file")
delta_apply :: proc(ctx: rawptr, update: ^db.Subscription_Update) {
	sets := (^Delta_Sets)(ctx)
	set := &sets.sets[update.subscription_id]
	for row in update.deletes {
		key := row_set_key(row)
		found := -1
		for existing, i in set^ {
			if existing == key {
				found = i
				break
			}
		}
		if found < 0 {
			testing.expectf(sets.t, false, "subscription %d: a delete for a row it does not have: %s", update.subscription_id, key)
		} else {
			delete(set^[found])
			unordered_remove(set, found)
		}
		delete(key)
	}
	for row in update.inserts do append(set, row_set_key(row))
}

// The aggregate subscriptions of a corpus, each checked against a fresh
// evaluation after every commit: groups that appear, change, move and empty,
// NULLs, a REAL next to integers, the extreme of min and max leaving, several
// changes to one row in one commit, and the table emptied and filled again.
@(test)
test_aggregate_subscriptions_follow_every_commit :: proc(t: ^testing.T) {
	store := fresh_db(t, "aggregate_delta")
	if store == nil do return
	defer cleanup_db(store, "aggregate_delta")
	follow_every_commit(t, store, "memory")
}

// The same corpus over a table that uses the page store, whose rows a group
// reads through the transaction: it read only memory rows, and lost a paged
// table's groups when it read them.
@(test)
test_aggregate_subscriptions_follow_every_commit_on_pages :: proc(t: ^testing.T) {
	PATH :: "_test_aggregate_delta_paged"
	db.remove_tree(PATH)
	defer db.remove_tree(PATH)
	store, err := db.store_open(PATH, {persistent = true, create = true, durable = false, paged_tables = true, page_frames = 8})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	follow_every_commit(t, store, "paged")
	testing.expect(t, store.tables["t"].paged != nil)
}

@(private = "file")
follow_every_commit :: proc(t: ^testing.T, store: ^db.Store, face: string) {
	host := db.host_init(store)
	defer db.host_destroy(host)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT, v INTEGER, w REAL)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'a', 1, 0.5), (2, 'a', 4, NULL), (3, 'b', NULL, 2.0), (4, 'b', 7, 1.25), (5, 'c', 2, NULL)")

	QUERIES :: []string {
		"SELECT k, count(*), count(v), sum(v), total(v), avg(v), min(v), max(v) FROM t GROUP BY k",
		"SELECT count(*), sum(v), min(v), max(v) FROM t WHERE v > 1",
		"SELECT count(*) FROM t",
		"SELECT avg(v), total(w) FROM t",
		"SELECT k, sum(w), max(w) FROM t GROUP BY k",
		"SELECT k, min(v) FROM t WHERE v IS NOT NULL GROUP BY k",
		"SELECT sum(v) + count(*) FROM t",
		"SELECT k, sum(v), avg(v + w) FROM t GROUP BY k",
	}
	sets := Delta_Sets{t = t}
	defer {
		for _, &set in sets.sets do join_set_destroy(&set)
		delete(sets.sets)
	}
	ids := make([dynamic]u64)
	defer delete(ids)
	for sql in QUERIES {
		id, snapshot, err := db.host_subscribe(host, sql)
		if !testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message) do return
		sets.sets[id] = join_set_from_snapshot(snapshot)
		for row in snapshot do db.free_values(row)
		delete(snapshot)
		append(&ids, id)
	}
	host.on_update = delta_apply
	host.on_update_ctx = &sets

	STEPS :: [][]string {
		{"INSERT INTO t VALUES (6, 'a', 9, NULL)"},
		{"INSERT INTO t VALUES (7, 'd', NULL, NULL)"},
		{"UPDATE t SET v = 3 WHERE id = 1"},
		// The maximum of `a` leaves; then the minimum of `b`.
		{"DELETE FROM t WHERE id = 6"},
		{"UPDATE t SET v = 8 WHERE id = 4"},
		{"UPDATE t SET k = 'b' WHERE id = 5"},
		// A REAL next to the integers of `a`.
		{"UPDATE t SET v = 2.5 WHERE id = 2"},
		{"UPDATE t SET v = 4 WHERE id = 2"},
		// Several changes to one row, and to one group, in one commit.
		{
			"INSERT INTO t VALUES (8, 'c', 5, 1.0)",
			"UPDATE t SET v = 6 WHERE id = 8",
			"UPDATE t SET k = 'a' WHERE id = 8",
			"DELETE FROM t WHERE id = 1",
		},
		{"INSERT INTO t VALUES (9, 'e', 1, 1.0)", "DELETE FROM t WHERE id = 9"},
		{"UPDATE t SET v = v + 1"},
		{"DELETE FROM t WHERE k = 'b'"},
		{"DELETE FROM t"},
		{"INSERT INTO t VALUES (10, 'a', 5, 0.25)"},
		{"INSERT INTO t VALUES (11, 'a', 5, 0.25), (12, 'f', -3, NULL)"},
		{"DELETE FROM t WHERE id = 10"},
	}
	for statements, s in STEPS {
		tx := db.tx_begin_write(store)
		for sql in statements {
			result, err := db.sql_execute_in_tx(tx, sql)
			testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message)
			db.error_free(&err)
			db.sql_result_destroy(&result)
		}
		commit_err := db.tx_commit(tx)
		testing.expectf(t, db.error_ok(commit_err), "step %d: %s", s, commit_err.message)
		db.error_free(&commit_err)
		for sql, q in QUERIES {
			label := fmt.tprintf("%s, step %d (%s), %s", face, s, statements[0], sql)
			delta_matches_fresh(t, host, sql, &sets.sets[ids[q]], label)
		}
	}
}

@(private = "file")
delta_matches_fresh :: proc(t: ^testing.T, host: ^db.Host, sql: string, set: ^[dynamic]string, label: string) {
	result, err := db.sql_execute(host.store, sql)
	if !testing.expectf(t, db.error_ok(err), "%s: %s", label, err.message) {
		db.error_free(&err)
		return
	}
	defer db.sql_result_destroy(&result)
	fresh := join_set_from_snapshot(result.rows)
	defer join_set_destroy(&fresh)
	slice.sort(set^[:])
	slice.sort(fresh[:])
	same := slice.equal(set^[:], fresh[:])
	if !same {
		for key in set^ do fmt.printfln("%s [deltas] %s", label, strings_printable(key))
		for key in fresh do fmt.printfln("%s [fresh] %s", label, strings_printable(key))
	}
	testing.expectf(t, same, "%s: the deltas built %d rows, a fresh evaluation has %d", label, len(set^), len(fresh))
}

@(private = "file")
strings_printable :: proc(key: string) -> string {
	out, _ := strings.replace_all(key, "\x1f", " | ", context.temp_allocator)
	return out
}

// A group follows a commit by the rows it changed, without reading the others,
// while its running values can: count, sum, total and avg always over
// integers, min and max until their extreme leaves. A REAL in a sum, or the
// extreme leaving, reads that group once; a group the commit did not touch is
// never read.
@(test)
test_aggregate_groups_are_read_only_when_their_values_cannot_follow :: proc(t: ^testing.T) {
	store := fresh_db(t, "aggregate_reads")
	if store == nil do return
	host := db.host_init(store)
	defer db.host_destroy(host)
	defer cleanup_db(store, "aggregate_reads")
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT, v)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'a', 1), (2, 'a', 5), (3, 'a', 9), (4, 'b', 2), (5, 'b', 4)")
	QUERIES :: []string {
		"SELECT k, count(*), sum(v), total(v), avg(v), min(v), max(v) FROM t GROUP BY k",
		"SELECT count(v), sum(v) FROM t",
	}
	sets := Delta_Sets{t = t}
	defer {
		for _, &set in sets.sets do join_set_destroy(&set)
		delete(sets.sets)
	}
	ids: [2]u64
	for sql, q in QUERIES {
		id, snapshot, err := db.host_subscribe(host, sql)
		if !testing.expectf(t, db.error_ok(err), "%s: %s", sql, err.message) do return
		sets.sets[id] = join_set_from_snapshot(snapshot)
		for row in snapshot do db.free_values(row)
		delete(snapshot)
		ids[q] = id
	}
	host.on_update = delta_apply
	host.on_update_ctx = &sets

	Step :: struct {
		sql:   string,
		reads: u64,
	}
	steps := []Step {
		{"INSERT INTO t VALUES (6, 'a', 3)", 0},
		{"UPDATE t SET v = 6 WHERE id = 6", 0},
		{"UPDATE t SET k = 'b', v = 3 WHERE id = 6", 0},
		{"DELETE FROM t WHERE id = 6", 0},
		{"INSERT INTO t VALUES (7, 'c', 8), (8, 'c', 8)", 0},
		// A new extreme replaces the old one without a read.
		{"UPDATE t SET v = 10 WHERE id = 2", 0},
		// The maximum of `a` leaves: `a` is read, by the grouped query only.
		{"DELETE FROM t WHERE id = 2", 1},
		// So does the minimum of `b`.
		{"UPDATE t SET v = 3 WHERE id = 4", 1},
		// A REAL in `c`: both queries sum it, so each reads its group, until it
		// leaves.
		{"UPDATE t SET v = 0.5 WHERE id = 7", 2},
		{"UPDATE t SET v = 7 WHERE id = 7", 2},
		{"INSERT INTO t VALUES (9, 'c', 7)", 0},
	}
	for step in steps {
		before := db.host_agg_group_reads(host)
		run_done(t, store, step.sql)
		reads := db.host_agg_group_reads(host) - before
		testing.expectf(t, reads == step.reads, "%s: %d groups read, expected %d", step.sql, reads, step.reads)
		for sql, q in QUERIES do delta_matches_fresh(t, host, sql, &sets.sets[ids[q]], step.sql)
	}
}
