# Third-party notices

miraidb is licensed under either of [MIT](LICENSE-MIT) or
[Apache-2.0](LICENSE-APACHE), at your option.

The engine is original code. It does not vendor third-party source files and
does not link any external library at runtime.

## Build and run dependencies

- **Odin** `base`, `core` and `vendor` (BSD-3-Clause; © 2016-2026 Ginger Bill),
  <https://odin-lang.org>. The compiler and its standard library are used to
  build and run miraidb; they are not distributed with it.

## Development tools

- **SQLite** (public domain), <https://www.sqlite.org>, is not used by the
  engine and no SQLite source is vendored or linked. The file format is
  implemented from the published specification by original code in
  `src/engine/sqlite_file.odin` and `src/engine/sqlite_write.odin`, and the
  `sqlite3_*` names in `src/sqlite_compat` exist so a program written against
  that API can link against this engine instead.
