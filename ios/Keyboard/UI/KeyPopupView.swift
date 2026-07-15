import UIKit

/// The enlarged "bubble" preview shown above a pressed character key.
/// Classic: a solid rounded rect with a drop shadow. Liquid glass: a real
/// `UIGlassEffect` bubble — the one true-glass element per press is cheap,
/// unlike glass on every key (see the note on `KeyboardTheme`).
final class KeyPopupView: UIView {
    private let label = UILabel()

    init(text: String, theme: KeyboardTheme) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        label.text = text
        label.textColor = theme.popupText
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        if theme.style == .liquidGlass, #available(iOS 26.0, *) {
            let bubble = UIVisualEffectView(effect: UIGlassEffect())
            bubble.cornerConfiguration = .uniformCorners(radius: .fixed(12))
            bubble.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bubble)
            bubble.contentView.addSubview(label)
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: topAnchor),
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
                bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            backgroundColor = theme.popupBackground
            layer.cornerRadius = 8
            layer.shadowColor = theme.keyShadow.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: 2)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
