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

## Repository hygiene

`bin/`, `_test_*` and any local `*.db` directory are ignored by git. Do not
commit generated indexes, logs or databases.
