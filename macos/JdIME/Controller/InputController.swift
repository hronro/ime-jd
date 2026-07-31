import AppKit
import InputMethodKit

@objc(JdIME_InputController)
final class InputController: IMKInputController {
    /// Candidates shown per panel page. Purely a display choice — the engine
    /// addresses candidates by flat index and has no page concept — so the page
    /// arithmetic lives here. 9 matches IMK's per-line element cap and the
    /// panel's 1-9 number labels (see Candidates.swift).
    private static let pageSize: UInt32 = 9

    private let engine = Engine()
    private let composition = Composition()
    private var candidatePanel: Candidates?

    /// The candidates currently on screen.
    private var visible: [Candidate] = []
    /// Flat index of the first visible candidate; always a multiple of
    /// `pageSize`.
    private var pageStart: UInt32 = 0

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        if let server = server {
            self.candidatePanel = Candidates(server: server)
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }
        guard let client = sender as? IMKTextInput else { return false }

        let action = keyAction(event: event, isComposing: composition.isActive)
        return dispatch(action: action, client: client)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        // Engine is per-controller; nothing to do on activation.
    }

    override func deactivateServer(_ sender: Any!) {
        // End any in-flight composition cleanly when the host loses focus.
        if let client = sender as? IMKTextInput {
            if composition.isActive {
                composition.commitRaw(client: client)
            }
        }
        composition.reset()
        endComposition()
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        if composition.isActive {
            composition.commitRaw(client: client)
        }
        endComposition()
    }

    override func cancelComposition() {
        if let client = self.client() {
            composition.cancel(client: client)
        }
        endComposition()
    }

    // MARK: - IMKCandidates callbacks

    override func candidates(_ sender: Any!) -> [Any]! {
        visible.map { CandidateFormatter.display($0) }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let client = self.client() else { return }
        // The panel hands back the *displayed* string (value + 〔hint〕), so map
        // it back to the candidate's committable value — a click should commit
        // 你, not 你 〔…〕. A collision here would need two candidates with the
        // same value AND the same hint, in which case either one commits
        // identical text, so the round-trip is sound.
        let shown = candidateString?.string ?? ""
        let value = visible.first {
            CandidateFormatter.display($0).string == shown
        }?.value ?? shown
        composition.commit(text: value, client: client)
        endComposition()
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        // No-op; engine drives selection.
    }

    // MARK: - Candidate window

    /// Re-read the visible page and point the engine's anchor at it.
    ///
    /// Pointing the anchor first is what keeps the engine's *automatic* commits
    /// (space, `;`, the literal-byte fallback) resolving to a candidate the user
    /// can actually see. Reads themselves are pure, so nothing else needs
    /// restoring afterwards.
    private func refreshCandidates() {
        let total = engine.state.optionsCount
        guard total > 0 else {
            visible = []
            pageStart = 0
            candidatePanel?.hide()
            return
        }
        if pageStart >= total { pageStart = 0 }
        engine.setAnchor(pageStart)
        visible = engine.readRange(from: pageStart, count: Int(Self.pageSize))
        if visible.isEmpty {
            candidatePanel?.hide()
        } else {
            candidatePanel?.show()
        }
    }

    /// Drop the engine's composition and tear down the candidate window.
    private func endComposition() {
        engine.reset()
        candidatePanel?.hide()
        visible = []
        pageStart = 0
    }

    // MARK: - Dispatch

    private func dispatch(action: KeyAction, client: IMKTextInput) -> Bool {
        switch action {
        case .passthrough:
            return false

        case .escape:
            composition.cancel(client: client)
            endComposition()
            return true

        case .commitRaw:
            composition.commitRaw(client: client)
            endComposition()
            return true

        case .backspace:
            engine.backspace()
            let stillComposing = composition.backspace(client: client)
            if !stillComposing {
                endComposition()
            } else {
                pageStart = 0
                refreshCandidates()
            }
            return true

        case .pageNext:
            let next = pageStart + Self.pageSize
            if next < engine.state.optionsCount {
                pageStart = next
                refreshCandidates()
            }
            return true

        case .pagePrev:
            pageStart = pageStart >= Self.pageSize ? pageStart - Self.pageSize : 0
            refreshCandidates()
            return true

        case .selectIdx(let idx):
            if idx < visible.count {
                composition.commit(text: visible[idx].value, client: client)
                endComposition()
                return true
            }
            // No candidate at that slot — fall through to the engine with
            // the digit as a literal byte. The engine treats `1`-`9` as
            // ordinary literal input (it does NOT pick from candidates;
            // that's our job — see core/docs/integration.md), so we end
            // up with the anchor candidate + digit appended via the
            // engine's commit-and-append path. Matches windows/src/tip.rs.
            let digitByte = UInt8(0x31 + idx)
            return dispatchEngineKey(byte: digitByte, client: client)

        case .engineKey(let byte):
            return dispatchEngineKey(byte: byte, client: client)
        }
    }

    private func dispatchEngineKey(byte: UInt8, client: IMKTextInput) -> Bool {
        let state = engine.pressKey(byte)

        if let commit = state.commit {
            if composition.isActive {
                composition.commit(text: commit, client: client)
            } else {
                client.insertText(
                    commit,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            if state.optionsCount == 0 {
                endComposition()
            } else {
                // Drilled in: committed text plus a fresh composition started
                // by the just-pressed key.
                composition.append(byte, client: client)
                pageStart = 0
                refreshCandidates()
            }
            return true
        }

        if state.optionsCount > 0 {
            composition.append(byte, client: client)
            pageStart = 0
            refreshCandidates()
            return true
        }

        // Engine returned nothing — don't consume the key.
        return false
    }
}
