import UIKit

enum ShiftState { case off, oneShot, locked }

/// The key plane: rows of `KeyButton`s laid out by proportional weights (so the
/// same model fits any iPhone/iPad width and orientation). Reports taps as `KeyCap`s.
/// A `.spacer` spec reserves width without a button, used to center short rows.
final class KeyboardLayoutView: UIView {
    var onKey: ((KeyCap) -> Void)?
    weak var popupHost: UIView?

    private struct RowItem {
        let spec: KeySpec
        let button: KeyButton?   // nil for spacers
    }
    private var rows: [[RowItem]] = []
    private var theme: KeyboardTheme
    private let idiom: KeyboardIdiom
    private var geometry: KeyGeometry = .classic

    /// Localized label for the return key (varies by the host's returnKeyType).
    var returnLabel = "换行" {
        didSet { forEachButton { if $0.spec.cap == .ret, let text = face(of: .ret) { $0.displayText = text } } }
    }

    /// A composition is open. The pre-26 stock keyboard then relabels space
    /// and return after what they do — 选定 (pick the first candidate) and
    /// 确认 (commit the raw input, on the plain fill even where the host's
    /// return type tints the key) — so classic does too; liquid glass's
    /// space and return look the same either way.
    var composing = false {
        didSet {
            guard composing != oldValue, theme.style == .classic else { return }
            forEachButton { relabel($0) }
        }
    }

    private var showsComposingActions: Bool { composing && theme.style == .classic }

    /// A Plus / Pro Max iPhone, whose stock rows are taller (see `metrics`).
    var largePhone = false { didSet { if largePhone != oldValue { setNeedsLayout() } } }

    /// How far the system already holds this keyboard in from each screen
    /// edge — on the iPhone Duo's outer display it hosts the extension 7pt
    /// in, where the stock keys start — so the portrait side margin only
    /// makes up the rest of the stock one.
    var systemSideInset: CGFloat = 0 { didSet { if systemSideInset != oldValue { setNeedsLayout() } } }

    init(theme: KeyboardTheme, idiom: KeyboardIdiom) {
        self.theme = theme
        self.idiom = idiom
        super.init(frame: .zero)
    }

    /// The text space and return show (nil for every other key).
    private func face(of cap: KeyCap) -> String? {
        let actions = showsComposingActions
        switch cap {
        case .space: return actions ? "选定" : cap.label
        case .ret:   return actions ? "确认" : returnLabel
        default:     return nil
        }
    }

    private func relabel(_ button: KeyButton) {
        if let text = face(of: button.spec.cap) { button.displayText = text }
        if button.spec.cap == .ret { button.untintedReturn = showsComposingActions }
    }

    /// Spacing per geometry and style, measured off the stock keyboards; the
    /// margins land the rows where the stock ones sit above this view's bottom
    /// edge. iPad keeps the original classic values.
    /// - Classic (iOS 18.6): 3pt side margins and 6pt key gaps, 12pt row gaps
    ///   — on the large phones 4pt margins and 11pt row gaps; landscape 8pt
    ///   row gaps and 5⅓pt key gaps. Exact in both orientations.
    /// - Liquid glass (iOS 26+): portrait 6pt key gaps, 11pt row gaps;
    ///   landscape 6pt / 8pt — its side margins sit inside the safe area this
    ///   view already keeps clear of. On the regular phones the stock rows sit
    ///   lower than this view's bottom edge (the system parks a third-party
    ///   keyboard above its globe/mic chin), so the rows hug that edge: within
    ///   4pt in portrait, exact in landscape and on the large phones.
    /// - iPhone Duo, unfolded (iOS 27.1, `.wide`): 10pt side margins and key
    ///   gaps inside the 801pt the system gives the keyboard, 13pt row gaps.
    private var metrics: (side: CGFloat, hGap: CGFloat, top: CGFloat, bottom: CGFloat, vGap: CGFloat) {
        let glass = theme.style == .liquidGlass
        switch geometry {
        case .classic:
            return (idiom == .pad ? 5 : 3, idiom == .pad ? 7 : 5, 5, 5, 8)
        case .stock:
            let m: (side: CGFloat, hGap: CGFloat, top: CGFloat, bottom: CGFloat, vGap: CGFloat)
            if glass {
                m = (6.5, 6, 12, largePhone ? 7 : 0, 11)
            } else {
                m = largePhone ? (4, 6, 8, 5, 11) : (3, 6, 8, 4, 12)
            }
            return (max(0, m.side - systemSideInset), m.hGap, m.top, m.bottom, m.vGap)
        case .stockCompact:
            return glass ? (4, 6, 8, 2, 8) : (3, 16.0 / 3, 8, 2, 8)
        case .wide:
            return (10, 10, 8, 4, 13)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func forEachButton(_ body: (KeyButton) -> Void) {
        for row in rows { for item in row { if let b = item.button { body(b) } } }
    }

    func setRows(_ specRows: [[KeySpec]], geometry: KeyGeometry = .classic) {
        forEachButton { $0.removeFromSuperview() }
        self.geometry = geometry
        rows = specRows.map { row in
            row.map { spec -> RowItem in
                guard spec.cap != .spacer else { return RowItem(spec: spec, button: nil) }
                let b = KeyButton(spec: spec, theme: theme, geometry: geometry)
                b.popupHost = popupHost
                relabel(b)
                b.onTap = { [weak self] cap in self?.onKey?(cap) }
                addSubview(b)
                return RowItem(spec: spec, button: b)
            }
        }
        setNeedsLayout()
    }

    func apply(theme: KeyboardTheme) {
        let restyled = theme.style != self.theme.style
        self.theme = theme
        forEachButton { $0.apply(theme: theme) }
        if restyled { setNeedsLayout() }
    }

    func updateShift(_ state: ShiftState) {
        forEachButton { b in
            switch b.spec.cap {
            case .char(let byte) where (0x61...0x7A).contains(byte):
                let lower = String(UnicodeScalar(byte))
                b.displayText = state == .off ? lower : lower.uppercased()
            case .shift:
                b.displayText = state == .locked ? "⇪" : "⇧"
                b.isAccented = state != .off
            default:
                break
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowCount = rows.count
        guard rowCount > 0 else { return }
        let m = metrics
        let totalV = bounds.height - m.top - m.bottom - CGFloat(rowCount - 1) * m.vGap
        let rowHeight = totalV / CGFloat(rowCount)

        var y = m.top
        for row in rows {
            let sumWeights = row.reduce(0) { $0 + $1.spec.weight }
            var x = m.side
            if geometry == .classic {
                // Each item gets its weight's share of what the gaps leave.
                let availW = bounds.width - 2 * m.side - CGFloat(row.count - 1) * m.hGap
                for item in row {
                    let w = availW * (item.spec.weight / sumWeights)
                    item.button?.frame = CGRect(x: x, y: y, width: w, height: rowHeight)
                    x += w + m.hGap
                }
            } else {
                // A grid, as on the stock keyboard: a weight unit is one key
                // plus its gap, so every row's keys land on the same columns
                // (the home row half a key in) and a spacer is pure gap.
                let pitch = (bounds.width - 2 * m.side + m.hGap) / sumWeights
                for item in row {
                    item.button?.frame = CGRect(x: x, y: y, width: item.spec.weight * pitch - m.hGap,
                                                height: rowHeight)
                    x += item.spec.weight * pitch
                }
            }
            y += rowHeight + m.vGap
        }
    }
}
