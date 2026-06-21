import UIKit
import Libjd

/// The keyboard extension's principal class. Owns the engine session and hosts the
/// reusable `KeyboardView`, forwarding committed text to the host via the text proxy
/// and keeping appearance / return key / height in sync with the host field.
final class KeyboardViewController: UIInputViewController {
    private let session = InputSession(pageSize: 9)
    private var keyboard: KeyboardView!
    private var heightConstraint: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        session.host = self

        let kb = KeyboardView(session: session, theme: currentTheme())
        kb.translatesAutoresizingMaskIntoConstraints = false
        kb.onReturn = { [weak self] in self?.onReturn() }
        kb.onNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        kb.showsNextKeyboardKey = needsInputModeSwitchKey
        kb.returnLabel = KeyboardTheme.returnLabel(textDocumentProxy.returnKeyType ?? .default)
        kb.onHeightChanged = { [weak self] in self?.updateHeight() }
        view.addSubview(kb)
        keyboard = kb

        heightConstraint = view.heightAnchor.constraint(equalToConstant: kb.preferredHeight)
        heightConstraint.priority = .defaultHigh   // don't fight the system's input-view sizing
        NSLayoutConstraint.activate([
            heightConstraint,
            kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kb.topAnchor.constraint(equalTo: view.topAnchor),
            kb.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.cancelAndReset()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        refreshAppearance()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        refreshAppearance()
        updateHeight()
    }

    private func refreshAppearance() {
        keyboard?.applyTheme(currentTheme())
        keyboard?.returnLabel = KeyboardTheme.returnLabel(textDocumentProxy.returnKeyType ?? .default)
    }

    private func currentTheme() -> KeyboardTheme {
        KeyboardTheme.resolve(
            traits: traitCollection,
            appearance: textDocumentProxy.keyboardAppearance ?? .default,
            returnKeyType: textDocumentProxy.returnKeyType ?? .default
        )
    }

    private func updateHeight() {
        guard let keyboard else { return }
        heightConstraint.constant = keyboard.preferredHeight
    }

    private func onReturn() {
        if session.isComposing {
            session.handle(.commitRaw)
        } else {
            textDocumentProxy.insertText("\n")
        }
    }
}

// MARK: - KeyboardHost

extension KeyboardViewController: KeyboardHost {
    func insertText(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
}
