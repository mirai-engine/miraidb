# Plan: version control and peer-to-peer sync

Status: **proposal**. Nothing here is implemented. This document states what the
feature is, what it reuses, how it would be built in phases and what each phase
has to prove before the next one starts. The open engine items it depends on are
numbered as in [roadmap.md](roadmap.md).

## What it is

A database that versions itself the way a source tree is versioned: every commit
has an identity, history is a graph rather than a line, work happens on branches,
and branches are compared, merged and shared. Sharing is **peer to peer**: there
is no server that owns the data. Every participant is a peer that holds a full
copy (or the part it asked for) and synchronises with whichever peers it can
reach.

Three kinds of peer, one protocol:

| Peer | What it is | What it adds |
|---|---|---|
| A user | a laptop or a desktop with the database embedded in an application | the work itself; online when its owner is |
| An office peer | a machine on the office network, always on | a copy that colleagues on the same network reach without the internet; it is a user that never sleeps, nothing more |
| A VPS | a peer on a public address | robustness: it is reachable when nobody else is, keeps every object, introduces peers that cannot see each other and relays for those that cannot connect directly |

The VPS and the office peer have **no authority**. They hold the same data as
any user, verify it the same way and can be replaced by another peer at any time.
Losing one loses no history, because every commit they hold is also held by the
peer that made it and by every peer that synchronised since.

What it is not:

- Not a consensus database. Peers may disagree for a while; they converge by
  merging, as branches do. There is no global order of commits and no leader.
- Not real-time collaboration by default. A branch can opt in to automatic
  merging (phase V6), but the model is commit, share, merge.
- Not a replacement for D14 (a follower that replays the leader's log). That is
  the single-branch, single-writer special case of this design, and it comes
  first.

## What already exists and is reused

| Piece | Where | What it gives this plan |
|---|---|---|
| Commit records with CRC32C, one per transaction | `src/engine/commitlog.odin` | the payload of a commit: the operations (`Store_Op`) a transaction applied, already encoded |
| Replay | `store_open` → `commitlog` | checkout: a state is the replay of a history |
| Snapshots with an offset index | `src/engine/snapshot.odin` | a starting point, so checking out a branch does not replay from the first commit |
| `AS OF <seq>` and row versions | `docs/sql.md` (Reading the past) | reading an older state without checking it out |
| Row-level change sets | subscriptions (`host_on_commit`) and `tx_build_ops` | diff and merge work on rows identified by primary key, which the engine already produces per commit |
| Deterministic export | `export-sqlite` | a byte-identical rendering of a state, which is what a content hash needs |
| Deflate | `src/engine/deflate.odin` | compressed packs |
| Identity, HMAC tokens, HS256 JWT, roles and grants | `roles.odin`, `jwt.odin`, `policies.odin` | who may write which branch, expressed with the policies that exist |
| `Vfs` | `src/engine/vfs.odin` | an object store that can live in memory for tests and under fault injection |
| The engine's networking library (Odin, same toolchain) | `mirai-engine`: `net` with `channel`, `replication`, `baseline`, `clock`, `conditioner`, `peer`/`host` | reliable ordered channels over UDP, "baseline plus changes" replication, a deterministic clock and a lossy-network simulator for tests |
| Cryptography | Odin `core:crypto`: SHA-2, BLAKE2b, Ed25519, X25519, ChaCha20-Poly1305 | content addresses, commit signatures and encrypted sessions without a third-party library |

## The model

### Objects

Everything a peer exchanges is an immutable object named by the hash of its
bytes (BLAKE2b-256, written in hex). Two peers that hold an object with the same
name hold the same bytes; a peer verifies every object it receives by hashing it.

| Object | Contents |
|---|---|
| **Change set** | the encoded operations of one transaction: the payload a commit record carries today, with schema changes included |
| **Commit** | the parent commit ids (one, or two for a merge), the change set id, the author's public key, a hybrid logical clock timestamp, a message, and an Ed25519 signature over all of it |
| **Checkpoint** | a snapshot of a whole state: one object per table, each a sorted list of `(primary key, row hash)` pages, plus the schema. It is a Merkle tree, so two checkpoints that share most tables share most objects, and a diff descends only where hashes differ |
| **Pack** | many objects in one compressed file, for transfer and for storage |

A commit names its parents, so the commits form a directed acyclic graph, the
history. The state at a commit is the replay of the change sets from the root (or
from the nearest checkpoint) along its first-parent path, with merge commits
carrying the change set that reconciles their parents.

### References

A **branch** is a name that points at a commit and moves when a commit is added
to it. A **tag** is a name that does not move. References live in the database
directory (`<db>/refs/…`) and are the only mutable thing in the object model.
Each peer has its own references and, for every peer it synchronises with, a
read-only copy of that peer's (`<peer>/main`), as remote-tracking branches are.

The working state of a database is a checkout of one branch: what `SELECT`
reads and what a transaction commits onto. Committing a transaction appends a
commit to the checked-out branch: the log as it exists today becomes the local
record of that branch, and each record gains the commit id it produced.

### Diff and merge

Rows are identified by their primary key, so changes are compared row by row and
column by column, not line by line:

- **Diff** of two commits: the rows inserted, deleted and changed (with the
  columns that changed), per table, plus the schema changes. Two checkpoints
  diff by walking their Merkle trees; two nearby commits diff by composing their
  change sets.
- **Three-way merge** of two branches: find the common ancestor, compute both
  diffs from it, and apply both. Changes to different rows, or to different
  columns of one row, merge cleanly. A **conflict** is a row whose same column
  changed to two different values, a row deleted on one side and changed on the
  other, a key inserted on both sides with different values, or schema changes
  that disagree.
- **After the merge**, constraints are checked again on the merged state (unique
  keys, foreign keys, `CHECK`, `NOT NULL`), because two clean changes can still
  violate one together: two branches that each insert a different row with the
  same unique email. Such a violation is a conflict too.
- **Conflicts are data.** An unfinished merge leaves its conflicts in a table,
  `_conflicts (table, key, column, base, ours, theirs)`, resolved with ordinary
  SQL; the merge commits when that table is empty.

### Clocks

Peers have no shared clock. Commits carry a hybrid logical clock (wall time plus
a counter, never behind any timestamp the peer has seen), which orders the
commits of one peer, gives `last writer wins` a meaning for branches that opt in
to it (V6), and survives clock skew between machines.

## The protocol

### Identity and membership

A peer is an Ed25519 key pair. A repository is identified by the id of its root
commit. Who belongs to it is **in the repository itself**: a `_members (key,
role, added_by)` table, changed by signed commits like any data. A commit is
valid only if its author was a member with write access at its first parent, so
every peer decides validity from history alone, with no server to ask. Roles
reuse grants and policies: a branch can be writable by some members only, and a
protected branch can require a merge commit signed by `n` of `m` maintainers.

### Sessions

Peers talk over the networking library's reliable ordered channel on UDP. Every
session starts with a Noise `XX` handshake (X25519, ChaCha20-Poly1305, BLAKE2b),
which authenticates both keys and encrypts everything after it; a peer that is
not a member is answered with nothing. TCP is the fallback where UDP is blocked.

### Synchronisation

1. **Advertise.** Each side sends its references: branch names and head commit
   ids. Equal heads end the session.
2. **Negotiate.** Each side works out which commits the other lacks. A history
   shares a long common prefix, so the sides exchange their recent commit ids in
   doubling windows (the last 32, 64, 128, …) until they find common ancestors,
   and summarise the rest with a Bloom filter; this is what a source-control
   fetch does, and it costs a few round trips whatever the size of the history.
3. **Transfer.** The side that has the missing objects sends one pack: the
   commits, their change sets and any checkpoint the other side asked for.
4. **Verify.** The receiver hashes every object, checks every signature and every
   author against `_members`, and replays every change set onto its parent's
   state before accepting it. A pack that fails is dropped whole.
5. **Update references.** The receiver moves its remote-tracking branches. A
   local branch fast-forwards when the remote one contains it; otherwise the
   user merges, or the branch's policy merges for them (V6).

Sync is symmetric and idempotent: running it twice changes nothing, and two peers
can sync in either direction or both at once.

### Finding peers

| How | When it works |
|---|---|
| Local network discovery (multicast DNS) | peers on the same office network find each other, and the office peer, with no configuration and no internet |
| Known addresses | a peer remembers the addresses of the peers it has met; the VPS has a fixed one |
| Introduction | a reachable peer (usually the VPS, but any) tells two members each other's public address and port, and both send to each other at once: UDP hole punching through most home and office NATs |
| Relay | when hole punching fails (symmetric NAT, a strict firewall), a reachable peer forwards the encrypted session. It sees only ciphertext |
| Gossip | peers forward the reference updates they receive, so a commit reaches every member through whoever is online, not only through the peer that made it |

### What the VPS and the office peer do

They run the same program as a user, with three settings turned on:

- **keep everything**: never prune objects, and accept every valid pack of the
  repositories they serve, so a user who was offline can always catch up;
- **introduce and relay**: answer introduction requests and forward sessions;
- **back up**: write checkpoints on a schedule and verify the whole history
  (replay plus signatures) once a day.

An office that runs its own peer works on the local network when the internet is
down, and synchronises with the VPS and the remote users when it comes back.

## Interfaces

From the command line:

```text
miraidb vcs init <db>                    give an existing database a root commit
miraidb vcs log <db> [branch]            the history: id, author, time, message
miraidb vcs branch <db> <name> [from]    create a branch
miraidb vcs checkout <db> <branch>       make it the working state
miraidb vcs diff <db> <a> <b>            rows and schema that differ
miraidb vcs merge <db> <branch>          three-way merge into the working branch
miraidb vcs tag <db> <name> <commit>
miraidb vcs remote add <db> <name> <address>
miraidb vcs sync <db> [peer]             fetch and push with one peer, or all
miraidb vcs serve <db> [--keep-all] [--relay]   run as an always-on peer
```

From SQL, so an application needs no new API:

```sql
SELECT * FROM orders AS OF COMMIT 'b3f1…';          -- read any commit
SELECT * FROM _commits WHERE author = '…';          -- the history is a table
SELECT * FROM _refs;                                 -- branches and tags
SELECT * FROM _diff('main', 'feature') WHERE table_name = 'orders';
SELECT * FROM _conflicts;                            -- an unfinished merge
```

And from the C ABI, `miraidb_commit_id`, `miraidb_checkout`, `miraidb_merge` and
`miraidb_sync`, so the embedding application drives it.

## Phases

Each phase is shippable on its own and ends with tests that prove it, the way
the roadmap's items do.

| # | Phase | Delivers | Proves it | Depends on |
|---|---|---|---|---|
| V0 | Commit identity | every commit record carries the id of its change set and of its parent: a hash chain over the existing log; `_commits`; `AS OF COMMIT` | a reopen recomputes every id; a flipped byte in an old record is detected | — |
| V1 | Branches on one machine | references, `branch`, `checkout` by replay from the nearest checkpoint, commits onto the checked-out branch | checking out A, B, A gives byte-identical exports of A both times | D17 multi-version pages (#10), for paged tables |
| V2 | Diff and merge | Merkle checkpoints, row-level diff, three-way merge, constraint re-check, `_conflicts` | a merge corpus (disjoint rows, same row different columns, same column, delete versus update, the unique-key collision, schema conflicts) where every case gives the documented result; the fuzzer generates random pairs of branches and checks that merging A into B and B into A give the same rows | V1 |
| V3 | Push and pull between two peers | packs, signatures, `_members`, the negotiation, the Noise session over TCP | two processes diverge, sync both ways and end with the same references and the same exports; a tampered pack and a non-member are refused; the D8 fault injection cuts the transfer at every byte and the receiver keeps its previous state | V2, D14 (#27) for the transport and the replay of foreign records, D15 (#26) for the session |
| V4 | Peer to peer | UDP channel, local discovery, introductions, hole punching, relays, gossip | the networking library's conditioner runs five peers with loss, latency and partitions; after the partition heals every peer holds every commit; a peer behind a simulated symmetric NAT syncs through a relay | V3 |
| V5 | Always-on peers | `serve --keep-all --relay`, scheduled checkpoints and verification, protected branches with `n` of `m` signatures | a user who was offline for a thousand commits catches up from the VPS alone; a protected branch refuses a merge with too few signatures | V4 |
| V6 | Live branches (opt-in) | branches that merge on every sync with last-writer-wins per column by hybrid clock; subscriptions that fire on merged changes | two peers editing different columns of the same rows converge with no conflict; with the same column, every peer picks the same winner | V5 |

Rough size, at this repository's pace: V0 and V1 a few weeks together, V2 the
largest single piece (the merge corpus is most of it), V3 and V4 about as large
as D14 and D15 combined, V5 and V6 smaller.

## Risks and the decisions they need

| Risk | Decision |
|---|---|
| Schema changes do not merge like rows | V2 merges a schema change only when one side made it, and treats two different changes to one table as a conflict to resolve by hand; a column added on both sides with the same definition is not a conflict |
| Constraints broken by two clean changes | re-check on the merged state, and report the violation as a conflict instead of failing the merge |
| History grows without bound | checkpoints let a new peer start from a recent state (a shallow clone); objects no branch reaches are collected, except on peers that keep everything |
| A malicious member | signatures make every commit attributable; validity is decided by replaying against `_members`; a member is removed by a commit, and what they wrote before stays attributable to them |
| Rewriting shared history | no force-push on a protected branch; on others, a rewritten branch arrives as a divergence to merge, never as lost commits |
| Clock skew | hybrid logical clocks; wall time is never used to order the commits of different peers except in V6, where the tie-break is documented |
| Private data on a VPS | sessions are encrypted; for a VPS that should not read the data, objects can be encrypted at rest with a repository key it does not hold (it then keeps and relays, but cannot verify by replay: it checks hashes and signatures only) |
| Large values | rows that carry large blobs are stored as separate objects, so a change to one column does not copy the blob |

## Open questions

- Whether a checkout should be a separate directory (one working state per
  branch, like a worktree) or switch in place; the first is simpler to make
  correct and costs disk.
- Whether `_members` changes should require more than one signature from the
  start, or only on protected repositories.
- Which hash to fix for the object format (BLAKE2b-256 is in `core:crypto` today;
  BLAKE3 is faster but is not), since it cannot change later without rewriting
  every id.
- How much of the networking library's message set to adopt as is, and what has
  to be added for packs larger than one datagram window.
