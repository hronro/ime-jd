import AppKit
import InputMethodKit

// Formats a candidate for display in the IMKCandidates panel: the value
// followed by its optional hint in 〔 〕 brackets, dimmed — matching the
// Windows and CLI frontends (` 〔hint〕`). Used both to populate the panel and
// to map a clicked candidate string back to its committable value.
enum CandidateFormatter {
    static func display(_ candidate: Candidate) -> NSAttributedString {
        let result = NSMutableAttributedString(string: candidate.value)
        if let hint = candidate.hint, !hint.isEmpty {
            result.append(NSAttributedString(
                string: " 〔\(hint)〕",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return result
    }
}

final class Candidates {
    private let panel: IMKCandidates

    // The panel is fed exactly one engine page (≤ pageSize candidates, see
    // InputController.candidates(_:)), but the stepping panel re-paginates
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

    init(server: IMKServer) {
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

    func show(snapshot: QuerySnapshot) {
        guard !snapshot.options.isEmpty else {
            hide()
            return
        }
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

    func hide() {
        if panel.isVisible() {
            panel.hide()
        }
    }
}
