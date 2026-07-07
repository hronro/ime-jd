// Platform-agnostic dispatch core for the iOS keyboard. Ports the state machine
// from macos/JdIME/Controller/InputController.swift (dispatch / dispatchEngineKey /
// applyEngineResult) and the buffer logic from Composition.swift, but:
//   - emits committed text to a `KeyboardHost` (backed by UITextDocumentProxy), and
//   - surfaces the in-flight raw code + candidate snapshot via `onChange` so the
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

final class InputSession {
    private let engine: Engine
    weak var host: KeyboardHost?

    /// The in-flight raw code (e.g. "js"), shown in the keyboard's candidate bar.
    private(set) var rawBuffer = ""
    /// Candidates/commit for the current page. `options` is this page only.
    private(set) var snapshot: QuerySnapshot = .empty
    /// Highest engine page fetched into the UI's append-only candidate strip.
    /// Runs ahead of `snapshot.currentPage` during lazy pagination — see
    /// `loadMoreCandidates`, which parks the engine back on the snapshot's page.
    private var lastFetchedPage: UInt32 = 0

    /// Fired after every state change. UI re-renders the composing label + candidates.
    var onChange: ((_ snapshot: QuerySnapshot, _ rawBuffer: String) -> Void)?

    var isComposing: Bool { !rawBuffer.isEmpty }

    init(pageSize: UInt8 = 9) {
        self.engine = Engine(pageSize: pageSize)
    }

    // MARK: - Single entry point

    func handle(_ action: KeyAction) {
        switch action {
        case .passthrough:        break
        case .engineKey(let b):   engineKey(b)
        case .backspace:          backspace()
        case .escape:             cancelAndReset()
        case .commitRaw:          commitRaw()
        case .pageNext:           applyEngineResult(engine.nextPage())
        case .pagePrev:           applyEngineResult(engine.prevPage())
        case .selectIdx(let i):   selectVisible(i)
        }
    }

    // MARK: - Engine key (port of dispatchEngineKey)

    private func engineKey(_ byte: UInt8) {
        let snap = engine.pressKey(byte)

        if let commit = snap.commit {
            // Commit goes to the host whether or not a composition was active
            // (macOS branches on composition only to choose the API; both insert).
            host?.insertText(commit)
            rawBuffer = ""
            if snap.options.isEmpty {
                // Plain commit (and drill-in produced nothing) — end the composition.
                engine.reset()
                setSnapshot(.empty)
            } else {
                // Drilled-in: committed text + a fresh composition started by `byte`.
                appendToBuffer(byte)
                setSnapshot(snap)
            }
            return
        }

        if !snap.options.isEmpty {
            appendToBuffer(byte)
            setSnapshot(snap)
            return
        }

        // The engine produced neither commit nor options. For printable ASCII this
        // is effectively unreachable (the engine's fallback commits the byte), but
        // unlike macOS there is no host passthrough for an on-screen tap — insert
        // the literal byte so the keypress is never silently dropped.
        if let scalar = Unicode.Scalar(UInt32(byte)) {
            host?.insertText(String(Character(scalar)))
        }
        rawBuffer = ""
        engine.reset()
        setSnapshot(.empty)
    }

    // MARK: - Backspace

    private func backspace() {
        guard isComposing else {
            // No composition in flight → delete a real character in the host.
            host?.deleteBackward()
            return
        }
        let snap = engine.backspace()
        rawBuffer.removeLast()
        if rawBuffer.isEmpty {
            engine.reset()
            setSnapshot(.empty)
        } else {
            applyEngineResult(snap)
        }
    }

    // MARK: - Commit / cancel

    /// Commit a candidate the user tapped on the current page.
    private func selectVisible(_ idx: Int) {
        guard idx >= 0, idx < snapshot.options.count else { return }
        commitCandidate(snapshot.options[idx].value)
    }

    /// Commit an explicit candidate value (used by the paginated candidate bar/grid).
    func commitCandidate(_ value: String) {
        host?.insertText(value)
        rawBuffer = ""
        engine.reset()
        setSnapshot(.empty)
    }

    /// Insert a digit or Chinese punctuation directly, bypassing libjd's punctuation
    /// table. Matches libjd's behavior: while composing, first commit the top
    /// candidate exactly as the engine's space does (option 0), then append the
    /// literal; otherwise insert it directly.
    func insertLiteral(_ s: String) {
        if isComposing {
            let snap = engine.pressKey(0x20)   // space: commit option 0, append nothing
            if let commit = snap.commit { host?.insertText(commit) }
            rawBuffer = ""
            engine.reset()
            setSnapshot(.empty)
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
        setSnapshot(.empty)
    }

    /// Drop the in-flight composition without committing (focus change / dismiss).
    func cancelAndReset() {
        rawBuffer = ""
        engine.reset()
        setSnapshot(.empty)
    }

    /// For the candidate bar's lazy pagination: fetch the page after the last
    /// fetched one and return its candidates WITHOUT firing `onChange` (the bar
    /// appends them itself, keeping already-shown candidates). Returns nil at the
    /// last page. The returned strings are owned Swift copies, safe to retain
    /// across later engine calls.
    ///
    /// The engine is parked back on `snapshot.currentPage` before returning:
    /// engine auto-commits (space, drill-in, punctuation fallback) act on the
    /// first option of the engine's CURRENT page, so leaving the paginator on a
    /// prefetched page would commit a candidate the user isn't looking at.
    func loadMoreCandidates() -> [Candidate]? {
        guard lastFetchedPage < snapshot.totalPages else { return nil }
        let next = engine.jumpToPage(lastFetchedPage + 1)
        _ = engine.jumpToPage(snapshot.currentPage)
        guard !next.options.isEmpty else { return nil }
        lastFetchedPage = next.currentPage
        return next.options
    }

    // MARK: - Helpers

    private func applyEngineResult(_ snap: QuerySnapshot) {
        setSnapshot(snap)
    }

    private func appendToBuffer(_ byte: UInt8) {
        guard let scalar = Unicode.Scalar(UInt32(byte)) else { return }
        rawBuffer.append(Character(scalar))
    }

    private func setSnapshot(_ snap: QuerySnapshot) {
        snapshot = snap
        lastFetchedPage = snap.currentPage
        onChange?(snap, rawBuffer)
    }
}
