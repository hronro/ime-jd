#ifndef JD_H
#define JD_H

#include <stddef.h>

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
 * `value` points into a dictionary blob: the library's embedded dictionary
 * — read-only data that lives for the whole process — or a dictionary or
 * user-dictionary blob the context was created with, which you own and
 * keep alive (see jd_init). `hint` is inline bytes owned by whoever owns
 * this struct. Nothing here is invalidated by later engine calls, so there
 * is nothing to copy defensively; the only lifetimes to respect are your
 * own blobs'.
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
 * `commit_a` / `commit_b` are NUL-terminated pointers into a dictionary blob
 * (valid exactly as long as `query_option.value` is); `commit_lit` is a
 * single literal byte. Any of them may be absent — NULL for the pointers, 0
 * for the byte. Nothing was committed when all three are absent. Splitting
 * the commit this way is what lets the library return it without owning a
 * buffer, so no pointer a caller receives is ever invalidated by the engine.
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
 * jd_deinit. Multiple contexts may exist simultaneously; the embedded
 * dictionary and punctuation tables are parsed once on first use and
 * shared read-only across all of them. The dictionaries a context types
 * from, by contrast, are per context: each context reads the blobs it was
 * created with for its whole lifetime.
 *
 * Thread-safety: contexts are independent — different threads operating on
 * different contexts is safe. A single context must not be used concurrently
 * from multiple threads; serialize calls with an external mutex if you need
 * that.
 */
typedef struct jd_context jd_context;

/**
 * Create a new context. Each returned handle is owned by the caller and must
 * be released with jd_deinit.
 *
 * `dict` is the dictionary the context types from: NULL (with `dict_len`
 * 0) for the library's embedded one, or a dictionary blob produced by
 * jd_dict_build to type from that instead. libjd-engine, the library built
 * without an embedded dictionary, has nothing to fall back on: there a NULL
 * `dict` fails.
 *
 * `user_dict` is either NULL (with `user_dict_len` 0) for no user
 * dictionary, or a user-dictionary blob produced by jd_user_dict_build
 * against this same `dict` — one built against any other dictionary fails.
 *
 * Both blobs are YOUR memory: 4-byte aligned, alive and unmoved until
 * jd_deinit — and for as long as you still use any candidate `value` or
 * commit segment that points into them. The engine validates each one here
 * in one linear pass (the same checks as jd_dict_check and
 * jd_user_dict_check) and reads them in place afterwards; it never copies
 * them. To change dictionaries, create a new context with the new blobs,
 * release the old context, and only then free the old blobs.
 *
 * Returns NULL when a blob fails validation (call jd_dict_check or
 * jd_user_dict_check to learn why — a stale or corrupt cached blob should
 * simply be rebuilt), when `dict` is NULL in libjd-engine, or on allocation
 * failure. It never falls back to another dictionary than the ones you
 * passed.
 *
 * Exactly one heap allocation happens here and exactly one matching free
 * happens in jd_deinit; nothing in between touches an allocator.
 */
jd_context *jd_init(const void *dict, size_t dict_len,
                    const void *user_dict, size_t user_dict_len);

/**
 * Release all memory held by ctx. After this call ctx is invalid. The shared
 * trie and punctuation tables remain alive for the rest of the process;
 * other contexts are unaffected. The user-dictionary blob the context was
 * created with is not touched — it is yours to free once nothing uses it.
 */
void jd_deinit(jd_context *ctx);

/* ------------------------------------------------------------------------
 * Text
 *
 * Every dictionary — the embedded one, one you build with jd_dict_build,
 * and a user dictionary — is built from the same text: lines of
 * `value<TAB>keys`, the line format of the library's own table files. A
 * host that lists the lines splits the text itself, so this is exactly how
 * the library reads it, byte by byte:
 *
 *   - Lines end at LF and count from 1; a CR alone ends nothing.
 *   - Each line is trimmed of spaces (0x20) and CRs at both ends, and of
 *     nothing else: not TAB, not U+3000 or any other whitespace.
 *   - A line that is then empty is blank and one that starts with `#` is a
 *     comment; both are ignored.
 *   - Any other line splits at its first TAB into the value before it and
 *     the keys after it, each trimmed of spaces at both ends. A line with
 *     no TAB is skipped.
 *   - Keys are 1 to 6 keys, each a-z or `;`, with no `;` after a letter.
 *     After a letter there are candidates on screen and `;` picks the
 *     second of them, so a code cannot go on with one there; before the
 *     first letter there is nothing to pick, so a code may start with `;`
 *     (`;` and `;;` are the embedded dictionary's ；and ：).
 *   - Values are 1 to JD_DICT_VALUE_MAX bytes of UTF-8 with no byte below
 *     0x20 and no 0x7F.
 *   - A byte-order mark is not skipped. Drop one when you decode a file,
 *     or U+FEFF becomes part of line 1.
 *
 * A line that breaks these rules is skipped — it never fails the build —
 * and counted in `invalid`. A line that exactly repeats an earlier line's
 * keys and value is dropped and counted in `dropped`. The words on one
 * code are listed in the order of their lines.
 * ---------------------------------------------------------------------- */

/** Status codes returned by the dictionary and user-dictionary calls. */
#define JD_USER_DICT_OK 0
/** build: `buf_cap` is below what the bound asks for. */
#define JD_USER_DICT_BUFFER_TOO_SMALL 1
/** build: more entries than the cap (`line` is the first excess one). */
#define JD_USER_DICT_TOO_MANY_ENTRIES 2
/**
 * check/init: built by a different libjd (format or byte order), or — a
 * user dictionary — against another dictionary than the one given.
 * Rebuild it.
 */
#define JD_USER_DICT_STALE 3
/** check/init: structurally invalid. Rebuild it. */
#define JD_USER_DICT_CORRUPT 4
/** check/init/build: a blob or buffer pointer is not 4-byte aligned. */
#define JD_USER_DICT_MISALIGNED 5
/** build: the text exceeds the text cap. */
#define JD_USER_DICT_TEXT_TOO_LONG 6
/** NULL for the embedded dictionary, in libjd-engine, which has none. */
#define JD_USER_DICT_NO_BUILTIN 7

/* ------------------------------------------------------------------------
 * Dictionary
 *
 * The dictionary is what a context types from: every code and the words
 * on it. The library embeds one, the 键道 tables, which jd_init uses when
 * you pass it none; libjd-engine embeds none, and is over 95% smaller.
 * Either way you can build your own from text and pass it to jd_init in
 * its place. It is the same structure as the embedded one, built by the same
 * code, so it types the same way and as fast, at any size up to
 * JD_DICT_MAX_ENTRIES.
 *
 * Build it once and keep the blob: cache the bytes (memory-map the file,
 * if you can — the engine reads it in place) and hand them to jd_init on
 * every launch. A build is the slow part — about 0.3 s per million entries
 * on a laptop — and checking a blob at jd_init a few tens of milliseconds
 * per million.
 * ---------------------------------------------------------------------- */

/** Hard limits on a dictionary. Also reported by jd_abi_layout. */
#define JD_DICT_MAX_ENTRIES 16777215u
#define JD_DICT_VALUE_MAX 1023
#define JD_DICT_TEXT_MAX 4294967295u

/**
 * A dictionary build reports in the same structs as a user dictionary's
 * (see below); `shared` is always 0, and a note is only ever a skipped
 * line or a dropped repeat.
 */
typedef struct jd_user_dict_note_s jd_dict_note;
typedef struct jd_user_dict_report_s jd_dict_report;
typedef struct jd_user_dict_info_s jd_dict_info;

/**
 * An upper bound on what jd_dict_build writes into your buffer from
 * `text_len` bytes of text at `text`: the largest blob the text can make,
 * the build's working space and, past it, one jd_dict_note per line that
 * is not empty. One parse of the text. Allocate at least this much, 4-byte
 * aligned, for `buf`; the blob itself is usually under half of it.
 */
size_t jd_dict_blob_bound(const char *text, size_t text_len);

/**
 * Build a dictionary blob from `text` into `buf`, your buffer of `buf_cap`
 * bytes (at least the bound, 4-byte aligned). On success `*blob_len`
 * receives the blob's length — that prefix of the buffer is the blob:
 * cache exactly those bytes, or hand them to jd_init — and `report` says
 * what went in, what was skipped and what was dropped. On failure — a
 * problem with the call as a whole, never with one line — `*blob_len` is 0
 * and `report->status` / `line` say why. The return value is
 * `report->status`. The library allocates nothing here.
 *
 * `source_tag` is stored in the blob for you (see jd_dict_check). The
 * notes sit past the blob, at `(char *)buf + report->notes_offset`,
 * `report->notes` of them, ascending by line: one for every line skipped
 * and one for every repeat dropped.
 *
 * The blob is valid for libraries of the same format and byte order: after
 * an update that changes the format, jd_dict_check reports it as stale
 * and you rebuild it from the text you kept. `blob_len` and `report` may
 * be NULL.
 */
unsigned int jd_dict_build(const char *text, size_t text_len,
                           unsigned long long source_tag,
                           void *buf, size_t buf_cap, size_t *blob_len,
                           jd_dict_report *report);

/**
 * Validate a dictionary blob exactly as jd_init would: JD_USER_DICT_OK, or
 * JD_USER_DICT_STALE / _CORRUPT / _MISALIGNED. On success `*info` (if not
 * NULL) receives the blob's source tag and entry count. Bytes past the
 * blob's own length are ignored.
 */
unsigned int jd_dict_check(const void *blob, size_t blob_len, jd_dict_info *info);

/* ------------------------------------------------------------------------
 * User dictionary
 *
 * A user dictionary is a blob you build from phrases and keep: cache the
 * bytes wherever you like and hand them to jd_init on every launch, so
 * the engine never parses text on a hot path. It sits on top of a
 * dictionary — the embedded one or your own — and the engine merges the
 * phrases into every candidate list — same ordering rules as the
 * dictionary, shorter completions first, ties by key order — and puts a
 * user phrase ahead of a dictionary word on the same code. Unlike a
 * dictionary it is capped small enough to rebuild in a keyboard extension
 * at every edit, so edits apply at once.
 *
 * To type from the user dictionary alone, build it against an empty
 * dictionary — jd_dict_build on no text — and pass that same dictionary
 * to jd_init.
 *
 * The blob carries a 64-bit `source_tag` you choose when building — a
 * file's modification time, a content hash, a database revision — and
 * jd_user_dict_check hands it back, so you can tell whether a cached blob
 * still matches the phrases you have without keeping a sidecar record.
 * The engine never interprets it.
 *
 * The text follows the rules above. On top of them, a phrase that repeats
 * a dictionary word on the same code is dropped and counted in `dropped`.
 * Everything the build has to say about individual lines — why a line was
 * skipped, what a dropped line repeats, and which kept phrases sit on a
 * code that a dictionary word or another phrase already uses (重码) —
 * comes back as jd_user_dict_notes, written into your buffer past the
 * blob. The status codes are for the call as a whole: a buffer below the
 * bound, too many phrases, too much text, a bad dictionary.
 * ---------------------------------------------------------------------- */

/** Hard limits. Also reported by jd_abi_layout so a binding can verify them. */
#define JD_USER_DICT_MAX_ENTRIES 500000
#define JD_USER_DICT_VALUE_MAX JD_DICT_VALUE_MAX
#define JD_USER_DICT_TEXT_MAX (16u * 1024u * 1024u)

/**
 * One thing jd_user_dict_build has to say about an input line. A skipped
 * line (it does not parse) carries exactly one of JD_USER_DICT_LINE_MALFORMED,
 * _BAD_KEYS and _BAD_VALUE, and nothing else. A dropped line (parsed, but
 * not in the blob) carries a JD_USER_DICT_LINE_REPEATS_* flag. A kept line
 * whose code is already taken carries JD_USER_DICT_LINE_CODE_IN_* flags:
 * the phrase works, listed ahead of the built-in word, but the code is
 * shared (重码), which is what a user wants to know before relying on it.
 */
typedef struct jd_user_dict_note_s {
  /** 1-based input line. */
  unsigned int line;
  /** JD_USER_DICT_LINE_* bits. */
  unsigned int flags;
  /**
   * A kept line this one relates to: for a repeat, the line it repeats (0
   * for a built-in word); for a shared code, the first kept line on that
   * code — and for that first line, the second. 0 otherwise.
   */
  unsigned int other;
  /** Built-in words on exactly this code; 0 on a skipped line. */
  unsigned int builtin;
  /** Other kept lines on exactly this code; 0 on a dropped or skipped line. */
  unsigned int peers;
} jd_user_dict_note;

/** Dropped: same keys and value as the kept line `other`. */
#define JD_USER_DICT_LINE_REPEATS_LINE 0x1u
/** Dropped: same keys and value as a word of the dictionary beneath. */
#define JD_USER_DICT_LINE_REPEATS_BUILTIN 0x2u
/** Kept: a word of the dictionary beneath sits on exactly this code (`builtin` says how many). */
#define JD_USER_DICT_LINE_CODE_IN_BUILTIN 0x4u
/** Kept: kept line `other` sits on this code too (`peers` says how many do). */
#define JD_USER_DICT_LINE_CODE_IN_LINE 0x8u
/** Skipped: neither blank nor a comment, and no TAB. */
#define JD_USER_DICT_LINE_MALFORMED 0x10u
/** Skipped: keys empty, longer than 6, not all a-z and `;`, or a `;` after a letter. */
#define JD_USER_DICT_LINE_BAD_KEYS 0x20u
/** Skipped: value empty, longer than JD_USER_DICT_VALUE_MAX, not UTF-8, or containing control bytes. */
#define JD_USER_DICT_LINE_BAD_VALUE 0x40u

/**
 * What jd_user_dict_build found. `status` is one of the JD_USER_DICT_*
 * codes; `line` is the 1-based input line it refers to (the first phrase
 * past the cap), or 0 when it refers to the call as a whole. The rest is
 * filled on success: `entries` went in, `dropped` were duplicates, `shared`
 * are kept phrases on a shared code, `invalid` lines were skipped because
 * they do not parse, and the notes — `dropped + shared + invalid` of them,
 * ascending by line — start `notes_offset` bytes into your buffer.
 */
typedef struct jd_user_dict_report_s {
  unsigned int status, line, entries, dropped, shared, invalid, notes, notes_offset;
} jd_user_dict_report;

/**
 * What jd_user_dict_check reports about a valid blob: the `source_tag` it
 * was built with and how many phrases it holds.
 */
typedef struct jd_user_dict_info_s {
  unsigned long long source_tag;
  unsigned int entries;
} jd_user_dict_info;

/**
 * An upper bound on what jd_user_dict_build writes into your buffer from
 * `phrases_len` bytes of text at `phrases`: the blob (one entry and one NUL
 * per line that is not empty, up to JD_USER_DICT_MAX_ENTRIES, plus the
 * text itself) and, past it, one jd_user_dict_note per line that is not
 * empty. One pass over the text, no parsing. Allocate at least this much,
 * 4-byte aligned, for `buf`.
 */
size_t jd_user_dict_blob_bound(const char *phrases, size_t phrases_len);

/**
 * Build a user-dictionary blob from `phrases` into `buf`, your buffer of
 * `buf_cap` bytes (at least the bound, 4-byte aligned). On success
 * `*blob_len` receives the blob's length — that prefix of the buffer is the
 * blob: cache exactly those bytes, or hand them to jd_init — and `report`
 * says what went in, what was skipped, what was dropped and what shares a
 * code. On failure — a problem with the call as a whole, never with one
 * line — `*blob_len` is 0 and `report->status` / `line` say why. The
 * return value is `report->status`. The library allocates nothing here:
 * sorting, the string pool and the notes are all laid out inside your
 * buffer.
 *
 * `source_tag` is stored in the blob for you (see jd_user_dict_check).
 *
 * The notes sit past the blob, at `(char *)buf + report->notes_offset`,
 * `report->notes` of them, ascending by line: one for every line skipped
 * because it does not parse, one for every line dropped as a duplicate and
 * one for every kept phrase whose code is shared. They are plain data in
 * your buffer, valid for as long as you keep it; jd_init only ever reads
 * the blob prefix, so a context can be created from the same buffer while
 * you still read them. A GUI maps them onto its rows; a CLI prints them.
 *
 * `blob_len` and `report` may be NULL.
 *
 * `dict` is the dictionary the user dictionary will sit on, as for
 * jd_init: NULL for the embedded one, or your own blob. The blob records
 * which dictionary it was deduplicated against, so it is valid on that one
 * only: after an update that changes the embedded dictionary, or once you
 * rebuild your own, jd_user_dict_check reports it as stale and you rebuild
 * it from the phrases you persisted. A `dict` that fails jd_dict_check
 * fails this call with the same status; a NULL one in libjd-engine with
 * JD_USER_DICT_NO_BUILTIN.
 */
unsigned int jd_user_dict_build(const void *dict, size_t dict_len,
                                const char *phrases, size_t phrases_len,
                                unsigned long long source_tag,
                                void *buf, size_t buf_cap, size_t *blob_len,
                                jd_user_dict_report *report);

/**
 * Validate a cached blob exactly as jd_init would on `dict` (NULL for the
 * embedded dictionary): JD_USER_DICT_OK, or JD_USER_DICT_STALE / _CORRUPT /
 * _MISALIGNED. Any failure means "rebuild it"; the distinction is for your
 * logs. On success `*info` (if not NULL) receives the blob's source tag and
 * phrase count, which is how you decide whether the cache still matches
 * your phrases. Bytes past the blob's own length are ignored, so passing a
 * whole buffer is fine. A `dict` that fails jd_dict_check fails this call
 * with the same status.
 */
unsigned int jd_user_dict_check(const void *dict, size_t dict_len,
                                const void *blob, size_t blob_len,
                                jd_user_dict_info *info);

/**
 * A 64-bit hash of `len` bytes at `bytes` (NULL is fine with a length of
 * 0), for the `source_tag` of a blob built from a text you keep: hash the
 * text when you build, hash it again at launch, and a cached blob whose
 * tag differs was built from something else. Fast enough to run over a
 * whole phrases file at every launch — gigabytes a second. The same bytes
 * hash the same on every platform and in every release of the library.
 * Not a cryptographic hash.
 */
unsigned long long jd_user_dict_hash(const void *bytes, size_t len);

/* ------------------------------------------------------------------------
 * Memory for hosts without an allocator of their own
 *
 * The user-dictionary calls take buffers you own. A host that cannot
 * allocate memory the library can read — a WebAssembly host, which has no
 * allocator inside the module's linear memory — gets it from here instead.
 * Native hosts normally use their own allocator and never call these.
 * ---------------------------------------------------------------------- */

/**
 * Allocate `size` bytes, aligned to 16, from the library's allocator.
 * Returns NULL for a size of 0 or on failure. Release with jd_free, passing
 * the same size. These are explicit host calls; the keystroke path still
 * never allocates.
 */
void *jd_alloc(size_t size);
void jd_free(void *ptr, size_t size);

/**
 * Feed one keystroke to the engine. `key` is interpreted as a literal ASCII
 * byte; the engine resolves it in this order:
 *   1. Space commits the candidate at `anchor_index` (or a bare " " when
 *      nothing is in flight); `;` commits `anchor_index + 1` on a trie
 *      composition. When there is no candidate at `anchor_index + 1`, `;`
 *      is handled as in 3: it commits the anchor candidate and opens the
 *      `;` symbol window. Digits are literal input — numeric candidate-selector
 *      bindings (`1`-`9` and the like) are the IME's responsibility, see
 *      docs/integration.md.
 *   2. The punctuation tables — paired entries auto-commit with toggle,
 *      single-candidate normals auto-commit, multi-candidate normals open a
 *      candidate window.
 *   3. The trie — descend, or commit-and-jump when the key is a child of
 *      the root but not of the current node. A descent never commits, even
 *      to a code with a single candidate: the next key commits it.
 *   4. Fallback — commit the anchor candidate with the key byte appended.
 *
 * Read the outcome with jd_state_ptr. While optional inline ASCII preedit is
 * active, this function does nothing until the host confirms or cancels it.
 */
void jd_press_key(jd_context *ctx, char key);

typedef unsigned int jd_inline_ascii_result;
enum {
  JD_INLINE_ASCII_UNHANDLED = 0,
  JD_INLINE_ASCII_ACCEPTED = 1,
  JD_INLINE_ASCII_FULL = 2
};

/**
 * Optional inline ASCII composer. Pass the translated ASCII byte and set
 * shift only for a Shift-modified key press. An uppercase A–Z starts a
 * preedit when Shift is down and there is no candidate composition. While
 * active, letters, digits and -_+.' append regardless of Shift. Filter
 * shortcuts and key releases in the host.
 *
 * ACCEPTED updates the preedit without producing a commit. FULL means the
 * 256-byte limit was reached and the previous preedit is intact. UNHANDLED
 * leaves the context unchanged. For Return or Space the host can submit the
 * current text via jd_inline_ascii_ptr and then clear it with jd_reset;
 * callers can cancel with jd_reset or edit with jd_backspace.
 */
jd_inline_ascii_result jd_press_inline_ascii(jd_context *ctx, char key,
                                            unsigned int shift);

/**
 * NUL-terminated inline ASCII preedit, or NULL when inactive. The borrowed
 * pointer is valid until the next mutation or jd_deinit. Copy the text
 * before keeping it across calls. This text is separate from jd_state.
 */
const char *jd_inline_ascii_ptr(jd_context *ctx);

/**
 * Remove one byte from active inline ASCII preedit, or undo the most recent
 * trie descent, re-deriving the candidate list, and
 * park the anchor back at the start of the shorter code. Closes a
 * punctuation candidate window without committing. Does nothing without
 * an active composition and never produces a commit.
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
 * replaced by the next operation that updates the state on the same context,
 * but the pointer itself never dangles and nothing reachable through it
 * does either.
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

/* ------------------------------------------------------------------------
 * Reverse lookup
 *
 * The other direction from the keystroke path: given a value, the codes it
 * is typed with.
 * ---------------------------------------------------------------------- */

/**
 * Inline code capacity, including the NUL terminator. A code is at most 6
 * keys; the library hard-errors at build time if that ever outgrows this
 * array.
 */
#define JD_CODE_CAP 8

/**
 * One code a value is typed with.
 *
 * `keys` is the code, NUL-terminated: a-z, and `;` before the first letter.
 * `index` is the value's position in the candidate list after typing
 * exactly these keys with nothing in flight — the index jd_read_range
 * returns it at, so 0 is what space commits. It counts the context's user
 * phrases on the same code, which lead the dictionary's words.
 */
typedef struct {
  char keys[JD_CODE_CAP];
  unsigned int index;
  /** JD_CODE_* bits. */
  unsigned int flags;
} jd_code;

/** The code comes from the context's user dictionary, not its dictionary. */
#define JD_CODE_USER 0x1u

/**
 * The codes `value` is typed with in this context: from its dictionary and
 * from the user dictionary the context was created with. `value` is
 * `value_len` bytes of UTF-8 compared byte for byte — it is not trimmed or
 * normalized — and need not be NUL-terminated.
 *
 * The codes go into `out`, which has room for `out_cap` entries, in
 * candidate order: shorter codes first, ties key by key (a-z, then `;`), and
 * a user phrase's code ahead of a dictionary word's on the same keys. Returns
 * how many codes there are in all, which may be more than `out_cap` — only
 * the first `out_cap` are written — so NULL and 0 count them. Returns 0 for
 * a value no dictionary holds, and for an empty one.
 *
 * A value listed twice on one code is one code, reported at its first
 * index. Dictionary codes only: a punctuation key (`,` for `，`) is not a
 * code.
 *
 * A pure read, like jd_read_range: the composition, the anchor and the
 * state block are untouched, and nothing is allocated. Cost: one binary
 * search over the dictionary, a few more per code to spell it out, and one
 * pass over the user dictionary's phrases.
 */
unsigned int jd_lookup_codes(jd_context *ctx, const char *value,
                             size_t value_len, jd_code *out,
                             unsigned int out_cap);

/* Queries for jd_abi_layout. */
#define JD_ABI_SIZEOF_STATE 0
#define JD_ABI_SIZEOF_OPTION 1
#define JD_ABI_HINT_CAP 2
#define JD_ABI_SCRATCH_OPTIONS 3
#define JD_ABI_MAX_COMMIT_LEN 4
#define JD_ABI_SIZEOF_USER_DICT_REPORT 5
#define JD_ABI_USER_DICT_MAX_ENTRIES 6
#define JD_ABI_USER_DICT_VALUE_MAX 7
#define JD_ABI_SIZEOF_USER_DICT_INFO 8
#define JD_ABI_SIZEOF_USER_DICT_NOTE 9
#define JD_ABI_SIZEOF_CODE 10
#define JD_ABI_CODE_CAP 11
#define JD_ABI_USER_DICT_TEXT_MAX 12
#define JD_ABI_DICT_MAX_ENTRIES 13
#define JD_ABI_DICT_VALUE_MAX 14
#define JD_ABI_DICT_TEXT_MAX 15
/** Entries in the embedded dictionary: 0 in libjd-engine. */
#define JD_ABI_BUILTIN_DICT_ENTRIES 16

/**
 * Layout self-check. This header and the language bindings declare these
 * structs by hand, so either can drift from the compiled library with no
 * diagnostic. Compare the values against your own sizeof/constants once at
 * startup; a mismatch means the declarations are out of sync and memory
 * would be corrupted.
 *
 * JD_ABI_MAX_COMMIT_LEN is the upper bound on a joined commit in bytes
 * (excluding a NUL) — size a buffer with it if you concatenate the segments
 * into fixed storage; it holds whatever dictionaries you load, whose values
 * are all capped at JD_DICT_VALUE_MAX. Unknown queries return 0.
 */
unsigned int jd_abi_layout(unsigned int what);

#ifdef __cplusplus
}
#endif

#endif /* JD_H */
