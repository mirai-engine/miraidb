package engine

import "base:runtime"
import "core:math"
import "core:strings"

// Full-text search as data. A virtual FTS table is a normal table of documents
// plus an inverted index kept in a shadow table; `MATCH` reads the shadow table,
// not the documents, so the query cost follows the number of matching documents
// rather than the size of the text.
//
//	_virtual (name, module, settings)      what virtual tables exist
//	_fts_<name>_terms (term, doc, tf)     one row per (token, document), tf counts it
//	_fts_<name>_docs  (doc, length)       tokens per document, for BM25
//	_fts_<name>_stats (id, docs, tokens)  one row: corpus size and total tokens
//
// The terms table is indexed on `term` and on `doc`, so a query walks the postings
// of its terms and a document rewrite touches only its own rows.
//
// Interior tables are ordinary tables: they are logged, replicated and dropped
// like any other, so FTS needs no format change.

VIRTUAL_TABLE :: "_virtual"
VIRTUAL_SCHEMA_SQL :: `
	CREATE TABLE IF NOT EXISTS _virtual (
		name TEXT PRIMARY KEY,
		module TEXT NOT NULL,
		settings TEXT NOT NULL
	)
`

FTS_MAX_TERMS :: 4096

Fts_Table :: struct {
	name:     string,
	// module is the virtual table module that made it: fts5/fts4 are inverted
	// indexes, rtree stores boxes. The name says which rules apply.
	module:   string,
	terms:    string,
	columns:  []string,
	settings: string,
}

// fts_is_full_text reports whether this virtual table maintains an inverted index.
fts_is_full_text :: proc(table: Fts_Table) -> bool {
	return strings.equal_fold(table.module, "fts5") || strings.equal_fold(table.module, "fts4")
}

// fts_is_spatial reports whether this virtual table stores bounding boxes.
fts_is_spatial :: proc(table: Fts_Table) -> bool {
	return strings.equal_fold(table.module, "rtree") || strings.equal_fold(table.module, "rtree_i32")
}

fts_ensure :: proc(tx: ^Tx) -> Error {
	_, err := sql_execute_in_tx(tx, VIRTUAL_SCHEMA_SQL)
	return err
}

// fts_run executes one statement inside the transaction and keeps only the error.
@(private)
fts_run :: proc(tx: ^Tx, sql: string, params: []Value = nil) -> Error {
	_, err := sql_execute_in_tx_params(tx, sql, params)
	return err
}

@(private)
fts_virtual_lookup :: proc(tx: ^Tx, name: string) -> (Fts_Table, bool) {
	table, err := tx_table(tx, VIRTUAL_TABLE)
	if err.kind != .None do return {}, false
	rows := make([dynamic]Row, 0, 8)
	defer delete(rows)
	table_collect(table, &rows)
	for row in rows {
		if len(row.values) < 3 do continue
		if row.values[0].kind != .String || !strings.equal_fold(row.values[0].s, name) do continue
		settings := ""
		if row.values[2].kind == .String do settings = row.values[2].s
		module := ""
		if len(row.values) > 1 && row.values[1].kind == .String do module = row.values[1].s
		columns := make([dynamic]string, 0, 4, tx.alloc)
		for piece in strings.split(settings, ",") {
			trimmed := strings.trim_space(piece)
			if len(trimmed) > 0 do append(&columns, trimmed)
		}
		return Fts_Table{name = row.values[0].s, module = module, terms = fts_terms_name(name), columns = columns[:], settings = settings}, true
	}
	return {}, false
}

@(private)
fts_terms_name :: proc(name: string, alloc := context.temp_allocator) -> string {
	return strings.concatenate({"_fts_", name, "_terms"}, alloc)
}

// fts_create makes the document table (when it does not exist), its shadow term
// table and the catalog row that links them.
fts_create :: proc(tx: ^Tx, name: string, module: string, columns: []string) -> Error {
	if len(name) == 0 do return errf(.Invalid_Argument, "a virtual table needs a name")
	if len(columns) == 0 do return errf(.Invalid_Argument, "virtual table %s needs at least one column", name)
	if strings.equal_fold(module, "rtree") || strings.equal_fold(module, "rtree_i32") {
		return rtree_create(tx, name, module, columns)
	}
	if !strings.equal_fold(module, "fts5") && !strings.equal_fold(module, "fts4") {
		return errf(.Sql_Unsupported, "virtual table module %s is not supported", module)
	}
	if err := fts_ensure(tx); err.kind != .None do return err
	if existing, found := fts_virtual_lookup(tx, name); found {
		return errf(.Table_Exists, "virtual table %s already exists", existing.name)
	}
	settings := strings.join(columns, ",")

	create := strings.concatenate({"CREATE TABLE IF NOT EXISTS ", name, " ("}, tx.alloc)
	for column, i in columns {
		if i > 0 do create = strings.concatenate({create, ", "}, tx.alloc)
		create = strings.concatenate({create, column, " TEXT"}, tx.alloc)
	}
	create = strings.concatenate({create, ")"}, tx.alloc)
	if err := fts_run(tx, create); err.kind != .None do return err

	terms := fts_terms_name(name, tx.alloc)
	terms_sql := strings.concatenate(
		{"CREATE TABLE IF NOT EXISTS ", terms, " (term TEXT NOT NULL, doc INTEGER NOT NULL, tf INTEGER NOT NULL)"},
		tx.alloc,
	)
	if err := fts_run(tx, terms_sql); err.kind != .None do return err
	docs := fts_docs_name(name, tx.alloc)
	docs_sql := strings.concatenate(
		{"CREATE TABLE IF NOT EXISTS ", docs, " (doc INTEGER PRIMARY KEY, length INTEGER NOT NULL)"},
		tx.alloc,
	)
	if err := fts_run(tx, docs_sql); err.kind != .None do return err
	stats := fts_stats_name(name, tx.alloc)
	stats_sql := strings.concatenate(
		{"CREATE TABLE IF NOT EXISTS ", stats, " (id INTEGER PRIMARY KEY, docs INTEGER NOT NULL, tokens INTEGER NOT NULL)"},
		tx.alloc,
	)
	if err := fts_run(tx, stats_sql); err.kind != .None do return err
	// An INTEGER PRIMARY KEY is the row id, and the scan planner does not treat it
	// as a probe target; the explicit index makes a length lookup a point read
	// instead of a scan of every document (the difference between O(1) and O(N)
	// per insert).
	docs_index := strings.concatenate(
		{"CREATE INDEX IF NOT EXISTS ", docs, "_doc ON ", docs, " (doc)"},
		tx.alloc,
	)
	if err := fts_run(tx, docs_index); err.kind != .None do return err
	seed := strings.concatenate({"INSERT INTO ", stats, " (id, docs, tokens) VALUES (1, 0, 0)"}, tx.alloc)
	if err := fts_run(tx, seed); err.kind != .None do return err
	// The postings index is created in this same transaction (index DDL is
	// staged like rows), so the first query already reads an index. The cost of a
	// query follows its matches; maintaining an index costs one probe per write.
	term_index := strings.concatenate(
		{"CREATE INDEX IF NOT EXISTS ", terms, "_term ON ", terms, " (term)"},
		tx.alloc,
	)
	if err := fts_run(tx, term_index); err.kind != .None do return err
	doc_index := strings.concatenate(
		{"CREATE INDEX IF NOT EXISTS ", terms, "_doc ON ", terms, " (doc)"},
		tx.alloc,
	)
	if err := fts_run(tx, doc_index); err.kind != .None do return err

	values := []Value {
		value_string(strings.clone(name, tx.alloc)),
		value_string(strings.clone(module, tx.alloc)),
		value_string(strings.clone(settings, tx.alloc)),
	}
	row_id, insert_err := tx_insert(tx, VIRTUAL_TABLE, values)
	if insert_err.kind != .None do return insert_err
	_ = row_id
	return ERROR_NONE
}

fts_drop :: proc(tx: ^Tx, name: string, if_exists: bool) -> Error {
	if err := fts_ensure(tx); err.kind != .None do return err
	table, found := fts_virtual_lookup(tx, name)
	if !found {
		if if_exists do return ERROR_NONE
		return errf(.Table_Not_Found, "no virtual table named %s", name)
	}
	// The catalog row goes first: with it gone, dropping the tables below runs as
	// plain drops instead of re-entering this procedure.
	drop_row := strings.concatenate({"DELETE FROM ", VIRTUAL_TABLE, " WHERE name = ?"}, tx.alloc)
	if err := fts_run(tx, drop_row, []Value{value_string(strings.clone(name, tx.alloc))}); err.kind != .None {
		return err
	}
	if err := tx_drop_table(tx, table.terms); err.kind != .None && err.kind != .Table_Not_Found do return err
	return tx_drop_table(tx, table.name)
}

// fts_index_row maintains the inverted index for one document. Every indexed
// column is tokenized with the same rules MATCH uses, so what is stored and what
// is searched can never disagree. The row keeps one posting per distinct term
// with its count (what BM25 needs), the document length, and the corpus totals,
// so ranking never scans the documents or the vocabulary.
//
// A row id this transaction handed out has no postings and no length yet, so it
// skips both lookups; that is what keeps a bulk load linear instead of quadratic
// in the size of the index.
fts_index_row :: proc(tx: ^Tx, table: Fts_Table, doc: Row_Id, values: []Value, is_new: bool) -> Error {
	if tx.fts_new_docs == nil do tx.fts_new_docs = make(map[string]map[Row_Id]bool)
	documents := tx.fts_new_docs[table.name]
	if documents == nil {
		documents = make(map[Row_Id]bool)
		tx.fts_new_docs[table.name] = documents
	}
	old_length := 0
	had_doc := false
	if !is_new {
		length, existed := fts_doc_length(tx, table, doc)
		old_length = length
		had_doc = existed
		del_terms := strings.concatenate({"DELETE FROM ", table.terms, " WHERE doc = ?"}, tx.alloc)
		if delete_err := fts_run(tx, del_terms, []Value{value_int(i64(doc))}); delete_err.kind != .None {
			return delete_err
		}
	}
	seen := make(map[string]int, 8, tx.alloc)
	defer delete(seen)
	insert := strings.concatenate(
		{"INSERT INTO ", table.terms, " (term, doc, tf) VALUES (?, ?, ?)"},
		tx.alloc,
	)
	total := 0
	for value in values {
		if value.kind != .String do continue
		term := strings.builder_make(tx.alloc)
		for b in transmute([]u8)value.s {
			if fts_is_word_byte(b) {
				strings.write_byte(&term, fts_fold_byte(b))
				continue
			}
			total += fts_count_term(&seen, strings.to_string(term))
			strings.builder_reset(&term)
			strings.builder_destroy(&term)
			term = strings.builder_make(tx.alloc)
		}
		total += fts_count_term(&seen, strings.to_string(term))
		strings.builder_destroy(&term)
	}
	for word, count in seen {
		err := fts_run(
			tx,
			insert,
			[]Value{value_string(word), value_int(i64(doc)), value_int(i64(count))},
		)
		if err.kind != .None do return err
	}
	docs_table := fts_docs_name(table.name, tx.alloc)
	if had_doc {
		update := strings.concatenate({"UPDATE ", docs_table, " SET length = ? WHERE doc = ?"}, tx.alloc)
		if err := fts_run(tx, update, []Value{value_int(i64(total)), value_int(i64(doc))}); err.kind != .None {
			return err
		}
	} else {
		insert_length := strings.concatenate({"INSERT INTO ", docs_table, " (doc, length) VALUES (?, ?)"}, tx.alloc)
		if err := fts_run(tx, insert_length, []Value{value_int(i64(doc)), value_int(i64(total))}); err.kind != .None {
			return err
		}
	}
	add_docs := had_doc ? 0 : 1
	if adjust_err := fts_stats_adjust(tx, table, add_docs, total - old_length); adjust_err.kind != .None {
		return adjust_err
	}
	documents[doc] = true
	return ERROR_NONE
}

// fts_count_term counts one token, capped so a pathological document cannot grow
// the posting map without bound.
@(private)
fts_count_term :: proc(seen: ^map[string]int, word: string) -> int {
	if len(word) == 0 do return 0
	if count, exists := seen[word]; exists {
		seen[word] = count + 1
		return 1
	}
	if len(seen) >= FTS_MAX_TERMS do return 1
	seen[strings.clone(word, context.temp_allocator)] = 1
	return 1
}

fts_remove_row :: proc(tx: ^Tx, table: Fts_Table, doc: Row_Id) -> Error {
	if documents, exists := tx.fts_new_docs[table.name]; exists {
		delete_key(&documents, doc)
	}
	length, existed := fts_doc_length(tx, table, doc)
	del_terms := strings.concatenate({"DELETE FROM ", table.terms, " WHERE doc = ?"}, tx.alloc)
	if delete_err := fts_run(tx, del_terms, []Value{value_int(i64(doc))}); delete_err.kind != .None {
		return delete_err
	}
	if !existed do return ERROR_NONE
	del_docs := strings.concatenate(
		{"DELETE FROM ", fts_docs_name(table.name, tx.alloc), " WHERE doc = ?"},
		tx.alloc,
	)
	if delete_err := fts_run(tx, del_docs, []Value{value_int(i64(doc))}); delete_err.kind != .None {
		return delete_err
	}
	return fts_stats_adjust(tx, table, -1, -length)
}

// fts_remove_row_length drops the postings and the length of one document and
// returns what it had, so an update adjusts the corpus totals once.
@(private)
fts_remove_row_length :: proc(tx: ^Tx, table: Fts_Table, doc: Row_Id) -> (length: int, existed: bool, err: Error) {
	length, existed = fts_doc_length(tx, table, doc)
	del_terms := strings.concatenate({"DELETE FROM ", table.terms, " WHERE doc = ?"}, tx.alloc)
	if delete_err := fts_run(tx, del_terms, []Value{value_int(i64(doc))}); delete_err.kind != .None {
		return 0, false, delete_err
	}
	if !existed do return 0, false, ERROR_NONE
	del_docs := strings.concatenate(
		{"DELETE FROM ", fts_docs_name(table.name, tx.alloc), " WHERE doc = ?"},
		tx.alloc,
	)
	if delete_err := fts_run(tx, del_docs, []Value{value_int(i64(doc))}); delete_err.kind != .None {
		return 0, false, delete_err
	}
	if adjust_err := fts_stats_adjust(tx, table, -1, -length); adjust_err.kind != .None {
		return 0, false, adjust_err
	}
	return length, true, ERROR_NONE
}

// --- Corpus statistics for BM25 -------------------------------------------

@(private)
fts_stats_name :: proc(name: string, alloc := context.temp_allocator) -> string {
	return strings.concatenate({"_fts_", name, "_stats"}, alloc)
}

@(private)
fts_docs_name :: proc(name: string, alloc := context.temp_allocator) -> string {
	return strings.concatenate({"_fts_", name, "_docs"}, alloc)
}

// fts_stats_read returns the number of documents and the total number of tokens,
// which is what BM25 needs for the average length.
@(private)
fts_stats_read :: proc(tx: ^Tx, table: Fts_Table) -> (docs: int, tokens: int) {
	sql := strings.concatenate(
		{"SELECT docs, tokens FROM ", fts_stats_name(table.name, tx.alloc), " WHERE id = 1"},
		tx.alloc,
	)
	result, err := sql_execute_in_tx(tx, sql)
	if err.kind != .None do return 0, 0
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 || len(result.rows[0]) < 2 do return 0, 0
	return int(result.rows[0][0].i), int(result.rows[0][1].i)
}

@(private)
fts_stats_adjust :: proc(tx: ^Tx, table: Fts_Table, docs_delta: int, tokens_delta: int) -> Error {
	docs, tokens := fts_stats_read(tx, table)
	next_docs := docs + docs_delta
	next_tokens := tokens + tokens_delta
	if next_docs < 0 do next_docs = 0
	if next_tokens < 0 do next_tokens = 0
	sql := strings.concatenate(
		{"UPDATE ", fts_stats_name(table.name, tx.alloc), " SET docs = ?, tokens = ? WHERE id = 1"},
		tx.alloc,
	)
	return fts_run(tx, sql, []Value{value_int(i64(next_docs)), value_int(i64(next_tokens))})
}

// fts_doc_length reads the token count of one document through its primary key.
@(private)
fts_doc_length :: proc(tx: ^Tx, table: Fts_Table, doc: Row_Id) -> (length: int, found: bool) {
	sql := strings.concatenate(
		{"SELECT length FROM ", fts_docs_name(table.name, tx.alloc), " WHERE doc = ?"},
		tx.alloc,
	)
	result, err := sql_execute_in_tx_params(tx, sql, []Value{value_int(i64(doc))})
	if err.kind != .None do return 0, false
	defer sql_result_destroy(&result)
	if len(result.rows) == 0 || len(result.rows[0]) < 1 do return 0, false
	return int(result.rows[0][0].i), true
}

@(private)
fts_is_word_byte :: proc(byte: u8) -> bool {
	return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte >= 0x80 || byte == '_'
}

@(private)
fts_fold_byte :: proc(byte: u8) -> u8 {
	if byte >= 'A' && byte <= 'Z' do return byte + 32
	return byte
}

// Fts_Match is the answer to one MATCH: the documents that satisfy it, and the
// BM25 score of each. Both are computed once per (table, pattern) and cached in
// the transaction, so the scan and ORDER BY rank share the work.
Fts_Match :: struct {
	docs:   map[Row_Id]bool,
	scores: map[Row_Id]f64,
}

// BM25 constants: the usual saturation (k1) and length normalisation (b).
FTS_BM25_K1 :: 1.2
FTS_BM25_B :: 0.75

// fts_match_docs answers "which documents contain this query, and how well".
// The pattern is a list separated by spaces: terms in a row must all be present,
// OR separates alternatives, AND is the juxtaposition it already is, and NOT
// removes the documents that carry the next term. The score is BM25 over the
// postings and the corpus totals, never over the documents: a query costs its
// matches, not the vocabulary.
fts_match_docs :: proc(tx: ^Tx, table: Fts_Table, pattern: string) -> (^Fts_Match, Error) {
	key := strings.concatenate({table.name, "\x00", pattern}, tx.alloc)
	if tx.fts_cache == nil do tx.fts_cache = make(map[string]^Fts_Match)
	if tx.fts_rank == nil do tx.fts_rank = make(map[string]string)
	if cached, found := tx.fts_cache[key]; found do return cached, ERROR_NONE

	match := new(Fts_Match)
	match.docs = make(map[Row_Id]bool)
	match.scores = make(map[Row_Id]f64)

	group := make([dynamic]map[Row_Id]int, 0, 4, context.temp_allocator)
	negative := make([dynamic]map[Row_Id]int, 0, 2, context.temp_allocator)
	positive: [dynamic]string
	defer {
		for set in group do delete(set)
		delete(group)
		for set in negative do delete(set)
		delete(negative)
		delete(positive)
	}
	negate_next := false
	for piece in strings.split(pattern, " ") {
		word := strings.trim_space(piece)
		if len(word) == 0 do continue
		if strings.equal_fold(word, "or") {
			fts_merge_group(&match.docs, group[:])
			clear(&group)
			continue
		}
		if strings.equal_fold(word, "not") {
			negate_next = true
			continue
		}
		// AND is the default between terms; spelling it out changes nothing.
		if strings.equal_fold(word, "and") do continue
		postings, postings_err := fts_term_rows(tx, table, word)
		if postings_err.kind != .None do return nil, postings_err
		if negate_next {
			append(&negative, postings)
			negate_next = false
		} else {
			append(&group, postings)
			append(&positive, strings.clone(fts_fold_word(word, tx.alloc), tx.alloc))
		}
	}
	fts_merge_group(&match.docs, group[:])
	for set in negative {
		for doc in set do delete_key(&match.docs, doc)
	}

	// Score every document that carries a query term. A document excluded by NOT
	// keeps its score; nothing reads it.
	docs_count, tokens := fts_stats_read(tx, table)
	average := docs_count > 0 ? f64(tokens) / f64(docs_count) : 0
	lengths := make(map[Row_Id]int, len(match.docs), context.temp_allocator)
	defer delete(lengths)
	for term in positive {
		postings, postings_err := fts_term_rows(tx, table, term)
		if postings_err.kind != .None do return nil, postings_err
		df := len(postings)
		// Okapi idf, shifted so it is never negative.
		idf := math.log(1 + (f64(docs_count) - f64(df) + 0.5) / (f64(df) + 0.5), math.E)
		for doc, tf in postings {
			length, known := lengths[doc]
			if !known {
				length, _ = fts_doc_length(tx, table, doc)
				lengths[doc] = length
			}
			length_ratio := average > 0 ? f64(length) / average : 0
			denominator := f64(tf) + FTS_BM25_K1 * (1 - FTS_BM25_B + FTS_BM25_B * length_ratio)
			match.scores[doc] += idf * f64(tf) * (FTS_BM25_K1 + 1) / denominator
		}
		delete(postings)
	}
	tx.fts_cache[key] = match
	tx.fts_rank[table.name] = key
	return match, ERROR_NONE
}

// fts_merge_group intersects the postings of one conjunction and adds them to the
// result: `a b` is narrower than `a`, and `a OR b` is wider.
@(private)
fts_merge_group :: proc(docs: ^map[Row_Id]bool, group: []map[Row_Id]int) {
	if len(group) == 0 do return
	if len(group) == 1 {
		for doc in group[0] do docs[doc] = true
		return
	}
	first := group[0]
	outer: for doc in first {
		for set, i in group {
			if i == 0 do continue
			if _, found := set[doc]; !found do continue outer
		}
		docs[doc] = true
	}
}

// fts_term_rows reads the postings of one term: document and count.
@(private)
fts_term_rows :: proc(tx: ^Tx, table: Fts_Table, word: string) -> (map[Row_Id]int, Error) {
	postings := make(map[Row_Id]int)
	sql := strings.concatenate({"SELECT doc, tf FROM ", table.terms, " WHERE term = ?"}, tx.alloc)
	result, err := sql_execute_in_tx_params(tx, sql, []Value{value_string(fts_fold_word(word, tx.alloc))})
	if err.kind != .None do return postings, err
	defer sql_result_destroy(&result)
	for row in result.rows {
		if len(row) < 2 do continue
		postings[Row_Id(row[0].i)] = int(row[1].i)
	}
	return postings, ERROR_NONE
}

@(private)
fts_fold_word :: proc(word: string, alloc := context.temp_allocator) -> string {
	out := make([]u8, len(word), alloc)
	for byte, i in transmute([]u8)word do out[i] = fts_fold_byte(byte)
	return string(out)
}

// fts_rank_value is the `rank` column of a full-text table: BM25 negated, so
// ORDER BY rank puts the best match first, the same convention SQLite's FTS5
// uses.
fts_rank_value :: proc(tx: ^Tx, table_name: string, doc: Row_Id) -> (f64, bool) {
	if tx == nil do return 0, false
	key, found := tx.fts_rank[table_name]
	if !found do return 0, false
	match := tx.fts_cache[key]
	if match == nil do return 0, false
	score, scored := match.scores[doc]
	if !scored do return 0, false
	return -score, true
}

// fts_query_terms splits a pattern into the positive terms it needs, folded the
// same way the index is.
@(private)
fts_query_terms :: proc(pattern: string, alloc: runtime.Allocator) -> map[string]bool {
	terms := make(map[string]bool, 8, alloc)
	for piece in strings.split(pattern, " ") {
		word := strings.trim_space(piece)
		if len(word) == 0 do continue
		if strings.equal_fold(word, "or") || strings.equal_fold(word, "and") || strings.equal_fold(word, "not") do continue
		terms[fts_fold_word(word, alloc)] = true
	}
	return terms
}

// fts_mark wraps every token that the pattern asks for with `[` and `]`. With
// `window` it keeps a few tokens around the first match instead of the whole
// text, which is what snippet() returns.
fts_mark :: proc(text: string, pattern: string, window: bool) -> string {
	terms := fts_query_terms(pattern, context.temp_allocator)
	defer delete(terms)
	Fts_Token :: struct {
		start: int,
		end:   int,
		word:  string,
	}
	tokens: [dynamic]Fts_Token
	defer delete(tokens)
	word := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&word)
	start := 0
	flush := proc(tokens: ^[dynamic]Fts_Token, start, end: int, word: ^strings.Builder) {
		if len(strings.to_string(word^)) == 0 do return
		append(tokens, Fts_Token{start = start, end = end, word = strings.clone(strings.to_string(word^), context.temp_allocator)})
		strings.builder_reset(word)
	}
	for b, i in transmute([]u8)text {
		if fts_is_word_byte(b) {
			if len(strings.to_string(word)) == 0 do start = i
			strings.write_byte(&word, fts_fold_byte(b))
			continue
		}
		flush(&tokens, start, i, &word)
	}
	flush(&tokens, start, len(text), &word)

	first_match := -1
	for token, i in tokens {
		if terms[token.word] {
			first_match = i
			break
		}
	}
	low, high := 0, len(tokens)
	if window && first_match >= 0 {
		low = first_match > 4 ? first_match - 4 : 0
		high = first_match + 8 < len(tokens) ? first_match + 8 : len(tokens)
	}
	out := strings.builder_make()
	position := low < len(tokens) ? tokens[low].start : len(text)
	if window && low > 0 do strings.write_string(&out, "…")
	for token, i in tokens {
		if i < low do continue
		if i >= high do break
		strings.write_string(&out, text[position:token.start])
		if terms[token.word] {
			strings.write_string(&out, "[")
			strings.write_string(&out, text[token.start:token.end])
			strings.write_string(&out, "]")
		} else {
			strings.write_string(&out, text[token.start:token.end])
		}
		position = token.end
	}
	if position < len(text) do strings.write_string(&out, text[position:])
	if window && high < len(tokens) do strings.write_string(&out, "…")
	return strings.to_string(out)
}

// fts_match_eval evaluates `documents MATCH 'pattern'` against the row being
// examined: the operand names a virtual table, and the row's id decides whether
// it is in the matching set.
fts_match_eval :: proc(tx: ^Tx, ctx: ^Eval_Ctx, operand: ^Expr, pattern: Value) -> (Value, Error) {
	table_name := ""
	if column, ok := operand^.(Column_Expr); ok {
		if len(column.table) > 0 {
			table_name = column.table
		} else {
			table_name = column.name
		}
	}
	if len(table_name) == 0 {
		return {}, errf(.Sql_Syntax, "MATCH needs a table on its left")
	}
	virtual: Fts_Table
	found := false
	for source in ctx.sources {
		if strings.equal_fold(source.table.schema.name, table_name) ||
		   (len(source.alias) > 0 && strings.equal_fold(source.alias, table_name)) {
			if candidate, is_virtual := fts_virtual_lookup(tx, source.table.schema.name); is_virtual {
				virtual = candidate
				found = true
			}
		}
	}
	if !found {
		if candidate, is_virtual := fts_virtual_lookup(tx, table_name); is_virtual {
			virtual = candidate
			found = true
		}
	}
	if !found do return {}, errf(.Table_Not_Found, "%s is not a full-text table", table_name)
	if pattern.kind != .String do return {}, errf(.Sql_Syntax, "MATCH needs a text pattern")
	match, match_err := fts_match_docs(tx, virtual, pattern.s)
	if match_err.kind != .None do return {}, match_err
	for source in ctx.sources {
		if strings.equal_fold(source.table.schema.name, virtual.name) {
			return value_int(match.docs[source.row.id] ? 1 : 0), ERROR_NONE
		}
	}
	return value_int(0), ERROR_NONE
}

// fts_index_if_virtual maintains the index when `table_name` names a virtual
// table, and does nothing (without touching the catalog) otherwise. A plain table
// costs one lookup of a table whose size is the number of virtual tables.
// `is_new` says the row did not exist before this statement, so the index can
// skip looking for postings that cannot be there.
fts_index_if_virtual :: proc(tx: ^Tx, table_name: string, doc: Row_Id, values: []Value, is_new: bool) -> Error {
	virtual, found := fts_virtual_lookup(tx, table_name)
	if !found || !fts_is_full_text(virtual) do return ERROR_NONE
	return fts_index_row(tx, virtual, doc, values, is_new)
}

fts_delete_if_virtual :: proc(tx: ^Tx, table_name: string, doc: Row_Id) -> Error {
	virtual, found := fts_virtual_lookup(tx, table_name)
	if !found || !fts_is_full_text(virtual) do return ERROR_NONE
	return fts_remove_row(tx, virtual, doc)
}

// fts_drop_if_virtual drops a virtual table, its shadow table and its catalog
// row together, keeping them from drifting apart.
fts_drop_if_virtual :: proc(tx: ^Tx, table_name: string, if_exists: bool) -> (bool, Error) {
	if _, found := fts_virtual_lookup(tx, table_name); !found do return false, ERROR_NONE
	return true, fts_drop(tx, table_name, if_exists)
}

// rtree_create makes a spatial table: the columns are the boxes themselves, so an
// overlap query is a range predicate the executor already knows how to answer.
//
//	CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx, miny, maxy)
//	SELECT id FROM places WHERE maxx >= 5 AND minx <= 5 AND maxy >= 5 AND miny <= 5
//
// The stored layout is the table's own columns rather than an R-tree node file;
// range predicates decide what overlaps, which gives the same rows an R-tree
// would, with a scan instead of a tree descent. That difference is written down
// in docs/sql.md rather than hidden: a bounded query is cheap, an unbounded one
// is a scan.
rtree_create :: proc(tx: ^Tx, name: string, module: string, columns: []string) -> Error {
	if len(columns) < 5 do return errf(
		.Invalid_Argument,
		"an rtree needs an id and at least four coordinates, got %d columns",
		len(columns),
	)
	coordinates := len(columns) - 1
	if coordinates % 2 != 0 do return errf(
		.Invalid_Argument,
		"an rtree needs an even number of coordinates (min,max pairs), got %d",
		coordinates,
	)
	if err := fts_ensure(tx); err.kind != .None do return err
	integer := strings.equal_fold(module, "rtree_i32")
	create := strings.concatenate({"CREATE TABLE IF NOT EXISTS ", name, " ("}, tx.alloc)
	for column, i in columns {
		if i > 0 do create = strings.concatenate({create, ", "}, tx.alloc)
		if i == 0 {
			// SQLite names the first column `id`; it is the row handle.
			create = strings.concatenate({create, column, " INTEGER PRIMARY KEY AUTOINCREMENT"}, tx.alloc)
			continue
		}
		create = strings.concatenate({create, column, integer ? " INTEGER" : " REAL"}, tx.alloc)
	}
	create = strings.concatenate({create, ")"}, tx.alloc)
	if err := fts_run(tx, create); err.kind != .None do return err
	values := []Value {
		value_string(strings.clone(name, tx.alloc)),
		value_string(strings.clone(module, tx.alloc)),
		value_string(strings.clone(strings.join(columns, ","), tx.alloc)),
	}
	if _, insert_err := tx_insert(tx, VIRTUAL_TABLE, values); insert_err.kind != .None do return insert_err
	return ERROR_NONE
}
