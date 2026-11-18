CREATE TABLE w(b, a TEXT PRIMARY KEY, c INT) WITHOUT ROWID;
CREATE INDEX wc ON w(c);
CREATE TABLE z(x, y, z, PRIMARY KEY(z, x), UNIQUE(y)) WITHOUT ROWID;
CREATE TABLE n(id INTEGER PRIMARY KEY, v) WITHOUT ROWID;
INSERT INTO w VALUES(1, 'x', 3), (2, 'a', 30), (NULL, 'm', -1);
INSERT INTO z VALUES('x1', 'y1', 2), ('x0', 'y2', 2), ('x9', 'y3', 1);
INSERT INTO n VALUES(5, 'five'), (-1, 'minus');
WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 2000) INSERT INTO n SELECT i + 100, printf('v%d', i) FROM s;
.schema
SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;
SELECT * FROM w;
SELECT * FROM z;
SELECT count(*), sum(id), min(v), max(v) FROM n;
SELECT * FROM w WHERE c = 30;
SELECT x FROM z WHERE y = 'y3';
PRAGMA index_list(z);
PRAGMA index_list(w);
UPDATE w SET c = 31 WHERE a = 'a';
DELETE FROM n WHERE id > 1000;
SELECT count(*) FROM n;
.dump w z
PRAGMA integrity_check;
