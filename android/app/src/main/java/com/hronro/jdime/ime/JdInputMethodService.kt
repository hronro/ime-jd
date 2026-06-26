// The IME service — the role played by ios/Keyboard/KeyboardViewController.swift.
// Owns the engine session, hosts the reusable KeyboardView, forwards committed
// text to the host via the InputConnection, and keeps theme / return key in sync.
package com.hronro.jdime.ime

import android.content.res.Configuration
import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import com.hronro.jdime.engine.InputSession
import com.hronro.jdime.engine.KeyAction
import com.hronro.jdime.engine.KeyboardHost
import com.hronro.jdime.ui.KeyboardTheme
import com.hronro.jdime.ui.KeyboardView

class JdInputMethodService : InputMethodService(), KeyboardHost {

    private val session: InputSession by lazy { InputSession(pageSize = 9).also { it.host = this } }
    private var keyboard: KeyboardView? = null

    override fun onCreateInputView(): View {
        val action = currentInputEditorInfo?.imeOptions ?: EditorInfo.IME_ACTION_UNSPECIFIED
        val kb = KeyboardView(this, session, KeyboardTheme.resolve(this, action))
        kb.onReturn = { onReturn() }
        kb.returnLabel = KeyboardTheme.returnLabel(action and EditorInfo.IME_MASK_ACTION)
        keyboard = kb
        return kb
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        session.cancelAndReset()
        val action = info?.imeOptions ?: EditorInfo.IME_ACTION_UNSPECIFIED
        keyboard?.applyTheme(KeyboardTheme.resolve(this, action))
        keyboard?.returnLabel = KeyboardTheme.returnLabel(action and EditorInfo.IME_MASK_ACTION)
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        session.cancelAndReset()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Re-theme live when the system toggles dark/light (or wallpaper colors change).
        val action = currentInputEditorInfo?.imeOptions ?: EditorInfo.IME_ACTION_UNSPECIFIED
        keyboard?.applyTheme(KeyboardTheme.resolve(this, action))
        keyboard?.returnLabel = KeyboardTheme.returnLabel(action and EditorInfo.IME_MASK_ACTION)
    }

    private fun onReturn() {
        if (session.isComposing) {
            session.handle(KeyAction.CommitRaw)
            return
        }
        val ic = currentInputConnection ?: return
        val action = (currentInputEditorInfo?.imeOptions ?: 0) and EditorInfo.IME_MASK_ACTION
        if (action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) {
            ic.performEditorAction(action)
        } else {
            ic.commitText("\n", 1)
        }
    }

    // KeyboardHost — committed text + host deletion via the InputConnection.

    override fun insertText(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    override fun deleteBackward() {
        val ic = currentInputConnection ?: return
        // Delete one code point — handle surrogate pairs, not a fixed 1 unit.
        val before = ic.getTextBeforeCursor(2, 0) ?: ""
        val n = if (before.length >= 2 &&
            Character.isSurrogatePair(before[before.length - 2], before[before.length - 1])
        ) 2 else 1
        ic.deleteSurroundingText(n, 0)
    }

    override fun onDestroy() {
        session.close()
        super.onDestroy()
    }
}
