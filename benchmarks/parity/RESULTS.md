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
write path. That regression is the first thing to find, before any of the
four items above.

To reproduce:

```sh
odin build benchmarks/parity -o:speed -out:bin/parity.exe
bin/parity.exe mem
bin/parity.exe disk
```
