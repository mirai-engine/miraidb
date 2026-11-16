/*
** sqlite3_miraidb.h -- the subset of SQLite's C API that sqlite3_miraidb.dll
** implements, declared so a C program can compile against it.
**
** This is not sqlite3.h. It declares the 43 functions the facade exports and the
** result codes they answer; a program that uses anything else will not link, and
** that is the honest state of the facade (43 of SQLite's 315 symbols). Look at
** docs/sqlite.md for what each one does here and where it differs.
**
** Build the library with:
**
**     odin build src/sqlite_compat -build-mode:shared -out:sqlite3_miraidb.dll
**
** and link it instead of sqlite3, or dlopen it at run time. Do not include both
** this header and sqlite3.h in one translation unit: the names are the same on
** purpose, and the point is that one replaces the other.
**
** Opening a SQLite file imports it into memory: writes do not reach the file the
** engine did not create. Opening any other path creates an engine database
** directory, which persists.
*/
#ifndef SQLITE3_MIRAIDB_H
#define SQLITE3_MIRAIDB_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>   /* size_t */
#include <stdint.h>   /* int64_t */

typedef int64_t sqlite3_int64;
typedef uint64_t sqlite3_uint64;
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef struct sqlite3_blob sqlite3_blob;

/* Result codes, SQLite's numbers. */
#define SQLITE_OK           0
#define SQLITE_ERROR        1
#define SQLITE_BUSY         5
#define SQLITE_NOMEM        7
#define SQLITE_READONLY     8
#define SQLITE_INTERRUPT    9
#define SQLITE_IOERR       10
#define SQLITE_CORRUPT     11
#define SQLITE_TOOBIG      13
#define SQLITE_CONSTRAINT  19
#define SQLITE_MISMATCH    20
#define SQLITE_MISUSE      21
#define SQLITE_AUTH        23
#define SQLITE_RANGE       25
#define SQLITE_NOTADB      26
#define SQLITE_ROW        100
#define SQLITE_DONE       101

/* Extended constraint codes, reported by sqlite3_extended_errcode and by
** sqlite3_errcode once sqlite3_extended_result_codes is on. */
#define SQLITE_CONSTRAINT_CHECK       (SQLITE_CONSTRAINT | (1 << 8))
#define SQLITE_CONSTRAINT_FOREIGNKEY  (SQLITE_CONSTRAINT | (3 << 8))
#define SQLITE_CONSTRAINT_NOTNULL     (SQLITE_CONSTRAINT | (5 << 8))
#define SQLITE_CONSTRAINT_PRIMARYKEY  (SQLITE_CONSTRAINT | (6 << 8))
#define SQLITE_CONSTRAINT_UNIQUE      (SQLITE_CONSTRAINT | (8 << 8))

/* Storage classes, as sqlite3_column_type answers them. */
#define SQLITE_INTEGER  1
#define SQLITE_FLOAT    2
#define SQLITE_TEXT     3
#define SQLITE_BLOB     4
#define SQLITE_NULL     5

/* sqlite3_open_v2 flags: accepted and unused; see docs/sqlite.md. */
#define SQLITE_OPEN_READONLY   0x00000001
#define SQLITE_OPEN_READWRITE  0x00000002
#define SQLITE_OPEN_CREATE     0x00000004
#define SQLITE_OPEN_MEMORY     0x00000080
#define SQLITE_OPEN_URI        0x00000040

/* Passed as the destructor to the bind calls: the facade copies the value, so
** the caller keeps ownership and no destructor runs. */
#define SQLITE_STATIC      ((void *)0)
#define SQLITE_TRANSIENT   ((void *)-1)

/* The row callback of sqlite3_exec: values are the text form of each column,
** NULL for SQL NULL, and names are the column names. A non-zero answer stops
** the statement. */
typedef int (*sqlite3_callback)(
  void *arg,
  int count,
  char **values,
  char **names
);

/* --- Connection ---------------------------------------------------------- */

int         sqlite3_open(const char *filename, sqlite3 **db);
int         sqlite3_open_v2(const char *filename, sqlite3 **db, int flags,
                            const char *vfs);
int         sqlite3_close(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3 *db);
int         sqlite3_errcode(sqlite3 *db);
int         sqlite3_extended_errcode(sqlite3 *db);
void        sqlite3_interrupt(sqlite3 *db);
int         sqlite3_changes(sqlite3 *db);
int         sqlite3_total_changes(sqlite3 *db);
int         sqlite3_busy_timeout(sqlite3 *db, int milliseconds);
int         sqlite3_extended_result_codes(sqlite3 *db, int onoff);
int         sqlite3_exec(sqlite3 *db, const char *sql, sqlite3_callback callback,
                         void *arg, char **errmsg);

/* --- Statements ---------------------------------------------------------- */

int          sqlite3_prepare_v2(sqlite3 *db, const char *sql, int nByte,
                                sqlite3_stmt **stmt, const char **tail);
int          sqlite3_step(sqlite3_stmt *stmt);
int          sqlite3_reset(sqlite3_stmt *stmt);
int          sqlite3_clear_bindings(sqlite3_stmt *stmt);
int          sqlite3_finalize(sqlite3_stmt *stmt);

int          sqlite3_bind_null(sqlite3_stmt *stmt, int index);
int          sqlite3_bind_int(sqlite3_stmt *stmt, int index, int value);
int          sqlite3_bind_int64(sqlite3_stmt *stmt, int index, sqlite3_int64 value);
int          sqlite3_bind_double(sqlite3_stmt *stmt, int index, double value);
int          sqlite3_bind_text(sqlite3_stmt *stmt, int index, const char *value,
                               int length, void *destructor);
int          sqlite3_bind_blob(sqlite3_stmt *stmt, int index, const void *data,
                               int length, void *destructor);

int          sqlite3_column_count(sqlite3_stmt *stmt);
const char  *sqlite3_column_name(sqlite3_stmt *stmt, int index);
int          sqlite3_column_type(sqlite3_stmt *stmt, int index);
int          sqlite3_column_int(sqlite3_stmt *stmt, int index);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt *stmt, int index);
double       sqlite3_column_double(sqlite3_stmt *stmt, int index);
const char  *sqlite3_column_text(sqlite3_stmt *stmt, int index);
const void  *sqlite3_column_blob(sqlite3_stmt *stmt, int index);
int          sqlite3_column_bytes(sqlite3_stmt *stmt, int index);
int          sqlite3_column_bytes16(sqlite3_stmt *stmt, int index);

/* --- Incremental BLOB I/O ------------------------------------------------
** The row is named by a single-column primary key, which plays the part of
** SQLite's rowid; a table without one is refused with SQLITE_ERROR. */

int  sqlite3_blob_open(sqlite3 *db, const char *database, const char *table,
                       const char *column, sqlite3_int64 row, int writable,
                       sqlite3_blob **blob);
int  sqlite3_blob_bytes(sqlite3_blob *blob);
int  sqlite3_blob_read(sqlite3_blob *blob, void *buffer, int count, int offset);
int  sqlite3_blob_write(sqlite3_blob *blob, const void *buffer, int count,
                        int offset);
int  sqlite3_blob_reopen(sqlite3_blob *blob, sqlite3_int64 row);
int  sqlite3_blob_close(sqlite3_blob *blob);

/* --- Library ------------------------------------------------------------- */

const char *sqlite3_libversion(void);
int         sqlite3_initialize(void);
int         sqlite3_shutdown(void);
void        sqlite3_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif /* SQLITE3_MIRAIDB_H */
