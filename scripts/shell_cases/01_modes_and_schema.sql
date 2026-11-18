CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, score REAL, note TEXT);
INSERT INTO people VALUES (1, 'Ada', 36, 9.5, NULL), (2, 'Grace', 45, 8.25, 'navy'), (3, 'Linus', 21, NULL, 'it''s');
CREATE INDEX people_age ON people (age);
CREATE VIEW adults AS SELECT name, age FROM people WHERE age >= 30;
SELECT * FROM people ORDER BY id;
.headers on
SELECT * FROM people ORDER BY id;
.mode csv
SELECT * FROM people ORDER BY id;
.mode column
SELECT * FROM people ORDER BY id;
.mode box
SELECT * FROM people ORDER BY id;
.mode table
SELECT * FROM people ORDER BY id;
.mode markdown
SELECT * FROM people ORDER BY id;
.mode json
SELECT * FROM people ORDER BY id;
.mode line
SELECT * FROM people WHERE id = 2;
.mode insert people
SELECT * FROM people ORDER BY id;
.mode quote
SELECT * FROM people ORDER BY id;
.mode html
SELECT * FROM people WHERE id = 1;
.mode tabs
SELECT * FROM people ORDER BY id;
.mode list
.nullvalue NULL
.separator ;
SELECT * FROM people ORDER BY id;
.separator |
.nullvalue ''
.tables
.indexes
.indexes people
.schema
.schema people
.dump
.print hello from the shell
SELECT count(*), sum(age), avg(score), group_concat(name, ',') FROM people;
SELECT name FROM adults ORDER BY name;
SELECT typeof(1), typeof(1.5), typeof('x'), typeof(x'00'), typeof(NULL);
SELECT 1/0, 7 % 3, 2.0 * 3, 'a' || 'b', length('héllo'), upper('abc'), round(2.5), abs(-3);
SELECT printf('%5.2f|%q|%d', 3.14159, 'it''s', 42);
UPDATE people SET age = age + 1 WHERE id = 3;
.changes on
UPDATE people SET age = age + 1 WHERE id = 3;
DELETE FROM people WHERE id = 99;
.changes off
SELECT * FROM nowhere;
SELECT * FROM people WHERE;
.databases
