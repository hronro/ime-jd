import UIKit
import Libjd

/// The keyboard extension's principal class. Hosts the process's `KeyboardView` and
/// engine session (see `Shared`), forwarding committed text to the host via the text
/// proxy and keeping appearance / return key / height in sync with the host field.
final class KeyboardViewController: UIInputViewController {
    /// The keyboard view and its session, kept for the life of the process.
    /// iOS creates a new controller for every presentation (each switch to
    /// the keyboard, each time it comes back up) and keeps the extension
    /// process running in between; building the view — ~35 keys with their
    /// constraints and glyphs — was most of what a presentation cost us. So
    /// the view is built once and each new controller adopts it.
    private final class Shared {
        let session: InputSession
        let keyboard: KeyboardView
        /// What the session's dictionary was loaded from, compared at every
        /// presentation: an edit made in the container app in between is
        /// adopted then, when nothing is composing (see syncUserDict).
        var userDictStamp: UserDictContainer.Stamp

        init(theme: KeyboardTheme) {
            // The stamp first: a file that changes in between is then
            // reloaded at the next presentation instead of missed.
            userDictStamp = UserDictContainer.shared.stamp()
            session = InputSession(userDict: UserDictContainer.shared.load()?.dict)
            keyboard = KeyboardView(session: session, theme: theme)
            keyboard.translatesAutoresizingMaskIntoConstraints = false
        }
    }
    private static var shared: Shared?
    /// The controller that adopted the shared view last. iOS keeps replaced
    /// controllers alive for a while (up to four at once while switching
    /// quickly); they must leave the view and the session alone.
    private static weak var owner: KeyboardViewController?
    private var isOwner: Bool { Self.owner === self }

    private var session: InputSession!
    private var keyboard: KeyboardView!
    private var heightConstraint: NSLayoutConstraint!

    /// Between `viewIsAppearing` and `viewDidAppear`: the slide-in, during
    /// which the height constraint is held a point short (see `applyHeight`).
    private var isPresenting = false

    /// Our own edits of the host's text (commit / literal / delete), so that
    /// `textDidChange` can tell them, and the host's reactions to them, from
    /// the user moving on — see there.
    private var hostEdits = HostEditTracker()

    /// The keyboard type the visible plane was chosen for — see `openFieldPlane`.
    private var planeKeyboardType: UIKeyboardType?

    override func viewDidLoad() {
        super.viewDidLoad()
        adoptKeyboard()
        heightConstraint = view.heightAnchor.constraint(equalToConstant: keyboard.preferredHeight)
        heightConstraint.priority = .defaultHigh   // don't fight the system's input-view sizing
        heightConstraint.isActive = true
    }

    /// Take the shared keyboard view (building it the first time) into this
    /// controller's view, and point its callbacks and the session's host
    /// here. Whatever the previous owner left — a composition, an open
    /// candidate grid — is dropped, as a fresh view would not have it.
    private func adoptKeyboard() {
        let shared = Self.shared ?? Shared(theme: currentTheme())
        Self.shared = shared
        Self.owner = self
        session = shared.session
        keyboard = shared.keyboard
        session.host = self
        session.cancelAndReset()
        hostEdits.forget()

        let kb = shared.keyboard
        kb.onReturn = { [weak self] in self?.onReturn() }
        kb.onNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        kb.onHeightChanged = { [weak self] in self?.applyHeight() }
        kb.showsNextKeyboardKey = needsInputModeSwitchKey
        kb.returnLabel = KeyboardTheme.returnLabel(textDocumentProxy.returnKeyType ?? .default)
        guard kb.superview !== view else { return }
        view.addSubview(kb)   // out of the previous owner's view, if any
        NSLayoutConstraint.activate([
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
        guard let shared = Self.shared else { return }
        let stamp = UserDictContainer.shared.stamp()
        guard stamp != shared.userDictStamp, !session.isComposing else { return }
        shared.userDictStamp = stamp
        session.replaceDictionary(UserDictContainer.shared.load()?.dict)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A controller iOS shows again after another one took the view over
        // (the keyboard dismissed and brought back) takes it back.
        if !isOwner { adoptKeyboard() }
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
        if isOwner { session.cancelAndReset() }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard isOwner else { return }
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
        guard isOwner else { return }
        // The host's text or caret changed. If the caret left where we were
        // typing — the user tapped another field or moved it — the in-flight
        // composition's place is gone: drop it (like the system keyboards)
        // instead of letting a later commit land at the new caret. Not for
        // our own edits' echoes (one arrives while a composition is
        // legitimately live: a drill-in commits text AND starts a fresh
        // composition in the same keystroke), nor for the host reacting to
        // them — a completion after the caret, or Safari's address bar
        // reporting a change about a second after each commit, which lost
        // what was being typed (see HostEditTracker).
        let moved = hostEdits.caretMoved(contextBefore: textDocumentProxy.documentContextBeforeInput,
                                         contextAfter: textDocumentProxy.documentContextAfterInput,
                                         document: documentID,
                                         at: CACurrentMediaTime())
        if moved {
            hostEdits.forget()
            if session.isComposing { session.cancelAndReset() }
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
        guard isOwner else { return }
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

    /// The field being edited (`UITextDocumentProxy.documentIdentifier`).
    /// Read through the Objective-C runtime: Swift declares it a non-optional
    /// UUID, but iOS hands back nil at times (seen while switching between
    /// fields in Contacts), and the bridge then traps.
    private var documentID: UUID? {
        let selector = NSSelectorFromString("documentIdentifier")
        guard let proxy = textDocumentProxy as? NSObject, proxy.responds(to: selector) else { return nil }
        return proxy.perform(selector)?.takeUnretainedValue() as? UUID
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
        hostEdits.inserted(text, into: documentID, at: CACurrentMediaTime())
        textDocumentProxy.insertText(text)
    }

    func deleteBackward() {
        hostEdits.deletedBackward(in: documentID, at: CACurrentMediaTime())
        textDocumentProxy.deleteBackward()
    }
}
