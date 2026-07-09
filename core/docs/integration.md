# Integrating libjd

A short, self-contained guide to linking and calling the library from your application. See `README.md` for the internal architecture.

## Building

```sh
zig build                                    # debug
zig build -Doptimize=ReleaseSmall            # smallest binary
zig build -Doptimize=ReleaseFast             # fastest binary
```

Outputs land in `zig-out/lib/` (and `zig-out/bin/` for the DLL on Windows):

| Platform | Static library      | Dynamic library                     |
|----------|---------------------|-------------------------------------|
| Linux    | `libjd.a`           | `libjd.so`                          |
| macOS    | `libjd.a`           | `libjd.dylib`                       |
| Windows  | `jd_static.lib`     | `jd.dll` (+ `jd.lib` import library) |

On Windows the static archive is named `jd_static.lib` to avoid colliding with the DLL's import library (`jd.lib`) — both would otherwise be written as `jd.lib` and overwrite each other in `zig-out/lib/`. Link against `jd_static.lib` for static linking; link against `jd.lib` and ship `jd.dll` for dynamic linking.

Targeting `wasm32-freestanding` produces neither — it emits a single WebAssembly reactor module at `zig-out/bin/jd.wasm`. See [WebAssembly](#webassembly).

The public header is at `include/jd.h`; a Clang/Swift module map is at `include/module.modulemap` (module name `Libjd`).

## Cross-compiling

`zig build` accepts the standard `-Dtarget=` option:

```sh
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-linux-musl
zig build -Dtarget=aarch64-ios
zig build -Dtarget=x86_64-windows
zig build -Dtarget=powerpc-linux-musl   # big-endian target
zig build -Dtarget=wasm32-freestanding   # WebAssembly reactor module
```

The blob's multi-byte fields are written in the target's endianness — the build-time generator runs on the host and, when the host and target differ, byte-swaps every u32 field before embedding the blob. Cross-compiling between little-endian and big-endian platforms is fully supported.
## The C API

Rust consumers should not hand-roll these declarations — depend on the shared bindings crate at `bindings/rust` (a Cargo path dependency; used by `cli/` and `windows/`), which links libjd and upholds the pointer-lifetime contract below by copying every result into owned data. Swift consumers likewise share the wrapper at `bindings/swift` (compiled directly into the `macos/` and `ios/` targets via their project.yml source paths). JavaScript/TypeScript consumers use the `bindings/javascript` package, which wraps the WebAssembly build — see [WebAssembly](#webassembly).

From `include/jd.h`:

```c
typedef struct {
  const char *value, *hint;
} query_option;

typedef struct {
  const char *commit;
  const query_option *options;
  unsigned int options_count, total_pages, current_page;
} query_result;

typedef struct jd_context jd_context;

jd_context   *jd_init(unsigned char page_size);
query_result  jd_press_key(jd_context *ctx, char key);
query_result  jd_next_page(jd_context *ctx);
query_result  jd_prev_page(jd_context *ctx);
query_result  jd_jump_to_page(jd_context *ctx, unsigned int page);
query_result  jd_backspace(jd_context *ctx);
void          jd_reset(jd_context *ctx);
void          jd_deinit(jd_context *ctx);
```

The header is C89-compatible and includes an `extern "C"` block for C++ consumers.

`jd_context` is opaque — the caller never inspects its layout. Multiple contexts may exist at once; the embedded trie is parsed once on first use and shared read-only across all of them.

### Function semantics

| Function                       | Effect                                                                       |
|--------------------------------|------------------------------------------------------------------------------|
| `jd_init(page_size)`           | Allocate a new context; `page_size` must be ≥ 1. Returns NULL when it is 0 or on allocation failure. |
| `jd_press_key(ctx, key)`       | Feed one keystroke. Returns either a committed string or a page.             |
| `jd_next_page(ctx)`            | Move to next page of the current candidate list, if any.                     |
| `jd_prev_page(ctx)`            | Move to previous page, if any.                                               |
| `jd_jump_to_page(ctx, n)`      | Set the current page directly (1-based); out-of-range is a no-op.            |
| `jd_backspace(ctx)`            | Undo the most recent letter keypress; recompute candidates.                  |
| `jd_reset(ctx)`                | Drop the in-flight query but keep the context alive.                         |
| `jd_deinit(ctx)`               | Tear down this context. Other contexts and the shared trie are unaffected.   |

### Reading `query_result`

The four numeric fields and two pointer fields together encode three mutually exclusive states:

| State                     | `commit`    | `options`     | `options_count` | `total_pages` | `current_page` |
|---------------------------|-------------|---------------|-----------------|---------------|----------------|
| Candidates available      | `NULL`      | non-`NULL`    | total candidates| ≥ 1           | 1-based        |
| Committed                 | non-`NULL`  | `NULL`        | 0               | 0             | 0              |
| Committed + drilled in    | non-`NULL`  | non-`NULL`    | total candidates| ≥ 1           | 1-based        |
| Empty (no-op)             | `NULL`      | `NULL`        | 0               | 0             | 0              |

The third row happens when the user types a key that isn't a child of the current trie node but *is* a child of the root: the current page's first candidate is committed *and* the user is now navigating fresh from the root with the just-pressed key.

`options_count` is the total candidates across all pages — not the length of the visible `options` array. The visible length is:

```
visible = (current_page == total_pages)
        ? (options_count - 1) % page_size + 1
        : page_size
```

All of the engine's automatic commits are **page-relative**: space, the commit-and-jump in the third row, and the literal-byte fallback each commit the first option of the paginator's **current page** — and `;` picks the current page's second — not global option 0. An IME that moves the paginator for reasons the user can't see (e.g. prefetching pages into an append-only candidate strip) must park it back on the visible page with `jd_jump_to_page` before the next key reaches the engine, or those commits target a page the user isn't looking at. This is exactly the bug the iOS/Android frontends had in their `loadMoreCandidates`; see how they fetch ahead and immediately jump back.

### Pointer lifetimes (important)

Every pointer in a returned `query_result` is **borrowed**. Lifetimes are per-context — invalidation triggers are calls into the same `ctx`:

- **`commit`** may point into either the embedded trie strings pool (when the commit *is* an existing candidate value — the common case) or a small per-context scratch buffer (when it's a synthesized or concatenated string). The caller can't and shouldn't distinguish: treat it as valid only until the next call into that context: `jd_press_key`, `jd_next_page`, `jd_prev_page`, `jd_jump_to_page`, `jd_backspace`, `jd_reset`, or `jd_deinit`. Copy it out before making any further call if you need it longer.
- **`options` and each `option.hint`** are valid only until the next state-changing call into the same context (same list as above). The `options` array and the hint strings live in the paginator's per-page buffer; either may be overwritten when the user navigates to another page or starts a new query.
- **`option.value`** always points into the embedded blob and is effectively static.

Treat the rule simply as: **don't hold any pointer returned for a context across the next call into that context.** Pointers from one context are unaffected by calls into a different context.

### Lifecycle contract

```
ctx = jd_init(...)  ──►  (jd_press_key   | jd_next_page | jd_prev_page |
                          jd_jump_to_page | jd_backspace | jd_reset)*  ──►  jd_deinit(ctx)
```

Each `jd_init` call returns an independent context owned by the caller. Contexts share the embedded trie (parsed lazily on the first call from any thread, then immutable for the rest of the process), but their query state is fully separate — pages, in-flight key indexes, scratch and pagination buffers, etc.

`jd_init` performs exactly one heap allocation (sized from caps embedded in the trie and punctuation blobs — worst-case BFS state, page buffers, and the longest possible commit composition) and `jd_deinit` performs exactly one matching free; nothing in between calls the allocator. Per-context resident memory for the bundled dictionary is around 240 KB at the default page size.

### Thread-safety

| Pattern                                                    | Safe?                                |
|------------------------------------------------------------|--------------------------------------|
| Different contexts called from different threads           | Yes — trie is read-only after init.  |
| A single context called from multiple threads concurrently | No — wrap calls in an external lock. |
| Multiple threads racing the very first `jd_init`           | Yes — the trie's one-time init is atomic. |

The library uses `std.heap.smp_allocator` internally (thread-safe, pure Zig, no libc dependency) — except on WebAssembly, which uses `std.heap.wasm_allocator` (see [WebAssembly](#webassembly)).

## WebAssembly

`zig build -Dtarget=wasm32-freestanding` produces a standalone reactor module at `zig-out/bin/jd.wasm` instead of the static/dynamic libraries. It has no `_start`, imports nothing (no WASI), and exports linear `memory`, the full `jd_*` C ABI, and one wasm-only helper — `jd_wasm_result_ptr`. The engine swaps `smp_allocator` for `std.heap.wasm_allocator` (the former needs threads and an OS page allocator, neither of which `wasm32-freestanding` has); everything else — including the embedded dictionary — is identical to the native build.

Calling the C ABI from a host has one wrinkle. `query_result` is a five-field struct, so the wasm32 C ABI returns it through an implicit struct-return pointer (sret): each result-returning `jd_*` export compiles to `fn(sret_ptr, ...args) void` and writes the struct through the caller-provided pointer. `jd_wasm_result_ptr()` returns the address of a single static `query_result` to use as that pointer — read its five little-endian `u32` fields out of `memory` after each call, then follow the `commit` / `options` pointers (also offsets into `memory`). The [pointer-lifetime contract](#pointer-lifetimes-important) still applies: copy the strings out before the next `jd_*` call.

You rarely want to do that by hand. The **`bindings/javascript`** package wraps all of it behind an ergonomic JavaScript API (`JdModule` / `Engine`, with TypeScript types) that copies every result into owned JS values. Point it at the `jd.wasm` from `zig build` or the `libjd-<ver>-wasm.wasm.tar.xz` release asset.

## Key routing for IMEs

`libjd` is the input *engine*; an IME built on top of it is the *interaction layer*. They have a clean split of responsibilities:

- The **engine** owns text-input semantics — extending the trie, committing on terminators, generating candidates, paginating.
- The **IME** owns UX — when to consume a keystroke vs let it pass through, how to render the composition and candidate list, what gesture/key selects a candidate.

The table below is the recommended dispatch policy across all platforms. Following it keeps engine behavior identical on Windows / macOS / Linux / iOS / Android, and concentrates per-platform differences in a small number of IME-side decisions.

| Key class | Dispatch | API call |
|---|---|---|
| Modifier chords (Ctrl / Cmd / Alt / Win+anything) | IME | pass through to the host — these are host shortcuts (select-all, copy/paste, menu accelerators, system commands) |
| `a`–`z` | engine | `jd_press_key(byte)` — descends the trie / starts a composition |
| Punctuation (the keys mapped in `src/punctuation-marks/normal.txt` + `paired.txt`, plus `;`) | engine **or** IME — implementer's choice | **Delegate to the engine**: `jd_press_key(byte)` resolves the byte to a Chinese mark (auto-commit, paired-toggle, or a candidate window — see "Punctuation handling" below). **Or bypass the engine** and insert the mark in the IME yourself, replicating the engine's semantics: if a composition is in flight, commit the top candidate first, then append the mark; otherwise insert the mark directly. **Desktop IMEs usually delegate** (the hardware key already shows the ASCII glyph); **mobile IMEs usually bypass**, so the on-screen keyboard shows the Chinese marks directly and the user taps the exact one. Either way, dispatch the **actually-typed byte** (`Shift+/` → `?`, `Shift+1` → `!`). **`;` is a special case**: the engine routes it through its trie *symbol scheme* (`;`→`；`, `;;`→`：`, `;e`→`（`, … — opening a candidate window when not composing) rather than the punctuation tables, and reuses it as the built-in **2nd-candidate selector** while composing a trie code (it picks the current page's option 1, not commit-then-append; on a *punctuation* candidate window it instead commits the window's first option and then opens its own symbol window). A delegating desktop IME gets both behaviors for free; a bypassing mobile IME usually omits the `;` key, since a candidate tap already selects the 2nd one. |
| Other printable ASCII (digits `0`-`9`, uppercase letters, other `Shift`/`Caps Lock`-modified bytes not in the punctuation tables …) | engine | `jd_press_key(byte)` — commits the current state and appends the byte literally, so `Shift+K` → `K` yields `…K`. |
| Space | engine | `jd_press_key(' ')` — engine commits the current page's first candidate and appends nothing |
| Candidate-selector keys / gestures | IME (bindings up to the implementer) | `commit_text(option_at(N).value)` then `jd_reset()` |
| Page-navigation keys / gestures | IME (bindings up to the implementer) | `jd_next_page` / `jd_prev_page` — separate functions, not bytes |
| Backspace | IME | `jd_backspace` plus shrink the IME's composition |
| Escape / Cancel | IME | `jd_reset` + tear down the composition without committing |
| Enter / Return | IME | commit the raw in-flight letters as-is — escape hatch for literal ASCII output; *do not* route to the engine |
| Home / End / Insert / Delete, arrows (if not bound to page nav) | IME | **consume while composing** — letting them through would move the host's caret out of the composition range |
| Function keys (F1-F12), modifiers (Ctrl/Shift/Alt/Win/Meta), media keys | IME | pass through to the host — not text input |

### Rationale

- **Why the engine handles all printable bytes (including space and punctuation)**: the engine's contract is "extend trie if the byte is a child of the current node; otherwise commit current state, then start fresh from root with the byte." Space is the one byte the engine treats as commit-only (it never appears in the appended commit string). Punctuation auto-commits *and* appends. Letting the engine own this means platform IMEs don't have to special-case any printable key.

- **Why modifier chords pass through**: `Ctrl`/`Cmd`/`Alt`/`Win`+anything are user shortcuts (select-all, save, menu accelerators, system commands). Routing them to the engine would feed `'a'` to the trie every time the user pressed Ctrl+A and break every editor convention. `Shift` and `Caps Lock` are *not* in this category — they don't pass through; they're the means by which the user types uppercase / shifted bytes that the engine receives. The IME translates the keypress via the platform's "VK + keyboard state → character" API (`ToUnicode` on Windows, `UCKeyTranslate` on macOS, etc.) so the engine sees `K` and `?` rather than `k` and `/`, and the engine's commit-and-append rule produces `你K` / `你?` naturally — no IME-side special case for "uppercase letter."

- **Why candidate selectors and page-nav bindings are the IME's call**: the engine has no opinion on *how* the user picks a non-top candidate or paginates — only on *what* candidates exist. Pick the bindings that fit the platform's idioms. A desktop IME might use `PgUp`/`PgDn` for pagination and `1` - `9` for selection, a mobile IME might use a swipe for pagination and a tap for selection. Whatever the bindings are, intercept them *before* `jd_press_key` so the engine never sees them.

- **Why pagination is IME-side**: `jd_press_key` doesn't have a "page" byte. The engine exposes `jd_next_page` / `jd_prev_page` as direct calls; the IME picks the gesture and invokes them.

- **Why Enter commits the raw letters, not via the engine**: it's the escape hatch for typing literal ASCII (URLs, code, English words) without engine conversion. The IME ends the composition with whatever text is currently displayed (the raw typed bytes), bypassing the engine's commit pipeline entirely. `jd_reset()` resets the engine state afterward.

- **Why arrow / nav keys are always consumed while composing**: the engine has no "cursor inside the composition" model — corrections are via `jd_backspace` only. If the IME let arrow keys reach the host, the host would move its caret out of the in-flight composition range, breaking the visual link between what the user is typing and where the text lands. Either bind arrows to page navigation (most natural — users expect ← to move "back" through pages) or no-op them, but never pass them through.

### Punctuation handling

The engine ships a build-time-generated punctuation table that maps selected ASCII bytes to Chinese equivalents. When `jd_press_key(byte)` finds a match, the engine handles it without any IME involvement:

- **Paired** (e.g. `"` → `“` / `”`): single-press commit; consecutive presses of the same key alternate halves. The toggle state is per-context, indexed by ASCII byte, and survives `jd_reset()` — it is cleared only by `jd_deinit`. Different paired keys (`"` vs `'` vs `(`) have independent toggles.
- **Normal, single candidate** (e.g. `.` → `。`): single-press commit, no window.
- **Normal, multiple candidates** (e.g. `[` → `「`/`【`/`〔`/`［`): opens a candidate window — `query_result.options` is non-`NULL`. The IME paginates via `jd_next_page` / `jd_prev_page` and selects with its own bindings, exactly as for trie candidates (commit `option_at(N).value`, then `jd_reset`). Do **not** route selector keys to the engine here: it treats `1`-`9` as literal input (`[` then `2` commits `「2`), and `;` does not pick option 1 on a punctuation window (it commits the window's first option, then opens its own symbol window). `jd_press_key(' ')` commits the current page's first option. Pagination honors `page_size` from `jd_init`.

Mixed-state behavior:

- If a trie composition is in flight (some letters typed) when a punctuation key is pressed, the engine commits the trie page's first candidate **and** the punctuation in one step (e.g. typing `n` then `.` yields a commit of `你。`).
- If a punctuation candidate window is open when the user presses a non-punctuation key, the engine commits the window's first candidate and then processes the new key (e.g. `[` opens the bracket window, pressing `n` commits `「` and starts a fresh trie composition with `n`).
- `jd_backspace` while a punctuation candidate window is open closes the window without committing.

If a byte isn't in either punctuation table, the engine falls back to the trie behavior described in the dispatch table.

If the IME **delegates** punctuation to the engine, it doesn't have to do anything special — just route the actually-typed byte to `jd_press_key` and use whatever `query_result` comes back. The full set of mapped keys is the union of the keys listed in `src/punctuation-marks/normal.txt` and `paired.txt`.

**Bypassing the engine (recommended for mobile IMEs).** Instead of routing punctuation to `jd_press_key`, a mobile IME typically shows the Chinese marks *directly* on the on-screen keyboard and inserts the tapped mark itself — the pressed key already *is* the mark, with no ASCII byte or table lookup involved. This is more intuitive on touch: the user sees and taps the exact mark, and paired marks (`“`/`”`, `‘`/`’`) become two separate keys rather than a press-toggle. To stay consistent with the delegating path, replicate the engine's commit-then-append rule:

- **Composing**: commit the current top candidate — `query_result.options[0].value`, which the IME already has from the last result — then `jd_reset(ctx)` and insert the mark. No engine call is needed: option 0 is exactly what the engine would have committed — provided the paginator still sits on the page that produced that result (see the page-relative note under "Reading `query_result`").
- **Not composing**: insert the mark directly.

In this mode the engine's punctuation table goes unused; the engine still owns the trie and the candidate list, and the IME just commits option 0 of the current result to flush an in-flight candidate — so behavior stays identical to a delegating IME, mark for mark.

### Putting it together

A minimal IME key handler starts by picking its own candidate-selector and page-navigation bindings, and deciding whether it handles punctuation itself (bypassing the engine) or delegates it. The selector / page bindings are claimed only while composing; punctuation, if the IME owns it, is claimed whether or not a composition is in flight. These choices are platform-specific:

```text
# A desktop IME binds keys and lets the engine convert punctuation:
candidate_selectors = '1'..'9'        # press N to pick the Nth candidate
page_prev / page_next = PgUp / PgDn   # (or ←/→, or '-'/'=')
handles_punctuation   = false         # route punctuation bytes to the engine

# A mobile IME selects by tap and paginates by swipe, so it binds NO keys, and
# owns punctuation so it can show the Chinese marks directly on the keyboard:
candidate_selectors = {}              # '1'-'9' are not selectors here
page_prev / page_next = (gestures)    # not keys at all
handles_punctuation   = true          # insert the tapped Chinese mark directly
```

The handler then dispatches each key against those bindings:

```text
on_key_down(key, ctx):
    if ctrl / cmd / alt / win held: pass through to host

    byte = translate_to_ascii(key, current keyboard state)
              # shift/caps-aware; e.g. Shift+/ → '?', Shift+K → 'K'

    if composing:
        # IME-owned keys, intercepted before the engine. They only matter
        # while a composition / candidate window is live.
        match key:
            backspace      → jd_backspace(ctx); shrink composition; redraw; done
            escape         → jd_reset(ctx); end composition; hide candidates; done
            enter          → commit raw composition text; jd_reset(ctx); hide candidates; done
            a page_prev / page_next binding → jd_prev_page / jd_next_page(ctx); redraw; done
            a candidate_selector for slot N:
                if a candidate exists at slot N → commit option_at(N).value; jd_reset(ctx); hide; done
                else → fall through to the engine (treat the key as a literal byte)
            other nav (home/end/etc.) → consume but no-op (engine has no cursor); done
            handles_punctuation and the key is a punctuation key:
                # IME owns punctuation (typical on mobile, where the on-screen key
                # already IS the Chinese mark). Commit the current top candidate —
                # the IME already has it from the last result, so no engine call —
                # then insert the mark on the pressed key:
                commit option_at(0).value; jd_reset(ctx); hide candidates
                insert the pressed key's mark; done
            otherwise: fall through to the engine dispatch below

    # IME-handled punctuation with NO composition in flight — just insert the mark
    # on the pressed key (the composing case is handled in the match above). When
    # handles_punctuation is off, punctuation reaches the engine dispatch below.
    if handles_punctuation and the key is a punctuation key:
        insert the pressed key's mark; done

    # Engine dispatch — runs whether or not a composition is in flight, for
    # every byte not claimed above. Because the selector/page bindings are
    # IME-defined, '1'-'9' reach here on a mobile IME (never claimed) but on a
    # desktop IME only when no candidate fills that slot. Every printable byte
    # the engine accepts: lowercase letters (a-z) start a composition;
    # punctuation resolves to Chinese (auto-commit, e.g. '.' → '。', or opens a
    # candidate window) — unless the IME already handled it above; every other
    # byte (digits, uppercase, unmapped symbols, space) is committed back
    # literally, so its visible output is unchanged. Chinese punctuation
    # therefore works even with no composition in flight.
    if byte is printable ASCII (0x20–0x7E):
        result = jd_press_key(ctx, byte)
        if result.commit: insert it (ending the composition if one was active)
        if result.options: start / extend composition, show candidates
        if both: drilled-in — insert commit, restart composition with byte
        if neither: don't consume (let the host see the key)
    else:
        pass through to host  # control chars, non-ASCII, function/media keys
```

The candidate-selector and page-prev / page-next lines are where the per-platform bindings live; everything else is identical across platforms. Two consequences worth restating:

- A bound candidate selector or page-nav key is consumed *before* the engine and never reaches `jd_press_key`. So a desktop IME's `1`-`9` pick candidates while composing, whereas a mobile IME (which binds no selector keys) sends `1`-`9` straight to the engine as literal digits.
- The engine dispatch is reached whether or not a composition is active — so a bare `.` commits `。` exactly as `n` then `.` commits `你。`, whether the engine resolves the punctuation or the IME does it itself. The keys that bypass the engine dispatch are the modifier chords, the IME-owned selector / page / nav keys (only while composing), and — when `handles_punctuation` is on — punctuation keys (the IME inserts the mark directly, still flushing any in-flight candidate by committing option 0 of the current result first).

## Allocator

Native builds use `std.heap.smp_allocator` (WebAssembly uses `std.heap.wasm_allocator` instead — see [WebAssembly](#webassembly)) — pure Zig, no libc dependency — and only ever touch it twice per context: one `alignedAlloc` inside `jd_init`, one matching `free` inside `jd_deinit`. Everything else (commit composition, BFS state, per-page candidate arrays, hint strings) lives in fixed-size regions carved from the per-context buffer at init time.

Because there is no runtime allocator traffic, there is no per-context leak detection to enable in Debug builds — leaks would only ever come from a misuse of `jd_init` / `jd_deinit` on the caller's side, which any standard heap-checker (Valgrind, AddressSanitizer, etc.) will surface against the one alloc/free pair.
