import UIKit

/// Closure-based UIButton — a shim from when the floor was iOS 13 (UIAction's
/// `addAction` is iOS 14+); at today's iOS 15 floor `addAction` would do.
final class ActionButton: UIButton {
    private var handler: (() -> Void)?

    /// Room on each side of an attributed title: `width` left and right,
    /// `height` above and below. The symmetric `contentEdgeInsets` (deprecated
    /// since iOS 15) without moving to `UIButton.Configuration`, whose buttons
    /// look and highlight differently.
    var titlePadding: CGSize = .zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize {
        guard titlePadding != .zero, let title = titleLabel?.attributedText?.size() else {
            return super.intrinsicContentSize
        }
        // Sized as UIKit sizes an attributed-title button with insets — `super`
        // can't help: without insets it pads 6pt above and below and widens to
        // 30pt. The title's text size plus padding, the width rounded up to
        // whole points and the height to the nearest pixel.
        let scale = max(traitCollection.displayScale, 1)
        return CGSize(
            width: (title.width + 2 * titlePadding.width).rounded(.up),
            height: ((title.height + 2 * titlePadding.height) * scale).rounded() / scale
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard titlePadding != .zero, let label = titleLabel else { return }
        // Center the title in the padded room in whole pixels, a half-pixel tie
        // rounding away from zero: UIKit's placement with insets for the
        // candidate fonts. (Centered in the full bounds instead, a title a pixel
        // taller than its room — the label is sized in whole points — lands a
        // pixel lower.)
        let scale = max(traitCollection.displayScale, 1)
        let room = bounds.insetBy(dx: titlePadding.width, dy: titlePadding.height)
        func offset(_ space: CGFloat, _ length: CGFloat) -> CGFloat {
            (((space * scale).rounded() - (length * scale).rounded()) / 2).rounded() / scale
        }
        label.frame.origin = CGPoint(x: room.minX + offset(room.width, label.frame.width),
                                     y: room.minY + offset(room.height, label.frame.height))
    }

    func onTap(_ handler: @escaping () -> Void) {
        self.handler = handler
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }
    @objc private func fire() { handler?() }
}
