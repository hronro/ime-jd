// Material-style keyboard colors (Gboard-like), with light/dark palettes, dynamic
// color (Material You) on Android 12+, and a return key tinted/labelled from
// EditorInfo.imeOptions. Dark vs light follows the system night-mode config.
package com.hronro.jdime.ui

import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.view.inputmethod.EditorInfo

data class KeyboardTheme(
    val keyboardBackground: Int,
    val keyBackground: Int,         // letter/character keys
    val specialKeyBackground: Int,  // shift / 123 / backspace / globe
    val keyText: Int,
    val specialKeyText: Int,
    val candidateText: Int,
    val candidateHint: Int,
    val composingText: Int,
    val separator: Int,
    val accent: Int,                // action color (Material primary)
    val onAccent: Int,              // text/icon on the accent
    val rippleColor: Int,           // Material touch ripple
    // Resolved per field below from `accent`/`specialKey*` by resolve().
    val returnBackground: Int,
    val returnText: Int,
) {
    companion object {
        private fun withAlpha(color: Int, alpha: Int): Int =
            (alpha shl 24) or (color and 0x00FFFFFF)

        // Static Material palettes (Gboard-like), used <API 31 and as the dynamic-color fallback.
        val LIGHT = make(
            keyboardBackground = 0xFFE8EAED.toInt(),
            keyBackground = 0xFFFFFFFF.toInt(),
            specialKeyBackground = 0xFFDADCE0.toInt(),
            keyText = 0xFF202124.toInt(),
            candidateHint = 0xFF5F6368.toInt(),
            separator = 0xFFDADCE0.toInt(),
            accent = 0xFF1A73E8.toInt(),
            onAccent = 0xFFFFFFFF.toInt(),
        )

        val DARK = make(
            keyboardBackground = 0xFF202124.toInt(),
            keyBackground = 0xFF3C4043.toInt(),
            specialKeyBackground = 0xFF292A2D.toInt(),
            keyText = 0xFFE8EAED.toInt(),
            candidateHint = 0xFF9AA0A6.toInt(),
            separator = 0xFF3C4043.toInt(),
            accent = 0xFF8AB4F8.toInt(),
            onAccent = 0xFF202124.toInt(),
        )

        private fun make(
            keyboardBackground: Int,
            keyBackground: Int,
            specialKeyBackground: Int,
            keyText: Int,
            candidateHint: Int,
            separator: Int,
            accent: Int,
            onAccent: Int,
        ) = KeyboardTheme(
            keyboardBackground = keyboardBackground,
            keyBackground = keyBackground,
            specialKeyBackground = specialKeyBackground,
            keyText = keyText,
            specialKeyText = keyText,
            candidateText = keyText,
            candidateHint = candidateHint,
            composingText = candidateHint,
            separator = separator,
            accent = accent,
            onAccent = onAccent,
            rippleColor = withAlpha(accent, 0x33),
            returnBackground = specialKeyBackground,
            returnText = keyText,
        )

        fun resolve(context: Context, imeOptions: Int): KeyboardTheme {
            val dark = (context.resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
            val base = when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> dynamic(context, dark)
                dark -> DARK
                else -> LIGHT
            }
            val action = imeOptions and EditorInfo.IME_MASK_ACTION
            return if (returnIsTinted(action)) {
                base.copy(returnBackground = base.accent, returnText = base.onAccent)
            } else {
                base.copy(returnBackground = base.specialKeyBackground, returnText = base.specialKeyText)
            }
        }

        // Material You: derive the palette from the system wallpaper colors (API 31+).
        @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
        private fun dynamic(context: Context, dark: Boolean): KeyboardTheme {
            fun c(id: Int) = context.getColor(id)
            return if (dark) make(
                keyboardBackground = c(android.R.color.system_neutral1_900),
                keyBackground = c(android.R.color.system_neutral1_700),
                specialKeyBackground = c(android.R.color.system_neutral1_800),
                keyText = c(android.R.color.system_neutral1_50),
                candidateHint = c(android.R.color.system_neutral2_400),
                separator = c(android.R.color.system_neutral1_700),
                accent = c(android.R.color.system_accent1_200),
                onAccent = c(android.R.color.system_neutral1_900),
            ) else make(
                keyboardBackground = c(android.R.color.system_neutral2_100),
                keyBackground = c(android.R.color.system_neutral1_50),
                specialKeyBackground = c(android.R.color.system_neutral2_200),
                keyText = c(android.R.color.system_neutral1_900),
                candidateHint = c(android.R.color.system_neutral2_500),
                separator = c(android.R.color.system_neutral2_300),
                accent = c(android.R.color.system_accent1_600),
                onAccent = c(android.R.color.system_neutral1_50),
            )
        }

        fun returnIsTinted(action: Int): Boolean = when (action) {
            EditorInfo.IME_ACTION_NONE, EditorInfo.IME_ACTION_UNSPECIFIED -> false
            else -> true
        }

        /** Localized return-key label for the host's IME action. */
        fun returnLabel(action: Int): String = when (action) {
            EditorInfo.IME_ACTION_GO -> "前往"
            EditorInfo.IME_ACTION_SEARCH -> "搜索"
            EditorInfo.IME_ACTION_SEND -> "发送"
            EditorInfo.IME_ACTION_NEXT -> "下一项"
            EditorInfo.IME_ACTION_DONE -> "完成"
            EditorInfo.IME_ACTION_PREVIOUS -> "上一项"
            else -> "换行"
        }
    }
}
