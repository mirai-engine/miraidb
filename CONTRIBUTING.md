# Contributing to miraidb

Bug reports, fixes and tests are welcome.

## Issues and pull requests

- Open an issue with what you ran, what happened and what you expected.
  Include the output of `miraidb check <database>` when a database is involved.
- A pull request goes to `main`. Keep it focused: one behaviour change per pull
  request, with the test that proves it.
- Before opening it, run:

  ```sh
  python3 scripts/build.py
  ```

  which builds the CLI and the example and runs the suite.

  and say in the description that both passed on your platform.

## Rules for the engine

- `src/engine` is the product. It must not depend on anything outside Odin's
  `core` packages.
- Every new durable format (log record, value kind, schema field) needs a
  documented encoding in `docs/file-format.md` and a decode path that rejects
  unknown input instead of guessing.
- A behaviour that SQL exposes must be reachable through the transaction API as
  well: reducers and SQL share one insert/update path.
- Do not add an embedded scripting runtime. New programmable behaviour is Odin
  code registered with the host.
- Tests live in `src/tests` and run without network access.

## Commits

One change per commit, in the imperative: what it does, then why it had to be
done that way. Tests and the doc that states the new behaviour travel with the
code. Small follow-ups get their own commit; the history is published as it is,
so no squashing is needed and none is expected.

## Repository hygiene

`bin/`, `_test_*` and any local `*.db` directory are ignored by git. Do not
commit generated indexes, logs or databases.

## Documentation

The documents in `docs/` are part of the product: they are what a reader uses to
decide whether the engine can do their job. They are held to the same rule as
the code — **a claim is true only while something checks it** — and
`scripts/docs_check.py` (a CI gate) checks the mechanical half: the version, the
test count, the gate count, the CLI command list, every relative link, the
`D<n>` cross-references between the roadmap and the backlog, and that no
document is orphaned. The rest is editorial:

- **One claim per sentence.** "The mirror patches three pages per commit" is a
  claim; "it is fast and modern" is not. Numbers carry their unit and the way
  they were measured.
- **State the present, not a wish.** Write what the tree does today. If it does
  not do it, it belongs in `docs/backlog.md` or `docs/roadmap.md`, not in the
  middle of a paragraph about what works.
- **Say where the edge is.** A feature that works for a subset says which subset
  (`LEFT` joins but not `RIGHT`; a page store but one version per row). An
  undocumented edge is read as a promise.
- **Name the proof.** A paragraph that claims behaviour ends with the test, gate
  or script that shows it: ``test_mirror_grows_and_reopens``,
  ``scripts/plan_check.py``. A claim nobody can run is a rumour.
- **Do not repeat; link.** Each fact lives in one document: measurements in
  `status.md`, order in `roadmap.md`, cost and design in `backlog.md`, SQL in
  `sql.md`, the file layout in `file-format.md`. The others link to it.
- **Same words for the same thing.** "commit log", "page file", "snapshot",
  "mirror", "work budget": one term each, spelled the same everywhere. SQL
  keywords and identifiers appear in `code spans`, in the case the engine prints.
- **Tables for state, prose for reasons.** A status table answers "what works";
  the paragraph under it answers "why it is that way".
- **Short paragraphs, one idea each.** A heading that needs three sentences to
  explain itself is the wrong heading.

When a change makes a sentence in `docs/` false, changing that sentence is part
of the change, not a follow-up: the gate catches the counts and the links, a
reader catches the rest, and a stale paragraph is a bug report waiting to happen.
