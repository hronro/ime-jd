import UIKit
import Libjd

/// The keyboard extension's principal class. Owns the engine session and hosts the
/// reusable `KeyboardView`, forwarding committed text to the host via the text proxy
/// and keeping appearance / return key / height in sync with the host field.
final class KeyboardViewController: UIInputViewController {
    private let session = InputSession(pageSize: 9)
    private var keyboard: KeyboardView!
    private var heightConstraint: NSLayoutConstraint!

    /// True between `viewWillAppear` and `viewDidAppear` — the keyboard's slide-in, the
    /// window during which iOS inflates the input view (see the presentation-offset note).
    private var isPresenting = false
    /// Largest plausible overshoot seen while the offset is still uncalibrated; committed
    /// to `presentationOffset` at `viewDidAppear`.
    private var pendingOffset: CGFloat = 0

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
        // NB: do NOT apply the presentation offset here. Applying it this early (or in
        // viewWillAppear) reintroduces the switch jitter; it must be applied in
        // viewIsAppearing. The constraint stays at `target` until then.
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Apply the offset trick at this (and only this) point in the slide-in: request
        // `target - offset` so iOS's inflation lands on `target`.
        isPresenting = true
        applyHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentationOffset == nil, pendingOffset > 0 {
            presentationOffset = pendingOffset   // commit the one-time calibration
        }
        isPresenting = false
        applyHeight()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        calibratePresentationOffset()
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
        applyHeight()
    }

    // MARK: - Height & the keyboard-switch resize fix
    //
    // When a custom keyboard slides in, iOS inflates the input view by a fixed number of
    // points above the height we request, then snaps it down to our height once presented.
    // That snap is a visible resize "jitter" on every keyboard switch (and it shifts the
    // host app's layout — e.g. Safari's bottom address bar). There is no API for that
    // offset and it varies by device and orientation, so we:
    //   1. measure it once — the first uncalibrated appearance shows the raw overshoot,
    //      which we read off the laid-out height and persist (keyed by idiom+orientation);
    //   2. thereafter request `target - offset` during the slide-in, so iOS's inflation
    //      lands exactly on `target`, then restore `target` once presented.
    // Net effect: seamless after a one-time per-device calibration — the same behaviour the
    // system keyboards exhibit — with no hardcoded per-device tables.

    private static let offsetStore = UserDefaults.standard

    private var offsetKey: String {
        let idiom = traitCollection.userInterfaceIdiom == .pad ? "pad" : "phone"
        let orientation = traitCollection.verticalSizeClass == .compact ? "landscape" : "portrait"
        return "presentationOffset.\(idiom).\(orientation)"
    }

    private var presentationOffset: CGFloat? {
        get { (Self.offsetStore.object(forKey: offsetKey) as? Double).map { CGFloat($0) } }
        set { Self.offsetStore.set(newValue.map { Double($0) }, forKey: offsetKey) }
    }

    /// Sets the height constraint: `target - offset` while presenting (so iOS's inflation
    /// lands on `target`), otherwise the true `target`. Falls back to `target` until the
    /// offset has been calibrated for this idiom/orientation.
    private func applyHeight() {
        guard let keyboard else { return }
        let target = keyboard.preferredHeight
        let wanted: CGFloat
        if isPresenting, let offset = presentationOffset {
            wanted = max(target - offset, target / 2)   // floor guards against a bad cache
        } else {
            wanted = target
        }
        if heightConstraint.constant != wanted { heightConstraint.constant = wanted }
    }

    /// First appearance per idiom/orientation only: capture iOS's raw inflation so later
    /// presentations can pre-cancel it. Bounded to a fraction of the keyboard height so the
    /// brief full-screen transient during attach (overshoot ≈ screen height) is ignored.
    private func calibratePresentationOffset() {
        guard let keyboard, presentationOffset == nil else { return }
        let target = keyboard.preferredHeight
        let overshoot = view.bounds.height - target
        guard overshoot > 0, overshoot < target * 0.5 else { return }
        pendingOffset = max(pendingOffset, overshoot)
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
            textDocumentProxy.insertText("\n")
        }
    }
}

// MARK: - KeyboardHost

extension KeyboardViewController: KeyboardHost {
    func insertText(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
}
