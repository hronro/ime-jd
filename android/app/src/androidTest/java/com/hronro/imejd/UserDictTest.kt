// The UserDict wrapper driven through the real engine — the Android
// counterpart of macos/JdIMETests/UserDictTests.swift, which mirrors
// bindings/rust/tests/engine.rs. Instrumented because it crosses JNI.
package com.hronro.imejd

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hronro.imejd.engine.Engine
import com.hronro.imejd.engine.UserDict
import com.hronro.imejd.engine.UserDictError
import com.hronro.imejd.engine.UserDictNote
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

private fun Engine.type(keys: String) = keys.forEach { pressKey(it.code.toByte()) }

@RunWith(AndroidJUnit4::class)
class UserDictTest {

    @Test
    fun userPhrasesLeadTheBuiltInCandidatesOnASharedCode() {
        // 'b' → 不 in the built-in tables; the user adds a word on the same
        // code and repeats a built-in one, which is dropped.
        val (dict, report) = UserDict.build("测试词\tb\n不\tb\n").let { it.dict to it.report }
        assertEquals(1, report.entries)
        assertEquals(1, report.dropped)
        assertEquals(listOf(2), report.notes.filter { it.isDropped }.map { it.line })
        assertEquals(1, dict.entries)

        Engine(dict).use { e ->
            e.type("b")
            assertEquals(listOf("测试词", "不"), e.readRange(0, 2).map { it.value })
            assertEquals("the user word is what space commits", "测试词", e.pressKey(' '.code.toByte()).commit)
        }
        Engine().use { plain ->
            plain.type("b")
            assertEquals("a plain context is unaffected", "不", plain.readRange(0, 1).first().value)
        }
    }

    @Test
    fun aUserOnlyCodeComposesWithHintsAndAutoCommits() {
        val dict = UserDict.build("键道\tzzzzzz\n键道输入法\tzzzzza\n").dict
        Engine(dict).use { e ->
            e.type("zzzzz")
            assertNull(e.state.commit)
            val window = e.readRange(0, 4)
            assertEquals(listOf("键道输入法", "键道"), window.map { it.value })
            assertEquals(listOf("a", "z"), window.map { it.hint })
            val state = e.pressKey('z'.code.toByte())
            assertEquals("键道", state.commit)
            assertEquals(0, state.optionsCount)
        }
    }

    @Test
    fun badLinesAreSkippedAndNotedNeverFatal() {
        // "zzzzzz" and "zzzzza" are free in the built-in tables, so the only
        // notes are the skipped lines'.
        val (dict, report) = UserDict.build("键道\tzzzzzz\nno tab\n好\tZZZZZA\n\tzzzzza\n").let { it.dict to it.report }
        assertEquals(1, dict.entries)
        assertEquals(1, report.entries)
        assertEquals(3, report.invalid)
        assertEquals(0, report.dropped)
        assertEquals(
            listOf(
                UserDictNote(2, UserDictNote.MALFORMED, 0, 0, 0),
                UserDictNote(3, UserDictNote.BAD_KEYS, 0, 0, 0),
                UserDictNote(4, UserDictNote.BAD_VALUE, 0, 0, 0),
            ),
            report.notes,
        )
        assertTrue(report.notes.all { it.isInvalid && !it.isDropped && !it.isShared })
    }

    @Test
    fun notesSayWhatALineRepeatsAndWhichCodesAreShared() {
        // 'b' carries built-in words; "zzzzzz" and "zzzzza" are free.
        val report = UserDict.build("测试词\tb\n一\tzzzzzz\n二\tzzzzzz\n键道\tzzzzza\n不\tb\n").report
        assertEquals(4, report.entries)
        assertEquals(1, report.dropped)
        assertEquals(3, report.shared)
        val wordsOnB = report.notes.first().builtIn
        assertTrue(wordsOnB >= 1)
        assertEquals(
            listOf(
                UserDictNote(1, UserDictNote.CODE_IN_BUILT_IN, 0, wordsOnB, 0),
                UserDictNote(2, UserDictNote.CODE_IN_LINE, 3, 0, 1),
                UserDictNote(3, UserDictNote.CODE_IN_LINE, 2, 0, 1),
                UserDictNote(5, UserDictNote.REPEATS_BUILT_IN, 0, wordsOnB, 0),
            ),
            report.notes,
        )
        assertTrue(report.notes[0].isShared)
        assertFalse(report.notes[0].isDropped)
        assertTrue(report.notes[3].isDropped)
        assertFalse(report.notes[3].isShared)

        assertEquals("nothing to say about a clean file", emptyList<UserDictNote>(), UserDict.build("键道\tzzzzzz\n").report.notes)
    }

    @Test
    fun anEmptyDictionaryIsValidAndInert() {
        val dict = UserDict.build("").dict
        assertEquals(0, dict.entries)
        Engine(dict).use { withDict ->
            Engine().use { plain ->
                withDict.type("a")
                plain.type("a")
                assertEquals(plain.state, withDict.state)
                assertEquals(plain.readRange(0, 9), withDict.readRange(0, 9))
            }
        }
    }

    /**
     * jd_init reads the blob in place for the context's lifetime and a JVM
     * array can move, so each engine works on its own native copy: the
     * dictionary's bytes can change, or go, without the engine noticing.
     */
    @Test
    fun theEngineOwnsACopyOfTheBlob() {
        val dict = UserDict.build("键道\tzzzzzz\n").dict
        Engine(dict).use { e ->
            dict.blob.fill(0)
            e.type("zzzzz")
            assertEquals(listOf("键道"), e.readRange(0, 4).map { it.value })
        }
    }

    @Test
    fun wholeCallFailuresAreThrownWithTheirLine() {
        val tooMany = (0..UserDict.MAX_ENTRIES).joinToString("") { "词$it\tzzzzzz\n" }
        val error = assertThrows(UserDictError::class.java) { UserDict.build(tooMany) }
        assertEquals(UserDictError.Status.TOO_MANY_ENTRIES, error.status)
        assertEquals("the first excess phrase", UserDict.MAX_ENTRIES + 1, error.line)

        val tooLong = "#" + "x".repeat(8 * 1024 * 1024) // JD_USER_DICT_TEXT_MAX, plus the '#'
        assertEquals(
            UserDictError(UserDictError.Status.TEXT_TOO_LONG, 0),
            assertThrows(UserDictError::class.java) { UserDict.build(tooLong) },
        )
    }

    @Test
    fun cachedBlobsRoundTripAndCorruptionIsCaught() {
        val tag = 0x0123_4567_89ab_cdefL
        val dict = UserDict.build("# comment\n键道\tzzzzzz\n", tag).dict
        assertEquals(1, dict.entries)
        assertEquals(tag, dict.sourceTag)

        // The tag and the count survive the trip through a cache.
        val again = UserDict.fromBlob(dict.blob.copyOf())
        assertEquals(tag, again.sourceTag)
        assertEquals(1, again.entries)
        Engine(again).use { e ->
            e.type("zzzzzz")
            assertEquals("the engine reads the cached copy like the original", "键道", e.state.commit)
        }

        val truncated = assertThrows(UserDictError::class.java) { UserDict.fromBlob(dict.blob.copyOf(dict.blob.size - 1)) }
        assertEquals(UserDictError.Status.CORRUPT, truncated.status)
        // The built-in dictionary's fingerprint lives in the header: another libjd's blob is stale.
        val stale = dict.blob.copyOf().also { it[12] = (it[12].toInt() xor 0xFF).toByte() }
        assertEquals(UserDictError.Status.STALE, assertThrows(UserDictError::class.java) { UserDict.fromBlob(stale) }.status)
        assertEquals(UserDictError.Status.CORRUPT, assertThrows(UserDictError::class.java) { UserDict.fromBlob(ByteArray(0)) }.status)
    }

    @Test
    fun theLimitsMatchTheLibrary() {
        // Exactly at the caps is fine; one past is the engine's to refuse.
        val atCap = (1..UserDict.MAX_ENTRIES).joinToString("") { "词$it\tzzzzzz\n" }
        assertEquals(UserDict.MAX_ENTRIES, UserDict.build(atCap).report.entries)
        val longest = "字".repeat(UserDict.MAX_VALUE_BYTES / 3) // 3 UTF-8 bytes each
        assertEquals(0, UserDict.build("$longest\tzzzzzz\n").report.invalid)
        assertEquals(1, UserDict.build("${longest}字\tzzzzzz\n").report.invalid)
        assertEquals(1, UserDict.build("长\t${"z".repeat(UserDict.MAX_KEY_LENGTH + 1)}\n").report.invalid)
    }
}
