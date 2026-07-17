// Port of ios/Keyboard/Engine/Engine.swift — a thin FFI wrapper over libjd.
// The native methods (jd_jni.c) return fully-owned QuerySnapshot objects, so
// there are no borrowed-pointer lifetimes to manage on the Kotlin side.
//
// Thread-safety mirrors libjd's contract: a single context must not be used
// from multiple threads concurrently. All calls here come from the IME's main
// thread, so no locking is needed.
package com.hronro.imejd.engine

import java.io.Closeable

class Engine(private val pageSize: Byte = 9) : Closeable {
    // The engine rejects a zero page size (its paginators divide by it) and
    // returns NULL on allocation failure; fail fast with a clear message
    // instead of passing a 0 handle into the native pointer casts.
    private var ctx: Long = run {
        require(pageSize >= 1) { "Engine pageSize must be >= 1" }
        val handle = nativeInit(pageSize)
        check(handle != 0L) { "jd_init failed (allocation failure)" }
        handle
    }

    // close() zeroes ctx; passing that through JNI would hand libjd a NULL
    // context and segfault the IME process. Fail with a clear error instead,
    // matching the JS binding's disposed poisoning.
    private fun requireCtx(): Long = ctx.also { check(it != 0L) { "Engine is closed" } }

    fun pressKey(byte: Byte): QuerySnapshot = nativePressKey(requireCtx(), byte, pageSize)
    fun backspace(): QuerySnapshot = nativeBackspace(requireCtx(), pageSize)
    fun nextPage(): QuerySnapshot = nativeNextPage(requireCtx(), pageSize)
    fun prevPage(): QuerySnapshot = nativePrevPage(requireCtx(), pageSize)
    fun jumpToPage(page: Int): QuerySnapshot = nativeJumpToPage(requireCtx(), page, pageSize)
    fun reset() = nativeReset(requireCtx())

    override fun close() {
        if (ctx != 0L) {
            nativeDeinit(ctx)
            ctx = 0L
        }
    }

    private external fun nativeInit(pageSize: Byte): Long
    private external fun nativeDeinit(ctx: Long)
    private external fun nativePressKey(ctx: Long, key: Byte, pageSize: Byte): QuerySnapshot
    private external fun nativeBackspace(ctx: Long, pageSize: Byte): QuerySnapshot
    private external fun nativeNextPage(ctx: Long, pageSize: Byte): QuerySnapshot
    private external fun nativePrevPage(ctx: Long, pageSize: Byte): QuerySnapshot
    private external fun nativeJumpToPage(ctx: Long, page: Int, pageSize: Byte): QuerySnapshot
    private external fun nativeReset(ctx: Long)

    companion object {
        init {
            // Load ONLY the shim. Its DT_NEEDED pulls in libjd.so together with
            // libc.so as one load group, so libjd.so's libc references (e.g.
            // getauxval) resolve. Loading libjd.so on its own would fail — being
            // libc-free, it declares no NEEDED libc.so to resolve those against.
            System.loadLibrary("jdjni")
        }
    }
}
