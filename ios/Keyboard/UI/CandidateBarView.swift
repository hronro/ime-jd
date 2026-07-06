import UIKit

/// The always-visible candidate strip: the in-flight code on the left, a
/// horizontally scrolling row of candidates, and an expand chevron on the right.
/// A dumb renderer — the owner supplies items and handles selection / lazy loading.
final class CandidateBarView: UIView, UIScrollViewDelegate {
    static let height: CGFloat = 44

    var onSelect: ((Int) -> Void)?
    var onExpand: (() -> Void)?
    var onNeedMore: (() -> Void)?

    private let composingLabel = UILabel()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let expandButton = ActionButton(type: .system)
    private let topSeparator = UIView()
    private var theme: KeyboardTheme
    private var shownCount = 0

    init(theme: KeyboardTheme) {
        self.theme = theme
        super.init(frame: .zero)
        build()
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        composingLabel.font = .systemFont(ofSize: 15, weight: .medium)
        composingLabel.setContentHuggingPriority(.required, for: .horizontal)
        composingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        composingLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The built-in Pinyin keyboard's affordance: a thin secondary-gray SF Symbol
        // chevron, not a filled text triangle. Starts hidden so the idle bar shows
        // nothing — visibility is decided by reset() once a composition has candidates.
        expandButton.setImage(UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        ), for: .normal)
        expandButton.isHidden = true
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.onTap { [weak self] in self?.onExpand?() }

        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(composingLabel)
        addSubview(scroll)
        addSubview(expandButton)
        addSubview(topSeparator)

        NSLayoutConstraint.activate([
            composingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            composingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: composingLabel.trailingAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor),

            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandButton.topAnchor.constraint(equalTo: topAnchor),
            expandButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 44pt box: the standard touch target, and equal to the grid's close
            // button so the expand/collapse chevron flips in place.
            expandButton.widthAnchor.constraint(equalToConstant: 44),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),

            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        composingLabel.textColor = theme.composingText
        expandButton.tintColor = theme.candidateHint
        topSeparator.backgroundColor = theme.separator
    }

    /// Replace the strip with a fresh page.
    func reset(composing: String, items: [Candidate], canExpand: Bool) {
        composingLabel.text = composing
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        shownCount = 0
        scroll.setContentOffset(.zero, animated: false)
        append(items)
        expandButton.isHidden = !canExpand
    }

    /// Append a freshly-loaded page of candidates (lazy pagination).
    func append(_ items: [Candidate]) {
        for cand in items {
            let idx = shownCount
            if idx > 0 {
                stack.addArrangedSubview(separator())
            }
            stack.addArrangedSubview(cell(cand, index: idx))
            shownCount += 1
        }
    }

    private func cell(_ cand: Candidate, index: Int) -> UIButton {
        let b = ActionButton(type: .system)
        b.setAttributedTitle(Self.title(cand, theme: theme), for: .normal)
        b.contentEdgeInsets = .init(top: 4, left: 12, bottom: 4, right: 12)
        b.onTap { [weak self] in self?.onSelect?(index) }
        return b
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = theme.separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return v
    }

    static func title(_ cand: Candidate, theme: KeyboardTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: cand.value,
            attributes: [.font: UIFont.systemFont(ofSize: 21), .foregroundColor: theme.candidateText]
        )
        if let hint = cand.hint, !hint.isEmpty {
            result.append(NSAttributedString(
                string: " 〔\(hint)〕",
                attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: theme.candidateHint]
            ))
        }
        return result
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let nearEnd = scrollView.contentOffset.x + scrollView.bounds.width * 2 >= scrollView.contentSize.width
        if nearEnd { onNeedMore?() }
    }
}
