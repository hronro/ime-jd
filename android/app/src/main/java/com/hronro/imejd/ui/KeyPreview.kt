// Gboard-style key-preview balloons: pressing a character key floats an
// enlarged copy of its glyph just above the key. Native-keyboard behavior:
// instant show on press, instant hide on slide-off, a short linger on release
// (AOSP's 70ms key-preview linger timeout), and one balloon per finger (split
// motion events give each key its own touch stream). Character keys only —
// space/return/shift/backspace/layer keys never pop, matching Gboard.
package com.hronro.imejd.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
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
        val balloon = active.remove(key) ?: return
        host.removeView(balloon)
        if (pool.size < 3) pool.addLast(balloon)
    }
}

/** One floating balloon: a rounded key-colored surface with the enlarged glyph. */
private class KeyPreviewBalloon(context: Context) : View(context) {

    private val density = context.resources.displayMetrics.density
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
        textAlign = Paint.Align.CENTER
        // Enlarged from the key's 22sp, the Gboard-like ~1.5× pop.
        textSize = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP, 32f, context.resources.displayMetrics,
        )
    }
    private val inkBounds = Rect()
    private var text = ""
    private var inkCenter = false
    private var boundTheme: KeyboardTheme? = null

    init {
        elevation = 4f * density
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun bind(text: String, inkCenter: Boolean, theme: KeyboardTheme) {
        this.text = text
        this.inkCenter = inkCenter
        if (boundTheme !== theme) {
            boundTheme = theme
            textPaint.color = theme.keyText
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = 8f * density
                setColor(theme.keyPreviewBackground)
            }
        }
        invalidate()
    }

    fun textWidth(): Float = textPaint.measureText(text)

    override fun onDraw(canvas: Canvas) {
        if (text.isEmpty()) return
        textPaint.getTextBounds(text, 0, text.length, inkBounds)
        // Vertically center the INK box, not the font's ascent/descent span.
        // The balloon shows one glyph alone, and metric centering leaves
        // descender letters (y g p q j) visibly low at the enlarged size.
        // KeyButton keeps the metric baseline — a key row wants one shared
        // baseline — but a balloon optically centers each glyph on its own.
        val baseline = height / 2f - inkBounds.exactCenterY()
        var x = width / 2f
        if (inkCenter) {
            // Same horizontal ink-centering as KeyButton: fullwidth CJK
            // punctuation inks only the left half of its em advance.
            x += textPaint.measureText(text) / 2f - inkBounds.exactCenterX()
        }
        canvas.drawText(text, x, baseline, textPaint)
    }
}
