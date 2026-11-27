package tests

import "core:fmt"
import "core:strings"
import "core:testing"

import db "../engine"

// A correlated subquery reads a column of the query around it through the
// link its resolution made (A1.8g): the link names the select the row comes
// from, and the run reads it from the frame that select pushed, never from a
// frame counted outward. The shapes below are the ones a frame laid out
// otherwise would get wrong (the same table inside and out, two levels, a join
// the planner reorders), each against the same query read through a view,
// whose tree keeps no links.

@(private = "file")
CL_QUERIES := []string {
	// The same table inside and out: the row compared is the outer one.
	"SELECT group_concat(x, ',') FROM (SELECT (SELECT count(*) FROM q AS r WHERE r.v > q.v) AS x FROM q ORDER BY id)",
	// Two levels: the innermost reads the outermost and the middle one.
	"SELECT group_concat(x, ',') FROM (SELECT (SELECT count(*) FROM r WHERE r.q_id = q.id AND r.w > (SELECT min(v) FROM q AS z WHERE z.id <> q.id AND z.v < r.w)) AS x FROM q ORDER BY id)",
	// Two levels over one table: the middle frame holds the same table at the
	// same place, so only the select a link names tells the rows apart.
	"SELECT group_concat(x, ',') FROM (SELECT (SELECT count(*) FROM q AS m WHERE m.v > q.v AND (SELECT count(*) FROM q AS z WHERE z.v > q.v AND z.v < m.v) > 1) AS x FROM q ORDER BY id)",
	// In WHERE, with EXISTS and NOT EXISTS.
	"SELECT group_concat(id, ',') FROM (SELECT id FROM q WHERE EXISTS (SELECT 1 FROM r WHERE r.q_id = q.id AND r.w > q.v) ORDER BY id)",
	"SELECT group_concat(id, ',') FROM (SELECT id FROM q WHERE NOT EXISTS (SELECT 1 FROM r WHERE r.q_id = q.id) ORDER BY id)",
	// An outer join of two tables the planner may reorder, read inside.
	"SELECT group_concat(x, ',') FROM (SELECT q.id || ':' || (SELECT count(*) FROM r AS s WHERE s.q_id = q.id AND s.w >= p.w) AS x FROM r AS p JOIN q ON q.id = p.q_id WHERE p.w > 1 ORDER BY q.id, p.id)",
	// A self-join outside, the subquery naming each side.
	"SELECT group_concat(x, ',') FROM (SELECT a.id || '-' || b.id || ':' || (SELECT count(*) FROM q AS c WHERE c.v BETWEEN a.v AND b.v) AS x FROM q AS a JOIN q AS b ON b.v > a.v ORDER BY a.id, b.id)",
	// In HAVING and in the select list of a grouped query.
	"SELECT group_concat(x, ',') FROM (SELECT q_id || ':' || count(*) || ':' || (SELECT v FROM q WHERE q.id = r.q_id) AS x FROM r GROUP BY q_id HAVING count(*) > (SELECT count(*) FROM q AS t WHERE t.v > 40) - 3 ORDER BY q_id)",
	// An unqualified name of the outer query.
	"SELECT group_concat(x, ',') FROM (SELECT (SELECT count(*) FROM r WHERE w > v) AS x FROM q ORDER BY id)",
}

// What SQLite answers for each of CL_QUERIES, over the same rows.
@(private = "file")
CL_SQLITE := []string {
	"3,6,9,0,4,7,10,1,5,8,11,2",
	"4,4,4,4,4,3,3,3,2,3,0,0",
	"1,4,7,0,2,5,8,0,3,6,9,0",
	"1,2,3,7,9,10",
	"11,12",
	"1:1,1:2,1:3,1:4,2:1,2:2,2:3,2:4,3:1,3:2,3:3,3:4,4:1,4:2,4:3,4:4,5:1,5:2,5:3,5:4,6:1,6:2,6:3,6:4,7:2,7:3,7:4,7:1,8:2,8:3,8:4,8:1,9:3,9:4,9:1,9:2,10:1,10:2,10:3",
	"1-4:4,1-8:3,1-12:2,2-1:4,2-4:7,2-5:3,2-8:6,2-9:2,2-12:5,3-1:7,3-2:4,3-4:10,3-5:6,3-6:3,3-8:9,3-9:5,3-10:2,3-12:8,5-1:2,5-4:5,5-8:4,5-12:3,6-1:5,6-2:2,6-4:8,6-5:4,6-8:7,6-9:3,6-12:6,7-1:8,7-2:5,7-3:2,7-4:11,7-5:7,7-6:4,7-8:10,7-9:6,7-10:3,7-12:9,8-4:2,9-1:3,9-4:6,9-5:2,9-8:5,9-12:4,10-1:6,10-2:3,10-4:9,10-5:5,10-6:2,10-8:8,10-9:4,10-12:7,11-1:9,11-2:6,11-3:3,11-4:12,11-5:8,11-6:5,11-7:2,11-8:11,11-9:7,11-10:4,11-12:10,12-4:3,12-8:2",
	"1:4:37,2:4:24,3:4:11,4:4:48,5:4:35,6:4:22,7:4:9,8:4:46,9:4:33,10:4:20",
	"6,18,30,0,8,20,32,0,10,22,34,0",
}

@(test)
test_a_correlated_column_reads_the_row_of_the_select_it_names :: proc(t: ^testing.T) {
	store, err := db.store_open("", {persistent = false})
	if !testing.expectf(t, db.error_ok(err), "open: %s", err.message) do return
	defer db.store_close(store)
	run_done(t, store, "CREATE TABLE q (id INTEGER PRIMARY KEY, v INTEGER)")
	run_done(t, store, "CREATE TABLE r (id INTEGER PRIMARY KEY, q_id INTEGER, w INTEGER)")
	run_done(t, store, "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 12) INSERT INTO q SELECT i, (i * 37) % 50 FROM s")
	run_done(t, store, "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 40) INSERT INTO r SELECT i, (i * 7) % 10 + 1, (i * 13) % 45 FROM s")
	for query, i in CL_QUERIES {
		view := fmt.tprintf("cl_%d", i)
		run_done(t, store, strings.concatenate({"CREATE VIEW ", view, " AS ", query}, context.temp_allocator))
		by_name := scalar(t, store, strings.concatenate({"SELECT * FROM ", view}, context.temp_allocator))
		testing.expectf(t, by_name.kind == .String && by_name.s == CL_SQLITE[i], "query %d by name: %v, SQLite %s", i, by_name, CL_SQLITE[i])
		for _ in 0 ..< 2 {
			linked := scalar(t, store, query)
			testing.expectf(t, linked.kind == by_name.kind && (linked.kind != .String || linked.s == by_name.s), "query %d: linked %v, by name %v", i, linked, by_name)
		}
	}
}
