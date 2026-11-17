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
