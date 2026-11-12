# Value layout: from 144 bytes to 24

`size_of(Value)` was **144 bytes**: a five-column row paid 720 bytes of values
plus an 80-byte `Row`. It is now **24 bytes**, so a five-column row pays 120
bytes of values. The measurement lives in `test_value_layout`, which fails if
the size moves.

## Today

```odin
Value_Payload :: struct #raw_union {
    b:     bool,
    i:     i64,
    u:     u64,
    f:     f64,
    s:     string,          // 16
    bytes: []u8,            // 16
    uuid:  Uuid,            // 16
    list:  []Value,         // 16
    big:   [2]u64,          // Int128/Uint128
    ident: ^Identity,
}

Value :: struct {
    kind: Value_Kind,       // 1 byte, padded to 8
    using payload: Value_Payload,
}
```

`#raw_union` makes every payload field start at offset zero, so the 16 bytes are
shared and `using` keeps the field reads (`v.i`, `v.s`, `v.uuid`, …) unchanged at
the call sites. The tag says which one is meaningful, which was already the
invariant of the type. Size: 8 + 16 = **24**, alignment 8.

Two payloads do not fit in 16 bytes and are handled explicitly:

| Kind | Why it does not fit | Where it goes |
|---|---|---|
| `Int128`, `Uint128` | a `u128` field forces 16-byte alignment, and the struct would round to 32 | two `u64` words in the payload, read with `value_big`, written with `value_int128`/`value_uint128` |
| `Identity` | 32 bytes | a fixed copy behind the `ident` pointer, owned by an intern table, read with `value_identity_of` |

The intern table is keyed by the 32 bytes, so values built from the same
identity share one copy and compare by pointer as well as by content. It grows
on the **process heap** (`runtime.heap_allocator`), not on `context.allocator`:
a caller (the test runner, a request handler) may install a temporary allocator
and release it later, and a table that outlives it must not live in that arena.
This was a real crash during the migration ("unable to insert into a map").
Identities are few (one per client or module) and every copy of a value may
exist in many rows, so no owner can free them; the table never frees.

## Measured

| | before | after |
|---|---|---|
| `size_of(Value)` | 144 | **24** |
| `size_of(Value_Payload)` | 144 | **16** |
| five values | 720 | **120** |
| `size_of(Column)` (holds a default value) | 256 | **128** |
| `size_of(Row)` | 80 | 80 |
| read snapshot at 50k rows, replays warm | 12.0 µs | **9.9 µs** |
| inserts (`bench`, one transaction) | 61.8k/s | 61.7k/s |

The read snapshot is 18% faster simply because the frozen copy moves a fifth of
the bytes. Inserts are unchanged: the bind and encode paths already dominated.

## What did not change

- **The log format.** `value_encode` writes the same bytes and `value_decode`
  builds the new layout, so `LOG_VERSION` stays at 15 and old databases replay.
- **The public API.** Constructors (`value_int`, `value_string`, …) and the
  field names are the same; `value_big` and `value_identity_of` are the two new
  readers for the moved payloads. `value_equal`, `value_compare`, `value_hash`,
  `value_format` and `value_coerce` only had those two readers swapped.
- **Ownership.** `value_clone` and `value_deep_free` still only deep-copy and
  release strings, bytes and lists; the 128-bit payload is inline and the
  identity pointer is shared, exactly like a `[]Value` header was before.

## Rejected alternatives

- **A `#no_nil` union payload with accessor helpers everywhere.** Correct, but
  it rewrites about a thousand field reads instead of ten, for the same size.
- **`struct #raw_union #packed` with a `u128` payload.** Gives 17 bytes and
  1-byte alignment: every field access becomes unaligned and Odin may assume
  16-byte alignment for `u128`. The two-word payload keeps the struct naturally
  aligned at 24.
- **`Row_Extras` behind a `u32` index** (the original plan). It would save the
  intern table for identities but needs an extras owner threaded through every
  `Value` construction site, which is a much larger change for 8 bytes per rare
  value; revisit only if identities ever become numerous.
- **Growing `Value` to 40 bytes to keep `Identity` inline.** 40 misses the
  target and makes every ordinary value pay for a rare one.

## Guardrails

`test_value_layout` asserts the size contract, the bit patterns of the 128-bit
payloads (including `min(i128)` and `max(u128)`), identity interning and
equality, and a round trip of every storage class through a real table, the log
and a reopen. Change the layout only with that test updated on purpose.
