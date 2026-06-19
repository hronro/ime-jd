#ifndef JD_H
#define JD_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const char *value, *hint;
} query_option;

typedef struct {
  const char *commit;
  const query_option *options;
  unsigned int options_count, total_pages, current_page;
} query_result;

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
 * Create a new context with the given page size. Returns NULL on allocation
 * failure. Each returned handle is owned by the caller and must be released
 * with jd_deinit.
 */
jd_context *jd_init(unsigned char page_size);

/**
 * Feed one keystroke to the engine. `key` is interpreted as a literal ASCII
 * byte; the engine resolves it in this order:
 *   1. If a candidate page is on screen, special keys pick from it (space
 *      commits option 0; `;` picks option 1 when not part of an active
 *      trie code). Numeric candidate-selector bindings (`1`-`9` and the
 *      like) are the IME's responsibility — see docs/integration.md.
 *   2. The punctuation tables — paired entries auto-commit with toggle,
 *      single-candidate normals auto-commit, multi-candidate normals open a
 *      paginated candidate window. See docs/integration.md.
 *   3. The trie — descend, or commit-and-jump when the key is a child of
 *      the root but not of the current node.
 *   4. Fallback — commit the in-flight first candidate (if any) with the
 *      key byte appended.
 *
 * The returned result encodes one of: candidates available, committed,
 * committed-and-drilled-in (both `commit` and `options` non-NULL), or empty.
 * Returned pointers are borrowed and only valid until the next jd_* call on
 * the same context — see docs/integration.md for the full result-field
 * semantics and pointer-lifetime contract.
 */
query_result jd_press_key(jd_context *ctx, char key);

/**
 * Advance the active candidate paginator (trie or punctuation candidate
 * window) by one page. No-op at the last page. Returns an empty result if
 * no composition is in flight.
 */
query_result jd_next_page(jd_context *ctx);

/**
 * Step the active candidate paginator back by one page. No-op at the first
 * page. Returns an empty result if no composition is in flight.
 */
query_result jd_prev_page(jd_context *ctx);

/**
 * Set the paginator's current page directly. `page` is 1-based. Out-of-range
 * requests (0, or larger than `total_pages`) are silently ignored, matching
 * the behavior of jd_next_page / jd_prev_page at boundaries.
 *
 * Returns the materialized options for the resulting current page, or an
 * empty result if no composition is in flight.
 */
query_result jd_jump_to_page(jd_context *ctx, unsigned int page);

/**
 * Undo the most recent trie descent: shrinks the in-flight key history by
 * one and re-materializes the previous candidate page. Returns an empty
 * result when there is no descent to undo — either because the cursor is
 * already at the root, or because the in-flight composition is a
 * punctuation candidate window (which has no trie descent state; the
 * window is simply closed). Has no effect when nothing is in flight.
 */
query_result jd_backspace(jd_context *ctx);

/**
 * Drop the in-flight composition (trie cursor, pressed-key history,
 * pagination state) without committing. The context remains alive and
 * usable. The per-context paired-punctuation toggle state is NOT cleared
 * by this call — only jd_deinit clears it.
 */
void jd_reset(jd_context *ctx);

/**
 * Release all memory held by ctx. After this call ctx is invalid; do not
 * use it for any other jd_* function. The shared trie and punctuation
 * tables remain alive for the rest of the process; other contexts are
 * unaffected.
 */
void jd_deinit(jd_context *ctx);

#ifdef __cplusplus
}
#endif

#endif /* JD_H */
