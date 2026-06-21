import UIKit

/// A single key. A `UIControl` so we get precise touch phases for: press
/// highlight, slide-off cancel, a preview bubble on character keys, and
/// press-and-hold repeat for backspace.
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

    private var isRepeating: Bool { spec.cap == .backspace }

    init(spec: KeySpec, theme: KeyboardTheme) {
        self.spec = spec
        self.theme = theme
        self.displayText = spec.cap.label
        super.init(frame: .zero)

        layer.cornerRadius = 5
        layer.shadowColor = theme.keyShadow.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)

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
        layer.shadowColor = theme.keyShadow.cgColor
        applyColors(pressed: false)
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
        titleLabel.textColor = isReturnKey ? theme.returnText
            : (isLightKey ? theme.keyText : theme.specialKeyText)

        let base: UIColor
        if isAccented {
            base = theme.keyBackground          // active shift: light
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
        applyColors(pressed: true)
        showPopupIfCharacter()
        if isRepeating { fire(); startRepeat() }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let inside = expanded.contains(touch.location(in: self))
        applyColors(pressed: inside)
        if !inside {
            hidePopup()
            stopRepeat()
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        applyColors(pressed: false)
        hidePopup()
        stopRepeat()
        let inside = touch.map { expanded.contains($0.location(in: self)) } ?? false
        if !isRepeating, inside { fire() }
    }

    override func cancelTracking(with event: UIEvent?) {
        applyColors(pressed: false)
        hidePopup()
        stopRepeat()
    }

    private var expanded: CGRect { bounds.insetBy(dx: -8, dy: -8) }

    private func fire() { onTap?(spec.cap) }

    // MARK: - Repeat

    private func startRepeat() {
        delayTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.fire()
            }
        }
    }

    private func stopRepeat() {
        delayTimer?.invalidate(); delayTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
    }

    // MARK: - Popup

    private func showPopupIfCharacter() {
        guard spec.cap.isCharacter, let host = popupHost else { return }
        let frame = convert(bounds, to: host)
        let w = max(frame.width * 1.35, 38)
        let h = frame.height + 28
        var x = frame.midX - w / 2
        x = min(max(x, 2), host.bounds.width - w - 2)
        let popup = KeyPopupView(text: displayText, theme: theme)
        popup.frame = CGRect(x: x, y: frame.maxY - h, width: w, height: h)
        host.addSubview(popup)
        self.popup = popup
    }

    private func hidePopup() {
        popup?.removeFromSuperview()
        popup = nil
    }

    deinit { stopRepeat() }
}
