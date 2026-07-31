// Port of bindings/swift/Engine.swift — a thin FFI wrapper over libjd.
//
// Candidates are addressed by flat index, not by page. [readRange] is a pure
// read: it never changes what the engine's automatic commits resolve to, so a
// candidate strip can prefetch as far ahead as it likes. Tell the engine what
// the user actually sees with [setAnchor].
//
// Thread-safety mirrors libjd's contract: a single context must not be used
// from multiple threads concurrently. All calls here come from the IME's main
// thread, so no locking is needed.
package com.hronro.imejd.engine

import java.io.Closeable

class Engine : Closeable {
    // jd_init returns NULL on allocation failure; fail fast with a clear
    // message instead of passing a 0 handle into the native pointer casts.
    private var ctx: Long = run {
        val handle = nativeInit()
        check(handle != 0L) { "jd_init failed (allocation failure)" }
        handle
    }

    /** How many candidates one native call can return; [readRange] loops. */
    private val readChunk: Int = nativeReadChunk()

    // close() zeroes ctx; passing that through JNI would hand libjd a NULL
    // context and segfault the IME process. Fail with a clear error instead,
    // matching the JS binding's disposed poisoning.
    private fun requireCtx(): Long = ctx.also { check(it != 0L) { "Engine is closed" } }

    /** Feed one keystroke and return the resulting state. */
    fun pressKey(byte: Byte): EngineState = nativePressKey(requireCtx(), byte)

    /**
     * Undo the most recent trie descent, or close a punctuation window.
     * Never produces a commit.
     */
    fun backspace(): EngineState = nativeBackspace(requireCtx())

    /** Drop the in-flight composition and any recorded commit. */
    fun reset(): EngineState = nativeReset(requireCtx())

    /**
     * Point the anchor at candidate [index], so the engine's automatic commits
     * follow what the user is looking at. Out-of-range indices are ignored.
     */
    fun setAnchor(index: Int): EngineState = nativeSetAnchor(requireCtx(), index)

    /** The engine's current state, without touching it. */
    val state: EngineState get() = nativeState(requireCtx())

    /**
     * Read the candidates at `[start, start + count)`. Returns fewer than
     * [count] at the end of the list, and none when nothing is in flight.
     *
     * A pure read — it never moves the anchor, so prefetch freely.
     */
    fun readRange(start: Int, count: Int): List<Candidate> {
        if (count <= 0) return emptyList()
        val handle = requireCtx()
        val out = ArrayList<Candidate>(count)
        var at = start
        while (out.size < count) {
            val want = minOf(count - out.size, readChunk)
            val chunk = nativeReadRange(handle, at, want)
            if (chunk.isEmpty()) break
            out.addAll(chunk)
            at += chunk.size
            if (chunk.size < want) break // hit the end of the list
        }
        return out
    }

    override fun close() {
        if (ctx != 0L) {
            nativeDeinit(ctx)
            ctx = 0L
        }
    }

    private external fun nativeInit(): Long
    private external fun nativeDeinit(ctx: Long)
    private external fun nativePressKey(ctx: Long, key: Byte): EngineState
    private external fun nativeBackspace(ctx: Long): EngineState
    private external fun nativeReset(ctx: Long): EngineState
    private external fun nativeSetAnchor(ctx: Long, index: Int): EngineState
    private external fun nativeState(ctx: Long): EngineState
    private external fun nativeReadRange(ctx: Long, start: Int, count: Int): List<Candidate>
    private external fun nativeReadChunk(): Int

    companion object {
        init {
            // Load ONLY the shim. Its DT_NEEDED pulls in libjd.so together with
            // libc.so as one load group, so libjd.so's libc references (e.g.
            // getauxval) resolve. Loading libjd.so on its own would fail — being
            // libc-free, it declares no NEEDED libc.so to resolve those against.
            //
            // JNI_OnLoad also verifies libjd's ABI layout against jd.h and
            // fails the load on a mismatch.
            System.loadLibrary("jdjni")
        }
    }
}
