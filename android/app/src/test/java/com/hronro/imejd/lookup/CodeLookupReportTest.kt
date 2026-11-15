// JVM unit tests for 编码反查's wording (no device needed): the codes are made
// by hand, in the shape Engine.lookupCodes returns them — the engine's own
// lookup is covered by bindings/java's tests. Mirrors
// ios/KeyboardTests/CodeLookupReportTests.swift.
package com.hronro.imejd.lookup

import com.hronro.jd.Code
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CodeLookupReportTest {
    private fun line(keys: String, note: String? = null) = CodeLookupReport.Line(keys, note)

    @Test
    fun everyCodeIsALineAndALaterCandidateSaysWhichItIs() {
        // 着, as the shipped tables give it: second candidate on `o`, first on the rest.
        val codes = listOf(Code("o", 1, false)) + listOf("fe", "qe", "flo", "fzou").map { Code(it, 0, false) }
        val report = CodeLookupReport("着", codes, userDictEnabled = false)
        assertTrue(report.found)
        assertNull(report.message)
        assertEquals("「着」的编码", report.title)
        assertEquals(
            listOf(line("o", "第 2 个候选"), line("fe"), line("qe"), line("flo"), line("fzou")),
            report.lines,
        )
    }

    @Test
    fun userCodesAreMarkedAndBothNotesJoin() {
        val codes = listOf(Code("d", 1, false), Code("zzzzzz", 0, true), Code("zq", 2, true))
        assertEquals(
            listOf(line("d", "第 2 个候选"), line("zzzzzz", "自造词"), line("zq", "第 3 个候选，自造词")),
            CodeLookupReport("的", codes, userDictEnabled = true).lines,
        )
    }

    @Test
    fun notFoundSaysWhereItLooked() {
        val enabled = CodeLookupReport("不在词库里的词", emptyList(), userDictEnabled = true)
        assertFalse(enabled.found)
        assertEquals(emptyList<CodeLookupReport.Line>(), enabled.lines)
        assertEquals("没有找到「不在词库里的词」", enabled.title)
        assertEquals("内置词库和用户自造词中都没有这个词。", enabled.message)
        assertEquals(
            "内置词库中没有这个词。用户自造词未启用，不在查询范围内。",
            CodeLookupReport("词", emptyList(), userDictEnabled = false).message,
        )
    }

    @Test
    fun aLongQueryIsCutShortInTheTitleByCharacters() {
        assertEquals("没有找到「${"键".repeat(20)}…」", CodeLookupReport("键".repeat(30), emptyList(), false).title)
        // 20 supplementary-plane characters are 40 UTF-16 units: not cut.
        val wide = "𠀀".repeat(20)
        assertEquals("没有找到「$wide」", CodeLookupReport(wide, emptyList(), false).title)
    }

    @Test
    fun thePastedQueryLosesOnlyLineBreaksSpacesAndTabsAtItsEnds() {
        assertEquals("键道", CodeLookupReport.query(" 键道\r\n"))
        assertEquals("键 道", CodeLookupReport.query("\t键 道\n"))
        assertEquals("键道　", CodeLookupReport.query("键道　"))
        assertEquals("", CodeLookupReport.query(" \n"))
    }
}
