# libjd

Core engine for the `jd` input method. Maps key sequences (a–z plus `;`) to candidate strings via a build-time-generated trie, then runs an interactive query/pagination state machine behind a small C ABI. Zero runtime dependencies — does not link libc.

## Integration Guide

To consume this library, see [docs/integration.md](./docs/integration.md).

## Architecture

The build is split into a host-side step and a target-side step.

```
Host (build time)                          Target (runtime)
─────────────────                          ────────────────
src/tables/*.txt
       │
       ▼
gen_trie  ──►  trie.bin  (binary blob)
                  │
                  ▼
            @embedFile  ──►  trie_blob.bytes  (rodata)
                                   │
                                   ▼
                             Trie.fromBytes  (O(1) pointer-cast)
                                   │
                                   ▼
                             Context (per-process state)
                                   │
                                   ├── trie cursor
                                   ├── NodePagination
                                   └── pressed-key history
```

At build time, `scripts/gen_trie.zig` runs on the host: it parses every `src/tables/*.txt` file, builds a trie via `trie.buildBlob`, and writes `trie.bin` plus a tiny wrapper module that does `@embedFile("trie.bin")`. The library imports that wrapper through the `trie_blob` module name and exposes it as a 4-byte-aligned `[]const u8` (see `src/tables.zig`).

At runtime, `jd_init` reinterprets the embedded bytes as a `Trie` view in O(1) — no parsing, no copying. All trie pointers (`*const Node`, value strings) point directly into the embedded blob.

Multi-byte fields in the blob are written in **target** endianness. The generator detects a mismatch with the host at build time and byte-swaps every u32 field, so the runtime can always read fields directly through `@ptrCast` in its native byte order — including when cross-compiling from LE to BE (or vice versa).

## Build & test

```sh
zig build              # produces zig-out/lib/libjd.{a,so,dylib,dll}
zig build test         # runs unit tests
zig build -Doptimize=ReleaseSmall   # smallest binary
```

The `-Dtables_eol=lf|crlf` option controls how the build-time generator splits table files. Defaults to `lf`; pass `crlf` on Windows checkouts that may have CRLF endings.
