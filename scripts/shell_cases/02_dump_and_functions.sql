CREATE TABLE log (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT DEFAULT '2026-01-01', msg TEXT, data BLOB);
CREATE TABLE totals (k TEXT PRIMARY KEY, n INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
CREATE TRIGGER log_count AFTER INSERT ON log BEGIN
  INSERT INTO totals (k, n) VALUES ('rows', 1) ON CONFLICT (k) DO UPDATE SET n = n + 1;
END;
INSERT INTO log (msg, data) VALUES ('héllo wörld', x'00ff10'), ('tab	inside', NULL), ('quote''s', x''), ('multi
line', zeroblob(3));
SELECT id, msg, hex(data), length(data) FROM log ORDER BY id;
SELECT * FROM totals;
SELECT * FROM sqlite_sequence;
.mode qbox
SELECT id, msg FROM log ORDER BY id;
.mode column
.width 3 -12
SELECT id, msg FROM log ORDER BY id;
.width
.mode list
.headers off
BEGIN;
INSERT INTO log (msg) VALUES ('in a transaction');
SELECT count(*) FROM log;
ROLLBACK;
SELECT count(*) FROM log;
BEGIN;
INSERT INTO log (msg) VALUES ('kept');
COMMIT;
SELECT msg FROM log WHERE id = (SELECT max(id) FROM log);
INSERT INTO totals (k) VALUES ('rows');
SELECT 1e100, 1e-100, 123456789012345678, -0.0, 0.1 + 0.2, 9223372036854775807 + 1;
SELECT round(3.14159, 2), cast('12abc' AS INTEGER), cast(3.9 AS INTEGER), 7 / 2, 7.0 / 2, 10 % 3;
SELECT substr('héllo', 2, 3), instr('banana', 'an'), replace('aaa', 'a', 'b'), trim('  x  '), quote('it''s'), char(72, 105);
SELECT coalesce(NULL, NULL, 'z'), ifnull(NULL, 1), nullif(1, 1), iif(1 > 2, 'a', 'b');
SELECT date('2026-11-18', '+1 month'), strftime('%Y-%j', '2026-03-01'), julianday('2000-01-01');
SELECT json_object('a', 1, 'b', json_array(1, 2)), json_extract('{"x":[1,2]}', '$.x[1]');
SELECT group_concat(msg, ' | ') FROM (SELECT msg FROM log ORDER BY id LIMIT 2);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5) SELECT sum(i), max(i) FROM n;
SELECT id, row_number() OVER (ORDER BY id DESC) FROM log ORDER BY id LIMIT 3;
.dump
.schema totals
.print done
