import AppKit
import InputMethodKit

// Formats a candidate for display in the IMKCandidates panel: the value
// followed by its optional hint in 〔 〕 brackets, dimmed — matching the
// Windows and CLI frontends (` 〔hint〕`). Used both to populate the panel and
// to map a clicked candidate string back to its committable value.
enum CandidateFormatter {
    /// The primitive, taking plain strings so formatting can be unit-tested
    /// without building an FFI-backed `Candidate`.
    static func display(value: String, hint: String?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: value)
        if let hint = hint, !hint.isEmpty {
            result.append(NSAttributedString(
                string: " 〔\(hint)〕",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return result
    }

    static func display(_ candidate: Candidate) -> NSAttributedString {
        display(value: candidate.value, hint: candidate.hint)
    }
}

/// The process's one candidate panel, shared by every InputController.
///
/// There must be exactly one IMKCandidates per IMKServer, alive as long as the
/// server. `-[IMKCandidates initWithServer:panelType:]` hands the new panel to
/// the server (`-[_IMKServerLegacy _setIMKCandidates:]`), which stores it in
/// an *unretained* ivar, never clears it, and messages it on every activation,
/// deactivation and key event (`_windowIsOpen` → `isVisible`,
/// `_serverGetsFirstShotAtWindowEvents` → `attributes`). Up to 0.10.1 each
/// InputController built a panel of its own, so as soon as the newest
/// client's controller went away (an app quit, a window closed) the server
/// pointed at a freed panel and the next activate / deactivate / key crashed
/// the IME in objc_msgSend. A string of those crashes makes macOS give up on
/// the IME in every process running at the time ("died too many times
/// recently"): those apps get raw keystrokes until they are relaunched.
final class Candidates {
    /// Created once, right after the IMKServer (AppDelegate), and never
    /// released. Nil only if the server could not be created.
    private(set) static var shared: Candidates?

    static func install(server: IMKServer) {
        guard shared == nil else { return }
        shared = Candidates(server: server)
    }

    /// Internal (not private) so the tests can compare it with the server's
    /// own pointer.
    let panel: IMKCandidates

    /// The controller whose candidates are on screen. The panel is shared, so
    /// a controller that is not (or no longer) the owner must not hide it —
    /// e.g. a background client's late deactivateServer arriving after the
    /// user has started composing in another app.
    private weak var owner: AnyObject?

    // The panel is fed exactly one display page (≤ InputController.pageSize
    // candidates, see InputController.candidates(_:)), but it re-paginates
    // whatever it's given by pixel width: each layout pass rebuilds an
    // IMKUICandidateLayoutTraits whose maxLengthOfLine (~369pt) caps the row,
    // and candidates that don't fit hide behind stepper arrows. The visible
    // page size then varies with each page's widest candidate (4-6 of our 9),
    // and the panel's 1-9 number labels drift from InputController's digit
    // mapping — pressing "1" can commit a candidate other than the one
    // labeled "1". Instance-level setters don't stick (traits are recomputed
    // from defaults every pass), so replace the class getter: every layout
    // pass now reads "current screen width" as the cap, a full engine page
    // always lays out in one row (IMK's per-line element cap is 9 = our page
    // size), the stepper disappears, and labels equal engine indices.
    //
    // Private layout internals of the IMKUI panel implementation, which spans
    // at least macOS 12.6 through 26 (cap 378pt / 369pt respectively) —
    // verified working on both. Where the class or getter is ever absent this
    // no-ops and the panel keeps its default width-driven stepping.
    private static let lineWidthCapRelaxed: Bool = {
        guard
            let traits = NSClassFromString("IMKUICandidateLayoutTraits"),
            let getter = class_getInstanceMethod(
                traits, NSSelectorFromString("maxLengthOfLine")
            )
        else { return false }
        let screenWide: @convention(block) (AnyObject) -> Double = { _ in
            Double(NSScreen.main?.visibleFrame.width ?? 1_440)
        }
        method_setImplementation(getter, imp_implementationWithBlock(screenWide))
        return true
    }()

    private init(server: IMKServer) {
        NSLog("JdIME: candidate line-width cap relaxed = %d", Self.lineWidthCapRelaxed ? 1 : 0)

        // Single-row horizontal stepping panel: native look, paging arrows on
        // the right, dark/light mode automatic.
        let type = IMKCandidatePanelType(kIMKSingleRowSteppingCandidatePanel)
        self.panel = IMKCandidates(server: server, panelType: type)

        // Route every key through InputController.handle(_:client:) FIRST so
        // our key gate has full control (= / -, 1-9, Esc, Backspace, Return
        // semantics differ from IMK defaults).
        panel.setAttributes([
            IMKCandidatesSendServerKeyEventFirst: NSNumber(value: true),
        ])
    }

    /// Show (or refresh) the panel for `owner`, the controller handling the
    /// current key. It has already loaded the visible candidates, which IMK
    /// reads back through its `candidates(_:)`.
    func show(for owner: AnyObject) {
        self.owner = owner
        panel.update()
        if !panel.isVisible() {
            panel.show(kIMKLocateCandidatesBelowHint)
            // The native panel's default window level sits below high-level
            // system UI (Spotlight, the menu bar, fullscreen apps), which then
            // paints over our candidates. Raise it to the shielding level —
            // the level macOS uses to cover the screen, above any normal
            // window — once the window exists (i.e. after show()).
            // setWindowLevel: is a private IMKCandidates selector declared in
            // the bridging header.
            panel.setWindowLevel(Int(CGShieldingWindowLevel()))
        }
    }

    /// Hide the panel if `owner` is the controller that showed it, or if that
    /// controller is gone (a weak reference reads nil once its deinit starts,
    /// which is how InputController.deinit clears a panel it left up).
    func hide(for owner: AnyObject) {
        if let current = self.owner, current !== owner { return }
        self.owner = nil
        if panel.isVisible() {
            panel.hide()
        }
    }
}
