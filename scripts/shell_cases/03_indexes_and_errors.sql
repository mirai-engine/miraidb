.headers on
CREATE TABLE a (x INTEGER PRIMARY KEY, y TEXT UNIQUE);
CREATE TABLE c (p, q, PRIMARY KEY (p, q));
CREATE TABLE d (m UNIQUE, n TEXT PRIMARY KEY, o, UNIQUE(o, m));
CREATE INDEX ay ON a (y) WHERE y > 'm';
CREATE UNIQUE INDEX ax2 ON a (x, y);
CREATE INDEX dn ON d (n);
CREATE VIEW v AS SELECT x, y, x + 1 AS z FROM a;
CREATE TABLE s (k TEXT) STRICT;
PRAGMA index_list(a);
PRAGMA index_list(c);
PRAGMA index_list(d);
PRAGMA table_info(v);
PRAGMA "main".table_info='a';
PRAGMA table_info(sqlite_schema);
SELECT type, name, tbl_name, rootpage > 0, sql FROM sqlite_schema ORDER BY rowid;
SELECT * FROM pragma_table_list ORDER BY schema, name;
.indexes
.indexes a
.schema v
.fullschema
.headers off
SELECT * FROM a WHERE;
SELECT * FRM a;
SELECT a.* x FROM a;
SELECT (1 + ;
CREAT TABLE x (a);
SELECT 'abc;
