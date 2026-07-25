// A single key, Material-styled: rounded surface with a touch ripple, centered
// glyph, slide-off cancel, press-and-hold repeat for backspace, and
// press-and-hold alternates on grouped punctuation (hold expands the balloon
// into a row; sliding moves the selection; release commits it). (Logic follows
// ios/Keyboard/UI/KeyButton.swift; the look is native Android.)
package com.hronro.imejd.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.MotionEvent
import android.view.View
import androidx.core.content.ContextCompat
import com.hronro.imejd.R

@SuppressLint("ViewConstructor")
class KeyButton(
    context: Context,
    val spec: KeySpec,
    private var theme: KeyboardTheme,
) : View(context) {

    var onTap: ((KeyCap) -> Unit)? = null

    /** Preview-balloon lifecycle, emitted only for character keys (Char/InsertLiteral). */
    var onPreview: ((KeyButton, KeyPreviewEvent) -> Unit)? = null

    /** Press-and-hold alternates: expand the balloon into the group row (false
     *  when the owner shows no previews, e.g. tablets), slide the selection
     *  (key-local coordinates), and commit it (null when deselected). */
    var onAlternatesExpand: ((KeyButton) -> Boolean)? = null
    var onAlternatesSlide: ((KeyButton, Float, Float) -> Unit)? = null
    var onAlternatesCommit: ((KeyButton) -> String?)? = null

    var displayText: String = spec.cap.label
        set(value) { field = value; invalidate() }

    /** When true (shift armed/locked), render the key in the "active" light style. */
    var isAccented: Boolean = false
        set(value) { field = value; installBackground(); invalidate() }

    /** Special keys (shift/backspace/globe) render a vector icon instead of a glyph. */
    var icon: Drawable? = null
        set(value) { field = value?.mutate(); invalidate() }

    private val isRepeating get() = spec.cap is KeyCap.Backspace
    private val hasPreview get() = spec.cap is KeyCap.Char || spec.cap is KeyCap.InsertLiteral

    private val density = context.resources.displayMetrics.density
    private val corner = 8f * density
    private val expand = 8f * density

    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
        textAlign = Paint.Align.CENTER
        textSize = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP, fontSizeSp(spec.cap), context.resources.displayMetrics,
        )
    }

    private val handler = Handler(Looper.getMainLooper())
    private var repeatRunnable: Runnable? = null
    private var alternatesRunnable: Runnable? = null
    /** True once a press-and-hold expanded the balloon into the alternates row:
     *  tracking then slides the selection instead of press-highlighting. */
    private var showingAlternates = false
    private val inkBounds = Rect()

    init {
        installBackground()
        icon = defaultIcon()
    }

    fun apply(theme: KeyboardTheme) {
        this.theme = theme
        installBackground()
        invalidate()
    }

    private fun defaultIcon(): Drawable? = when (spec.cap) {
        KeyCap.Backspace -> ContextCompat.getDrawable(context, R.drawable.ic_backspace)
        KeyCap.Globe -> ContextCompat.getDrawable(context, R.drawable.ic_language)
        KeyCap.Shift -> ContextCompat.getDrawable(context, R.drawable.ic_shift)
        else -> null
    }

    private fun fontSizeSp(cap: KeyCap): Float = when (cap) {
        is KeyCap.Char, is KeyCap.InsertLiteral -> 22f
        KeyCap.Space, KeyCap.Return, is KeyCap.ToLayer, KeyCap.Globe, KeyCap.Spacer -> 16f
        KeyCap.Shift, KeyCap.Backspace -> 20f
    }

    private val isLightKey: Boolean get() = when (spec.cap) {
        is KeyCap.Char, is KeyCap.InsertLiteral, KeyCap.Space -> true
        else -> false
    }
    private val isReturnKey get() = spec.cap is KeyCap.Return

    private fun keyFill(): Int = when {
        isAccented -> theme.keyBackground       // active shift: lighter surface
        isReturnKey -> theme.returnBackground
        isLightKey -> theme.keyBackground
        else -> theme.specialKeyBackground
    }

    private fun textColor(): Int = when {
        isReturnKey -> theme.returnText
        isLightKey -> theme.keyText
        else -> theme.specialKeyText
    }

    // Rounded surface + a bounded Material ripple (clipped to the rounded mask).
    private fun installBackground() {
        val content = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = corner
            setColor(keyFill())
        }
        val mask = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = corner
            setColor(Color.WHITE)
        }
        background = RippleDrawable(ColorStateList.valueOf(theme.rippleColor), content, mask)
    }

    override fun onDraw(canvas: Canvas) {
        // Background (rounded surface + ripple) is drawn by View; we draw the icon or glyph.
        val ic = icon
        if (ic != null) {
            val size = (24 * density).toInt()
            val l = (width - size) / 2
            val t = (height - size) / 2
            ic.setBounds(l, t, l + size, t + size)
            ic.setTint(textColor())
            ic.draw(canvas)
            return
        }
        textPaint.color = textColor()
        val fm = textPaint.fontMetrics
        val baseline = height / 2f - (fm.ascent + fm.descent) / 2f
        var x = width / 2f
        if (spec.cap is KeyCap.InsertLiteral && displayText.isNotEmpty()) {
            // Fullwidth CJK punctuation (。，、！…) inks only the bottom-left of a
            // full-em advance. CoreText hides that on iOS by compressing the trailing
            // half-em at line ends; Android's Paint has no such rule, so centering the
            // advance leaves the mark visibly left of center. Center on the ink box
            // instead — horizontally only: the low vertical position is how these
            // marks sit in running text (and on the iOS keys).
            textPaint.getTextBounds(displayText, 0, displayText.length, inkBounds)
            x += textPaint.measureText(displayText) / 2f - inkBounds.exactCenterX()
        }
        canvas.drawText(displayText, x, baseline, textPaint)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                isPressed = true
                drawableHotspotChanged(event.x, event.y)
                preview(KeyPreviewEvent.SHOW)
                if (spec.alternates.isNotEmpty()) startAlternatesDelay()
                if (isRepeating) { fire(); startRepeat() }
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (showingAlternates) {
                    onAlternatesSlide?.invoke(this, event.x, event.y)
                    return true
                }
                val inside = insideExpanded(event.x, event.y)
                if (inside) {
                    if (!isPressed) { isPressed = true; preview(KeyPreviewEvent.SHOW) }
                    drawableHotspotChanged(event.x, event.y)
                } else {
                    if (isPressed) { isPressed = false; preview(KeyPreviewEvent.CANCEL) }
                    stopRepeat()
                    stopAlternatesDelay()
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                stopAlternatesDelay()
                if (showingAlternates) {
                    showingAlternates = false
                    isPressed = false
                    val value = onAlternatesCommit?.invoke(this)
                    if (value != null) {
                        // The primary commits like a plain tap (a future Char
                        // group must still go through the engine); alternates
                        // bypass it.
                        if (value == displayText) fire() else onTap?.invoke(KeyCap.InsertLiteral(value))
                    }
                    return true
                }
                val inside = insideExpanded(event.x, event.y)
                isPressed = false
                stopRepeat()
                preview(KeyPreviewEvent.RELEASE)
                if (!isRepeating && inside) fire()
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                stopAlternatesDelay()
                showingAlternates = false
                isPressed = false
                stopRepeat()
                preview(KeyPreviewEvent.CANCEL)
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun insideExpanded(x: Float, y: Float): Boolean =
        x >= -expand && y >= -expand && x <= width + expand && y <= height + expand

    private fun fire() = onTap?.invoke(spec.cap)

    private fun preview(event: KeyPreviewEvent) {
        if (hasPreview) onPreview?.invoke(this, event)
    }

    // Fire immediately on down, then after 350ms repeat every 100ms (matches iOS).
    private fun startRepeat() {
        val r = object : Runnable {
            override fun run() { fire(); handler.postDelayed(this, 100) }
        }
        repeatRunnable = r
        handler.postDelayed(r, 350)
    }

    private fun stopRepeat() {
        repeatRunnable?.let { handler.removeCallbacks(it) }
        repeatRunnable = null
    }

    // Hold ~450ms on a grouped key to swap the balloon for the alternates row.
    private fun startAlternatesDelay() {
        val r = Runnable {
            alternatesRunnable = null
            if (onAlternatesExpand?.invoke(this) == true) showingAlternates = true
        }
        alternatesRunnable = r
        handler.postDelayed(r, 450)
    }

    private fun stopAlternatesDelay() {
        alternatesRunnable?.let { handler.removeCallbacks(it) }
        alternatesRunnable = null
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        stopRepeat()
        stopAlternatesDelay()
        showingAlternates = false
        // Layer switches rebuild the key plane mid-press; don't strand a balloon.
        preview(KeyPreviewEvent.CANCEL)
    }
}
