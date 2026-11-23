// The engine's verdict on one row of the phrase list: the notes UserDict.build
// leaves, mapped onto the rows by line, with the words the list shows. Port of
// bindings/swift/UserDictProblem.swift — the same mapping and the same words
// as the macOS and iOS lists.
package com.hronro.imejd.userdict

import com.hronro.jd.UserDict
import com.hronro.jd.UserDictNote
import com.hronro.jd.UserDictReport

sealed interface UserDictProblem {
    /** In the file, but libjd skips it: it does not parse. [flags] say why. */
    data class Invalid(val flags: Int) : UserDictProblem

    /** In the file, but libjd drops it: the same phrase as row [ofRow], or (null) as a built-in word. */
    data class Duplicate(val ofRow: Int?) : UserDictProblem

    /**
     * Works, and is listed first — but the code already carries [builtIn]
     * built-in words and/or [peers] other rows, the first of them [otherRow].
     */
    data class SharedCode(val builtIn: Int, val otherRow: Int?, val peers: Int) : UserDictProblem

    val text: String
        get() = when (this) {
            is Invalid -> when {
                (flags and UserDictNote.MALFORMED) != 0 -> "缺少制表符（无编码），不生效"
                (flags and UserDictNote.BAD_KEYS) != 0 ->
                    "编码无效（1 到 ${UserDict.MAX_KEY_LENGTH} 个 a-z，开头可以有 ;），不生效"
                else -> "词无效（不能为空或含控制字符，最长 ${UserDict.MAX_VALUE_BYTES} 字节），不生效"
            }
            is Duplicate -> if (ofRow != null) "与第 ${ofRow + 1} 条重复，不生效" else "与内置词重复，不生效"
            is SharedCode -> {
                // "与 2 个内置词及第 3 条等 2 条同码", or either half alone.
                val parts = ArrayList<String>(2)
                if (builtIn > 0) parts.add(" $builtIn 个内置词")
                if (otherRow != null) {
                    parts.add(if (peers > 1) "第 ${otherRow + 1} 条等 $peers 条" else "第 ${otherRow + 1} 条")
                }
                "与" + parts.joinToString("及") + "同码"
            }
        }

    val isInvalid: Boolean get() = this is Invalid
    val isDuplicate: Boolean get() = this is Duplicate
    val isSharedCode: Boolean get() = this is SharedCode

    companion object {
        /**
         * One verdict per row, from the notes of the build of the text the
         * rows came from; `lines[i]` is row `i`'s 1-based line in that text,
         * ascending, as [UserDictFile.parse] returns them. A null [report] — the text could not be built at all — flags
         * nothing: the engine has no notes on a file it could not read.
         */
        fun forRows(lines: List<Int>, report: UserDictReport?): List<UserDictProblem?> {
            val problems = arrayOfNulls<UserDictProblem>(lines.size)
            if (report == null) return problems.asList()
            // Rows read from a file come ascending by line, and so do the
            // notes: each row's note is found by walking the two together,
            // and a note's other row by a binary search — no table over
            // hundreds of thousands of rows.
            val rowLines = lines.toIntArray()
            for (i in 1 until rowLines.size) {
                require(rowLines[i - 1] < rowLines[i]) { "rows out of line order" }
            }
            var index = 0
            for (note in report.notes) {
                while (index < rowLines.size && rowLines[index] < note.line) index++
                if (index == rowLines.size) break
                if (rowLines[index] != note.line) continue
                val other = rowLines.binarySearch(note.other).takeIf { note.other != 0 && it >= 0 }
                problems[index] = when {
                    note.isInvalid -> Invalid(note.flags)
                    note.has(UserDictNote.REPEATS_LINE) -> Duplicate(other)
                    note.has(UserDictNote.REPEATS_BUILT_IN) -> Duplicate(null)
                    note.isShared -> SharedCode(
                        builtIn = note.builtIn,
                        otherRow = if (note.has(UserDictNote.CODE_IN_LINE)) other else null,
                        peers = note.peers,
                    )
                    else -> null
                }
            }
            return problems.asList()
        }
    }
}
