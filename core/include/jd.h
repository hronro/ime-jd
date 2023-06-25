typedef struct {
  const char *value, *hint;
} query_option;

typedef struct {
  const char *commit;
  const query_option *options;
  const unsigned int options_count, total_pages, current_page;
} query_result;

void jd_init(unsigned char page_size);
const query_result jd_press_key(char key);
const query_result jd_next_page();
const query_result jd_prev_page();
const query_result jd_backspace();
void jd_reset();
void jd_deinit();
