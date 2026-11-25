package engine

// Roles and permissions are catalog data next to the row policies:
//
//	_role  (role, identity)          who has a role; '*' means every caller
//	_grant (role, table_name, action) what a role may write
//
// Writes are checked against `_grant` only when the table exists, so a database
// that never grants anything pays one map lookup per statement. Reads stay the
// job of row policies, which can call `has_role()` for the same roles.

import "core:fmt"
import "core:strings"

ROLE_TABLE :: "_role"
GRANT_TABLE :: "_grant"

// --- What a server's client may not reach -----------------------------------
//
// A store without host access serves clients it does not trust (the server's
// default). A statement runs as the identity a token authenticated, so a client
// must not reach what decides identities and rights:
//
// - the credentials: `_token` (the token digests) and `_meta`, which holds the
//   key that signs every token and JWT: reading it is minting any identity;
// - the authority: creating, writing, altering or dropping `_role`, `_grant`,
//   `_policy` or the credentials, and GRANT, REVOKE and policy DDL;
// - SET identity, which names any identity without a token.
//
// The engine reaches those tables for itself (a token check, the rows GRANT
// writes, the policies of a dropped table) inside catalog_scope, which counts
// per thread: a statement the client wrote never runs inside one, even when a
// trigger or a view runs it on the client's behalf.

@(thread_local, private)
catalog_depth: int

@(private, deferred_none = catalog_scope_end)
catalog_scope :: proc() {
	catalog_depth += 1
}

@(private)
catalog_scope_end :: proc() {
	catalog_depth -= 1
}

// client_untrusted reports a statement a client wrote, on a store that does not
// trust its clients.
@(private)
client_untrusted :: proc(store: ^Store) -> bool {
	return store != nil && !store.host_access && catalog_depth == 0
}

// credential_table names a table a client may not even read.
@(private)
credential_table :: proc(name: string) -> bool {
	return strings.equal_fold(name, TOKEN_TABLE) || strings.equal_fold(name, META_TABLE)
}

// authority_table names a table a client may not create, write or drop.
@(private)
authority_table :: proc(name: string) -> bool {
	if credential_table(name) do return true
	return strings.equal_fold(name, ROLE_TABLE) || strings.equal_fold(name, GRANT_TABLE) || strings.equal_fold(name, POLICY_TABLE)
}

// client_authority_refusal is the one answer a client gets for reaching the
// authority: it changes nothing and says how a deployment trusts its clients.
@(private)
client_authority_refusal :: proc(what: string) -> Error {
	return errf(
		.Permission_Denied,
		"%s is the host's: a client may not change who it is or what it may do (start the server with --allow-host to trust every client)",
		what,
	)
}

// client_credential_refusal answers a client that names a credential table.
@(private)
client_credential_refusal :: proc(name: string) -> Error {
	return errf(.Permission_Denied, "%s holds the server's credentials: a client may not read it", name)
}

// client_authority_check refuses a client's create, write, alter or drop of an
// authority table.
@(private)
client_authority_check :: proc(store: ^Store, name: string) -> Error {
	if !client_untrusted(store) || !authority_table(name) do return ERROR_NONE
	return client_authority_refusal(name)
}

ROLE_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _role (
		role TEXT NOT NULL,
		identity TEXT NOT NULL
	)`

GRANT_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _grant (
		role TEXT NOT NULL,
		table_name TEXT NOT NULL,
		action TEXT NOT NULL
	)`

// identity_text is the lowercase hex form roles are granted to.
identity_text :: proc(identity: Identity) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.allocator)
	for byte in identity {
		fmt.sbprintf(&builder, "%02x", byte)
	}
	return strings.to_string(builder)
}

@(private)
roles_ensure_tables :: proc(tx: ^Tx) -> Error {
	discarded_18, role_err := sql_execute_in_tx(tx, ROLE_SCHEMA_SQL)
	sql_result_destroy(&discarded_18)
	if role_err.kind != .None do return role_err
	discarded_19, grant_err := sql_execute_in_tx(tx, GRANT_SCHEMA_SQL)
	sql_result_destroy(&discarded_19)
	return grant_err
}

@(private)
roles_row_exists :: proc(tx: ^Tx, sql: string, params: []Value) -> (bool, Error) {
	result, err := sql_execute_in_tx_params(tx, sql, params)
	if err.kind != .None do return false, err
	defer sql_result_destroy(&result)
	return len(result.rows) > 0, ERROR_NONE
}

// sql_exec_grant handles GRANT and REVOKE, which take two shapes:
//
//	GRANT role TO identity          REVOKE role FROM identity
//	GRANT action ON table TO role   REVOKE action ON table FROM role
sql_exec_grant :: proc(tx: ^Tx, stmt: Grant_Stmt) -> (Sql_Result, Error) {
	if client_untrusted(tx.store) do return {}, client_authority_refusal(stmt.revoke ? "REVOKE" : "GRANT")
	catalog_scope()
	if len(stmt.role) == 0 do return {}, errf(.Sql_Syntax, "GRANT needs a role name")
	if ensure_err := roles_ensure_tables(tx); ensure_err.kind != .None {
		return {}, ensure_err
	}
	// The next write re-reads the catalog.
	tx.store.grants_checked = false
	if len(stmt.table) == 0 {
		// Role membership.
		if len(stmt.identity) == 0 {
			return {}, errf(.Sql_Syntax, "GRANT needs an identity or an ON table clause")
		}
		identity := strings.trim_space(stmt.identity)
		if stmt.revoke {
			dropped_1, revoke_err := sql_execute_in_tx_params(
				tx,
				"DELETE FROM _role WHERE role = ? AND identity = ?",
				[]Value{value_string(stmt.role), value_string(identity)},
			)
			sql_result_destroy(&dropped_1)
			if revoke_err.kind != .None do return {}, revoke_err
		} else {
			exists, exists_err := roles_row_exists(
				tx,
				"SELECT 1 FROM _role WHERE role = ? AND identity = ?",
				[]Value{value_string(stmt.role), value_string(identity)},
			)
			if exists_err.kind != .None do return {}, exists_err
			if !exists {
				dropped_2, insert_err := sql_execute_in_tx_params(
					tx,
					"INSERT INTO _role (role, identity) VALUES (?, ?)",
					[]Value{value_string(stmt.role), value_string(identity)},
				)
				sql_result_destroy(&dropped_2)
				if insert_err.kind != .None do return {}, insert_err
			}
		}
		return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
	}
	// Table permissions.
	if len(stmt.action) == 0 do return {}, errf(.Sql_Syntax, "GRANT ... ON needs an action")
	action := strings.to_lower(stmt.action, context.temp_allocator)
	switch action {
	case "select", "insert", "update", "delete", "all", "*":
	case:
		return {}, errf(.Invalid_Argument, "unknown permission %q", stmt.action)
	}
	if stmt.revoke {
		dropped_3, revoke_err := sql_execute_in_tx_params(
			tx,
			"DELETE FROM _grant WHERE role = ? AND table_name = ? AND action = ?",
			[]Value{value_string(stmt.role), value_string(stmt.table), value_string(action)},
		)
		sql_result_destroy(&dropped_3)
		if revoke_err.kind != .None do return {}, revoke_err
	} else {
		exists, exists_err := roles_row_exists(
			tx,
			"SELECT 1 FROM _grant WHERE role = ? AND table_name = ? AND action = ?",
			[]Value{value_string(stmt.role), value_string(stmt.table), value_string(action)},
		)
		if exists_err.kind != .None do return {}, exists_err
		if !exists {
			dropped_4, insert_err := sql_execute_in_tx_params(
				tx,
				"INSERT INTO _grant (role, table_name, action) VALUES (?, ?, ?)",
				[]Value{value_string(stmt.role), value_string(stmt.table), value_string(action)},
			)
			sql_result_destroy(&dropped_4)
			if insert_err.kind != .None do return {}, insert_err
		}
	}
	return Sql_Result{kind = .Ack, commit_seq = tx.store.commit_seq}, ERROR_NONE
}

// has_role reports whether the current identity holds a role (directly or
// through the '*' grant).
has_role :: proc(tx: ^Tx, role: string) -> (bool, Error) {
	if tx == nil do return false, ERROR_NONE
	if tx_table_probe(tx, ROLE_TABLE) == nil do return false, ERROR_NONE
	identity := identity_text(tx.store.identity)
	defer delete(identity)
	return roles_row_exists(
		tx,
		"SELECT 1 FROM _role WHERE role = ? AND (identity = ? OR identity = '*')",
		[]Value{value_string(role), value_string(identity)},
	)
}

// permission_allows says whether the current identity may write to a table.
// Without a grant catalog every write is allowed, which keeps databases that
// never asked for roles exactly as open as before.
permission_allows :: proc(tx: ^Tx, table_name, action: string) -> (bool, Error) {
	if tx == nil do return true, ERROR_NONE
	if len(table_name) == 0 || table_name[0] == '_' do return true, ERROR_NONE
	if !tx_system_table_exists(tx, GRANT_TABLE, &tx.grant_probe) do return true, ERROR_NONE
	if !tx.store.grants_checked {
		tx.store.grants_checked = true
		tx.store.grants_active = false
		result, err := sql_execute_in_tx_params(tx, "SELECT 1 FROM _grant LIMIT 1", nil)
		if err.kind == .None {
			tx.store.grants_active = len(result.rows) > 0
			sql_result_destroy(&result)
		}
	}
	if !tx.store.grants_active do return true, ERROR_NONE
	identity := identity_text(tx.store.identity)
	defer delete(identity)
	result, err := sql_execute_in_tx_params(
		tx,
		`
		SELECT 1 FROM _grant g JOIN _role r ON r.role = g.role
		WHERE (g.table_name = ? OR g.table_name = '*')
		  AND (g.action = ? OR g.action = 'all' OR g.action = '*')
		  AND (r.identity = ? OR r.identity = '*')
		LIMIT 1`,
		[]Value{value_string(table_name), value_string(action), value_string(identity)},
	)
	if err.kind != .None do return false, err
	defer sql_result_destroy(&result)
	return len(result.rows) > 0, ERROR_NONE
}

// tx_check_permission is the write gate: the caller turns a refused action into
// a Permission_Denied error that names the table.
tx_check_permission :: proc(tx: ^Tx, table_name, action: string) -> Error {
	if tx != nil {
		if refusal := client_authority_check(tx.store, table_name); refusal.kind != .None do return refusal
	}
	allowed, err := permission_allows(tx, table_name, action)
	if err.kind != .None do return err
	if allowed do return ERROR_NONE
	return errf(.Permission_Denied, "the current identity may not %s %s", action, table_name)
}
