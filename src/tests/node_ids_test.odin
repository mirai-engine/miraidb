package tests

import "core:testing"

import db "../engine"

// A resolved statement links a node by its number (A1.8): every node the
// parser makes that a resolution links (a column, a call, a binary operator)
// has a number of its own in its query, from 1 to Query.node_count with none
// missing.

@(private = "file")
Ni_Seen :: struct {
	ids:   map[db.Node_Id]int,
	nodes: int,
}

@(private = "file")
ni_select :: proc(seen: ^Ni_Seen, select: ^db.Select_Stmt) {
	for item in select.projections do ni_expr(seen, item.expr)
	for join in select.joins do ni_expr(seen, join.on)
	ni_expr(seen, select.where_clause)
}

@(private = "file")
ni_expr :: proc(seen: ^Ni_Seen, expr: ^db.Expr) {
	visit :: proc(expr: ^db.Expr, user: rawptr) -> bool {
		seen := cast(^Ni_Seen)user
		id: db.Node_Id
		numbered := true
		#partial switch e in expr^ {
		case db.Column_Expr:
			id = e.id
		case db.Call_Expr:
			id = e.id
		case db.Binary_Expr:
			id = e.id
		case db.Subquery_Expr:
			// The walk stops at a subquery; its SELECT is the same query's.
			ni_select(seen, e.select)
			numbered = false
		case:
			numbered = false
		}
		if numbered {
			seen.nodes += 1
			seen.ids[id] += 1
		}
		return true
	}
	db.expr_walk(expr, visit, seen)
}

@(test)
test_the_parser_numbers_the_nodes_a_resolution_links :: proc(t: ^testing.T) {
	sql := "SELECT a.x + 1, lower(b.n), count(*) FROM a JOIN b ON b.id = a.id AND b.k <> 2 WHERE a.x > (SELECT max(v) FROM c WHERE c.k = a.k) OR a.y IN (1, 2)"
	query, err := db.sql_parse(sql)
	if !testing.expectf(t, db.error_ok(err), "parse: %s", err.message) do return
	defer db.query_destroy(&query)
	select, is_select := query.statement.(db.Select_Stmt)
	if !testing.expect(t, is_select) do return
	seen := Ni_Seen{ids = make(map[db.Node_Id]int)}
	defer delete(seen.ids)
	ni_select(&seen, &select)
	testing.expect(t, seen.nodes > 10)
	// Every node numbered, each number once, and the numbers 1..node_count.
	testing.expect_value(t, seen.ids[0], 0)
	testing.expect_value(t, len(seen.ids), seen.nodes)
	testing.expect_value(t, int(query.node_count), seen.nodes)
	for id in seen.ids {
		testing.expectf(t, id >= 1 && id <= query.node_count, "node %d outside 1..%d", id, query.node_count)
	}
	// Another query numbers its own from 1.
	other, other_err := db.sql_parse("SELECT y FROM a")
	if !testing.expect(t, db.error_ok(other_err)) do return
	defer db.query_destroy(&other)
	testing.expect_value(t, other.node_count, db.Node_Id(1))
}
