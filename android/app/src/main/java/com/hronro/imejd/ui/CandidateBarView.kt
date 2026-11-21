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
import android.util.SparseArray
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import com.hronro.jd.Candidate

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
    private val strip = Strip(context)
    private val expandButton = ChevronView(context, pointsUp = false)
    private val separatorPaint = Paint()

    /**
     * An announcement for the idle bar — "a new version is out", set by the
     * IME service from UpdateChecker. It takes the candidate strip's place
     * only while nothing is being composed, so it never competes with
     * candidates, and disappears for good once tapped (the service clears it).
     */
    private val noticeLabel = TextView(context)
    private var notice: CharSequence? = null
    private var idle = true

    /**
     * True while reset() rebuilds the strip. The programmatic scrollTo fires the
     * scroll-change listener synchronously against the emptied strip, and
     * re-entering onNeedMore mid-rebuild would append a prefetched page ahead
     * of page 1 — cells would no longer line up with the owner's item indices,
     * so taps would commit a different candidate than displayed.
     */
    private var isResetting = false

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setWillNotDraw(false)
        build()
        style()
    }

    private fun dp(v: Int) = (v * density).toInt()

    private fun build() {
        composingLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        composingLabel.setPadding(dp(10), 0, dp(6), 0)
        addView(composingLabel, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))

        scroll.isHorizontalScrollBarEnabled = false
        scroll.addView(strip, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT))
        scroll.setOnScrollChangeListener { _, scrollX, _, _, _ ->
            if (strip.showVisibleCells()) strip.requestLayout()
            if (!isResetting && scrollX + scroll.width * 2 >= strip.contentWidth) onNeedMore?.invoke()
        }
        addView(scroll, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))

        // Same slot as the strip (weight 1); exactly one of the two is visible.
        noticeLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        noticeLabel.setPadding(dp(12), 0, dp(12), 0)
        noticeLabel.gravity = Gravity.CENTER_VERTICAL
        noticeLabel.isSingleLine = true
        noticeLabel.ellipsize = android.text.TextUtils.TruncateAt.END
        noticeLabel.isClickable = true
        noticeLabel.visibility = View.GONE
        addView(noticeLabel, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))

        // The system keyboards' affordance: a thin secondary-gray chevron in a 44dp
        // box (equal to the grid's close button, so the expand/collapse flip lands in
        // place). Starts GONE so the idle bar shows nothing — reset() decides
        // visibility once a composition has candidates.
        expandButton.visibility = View.GONE
        expandButton.setOnClickListener { onExpand?.invoke() }
        addView(expandButton, LayoutParams(dp(44), LayoutParams.MATCH_PARENT))
    }

    fun apply(theme: KeyboardTheme) {
        if (theme == this.theme) return
        this.theme = theme
        style()
    }

    private fun style() {
        composingLabel.setTextColor(theme.composingText)
        expandButton.tint = theme.candidateHint
        expandButton.background = rippleBackground(theme)
        // Accent: it is a tappable link, not a candidate.
        noticeLabel.setTextColor(theme.accent)
        noticeLabel.background = rippleBackground(theme)
        separatorPaint.color = theme.separator
        separatorPaint.strokeWidth = 0.5f * density
        strip.restyle()
        invalidate()
    }

    /** Replace the strip with a fresh page. */
    fun reset(composing: String, items: List<Candidate>, canExpand: Boolean) {
        composingLabel.text = composing
        isResetting = true
        strip.clear()
        scroll.scrollTo(0, 0)
        strip.append(items)
        isResetting = false
        expandButton.visibility = if (canExpand) View.VISIBLE else View.GONE
        idle = composing.isEmpty() && items.isEmpty()
        applyNoticeVisibility()
    }

    /** Show [text] in the idle bar (null clears it); [onTap] runs when it is tapped. */
    fun setNotice(text: CharSequence?, onTap: (() -> Unit)?) {
        notice = text
        noticeLabel.text = text
        noticeLabel.setOnClickListener(if (onTap != null) View.OnClickListener { onTap() } else null)
        applyNoticeVisibility()
    }

    private fun applyNoticeVisibility() {
        val show = idle && notice != null
        noticeLabel.visibility = if (show) View.VISIBLE else View.GONE
        scroll.visibility = if (show) View.GONE else View.VISIBLE
    }

    /** Append a freshly-loaded page of candidates (lazy pagination). */
    fun append(items: List<Candidate>) = strip.append(items)

    /** One candidate's cell: its title centered in 12dp of room left and
     *  right, 4dp above and below; the cell's index is its tag. */
    private fun newCell() = TextView(context).apply {
        gravity = Gravity.CENTER
        setPadding(dp(12), dp(4), dp(12), dp(4))
        isClickable = true
        background = rippleBackground(theme)
        setOnClickListener { v -> onSelect?.invoke(v.tag as Int) }
    }

    private fun rippleBackground(theme: KeyboardTheme) =
        RippleDrawable(ColorStateList.valueOf(theme.rippleColor), null, ColorDrawable(Color.WHITE))

    /**
     * The scrolling row of candidates. It changes on every keystroke, so it is
     * built for that: each candidate is measured once ([CellSizes]), cells are
     * placed by arithmetic, and a small pool of reused cells covers only what
     * is on screen and half a screen to either side. It used to build a
     * TextView, its ripple and a separator for every loaded candidate (16 a
     * page) in a LinearLayout on every keystroke. Cells sit where that
     * LinearLayout put them: back to back with a hairline between, each
     * vertically centered.
     */
    private inner class Strip(context: Context) : ViewGroup(context) {
        private val candidates = ArrayList<Candidate>()
        /** Where each cell starts and its size, in px. */
        private var cellX = IntArray(32)
        private var cellW = IntArray(32)
        private var cellH = IntArray(32)
        var contentWidth = 0
            private set

        /** Cells on screen by candidate index, and spare ones to reuse. */
        private val shown = SparseArray<TextView>()
        private val spare = ArrayList<TextView>()
        /** Sizes titles the way a cell would; never shown. (TextView needs
         *  layout params to take new text after its first measure.) */
        private val measurer = newCell().apply { layoutParams = generateDefaultLayoutParams() }

        private val separatorFill = Paint()
        private val separatorWidth = (0.5f * density).toInt().coerceAtLeast(1)
        private val separatorHeight = dp(24)

        init { setWillNotDraw(false) }

        fun restyle() {
            separatorFill.color = theme.separator
            for (k in 0 until shown.size()) shown.valueAt(k).let { cell ->
                cell.background = rippleBackground(theme)
                cell.text = styledTitle(candidates[shown.keyAt(k)], theme, density)
            }
            for (cell in spare) cell.background = rippleBackground(theme)
            invalidate()
        }

        /** Empty the strip; its cells go back to the pool. */
        fun clear() {
            candidates.clear()
            contentWidth = 0
            for (k in 0 until shown.size()) spare.add(shown.valueAt(k))
            shown.clear()
        }

        fun append(items: List<Candidate>) {
            if (items.isNotEmpty()) {
                ensureCapacity(candidates.size + items.size)
                for (cand in items) {
                    val i = candidates.size
                    val size = CellSizes.size(cand, density, measurer) { styledTitle(cand, theme, density) }
                    cellX[i] = if (i == 0) 0 else cellX[i - 1] + cellW[i - 1] + separatorWidth
                    cellW[i] = (size ushr 32).toInt()
                    cellH[i] = size.toInt()
                    candidates.add(cand)
                }
                val last = candidates.size - 1
                contentWidth = cellX[last] + cellW[last]
            }
            showVisibleCells()
            requestLayout()
        }

        private fun ensureCapacity(n: Int) {
            if (n <= cellX.size) return
            val size = maxOf(n, cellX.size * 2)
            cellX = cellX.copyOf(size)
            cellW = cellW.copyOf(size)
            cellH = cellH.copyOf(size)
        }

        /**
         * Put cells on the candidates on screen and half a screen to either
         * side; hand the rest back to the pool. Returns whether that changed
         * anything, so the strip needs laying out.
         */
        fun showVisibleCells(): Boolean {
            val count = candidates.size
            val width = scroll.width
            var first = 0
            var end = 0
            if (width > 0 && count > 0) {
                val minX = scroll.scrollX - width / 2
                val maxX = scroll.scrollX + width * 3 / 2
                first = firstCellEndingAfter(minX)
                end = first
                while (end < count && cellX[end] <= maxX) end++
            }
            var changed = false
            for (k in shown.size() - 1 downTo 0) {
                val i = shown.keyAt(k)
                if (i < first || i >= end) {
                    spare.add(shown.valueAt(k))
                    shown.removeAt(k)
                    changed = true
                }
            }
            for (i in first until end) {
                if (shown.get(i) != null) continue
                val cell = spare.removeLastOrNull()
                    ?: newCell().also { addViewInLayout(it, -1, generateDefaultLayoutParams(), true) }
                cell.text = styledTitle(candidates[i], theme, density)
                cell.tag = i
                cell.visibility = VISIBLE
                shown.put(i, cell)
                changed = true
            }
            for (cell in spare) if (cell.visibility != GONE) cell.visibility = GONE
            return changed
        }

        private fun firstCellEndingAfter(x: Int): Int {
            var low = 0
            var high = candidates.size
            while (low < high) {
                val mid = (low + high) ushr 1
                if (cellX[mid] + cellW[mid] <= x) low = mid + 1 else high = mid
            }
            return low
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            setMeasuredDimension(contentWidth, MeasureSpec.getSize(heightMeasureSpec))
        }

        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
            // The first layout is the first time the strip's width is known.
            showVisibleCells()
            val height = b - t
            for (k in 0 until shown.size()) {
                val i = shown.keyAt(k)
                val h = minOf(cellH[i], height)
                val top = (height - h) / 2
                shown.valueAt(k).apply {
                    measure(
                        MeasureSpec.makeMeasureSpec(cellW[i], MeasureSpec.EXACTLY),
                        MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY),
                    )
                    layout(cellX[i], top, cellX[i] + cellW[i], top + h)
                }
            }
        }

        override fun onDraw(canvas: Canvas) {
            // The hairline before every cell but the first.
            val top = ((height - separatorHeight) / 2).toFloat()
            for (k in 0 until shown.size()) {
                val i = shown.keyAt(k)
                if (i == 0) continue
                val x = cellX[i].toFloat()
                canvas.drawRect(x - separatorWidth, top, x, top + separatorHeight, separatorFill)
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
 * Measured candidate cells. A cell's size depends only on its title's text
 * (and the display density), and the same few thousand candidates come back
 * keystroke after keystroke, so each is measured once; the cache is dropped if
 * it ever grows past a few thousand.
 */
private object CellSizes {
    private val sizes = HashMap<String, Long>()
    private var density = 0f

    /** [measurer]'s size around [title]: width in the high 32 bits, height in the low. */
    fun size(cand: Candidate, density: Float, measurer: TextView, title: () -> CharSequence): Long {
        if (density != this.density) {
            sizes.clear()
            this.density = density
        }
        val hint = cand.hint
        val key = if (hint.isNullOrEmpty()) cand.value else cand.value + '\u0000' + hint
        sizes[key]?.let { return it }
        if (sizes.size > 4096) sizes.clear()
        measurer.text = title()
        val unspecified = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        measurer.measure(unspecified, unspecified)
        val size = (measurer.measuredWidth.toLong() shl 32) or measurer.measuredHeight.toLong()
        sizes[key] = size
        return size
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
