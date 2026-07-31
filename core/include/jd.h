#ifndef JD_H
#define JD_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Inline hint capacity, including the NUL terminator. A hint is the key
 * sequence still needed below the candidate's node, bounded by the
 * dictionary's max key length minus one. The library hard-errors at build
 * time if that bound ever outgrows this array.
 */
#define JD_HINT_CAP 8

/**
 * One candidate.
 *
 * Both fields are safe to keep indefinitely. `value` always points into the
 * library's embedded dictionary blob — read-only data that lives for the
 * whole process — and `hint` is inline bytes owned by whoever owns this
 * struct. There is no invalidation rule and nothing to copy defensively.
 *
 * `hint[0] == 0` means the candidate needs no further keys.
 */
typedef struct {
  const char *value;
  char hint[JD_HINT_CAP];
} query_option;

/**
 * The result of the last operation on a context.
 *
 * A commit is delivered as up to three pieces, concatenated in this order:
 *
 *   commit_a ++ commit_b ++ commit_lit
 *
 * `commit_a` / `commit_b` are NUL-terminated pointers into the embedded blob
 * (immortal, exactly like `query_option.value`); `commit_lit` is a single
 * literal byte. Any of them may be absent — NULL for the pointers, 0 for the
 * byte. Nothing was committed when all three are absent. Splitting the
 * commit this way is what lets the library return it without owning a buffer,
 * so every pointer a caller ever receives is immortal.
 *
 * `options_count` is the total number of candidates for the in-flight
 * composition, or 0 when none is in flight. Read them with jd_read_range.
 *
 * `anchor_index` is the 0-based candidate index the engine's own automatic
 * commits resolve against — space and the literal-byte fallbacks take
 * `anchor_index`, `;` takes `anchor_index + 1`. It moves only when you call
 * jd_set_anchor or when a new composition starts; reading candidates never
 * moves it.
 *
 * The four states a result can encode:
 *
 *   | state                    | commit_* | options_count |
 *   |--------------------------|----------|---------------|
 *   | candidates available     | absent   | > 0           |
 *   | committed                | present  | 0             |
 *   | committed + drilled in   | present  | > 0           |
 *   | empty (no-op)            | absent   | 0             |
 */
typedef struct {
  const char *commit_a, *commit_b;
  char commit_lit;
  unsigned int options_count, anchor_index;
} jd_state;

/**
 * Opaque per-instance context handle. Create with jd_init, destroy with
 * jd_deinit. Multiple contexts may exist simultaneously; the embedded trie
 * and punctuation tables are parsed once on first use and shared read-only
 * across all of them.
 *
 * Thread-safety: contexts are independent — different threads operating on
 * different contexts is safe. A single context must not be used concurrently
 * from multiple threads; serialize calls with an external mutex if you need
 * that.
 */
typedef struct jd_context jd_context;

/**
 * Create a new context. Returns NULL on allocation failure. Each returned
 * handle is owned by the caller and must be released with jd_deinit.
 *
 * Exactly one heap allocation happens here and exactly one matching free
 * happens in jd_deinit; nothing in between touches an allocator.
 */
jd_context *jd_init(void);

/**
 * Release all memory held by ctx. After this call ctx is invalid. The shared
 * trie and punctuation tables remain alive for the rest of the process;
 * other contexts are unaffected.
 */
void jd_deinit(jd_context *ctx);

/**
 * Feed one keystroke to the engine. `key` is interpreted as a literal ASCII
 * byte; the engine resolves it in this order:
 *   1. Space commits the candidate at `anchor_index` (or a bare " " when
 *      nothing is in flight); `;` commits `anchor_index + 1` on a trie
 *      composition. Digits are literal input — numeric candidate-selector
 *      bindings (`1`-`9` and the like) are the IME's responsibility, see
 *      docs/integration.md.
 *   2. The punctuation tables — paired entries auto-commit with toggle,
 *      single-candidate normals auto-commit, multi-candidate normals open a
 *      candidate window.
 *   3. The trie — descend, or commit-and-jump when the key is a child of
 *      the root but not of the current node.
 *   4. Fallback — commit the anchor candidate with the key byte appended.
 *
 * Read the outcome with jd_state_ptr.
 */
void jd_press_key(jd_context *ctx, char key);

/**
 * Undo the most recent trie descent, re-deriving the candidate list, and
 * park the anchor back at the start of the shorter code. Closes a
 * punctuation candidate window without committing. Does nothing when there
 * is no descent to undo. Never produces a commit.
 */
void jd_backspace(jd_context *ctx);

/**
 * Drop the in-flight composition and any recorded commit, without
 * committing. The context stays alive and usable. The per-context
 * paired-punctuation toggle state is NOT cleared by this call — only
 * jd_deinit clears it.
 */
void jd_reset(jd_context *ctx);

/**
 * Point the anchor at candidate `index` (0-based) — call this when the user
 * navigates, so the engine's automatic commits follow what's on screen.
 * Out-of-range requests are silently ignored, so any value is safe to pass.
 */
void jd_set_anchor(jd_context *ctx, unsigned int index);

/**
 * Address of the context's state block. Stable for the context's whole
 * lifetime: read it once after jd_init and keep it. The contents are
 * replaced by the next jd_press_key / jd_backspace / jd_reset /
 * jd_set_anchor on the same context, but the pointer itself never dangles
 * and nothing reachable through it does either.
 */
const jd_state *jd_state_ptr(jd_context *ctx);

/**
 * Copy the candidates at indices [start, start + count) into `out`, which
 * must have room for `out_cap` entries. Returns how many were written —
 * clipped by both `out_cap` and the total candidate count, so a short
 * buffer or an out-of-range window is not an error, just a smaller result.
 *
 * This is a pure read: it never moves `anchor_index` and never invalidates
 * anything previously returned. Fetch as far ahead as you like — building an
 * append-only candidate strip needs no bookkeeping beyond remembering how
 * far you got.
 *
 * Cost: reading forward is amortized O(1) per candidate, so walking the
 * whole list in windows costs one pass. Jumping backwards re-walks from the
 * start, O(start + count) — normally irrelevant, since a UI already holds
 * the candidates it fetched.
 */
unsigned int jd_read_range(jd_context *ctx, unsigned int start,
                           unsigned int count, query_option *out,
                           unsigned int out_cap);

/**
 * A `JD_ABI_SCRATCH_OPTIONS`-entry buffer owned by the context, usable as
 * jd_read_range's `out`. It exists for hosts that cannot hand the library
 * memory of their own — notably a WebAssembly host, which has no allocator
 * inside linear memory. Native callers normally pass their own buffer and
 * accumulate with no intermediate copies. The pointer is stable for the
 * context's lifetime; the contents are yours until the next jd_read_range.
 */
query_option *jd_scratch_ptr(jd_context *ctx);

/* Queries for jd_abi_layout. */
#define JD_ABI_SIZEOF_STATE 0
#define JD_ABI_SIZEOF_OPTION 1
#define JD_ABI_HINT_CAP 2
#define JD_ABI_SCRATCH_OPTIONS 3
#define JD_ABI_MAX_COMMIT_LEN 4

/**
 * Layout self-check. This header and the language bindings declare these
 * structs by hand, so either can drift from the compiled library with no
 * diagnostic. Compare the values against your own sizeof/constants once at
 * startup; a mismatch means the declarations are out of sync and memory
 * would be corrupted.
 *
 * JD_ABI_MAX_COMMIT_LEN is the upper bound on a joined commit in bytes
 * (excluding a NUL) — size a buffer with it if you concatenate the segments
 * into fixed storage. Unknown queries return 0.
 */
unsigned int jd_abi_layout(unsigned int what);

#ifdef __cplusplus
}
#endif

#endif /* JD_H */
