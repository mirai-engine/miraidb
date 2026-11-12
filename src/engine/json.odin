package engine

// JSON support: a small parser for the text form, the writers the functions
// return, and the dispatcher the expression evaluator calls.
//
// The tree owns its strings and arrays; json_destroy releases them. The text a
// function returns is owned by the caller, like every other SQL result.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

Json_Kind :: enum {
	Null,
	Bool,
	Number,
	String,
	Array,
	Object,
}

Json_Value :: struct {
	kind:    Json_Kind,
	boolean: bool,
	number:  f64,
	text:    string,
	items:   []Json_Value,
	keys:    []string,
	values:  []Json_Value,
}

Json_Parser :: struct {
	text:   string,
	at:     int,
	alloc:  mem.Allocator,
	failed: bool,
}

json_parse :: proc(text: string, alloc: mem.Allocator) -> (Json_Value, bool) {
	parser := Json_Parser{text = text, alloc = alloc}
	json_skip_space(&parser)
	value := json_parse_value(&parser, 0)
	json_skip_space(&parser)
	if parser.failed || parser.at != len(parser.text) {
		json_destroy(value, alloc)
		return {}, false
	}
	return value, true
}

@(private)
json_skip_space :: proc(p: ^Json_Parser) {
	for p.at < len(p.text) {
		switch p.text[p.at] {
		case ' ', '\t', '\n', '\r':
			p.at += 1
		case:
			return
		}
	}
}

@(private)
json_parse_value :: proc(p: ^Json_Parser, depth: int) -> Json_Value {
	if p.failed || depth > JSON_MAX_DEPTH || p.at >= len(p.text) {
		p.failed = true
		return {}
	}
	switch p.text[p.at] {
	case '{':
		return json_parse_object(p, depth)
	case '[':
		return json_parse_array(p, depth)
	case '"':
		text, ok := json_parse_string(p)
		if !ok {
			p.failed = true
			return {}
		}
		return Json_Value{kind = .String, text = text}
	case 't':
		if strings.has_prefix(p.text[p.at:], "true") {
			p.at += 4
			return Json_Value{kind = .Bool, boolean = true}
		}
	case 'f':
		if strings.has_prefix(p.text[p.at:], "false") {
			p.at += 5
			return Json_Value{kind = .Bool, boolean = false}
		}
	case 'n':
		if strings.has_prefix(p.text[p.at:], "null") {
			p.at += 4
			return Json_Value{kind = .Null}
		}
	}
	number, ok := json_parse_number(p)
	if !ok {
		p.failed = true
		return {}
	}
	return Json_Value{kind = .Number, number = number}
}

JSON_MAX_DEPTH :: 64

@(private)
json_parse_number :: proc(p: ^Json_Parser) -> (f64, bool) {
	start := p.at
	if p.at < len(p.text) && p.text[p.at] == '-' do p.at += 1
	digits := 0
	for p.at < len(p.text) && p.text[p.at] >= '0' && p.text[p.at] <= '9' {
		p.at += 1
		digits += 1
	}
	if digits == 0 do return 0, false
	if p.at < len(p.text) && p.text[p.at] == '.' {
		p.at += 1
		fraction := 0
		for p.at < len(p.text) && p.text[p.at] >= '0' && p.text[p.at] <= '9' {
			p.at += 1
			fraction += 1
		}
		if fraction == 0 do return 0, false
	}
	if p.at < len(p.text) && (p.text[p.at] == 'e' || p.text[p.at] == 'E') {
		p.at += 1
		if p.at < len(p.text) && (p.text[p.at] == '+' || p.text[p.at] == '-') do p.at += 1
		exponent := 0
		for p.at < len(p.text) && p.text[p.at] >= '0' && p.text[p.at] <= '9' {
			p.at += 1
			exponent += 1
		}
		if exponent == 0 do return 0, false
	}
	number: f64
	text := p.text[start:p.at]
	if parsed, ok := parse_time_number(text); ok {
		number = parsed
	} else {
		return 0, false
	}
	return number, true
}

@(private)
json_parse_string :: proc(p: ^Json_Parser) -> (string, bool) {
	if p.at >= len(p.text) || p.text[p.at] != '"' do return "", false
	p.at += 1
	builder := strings.builder_make(p.alloc)
	for p.at < len(p.text) {
		c := p.text[p.at]
		if c == '"' {
			p.at += 1
			return strings.to_string(builder), true
		}
		if c == '\\' {
			p.at += 1
			if p.at >= len(p.text) do break
			escape := p.text[p.at]
			p.at += 1
			switch escape {
			case '"':
				strings.write_byte(&builder, '"')
			case '\\':
				strings.write_byte(&builder, '\\')
			case '/':
				strings.write_byte(&builder, '/')
			case 'b':
				strings.write_byte(&builder, 8)
			case 'f':
				strings.write_byte(&builder, 12)
			case 'n':
				strings.write_byte(&builder, '\n')
			case 'r':
				strings.write_byte(&builder, '\r')
			case 't':
				strings.write_byte(&builder, '\t')
			case 'u':
				if p.at + 4 > len(p.text) do break
				code := u32(0)
				for i in 0 ..< 4 {
					digit, digit_ok := sql_hex_digit(p.text[p.at + i])
					if !digit_ok {
						strings.builder_destroy(&builder)
						return "", false
					}
					code = code << 4 | u32(digit)
				}
				p.at += 4
				// A high surrogate pairs with the following \u escape.
				if code >= 0xD800 && code <= 0xDBFF && p.at + 6 <= len(p.text) &&
				   p.text[p.at] == '\\' && p.text[p.at + 1] == 'u' {
					low := u32(0)
					valid := true
					for i in 0 ..< 4 {
						digit, digit_ok := sql_hex_digit(p.text[p.at + 2 + i])
						if !digit_ok {
							valid = false
							break
						}
						low = low << 4 | u32(digit)
					}
					if valid && low >= 0xDC00 && low <= 0xDFFF {
						code = 0x10000 + (code - 0xD800) << 10 + (low - 0xDC00)
						p.at += 6
					}
				}
				strings.write_rune(&builder, rune(code))
			case:
				strings.builder_destroy(&builder)
				return "", false
			}
			continue
		}
		if c < 0x20 {
			strings.builder_destroy(&builder)
			return "", false
		}
		// Copy a whole UTF-8 sequence.
		size := utf8.rune_size(rune(p.text[p.at])) if p.text[p.at] < 0x80 else utf8_char_size(p.text[p.at])
		strings.write_string(&builder, p.text[p.at:min(p.at + size, len(p.text))])
		p.at += size
	}
	strings.builder_destroy(&builder)
	return "", false
}

@(private)
utf8_char_size :: proc(lead: u8) -> int {
	switch {
	case lead < 0x80:
		return 1
	case lead >> 5 == 0b110:
		return 2
	case lead >> 4 == 0b1110:
		return 3
	case lead >> 3 == 0b11110:
		return 4
	}
	return 1
}

@(private)
json_parse_array :: proc(p: ^Json_Parser, depth: int) -> Json_Value {
	p.at += 1 // '['
	items := make([dynamic]Json_Value, 0, 4, p.alloc)
	json_skip_space(p)
	if p.at < len(p.text) && p.text[p.at] == ']' {
		p.at += 1
		return Json_Value{kind = .Array, items = items[:]}
	}
	for {
		json_skip_space(p)
		item := json_parse_value(p, depth + 1)
		if p.failed {
			return Json_Value{kind = .Array, items = items[:]}
		}
		append(&items, item)
		json_skip_space(p)
		if p.at >= len(p.text) {
			p.failed = true
			return Json_Value{kind = .Array, items = items[:]}
		}
		if p.text[p.at] == ',' {
			p.at += 1
			continue
		}
		if p.text[p.at] == ']' {
			p.at += 1
			return Json_Value{kind = .Array, items = items[:]}
		}
		p.failed = true
		return Json_Value{kind = .Array, items = items[:]}
	}
}

@(private)
json_parse_object :: proc(p: ^Json_Parser, depth: int) -> Json_Value {
	p.at += 1 // '{'
	keys := make([dynamic]string, 0, 4, p.alloc)
	values := make([dynamic]Json_Value, 0, 4, p.alloc)
	json_skip_space(p)
	if p.at < len(p.text) && p.text[p.at] == '}' {
		p.at += 1
		return Json_Value{kind = .Object, keys = keys[:], values = values[:]}
	}
	for {
		json_skip_space(p)
		key, key_ok := json_parse_string(p)
		if !key_ok {
			p.failed = true
			return Json_Value{kind = .Object, keys = keys[:], values = values[:]}
		}
		json_skip_space(p)
		if p.at >= len(p.text) || p.text[p.at] != ':' {
			p.failed = true
			return Json_Value{kind = .Object, keys = keys[:], values = values[:]}
		}
		p.at += 1
		json_skip_space(p)
		value := json_parse_value(p, depth + 1)
		if p.failed {
			return Json_Value{kind = .Object, keys = keys[:], values = values[:]}
		}
		append(&keys, key)
		append(&values, value)
		json_skip_space(p)
		if p.at >= len(p.text) {
			p.failed = true
			return Json_Value{kind = .Object, keys = keys[:], values = values[:]}
		}
		if p.text[p.at] == ',' {
			p.at += 1
			continue
		}
		if p.text[p.at] == '}' {
			p.at += 1
			return Json_Value{kind = .Object, keys = keys[:], values = values[:]}
		}
		p.failed = true
		return Json_Value{kind = .Object, keys = keys[:], values = values[:]}
	}
}

json_destroy :: proc(value: Json_Value, alloc: mem.Allocator) {
	#partial switch value.kind {
	case .String:
		delete(value.text, alloc)
	case .Array:
		for item in value.items do json_destroy(item, alloc)
		delete(value.items, alloc)
	case .Object:
		for key in value.keys do delete(key, alloc)
		for item in value.values do json_destroy(item, alloc)
		delete(value.keys, alloc)
		delete(value.values, alloc)
	}
}

// --- Writing ---------------------------------------------------------------

json_write :: proc(value: Json_Value, alloc: mem.Allocator) -> string {
	builder := strings.builder_make(alloc)
	json_write_to(&builder, value)
	return strings.to_string(builder)
}

json_write_to :: proc(b: ^strings.Builder, value: Json_Value) {
	switch value.kind {
	case .Null:
		strings.write_string(b, "null")
	case .Bool:
		strings.write_string(b, value.boolean ? "true" : "false")
	case .Number:
		if value.number == math.floor(value.number) && math.abs(value.number) < 1e15 {
			fmt.sbprintf(b, "%d", i64(value.number))
		} else {
			fmt.sbprintf(b, "%v", value.number)
		}
	case .String:
		json_write_string(b, value.text)
	case .Array:
		strings.write_byte(b, '[')
		for item, i in value.items {
			if i > 0 do strings.write_byte(b, ',')
			json_write_to(b, item)
		}
		strings.write_byte(b, ']')
	case .Object:
		strings.write_byte(b, '{')
		for key, i in value.keys {
			if i > 0 do strings.write_byte(b, ',')
			json_write_string(b, key)
			strings.write_byte(b, ':')
			json_write_to(b, value.values[i])
		}
		strings.write_byte(b, '}')
	}
}

json_write_string :: proc(b: ^strings.Builder, text: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

// --- Conversion between SQL values and JSON --------------------------------

json_from_value :: proc(value: Value, alloc: mem.Allocator) -> Json_Value {
	#partial switch value.kind {
	case .Null, .Default:
		return Json_Value{kind = .Null}
	case .Bool:
		return Json_Value{kind = .Bool, boolean = value.b}
	case .Int:
		return Json_Value{kind = .Number, number = f64(value.i)}
	case .Uint:
		return Json_Value{kind = .Number, number = f64(value.u)}
	case .Float:
		return Json_Value{kind = .Number, number = value.f}
	case .String:
		return Json_Value{kind = .String, text = strings.clone(value.s, alloc)}
	}
	text := value_format(value, alloc)
	return Json_Value{kind = .String, text = text}
}

json_to_value :: proc(value: Json_Value, alloc: mem.Allocator) -> Value {
	#partial switch value.kind {
	case .Null:
		return value_null()
	case .Bool:
		return value_bool(value.boolean)
	case .Number:
		if value.number == math.floor(value.number) && math.abs(value.number) < 9.2e18 {
			return value_int(i64(value.number))
		}
		return value_float(value.number)
	case .String:
		return value_string(strings.clone(value.text, alloc))
	}
	text := json_write(value, alloc)
	return value_string(text)
}

// --- Paths -----------------------------------------------------------------

// json_path_find resolves a JSON path such as `$.a[0].b` against a value.
json_path_find :: proc(root: Json_Value, path: string) -> (Json_Value, bool) {
	trimmed := strings.trim_space(path)
	if len(trimmed) == 0 do return root, true
	at := 0
	if trimmed[0] == '$' do at = 1
	current := root
	for at < len(trimmed) {
		switch trimmed[at] {
		case '.':
			at += 1
			start := at
			for at < len(trimmed) && trimmed[at] != '.' && trimmed[at] != '[' do at += 1
			name := trimmed[start:at]
			if current.kind != .Object do return {}, false
			found := false
			for key, i in current.keys {
				if strings.equal_fold(key, name) {
					current = current.values[i]
					found = true
					break
				}
			}
			if !found do return {}, false
		case '[':
			at += 1
			if at < len(trimmed) && trimmed[at] == '"' {
				at += 1
				start := at
				for at < len(trimmed) && trimmed[at] != '"' do at += 1
				name := trimmed[start:at]
				if at < len(trimmed) do at += 1
				if at < len(trimmed) && trimmed[at] == ']' do at += 1
				if current.kind != .Object do return {}, false
				found := false
				for key, i in current.keys {
					if strings.equal_fold(key, name) {
						current = current.values[i]
						found = true
						break
					}
				}
				if !found do return {}, false
				continue
			}
			if at < len(trimmed) && trimmed[at] == '#' {
				at += 1
				if at < len(trimmed) && trimmed[at] == ']' do at += 1
				if current.kind != .Array do return {}, false
				return Json_Value{kind = .Number, number = f64(len(current.items))}, true
			}
			start := at
			for at < len(trimmed) && trimmed[at] != ']' do at += 1
			index_text := trimmed[start:at]
			if at < len(trimmed) && trimmed[at] == ']' do at += 1
			index, index_ok := parse_time_number(index_text)
			if !index_ok || index < 0 do return {}, false
			if current.kind != .Array do return {}, false
			slot := int(index)
			if slot >= len(current.items) do return {}, false
			current = current.items[slot]
		case:
			return {}, false
		}
	}
	return current, true
}

// --- Functions -------------------------------------------------------------

json_type_name :: proc(value: Json_Value) -> string {
	#partial switch value.kind {
	case .Null:
		return "null"
	case .Bool:
		return value.boolean ? "true" : "false"
	case .Number:
		if value.number == math.floor(value.number) do return "integer"
		return "real"
	case .String:
		return "text"
	case .Array:
		return "array"
	case .Object:
		return "object"
	}
	return "null"
}

// json_call runs a JSON function. It reports false when the name is not one of
// them, and returns a NULL value for invalid input or a missing path.
json_call :: proc(name: string, args: []Value) -> (Value, bool, Error) {
	if strings.equal_fold(name, "json_set") || strings.equal_fold(name, "json_replace") || strings.equal_fold(name, "json_remove") {
		return json_mutation(name, args)
	}
	if len(args) > 0 && args[0].kind == .Null && !strings.equal_fold(name, "json_array") &&
	   !strings.equal_fold(name, "json_object") && !strings.equal_fold(name, "json_quote") {
		return value_null(), true, ERROR_NONE
	}
	switch strings.to_lower(name) {
	case "json_valid":
		if len(args) != 1 do return {}, true, errf(.Invalid_Argument, "json_valid() takes one argument")
		if args[0].kind != .String do return value_int(0), true, ERROR_NONE
		doc, ok := json_parse(args[0].s, context.temp_allocator)
		if ok do json_destroy(doc, context.temp_allocator)
		return value_int(ok ? 1 : 0), true, ERROR_NONE
	case "json":
		if len(args) != 1 do return {}, true, errf(.Invalid_Argument, "json() takes one argument")
		if args[0].kind != .String do return {}, true, errf(.Invalid_Type, "json() expects text")
		doc, ok := json_parse(args[0].s, context.allocator)
		if !ok do return {}, true, errf(.Invalid_Argument, "malformed JSON")
		text := json_write(doc, context.allocator)
		json_destroy(doc, context.allocator)
		return value_string(text), true, ERROR_NONE
	case "json_type":
		if len(args) != 1 && len(args) != 2 do return {}, true, errf(.Invalid_Argument, "json_type() takes one or two arguments")
		if args[0].kind != .String do return {}, true, errf(.Invalid_Type, "json_type() expects text")
		doc, ok := json_parse(args[0].s, context.allocator)
		if !ok do return value_null(), true, ERROR_NONE
		defer json_destroy(doc, context.allocator)
		target := doc
		if len(args) == 2 {
			if args[1].kind != .String do return value_null(), true, ERROR_NONE
			found: bool
			target, found = json_path_find(doc, args[1].s)
			if !found do return value_null(), true, ERROR_NONE
		}
		return value_string(strings.clone(json_type_name(target), context.allocator)), true, ERROR_NONE
	case "json_extract":
		if len(args) < 2 do return {}, true, errf(.Invalid_Argument, "json_extract() needs a document and a path")
		if args[0].kind != .String do return {}, true, errf(.Invalid_Type, "json_extract() expects text")
		doc, ok := json_parse(args[0].s, context.allocator)
		if !ok do return value_null(), true, ERROR_NONE
		defer json_destroy(doc, context.allocator)
		if len(args) == 2 {
			if args[1].kind != .String do return value_null(), true, ERROR_NONE
			target, found := json_path_find(doc, args[1].s)
			if !found do return value_null(), true, ERROR_NONE
			return json_to_value(target, context.allocator), true, ERROR_NONE
		}
		// Several paths produce a JSON array of the results.
		items := make([dynamic]Json_Value, 0, len(args) - 1, context.temp_allocator)
		for path in args[1:] {
			if path.kind != .String do return value_null(), true, ERROR_NONE
			target, found := json_path_find(doc, path.s)
			append(&items, Json_Value{kind = .Null} if !found else target)
		}
		return value_string(json_write(Json_Value{kind = .Array, items = items[:]}, context.allocator)), true, ERROR_NONE
	case "json_array_length":
		if len(args) != 1 && len(args) != 2 do return {}, true, errf(.Invalid_Argument, "json_array_length() takes one or two arguments")
		if args[0].kind != .String do return {}, true, errf(.Invalid_Type, "json_array_length() expects text")
		doc, ok := json_parse(args[0].s, context.temp_allocator)
		if !ok do return value_null(), true, ERROR_NONE
		defer json_destroy(doc, context.temp_allocator)
		target := doc
		if len(args) == 2 {
			if args[1].kind != .String do return value_null(), true, ERROR_NONE
			found: bool
			target, found = json_path_find(doc, args[1].s)
			if !found do return value_null(), true, ERROR_NONE
		}
		if target.kind != .Array do return value_int(0), true, ERROR_NONE
		return value_int(i64(len(target.items))), true, ERROR_NONE
	case "json_array":
		items := make([]Json_Value, len(args), context.temp_allocator)
		for arg, i in args do items[i] = json_from_value(arg, context.temp_allocator)
		text := json_write(Json_Value{kind = .Array, items = items}, context.allocator)
		return value_string(text), true, ERROR_NONE
	case "json_object":
		if len(args) % 2 != 0 do return {}, true, errf(.Invalid_Argument, "json_object() takes key/value pairs")
		count := len(args) / 2
		keys := make([]string, count, context.temp_allocator)
		values := make([]Json_Value, count, context.temp_allocator)
		for i in 0 ..< count {
			key := args[i * 2]
			if key.kind != .String do return {}, true, errf(.Invalid_Type, "json_object() keys must be text")
			keys[i] = key.s
			values[i] = json_from_value(args[i * 2 + 1], context.temp_allocator)
		}
		text := json_write(Json_Value{kind = .Object, keys = keys, values = values}, context.allocator)
		return value_string(text), true, ERROR_NONE
	case "json_quote":
		if len(args) != 1 do return {}, true, errf(.Invalid_Argument, "json_quote() takes one argument")
		item := json_from_value(args[0], context.temp_allocator)
		return value_string(json_write(item, context.allocator)), true, ERROR_NONE
	}
	return {}, false, ERROR_NONE
}

// json_call_name reports whether a function name belongs to the JSON family.
json_call_name :: proc(name: string) -> bool {
	for candidate in ([]string{"json", "json_valid", "json_type", "json_extract", "json_array", "json_object", "json_quote", "json_array_length", "json_set", "json_replace", "json_remove"}) {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}

// --- Mutation --------------------------------------------------------------

Json_Segment :: struct {
	is_index: bool,
	name:     string,
	index:    int,
}

// json_path_split separates the parent path from the last segment: object keys
// and array slots are the only things a mutator can reach.
json_path_split :: proc(path: string) -> (parent: string, last: Json_Segment, ok: bool) {
	trimmed := strings.trim_space(path)
	if len(trimmed) < 2 do return "", {}, false
	depth := 0
	cut := -1
	for at in 1 ..< len(trimmed) {
		switch trimmed[at] {
		case '[':
			if depth == 0 do cut = at
			depth += 1
		case ']':
			if depth > 0 do depth -= 1
		case '.':
			if depth == 0 do cut = at
		}
	}
	if cut <= 0 do return "", {}, false
	parent = trimmed[:cut]
	rest := trimmed[cut:]
	if rest[0] == '.' {
		if len(rest) < 2 do return "", {}, false
		return parent, Json_Segment{name = rest[1:]}, true
	}
	if rest[0] == '[' {
		if !strings.has_suffix(rest, "]") do return "", {}, false
		index_text := rest[1:len(rest) - 1]
		index, number_ok := parse_time_number(index_text)
		if !number_ok || index < 0 do return "", {}, false
		return parent, Json_Segment{is_index = true, index = int(index)}, true
	}
	return "", {}, false
}

// json_path_find_ptr resolves a path to a pointer inside the tree, so mutators
// can change the value in place (the containers are slices).
json_path_find_ptr :: proc(root: ^Json_Value, path: string) -> (^Json_Value, bool) {
	trimmed := strings.trim_space(path)
	if len(trimmed) == 0 do return root, true
	at := 0
	if trimmed[0] == '$' do at = 1
	current := root
	for at < len(trimmed) {
		switch trimmed[at] {
		case '.':
			at += 1
			start := at
			for at < len(trimmed) && trimmed[at] != '.' && trimmed[at] != '[' do at += 1
			name := trimmed[start:at]
			if current.kind != .Object do return nil, false
			found := -1
			for key, i in current.keys {
				if strings.equal_fold(key, name) {
					found = i
					break
				}
			}
			if found < 0 do return nil, false
			current = &current.values[found]
		case '[':
			at += 1
			if at < len(trimmed) && trimmed[at] == '"' do return nil, false
			start := at
			for at < len(trimmed) && trimmed[at] != ']' do at += 1
			index_text := trimmed[start:at]
			if at < len(trimmed) do at += 1
			index, number_ok := parse_time_number(index_text)
			if !number_ok || index < 0 do return nil, false
			if current.kind != .Array do return nil, false
			slot := int(index)
			if slot >= len(current.items) do return nil, false
			current = &current.items[slot]
		case:
			return nil, false
		}
	}
	return current, true
}

// json_set_path writes a value at a path. With replace_only, a missing path is
// an error unless it already exists (json_replace).
json_set_path :: proc(root: ^Json_Value, path: string, new_value: Json_Value, replace_only: bool, alloc: mem.Allocator) -> bool {
	parent_path, last, split_ok := json_path_split(path)
	if !split_ok do return false
	parent, parent_ok := json_path_find_ptr(root, parent_path)
	if !parent_ok do return false
	if last.is_index {
		if parent.kind != .Array do return false
		if last.index < len(parent.items) {
			json_destroy(parent.items[last.index], alloc)
			parent.items[last.index] = new_value
			return true
		}
		if replace_only do return false
		grown := make([]Json_Value, len(parent.items) + 1, alloc)
		copy(grown, parent.items)
		grown[len(parent.items)] = new_value
		delete(parent.items, alloc)
		parent.items = grown
		return true
	}
	if parent.kind != .Object do return false
	for key, i in parent.keys {
		if !strings.equal_fold(key, last.name) do continue
		json_destroy(parent.values[i], alloc)
		parent.values[i] = new_value
		return true
	}
	if replace_only do return false
	keys := make([]string, len(parent.keys) + 1, alloc)
	copy(keys, parent.keys)
	keys[len(parent.keys)] = strings.clone(last.name, alloc)
	values := make([]Json_Value, len(parent.values) + 1, alloc)
	copy(values, parent.values)
	values[len(parent.values)] = new_value
	delete(parent.keys, alloc)
	delete(parent.values, alloc)
	parent.keys = keys
	parent.values = values
	return true
}

// json_remove_path drops the value a path names.
json_remove_path :: proc(root: ^Json_Value, path: string, alloc: mem.Allocator) -> bool {
	parent_path, last, split_ok := json_path_split(path)
	if !split_ok do return false
	parent, parent_ok := json_path_find_ptr(root, parent_path)
	if !parent_ok do return false
	if last.is_index {
		if parent.kind != .Array || last.index >= len(parent.items) do return false
		json_destroy(parent.items[last.index], alloc)
		for i in last.index ..< len(parent.items) - 1 do parent.items[i] = parent.items[i + 1]
		parent.items = parent.items[:len(parent.items) - 1]
		return true
	}
	if parent.kind != .Object do return false
	for key, i in parent.keys {
		if !strings.equal_fold(key, last.name) do continue
		delete(key, alloc)
		json_destroy(parent.values[i], alloc)
		for j in i ..< len(parent.values) - 1 {
			parent.keys[j] = parent.keys[j + 1]
			parent.values[j] = parent.values[j + 1]
		}
		parent.keys = parent.keys[:len(parent.keys) - 1]
		parent.values = parent.values[:len(parent.values) - 1]
		return true
	}
	return false
}

// json_mutation runs json_set, json_replace and json_remove.
json_mutation :: proc(name: string, args: []Value) -> (Value, bool, Error) {
	if len(args) < 2 do return {}, true, errf(.Invalid_Argument, "%s() needs a document and paths", name)
	if args[0].kind != .String do return {}, true, errf(.Invalid_Type, "%s() expects text", name)
	doc, ok := json_parse(args[0].s, context.allocator)
	if !ok do return {}, true, errf(.Invalid_Argument, "malformed JSON")
	if strings.equal_fold(name, "json_remove") {
		for path in args[1:] {
			if path.kind != .String do break
			json_remove_path(&doc, path.s, context.allocator)
		}
	} else {
		if (len(args) - 1) % 2 != 0 {
			json_destroy(doc, context.allocator)
			return {}, true, errf(.Invalid_Argument, "%s() takes path/value pairs", name)
		}
		replace_only := strings.equal_fold(name, "json_replace")
		for i := 1; i + 1 < len(args); i += 2 {
			path := args[i]
			if path.kind != .String do break
			proposed := json_from_value(args[i + 1], context.allocator)
			if !json_set_path(&doc, path.s, proposed, replace_only, context.allocator) {
				json_destroy(proposed, context.allocator)
				if replace_only do continue
				json_destroy(doc, context.allocator)
				return {}, true, errf(.Invalid_Argument, "json_set() could not reach the path")
			}
		}
	}
	text := json_write(doc, context.allocator)
	json_destroy(doc, context.allocator)
	return value_string(text), true, ERROR_NONE
}
