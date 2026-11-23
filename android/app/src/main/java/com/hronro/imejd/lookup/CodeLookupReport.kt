// 编码反查's wording for one query: libjd's codes for it (Engine.lookupCodes),
// worded for the user. Port of bindings/swift/CodeLookupReport.swift — the
// same notes, the same messages and the same trimming as the macOS and iOS
// clients.
package com.hronro.imejd.lookup

import com.hronro.jd.Code

class CodeLookupReport private constructor(query: String, codes: List<Code>, scope: Scope?, unavailable: String?) {
    /** Which dictionaries a lookup searched — what the keyboard types from. */
    enum class Scope {
        /** The built-in dictionary alone: the user's phrases are off. */
        BUILT_IN,

        /** The built-in dictionary and the user's phrases. */
        BUILT_IN_AND_USER,

        /** The user's phrases alone: the built-in dictionary is off. */
        USER_ONLY,
    }

    /** libjd's [codes] for [query], from the dictionaries [scope] names. */
    constructor(query: String, codes: List<Code>, scope: Scope) : this(query, codes, scope, null)

    /** Nothing could be looked up: the user's phrases alone were to be searched, and cannot be had, for the reason [why]. */
    constructor(query: String, why: String) : this(query, emptyList(), null, why)

    /** One code: the keys, and what sets it apart, if anything. */
    data class Line(
        val keys: String,
        /**
         * Which candidate the word is on this code when it is not the first,
         * and whether the code is the user's (自造词); null when neither
         * applies.
         */
        val note: String?,
    )

    /** 「着」的编码, or 没有找到「…」. */
    val title: String

    /** The codes, in libjd's order — shortest first; empty when not found. */
    val lines: List<Line>

    /** Why nothing was found; null when something was. */
    val message: String?

    val found: Boolean get() = lines.isNotEmpty()

    init {
        // On a code where the word is the first candidate the code stands
        // alone; any other says which candidate the word is there. Nothing
        // says which key commits it: that is the engine's business, and it
        // has changed before.
        val word = shown(query)
        if (codes.isEmpty()) {
            title = "没有找到「$word」"
            lines = emptyList()
            message = unavailable ?: when (scope) {
                Scope.BUILT_IN_AND_USER -> "内置词库和用户自造词中都没有这个词。"
                Scope.USER_ONLY -> "用户自造词中没有这个词。内置词库已忽略，不在查询范围内。"
                Scope.BUILT_IN, null -> "内置词库中没有这个词。用户自造词未启用，不在查询范围内。"
            }
        } else {
            title = "「$word」的编码"
            lines = codes.map { code ->
                val notes = ArrayList<String>(2)
                if (code.index() > 0) notes.add("第 ${code.index() + 1} 个候选")
                if (code.user()) notes.add("自造词")
                Line(code.keys(), notes.takeIf { it.isNotEmpty() }?.joinToString("，"))
            }
            message = null
        }
    }

    companion object {
        /**
         * The query as the engine should see it. A pasted word often carries
         * a line break or spaces at its ends; dropping spaces, TABs, CRs and
         * LFs there never loses a match, because no phrase starts or ends
         * with one (the table format trims spaces, and control bytes are not
         * allowed in a phrase). U+3000 and other spaces stay: a phrase may
         * end with one.
         */
        fun query(input: String): String = input.trim { it == ' ' || it == '\t' || it == '\r' || it == '\n' }

        /** The query as a title quotes it: a long paste is cut short. */
        private fun shown(query: String): String {
            // Counted in code points, not UTF-16 units, so a supplementary-
            // plane character is never split. (Swift counts grapheme
            // clusters; the two agree on Chinese text.)
            val limit = 20
            val count = query.codePointCount(0, query.length)
            return if (count > limit) query.substring(0, query.offsetByCodePoints(0, limit)) + "…" else query
        }
    }
}
