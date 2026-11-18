package engine

// JSONB is SQLite's binary form of a JSON document (https://sqlite.org/jsonb.html).
// Each element is a header and a payload. The low four bits of the header's first
// byte are the element's type; the high four are the payload's size when it is 0
// to 11, or say that the size follows in 1, 2, 4 or 8 big-endian bytes (12 to 15).
// A number or a string keeps its text as the payload; an array's payload is its
// elements, an object's its keys and values in turn.
//
// The jsonb_* functions answer what their json_* counterparts answer, in this
// form, and every JSON function reads a document given in it. The encoder writes
// the smallest header for each size, as SQLite does for a document it builds, so
// jsonb() of a JSON text is SQLite's bytes. One difference stays: a string the
// text wrote with an escape SQLite could keep as it is (`"A"`) is stored
// with the escape by SQLite and as the character here; both read back the same.

import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

JSONB_NULL :: 0
JSONB_TRUE :: 1
JSONB_FALSE :: 2
JSONB_INT :: 3
JSONB_INT5 :: 4
JSONB_FLOAT :: 5
JSONB_FLOAT5 :: 6
JSONB_TEXT :: 7
JSONB_TEXTJ :: 8
JSONB_TEXT5 :: 9
JSONB_TEXTRAW :: 10
JSONB_ARRAY :: 11
JSONB_OBJECT :: 12

// jsonb_encode writes a document in JSONB.
jsonb_encode :: proc(value: Json_Value, alloc: mem.Allocator) -> []u8 {
	out := make([dynamic]u8, 0, 16, alloc)
	jsonb_append(&out, value)
	return out[:]
}

@(private)
jsonb_header :: proc(out: ^[dynamic]u8, type: u8, size: int) {
	switch {
	case size <= 11:
		append(out, type | u8(size) << 4)
	case size <= 0xff:
		append(out, type | 0xc0, u8(size))
	case size <= 0xffff:
		append(out, type | 0xd0, u8(size >> 8), u8(size))
	case:
		append(out, type | 0xe0, u8(size >> 24), u8(size >> 16), u8(size >> 8), u8(size))
	}
}

@(private)
jsonb_text_node :: proc(out: ^[dynamic]u8, text: string) {
	// A string with nothing to escape is plain text; one with something is
	// stored escaped, the way JSON writes it.
	builder := strings.builder_make(context.temp_allocator)
	json_write_string(&builder, text)
	written := strings.to_string(builder)
	escaped := written[1:len(written) - 1]
	if escaped == text {
		jsonb_header(out, JSONB_TEXT, len(text))
		append(out, ..transmute([]u8)text)
	} else {
		jsonb_header(out, JSONB_TEXTJ, len(escaped))
		append(out, ..transmute([]u8)escaped)
	}
}

@(private)
jsonb_append :: proc(out: ^[dynamic]u8, value: Json_Value) {
	switch value.kind {
	case .Null:
		append(out, JSONB_NULL)
	case .Bool:
		append(out, value.boolean ? JSONB_TRUE : JSONB_FALSE)
	case .Number:
		text := json_write(value, context.temp_allocator)
		jsonb_header(out, value.is_integer ? JSONB_INT : JSONB_FLOAT, len(text))
		append(out, ..transmute([]u8)text)
	case .String:
		jsonb_text_node(out, value.text)
	case .Array, .Object:
		payload := make([dynamic]u8, 0, 16, context.temp_allocator)
		if value.kind == .Array {
			for item in value.items do jsonb_append(&payload, item)
		} else {
			for key, i in value.keys {
				jsonb_text_node(&payload, key)
				jsonb_append(&payload, value.values[i])
			}
		}
		jsonb_header(out, value.kind == .Array ? JSONB_ARRAY : JSONB_OBJECT, len(payload))
		append(out, ..payload[:])
	}
}

// jsonb_decode reads a JSONB document; false when the bytes are not one, so a
// BLOB that is not JSONB is not mistaken for a document.
jsonb_decode :: proc(data: []u8, alloc: mem.Allocator) -> (Json_Value, bool) {
	if len(data) == 0 do return {}, false
	value, next, ok := jsonb_node(data, 0, 0, alloc)
	if !ok || next != len(data) {
		if ok do json_destroy(value, alloc)
		return {}, false
	}
	return value, true
}

// jsonb_size reads the header at `at`: the type, how many bytes the header
// takes and how many the payload does.
@(private)
jsonb_size :: proc(data: []u8, at: int) -> (type: u8, header: int, size: int, ok: bool) {
	if at >= len(data) do return
	first := data[at]
	type = first & 0x0f
	code := int(first >> 4)
	if code <= 11 do return type, 1, code, true
	extra := 1 << uint(code - 12) // 1, 2, 4 or 8 bytes
	if at + 1 + extra > len(data) do return
	for i in 0 ..< extra {
		if size > (max(int) >> 8) do return
		size = size << 8 | int(data[at + 1 + i])
	}
	return type, 1 + extra, size, true
}

@(private)
jsonb_node :: proc(data: []u8, at: int, depth: int, alloc: mem.Allocator) -> (value: Json_Value, next: int, ok: bool) {
	if depth > JSON_MAX_DEPTH do return
	type, header, size, size_ok := jsonb_size(data, at)
	if !size_ok do return
	start := at + header
	end := start + size
	if end > len(data) || end < start do return
	payload := string(data[start:end])
	switch type {
	case JSONB_NULL, JSONB_TRUE, JSONB_FALSE:
		if size != 0 do return
		if type == JSONB_NULL do return Json_Value{kind = .Null}, end, true
		return Json_Value{kind = .Bool, boolean = type == JSONB_TRUE}, end, true
	case JSONB_INT, JSONB_FLOAT:
		parser := Json_Parser{text = payload, alloc = alloc}
		number := json_parse_value(&parser, 0)
		if parser.failed || parser.at != len(payload) || number.kind != .Number do return
		return number, end, true
	case JSONB_INT5:
		// JSON5's hexadecimal integer: the document reads it as its value.
		text := payload
		negative := false
		if len(text) > 0 && (text[0] == '-' || text[0] == '+') {
			negative = text[0] == '-'
			text = text[1:]
		}
		if len(text) < 3 || text[0] != '0' || (text[1] != 'x' && text[1] != 'X') do return
		parsed, parsed_ok := strconv.parse_u64_of_base(text[2:], 16)
		if !parsed_ok do return
		number := negative ? -f64(parsed) : f64(parsed)
		return Json_Value{kind = .Number, number = number, is_integer = true}, end, true
	case JSONB_FLOAT5:
		// JSON5's other numbers: a leading or trailing point, a sign, Infinity.
		text := payload
		if len(text) > 0 && text[0] == '+' do text = text[1:]
		negative := len(text) > 0 && text[0] == '-'
		body := negative ? text[1:] : text
		if body == "Infinity" || body == "Inf" {
			return Json_Value{kind = .Number, number = math.inf_f64(negative ? -1 : 1)}, end, true
		}
		if body == "NaN" do return Json_Value{kind = .Null}, end, true
		parsed, parsed_ok := strconv.parse_f64(text)
		if !parsed_ok do return
		return Json_Value{kind = .Number, number = parsed}, end, true
	case JSONB_TEXT, JSONB_TEXTRAW:
		return Json_Value{kind = .String, text = strings.clone(payload, alloc)}, end, true
	case JSONB_TEXTJ, JSONB_TEXT5:
		quoted := strings.concatenate({"\"", payload, "\""}, context.temp_allocator)
		parser := Json_Parser{text = quoted, alloc = alloc}
		text := json_parse_value(&parser, 0)
		if parser.failed || parser.at != len(quoted) || text.kind != .String do return
		return text, end, true
	case JSONB_ARRAY:
		items := make([dynamic]Json_Value, 0, 4, alloc)
		cursor := start
		for cursor < end {
			item, after, item_ok := jsonb_node(data[:end], cursor, depth + 1, alloc)
			if !item_ok {
				json_destroy(Json_Value{kind = .Array, items = items[:]}, alloc)
				return
			}
			append(&items, item)
			cursor = after
		}
		return Json_Value{kind = .Array, items = items[:]}, end, true
	case JSONB_OBJECT:
		keys := make([dynamic]string, 0, 4, alloc)
		values := make([dynamic]Json_Value, 0, 4, alloc)
		cursor := start
		for cursor < end {
			key_type, _, _, key_ok := jsonb_size(data, cursor)
			key, after_key, decoded := jsonb_node(data[:end], cursor, depth + 1, alloc)
			if !key_ok || !decoded || key_type < JSONB_TEXT || key_type > JSONB_TEXTRAW || after_key >= end {
				if decoded do json_destroy(key, alloc)
				json_destroy(Json_Value{kind = .Object, keys = keys[:], values = values[:]}, alloc)
				return
			}
			item, after, item_ok := jsonb_node(data[:end], after_key, depth + 1, alloc)
			if !item_ok {
				json_destroy(key, alloc)
				json_destroy(Json_Value{kind = .Object, keys = keys[:], values = values[:]}, alloc)
				return
			}
			append(&keys, key.text)
			append(&values, item)
			cursor = after
		}
		return Json_Value{kind = .Object, keys = keys[:], values = values[:]}, end, true
	}
	return
}

// jsonb_value is a document's JSONB as a BLOB value.
jsonb_value :: proc(value: Json_Value, alloc: mem.Allocator) -> Value {
	return value_bytes(jsonb_encode(value, alloc))
}

// jsonb_from_text turns a JSON function's text answer into JSONB; NULL stays.
jsonb_from_text :: proc(result: Value) -> (Value, Error) {
	if result.kind != .String do return result, ERROR_NONE
	doc, ok := json_parse(result.s, context.temp_allocator)
	if !ok do return {}, errf(.Invalid_Argument, "malformed JSON")
	return jsonb_value(doc, context.allocator), ERROR_NONE
}
