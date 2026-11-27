package tests

import "core:math/rand"
import "core:strings"
import "core:testing"

import db "../engine"

// A comparison is linked to the collation and the affinities its operands give
// it when its statement is resolved (A1.8e): it does not look a collation up
// by name, nor work its columns' affinity out, at every row. A view's query
// keeps no links (a tree of its own, parsed at every run), so the same query
// read through a view is what a comparison by name answers.

@(private = "file")
ck_store :: proc(t: ^testing.T) -> ^db.Store {
	store, err := db.store_open("", {persistent = false})
	testing.expectf(t, db.error_ok(err), "open: %s", err.message)
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, folded TEXT COLLATE NOCASE, padded TEXT COLLATE RTRIM, n INTEGER, s TEXT)")
	run_done(t, store, "INSERT INTO t VALUES (1, 'Árbol', 'ÁRBOL', 'x  ', 5, '5'), (2, 'ñandú', 'Ñandú', 'x', 12, '12'), (3, 'abc', 'ABC', 'y ', 7, 'seven'), (4, 'ABC', 'abd', 'x', 30, '4'), (5, NULL, NULL, NULL, NULL, NULL)")
	return store
}

@(private = "file")
CK_QUERY :: "SELECT group_concat(answer, ',') FROM (SELECT id || ':' || (name = 'árbol' COLLATE NOCASE) || (name = 'ABC' COLLATE NOCASE) || (folded = 'árbol') || (folded < 'abc') || ('ÑANDÚ' = folded) || (padded = 'x') || (padded > 'x ') || (name COLLATE BINARY = folded) || (name = folded COLLATE NOCASE) || (n > '10') || (s > 10) || (n = s) || (s IS 12) || (name IS NOT NULL) || (n <> 7) AS answer FROM t ORDER BY id)"

@(private = "file")
ck_by_name :: proc(t: ^testing.T, store: ^db.Store, query: string, view: string, lookups: u64) -> string {
	run_done(t, store, strings.concatenate({"CREATE VIEW ", view, " AS ", query}, context.temp_allocator))
	db.resolve_counters_reset()
	result := run(t, store, strings.concatenate({"SELECT * FROM ", view}, context.temp_allocator))
	defer db.sql_result_destroy(&result)
	testing.expectf(t, db.resolve_counters().collation_names >= lookups, "by name: %v", db.resolve_counters())
	if !testing.expect(t, len(result.rows) == 1) do return ""
	return strings.clone(result.rows[0][0].s, context.temp_allocator)
}

@(test)
test_a_linked_comparison_answers_as_a_comparison_by_name :: proc(t: ^testing.T) {
	store := ck_store(t)
	defer db.store_close(store)
	want := ck_by_name(t, store, CK_QUERY, "by_name", 20)
	testing.expect(t, len(want) > 40, "every row answers")
	for _ in 0 ..< 3 do testing.expect_value(t, scalar(t, store, CK_QUERY).s, want)
	db.resolve_counters_reset()
	testing.expect_value(t, scalar(t, store, CK_QUERY).s, want)
	counted := db.resolve_counters()
	testing.expectf(t, counted.collation_names == 0, "%d collation lookups", counted.collation_names)
}

@(private = "file")
ck_reverse :: proc(a, b: string, user: rawptr) -> int {
	if a == b do return 0
	return a < b ? 1 : -1
}

// A program's collation is decided as a builtin's is, and the registry is part
// of the catalog: registered, replaced or dropped, a kept statement decides
// again.
@(test)
test_a_kept_comparison_follows_the_collations_registered :: proc(t: ^testing.T) {
	store := ck_store(t)
	defer db.store_close(store)
	query :: "SELECT group_concat(id, ',') FROM (SELECT id FROM t WHERE name < 'b' COLLATE backwards ORDER BY id)"
	testing.expect(t, !db.error_ok(run_error(t, store, query)), "no backwards collation yet")
	testing.expect(t, db.error_ok(db.store_register_collation(store, "backwards", ck_reverse)))
	want := ck_by_name(t, store, query, "backwards_by_name", 4)
	testing.expect_value(t, want, "1,2")
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, query).s, want)
	// NOCASE replaced by a program's comparison is the program's.
	nocase :: "SELECT group_concat(id, ',') FROM (SELECT id FROM t WHERE name = 'abc' COLLATE NOCASE ORDER BY id)"
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, nocase).s, "3,4")
	testing.expect(t, db.error_ok(db.store_register_collation(store, "nocase", ck_reverse, nil, true)))
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, nocase).s, "3")
	testing.expect(t, db.store_unregister_collation(store, "nocase"))
	for _ in 0 ..< 2 do testing.expect_value(t, scalar(t, store, nocase).s, "3,4")
	testing.expect(t, db.store_unregister_collation(store, "backwards"))
	testing.expect(t, !db.error_ok(run_error(t, store, query)), "backwards is gone")
}

// NOCASE without the lowered copies orders every pair of texts as the lowered
// copies do, invalid UTF-8 and characters outside ASCII included.
@(test)
test_nocase_without_copies_orders_as_the_lowered_texts :: proc(t: ^testing.T) {
	pieces := []string{"a", "A", "z", "Z", "é", "É", "ñ", "Ñ", "ß", "İ", "ı", "Σ", "σ", "ς", "\xff", "\xc3", " ", "0", "~", "日", "Ǆ", "ǅ", "ǆ", "\xe2\x82"}
	random := rand.create(0x5eed)
	context.random_generator = rand.default_random_generator(&random)
	make_text :: proc(pieces: []string) -> string {
		builder := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< rand.int_max(6) do strings.write_string(&builder, rand.choice(pieces))
		return strings.to_string(builder)
	}
	sign :: proc(x: int) -> int {return x < 0 ? -1 : x > 0 ? 1 : 0}
	for _ in 0 ..< 20000 {
		a, b := make_text(pieces), make_text(pieces)
		lowered := db.text_compare(strings.to_lower(a, context.temp_allocator), strings.to_lower(b, context.temp_allocator))
		folded := db.nocase_compare(a, b)
		if !testing.expectf(t, sign(lowered) == sign(folded), "%q vs %q: lowered %d, folded %d", a, b, lowered, folded) do return
	}
}
