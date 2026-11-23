// The binding's native methods, all of them, implemented over libjd's C ABI
// (core/include/jd.h) by src/main/c/jd_jni.c.
//
// javac -h writes their C declarations (build.gradle.kts), which jd_jni.c
// includes and is compiled against with -Werror=missing-prototypes: rename a
// method here, or change its types, and the native build fails until
// jd_jni.c follows.
package com.hronro.jd;

import java.nio.ByteBuffer;
import java.util.List;
import org.jspecify.annotations.Nullable;

final class Jni {
    static {
        // Load ONLY the shim. Its DT_NEEDED pulls in libjd together with libc
        // as one load group, so libjd's libc references (getauxval, on
        // Android) resolve; libjd, being libc-free, declares no NEEDED libc of
        // its own to resolve them against when loaded alone.
        //
        // JNI_OnLoad checks libjd's struct layout and limits against jd.h and
        // finds the classes it builds, and fails the load otherwise.
        System.loadLibrary("jdjni");
    }

    private Jni() {}

    // A blob argument is a byte[], copied where libjd needs it to stay put,
    // or a direct ByteBuffer — a mapped file — read where it is.

    /**
     * A new context typing from {@code dict} — null for the embedded
     * dictionary — merged with {@code userDict} when given. A blob in a
     * direct buffer is read in place: the caller keeps the buffer reachable
     * until {@link #deinit}. 0 when jd_init refuses (see {@link Engine}).
     */
    static native long init(@Nullable Object dict, @Nullable Object userDict);

    /** Frees a context from {@link #init}, and its copies of the blobs. */
    static native void deinit(long handle);

    static native EngineState pressKey(long handle, byte key);

    static native EngineState backspace(long handle);

    static native EngineState reset(long handle);

    static native EngineState setAnchor(long handle, int index);

    static native EngineState state(long handle);

    /** Up to {@link #readChunk} candidates from {@code start}, Strings built for exactly those. */
    static native List<Candidate> readRange(long handle, int start, int count);

    /** The most candidates one {@link #readRange} returns. */
    static native int readChunk();

    /**
     * The codes UTF-8 {@code value} is typed with, in candidate order: {keys,
     * details}. The keys are a String[]; the details an int[] of two ints per
     * code, its candidate index and its JD_CODE_* flags.
     */
    static native Object[] lookupCodes(long handle, byte[] value);

    /** A cached dictionary blob, validated exactly as jd_init would: {status, entries, source tag}. */
    static native long[] dictCheck(Object blob);

    /** A cached user-dictionary blob on {@code dict}, validated exactly as jd_init would. */
    static native long[] userDictCheck(@Nullable Object dict, Object blob);

    /** libjd's content hash, jd_user_dict_hash. */
    static native long userDictHash(byte[] bytes);

    /** {@link #userDictHash} over a direct buffer, in place. */
    static native long userDictHashDirect(ByteBuffer bytes);

    /** Entries in the embedded dictionary: 0 in libjd-engine. */
    static native int builtinEntries();

    /**
     * Builds a dictionary from UTF-8 text: {blob, report}. The blob is a
     * byte[], or null when the build failed as a whole; the report is an int[]
     * of status, line, entries, dropped, shared and invalid, then five ints
     * per note: line, flags, other, built-in and peers.
     */
    static native @Nullable Object[] dictBuild(byte[] text, long sourceTag);

    /** {@link #dictBuild} for a user dictionary on {@code dict} (null for the embedded one). */
    static native @Nullable Object[] userDictBuild(@Nullable Object dict, byte[] text, long sourceTag);
}
