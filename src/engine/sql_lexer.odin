package engine

import "core:mem"
import "core:strings"

// Token_Kind is the lexical class of a SQL token. Punctuation and operators
// carry their text; the parser compares that text.
Token_Kind :: enum u8 {
	EOF,
	Ident,
	Quoted_Ident,
	String,
	Number,
	Blob,
	Punct,
}

Token :: struct {
	kind: Token_Kind,
	text: string,
	line: int,
	column: int,
	// end is the offset in the source just past the token, so the parser can
	// take the text a construct was written with; start is where it begins.
	end: int,
	start: int,
}

Lexer :: struct {
	src:    string,
	pos:    int,
	line:   int,
	column: int,
	// alloc owns the text of a quoted token: a quoted identifier or a string
	// literal is not a slice of the source, and the statement's arena is what
	// frees it when the statement is done.
	alloc:  mem.Allocator,
	// start is where the token being scanned begins.
	start:  int,
}

lexer_init :: proc(src: string, alloc := context.allocator) -> Lexer {
	return Lexer{src = src, pos = 0, line = 1, column = 1, alloc = alloc}
}

@(private)
lexer_peek :: proc(l: ^Lexer) -> u8 {
	if l.pos >= len(l.src) do return 0
	return l.src[l.pos]
}

@(private)
lexer_peek_at :: proc(l: ^Lexer, offset: int) -> u8 {
	if l.pos + offset >= len(l.src) do return 0
	return l.src[l.pos + offset]
}

@(private)
lexer_advance :: proc(l: ^Lexer) -> u8 {
	c := l.src[l.pos]
	l.pos += 1
	if c == '\n' {
		l.line += 1
		l.column = 1
	} else {
		l.column += 1
	}
	return c
}

@(private)
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
is_ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

@(private)
is_ident_char :: proc(c: u8) -> bool {
	return is_ident_start(c) || is_digit(c) || c == '$'
}

// lexer_next returns the next token. Unterminated strings and comments return a
// Punct token with empty text, which the parser rejects with a position.
lexer_next :: proc(l: ^Lexer) -> Token {
	token := lexer_scan(l)
	token.end = l.pos
	token.start = l.start
	return token
}

@(private)
lexer_scan :: proc(l: ^Lexer) -> Token {
	for {
		l.start = l.pos
		if l.pos >= len(l.src) {
			return Token{kind = .EOF, line = l.line, column = l.column}
		}
		c := lexer_peek(l)
		if is_space(c) {
			lexer_advance(l)
			continue
		}
		if c == '-' && lexer_peek_at(l, 1) == '-' {
			for l.pos < len(l.src) && lexer_peek(l) != '\n' do lexer_advance(l)
			continue
		}
		if c == '/' && lexer_peek_at(l, 1) == '*' {
			lexer_advance(l)
			lexer_advance(l)
			for l.pos < len(l.src) {
				if lexer_peek(l) == '*' && lexer_peek_at(l, 1) == '/' {
					lexer_advance(l)
					lexer_advance(l)
					break
				}
				lexer_advance(l)
			}
			continue
		}
		break
	}
	start := l.pos
	line := l.line
	column := l.column
	c := lexer_peek(l)

	switch c {
	case '\'', '"', '`':
		quote := c
		lexer_advance(l)
		builder := strings.builder_make(l.alloc)
		for {
			if l.pos >= len(l.src) {
				strings.builder_destroy(&builder)
				return Token{kind = .Punct, text = "", line = line, column = column}
			}
			ch := lexer_advance(l)
			if ch == quote {
				if lexer_peek(l) == quote {
					lexer_advance(l)
					strings.write_byte(&builder, quote)
					continue
				}
				break
			}
			strings.write_byte(&builder, ch)
		}
		kind := Token_Kind.String
		if quote != '\'' do kind = .Quoted_Ident
		return Token{kind = kind, text = strings.to_string(builder), line = line, column = column}
	case:
	}

	if is_digit(c) || (c == '.' && is_digit(lexer_peek_at(l, 1))) {
		lexer_advance(l)
		for l.pos < len(l.src) {
			ch := lexer_peek(l)
			if is_digit(ch) || ch == '.' || ch == 'e' || ch == 'E' {
				// Stop before a `..` range operator; SQL has none, but a
				// trailing dot on a number is a common typo.
				lexer_advance(l)
				continue
			}
			if (ch == '+' || ch == '-') && l.pos > start {
				prev := l.src[l.pos - 1]
				if prev == 'e' || prev == 'E' {
					lexer_advance(l)
					continue
				}
			}
			break
		}
		return Token{kind = .Number, text = l.src[start:l.pos], line = line, column = column}
	}

	// `$1` is a PostgreSQL parameter; the parser reads it from an identifier.
	if c == '$' && l.pos + 1 < len(l.src) && is_digit(l.src[l.pos + 1]) {
		lexer_advance(l)
		for l.pos < len(l.src) && is_digit(lexer_peek(l)) do lexer_advance(l)
		return Token{kind = .Ident, text = l.src[start:l.pos], line = line, column = column}
	}
	if is_ident_start(c) {
		lexer_advance(l)
		for l.pos < len(l.src) && is_ident_char(lexer_peek(l)) do lexer_advance(l)
		// x'0f0f' is a blob literal.
		if l.pos - start == 1 && (c == 'x' || c == 'X') && lexer_peek(l) == '\'' {
			lexer_advance(l)
			hex_start := l.pos
			for l.pos < len(l.src) && lexer_peek(l) != '\'' do lexer_advance(l)
			hex_text := l.src[hex_start:l.pos]
			if l.pos < len(l.src) do lexer_advance(l)
			return Token{kind = .Blob, text = hex_text, line = line, column = column}
		}
		return Token{kind = .Ident, text = l.src[start:l.pos], line = line, column = column}
	}

	lexer_advance(l)
	switch c {
	case '?':
		// `?NNN` is SQLite's numbered parameter: the n-th value, by number.
		if l.pos < len(l.src) && is_digit(lexer_peek(l)) {
			for l.pos < len(l.src) && is_digit(lexer_peek(l)) do lexer_advance(l)
			return Token{kind = .Punct, text = l.src[start:l.pos], line = line, column = column}
		}
	case '$':
		// `$name` is one of SQLite's named parameters (`$1` is PostgreSQL's
		// numbered one, read above).
		if l.pos < len(l.src) && is_ident_start(lexer_peek(l)) {
			for l.pos < len(l.src) && is_ident_char(lexer_peek(l)) do lexer_advance(l)
			return Token{kind = .Punct, text = l.src[start:l.pos], line = line, column = column}
		}
	case '=':
		if lexer_peek(l) == '=' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "==", line = line, column = column}
		}
		return Token{kind = .Punct, text = "=", line = line, column = column}
	case '<':
		if lexer_peek(l) == '=' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "<=", line = line, column = column}
		}
		if lexer_peek(l) == '>' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "<>", line = line, column = column}
		}
		if lexer_peek(l) == '<' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "<<", line = line, column = column}
		}
		// PostgreSQL's array operators: `<@` is "contained by".
		if lexer_peek(l) == '@' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "<@", line = line, column = column}
		}
		return Token{kind = .Punct, text = "<", line = line, column = column}
	case '>':
		if lexer_peek(l) == '=' {
			lexer_advance(l)
			return Token{kind = .Punct, text = ">=", line = line, column = column}
		}
		if lexer_peek(l) == '>' {
			lexer_advance(l)
			return Token{kind = .Punct, text = ">>", line = line, column = column}
		}
		return Token{kind = .Punct, text = ">", line = line, column = column}
	case '-':
		// SQLite's JSON operators: `->` answers JSON, `->>` an SQL value.
		if lexer_peek(l) == '>' {
			lexer_advance(l)
			if lexer_peek(l) == '>' {
				lexer_advance(l)
				return Token{kind = .Punct, text = "->>", line = line, column = column}
			}
			return Token{kind = .Punct, text = "->", line = line, column = column}
		}
	case '@':
		// `@>` is PostgreSQL's "contains".
		if lexer_peek(l) == '>' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "@>", line = line, column = column}
		}
		// `@name` is one of SQLite's named parameters.
		if l.pos < len(l.src) && is_ident_start(lexer_peek(l)) {
			for l.pos < len(l.src) && is_ident_char(lexer_peek(l)) do lexer_advance(l)
			return Token{kind = .Punct, text = l.src[start:l.pos], line = line, column = column}
		}
	case '&':
		// `&&` is PostgreSQL's "overlaps".
		if lexer_peek(l) == '&' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "&&", line = line, column = column}
		}
	case '!':
		if lexer_peek(l) == '=' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "!=", line = line, column = column}
		}
	case '|':
		if lexer_peek(l) == '|' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "||", line = line, column = column}
		}
	case ':':
		// PostgreSQL's cast, `x::type`.
		if lexer_peek(l) == ':' {
			lexer_advance(l)
			return Token{kind = .Punct, text = "::", line = line, column = column}
		}
		// `:name` is one of SQLite's named parameters.
		if l.pos < len(l.src) && is_ident_start(lexer_peek(l)) {
			for l.pos < len(l.src) && is_ident_char(lexer_peek(l)) do lexer_advance(l)
			return Token{kind = .Punct, text = l.src[start:l.pos], line = line, column = column}
		}
	}

	return Token{kind = .Punct, text = l.src[start:l.pos], line = line, column = column}
}
