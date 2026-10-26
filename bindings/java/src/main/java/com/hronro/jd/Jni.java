// The binding's native methods, all of them, implemented over libjd's C ABI
// (core/include/jd.h) by src/main/c/jd_jni.c.
//
// javac -h writes their C declarations (build.gradle.kts), which jd_jni.c
// includes and is compiled against with -Werror=missing-prototypes: rename a
// method here, or change its types, and the native build fails until
// jd_jni.c follows.
package com.hronro.jd;

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

    /**
     * A new context over the built-in dictionary, merged with {@code userDict}
     * when given: a {@link UserDict}'s blob, copied into native memory the
     * context owns. 0 when that memory cannot be had, or jd_init refuses the
     * blob.
     */
    static native long init(byte @Nullable [] userDict);

    /** Frees a context from {@link #init}, and its copy of the blob. */
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

    /** A cached blob, validated exactly as jd_init would: {status, entries, source tag}. */
    static native long[] userDictCheck(byte[] blob);

    /**
     * Builds a user dictionary from UTF-8 text: {blob, report}. The blob is a
     * byte[], or null when the build failed as a whole; the report is an int[]
     * of status, line, entries, dropped, shared and invalid, then five ints
     * per note: line, flags, other, built-in and peers.
     */
    static native @Nullable Object[] userDictBuild(byte[] text, long sourceTag);
}
