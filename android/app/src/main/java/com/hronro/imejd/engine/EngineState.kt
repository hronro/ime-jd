// Value types over libjd's C ABI, mirroring bindings/swift/Candidate.swift.
// These are built on the native side (see app/src/main/cpp/jd_jni.c). JNI has to
// materialize JVM objects, so unlike the Rust and Swift bindings this is the one
// place a copy is unavoidable — which is why `Engine.readRange` builds Strings
// only for the window that was asked for.
package com.hronro.imejd.engine

/** One candidate: the committable text plus an optional remaining-keys hint. */
data class Candidate(val value: String, val hint: String?)

/**
 * What the engine holds after an operation.
 *
 * [commit] is the last operation's committed text, already joined from the
 * ABI's segments. [optionsCount] is the total number of candidates in flight;
 * read them with [Engine.readRange]. [anchorIndex] is the candidate the
 * engine's own automatic commits resolve against — space and the literal-byte
 * fallbacks take it, `;` takes the next one.
 */
data class EngineState(
    val commit: String?,
    val optionsCount: Int,
    val anchorIndex: Int,
) {
    val isComposing: Boolean get() = optionsCount > 0
    val hasCommit: Boolean get() = commit != null
    val isEmpty: Boolean get() = commit == null && optionsCount == 0

    companion object {
        @JvmField
        val EMPTY = EngineState(null, 0, 0)
    }
}
