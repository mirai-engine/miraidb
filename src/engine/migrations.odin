package engine

import "core:fmt"
import "core:strconv"

// A migration is one schema step. Steps are applied in order, each one inside
// its own transaction together with the version bump, so a failure leaves the
// database at the previous version.
Migration :: struct {
	version: u32,
	sql:     []string,
}

// host_schema_version reads the stored version. `host_init` seeds it to 1.
host_schema_version :: proc(host: ^Host) -> u32 {
	if err := host_ensure_meta(host); err.kind != .None do return 0
	value, found := host_meta(host, "schema_version")
	if !found do return 0
	parsed, ok := strconv.parse_uint(value)
	if !ok do return 0
	return u32(parsed)
}

// host_migrate applies every migration above the stored version. Each step must
// be exactly the next version; a gap or a failing statement stops the run.
host_migrate :: proc(host: ^Host, migrations: []Migration) -> (applied: int, err: Error) {
	if ensure_err := host_ensure_meta(host); ensure_err.kind != .None do return 0, ensure_err
	current := host_schema_version(host)
	for migration in migrations {
		if migration.version <= current do continue
		if migration.version != current + 1 {
			return applied, errf(
				.Invalid_Argument,
				"migration %d is out of order; the database is at %d",
				migration.version,
				current,
			)
		}
		tx := tx_begin_write(host.store)
		for statement in migration.sql {
			if _, statement_err := sql_execute_in_tx(tx, statement); statement_err.kind != .None {
				tx_rollback(tx)
				return applied, errf(
					statement_err.kind,
					"migration %d failed: %s",
					migration.version,
					statement_err.message,
				)
			}
		}
		version_text := fmt.aprintf("%d", migration.version)
		_, update_err := sql_execute_in_tx_params(
			tx,
			"UPDATE _meta SET value = ? WHERE key = 'schema_version'",
			[]Value{value_string(version_text)},
		)
		if update_err.kind != .None {
			tx_rollback(tx)
			return applied, update_err
		}
		if commit_err := tx_commit(tx); commit_err.kind != .None do return applied, commit_err
		current = migration.version
		applied += 1
	}
	return applied, ERROR_NONE
}
