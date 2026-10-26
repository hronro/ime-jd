// The app's user-dictionary store against a temporary file and preferences
// file — the Android counterpart of ios/KeyboardTests/UserDictStoreTests.swift:
// the file as typed, the engine's verdict per row, whole-file failures, the
// switch, the import reader, the duplicates' removal, the export.
package com.hronro.imejd

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hronro.imejd.userdict.UserDictEntry
import com.hronro.imejd.userdict.UserDictFile
import com.hronro.imejd.userdict.UserDictProblem
import com.hronro.imejd.userdict.UserDictStore
import com.hronro.jd.UserDict
import com.hronro.jd.UserDictException
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UserDictStoreTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefsName = "test-user-dict-store"
    private lateinit var dir: File
    private lateinit var file: File
    private lateinit var blob: File
    private lateinit var store: UserDictStore

    @Before
    fun setUp() {
        dir = File(context.cacheDir, "user-dict-store-test").apply { deleteRecursively(); mkdirs() }
        file = File(dir, "用户自造词.txt")
        blob = File(dir, "no-backup/用户自造词.blob")
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE).edit().clear().commit()
        store = newStore()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE).edit().clear().commit()
    }

    private fun newStore() = UserDictStore(file, blob, context.getSharedPreferences(prefsName, Context.MODE_PRIVATE))

    private fun importing(text: String) = UserDictStore.entriesFrom(ByteArrayInputStream(text.toByteArray()))

    @Test
    fun everyRowIsSavedAsTypedWithTheEnginesVerdict() {
        assertEquals(emptyList<Any>(), store.rows)
        assertEquals("尚无词条", store.statusText)
        val entries = listOf(
            UserDictEntry("甲", "zzzzzz"),
            UserDictEntry("乙", "ZZZZZA"),   // bad keys: skipped
            UserDictEntry("甲", "zzzzzz"),   // repeats row 1: dropped
            UserDictEntry("不", "b"),        // repeats a built-in word: dropped
            UserDictEntry("测试词", "b"),    // shares b with built-in words: kept
        )
        store.save(entries)

        assertEquals(entries, store.entries)
        assertEquals(listOf(2, 3, 4, 5, 6), store.rows.map { it.line })
        assertNull(store.lastError)
        assertEquals(2, store.dictionary?.entries)
        assertEquals(5, store.problems.size)
        assertNull(store.problems[0])
        assertTrue(store.problems[1] is UserDictProblem.Invalid)
        assertEquals(UserDictProblem.Duplicate(0), store.problems[2])
        assertEquals(UserDictProblem.Duplicate(null), store.problems[3])
        val shared = store.problems[4] as UserDictProblem.SharedCode
        assertTrue(shared.builtIn >= 1)
        assertNull(shared.otherRow)
        assertEquals("编码无效（1 到 6 个 a-z），不生效", store.problems[1]?.text)
        assertEquals("与第 1 条重复，不生效", store.problems[2]?.text)
        assertEquals("与内置词重复，不生效", store.problems[3]?.text)
        assertEquals("与 ${shared.builtIn} 个内置词同码", shared.text)
        assertEquals("2 条生效，1 条无效，2 条重复，1 条同码", store.statusText)

        // A fresh store reads the same rows back, in order, with the same verdicts.
        val again = newStore()
        assertEquals(store.rows, again.rows)
        assertEquals(store.problems, again.problems)
    }

    /**
     * A save caches the blob beside the text, and the next load — the
     * keyboard's, at every start — takes it instead of building. The list's
     * verdicts need a build's notes, which only that list asks for.
     */
    @Test
    fun theNextLoadTakesTheCachedBlob() {
        val entries = listOf(UserDictEntry("键道", "zzzzzz"), UserDictEntry("键道", "zzzzzz"))
        store.save(entries)
        assertEquals(UserDictStore.Source.BUILT, store.source)
        assertTrue("cached beside the text", blob.exists())

        val again = newStore()
        assertEquals(UserDictStore.Source.BLOB, again.source)
        assertEquals(1, again.dictionary?.entries)
        assertEquals(UserDictFile.hash(UserDictFile.serialize(entries)), again.dictionary?.sourceTag)
        assertEquals("the list still gets its verdicts", store.problems, again.problems)
        assertEquals(listOf(1), again.duplicateRows)
    }

    @Test
    fun aBrokenOrForeignBlobIsRebuiltAndReplaced() {
        store.save(listOf(UserDictEntry("键道", "zzzzzz")))

        // Corrupt: rebuilt, and the cache is good again.
        blob.writeBytes(byteArrayOf(1, 2, 3, 4))
        assertEquals(UserDictStore.Source.BUILT, newStore().source)
        assertEquals(UserDictStore.Source.BLOB, newStore().source)

        // Another text's — the file replaced behind the cache's back, as a
        // restore from a backup might: rebuilt from the text, never the blob.
        UserDictFile.write(UserDictFile.serialize(listOf(UserDictEntry("键道输入法", "zzzzzz"))), file)
        val replaced = newStore()
        assertEquals(UserDictStore.Source.BUILT, replaced.source)
        assertEquals("键道输入法", replaced.rows.single().entry.value)
        assertEquals(UserDictStore.Source.BLOB, newStore().source)

        // No file: no cache either.
        file.delete()
        assertNull(newStore().dictionary)
        assertFalse(blob.exists())
    }

    @Test
    fun aFileTheEngineRefusesIsKeptAndRunsOnNothing() {
        store.isEnabled = true
        store.save(listOf(UserDictEntry("键道", "zzzzzz")))
        assertNotNull(store.activeDictionary)

        // One phrase past the cap: the engine refuses the file as a whole.
        val tooMany = (0..UserDict.MAX_ENTRIES).map { UserDictEntry("词$it", "zzzzzz") }
        store.save(tooMany)
        val error = store.lastError as UserDictStore.LoadError.Build
        assertEquals(UserDictException.Status.TOO_MANY_ENTRIES, error.error.status)
        assertEquals(UserDict.MAX_ENTRIES + 2, error.error.line)
        assertEquals("the rows are the user's: still written", UserDict.MAX_ENTRIES + 1, store.rows.size)
        assertNull(store.dictionary)
        assertNull("every session runs on the built-in dictionary", store.activeDictionary)
        assertTrue(store.problems.all { it == null })
        assertEquals("未能加载：第 ${UserDict.MAX_ENTRIES + 2} 行起超过 ${UserDict.MAX_ENTRIES} 条上限", store.statusText)
        assertFalse("no blob for a file that cannot be built", blob.exists())

        // Fixed: back to normal.
        store.save(tooMany.take(2))
        assertNull(store.lastError)
        assertEquals("two phrases on one code are both kept", 2, store.dictionary?.entries)
    }

    @Test
    fun theSwitchLivesInThePreferencesAndEveryChangeIsAnnounced() {
        assertFalse(store.isEnabled)
        store.save(listOf(UserDictEntry("键道", "zzzzzz")))
        assertNull("off: sessions run on the built-in dictionary", store.activeDictionary)

        var notified = 0
        val listener: () -> Unit = { notified++ }
        store.addListener(listener)
        val before = store.generation
        store.isEnabled = true
        assertEquals(1, notified)
        store.isEnabled = true
        assertEquals("no change, no notice", 1, notified)
        assertTrue(store.generation > before)
        assertNotNull(store.activeDictionary)
        assertTrue(newStore().isEnabled)

        store.save(listOf(UserDictEntry("键道输入法", "zzzzzz")))
        assertEquals("a save is announced too", 2, notified)
        store.removeListener(listener)
        store.isEnabled = false
        assertEquals(2, notified)
    }

    @Test
    fun anImportedFileIsReadTheWayTheListsOwnIs() {
        // A BOM, CRLF line ends, a comment, a blank line, spaces around the
        // fields, a line without a TAB: every phrase line becomes a row, as
        // typed, in file order; nothing is judged.
        assertEquals(
            listOf(
                UserDictEntry("键道", "zzzzzz"),
                UserDictEntry("乙", "ZZZZZA"),
                UserDictEntry("没有编码", ""),
            ),
            importing("﻿# 键道用户自造词\r\n键道\tzzzzzz\r\n\r\n 乙 \t ZZZZZA \r\n没有编码\r\n"),
        )
        assertEquals("nothing written", emptyList<Any>(), store.rows)

        assertThrows(UserDictStore.LoadError.NotUtf8::class.java) {
            UserDictStore.entriesFrom(ByteArrayInputStream(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x41)))
        }
        val none = assertThrows(UserDictStore.LoadError.NoPhrases::class.java) { importing("# only a comment\n\n") }
        assertEquals("文件中没有词条", none.message)
    }

    @Test
    fun duplicatesAreTheEnginesToNameAndTheUsersToRemove() {
        val entries = listOf(
            UserDictEntry("甲", "zzzzzz"),
            UserDictEntry("乙", "ZZZZZA"),   // invalid: stays
            UserDictEntry("甲", "zzzzzz"),   // repeats row 0
            UserDictEntry("不", "b"),        // repeats a built-in word
            UserDictEntry("丙", "zzzzzz"),   // shares the code: works, stays
        )
        store.saveIfBuildable(entries) // an import: appended as it is
        assertEquals("nothing is dropped on the way in", 5, store.rows.size)
        assertEquals(listOf(2, 3), store.duplicateRows)
        assertEquals("2 条生效，1 条无效，2 条重复，2 条同码", store.statusText)

        assertEquals(2, store.removeDuplicates())
        assertEquals("the first of each stays", listOf(entries[0], entries[1], entries[4]), store.entries)
        assertEquals(emptyList<Int>(), store.duplicateRows)
        assertEquals(0, store.removeDuplicates())

        // A file the engine refuses as a whole has no notes: nothing to remove.
        store.save(List(UserDict.MAX_ENTRIES + 1) { entries[0] })
        assertNotNull(store.lastError)
        assertEquals(emptyList<Int>(), store.duplicateRows)
        assertEquals(0, store.removeDuplicates())
    }

    @Test
    fun anImportTheEngineRefusesWritesNothing() {
        store.save(listOf(UserDictEntry("键道", "zzzzzz")))
        val before = file.readBytes()
        val tooMany = (0..UserDict.MAX_ENTRIES).map { UserDictEntry("词$it", "zzzzzz") }
        val refused = assertThrows(UserDictStore.LoadError.Build::class.java) { store.saveIfBuildable(tooMany) }
        assertEquals("第 ${UserDict.MAX_ENTRIES + 2} 行起超过 ${UserDict.MAX_ENTRIES} 条上限", refused.message)
        assertEquals(1, store.rows.size)
        assertNull(store.lastError)
        assertArrayEquals(before, file.readBytes())

        // Too much text is libjd's to refuse too, as on every client.
        val huge = listOf(UserDictEntry("词".repeat(3_000_000), "zzzzzz")) // 9 MB of UTF-8
        val tooLong = assertThrows(UserDictStore.LoadError.Build::class.java) { store.saveIfBuildable(huge) }
        assertEquals(UserDictException.Status.TEXT_TOO_LONG, tooLong.error.status)
        assertEquals("文件超过 8 MB 上限", tooLong.message)
        assertArrayEquals(before, file.readBytes())

        // Within the caps: written like any save, and cached.
        store.saveIfBuildable(tooMany.take(3))
        assertEquals(3, store.rows.size)
        assertEquals(3, store.dictionary?.entries)
        assertEquals(UserDictStore.Source.BLOB, newStore().source)
    }

    @Test
    fun theExportIsTheFileItself() {
        val entries = listOf(UserDictEntry("键道", "zzzzzz"), UserDictEntry("乙", "ZZZZZA"))
        store.save(entries)
        val out = ByteArrayOutputStream()
        store.export(out)
        assertArrayEquals("byte for byte", file.readBytes(), out.toByteArray())
        assertEquals("and it imports as it is", entries, UserDictStore.entriesFrom(ByteArrayInputStream(out.toByteArray())))
    }

    @Test
    fun anUnreadableFileIsReportedNotCrashed() {
        file.writeBytes(byteArrayOf(0xC4.toByte(), 0xE3.toByte(), 0x09, 0x61, 0x0A))
        val broken = newStore()
        assertTrue(broken.lastError is UserDictStore.LoadError.NotUtf8)
        assertEquals("未能加载：文件不是 UTF-8 编码", broken.statusText)
        assertEquals(emptyList<Any>(), broken.rows)
        assertNull(broken.dictionary)
    }
}
