import UIKit

/// In-app preview of the keyboard, for development/QA without enabling the
/// extension in Settings. It drives the SAME `KeyboardView` + `InputSession`, with
/// committed text routed into a real text view (which conforms to `UIKeyInput`).
final class KeyboardPreviewViewController: UIViewController {
    private let session = InputSession(pageSize: 16)   // mirrors the extension
    private let host = FieldHost()
    private let textView = UITextView()
    private var keyboard: KeyboardView!
    private var heightConstraint: NSLayoutConstraint!
    /// Liquid glass only: the extension rides the system keyboard panel's
    /// material, which doesn't exist in-app — this stand-in fills in behind
    /// the (fully transparent) keyboard so the preview looks like the real thing.
    private var previewBackdrop: UIVisualEffectView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "试用"

        session.host = host

        textView.font = .systemFont(ofSize: 22)
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
        ])

        // `-system` QA launch arg: let the SYSTEM keyboard drive the field
        // instead of the inline preview — with the extension enabled in the
        // simulator (simctl defaults write), that's our real keyboard in its
        // real hosting context (system backdrop, height dance, return label).
        if CommandLine.arguments.contains("-system") {
            textView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12).isActive = true
            return
        }

        // Suppress the system keyboard while keeping the text view editable via
        // UIKeyInput, so only our preview keyboard is shown.
        textView.inputView = UIView()
        host.input = textView

        let kb = KeyboardView(session: session, theme: currentTheme())
        kb.translatesAutoresizingMaskIntoConstraints = false
        kb.showsNextKeyboardKey = false   // no input-mode switching inside the app
        kb.onReturn = { [weak self] in
            guard let self else { return }
            if self.session.isComposing { self.session.handle(.commitRaw) }
            else { self.host.insertText("\n") }
        }
        kb.onHeightChanged = { [weak self] in self?.updateHeight() }
        self.keyboard = kb

        if currentTheme().style == .liquidGlass {
            let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(backdrop)
            previewBackdrop = backdrop
        }

        view.addSubview(kb)
        heightConstraint = kb.heightAnchor.constraint(equalToConstant: kb.preferredHeight)
        var constraints = [
            textView.bottomAnchor.constraint(equalTo: kb.topAnchor, constant: -12),

            kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kb.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            heightConstraint!,
        ]
        if let backdrop = previewBackdrop {
            constraints += [
                backdrop.topAnchor.constraint(equalTo: kb.topAnchor),
                backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                // Under the home indicator too, like the real keyboard surface.
                backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        applyBackdropWash()
    }

    private func applyBackdropWash() {
        previewBackdrop?.contentView.backgroundColor = currentTheme().materialWash
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
        // The remaining QA flags drive the inline preview keyboard.
        guard keyboard != nil else { return }
        // QA launch flags to preview a specific plane directly.
        if CommandLine.arguments.contains("-numbers") { keyboard.showLayer(.numbers) }
        else if CommandLine.arguments.contains("-symbols") { keyboard.showLayer(.symbols) }
        // `-type ab` feeds keys into the session at launch, so screenshots can
        // capture the composing candidate bar without tapping.
        if let i = CommandLine.arguments.firstIndex(of: "-type"),
           CommandLine.arguments.indices.contains(i + 1) {
            for b in CommandLine.arguments[i + 1].utf8 { session.handle(.engineKey(b)) }
        }
        // `-expand` opens the candidate grid over the keys (combine with -type).
        if CommandLine.arguments.contains("-expand") { keyboard.expandCandidates() }
        // `-popup r` renders the key-press bubble for a character key — popups
        // only live during a touch, so screenshots can't capture them otherwise.
        if let i = CommandLine.arguments.firstIndex(of: "-popup"),
           CommandLine.arguments.indices.contains(i + 1),
           let ch = CommandLine.arguments[i + 1].first {
            keyboard.showKeyPopup(ch)
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        keyboard?.applyTheme(currentTheme())
        applyBackdropWash()
        updateHeight()
    }

    private func currentTheme() -> KeyboardTheme {
        // `-classic` QA launch arg forces the pre-26 style on an iOS 26
        // simulator, keeping the classic path screenshot-testable without
        // installing an old runtime.
        KeyboardTheme.resolve(
            traits: traitCollection,
            appearance: .default,
            returnKeyType: .default,
            forceClassic: CommandLine.arguments.contains("-classic")
        )
    }

    private func updateHeight() {
        guard let keyboard else { return }
        heightConstraint.constant = keyboard.preferredHeight
    }
}

/// Routes committed text into any `UIKeyInput` (a `UITextView` here).
final class FieldHost: KeyboardHost {
    weak var input: UIKeyInput?
    func insertText(_ text: String) { input?.insertText(text) }
    func deleteBackward() { input?.deleteBackward() }
}
