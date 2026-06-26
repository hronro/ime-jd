// Port of ios/KeyboardTests/InputSessionTests.swift. Instrumented (androidTest)
// rather than a JVM unit test because it drives the real engine through JNI and
// needs libjd.so / libjdjni.so loaded on a device/emulator.
package com.hronro.jdime

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hronro.jdime.engine.InputSession
import com.hronro.jdime.engine.KeyAction
import com.hronro.jdime.engine.KeyboardHost
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

private class MockHost : KeyboardHost {
    val inserted = mutableListOf<String>()
    var deletes = 0
    override fun insertText(text: String) { inserted.add(text) }
    override fun deleteBackward() { deletes++ }
    val joined: String get() = inserted.joinToString("")
}

private fun ascii(c: Char): Byte = c.code.toByte()

@RunWith(AndroidJUnit4::class)
class InputSessionTest {

    private fun makeSession(): Pair<InputSession, MockHost> {
        val s = InputSession(pageSize = 9)
        val h = MockHost()
        s.host = h
        return s to h
    }

    @Test
    fun letterStartsCompositionWithoutInserting() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('n')))
        assertTrue(s.isComposing)
        assertFalse(s.snapshot.options.isEmpty())
        assertEquals(emptyList<String>(), h.inserted)
        assertEquals("n", s.rawBuffer)
    }

    @Test
    fun barePunctuationCommitsToHost() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('.')))
        assertEquals("。", h.joined)
        assertFalse(s.isComposing)
    }

    @Test
    fun punctuationCommitsAndAppendsAfterComposition() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('n')))
        s.handle(KeyAction.EngineKey(ascii('.')))
        assertTrue("got ${h.joined}", h.joined.endsWith("。"))
        assertTrue(h.joined.length > 1)
        assertFalse(s.isComposing)
    }

    @Test
    fun selectVisibleCommitsCandidate() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        val first = s.snapshot.options.first().value
        s.handle(KeyAction.SelectIdx(0))
        assertEquals(first, h.joined)
        assertFalse(s.isComposing)
    }

    @Test
    fun backspaceWhileComposingDoesNotTouchHost() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        assertTrue(s.isComposing)
        s.handle(KeyAction.Backspace)
        assertEquals(0, h.deletes)
        assertFalse(s.isComposing)
    }

    @Test
    fun backspaceWithoutCompositionDeletesHostChar() {
        val (s, h) = makeSession()
        s.handle(KeyAction.Backspace)
        assertEquals(1, h.deletes)
        assertEquals(emptyList<String>(), h.inserted)
    }

    @Test
    fun commitRawEmitsRawBuffer() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        s.handle(KeyAction.CommitRaw)
        assertEquals("b", h.joined)
        assertFalse(s.isComposing)
    }

    @Test
    fun cancelResetClearsWithoutInserting() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        s.cancelAndReset()
        assertFalse(s.isComposing)
        assertEquals(emptyList<String>(), h.inserted)
    }

    @Test
    fun onChangeFiresOnKey() {
        val (s, _) = makeSession()
        var calls = 0
        s.onChange = { _, _ -> calls++ }
        s.handle(KeyAction.EngineKey(ascii('b')))
        assertTrue(calls > 0)
    }

    @Test
    fun insertLiteralWhenNotComposingInsertsDirectly() {
        val (s, h) = makeSession()
        s.insertLiteral("。")
        assertEquals("。", h.joined)
        assertFalse(s.isComposing)
    }

    @Test
    fun insertLiteralWhileComposingCommitsTopThenAppends() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('n')))
        val top = s.snapshot.options.first().value
        s.insertLiteral("。")
        assertEquals(top + "。", h.joined)
        assertFalse(s.isComposing)
    }

    @Test
    fun spaceCommitsTopCandidate() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('n')))
        assertTrue(s.isComposing)
        s.handle(KeyAction.EngineKey(0x20))
        assertFalse("space should commit the top candidate", h.joined.isEmpty())
        assertFalse(s.isComposing)
    }
}
