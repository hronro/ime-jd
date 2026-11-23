# libjd

Core engine for the `jd` input method. Two build-time-generated data structures drive it: a trie mapping key sequences (a–z plus `;`) to candidate strings — the dictionary — and a punctuation lookup table mapping ASCII punctuation keys to Chinese punctuation (auto-committed singles, multi-candidate windows, and toggled paired quotes). Two more, both optional, are built at runtime by the host: a dictionary of its own, in place of the embedded one, and a user dictionary of the user's own phrases, merged into every candidate list. All of them feed an interactive query state machine exposed through a small C ABI. Zero runtime dependencies — does not link libc. Built with `-Dbuiltin_dict=false` it embeds no dictionary at all (libjd-engine), for a host that always passes its own.

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
gen_trie (dict.build) ──►  trie.bin
                  │
                  └──► @embedFile ──► Trie.fromBytes  (O(1) ptr-cast)  — or a host's dictionary, dict.open (O(n) check)
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
                                            ├── its dictionary (embedded, or the host's blob)
                                            ├── composed prefix (key bytes) + dictionary node
                                            ├── user dict view (host blob, optional)
                                            ├── pager: Pager union (trie | punc)
                                            │     trie = built-in BFS ⨝ user cursor
                                            ├── anchor_index + 2 cached options
                                            └── pair_toggle_bits  (1 bit / ASCII key)

Host (runtime, optional)
────────────────────────
text ──► jd_dict_build ──► dictionary blob (host memory, cached) ──┐
phrases.txt / GUI ──► jd_user_dict_build ──► blob (host memory, cached) ──► jd_init(dict, user_dict) ──► dict.open / UserDict.fromBytes (O(n) validate, no copy)
```

**Trie pipeline.** At build time, `scripts/gen_trie.zig` joins every `tables/*.txt` file and builds it with `dict.build` (`src/dict.zig`) — the very builder `jd_dict_build` runs for a host, line rules included, but strict: a line it would skip or drop fails the build, naming the file and line — then writes `trie.bin` plus a tiny wrapper module that does `@embedFile("trie.bin")`. The library imports that wrapper through the `trie_blob` module name and exposes it as a 4-byte-aligned `[]const u8` (see `src/tables.zig`). The builder needs no allocator: a stable radix sort puts the lines in depth-first code order, which makes each node at depth *d* one run of lines sharing *d* keys, so the nodes come out breadth first, depth by depth, with their counts and the BFS buffer sizes worked out from how many keys each line shares with the one before; then the reverse index is sorted in place. A host's dictionary goes through `dict.open` at `jd_init`, which checks every structural fact the engine relies on — numbering, code rules, counts, buffer sizes, UTF-8, the index — in O(n), so a corrupt one is refused rather than trusted; the embedded one is trusted, and checked by a test instead.

**Punctuation pipeline.** `scripts/gen_punc.zig` does the same for `punctuation-marks/normal.txt` (key + N candidate values) and `paired.txt` (key + open + close), producing `punc.bin` and a `punc_blob` wrapper. The runtime view (`punc.Punc`) is two inline 256-slot tables directly indexed by ASCII byte plus a shared NUL-separated strings pool — no prefix-sum, just one indexed load per lookup. Conflicts (same key in both files, reserved keys like space / `;` / digits, duplicate keys within a file) are caught at build time.

**User dictionary pipeline.** `src/user_dict.zig` is built at runtime by the host, not at startup: `jd_user_dict_build` turns `value<TAB>keys` text (the table files' own format, by the same line rules) into a blob inside a buffer the host supplies, skipping the lines that do not parse (one typo never costs the rest of the file), sorting, and dropping exact duplicates of earlier lines and of words on the same code in the dictionary beneath — the embedded one or the host's. It is O(n log n) whatever the text holds: a stable radix sort puts the phrases in code order, the phrases sharing a code are sorted by value for a moment so a repeat sits next to the line it repeats, and one trie walk per code — resumed from where it parts from the code before — answers whether a built-in word repeats a phrase and how many share its code. Up to the 500 000-phrase cap, that is about 30 ms for the cap's worth on a desktop core. It also leaves *notes* past the blob, inside the same host buffer (the bound covers them): which lines it skipped and why, which it dropped and what they repeat, and which kept phrases sit on a code that a built-in word or another phrase already uses (重码), so a phrase manager flags its rows straight from the engine's verdict instead of re-deriving it. The host caches the blob's bytes however it likes — the blob carries a host-chosen 64-bit source tag, so the host can tell a current cache from a stale one without a sidecar record — and passes them to `jd_init`, which validates them in one linear pass — sizes, offsets, sort order, key alphabet, UTF-8 (one pass over the string pool), and the fingerprint of the dictionary the blob was deduplicated against (a hash of its contents, which every dictionary build stores in its header) — and then reads them in place. The values lie back to back in the pool, so its UTF-8 is checked whole, 16 bytes at a time where the target has vectors: about 2 ms for a blob at the cap. `jd_user_dict_hash` gives every host the same fast content hash for its source tag. A memory-mapped cache file is the natural blob — aligned, fixed, uncopied, and shared between processes that map it — and hosts without an allocator of their own, such as a WebAssembly host, get their buffers from `jd_alloc`. The blob's entries are sorted by key length, then by key rank, which is exactly the BFS order `NodePagination` yields, so the entries below any prefix are one binary search per key length and the two sources merge with a plain two-way merge (`TriePagination`). Nothing about the user cursor is sized by the dictionary, which is why the per-context allocation is unchanged and any blob can be attached to any context. The blob is the host's memory for the context's lifetime: switching dictionaries means creating a context with the new blob and releasing the old one.

**At runtime**, `jd_init` reinterprets each embedded blob as a `Trie` / `Punc` view in O(1) — no parsing, no copying — and validates a host's dictionary and user-dictionary blob, if any, in O(n). The context keeps its own `Trie` view, so contexts on different dictionaries live side by side. On each `jd_press_key`, the engine first checks the punctuation tables (paired then normal) before falling back to the trie. Paired entries flip a per-context toggle bit so consecutive presses alternate halves; multi-candidate normals open a candidate window via `PuncPagination` (lives alongside `NodePagination` in `src/pagination.zig`). "Does this key continue the composition" asks both the built-in trie and the user dictionary, so a prefix only the user dictionary knows composes exactly like a built-in one.

**Reverse lookup** (`jd_lookup_codes`, value → codes) needs no runtime index. `gen_trie` numbers the nodes breadth-first, children in key-rank order, so the children of every node laid end to end are nodes 1, 2, 3, … — a child slot `k` *is* node `k + 1`, and the blob needs no child-index pool. In its place it stores `by_value`, every value index sorted by the value's bytes: a value's occurrences are one binary search away, in node order, which is shortest code first. A node's code is spelled by walking up to the root, each parent found by a binary search over the nodes' monotonic `children_start`. The two pools are about the same size, so the blob barely changes. The user dictionary's half is a linear scan of its phrases, which are capped at 500,000: about a millisecond at the cap, which an index would buy back only by adding to every blob's size, build and validation.

**Candidates are enumerated by flat index**, not by page — `src/pagination.zig` exposes `readRange(start, count, out)` over a single forward-only cursor (a BFS over the built-in subtree, merged with the user cursor), writing into caller memory. That cursor is purely internal: `Context` keeps a separate `anchor_index` (plus the two options at it, which is all the engine's automatic commits can need) so a frontend can prefetch a candidate strip arbitrarily far ahead without changing what space would commit. Reading forward is amortized O(1) per candidate; reading backward rewinds and replays. A user phrase comes before a built-in word on the same code, so a user can override what a code commits by default.

Nothing the caller receives is ever invalidated by the engine: a candidate's `value` and a commit's segments point into the embedded blobs — or into the user-dictionary blob the context was created with, which the host keeps alive — and a candidate's `hint` is inline bytes. Commits are returned as up to two such pointers plus one literal byte rather than being assembled, so the library owns no string buffer at all.

The dictionary blob's header carries worst-case sizes for the BFS frontier and path buffer, computed by the build. `jd_init` reads those caps and allocates one per-context buffer big enough to hold the `Context` struct plus both regions. After that one allocation, the library never touches the allocator again until `jd_deinit` — `jd_user_dict_build` included, which sorts and lays out its string pool inside the host's output buffer.

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

The `-Dtables_eol=lf|crlf` option controls how the punctuation generator splits its files. Defaults to `lf`; pass `crlf` on Windows checkouts that may have CRLF endings. (The dictionary tables need no such option: every dictionary line drops a trailing CR.)

`-Dbuiltin_dict=false` builds libjd-engine, without the embedded dictionary — see [docs/integration.md](./docs/integration.md#libjd-engine-without-the-embedded-dictionary).

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
