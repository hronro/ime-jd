import UIKit

/// A single key. A `UIControl` so we get precise touch phases for: press
/// highlight, slide-off cancel, a preview bubble on character/punctuation
/// keys, press-and-hold repeat for backspace, and press-and-hold alternates
/// on grouped punctuation (hold expands the bubble into a row; sliding moves
/// the selection; release commits it).
final class KeyButton: UIControl {
    let spec: KeySpec
    var onTap: ((KeyCap) -> Void)?
    /// Non-clipping view the preview bubble is added to (so it can draw above keys).
    weak var popupHost: UIView?

    /// Overrides the displayed glyph (e.g. uppercase letters when shift is on,
    /// or ⇪ for caps-lock). Defaults to `spec.cap.label`.
    var displayText: String {
        didSet { titleLabel.text = displayText }
    }
    /// When true (shift armed/locked), render the key in the "active" light style.
    var isAccented = false {
        didSet { applyColors(pressed: false) }
    }

    private let titleLabel = UILabel()
    private var theme: KeyboardTheme
    private var popup: KeyPopupView?
    private var delayTimer: Timer?
    private var repeatTimer: Timer?
    private var alternatesTimer: Timer?
    /// True once a press-and-hold expanded the popup into the alternates row:
    /// tracking then slides the selection instead of press-highlighting.
    private var showingAlternates = false

    private var isRepeating: Bool { spec.cap == .backspace }

    init(spec: KeySpec, theme: KeyboardTheme) {
        self.spec = spec
        self.theme = theme
        self.displayText = spec.cap.label
        super.init(frame: .zero)

        applyChrome()

        titleLabel.text = displayText
        titleLabel.textAlignment = .center
        titleLabel.font = Self.font(for: spec.cap)
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
        ])
        applyColors(pressed: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        applyChrome()
        applyColors(pressed: false)
    }

    /// Style-dependent key shape and shadow (see `KeyboardTheme`'s chrome vars).
    private func applyChrome() {
        layer.cornerRadius = theme.keyCornerRadius
        layer.cornerCurve = theme.keyCornerCurve
        layer.shadowColor = theme.keyShadow.cgColor
        layer.shadowOpacity = theme.keyShadowOpacity
        layer.shadowRadius = theme.keyShadowBlur
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    private static func font(for cap: KeyCap) -> UIFont {
        switch cap {
        case .char, .insertLiteral: return .systemFont(ofSize: 22)
        case .space, .ret, .toLayer, .globe, .spacer: return .systemFont(ofSize: 16)
        case .shift, .backspace: return .systemFont(ofSize: 20)
        }
    }

    // MARK: - Colors

    private var isLightKey: Bool {
        switch spec.cap {
        case .char, .insertLiteral, .space: return true
        default: return false
        }
    }

    private func applyColors(pressed: Bool) {
        titleLabel.textColor = isAccented ? theme.shiftActiveText
            : isReturnKey ? theme.returnText
            : (isLightKey ? theme.keyText : theme.specialKeyText)

        let base: UIColor
        if isAccented {
            base = theme.shiftActiveBackground  // active shift: light
        } else if isReturnKey {
            base = theme.returnBackground
        } else if isLightKey {
            base = theme.keyBackground
        } else {
            base = theme.specialKeyBackground
        }
        backgroundColor = pressed ? (isLightKey ? theme.keyHighlight : theme.keyBackground) : base
    }

    private var isReturnKey: Bool { spec.cap == .ret }

    // MARK: - Touch tracking

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        KeyClick.play(spec.cap)
        applyColors(pressed: true)
        showPopupIfPreviewable()
        if !spec.alternates.isEmpty { startAlternatesDelay() }
        if isRepeating { fire(); startRepeat() }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if showingAlternates, let popup {
            popup.updateSelection(forTouch: touch.location(in: popup))
            return true
        }
        let inside = hitSlop.contains(touch.location(in: self))
        applyColors(pressed: inside)
        if !inside {
            hidePopup()
            stopRepeat()
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        applyColors(pressed: false)
        stopRepeat()
        if showingAlternates {
            let selected = popup?.selectedValue
            hidePopup()
            if let selected {
                // The primary commits like a plain tap (a future .char group
                // must still go through the engine); alternates bypass it.
                selected == displayText ? fire() : onTap?(.insertLiteral(selected))
            }
            return
        }
        hidePopup()
        let inside = touch.map { hitSlop.contains($0.location(in: self)) } ?? false
        if !isRepeating, inside { fire() }
    }

    override func cancelTracking(with event: UIEvent?) {
        applyColors(pressed: false)
        hidePopup()
        stopRepeat()
    }

    private var hitSlop: CGRect { bounds.insetBy(dx: -8, dy: -8) }

    private func fire() { onTap?(spec.cap) }

    /// QA hook: render the pressed state + preview bubble without a touch.
    /// Popups only live during a touch, so screenshots need this (see the
    /// preview app's `-popup` launch arg).
    func showPressedForQA() {
        applyColors(pressed: true)
        showPopupIfPreviewable()
    }

    /// QA hook: render the expanded press-and-hold row with the given group
    /// index highlighted (0 = primary; see the preview app's `-alts` arg).
    func showAlternatesForQA(selected: Int) {
        applyColors(pressed: true)
        expandAlternates()
        popup?.selectValue(at: selected)
    }

    // MARK: - Repeat

    private func startRepeat() {
        delayTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                KeyClick.play(self.spec.cap)   // the system keyboard clicks every repeat tick
                self.fire()
            }
        }
    }

    private func stopRepeat() {
        delayTimer?.invalidate(); delayTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
    }

    // MARK: - Popup

    private var isPreviewable: Bool {
        // Letters and direct-insert marks, like the system keyboard (special
        // keys show no bubble).
        if case .insertLiteral = spec.cap { return true }
        return spec.cap.isCharacter
    }

    private func showPopupIfPreviewable() {
        // iPhone only: the system keyboard shows no key previews on iPad,
        // where keys are big enough that the finger doesn't cover the glyph.
        guard traitCollection.userInterfaceIdiom != .pad else { return }
        guard isPreviewable, let host = popupHost else { return }
        let popup = KeyPopupView(text: displayText, theme: theme,
                                 keyFrame: convert(bounds, to: host),
                                 hostBounds: host.bounds)
        host.addSubview(popup)
        self.popup = popup
    }

    // MARK: - Alternates (press-and-hold)

    private func startAlternatesDelay() {
        alternatesTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.expandAlternates()
        }
    }

    /// Swap the single-glyph bubble for the sliding alternates row.
    private func expandAlternates() {
        guard traitCollection.userInterfaceIdiom != .pad else { return }
        guard !spec.alternates.isEmpty, let host = popupHost else { return }
        popup?.removeFromSuperview()
        let popup = KeyPopupView(alternates: [displayText] + spec.alternates, theme: theme,
                                 keyFrame: convert(bounds, to: host),
                                 hostBounds: host.bounds)
        host.addSubview(popup)
        self.popup = popup
        showingAlternates = true
    }

    private func hidePopup() {
        alternatesTimer?.invalidate(); alternatesTimer = nil
        showingAlternates = false
        popup?.removeFromSuperview()
        popup = nil
    }

    deinit {
        stopRepeat()
        alternatesTimer?.invalidate()
    }
}
