// libjd driver: what a front end does per keystroke -- press the key, take the
// commit, and read the first page of candidates.
#include "common.h"
#include "jd.h"

static jd_context *ctx;
static const jd_state *st;
static query_option page[PAGE];

static void eng_startup(double *ph, int *n, const char **names) {
  uint64_t t0 = now_ns();
  ctx = jd_init(NULL, 0);
  uint64_t t1 = now_ns();
  if (!ctx) { fprintf(stderr, "jd_init failed\n"); exit(2); }
  st = jd_state_ptr(ctx);
  names[0] = "jd_init";
  ph[0] = (double)(t1 - t0);
  *n = 1;
}

static void eng_event(uint8_t b) {
  if (b >= 1 && b <= PAGE) {  // pick candidate b-1 on the page, like a digit key in the UI
    jd_set_anchor(ctx, b - 1);
    jd_press_key(ctx, ' ');
  } else {
    jd_press_key(ctx, (char)b);
  }
}

static void eng_collect(void) {
  if (st->commit_a) out_append(st->commit_a, strlen(st->commit_a));
  if (st->commit_b) out_append(st->commit_b, strlen(st->commit_b));
  if (st->commit_lit) out_append(&st->commit_lit, 1);
  if (st->options_count) {
    unsigned k = jd_read_range(ctx, 0, PAGE, page, PAGE);
    uint64_t s = 0;
    for (unsigned i = 0; i < k; i++) s += (uint8_t)page[i].value[0] + (uint8_t)page[i].hint[0];
    sink += s;
  }
}

// userdict DICT BASE REPS CODE VALUE: what a host does when the user saves
// their phrases -- read the file, jd_user_dict_build into a buffer, jd_init on
// the blob, release the old context -- then type the new phrase. Afterwards,
// what each later start costs with that blob cached: check + jd_init.
static int eng_userdict(int argc, char **argv) {
  if (argc < 7) { fprintf(stderr, "userdict needs DICT BASE REPS CODE VALUE\n"); return 2; }
  const char *path = argv[2], *code = argv[5], *value = argv[6];
  int reps = atoi(argv[4]);
  if (reps < 1 || reps > UD_MAX_REPS) reps = UD_MAX_REPS;
  size_t nbase;
  uint8_t *base = slurp(argv[3], &nbase);
  double rd[UD_MAX_REPS], bd[UD_MAX_REPS], in[UD_MAX_REPS], rel[UD_MAX_REPS], tot[UD_MAX_REPS], use[UD_MAX_REPS];
  void *buf = NULL;
  size_t cap = 0, blob_len = 0, text_len = 0;
  jd_user_dict_report rep = {0};
  int ok = 1;
  for (int r = 0; r < reps; r++) {
    ud_edit(path, base, nbase, code, value, r);
    uint64_t t0 = now_ns();
    uint8_t *text = slurp(path, &text_len);
    uint64_t t1 = now_ns();
    size_t c = (jd_user_dict_blob_bound((const char *)text, text_len) + 15) & ~(size_t)15;
    void *nb = aligned_alloc(16, c);
    if (!nb || jd_user_dict_build((const char *)text, text_len, (unsigned long long)r, nb, c, &blob_len, &rep) != JD_USER_DICT_OK) {
      fprintf(stderr, "jd_user_dict_build failed: status %u line %u\n", rep.status, rep.line);
      exit(2);
    }
    free(text);
    uint64_t t2 = now_ns();
    jd_context *nc = jd_init(nb, blob_len);
    if (!nc) { fprintf(stderr, "jd_init rejected the blob\n"); exit(2); }
    uint64_t t3 = now_ns();
    jd_deinit(ctx);
    free(buf);
    ctx = nc;
    st = jd_state_ptr(ctx);
    buf = nb;
    cap = c;
    uint64_t t4 = now_ns();
    ok &= ud_probe(code);
    uint64_t t5 = now_ns();
    rd[r] = (double)(t1 - t0), bd[r] = (double)(t2 - t1), in[r] = (double)(t3 - t2);
    rel[r] = (double)(t4 - t3), tot[r] = (double)(t4 - t0), use[r] = (double)(t5 - t4);
  }
  double ck[UD_MAX_REPS], ci[UD_MAX_REPS];
  for (int r = 0; r < reps; r++) {
    jd_user_dict_info info;
    uint64_t t0 = now_ns();
    unsigned s = jd_user_dict_check(buf, blob_len, &info);
    uint64_t t1 = now_ns();
    jd_context *c2 = jd_init(buf, blob_len);
    uint64_t t2 = now_ns();
    if (s != JD_USER_DICT_OK || !c2) { fprintf(stderr, "cached blob rejected\n"); exit(2); }
    jd_deinit(c2);
    ck[r] = (double)(t1 - t0), ci[r] = (double)(t2 - t1);
  }
  printf("  \"userdict\": {\n    \"reps\": %d, \"ok\": %s, \"entries\": %u, \"dropped\": %u, \"shared\": %u, \"invalid\": %u,\n"
         "    \"text_bytes\": %zu, \"blob_bytes\": %zu, \"buffer_bytes\": %zu,\n",
         reps, ok ? "true" : "false", rep.entries, rep.dropped, rep.shared, rep.invalid, text_len, blob_len, cap);
  phase_json("read_file", rd, reps, 0);
  phase_json("build", bd, reps, 0);
  phase_json("init", in, reps, 0);
  phase_json("release_old", rel, reps, 0);
  phase_json("apply_total", tot, reps, 0);
  phase_json("first_use", use, reps, 0);
  phase_json("cached_check", ck, reps, 0);
  phase_json("cached_init", ci, reps, 1);
  printf("  },\n  \"max_rss\": %llu\n}\n", (unsigned long long)max_rss());
  return ok ? 0 : 1;
}

static void eng_reset(void) { jd_reset(ctx); }
static void *eng_new_session(void) { return jd_init(NULL, 0); }
static void eng_free_session(void *s) { jd_deinit(s); }
static const char *ENGINE = "libjd";
