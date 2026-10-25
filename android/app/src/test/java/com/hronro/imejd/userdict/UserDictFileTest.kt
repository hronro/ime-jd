// JVM unit tests for the phrases file's format (no device needed): how lines
// are split for display and written back. The engine's verdicts are covered
// by the instrumented UserDictStoreTest.
package com.hronro.imejd.userdict

import java.nio.charset.CharacterCodingException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UserDictFileTest {

    @Test
    fun linesSplitTheWayTheEngineSplitsThem() {
        val text = "# comment\n键道\tzzzzzz\r\n\n  空格 \t  ab  \nno tab here\n\tzzz\n值\t\n  # indented comment\n"
        assertEquals(
            listOf(
                UserDictRow(2, UserDictEntry("键道", "zzzzzz")),
                UserDictRow(4, UserDictEntry("空格", "ab")),
                UserDictRow(5, UserDictEntry("no tab here", "")),
                UserDictRow(6, UserDictEntry("", "zzz")),
                UserDictRow(7, UserDictEntry("值", "")),
            ),
            UserDictFile.parse(text),
        )
        // Only the first TAB splits: the rest is the code's, for the engine to judge.
        assertEquals(listOf(UserDictRow(1, UserDictEntry("a", "b\tc"))), UserDictFile.parse("a\tb\tc"))
        assertEquals(emptyList<UserDictRow>(), UserDictFile.parse(""))
    }

    @Test
    fun aSaveIsTheHeaderAndOneLinePerEntryInOrder() {
        val entries = listOf(UserDictEntry("键道", "zzzzzz"), UserDictEntry("", ""), UserDictEntry("乙", "ZZZZZA"))
        val text = UserDictFile.serialize(entries)
        assertEquals(UserDictFile.HEADER + "\n键道\tzzzzzz\n\t\n乙\tZZZZZA\n", text)
        // Entry i lands on line i + 2, and reads back as it went in — an
        // empty one too: its line is a lone TAB, which the engine flags.
        assertEquals(listOf(2, 3, 4), UserDictFile.parse(text).map { it.line })
        assertEquals(entries, UserDictFile.parse(text).map { it.entry })
    }

    /** The cached blob's tag: FNV-1a 64, the Swift clients' function, on its published vectors. */
    @Test
    fun theHashIsFnv1a64() {
        assertEquals(0xcbf29ce484222325uL.toLong(), UserDictFile.hash(""))
        assertEquals(0xaf63dc4c8601ec8cuL.toLong(), UserDictFile.hash("a"))
        assertEquals(0x85944171f73967e8uL.toLong(), UserDictFile.hash("foobar"))
        assertEquals("over the UTF-8 bytes", 0x07f46b66f9515be2L, UserDictFile.hash("键道\tzzzzzz\n"))
    }

    @Test
    fun decodingIsStrictUtf8WithTheBomDropped() {
        assertEquals("键道", UserDictFile.decode(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "键道".toByteArray()))
        assertEquals("", UserDictFile.decode(ByteArray(0)))
        // GBK for 你 — a file saved in the wrong encoding is refused, not mangled.
        assertThrows(CharacterCodingException::class.java) {
            UserDictFile.decode(byteArrayOf(0xC4.toByte(), 0xE3.toByte()))
        }
    }
}
