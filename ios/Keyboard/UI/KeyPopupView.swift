import UIKit

/// The enlarged "bubble" preview shown above a pressed character key.
final class KeyPopupView: UIView {
    private let label = UILabel()

    init(text: String, theme: KeyboardTheme) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = theme.popupBackground
        layer.cornerRadius = 8
        layer.shadowColor = theme.keyShadow.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)

        label.text = text
        label.textColor = theme.popupText
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
