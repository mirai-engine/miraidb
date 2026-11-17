package engine

import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"

// COPY moves rows between a table and the two text formats PostgreSQL defines:
// the text format (tab separated, `\N` for NULL, backslash escapes) and CSV. The
// statement itself is in sql_ast.odin; this file reads and writes it, and the
// front ends (the CLI and the wire) supply or consume the bytes for STDIN and
// STDOUT.

// copy_delimiter is the field separator, `\t` in the text format and a comma in
// CSV unless the statement names another.
copy_delimiter :: proc(stmt: Copy_Stmt) -> u8 {
	if stmt.delimiter != 0 do return stmt.delimiter
	return stmt.format == .Csv ? ',' : '\t'
}

// Copy_Sink takes one parsed row. The values point into a buffer the scanner
// clears after the call, so a sink that keeps them has to clone them.
Copy_Sink :: proc(ctx: rawptr, fields: []Value) -> Error

// Copy_Scanner splits one row at a time out of a text. It owns the buffers, so a
// caller hands it the whole file (or stream) and sinks each row.
Copy_Scanner :: struct {
	stmt:      Copy_Stmt,
	text:      string,
	offset:    int,
	rows:      int,
	scratch:   [dynamic]u8,
	starts:    [dynamic]int,
	// nulls marks, per field, the ones the format reads as NULL. The text format
	// decides from the raw field, before unescaping; CSV from an unquoted one.
	nulls:     [dynamic]bool,
	alloc:     mem.Allocator,
}

copy_scanner_make :: proc(stmt: Copy_Stmt, text: string, alloc: mem.Allocator) -> Copy_Scanner {
	return Copy_Scanner {
		stmt = stmt,
		text = text,
		scratch = make([dynamic]u8, 0, 256, alloc),
		starts = make([dynamic]int, 0, 8, alloc),
		nulls = make([dynamic]bool, 0, 8, alloc),
		alloc = alloc,
	}
}

// copy_scanner_destroy ends a scanner. Its buffers are arena memory: a scanner
// is made for one statement and goes away with the arena that holds it, so there
// is nothing to free one by one.
copy_scanner_destroy :: proc(scanner: ^Copy_Scanner) {
	scanner^ = {}
}

// copy_scan_next answers the next row, or false at the end of the text.
copy_scan_next :: proc(scanner: ^Copy_Scanner, fields: ^[dynamic]Value) -> (bool, Error) {
	switch scanner.stmt.format {
	case .Text:
		return copy_scan_next_text(scanner, fields)
	case .Csv:
		return copy_scan_next_csv(scanner, fields)
	}
	return false, ERROR_NONE
}

// copy_scan_all runs the whole text through the sink, answering the row count.
copy_scan_all :: proc(
	stmt: Copy_Stmt,
	text: string,
	sink: Copy_Sink,
	ctx: rawptr,
	alloc: mem.Allocator,
) -> (int, Error) {
	scanner := copy_scanner_make(stmt, text, alloc)
	defer copy_scanner_destroy(&scanner)
	fields := make([dynamic]Value, 0, 8, alloc)
	for {
		clear(&fields)
		ok, row_err := copy_scan_next(&scanner, &fields)
		if row_err.kind != .None do return scanner.rows, row_err
		if !ok do break
		if sink_err := sink(ctx, fields[:]); sink_err.kind != .None do return scanner.rows, sink_err
	}
	return scanner.rows, ERROR_NONE
}

// copy_next_line returns one line of `text` from `offset` without its terminator.
// A trailing `\r` is dropped, so a file written on Windows reads the same.
@(private)
copy_next_line :: proc(text: string, from: int) -> (line: string, next: int, ok: bool) {
	if from > len(text) do return "", from, false
	offset := from
	for offset < len(text) && text[offset] != '\n' do offset += 1
	line = text[from:offset]
	if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
	if offset >= len(text) && from >= len(text) do return "", offset, false
	return line, offset + 1, true
}

// copy_fields_from_buffer turns the fields recorded in `starts` into values. The
// field text is the bytes between one start and the next, all of them inside
// `scratch`, which is not touched while they are built.
@(private)
copy_fields_from_buffer :: proc(
	scanner: ^Copy_Scanner,
	fields: ^[dynamic]Value,
) {
	starts := scanner.starts[:]
	for start, i in starts {
		end := i + 1 < len(starts) ? starts[i + 1] : len(scanner.scratch)
		if i < len(scanner.nulls) && scanner.nulls[i] {
			append(fields, value_null())
			continue
		}
		append(fields, value_string(string(scanner.scratch[start:end])))
	}
}

// copy_scan_next_text reads one line of the text format: fields between the
// separator, `null_text` for NULL and a backslash escaping the separator, a
// newline and itself.
@(private)
copy_scan_next_text :: proc(scanner: ^Copy_Scanner, fields: ^[dynamic]Value) -> (bool, Error) {
	line, next, ok := copy_next_line(scanner.text, scanner.offset)
	if !ok do return false, ERROR_NONE
	scanner.offset = next
	if scanner.stmt.header && scanner.rows == 0 {
		scanner.rows += 1
		// The header is not a row: skip it and read the one after it.
		return copy_scan_next_text(scanner, fields)
	}
	delimiter := copy_delimiter(scanner.stmt)
	clear(&scanner.scratch)
	clear(&scanner.starts)
	clear(&scanner.nulls)
	field_start := 0
	for i in 0 ..= len(line) {
		if i < len(line) && line[i] != delimiter do continue
		raw := line[field_start:i]
		append(&scanner.starts, len(scanner.scratch))
		append(&scanner.nulls, raw == scanner.stmt.null_text)
		if raw != scanner.stmt.null_text {
			if _, unescape_err := copy_unescape(&scanner.scratch, raw); unescape_err.kind != .None {
				return false, unescape_err
			}
		}
		field_start = i + 1
	}
	scanner.rows += 1
	copy_fields_from_buffer(scanner, fields)
	return true, ERROR_NONE
}

// copy_unescape appends the unescaped bytes of one text-format field to `dst`.
// PostgreSQL reads `\b \f \n \r \t \v \\` and an octal `\ooo`, and keeps the
// character of any other escape.
@(private)
copy_unescape :: proc(dst: ^[dynamic]u8, field: string) -> (string, Error) {
	start := len(dst)
	i := 0
	for i < len(field) {
		c := field[i]
		i += 1
		if c != '\\' {
			append(dst, c)
			continue
		}
		if i >= len(field) {
			return "", errf(.Invalid_Argument, "COPY: a field ends with a backslash")
		}
		e := field[i]
		i += 1
		switch e {
		case 'b':
			append(dst, 8)
		case 'f':
			append(dst, 12)
		case 'n':
			append(dst, '\n')
		case 'r':
			append(dst, '\r')
		case 't':
			append(dst, '\t')
		case 'v':
			append(dst, 11)
		case '\\':
			append(dst, '\\')
		case '0' ..= '7':
			code := u32(e - '0')
			for _ in 0 ..< 2 {
				if i >= len(field) || field[i] < '0' || field[i] > '7' do break
				code = code * 8 + u32(field[i] - '0')
				i += 1
			}
			if code > 255 {
				return "", errf(.Invalid_Argument, "COPY: the octal escape \\%o is not a byte", code)
			}
			append(dst, u8(code))
		case:
			append(dst, e)
		}
	}
	return string(dst[start:]), ERROR_NONE
}

// copy_scan_next_csv reads one CSV record: quoted fields may hold the separator,
// a quote (written twice) and a newline, an unquoted empty field is NULL where a
// quoted empty field is an empty string.
@(private)
copy_scan_next_csv :: proc(scanner: ^Copy_Scanner, fields: ^[dynamic]Value) -> (bool, Error) {
	text := scanner.text
	if scanner.offset >= len(text) do return false, ERROR_NONE
	delimiter := copy_delimiter(scanner.stmt)
	clear(&scanner.scratch)
	clear(&scanner.starts)
	clear(&scanner.nulls)
	field_start := 0
	quoted := false
	in_quotes := false
	for scanner.offset < len(text) {
		c := text[scanner.offset]
		if in_quotes {
			if c == '"' {
				if scanner.offset + 1 < len(text) && text[scanner.offset + 1] == '"' {
					append(&scanner.scratch, '"')
					scanner.offset += 2
					continue
				}
				in_quotes = false
				scanner.offset += 1
				continue
			}
			append(&scanner.scratch, c)
			scanner.offset += 1
			continue
		}
		switch c {
		case '"':
			if len(scanner.scratch) != field_start {
				return false, errf(.Invalid_Argument, "COPY: a quote inside an unquoted CSV field")
			}
			in_quotes = true
			quoted = true
			scanner.offset += 1
		case delimiter:
			append(&scanner.starts, field_start)
			append(
				&scanner.nulls,
				!quoted && string(scanner.scratch[field_start:]) == scanner.stmt.null_text,
			)
			field_start = len(scanner.scratch)
			quoted = false
			scanner.offset += 1
		case '\r', '\n':
			if c == '\r' && scanner.offset + 1 < len(text) && text[scanner.offset + 1] == '\n' {
				scanner.offset += 1
			}
			scanner.offset += 1
			append(&scanner.starts, field_start)
			append(
				&scanner.nulls,
				!quoted && string(scanner.scratch[field_start:]) == scanner.stmt.null_text,
			)
			scanner.rows += 1
			if scanner.stmt.header && scanner.rows == 1 {
				// The header names the columns; skip it and read the next record.
				clear(&scanner.scratch)
				clear(&scanner.starts)
				clear(&scanner.nulls)
				field_start = 0
				quoted = false
				return copy_scan_next_csv(scanner, fields)
			}
			copy_fields_from_buffer(scanner, fields)
			return true, ERROR_NONE
		case:
			append(&scanner.scratch, c)
			scanner.offset += 1
		}
	}
	if in_quotes {
		return false, errf(.Invalid_Argument, "COPY: the last CSV field is not closed")
	}
	// A last record without a newline after it.
	if scanner.offset >= len(text) && (len(scanner.scratch) > field_start || len(scanner.starts) > 0 || quoted) {
		append(&scanner.starts, field_start)
		append(
			&scanner.nulls,
			!quoted && string(scanner.scratch[field_start:]) == scanner.stmt.null_text,
		)
		scanner.rows += 1
		if scanner.stmt.header && scanner.rows == 1 do return false, ERROR_NONE
		copy_fields_from_buffer(scanner, fields)
		return true, ERROR_NONE
	}
	return false, ERROR_NONE
}

// Copy_Writer formats rows the other way, into the text or CSV form. It keeps a
// builder and appends one row per call.
Copy_Writer :: struct {
	stmt:    Copy_Stmt,
	builder: strings.Builder,
	alloc:   mem.Allocator,
}

copy_writer_make :: proc(stmt: Copy_Stmt, columns: []string, alloc: mem.Allocator) -> Copy_Writer {
	writer := Copy_Writer {
		stmt  = stmt,
		alloc = alloc,
	}
	writer.builder = strings.builder_make(alloc)
	if stmt.format == .Csv && stmt.header {
		delimiter := copy_delimiter(stmt)
		for name, i in columns {
			if i > 0 do strings.write_byte(&writer.builder, delimiter)
			copy_writer_write_csv(&writer.builder, name, delimiter)
		}
		strings.write_byte(&writer.builder, '\n')
	}
	return writer
}

copy_writer_destroy :: proc(writer: ^Copy_Writer) {
	strings.builder_destroy(&writer.builder)
}

// copy_writer_row appends one row, in the format the statement asked for.
copy_writer_row :: proc(writer: ^Copy_Writer, values: []Value) {
	delimiter := copy_delimiter(writer.stmt)
	for value, i in values {
		if i > 0 do strings.write_byte(&writer.builder, delimiter)
		if value.kind == .Null {
			strings.write_string(&writer.builder, writer.stmt.null_text)
			continue
		}
		// PostgreSQL's text formats render a bool as `t` or `f` and an array
		// between braces: the wire's text form is the same one.
		text := pg_text_value(value, writer.alloc)
		switch writer.stmt.format {
		case .Text:
			copy_write_text_field(&writer.builder, text, delimiter)
		case .Csv:
			copy_writer_write_csv(&writer.builder, text, delimiter)
		}
	}
	strings.write_byte(&writer.builder, '\n')
}

// copy_write_text_field writes a text-format field, escaping the separator, a
// newline, a carriage return and the backslash itself.
@(private)
copy_write_text_field :: proc(builder: ^strings.Builder, text: string, delimiter: u8) {
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			if c == delimiter do strings.write_byte(builder, '\\')
			strings.write_byte(builder, c)
		}
	}
}

// copy_writer_write_csv writes a CSV field, quoting it when it holds the
// separator, a quote or a newline. An empty string is quoted so it does not read
// back as NULL.
@(private)
copy_writer_write_csv :: proc(builder: ^strings.Builder, text: string, delimiter: u8) {
	quote := len(text) == 0
	for i in 0 ..< len(text) {
		c := text[i]
		if c == delimiter || c == '"' || c == '\n' || c == '\r' {
			quote = true
			break
		}
	}
	if !quote {
		strings.write_string(builder, text)
		return
	}
	strings.write_byte(builder, '"')
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '"' do strings.write_byte(builder, '"')
		strings.write_byte(builder, c)
	}
	strings.write_byte(builder, '"')
}

// copy_column_count is how many columns the statement copies: the ones it names,
// or the table's. The wire answers a COPY with this count, so a driver knows what
// to expect.
copy_column_count :: proc(tx: ^Tx, stmt: Copy_Stmt) -> int {
	if len(stmt.columns) > 0 do return len(stmt.columns)
	if table := tx_table_probe(tx, stmt.table); table != nil do return len(table.schema.columns)
	return 0
}

// copy_rows_to_text renders the table's rows in the statement's format. The
// columns are the ones the statement names, or every column in schema order.
copy_rows_to_text :: proc(tx: ^Tx, stmt: Copy_Stmt, alloc: mem.Allocator) -> (string, int, Error) {
	table, table_err := tx_table(tx, stmt.table)
	if table_err.kind != .None do return "", 0, table_err
	positions: []int
	names: []string
	if len(stmt.columns) == 0 {
		positions = make([]int, len(table.schema.columns), tx.alloc)
		names = make([]string, len(table.schema.columns), tx.alloc)
		for column, i in table.schema.columns {
			positions[i] = i
			names[i] = column.name
		}
	} else {
		positions = make([]int, len(stmt.columns), tx.alloc)
		names = make([]string, len(stmt.columns), tx.alloc)
		for name, i in stmt.columns {
			index, found := schema_column_index(&table.schema, name)
			if !found {
				return "", 0, errf(
					.Column_Not_Found,
					"column %s does not exist in %s",
					name,
					stmt.table,
				)
			}
			positions[i] = index
			names[i] = table.schema.columns[index].name
		}
	}
	rows := make([dynamic]Row, 0, 64, tx.alloc)
	if collect_err := tx_collect(tx, stmt.table, &rows); collect_err.kind != .None {
		return "", 0, collect_err
	}
	writer := copy_writer_make(stmt, names, alloc)
	projected := make([]Value, len(positions), tx.alloc)
	for row in rows {
		for position, i in positions do projected[i] = row.values[position]
		copy_writer_row(&writer, projected)
	}
	text := strings.to_string(writer.builder)
	text = strings.clone(text, alloc)
	_ = writer
	return text, len(rows), ERROR_NONE
}

// Copy_Sink_State is the sink the executor installs: it inserts one parsed row
// through the same path INSERT uses, so coercion, defaults, generated columns,
// constraints, policies and triggers all apply.
@(private)
Copy_Sink_State :: struct {
	tx:   ^Tx,
	stmt: Copy_Stmt,
	row:  int,
}

@(private)
copy_insert_sink :: proc(ctx: rawptr, fields: []Value) -> Error {
	state := cast(^Copy_Sink_State)ctx
	table, table_err := tx_table(state.tx, state.stmt.table)
	if table_err.kind != .None do return table_err
	expected := len(state.stmt.columns)
	if expected == 0 do expected = len(table.schema.columns)
	if len(fields) != expected {
		return errf(
			.Invalid_Argument,
			"COPY row %d has %d fields, %s expects %d",
			state.row + 1,
			len(fields),
			state.stmt.table,
			expected,
		)
	}
	// COPY carries text: each field is parsed against the type of its column, as
	// PostgreSQL does, so `2` reaches an INTEGER column as 2 and not as "2".
	positions := make([]int, len(fields), state.tx.alloc)
	if len(state.stmt.columns) == 0 {
		for i in 0 ..< len(fields) do positions[i] = i
	} else {
		for name, i in state.stmt.columns {
			index, found := schema_column_index(&table.schema, name)
			if !found {
				return errf(.Column_Not_Found, "column %s does not exist in %s", name, state.stmt.table)
			}
			positions[i] = index
		}
	}
	exprs := make([]^Expr, len(fields), state.tx.alloc)
	for value, i in fields {
		converted := value
		if value.kind != .Null {
			column := table.schema.columns[positions[i]]
			converted_value, cast_err := value_cast(value, column.type)
			if cast_err.kind != .None {
				wrapped := errf(
					cast_err.kind,
					"COPY row %d, column %s: %s",
					state.row + 1,
					column.name,
					cast_err.message,
				)
				error_free(&cast_err)
				return wrapped
			}
			converted = converted_value
		}
		literal := new(Expr, state.tx.alloc)
		literal^ = Literal_Expr{value = converted}
		exprs[i] = literal
	}
	insert := Insert_Stmt {
		table   = state.stmt.table,
		columns = state.stmt.columns,
		rows    = [][]^Expr{exprs},
	}
	result, insert_err := sql_exec_insert(state.tx, insert, nil)
	if insert_err.kind != .None {
		wrapped := errf(insert_err.kind, "COPY row %d: %s", state.row + 1, insert_err.message)
		error_free(&insert_err)
		return wrapped
	}
	state.row += 1
	sql_result_destroy(&result)
	return ERROR_NONE
}

// copy_insert reads `text` and inserts every row it holds, answering the count.
copy_insert :: proc(tx: ^Tx, stmt: Copy_Stmt, text: string) -> (int, Error) {
	temp: virtual.Arena
	if init_err := virtual.arena_init_growing(&temp); init_err != nil {
		return 0, errf(.Out_Of_Memory, "COPY: %v", init_err)
	}
	defer virtual.arena_destroy(&temp)
	state := Copy_Sink_State {
		tx   = tx,
		stmt = stmt,
	}
	_, scan_err := copy_scan_all(stmt, text, copy_insert_sink, &state, virtual.arena_allocator(&temp))
	if scan_err.kind != .None do return state.row, scan_err
	return state.row, ERROR_NONE
}

// copy_file_insert runs COPY ... FROM 'path'.
copy_file_insert :: proc(tx: ^Tx, stmt: Copy_Stmt) -> (int, Error) {
	data, read_err := os.read_entire_file(stmt.path, tx.alloc)
	if read_err != nil {
		return 0, errf(.Io, "cannot read %s: %v", stmt.path, read_err)
	}
	return copy_insert(tx, stmt, string(data))
}

// copy_file_write runs COPY ... TO 'path'.
copy_file_write :: proc(tx: ^Tx, stmt: Copy_Stmt) -> (int, Error) {
	text, count, text_err := copy_rows_to_text(tx, stmt, tx.alloc)
	if text_err.kind != .None do return 0, text_err
	write_err := os.write_entire_file(stmt.path, transmute([]u8)text)
	if write_err != nil {
		return 0, errf(.Io, "cannot write %s: %v", stmt.path, write_err)
	}
	return count, ERROR_NONE
}
