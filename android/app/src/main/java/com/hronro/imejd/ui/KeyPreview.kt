// Gboard-style key-preview balloons: pressing a character key floats an
// enlarged copy of its glyph just above the key. Native-keyboard behavior:
// instant show on press, instant hide on slide-off, a short linger on release
// (AOSP's 70ms key-preview linger timeout), and one balloon per finger (split
// motion events give each key its own touch stream). Character keys only —
// space/return/shift/backspace/layer keys never pop, matching Gboard.
//
// Press-and-hold on a key with `KeySpec.alternates` expands its balloon into a
// row of grouped marks (primary first): the finger slides to move the accent
// highlight, release commits, sliding well below the key deselects. The row
// extends toward the screen's center — display order reversed on the right
// half — so the primary starts out directly above the finger, like Gboard.
package com.hronro.imejd.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** Press lifecycle of a previewable key, reported by KeyButton. */
enum class KeyPreviewEvent { SHOW, RELEASE, CANCEL }

private const val LINGER_MS = 70L // AOSP config_key_preview_linger_timeout

/**
 * Owns the balloons for one keyboard: geometry, linger timing, and a small
 * recycle pool. Balloons are children of the host FrameLayout (KeyboardView),
 * so top-row previews float over the candidate bar the way Gboard's float
 * over its suggestion strip — no popup windows involved.
 */
class KeyPreviewController(private val host: FrameLayout, private var theme: KeyboardTheme) {

    private val density = host.resources.displayMetrics.density
    private val active = HashMap<KeyButton, KeyPreviewBalloon>()
    private val pendingHides = HashMap<KeyButton, Runnable>()
    private val pool = ArrayDeque<KeyPreviewBalloon>()

    /** Slide bookkeeping for one expanded alternates row, in host coordinates. */
    private class ExpandedState(
        val cells: List<String>,       // display order (reversed on the right half)
        val contentLeft: Float,        // left edge of cell 0
        val cellWidth: Float,
        val keyFrame: Rect,
        var selected: Int?,
    )

    private val expanded = HashMap<KeyButton, ExpandedState>()

    fun handle(key: KeyButton, event: KeyPreviewEvent) = when (event) {
        KeyPreviewEvent.SHOW -> show(key)
        KeyPreviewEvent.RELEASE -> scheduleHide(key)
        KeyPreviewEvent.CANCEL -> hideNow(key)
    }

    fun apply(theme: KeyboardTheme) {
        this.theme = theme
        // Live balloons are transient; drop them rather than restyle mid-press.
        // Hide before clearing so re-pooled stale-colored balloons don't survive.
        for (key in active.keys.toList()) hideNow(key)
        pool.clear()
    }

    private fun show(key: KeyButton) {
        pendingHides.remove(key)?.let(host::removeCallbacks)
        val fresh = active[key] == null
        val balloon = active.getOrPut(key) {
            pool.removeLastOrNull() ?: KeyPreviewBalloon(host.context)
        }
        balloon.bind(key.displayText, key.spec.cap is KeyCap.InsertLiteral, theme)

        // Key frame in host coordinates. The balloon is wider than the key and
        // sits a key-gap above it; clamps keep it inside the host — edge keys
        // shift inward, and the top row floats over the candidate bar.
        val keyRect = Rect(0, 0, key.width, key.height)
        host.offsetDescendantRectToMyCoords(key, keyRect)
        val margin = 2f * density
        val widen = (16f * density).toInt()
        val w = max(key.width + widen, (balloon.textWidth() + widen).toInt())
        val h = key.height
        val x = min(max(keyRect.exactCenterX() - w / 2f, margin), host.width - w - margin)
        val y = max(keyRect.top - 8f * density - h, margin)
        place(balloon, fresh, w, h, x, y)
    }

    // MARK: - Press-and-hold alternates (driven by KeyButton)

    /** Expand [key]'s balloon into its alternates row; false when it has none. */
    fun expandAlternates(key: KeyButton): Boolean {
        val values = listOf(key.displayText) + key.spec.alternates
        if (values.size < 2) return false
        pendingHides.remove(key)?.let(host::removeCallbacks)
        val fresh = active[key] == null
        val balloon = active.getOrPut(key) {
            pool.removeLastOrNull() ?: KeyPreviewBalloon(host.context)
        }

        val keyRect = Rect(0, 0, key.width, key.height)
        host.offsetDescendantRectToMyCoords(key, keyRect)

        // Cells extend toward the screen's center, so the row stays on-screen
        // and the primary value starts out above the finger.
        val reversed = keyRect.exactCenterX() > host.width / 2f
        val cells = if (reversed) values.reversed() else values
        val selected = if (reversed) cells.size - 1 else 0
        val pad = 6f * density
        val cellWidth = max(key.width.toFloat(), 40f * density)
        val margin = 2f * density
        val w = cells.size * cellWidth + 2 * pad
        val h = key.height
        var x = if (reversed) {
            keyRect.exactCenterX() + pad + cellWidth / 2f - w
        } else {
            keyRect.exactCenterX() - pad - cellWidth / 2f
        }
        x = min(max(x, margin), host.width - w - margin)
        val y = max(keyRect.top - 8f * density - h, margin)

        balloon.bindRow(cells, selected, cellWidth, pad, theme)
        place(balloon, fresh, w.toInt(), h, x, y)
        expanded[key] = ExpandedState(cells, x + pad, cellWidth, keyRect, selected)
        return true
    }

    /** Move the selection for a touch at ([x], [y]) in [key]'s coordinates. */
    fun slideAlternates(key: KeyButton, x: Float, y: Float) {
        val st = expanded[key] ?: return
        val hostX = st.keyFrame.left + x
        val hostY = st.keyFrame.top + y
        // Sliding well below the key deselects, so the press can be abandoned.
        val sel = if (hostY > st.keyFrame.bottom + 30f * density) {
            null
        } else {
            val i = floor((hostX - st.contentLeft) / st.cellWidth).toInt()
            min(max(i, 0), st.cells.size - 1)
        }
        if (sel != st.selected) {
            st.selected = sel
            active[key]?.setSelected(sel)
        }
    }

    /** Tear down [key]'s row and return the selected mark (null if deselected). */
    fun commitAlternates(key: KeyButton): String? {
        val st = expanded[key] ?: return null
        val value = st.selected?.let(st.cells::get)
        hideNow(key)
        return value
    }

    private fun place(balloon: KeyPreviewBalloon, fresh: Boolean, w: Int, h: Int, x: Float, y: Float) {
        if (fresh) {
            // Absolute LEFT (not START): balloons are positioned in LTR keyboard
            // coordinates and must not flip under an RTL system locale.
            host.addView(balloon, FrameLayout.LayoutParams(w, h, Gravity.TOP or Gravity.LEFT))
        } else {
            val lp = balloon.layoutParams
            if (lp.width != w || lp.height != h) {
                lp.width = w
                lp.height = h
                balloon.layoutParams = lp
            }
        }
        balloon.translationX = x
        balloon.translationY = y
    }

    private fun scheduleHide(key: KeyButton) {
        if (!active.containsKey(key) || pendingHides.containsKey(key)) return
        val r = Runnable {
            pendingHides.remove(key)
            hideNow(key)
        }
        pendingHides[key] = r
        host.postDelayed(r, LINGER_MS)
    }

    private fun hideNow(key: KeyButton) {
        pendingHides.remove(key)?.let(host::removeCallbacks)
        expanded.remove(key)
        val balloon = active.remove(key) ?: return
        host.removeView(balloon)
        if (pool.size < 3) pool.addLast(balloon)
    }
}

/**
 * One floating balloon: a rounded key-colored surface with either the enlarged
 * glyph of a pressed key, or the press-and-hold row of alternates with the
 * accent selection highlight.
 */
private class KeyPreviewBalloon(context: Context) : View(context) {

    private val density = context.resources.displayMetrics.density
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
        textAlign = Paint.Align.CENTER
    }
    private val highlightPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val highlightRect = RectF()
    private val inkBounds = Rect()
    // Enlarged from the key's 22sp, the Gboard-like ~1.5× pop; row cells run
    // slightly smaller so a group reads as a menu, not a wall.
    private val singleTextPx = sp(32f)
    private val cellTextPx = sp(24f)
    private var text = ""
    private var inkCenter = false
    private var cells: List<String>? = null   // non-null → alternates-row mode
    private var selected: Int? = null
    private var cellWidth = 0f
    private var pad = 0f
    private var boundTheme: KeyboardTheme? = null

    init {
        elevation = 4f * density
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private fun sp(v: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, context.resources.displayMetrics)

    fun bind(text: String, inkCenter: Boolean, theme: KeyboardTheme) {
        this.text = text
        this.inkCenter = inkCenter
        this.cells = null
        this.selected = null
        ensureTheme(theme)
        invalidate()
    }

    fun bindRow(cells: List<String>, selected: Int, cellWidth: Float, pad: Float, theme: KeyboardTheme) {
        this.cells = cells
        this.selected = selected
        this.cellWidth = cellWidth
        this.pad = pad
        ensureTheme(theme)
        invalidate()
    }

    fun setSelected(index: Int?) {
        if (selected == index) return
        selected = index
        invalidate()
    }

    private fun ensureTheme(theme: KeyboardTheme) {
        if (boundTheme === theme) return
        boundTheme = theme
        highlightPaint.color = theme.accent
        background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = 8f * density
            setColor(theme.keyPreviewBackground)
        }
    }

    fun textWidth(): Float {
        textPaint.textSize = singleTextPx
        return textPaint.measureText(text)
    }

    override fun onDraw(canvas: Canvas) {
        val theme = boundTheme ?: return
        val row = cells
        if (row == null) {
            if (text.isEmpty()) return
            textPaint.textSize = singleTextPx
            textPaint.color = theme.keyText
            drawGlyph(canvas, text, width / 2f, inkCenter)
            return
        }
        for ((i, cell) in row.withIndex()) {
            val left = pad + i * cellWidth
            if (i == selected) {
                highlightRect.set(
                    left + 2f * density, 4f * density,
                    left + cellWidth - 2f * density, height - 4f * density,
                )
                canvas.drawRoundRect(highlightRect, 8f * density, 8f * density, highlightPaint)
            }
            // Wide entries (…… ——) shrink to their cell, like the iOS callout.
            textPaint.textSize = cellTextPx
            val w = textPaint.measureText(cell)
            val maxW = cellWidth - 4f * density
            if (w > maxW) textPaint.textSize = cellTextPx * maxW / w
            textPaint.color = if (i == selected) theme.onAccent else theme.keyText
            drawGlyph(canvas, cell, left + cellWidth / 2f, inkCenter = true)
        }
    }

    private fun drawGlyph(canvas: Canvas, glyph: String, centerX: Float, inkCenter: Boolean) {
        textPaint.getTextBounds(glyph, 0, glyph.length, inkBounds)
        // Vertically center the INK box, not the font's ascent/descent span.
        // The balloon shows a glyph alone, and metric centering leaves
        // descender letters (y g p q j) visibly low at the enlarged size.
        // KeyButton keeps the metric baseline — a key row wants one shared
        // baseline — but a balloon optically centers each glyph on its own.
        val baseline = height / 2f - inkBounds.exactCenterY()
        var x = centerX
        if (inkCenter) {
            // Same horizontal ink-centering as KeyButton: fullwidth CJK
            // punctuation inks only the left half of its em advance.
            x += textPaint.measureText(glyph) / 2f - inkBounds.exactCenterX()
        }
        canvas.drawText(glyph, x, baseline, textPaint)
    }
}
