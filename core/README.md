# libjd

Core engine for the `jd` input method. Two build-time-generated data structures drive it: a trie mapping key sequences (a–z plus `;`) to candidate strings, and a punctuation lookup table mapping ASCII punctuation keys to Chinese punctuation (auto-committed singles, multi-candidate windows, and toggled paired quotes). Both feed an interactive query state machine exposed through a small C ABI. Zero runtime dependencies — does not link libc.

## Integration Guide

To consume this library, see [docs/integration.md](./docs/integration.md).

## Architecture

The build runs two parallel host-side generators that emit blobs the target embeds via `@embedFile`.

```
Host (build time)                          Target (runtime)
─────────────────                          ────────────────
tables/*.txt
       │
       ▼
gen_trie  ──►  trie.bin
                  │
                  └──► @embedFile ──► Trie.fromBytes  (O(1) ptr-cast)
                                            │
punctuation-marks/*.txt                     │
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
                                            ├── anchor_index + 2 cached options
                                            └── pair_toggle_bits  (1 bit / ASCII key)
```

**Trie pipeline.** At build time, `scripts/gen_trie.zig` parses every `tables/*.txt` file, builds a trie via `trie.buildBlob`, and writes `trie.bin` plus a tiny wrapper module that does `@embedFile("trie.bin")`. The library imports that wrapper through the `trie_blob` module name and exposes it as a 4-byte-aligned `[]const u8` (see `src/tables.zig`).

**Punctuation pipeline.** `scripts/gen_punc.zig` does the same for `punctuation-marks/normal.txt` (key + N candidate values) and `paired.txt` (key + open + close), producing `punc.bin` and a `punc_blob` wrapper. The runtime view (`punc.Punc`) is two inline 256-slot tables directly indexed by ASCII byte plus a shared NUL-separated strings pool — no prefix-sum, just one indexed load per lookup. Conflicts (same key in both files, reserved keys like space / `;` / digits, duplicate keys within a file) are caught at build time.

**At runtime**, `jd_init` reinterprets each blob as a `Trie` / `Punc` view in O(1) — no parsing, no copying. On each `jd_press_key`, the engine first checks the punctuation tables (paired then normal) before falling back to the trie. Paired entries flip a per-context toggle bit so consecutive presses alternate halves; multi-candidate normals open a candidate window via `PuncPagination` (lives alongside `NodePagination` in `src/pagination.zig`).

**Candidates are enumerated by flat index**, not by page — `src/pagination.zig` exposes `readRange(start, count, out)` over a single forward-only BFS cursor, writing into caller memory. That cursor is purely internal: `Context` keeps a separate `anchor_index` (plus the two options at it, which is all the engine's automatic commits can need) so a frontend can prefetch a candidate strip arbitrarily far ahead without changing what space would commit. Reading forward is amortized O(1) per candidate; reading backward rewinds and replays.

Nothing the caller receives can dangle: a candidate's `value` and a commit's segments point into the embedded blobs, and a candidate's `hint` is inline bytes. Commits are returned as up to two immortal pointers plus one literal byte rather than being assembled, so the library owns no string buffer at all.

The trie blob's header carries worst-case sizes for the BFS frontier and path buffer — `gen_trie` computes them with one bottom-up pass. `jd_init` reads those caps and allocates one per-context buffer big enough to hold the `Context` struct plus both regions. After that one allocation, the library never touches the allocator again until `jd_deinit`.

Multi-byte fields in both blobs are written in **target** endianness. Each generator detects a host/target mismatch at build time and byte-swaps the relevant fields (u32 for the trie blob; u32 + u16 for the punc blob), so the runtime can always read through `@ptrCast` in its native byte order — including when cross-compiling from LE to BE (or vice versa).

## Build & test

```sh
zig build                          # produces zig-out/lib/libjd.{a,so,dylib,dll}
zig build test                     # runs unit tests
zig build -Doptimize=ReleaseFast   # fastest binary
zig build -Doptimize=ReleaseSmall  # smallest binary
```

Targeting `wasm32-freestanding` builds a standalone WebAssembly reactor module (`zig-out/bin/jd.wasm`) exporting the same C ABI, instead of the static/dynamic libraries:

```sh
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseFast   # zig-out/bin/jd.wasm
```

See [docs/integration.md](./docs/integration.md#webassembly) for the WebAssembly specifics, and `bindings/javascript` for the ergonomic JavaScript wrapper.

The `-Dtables_eol=lf|crlf` option controls how the build-time generator splits table files. Defaults to `lf`; pass `crlf` on Windows checkouts that may have CRLF endings.

## Layout

```
build.zig            build graph: runs the generators, then builds the lib
build.zig.zon        package manifest (single source of truth for the version)
tables/              trie source data — *.txt, generator input
punctuation-marks/   punctuation source data — *.txt, generator input
scripts/             host-side generators (gen_trie.zig, gen_punc.zig)
src/                 library sources — .zig only
include/             public C headers
docs/                integration guide
```

The `.txt` files under `tables/` and `punctuation-marks/` are data, not compilation units: the Zig compiler never sees them. `build.zig` feeds them to the host-side generators, and only the resulting `.bin` blobs get embedded into the library. Both directories are listed in `build.zig.zon`'s `.paths`, so they travel with the package.
