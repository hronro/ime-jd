// Port of ios/KeyboardTests/InputSessionTests.swift. Instrumented (androidTest)
// rather than a JVM unit test because it drives the real engine through JNI and
// needs libjd.so / libjdjni.so loaded on a device/emulator.
package com.hronro.imejd

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hronro.imejd.engine.InputSession
import com.hronro.imejd.engine.KeyAction
import com.hronro.imejd.engine.KeyboardHost
import com.hronro.imejd.engine.SessionSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
        val s = InputSession()
        val h = MockHost()
        s.host = h
        return s to h
    }

    /**
     * A letter starts a composition shown in the keyboard's own bar — nothing
     * must leak to the host until commit (the cardinal on-screen-keyboard rule).
     */
    @Test
    fun letterStartsCompositionWithoutInserting() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('n')))
        assertTrue(s.isComposing)
        assertFalse(s.snapshot.candidates.isEmpty())
        assertTrue(s.snapshot.optionsCount > 0)
        assertTrue("composition must not leak to the host", h.inserted.isEmpty())
        assertEquals("n", s.rawBuffer)
    }

    /** Bare '.' resolves to the Chinese full stop via the engine's punctuation table. */
    @Test
    fun barePunctuationCommitsToHost() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('.')))
        assertEquals("。", h.joined)
        assertFalse(s.isComposing)
    }

    /** 'n' then '.' commits the top candidate AND appends 。 in one step. */
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
        val first = s.snapshot.candidates.first().value
        s.handle(KeyAction.SelectIdx(0))
        assertEquals(first, h.joined)
        assertFalse(s.isComposing)
    }

    /**
     * The session tracks everything the bar has loaded, so a tap on a
     * scrolled-in candidate resolves too — not just the first window.
     */
    @Test
    fun selectVisibleReachesScrolledInCandidates() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        val firstWindow = s.snapshot.candidates.size
        assertNotNull(s.loadMoreCandidates())
        assertTrue(s.snapshot.candidates.size > firstWindow)

        val scrolledIn = s.snapshot.candidates[firstWindow]
        s.handle(KeyAction.SelectIdx(firstWindow))
        assertEquals(scrolledIn.value, h.joined)
    }

    @Test
    fun backspaceWhileComposingDoesNotTouchHost() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        assertTrue(s.isComposing)
        s.handle(KeyAction.Backspace)
        assertEquals("deleting composition must not delete host text", 0, h.deletes)
        assertFalse(s.isComposing)
        assertEquals(0, s.snapshot.optionsCount)
    }

    @Test
    fun backspaceWithoutCompositionDeletesHostChar() {
        val (s, h) = makeSession()
        s.handle(KeyAction.Backspace)
        assertEquals(1, h.deletes)
        assertTrue(h.inserted.isEmpty())
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
        assertEquals(SessionSnapshot.EMPTY, s.snapshot)
        assertTrue(h.inserted.isEmpty())
    }

    @Test
    fun onChangeFiresOnKey() {
        val (s, _) = makeSession()
        var calls = 0
        s.onChange = { calls++ }
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
        val top = s.snapshot.candidates.first().value
        s.insertLiteral("。")
        // Matches libjd: top candidate committed, then the punctuation appended.
        assertEquals(top + "。", h.joined)
        assertFalse(s.isComposing)
    }

    @Test
    fun spaceCommitsTopCandidate() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('n')))
        assertTrue(s.isComposing)
        // space → engine commits the anchor candidate, appends nothing
        s.handle(KeyAction.EngineKey(0x20))
        assertEquals("你", h.joined)
        assertFalse(s.isComposing)
    }

    // ---- Lazy loading -----------------------------------------------------
    //
    // Under the old page-based ABI, prefetching moved the engine's only cursor,
    // which doubled as the commit anchor — so the strip had to jump the engine
    // back or space would commit a candidate the user wasn't looking at. Reads
    // are pure now, but the *property* is what matters, so these stay.

    @Test
    fun spaceCommitsFirstVisibleCandidateAfterPrefetch() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        val firstVisible = s.snapshot.candidates.first().value
        assertNotNull("prefetch should return candidates", s.loadMoreCandidates())
        assertNotNull(s.loadMoreCandidates())
        s.handle(KeyAction.EngineKey(0x20))
        assertEquals(firstVisible, h.joined)
    }

    /** Same property for the punctuation bypass (insertLiteral presses space). */
    @Test
    fun insertLiteralCommitsFirstVisibleCandidateAfterPrefetch() {
        val (s, h) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        val firstVisible = s.snapshot.candidates.first().value
        s.loadMoreCandidates()
        s.insertLiteral("。")
        assertEquals(firstVisible + "。", h.joined)
    }

    /**
     * The bar appends prefetched candidates itself and keeps what's on screen,
     * so a prefetch must extend the loaded list without re-rendering it.
     */
    @Test
    fun prefetchAppendsWithoutFiringOnChange() {
        val (s, _) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        val before = s.snapshot.candidates

        var calls = 0
        s.onChange = { calls++ }
        val more = s.loadMoreCandidates()

        assertEquals("prefetch must not re-render the bar", 0, calls)
        assertNotNull(more)
        // The already-shown prefix is unchanged; the new candidates are appended.
        assertEquals(before, s.snapshot.candidates.take(before.size))
        assertEquals(before.size + more!!.size, s.snapshot.candidates.size)
    }

    /**
     * Consecutive prefetches surface each remaining candidate exactly once,
     * then stop. 'a' is small enough (29 candidates) to walk exhaustively.
     */
    @Test
    fun loadMoreWalksEveryCandidateThenStops() {
        val (s, _) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('a')))
        val total = s.snapshot.optionsCount
        assertTrue(
            "test needs a code with more candidates than one window",
            total > s.snapshot.candidates.size,
        )

        var fetches = 0
        while (true) {
            val more = s.loadMoreCandidates() ?: break
            assertFalse(more.isEmpty())
            fetches++
            assertTrue("prefetch ran past the candidate count", fetches <= total)
        }
        assertTrue(fetches > 0)
        assertEquals(
            "prefetch should surface every candidate exactly once",
            total,
            s.snapshot.candidates.size,
        )
        assertNull(s.loadMoreCandidates())
    }

    /** A new keystroke resets the loaded list — the strip starts over. */
    @Test
    fun newKeystrokeResetsTheLoadedList() {
        val (s, _) = makeSession()
        s.handle(KeyAction.EngineKey(ascii('b')))
        s.loadMoreCandidates()
        val grown = s.snapshot.candidates.size

        s.handle(KeyAction.EngineKey(ascii('a')))
        assertTrue(s.snapshot.candidates.size < grown)
        assertEquals("ba", s.rawBuffer)
    }
}
