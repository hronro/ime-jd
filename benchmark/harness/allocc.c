// Counts heap allocations process-wide via dyld interposing.
// Load with DYLD_INSERT_LIBRARIES; the harness reads counters via allocc_get.
#include <malloc/malloc.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct { uint64_t mallocs, frees, reallocs, bytes; } allocc_t;
static _Atomic uint64_t n_malloc, n_free, n_realloc, n_bytes;

void allocc_get(allocc_t *a) {
  a->mallocs = atomic_load_explicit(&n_malloc, memory_order_relaxed);
  a->frees = atomic_load_explicit(&n_free, memory_order_relaxed);
  a->reallocs = atomic_load_explicit(&n_realloc, memory_order_relaxed);
  a->bytes = atomic_load_explicit(&n_bytes, memory_order_relaxed);
}

#define BUMP(c, v) atomic_fetch_add_explicit(&(c), (v), memory_order_relaxed)

static void *my_malloc(size_t s) { BUMP(n_malloc, 1); BUMP(n_bytes, s); return malloc(s); }
static void *my_calloc(size_t n, size_t s) { BUMP(n_malloc, 1); BUMP(n_bytes, n * s); return calloc(n, s); }
static void *my_realloc(void *p, size_t s) {
  if (p) BUMP(n_realloc, 1); else BUMP(n_malloc, 1);
  BUMP(n_bytes, s);
  return realloc(p, s);
}
static void my_free(void *p) { if (p) BUMP(n_free, 1); free(p); }
static int my_posix_memalign(void **r, size_t a, size_t s) { BUMP(n_malloc, 1); BUMP(n_bytes, s); return posix_memalign(r, a, s); }
static void *my_aligned_alloc(size_t a, size_t s) { BUMP(n_malloc, 1); BUMP(n_bytes, s); return aligned_alloc(a, s); }
static void *my_zone_malloc(malloc_zone_t *z, size_t s) { BUMP(n_malloc, 1); BUMP(n_bytes, s); return malloc_zone_malloc(z, s); }
static void *my_zone_calloc(malloc_zone_t *z, size_t n, size_t s) { BUMP(n_malloc, 1); BUMP(n_bytes, n * s); return malloc_zone_calloc(z, n, s); }
static void *my_zone_realloc(malloc_zone_t *z, void *p, size_t s) {
  if (p) BUMP(n_realloc, 1); else BUMP(n_malloc, 1);
  BUMP(n_bytes, s);
  return malloc_zone_realloc(z, p, s);
}
static void my_zone_free(malloc_zone_t *z, void *p) { if (p) BUMP(n_free, 1); malloc_zone_free(z, p); }

#define INTERPOSE(r, o) \
  __attribute__((used)) static struct { const void *a, *b; } _ip_##o __attribute__((section("__DATA,__interpose"))) = {(const void *)(uintptr_t)&r, (const void *)(uintptr_t)&o}
INTERPOSE(my_malloc, malloc);
INTERPOSE(my_calloc, calloc);
INTERPOSE(my_realloc, realloc);
INTERPOSE(my_free, free);
INTERPOSE(my_posix_memalign, posix_memalign);
INTERPOSE(my_aligned_alloc, aligned_alloc);
INTERPOSE(my_zone_malloc, malloc_zone_malloc);
INTERPOSE(my_zone_calloc, malloc_zone_calloc);
INTERPOSE(my_zone_realloc, malloc_zone_realloc);
INTERPOSE(my_zone_free, malloc_zone_free);
