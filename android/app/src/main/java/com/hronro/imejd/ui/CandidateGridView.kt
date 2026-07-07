// Port of ios/Keyboard/UI/CandidateGridView.swift. The expanded candidate list:
// a scrollable wrapping grid of ALL loaded candidates, shown when the user taps
// the bar's expand chevron. Covers the keys (opaque background).
package com.hronro.imejd.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.RippleDrawable
import android.util.AttributeSet
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.hronro.imejd.engine.Candidate
import kotlin.math.max

@SuppressLint("ViewConstructor")
class CandidateGridView(context: Context, private var theme: KeyboardTheme) : LinearLayout(context) {

    var onSelect: ((Int) -> Unit)? = null
    var onNeedMore: (() -> Unit)? = null
    var onClose: (() -> Unit)? = null

    private val density = context.resources.displayMetrics.density
    private val closeButton = ChevronView(context, pointsUp = true)
    private val flow = FlowLayout(context)
    private val scroll = ScrollView(context)
    private var items: List<Candidate> = emptyList()

    init {
        orientation = VERTICAL
        build()
        apply(theme)
    }

    private fun dp(v: Int) = (v * density).toInt()

    private fun build() {
        // Same 44dp trailing box as the bar's expand chevron, so the flip lands in place.
        closeButton.setOnClickListener { onClose?.invoke() }
        addView(closeButton, LayoutParams(dp(44), dp(CandidateBarView.HEIGHT_DP)).apply {
            gravity = Gravity.END
        })

        val sep = View(context)
        addView(sep, LayoutParams(LayoutParams.MATCH_PARENT, (0.5f * density).toInt().coerceAtLeast(1)))
        sep.setBackgroundColor(theme.separator)

        flow.setPadding(dp(4), dp(4), dp(4), dp(4))
        scroll.addView(flow, ViewGroup.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        scroll.setOnScrollChangeListener { _, _, scrollY, _, _ ->
            val content = if (flow.height > 0) flow.height else 1
            if (scrollY + scroll.height * 1.5f >= content) onNeedMore?.invoke()
        }
        addView(scroll, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        // A ScrollView whose content fits its viewport cannot scroll, so the scroll
        // listener's prefetch never fires on a freshly-expanded, underfilled grid.
        // After each layout, if there is nothing left to scroll to, ask for another
        // page — the grid fills itself until content overflows the viewport. The
        // chain terminates because the owner's loader no-ops once the engine is out
        // of pages, and appending nothing schedules no further layout. Posted, not
        // invoked inline: appending mutates the tree, which is illegal mid-layout.
        if (items.isNotEmpty() && !scroll.canScrollVertically(1)) {
            post { onNeedMore?.invoke() }
        }
    }

    fun apply(theme: KeyboardTheme) {
        this.theme = theme
        setBackgroundColor(theme.keyboardBackground)
        closeButton.tint = theme.candidateHint
        closeButton.background = RippleDrawable(ColorStateList.valueOf(theme.rippleColor), null, ColorDrawable(Color.WHITE))
        rebuild()
    }

    fun setItems(items: List<Candidate>) {
        this.items = items
        rebuild()
    }

    fun append(new: List<Candidate>) {
        if (new.isEmpty()) return
        items = items + new
        rebuild()
    }

    private fun rebuild() {
        flow.removeAllViews()
        items.forEachIndexed { index, cand -> flow.addView(chip(cand, index)) }
    }

    private fun chip(cand: Candidate, index: Int): TextView {
        return TextView(context).apply {
            text = CandidateBarView.styledTitle(cand, theme, density)
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(10), dp(14), dp(10))
            isClickable = true
            background = RippleDrawable(ColorStateList.valueOf(theme.rippleColor), null, ColorDrawable(Color.WHITE))
            setOnClickListener { onSelect?.invoke(index) }
        }
    }
}

/** A minimal wrapping container: lays children left-to-right, wrapping to new rows. */
class FlowLayout @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null,
) : ViewGroup(context, attrs) {

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val maxRight = width - paddingRight
        var x = paddingLeft
        var y = paddingTop
        var rowHeight = 0
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            if (c.visibility == GONE) continue
            c.measure(
                MeasureSpec.makeMeasureSpec(width, MeasureSpec.AT_MOST),
                MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
            )
            if (x + c.measuredWidth > maxRight && x > paddingLeft) {
                x = paddingLeft
                y += rowHeight
                rowHeight = 0
            }
            x += c.measuredWidth
            rowHeight = max(rowHeight, c.measuredHeight)
        }
        val total = y + rowHeight + paddingBottom
        setMeasuredDimension(width, resolveSize(total, heightMeasureSpec))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val maxRight = (r - l) - paddingRight
        var x = paddingLeft
        var y = paddingTop
        var rowHeight = 0
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            if (c.visibility == GONE) continue
            if (x + c.measuredWidth > maxRight && x > paddingLeft) {
                x = paddingLeft
                y += rowHeight
                rowHeight = 0
            }
            c.layout(x, y, x + c.measuredWidth, y + c.measuredHeight)
            x += c.measuredWidth
            rowHeight = max(rowHeight, c.measuredHeight)
        }
    }
}
