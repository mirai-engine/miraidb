package engine

import "core:fmt"
import "core:strings"

// CREATE TABLE name AS SELECT ...: a table with one column per result column,
// filled with the query's rows. As in SQLite, the columns are named after the
// result columns (a repeated name gets ":1", ":2", ...), each is declared with
// its expression's affinity (INT, TEXT, REAL, NUM, or no type) and nothing
// else, and the table keeps the text SQLite writes for it, not the statement:
//
//	CREATE TABLE v(a INT,b TEXT)
//
// or, once the text would reach 50 characters, one column per line.

// SQLITE_KEYWORDS are SQLite's keywords in the order its own table lists them
// (keywordhash.h): sqlite3_keyword_name(i) names the same word SQLite does, and
// a name that is one of them is written quoted.
SQLITE_KEYWORDS := [147]string {
	"REINDEX", "INDEXED", "INDEX", "DESC", "ESCAPE", "EACH", "CHECK", "KEY", "BEFORE", "FOREIGN", "FOR",
	"IGNORE", "REGEXP", "EXPLAIN", "INSTEAD", "ADD", "DATABASE", "AS", "SELECT", "TABLE", "LEFT", "THEN",
	"END", "DEFERRABLE", "ELSE", "EXCLUDE", "DELETE", "TEMPORARY", "TEMP", "OR", "ISNULL", "NULLS",
	"SAVEPOINT", "INTERSECT", "TIES", "NOTNULL", "NOT", "NO", "NULL", "LIKE", "EXCEPT", "TRANSACTION",
	"ACTION", "ON", "NATURAL", "ALTER", "RAISE", "EXCLUSIVE", "EXISTS", "CONSTRAINT", "INTO", "OFFSET",
	"OF", "SET", "TRIGGER", "RANGE", "GENERATED", "DETACH", "HAVING", "GLOB", "BEGIN", "INNER",
	"REFERENCES", "UNIQUE", "QUERY", "WITHOUT", "WITH", "OUTER", "RELEASE", "ATTACH", "BETWEEN",
	"NOTHING", "GROUPS", "GROUP", "CASCADE", "ASC", "DEFAULT", "CASE", "COLLATE", "CREATE",
	"CURRENT_DATE", "IMMEDIATE", "JOIN", "INSERT", "MATCH", "PLAN", "ANALYZE", "PRAGMA", "MATERIALIZED",
	"DEFERRED", "DISTINCT", "IS", "UPDATE", "VALUES", "VIRTUAL", "ALWAYS", "WHEN", "WHERE", "RECURSIVE",
	"ABORT", "AFTER", "RENAME", "AND", "DROP", "PARTITION", "AUTOINCREMENT", "TO", "IN", "CAST",
	"COLUMN", "COMMIT", "CONFLICT", "CROSS", "CURRENT_TIMESTAMP", "CURRENT_TIME", "CURRENT",
	"PRECEDING", "FAIL", "LAST", "FILTER", "REPLACE", "FIRST", "FOLLOWING", "FROM", "FULL", "LIMIT",
	"IF", "ORDER", "RESTRICT", "OTHERS", "OVER", "RETURNING", "RIGHT", "ROLLBACK", "ROWS", "ROW",
	"UNBOUNDED", "UNION", "USING", "VACUUM", "VIEW", "WINDOW", "DO", "BY", "INITIALLY", "ALL", "PRIMARY",
}

// sqlite_is_keyword answers whether a word is one of SQLite's keywords, in
// any case.
sqlite_is_keyword :: proc(word: string) -> bool {
	for keyword in SQLITE_KEYWORDS {
		if strings.equal_fold(keyword, word) do return true
	}
	return false
}

// sqlite_ident_put writes a name as SQLite's identPut does: bare when it is
// letters, digits and underscores not starting with a digit and not a
// keyword, else in double quotes with its quotes doubled.
@(private)
sqlite_ident_put :: proc(builder: ^strings.Builder, name: string) {
	plain := len(name) > 0 && !(name[0] >= '0' && name[0] <= '9') && !sqlite_is_keyword(name)
	for i in 0 ..< len(name) {
		c := name[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') {
			plain = false
			break
		}
	}
	if plain {
		strings.write_string(builder, name)
		return
	}
	strings.write_byte(builder, '"')
	for i in 0 ..< len(name) {
		if name[i] == '"' do strings.write_byte(builder, '"')
		strings.write_byte(builder, name[i])
	}
	strings.write_byte(builder, '"')
}

// sqlite_affinity_spelling is the type SQLite writes for an affinity read from a
// declared type by its five rules: " INT", " TEXT", " REAL", " NUM", or
// nothing for a column without one (BLOB).
@(private)
sqlite_affinity_spelling :: proc(declared: string) -> string {
	if len(declared) == 0 do return ""
	upper := strings.to_upper(declared, context.temp_allocator)
	if strings.contains(upper, "INT") do return " INT"
	if strings.contains(upper, "CHAR") || strings.contains(upper, "CLOB") || strings.contains(upper, "TEXT") do return " TEXT"
	if strings.contains(upper, "BLOB") do return ""
	if strings.contains(upper, "REAL") || strings.contains(upper, "FLOA") || strings.contains(upper, "DOUB") do return " REAL"
	return " NUM"
}

// sqlite_create_as_text is the CREATE TABLE text SQLite writes for a table
// made from a query (createTableStmt in its build.c).
@(private)
sqlite_create_as_text :: proc(name: string, columns: []string, types: []string, alloc := context.allocator) -> string {
	ident_length :: proc(name: string) -> int {
		n := 2
		for i in 0 ..< len(name) {
			n += name[i] == '"' ? 2 : 1
		}
		return n
	}
	n := ident_length(name)
	for column in columns do n += ident_length(column) + 5
	separator, between, closing := "", ",", ")"
	if n >= 50 do separator, between, closing = "\n  ", ",\n  ", "\n)"
	builder := strings.builder_make(alloc)
	strings.write_string(&builder, "CREATE TABLE ")
	sqlite_ident_put(&builder, name)
	strings.write_byte(&builder, '(')
	for column, i in columns {
		strings.write_string(&builder, i == 0 ? separator : between)
		sqlite_ident_put(&builder, column)
		strings.write_string(&builder, types[i])
	}
	strings.write_string(&builder, closing)
	return strings.to_string(builder)
}

// sql_exec_create_table_as runs CREATE TABLE ... AS SELECT: the query once,
// then the table its columns describe, then its rows.
sql_exec_create_table_as :: proc(tx: ^Tx, stmt: Create_Table_Stmt, params: []Value) -> (Sql_Result, Error) {
	_, view_exists := view_sql(tx, stmt.name)
	if tx_table_probe(tx, stmt.name) != nil || view_exists {
		if stmt.if_not_exists do return Sql_Result{kind = .Ack, message = result_own("table already exists")}, ERROR_NONE
		return {}, errf(.Table_Exists, "table %s already exists", stmt.name)
	}
	result, select_err := sql_exec_select(tx, stmt.as_select^, params)
	if select_err.kind != .None do return {}, select_err
	defer sql_result_destroy(&result)

	// The names, a repeated one numbered as SQLite numbers it.
	columns := make([]string, len(result.columns), context.temp_allocator)
	for name, i in result.columns {
		candidate := name
		count := 0
		for {
			taken := false
			for other in columns[:i] {
				if strings.equal_fold(other, candidate) {
					taken = true
					break
				}
			}
			if !taken do break
			count += 1
			candidate = fmt.tprintf("%s:%d", name, count)
		}
		columns[i] = candidate
	}
	types := make([]string, len(columns), context.temp_allocator)
	declared := sql_describe_declared(tx, stmt.as_select^)
	for _, i in columns {
		types[i] = i < len(declared) ? sqlite_affinity_spelling(declared[i]) : ""
	}

	text := sqlite_create_as_text(stmt.name, columns, types, context.temp_allocator)
	created, create_err := sql_execute_in_tx(tx, text)
	if create_err.kind != .None do return {}, create_err
	sql_result_destroy(&created)
	if len(result.rows) > 0 {
		insert := strings.builder_make(context.temp_allocator)
		strings.write_string(&insert, "INSERT INTO ")
		sqlite_ident_put(&insert, stmt.name)
		strings.write_string(&insert, " VALUES (")
		for _, i in columns {
			strings.write_string(&insert, i == 0 ? "?" : ", ?")
		}
		strings.write_byte(&insert, ')')
		for row in result.rows {
			inserted, insert_err := sql_execute_in_tx_params(tx, strings.to_string(insert), row)
			if insert_err.kind != .None do return {}, insert_err
			sql_result_destroy(&inserted)
		}
	}
	return Sql_Result{kind = .Ack}, ERROR_NONE
}
