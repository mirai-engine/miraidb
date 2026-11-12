/* Embedding example: a tiny address book.
 *
 * Build the library first:
 *     odin build src/capi -build-mode:shared -out:bin/miraidb.dll
 * then compile this file against include/miraidb.h and link with the library.
 *
 * The same program works against a native database or a SQLite file: point it
 * at either and the import happens transparently.
 */

#include <stdio.h>
#include <string.h>

#include "miraidb.h"

static void fail(miraidb_conn db, const char *what) {
    fprintf(stderr, "%s: %s\n", what, miraidb_errmsg(db));
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "address_book.db";
    miraidb_conn db = miraidb_open(path);
    if (!db) {
        fprintf(stderr, "cannot open %s\n", path);
        return 1;
    }

    if (miraidb_exec(db, "CREATE TABLE IF NOT EXISTS people ("
                         "id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)") != MIRAIDB_OK) {
        fail(db, "create");
        miraidb_close(db);
        return 1;
    }

    miraidb_stmt insert = miraidb_prepare(db, "INSERT INTO people (id, name, age) VALUES (?, ?, ?)");
    struct { long long id; const char *name; long long age; } people[] = {
        {1, "Ada", 36}, {2, "Grace", 45}, {3, "Lin", 31},
    };
    for (size_t i = 0; i < sizeof people / sizeof people[0]; i++) {
        miraidb_bind_int(insert, 0, people[i].id);
        miraidb_bind_text(insert, 1, people[i].name);
        miraidb_bind_int(insert, 2, people[i].age);
        if (miraidb_step(insert) == MIRAIDB_ERROR) {
            fail(db, "insert");
            miraidb_finalize(insert);
            miraidb_close(db);
            return 1;
        }
        miraidb_reset(insert);
    }
    miraidb_finalize(insert);

    miraidb_stmt query = miraidb_prepare(db, "SELECT id, name, age FROM people WHERE age > ? ORDER BY id");
    miraidb_bind_int(query, 0, 32);
    printf("%-4s %-8s %s\n", "id", "name", "age");
    while (miraidb_step(query) == MIRAIDB_ROW) {
        printf("%-4lld %-8s %lld\n",
               miraidb_column_int(query, 0),
               miraidb_column_text(query, 1),
               miraidb_column_int(query, 2));
    }
    miraidb_finalize(query);

    miraidb_close(db);
    return 0;
}
