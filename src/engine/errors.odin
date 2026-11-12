package engine

import "core:fmt"

// Error_Kind classifies every failure the engine reports. The messages are for
// humans; callers branch on the kind.
Error_Kind :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Argument,
	Invalid_Type,
	Table_Not_Found,
	Table_Exists,
	Column_Not_Found,
	Index_Exists,
	Index_Not_Found,
	No_Primary_Key,
	Duplicate_Primary_Key,
	Duplicate_Unique,
	Not_Null_Violation,
	Auto_Increment_Requires_Integer,
	Sql_Syntax,
	Sql_Unsupported,
	Sql_Not_A_Query,
	Transaction_Closed,
	Transaction_Read_Only,
	Io,
	Corrupt_Log,
	Format_Too_New,
	Permission_Denied,
	Cancelled,
	Quota_Exceeded,
	// Locked means another process owns the database directory.
	Locked,
	// Incomplete means a framed message stopped before its end: a socket loop
	// must read more bytes rather than treat it as a malformed request.
	Incomplete,
	Internal,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

ERROR_NONE :: Error{kind = .None}

error_ok :: proc(err: Error) -> bool {
	return err.kind == .None
}

// errf builds an Error with a formatted message. The message is owned by the
// heap and lives as long as the caller keeps it.
errf :: proc(kind: Error_Kind, format: string, args: ..any) -> Error {
	return Error {
		kind = kind,
		message = fmt.aprintf(format, ..args),
	}
}

// error_kind_name is the stable, machine friendly name of a kind. It is used by
// tests and by the CLI's error output.
error_kind_name :: proc(kind: Error_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Out_Of_Memory:
		return "out_of_memory"
	case .Invalid_Argument:
		return "invalid_argument"
	case .Invalid_Type:
		return "invalid_type"
	case .Table_Not_Found:
		return "table_not_found"
	case .Table_Exists:
		return "table_exists"
	case .Column_Not_Found:
		return "column_not_found"
	case .Index_Exists:
		return "index_exists"
	case .Index_Not_Found:
		return "index_not_found"
	case .No_Primary_Key:
		return "no_primary_key"
	case .Duplicate_Primary_Key:
		return "duplicate_primary_key"
	case .Duplicate_Unique:
		return "duplicate_unique"
	case .Not_Null_Violation:
		return "not_null_violation"
	case .Auto_Increment_Requires_Integer:
		return "auto_increment_requires_integer"
	case .Sql_Syntax:
		return "sql_syntax"
	case .Sql_Unsupported:
		return "sql_unsupported"
	case .Sql_Not_A_Query:
		return "sql_not_a_query"
	case .Transaction_Closed:
		return "transaction_closed"
	case .Transaction_Read_Only:
		return "transaction_read_only"
	case .Io:
		return "io"
	case .Corrupt_Log:
		return "corrupt_log"
	case .Format_Too_New:
		return "format_too_new"
	case .Permission_Denied:
		return "permission_denied"
	case .Cancelled:
		return "cancelled"
	case .Quota_Exceeded:
		return "quota_exceeded"
	case .Locked:
		return "locked"
	case .Incomplete:
		return "incomplete"
	case .Internal:
		return "internal"
	}
	return "unknown"
}
