// The IME service — the role played by ios/Keyboard/KeyboardViewController.swift.
// Owns the engine session, hosts the reusable KeyboardView, forwards committed
// text to the host via the InputConnection, and keeps theme / return key in sync.
package com.hronro.imejd.ime

import android.content.Intent
import android.content.res.Configuration
import android.inputmethodservice.InputMethodService
import android.os.SystemClock
import android.view.View
import android.view.inputmethod.EditorInfo
import com.hronro.imejd.BuildConfig
import com.hronro.imejd.R
import com.hronro.imejd.app.MainActivity
import com.hronro.imejd.engine.InputSession
import com.hronro.imejd.engine.KeyAction
import com.hronro.imejd.engine.KeyboardHost
import com.hronro.imejd.ui.FieldPolicy
import com.hronro.imejd.ui.KeyboardTheme
import com.hronro.imejd.ui.KeyboardView
import com.hronro.imejd.update.UpdateChecker

class JdInputMethodService : InputMethodService(), KeyboardHost {

    // 16 per fetch — selection is by tap, so pages aren't capped at 9 the way
    // macOS's 1-9 digit labels cap them; bigger pages = fewer grid-fill round trips.
    private val session: InputSession by lazy { InputSession().also { it.host = this } }
    private var keyboard: KeyboardView? = null

    /**
     * When we last edited the host ourselves (commit / literal / delete), in
     * SystemClock.uptimeMillis time. onUpdateSelection uses it to tell our
     * own edits' echoes apart from external caret moves — see there.
     */
    private var lastOwnHostEdit = 0L

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
        // The field's inputType decides how the keyboard opens (FieldPolicy):
        // numeric fields on ?123, password fields with letters going straight
        // to the host. A restart on the same field — apps call restartInput
        // after programmatic edits, mid-typing — keeps the user's plane; only
        // a new field (or a fresh show) re-picks it.
        val inputType = info?.inputType ?: 0
        keyboard?.directInput = FieldPolicy.isPassword(inputType)
        if (!restarting) keyboard?.showLayer(FieldPolicy.openingLayer(inputType))
        // The daily update check rides on the keyboard appearing — the one
        // moment the IME is certainly in use. It is a prefs read when nothing
        // is due; a hit refreshes the idle-bar notice as soon as it lands.
        // Store builds have no updater at all (BuildConfig.AUTO_UPDATE).
        if (BuildConfig.AUTO_UPDATE) {
            UpdateChecker.checkIfDue(this) { refreshUpdateNotice() }
            refreshUpdateNotice()
        }
    }

    /**
     * Announce an update the user has not seen yet in the idle candidate bar.
     * Tapping it opens the container app (which holds the install flow) and
     * retires the notice for that version.
     */
    private fun refreshUpdateNotice() {
        val kb = keyboard ?: return
        val update = UpdateChecker.pendingNotice(this)
        if (update == null) {
            kb.setUpdateNotice(null, null)
            return
        }
        kb.setUpdateNotice(getString(R.string.update_notice, update.tag)) {
            UpdateChecker.markNoticeSeen(this)
            kb.setUpdateNotice(null, null)
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            requestHideSelf(0)
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        session.cancelAndReset()
    }

    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        candidatesStart: Int,
        candidatesEnd: Int,
    ) {
        super.onUpdateSelection(
            oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd,
        )
        // The host's caret moved. If it wasn't us — the user tapped elsewhere
        // in the field, or the app moved the selection — the in-flight
        // composition's context is gone: drop it (as on iOS) rather than let
        // a later commit land stale text at the new cursor. Our own commits
        // echo here too, and the drill-in echo arrives while a fresh
        // composition is legitimately live (commit + new composition in one
        // keystroke), so selection changes inside the grace window are
        // treated as our own echo. Field switches don't need any of this:
        // onStartInputView / onFinishInputView already reset. The
        // `keyboard != null` guard keeps a pre-view callback from force-
        // initializing the lazy session just to find it idle.
        if (keyboard != null && session.isComposing &&
            SystemClock.uptimeMillis() - lastOwnHostEdit > 150
        ) {
            session.cancelAndReset()
        }
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
            insertText("\n") // via KeyboardHost, so the edit is stamped as our own
        }
    }

    // KeyboardHost — committed text + host deletion via the InputConnection.

    override fun insertText(text: String) {
        lastOwnHostEdit = SystemClock.uptimeMillis()
        currentInputConnection?.commitText(text, 1)
    }

    override fun deleteBackward() {
        val ic = currentInputConnection ?: return
        lastOwnHostEdit = SystemClock.uptimeMillis()
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
