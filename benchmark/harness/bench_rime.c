// librime driver, mirroring what Squirrel does per keystroke: process_key, then
// get_commit / get_status / get_context and read the menu page.
//
// env: RIME_SHARED, RIME_USER (the deployed scheme), RIME_LOG (log dir),
//      RIME_FULL_CHECK=1 (start_maintenance(True)), RIME_OPTS="opt=0,opt2=1"
#include "common.h"
#include "rime_api.h"

static RimeApi *api;
static RimeSessionId sess;
static RimeTraits traits;

static void set_opts(RimeSessionId s) {
  const char *o = getenv("RIME_OPTS");
  if (!o || !*o) return;
  char buf[256];
  snprintf(buf, sizeof buf, "%s", o);
  for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
    char *eq = strchr(tok, '=');
    if (!eq) continue;
    *eq = 0;
    api->set_option(s, tok, atoi(eq + 1) ? True : False);
  }
}

static void eng_startup(double *ph, int *n, const char **names) {
  api = rime_get_api();
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = getenv("RIME_SHARED");
  traits.user_data_dir = getenv("RIME_USER");
  traits.distribution_name = "bench";
  traits.distribution_code_name = "bench";
  traits.distribution_version = "1";
  traits.app_name = "rime.bench";
  traits.min_log_level = 1;
  traits.log_dir = getenv("RIME_LOG") ? getenv("RIME_LOG") : "";
  uint64_t t0 = now_ns();
  api->setup(&traits);
  uint64_t t1 = now_ns();
  api->initialize(&traits);
  uint64_t t2 = now_ns();
  const char *fc = getenv("RIME_FULL_CHECK");
  if (api->start_maintenance(fc && *fc == '1')) api->join_maintenance_thread();
  uint64_t t3 = now_ns();
  sess = api->create_session();
  uint64_t t4 = now_ns();
  char cur[64] = {0};
  api->get_current_schema(sess, cur, sizeof cur);
  if (strcmp(cur, "keytao")) api->select_schema(sess, "keytao");  // the scheme's schema id
  set_opts(sess);
  uint64_t t5 = now_ns();
  api->get_current_schema(sess, cur, sizeof cur);
  if (strcmp(cur, "keytao")) { fprintf(stderr, "schema is '%s', not keytao\n", cur); exit(2); }
  names[0] = "setup", ph[0] = (double)(t1 - t0);
  names[1] = "initialize", ph[1] = (double)(t2 - t1);
  names[2] = "maintenance", ph[2] = (double)(t3 - t2);
  names[3] = "create_session", ph[3] = (double)(t4 - t3);
  names[4] = "select_schema", ph[4] = (double)(t5 - t4);
  *n = 5;
}

static void eng_event(uint8_t b) {
  int code = (b >= 1 && b <= PAGE) ? '0' + b : b;  // digit keys select on the page
  api->process_key(sess, code, 0);
}

static int checked_page;
static void eng_collect(void) {
  RIME_STRUCT(RimeCommit, commit);
  if (api->get_commit(sess, &commit)) {
    if (commit.text) out_append(commit.text, strlen(commit.text));
    api->free_commit(&commit);
  }
  RIME_STRUCT(RimeStatus, status);
  if (api->get_status(sess, &status)) {
    sink += status.is_composing;
    api->free_status(&status);
  }
  RIME_STRUCT(RimeContext, ctx);
  if (api->get_context(sess, &ctx)) {
    uint64_t s = ctx.composition.preedit ? (uint8_t)ctx.composition.preedit[0] : 0;
    for (int i = 0; i < ctx.menu.num_candidates; i++) {
      s += (uint8_t)ctx.menu.candidates[i].text[0];
      if (ctx.menu.candidates[i].comment) s += (uint8_t)ctx.menu.candidates[i].comment[0];
    }
    if (!checked_page && ctx.menu.num_candidates) {
      checked_page = 1;
      if (ctx.menu.page_size != PAGE) {
        fprintf(stderr, "rime page_size %d != %d\n", ctx.menu.page_size, PAGE);
        exit(2);
      }
    }
    sink += s;
    api->free_context(&ctx);
  }
}

// userdict DICT BASE REPS CODE VALUE: the scheme's user dictionary is a
// *.dict.yaml compiled into its dictionaries, so an edit takes effect through
// 重新部署 -- what Squirrel's deploy() does: finalize, initialize(nil),
// start_maintenance(full check) -- and a new session; then type the phrase.
static int eng_userdict(int argc, char **argv) {
  if (argc < 7) { fprintf(stderr, "userdict needs DICT BASE REPS CODE VALUE\n"); return 2; }
  const char *path = argv[2], *code = argv[5], *value = argv[6];
  int reps = atoi(argv[4]);
  if (reps < 1 || reps > UD_MAX_REPS) reps = UD_MAX_REPS;
  size_t nbase;
  uint8_t *base = slurp(argv[3], &nbase);
  double fin[UD_MAX_REPS], ini[UD_MAX_REPS], dep[UD_MAX_REPS], ses[UD_MAX_REPS], tot[UD_MAX_REPS], use[UD_MAX_REPS];
  int ok = 1;
  for (int r = 0; r < reps; r++) {
    ud_edit(path, base, nbase, code, value, r);
    uint64_t t0 = now_ns();
    api->destroy_session(sess);
    api->finalize();
    uint64_t t1 = now_ns();
    api->initialize(NULL);
    uint64_t t2 = now_ns();
    if (api->start_maintenance(True)) api->join_maintenance_thread();
    uint64_t t3 = now_ns();
    sess = api->create_session();
    char cur[64] = {0};
    api->get_current_schema(sess, cur, sizeof cur);
    if (strcmp(cur, "keytao")) api->select_schema(sess, "keytao");  // the scheme's schema id
    set_opts(sess);
    uint64_t t4 = now_ns();
    ok &= ud_probe(code);
    uint64_t t5 = now_ns();
    fin[r] = (double)(t1 - t0), ini[r] = (double)(t2 - t1), dep[r] = (double)(t3 - t2);
    ses[r] = (double)(t4 - t3), tot[r] = (double)(t4 - t0), use[r] = (double)(t5 - t4);
  }
  printf("  \"userdict\": {\n    \"reps\": %d, \"ok\": %s,\n", reps, ok ? "true" : "false");
  phase_json("finalize", fin, reps, 0);
  phase_json("initialize", ini, reps, 0);
  phase_json("deploy", dep, reps, 0);
  phase_json("create_session", ses, reps, 0);
  phase_json("apply_total", tot, reps, 0);
  phase_json("first_use", use, reps, 1);
  printf("  },\n  \"max_rss\": %llu\n}\n", (unsigned long long)max_rss());
  return ok ? 0 : 1;
}

static void eng_reset(void) { api->clear_composition(sess); }
static void *eng_new_session(void) {
  RimeSessionId s = api->create_session();
  set_opts(s);
  return (void *)s;
}
static void eng_free_session(void *s) { api->destroy_session((RimeSessionId)s); }
static const char *ENGINE = "librime";
