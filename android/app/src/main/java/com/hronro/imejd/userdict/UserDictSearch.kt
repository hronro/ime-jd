// Searching the phrase list, for the list screen. Port of
// bindings/swift/UserDictSearch.swift.
package com.hronro.imejd.userdict

import java.util.Locale

/**
 * The rows of a phrase list as one case-folded text, so a search box keeps up
 * with hundreds of thousands of rows: each row is its value, a TAB, its keys
 * and a newline, lowercased, and a query is one substring scan of the whole
 * text with every hit mapped back to its row. Build it when the rows change —
 * or at the first query after — and ask it as often as the query changes.
 * Never matches across fields, a query holding no TAB or newline.
 */
class UserDictSearch(entries: List<UserDictEntry>) {
    private val text: String
    /** Where row `i` starts in [text] is `starts[i]`; one more at the end. */
    private val starts = IntArray(entries.size + 1)

    init {
        val builder = StringBuilder()
        entries.forEachIndexed { index, entry ->
            builder.append(entry.value.lowercase(Locale.ROOT)).append('\t')
                .append(entry.keys.lowercase(Locale.ROOT)).append('\n')
            starts[index + 1] = builder.length
        }
        text = builder.toString()
    }

    /** The rows that contain [query], ascending; every row for an empty query. */
    fun matches(query: String): List<Int> {
        val rows = starts.size - 1
        if (query.isEmpty()) return List(rows) { it }
        val needle = query.lowercase(Locale.ROOT)
        if ('\t' in needle || '\n' in needle) return emptyList()
        val hits = ArrayList<Int>()
        var from = 0
        var row = 0
        while (true) {
            val at = text.indexOf(needle, from)
            if (at < 0) break
            while (starts[row + 1] <= at) row++
            hits.add(row)
            // One hit per row: go on from the next one.
            from = starts[row + 1]
        }
        return hits
    }
}
