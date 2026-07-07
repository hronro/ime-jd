// The IME service — the role played by ios/Keyboard/KeyboardViewController.swift.
// Owns the engine session, hosts the reusable KeyboardView, forwards committed
// text to the host via the InputConnection, and keeps theme / return key in sync.
package com.hronro.imejd.ime

import android.content.res.Configuration
import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import com.hronro.imejd.engine.InputSession
import com.hronro.imejd.engine.KeyAction
import com.hronro.imejd.engine.KeyboardHost
import com.hronro.imejd.ui.KeyboardTheme
import com.hronro.imejd.ui.KeyboardView

class JdInputMethodService : InputMethodService(), KeyboardHost {

    // 16 per fetch — selection is by tap, so pages aren't capped at 9 the way
    // macOS's 1-9 digit labels cap them; bigger pages = fewer grid-fill round trips.
    private val session: InputSession by lazy { InputSession(pageSize = 16).also { it.host = this } }
    private var keyboard: KeyboardView? = null

    override fun onCreateInputView(): View {
        val opts = currentInputEditorInfo?.imeOptions ?: 0
        val kb = KeyboardView(this, session, KeyboardTheme.resolve(this, opts))
        kb.onReturn = { onReturn() }
        kb.returnLabel = KeyboardTheme.returnLabel(KeyboardTheme.effectiveAction(opts))
        keyboard = kb
        return kb
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        session.cancelAndReset()
        val opts = info?.imeOptions ?: 0
        keyboard?.applyTheme(KeyboardTheme.resolve(this, opts))
        keyboard?.returnLabel = KeyboardTheme.returnLabel(KeyboardTheme.effectiveAction(opts))
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        session.cancelAndReset()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Re-theme live when the system toggles dark/light (or wallpaper colors change).
        val opts = currentInputEditorInfo?.imeOptions ?: 0
        keyboard?.applyTheme(KeyboardTheme.resolve(this, opts))
        keyboard?.returnLabel = KeyboardTheme.returnLabel(KeyboardTheme.effectiveAction(opts))
    }

    private fun onReturn() {
        if (session.isComposing) {
            session.handle(KeyAction.CommitRaw)
            return
        }
        val ic = currentInputConnection ?: return
        val action = KeyboardTheme.effectiveAction(currentInputEditorInfo?.imeOptions ?: 0)
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
        // ⌫ with an active selection deletes the selection itself.
        // deleteSurroundingText operates AROUND the selection — it would eat
        // the character before it and leave the selected text in place.
        if (!ic.getSelectedText(0).isNullOrEmpty()) {
            ic.commitText("", 1)
            return
        }
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
