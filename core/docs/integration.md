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

Rust consumers should not hand-roll these declarations — depend on the shared bindings crate at `bindings/rust` (a Cargo path dependency; used by `cli/` and `windows/`). Swift consumers likewise share the wrapper at `bindings/swift` (compiled directly into the `macos/` and `ios/` targets via their project.yml source paths). JavaScript/TypeScript consumers use the `bindings/javascript` package, which wraps the WebAssembly build — see [WebAssembly](#webassembly).

From `include/jd.h`:

```c
#define JD_HINT_CAP 8

typedef struct {
  const char *value;
  char hint[JD_HINT_CAP];
} query_option;

typedef struct {
  const char *commit_a, *commit_b;
  char commit_lit;
  unsigned int options_count, anchor_index;
} jd_state;

typedef struct jd_context jd_context;

jd_context     *jd_init(void);
void            jd_deinit(jd_context *ctx);

void            jd_press_key(jd_context *ctx, char key);
void            jd_backspace(jd_context *ctx);
void            jd_reset(jd_context *ctx);
void            jd_set_anchor(jd_context *ctx, unsigned int index);

const jd_state *jd_state_ptr(jd_context *ctx);
query_option   *jd_scratch_ptr(jd_context *ctx);
unsigned int    jd_read_range(jd_context *ctx, unsigned int start,
                              unsigned int count, query_option *out,
                              unsigned int out_cap);

unsigned int    jd_abi_layout(unsigned int what);
```

The header is C89-compatible and includes an `extern "C"` block for C++ consumers.

`jd_context` is opaque — the caller never inspects its layout. Multiple contexts may exist at once; the embedded trie is parsed once on first use and shared read-only across all of them.

No function returns a struct by value, so there is no sret shim on any target.

### Function semantics

| Function                      | Effect                                                                       |
|-------------------------------|------------------------------------------------------------------------------|
| `jd_init()`                   | Allocate a new context. Returns NULL on allocation failure.                  |
| `jd_deinit(ctx)`              | Tear down this context. Other contexts and the shared tables are unaffected. |
| `jd_press_key(ctx, key)`      | Feed one keystroke. Read the outcome with `jd_state_ptr`.                    |
| `jd_backspace(ctx)`           | Undo the most recent letter keypress; re-derive the candidates. Never commits. |
| `jd_reset(ctx)`               | Drop the in-flight composition *and* any recorded commit.                    |
| `jd_set_anchor(ctx, i)`       | Point the anchor at candidate `i` (0-based); out-of-range is a no-op.        |
| `jd_state_ptr(ctx)`           | Address of this context's state block. Stable for its whole lifetime.        |
| `jd_read_range(...)`          | Copy a window of candidates into caller memory. Pure — see below.            |
| `jd_scratch_ptr(ctx)`         | A context-owned buffer usable as `jd_read_range`'s `out`.                    |
| `jd_abi_layout(what)`         | Struct sizes and limits, for checking hand-written declarations.             |

### Candidates are addressed by flat index

The engine has **no notion of a page**. A composition exposes `options_count` candidates at indices `[0, options_count)`, and you read whatever window you want:

```c
query_option page[9];
unsigned int n = jd_read_range(ctx, 0, 9, page, 9);   /* the "first page" */
```

`jd_read_range` returns how many it wrote, clipped by both `out_cap` and the total. A short buffer or an out-of-range window is not an error, just a smaller result — there is no remainder math to get right.

Paging is a frontend concern. A desktop IME with a nine-wide panel reads `[(p-1)*9, p*9)`; a mobile candidate strip reads `[loaded, loaded+16)` and appends. Both are one call.

**Reads are pure.** `jd_read_range` never changes anything you can observe: it does not move `anchor_index`, and nothing it returns can be invalidated (see the next section). Prefetch as far ahead as you like; the only bookkeeping is remembering how far you got.

Cost model: reading forward is amortized O(1) per candidate, so walking the whole list in windows costs a single pass over the trie. Jumping backwards re-walks from the start, O(start + count) — normally irrelevant, since a UI already holds the candidates it fetched.

### The anchor: what the engine's own commits resolve to

Some keys make the engine commit by itself — space, `;`, the commit-and-jump when a key restarts from the root, and the literal-byte fallback. Those resolve against **`anchor_index`**: space and the fallbacks take `anchor_index`, `;` takes `anchor_index + 1`.

The anchor moves only when you call `jd_set_anchor`, or when a new composition starts (which resets it to 0). So the rule for a frontend is simply:

> Whenever you change which candidate the user sees first, call `jd_set_anchor` with its index.

A mobile IME that never paginates (the user taps a candidate) never has to call it at all. A desktop IME calls it once per page turn.

This is deliberately separate from the engine's internal enumeration cursor, which `jd_read_range` moves freely. Keeping them apart is what makes prefetching safe: an earlier version of this API had one cursor serving both roles, and a frontend that fetched ahead for its candidate strip would leave the engine parked on a page the user could not see, so the next space committed the wrong candidate.

### Reading a commit

A commit arrives as up to three pieces, concatenated in this order:

```
commit_a ++ commit_b ++ commit_lit
```

`commit_a` / `commit_b` are NUL-terminated strings; `commit_lit` is a single literal byte. Any may be absent — NULL for the pointers, 0 for the byte — and nothing was committed when all three are absent.

The split exists so the library never needs a buffer of its own: every commit it can produce is at most two dictionary strings plus one typed byte, so it can hand back pointers into its own read-only data instead of assembling anything. Join them however suits you:

```c
const jd_state *s = jd_state_ptr(ctx);
if (s->commit_a || s->commit_b || s->commit_lit) {
  char buf[/* jd_abi_layout(JD_ABI_MAX_COMMIT_LEN) */ 1024];
  size_t n = 0;
  if (s->commit_a) n += copy(buf + n, s->commit_a);
  if (s->commit_b) n += copy(buf + n, s->commit_b);
  if (s->commit_lit) buf[n++] = s->commit_lit;
  buf[n] = '\0';
}
```

`jd_abi_layout(JD_ABI_MAX_COMMIT_LEN)` gives the exact upper bound in bytes for the bundled dictionary, if you want a fixed buffer. Most callers just append into whatever string type their language uses; all four bindings expose a joined form.

### The four states

| State                     | commit_* | `options_count` |
|---------------------------|----------|-----------------|
| Candidates available      | absent   | > 0             |
| Committed                 | present  | 0               |
| Committed + drilled in    | present  | > 0             |
| Empty (no-op)             | absent   | 0               |

The third row happens when the user types a key that isn't a child of the current trie node but *is* a child of the root: the anchor candidate is committed *and* the user is now navigating fresh from the root with the just-pressed key.

### Pointer lifetimes

There is nothing to manage.

- **`query_option.value`** and the **commit segments** always point into the embedded dictionary blob — read-only data that lives for the whole process. They are valid forever.
- **`query_option.hint`** is inline bytes, owned by whatever owns the struct.
- **`jd_state_ptr`** returns an address that is valid for the context's whole lifetime. Read it once after `jd_init` and keep it. Its *contents* are replaced by the next `jd_press_key` / `jd_backspace` / `jd_reset` / `jd_set_anchor` on that context, but nothing reachable through it dangles.

So a candidate list can be retained indefinitely, sent to another thread, or held across any number of later engine calls, with no copying. The bindings take advantage of this: `bindings/rust` hands out `&'static str`, and the Swift binding materializes a `String` only when something asks to render one.

The one buffer you must not alias is `jd_scratch_ptr` — it's a convenience for hosts that can't hand the library memory of their own, and each `jd_read_range` into it overwrites the previous window. Pass your own buffer if you want to accumulate.

### Lifecycle contract

```
ctx = jd_init()  ──►  (jd_press_key | jd_backspace | jd_reset |
                       jd_set_anchor | jd_read_range)*  ──►  jd_deinit(ctx)
```

Each `jd_init` call returns an independent context owned by the caller. Contexts share the embedded trie (parsed lazily on the first call from any thread, then immutable for the rest of the process), but their query state is fully separate.

`jd_init` performs exactly one heap allocation (sized from caps embedded in the trie blob — the worst-case BFS frontier and path buffer) and `jd_deinit` performs exactly one matching free; nothing in between calls the allocator. Per-context resident memory for the bundled dictionary is around 235 KB.

### Thread-safety

| Pattern                                                    | Safe?                                |
|------------------------------------------------------------|--------------------------------------|
| Different contexts called from different threads           | Yes — tables are read-only after init. |
| A single context called from multiple threads concurrently | No — wrap calls in an external lock. |
| Multiple threads racing the very first `jd_init`           | Yes — the one-time init is atomic.   |
| Retaining candidates and reading them from another thread  | Yes — they point at immortal data.   |

The library uses `std.heap.smp_allocator` internally (thread-safe, pure Zig, no libc dependency) — except on WebAssembly, which uses `std.heap.wasm_allocator` (see [WebAssembly](#webassembly)).

### Checking your declarations

`jd.h` is hand-written, and some bindings (notably `bindings/rust`) declare the structs a second time. A silent drift between those declarations and the compiled library would corrupt memory, so the library reports its own layout:

```c
assert(jd_abi_layout(JD_ABI_SIZEOF_STATE)  == sizeof(jd_state));
assert(jd_abi_layout(JD_ABI_SIZEOF_OPTION) == sizeof(query_option));
assert(jd_abi_layout(JD_ABI_HINT_CAP)      == JD_HINT_CAP);
```

Every binding in this repo runs these once at init. Unknown queries return 0.

## WebAssembly

`zig build -Dtarget=wasm32-freestanding` produces a standalone reactor module at `zig-out/bin/jd.wasm` instead of the static/dynamic libraries. It has no `_start`, imports nothing (no WASI), and exports linear `memory` plus the `jd_*` C ABI — with no wasm-only additions. The engine swaps `smp_allocator` for `std.heap.wasm_allocator` (the former needs threads and an OS page allocator, neither of which `wasm32-freestanding` has); everything else — including the embedded dictionary — is identical to the native build.

Two details matter for a JS host:

- **State lives at a fixed address.** `jd_state_ptr(ctx)` is constant for the context's lifetime, so read it once and then read the fields straight out of `memory` after each call. On wasm32 `jd_state` is 20 bytes: two 4-byte pointers, one byte, three bytes of padding, then two u32s. `query_option` is 12 bytes: a 4-byte pointer then the 8-byte inline hint. Verify both with `jd_abi_layout` rather than trusting the arithmetic.
- **A JS host cannot allocate inside linear memory**, so it has no buffer to give `jd_read_range`. Use `jd_scratch_ptr(ctx)` as the `out` argument and decode larger windows in chunks; `jd_abi_layout(JD_ABI_SCRATCH_OPTIONS)` reports its capacity.

You rarely want to do that by hand. The **`bindings/javascript`** package wraps all of it behind an ergonomic JavaScript API (`JdModule` / `Engine`, with TypeScript types). Point it at the `jd.wasm` from `zig build` or the `libjd-<ver>-wasm.wasm.tar.xz` release asset.

## Key routing for IMEs

`libjd` is the input *engine*; an IME built on top of it is the *interaction layer*. They have a clean split of responsibilities:

- The **engine** owns text-input semantics — extending the trie, committing on terminators, generating candidates.
- The **IME** owns UX — when to consume a keystroke vs let it pass through, how to render the composition and candidate list, what gesture/key selects a candidate, and what a "page" is.

The table below is the recommended dispatch policy across all platforms. Following it keeps engine behavior identical on Windows / macOS / Linux / iOS / Android, and concentrates per-platform differences in a small number of IME-side decisions.

| Key class | Dispatch | API call |
|---|---|---|
| Modifier chords (Ctrl / Cmd / Alt / Win+anything) | IME | pass through to the host — these are host shortcuts (select-all, copy/paste, menu accelerators, system commands) |
| `a`–`z` | engine | `jd_press_key(byte)` — descends the trie / starts a composition |
| Punctuation (the keys mapped in `punctuation-marks/normal.txt` + `paired.txt`, plus `;`) | engine **or** IME — implementer's choice | **Delegate to the engine**: `jd_press_key(byte)` resolves the byte to a Chinese mark (auto-commit, paired-toggle, or a candidate window — see "Punctuation handling" below). **Or bypass the engine** and insert the mark in the IME yourself, replicating the engine's semantics: if a composition is in flight, commit the anchor candidate first, then append the mark; otherwise insert the mark directly. **Desktop IMEs usually delegate** (the hardware key already shows the ASCII glyph); **mobile IMEs usually bypass**, so the on-screen keyboard shows the Chinese marks directly and the user taps the exact one. Either way, dispatch the **actually-typed byte** (`Shift+/` → `?`, `Shift+1` → `!`). **`;` is a special case**: the engine routes it through its trie *symbol scheme* (`;`→`；`, `;;`→`：`, `;e`→`（`, … — opening a candidate window when not composing) rather than the punctuation tables, and reuses it as the built-in **2nd-candidate selector** while composing a trie code (it picks `anchor_index + 1`, not commit-then-append; on a *punctuation* candidate window it instead commits the window's anchor candidate and then opens its own symbol window). A delegating desktop IME gets both behaviors for free; a bypassing mobile IME usually omits the `;` key, since a candidate tap already selects the 2nd one. |
| Other printable ASCII (digits `0`-`9`, uppercase letters, other `Shift`/`Caps Lock`-modified bytes not in the punctuation tables …) | engine | `jd_press_key(byte)` — commits the current state and appends the byte literally, so `Shift+K` → `K` yields `…K`. |
| Space | engine | `jd_press_key(' ')` — engine commits the anchor candidate and appends nothing |
| Candidate-selector keys / gestures | IME (bindings up to the implementer) | commit the candidate's `value` yourself, then `jd_reset()` |
| Page-navigation keys / gestures | IME | compute the new window, `jd_read_range` it, and `jd_set_anchor` to its first index |
| Backspace | IME | `jd_backspace` plus shrink the IME's composition |
| Escape / Cancel | IME | `jd_reset` + tear down the composition without committing |
| Enter / Return | IME | commit the raw in-flight letters as-is — escape hatch for literal ASCII output; *do not* route to the engine |
| Home / End / Insert / Delete, arrows (if not bound to page nav) | IME | **consume while composing** — letting them through would move the host's caret out of the composition range |
| Function keys (F1-F12), modifiers (Ctrl/Shift/Alt/Win/Meta), media keys | IME | pass through to the host — not text input |

### Rationale

- **Why the engine handles all printable bytes (including space and punctuation)**: the engine's contract is "extend trie if the byte is a child of the current node; otherwise commit current state, then start fresh from root with the byte." Space is the one byte the engine treats as commit-only (it never appears in the appended commit string). Punctuation auto-commits *and* appends. Letting the engine own this means platform IMEs don't have to special-case any printable key.

- **Why modifier chords pass through**: `Ctrl`/`Cmd`/`Alt`/`Win`+anything are user shortcuts (select-all, save, menu accelerators, system commands). Routing them to the engine would feed `'a'` to the trie every time the user pressed Ctrl+A and break every editor convention. `Shift` and `Caps Lock` are *not* in this category — they don't pass through; they're the means by which the user types uppercase / shifted bytes that the engine receives. The IME translates the keypress via the platform's "VK + keyboard state → character" API (`ToUnicode` on Windows, `UCKeyTranslate` on macOS, etc.) so the engine sees `K` and `?` rather than `k` and `/`, and the engine's commit-and-append rule produces `你K` / `你?` naturally — no IME-side special case for "uppercase letter."

- **Why candidate selection is entirely the IME's job**: candidate values are immortal pointers into the dictionary blob, so an IME that has read a candidate can commit it directly and then call `jd_reset()`. There is no "pick candidate N" call, and no need for one. The engine has no opinion on *how* the user picks a candidate — only on *what* candidates exist.

- **Why paging is IME-side**: the engine exposes a flat candidate list; how many fit on screen, and whether the UI pages or scrolls, is a platform question. Read the window you want and tell the engine where the user is looking with `jd_set_anchor`.

- **Why Enter commits the raw letters, not via the engine**: it's the escape hatch for typing literal ASCII (URLs, code, English words) without engine conversion. The IME ends the composition with whatever text is currently displayed (the raw typed bytes), bypassing the engine's commit pipeline entirely. `jd_reset()` resets the engine state afterward.

- **Why arrow / nav keys are always consumed while composing**: the engine has no "cursor inside the composition" model — corrections are via `jd_backspace` only. If the IME let arrow keys reach the host, the host would move its caret out of the in-flight composition range, breaking the visual link between what the user is typing and where the text lands. Either bind arrows to page navigation (most natural — users expect ← to move "back" through pages) or no-op them, but never pass them through.

### Punctuation handling

The engine ships a build-time-generated punctuation table that maps selected ASCII bytes to Chinese equivalents. When `jd_press_key(byte)` finds a match, the engine handles it without any IME involvement:

- **Paired** (e.g. `"` → `“` / `”`): single-press commit; consecutive presses of the same key alternate halves. The toggle state is per-context, indexed by ASCII byte, and survives `jd_reset()` — it is cleared only by `jd_deinit`. Different paired keys (`"` vs `'` vs `(`) have independent toggles.
- **Normal, single candidate** (e.g. `.` → `。`): single-press commit, no window.
- **Normal, multiple candidates** (e.g. `[` → `「`/`【`/`〔`/`［`): opens a candidate window — `options_count` becomes non-zero and `jd_read_range` returns the marks. The IME renders and selects with its own bindings, exactly as for trie candidates. Do **not** route selector keys to the engine here: it treats `1`-`9` as literal input (`[` then `2` commits `「2`), and `;` does not pick a candidate on a punctuation window (it commits the anchor mark, then opens its own symbol window). `jd_press_key(' ')` commits the anchor mark.

Mixed-state behavior:

- If a trie composition is in flight (some letters typed) when a punctuation key is pressed, the engine commits the anchor candidate **and** the punctuation in one step (e.g. typing `n` then `.` yields a commit of `你。` — arriving as `commit_a` = `你`, `commit_b` = `。`).
- If a punctuation candidate window is open when the user presses a non-punctuation key, the engine commits the anchor mark and then processes the new key (e.g. `[` opens the bracket window, pressing `n` commits `「` and starts a fresh trie composition with `n`).
- `jd_backspace` while a punctuation candidate window is open closes the window without committing.

If a byte isn't in either punctuation table, the engine falls back to the trie behavior described in the dispatch table.

If the IME **delegates** punctuation to the engine, it doesn't have to do anything special — just route the actually-typed byte to `jd_press_key`. The full set of mapped keys is the union of the keys listed in `punctuation-marks/normal.txt` and `paired.txt`.

**Bypassing the engine (recommended for mobile IMEs).** Instead of routing punctuation to `jd_press_key`, a mobile IME typically shows the Chinese marks *directly* on the on-screen keyboard and inserts the tapped mark itself — the pressed key already *is* the mark, with no ASCII byte or table lookup involved. This is more intuitive on touch: the user sees and taps the exact mark, and paired marks (`“`/`”`, `‘`/`’`) become two separate keys rather than a press-toggle. To stay consistent with the delegating path, replicate the engine's commit-then-append rule:

- **Composing**: commit the anchor candidate, then `jd_reset(ctx)` and insert the mark. The simplest way to get the right text is to press space through the engine (`jd_press_key(' ')`) and use the commit it returns — that *is,* by definition, the anchor candidate.
- **Not composing**: insert the mark directly.

In this mode the engine's punctuation table goes unused; the engine still owns the trie and the candidate list.

### Putting it together

A minimal IME key handler starts by picking its own candidate-selector and page-navigation bindings, and deciding whether it handles punctuation itself (bypassing the engine) or delegates it. The selector / page bindings are claimed only while composing; punctuation, if the IME owns it, is claimed whether or not a composition is in flight. These choices are platform-specific:

```text
# A desktop IME binds keys and lets the engine convert punctuation:
page_size             = 9             # candidates drawn per panel page
candidate_selectors   = '1'..'9'      # press N to pick the Nth visible candidate
page_prev / page_next = PgUp / PgDn   # (or ←/→, or '-'/'=')
handles_punctuation   = false         # route punctuation bytes to the engine

# A mobile IME selects by tap and scrolls its candidate strip, so it binds NO
# keys, and owns punctuation so it can show the Chinese marks directly:
page_size             = (a scrolling strip, fetched 16 at a time)
candidate_selectors   = {}            # '1'-'9' are not selectors here
page_prev / page_next = (gestures)    # not keys at all
handles_punctuation   = true          # insert the tapped Chinese mark directly
```

The handler keeps two pieces of its own state: `window_start` (the flat index the visible candidates begin at) and the candidates it last read.

```text
show_window(ctx, start):
    window_start = start
    visible      = jd_read_range(ctx, start, page_size)
    jd_set_anchor(ctx, start)     # the engine's own commits follow the user's eyes
    redraw(visible)

on_key_down(key, ctx):
    if ctrl / cmd / alt / win held: pass through to host

    byte = translate_to_ascii(key, current keyboard state)
              # shift/caps-aware; e.g. Shift+/ → '?', Shift+K → 'K'

    if composing:
        # IME-owned keys, intercepted before the engine. They only matter
        # while a composition / candidate window is live.
        match key:
            backspace      → jd_backspace(ctx); shrink composition; show_window(ctx, 0); done
            escape         → jd_reset(ctx); end composition; hide candidates; done
            enter          → commit raw composition text; jd_reset(ctx); hide candidates; done
            page_next      → if window_start + page_size < options_count:
                                 show_window(ctx, window_start + page_size)
                             done
            page_prev      → show_window(ctx, max(0, window_start - page_size)); done
            a candidate_selector for slot N:
                if visible[N] exists → commit visible[N].value; jd_reset(ctx); hide; done
                else → fall through to the engine (treat the key as a literal byte)
            other nav (home/end/etc.) → consume but no-op (engine has no cursor); done
            handles_punctuation and the key is a punctuation key:
                # IME owns punctuation (typical on mobile, where the on-screen key
                # already IS the Chinese mark). Flush the in-flight candidate the
                # way the engine would, then insert the mark:
                jd_press_key(ctx, ' '); insert the commit; jd_reset(ctx); hide candidates
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
        jd_press_key(ctx, byte)
        state = jd_state_ptr(ctx)
        if state has a commit: insert it (ending the composition if one was active)
        if state.options_count > 0: start / extend composition; show_window(ctx, 0)
        if neither: don't consume (let the host see the key)
    else:
        pass through to host  # control chars, non-ASCII, function/media keys
```

The `page_size`, candidate-selector and page-nav lines are where the per-platform bindings live; everything else is identical across platforms. Two consequences worth restating:

- A bound candidate selector or page-nav key is consumed *before* the engine and never reaches `jd_press_key`. So a desktop IME's `1`-`9` pick candidates while composing, whereas a mobile IME (which binds no selector keys) sends `1`-`9` straight to the engine as literal digits.
- The engine dispatch is reached whether or not a composition is active — so a bare `.` commits `。` exactly as `n` then `.` commits `你。`, whether the engine resolves the punctuation or the IME does it itself. The keys that bypass the engine dispatch are the modifier chords, the IME-owned selector / page / nav keys (only while composing), and — when `handles_punctuation` is on — punctuation keys.

## Allocator

Native builds use `std.heap.smp_allocator` (WebAssembly uses `std.heap.wasm_allocator` instead — see [WebAssembly](#webassembly)) — pure Zig, no libc dependency — and only ever touch it twice per context: one `alignedAlloc` inside `jd_init`, one matching `free` inside `jd_deinit`. Everything else (the BFS enumeration state, the anchor cache, the state block, the read scratch) lives in fixed-size regions of the per-context allocation, carved at init time or inlined in the context struct.

Because there is no runtime allocator traffic, there is no per-context leak detection to enable in Debug builds — leaks would only ever come from a misuse of `jd_init` / `jd_deinit` on the caller's side, which any standard heap-checker (Valgrind, AddressSanitizer, etc.) will surface against the one alloc/free pair.
