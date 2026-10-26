// JNI bridge over libjd's C ABI (see ../../../../../core/include/jd.h): the
// native methods of com.hronro.jd.Jni, which declares every one of them.
//
// Unlike the Rust and Swift bindings — which can hand out libjd's immortal blob
// pointers directly — JNI has to materialize JVM objects, so this layer is the
// one place a copy is unavoidable. It therefore copies only what the caller
// asks for: `readRange` builds Strings for exactly the requested window,
// so a candidate strip that has fetched 900 candidates but only shows 9 pays
// for 9 rows' worth of String work at a time.
//
// A user dictionary crosses as plain arrays: `userDictBuild` returns the blob
// as a byte[] and the report as an int[], `userDictCheck` a cached blob's
// verdict as a long[], and `init` copies a blob into memory of its own,
// because jd_init reads the blob in place for the context's whole lifetime and
// a JVM array can move. The only classes built here are EngineState and
// Candidate (see JNI_OnLoad).
//
// The functions' names and types come from com_hronro_jd_Jni.h, which javac -h
// writes from Jni.java. Both native builds compile this file against it with
// -Werror=missing-prototypes, so a function that no longer matches its Java
// declaration fails the build, not the first call:
//   - android/scripts/build-libjd.sh, with the NDK clang, per Android ABI;
//   - scripts/build-host.sh, with zig cc, for the machine running the tests.
// Both link against the *dynamic* libjd: the static archive uses local-exec
// TLS relocations that a linker rejects in a shared object.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include "jd.h"
#include "com_hronro_jd_Jni.h"

// How many candidates one native read pulls across the JNI boundary at a time.
// The Java side loops for larger windows.
#define READ_CHUNK 64

// Cached classes/methods (global refs live for the process). Populated in JNI_OnLoad.
static jclass    g_state_cls;
static jmethodID g_state_ctor;      // (Ljava/lang/String;II)V
static jclass    g_candidate_cls;
static jmethodID g_candidate_ctor;  // (Ljava/lang/String;Ljava/lang/String;)V
static jclass    g_arraylist_cls;
static jmethodID g_arraylist_ctor;  // (I)V
static jmethodID g_arraylist_add;   // (Ljava/lang/Object;)Z
static jclass    g_object_cls;      // java/lang/Object, for userDictBuild's pair

// Fails the library load with an UnsatisfiedLinkError saying `why`. ART swaps
// whatever is pending for a generic "JNI_ERR returned from JNI_OnLoad", so an
// exception a failed lookup left (NoClassDefFoundError, NoSuchMethodError) is
// printed first, to stderr or, on Android, logcat.
static jint fail_load(JNIEnv *env, const char *why) {
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env); // and clears it
    jclass error = (*env)->FindClass(env, "java/lang/UnsatisfiedLinkError");
    if (error != NULL) (*env)->ThrowNew(env, error, why);
    return JNI_ERR;
}

// A global reference to class `name`, or NULL with NoClassDefFoundError pending.
static jclass global_class(JNIEnv *env, const char *name) {
    jclass local = (*env)->FindClass(env, name);
    if (local == NULL) return NULL;
    jclass global = (jclass)(*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    return global;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    // Every class instantiated from C here must keep its name AND constructor
    // through R8: see ../resources/META-INF/proguard/jd.pro. R8 cannot see
    // these references, and it silently ignores keep rules whose class no
    // longer exists, so renaming a class on the Java side without updating
    // both this file and the rule ships a release whose library fails to load
    // here (v0.5.0 of the Android app crashed on its first popup that way).
    static const char missing[] =
        "jd_jni: a class or method it builds with is missing (renamed without "
        "updating jd_jni.c, or stripped by R8: see META-INF/proguard/jd.pro)";
    g_state_cls = global_class(env, "com/hronro/jd/EngineState");
    if (g_state_cls == NULL) return fail_load(env, missing);
    g_state_ctor = (*env)->GetMethodID(env, g_state_cls, "<init>",
        "(Ljava/lang/String;II)V");
    if (g_state_ctor == NULL) return fail_load(env, missing);

    g_candidate_cls = global_class(env, "com/hronro/jd/Candidate");
    if (g_candidate_cls == NULL) return fail_load(env, missing);
    g_candidate_ctor = (*env)->GetMethodID(env, g_candidate_cls, "<init>",
        "(Ljava/lang/String;Ljava/lang/String;)V");
    if (g_candidate_ctor == NULL) return fail_load(env, missing);

    g_arraylist_cls = global_class(env, "java/util/ArrayList");
    if (g_arraylist_cls == NULL) return fail_load(env, missing);
    g_arraylist_ctor = (*env)->GetMethodID(env, g_arraylist_cls, "<init>", "(I)V");
    if (g_arraylist_ctor == NULL) return fail_load(env, missing);
    g_arraylist_add  = (*env)->GetMethodID(env, g_arraylist_cls, "add", "(Ljava/lang/Object;)Z");
    if (g_arraylist_add == NULL) return fail_load(env, missing);

    g_object_cls = global_class(env, "java/lang/Object");
    if (g_object_cls == NULL) return fail_load(env, missing);

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
        return fail_load(env, "jd_jni: libjd's struct layout or limits differ from jd.h");
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

// ---- the engine: Engine's half of Jni ----

// What Engine holds as its handle: the context, and the copy of the
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
// that userDictBuild made, or userDictCheck passed, never is.
JNIEXPORT jlong JNICALL
Java_com_hronro_jd_Jni_init(JNIEnv *env, jclass cls, jbyteArray user_dict) {
    (void)cls;
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
Java_com_hronro_jd_Jni_deinit(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    engine_t *e = (engine_t *)(intptr_t)handle;
    jd_deinit(e->ctx);
    free(e->blob); // only now: the context read it until jd_deinit
    free(e);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jd_Jni_pressKey(JNIEnv *env, jclass cls, jlong handle, jbyte key) {
    (void)cls;
    jd_context *c = ctx_of(handle);
    jd_press_key(c, (char)key);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jd_Jni_backspace(JNIEnv *env, jclass cls, jlong handle) {
    (void)cls;
    jd_context *c = ctx_of(handle);
    jd_backspace(c);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jd_Jni_reset(JNIEnv *env, jclass cls, jlong handle) {
    (void)cls;
    jd_context *c = ctx_of(handle);
    jd_reset(c);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jd_Jni_setAnchor(JNIEnv *env, jclass cls, jlong handle, jint index) {
    (void)cls;
    jd_context *c = ctx_of(handle);
    jd_set_anchor(c, (unsigned int)index);
    return build_state(env, c);
}

JNIEXPORT jobject JNICALL
Java_com_hronro_jd_Jni_state(JNIEnv *env, jclass cls, jlong handle) {
    (void)cls;
    return build_state(env, ctx_of(handle));
}

// Read up to READ_CHUNK candidates starting at `start` and return them as a
// List<Candidate>. Strings are built only for what was asked for.
JNIEXPORT jobject JNICALL
Java_com_hronro_jd_Jni_readRange(
    JNIEnv *env, jclass cls, jlong handle, jint start, jint count) {
    (void)cls;
    jd_context *c = ctx_of(handle);

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

// The chunk size the Java side must loop against for larger windows.
JNIEXPORT jint JNICALL
Java_com_hronro_jd_Jni_readChunk(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    return (jint)READ_CHUNK;
}

// ---- the user dictionary: UserDict's half of Jni ----

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
Java_com_hronro_jd_Jni_userDictCheck(JNIEnv *env, jclass cls, jbyteArray blob) {
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
Java_com_hronro_jd_Jni_userDictBuild(
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
