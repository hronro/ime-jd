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
 * Initialize the library with the given page size.
 *
 * Must be called before any other jd_* function. If called more than once,
 * the caller is responsible for invoking jd_deinit() before each subsequent
 * jd_init() — otherwise the previous context's memory leaks.
 */
void jd_init(unsigned char page_size);

query_result jd_press_key(char key);
query_result jd_next_page(void);
query_result jd_prev_page(void);
query_result jd_backspace(void);
void jd_reset(void);

/**
 * Tear down the library and release all memory held by the current context.
 * After this call, jd_init() must be invoked again before any other jd_*
 * function is used.
 */
void jd_deinit(void);

#ifdef __cplusplus
}
#endif

#endif /* JD_H */
