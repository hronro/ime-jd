import UIKit

/// In-app preview of the keyboard, for development/QA without enabling the
/// extension in Settings. It drives the SAME `KeyboardView` + `InputSession`, with
/// committed text routed into a real text view (which conforms to `UIKeyInput`).
final class KeyboardPreviewViewController: UIViewController {
    private let session = InputSession(pageSize: 9)
    private let host = FieldHost()
    private let textView = UITextView()
    private var keyboard: KeyboardView!
    private var heightConstraint: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "试用"

        session.host = host

        textView.font = .systemFont(ofSize: 22)
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.translatesAutoresizingMaskIntoConstraints = false
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

        view.addSubview(textView)
        view.addSubview(kb)
        let g = view.safeAreaLayoutGuide
        heightConstraint = kb.heightAnchor.constraint(equalToConstant: kb.preferredHeight)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: kb.topAnchor, constant: -12),

            kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kb.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            heightConstraint,
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
        // QA launch flags to preview a specific plane directly.
        if CommandLine.arguments.contains("-numbers") { keyboard.showLayer(.numbers) }
        else if CommandLine.arguments.contains("-symbols") { keyboard.showLayer(.symbols) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        keyboard?.applyTheme(currentTheme())
        updateHeight()
    }

    private func currentTheme() -> KeyboardTheme {
        KeyboardTheme.resolve(traits: traitCollection, appearance: .default, returnKeyType: .default)
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
