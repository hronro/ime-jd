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
        didSet { titleLabel.text = displayText; updateFace() }
    }
    /// When true (shift armed/locked), render the key in the "active" style.
    var isAccented = false {
        didSet { updateFace(); applyColors(pressed: false) }
    }
    /// Return only: drop the host return type's action tint for the plain
    /// function-key fill (classic while composing, when return reads 确认).
    var untintedReturn = false {
        didSet { if untintedReturn != oldValue { applyColors(pressed: false) } }
    }

    private let titleLabel = UILabel()
    private var titleCenterY: NSLayoutConstraint!
    /// Shows `symbolName` in place of the title label when a key has one.
    private let symbolView = UIImageView()
    /// Liquid glass's space bar: blank but for the input method's initial in
    /// the corner, the way the stock keyboards mark theirs (拼 for Pinyin).
    private let cornerLabel = UILabel()
    private var theme: KeyboardTheme
    private let geometry: KeyGeometry
    private var popup: KeyPopupView?
    private var delayTimer: Timer?
    private var repeatTimer: Timer?
    private var alternatesTimer: Timer?
    /// True once a press-and-hold expanded the popup into the alternates row:
    /// tracking then slides the selection instead of press-highlighting.
    private var showingAlternates = false

    private var isRepeating: Bool { spec.cap == .backspace }

    init(spec: KeySpec, theme: KeyboardTheme, geometry: KeyGeometry = .classic) {
        self.spec = spec
        self.theme = theme
        self.geometry = geometry
        self.displayText = spec.cap.label
        super.init(frame: .zero)

        applyChrome()

        titleLabel.text = displayText
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        // The symbol speaks for the key: its label stays the text glyph (QA
        // lookups and VoiceOver find the key by it, as before).
        symbolView.isAccessibilityElement = true
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)
        titleCenterY = titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleCenterY,
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if spec.cap == .space {
            cornerLabel.text = "键"
            cornerLabel.font = .systemFont(ofSize: 13)
            cornerLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cornerLabel)
            NSLayoutConstraint.activate([
                cornerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6.2),
                cornerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2.7),
            ])
        }
        updateFace()
        applyColors(pressed: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        applyChrome()
        updateFace()
        applyColors(pressed: false)
    }

    /// Style-dependent key shape and shadow (see `KeyboardTheme`'s chrome vars).
    private func applyChrome() {
        layer.cornerRadius = theme.keyCornerRadius
        layer.cornerCurve = theme.keyCornerCurve
        layer.shadowColor = theme.keyShadow.cgColor
        layer.shadowOpacity = theme.keyShadowOpacity
        layer.shadowRadius = 0   // a hard edge, where there is a shadow at all
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    // MARK: - Face

    /// The SF Symbol drawn in place of `displayText`: the globe in every style
    /// (the 🌐 emoji renders in colour, unlike any system key face); shift and
    /// delete on the iPhone grid and in liquid glass, the stock keyboards'
    /// glyphs (filled arrow when armed, caps-lock glyph when locked); and in
    /// liquid glass a return glyph per return-key type instead of text.
    private var symbolName: String? {
        let symbolic = theme.style == .liquidGlass || geometry != .classic
        switch spec.cap {
        case .globe:
            return "globe"
        case .shift where symbolic:
            return displayText == "⇪" ? "capslock.fill" : isAccented ? "shift.fill" : "shift"
        case .backspace where symbolic:
            return "delete.left"
        case .ret:
            return theme.returnSymbol
        default:
            return nil
        }
    }

    /// Sized to the stock keyboard's glyphs: in-row globe 20pt (iPhone Duo,
    /// iOS 27); shift, delete and return 19pt in liquid glass (iOS 27) — 20pt
    /// on the Duo's unfolded inner display — and shift and delete 20pt in
    /// classic (iOS 18.6).
    private var symbolConfiguration: UIImage.SymbolConfiguration {
        let size: CGFloat = spec.cap == .globe || theme.style == .classic || geometry == .wide ? 20 : 19
        return UIImage.SymbolConfiguration(font: .systemFont(ofSize: size))
    }

    private func updateFace() {
        let name = symbolName
        symbolView.image = name.flatMap { UIImage(systemName: $0, withConfiguration: symbolConfiguration) }
        symbolView.accessibilityLabel = displayText
        symbolView.isHidden = name == nil
        let markedSpace = spec.cap == .space && theme.style == .liquidGlass
        cornerLabel.isHidden = !markedSpace
        cornerLabel.accessibilityLabel = displayText
        titleLabel.isHidden = name != nil || markedSpace
        let face = Self.face(for: spec.cap, text: displayText, style: theme.style, geometry: geometry)
        titleLabel.font = face.font
        titleCenterY.constant = -face.rise
    }

    /// The iPhone grid matches the stock keyboard's key faces, which run
    /// larger than iPad's, small letters larger still and raised, to balance
    /// capitals, digits and marks: in liquid glass (iOS 27) small letters
    /// 24.5pt 2.3pt above center, the rest 21.5pt 1.2pt above, with an 18pt
    /// plane key — 30.5pt and 27.5pt, 2.8pt and 0.8pt up, on the iPhone Duo's
    /// unfolded inner display; in classic (iOS 18.6) small letters light
    /// 25.5pt 2.8pt above center, the rest regular 22pt centered.
    private static func face(for cap: KeyCap, text: String, style: KeyboardTheme.Style,
                             geometry: KeyGeometry) -> (font: UIFont, rise: CGFloat) {
        let glass = style == .liquidGlass
        let phoneGrid = geometry != .classic
        switch cap {
        case .char, .insertLiteral:
            guard phoneGrid else { return (.systemFont(ofSize: 22), 0) }
            var smallLetter = false
            if case .char = cap { smallLetter = text != text.uppercased() }
            // The iPhone Duo's unfolded inner display: the same scheme, larger.
            if glass, geometry == .wide {
                return smallLetter ? (.systemFont(ofSize: 30.5), 2.8) : (.systemFont(ofSize: 27.5), 0.8)
            }
            switch (glass, smallLetter) {
            case (true, true):   return (.systemFont(ofSize: 24.5), 2.3)
            case (true, false):  return (.systemFont(ofSize: 21.5), 1.2)
            case (false, true):  return (.systemFont(ofSize: 25.5, weight: .light), 2.8)
            case (false, false): return (.systemFont(ofSize: 22), 0)
            }
        case .toLayer: return (.systemFont(ofSize: phoneGrid && glass ? 18 : 16), 0)
        case .space, .ret, .globe, .spacer: return (.systemFont(ofSize: 16), 0)
        case .shift, .backspace: return (.systemFont(ofSize: 20), 0)
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
        let tintedReturn = isReturnKey && !untintedReturn
        titleLabel.textColor = isAccented ? theme.shiftActiveText
            : tintedReturn ? theme.returnText
            : (isLightKey ? theme.keyText : theme.specialKeyText)

        symbolView.tintColor = titleLabel.textColor
        cornerLabel.textColor = theme.keyText.withAlphaComponent(theme.isDark ? 0.3 : 0.2)

        let base: UIColor
        if isAccented {
            base = theme.shiftActiveBackground  // classic: light; glass: the normal fill
        } else if tintedReturn {
            base = theme.returnBackground
        } else if isLightKey {
            base = theme.keyBackground
        } else {
            base = theme.specialKeyBackground
        }
        let pressedFill = !isLightKey ? theme.specialKeyHighlight
            : spec.cap == .space ? theme.keyHighlight : theme.letterKeyHighlight
        backgroundColor = pressed ? pressedFill : base
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
                                 hostBounds: host.bounds,
                                 glyphSize: titleLabel.font.pointSize, geometry: geometry)
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
                                 hostBounds: host.bounds, geometry: geometry)
        host.addSubview(popup)
        self.popup = popup
        showingAlternates = true
        // The panel hovers clear of the key: iOS 27 shows the key pressed
        // beneath it, iOS 26 at rest. (Classic's row covers the key.)
        applyColors(pressed: theme.style == .classic || theme.detachedCallout)
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
