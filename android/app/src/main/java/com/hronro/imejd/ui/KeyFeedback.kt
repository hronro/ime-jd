// Key-press feedback — counterpart of ios/Keyboard/UI/KeyClick.swift, plus
// vibration (on iOS haptics require Full Access, so the keyboard there only
// clicks; Android has no such gate). Both channels follow the built-in
// keyboards' conventions (Gboard/AOSP): the system keypress sound set via
// AudioManager, the system-tuned KEYBOARD_TAP haptic, and user toggles —
// persisted here, surfaced as switches in the container app (MainActivity).
// The app, the embedded preview, and the IME service all run in this one
// process, and the prefs are re-read per press, so a flipped switch applies
// on the very next key with no listener plumbing.
package com.hronro.imejd.ui

import android.content.Context
import android.content.SharedPreferences
import android.media.AudioManager
import android.view.HapticFeedbackConstants
import android.view.View

object KeyFeedback {

    private const val PREFS = "keyboard_settings"
    private const val PREF_SOUND = "key_sound"
    private const val PREF_VIBRATION = "key_vibration"

    // Both default ON: sound matches the iOS keyboard (which always clicks —
    // the toggle is the Android affordance, not a different default), and
    // vibration matches Gboard's out-of-the-box behavior.
    fun isSoundEnabled(context: Context): Boolean =
        prefs(context).getBoolean(PREF_SOUND, true)

    fun isVibrationEnabled(context: Context): Boolean =
        prefs(context).getBoolean(PREF_VIBRATION, true)

    fun setSoundEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(PREF_SOUND, enabled).apply()
    }

    fun setVibrationEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(PREF_VIBRATION, enabled).apply()
    }

    /** Touch-down feedback for a key. */
    fun play(view: View, cap: KeyCap) {
        val fx = when (cap) {
            // The system set has no modifier sound (unlike iOS's 1156): only
            // delete/return/space are distinct, everything else is "standard".
            is KeyCap.Char, is KeyCap.InsertLiteral,
            KeyCap.Shift, is KeyCap.ToLayer, KeyCap.Globe,
            -> AudioManager.FX_KEYPRESS_STANDARD
            KeyCap.Backspace -> AudioManager.FX_KEYPRESS_DELETE
            KeyCap.Space -> AudioManager.FX_KEYPRESS_SPACEBAR
            KeyCap.Return -> AudioManager.FX_KEYPRESS_RETURN
            KeyCap.Spacer -> return
        }
        perform(view, fx)
    }

    /** Candidate taps insert text, so they use the letter-key sound. */
    fun playInput(view: View) = perform(view, AudioManager.FX_KEYPRESS_STANDARD)

    /** Bar/grid controls (expand chevron, close). */
    fun playModifier(view: View) = perform(view, AudioManager.FX_KEYPRESS_STANDARD)

    private fun perform(view: View, fx: Int) {
        val prefs = prefs(view.context)
        if (prefs.getBoolean(PREF_SOUND, true)) {
            // The volume overload deliberately skips the system-wide "touch
            // sounds" check the plain one makes — our own toggle is the gate
            // (the AOSP keyboard uses this overload for the same reason).
            // -1 = the system's default effect volume. Playback is async in
            // the system server, and the silent/vibrate ringer still mutes
            // it, both like the built-in keyboards.
            val am = view.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.playSoundEffect(fx, -1f)
        }
        if (prefs.getBoolean(PREF_VIBRATION, true)) {
            // The system-tuned soft-keyboard haptic; needs no VIBRATE
            // permission. The flag frees it from the system "touch feedback"
            // toggle since we gate ourselves. API 33 deprecated the flag to a
            // no-op for unprivileged apps, but API 34+ moved keyboard haptics
            // under a dedicated default-on system toggle, so in practice our
            // switch stays the deciding one.
            @Suppress("DEPRECATION")
            view.performHapticFeedback(
                HapticFeedbackConstants.KEYBOARD_TAP,
                HapticFeedbackConstants.FLAG_IGNORE_GLOBAL_SETTING,
            )
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
