import UIKit

/// The full keyboard surface: candidate bar + key plane, with layer switching,
/// shift state, theming, the expandable candidate grid, and lazy pagination.
/// Driven by an `InputSession`; used by both the extension and the in-app preview.
final class KeyboardView: UIView {
    let session: InputSession

    /// Return key: owner decides commit-raw vs. newline (it knows the host).
    var onReturn: (() -> Void)?
    /// Globe key: owner advances to the next keyboard (extension only).
    var onNextKeyboard: (() -> Void)?
    /// Called when the preferred height changes (rotation / idiom change).
    var onHeightChanged: (() -> Void)?

    var showsNextKeyboardKey = true { didSet { if showsNextKeyboardKey != oldValue { rebuildKeys() } } }

    /// Localized label for the return key (set from the host's returnKeyType).
    var returnLabel: String = "换行" { didSet { keyGrid.returnLabel = returnLabel } }

    private(set) var theme: KeyboardTheme
    private var idiom: KeyboardIdiom = .phone { didSet { if idiom != oldValue { rebuildKeys() } } }
    private var compactHeight = false

    private var layer_: KeyboardLayer = .letters
    private var shift: ShiftState = .off
    private var lastShiftTap: CFTimeInterval = 0

    private let candidateBar: CandidateBarView
    private let keyGrid: KeyboardLayoutView
    private var gridOverlay: CandidateGridView?

    /// Accumulated candidates for the current composition (across loaded pages).
    private var items: [Candidate] = []

    var preferredHeight: CGFloat {
        CandidateBarView.height + KeyLayout.keysHeight(idiom: idiom, compactHeight: compactHeight)
    }

    init(session: InputSession, theme: KeyboardTheme = .light) {
        self.session = session
        self.theme = theme
        self.candidateBar = CandidateBarView(theme: theme)
        self.keyGrid = KeyboardLayoutView(theme: theme, idiom: .phone)
        super.init(frame: .zero)

        clipsToBounds = false
        backgroundColor = theme.keyboardBackground

        keyGrid.popupHost = self
        keyGrid.clipsToBounds = false
        keyGrid.onKey = { [weak self] cap in self?.handle(cap) }

        candidateBar.onSelect = { [weak self] i in self?.select(i) }
        candidateBar.onExpand = { [weak self] in self?.expandGrid() }
        candidateBar.onNeedMore = { [weak self] in self?.loadMore() }

        session.onChange = { [weak self] snap, raw in self?.renderCandidates(snap, raw) }

        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        keyGrid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(candidateBar)
        addSubview(keyGrid)
        // Keep content inside the safe area so the notch / rounded corners don't
        // cover the left column or first candidate in landscape (no-op in portrait,
        // where the horizontal insets are 0). The background still fills edge-to-edge.
        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            candidateBar.topAnchor.constraint(equalTo: topAnchor),
            candidateBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            candidateBar.heightAnchor.constraint(equalToConstant: CandidateBarView.height),
            keyGrid.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
            keyGrid.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            keyGrid.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            keyGrid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        rebuildKeys()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Traits

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateForTraits()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateForTraits()
    }

    private func updateForTraits() {
        let newIdiom: KeyboardIdiom = traitCollection.userInterfaceIdiom == .pad ? .pad : .phone
        let newCompact = traitCollection.verticalSizeClass == .compact
        let changed = newIdiom != idiom || newCompact != compactHeight
        idiom = newIdiom
        compactHeight = newCompact
        if changed { onHeightChanged?() }
    }

    /// Switch the visible plane (QA / preview convenience).
    func showLayer(_ layer: KeyboardLayer) { setLayer(layer) }

    func applyTheme(_ theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.keyboardBackground
        candidateBar.apply(theme: theme)
        keyGrid.apply(theme: theme)
        gridOverlay?.apply(theme: theme)
    }

    // MARK: - Keys

    private func rebuildKeys() {
        keyGrid.setRows(KeyLayout.rows(layer: layer_, idiom: idiom, showGlobe: showsNextKeyboardKey))
        keyGrid.updateShift(shift)
    }

    private func handle(_ cap: KeyCap) {
        switch cap {
        case .char(let b):           sendChar(b)
        case .insertLiteral(let s):  collapseGrid(); session.insertLiteral(s)
        case .backspace:         collapseGrid(); session.handle(.backspace)
        case .space:             collapseGrid(); session.handle(.engineKey(0x20))
        case .ret:               collapseGrid(); onReturn?()
        case .globe:             onNextKeyboard?()
        case .shift:             toggleShift()
        case .toLayer(let l):    setLayer(l)
        case .spacer:            break   // no button is created for spacers
        }
    }

    private func sendChar(_ b: UInt8) {
        var byte = b
        if shift != .off, (0x61...0x7A).contains(b) { byte = b - 0x20 }
        collapseGrid()
        session.handle(.engineKey(byte))
        if shift == .oneShot { shift = .off; keyGrid.updateShift(shift) }
    }

    private func toggleShift() {
        let now = CACurrentMediaTime()
        let doubleTap = (now - lastShiftTap) < 0.3
        lastShiftTap = now
        switch shift {
        case .off:     shift = .oneShot
        case .oneShot: shift = doubleTap ? .locked : .off
        case .locked:  shift = .off
        }
        keyGrid.updateShift(shift)
    }

    private func setLayer(_ l: KeyboardLayer) {
        layer_ = l
        shift = .off
        rebuildKeys()
    }

    // MARK: - Candidates

    private func renderCandidates(_ snap: QuerySnapshot, _ raw: String) {
        items = snap.options
        // Chevron keyed to a fixed count, not totalPages, so the expand affordance
        // doesn't vanish for mid-size candidate sets when the engine page size grows.
        candidateBar.reset(composing: raw, items: items, canExpand: snap.optionsCount > 9)
        if let grid = gridOverlay {
            if raw.isEmpty { collapseGrid() } else { grid.setItems(items) }
        }
    }

    private func loadMore() {
        guard let more = session.loadMoreCandidates(), !more.isEmpty else { return }
        items.append(contentsOf: more)
        candidateBar.append(more)
        gridOverlay?.append(more)
    }

    private func select(_ index: Int) {
        guard index >= 0, index < items.count else { return }
        collapseGrid()
        session.commitCandidate(items[index].value)
    }

    private func expandGrid() {
        guard gridOverlay == nil, !items.isEmpty else { return }
        let grid = CandidateGridView(theme: theme)
        grid.setItems(items)
        grid.onSelect = { [weak self] i in self?.select(i) }
        grid.onNeedMore = { [weak self] in self?.loadMore() }
        grid.onClose = { [weak self] in self?.collapseGrid() }
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: candidateBar.topAnchor),
            grid.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        gridOverlay = grid
    }

    private func collapseGrid() {
        gridOverlay?.removeFromSuperview()
        gridOverlay = nil
    }
}
