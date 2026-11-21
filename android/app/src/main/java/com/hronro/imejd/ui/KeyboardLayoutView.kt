// Port of ios/Keyboard/UI/KeyboardLayoutView.swift. The key plane: rows of
// KeyButtons laid out by proportional weights (so one model fits any width and
// orientation). A `.Spacer` spec reserves width without a button, to center rows.
package com.hronro.imejd.ui

import android.annotation.SuppressLint
import android.content.Context
import android.view.ViewGroup
import androidx.core.content.ContextCompat
import com.hronro.imejd.R
import kotlin.math.roundToInt

enum class ShiftState { OFF, ONE_SHOT, LOCKED }

@SuppressLint("ViewConstructor")
class KeyboardLayoutView(
    context: Context,
    private var theme: KeyboardTheme,
    idiom: KeyboardIdiom,
) : ViewGroup(context) {

    var onKey: ((KeyCap) -> Unit)? = null

    /** Forwarded KeyButton preview events; the owner routes them to the balloon layer. */
    var onKeyPreview: ((KeyButton, KeyPreviewEvent) -> Unit)? = null

    /** Forwarded press-and-hold alternates callbacks (see KeyButton). */
    var onAlternatesExpand: ((KeyButton) -> Boolean)? = null
    var onAlternatesSlide: ((KeyButton, Float, Float) -> Unit)? = null
    var onAlternatesCommit: ((KeyButton) -> String?)? = null

    var returnLabel: String = "换行"
        set(value) {
            field = value
            forEachButton { if (it.spec.cap is KeyCap.Return) it.displayText = value }
        }

    private class RowItem(val spec: KeySpec, val button: KeyButton?)
    /** The plane on screen. */
    private var rows: List<List<RowItem>> = emptyList()
    /**
     * The planes built so far (letters, 123, #+=), kept so that switching back
     * to one shows its buttons again instead of building ~35 new ones on every
     * trip to 123 for a mark. A kept plane's buttons stay children, GONE while
     * another plane shows. Everything else that shapes the keys (the idiom) is
     * fixed for this view's life.
     */
    private val planes = HashMap<KeyboardLayer, List<List<RowItem>>>()
    private var shift: ShiftState = ShiftState.OFF

    private val density = context.resources.displayMetrics.density
    private val hGap = (if (idiom == KeyboardIdiom.PAD) 7f else 5f) * density
    private val vGap = 8f * density
    private val sideMargin = (if (idiom == KeyboardIdiom.PAD) 5f else 3f) * density
    private val topMargin = 5f * density

    init { clipChildren = false }

    private inline fun forEachButton(body: (KeyButton) -> Unit) {
        for (row in rows) for (item in row) item.button?.let(body)
    }

    /** Show [layer]'s keys: its buttons as built earlier, else built now from
     *  [specRows] and kept. Brings a kept plane up to date with the theme and
     *  return label it missed while hidden; the owner re-asserts the shift. */
    fun showPlane(layer: KeyboardLayer, specRows: () -> List<List<KeySpec>>) {
        val kept = planes[layer]
        if (kept != null && kept === rows) return
        forEachButton { it.leavePlane(); it.visibility = GONE }
        if (kept != null) {
            rows = kept
            forEachButton { b ->
                b.apply(theme)
                if (b.spec.cap is KeyCap.Return) b.displayText = returnLabel
                b.visibility = VISIBLE
            }
        } else {
            rows = build(specRows())
            planes[layer] = rows
        }
        requestLayout()
    }

    private fun build(specRows: List<List<KeySpec>>): List<List<RowItem>> =
        specRows.map { row ->
            row.map { spec ->
                if (spec.cap is KeyCap.Spacer) {
                    RowItem(spec, null)
                } else {
                    val b = KeyButton(context, spec, theme)
                    if (spec.cap is KeyCap.Return) b.displayText = returnLabel
                    b.onTap = { cap -> onKey?.invoke(cap) }
                    b.onPressBegan = { pressed -> rollOver(pressed) }
                    b.onPreview = { key, event -> onKeyPreview?.invoke(key, event) }
                    b.onAlternatesExpand = { key -> onAlternatesExpand?.invoke(key) ?: false }
                    b.onAlternatesSlide = { key, x, y -> onAlternatesSlide?.invoke(key, x, y) }
                    b.onAlternatesCommit = { key -> onAlternatesCommit?.invoke(key) }
                    addView(b)
                    RowItem(spec, b)
                }
            }
        }

    /** A key went down: type any other key still held (see
     *  [KeyButton.commitForRollover]), in the order they were pressed. */
    private fun rollOver(pressed: KeyButton) {
        val held = ArrayList<KeyButton>(2)
        forEachButton { if (it !== pressed && it.isTracking) held.add(it) }
        held.sortBy { it.pressOrder }
        for (key in held) key.commitForRollover()
    }

    fun apply(theme: KeyboardTheme) {
        this.theme = theme
        forEachButton { it.apply(theme) }
    }

    fun updateShift(state: ShiftState) {
        shift = state
        forEachButton { b ->
            when (val cap = b.spec.cap) {
                is KeyCap.Char -> {
                    val byte = cap.byte.toInt() and 0xFF
                    if (byte in 0x61..0x7A) {
                        val lower = byte.toChar().toString()
                        b.displayText = if (state == ShiftState.OFF) lower else lower.uppercase()
                    }
                }
                KeyCap.Shift -> {
                    b.icon = ContextCompat.getDrawable(
                        context,
                        if (state == ShiftState.LOCKED) R.drawable.ic_caps_lock else R.drawable.ic_shift,
                    )
                    b.isAccented = state != ShiftState.OFF
                }
                else -> {}
            }
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(w, h)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val rowCount = rows.size
        if (rowCount == 0) return
        val width = (r - l).toFloat()
        val height = (b - t).toFloat()
        val totalV = height - 2 * topMargin - (rowCount - 1) * vGap
        val rowHeight = totalV / rowCount

        var y = topMargin
        for (row in rows) {
            val sumWeights = row.fold(0f) { acc, item -> acc + item.spec.weight }
            val availW = width - 2 * sideMargin - (row.size - 1) * hGap
            var x = sideMargin
            for (item in row) {
                val cw = availW * (item.spec.weight / sumWeights)
                item.button?.let { btn ->
                    val left = x.roundToInt()
                    val top = y.roundToInt()
                    btn.measure(
                        MeasureSpec.makeMeasureSpec(cw.roundToInt(), MeasureSpec.EXACTLY),
                        MeasureSpec.makeMeasureSpec(rowHeight.roundToInt(), MeasureSpec.EXACTLY),
                    )
                    btn.layout(left, top, (x + cw).roundToInt(), (y + rowHeight).roundToInt())
                }
                x += cw + hGap
            }
            y += rowHeight + vGap
        }
    }
}
