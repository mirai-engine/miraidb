package tests

import "core:testing"

import db "../engine"

// The small SQLite functions and pragmas a tool asks for. Each one is compared
// against SQLite's own answer, which `scripts/differential.py` cannot reach for
// the ones that depend on the version.
@(test)
test_sqlite_scalar_gaps :: proc(t: ^testing.T) {
	store := fresh_db(t, "sqlite_gaps")
	if store == nil do return
	defer cleanup_db(store, "sqlite_gaps")

	scalar :: proc(t: ^testing.T, store: ^db.Store, sql: string) -> db.Value {
		return scalar(t, store, sql)
	}

	// The hyperbolic family, and the two with a domain.
	check := run(
		t,
		store,
		"SELECT sinh(0), cosh(0), tanh(0), asinh(0), acosh(1), atanh(0), acosh(0.5), atanh(2)",
	)
	testing.expect_value(t, check.rows[0][0].f, f64(0))
	testing.expect_value(t, check.rows[0][1].f, f64(1))
	testing.expect_value(t, check.rows[0][2].f, f64(0))
	testing.expect_value(t, check.rows[0][4].f, f64(0))
	testing.expect_value(t, check.rows[0][6].kind, db.Value_Kind.Null)
	testing.expect_value(t, check.rows[0][7].kind, db.Value_Kind.Null)
	db.sql_result_destroy(&check)

	// SOUNDEX: the classic cases, and a text with no letter at all.
	soundex := run(t, store, "SELECT soundex('Robert'), soundex('Rupert'), soundex('Tymczak'), soundex('')")
	testing.expect_value(t, soundex.rows[0][0].s, "R163")
	testing.expect_value(t, soundex.rows[0][1].s, "R163")
	testing.expect_value(t, soundex.rows[0][2].s, "T522")
	testing.expect_value(t, soundex.rows[0][3].s, "?000")
	db.sql_result_destroy(&soundex)

	// unistr reads the escapes unistr_quote writes, and the affinity names the
	// storage class of a value.
	text := run(t, store, "SELECT unistr('a\\u0041\\+000042'), affinity(1), affinity(1.5), affinity('x')")
	testing.expect_value(t, text.rows[0][0].s, "aAB")
	testing.expect_value(t, text.rows[0][1].s, "INTEGER")
	testing.expect_value(t, text.rows[0][2].s, "REAL")
	testing.expect_value(t, text.rows[0][3].s, "TEXT")
	db.sql_result_destroy(&text)
	quoted := run(t, store, "SELECT unistr_quote('a' || char(9) || 'b')")
	testing.expect_value(t, quoted.rows[0][0].s, "unistr('a\\u0009b')")
	db.sql_result_destroy(&quoted)

	// timediff is `first - second`, as a signed calendar span.
	span := run(
		t,
		store,
		"SELECT timediff('2024-01-01 00:00:00', '2024-03-02 03:04:05'), timediff('2024-03-02 03:04:05', '2024-01-01 00:00:00'), timediff('2024-02-29 12:00:00', '2024-03-01 12:00:00')",
	)
	testing.expect_value(t, span.rows[0][0].s, "-0000-02-01 03:04:05.000")
	testing.expect_value(t, span.rows[0][1].s, "+0000-02-01 03:04:05.000")
	testing.expect_value(t, span.rows[0][2].s, "-0000-00-01 00:00:00.000")
	db.sql_result_destroy(&span)

	// The introspection functions a tool prints.
	intro := run(
		t,
		store,
		"SELECT sqlite_compileoption_used('MIRAIDB'), sqlite_compileoption_used('ENABLE_FTS5'), sqlite_compileoption_get(0), sqlite_compileoption_get(5), sqlite_source_id()",
	)
	testing.expect_value(t, intro.rows[0][0].i, i64(1))
	testing.expect_value(t, intro.rows[0][1].i, i64(0))
	testing.expect_value(t, intro.rows[0][2].s, "MIRAIDB")
	testing.expect_value(t, intro.rows[0][3].kind, db.Value_Kind.Null)
	testing.expect_value(t, intro.rows[0][4].s, "miraidb")
	db.sql_result_destroy(&intro)
	_ = scalar
}

@(test)
test_sqlite_pragma_gaps :: proc(t: ^testing.T) {
	store := fresh_db(t, "sqlite_pragmas")
	if store == nil do return
	defer cleanup_db(store, "sqlite_pragmas")

	// collation_list names the three collations the engine implements.
	collations := run(t, store, "PRAGMA collation_list")
	defer db.sql_result_destroy(&collations)
	testing.expect_value(t, len(collations.rows), 3)
	testing.expect_value(t, collations.rows[0][1].s, "BINARY")
	testing.expect_value(t, collations.rows[1][1].s, "NOCASE")
	testing.expect_value(t, collations.rows[2][1].s, "RTRIM")

	// module_list names the virtual table modules a CREATE VIRTUAL TABLE accepts.
	modules := run(t, store, "PRAGMA module_list")
	defer db.sql_result_destroy(&modules)
	testing.expect_value(t, len(modules.rows), 6)
	testing.expect_value(t, modules.rows[0][1].s, "fts4")

	// The knobs that have nothing to give back are acknowledged, and the ones
	// with a neutral answer answer it.
	for statement in ([]string {
		"PRAGMA shrink_memory",
		"PRAGMA incremental_vacuum",
		"PRAGMA temp_store_directory = '/tmp'",
		"PRAGMA data_store_directory = '/tmp'",
		"PRAGMA soft_heap_limit64 = 1000",
	}) {
		result := run(t, store, statement)
		testing.expect_value(t, result.kind, db.Sql_Result_Kind.Ack)
		db.sql_result_destroy(&result)
	}
	Case :: struct {
		sql:   string,
		value: i64,
	}
	for entry in ([]Case {
			{"PRAGMA temp_store", i64(0)},
			{"PRAGMA legacy_file_format", i64(0)},
			{"PRAGMA soft_heap_limit64", i64(0)},
		}) {
		result := run(t, store, entry.sql)
		testing.expectf(t, len(result.rows) == 1, "%s answered no row", entry.sql)
		if len(result.rows) == 1 do testing.expect_value(t, result.rows[0][0].i, entry.value)
		db.sql_result_destroy(&result)
	}
	empty := run(t, store, "PRAGMA temp_store_directory")
	defer db.sql_result_destroy(&empty)
	testing.expect_value(t, empty.rows[0][0].s, "")
}

// The JSON mutators and aggregates, compared against SQLite's answers.
@(test)
test_json_mutators_and_aggregates :: proc(t: ^testing.T) {
	store := fresh_db(t, "json_functions")
	if store == nil do return
	defer cleanup_db(store, "json_functions")

	// json_insert adds what is not there and leaves what is; json_set replaces
	// and json_replace only replaces.
	inserted := run(
		t,
		store,
		`SELECT json_insert('{"a":1}', '$.b', 2), json_insert('{"a":1}', '$.a', 9), json_insert('[1,2]', '$[2]', 3)`,
	)
	testing.expect_value(t, inserted.rows[0][0].s, `{"a":1,"b":2}`)
	testing.expect_value(t, inserted.rows[0][1].s, `{"a":1}`)
	testing.expect_value(t, inserted.rows[0][2].s, `[1,2,3]`)
	db.sql_result_destroy(&inserted)

	// A merge patch: null removes a member, anything else replaces or adds it.
	patched := run(t, store, `SELECT json_patch('{"a":1,"b":2}', '{"b":null,"c":3}')`)
	testing.expect_value(t, patched.rows[0][0].s, `{"a":1,"c":3}`)
	db.sql_result_destroy(&patched)
	nested := run(t, store, `SELECT json_patch('{"a":{"x":1}}', '{"a":{"y":2}}')`)
	testing.expect_value(t, nested.rows[0][0].s, `{"a":{"x":1,"y":2}}`)
	db.sql_result_destroy(&nested)

	// json_pretty indents four spaces by default, the format SQLite writes.
	pretty := run(t, store, `SELECT json_pretty('{"a":[1,2],"b":{}}')`)
	testing.expect_value(t, pretty.rows[0][0].s, "{\n    \"a\": [\n        1,\n        2\n    ],\n    \"b\": {}\n}")
	db.sql_result_destroy(&pretty)

	// json_error_position is 0 for a document that parses and the byte position
	// otherwise.
	position := run(t, store, `SELECT json_error_position('{"a":}'), json_error_position('[1,2]')`)
	testing.expect_value(t, position.rows[0][0].i, i64(6))
	testing.expect_value(t, position.rows[0][1].i, i64(0))
	db.sql_result_destroy(&position)

	// The aggregates build one document from the group, and an empty group is
	// NULL, as SQLite answers it.
	run(t, store, "CREATE TABLE t (k TEXT, v INTEGER)")
	run(t, store, "INSERT INTO t VALUES ('a', 1), ('b', 2), ('c', 3)")
	array := run(t, store, "SELECT json_group_array(v) FROM t")
	testing.expect_value(t, array.rows[0][0].s, "[1,2,3]")
	db.sql_result_destroy(&array)
	object := run(t, store, "SELECT json_group_object(k, v) FROM t")
	testing.expect_value(t, object.rows[0][0].s, `{"a":1,"b":2,"c":3}`)
	db.sql_result_destroy(&object)
	empty := run(t, store, "SELECT json_group_array(v) FROM t WHERE v > 100")
	testing.expect_value(t, empty.rows[0][0].s, "[]")
	db.sql_result_destroy(&empty)
	grouped := run(t, store, "SELECT k, json_group_array(v) FROM t GROUP BY k ORDER BY k")
	testing.expect_value(t, len(grouped.rows), 3)
	testing.expect_value(t, grouped.rows[1][1].s, "[2]")
	db.sql_result_destroy(&grouped)
}

// The ordered aggregates SQLite 3.51 added. median(Y) is the 0.5 percentile,
// percentile_cont interpolates, percentile_disc takes a value, and percentile()
// reads its argument as a percentage.
@(test)
test_percentile_aggregates :: proc(t: ^testing.T) {
	store := fresh_db(t, "percentile")
	if store == nil do return
	defer cleanup_db(store, "percentile")

	run(t, store, "CREATE TABLE t (v REAL)")
	run(t, store, "INSERT INTO t VALUES (1), (2), (3), (4), (10)")

	rows := run(
		t,
		store,
		"SELECT median(v), percentile(v, 0.5), percentile_cont(v, 0.25), percentile_disc(v, 0.25), percentile_cont(v, 0.9), percentile_disc(v, 0.9) FROM t",
	)
	defer db.sql_result_destroy(&rows)
	testing.expect_value(t, rows.rows[0][0].f, f64(3))
	// percentile() takes a percentage: 0.5% of four steps is 0.02 of the way
	// from 1 to 2.
	testing.expect_value(t, rows.rows[0][1].f, 1.02)
	testing.expect_value(t, rows.rows[0][2].f, f64(2))
	testing.expect_value(t, rows.rows[0][3].f, f64(2))
	testing.expect_value(t, rows.rows[0][4].f, 7.6000000000000005)
	testing.expect_value(t, rows.rows[0][5].f, f64(4))

	// An even count interpolates for the median and takes a value for the
	// discrete form; an empty group is NULL.
	two := run(t, store, "SELECT median(v), percentile_disc(v, 0.5) FROM t WHERE v < 3")
	testing.expect_value(t, two.rows[0][0].f, 1.5)
	testing.expect_value(t, two.rows[0][1].f, f64(1))
	db.sql_result_destroy(&two)
	empty := run(t, store, "SELECT median(v) FROM t WHERE v > 100")
	testing.expect_value(t, empty.rows[0][0].kind, db.Value_Kind.Null)
	db.sql_result_destroy(&empty)

	// A fraction outside [0, 1] is refused with SQLite's words.
	bad := run_error(t, store, "SELECT percentile_cont(v, 1.5) FROM t")
	defer db.error_free(&bad)
	testing.expect_value(t, bad.kind, db.Error_Kind.Invalid_Argument)
}
