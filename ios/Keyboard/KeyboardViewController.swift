import UIKit
import Libjd

/// The keyboard extension's principal class. Owns the engine session and hosts the
/// reusable `KeyboardView`, forwarding committed text to the host via the text proxy
/// and keeping appearance / return key / height in sync with the host field.
final class KeyboardViewController: UIInputViewController {
    // 16 per fetch — iOS selects by tap, so pages aren't capped at 9 the way
    // macOS's 1-9 digit labels cap them; bigger pages = fewer grid-fill round trips.
    private let session = InputSession(userDict: UserDictContainer.shared.load()?.dict)
    /// What the session's dictionary was loaded from, compared at every
    /// presentation: an edit made in the container app in between is
    /// adopted then, when nothing is composing (see syncUserDict).
    private var userDictStamp = UserDictContainer.shared.stamp()
    private var keyboard: KeyboardView!
    private var heightConstraint: NSLayoutConstraint!

    /// Between `viewIsAppearing` and `viewDidAppear`: the slide-in, during
    /// which the height constraint is held a point short (see `applyHeight`).
    private var isPresenting = false

    /// When we last edited the host ourselves (commit / literal / delete).
    /// `textDidChange` uses it to tell our own edits' echoes apart from
    /// external changes — see there.
    private var lastOwnHostEdit: CFTimeInterval = 0

    /// The keyboard type the visible plane was chosen for — see `openFieldPlane`.
    private var planeKeyboardType: UIKeyboardType?

    override func viewDidLoad() {
        super.viewDidLoad()
        session.host = self

        let kb = KeyboardView(session: session, theme: currentTheme())
        kb.translatesAutoresizingMaskIntoConstraints = false
        kb.onReturn = { [weak self] in self?.onReturn() }
        kb.onNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        kb.showsNextKeyboardKey = needsInputModeSwitchKey
        kb.returnLabel = KeyboardTheme.returnLabel(textDocumentProxy.returnKeyType ?? .default)
        kb.onHeightChanged = { [weak self] in self?.applyHeight() }
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

    /// Adopt an edited user dictionary. A context's dictionary is fixed for
    /// its lifetime and the candidates on screen point into its blob, so the
    /// swap happens between presentations, when nothing is composing. Two
    /// stats and a defaults read when nothing changed.
    private func syncUserDict() {
        let stamp = UserDictContainer.shared.stamp()
        guard stamp != userDictStamp, !session.isComposing else { return }
        userDictStamp = stamp
        session.replaceDictionary(UserDictContainer.shared.load()?.dict)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncUserDict()
        // Every presentation opens on the plane the field asks for (a numeric
        // field on 123, anything else on letters), whatever plane was showing
        // when the keyboard went away — the system keyboards reset the same way.
        openFieldPlane(force: true)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isPresenting = true
        applyHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresenting = false
        applyHeight()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A cancelled appearance (no viewDidAppear) must not leave the
        // height a point short.
        isPresenting = false
        session.cancelAndReset()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Apple documents needsInputModeSwitchKey as only reliable from layout
        // time on; the viewDidLoad read can be wrong (and can change later,
        // e.g. when the keyboard list changes). The didSet no-ops unless the
        // value actually flips, so re-asserting every pass is free.
        keyboard?.showsNextKeyboardKey = needsInputModeSwitchKey
        // Re-resolve the theme too: a live light/dark flip reaches a presented
        // extension's traits erratically (traitCollectionDidChange can lag or
        // skip), but a layout pass follows whenever they do move. applyTheme
        // and the returnLabel setter no-op when nothing changed.
        refreshAppearance()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        // The host's text or caret changed. If it wasn't us — the user tapped
        // another field, moved the caret, or the app edited the text — the
        // in-flight composition's context is gone: drop it (like the system
        // keyboards) instead of letting a later commit land stale text at the
        // new cursor. Our own proxy edits echo here too, and one of them
        // arrives while a composition is legitimately live (a drill-in
        // commits text AND starts a fresh composition in the same keystroke),
        // so edits inside the grace window are treated as our own echo.
        if session.isComposing, CACurrentMediaTime() - lastOwnHostEdit > 0.15 {
            session.cancelAndReset()
        }
        // A switch to another field lands here too, with the proxy already
        // reporting the new field's traits: re-pick the plane when the
        // keyboard type moved. Caret moves and our own echoes keep the type,
        // so the plane the user chose survives them.
        openFieldPlane(force: false)
        refreshAppearance()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        refreshAppearance()
        applyHeight()
    }

    // MARK: - Height

    /// How far short of its height the keyboard asks to be while it slides
    /// in. Any change will do (see `applyHeight`); one point because iOS
    /// sometimes lays the keyboard out at exactly what was asked for, and a
    /// frame one point short cannot be seen.
    private static let slideInShortfall: CGFloat = 1

    /// Pins the input view to the keyboard's own height: the candidate bar
    /// plus the rows, a point less while it slides in. The constraint stays
    /// below required (see viewDidLoad), so the system's sizing wins where
    /// it insists.
    ///
    /// The point is for iOS 18, which lays a keyboard that is switching in
    /// out 45 pt taller than asked and only brings it down ~17 ms after
    /// `viewDidAppear`, by which time the tall frame has been shown: the
    /// whole panel flashes taller on every switch. A change of this
    /// constraint in `viewDidAppear` makes iOS apply the asked-for height
    /// at once, before that frame is drawn; holding it a point short from
    /// `viewIsAppearing` is what makes restoring it there a change. See
    /// ios/docs/keyboard-switch-height-jitter.md.
    private func applyHeight() {
        guard let keyboard, let heightConstraint else { return }
        let wanted = keyboard.preferredHeight - (isPresenting ? Self.slideInShortfall : 0)
        if heightConstraint.constant != wanted { heightConstraint.constant = wanted }
    }

    /// Show the plane the current field's keyboard type asks for. `force`
    /// applies it even when the type is unchanged (a fresh presentation);
    /// otherwise only a type change — a differently typed field — moves the
    /// plane out from under the user.
    private func openFieldPlane(force: Bool) {
        let type = textDocumentProxy.keyboardType ?? .default
        guard force || type != planeKeyboardType else { return }
        planeKeyboardType = type
        keyboard?.showLayer(KeyboardLayer.initial(for: type))
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

    private func onReturn() {
        if session.isComposing {
            session.handle(.commitRaw)
        } else {
            insertText("\n")   // via KeyboardHost, so the edit is stamped as our own
        }
    }
}

// MARK: - KeyboardHost

extension KeyboardViewController: KeyboardHost {
    func insertText(_ text: String) {
        lastOwnHostEdit = CACurrentMediaTime()
        textDocumentProxy.insertText(text)
    }

    func deleteBackward() {
        lastOwnHostEdit = CACurrentMediaTime()
        textDocumentProxy.deleteBackward()
    }
}
