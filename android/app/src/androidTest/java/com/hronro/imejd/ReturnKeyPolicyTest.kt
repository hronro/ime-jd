// The return key's behavior (JdInputMethodService.onReturn) and its label/tint
// (KeyboardTheme.resolve / returnLabel) all derive from
// KeyboardTheme.effectiveAction; these tests pin that policy — most importantly
// that IME_FLAG_NO_ENTER_ACTION forces the newline path no matter what action
// the editor declares.
package com.hronro.imejd

import android.view.inputmethod.EditorInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hronro.imejd.ui.KeyboardTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReturnKeyPolicyTest {

    @Test
    fun plainActionPassesThrough() {
        assertEquals(
            EditorInfo.IME_ACTION_SEND,
            KeyboardTheme.effectiveAction(EditorInfo.IME_ACTION_SEND),
        )
    }

    @Test
    fun noEnterActionFlagForcesNewline() {
        // TextView sets this flag automatically on multiline editors with an
        // action (chat compose boxes) — enter must insert a newline there,
        // not fire the action.
        assertEquals(
            EditorInfo.IME_ACTION_NONE,
            KeyboardTheme.effectiveAction(
                EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_ENTER_ACTION,
            ),
        )
    }

    @Test
    fun unspecifiedStaysUnspecified() {
        assertEquals(EditorInfo.IME_ACTION_UNSPECIFIED, KeyboardTheme.effectiveAction(0))
    }

    @Test
    fun otherFlagBitsNeverLeakIntoTheAction() {
        assertEquals(
            EditorInfo.IME_ACTION_SEARCH,
            KeyboardTheme.effectiveAction(
                EditorInfo.IME_ACTION_SEARCH or EditorInfo.IME_FLAG_NO_FULLSCREEN,
            ),
        )
    }

    @Test
    fun labelAndTintFollowEffectiveAction() {
        val flagged = KeyboardTheme.effectiveAction(
            EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_ENTER_ACTION,
        )
        assertEquals("换行", KeyboardTheme.returnLabel(flagged))
        assertFalse(KeyboardTheme.returnIsTinted(flagged))

        val plain = KeyboardTheme.effectiveAction(EditorInfo.IME_ACTION_SEND)
        assertEquals("发送", KeyboardTheme.returnLabel(plain))
        assertTrue(KeyboardTheme.returnIsTinted(plain))
    }
}
