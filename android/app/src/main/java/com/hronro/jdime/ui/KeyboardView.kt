// Port of ios/Keyboard/UI/KeyboardView.swift. The full keyboard surface:
// candidate bar + key plane, with layer switching, shift state, theming, the
// expandable candidate grid, and lazy pagination. Driven by an InputSession.
package com.hronro.jdime.ui

import android.annotation.SuppressLint
import android.content.Context
import android.os.SystemClock
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.hronro.jdime.engine.Candidate
import com.hronro.jdime.engine.KeyAction
import com.hronro.jdime.engine.QuerySnapshot

@SuppressLint("ViewConstructor")
class KeyboardView(
    context: Context,
    val session: com.hronro.jdime.engine.InputSession,
    private var theme: KeyboardTheme,
) : FrameLayout(context) {

    /** Return key: owner decides commit-raw vs. newline (it knows the host). */
    var onReturn: (() -> Unit)? = null

    /** Localized label for the return key (set from the host's IME action). */
    var returnLabel: String = "换行"
        set(value) { field = value; keyGrid.returnLabel = value }

    private val density = context.resources.displayMetrics.density
    private val idiom: KeyboardIdiom =
        if (context.resources.configuration.smallestScreenWidthDp >= 600) KeyboardIdiom.PAD else KeyboardIdiom.PHONE
    private val compactHeight: Boolean =
        context.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE

    private var layer: KeyboardLayer = KeyboardLayer.LETTERS
    private var shift: ShiftState = ShiftState.OFF
    private var lastShiftTap: Long = 0

    private val container = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val candidateBar = CandidateBarView(context, theme)
    private val keyGrid = KeyboardLayoutView(context, theme, idiom)
    private var gridOverlay: CandidateGridView? = null

    /** Accumulated candidates for the current composition (across loaded pages). */
    private var items: List<Candidate> = emptyList()

    /** Bottom system-bar (gesture/nav) inset; the keyboard grows by this so keys clear it. */
    private var bottomInset = 0

    val preferredHeightPx: Int
        get() = ((CandidateBarView.HEIGHT_DP + KeyLayout.keysHeightDp(idiom, compactHeight)) * density).toInt()

    init {
        setBackgroundColor(theme.keyboardBackground)
        clipChildren = false

        keyGrid.onKey = { cap -> handle(cap) }
        candidateBar.onSelect = { i -> select(i) }
        candidateBar.onExpand = { expandGrid() }
        candidateBar.onNeedMore = { loadMore() }
        session.onChange = { snap, raw -> renderCandidates(snap, raw) }

        container.addView(
            candidateBar,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (CandidateBarView.HEIGHT_DP * density).toInt()),
        )
        container.addView(
            keyGrid,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f),
        )
        addView(container, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

        // Targeting SDK 35, the IME window is edge-to-edge and draws behind the system
        // navigation/gesture bar. Consume that bottom inset and pad it out (the keyboard
        // grows; the strip behind the gesture bar shows the keyboard background).
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            // navigationBars() under-reports in gesture nav (just the home pill); the
            // system's IME nav bar that hosts the hide/switcher buttons is captured by
            // tappableElement(). Pad by the larger so the bottom row always clears it.
            val nav = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            val tap = insets.getInsets(WindowInsetsCompat.Type.tappableElement()).bottom
            val b = maxOf(nav, tap)
            if (b != bottomInset) {
                bottomInset = b
                setPadding(0, 0, 0, b)
                requestLayout()
            }
            insets
        }

        rebuildKeys()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        ViewCompat.requestApplyInsets(this)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = preferredHeightPx + bottomInset
        super.onMeasure(
            MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY),
        )
        setMeasuredDimension(w, h)
    }

    fun applyTheme(theme: KeyboardTheme) {
        this.theme = theme
        setBackgroundColor(theme.keyboardBackground)
        candidateBar.apply(theme)
        keyGrid.apply(theme)
        gridOverlay?.apply(theme)
    }

    // MARK: - Keys

    private fun rebuildKeys() {
        keyGrid.setRows(KeyLayout.rows(layer, idiom))
        keyGrid.updateShift(shift)
    }

    private fun handle(cap: KeyCap) {
        when (cap) {
            is KeyCap.Char -> sendChar(cap.byte)
            is KeyCap.InsertLiteral -> { collapseGrid(); session.insertLiteral(cap.text) }
            KeyCap.Backspace -> { collapseGrid(); session.handle(KeyAction.Backspace) }
            KeyCap.Space -> { collapseGrid(); session.handle(KeyAction.EngineKey(0x20)) }
            KeyCap.Return -> { collapseGrid(); onReturn?.invoke() }
            KeyCap.Globe -> {}
            KeyCap.Shift -> toggleShift()
            is KeyCap.ToLayer -> setLayer(cap.layer)
            KeyCap.Spacer -> {}
        }
    }

    private fun sendChar(b: Byte) {
        var byte = b.toInt() and 0xFF
        if (shift != ShiftState.OFF && byte in 0x61..0x7A) byte -= 0x20
        collapseGrid()
        session.handle(KeyAction.EngineKey(byte.toByte()))
        if (shift == ShiftState.ONE_SHOT) { shift = ShiftState.OFF; keyGrid.updateShift(shift) }
    }

    private fun toggleShift() {
        val now = SystemClock.uptimeMillis()
        val doubleTap = (now - lastShiftTap) < 300
        lastShiftTap = now
        shift = when (shift) {
            ShiftState.OFF -> ShiftState.ONE_SHOT
            ShiftState.ONE_SHOT -> if (doubleTap) ShiftState.LOCKED else ShiftState.OFF
            ShiftState.LOCKED -> ShiftState.OFF
        }
        keyGrid.updateShift(shift)
    }

    private fun setLayer(l: KeyboardLayer) {
        layer = l
        shift = ShiftState.OFF
        rebuildKeys()
    }

    // MARK: - Candidates

    private fun renderCandidates(snap: QuerySnapshot, raw: String) {
        items = snap.options
        candidateBar.reset(raw, items, canExpand = snap.totalPages > 1)
        gridOverlay?.let { grid ->
            if (raw.isEmpty()) collapseGrid() else grid.setItems(items)
        }
    }

    private fun loadMore() {
        val more = session.loadMoreCandidates() ?: return
        if (more.isEmpty()) return
        items = items + more
        candidateBar.append(more)
        gridOverlay?.append(more)
    }

    private fun select(index: Int) {
        if (index < 0 || index >= items.size) return
        collapseGrid()
        session.commitCandidate(items[index].value)
    }

    private fun expandGrid() {
        if (gridOverlay != null || items.isEmpty()) return
        val grid = CandidateGridView(context, theme)
        grid.setItems(items)
        grid.onSelect = { i -> select(i) }
        grid.onNeedMore = { loadMore() }
        grid.onClose = { collapseGrid() }
        addView(grid, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        gridOverlay = grid
    }

    private fun collapseGrid() {
        gridOverlay?.let { removeView(it) }
        gridOverlay = null
    }
}
