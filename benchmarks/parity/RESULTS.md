# The reference suite: results

`benchmarks/parity` runs the reference database's own benchmark suite (its raw
datastore against SQLite: same schemas, same generated rows, same sizes) through
this engine's in-process API. Both suites ran on the same Windows machine on
2026-11-16, one after the other on an idle box. The reference and SQLite figures
are Criterion's estimates (`--warm-up-time 1 --measurement-time 3`), and this
engine's are the median of 60 to 5 000 runs. Times in microseconds; lower is
better.

## Before (the first run)

### In memory

| Workload | This engine | Reference | SQLite | Engine ÷ reference |
|---|---:|---:|---:|---:|
| empty transaction | 0.70 | 0.62 | 0.64 | 1.1× |
| insert_bulk u32_u64_str unique_0 (256 rows onto 2 048) | 1 645 | 267 | 139 | 6.2× |
| insert_bulk u32_u64_str btree_each_column | 1 605 | 528 | 739 | 3.0× |
| insert_bulk u32_u64_u64 unique_0 | 1 425 | 194 | 124 | 7.3× |
| insert_bulk u32_u64_u64 btree_each_column | 1 310 | 391 | 486 | 3.3× |
| iterate 256 rows (u32_u64_str) | 15.1 | 1.65 | 29.2 | 9.2× |
| iterate 256 rows (u32_u64_u64) | 16.2 | 1.47 | 24.4 | 11× |
| update_bulk 256 of 2 048 (u32_u64_str) | 2 339 | 493 | 53.8 | 4.7× |
| update_bulk 256 of 2 048 (u32_u64_u64) | 2 012 | 396 | 44.7 | 5.1× |
| filter, string index, 256 of 2 048 | 14.8 | 4.05 | 91.8 | 3.7× |
| filter, u64 index, 256 of 2 048 | 14.3 | 4.06 | 82.3 | 3.5× |

### On disk

The reference's durable test database commits before its log reaches the disk
(a background worker syncs it); this engine's `disk` mode is the same contract
(`durability = .None`: written, not synced).

| Workload | This engine | Reference | SQLite | Engine ÷ reference |
|---|---:|---:|---:|---:|
| empty transaction | 0.70 | 0.63 | 0.65 | 1.1× |
| insert_bulk u32_u64_str unique_0 | 3 761 | 450 | 199 | 8.4× |
| insert_bulk u32_u64_u64 unique_0 | 3 405 | 234 | 239 | 15× |
| iterate 256 rows (u32_u64_str) | 16.8 | 1.59 | 36.5 | 11× |
| update_bulk (u32_u64_str) | 4 257 | 707 | 84.2 | 6.0× |
| filter, string index | 14.2 | 4.16 | 103 | 3.4× |

## After the write-path round

Six changes to the write path, measured in two batches (the first four took 256
inserts from 1 645 to 1 031 us, the last two to 762):

| Change | Where |
|---|---|
| a commit sorts the row ids it applies with the typed sort | `map_keys_sorted` |
| a store nobody watches does not clone every value for the commit hook | `tx_commit` |
| a store with no log does not encode a payload it would throw away; the memory log appends a record at once, not byte by byte | `tx_commit`, `log_append` |
| an insert is not probed for uniqueness a second time when its own commit applies it (staging checked it under the same write lock); updates still are, because two rows that swap keys collide halfway through | `apply_validated`, `table_insert` |
| a table name is cloned into the read set once per transaction, not on every lookup | `tx_table`, `tx_table_probe` |
| unique keys are encoded straight into the transaction arena, and "does another row hold this key" walks the index in place instead of building a list of ids | `unique_key`, `tx_committed_key_taken` |

In memory, median of the quietest of three runs (the minimums agree within 10%):

| Workload | Before | After | Reference | After ÷ reference |
|---|---:|---:|---:|---:|
| empty transaction | 0.70 | 0.50 | 0.62 | **0.8×** |
| insert_bulk u32_u64_str unique_0 | 1 645 | 762 | 267 | 2.9× |
| insert_bulk u32_u64_str btree_each_column | 1 605 | 868 | 528 | 1.6× |
| insert_bulk u32_u64_u64 unique_0 | 1 425 | 612 | 194 | 3.2× |
| insert_bulk u32_u64_u64 btree_each_column | 1 310 | 757 | 391 | 1.9× |
| update_bulk u32_u64_str | 2 339 | 1 142 | 493 | 2.3× |
| update_bulk u32_u64_u64 | 2 012 | 1 007 | 396 | 2.5× |

On disk the medians moved by 3× between runs with the same binary (the OS's
write path, not the engine), so this table gives the minimum of 60 runs; the
reference figure is Criterion's estimate, which sits nearer its median, so the
ratio flatters this engine somewhat:

| Workload | Before (min) | After (min) | Reference | After ÷ reference |
|---|---:|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 2 007 | 1 339 | 450 | 3.0× |
| insert_bulk u32_u64_u64 unique_0 | 1 776 | 1 124 | 234 | 4.8× |
| update_bulk u32_u64_str | 2 439 | 1 689 | 707 | 2.4× |
| update_bulk u32_u64_u64 | 2 285 | 1 505 | 440 | 3.4× |

## Third round: per-row lookups

Measured with timers on every phase, the step planned next (hand staged rows to
the table instead of copying them) was worth about 4% of an insert: the copy is
one allocation per row. The larger shares were elsewhere, and this round took
them:

| Change | Where |
|---|---|
| `_grant` and `_trigger` existence is cached per transaction: every row asked four times, each through half a dozen maps keyed by name | `tx_system_table_exists` |
| the table an insert resolved, and its staging record, are reused by the next insert into the same table | `tx_insert` |
| the unique keys the check encoded are the ones registered, when no trigger can run in between | `tx_check_unique`, `tx_register_keys` |
| index entry keys are encoded into a per-table buffer that keeps its capacity | `index_entry_key` |
| the staging maps start at 64 entries | `tx_writes` |

The caches are reset by every change that can make them wrong: creating,
dropping, altering or renaming a table, dropping a column and rolling back to a
savepoint. `test_insert_caches_follow_the_catalog` changes the catalog between
inserts of one transaction, and fails when the create reset or the savepoint
reset is removed.

In memory, best median of three runs:

| Workload | Round 2 | Round 3 | Reference | Round 3 ÷ reference |
|---|---:|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 762 | 681 | 267 | 2.6× |
| insert_bulk u32_u64_str btree_each_column | 868 | 835 | 528 | 1.6× |
| insert_bulk u32_u64_u64 unique_0 | 612 | 567 | 194 | 2.9× |
| insert_bulk u32_u64_u64 btree_each_column | 757 | 692 | 391 | 1.8× |
| update_bulk u32_u64_str | 1 142 | 1 132 | 493 | 2.3× |
| update_bulk u32_u64_u64 | 1 007 | 927 | 396 | 2.3× |

The engine-only timing (256 inserts into a 2 048-row table, best of 300) went
from 286 us of staging and 178 us of commit to 216 and 161. The benchmark moves
less than that, because its timed routine also prunes row history after the
commit, as the CLI does, and that walks the table.

## Fourth round: rows in id order

A scan walked the table's hash map and then sorted what it found. After a
truncate the map keeps its capacity, so 256 rows meant visiting 4 096 slots,
and the sort cost as much again. Each table now keeps an ordered list of its
row ids beside the map: inserts append (ids are handed out in increasing
order; an id that arrives out of order is placed by binary search), pruning
history compacts it, a truncate clears it and a copy-on-write clone derives
its own. A scan walks the list and looks each id up, so the rows come out
sorted with no sort. Only writers touch the list, because readers share
tables. If a scan does not meet every row of the map it is redone from the
map, so a writer that forgot the list would cost speed, never rows.
`test_scans_come_out_in_row_id_order` walks every writer path.

| Workload | Round 3 | Round 4 | Reference | Round 4 ÷ reference |
|---|---:|---:|---:|---:|
| iterate 256 rows (u32_u64_str) | 15.1 | 4.6 | 1.65 | 2.8× |
| iterate 256 rows (u32_u64_u64) | 16.2 | 4.6 | 1.47 | 3.1× |

The same round made `row_ids_sort` allocation-free: it had borrowed the temp
allocator, which nothing frees in a long-running server, on every commit.

## What the numbers say

The engine is still **not** as fast as the reference. It is now faster on an empty
transaction, and writes went from 3–15× slower to 1.6–2.9× in memory. Scans and
index lookups were 3 to 11 times slower; scans are now about 3 times slower
than the reference after round four, and still faster than SQLite.

Where the remaining write time goes, measured with timers inside `tx_insert` and
`tx_commit` (256 inserts into a table with one unique index): about 1.15 us per
row to stage and 0.75 us to apply. The staging half is a dozen small costs, none
above a fifth of the total: four table lookups by name, the coercion, a copy of
every value into the transaction arena, the unique probe, two trigger-table
probes, the staged-row map and the unique-key registry. The apply half copies
every value again, from the arena to the table's heap, and copies each index key
into the table arena.

What would close the rest, in order of payoff:

1. **Store rows contiguously.** Round four removed the sort and the empty slots,
   but a scan still looks every id up in a map; rows stored in id order (pages
   or a B-tree of rows) would make it a walk over memory, and remove the map
   insert that is the largest single cost of staging a row.
2. **Key the index trees by fixed-size values** where the key allows it (an
   integer column), instead of an encoded string per entry: the index entry is
   the largest share of applying a row.
3. **Prune only what a commit touched.** Pruning row history walks every row of
   every table; the CLI and the C ABI do it after each statement.
4. **Hand staged rows to the table instead of copying them** (about 4% of an
   insert, measured; the ownership has to survive savepoints, `ALTER` and
   rollback, so it is last).

## Measured again (2026-11-19), after the SQLite blocks

Both suites rebuilt from their sources of the day (this engine at `75d2f8f`)
and run one after the other, with the same Criterion settings. The reference
ran faster than on 2026-11-16 on most writes (the same machine, another day),
so the engine was also rebuilt at round four's commit (`f0ce943`) and the two
builds run interleaved, three times each, to tell the code from the machine.

In memory, best median of three runs:

| Workload | Round 4 build | Today's build | Change | Reference | SQLite | Today ÷ reference |
|---|---:|---:|---:|---:|---:|---:|
| empty transaction | 0.50 | 0.50 | 0% | 0.53 | 0.55 | 0.9× |
| insert_bulk u32_u64_str unique_0 | 675 | 745 | **+10%** | 231 | 127 | 3.2× |
| insert_bulk u32_u64_str btree_each_column | 812 | 861 | +6% | 534 | 801 | 1.6× |
| insert_bulk u32_u64_u64 unique_0 | 516 | 639 | **+24%** | 186 | 121 | 3.4× |
| insert_bulk u32_u64_u64 btree_each_column | 684 | 698 | +2% | 363 | 482 | 1.9× |
| update_bulk u32_u64_str | 944 | 1 328 | **+41%** | 349 | 51.2 | 3.8× |
| update_bulk u32_u64_u64 | 832 | 1 155 | **+39%** | 313 | 42.9 | 3.7× |
| iterate 256 rows (u32_u64_str) | 4.8 | 4.8 | 0% | 1.33 | 25.0 | 3.6× |
| iterate 256 rows (u32_u64_u64) | 4.8 | 4.9 | +2% | 1.99 | 22.6 | 2.5× |
| filter, string index | 13.2 | 13.6 | +3% | 3.25 | 90.5 | 4.2× |
| filter, u64 index | 12.9 | 12.9 | 0% | 3.28 | 72.3 | 3.9× |

On disk (this engine's minimum of 60 runs, as above; its medians moved by 50%
between runs):

| Workload | Today's build | Reference | SQLite | ÷ reference |
|---|---:|---:|---:|---:|
| empty transaction | 0.60 | 0.53 | 0.58 | 1.1× |
| insert_bulk u32_u64_str unique_0 | 1 448 | 335 | 181 | 4.3× |
| insert_bulk u32_u64_u64 unique_0 | 1 164 | 208 | 317 | 5.6× |
| update_bulk u32_u64_str | 1 840 | 417 | 85.8 | 4.4× |
| update_bulk u32_u64_u64 | 1 768 | 352 | 120 | 5.0× |
| iterate 256 rows (u32_u64_str) | 4.6 | 1.41 | 30.4 | 3.3× |
| filter, string index | 10.0 | 3.29 | 175 | 3.0× |

Scans, filters and the empty transaction did not move. **Updates are about 40%
slower and inserts into a table with one unique index 10–24% slower than at
round four**: something between `f0ce943` and `75d2f8f` added work to the
write path.

A bisect over the 191 engine commits between them found it in `7f7cd01`
(partial and expression indexes, NULLs in a UNIQUE column). Every write asked
each UNIQUE index whether the row's key held a NULL, four times per row
(staging, the key registry in both directions, the table's own check), and
answered by encoding the whole key into a heap buffer. A plain index now looks
at its columns; only an expression part is evaluated. Measured interleaved
with the round-four build, best median of three:

| Workload | Round 4 | Before the fix | After |
|---|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 675 | 745 | 689 |
| insert_bulk u32_u64_u64 unique_0 | 516 | 639 | 542 |
| update_bulk u32_u64_str | 944 | 1 328 | 1 009 |
| update_bulk u32_u64_u64 | 832 | 1 155 | 864 |

What is left (2–7%) is within the spread of the runs and the WHERE a partial
index has to be asked. `test_unique_null_check_allocates_nothing` fails if the
check allocates again.

## The parity gate (2026-11-21)

`scripts/parity.py` is a gate of `scripts/ci.py`: it builds this suite with
`-o:speed`, runs it in memory three times and fails when a workload's best median
is more than 15% over `baseline.json` (with 0.2 µs of slack for the ones under a
microsecond). A workload over its baseline is measured again first and keeps its
better number: the machine has slow stretches that move every run of one
measurement together (+19% once, for an unchanged build, which best-of-five did
not remove), and a regression of the code is still there the second time. A
CPU-only calibration loop beside the workloads did not move at all while they
did, so the stretches are not the clock and cannot be divided out. The baseline is this machine's: `--record` writes the median of
five rounds of best-of-three, a typical good run rather than the luckiest, which
one round had made a workload sit 13–15% over its baseline on ordinary runs. A
change that makes a workload faster records the new number, so the gain is held.
The reference's and SQLite's numbers beside them are 2026-11-19's, on this
machine. Disk is not gated: its medians move by half between runs.

Recorded today, in µs (in memory):

| Workload | Engine | Reference | SQLite | ÷ reference |
|---|---:|---:|---:|---:|
| empty transaction | 0.50 | 0.53 | 0.55 | 0.9× |
| insert_bulk u32_u64_str unique_0 | 668 | 231 | 127 | 2.9× |
| insert_bulk u32_u64_str btree_each_column | 780 | 534 | 801 | 1.5× |
| insert_bulk u32_u64_u64 unique_0 | 518 | 186 | 121 | 2.8× |
| insert_bulk u32_u64_u64 btree_each_column | 615 | 363 | 482 | 1.7× |
| update_bulk u32_u64_str | 969 | 349 | 51.2 | 2.8× |
| update_bulk u32_u64_u64 | 824 | 313 | 42.9 | 2.6× |
| iterate 256 rows (u32_u64_str) | 4.50 | 1.33 | 25.0 | 3.4× |
| iterate 256 rows (u32_u64_u64) | 4.60 | 1.99 | 22.6 | 2.3× |
| filter, string index | 12.7 | 3.25 | 90.5 | 3.9× |
| filter, u64 index | 12.2 | 3.28 | 72.3 | 3.7× |

One workload is at the reference (the empty transaction); the others are
1.5–3.9× it. The updates are 4–5% under 2026-11-19's numbers after the
regression fix (1 009 → 969 µs and 864 → 824 µs), which is within what a day
moves this machine and was not traced to a change. A run of the gate takes
about 35 s.

## R1: rows stored in id order (2026-11-22)

A memory table keeps its rows in one slice in id order, where a map keyed by id
held them before (with a sorted list of ids beside it for scans). A lookup tries
the slot the id would have with no id missing, then a binary search; a scan walks
the slice. Before and after, interleaved three times each, best median, in µs:

| Workload | Before | R1 | Change |
|---|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 729 | 686 | −6% |
| insert_bulk u32_u64_str btree_each_column | 907 | 849 | −6% |
| insert_bulk u32_u64_u64 unique_0 | 578 | 495 | −14% |
| insert_bulk u32_u64_u64 btree_each_column | 728 | 608 | −17% |
| update_bulk u32_u64_str | 1 116 | 1 045 | −6% |
| update_bulk u32_u64_u64 | 935 | 877 | −6% |
| iterate 256 rows (u32_u64_str) | 5.0 | 3.0 | −40% |
| iterate 256 rows (u32_u64_u64) | 4.8 | 3.1 | −35% |
| filter, string index | 13.8 | 9.3 | −33% |
| filter, u64 index | 13.4 | 8.6 | −36% |

Of iterate's 3.0 µs, 2.1 were `table_collect` copying 256 rows into a list. The
reference iterates over its rows; `table_scan` does the same over the slice, and
this suite's iterate now uses it: **1.4 µs** (u32_u64_str, the reference's 1.33)
and **1.5 µs** (u32_u64_u64, the reference's 1.99). Taking a read transaction and
the table is 0.9 of that.

An insert's time is not where R1's item put it. 256 inserts into a map are
8.8 µs of the ~700 a 256-row insert takes; staging with one UNIQUE index costs
377 µs against 154 µs with none (the key is encoded and probed per row), and the
commit of a table with an index per column 575 µs against 306 µs with one. Both
are the index keys, R2's item. The baseline is recorded again with R1's numbers.

## The SQL path (2026-11-22)

The reference's suite reads and writes through its table API; a statement through
`sql_execute` was not measured at all. This suite now adds four SQL workloads over
a 256-row table with a unique index (`sql/select_1`, `sql/point_rowid`,
`sql/point_index`, `sql/count`), held to the baseline like the rest, with no
reference figure beside them. Three costs stood out:

- **Every parse reserved and released a virtual arena**, two system calls, about
  11 µs of a `SELECT 1`. The parser now takes its arena from a pool of sixteen
  and gives it back emptied (`query_arena_take`, `query_arena_give`).
- **`WHERE rowid = k` scanned the table**, evaluating the comparison on every
  row. A conjunct that names the rowid (`rowid`, `_rowid_`, `oid`, or a
  single-column INTEGER PRIMARY KEY) now reads the one row it names
  (`rowid_candidates`); the WHERE is still evaluated on it.
- **A scan allocated one small list of sources per row** on the heap and freed
  each in one of some forty places, then sorted the rows by id although a scan
  already yields them in that order. The lists now live in one pooled arena per
  statement, and the sort runs only when the rows are out of order.

Before and after, interleaved six times, best run, in µs (the tables are 256
rows, `u` is 2 048):

| Statement | Before | After | Change |
|---|---:|---:|---:|
| `SELECT 1` | 21.7 | 5.6 | −74% |
| `SELECT * FROM t WHERE rowid = 7` | 137.6 | 11.7 | −92% |
| `SELECT * FROM t WHERE id = 7` (unique index) | 31.4 | 12.6 | −60% |
| `SELECT count(*) FROM t` | 84.1 | 36.2 | −57% |
| `SELECT count(*) FROM u` | 564.5 | 275.9 | −51% |
| `SELECT count(*) FROM u WHERE age > 10` | 876.5 | 672.5 | −23% |
| `SELECT id FROM u WHERE age = 30` | 868.1 | 597.5 | −31% |

What a filtered scan spends now is mostly the WHERE itself, about 0.2 µs a row
for one comparison. The baseline is recorded again; the table workloads came out
2–6% under their previous numbers, within what a day moves this machine.

## R3: a prune visits what changed (2026-11-22)

Pruning row history walked every row of every table, and this suite prunes after
each commit, as the CLI does. A table now keeps the ids of the rows that hold a
version or are a tombstone, and a prune visits those. Measured alone, a prune
after a one-row commit beside a 100 000-row table went from 997 µs to 0.1 µs.
Before and after, interleaved four times each, best median, in µs:

| Workload | Before | R3 | Change |
|---|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 683 | 651 | −5% |
| insert_bulk u32_u64_str btree_each_column | 675 | 658 | −3% |
| insert_bulk u32_u64_u64 unique_0 | 501 | 466 | −7% |
| insert_bulk u32_u64_u64 btree_each_column | 521 | 489 | −6% |
| update_bulk u32_u64_str | 1 078 | 1 013 | −6% |
| update_bulk u32_u64_u64 | 835 | 822 | −2% |

The reads do not prune and did not move. The baseline stays R6's: recorded
again, every workload came out 0–14% slower, the reads R3 does not touch among
them, which is the machine and not the code; R6's numbers hold the gate tighter.

## R4: a stored row is one allocation (2026-11-22)

A commit copies each staged row from the transaction arena into the table. The
copy was one allocation for the value array and one per text, blob or list; it is
now one for the whole row. Measured inside the commit of 256 inserts over 2 048
rows: 57 → 42 µs for the text rows, ~40 µs either way for the integer rows (one
allocation already). The parity workloads, interleaved five times, best median:

| Workload | Before | R4 | Change |
|---|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 668 | 643 | −4% |
| insert_bulk u32_u64_str btree_each_column | 705 | 659 | −6% |
| update_bulk u32_u64_str | 1 102 | 1 025 | −7% |
| insert_bulk u32_u64_u64 unique_0 | 486 | 489 | +1% |
| insert_bulk u32_u64_u64 btree_each_column | 508 | 525 | +3% |
| update_bulk u32_u64_u64 | 862 | 865 | 0% |

The integer rows allocate as before (a row with nothing after its array is the
array, as it was); their ±3% is what the same build moves between runs here (the
text update read −7% in one round and +2% in the next). The baseline is kept.

## R7: index nodes from a pool (2026-11-22)

A memory index allocated each tree node from the heap. A commit with a reader
open copies the whole table, so it allocated a node per key: 10–16 ms of the
copy of a 50 000-row table. Each index now takes its nodes from a pool of its own
(chunks of slots and a free list, freed with the index). The commit with a
reader open (`miraidb bench-read`, interleaved five times): 20 000 rows 5.7–17 →
4.4–4.7 ms, 50 000 rows 15–78 → 13–17 ms. Every insert that files a new key
allocated a node too, so the writes moved, interleaved five times, best median:

| Workload | Before | R7 | Change |
|---|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 648 | 658 | +2% |
| insert_bulk u32_u64_str btree_each_column | 704 | 674 | −4% |
| update_bulk u32_u64_str | 1 138 | 1 054 | −7% |
| insert_bulk u32_u64_u64 unique_0 | 506 | 474 | −6% |
| insert_bulk u32_u64_u64 btree_each_column | 565 | 483 | −15% |
| update_bulk u32_u64_u64 | 919 | 855 | −7% |

The reads did not move. The baseline is kept.

On the performance gate (`scripts/bench.py`, Linux, 20 000 rows) the commit with
a reader open is 6.8–9.6 ms against 16.9 recorded before R1, a read transaction
1.3–1.9 µs against 10.7, and the first read after a commit 5.8–6.9 µs against 38.
Those three are written into `benchmarks/baseline.json` by hand (1.5, 6.2, 7 200):
a full `--record` also rewrote the insert rate and the compaction time, which
moved 46 000–106 000 rows/s and 0.34–1.39 s between three runs of the same build,
so a recorded number there was a draw, not a baseline.

## R2: the write path by stage (2026-11-25)

Before changing the write path again, where its time goes. Three runs of
`bin/parity.exe mem` on the same idle machine (best median, µs; the reference's
numbers from 2026-11-19):

| Workload | This engine | Reference | Ratio |
|---|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 647 | 231 | 2.8× |
| insert_bulk u32_u64_str btree_each_column | 634 | 534 | 1.2× |
| update_bulk u32_u64_str | 1 036 | 349 | 3.0× |
| insert_bulk u32_u64_u64 unique_0 | 464 | 186 | 2.5× |
| insert_bulk u32_u64_u64 btree_each_column | 477 | 363 | 1.3× |
| update_bulk u32_u64_u64 | 816 | 313 | 2.6× |

An insert into a table with an index on every column (three indexes) costs what
one into a table with a single unique index costs: maintaining an index is not
what is slow, the unique check is.

**How it was measured.** A harness outside the repository runs one workload
2 000 times through the same calls as the parity suite (`tx_insert` and
`tx_commit`; for the update, the index lookup and `tx_update`), against a copy of
`src/engine` with a tick counter around each stage of `tx_insert_row`,
`tx_update_row`, `tx_commit`, `table_insert` and `table_update`. Each probe costs
a few tens of nanoseconds, so the probed totals are 10–40% above the parity
numbers; the shares are what to read. The first 400 runs of each workload are
slower than the rest (the arenas and the index pools growing); the numbers below
include them. `perf` on a Linux build was tried first: the same workload is two to
three times slower there, a third of it in `mmap`, `munmap` and page faults from
musl's allocator, so its profile describes Linux's allocator more than this
engine, and the gate machine is Windows.

Insert, 256 rows into 2 048, one transaction (µs per transaction):

| Stage | u64 | str | Share (u64) |
|---|---:|---:|---:|
| unique check: encode the key, probe the staged keys, descend the committed tree | 201 | 203 | 30% |
| apply: put the row in each index | 105 | 100 | 15% |
| stage: undo note, the staged row map, register the key | 98 | 99 | 14% |
| table lookup, permission, coerce and clone the values | 83 | 125 | 12% |
| commit: build the ops (sorted staged ids) | 52 | 52 | 8% |
| apply: pack the values, put the row | 39 | 54 | 6% |
| CHECK, index validation, foreign keys | 20 | 18 | 3% |
| commit: ephemeral flags, log record | 17 | 19 | 2% |

Update, 256 rows found by id and rewritten (column 1, which no index covers):

| Stage | u64 | str | Share (u64) |
|---|---:|---:|---:|
| stage: unregister, check and register the unique key | 360 | 443 | 28% |
| apply: remove from every index, keep the version, pack, put back in every index | 245 | 358 | 19% |
| apply: the unique check again | 171 | 246 | 13% |
| table lookup, `tx_get`, coerce and clone the values | 132 | 208 | 10% |
| commit: build the ops | 62 | 61 | 5% |

About 775 of the update's ~1 300 probed microseconds are spent on a key that did
not change: encoded three times while staging, checked again at the apply, and
taken out of its index and put back.

**What the reference does per row** (read from its source, `crates/table`,
`crates/datastore`). It does not do fewer steps: an insert writes the row into the
transaction's pages, seeks the same unique index three times (the transaction's,
then the committed one twice: set semantics and the constraint), and at commit
builds a value per row and writes it again into the committed pages with a second
index insertion. An update is a delete and an insert, and the commit removes the
old row from every index too. What it does not pay is the cost of each step:

- the index on a `u32` column is a `BTreeMap<u32, RowPointer>` keyed by the
  integer read from the row: no encoded key, no allocation, no string compare;
- tables are found by an integer id, not by hashing their name;
- a delete in a transaction is a bit in a per-page bitset;
- a row of fixed-size columns is copied into page memory with no heap allocation.

**Candidates, by weight** (each to be measured interleaved against the build
before it and dropped if it does not gain, as R2b was):

1. An update that changes no column of an index skips the unique work while
   staging and, at the apply, the second check and the index remove and put:
   about 55–60% of `update_bulk`.
2. A unique index over one integer column keyed by the integer itself (fixed size,
   compared as a number): the unique check, the index put and the key
   registration, together about 55% of `insert_bulk unique_0`.
3. One key encoding per row: the key the unique check computes is the one the
   apply files, instead of being encoded again for the tree (part of 1 and 2 where
   a key is not an integer).
4. The table looked up once per transaction, not by name per row: the update
   path has no cached table at all, and `tx.state.writes[name]` and
   `store.tables[name]` hash the name for every row (part of the 10–12% lookup
   stage).
5. The staged rows of a table whose ids only grow kept in a slice rather than a
   map, which also makes building the ops a walk instead of a sort (the 8%
   build stage and part of the 14% staging stage).

The baseline is not changed: nothing here makes the engine faster yet.

## R2, candidate 1: an update that keeps its keys moves none (2026-11-25)

An update whose new values leave every key column of a plain index identical
(same kind, same bits: `value_identical`) neither checks nor moves that key.
While staging, `tx_update_row` skips the unregister, the check and the register
of the row's unique keys; at the apply, `table_update` skips the second unique
check and the index remove and put for every index whose key is kept. An index
with an expression or a WHERE, and a transaction that created or dropped an
index, still take the full path.

A committed row the transaction rewrote used to give up its committed key for
good (its new key was registered in the transaction's map). It now keeps it
when its new values do: the two readers of that rule, the unique check
(`tx_committed_key_taken`) and the rows an INSERT OR REPLACE deletes
(`unique_conflicts`), ask the staged row (`tx_rewrite_keeps_key`), which only a
row the committed index files under the probed key pays.
`test_insert_or_replace_finds_a_key_an_update_kept` fails without that half.

Five interleaved rounds against the build before it (µs, medians):

| Workload | Before | After | After / before | Reference | Ratio now |
|---|---:|---:|---:|---:|---:|
| update_bulk u32_u64_str | 1 094 | 671 | 0.61 | 349 | 1.9× |
| update_bulk u32_u64_u64 | 917 | 460 | 0.50 | 313 | 1.5× |

Every other workload is within noise (0.93–1.03). `scripts/parity.py --record`
then measured 642 and 436 µs (1.8× and 1.4× the reference); only those two
numbers went to `baseline.json`, so the others keep their tighter baseline.

## R2, candidate 2: integer keys by hash (2026-11-25)

The stage probes overstated where an insert's time goes: each probe costs a
clock read, and the unique check holds several. Taking one stage away at a time
(a build that skips it, wrong on purpose, timed in five interleaved rounds of
the u64 insert) gave the real weights, in µs per 256 rows:

| Build | µs | Of the build before |
|---|---:|---:|
| `main` | 461 | 1.00 |
| A: index keys compared eight bytes at a time | 388 | 0.84 |
| A without the probe of the committed index | 326 | 0.84 of A |
| A without the unique index's put at the apply | 335 | 0.86 of A |
| A without any unique check or registration | 276 | 0.71 of A |

The committed probe is a descent of a red-black tree, a node per level, and
the staged check built the index's name and the encoded value in the arena for
every row to hash it.

Three changes came of it:

- `text_compare`, which every descent of an index tree calls once per level,
  compares eight bytes at a time.
- A UNIQUE index over one plain column keeps, beside its tree, a hash from each
  integer key to the row holding it (`Index.ints`). The unique check, the
  apply's check and an equality lookup ask it instead of the tree. Its keys
  follow `value_encode_key`'s spaces (`index_int_key`): an unsigned integer in
  its own, a signed one or a real that holds one exactly in the space numbers
  share, so 5 and 5.0 are one key and 2^53 + 1 and 2^53.0 are two, as in
  SQLite. Every other value, and every ordered question, is the tree's. An
  index whose hash cannot grow drops it and answers from the tree.
- A transaction stages the integer keys of those indexes in a map of their own
  (`Table_Writes.unique_ints`), keyed by the index's position and the integer.

Five interleaved rounds against the build before it (µs, medians):

| Workload | Before | After | After / before | Reference | Ratio now |
|---|---:|---:|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 609 | 490 | 0.81 | 231 | 2.1× |
| insert_bulk u32_u64_u64 unique_0 | 438 | 325 | 0.74 | 186 | 1.7× |
| insert_bulk u32_u64_str btree_each_column | 597 | 537 | 0.90 | 534 | 1.0× |
| insert_bulk u32_u64_u64 btree_each_column | 442 | 393 | 0.89 | 363 | 1.1× |
| update_bulk u32_u64_str | 589 | 495 | 0.84 | 349 | 1.4× |
| update_bulk u32_u64_u64 | 387 | 332 | 0.86 | 313 | 1.1× |

The reads stay within noise (0.93–1.04). `scripts/parity.py --record` took the
six write workloads only (it measured the u64 unique insert at 399 µs, a looser
number than the rounds above); the others keep their tighter baseline.

What is left of the unique insert is mostly not the index: staging the row,
converting and copying its values, building the commit's operations and the
tree put. Candidates 3–5 are those.

## R2, candidates 3–5: staging, conversion and the commit (2026-11-25)

Taking stages away again (seven rounds, high priority) put conversion at
about 9% of the u64 insert, and the growth of the staging map at 7%, while the
permission check, the value copy and the trigger probes were each within 3%.
The commit copied every 240-byte op three times and found its table by name
for every row. Four changes:

- `value_coerce_into` returns a value already of its column's kind (an
  unsigned or signed integer within the column's width, a text) as the whole
  conversion would, its subtype cleared, without the three calls and the
  errors they return.
- A transaction's inserted rows are `Staged_Rows`: an array in id order while
  the ids run upward one at a time, as the ids a transaction hands out do, and
  the map for any other. An insert is an append, and the commit walks the
  array with no sort.
- The commit sizes its op list once and returns it without a copy, builds the
  list of logged ops only when the store logs, and asks whether a table is
  TEMP once per table instead of once per row.
- The apply finds the table of a run of row ops once (`Apply_Cache`).

Five interleaved rounds against the build before it (µs, medians):

| Workload | Before | After | After / before | Reference | Ratio now |
|---|---:|---:|---:|---:|---:|
| insert_bulk u32_u64_str unique_0 | 480 | 332 | 0.69 | 231 | 1.4× |
| insert_bulk u32_u64_u64 unique_0 | 343 | 289 | 0.84 | 186 | 1.6× |
| insert_bulk u32_u64_str btree_each_column | 546 | 406 | 0.74 | 534 | **0.76×** |
| insert_bulk u32_u64_u64 btree_each_column | 413 | 314 | 0.76 | 363 | **0.86×** |
| update_bulk u32_u64_str | 489 | 469 | 0.96 | 349 | 1.3× |
| update_bulk u32_u64_u64 | 345 | 328 | 0.95 | 313 | 1.05× |

Reads within noise (0.92–1.00). The gate counts 7 of its 11 workloads at or
under the reference now. Only the six write numbers went to `baseline.json`.

## A gain over the reference is held (2026-11-25)

The baseline's 15% follows this machine's own numbers, so a workload under the
reference could give its lead back a step at a time, each step inside the
budget: `empty` at 0.94× could reach 1.3× before it failed, and `update u64` at
0.99× up to 1.14×. `baseline.json` now lists under `reached` the workloads at or
under the reference, and `scripts/parity.py` fails when one of them is more than
10% slower than the reference (with the same 0.2 µs of slack), whatever its
baseline allows. A workload over either line is measured again first, as before.
`--record` adds a workload to the list once its recorded number is at or under
the reference and never takes one off; that is an edit by hand. The list has
the six of today: `empty`, both filters, both inserts with an index per
column and `iterate u64`. `--self-test` checks the rules on
made-up numbers (a workload inside its baseline but past 1.10×, one that never
reached the reference, the timer's slack, what `--record` lists), and is a gate
of its own, `parity rules`.

`update u64` was on the list at first, from a recorded 0.99×, and failed the
gate twice the same day at 1.11× on a quiet machine. Measured alternating with
the build before it, it is 1.05–1.06× the reference: the 0.99 was one good
round, not where the workload is. It left the list by hand (2026-11-26) and is
held to its baseline only, with the other workloads still behind the reference.

To reproduce:

```sh
odin build benchmarks/parity -o:speed -out:bin/parity.exe
bin/parity.exe mem
bin/parity.exe disk
python scripts/parity.py            # the gate
python scripts/parity.py --record   # after a change that makes it faster
```
