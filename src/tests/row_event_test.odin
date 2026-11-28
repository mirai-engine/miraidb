package tests

import "core:fmt"
import "core:strings"
import "core:testing"

import db "../engine"

// Event_Log is what the triggers and the row event hook saw, in order.
@(private = "file")
Event_Log :: struct {
	lines: [dynamic]string,
}

// row_text is a rowid and its values as `rowid:v1:v2...`, or `-` for no row.
@(private = "file")
row_text :: proc(rowid: db.Value, values: []db.Value) -> string {
	if rowid.kind == .Null do return strings.clone("-")
	b := strings.builder_make()
	strings.write_string(&b, db.value_format(rowid, context.temp_allocator))
	for v in values {
		strings.write_byte(&b, ':')
		strings.write_string(&b, db.value_format(v, context.temp_allocator))
	}
	return strings.to_string(b)
}

// mark(when, kind, OLD.id, OLD.id, OLD.a, OLD.b, NEW.id, NEW.id, NEW.a, NEW.b)
// logs what a trigger sees: the rowid is the INTEGER PRIMARY KEY, `id`.
@(private = "file")
mark :: proc(args: []db.Value, user: rawptr) -> (db.Value, db.Error) {
	log := (^Event_Log)(user)
	old := row_text(args[2], args[3:6])
	new := row_text(args[6], args[7:10])
	append(&log.lines, fmt.aprintf("%s %s old=%s new=%s", args[0].s, args[1].s, old, new))
	delete(old)
	delete(new)
	return db.value_null(), db.ERROR_NONE
}

@(private = "file")
on_row_event :: proc(ctx: rawptr, event: ^db.Row_Event) {
	log := (^Event_Log)(ctx)
	kind := [db.Row_Change]string{.Insert = "insert", .Update = "update", .Delete = "delete"}
	old := row_text(event.old != nil ? db.value_int(event.old_rowid) : db.value_null(), event.old)
	new := row_text(event.new != nil ? db.value_int(event.new_rowid) : db.value_null(), event.new)
	append(&log.lines, fmt.aprintf("hook %s %s%s d%d old=%s new=%s", event.table, kind[event.change], event.replaced ? " replaced" : "", event.depth, old, new))
	delete(old)
	delete(new)
}

// The row event hook sees each row a statement changes with its values before
// and after, as the statement's triggers see them: after the BEFORE trigger and
// before the AFTER one, with the rowid an UPDATE gives a row, the defaults and
// the affinity of an INSERT, the rows a trigger writes (one level deeper), and
// the rows an INSERT or UPDATE OR REPLACE removes, which no trigger sees.
@(test)
test_row_events_see_the_rows_a_trigger_sees :: proc(t: ^testing.T) {
	store := fresh_db(t, "row_events")
	if store == nil do return
	defer cleanup_db(store, "row_events")
	log: Event_Log
	defer {
		for line in log.lines do delete(line)
		delete(log.lines)
	}
	testing.expect(t, db.error_ok(db.store_register_function(store, "mark", 10, mark, &log)))
	run_done(t, store, "CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b TEXT DEFAULT 'd' UNIQUE)")
	run_done(t, store, "CREATE TABLE u (x TEXT)")
	NEW_ARGS :: "NEW.id, NEW.id, NEW.a, NEW.b"
	OLD_ARGS :: "OLD.id, OLD.id, OLD.a, OLD.b"
	NONE :: "NULL, NULL, NULL, NULL"
	for w in ([]string{"BEFORE", "AFTER"}) {
		lower := strings.to_lower(w, context.temp_allocator)
		run_done(t, store, fmt.tprintf("CREATE TRIGGER %s_i %s INSERT ON t BEGIN SELECT mark('%s', 'insert', %s, %s); END", lower, w, lower, NONE, NEW_ARGS))
		run_done(t, store, fmt.tprintf("CREATE TRIGGER %s_u %s UPDATE ON t BEGIN SELECT mark('%s', 'update', %s, %s); END", lower, w, lower, OLD_ARGS, NEW_ARGS))
	}
	run_done(t, store, fmt.tprintf("CREATE TRIGGER before_d BEFORE DELETE ON t BEGIN SELECT mark('before', 'delete', %s, %s); END", OLD_ARGS, NONE))
	run_done(t, store, fmt.tprintf("CREATE TRIGGER after_d AFTER DELETE ON t BEGIN SELECT mark('after', 'delete', %s, %s); INSERT INTO u VALUES (OLD.b); END", OLD_ARGS, NONE))
	store.hooks.row_event = on_row_event
	store.hooks.row_event_ctx = &log

	Step :: struct {
		sql:  string,
		want: []string,
	}
	// A line ending in `*` is matched by its start: what a BEFORE trigger sees
	// of an INSERT's rowid is the trigger's business, not the hook's.
	steps := []Step {
		{"INSERT INTO t (a, b) VALUES (1, 'x')", {"before insert*", "hook t insert d0 old=- new=1:1:1:x", "after insert old=- new=1:1:1:x"}},
		// The affinity and the default are the row's, as the trigger sees it.
		{"INSERT INTO t (a) VALUES ('7')", {"before insert*", "hook t insert d0 old=- new=2:2:7:d", "after insert old=- new=2:2:7:d"}},
		{"UPDATE t SET a = a + 1 WHERE id = 1", {"before update old=1:1:1:x new=1:1:2:x", "hook t update d0 old=1:1:1:x new=1:1:2:x", "after update old=1:1:1:x new=1:1:2:x"}},
		// The rowid an UPDATE gives the row.
		{"UPDATE t SET id = 10 WHERE id = 2", {"before update old=2:2:7:d new=10:10:7:d", "hook t update d0 old=2:2:7:d new=10:10:7:d", "after update old=2:2:7:d new=10:10:7:d"}},
		// The row the AFTER trigger writes is one level deeper.
		{"DELETE FROM t WHERE id = 10", {"before delete old=10:10:7:d new=-", "hook t delete d0 old=10:10:7:d new=-", "after delete old=10:10:7:d new=-", "hook u insert d1 old=- new=1:d"}},
		// A REPLACE removes the row it collides with: the hook sees it, no
		// trigger does. It is seen before the BEFORE trigger of the insert, which
		// runs when the row is inserted again; SQLite runs that trigger first.
		{"INSERT OR REPLACE INTO t (id, a, b) VALUES (1, 5, 'y')", {"hook t delete replaced d0 old=1:1:2:x new=-", "before insert*", "hook t insert d0 old=- new=1:1:5:y", "after insert old=- new=1:1:5:y"}},
		{"INSERT OR REPLACE INTO t (a, b) VALUES (9, 'y')", {"hook t delete replaced d0 old=1:1:5:y new=-", "before insert*", "hook t insert d0 old=- new=2:2:9:y", "after insert old=- new=2:2:9:y"}},
		{"INSERT INTO t VALUES (3, 0, 'w')", {"before insert*", "hook t insert d0 old=- new=3:3:0:w", "after insert old=- new=3:3:0:w"}},
		{"UPDATE OR REPLACE t SET b = 'w' WHERE id = 2", {"hook t delete replaced d0 old=3:3:0:w new=-", "before update old=2:2:9:y new=2:2:9:w", "hook t update d0 old=2:2:9:y new=2:2:9:w", "after update old=2:2:9:y new=2:2:9:w"}},
		// A DELETE of every row is a delete per row.
		{"DELETE FROM t", {"before delete old=2:2:9:w new=-", "hook t delete d0 old=2:2:9:w new=-", "after delete old=2:2:9:w new=-", "hook u insert d1 old=- new=2:w"}},
	}
	for step in steps {
		for line in log.lines do delete(line)
		clear(&log.lines)
		run_done(t, store, step.sql)
		same := len(log.lines) == len(step.want)
		for want, i in step.want {
			if !same do break
			if strings.has_suffix(want, "*") {
				same = strings.has_prefix(log.lines[i], want[:len(want) - 1])
			} else {
				same = log.lines[i] == want
			}
		}
		if !same {
			for line in log.lines do fmt.printfln("%s [seen] %s", step.sql, line)
			for line in step.want do fmt.printfln("%s [want] %s", step.sql, line)
		}
		testing.expectf(t, same, "%s: the hook and the triggers saw another sequence", step.sql)
	}
	// With no hook, nothing is reported.
	store.hooks.row_event = nil
	for line in log.lines do delete(line)
	clear(&log.lines)
	run_done(t, store, "INSERT INTO u VALUES ('z')")
	testing.expect_value(t, len(log.lines), 0)
}
