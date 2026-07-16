import UIKit

/// Container-app landing screen: walks the user through enabling the keyboard
/// system-wide — with a one-tap shortcut into Settings — and pins an in-app
/// preview button to the bottom so the keyboard can be tried without enabling
/// anything.
final class RootViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "键道"

        // The guide scrolls; the "try it in-app" button is pinned to the bottom
        // bar (below) so it stays reachable on short screens, in landscape, and
        // at large Dynamic Type sizes.
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        let hero = makeHero()
        let header = makeSectionHeader("启用步骤")
        let stepsCard = makeStepsCard()
        let note = makeFullAccessNote()
        let openSettings = makeOpenSettingsButton()

        let content = UIStackView(arrangedSubviews: [hero, header, stepsCard, note, openSettings])
        content.axis = .vertical
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setCustomSpacing(28, after: hero)        // hero → section header
        content.setCustomSpacing(10, after: header)      // header → card
        content.setCustomSpacing(12, after: stepsCard)   // card → reassurance note
        content.setCustomSpacing(24, after: note)        // note → primary button
        scrollView.addSubview(content)

        let bottomBar = makeBottomBar()
        view.addSubview(bottomBar)

        let g = view.safeAreaLayoutGuide
        let cw = scrollView.contentLayoutGuide
        let fw = scrollView.frameLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: g.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            content.topAnchor.constraint(equalTo: cw.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: cw.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: cw.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: cw.trailingAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: fw.widthAnchor, constant: -48),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Actions

    private func openSystemSettings() {
        // Public API opens this app's own page in Settings (the only App
        // Store-safe deep link); the numbered steps spell out the rest of the path.
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openPreview() {
        navigationController?.pushViewController(KeyboardPreviewViewController(), animated: true)
    }

    // MARK: - Hero

    private func makeHero() -> UIView {
        let title = UILabel()
        title.text = "键道输入法"
        title.font = .systemFont(ofSize: 28, weight: .bold)

        let subtitle = UILabel()
        subtitle.text = "完全离线 · 保护隐私"
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, subtitle])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }

    // MARK: - Steps

    private func makeSectionHeader(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        return label
    }

    private func makeStepsCard() -> UIView {
        let steps = [
            "打开「设置」→「通用」→「键盘」",
            "轻点「键盘」→「添加新键盘…」",
            "在列表中选择「键道」",
        ]
        let rows = steps.enumerated().map { makeStepRow(number: $0.offset + 1, text: $0.element) }
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
        ])
        return card
    }

    private func makeStepRow(number: Int, text: String) -> UIView {
        let badge = UILabel()
        badge.text = "\(number)"
        badge.textAlignment = .center
        badge.textColor = .white
        badge.font = .systemFont(ofSize: 14, weight: .semibold)
        badge.backgroundColor = .systemBlue
        badge.layer.cornerRadius = 12
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
        ])

        let label = UILabel()
        label.attributedText = emphasize(text)
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [badge, label])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .top   // badge tracks the first line when the text wraps
        return row
    }

    /// Emphasizes the quoted UI labels (「…」) within a step so the exact things
    /// to tap in Settings stand out from the connective text.
    private func emphasize(_ text: String) -> NSAttributedString {
        let regular = UIFont.systemFont(ofSize: 16)
        let semibold = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: regular, .foregroundColor: UIColor.label]
        )
        let ns = text as NSString
        var start = 0
        while start < ns.length {
            let open = ns.range(of: "「", options: [], range: NSRange(location: start, length: ns.length - start))
            guard open.location != NSNotFound else { break }
            let close = ns.range(of: "」", options: [], range: NSRange(location: open.location, length: ns.length - open.location))
            guard close.location != NSNotFound else { break }
            let end = close.location + close.length
            attributed.addAttribute(.font, value: semibold, range: NSRange(location: open.location, length: end - open.location))
            start = end
        }
        return attributed
    }

    private func makeFullAccessNote() -> UIView {
        let symbol = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let icon = UIImageView(image: UIImage(systemName: "lock.shield", withConfiguration: symbol))
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = "无需开启「完全访问权限」"
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        return row
    }

    // MARK: - Buttons

    private func makeOpenSettingsButton() -> UIView {
        let button = makeButton(title: "打开系统设置", prominent: true, systemImage: "gearshape.fill")
        button.onTap { [weak self] in self?.openSystemSettings() }
        return button
    }

    private func makeBottomBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = .systemBackground
        bar.translatesAutoresizingMaskIntoConstraints = false

        // Hairline so scrolled content reads as passing under a distinct footer.
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(separator)

        let tryButton = makeButton(title: "在应用内试用键盘", prominent: false, systemImage: "keyboard")
        tryButton.onTap { [weak self] in self?.openPreview() }
        bar.addSubview(tryButton)

        let safe = bar.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: bar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            tryButton.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            tryButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 24),
            tryButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -24),
            tryButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ])
        return bar
    }

    /// A full-width call-to-action. `prominent` = filled (primary action);
    /// otherwise tinted (secondary). Uses `UIButton.Configuration` on iOS 15+ for
    /// native padding, icon layout, and pressed states, with a manual fallback at
    /// the iOS 13 deployment floor.
    private func makeButton(title: String, prominent: Bool, systemImage: String?) -> ActionButton {
        let button = ActionButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var cfg = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
            cfg.title = title
            cfg.baseBackgroundColor = .systemBlue
            cfg.baseForegroundColor = prominent ? .white : .systemBlue
            cfg.cornerStyle = .large
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)
            if let systemImage {
                cfg.image = UIImage(systemName: systemImage)
                cfg.imagePlacement = .leading
                cfg.imagePadding = 8
                cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            }
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 17, weight: .semibold)
                return out
            }
            button.configuration = cfg
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            button.setTitleColor(prominent ? .white : .systemBlue, for: .normal)
            button.backgroundColor = prominent ? .systemBlue : UIColor.systemBlue.withAlphaComponent(0.12)
            button.layer.cornerRadius = 14
            button.layer.cornerCurve = .continuous
        }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return button
    }
}
