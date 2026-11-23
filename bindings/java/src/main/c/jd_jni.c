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
// A dictionary and a user dictionary cross as plain arrays: `dictBuild` and
// `userDictBuild` return the blob as a byte[] and the report as an int[], and
// `dictCheck` and `userDictCheck` a cached blob's verdict as a long[]. A blob
// argument is a byte[] or a direct ByteBuffer — a mapped cache file — (see
// `blob_arg`). `init` copies a byte[] into memory of its own, because jd_init
// reads a blob in place for the context's whole lifetime and a JVM array can
// move; a direct buffer does not move, so it is read where it is, and the
// Java side keeps the buffer reachable for as long as an engine uses it.
// `lookupCodes` returns plain arrays too. The only classes built here are
// EngineState and Candidate (see JNI_OnLoad).
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
static jclass    g_object_cls;      // java/lang/Object, for userDictBuild's and lookupCodes' pairs
static jclass    g_string_cls;      // java/lang/String, for lookupCodes' keys
static jclass    g_bytes_cls;       // byte[], to tell a blob in an array from one in a buffer

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
    g_string_cls = global_class(env, "java/lang/String");
    if (g_string_cls == NULL) return fail_load(env, missing);
    g_bytes_cls = global_class(env, "[B");
    if (g_bytes_cls == NULL) return fail_load(env, missing);

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
        jd_abi_layout(JD_ABI_USER_DICT_VALUE_MAX) != JD_USER_DICT_VALUE_MAX ||
        jd_abi_layout(JD_ABI_USER_DICT_TEXT_MAX) != JD_USER_DICT_TEXT_MAX ||
        jd_abi_layout(JD_ABI_DICT_MAX_ENTRIES) != JD_DICT_MAX_ENTRIES ||
        jd_abi_layout(JD_ABI_DICT_VALUE_MAX) != JD_DICT_VALUE_MAX ||
        jd_abi_layout(JD_ABI_DICT_TEXT_MAX) != JD_DICT_TEXT_MAX ||
        jd_abi_layout(JD_ABI_SIZEOF_CODE) != sizeof(jd_code) ||
        jd_abi_layout(JD_ABI_CODE_CAP) != JD_CODE_CAP) {
        return fail_load(env, "jd_jni: libjd's struct layout or limits differ from jd.h");
    }

    return JNI_VERSION_1_6;
}

// Every allocation here can fail. A NULL result from a function in this file
// means an exception is pending — OutOfMemoryError, mostly — which the Java
// side throws once the native method returns. Nothing calls JNI again before
// returning, beyond releasing references.
static void throw_oom(JNIEnv *env, const char *what) {
    jclass oom = (*env)->FindClass(env, "java/lang/OutOfMemoryError");
    if (oom != NULL) (*env)->ThrowNew(env, oom, what);
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
// `limit` is given; pass SIZE_MAX to stop at the NUL. An empty string for an
// empty input; NULL, with OutOfMemoryError pending, when memory runs out.
static jstring utf8_to_jstring_n(JNIEnv *env, const char *s, size_t limit) {
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
    if (buf == NULL) {
        throw_oom(env, "string buffer");
        return NULL;
    }

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
        if (joined == NULL) {
            throw_oom(env, "commit buffer");
            return NULL;
        }

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
        if (commit == NULL) return NULL;
    }

    jobject state = (*env)->NewObject(env, g_state_cls, g_state_ctor,
        commit, (jint)s->options_count, (jint)s->anchor_index);
    if (commit) (*env)->DeleteLocalRef(env, commit);
    return state;
}

// ---- the engine: Engine's half of Jni ----

// A blob argument's bytes, for as long as the caller needs them: NULL for a
// null one; a direct ByteBuffer's memory, where it is; a byte[]'s contents,
// copied into `*owned` — malloc's alignment covers the 4 libjd asks for —
// which the caller frees. 0, with an exception pending, when that fails.
static int blob_arg(JNIEnv *env, jobject blob, const void **bytes, size_t *len, void **owned) {
    *bytes = NULL;
    *len = 0;
    *owned = NULL;
    if (blob == NULL) return 1;
    if ((*env)->IsInstanceOf(env, blob, g_bytes_cls)) {
        const jsize n = (*env)->GetArrayLength(env, (jbyteArray)blob);
        void *copy = malloc(n > 0 ? (size_t)n : 1);
        if (copy == NULL) {
            throw_oom(env, "blob copy");
            return 0;
        }
        (*env)->GetByteArrayRegion(env, (jbyteArray)blob, 0, n, (jbyte *)copy);
        *owned = copy;
        *bytes = copy;
        *len = (size_t)n;
        return 1;
    }
    const void *at = (*env)->GetDirectBufferAddress(env, blob);
    const jlong capacity = (*env)->GetDirectBufferCapacity(env, blob);
    if (at == NULL || capacity < 0) {
        jclass iae = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
        if (iae != NULL) (*env)->ThrowNew(env, iae, "not a direct buffer");
        return 0;
    }
    *bytes = at;
    *len = (size_t)capacity;
    return 1;
}

// What Engine holds as its handle: the context, and the copies of the
// dictionary and user-dictionary blobs it was created with (NULL for none,
// and for a blob read in place). jd_init never copies a blob and reads it
// until jd_deinit, so they live here and are freed only after the context.
typedef struct {
    jd_context *ctx;
    void *dict;
    void *user_dict;
} engine_t;

static jd_context *ctx_of(jlong handle) {
    return ((engine_t *)(intptr_t)handle)->ctx;
}

static void free_engine(engine_t *e) {
    free(e->dict);
    free(e->user_dict);
    free(e);
}

// 0 when jd_init refuses: no dictionary in libjd-engine, a user dictionary
// built on another dictionary, or no memory — told apart on the Java side.
// Also 0, with an exception pending, when a blob argument is unusable.
JNIEXPORT jlong JNICALL
Java_com_hronro_jd_Jni_init(JNIEnv *env, jclass cls, jobject dict, jobject user_dict) {
    (void)cls;
    engine_t *e = (engine_t *)calloc(1, sizeof(engine_t));
    if (e == NULL) return 0;
    const void *dict_bytes, *user_bytes;
    size_t dict_len, user_len;
    if (!blob_arg(env, dict, &dict_bytes, &dict_len, &e->dict) ||
        !blob_arg(env, user_dict, &user_bytes, &user_len, &e->user_dict)) {
        free_engine(e);
        return 0;
    }
    e->ctx = jd_init(dict_bytes, dict_len, user_bytes, user_len);
    if (e->ctx == NULL) {
        free_engine(e);
        return 0;
    }
    return (jlong)(intptr_t)e;
}

JNIEXPORT void JNICALL
Java_com_hronro_jd_Jni_deinit(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    engine_t *e = (engine_t *)(intptr_t)handle;
    jd_deinit(e->ctx);
    free_engine(e); // only now: the context read the blobs until jd_deinit
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
    if (list == NULL) return NULL;
    for (unsigned int i = 0; i < n; i++) {
        jstring value = utf8_to_jstring(env, buf[i].value != NULL ? buf[i].value : "");
        if (value == NULL) return NULL;
        // The hint is inline, NUL-padded bytes — not a pointer — and an empty
        // first byte means "no hint".
        jstring hint = NULL;
        if (buf[i].hint[0] != 0) {
            hint = utf8_to_jstring_n(env, buf[i].hint, JD_HINT_CAP);
            if (hint == NULL) return NULL;
        }
        jobject cand = (*env)->NewObject(env, g_candidate_cls, g_candidate_ctor, value, hint);
        if (cand == NULL) return NULL;
        (*env)->CallBooleanMethod(env, list, g_arraylist_add, cand);
        if ((*env)->ExceptionCheck(env)) return NULL;
        (*env)->DeleteLocalRef(env, cand);
        (*env)->DeleteLocalRef(env, value);
        if (hint) (*env)->DeleteLocalRef(env, hint);
    }
    return list;
}

// The chunk size the Java side must loop against for larger windows.
JNIEXPORT jint JNICALL
Java_com_hronro_jd_Jni_readChunk(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    return (jint)READ_CHUNK;
}

// The codes UTF-8 `value` is typed with, as a two-element Object[]:
//   [0] the keys, a String[] (ASCII, so NewStringUTF is exact);
//   [1] an int[] of two ints per code: its candidate index, its JD_CODE_* flags.
// Both in libjd's order. NULL with OutOfMemoryError pending when memory runs out.
JNIEXPORT jobjectArray JNICALL
Java_com_hronro_jd_Jni_lookupCodes(JNIEnv *env, jclass cls, jlong handle, jbyteArray value) {
    (void)cls;
    jd_context *c = ctx_of(handle);
    const jsize value_len = (*env)->GetArrayLength(env, value);
    jbyte *bytes = (*env)->GetByteArrayElements(env, value, NULL);
    if (bytes == NULL) return NULL; // OutOfMemoryError pending

    // No value in the built-in tables has more than a dozen codes; a longer
    // list is answered with its total, so ask once more with room for it.
    jd_code local[16];
    jd_code *codes = local;
    unsigned int n = jd_lookup_codes(c, (const char *)bytes, (size_t)value_len, codes, 16);
    if (n > 16) {
        codes = (jd_code *)malloc((size_t)n * sizeof(jd_code));
        if (codes == NULL) {
            (*env)->ReleaseByteArrayElements(env, value, bytes, JNI_ABORT);
            throw_oom(env, "lookup buffer");
            return NULL;
        }
        n = jd_lookup_codes(c, (const char *)bytes, (size_t)value_len, codes, n);
    }
    (*env)->ReleaseByteArrayElements(env, value, bytes, JNI_ABORT);

    jobjectArray out = NULL;
    jobjectArray keys = (*env)->NewObjectArray(env, (jsize)n, g_string_cls, NULL);
    jintArray details = keys != NULL ? (*env)->NewIntArray(env, (jsize)(2 * n)) : NULL;
    if (details != NULL) {
        unsigned int i = 0;
        for (; i < n; i++) {
            // The inline keys are NUL-padded and at most JD_CODE_CAP - 1 long.
            char z[JD_CODE_CAP + 1];
            for (int k = 0; k < JD_CODE_CAP; k++) z[k] = codes[i].keys[k];
            z[JD_CODE_CAP] = '\0';
            jstring key = (*env)->NewStringUTF(env, z);
            if (key == NULL) break;
            (*env)->SetObjectArrayElement(env, keys, (jsize)i, key);
            (*env)->DeleteLocalRef(env, key);
            const jint row[2] = { (jint)codes[i].index, (jint)codes[i].flags };
            (*env)->SetIntArrayRegion(env, details, (jsize)(2 * i), 2, row);
        }
        if (i == n) {
            out = (*env)->NewObjectArray(env, 2, g_object_cls, NULL);
            if (out != NULL) {
                (*env)->SetObjectArrayElement(env, out, 0, keys);
                (*env)->SetObjectArrayElement(env, out, 1, details);
            }
        }
    }
    if (codes != local) free(codes);
    return out;
}

// ---- the user dictionary: UserDict's half of Jni ----

// A cached blob's verdict, as jd_init would give it: {status, entries,
// source_tag}. The engine validates again in jd_init; this is how a client
// reads the tag that says whether the cache is still its text's before using
// it.
static jlongArray verdict_of(JNIEnv *env, unsigned int status, const jd_user_dict_info *info) {
    const jlong verdict[3] = { (jlong)status, (jlong)info->entries, (jlong)info->source_tag };
    jlongArray out = (*env)->NewLongArray(env, 3);
    if (out != NULL) (*env)->SetLongArrayRegion(env, out, 0, 3, verdict);
    return out;
}

// jd_dict_check on a dictionary blob.
JNIEXPORT jlongArray JNICALL
Java_com_hronro_jd_Jni_dictCheck(JNIEnv *env, jclass cls, jobject blob) {
    (void)cls;
    const void *bytes;
    size_t len;
    void *owned;
    if (!blob_arg(env, blob, &bytes, &len, &owned)) return NULL;
    jd_dict_info info = {0};
    const unsigned int status = jd_dict_check(bytes, len, &info);
    free(owned);
    return verdict_of(env, status, &info);
}

// jd_user_dict_check on a user-dictionary blob, on `dict` (null for the
// embedded dictionary).
JNIEXPORT jlongArray JNICALL
Java_com_hronro_jd_Jni_userDictCheck(JNIEnv *env, jclass cls, jobject dict, jobject blob) {
    (void)cls;
    const void *dict_bytes, *bytes;
    size_t dict_len, len;
    void *dict_owned, *owned;
    if (!blob_arg(env, dict, &dict_bytes, &dict_len, &dict_owned)) return NULL;
    if (!blob_arg(env, blob, &bytes, &len, &owned)) {
        free(dict_owned);
        return NULL;
    }
    jd_user_dict_info info = {0};
    const unsigned int status = jd_user_dict_check(dict_bytes, dict_len, bytes, len, &info);
    free(owned);
    free(dict_owned);
    return verdict_of(env, status, &info);
}

JNIEXPORT jint JNICALL
Java_com_hronro_jd_Jni_builtinEntries(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    return (jint)jd_abi_layout(JD_ABI_BUILTIN_DICT_ENTRIES);
}

// libjd's content hash (jd_user_dict_hash) of a byte[], read in place.
JNIEXPORT jlong JNICALL
Java_com_hronro_jd_Jni_userDictHash(JNIEnv *env, jclass cls, jbyteArray bytes) {
    (void)cls;
    const jsize len = (*env)->GetArrayLength(env, bytes);
    // An empty array may pin to NULL with nothing pending.
    if (len == 0) return (jlong)jd_user_dict_hash(NULL, 0);
    void *pinned = (*env)->GetPrimitiveArrayCritical(env, bytes, NULL);
    if (pinned == NULL) return 0; // OutOfMemoryError pending
    const unsigned long long hash = jd_user_dict_hash(pinned, (size_t)len);
    (*env)->ReleasePrimitiveArrayCritical(env, bytes, pinned, JNI_ABORT);
    return (jlong)hash;
}

// `userDictHash` over a direct buffer: a mapped file, hashed without a read.
JNIEXPORT jlong JNICALL
Java_com_hronro_jd_Jni_userDictHashDirect(JNIEnv *env, jclass cls, jobject bytes) {
    (void)cls;
    const void *at;
    size_t len;
    void *owned;
    // A direct buffer is read in place: `owned` stays NULL.
    if (!blob_arg(env, bytes, &at, &len, &owned)) return 0;
    const unsigned long long hash = jd_user_dict_hash(at, len);
    free(owned);
    return (jlong)hash;
}

// What a build left in `buf` as a two-element Object[]:
//   [0] the blob as a byte[] — null when the build failed as a whole;
//   [1] the report as an int[]: status, line, entries, dropped, shared,
//       invalid, then five ints per note: line, flags, other, builtin, peers.
// Every verdict is libjd's; this only moves it across. NULL, with an
// OutOfMemoryError pending, when the arrays cannot be had.
static jobjectArray build_result(JNIEnv *env, unsigned int status, const jd_user_dict_report *report,
                                 const void *buf, size_t blob_len) {
    const unsigned int notes = status == JD_USER_DICT_OK ? report->notes : 0;
    jobjectArray out = NULL;
    jintArray summary = (*env)->NewIntArray(env, (jsize)(6 + 5 * notes));
    if (summary == NULL) return NULL;
    const jint head[6] = {
        (jint)report->status, (jint)report->line, (jint)report->entries,
        (jint)report->dropped, (jint)report->shared, (jint)report->invalid,
    };
    (*env)->SetIntArrayRegion(env, summary, 0, 6, head);
    // The notes sit past the blob, ascending by line (see jd.h): five
    // unsigned ints each, which is the layout of the int[] they go to, so
    // they cross in one call.
    _Static_assert(sizeof(jd_user_dict_note) == 5 * sizeof(jint), "a note is five ints");
    if (notes > 0) {
        (*env)->SetIntArrayRegion(env, summary, 6, (jsize)(5 * notes),
            (const jint *)((const char *)buf + report->notes_offset));
    }
    jbyteArray blob = NULL;
    if (status == JD_USER_DICT_OK) {
        blob = (*env)->NewByteArray(env, (jsize)blob_len);
        if (blob == NULL) return NULL;
        (*env)->SetByteArrayRegion(env, blob, 0, (jsize)blob_len, (const jbyte *)buf);
    }
    out = (*env)->NewObjectArray(env, 2, g_object_cls, NULL);
    if (out != NULL) {
        (*env)->SetObjectArrayElement(env, out, 0, blob);
        (*env)->SetObjectArrayElement(env, out, 1, summary);
    }
    return out;
}

// A dictionary build — `dict` is NULL — or a user-dictionary build on
// `dict_arg` (null for the embedded dictionary) from UTF-8 `text`, into a
// buffer of the size the bound asks for: see build_result. Throws
// OutOfMemoryError when the buffer cannot be had.
static jobjectArray build(JNIEnv *env, int user, jobject dict_arg, jbyteArray text, jlong source_tag) {
    const void *dict_bytes;
    size_t dict_len;
    void *dict_owned;
    if (!blob_arg(env, dict_arg, &dict_bytes, &dict_len, &dict_owned)) return NULL;
    const jsize text_len = (*env)->GetArrayLength(env, text);
    jbyte *bytes = (*env)->GetByteArrayElements(env, text, NULL);
    if (bytes == NULL) { // OutOfMemoryError pending
        free(dict_owned);
        return NULL;
    }
    // The library takes a NULL pointer as no text, but never needs one: an
    // empty array still has an address to point at.
    static const char empty = 0;
    const char *chars = text_len > 0 ? (const char *)bytes : &empty;

    const size_t bound = user ? jd_user_dict_blob_bound(chars, (size_t)text_len)
                              : jd_dict_blob_bound(chars, (size_t)text_len);
    void *buf = malloc(bound > 0 ? bound : 1); // malloc's alignment covers the 4 asked for
    if (buf == NULL) {
        (*env)->ReleaseByteArrayElements(env, text, bytes, JNI_ABORT);
        free(dict_owned);
        throw_oom(env, "dictionary build buffer");
        return NULL;
    }
    size_t blob_len = 0;
    jd_user_dict_report report = {0};
    const unsigned int status = user
        ? jd_user_dict_build(dict_bytes, dict_len, chars, (size_t)text_len,
                             (unsigned long long)source_tag, buf, bound, &blob_len, &report)
        : jd_dict_build(chars, (size_t)text_len, (unsigned long long)source_tag,
                        buf, bound, &blob_len, &report);
    (*env)->ReleaseByteArrayElements(env, text, bytes, JNI_ABORT);
    free(dict_owned);

    jobjectArray out = build_result(env, status, &report, buf, blob_len);
    free(buf);
    return out;
}

JNIEXPORT jobjectArray JNICALL
Java_com_hronro_jd_Jni_dictBuild(JNIEnv *env, jclass cls, jbyteArray text, jlong source_tag) {
    (void)cls;
    return build(env, 0, NULL, text, source_tag);
}

JNIEXPORT jobjectArray JNICALL
Java_com_hronro_jd_Jni_userDictBuild(JNIEnv *env, jclass cls, jobject dict, jbyteArray text, jlong source_tag) {
    (void)cls;
    return build(env, 1, dict, text, source_tag);
}
