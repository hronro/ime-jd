// Touches on the in-app preview keyboard — the same KeyboardView, key planes
// and KeyButtons as the IME — injected the way fingers make them, for what
// only real touch dispatch shows: which key types first when presses overlap.
package com.hronro.imejd

import android.app.Activity
import android.content.Intent
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hronro.imejd.app.KeyboardPreviewActivity
import com.hronro.imejd.engine.InputSession
import com.hronro.imejd.engine.KeyAction
import com.hronro.imejd.engine.KeyboardHost
import com.hronro.imejd.ui.KeyButton
import com.hronro.imejd.ui.KeyCap
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyTouchTest {

    private val instr = InstrumentationRegistry.getInstrumentation()
    private var activity: Activity? = null

    @After
    fun finish() {
        activity?.finish()
    }

    /** Fingers on the screen: each down or up is injected with every finger
     *  still down, as the touchscreen reports them. */
    private inner class Fingers {
        private val downTime = SystemClock.uptimeMillis()
        private val active = mutableListOf<Pair<Int, Pair<Float, Float>>>()

        fun down(id: Int, at: Pair<Float, Float>) {
            active += id to at
            send(if (active.size == 1) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_POINTER_DOWN, active.size - 1)
        }

        fun up(id: Int) {
            val index = active.indexOfFirst { it.first == id }
            send(if (active.size == 1) MotionEvent.ACTION_UP else MotionEvent.ACTION_POINTER_UP, index)
            active.removeAt(index)
        }

        private fun send(action: Int, index: Int) {
            val props = active.map { (id, _) ->
                MotionEvent.PointerProperties().apply { this.id = id; toolType = MotionEvent.TOOL_TYPE_FINGER }
            }.toTypedArray()
            val coords = active.map { (_, at) ->
                MotionEvent.PointerCoords().apply { x = at.first; y = at.second; pressure = 1f; size = 1f }
            }.toTypedArray()
            val event = MotionEvent.obtain(
                downTime, SystemClock.uptimeMillis(),
                action or (index shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                active.size, props, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
            )
            instr.uiAutomation.injectInputEvent(event, true)
            event.recycle()
            SystemClock.sleep(60)
        }
    }

    private fun launch(typed: String? = null) {
        val intent = Intent(instr.targetContext, KeyboardPreviewActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        typed?.let { intent.putExtra(KeyboardPreviewActivity.EXTRA_TYPE, it) }
        val started = instr.startActivitySync(intent)
        activity = started
        // Touches injected before the window takes input are dropped: wait
        // for focus, then for the window's entry animation to settle.
        val deadline = SystemClock.uptimeMillis() + 5_000
        var focused = false
        while (!focused && SystemClock.uptimeMillis() < deadline) {
            instr.runOnMainSync { focused = started.hasWindowFocus() }
            if (!focused) SystemClock.sleep(50)
        }
        assertTrue("the preview never took focus", focused)
        SystemClock.sleep(500)
        instr.waitForIdleSync()
    }

    private fun <T : View> find(root: View, cls: Class<T>, match: (T) -> Boolean): T? {
        if (cls.isInstance(root) && match(cls.cast(root)!!)) return cls.cast(root)
        if (root is ViewGroup) for (i in 0 until root.childCount) find(root.getChildAt(i), cls, match)?.let { return it }
        return null
    }

    /** The center, on screen, of the key on the plane showing whose cap matches. */
    private fun key(match: (KeyCap) -> Boolean): Pair<Float, Float> {
        var center: Pair<Float, Float>? = null
        instr.runOnMainSync {
            val key = find(activity!!.window.decorView, KeyButton::class.java) { it.isShown && match(it.spec.cap) }!!
            val loc = IntArray(2).also { key.getLocationOnScreen(it) }
            center = (loc[0] + key.width / 2f) to (loc[1] + key.height / 2f)
        }
        return center!!
    }

    private fun letter(c: Char) = key { (it as? KeyCap.Char)?.byte == c.code.toByte() }

    private fun fieldText(): String {
        instr.waitForIdleSync()
        var text = ""
        instr.runOnMainSync { text = find(activity!!.window.decorView, EditText::class.java) { true }!!.text.toString() }
        return text
    }

    /** What the engine commits for [keys] typed one after another. */
    private fun committed(keys: String): String {
        val out = StringBuilder()
        val session = InputSession()
        session.host = object : KeyboardHost {
            override fun insertText(text: String) { out.append(text) }
            override fun deleteBackward() {}
        }
        for (c in keys) session.handle(KeyAction.EngineKey(c.code.toByte()))
        session.close()
        return out.toString()
    }

    /**
     * Fast two-thumb typing: the next key goes down before the last one comes
     * up, and can come up first. Keys type in the order they went down — the
     * held one types when the next goes down — not in the order they come up.
     */
    @Test
    fun overlappingPressesTypeInPressOrder() {
        val inOrder = committed("nj ")
        assertNotEquals("the two orders must commit differently to tell them apart", committed("jn "), inOrder)
        launch()
        val fingers = Fingers()
        fingers.down(0, letter('n'))
        fingers.down(1, letter('j'))
        fingers.up(1)
        fingers.up(0)
        fingers.down(0, key { it == KeyCap.Space })
        fingers.up(0)
        assertEquals(inOrder, fieldText())
    }
}
