#ifndef MIRAIDB_H
#define MIRAIDB_H

/*
 * miraidb - embeddable relational database.
 *
 * The C ABI is the language-neutral way into the engine. Build the shared
 * library with:
 *
 *     odin build src/capi -build-mode:shared -out:libmiraidb.so
 *
 * then link with -lmiraidb. Handles are opaque pointers; a connection owns its
 * database, and statements belong to their connection.
 *
 * Return codes: MIRAIDB_OK (0) on success, MIRAIDB_ERROR (1) on failure,
 * MIRAIDB_ROW (100) when a step produced a row and MIRAIDB_DONE (101) when the
 * statement finished.
 *
 * Strings are UTF-8 and NUL-terminated. Text and blob pointers returned by the
 * column accessors are borrowed: they stay valid until the next step, reset or
 * finalize of that statement.
 */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct miraidb_connection miraidb_connection;
typedef struct miraidb_statement miraidb_statement;

typedef void *miraidb_conn;
typedef void *miraidb_stmt;

#define MIRAIDB_OK    0
#define MIRAIDB_ERROR 1
#define MIRAIDB_ROW   100
#define MIRAIDB_DONE  101

#define MIRAIDB_NULL  0
#define MIRAIDB_BOOL  1
#define MIRAIDB_INT   2
#define MIRAIDB_FLOAT 3
#define MIRAIDB_TEXT  4
#define MIRAIDB_BLOB  5
#define MIRAIDB_OTHER 6

/* Opens the engine format, or imports a .sqlite/.db file into memory. */
miraidb_conn miraidb_open(const char *path);
void         miraidb_close(miraidb_conn db);

/* Last error for the connection, or an empty string. When db is NULL, the
   reason the last miraidb_open failed. */
const char  *miraidb_errmsg(miraidb_conn db);

/* Runs one statement without parameters. */
int miraidb_exec(miraidb_conn db, const char *sql);

/* Writes a compacted copy of the database at path; the copy is a full database. */
int miraidb_backup(miraidb_conn db, const char *path);

/* Prepared statements. `index` is zero-based. */
miraidb_stmt miraidb_prepare(miraidb_conn db, const char *sql);
/* Parameter indexes are zero-based: `index` 0 binds the first `?`. */
int  miraidb_bind_null(miraidb_stmt stmt, int index);
int  miraidb_bind_int(miraidb_stmt stmt, int index, long long value);
int  miraidb_bind_double(miraidb_stmt stmt, int index, double value);
int  miraidb_bind_text(miraidb_stmt stmt, int index, const char *value);
int  miraidb_bind_blob(miraidb_stmt stmt, int index, const void *data, int length);

/* Executes on the first call, then advances one row at a time. */
int  miraidb_step(miraidb_stmt stmt);
void miraidb_reset(miraidb_stmt stmt);
void miraidb_finalize(miraidb_stmt stmt);

/* Rows produced by the last executed statement. */
int         miraidb_changes(miraidb_stmt stmt);
int         miraidb_column_count(miraidb_stmt stmt);
const char *miraidb_column_name(miraidb_stmt stmt, int index);
int         miraidb_column_type(miraidb_stmt stmt, int index);
long long   miraidb_column_int(miraidb_stmt stmt, int index);
double      miraidb_column_double(miraidb_stmt stmt, int index);
const char *miraidb_column_text(miraidb_stmt stmt, int index);
const void *miraidb_column_bytes(miraidb_stmt stmt, int index, int *length);
int         miraidb_column_is_null(miraidb_stmt stmt, int index);

const char *miraidb_version(void);

#ifdef __cplusplus
}
#endif

#endif /* MIRAIDB_H */
