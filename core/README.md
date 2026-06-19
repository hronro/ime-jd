# libjd

Core engine for the `jd` input method. Two build-time-generated data structures drive it: a trie mapping key sequences (a–z plus `;`) to candidate strings, and a punctuation lookup table mapping ASCII punctuation keys to Chinese punctuation (auto-committed singles, paginated multi-candidate windows, and toggled paired quotes). Both feed an interactive query/pagination state machine exposed through a small C ABI. Zero runtime dependencies — does not link libc.

## Integration Guide

To consume this library, see [docs/integration.md](./docs/integration.md).

## Architecture

The build runs two parallel host-side generators that emit blobs the target embeds via `@embedFile`.

```
Host (build time)                          Target (runtime)
─────────────────                          ────────────────
src/tables/*.txt
       │
       ▼
gen_trie  ──►  trie.bin
                  │
                  └──► @embedFile ──► Trie.fromBytes  (O(1) ptr-cast)
                                            │
src/punctuation-marks/*.txt                 │
       │                                    │
       ▼                                    │
gen_punc  ──►  punc.bin                     │
                  │                         │
                  └──► @embedFile ──► Punc.fromBytes  (O(1) ptr-cast)
                                            │
                                            ▼
                                     Context (per-context state)
                                            │
                                            ├── trie cursor + pressed-key history
                                            ├── pager: Pager union (trie | punc)
                                            └── pair_toggle_bits  (1 bit / ASCII key)
```

**Trie pipeline.** At build time, `scripts/gen_trie.zig` parses every `src/tables/*.txt` file, builds a trie via `trie.buildBlob`, and writes `trie.bin` plus a tiny wrapper module that does `@embedFile("trie.bin")`. The library imports that wrapper through the `trie_blob` module name and exposes it as a 4-byte-aligned `[]const u8` (see `src/tables.zig`).

**Punctuation pipeline.** `scripts/gen_punc.zig` does the same for `src/punctuation-marks/normal.txt` (key + N candidate values) and `paired.txt` (key + open + close), producing `punc.bin` and a `punc_blob` wrapper. The runtime view (`punc.Punc`) is two inline 256-slot tables directly indexed by ASCII byte plus a shared NUL-separated strings pool — no prefix-sum, just one indexed load per lookup. Conflicts (same key in both files, reserved keys like space / `;` / digits, duplicate keys within a file) are caught at build time.

**At runtime**, `jd_init` reinterprets each blob as a `Trie` / `Punc` view in O(1) — no parsing, no copying. On each `jd_press_key`, the engine first checks the punctuation tables (paired then normal) before falling back to the trie. Paired entries flip a per-context toggle bit so consecutive presses alternate halves; multi-candidate normals open a paginated candidate window via `PuncPagination` (lives alongside `NodePagination` in `src/pagination.zig`).

The trie blob's header carries worst-case sizes for the BFS frontier and path buffer used during pagination — `gen_trie` computes them with one bottom-up pass. `jd_init` reads those caps and allocates one per-context buffer big enough to hold the `Context` struct plus every internal container. After that one allocation, the library never touches the allocator again until `jd_deinit`.

Multi-byte fields in both blobs are written in **target** endianness. Each generator detects a host/target mismatch at build time and byte-swaps the relevant fields (u32 for the trie blob; u32 + u16 for the punc blob), so the runtime can always read through `@ptrCast` in its native byte order — including when cross-compiling from LE to BE (or vice versa).

## Build & test

```sh
zig build              # produces zig-out/lib/libjd.{a,so,dylib,dll}
zig build test         # runs unit tests
zig build -Doptimize=ReleaseSmall   # smallest binary
```

The `-Dtables_eol=lf|crlf` option controls how the build-time generator splits table files. Defaults to `lf`; pass `crlf` on Windows checkouts that may have CRLF endings.
