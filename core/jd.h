typedef struct {
  char *value, hint;
} query_option;

typedef struct {
  char *commit;
  query_option *options;
  unsigned int options_count, total_pages, current_page;
} query_result;

void jd_init(unsigned char page_size);
query_result jd_press_key(char key);
query_result jd_next_page();
query_result jd_prev_page();
query_result jd_backspace();
void jd_reset();
void jd_deinit();
