// Platform-agnostic dispatch core for the iOS keyboard. Ports the state machine
// from macos/JdIME/Controller/InputController.swift (dispatch / dispatchEngineKey)
// and the buffer logic from Composition.swift, but:
//   - emits committed text to a `KeyboardHost` (backed by UITextDocumentProxy), and
//   - surfaces the in-flight raw code + loaded candidates via `onChange` so the
//     keyboard draws them in its OWN candidate bar (iOS forbids inline marked text).
//
// No UIKit import here on purpose, so this file is unit-testable with a mock host.
import Foundation

/// The host text field, abstracted to what the session needs. The keyboard
/// extension implements this by forwarding to `textDocumentProxy`; tests use a mock.
protocol KeyboardHost: AnyObject {
    func insertText(_ text: String)
    func deleteBackward()
}

/// What the keyboard needs in order to draw: the candidates loaded so far (an
/// append-only prefix of the engine's list), how many exist in total, and the
/// in-flight raw code.
struct SessionSnapshot: Equatable {
    var candidates: [Candidate] = []
    var optionsCount: UInt32 = 0
    var rawBuffer: String = ""

    static let empty = SessionSnapshot()

    var isComposing: Bool { !rawBuffer.isEmpty }
    /// Whether the bar should offer the expand-to-grid affordance. Keyed to a
    /// fixed count so it doesn't vanish for mid-size candidate sets if the
    /// fetch window changes.
    var canExpand: Bool { optionsCount > 9 }
}

final class InputSession {
    /// How many candidates each fetch pulls in. The bar shows a handful and
    /// asks for more as it scrolls.
    private static let windowSize = 16

    private let engine = Engine()
    weak var host: KeyboardHost?

    /// The in-flight raw code (e.g. "js"), shown in the keyboard's candidate bar.
    private(set) var rawBuffer = ""
    /// Candidates loaded so far, plus the totals the UI needs.
    private(set) var snapshot: SessionSnapshot = .empty

    /// Fired after every state change. UI re-renders the composing label + candidates.
    var onChange: ((SessionSnapshot) -> Void)?

    var isComposing: Bool { !rawBuffer.isEmpty }

    // MARK: - Single entry point

    func handle(_ action: KeyAction) {
        switch action {
        case .passthrough:      break
        case .engineKey(let b): engineKey(b)
        case .backspace:        backspace()
        case .escape:           cancelAndReset()
        case .commitRaw:        commitRaw()
        case .selectIdx(let i): selectVisible(i)
        case .pageNext, .pagePrev:
            // The on-screen keyboard binds no page keys — the candidate bar
            // scrolls instead, pulling more in via `loadMoreCandidates`. These
            // cases exist for the desktop key gate that shares `KeyAction`.
            break
        }
    }

    // MARK: - Engine key

    private func engineKey(_ byte: UInt8) {
        let state = engine.pressKey(byte)

        if let commit = state.commit {
            // Commit goes to the host whether or not a composition was active
            // (macOS branches on composition only to choose the API; both insert).
            host?.insertText(commit)
            rawBuffer = ""
            if state.optionsCount == 0 {
                // Plain commit (and drill-in produced nothing) — end the composition.
                engine.reset()
            } else {
                // Drilled in: committed text + a fresh composition started by `byte`.
                appendToBuffer(byte)
            }
            reload()
            return
        }

        if state.optionsCount > 0 {
            appendToBuffer(byte)
            reload()
            return
        }

        // The engine produced neither commit nor candidates. For printable ASCII
        // this is effectively unreachable (the engine's fallback commits the
        // byte), but unlike macOS there is no host passthrough for an on-screen
        // tap — insert the literal byte so the keypress is never silently dropped.
        if let scalar = Unicode.Scalar(UInt32(byte)) {
            host?.insertText(String(Character(scalar)))
        }
        rawBuffer = ""
        engine.reset()
        reload()
    }

    // MARK: - Backspace

    private func backspace() {
        guard isComposing else {
            // No composition in flight → delete a real character in the host.
            host?.deleteBackward()
            return
        }
        engine.backspace()
        rawBuffer.removeLast()
        if rawBuffer.isEmpty {
            engine.reset()
        }
        reload()
    }

    // MARK: - Commit / cancel

    /// Commit a candidate the user tapped in the bar or grid.
    private func selectVisible(_ idx: Int) {
        guard idx >= 0, idx < snapshot.candidates.count else { return }
        commitCandidate(snapshot.candidates[idx].value)
    }

    /// Commit an explicit candidate value (used by the candidate bar/grid).
    func commitCandidate(_ value: String) {
        host?.insertText(value)
        rawBuffer = ""
        engine.reset()
        reload()
    }

    /// Insert a digit or Chinese punctuation directly, bypassing libjd's punctuation
    /// table. Matches libjd's behavior: while composing, first commit the top
    /// candidate exactly as the engine's space does, then append the literal;
    /// otherwise insert it directly.
    func insertLiteral(_ s: String) {
        if isComposing {
            let state = engine.pressKey(0x20)   // space: commit the anchor, append nothing
            if let commit = state.commit { host?.insertText(commit) }
            rawBuffer = ""
            engine.reset()
            reload()
        }
        host?.insertText(s)
    }

    /// Return-key escape hatch: emit the raw typed code literally, drop composition.
    func commitRaw() {
        if !rawBuffer.isEmpty {
            host?.insertText(rawBuffer)
            rawBuffer = ""
        }
        engine.reset()
        reload()
    }

    /// Drop the in-flight composition without committing (focus change / dismiss).
    func cancelAndReset() {
        rawBuffer = ""
        engine.reset()
        reload()
    }

    /// For the candidate bar's lazy scrolling: fetch the next window of
    /// candidates and return them WITHOUT firing `onChange` (the bar appends
    /// them itself, keeping already-shown candidates). Returns nil at the end
    /// of the list.
    ///
    /// No bookkeeping beyond remembering how far we've got: engine reads are
    /// pure, so fetching ahead cannot change what the engine's automatic
    /// commits resolve to. (The page-based ABI this replaced needed a
    /// jump-back dance here, and getting it wrong committed a candidate the
    /// user wasn't looking at.)
    func loadMoreCandidates() -> [Candidate]? {
        let loaded = UInt32(snapshot.candidates.count)
        guard loaded < snapshot.optionsCount else { return nil }
        let more = engine.readRange(from: loaded, count: Self.windowSize)
        guard !more.isEmpty else { return nil }
        snapshot.candidates.append(contentsOf: more)
        return more
    }

    // MARK: - Helpers

    private func appendToBuffer(_ byte: UInt8) {
        guard let scalar = Unicode.Scalar(UInt32(byte)) else { return }
        rawBuffer.append(Character(scalar))
    }

    /// Re-read the leading window from the engine and publish it.
    private func reload() {
        let state = engine.state
        snapshot = SessionSnapshot(
            candidates: state.optionsCount > 0
                ? engine.readRange(from: 0, count: Self.windowSize)
                : [],
            optionsCount: state.optionsCount,
            rawBuffer: rawBuffer
        )
        onChange?(snapshot)
    }
}
