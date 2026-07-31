// JNI bridge over libjd's C ABI (see ../../../../../core/include/jd.h).
//
// Unlike the Rust and Swift bindings — which can hand out libjd's immortal blob
// pointers directly — JNI has to materialize JVM objects, so this layer is the
// one place a copy is unavoidable. It therefore copies only what the caller
// asks for: `nativeReadRange` builds Strings for exactly the requested window,
// so a candidate strip that has fetched 900 candidates but only shows 9 pays
// for 9 rows' worth of String work at a time.
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

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

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

    // This file reads libjd's structs through the hand-written jd.h, so a
    // drift between the header and the compiled library would corrupt memory
    // with no diagnostic. Refuse to load instead.
    if (jd_abi_layout(JD_ABI_SIZEOF_STATE) != sizeof(jd_state) ||
        jd_abi_layout(JD_ABI_SIZEOF_OPTION) != sizeof(query_option) ||
        jd_abi_layout(JD_ABI_HINT_CAP) != JD_HINT_CAP) {
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

JNIEXPORT jlong JNICALL
Java_com_hronro_imejd_engine_Engine_nativeInit(JNIEnv *env, jobject thiz) {
    (void)env; (void)thiz;
    return (jlong)(intptr_t)jd_init();
}

JNIEXPORT void JNICALL
Java_com_hronro_imejd_engine_Engine_nativeDeinit(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)env; (void)thiz;
    jd_deinit((jd_context *)(intptr_t)ctx);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativePressKey(JNIEnv *env, jobject thiz, jlong ctx, jbyte key) {
    (void)thiz;
    jd_context *c = (jd_context *)(intptr_t)ctx;
    jd_press_key(c, (char)key);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeBackspace(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)thiz;
    jd_context *c = (jd_context *)(intptr_t)ctx;
    jd_backspace(c);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeReset(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)thiz;
    jd_context *c = (jd_context *)(intptr_t)ctx;
    jd_reset(c);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeSetAnchor(JNIEnv *env, jobject thiz, jlong ctx, jint index) {
    (void)thiz;
    jd_context *c = (jd_context *)(intptr_t)ctx;
    jd_set_anchor(c, (unsigned int)index);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeState(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)thiz;
    return build_state(env, (jd_context *)(intptr_t)ctx);
}

// Read up to READ_CHUNK candidates starting at `start` and return them as a
// List<Candidate>. Strings are built only for what was asked for.
JNIEXPORT jobject JNICALL
Java_com_hronro_imejd_engine_Engine_nativeReadRange(
    JNIEnv *env, jobject thiz, jlong ctx, jint start, jint count) {
    (void)thiz;
    jd_context *c = (jd_context *)(intptr_t)ctx;

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
