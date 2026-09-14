// Port of ios/Keyboard/UI/KeyboardView.swift. The full keyboard surface:
// candidate bar + key plane, with layer switching, shift state, theming, the
// expandable candidate grid, and lazy pagination. Driven by an InputSession.
package com.hronro.imejd.ui

import android.annotation.SuppressLint
import android.content.Context
import android.os.SystemClock
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.hronro.imejd.engine.Candidate
import com.hronro.imejd.engine.KeyAction
import com.hronro.imejd.engine.SessionSnapshot

@SuppressLint("ViewConstructor")
class KeyboardView(
    context: Context,
    val session: com.hronro.imejd.engine.InputSession,
    private var theme: KeyboardTheme,
) : FrameLayout(context) {

    /** Return key: owner decides commit-raw vs. newline (it knows the host). */
    var onReturn: (() -> Unit)? = null

    /** Localized label for the return key (set from the host's IME action). */
    var returnLabel: String = "换行"
        set(value) { field = value; keyGrid.returnLabel = value }

    /**
     * Password fields (FieldPolicy.isPassword): letters and space bypass the
     * engine and land in the host exactly as typed (case per shift) — nothing
     * composes, so the candidate bar stays empty and nothing but what the user
     * tapped reaches a masked field. Set by the owner per field.
     */
    var directInput = false

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

    // Key-preview balloons; phone only — tablets don't pop previews (Gboard/AOSP behavior).
    private val previews: KeyPreviewController? =
        if (idiom == KeyboardIdiom.PHONE) KeyPreviewController(this, theme) else null

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
        keyGrid.onKeyPreview = { key, event -> previews?.handle(key, event) }
        // No previews (tablets) → expand refuses, and long-press stays inert,
        // matching the no-balloon behavior there.
        keyGrid.onAlternatesExpand = { key -> previews?.expandAlternates(key) ?: false }
        keyGrid.onAlternatesSlide = { key, x, y -> previews?.slideAlternates(key, x, y) }
        keyGrid.onAlternatesCommit = { key -> previews?.commitAlternates(key) }
        candidateBar.onSelect = { i -> select(i) }
        candidateBar.onExpand = { expandGrid() }
        candidateBar.onNeedMore = { loadMore() }
        session.onChange = { snap -> renderCandidates(snap) }

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
        previews?.apply(theme)
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
            KeyCap.Space -> {
                collapseGrid()
                if (directInput) session.insertLiteral(" ") else session.handle(KeyAction.EngineKey(0x20))
            }
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
        if (directInput) session.insertLiteral(byte.toChar().toString())
        else session.handle(KeyAction.EngineKey(byte.toByte()))
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

    /**
     * Switch the visible plane (mirrors iOS `showLayer`): the owner opens each
     * field on the plane its input type asks for (FieldPolicy.openingLayer);
     * QA extras pick one for screenshots. No-op when already there, so
     * re-asserting per field is free; a pending shift is dropped, as on a
     * plane switch.
     */
    fun showLayer(layer: KeyboardLayer) {
        if (layer != this.layer || shift != ShiftState.OFF) setLayer(layer)
    }

    /**
     * Announce something in the idle candidate bar — the IME service's
     * "new version available" notice. Shown only while nothing is being
     * composed; null clears it.
     */
    fun setUpdateNotice(text: CharSequence?, onTap: (() -> Unit)?) = candidateBar.setNotice(text, onTap)

    // MARK: - Candidates

    private fun renderCandidates(snap: SessionSnapshot) {
        items = snap.candidates
        candidateBar.reset(snap.rawBuffer, items, canExpand = snap.canExpand)
        gridOverlay?.let { grid ->
            if (snap.rawBuffer.isEmpty()) collapseGrid() else grid.setItems(items)
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
        KeyFeedback.playInput(this)
        collapseGrid()
        session.commitCandidate(items[index].value)
    }

    private fun expandGrid() {
        if (gridOverlay != null || items.isEmpty()) return
        KeyFeedback.playModifier(this)
        val grid = CandidateGridView(context, theme)
        grid.setItems(items)
        grid.onSelect = { i -> select(i) }
        grid.onNeedMore = { loadMore() }
        grid.onClose = { KeyFeedback.playModifier(this); collapseGrid() }
        addView(grid, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        gridOverlay = grid
    }

    private fun collapseGrid() {
        gridOverlay?.let { removeView(it) }
        gridOverlay = null
    }
}
