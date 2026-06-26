// JNI bridge over libjd's C ABI (see ../../../../../core/include/jd.h).
//
// Mirrors the role of ios/Keyboard/Engine/QuerySnapshot.swift's `copy`: every
// borrowed pointer in a `query_result` is deep-copied into owned Java objects
// here, so nothing borrowed ever escapes to Kotlin. The Kotlin `Engine` calls
// these `native*` methods and gets back fully-owned QuerySnapshot objects.
//
// Compiled with the NDK clang and linked against the *dynamic* libjd.so (the
// static archive uses local-exec TLS relocations that ld rejects in a shared
// object). See android/scripts/build-libjd.sh.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include "jd.h"

// Cached classes/methods (global refs live for the process). Populated in JNI_OnLoad.
static jclass    g_snapshot_cls;
static jmethodID g_snapshot_ctor;   // (Ljava/lang/String;Ljava/util/List;III)V
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
    c = (*env)->FindClass(env, "com/hronro/jdime/engine/QuerySnapshot");
    g_snapshot_cls = (jclass)(*env)->NewGlobalRef(env, c);
    g_snapshot_ctor = (*env)->GetMethodID(env, g_snapshot_cls, "<init>",
        "(Ljava/lang/String;Ljava/util/List;III)V");

    c = (*env)->FindClass(env, "com/hronro/jdime/engine/Candidate");
    g_candidate_cls = (jclass)(*env)->NewGlobalRef(env, c);
    g_candidate_ctor = (*env)->GetMethodID(env, g_candidate_cls, "<init>",
        "(Ljava/lang/String;Ljava/lang/String;)V");

    c = (*env)->FindClass(env, "java/util/ArrayList");
    g_arraylist_cls = (jclass)(*env)->NewGlobalRef(env, c);
    g_arraylist_ctor = (*env)->GetMethodID(env, g_arraylist_cls, "<init>", "(I)V");
    g_arraylist_add  = (*env)->GetMethodID(env, g_arraylist_cls, "add", "(Ljava/lang/Object;)Z");

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

// UTF-8 C string -> jstring (via UTF-16). Returns NULL for a NULL input.
static jstring utf8_to_jstring(JNIEnv *env, const char *s) {
    if (s == NULL) return NULL;

    // Pass 1: count UTF-16 code units.
    size_t n16 = 0;
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        uint32_t cp = utf8_next(&p);
        n16 += (cp > 0xFFFF) ? 2 : 1;
    }

    if (n16 == 0) return (*env)->NewString(env, NULL, 0);

    jchar *buf = (jchar *)malloc(n16 * sizeof(jchar));
    if (buf == NULL) return NULL;

    // Pass 2: emit UTF-16 (surrogate pairs for supplementary code points).
    size_t j = 0;
    p = (const unsigned char *)s;
    while (*p) {
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

// Build a QuerySnapshot from a query_result, copying every string out. The
// visible-options count mirrors QuerySnapshot.copy in the Swift port.
static jobject build_snapshot(JNIEnv *env, query_result r, unsigned char page_size) {
    jstring commit = utf8_to_jstring(env, r.commit);
    jobject list = (*env)->NewObject(env, g_arraylist_cls, g_arraylist_ctor, (jint)page_size);

    if (r.options != NULL && r.options_count > 0) {
        unsigned int visible;
        if (r.current_page == r.total_pages) {
            unsigned int rem = r.options_count % page_size;
            visible = (rem == 0) ? page_size : rem;
        } else {
            visible = page_size;
        }
        for (unsigned int i = 0; i < visible; i++) {
            query_option opt = r.options[i];
            jstring value = utf8_to_jstring(env, opt.value);
            jstring hint  = utf8_to_jstring(env, opt.hint);
            jobject cand = (*env)->NewObject(env, g_candidate_cls, g_candidate_ctor, value, hint);
            (*env)->CallBooleanMethod(env, list, g_arraylist_add, cand);
            (*env)->DeleteLocalRef(env, cand);
            if (value) (*env)->DeleteLocalRef(env, value);
            if (hint)  (*env)->DeleteLocalRef(env, hint);
        }
    }

    jobject snapshot = (*env)->NewObject(env, g_snapshot_cls, g_snapshot_ctor,
        commit, list, (jint)r.options_count, (jint)r.total_pages, (jint)r.current_page);
    if (commit) (*env)->DeleteLocalRef(env, commit);
    (*env)->DeleteLocalRef(env, list);
    return snapshot;
}

// ---- native methods of com.hronro.jdime.engine.Engine (member fns → jobject thiz) ----

JNIEXPORT jlong JNICALL
Java_com_hronro_jdime_engine_Engine_nativeInit(JNIEnv *env, jobject thiz, jbyte page_size) {
    (void)env; (void)thiz;
    return (jlong)(intptr_t)jd_init((unsigned char)page_size);
}

JNIEXPORT void JNICALL
Java_com_hronro_jdime_engine_Engine_nativeDeinit(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)env; (void)thiz;
    jd_deinit((jd_context *)(intptr_t)ctx);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jdime_engine_Engine_nativePressKey(JNIEnv *env, jobject thiz, jlong ctx, jbyte key, jbyte page_size) {
    (void)thiz;
    query_result r = jd_press_key((jd_context *)(intptr_t)ctx, (char)key);
    return build_snapshot(env, r, (unsigned char)page_size);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jdime_engine_Engine_nativeBackspace(JNIEnv *env, jobject thiz, jlong ctx, jbyte page_size) {
    (void)thiz;
    query_result r = jd_backspace((jd_context *)(intptr_t)ctx);
    return build_snapshot(env, r, (unsigned char)page_size);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jdime_engine_Engine_nativeNextPage(JNIEnv *env, jobject thiz, jlong ctx, jbyte page_size) {
    (void)thiz;
    query_result r = jd_next_page((jd_context *)(intptr_t)ctx);
    return build_snapshot(env, r, (unsigned char)page_size);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jdime_engine_Engine_nativePrevPage(JNIEnv *env, jobject thiz, jlong ctx, jbyte page_size) {
    (void)thiz;
    query_result r = jd_prev_page((jd_context *)(intptr_t)ctx);
    return build_snapshot(env, r, (unsigned char)page_size);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jdime_engine_Engine_nativeJumpToPage(JNIEnv *env, jobject thiz, jlong ctx, jint page, jbyte page_size) {
    (void)thiz;
    query_result r = jd_jump_to_page((jd_context *)(intptr_t)ctx, (unsigned int)page);
    return build_snapshot(env, r, (unsigned char)page_size);
}

JNIEXPORT void JNICALL
Java_com_hronro_jdime_engine_Engine_nativeReset(JNIEnv *env, jobject thiz, jlong ctx) {
    (void)env; (void)thiz;
    jd_reset((jd_context *)(intptr_t)ctx);
}
