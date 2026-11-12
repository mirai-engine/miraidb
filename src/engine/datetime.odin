package engine

import "core:fmt"
import "core:math"
import "core:strings"

// SQLite's date and time functions work in Julian days: a day starts at noon,
// so the integer part is the date and the fraction is the time. The engine
// stores microseconds since the epoch elsewhere, so everything here converts.

JD_UNIX_EPOCH :: 2440587.5
SECONDS_PER_DAY :: 86400.0

// Db_Time is one instant, in Julian days, UTC.
Db_Time :: struct {
	jd: f64,
}

db_time_now :: proc() -> Db_Time {
	return Db_Time{jd = JD_UNIX_EPOCH + f64(now_microseconds()) / (SECONDS_PER_DAY * 1e6)}
}

// db_time_parse reads the first argument of a date function (text, a Julian day
// or 'now') and applies the modifiers that follow. It reports whether a usable
// instant came out; a NULL or unparsable input yields false, as in SQLite.
db_time_parse :: proc(args: []Value) -> (Db_Time, bool) {
	if len(args) == 0 do return {}, false
	input := args[0]
	#partial switch input.kind {
	case .Null, .Default:
		return {}, false
	}
	modifiers := args[1:]
	// 'unixepoch' reinterprets a numeric input as seconds since 1970.
	unix := false
	for modifier in modifiers {
		if modifier.kind != .String do continue
		if strings.equal_fold(strings.trim_space(modifier.s), "unixepoch") do unix = true
	}
	moment: Db_Time
	parsed := false
	#partial switch input.kind {
	case .String:
		text := strings.trim_space(input.s)
		if strings.equal_fold(text, "now") {
			moment = db_time_now()
			parsed = true
		} else if db_time_parse_text(text, &moment) {
			parsed = true
		}
	case .Int, .Float, .Uint:
		number, number_ok := value_to_f64(input)
		if number_ok {
			if unix {
				moment = Db_Time{jd = JD_UNIX_EPOCH + number / SECONDS_PER_DAY}
			} else {
				moment = Db_Time{jd = number}
			}
			parsed = true
		}
	}
	if !parsed do return {}, false
	for modifier in modifiers {
		if modifier.kind != .String do continue
		if !db_time_apply_modifier(&moment, strings.trim_space(modifier.s)) do return {}, false
	}
	return moment, true
}

// db_time_parse_text reads 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM[:SS[.fff]]',
// 'HH:MM[:SS]' (anchored at 2000-01-01, as SQLite does) and the 'T' separator.
db_time_parse_text :: proc(text: string, out: ^Db_Time) -> bool {
	year := 2000
	month := 1
	day := 1
	hour := 0
	minute := 0
	second := 0
	fraction := f64(0)
	index := 0

	read_number :: proc(text: string, index: ^int, digits: int) -> (int, bool) {
		value := 0
		read := 0
		for read < digits && index^ < len(text) {
			c := text[index^]
			if c < '0' || c > '9' do break
			value = value * 10 + int(c - '0')
			index^ += 1
			read += 1
		}
		return value, read > 0
	}

	// A leading '-' belongs to a negative year; otherwise the date comes first.
	negative_year := false
	if index < len(text) && text[index] == '-' {
		negative_year = true
		index += 1
	}
	if value, ok := read_number(text, &index, 4); ok {
		if index < len(text) && text[index] == '-' {
			year = negative_year ? -value : value
			index += 1
			m, m_ok := read_number(text, &index, 2)
			if !m_ok do return false
			month = m
			if index >= len(text) || text[index] != '-' do return false
			index += 1
			d, d_ok := read_number(text, &index, 2)
			if !d_ok do return false
			day = d
			if index < len(text) && (text[index] == ' ' || text[index] == 'T') do index += 1
			else do index = len(text)
		} else {
			// Not a date: the leading digits were the hour of a time-only input.
			index = 0
			year, month, day = 2000, 1, 1
		}
	}
	if index < len(text) {
		h, h_ok := read_number(text, &index, 2)
		if !h_ok do return false
		hour = h
		if index >= len(text) || text[index] != ':' do return false
		index += 1
		m, m_ok := read_number(text, &index, 2)
		if !m_ok do return false
		minute = m
		if index < len(text) && text[index] == ':' {
			index += 1
			s, s_ok := read_number(text, &index, 2)
			if !s_ok do return false
			second = s
			if index < len(text) && text[index] == '.' {
				index += 1
				scale := f64(0.1)
				for index < len(text) && text[index] >= '0' && text[index] <= '9' {
					fraction += f64(text[index] - '0') * scale
					scale /= 10
					index += 1
				}
			}
		}
	}
	if month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60 {
		return false
	}
	days := db_days_from_civil(year, month, day)
	seconds := f64(hour * 3600 + minute * 60 + second) + fraction
	out.jd = f64(days) + JD_UNIX_EPOCH + seconds / SECONDS_PER_DAY
	return true
}

// db_time_apply_modifier understands '±N day|hour|minute|second|month|year',
// 'start of day|month|year' and the no-op 'utc' / 'localtime' / 'unixepoch'.
db_time_apply_modifier :: proc(moment: ^Db_Time, modifier: string) -> bool {
	lower := strings.to_lower(modifier, context.temp_allocator)
	if strings.equal_fold(lower, "unixepoch") || strings.equal_fold(lower, "utc") ||
	   strings.equal_fold(lower, "localtime") {
		return true
	}
	if strings.has_prefix(lower, "start of ") {
		kind := strings.trim_space(lower[len("start of "):])
		year, month, day, hour, minute, second := db_time_civil(moment^)
		switch {
		case kind == "day":
			hour, minute, second = 0, 0, 0
		case kind == "month":
			day, hour, minute, second = 1, 0, 0, 0
		case kind == "year":
			month, day, hour, minute, second = 1, 1, 0, 0, 0
		case:
			return false
		}
		moment.jd = db_time_from_civil(year, month, day, hour, minute, second, 0)
		return true
	}
	trimmed := strings.trim_space(lower)
	sign := f64(1)
	if len(trimmed) > 0 && (trimmed[0] == '+' || trimmed[0] == '-') {
		if trimmed[0] == '-' do sign = -1
		trimmed = trimmed[1:]
	}
	space := strings.index_byte(trimmed, ' ')
	if space < 0 do return false
	number_text := trimmed[:space]
	unit := strings.trim_space(trimmed[space:])
	amount := f64(0)
	value, ok := parse_time_number(number_text)
	if !ok do return false
	amount = value * sign
	switch {
	case strings.has_prefix(unit, "day"):
		moment.jd += amount
	case strings.has_prefix(unit, "hour"):
		moment.jd += amount / 24
	case strings.has_prefix(unit, "minute"):
		moment.jd += amount / (24 * 60)
	case strings.has_prefix(unit, "second"):
		moment.jd += amount / SECONDS_PER_DAY
	case strings.has_prefix(unit, "month"):
		year, month, day, hour, minute, second := db_time_civil(moment^)
		total := (year * 12 + (month - 1)) + int(amount)
		year = int(math.floor(f64(total) / 12))
		month = total - year * 12 + 1
		// A month step clamps the day: 31 January plus one month is 29 February.
		if day > db_days_in_month(year, month) do day = db_days_in_month(year, month)
		moment.jd = db_time_from_civil(year, month, day, hour, minute, second, 0)
	case strings.has_prefix(unit, "year"):
		year, month, day, hour, minute, second := db_time_civil(moment^)
		year += int(amount)
		moment.jd = db_time_from_civil(year, month, day, hour, minute, second, 0)
	case:
		return false
	}
	return true
}

// parse_time_number reads a decimal number without an allocator.
parse_time_number :: proc(text: string) -> (f64, bool) {
	if len(text) == 0 do return 0, false
	integer := f64(0)
	scale := f64(1)
	fractional := false
	fraction := f64(0)
	digits := 0
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '.' && !fractional {
			fractional = true
			scale = 0.1
			continue
		}
		if c < '0' || c > '9' do return 0, false
		if fractional {
			fraction += f64(c - '0') * scale
			scale /= 10
		} else {
			integer = integer * 10 + f64(c - '0')
		}
		digits += 1
	}
	if digits == 0 do return 0, false
	return integer + fraction, true
}

// db_days_in_month reports the length of a month.
db_days_in_month :: proc(year, month: int) -> int {
	switch month {
	case 1, 3, 5, 7, 8, 10, 12:
		return 31
	case 4, 6, 9, 11:
		return 30
	}
	leap := (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
	return leap ? 29 : 28
}

db_time_civil :: proc(t: Db_Time) -> (year, month, day, hour, minute, second: int) {
	days := i64(math.floor(t.jd - JD_UNIX_EPOCH))
	fraction := (t.jd - JD_UNIX_EPOCH) - f64(days)
	if fraction < 0 {
		fraction += 1
		days -= 1
	}
	year, month, day = db_civil_from_days(days)
	total := int(fraction * SECONDS_PER_DAY + 0.5)
	if total >= 86400 {
		total -= 86400
		day, month, year = db_civil_from_days(days + 1)
	}
	hour = total / 3600
	minute = (total % 3600) / 60
	second = total % 60
	return
}

db_time_from_civil :: proc(year, month, day, hour, minute, second: int, millisecond: int) -> f64 {
	days := db_days_from_civil(year, month, day)
	seconds := f64(hour * 3600 + minute * 60 + second) + f64(millisecond) / 1000
	return f64(days) + JD_UNIX_EPOCH + seconds / SECONDS_PER_DAY
}

// db_days_from_civil and db_civil_from_days use Howard Hinnant's algorithms,
// which count days from 1970-01-01 and work for negative years too.
db_days_from_civil :: proc(year, month, day: int) -> i64 {
	y := i64(year)
	if month <= 2 do y -= 1
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	mp := i64((month + 9) % 12)
	doy := (153 * mp + 2) / 5 + i64(day) - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

db_civil_from_days :: proc(days: i64) -> (year, month, day: int) {
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	yy := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	dd := doy - (153 * mp + 2) / 5 + 1
	mm := mp < 10 ? mp + 3 : mp - 9
	yy += (mm <= 2 ? 1 : 0)
	return int(yy), int(mm), int(dd)
}

// db_time_format renders the text forms SQLite returns.
db_time_format :: proc(t: Db_Time, with_date, with_time: bool) -> string {
	year, month, day, hour, minute, second := db_time_civil(t)
	builder := strings.builder_make()
	if with_date do fmt.sbprintf(&builder, "%04d-%02d-%02d", year, month, day)
	if with_date && with_time do strings.write_byte(&builder, ' ')
	if with_time do fmt.sbprintf(&builder, "%02d:%02d:%02d", hour, minute, second)
	out := strings.clone(strings.to_string(builder))
	strings.builder_destroy(&builder)
	return out
}

db_time_unix :: proc(t: Db_Time) -> i64 {
	return i64(math.round((t.jd - JD_UNIX_EPOCH) * SECONDS_PER_DAY))
}

// db_time_strftime implements the strftime codes SQLite supports most often.
db_time_strftime :: proc(format: string, t: Db_Time) -> string {
	year, month, day, hour, minute, second := db_time_civil(t)
	day_of_year := int(db_days_from_civil(year, month, day) - db_days_from_civil(year, 1, 1)) + 1
	builder := strings.builder_make()
	i := 0
	for i < len(format) {
		c := format[i]
		if c != '%' || i + 1 >= len(format) {
			strings.write_byte(&builder, c)
			i += 1
			continue
		}
		code := format[i + 1]
		i += 2
		switch code {
		case 'Y':
			fmt.sbprintf(&builder, "%04d", year)
		case 'm':
			fmt.sbprintf(&builder, "%02d", month)
		case 'd':
			fmt.sbprintf(&builder, "%02d", day)
		case 'H':
			fmt.sbprintf(&builder, "%02d", hour)
		case 'M':
			fmt.sbprintf(&builder, "%02d", minute)
		case 'S':
			fmt.sbprintf(&builder, "%02d", second)
		case 'j':
			fmt.sbprintf(&builder, "%03d", day_of_year)
		case 's':
			fmt.sbprintf(&builder, "%d", db_time_unix(t))
		case 'J':
			fmt.sbprintf(&builder, "%.6f", t.jd)
		case 'w':
			// 0 is Sunday; the epoch was a Thursday (4).
			weekday := i64(math.mod(math.floor(t.jd + 1.5), 7))
			fmt.sbprintf(&builder, "%d", weekday)
		case 'F':
			fmt.sbprintf(&builder, "%04d-%02d-%02d", year, month, day)
		case 'T':
			fmt.sbprintf(&builder, "%02d:%02d:%02d", hour, minute, second)
		case '%':
			strings.write_byte(&builder, '%')
		case:
			strings.write_byte(&builder, '%')
			strings.write_byte(&builder, code)
		}
	}
	out := strings.clone(strings.to_string(builder))
	strings.builder_destroy(&builder)
	return out
}

// datetime_call evaluates the date and time functions. It returns a NULL value
// with ok = false when the input cannot be understood.
db_time_call :: proc(name: string, args: []Value) -> (Value, bool) {
	moment, ok := db_time_parse(args)
	if !ok do return value_null(), false
	switch {
	case strings.equal_fold(name, "date"):
		return value_string(db_time_format(moment, true, false)), true
	case strings.equal_fold(name, "time"):
		return value_string(db_time_format(moment, false, true)), true
	case strings.equal_fold(name, "datetime"):
		return value_string(db_time_format(moment, true, true)), true
	case strings.equal_fold(name, "julianday"):
		return value_float(moment.jd), true
	case strings.equal_fold(name, "unixepoch"):
		return value_int(db_time_unix(moment)), true
	}
	return value_null(), false
}

// db_time_has_functions reports whether a name belongs to the date family, so
// the evaluator can route it before the generic call path.
db_time_has_functions :: proc(name: string) -> bool {
	for candidate in ([]string{"date", "time", "datetime", "julianday", "unixepoch", "strftime"}) {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}
