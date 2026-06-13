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

void          jd_init(unsigned char page_size);
query_result  jd_press_key(char key);
query_result  jd_next_page(void);
query_result  jd_prev_page(void);
query_result  jd_backspace(void);
void          jd_reset(void);
void          jd_deinit(void);
```

The header is C89-compatible and includes an `extern "C"` block for C++ consumers.

### Function semantics

| Function                | Effect                                                                |
|-------------------------|-----------------------------------------------------------------------|
| `jd_init(page_size)`    | One-time setup. Parses the embedded blob, allocates the global state. |
| `jd_press_key(key)`     | Feed one keystroke. Returns either a committed string or a page.      |
| `jd_next_page()`        | Move to next page of the current candidate list, if any.              |
| `jd_prev_page()`        | Move to previous page, if any.                                        |
| `jd_backspace()`        | Undo the most recent letter keypress; recompute candidates.           |
| `jd_reset()`            | Drop the in-flight query but keep the library initialized.            |
| `jd_deinit()`           | Tear down all state. After this, only `jd_init` is callable.          |

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

Every pointer in a returned `query_result` is **borrowed**. Lifetimes:

- **`commit`** is allocated in a per-keypress arena and is valid only until the next call to `jd_press_key`, `jd_next_page`, `jd_prev_page`, `jd_backspace`, `jd_reset`, or `jd_deinit`. Copy it out before making any further call if you need it longer.
- **`options` and each `option.value` / `option.hint`** are valid only until the next state-changing call (same list as above). Specifically, `option.value` points into the embedded blob (effectively static), but `option.hint` is allocated in the paginator's per-page arena and is invalidated when the user navigates to another page.

Treat the rule simply as: **don't hold any pointer returned by the library across the next library call.**

### Lifecycle contract

```
jd_init  ──►  (jd_press_key | jd_next_page | jd_prev_page |
              jd_backspace  | jd_reset)*       ──►  jd_deinit
```

Calling `jd_init` while a context is already initialized leaks the previous context's memory. Always call `jd_deinit` between successive inits. (The library doesn't enforce this — it's a caller contract, documented in `jd.h`.)

The library is **not** thread-safe. All state is global; concurrent calls from multiple threads will corrupt it. Either funnel calls through one thread, or wrap calls in an external mutex.

## Debug builds

A `Debug` build of `libjd` uses Zig's `DebugAllocator`, which detects leaks at `jd_deinit` time. If you suspect a leak, build the core with `zig build` (no `-Doptimize=`) and look at stderr after teardown.

`Release` builds use `std.heap.smp_allocator` — pure Zig, thread-safe, no libc dependency. That keeps the library zero-dep for distribution.
