// Port of ios/Keyboard/UI/KeyLayout.swift. Proportional key weights so one model
// lays out across phone/tablet and orientations. Key arrays/weights are copied
// verbatim — including the Chinese-punctuation rows and the omitted ';'.
package com.hronro.jdime.ui

/** Which key plane is showing. */
enum class KeyboardLayer { LETTERS, NUMBERS, SYMBOLS }

/**
 * What a key does. Character keys carry the literal ASCII byte sent to the engine
 * (the engine converts punctuation to its Chinese form and echoes everything else).
 */
sealed interface KeyCap {
    data class Char(val byte: Byte) : KeyCap              // a letter sent to the engine
    data class InsertLiteral(val text: String) : KeyCap   // digit / Chinese punctuation, inserted directly
    data object Backspace : KeyCap
    data object Shift : KeyCap
    data class ToLayer(val layer: KeyboardLayer) : KeyCap
    data object Globe : KeyCap
    data object Space : KeyCap
    data object Return : KeyCap
    data object Spacer : KeyCap                            // invisible gap; reserves width, no button

    /** Glyph shown on the key. */
    val label: String
        get() = when (this) {
            is Char -> (byte.toInt() and 0xFF).toChar().toString()
            is InsertLiteral -> text
            Backspace -> "⌫"
            Shift -> "⇧"
            is ToLayer -> when (layer) {
                KeyboardLayer.LETTERS -> "ABC"
                KeyboardLayer.NUMBERS -> "123"
                KeyboardLayer.SYMBOLS -> "#+="
            }
            Globe -> "🌐"
            Space -> "空格"
            Return -> "换行"
            Spacer -> ""
        }

    val isCharacter: Boolean get() = this is Char
}

/** A key plus its relative width within its row (1 = a standard letter key). */
data class KeySpec(val cap: KeyCap, val weight: Float = 1f)

enum class KeyboardIdiom { PHONE, PAD }

object KeyLayout {
    fun rows(layer: KeyboardLayer, idiom: KeyboardIdiom): List<List<KeySpec>> =
        when (layer) {
            KeyboardLayer.LETTERS -> letters(idiom)
            KeyboardLayer.NUMBERS -> numbers(idiom)
            KeyboardLayer.SYMBOLS -> symbols(idiom)
        }

    /** Key plane height in dp (excludes the candidate bar). */
    fun keysHeightDp(idiom: KeyboardIdiom, compactHeight: Boolean): Int =
        when (idiom) {
            KeyboardIdiom.PHONE -> if (compactHeight) 162 else 216
            KeyboardIdiom.PAD -> if (compactHeight) 352 else 264
        }

    // MARK: - Plane builders

    private fun charRow(s: String): List<KeySpec> =
        s.map { KeySpec(KeyCap.Char(it.code.toByte())) }

    private fun litRow(marks: List<String>): List<KeySpec> =
        marks.map { KeySpec(KeyCap.InsertLiteral(it)) }

    private fun letters(idiom: KeyboardIdiom): List<List<KeySpec>> = listOf(
        charRow("qwertyuiop"),
        // 9-key home row, centered. ';' is omitted: on desktop it picks the 2nd
        // candidate, but on mobile you tap the candidate instead.
        listOf(KeySpec(KeyCap.Spacer, 0.5f)) + charRow("asdfghjkl") + listOf(KeySpec(KeyCap.Spacer, 0.5f)),
        listOf(KeySpec(KeyCap.Shift, 1.5f)) + charRow("zxcvbnm") + listOf(KeySpec(KeyCap.Backspace, 1.5f)),
        bottomRow(idiom),
    )

    // Digits + Chinese punctuation, shown directly (not the ASCII forms). The two
    // pages together cover every mark in core/src/punctuation-marks/. Keys insert
    // their mark via the engine-bypass path (InputSession.insertLiteral).
    private fun numbers(idiom: KeyboardIdiom): List<List<KeySpec>> = listOf(
        litRow(listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0")),
        litRow(listOf("。", "，", "、", "？", "！", "：", "……", "·", "～", "｀")),
        listOf(KeySpec(KeyCap.ToLayer(KeyboardLayer.SYMBOLS), 1.5f)) +
            litRow(listOf("“", "”", "‘", "’", "（", "）", "《", "》")) +
            listOf(KeySpec(KeyCap.Backspace, 1.5f)),
        bottomRow(idiom, leftLayer = KeyboardLayer.LETTERS),
    )

    private fun symbols(idiom: KeyboardIdiom): List<List<KeySpec>> = listOf(
        litRow(listOf("「", "」", "【", "】", "〔", "〕", "［", "］", "『", "』")),
        litRow(listOf("〖", "〗", "｛", "｝", "＠", "＃", "＄", "％", "＆", "＊")),
        listOf(KeySpec(KeyCap.ToLayer(KeyboardLayer.NUMBERS), 1.5f)) +
            litRow(listOf("＋", "－", "＝", "＿", "｜", "¦", "＼", "／")) +
            listOf(KeySpec(KeyCap.Backspace, 1.5f)),
        bottomRow(idiom, leftLayer = KeyboardLayer.LETTERS),
    )

    /** `[123/ABC] [ space ] [ return ]`. No globe key — IME switching is offered by
     *  the system navigation bar's input-method switcher. */
    private fun bottomRow(
        idiom: KeyboardIdiom,
        leftLayer: KeyboardLayer = KeyboardLayer.NUMBERS,
    ): List<KeySpec> = listOf(
        KeySpec(KeyCap.ToLayer(leftLayer), 2.0f),
        KeySpec(KeyCap.Space, 6.0f),
        KeySpec(KeyCap.Return, 2.0f),
    )
}
