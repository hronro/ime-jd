// JNI bridge over libjd's C ABI (see ../../../../../core/include/jd.h).
//
// Unlike the Rust and Swift bindings — which can hand out libjd's immortal blob
// pointers directly — JNI has to materialize JVM objects, so this layer is the
// one place a copy is unavoidable. It therefore copies only what the caller
// asks for: `nativeReadRange` builds Strings for exactly the requested window,
// so a candidate strip that has fetched 900 candidates but only shows 9 pays
// for 9 rows' worth of String work at a time.
//
// A user dictionary crosses as plain arrays: `UserDict.nativeBuild` returns the
// blob as a byte[] and the report as an int[], `UserDict.nativeCheck` a cached
// blob's verdict as a long[], and `Engine.nativeInit` copies a blob into memory
// of its own, because jd_init reads the blob in place for the context's whole
// lifetime and a JVM array can move. No class of this app is built here for
// any of them, so R8 has nothing new to keep in step with this file.
//
// Compiled with the NDK clang and linked against the *dynamic* libjd.so (the
// static archive uses local-exec TLS relocations that ld rejects in a shared
// object). See android/scripts/build-libjd.sh.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include "jd.h"

// How many candidates one native read pulls across the JNI boundary at a time.
// The Kotlin side loops for larger windows.
#define READ_CHUNK 64

// Cached classes/methods (global refs live for the process). Populated in JNI_OnLoad.
static jclass    g_state_cls;
static jmethodID g_state_ctor;      // (Ljava/lang/String;II)V
static jclass    g_candidate_cls;
static jmethodID g_candidate_ctor;  // (Ljava/lang/String;Ljava/lang/String;)V
static jclass    g_arraylist_cls;
static jmethodID g_arraylist_ctor;  // (I)V
static jmethodID g_arraylist_add;   // (Ljava/lang/Object;)Z
static jclass    g_object_cls;      // java/lang/Object, for UserDict.nativeBuild's pair

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    // Every class instantiated from C here must keep its name AND constructor
    // in ../../../proguard-rules.pro — R8 cannot see these references, and it
    // silently ignores keep rules whose class no longer exists. Renaming a
    // class on the Kotlin side without updating the keep rule ships a release
    // IME that crashes right here on its first popup.
    jclass c;
    c = (*env)->FindClass(env, "com/hronro/imejd/engine/EngineState");
    g_state_cls = (jclass)(*env)->NewGlobalRef(env, c);
    g_state_ctor = (*env)->GetMethodID(env, g_state_cls, "<init>",
        "(Ljava/lang/String;II)V");

    c = (*env)->FindClass(env, "com/hronro/imejd/engine/Candidate");
    g_candidate_cls = (jclass)(*env)->NewGlobalRef(env, c);
    g_candidate_ctor = (*env)->GetMethodID(env, g_candidate_cls, "<init>",
        "(Ljava/lang/String;Ljava/lang/String;)V");

    c = (*env)->FindClass(env, "java/util/ArrayList");
    g_arraylist_cls = (jclass)(*env)->NewGlobalRef(env, c);
    g_arraylist_ctor = (*env)->GetMethodID(env, g_arraylist_cls, "<init>", "(I)V");
    g_arraylist_add  = (*env)->GetMethodID(env, g_arraylist_cls, "add", "(Ljava/lang/Object;)Z");

    c = (*env)->FindClass(env, "java/lang/Object");
    g_object_cls = (jclass)(*env)->NewGlobalRef(env, c);

    // This file reads libjd's structs through the hand-written jd.h, so a
    // drift between the header and the compiled library would corrupt memory
    // with no diagnostic. Refuse to load instead.
    if (jd_abi_layout(JD_ABI_SIZEOF_STATE) != sizeof(jd_state) ||
        jd_abi_layout(JD_ABI_SIZEOF_OPTION) != sizeof(query_option) ||
        jd_abi_layout(JD_ABI_HINT_CAP) != JD_HINT_CAP ||
        jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_REPORT) != sizeof(jd_user_dict_report) ||
        jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_NOTE) != sizeof(jd_user_dict_note) ||
        jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_INFO) != sizeof(jd_user_dict_info) ||
        jd_abi_layout(JD_ABI_USER_DICT_MAX_ENTRIES) != JD_USER_DICT_MAX_ENTRIES ||
        jd_abi_layout(JD_ABI_USER_DICT_VALUE_MAX) != JD_USER_DICT_VALUE_MAX) {
        return JNI_ERR;
    }

    return JNI_VERSION_1_6;
}

// Decode one code point from standard UTF-8, advancing *pp. Invalid bytes yield
// U+FFFD. (libjd emits standard UTF-8; do NOT feed it to NewStringUTF, which
// expects *modified* UTF-8 and mis-encodes 4-byte / supplementary-plane chars.)
static uint32_t utf8_next(const unsigned char **pp) {
    const unsigned char *p = *pp;
    unsigned char b = p[0];
    uint32_t cp;
    int len;
    if (b < 0x80)            { cp = b;        len = 1; }
    else if ((b & 0xE0) == 0xC0) { cp = b & 0x1F; len = 2; }
    else if ((b & 0xF0) == 0xE0) { cp = b & 0x0F; len = 3; }
    else if ((b & 0xF8) == 0xF0) { cp = b & 0x07; len = 4; }
    else { *pp = p + 1; return 0xFFFD; }
    for (int i = 1; i < len; i++) {
        if ((p[i] & 0xC0) != 0x80) { *pp = p + i; return 0xFFFD; }
        cp = (cp << 6) | (p[i] & 0x3F);
    }
    *pp = p + len;
    return cp;
}

// UTF-8 bytes -> jstring (via UTF-16). `s` need not be NUL-terminated when
// `limit` is given; pass SIZE_MAX to stop at the NUL. Returns NULL for a NULL
// input, and an empty string for an empty one.
static jstring utf8_to_jstring_n(JNIEnv *env, const char *s, size_t limit) {
    if (s == NULL) return NULL;

    const unsigned char *start = (const unsigned char *)s;
    const unsigned char *end = start;
    while ((size_t)(end - start) < limit && *end) end++;
    const size_t nbytes = (size_t)(end - start);

    if (nbytes == 0) return (*env)->NewString(env, NULL, 0);

    // Pass 1: count UTF-16 code units.
    size_t n16 = 0;
    const unsigned char *p = start;
    while (p < end) {
        uint32_t cp = utf8_next(&p);
        n16 += (cp > 0xFFFF) ? 2 : 1;
    }

    jchar *buf = (jchar *)malloc(n16 * sizeof(jchar));
    if (buf == NULL) return NULL;

    // Pass 2: emit UTF-16 (surrogate pairs for supplementary code points).
    size_t j = 0;
    p = start;
    while (p < end) {
        uint32_t cp = utf8_next(&p);
        if (cp > 0xFFFF) {
            cp -= 0x10000;
            buf[j++] = (jchar)(0xD800 + (cp >> 10));
            buf[j++] = (jchar)(0xDC00 + (cp & 0x3FF));
        } else {
            buf[j++] = (jchar)cp;
        }
    }

    jstring result = (*env)->NewString(env, buf, (jsize)n16);
    free(buf);
    return result;
}

static jstring utf8_to_jstring(JNIEnv *env, const char *s) {
    return utf8_to_jstring_n(env, s, (size_t)-1);
}

// Read the context's state block and build an EngineState, joining the commit
// segments in the order the ABI defines: commit_a ++ commit_b ++ commit_lit.
static jobject build_state(JNIEnv *env, jd_context *ctx) {
    const jd_state *s = jd_state_ptr(ctx);

    jstring commit = NULL;
    if (s->commit_a != NULL || s->commit_b != NULL || s->commit_lit != 0) {
        // The engine's own bound: two longest values plus one literal byte.
        const unsigned int cap = jd_abi_layout(JD_ABI_MAX_COMMIT_LEN);
        char *joined = (char *)malloc((size_t)cap + 1);
        if (joined == NULL) return NULL;

        size_t len = 0;
        const char *segs[2] = { s->commit_a, s->commit_b };
        for (int i = 0; i < 2; i++) {
            const char *seg = segs[i];
            if (seg == NULL) continue;
            for (const char *p = seg; *p && len < cap; p++) joined[len++] = *p;
        }
        if (s->commit_lit != 0 && len < cap) joined[len++] = s->commit_lit;
        joined[len] = '\0';

        commit = utf8_to_jstring(env, joined);
        free(joined);
    }

    jobject state = (*env)->NewObject(env, g_state_cls, g_state_ctor,
        commit, (jint)s->options_count, (jint)s->anchor_index);
    if (commit) (*env)->DeleteLocalRef(env, commit);
    return state;
}

// ---- native methods of com.hronro.imejd.engine.Engine (member fns → jobject thiz) ----

// What Kotlin's Engine holds as its handle: the context, and the copy of the
// user-dictionary blob it was created with (NULL for the built-in dictionary
// alone). jd_init never copies the blob and reads it until jd_deinit, so it
// lives here and is freed only after the context.
typedef struct {
    jd_context *ctx;
    void *blob;
} engine_t;

static jd_context *ctx_of(jlong handle) {
    return ((engine_t *)(intptr_t)handle)->ctx;
}

// 0 on allocation failure, or when jd_init refuses the blob — which a blob
// UserDict.nativeBuild made in this process never is.
JNIEXPORT jlong JNICALL
Java_com_hronro_imejd_engine_Engine_nativeInit(JNIEnv *env, jobject thiz, jbyteArray user_dict) {
    (void)thiz;
    engine_t *e = (engine_t *)calloc(1, sizeof(engine_t));
    if (e == NULL) return 0;
    size_t len = 0;
    if (user_dict != NULL) {
        len = (size_t)(*env)->GetArrayLength(env, user_dict);
        // malloc's alignment (8 or 16) covers the 4 jd_init asks for.
        e->blob = malloc(len > 0 ? len : 1);
        if (e->blob == NULL) {
            free(e);
            return 0;
        }
        (*env)->GetByteArrayRegion(env, user_dict, 0, (jsize)len, (jbyte *)e->blob);
    }
    e->ctx = jd_init(e->blob, len);
    if (e->ctx == NULL) {
        free(e->blob);
        free(e);
        return 0;
    }
    return (jlong)(intptr_t)e;
}

JNIEXPORT void JNICALL
Java_com_hronro_imejd_engine_Engine_nativeDeinit(JNIEnv *env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    engine_t *e = (engine_t *)(intptr_t)handle;
    jd_deinit(e->ctx);
    free(e->blob); // only now: the context read it until jd_deinit
    free(e);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativePressKey(JNIEnv *env, jobject thiz, jlong ctx, jbyte key) {
    (void)thiz;
    jd_context *c = ctx_of(ctx);
    jd_press_key(c, (char)key);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeBackspace(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)thiz;
    jd_context *c = ctx_of(ctx);
    jd_backspace(c);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeReset(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)thiz;
    jd_context *c = ctx_of(ctx);
    jd_reset(c);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeSetAnchor(JNIEnv *env, jobject thiz, jlong ctx, jint index) {
    (void)thiz;
    jd_context *c = ctx_of(ctx);
    jd_set_anchor(c, (unsigned int)index);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeState(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)thiz;
    return build_state(env, ctx_of(ctx));
}

// Read up to READ_CHUNK candidates starting at `start` and return them as a
// List<Candidate>. Strings are built only for what was asked for.
JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeReadRange(
    JNIEnv *env, jobject thiz, jlong ctx, jint start, jint count) {
    (void)thiz;
    jd_context *c = ctx_of(ctx);

    unsigned int want = (count < 0) ? 0u : (unsigned int)count;
    if (want > READ_CHUNK) want = READ_CHUNK;

    query_option buf[READ_CHUNK];
    unsigned int n = jd_read_range(c, (unsigned int)start, want, buf, READ_CHUNK);

    jobject list = (*env)->NewObject(env, g_arraylist_cls, g_arraylist_ctor, (jint)n);
    for (unsigned int i = 0; i < n; i++) {
        jstring value = utf8_to_jstring(env, buf[i].value);
        // The hint is inline, NUL-padded bytes — not a pointer — and an empty
        // first byte means "no hint".
        jstring hint = (buf[i].hint[0] == 0)
            ? NULL
            : utf8_to_jstring_n(env, buf[i].hint, JD_HINT_CAP);
        jobject cand = (*env)->NewObject(env, g_candidate_cls, g_candidate_ctor, value, hint);
        (*env)->CallBooleanMethod(env, list, g_arraylist_add, cand);
        (*env)->DeleteLocalRef(env, cand);
        if (value) (*env)->DeleteLocalRef(env, value);
        if (hint)  (*env)->DeleteLocalRef(env, hint);
    }
    return list;
}

// The chunk size the Kotlin side must loop against for larger windows.
JNIEXPORT jint JNICALL
Java_com_hronro_imejd_engine_Engine_nativeReadChunk(JNIEnv *env, jobject thiz) {
    (void)env; (void)thiz;
    return (jint)READ_CHUNK;
}

// ---- native methods of com.hronro.imejd.engine.UserDict (static → jclass) ----

static void throw_oom(JNIEnv *env, const char *what) {
    jclass oom = (*env)->FindClass(env, "java/lang/OutOfMemoryError");
    if (oom != NULL) (*env)->ThrowNew(env, oom, what);
}

// Validate a cached blob exactly as jd_init would (jd_user_dict_check) and
// return {status, entries, source_tag}. The bytes are checked in a copy: a
// byte[] promises no alignment. The engine validates again in jd_init; this
// is how a client reads the tag that says whether the cache is still its
// text's before using it.
JNIEXPORT jlongArray JNICALL
Java_com_hronro_imejd_engine_UserDict_nativeCheck(JNIEnv *env, jclass cls, jbyteArray blob) {
    (void)cls;
    const jsize len = (*env)->GetArrayLength(env, blob);
    void *copy = malloc(len > 0 ? (size_t)len : 1); // malloc's alignment covers the 4 asked for
    if (copy == NULL) {
        throw_oom(env, "user dictionary check buffer");
        return NULL;
    }
    (*env)->GetByteArrayRegion(env, blob, 0, len, (jbyte *)copy);
    jd_user_dict_info info = {0};
    const unsigned int status = jd_user_dict_check(copy, (size_t)len, &info);
    free(copy);
    const jlong verdict[3] = { (jlong)status, (jlong)info.entries, (jlong)info.source_tag };
    jlongArray out = (*env)->NewLongArray(env, 3);
    if (out != NULL) (*env)->SetLongArrayRegion(env, out, 0, 3, verdict);
    return out;
}

// Build a user dictionary from UTF-8 `text` into a buffer of the size
// jd_user_dict_blob_bound asks for, and hand back a two-element Object[]:
//   [0] the blob as a byte[] — null when the build failed as a whole;
//   [1] the report as an int[]: status, line, entries, dropped, shared,
//       invalid, then five ints per note: line, flags, other, builtin, peers.
// Every verdict is libjd's; this only moves it across. Throws
// OutOfMemoryError when the buffer cannot be had.
JNIEXPORT jobjectArray JNICALL
Java_com_hronro_imejd_engine_UserDict_nativeBuild(
    JNIEnv *env, jclass cls, jbyteArray text, jlong source_tag) {
    (void)cls;
    const jsize text_len = (*env)->GetArrayLength(env, text);
    jbyte *bytes = (*env)->GetByteArrayElements(env, text, NULL);
    if (bytes == NULL) return NULL; // OutOfMemoryError pending
    // The library takes a NULL pointer as no text, but never needs one: an
    // empty array still has an address to point at.
    static const char empty = 0;
    const char *phrases = text_len > 0 ? (const char *)bytes : &empty;

    const size_t bound = jd_user_dict_blob_bound(phrases, (size_t)text_len);
    void *buf = malloc(bound > 0 ? bound : 1); // malloc's alignment covers the 4 asked for
    if (buf == NULL) {
        (*env)->ReleaseByteArrayElements(env, text, bytes, JNI_ABORT);
        throw_oom(env, "user dictionary build buffer");
        return NULL;
    }
    size_t blob_len = 0;
    jd_user_dict_report report = {0};
    const unsigned int status = jd_user_dict_build(
        phrases, (size_t)text_len, (unsigned long long)source_tag,
        buf, bound, &blob_len, &report);
    (*env)->ReleaseByteArrayElements(env, text, bytes, JNI_ABORT);

    // Any NULL below has an OutOfMemoryError pending, which the caller sees.
    const unsigned int notes = status == JD_USER_DICT_OK ? report.notes : 0;
    jobjectArray out = NULL;
    jintArray summary = (*env)->NewIntArray(env, (jsize)(6 + 5 * notes));
    if (summary != NULL) {
        const jint head[6] = {
            (jint)report.status, (jint)report.line, (jint)report.entries,
            (jint)report.dropped, (jint)report.shared, (jint)report.invalid,
        };
        (*env)->SetIntArrayRegion(env, summary, 0, 6, head);
        // The notes sit past the blob, ascending by line (see jd.h).
        const jd_user_dict_note *n =
            (const jd_user_dict_note *)((const char *)buf + report.notes_offset);
        for (unsigned int i = 0; i < notes; i++) {
            const jint row[5] = {
                (jint)n[i].line, (jint)n[i].flags, (jint)n[i].other,
                (jint)n[i].builtin, (jint)n[i].peers,
            };
            (*env)->SetIntArrayRegion(env, summary, (jsize)(6 + 5 * i), 5, row);
        }
        jbyteArray blob = NULL;
        if (status == JD_USER_DICT_OK) {
            blob = (*env)->NewByteArray(env, (jsize)blob_len);
            if (blob != NULL) {
                (*env)->SetByteArrayRegion(env, blob, 0, (jsize)blob_len, (const jbyte *)buf);
            }
        }
        if (status != JD_USER_DICT_OK || blob != NULL) {
            out = (*env)->NewObjectArray(env, 2, g_object_cls, NULL);
            if (out != NULL) {
                (*env)->SetObjectArrayElement(env, out, 0, blob);
                (*env)->SetObjectArrayElement(env, out, 1, summary);
            }
        }
    }
    free(buf);
    return out;
}
