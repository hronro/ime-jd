# libjd

Core engine for the `jd` input method. Two build-time-generated data structures drive it: a trie mapping key sequences (a–z plus `;`) to candidate strings, and a punctuation lookup table mapping ASCII punctuation keys to Chinese punctuation (auto-committed singles, multi-candidate windows, and toggled paired quotes). A third, optional one is built at runtime by the host: a user dictionary of the user's own phrases, merged into every candidate list. All of them feed an interactive query state machine exposed through a small C ABI. Zero runtime dependencies — does not link libc.

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
                                            ├── composed prefix (key bytes) + built-in node
                                            ├── user dict view (host blob, optional)
                                            ├── pager: Pager union (trie | punc)
                                            │     trie = built-in BFS ⨝ user cursor
                                            ├── anchor_index + 2 cached options
                                            └── pair_toggle_bits  (1 bit / ASCII key)

Host (runtime, optional)
────────────────────────
phrases.txt / GUI ──► jd_user_dict_build ──► blob (host memory, cached) ──► jd_init(blob) ──► UserDict.fromBytes (O(n) validate, no copy)
```

**Trie pipeline.** At build time, `scripts/gen_trie.zig` parses every `tables/*.txt` file, builds a trie via `trie.buildBlob`, and writes `trie.bin` plus a tiny wrapper module that does `@embedFile("trie.bin")`. The library imports that wrapper through the `trie_blob` module name and exposes it as a 4-byte-aligned `[]const u8` (see `src/tables.zig`).

**Punctuation pipeline.** `scripts/gen_punc.zig` does the same for `punctuation-marks/normal.txt` (key + N candidate values) and `paired.txt` (key + open + close), producing `punc.bin` and a `punc_blob` wrapper. The runtime view (`punc.Punc`) is two inline 256-slot tables directly indexed by ASCII byte plus a shared NUL-separated strings pool — no prefix-sum, just one indexed load per lookup. Conflicts (same key in both files, reserved keys like space / `;` / digits, duplicate keys within a file) are caught at build time.

**User dictionary pipeline.** `src/user_dict.zig` is the one piece built at runtime, and it is built by the host, not at startup: `jd_user_dict_build` turns `value<TAB>keys` text (the table files' own format) into a blob inside a buffer the host supplies, skipping the lines that do not parse (one typo never costs the rest of the file), sorting, and dropping exact duplicates of earlier lines and of built-in words on the same code. It also leaves *notes* past the blob, inside the same host buffer (the bound covers them): which lines it skipped and why, which it dropped and what they repeat, and which kept phrases sit on a code that a built-in word or another phrase already uses (重码), so a phrase manager flags its rows straight from the engine's verdict instead of re-deriving it. The host caches the blob's bytes however it likes — the blob carries a host-chosen 64-bit source tag, so the host can tell a current cache from a stale one without a sidecar record — and passes them to `jd_init`, which validates them in one linear pass — sizes, offsets, sort order, key alphabet, UTF-8 (one pass over the string pool), and a fingerprint of the built-in trie the blob was deduplicated against (`gen_trie` emits it as a CRC-32 next to `trie.bin`) — and then reads them in place. A memory-mapped cache file is the natural blob — aligned, fixed, uncopied, and shared between processes that map it — and hosts without an allocator of their own, such as a WebAssembly host, get their buffers from `jd_alloc`. The blob's entries are sorted by key length, then by key rank, which is exactly the BFS order `NodePagination` yields, so the entries below any prefix are one binary search per key length and the two sources merge with a plain two-way merge (`TriePagination`). Nothing about the user cursor is sized by the dictionary, which is why the per-context allocation is unchanged and any blob can be attached to any context. The blob is the host's memory for the context's lifetime: switching dictionaries means creating a context with the new blob and releasing the old one.

**At runtime**, `jd_init` reinterprets each embedded blob as a `Trie` / `Punc` view in O(1) — no parsing, no copying — and validates the user-dictionary blob, if any, in O(n). On each `jd_press_key`, the engine first checks the punctuation tables (paired then normal) before falling back to the trie. Paired entries flip a per-context toggle bit so consecutive presses alternate halves; multi-candidate normals open a candidate window via `PuncPagination` (lives alongside `NodePagination` in `src/pagination.zig`). "Does this key continue the composition" asks both the built-in trie and the user dictionary, so a prefix only the user dictionary knows composes exactly like a built-in one.

**Candidates are enumerated by flat index**, not by page — `src/pagination.zig` exposes `readRange(start, count, out)` over a single forward-only cursor (a BFS over the built-in subtree, merged with the user cursor), writing into caller memory. That cursor is purely internal: `Context` keeps a separate `anchor_index` (plus the two options at it, which is all the engine's automatic commits can need) so a frontend can prefetch a candidate strip arbitrarily far ahead without changing what space would commit. Reading forward is amortized O(1) per candidate; reading backward rewinds and replays. A user phrase comes before a built-in word on the same code, so a user can override what a code commits by default.

Nothing the caller receives is ever invalidated by the engine: a candidate's `value` and a commit's segments point into the embedded blobs — or into the user-dictionary blob the context was created with, which the host keeps alive — and a candidate's `hint` is inline bytes. Commits are returned as up to two such pointers plus one literal byte rather than being assembled, so the library owns no string buffer at all.

The trie blob's header carries worst-case sizes for the BFS frontier and path buffer — `gen_trie` computes them with one bottom-up pass. `jd_init` reads those caps and allocates one per-context buffer big enough to hold the `Context` struct plus both regions. After that one allocation, the library never touches the allocator again until `jd_deinit` — `jd_user_dict_build` included, which sorts and lays out its string pool inside the host's output buffer.

Multi-byte fields in both blobs are written in **target** endianness. Each generator detects a host/target mismatch at build time and byte-swaps the relevant fields (u32 for the trie blob; u32 + u16 for the punc blob), so the runtime can always read through `@ptrCast` in its native byte order — including when cross-compiling from LE to BE (or vice versa).

## Build & test

```sh
zig build                          # produces zig-out/lib/libjd.{a,so,dylib,dll}
zig build test                     # runs unit tests
zig build -Doptimize=fast          # fastest binary
zig build -Doptimize=small         # smallest binary
```

Targeting `wasm32-freestanding` builds a standalone WebAssembly reactor module (`zig-out/bin/jd.wasm`) exporting the same C ABI, instead of the static/dynamic libraries:

```sh
zig build -Dtarget=wasm32-freestanding -Doptimize=fast   # zig-out/bin/jd.wasm
```

See [docs/integration.md](./docs/integration.md#webassembly) for the WebAssembly specifics, and `bindings/javascript` for the ergonomic JavaScript wrapper.

The `-Dtables_eol=lf|crlf` option controls how the build-time generator splits table files. Defaults to `lf`; pass `crlf` on Windows checkouts that may have CRLF endings.

Every build except `-Doptimize=debug` strips debug info from the library. Pass `-Dstrip=false` to keep it, e.g. to symbolicate a crash inside the engine.

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
