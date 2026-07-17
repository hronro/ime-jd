// Lifecycle tests for the Engine wrapper itself (InputSessionTest covers the
// composition logic above it). Instrumented for the same reason: the guards sit
// directly in front of real JNI calls into libjd.so.
package com.hronro.imejd

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hronro.imejd.engine.Engine
import org.junit.Assert.assertThrows
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
        val e = Engine(pageSize = 9)
        e.close()
        assertThrows(IllegalStateException::class.java) { e.pressKey('n'.code.toByte()) }
        assertThrows(IllegalStateException::class.java) { e.backspace() }
        assertThrows(IllegalStateException::class.java) { e.nextPage() }
        assertThrows(IllegalStateException::class.java) { e.prevPage() }
        assertThrows(IllegalStateException::class.java) { e.jumpToPage(1) }
        assertThrows(IllegalStateException::class.java) { e.reset() }
    }

    @Test
    fun doubleCloseIsSafe() {
        Engine(pageSize = 9).apply {
            close()
            close()
        }
    }

    /** The guard must not get in the way of a live engine. */
    @Test
    fun openEngineStillWorks() {
        Engine(pageSize = 9).use { e ->
            val snap = e.pressKey('n'.code.toByte())
            check(snap.options.isNotEmpty()) { "expected candidates for 'n'" }
        }
    }
}
