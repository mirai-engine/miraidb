/*
** sqlite3_miraidb.h -- the subset of SQLite's C API that sqlite3_miraidb.dll
** implements, declared so a C program can compile against it.
**
** This is not sqlite3.h. It declares the 119 functions the facade exports and the
** result codes they answer; a program that uses anything else will not link, and
** that is the honest state of the facade (119 of SQLite's 315 symbols). Look at
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
typedef struct sqlite3_context sqlite3_context;
typedef struct sqlite3_value sqlite3_value;

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
/* With statements still open, the connection closes when the last one is
** finalized; the call answers SQLITE_OK. */
int         sqlite3_close_v2(sqlite3 *db);
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
const char *sqlite3_errstr(int code);
int         sqlite3_error_offset(sqlite3 *db);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3 *db);
void        sqlite3_set_last_insert_rowid(sqlite3 *db, sqlite3_int64 rowid);
sqlite3_int64 sqlite3_changes64(sqlite3 *db);
sqlite3_int64 sqlite3_total_changes64(sqlite3 *db);
/* 0 while a BEGIN or a SAVEPOINT holds a transaction open, 1 otherwise. */
int         sqlite3_get_autocommit(sqlite3 *db);

/* --- Statements ---------------------------------------------------------- */

int          sqlite3_prepare_v2(sqlite3 *db, const char *sql, int nByte,
                                sqlite3_stmt **stmt, const char **tail);
/* The flags are hints to SQLite's own cache and change nothing here. */
int          sqlite3_prepare_v3(sqlite3 *db, const char *sql, int nByte,
                                unsigned int flags, sqlite3_stmt **stmt,
                                const char **tail);
int          sqlite3_prepare(sqlite3 *db, const char *sql, int nByte,
                             sqlite3_stmt **stmt, const char **tail);
int          sqlite3_step(sqlite3_stmt *stmt);
int          sqlite3_reset(sqlite3_stmt *stmt);
int          sqlite3_clear_bindings(sqlite3_stmt *stmt);
int          sqlite3_finalize(sqlite3_stmt *stmt);
sqlite3     *sqlite3_db_handle(sqlite3_stmt *stmt);
const char  *sqlite3_sql(sqlite3_stmt *stmt);
int          sqlite3_stmt_readonly(sqlite3_stmt *stmt);
int          sqlite3_stmt_busy(sqlite3_stmt *stmt);
int          sqlite3_stmt_isexplain(sqlite3_stmt *stmt);
/* RUN and VM_STEP (one per step here) answer; the bytecode counters answer 0. */
#define SQLITE_STMTSTATUS_FULLSCAN_STEP  1
#define SQLITE_STMTSTATUS_SORT           2
#define SQLITE_STMTSTATUS_AUTOINDEX      3
#define SQLITE_STMTSTATUS_VM_STEP        4
#define SQLITE_STMTSTATUS_REPREPARE      5
#define SQLITE_STMTSTATUS_RUN            6
int          sqlite3_stmt_status(sqlite3_stmt *stmt, int op, int reset);

int          sqlite3_bind_null(sqlite3_stmt *stmt, int index);
int          sqlite3_bind_int(sqlite3_stmt *stmt, int index, int value);
int          sqlite3_bind_int64(sqlite3_stmt *stmt, int index, sqlite3_int64 value);
int          sqlite3_bind_double(sqlite3_stmt *stmt, int index, double value);
int          sqlite3_bind_text(sqlite3_stmt *stmt, int index, const char *value,
                               int length, void *destructor);
int          sqlite3_bind_blob(sqlite3_stmt *stmt, int index, const void *data,
                               int length, void *destructor);
int          sqlite3_bind_zeroblob(sqlite3_stmt *stmt, int index, int n);
/* Parameters are ?, ?NNN, :name, @name and $name, numbered as SQLite numbers
** them; a name includes its prefix, and a bare ? has no name (NULL). */
int          sqlite3_bind_parameter_count(sqlite3_stmt *stmt);
const char  *sqlite3_bind_parameter_name(sqlite3_stmt *stmt, int index);
int          sqlite3_bind_parameter_index(sqlite3_stmt *stmt, const char *name);
/* The text with the bound values in place; free it with sqlite3_free. */
char        *sqlite3_expanded_sql(sqlite3_stmt *stmt);
int          sqlite3_bind_zeroblob64(sqlite3_stmt *stmt, int index,
                                     sqlite3_uint64 n);
/* Binds a NULL that carries `pointer` for sqlite3_value_pointer(v, type); the
** destructor runs when the parameter is bound again, the bindings are cleared
** or the statement is finalized. */
int          sqlite3_bind_pointer(sqlite3_stmt *stmt, int index, void *pointer,
                                  const char *type, void (*destructor)(void *));

int          sqlite3_column_count(sqlite3_stmt *stmt);
/* The column count while a row is available, 0 otherwise. */
int          sqlite3_data_count(sqlite3_stmt *stmt);
/* Where a result column comes from, right after prepare: NULL for an
** expression, and for every column when a source is not a table (a derived
** table, a CTE, a view). The declared type is the engine's name for it --
** INTEGER, REAL, TEXT or BLOB -- not the text a CREATE TABLE spelled. */
const char  *sqlite3_column_decltype(sqlite3_stmt *stmt, int index);
const char  *sqlite3_column_database_name(sqlite3_stmt *stmt, int index);
const char  *sqlite3_column_table_name(sqlite3_stmt *stmt, int index);
const char  *sqlite3_column_origin_name(sqlite3_stmt *stmt, int index);
const char  *sqlite3_column_name(sqlite3_stmt *stmt, int index);
int          sqlite3_column_type(sqlite3_stmt *stmt, int index);
int          sqlite3_column_int(sqlite3_stmt *stmt, int index);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt *stmt, int index);
double       sqlite3_column_double(sqlite3_stmt *stmt, int index);
const char  *sqlite3_column_text(sqlite3_stmt *stmt, int index);
const void  *sqlite3_column_blob(sqlite3_stmt *stmt, int index);
int          sqlite3_column_bytes(sqlite3_stmt *stmt, int index);
int          sqlite3_column_bytes16(sqlite3_stmt *stmt, int index);

/* --- UTF-16 ----------------------------------------------------------------
** The UTF-16 face of the calls above, converted at the boundary: "16" is the
** machine's byte order, LE and BE name one. A column's text lives until the
** statement moves, a column's name or origin until finalize, a value's text as
** long as the value, the error message until the next call that changes it. */

#define SQLITE_UTF16LE        2
#define SQLITE_UTF16BE        3
#define SQLITE_UTF16          4

int          sqlite3_open16(const void *filename, sqlite3 **db);
const void  *sqlite3_errmsg16(sqlite3 *db);
int          sqlite3_prepare16(sqlite3 *db, const void *sql, int nByte,
                               sqlite3_stmt **stmt, const void **tail);
int          sqlite3_prepare16_v2(sqlite3 *db, const void *sql, int nByte,
                                  sqlite3_stmt **stmt, const void **tail);
int          sqlite3_prepare16_v3(sqlite3 *db, const void *sql, int nByte,
                                  unsigned int flags, sqlite3_stmt **stmt,
                                  const void **tail);
int          sqlite3_bind_text16(sqlite3_stmt *stmt, int index, const void *value,
                                 int nBytes, void *destructor);
/* encoding is SQLITE_UTF8, SQLITE_UTF16LE, SQLITE_UTF16BE or SQLITE_UTF16. */
int          sqlite3_bind_text64(sqlite3_stmt *stmt, int index, const char *value,
                                 sqlite3_uint64 nBytes, void *destructor,
                                 unsigned char encoding);
const void  *sqlite3_column_text16(sqlite3_stmt *stmt, int index);
const void  *sqlite3_column_name16(sqlite3_stmt *stmt, int index);
const void  *sqlite3_column_decltype16(sqlite3_stmt *stmt, int index);
const void  *sqlite3_column_database_name16(sqlite3_stmt *stmt, int index);
const void  *sqlite3_column_table_name16(sqlite3_stmt *stmt, int index);
const void  *sqlite3_column_origin_name16(sqlite3_stmt *stmt, int index);

/* --- Application-defined functions ----------------------------------------
** A scalar function gives xFunc; an aggregate gives xStep and xFinal and keeps
** its accumulator in sqlite3_aggregate_context memory. A function with a
** builtin's name replaces it, except an aggregate builtin (count, sum, ...),
** which keeps its name: registering one answers SQLITE_ERROR. Values arrive as
** UTF-8 whatever eTextRep says. Auxiliary data lives for one call. */

#define SQLITE_UTF8           1
#define SQLITE_DETERMINISTIC  0x000000800

int  sqlite3_create_function(sqlite3 *db, const char *name, int nArg,
                             int eTextRep, void *pApp,
                             void (*xFunc)(sqlite3_context *, int, sqlite3_value **),
                             void (*xStep)(sqlite3_context *, int, sqlite3_value **),
                             void (*xFinal)(sqlite3_context *));
int  sqlite3_create_function_v2(sqlite3 *db, const char *name, int nArg,
                                int eTextRep, void *pApp,
                                void (*xFunc)(sqlite3_context *, int, sqlite3_value **),
                                void (*xStep)(sqlite3_context *, int, sqlite3_value **),
                                void (*xFinal)(sqlite3_context *),
                                void (*xDestroy)(void *));

void        *sqlite3_user_data(sqlite3_context *ctx);
sqlite3     *sqlite3_context_db_handle(sqlite3_context *ctx);
void        *sqlite3_aggregate_context(sqlite3_context *ctx, int nBytes);
void        *sqlite3_get_auxdata(sqlite3_context *ctx, int n);
void         sqlite3_set_auxdata(sqlite3_context *ctx, int n, void *data,
                                 void (*destructor)(void *));

int                  sqlite3_value_type(sqlite3_value *value);
int                  sqlite3_value_numeric_type(sqlite3_value *value);
int                  sqlite3_value_int(sqlite3_value *value);
sqlite3_int64        sqlite3_value_int64(sqlite3_value *value);
double               sqlite3_value_double(sqlite3_value *value);
const unsigned char *sqlite3_value_text(sqlite3_value *value);
const void          *sqlite3_value_blob(sqlite3_value *value);
int                  sqlite3_value_bytes(sqlite3_value *value);
sqlite3_value       *sqlite3_value_dup(const sqlite3_value *value);
void                 sqlite3_value_free(sqlite3_value *value);
const void          *sqlite3_value_text16(sqlite3_value *value);
const void          *sqlite3_value_text16le(sqlite3_value *value);
const void          *sqlite3_value_text16be(sqlite3_value *value);
int                  sqlite3_value_bytes16(sqlite3_value *value);
/* The pointer a value carries when it was bound or returned with the same
** type name; NULL otherwise. To SQL such a value is NULL, and a copy made with
** sqlite3_value_dup or a row that stores it holds a plain NULL. */
void                *sqlite3_value_pointer(sqlite3_value *value, const char *type);
/* A value never carries a subtype, a no-change mark or a bind origin here. */
unsigned int         sqlite3_value_subtype(sqlite3_value *value);
int                  sqlite3_value_nochange(sqlite3_value *value);
int                  sqlite3_value_frombind(sqlite3_value *value);

void sqlite3_result_null(sqlite3_context *ctx);
void sqlite3_result_int(sqlite3_context *ctx, int value);
void sqlite3_result_int64(sqlite3_context *ctx, sqlite3_int64 value);
void sqlite3_result_double(sqlite3_context *ctx, double value);
void sqlite3_result_text(sqlite3_context *ctx, const char *text, int n,
                         void (*destructor)(void *));
void sqlite3_result_text64(sqlite3_context *ctx, const char *text,
                           sqlite3_uint64 n, void (*destructor)(void *),
                           unsigned char encoding);
void sqlite3_result_blob(sqlite3_context *ctx, const void *data, int n,
                         void (*destructor)(void *));
void sqlite3_result_blob64(sqlite3_context *ctx, const void *data,
                           sqlite3_uint64 n, void (*destructor)(void *));
void sqlite3_result_zeroblob(sqlite3_context *ctx, int n);
int  sqlite3_result_zeroblob64(sqlite3_context *ctx, sqlite3_uint64 n);
void sqlite3_result_value(sqlite3_context *ctx, sqlite3_value *value);
void sqlite3_result_error(sqlite3_context *ctx, const char *message, int n);
void sqlite3_result_error_code(sqlite3_context *ctx, int code);
void sqlite3_result_error_nomem(sqlite3_context *ctx);
void sqlite3_result_error_toobig(sqlite3_context *ctx);
/* Accepted and dropped: subtypes are not carried. */
void sqlite3_result_subtype(sqlite3_context *ctx, unsigned int subtype);
void sqlite3_result_text16(sqlite3_context *ctx, const void *text, int nBytes,
                           void (*destructor)(void *));
void sqlite3_result_text16le(sqlite3_context *ctx, const void *text, int nBytes,
                             void (*destructor)(void *));
void sqlite3_result_text16be(sqlite3_context *ctx, const void *text, int nBytes,
                             void (*destructor)(void *));
void sqlite3_result_error16(sqlite3_context *ctx, const void *message, int nBytes);
/* The destructor runs when the step that made the value ends. */
void sqlite3_result_pointer(sqlite3_context *ctx, void *pointer, const char *type,
                            void (*destructor)(void *));
int  sqlite3_create_function16(sqlite3 *db, const void *name, int nArg,
                               int eTextRep, void *pApp,
                               void (*xFunc)(sqlite3_context *, int, sqlite3_value **),
                               void (*xStep)(sqlite3_context *, int, sqlite3_value **),
                               void (*xFinal)(sqlite3_context *));

/* --- Collations -----------------------------------------------------------
** A comparison SQL names with COLLATE: it answers in WHERE, ON, CASE, IN and
** BETWEEN; ORDER BY (a window's too) ranks the values under it; GROUP BY,
** DISTINCT and PARTITION BY group by the classes it makes; a column may be
** declared with it, but not a key: an index orders folded text and refuses it.
** BINARY, NOCASE and RTRIM may be replaced on the connection; an index under
** a replaced name is not read meanwhile. A NULL comparison deletes the
** collation (a deleted replacement gives the built-in back); the destructor runs
** on replace, delete and close. A UTF-16 text representation hands the
** comparison UTF-16 bytes. */

int sqlite3_create_collation(sqlite3 *db, const char *name, int eTextRep,
                             void *pArg,
                             int (*xCompare)(void *, int, const void *, int, const void *));
int sqlite3_create_collation_v2(sqlite3 *db, const char *name, int eTextRep,
                                void *pArg,
                                int (*xCompare)(void *, int, const void *, int, const void *),
                                void (*xDestroy)(void *));
int sqlite3_create_collation16(sqlite3 *db, const void *name, int eTextRep,
                               void *pArg,
                               int (*xCompare)(void *, int, const void *, int, const void *));
/* Called when a statement names a collation nobody registered; the callback may
** register it then. */
int sqlite3_collation_needed(sqlite3 *db, void *pArg,
                             void (*callback)(void *, sqlite3 *, int, const char *));
int sqlite3_collation_needed16(sqlite3 *db, void *pArg,
                               void (*callback)(void *, sqlite3 *, int, const void *));

/* --- Virtual table modules -------------------------------------------------
** A module's table is read whole each time a statement names it: xBestIndex
** is offered the arguments written after the name (`FROM t(1, 2)`, as
** equality constraints on the HIDDEN columns in order) and the WHERE terms
** `column op constant`, xFilter receives the ones it numbered, and the rows
** come from xOpen/xEof/xColumn/xRowid/xNext; the WHERE is applied to them
** afterwards whatever the module did. A table after the first of a join is
** read once per outer row, with its arguments and its ON terms bound to that
** row. INSERT, UPDATE and DELETE call xUpdate with SQLite's arguments; xBegin,
** xSync, xCommit and xRollback (and, from iVersion 2, xSavepoint, xRelease and
** xRollbackTo) follow the transaction that wrote; ALTER TABLE RENAME calls
** xRename; xFindFunction overloads a function whose first argument is one of
** the table's columns. xShadowName and xIntegrity are not called. */

typedef struct sqlite3_vtab sqlite3_vtab;
typedef struct sqlite3_index_info sqlite3_index_info;
typedef struct sqlite3_vtab_cursor sqlite3_vtab_cursor;
typedef struct sqlite3_module sqlite3_module;

struct sqlite3_module {
  int iVersion;
  int (*xCreate)(sqlite3 *, void *pAux, int argc, const char *const *argv,
                 sqlite3_vtab **ppVTab, char **pzErr);
  int (*xConnect)(sqlite3 *, void *pAux, int argc, const char *const *argv,
                  sqlite3_vtab **ppVTab, char **pzErr);
  int (*xBestIndex)(sqlite3_vtab *pVTab, sqlite3_index_info *);
  int (*xDisconnect)(sqlite3_vtab *pVTab);
  int (*xDestroy)(sqlite3_vtab *pVTab);
  int (*xOpen)(sqlite3_vtab *pVTab, sqlite3_vtab_cursor **ppCursor);
  int (*xClose)(sqlite3_vtab_cursor *);
  int (*xFilter)(sqlite3_vtab_cursor *, int idxNum, const char *idxStr,
                 int argc, sqlite3_value **argv);
  int (*xNext)(sqlite3_vtab_cursor *);
  int (*xEof)(sqlite3_vtab_cursor *);
  int (*xColumn)(sqlite3_vtab_cursor *, sqlite3_context *, int);
  int (*xRowid)(sqlite3_vtab_cursor *, sqlite3_int64 *pRowid);
  int (*xUpdate)(sqlite3_vtab *, int, sqlite3_value **, sqlite3_int64 *);
  int (*xBegin)(sqlite3_vtab *pVTab);
  int (*xSync)(sqlite3_vtab *pVTab);
  int (*xCommit)(sqlite3_vtab *pVTab);
  int (*xRollback)(sqlite3_vtab *pVTab);
  int (*xFindFunction)(sqlite3_vtab *pVtab, int nArg, const char *zName,
                       void (**pxFunc)(sqlite3_context *, int, sqlite3_value **),
                       void **ppArg);
  int (*xRename)(sqlite3_vtab *pVtab, const char *zNew);
  int (*xSavepoint)(sqlite3_vtab *pVTab, int);
  int (*xRelease)(sqlite3_vtab *pVTab, int);
  int (*xRollbackTo)(sqlite3_vtab *pVTab, int);
  int (*xShadowName)(const char *);
  int (*xIntegrity)(sqlite3_vtab *pVTab, const char *zSchema,
                    const char *zTabName, int mFlags, char **pzErr);
};

struct sqlite3_index_info {
  int nConstraint;
  struct sqlite3_index_constraint {
    int iColumn;
    unsigned char op;
    unsigned char usable;
    int iTermOffset;
  } *aConstraint;
  int nOrderBy;
  struct sqlite3_index_orderby {
    int iColumn;
    unsigned char desc;
  } *aOrderBy;
  struct sqlite3_index_constraint_usage {
    int argvIndex;
    unsigned char omit;
  } *aConstraintUsage;
  int idxNum;
  char *idxStr;
  int needToFreeIdxStr;
  int orderByConsumed;
  double estimatedCost;
  sqlite3_int64 estimatedRows;
  int idxFlags;
  sqlite3_uint64 colUsed;
};

struct sqlite3_vtab {
  const sqlite3_module *pModule;
  int nRef;
  char *zErrMsg;
};

struct sqlite3_vtab_cursor {
  sqlite3_vtab *pVtab;
};

#define SQLITE_INDEX_CONSTRAINT_EQ  2
#define SQLITE_INDEX_CONSTRAINT_GT  4
#define SQLITE_INDEX_CONSTRAINT_LE  8
#define SQLITE_INDEX_CONSTRAINT_LT 16
#define SQLITE_INDEX_CONSTRAINT_GE 32

int sqlite3_create_module(sqlite3 *db, const char *zName, const sqlite3_module *p,
                          void *pClientData);
int sqlite3_create_module_v2(sqlite3 *db, const char *zName,
                             const sqlite3_module *p, void *pClientData,
                             void (*xDestroy)(void *));
/* Drops every module not named in the NULL-terminated list (all when NULL). */
int sqlite3_drop_modules(sqlite3 *db, const char **azKeep);
int sqlite3_declare_vtab(sqlite3 *db, const char *zSQL);
/* Accepted from inside xCreate or xConnect; changes nothing here. */
int sqlite3_vtab_config(sqlite3 *db, int op, ...);
/* SQLITE_ABORT: the only conflict mode a module write sees here. */
int sqlite3_vtab_on_conflict(sqlite3 *db);
/* Always 0 / "BINARY" / 0 / 0 here: no column is left unchanged, constraints
** compare in BINARY, DISTINCT is not passed, IN is offered value by value. */
int sqlite3_vtab_nochange(sqlite3_context *ctx);
const char *sqlite3_vtab_collation(sqlite3_index_info *info, int iCons);
int sqlite3_vtab_distinct(sqlite3_index_info *info);
int sqlite3_vtab_in(sqlite3_index_info *info, int iCons, int bHandle);
int sqlite3_vtab_in_first(sqlite3_value *pVal, sqlite3_value **ppOut);
int sqlite3_vtab_in_next(sqlite3_value *pVal, sqlite3_value **ppOut);
/* The constant of a constraint, while xBestIndex runs. */
int sqlite3_vtab_rhs_value(sqlite3_index_info *info, int iCons, sqlite3_value **ppVal);

/* --- Connection hooks ----------------------------------------------------
** Each call replaces the hook and answers the argument the previous one had;
** NULL removes it. The update hook sees every changed row of a user table
** (not the rows a REPLACE removes); a commit hook that answers non-zero turns
** the commit into a rollback, reported as SQLITE_CONSTRAINT_COMMITHOOK; the
** rollback hook runs for ROLLBACK, a vetoed commit, and a statement that fails
** in autocommit, not for a connection closed with a transaction open. */

#define SQLITE_DELETE   9
#define SQLITE_INSERT  18
#define SQLITE_UPDATE  23
#define SQLITE_CONSTRAINT_COMMITHOOK  (SQLITE_CONSTRAINT | (2 << 8))

void *sqlite3_commit_hook(sqlite3 *db, int (*callback)(void *), void *arg);
void *sqlite3_rollback_hook(sqlite3 *db, void (*callback)(void *), void *arg);
/* The progress handler runs every n rows a statement visits (SQLite counts
** bytecode instructions); a non-zero answer interrupts the statement. */
void  sqlite3_progress_handler(sqlite3 *db, int n, int (*callback)(void *),
                               void *arg);
void *sqlite3_update_hook(sqlite3 *db,
                          void (*callback)(void *, int, const char *,
                                           const char *, sqlite3_int64),
                          void *arg);

/* --- Authorizer ------------------------------------------------------------
** Asked while a statement is prepared, with SQLite's action codes and
** arguments: SQLITE_OK allows, SQLITE_DENY fails the prepare (SQLITE_AUTH),
** SQLITE_IGNORE reads a column as NULL, leaves an assigned column alone, or
** makes the statement do nothing. The order of the questions is not SQLite's;
** the questions are, except those about SQLite's own sqlite_* tables, which
** this engine does not have. The sixth argument (trigger or view) is NULL. */

#define SQLITE_DENY    1
#define SQLITE_IGNORE  2

#define SQLITE_CREATE_INDEX        1
#define SQLITE_CREATE_TABLE        2
#define SQLITE_CREATE_TEMP_TABLE   4
#define SQLITE_CREATE_TRIGGER      7
#define SQLITE_CREATE_VIEW         8
#define SQLITE_DROP_INDEX         10
#define SQLITE_DROP_TABLE         11
#define SQLITE_DROP_TRIGGER       16
#define SQLITE_DROP_VIEW          17
#define SQLITE_PRAGMA             19
#define SQLITE_READ               20
#define SQLITE_SELECT             21
#define SQLITE_TRANSACTION        22
#define SQLITE_ATTACH             24
#define SQLITE_DETACH             25
#define SQLITE_ALTER_TABLE        26
#define SQLITE_REINDEX            27
#define SQLITE_ANALYZE            28
#define SQLITE_FUNCTION           31
#define SQLITE_SAVEPOINT          32

int sqlite3_set_authorizer(sqlite3 *db,
                           int (*callback)(void *, int, const char *,
                                           const char *, const char *,
                                           const char *),
                           void *arg);

/* --- Trace -----------------------------------------------------------------
** STMT when a statement starts running (X is its text), ROW for each row,
** PROFILE when it ends (X points at the nanoseconds it ran), CLOSE when the
** connection closes (P is the connection). */

#define SQLITE_TRACE_STMT     0x01
#define SQLITE_TRACE_PROFILE  0x02
#define SQLITE_TRACE_ROW      0x04
#define SQLITE_TRACE_CLOSE    0x08

int sqlite3_trace_v2(sqlite3 *db, unsigned int mask,
                     int (*callback)(unsigned int, void *, void *, void *),
                     void *ctx);

/* A placeholder for name/nArg that fails with "unable to use function ... in
** the requested context", unless this connection registered one. */
int sqlite3_overload_function(sqlite3 *db, const char *name, int nArg);

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

/* --- The database as a whole ---------------------------------------------
** The image is SQLite's file format. A backup copies the source as it is at
** the last step, in one transaction of the destination; only "main" can be
** named. A deserialized connection stops writing the file it was opened on. */

#define SQLITE_SERIALIZE_NOCOPY         0x001
#define SQLITE_DESERIALIZE_FREEONCLOSE  1
#define SQLITE_DESERIALIZE_RESIZEABLE   2
#define SQLITE_DESERIALIZE_READONLY     4
#define SQLITE_TXN_NONE   0
#define SQLITE_TXN_READ   1
#define SQLITE_TXN_WRITE  2

typedef struct sqlite3_backup sqlite3_backup;

unsigned char *sqlite3_serialize(sqlite3 *db, const char *schema,
                                 sqlite3_int64 *size, unsigned int flags);
int sqlite3_deserialize(sqlite3 *db, const char *schema, unsigned char *data,
                        sqlite3_int64 db_size, sqlite3_int64 buffer_size,
                        unsigned int flags);
sqlite3_backup *sqlite3_backup_init(sqlite3 *dest, const char *dest_name,
                                    sqlite3 *source, const char *source_name);
int  sqlite3_backup_step(sqlite3_backup *backup, int pages);
int  sqlite3_backup_finish(sqlite3_backup *backup);
int  sqlite3_backup_remaining(sqlite3_backup *backup);
int  sqlite3_backup_pagecount(sqlite3_backup *backup);
const char *sqlite3_db_filename(sqlite3 *db, const char *schema);
const char *sqlite3_db_name(sqlite3 *db, int index);
int  sqlite3_db_readonly(sqlite3 *db, const char *schema);
int  sqlite3_txn_state(sqlite3 *db, const char *schema);

/* --- Library ------------------------------------------------------------- */

const char *sqlite3_libversion(void);
int         sqlite3_libversion_number(void);
const char *sqlite3_sourceid(void);
int         sqlite3_initialize(void);
int         sqlite3_shutdown(void);

/* What the library hands over to be freed (an exec error message) comes from
** this allocator and goes back through sqlite3_free. */
void         *sqlite3_malloc(int size);
void         *sqlite3_malloc64(sqlite3_uint64 size);
void         *sqlite3_realloc(void *pointer, int size);
void         *sqlite3_realloc64(void *pointer, sqlite3_uint64 size);
sqlite3_uint64 sqlite3_msize(void *pointer);
void          sqlite3_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif /* SQLITE3_MIRAIDB_H */
