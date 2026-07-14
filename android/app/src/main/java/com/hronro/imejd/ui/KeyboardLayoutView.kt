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

    var returnLabel: String = "换行"
        set(value) {
            field = value
            forEachButton { if (it.spec.cap is KeyCap.Return) it.displayText = value }
        }

    private class RowItem(val spec: KeySpec, val button: KeyButton?)
    private var rows: List<List<RowItem>> = emptyList()
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

    fun setRows(specRows: List<List<KeySpec>>) {
        removeAllViews()
        rows = specRows.map { row ->
            row.map { spec ->
                if (spec.cap is KeyCap.Spacer) {
                    RowItem(spec, null)
                } else {
                    val b = KeyButton(context, spec, theme)
                    if (spec.cap is KeyCap.Return) b.displayText = returnLabel
                    b.onTap = { cap -> onKey?.invoke(cap) }
                    b.onPreview = { key, event -> onKeyPreview?.invoke(key, event) }
                    addView(b)
                    RowItem(spec, b)
                }
            }
        }
        updateShift(shift)
        requestLayout()
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
