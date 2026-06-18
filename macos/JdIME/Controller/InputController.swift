import AppKit
import InputMethodKit

@objc(JdIME_InputController)
final class InputController: IMKInputController {
    private let engine = Engine(pageSize: 9)
    private let composition = Composition()
    private var candidatePanel: Candidates?
    private var lastSnapshot: QuerySnapshot = .empty

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
        engine.reset()
        composition.reset()
        candidatePanel?.hide()
        lastSnapshot = .empty
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        if composition.isActive {
            composition.commitRaw(client: client)
        }
        engine.reset()
        candidatePanel?.hide()
        lastSnapshot = .empty
    }

    override func cancelComposition() {
        if let client = self.client() {
            composition.cancel(client: client)
        }
        engine.reset()
        candidatePanel?.hide()
        lastSnapshot = .empty
    }

    // MARK: - IMKCandidates callbacks

    override func candidates(_ sender: Any!) -> [Any]! {
        lastSnapshot.options.map { CandidateFormatter.display($0) }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let client = self.client() else { return }
        // The panel hands back the displayed string (value + 〔hint〕). Map it
        // back to the candidate's committable value so a click commits 你, not
        // 你 〔…〕.
        let shown = candidateString?.string ?? ""
        let value = lastSnapshot.options.first {
            CandidateFormatter.display($0).string == shown
        }?.value ?? shown
        composition.commit(text: value, client: client)
        engine.reset()
        candidatePanel?.hide()
        lastSnapshot = .empty
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        // No-op; engine drives selection.
    }

    // MARK: - Dispatch

    private func dispatch(action: KeyAction, client: IMKTextInput) -> Bool {
        switch action {
        case .passthrough:
            return false

        case .escape:
            composition.cancel(client: client)
            engine.reset()
            candidatePanel?.hide()
            lastSnapshot = .empty
            return true

        case .commitRaw:
            composition.commitRaw(client: client)
            engine.reset()
            candidatePanel?.hide()
            lastSnapshot = .empty
            return true

        case .backspace:
            let snapshot = engine.backspace()
            let stillComposing = composition.backspace(client: client)
            if !stillComposing {
                engine.reset()
                candidatePanel?.hide()
                lastSnapshot = .empty
            } else {
                applyEngineResult(snapshot: snapshot, client: client, appendByte: nil)
            }
            return true

        case .pageNext:
            let snapshot = engine.nextPage()
            applyEngineResult(snapshot: snapshot, client: client, appendByte: nil)
            return true

        case .pagePrev:
            let snapshot = engine.prevPage()
            applyEngineResult(snapshot: snapshot, client: client, appendByte: nil)
            return true

        case .selectIdx(let idx):
            if idx < lastSnapshot.options.count {
                let text = lastSnapshot.options[idx].value
                composition.commit(text: text, client: client)
                engine.reset()
                candidatePanel?.hide()
                lastSnapshot = .empty
                return true
            }
            // Fall through to engine with the digit as a literal — matches
            // windows/src/tip.rs:183-195 behavior.
            let digitByte = UInt8(0x31 + idx)
            return dispatchEngineKey(byte: digitByte, client: client)

        case .engineKey(let byte):
            return dispatchEngineKey(byte: byte, client: client)
        }
    }

    private func dispatchEngineKey(byte: UInt8, client: IMKTextInput) -> Bool {
        let snapshot = engine.pressKey(byte)

        if let commit = snapshot.commit {
            if composition.isActive {
                composition.commit(text: commit, client: client)
            } else {
                client.insertText(
                    commit,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            if snapshot.options.isEmpty {
                engine.reset()
                candidatePanel?.hide()
                lastSnapshot = .empty
            } else {
                composition.append(byte, client: client)
                showCandidates(snapshot: snapshot)
            }
            return true
        }

        if !snapshot.options.isEmpty {
            composition.append(byte, client: client)
            showCandidates(snapshot: snapshot)
            return true
        }

        // Engine returned nothing — don't consume the key.
        return false
    }

    private func applyEngineResult(
        snapshot: QuerySnapshot,
        client: IMKTextInput,
        appendByte: UInt8?
    ) {
        if let b = appendByte {
            composition.append(b, client: client)
        }
        if snapshot.options.isEmpty {
            candidatePanel?.hide()
            lastSnapshot = snapshot
        } else {
            showCandidates(snapshot: snapshot)
        }
    }

    private func showCandidates(snapshot: QuerySnapshot) {
        lastSnapshot = snapshot
        candidatePanel?.show(snapshot: snapshot)
    }
}
