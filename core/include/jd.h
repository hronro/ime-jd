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
 * is parsed once on first use and shared read-only across all of them.
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

query_result jd_press_key(jd_context *ctx, char key);
query_result jd_next_page(jd_context *ctx);
query_result jd_prev_page(jd_context *ctx);
query_result jd_backspace(jd_context *ctx);
void         jd_reset(jd_context *ctx);

/**
 * Release all memory held by ctx. After this call ctx is invalid; do not
 * use it for any other jd_* function. The shared trie remains alive for the
 * rest of the process; other contexts are unaffected.
 */
void jd_deinit(jd_context *ctx);

#ifdef __cplusplus
}
#endif

#endif /* JD_H */
