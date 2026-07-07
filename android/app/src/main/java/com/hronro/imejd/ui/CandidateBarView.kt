// Port of ios/Keyboard/UI/CandidateBarView.swift. The always-visible strip: the
// in-flight code on the left, a horizontally scrolling row of candidates, and an
// expand chevron on the right. A dumb renderer — the owner supplies items and
// handles selection / lazy loading.
package com.hronro.imejd.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.RippleDrawable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.AbsoluteSizeSpan
import android.text.style.ForegroundColorSpan
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import com.hronro.imejd.engine.Candidate

@SuppressLint("ViewConstructor")
class CandidateBarView(context: Context, private var theme: KeyboardTheme) : LinearLayout(context) {

    companion object {
        const val HEIGHT_DP = 44

        /** Candidate value (large) + optional hint in 〔…〕 (small, gray). Shared with the grid. */
        fun styledTitle(cand: Candidate, theme: KeyboardTheme, density: Float): CharSequence {
            val sb = SpannableStringBuilder()
            val v = cand.value
            sb.append(v)
            sb.setSpan(AbsoluteSizeSpan((21 * density).toInt()), 0, v.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            sb.setSpan(ForegroundColorSpan(theme.candidateText), 0, v.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val hint = cand.hint
            if (!hint.isNullOrEmpty()) {
                val start = sb.length
                sb.append(" 〔").append(hint).append("〕")
                sb.setSpan(AbsoluteSizeSpan((13 * density).toInt()), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                sb.setSpan(ForegroundColorSpan(theme.candidateHint), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            return sb
        }
    }

    var onSelect: ((Int) -> Unit)? = null
    var onExpand: (() -> Unit)? = null
    var onNeedMore: (() -> Unit)? = null

    private val density = context.resources.displayMetrics.density
    private val composingLabel = TextView(context)
    private val scroll = HorizontalScrollView(context)
    private val stack = LinearLayout(context)
    private val expandButton = ChevronView(context, pointsUp = false)
    private val separatorPaint = Paint()
    private var shownCount = 0

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setWillNotDraw(false)
        build()
        apply(theme)
    }

    private fun dp(v: Int) = (v * density).toInt()

    private fun build() {
        composingLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        composingLabel.setPadding(dp(10), 0, dp(6), 0)
        addView(composingLabel, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))

        stack.orientation = LinearLayout.HORIZONTAL
        stack.gravity = Gravity.CENTER_VERTICAL
        scroll.isHorizontalScrollBarEnabled = false
        scroll.addView(stack, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))
        scroll.setOnScrollChangeListener { _, scrollX, _, _, _ ->
            if (scrollX + scroll.width * 2 >= stack.width) onNeedMore?.invoke()
        }
        addView(scroll, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))

        // The system keyboards' affordance: a thin secondary-gray chevron in a 44dp
        // box (equal to the grid's close button, so the expand/collapse flip lands in
        // place). Starts GONE so the idle bar shows nothing — reset() decides
        // visibility once a composition has candidates.
        expandButton.visibility = View.GONE
        expandButton.setOnClickListener { onExpand?.invoke() }
        addView(expandButton, LayoutParams(dp(44), LayoutParams.MATCH_PARENT))
    }

    fun apply(theme: KeyboardTheme) {
        this.theme = theme
        composingLabel.setTextColor(theme.composingText)
        expandButton.tint = theme.candidateHint
        expandButton.background = rippleBackground(theme)
        separatorPaint.color = theme.separator
        separatorPaint.strokeWidth = 0.5f * density
        invalidate()
    }

    /** Replace the strip with a fresh page. */
    fun reset(composing: String, items: List<Candidate>, canExpand: Boolean) {
        composingLabel.text = composing
        stack.removeAllViews()
        shownCount = 0
        scroll.scrollTo(0, 0)
        append(items)
        expandButton.visibility = if (canExpand) View.VISIBLE else View.GONE
    }

    /** Append a freshly-loaded page of candidates (lazy pagination). */
    fun append(items: List<Candidate>) {
        for (cand in items) {
            val idx = shownCount
            if (idx > 0) stack.addView(separator())
            stack.addView(cell(cand, idx))
            shownCount++
        }
    }

    private fun cell(cand: Candidate, index: Int): TextView {
        return TextView(context).apply {
            text = styledTitle(cand, theme, density)
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(4), dp(12), dp(4))
            isClickable = true
            background = rippleBackground(theme)
            setOnClickListener { onSelect?.invoke(index) }
        }
    }

    private fun rippleBackground(theme: KeyboardTheme) =
        RippleDrawable(ColorStateList.valueOf(theme.rippleColor), null, ColorDrawable(Color.WHITE))

    private fun separator(): View {
        return View(context).apply {
            setBackgroundColor(theme.separator)
            layoutParams = LinearLayout.LayoutParams((0.5f * density).toInt().coerceAtLeast(1), dp(24)).apply {
                gravity = Gravity.CENTER_VERTICAL
            }
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // Top separator hairline.
        canvas.drawLine(0f, 0.25f * density, width.toFloat(), 0.25f * density, separatorPaint)
    }
}

/**
 * The Material `expand_more` / `expand_less` chevron — the affordance Gboard uses
 * in its suggestion strip — drawn from the icon's 24dp-viewport path, so the shape
 * matches exactly (45° arms, 2dp thickness, sharp apex, vertically-cut tips).
 * Text glyphs like ▾ render as filled triangles, which is why this is drawn
 * instead. Colored via [tint].
 */
class ChevronView(context: Context, private val pointsUp: Boolean) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val path = Path()

    var tint: Int = 0
        set(value) {
            field = value
            paint.color = value
            invalidate()
        }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // Material expand_more path in its 24dp viewport, centered in whatever box
        // the owner gives the view; expand_less is its exact vertical mirror.
        val s = resources.displayMetrics.density
        val ox = (w - 24f * s) / 2f
        val oy = (h - 24f * s) / 2f
        fun x(v: Float) = ox + v * s
        fun y(v: Float) = oy + (if (pointsUp) 24f - v else v) * s
        path.reset()
        path.moveTo(x(16.59f), y(8.59f))
        path.lineTo(x(12f), y(13.17f))
        path.lineTo(x(7.41f), y(8.59f))
        path.lineTo(x(6f), y(10f))
        path.lineTo(x(12f), y(16f))
        path.lineTo(x(18f), y(10f))
        path.close()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawPath(path, paint)
    }
}
