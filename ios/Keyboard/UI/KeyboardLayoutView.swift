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
    private let hGap: CGFloat
    private let vGap: CGFloat = 8
    private let sideMargin: CGFloat
    private let topMargin: CGFloat = 5

    /// Localized label for the return key (varies by the host's returnKeyType).
    var returnLabel = "换行" {
        didSet { forEachButton { if $0.spec.cap == .ret { $0.displayText = returnLabel } } }
    }

    init(theme: KeyboardTheme, idiom: KeyboardIdiom) {
        self.theme = theme
        self.hGap = idiom == .pad ? 7 : 5
        self.sideMargin = idiom == .pad ? 5 : 3
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func forEachButton(_ body: (KeyButton) -> Void) {
        for row in rows { for item in row { if let b = item.button { body(b) } } }
    }

    func setRows(_ specRows: [[KeySpec]]) {
        forEachButton { $0.removeFromSuperview() }
        rows = specRows.map { row in
            row.map { spec -> RowItem in
                guard spec.cap != .spacer else { return RowItem(spec: spec, button: nil) }
                let b = KeyButton(spec: spec, theme: theme)
                b.popupHost = popupHost
                if spec.cap == .ret { b.displayText = returnLabel }
                b.onTap = { [weak self] cap in self?.onKey?(cap) }
                addSubview(b)
                return RowItem(spec: spec, button: b)
            }
        }
        setNeedsLayout()
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        forEachButton { $0.apply(theme: theme) }
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
        let totalV = bounds.height - 2 * topMargin - CGFloat(rowCount - 1) * vGap
        let rowHeight = totalV / CGFloat(rowCount)

        var y = topMargin
        for row in rows {
            let sumWeights = row.reduce(0) { $0 + $1.spec.weight }
            let availW = bounds.width - 2 * sideMargin - CGFloat(row.count - 1) * hGap
            var x = sideMargin
            for item in row {
                let w = availW * (item.spec.weight / sumWeights)
                item.button?.frame = CGRect(x: x, y: y, width: w, height: rowHeight)
                x += w + hGap
            }
            y += rowHeight + vGap
        }
    }
}
