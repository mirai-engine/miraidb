package tests

import "core:strings"
import "core:testing"

// NEW.rowid, OLD.rowid, _rowid_ and oid name the row a trigger fires for, as
// SQLite reads them: the INTEGER PRIMARY KEY of a table that has one, the row id
// of one that has not, and the rowid an UPDATE gives the row. They used to fail
// with "column rowid does not exist in NEW".
@(test)
test_a_trigger_reads_the_rowid_of_its_row :: proc(t: ^testing.T) {
	store := fresh_db(t, "trigger_rowid")
	if store == nil do return
	defer cleanup_db(store, "trigger_rowid")
	for sql in ([]string {
		"CREATE TABLE t (id INTEGER PRIMARY KEY, a)",
		"CREATE TABLE r (a INTEGER, b)",
		"CREATE TABLE log (seq INTEGER PRIMARY KEY, w TEXT, nr, nid, o_r, nx, n_r)",
		"CREATE TRIGGER ai AFTER INSERT ON t BEGIN INSERT INTO log (w, nr, nid, o_r, nx, n_r) VALUES ('ai', NEW.rowid, NEW.id, NULL, NEW._rowid_, NEW.oid); END",
		"CREATE TRIGGER bu BEFORE UPDATE ON t BEGIN INSERT INTO log (w, nr, nid, o_r, nx, n_r) VALUES ('bu', NEW.rowid, NEW.id, OLD.rowid, OLD._rowid_, OLD.oid); END",
		"CREATE TRIGGER ad AFTER DELETE ON t BEGIN INSERT INTO log (w, nr, nid, o_r, nx, n_r) VALUES ('ad', NULL, NULL, OLD.rowid, OLD._rowid_, OLD.oid); END",
		"CREATE TRIGGER rai AFTER INSERT ON r BEGIN INSERT INTO log (w, nr) VALUES ('rai', NEW.rowid); END",
		"CREATE TRIGGER rbu BEFORE UPDATE ON r BEGIN INSERT INTO log (w, nr, o_r) VALUES ('rbu', NEW.rowid, OLD.rowid); END",
		"CREATE TRIGGER bi BEFORE INSERT ON t BEGIN INSERT INTO log (w, nr, nid) VALUES ('bi', NEW.rowid, NEW.id); END",
		"INSERT INTO t (a) VALUES (1)",
		"INSERT INTO t VALUES (7, 2)",
		"UPDATE t SET id = 9 WHERE id = 7",
		"DELETE FROM t WHERE id = 9",
		"INSERT INTO r VALUES (1, 2)",
		"INSERT INTO r (rowid, a) VALUES (5, 3)",
		"UPDATE r SET a = 4 WHERE rowid = 5",
	}) {
		run_done(t, store, sql)
	}
	// What SQLite 3.45 logs for the same statements, but for one row: a BEFORE
	// INSERT of a row whose rowid is chosen for it sees here the rowid it gets,
	// in NEW.rowid as in NEW.id, where SQLite shows -1 in both (an open
	// difference, older than NEW.rowid: NEW.id answered so already).
	want := "bi|1|1|NULL|NULL|NULL,ai|1|1|NULL|1|1,bi|7|7|NULL|NULL|NULL,ai|7|7|NULL|7|7,bu|9|9|7|7|7,ad|NULL|NULL|9|9|9,rai|1|NULL|NULL|NULL|NULL,rai|5|NULL|NULL|NULL|NULL,rbu|5|NULL|5|NULL|NULL"
	got := scalar(t, store, "SELECT group_concat(w || '|' || coalesce(nr, 'NULL') || '|' || coalesce(nid, 'NULL') || '|' || coalesce(o_r, 'NULL') || '|' || coalesce(nx, 'NULL') || '|' || coalesce(n_r, 'NULL'), ',') FROM (SELECT * FROM log ORDER BY seq)")
	testing.expectf(t, got.s == want, "the triggers logged %s", got.s)
	// A column of that name is the column, not the rowid.
	run_done(t, store, "CREATE TABLE c (oid TEXT)")
	run_done(t, store, "CREATE TRIGGER ci AFTER INSERT ON c BEGIN INSERT INTO log (w, nr) VALUES ('ci', NEW.oid); END")
	run_done(t, store, "INSERT INTO c VALUES ('mine')")
	testing.expect(t, strings.contains(scalar(t, store, "SELECT group_concat(nr, ',') FROM log WHERE w = 'ci'").s, "mine"))
}
