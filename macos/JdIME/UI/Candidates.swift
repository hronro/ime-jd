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

    init(server: IMKServer) {
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
        }
    }

    func hide() {
        if panel.isVisible() {
            panel.hide()
        }
    }
}
