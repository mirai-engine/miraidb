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
 * MIRAIDB_MISUSE (2) when the handle is not live (a statement used after
 * finalize, or anything used through a connection already closed: the call does
 * nothing and the process keeps running), MIRAIDB_DENIED (3) for a token that is
 * unknown or expired,
 * MIRAIDB_ROW (100) when a step produced a row and MIRAIDB_DONE (101) when the
 * statement finished.
 *
 * Strings are UTF-8 and NUL-terminated. Text and blob pointers returned by the
 * column accessors are borrowed: they stay valid until the next step, reset or
 * finalize of that statement.
 *
 * Threads: a connection, and every statement made from it, belongs to one thread
 * at a time. Two threads may use two connections on the same file - the engine
 * takes a reader/writer lock on the file - and miraidb_interrupt is the one call
 * that may run on another thread while a statement is executing. Nothing else is
 * synchronised: opening the same path twice in one process, sharing a statement,
 * or closing a connection while another thread uses it is a data race, not a
 * refused call.
 */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct miraidb_connection miraidb_connection;
typedef struct miraidb_statement miraidb_statement;

typedef void *miraidb_conn;

/* Flags for miraidb_open_ex; several may be combined. miraidb_open(path) is
 * miraidb_open_ex(path, 0). A path that is already a SQLite file is imported
 * into memory and mirrored back after every commit, whatever the flags say. */
#define MIRAIDB_OPEN_READ_ONLY 1  /* take the reader's lock; every write refused */
#define MIRAIDB_OPEN_IN_MEMORY 2  /* nothing on disk, gone on close */
#define MIRAIDB_OPEN_NO_SYNC   4  /* never fsync the log (faster, less safe) */
#define MIRAIDB_OPEN_PAGED     8  /* keep new tables in page files, not in RAM */
typedef void *miraidb_stmt;

#define MIRAIDB_OK     0
#define MIRAIDB_ERROR  1
#define MIRAIDB_MISUSE 2
#define MIRAIDB_DENIED 3
#define MIRAIDB_ROW    100
#define MIRAIDB_DONE   101

#define MIRAIDB_NULL  0
#define MIRAIDB_BOOL  1
#define MIRAIDB_INT   2
#define MIRAIDB_FLOAT 3
#define MIRAIDB_TEXT  4
#define MIRAIDB_BLOB  5
#define MIRAIDB_OTHER 6

/* Opens the engine format, or imports a .sqlite/.db file into memory. */
miraidb_conn miraidb_open(const char *path);
miraidb_conn miraidb_open_ex(const char *path, int flags);
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
/* Parameter indexes are zero-based: `index` 0 binds the first `?`. An index at
 * or past the number of parameters the statement binds is refused with
 * MIRAIDB_ERROR instead of growing the parameter list. */
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

/* Caps for one statement. Both belong to the connection's session, are not part
 * of the database, and survive a commit; zero removes the cap. A statement that
 * overruns either is refused with MIRAIDB_ERROR and miraidb_errmsg names which
 * cap it hit. miraidb_work_used reports what this connection has spent so far. */
int          miraidb_set_row_quota(miraidb_conn db, unsigned long long rows);
int          miraidb_set_work_budget(miraidb_conn db, unsigned long long units);
unsigned long long miraidb_work_used(miraidb_conn db);

/* Asks the statement running on any thread to stop; the next statement on this
 * connection starts with a clean flag, so an interrupted call leaves the
 * connection usable. A dead handle answers MIRAIDB_MISUSE and does nothing. */
int miraidb_interrupt(miraidb_conn db);

/* Identity and credentials. Row policies filter by the identity the connection
 * carries. A connection that never set one carries the all-zero identity, so a
 * policy that compares against current_identity() matches no row until an
 * identity or a token is set: an embedded caller that wants to be the host has
 * to say which identity that is. An identity is the 32 bytes of an IDENTITY
 * value, the same shape a token names - not text, and not a UUID string.
 *
 *   unsigned char id[32]; unsigned char out[32]; char token[128];
 *   miraidb_identity(db, out);              // who the policies see now
 *   miraidb_issue_token(db, id, 0, token, sizeof token);  // 0: never expires
 *   miraidb_authenticate(other, token);     // MIRAIDB_DENIED if unknown/expired
 *
 * miraidb_issue_token writes at most out_len bytes including the NUL and returns
 * the token's length, or -1 when the buffer is too small (a token is 67
 * characters, so 68 bytes always fit). ttl_us is microseconds, zero meaning no
 * expiry. A token is stored as an HMAC digest, so the database file does not hold
 * a usable credential. miraidb_authenticate leaves the identity unchanged when it
 * answers MIRAIDB_DENIED, and explains the reason through miraidb_errmsg. */
int  miraidb_set_identity(miraidb_conn db, const void *identity32);
int  miraidb_identity(miraidb_conn db, void *out32);
int  miraidb_issue_token(miraidb_conn db, const void *identity32,
                         long long ttl_us, char *out, unsigned long long out_len);
int  miraidb_authenticate(miraidb_conn db, const char *token);

const char *miraidb_version(void);

#ifdef __cplusplus
}
#endif

#endif /* MIRAIDB_H */
