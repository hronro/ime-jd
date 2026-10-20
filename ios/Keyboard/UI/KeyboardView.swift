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

    /// Whether the bar, keys, and candidate grid keep clear of the horizontal
    /// safe-area insets (true: the notch in landscape) or span the full width.
    /// The extension keeps the default; the in-app preview turns it off where
    /// the app window has insets a keyboard window doesn't (see there).
    var followsHorizontalSafeArea = true {
        didSet {
            guard followsHorizontalSafeArea != oldValue else { return }
            NSLayoutConstraint.deactivate(followsHorizontalSafeArea ? edgeConstraints : safeAreaConstraints)
            NSLayoutConstraint.activate(followsHorizontalSafeArea ? safeAreaConstraints : edgeConstraints)
        }
    }

    /// Localized label for the return key (set from the host's returnKeyType).
    /// Guarded: the setter walks every key, and the owner re-asserts it on
    /// every layout pass (see KeyboardViewController.viewWillLayoutSubviews).
    var returnLabel: String = "换行" {
        didSet { if returnLabel != oldValue { keyGrid.returnLabel = returnLabel } }
    }

    private(set) var theme: KeyboardTheme
    private var idiom: KeyboardIdiom = .phone { didSet { if idiom != oldValue { rebuildKeys() } } }
    /// iPhone landscape. The stock geometry proportions the rows per orientation.
    private var compactHeight = false {
        didSet { if compactHeight != oldValue, keyGeometry != .classic { rebuildKeys() } }
    }

    /// A regular-width iPhone keyboard: the iPhone Duo's unfolded inner
    /// display (and only that — a large iPhone in landscape is compact height).
    private var regularWidth = false {
        didSet { if regularWidth != oldValue, idiom == .phone { rebuildKeys() } }
    }

    /// A Plus / Pro Max iPhone (414pt wide and up, the iPhone Duo's outer
    /// display included), whose stock keyboard has taller rows. Read off the
    /// portrait width — the keyboard spans the screen — so a presentation
    /// knows it by its first layout pass.
    private var largePhone = false {
        didSet {
            guard largePhone != oldValue else { return }
            keyGrid.largePhone = largePhone
            rebuildKeys()   // the in-row globe's bottom row differs (see KeyLayout)
            onHeightChanged?()
        }
    }

    /// The stock iPhone proportions, in either style; on the iPhone Duo's
    /// unfolded inner display, its roomier `.wide` grid. iPad — whose stock
    /// keyboard is a different, full-size layout — keeps the original ones.
    private var keyGeometry: KeyGeometry {
        guard idiom == .phone else { return .classic }
        if compactHeight { return .stockCompact }
        return regularWidth ? .wide : .stock
    }

    private var layer_: KeyboardLayer = .letters
    private var shift: ShiftState = .off
    private var lastShiftTap: CFTimeInterval = 0

    private let candidateBar: CandidateBarView
    private let keyGrid: KeyboardLayoutView
    private var gridOverlay: CandidateGridView?

    /// The horizontal extent of the content, pinned to the safe area or to
    /// the edges per `followsHorizontalSafeArea`.
    private let contentGuide = UILayoutGuide()
    private var safeAreaConstraints: [NSLayoutConstraint] = []
    private var edgeConstraints: [NSLayoutConstraint] = []

    /// Accumulated candidates for the current composition (across loaded pages).
    private var items: [Candidate] = []

    var preferredHeight: CGFloat {
        CandidateBarView.height + KeyLayout.keysHeight(idiom: idiom, geometry: keyGeometry,
                                                       compactHeight: compactHeight, largePhone: largePhone,
                                                       style: theme.style)
    }

    init(session: InputSession, theme: KeyboardTheme = .light) {
        self.session = session
        self.theme = theme
        self.candidateBar = CandidateBarView(theme: theme)
        self.keyGrid = KeyboardLayoutView(theme: theme, idiom: .phone)
        super.init(frame: .zero)

        clipsToBounds = false
        backgroundColor = theme.keyboardBackground
        syncAppearance()

        keyGrid.popupHost = self
        keyGrid.clipsToBounds = false
        keyGrid.onKey = { [weak self] cap in self?.handle(cap) }

        candidateBar.onSelect = { [weak self] i in self?.select(i) }
        candidateBar.onExpand = { [weak self] in self?.expandGrid() }
        candidateBar.onNeedMore = { [weak self] in self?.loadMore() }

        session.onChange = { [weak self] snap in self?.renderCandidates(snap) }

        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        keyGrid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(candidateBar)
        addSubview(keyGrid)
        // Keep content inside the safe area so the notch / rounded corners don't
        // cover the left column or first candidate in landscape (no-op in the
        // extension in portrait, where the horizontal insets are 0). The
        // background still fills edge-to-edge.
        addLayoutGuide(contentGuide)
        let safe = safeAreaLayoutGuide
        safeAreaConstraints = [
            contentGuide.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ]
        edgeConstraints = [
            contentGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(safeAreaConstraints + [
            contentGuide.topAnchor.constraint(equalTo: topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
            candidateBar.topAnchor.constraint(equalTo: topAnchor),
            candidateBar.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            candidateBar.heightAnchor.constraint(equalToConstant: CandidateBarView.height),
            keyGrid.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
            keyGrid.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            keyGrid.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
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

    // Deprecated like the method it overrides (iOS 17 moved to trait-change
    // registration, which the iOS 15 floor lacks): keeps the iOS 17 test
    // bundle, which compiles this file too, from warning on the super call.
    @available(iOS, deprecated: 17.0)
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateForTraits()
    }

    private func updateForTraits() {
        let newIdiom: KeyboardIdiom = traitCollection.userInterfaceIdiom == .pad ? .pad : .phone
        let newCompact = traitCollection.verticalSizeClass == .compact
        let newRegularWidth = traitCollection.horizontalSizeClass == .regular
        let changed = newIdiom != idiom || newCompact != compactHeight || newRegularWidth != regularWidth
        idiom = newIdiom
        compactHeight = newCompact
        regularWidth = newRegularWidth
        if changed { onHeightChanged?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if idiom == .phone, !compactHeight, bounds.width > 0 { largePhone = bounds.width >= 414 }
        // The system can host the keyboard narrower than the screen — 452pt
        // of the iPhone Duo's 466pt outer display — and that inset is part of
        // the stock side margin.
        let screenWidth = window?.windowScene?.screen.bounds.width ?? bounds.width
        keyGrid.systemSideInset = idiom == .phone ? max(0, (screenWidth - bounds.width) / 2) : 0
    }

    /// Switch the visible plane: the owner opens each field on the plane its
    /// keyboard type asks for (`KeyboardLayer.initial(for:)`); QA args pick one
    /// for screenshots. No-op when already there, so re-asserting on every
    /// presentation is free; a pending shift is dropped, as on a plane switch.
    func showLayer(_ layer: KeyboardLayer) {
        guard layer != layer_ || shift != .off else { return }
        setLayer(layer)
    }

    /// Expand the candidate grid (QA / preview convenience, mirrors the chevron).
    func expandCandidates() { expandGrid() }

    /// Show a key's pressed state + preview bubble (QA / preview convenience —
    /// popups only live during a touch, so screenshots need this). Keys are
    /// looked up by their displayed label, so `r` and `：` both work.
    func showKeyPopup(_ label: String) {
        keyButton(labeled: label)?.showPressedForQA()
    }

    /// Show a key's expanded press-and-hold row with the given group index
    /// highlighted (QA / preview convenience, mirrors hold + slide).
    func showKeyAlternates(_ label: String, selected: Int) {
        keyButton(labeled: label)?.showAlternatesForQA(selected: selected)
    }

    private func keyButton(labeled label: String) -> KeyButton? {
        // QA args run right after a plane switch; the popup geometry needs the
        // rebuilt keys to have real frames.
        layoutIfNeeded()
        return keyGrid.subviews.compactMap { $0 as? KeyButton }
            .first { $0.displayText == label }
    }

    func applyTheme(_ theme: KeyboardTheme) {
        // The owner re-applies on every layout pass (the extension's trait
        // updates can lag a live appearance flip, so layout is the only
        // reliable hook) — the guard makes that ~free.
        guard theme != self.theme else { return }
        let restyled = theme.style != self.theme.style
        self.theme = theme
        backgroundColor = theme.keyboardBackground
        syncAppearance()
        candidateBar.apply(theme: theme)
        keyGrid.apply(theme: theme)
        gridOverlay?.apply(theme: theme)
        // Key faces and the plane's height follow the style (the QA
        // `-classic` switch; the OS never changes it under a running keyboard).
        if restyled {
            rebuildKeys()
            onHeightChanged?()
        }
    }

    private func syncAppearance() {
        // Mirror the resolved appearance into this subtree's traits, so
        // trait-driven chrome (the glass popup) follows the HOST's requested
        // keyboardAppearance even when it differs from the system style.
        // Scoped to the keyboard view — overriding the controller's view
        // would feed the override back into the next `resolve(traits:)` and
        // wedge the theme after the host reverts to `.default`. No-op
        // visually for classic (its colors are explicit).
        //
        // NB: liquid glass draws NO background of its own
        // (`keyboardBackground` is `.clear`): the extension rides the system
        // keyboard panel's material, which also covers the strip above and
        // the globe/mic chin below our view — any material of ours would tint
        // just our rectangle and show as a seam against them. The in-app
        // preview, which has no system panel, supplies its own stand-in
        // (see KeyboardPreviewViewController).
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
    }

    // MARK: - Keys

    private func rebuildKeys() {
        let geometry = keyGeometry
        keyGrid.setRows(KeyLayout.rows(layer: layer_, idiom: idiom, showGlobe: showsNextKeyboardKey,
                                       geometry: geometry, largePhone: largePhone, style: theme.style),
                        geometry: geometry)
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

    private func renderCandidates(_ snap: SessionSnapshot) {
        items = snap.candidates
        keyGrid.composing = !snap.rawBuffer.isEmpty
        candidateBar.reset(
            composing: snap.rawBuffer,
            items: items,
            canExpand: snap.canExpand
        )
        if let grid = gridOverlay {
            if snap.rawBuffer.isEmpty { collapseGrid() } else { grid.setItems(items) }
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
        KeyClick.playInput()
        collapseGrid()
        session.commitCandidate(items[index].value)
    }

    private func expandGrid() {
        guard gridOverlay == nil, !items.isEmpty else { return }
        KeyClick.playModifier()
        let grid = CandidateGridView(theme: theme)
        grid.setItems(items)
        grid.onSelect = { [weak self] i in self?.select(i) }
        grid.onNeedMore = { [weak self] in self?.loadMore() }
        grid.onClose = { [weak self] in KeyClick.playModifier(); self?.collapseGrid() }
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: candidateBar.topAnchor),
            grid.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        gridOverlay = grid
        // The overlay is translucent in liquid glass (the material shows through),
        // so the plane and bar must actually vanish, not merely be covered.
        keyGrid.isHidden = true
        candidateBar.isHidden = true
    }

    private func collapseGrid() {
        gridOverlay?.removeFromSuperview()
        gridOverlay = nil
        keyGrid.isHidden = false
        candidateBar.isHidden = false
    }
}
