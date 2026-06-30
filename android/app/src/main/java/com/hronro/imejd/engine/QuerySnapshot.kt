// Port of ios/Keyboard/Engine/QuerySnapshot.swift. These objects are built on
// the native side (see app/src/main/cpp/jd_jni.c) with every string deep-copied
// out of the borrowed query_result, so a snapshot is safe to retain across later
// engine calls (load-bearing for candidate pagination).
package com.hronro.imejd.engine

data class Candidate(val value: String, val hint: String?)

data class QuerySnapshot(
    val commit: String?,
    val options: List<Candidate>,
    val optionsCount: Int,
    val totalPages: Int,
    val currentPage: Int,
) {
    val hasCandidates: Boolean get() = options.isNotEmpty()
    val hasCommit: Boolean get() = commit != null
    val isEmpty: Boolean get() = commit == null && options.isEmpty()

    companion object {
        @JvmField
        val EMPTY = QuerySnapshot(null, emptyList(), 0, 0, 0)
    }
}
