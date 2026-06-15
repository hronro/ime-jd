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

The public header is at `include/jd.h`; a Clang/Swift module map is at `include/module.modulemap` (module name `Libjd`).

## Cross-compiling

`zig build` accepts the standard `-Dtarget=` option:

```sh
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-linux-musl
zig build -Dtarget=aarch64-ios
zig build -Dtarget=x86_64-windows
zig build -Dtarget=powerpc-linux-musl   # big-endian target
```

The blob's multi-byte fields are written in the target's endianness — the build-time generator runs on the host and, when the host and target differ, byte-swaps every u32 field before embedding the blob. Cross-compiling between little-endian and big-endian platforms is fully supported.

## The C API

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
| `jd_init(page_size)`           | Allocate a new context. Returns NULL on allocation failure.                  |
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

The third row happens when the user types a key that isn't a child of the current trie node but *is* a child of the root: the in-flight candidate is committed *and* the user is now navigating fresh from the root with the just-pressed key.

`options_count` is the total candidates across all pages — not the length of the visible `options` array. The visible length is:

```
visible = (current_page == total_pages)
        ? (options_count - 1) % page_size + 1
        : page_size
```

### Pointer lifetimes (important)

Every pointer in a returned `query_result` is **borrowed**. Lifetimes are per-context — invalidation triggers are calls into the same `ctx`:

- **`commit`** is allocated in a per-keypress arena (per context) and is valid only until the next call into that context: `jd_press_key`, `jd_next_page`, `jd_prev_page`, `jd_jump_to_page`, `jd_backspace`, `jd_reset`, or `jd_deinit`. Copy it out before making any further call if you need it longer.
- **`options` and each `option.value` / `option.hint`** are valid only until the next state-changing call into the same context (same list as above). Specifically, `option.value` points into the embedded blob (effectively static), but `option.hint` is allocated in the paginator's per-page arena and is invalidated when the user navigates to another page.

Treat the rule simply as: **don't hold any pointer returned for a context across the next call into that context.** Pointers from one context are unaffected by calls into a different context.

### Lifecycle contract

```
ctx = jd_init(...)  ──►  (jd_press_key   | jd_next_page | jd_prev_page |
                          jd_jump_to_page | jd_backspace | jd_reset)*  ──►  jd_deinit(ctx)
```

Each `jd_init` call returns an independent context owned by the caller. Contexts share the embedded trie (parsed lazily on the first call from any thread, then immutable for the rest of the process), but their query state is fully separate — pages, in-flight key indexes, the per-keypress arena, etc.

### Thread-safety

| Pattern                                                    | Safe?                                |
|------------------------------------------------------------|--------------------------------------|
| Different contexts called from different threads           | Yes — trie is read-only after init.  |
| A single context called from multiple threads concurrently | No — wrap calls in an external lock. |
| Multiple threads racing the very first `jd_init`           | Yes — the trie's one-time init is atomic. |

The library uses `std.heap.smp_allocator` internally (thread-safe, pure Zig, no libc dependency).

## Key routing for IMEs

`libjd` is the input *engine*; an IME built on top of it is the *interaction layer*. They have a clean split of responsibilities:

- The **engine** owns text-input semantics — extending the trie, committing on terminators, generating candidates, paginating.
- The **IME** owns UX — when to consume a keystroke vs let it pass through, how to render the composition and candidate list, what gesture/key selects a candidate.

The table below is the recommended dispatch policy across all platforms. Following it keeps engine behavior identical on Windows / macOS / Linux / iOS / Android, and concentrates per-platform differences in a small number of IME-side decisions.

| Key class | Dispatch | API call |
|---|---|---|
| Modifier chords (Ctrl / Cmd / Alt / Win+anything) | IME | pass through to the host — these are host shortcuts (select-all, copy/paste, menu accelerators, system commands) |
| `a`–`z`, `;` | engine | `jd_press_key(byte)` |
| Other printable ASCII (`.` `,` `'` `[` `]` `=` uppercase letters, `Shift`/`Caps Lock`-modified bytes …) | engine | `jd_press_key(byte)` — engine commits the current state and appends the byte. The IME must translate to the **actually-typed byte** (e.g. `Shift+/` → `?`, `Shift+1` → `!`, `Shift+K` → `K`), not the unshifted virtual key — the engine appends the byte literally, so `?` and `/` produce different commit strings |
| Space | engine | `jd_press_key(' ')` — engine commits the top candidate and appends nothing |
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

### Putting it together

A minimal IME key handler looks like:

```text
on_key_down(key, ctx):
    if ctrl / cmd / alt / win held: pass through to host

    byte = translate_to_ascii(key, current keyboard state)
              # shift/caps-aware; e.g. Shift+/ → '?', Shift+K → 'K'

    if not composing:
        if byte is a lowercase letter (a-z): start composition; jd_press_key(ctx, byte)
        else: pass through to host (host inserts literal `K`, `?`, `1`, etc.)

    else (composing):
        match key:
            backspace      → jd_backspace(ctx); shrink composition; redraw
            escape         → jd_reset(ctx); end composition; hide candidates
            enter          → commit raw composition text; jd_reset(ctx); hide candidates
            page-prev gesture → result = jd_prev_page(ctx); redraw candidates
            page-next gesture → result = jd_next_page(ctx); redraw candidates
            candidate-selector for N → commit option_at(N).value; jd_reset(ctx); hide
            other nav (home/end/etc.)→ consume but no-op (engine has no cursor)
            otherwise (any byte the engine accepts):
                result = jd_press_key(ctx, byte)
                if result.commit: insert it, end composition
                if result.options: extend composition, show candidates
                if both: drilled-in — insert commit, restart composition with byte
                if neither: don't consume (let the host see the key)
```

The page-prev / page-next / candidate-selector lines are where the per-platform bindings live; everything else is identical across platforms.

## Debug builds

A `Debug` build gives each context its own `DebugAllocator`. When you call `jd_deinit(ctx)`, the allocator's leak detector runs against that context's allocations and prints any unfreed blocks to stderr — independently for every context.

`Release` builds use `std.heap.smp_allocator` across all contexts — pure Zig, thread-safe, no libc dependency. That keeps the library zero-dep for distribution.
