import UIKit
import Libjd

/// The keyboard extension's principal class. Owns the engine session and hosts the
/// reusable `KeyboardView`, forwarding committed text to the host via the text proxy
/// and keeping appearance / return key / height in sync with the host field.
final class KeyboardViewController: UIInputViewController {
    private let session = InputSession(pageSize: 9)
    private var keyboard: KeyboardView!
    private var heightConstraint: NSLayoutConstraint!

    /// True between `viewIsAppearing` and `viewDidAppear` — the keyboard's slide-in, the
    /// window during which iOS inflates the input view (see the presentation-offset note).
    private var isPresenting = false
    /// Largest plausible offset sampled from this presentation's layout passes; committed
    /// to `presentationOffset` at `viewDidAppear`. Reset at each `viewIsAppearing`.
    private var pendingOffset: CGFloat = 0
    /// The offset key captured at `viewIsAppearing`. Samples are committed only if the key
    /// is unchanged at `viewDidAppear`, so a rotation mid-slide-in can't store a value
    /// measured in one orientation under the other orientation's key.
    private var presentingKey: String?

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
        // Start this presentation's measurement from scratch (also discards anything a
        // pre-`viewIsAppearing` layout pass may have sampled) and pin the key it's for.
        pendingOffset = 0
        presentingKey = offsetKey
        applyHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Commit this slide-in's measurement — first calibration and self-healing of a
        // stale value alike — unless the key changed mid-slide-in (rotation). The 0.5pt
        // tolerance avoids rewriting the store over sub-pixel layout noise.
        if pendingOffset > 0, offsetKey == presentingKey,
           abs(pendingOffset - (presentationOffset ?? 0)) > 0.5 {
            presentationOffset = pendingOffset
        }
        isPresenting = false
        applyHeight()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        samplePresentationOffset()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A cancelled appearance (no viewDidAppear) must not leave the trick armed for
        // applyHeight calls that arrive while off-screen.
        isPresenting = false
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
    //   1. measure it on every slide-in — while presenting, `bounds.height - constraint`
    //      reads the raw inflation whether or not the trick is applied — and persist the
    //      result, keyed by device model + iOS major + orientation;
    //   2. request `target - offset` during the slide-in, so iOS's inflation lands
    //      exactly on `target`, then restore `target` once presented.
    // Net effect: one calibration jitter the first time a key is seen (matching the system
    // keyboards' first-launch behaviour), seamless after — and a bad or outdated offset
    // heals after a single jitter instead of persisting until reinstall.

    private static let offsetStore = UserDefaults.standard

    /// Model identifier (e.g. "iPhone17,2"). Part of the offset key: `UserDefaults`
    /// survives restoring a backup onto a different device, where the calibrated offset
    /// may not apply — a new model recalibrates instead of inheriting it.
    private static let deviceModel: String = {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: sys.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    /// Nil when the window scene isn't available to report the orientation — then we
    /// neither apply nor record an offset, rather than guess a bucket. (The size classes
    /// can't stand in for orientation — `.regular` in both iPad orientations — and neither
    /// can the view's own aspect: a keyboard is wider than tall in *every* orientation.)
    /// iOS major is part of the key so an OS update recalibrates; if an update removes the
    /// inflation mechanism entirely, the fresh key never sees a positive sample, never
    /// calibrates, and the trick gracefully never engages.
    private var offsetKey: String? {
        guard let o = view.window?.windowScene?.interfaceOrientation else { return nil }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let orientation = o.isLandscape ? "landscape" : "portrait"
        return "presentationOffset.\(Self.deviceModel).ios\(major).\(orientation)"
    }

    private var presentationOffset: CGFloat? {
        get {
            guard let key = offsetKey else { return nil }
            return (Self.offsetStore.object(forKey: key) as? Double).map { CGFloat($0) }
        }
        set {
            guard let key = offsetKey else { return }
            Self.offsetStore.set(newValue.map { Double($0) }, forKey: key)
        }
    }

    /// Sets the height constraint: `target - offset` while presenting (so iOS's inflation
    /// lands on `target`), otherwise the true `target`. Falls back to `target` when no
    /// offset is calibrated for this key yet, or when the cached one looks implausibly
    /// large (≥ half the target) — that appearance then jitters like an uncalibrated one,
    /// and the sample it takes overwrites the bad cache for next time.
    private func applyHeight() {
        guard let keyboard else { return }
        let target = keyboard.preferredHeight
        let wanted: CGFloat
        if isPresenting, let offset = presentationOffset, offset < target * 0.5 {
            wanted = target - offset
        } else {
            wanted = target
        }
        if heightConstraint.constant != wanted { heightConstraint.constant = wanted }
    }

    /// Measure iOS's presentation inflation from this slide-in's layout passes:
    /// `bounds.height - constraint.constant` equals the raw offset whether or not the
    /// trick is applied (untricked bounds settle at `target + offset`; tricked at
    /// `(target - cached) + offset`). Sampling only while presenting is what makes this
    /// safe to persist — inflated bounds are the *expected* state here, unlike after
    /// `viewDidAppear`, where "inflation not yet removed" is indistinguishable from
    /// "cache stale" (see the jitter doc on the removed validation pass). The bounds
    /// check discards the full-screen attach transient (measures ≈ screen height) and
    /// passes where the system height isn't applied yet (measure 0).
    private func samplePresentationOffset() {
        guard isPresenting, let keyboard, offsetKey == presentingKey else { return }
        let measured = view.bounds.height - heightConstraint.constant
        guard measured > 0, measured < keyboard.preferredHeight * 0.5 else { return }
        pendingOffset = max(pendingOffset, measured)
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
