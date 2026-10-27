// What a host field asks of the keyboard, read off its EditorInfo — the
// counterpart of iOS's KeyboardLayer.initial(for:), plus the password and
// ASCII rules Android needs and iOS doesn't (iOS hands secure and
// ASCII-capable fields to the system keyboard; Android shows third-party
// IMEs there).
package com.hronro.imejd.ui

import android.text.InputType
import android.view.inputmethod.EditorInfo

object FieldPolicy {
    /**
     * The plane a field opens on. Numeric classes — number / phone / datetime,
     * i.e. 验证码, 手机号, 金额 fields — open on ?123 so the digits sit under the
     * thumb instead of one plane switch away, as the built-in and the
     * mainstream Chinese keyboards do. Android never swaps IMEs for a field on
     * its own (unlike iOS, which gives numeric fields its own pads), and a
     * number field's key listener silently drops every Chinese character
     * committed into it, so on letters the user would type into the void.
     * Text classes open on letters, email / URI variations included: this
     * keyboard is Chinese-only, and non-Chinese text belongs to another
     * keyboard (see the README).
     */
    fun openingLayer(inputType: Int): KeyboardLayer =
        when (inputType and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_NUMBER, InputType.TYPE_CLASS_PHONE, InputType.TYPE_CLASS_DATETIME ->
                KeyboardLayer.NUMBERS
            else -> KeyboardLayer.LETTERS
        }

    /**
     * Whether the field is a password. Letters then bypass the engine and land
     * in the host exactly as typed — no composition, no candidates — because a
     * masked field gives no hint that a stray space just committed a Chinese
     * candidate into it. Covers the text and number password variations,
     * visible passwords included (same field, same expectations).
     */
    fun isPassword(inputType: Int): Boolean {
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (inputType and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT ->
                variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    /**
     * Whether letters bypass the engine: in a password field ([isPassword]),
     * and in one whose imeOptions carry IME_FLAG_FORCE_ASCII — an account ID,
     * the 编码 field of the container app's phrase dialog. Android asks a
     * keyboard that cannot type ASCII by default to honour the flag, and on
     * this one every letter composes.
     */
    fun isDirectInput(inputType: Int, imeOptions: Int): Boolean =
        isPassword(inputType) || (imeOptions and EditorInfo.IME_FLAG_FORCE_ASCII) != 0
}
