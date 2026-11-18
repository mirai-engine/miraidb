CREATE TABLE t(a INTEGER, b TEXT, c REAL, d, e NUMERIC, f BLOB, "g h" VARCHAR(10));
INSERT INTO t VALUES (1, 'x', 1.5, 'any', 3, x'00', 'gh'), (2, 'y', 2.5, 7, 4.0, NULL, NULL);
CREATE TABLE v AS SELECT * FROM t;
CREATE TABLE w AS SELECT a, a + 1, 'lit', 1.5, CAST(a AS TEXT) AS ct, a AS "select", b AS a FROM t;
CREATE TABLE IF NOT EXISTS v AS SELECT 1;
CREATE TABLE longnamedtable_for_the_threshold AS SELECT a AS first_column_name, b AS second_column_name FROM t;
CREATE TABLE e AS SELECT * FROM t WHERE 0;
CREATE TABLE s AS SELECT count(*) AS n, max(b) AS m FROM t;
SELECT name, sql FROM sqlite_schema;
SELECT * FROM w;
SELECT * FROM s;
SELECT typeof(a), typeof(d), typeof(e) FROM v;
PRAGMA table_info(w);
.schema e
.dump w
