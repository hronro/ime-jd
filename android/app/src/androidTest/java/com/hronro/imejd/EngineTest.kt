// Lifecycle tests for the Engine wrapper itself (InputSessionTest covers the
// composition logic above it). Instrumented for the same reason: the guards sit
// directly in front of real JNI calls into libjd.so.
package com.hronro.imejd

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hronro.imejd.engine.Engine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EngineTest {

    /**
     * Regression: close() zeroes the native handle, so without the disposed
     * guard any later call would pass NULL to libjd and segfault the process.
     * The JS binding throws on use-after-dispose; the Kotlin side must match.
     */
    @Test
    fun useAfterCloseThrowsInsteadOfCrashing() {
        val e = Engine()
        e.close()
        assertThrows(IllegalStateException::class.java) { e.pressKey('n'.code.toByte()) }
        assertThrows(IllegalStateException::class.java) { e.backspace() }
        assertThrows(IllegalStateException::class.java) { e.reset() }
        assertThrows(IllegalStateException::class.java) { e.setAnchor(0) }
        assertThrows(IllegalStateException::class.java) { e.state }
        assertThrows(IllegalStateException::class.java) { e.readRange(0, 4) }
    }

    @Test
    fun doubleCloseIsSafe() {
        Engine().apply {
            close()
            close()
        }
    }

    /** The guard must not get in the way of a live engine. */
    @Test
    fun openEngineStillWorks() {
        Engine().use { e ->
            val state = e.pressKey('n'.code.toByte())
            assertTrue("expected candidates for 'n'", state.optionsCount > 0)
            assertTrue(e.readRange(0, 9).isNotEmpty())
        }
    }

    /**
     * `readRange` loops over the JNI chunk size, so a window larger than one
     * native call must still come back complete and in order.
     */
    @Test
    fun readRangeSpansMultipleNativeChunks() {
        Engine().use { e ->
            val total = e.pressKey('j'.code.toByte()).optionsCount
            assertTrue("expected a long candidate list for 'j'", total > 200)

            val big = e.readRange(0, 200)
            assertEquals(200, big.size)
            assertTrue(big.all { it.value.isNotEmpty() })

            // Chunked reads agree with a smaller single-chunk read.
            assertEquals(big.take(32).map { it.value }, e.readRange(0, 32).map { it.value })

            // A window is clipped by the total, never padded.
            assertEquals(total, e.readRange(0, total + 50).size)
            assertTrue(e.readRange(total, 5).isEmpty())
            assertTrue(e.readRange(0, 0).isEmpty())
        }
    }

    /** Reads are pure: prefetching must not change what space commits. */
    @Test
    fun readingAheadDoesNotMoveTheAnchor() {
        Engine().use { e ->
            val total = e.pressKey('j'.code.toByte()).optionsCount
            val anchorValue = e.readRange(0, 1).first().value

            e.readRange(total - 8, 8)
            assertEquals(0, e.state.anchorIndex)
            assertEquals(anchorValue, e.pressKey(' '.code.toByte()).commit)
        }
    }

    @Test
    fun setAnchorMovesWhatSpaceCommits() {
        Engine().use { e ->
            e.pressKey('j'.code.toByte())
            val target = e.readRange(7, 1).first().value

            assertEquals(7, e.setAnchor(7).anchorIndex)
            assertEquals(target, e.pressKey(' '.code.toByte()).commit)
        }
    }

    @Test
    fun setAnchorIgnoresOutOfRange() {
        Engine().use { e ->
            val total = e.pressKey('j'.code.toByte()).optionsCount
            e.setAnchor(3)
            e.setAnchor(total) // one past the end
            assertEquals(3, e.state.anchorIndex)
            e.setAnchor(Int.MAX_VALUE)
            assertEquals(3, e.state.anchorIndex)
        }
    }

    /** A commit that appends a literal byte must join in the right order. */
    @Test
    fun literalAppendJoinsInOrder() {
        Engine().use { e ->
            e.pressKey('a'.code.toByte())
            val first = e.readRange(0, 1).first().value
            // A digit is literal input to the engine: commit the anchor, append '2'.
            assertEquals(first + "2", e.pressKey('2'.code.toByte()).commit)
        }
    }

    /** Hints are inline bytes, bounded by the dictionary's max key length. */
    @Test
    fun hintsAreBoundedOrAbsent() {
        Engine().use { e ->
            e.pressKey('j'.code.toByte())
            val window = e.readRange(0, 32)
            for (c in window) {
                c.hint?.let { assertTrue("hint '$it' is too long", it.isNotEmpty() && it.length < 8) }
            }
            assertTrue(
                "a fully-typed code should have a hintless candidate",
                window.any { it.hint == null },
            )
        }
    }
}
