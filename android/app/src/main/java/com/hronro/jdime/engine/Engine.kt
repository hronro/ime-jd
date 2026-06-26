// Port of ios/Keyboard/Engine/Engine.swift — a thin FFI wrapper over libjd.
// The native methods (jd_jni.c) return fully-owned QuerySnapshot objects, so
// there are no borrowed-pointer lifetimes to manage on the Kotlin side.
//
// Thread-safety mirrors libjd's contract: a single context must not be used
// from multiple threads concurrently. All calls here come from the IME's main
// thread, so no locking is needed.
package com.hronro.jdime.engine

import java.io.Closeable

class Engine(private val pageSize: Byte = 9) : Closeable {
    private var ctx: Long = nativeInit(pageSize)

    fun pressKey(byte: Byte): QuerySnapshot = nativePressKey(ctx, byte, pageSize)
    fun backspace(): QuerySnapshot = nativeBackspace(ctx, pageSize)
    fun nextPage(): QuerySnapshot = nativeNextPage(ctx, pageSize)
    fun prevPage(): QuerySnapshot = nativePrevPage(ctx, pageSize)
    fun jumpToPage(page: Int): QuerySnapshot = nativeJumpToPage(ctx, page, pageSize)
    fun reset() = nativeReset(ctx)

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
