// Shared harness for bench_jd.c / bench_rime.c (macOS only: mach task_info,
// malloc zones, CLOCK_UPTIME_RAW). Each engine file defines:
//   static void eng_startup(double *phase_ns, int *nphase, const char **names)
//   static void eng_event(uint8_t b)      -- feed one stream event (no reads)
//   static void eng_collect(void)         -- read commit (append to out) + first page
//   static void eng_reset(void)
//   static void *eng_new_session(void) / eng_free_session(void *)
// and includes this file, whose main() prints one JSON object:
//   bench_X startup                     init, first key, first commit, memory
//   bench_X sessions N                  N more sessions: create time, memory
//   bench_X stream KEYS EXPECT CATS TPUT LAT [LIMIT]
//       pass 0 replays the stream and checks the committed text against
//       EXPECT; then TPUT untimed passes (engine only, then with reads) and
//       LAT passes with per-event timestamps. LIMIT replays only the first
//       LIMIT events and checks the output as a prefix of EXPECT.
//   bench_X userdict DICT BASE REPS CODE VALUE
//       REPS times: write BASE plus the line "VALUE<rep>\tCODE" to DICT (the
//       user's edit, untimed), apply it the engine's way, then type CODE +
//       space, which must commit VALUE<rep>.
// Allocation counts appear when allocc.dylib is DYLD_INSERT_LIBRARIES'd.
#pragma once
#include <dlfcn.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#define PAGE 6

static inline uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static uint64_t footprint(void) {
  task_vm_info_data_t vm;
  mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &c) != KERN_SUCCESS) return 0;
  return vm.phys_footprint;
}
static uint64_t resident(void) {
  task_vm_info_data_t vm;
  mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &c) != KERN_SUCCESS) return 0;
  return vm.resident_size;
}
static uint64_t heap_in_use(void) {
  malloc_statistics_t st;
  malloc_zone_statistics(NULL, &st);
  return st.size_in_use;
}
static uint64_t max_rss(void) {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return (uint64_t)ru.ru_maxrss;  // bytes on macOS
}

// Allocation counters from allocc.dylib when it is DYLD_INSERT_LIBRARIES'd.
typedef struct { uint64_t mallocs, frees, reallocs, bytes; } allocc_t;
static void (*allocc_get)(allocc_t *);
static allocc_t allocs(void) {
  allocc_t a = {0};
  if (allocc_get) allocc_get(&a);
  return a;
}

// ---- output buffer ----
static char *out_buf;
static size_t out_len, out_cap;
static void out_append(const char *s, size_t n) {
  if (out_len + n > out_cap) {
    out_cap = (out_len + n) * 2 + 4096;
    out_buf = (char *)realloc(out_buf, out_cap);
  }
  memcpy(out_buf + out_len, s, n);
  out_len += n;
}
static volatile uint64_t sink;  // candidate bytes touched, keeps reads alive

static uint8_t *slurp(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(2); }
  fseek(f, 0, SEEK_END);
  *len = (size_t)ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *b = (uint8_t *)malloc(*len + 1);
  if (fread(b, 1, *len, f) != *len) { perror(path); exit(2); }
  fclose(f);
  b[*len] = 0;
  return b;
}

static int cmp_u32(const void *a, const void *b) {
  uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
  return x < y ? -1 : x > y;
}
static void print_dist(const char *name, uint32_t *v, size_t n, int last) {
  if (!n) { printf("    \"%s\": null%s\n", name, last ? "" : ","); return; }
  qsort(v, n, sizeof *v, cmp_u32);
  double sum = 0;
  for (size_t i = 0; i < n; i++) sum += v[i];
#define P(q) v[(size_t)((double)(n - 1) * (q))]
  printf("    \"%s\": {\"n\": %zu, \"mean\": %.1f, \"p50\": %u, \"p90\": %u, \"p99\": %u, "
         "\"p999\": %u, \"max\": %u}%s\n",
         name, n, sum / n, P(0.5), P(0.9), P(0.99), P(0.999), v[n - 1], last ? "" : ",");
#undef P
}

static void eng_startup(double *phase_ns, int *nphase, const char **names);
static void eng_event(uint8_t b);
static void eng_collect(void);
static void eng_reset(void);
static void *eng_new_session(void);
static void eng_free_session(void *);
static const char *ENGINE;

static void mem_json(const char *k, uint64_t fp, uint64_t heap, int last) {
  printf("  \"%s\": {\"footprint\": %llu, \"heap\": %llu}%s\n", k, (unsigned long long)fp,
         (unsigned long long)heap, last ? "" : ",");
}

// Categories: written by gen_streams.py next to the keys.
enum { C_FIRST, C_NEXT, C_TOPUP, C_SPACE, C_SELECT, C_PUNCT, C_N };
static const char *CAT_NAMES[C_N] = {"first_key", "next_key", "topup_key", "space", "select", "punct"};

// ---- userdict mode: apply an edited user dictionary, then type the edit ----
// Each engine defines eng_userdict(), which loops: ud_edit() (untimed: the
// user saving the file, a new probe phrase each time), then the engine's own
// way of applying it, then ud_probe() -- typing the probe phrase's code + space
// must commit the probe phrase, or the edit did not take effect.
static int eng_userdict(int argc, char **argv);

#define UD_MAX_REPS 64
static char ud_expect[256];

static void ud_edit(const char *path, const uint8_t *base, size_t n, const char *code, const char *value, int rep) {
  snprintf(ud_expect, sizeof ud_expect, "%s%d", value, rep);
  FILE *f = fopen(path, "wb");
  if (!f || fwrite(base, 1, n, f) != n || fprintf(f, "%s\t%s\n", ud_expect, code) < 0 || fclose(f)) {
    perror(path);
    exit(2);
  }
}

static int ud_probe(const char *code) {
  out_len = 0;
  for (const char *c = code; *c; c++) { eng_event((uint8_t)*c); eng_collect(); }
  eng_event(' ');
  eng_collect();
  size_t n = strlen(ud_expect);
  return out_len == n && !memcmp(out_buf, ud_expect, n);
}

static int cmp_dbl(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static double median(const double *v, int n) {
  double s[UD_MAX_REPS];
  memcpy(s, v, (size_t)n * sizeof *v);
  qsort(s, (size_t)n, sizeof *s, cmp_dbl);
  return n % 2 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
}
// "name": {"median": m, "runs": [...]}
static void phase_json(const char *name, const double *v, int n, int last) {
  printf("    \"%s\": {\"median\": %.0f, \"runs\": [", name, median(v, n));
  for (int i = 0; i < n; i++) printf("%s%.0f", i ? ", " : "", v[i]);
  printf("]}%s\n", last ? "" : ",");
}

int main(int argc, char **argv) {
  allocc_get = (void (*)(allocc_t *))dlsym(RTLD_DEFAULT, "allocc_get");
  if (argc < 2) {
    fprintf(stderr, "usage: %s startup | stream KEYS EXPECT CATS TPUT LAT [LIMIT] | sessions N | userdict DICT BASE REPS CODE VALUE\n", argv[0]);
    return 2;
  }
  const char *mode = argv[1];
  uint64_t fp0 = footprint(), heap0 = heap_in_use();
  allocc_t a0 = allocs();
  double ph[8];
  const char *phn[8];
  int nph = 0;
  uint64_t t_start = now_ns();
  eng_startup(ph, &nph, phn);
  uint64_t t_ready = now_ns();
  uint64_t fp1 = footprint(), heap1 = heap_in_use();
  allocc_t a1 = allocs();

  printf("{\n  \"engine\": \"%s\",\n  \"mode\": \"%s\",\n", ENGINE, mode);
  printf("  \"startup_ns\": {");
  for (int i = 0; i < nph; i++) printf("\"%s\": %.0f, ", phn[i], ph[i]);
  printf("\"total\": %llu},\n", (unsigned long long)(t_ready - t_start));
  printf("  \"startup_allocs\": {\"mallocs\": %llu, \"bytes\": %llu},\n",
         (unsigned long long)(a1.mallocs - a0.mallocs), (unsigned long long)(a1.bytes - a0.bytes));
  mem_json("mem_before_init", fp0, heap0, 0);
  mem_json("mem_after_init", fp1, heap1, 0);

  if (!strcmp(mode, "userdict")) return eng_userdict(argc, argv);

  if (!strcmp(mode, "startup")) {
    // First keystroke after startup: what the user feels when they start typing.
    uint64_t t0 = now_ns();
    eng_event('b');
    eng_collect();
    uint64_t t1 = now_ns();
    eng_event(' ');
    eng_collect();
    uint64_t t2 = now_ns();
    printf("  \"first_key_ns\": %llu,\n  \"first_commit_ns\": %llu,\n", (unsigned long long)(t1 - t0),
           (unsigned long long)(t2 - t1));
    mem_json("mem_after_first_key", footprint(), heap_in_use(), 0);
    printf("  \"max_rss\": %llu\n}\n", (unsigned long long)max_rss());
    return 0;
  }

  if (!strcmp(mode, "sessions")) {
    int n = argc > 2 ? atoi(argv[2]) : 16;
    void **s = (void **)calloc((size_t)n, sizeof *s);
    uint32_t *lat = (uint32_t *)calloc((size_t)n, sizeof *lat);
    uint64_t fpa = footprint(), ha = heap_in_use();
    allocc_t aa = allocs();
    for (int i = 0; i < n; i++) {
      uint64_t t0 = now_ns();
      s[i] = eng_new_session();
      lat[i] = (uint32_t)(now_ns() - t0);
    }
    uint64_t fpb = footprint(), hb = heap_in_use();
    allocc_t ab = allocs();
    printf("  \"sessions\": %d,\n  \"per_session_footprint\": %.0f,\n  \"per_session_heap\": %.0f,\n", n,
           (double)(fpb - fpa) / n, (double)(hb - ha) / n);
    printf("  \"per_session_mallocs\": %.1f,\n  \"per_session_alloc_bytes\": %.0f,\n",
           (double)(ab.mallocs - aa.mallocs) / n, (double)(ab.bytes - aa.bytes) / n);
    printf("  \"create_ns\": {\n");
    print_dist("create", lat, (size_t)n, 1);
    printf("  },\n");
    uint64_t t0 = now_ns();
    for (int i = 0; i < n; i++) eng_free_session(s[i]);
    printf("  \"destroy_ns_mean\": %.0f\n}\n", (double)(now_ns() - t0) / n);
    return 0;
  }

  // ---- stream ----
  if (argc < 7) { fprintf(stderr, "stream needs KEYS EXPECT CATS TPUT LAT\n"); return 2; }
  size_t nk, ne, nc;
  uint8_t *keys = slurp(argv[2], &nk);
  uint8_t *expect = slurp(argv[3], &ne);
  uint8_t *cats = slurp(argv[4], &nc);
  int tput_passes = atoi(argv[5]), lat_passes = atoi(argv[6]);
  if (nc != nk) { fprintf(stderr, "cats/keys length mismatch\n"); return 2; }
  // Optional 8th arg: only replay the first LIMIT events (diagnostics); the
  // output is then checked as a prefix of the expected text.
  size_t limit = argc > 7 ? (size_t)atoll(argv[7]) : 0;
  int prefix_only = limit && limit < nk;
  if (prefix_only) nk = limit;

  // Pass 0: warm-up + correctness against the expected text.
  out_len = 0;
  uint64_t tw0 = now_ns();
  for (size_t i = 0; i < nk; i++) { eng_event(keys[i]); eng_collect(); }
  uint64_t tw1 = now_ns();
  int ok = prefix_only ? (out_len <= ne && !memcmp(out_buf, expect, out_len))
                       : (out_len == ne && !memcmp(out_buf, expect, ne));
  size_t diff = 0;
  if (!ok) {
    while (diff < out_len && diff < ne && (uint8_t)out_buf[diff] == expect[diff]) diff++;
    FILE *f = fopen("/dev/stderr", "w");
    size_t lo = diff > 60 ? diff - 60 : 0;
    fprintf(f, "MISMATCH at byte %zu (got %zu bytes, want %zu)\n got: %.*s\nwant: %.*s\n", diff, out_len, ne,
            (int)((out_len - lo) < 180 ? out_len - lo : 180), out_buf + lo, (int)((ne - lo) < 180 ? ne - lo : 180),
            (const char *)expect + lo);
  }
  printf("  \"events\": %zu,\n  \"output_ok\": %s,\n  \"output_bytes\": %zu,\n  \"first_pass_ns\": %llu,\n", nk,
         ok ? "true" : "false", out_len, (unsigned long long)(tw1 - tw0));
  mem_json("mem_after_warmup", footprint(), heap_in_use(), 0);

  // Throughput passes: no per-event timers, so libjd's numbers are not the
  // timer's. Both the bare engine call and the full front-end round trip.
  printf("  \"throughput_ns_per_event\": {\"engine_only\": [");
  for (int p = 0; p < tput_passes; p++) {
    eng_reset();
    out_len = 0;
    uint64_t t0 = now_ns();
    for (size_t i = 0; i < nk; i++) eng_event(keys[i]);
    uint64_t t1 = now_ns();
    printf("%s%.2f", p ? ", " : "", (double)(t1 - t0) / nk);
  }
  printf("], \"with_reads\": [");
  allocc_t ta0 = allocs();
  for (int p = 0; p < tput_passes; p++) {
    eng_reset();
    out_len = 0;
    uint64_t t0 = now_ns();
    for (size_t i = 0; i < nk; i++) { eng_event(keys[i]); eng_collect(); }
    uint64_t t1 = now_ns();
    printf("%s%.2f", p ? ", " : "", (double)(t1 - t0) / nk);
  }
  allocc_t ta1 = allocs();
  printf("]},\n");
  if (allocc_get && tput_passes)
    printf("  \"allocs_per_event\": {\"mallocs\": %.2f, \"frees\": %.2f, \"reallocs\": %.2f, \"bytes\": %.1f},\n",
           (double)(ta1.mallocs - ta0.mallocs) / nk / tput_passes, (double)(ta1.frees - ta0.frees) / nk / tput_passes,
           (double)(ta1.reallocs - ta0.reallocs) / nk / tput_passes, (double)(ta1.bytes - ta0.bytes) / nk / tput_passes);

  // Latency passes: per-event timestamps, split by event category.
  size_t cap = nk * (size_t)lat_passes;
  uint32_t *eng = (uint32_t *)malloc(cap * sizeof *eng), *tot = (uint32_t *)malloc(cap * sizeof *tot);
  uint32_t *bycat[C_N];
  size_t ncat[C_N] = {0};
  for (int c = 0; c < C_N; c++) bycat[c] = (uint32_t *)malloc(cap * sizeof(uint32_t));
  size_t m = 0;
  for (int p = 0; p < lat_passes; p++) {
    eng_reset();
    out_len = 0;
    for (size_t i = 0; i < nk; i++) {
      uint64_t t0 = now_ns();
      eng_event(keys[i]);
      uint64_t t1 = now_ns();
      eng_collect();
      uint64_t t2 = now_ns();
      eng[m] = (uint32_t)(t1 - t0);
      tot[m] = (uint32_t)(t2 - t0);
      int c = cats[i] < C_N ? cats[i] : C_NEXT;
      bycat[c][ncat[c]++] = tot[m];
      m++;
    }
  }
  printf("  \"latency_ns\": {\n");
  print_dist("engine_only", eng, m, 0);
  print_dist("with_reads", tot, m, 0);
  for (int c = 0; c < C_N; c++) print_dist(CAT_NAMES[c], bycat[c], ncat[c], c == C_N - 1);
  printf("  },\n");
  mem_json("mem_after_all", footprint(), heap_in_use(), 0);
  printf("  \"resident_after_all\": %llu,\n", (unsigned long long)resident());
  printf("  \"max_rss\": %llu\n}\n", (unsigned long long)max_rss());
  return ok ? 0 : 1;
}
