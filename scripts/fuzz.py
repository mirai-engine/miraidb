#!/usr/bin/env python3
"""Fuzz the engine: random SQL must never take the process down.

The harness creates a database with a known schema, then feeds a seeded stream of
statements to one REPL process per chunk. Half of them are valid SQL, half are
deliberately broken (wrong arity, unknown tables, unbalanced syntax). The engine
may reject anything it likes, but it must answer with an error and keep running,
and the database must stay consistent afterwards:

    python3 scripts/fuzz.py --statements 500 --seed 1
    python3 scripts/fuzz.py --statements 5000 --seconds 120

Exit code 0 means every chunk survived, `PRAGMA integrity_check` answered `ok`
after each one, and no output looked like a crash.
"""

from __future__ import annotations

import argparse
import os
import random
import re
import shutil
import subprocess
import sys
import time

SCHEMA = [
    "CREATE TABLE IF NOT EXISTS account (id INTEGER PRIMARY KEY, name TEXT UNIQUE, balance INTEGER NOT NULL DEFAULT 0, kind TEXT)",
    "CREATE TABLE IF NOT EXISTS entry (id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER, amount INTEGER, memo TEXT, FOREIGN KEY (account_id) REFERENCES account (id))",
    "CREATE INDEX IF NOT EXISTS entry_amount ON entry (amount)",
    "CREATE INDEX IF NOT EXISTS entry_account ON entry USING HASH (account_id)",
    "INSERT INTO account (id, name, balance, kind) SELECT 1, 'one', 100, 'savings' WHERE NOT EXISTS (SELECT 1 FROM account WHERE id = 1)",
    "INSERT INTO account (id, name, balance, kind) SELECT 2, 'two', 200, 'current' WHERE NOT EXISTS (SELECT 1 FROM account WHERE id = 2)",
    "INSERT INTO account (id, name, balance, kind) SELECT 3, 'three', 300, NULL WHERE NOT EXISTS (SELECT 1 FROM account WHERE id = 3)",
]

TABLES = ["account", "entry"]
COLUMNS = {
    "account": ["id", "name", "balance", "kind"],
    "entry": ["id", "account_id", "amount", "memo"],
}
LITERALS = ["0", "1", "-1", "42", "2.5", "'x'", "'two'", "NULL", "x'00ff'", "''", "9223372036854775808"]
OPERATORS = ["=", "<>", "<", ">", "<=", ">="]
FUNCTIONS = ["abs", "length", "upper", "lower", "coalesce", "round", "typeof", "hex", "sum", "count", "avg"]
PRAGMAS = [
    "PRAGMA table_info(account)",
    "PRAGMA index_list(entry)",
    "PRAGMA foreign_key_check",
    "PRAGMA integrity_check",
    "PRAGMA stats",
    "PRAGMA journal_mode",
    "PRAGMA schema_version",
    "PRAGMA user_version",
]


def literal(rng: random.Random) -> str:
    return rng.choice(LITERALS)


def column(rng: random.Random, tables: list[str]) -> str:
    table = rng.choice(tables)
    return rng.choice(COLUMNS[table])


def where(rng: random.Random, tables: list[str], depth: int = 0) -> str:
    shape = rng.randrange(0, 7 if depth < 2 else 4)
    if shape == 0:
        return f"{column(rng, tables)} IS NULL"
    if shape == 1:
        return f"{column(rng, tables)} IS NOT NULL"
    if shape == 2:
        return f"{column(rng, tables)} {rng.choice(OPERATORS)} {literal(rng)}"
    if shape == 3:
        return f"{column(rng, tables)} LIKE '%{rng.choice(['a', 'o', '_'])}%'"
    if shape == 4:
        return f"({where(rng, tables, depth + 1)}) AND ({where(rng, tables, depth + 1)})"
    if shape == 5:
        return f"({where(rng, tables, depth + 1)}) OR ({where(rng, tables, depth + 1)})"
    return f"NOT ({where(rng, tables, depth + 1)})"


def select(rng: random.Random) -> str:
    shape = rng.randrange(0, 8)
    if shape == 0:
        return f"SELECT * FROM {rng.choice(TABLES)} LIMIT {rng.randrange(0, 20)}"
    if shape == 1:
        return f"SELECT count(*), sum(amount) FROM entry WHERE {where(rng, ['entry'])}"
    if shape == 2:
        return (
            "SELECT account.name, count(*), sum(entry.amount) FROM account "
            "JOIN entry ON account.id = entry.account_id "
            f"GROUP BY account.name HAVING count(*) > {rng.randrange(0, 3)}"
        )
    if shape == 3:
        return (
            "SELECT a.name, b.amount FROM account a JOIN entry b "
            f"ON a.id = b.account_id WHERE {where(rng, ['account', 'entry'])} "
            f"ORDER BY b.amount DESC LIMIT {rng.randrange(0, 10)}"
        )
    if shape == 4:
        return f"SELECT {rng.choice(FUNCTIONS)}({column(rng, ['entry'])}) FROM entry"
    if shape == 5:
        return (
            "SELECT id, row_number() OVER (PARTITION BY account_id ORDER BY id) AS n "
            "FROM entry LIMIT 10"
        )
    if shape == 6:
        return (
            "SELECT account.name FROM account WHERE account.id IN "
            "(SELECT account_id FROM entry WHERE amount > 0)"
        )
    return f"SELECT {column(rng, TABLES)} FROM {rng.choice(TABLES)} ORDER BY 1 DESC LIMIT 5"


def mutation(rng: random.Random) -> str:
    shape = rng.randrange(0, 6)
    if shape == 0:
        return (
            "INSERT INTO account (name, balance, kind) VALUES "
            f"('n{rng.randrange(0, 50)}', {rng.randrange(-100, 1000)}, {literal(rng)})"
        )
    if shape == 1:
        return (
            "INSERT INTO entry (account_id, amount, memo) VALUES "
            f"({rng.randrange(1, 6)}, {rng.randrange(-50, 500)}, {literal(rng)})"
        )
    if shape == 2:
        return f"UPDATE account SET balance = balance + {rng.randrange(-10, 10)} WHERE {where(rng, ['account'])}"
    if shape == 3:
        return f"DELETE FROM entry WHERE {where(rng, ['entry'])}"
    if shape == 4:
        return f"UPDATE entry SET amount = {rng.randrange(0, 100)} WHERE {where(rng, ['entry'])}"
    return f"INSERT OR REPLACE INTO entry (id, account_id, amount) VALUES ({rng.randrange(1, 40)}, {rng.randrange(1, 4)}, {rng.randrange(0, 100)})"


def ddl(rng: random.Random) -> str:
    shape = rng.randrange(0, 6)
    if shape == 0:
        return f"CREATE INDEX IF NOT EXISTS fuzz_idx_{rng.randrange(0, 3)} ON entry (memo)"
    if shape == 1:
        return f"DROP INDEX IF EXISTS fuzz_idx_{rng.randrange(0, 3)}"
    if shape == 2:
        return f"ALTER TABLE entry ADD COLUMN extra_{rng.randrange(0, 2)} INTEGER DEFAULT 0"
    if shape == 3:
        return "ALTER TABLE entry DROP COLUMN extra_0"
    if shape == 4:
        return rng.choice(PRAGMAS)
    return "VACUUM"


def broken(rng: random.Random) -> str:
    shape = rng.randrange(0, 8)
    if shape == 0:
        return f"SELECT * FROM {rng.choice(['nope', 'account', 'acount', '_internal'])}"
    if shape == 1:
        return f"INSERT INTO account (name) VALUES ({literal(rng)}, {literal(rng)})"
    if shape == 2:
        return rng.choice(["SELECT", "FROM", "WHERE", "SELECT * FROM", "INSERT INTO", ")("])
    if shape == 3:
        return f"SELECT {column(rng, TABLES)} FROM {rng.choice(TABLES)} WHERE {column(rng, TABLES)} ="
    if shape == 4:
        return "UPDATE nope SET a = 1"
    if shape == 5:
        return "SELECT * FROM account JOIN entry"
    if shape == 6:
        return f"INSERT INTO entry (account_id) VALUES ('{rng.randrange(1, 999)}')"
    return "PRAGMA made_up_setting = 7"


def statement(rng: random.Random) -> str:
    roll = rng.randrange(0, 100)
    if roll < 45:
        text = select(rng)
    elif roll < 75:
        text = mutation(rng)
    elif roll < 90:
        text = ddl(rng)
    else:
        text = broken(rng)
    if rng.randrange(0, 20) == 0:
        text += ";"
    return text


def run_repl(binary: str, database: str, statements: list[str], timeout: float) -> tuple[int, str]:
    script = "".join(f"{text};\n" for text in statements)
    try:
        done = subprocess.run(
            [binary, "repl", database],
            input=script,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as expired:
        output = (expired.stdout or "") + (expired.stderr or "")
        return -1, output if isinstance(output, str) else output.decode("utf-8", "replace")
    return done.returncode, done.stdout + done.stderr


def run_sql(binary: str, database: str, sql: str, timeout: float = 30) -> tuple[int, str]:
    done = subprocess.run(
        [binary, "sql", database, sql],
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    return done.returncode, done.stdout + done.stderr


CRASH = re.compile(r"panic|Illegal instruction|Segmentation|assertion|bad free|stack trace", re.IGNORECASE)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default="./bin/miraidb.exe", help="the CLI to fuzz")
    parser.add_argument("--statements", type=int, default=500, help="statements to generate")
    parser.add_argument("--chunk", type=int, default=50, help="statements per process")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--seconds", type=float, default=0, help="stop after this long, whatever the count")
    parser.add_argument("--database", default="_fuzz_db", help="scratch database directory")
    parser.add_argument("--timeout", type=float, default=120, help="seconds per chunk")
    parser.add_argument("--keep", action="store_true", help="leave the database for inspection")
    args = parser.parse_args()

    if not os.path.exists(args.bin):
        print(f"fuzz: {args.bin} not found; build first", file=sys.stderr)
        return 2
    rng = random.Random(args.seed)
    shutil.rmtree(args.database, ignore_errors=True)
    started = time.monotonic()
    problems = 0
    executed = 0
    if not os.path.exists(args.database):
        code, output = run_sql(args.bin, args.database, SCHEMA[0])
        if code != 0:
            print(f"fuzz: cannot create the database: {output}", file=sys.stderr)
            return 2
    for setup in SCHEMA:
        code, output = run_sql(args.bin, args.database, setup)
        if code != 0:
            print(f"fuzz: schema setup failed (exit {code}): {output!r}", file=sys.stderr)
            print(f"fuzz: statement was: {setup}", file=sys.stderr)
            return 2

    try:
        while executed < args.statements:
            if args.seconds and time.monotonic() - started > args.seconds:
                break
            chunk = [statement(rng) for _ in range(min(args.chunk, args.statements - executed))]
            executed += len(chunk)
            code, output = run_repl(args.bin, args.database, chunk, args.timeout)
            if code != 0 or CRASH.search(output):
                problems += 1
                print(f"fuzz: chunk failed (exit {code}) after {executed} statements", file=sys.stderr)
                for line in output.splitlines()[-25:]:
                    print(f"    {line}", file=sys.stderr)
                for text in chunk:
                    print(f"    statement: {text}", file=sys.stderr)
                break
            code, output = run_sql(args.bin, args.database, "PRAGMA integrity_check")
            if code != 0 or "ok" not in output:
                problems += 1
                print(f"fuzz: integrity_check failed after {executed} statements", file=sys.stderr)
                for line in output.splitlines()[:10]:
                    print(f"    {line}", file=sys.stderr)
                break
            print(f"fuzz: {executed} statements, {time.monotonic() - started:.1f}s")
    finally:
        if not args.keep:
            shutil.rmtree(args.database, ignore_errors=True)

    elapsed = time.monotonic() - started
    if problems:
        print(f"fuzz: FAILED after {executed} statements in {elapsed:.1f}s", file=sys.stderr)
        return 1
    print(f"fuzz: ok, {executed} statements in {elapsed:.1f}s ({executed / max(elapsed, 1e-9):.1f}/s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
