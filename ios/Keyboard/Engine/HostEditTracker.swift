// Tells a change the host reports apart from the keyboard's own edits and
// from the user moving on. No UIKit, so it is tested hostless.
//
// iOS gives a third-party keyboard no marked text: the code being typed lives
// in the keyboard's own candidate bar, and the host sees only what is
// committed. So when the host reports that its text changed while a code is in
// flight, the keyboard has to decide whether the code still belongs where it
// was typed. It does not when the user tapped another field or moved the caret
// (the system keyboards drop it then too); it does when the change is the echo
// of our own edit, or the host reacting to it — a completion after the caret,
// or Safari's address bar, which reports a change about a second after each
// commit; dropping the code then lost what the user was typing.
//
// What decides it is the text before the caret: after any of our recent edits
// it ends with what we typed, and a completion after the caret leaves it so,
// while a caret moved elsewhere leaves it ending with something else. A host
// that shares no text around the caret at all — Safari's address bar, measured
// on iOS 18.2: no text before or after, no selection, yet a change reported
// about a second after each insert — gives nothing to tell those apart, so
// there only a switch to another field (a new document identifier) counts.
// Where nothing we typed is known (a new presentation, a new line), a change
// counts as our own only while it follows our last edit closely, as before.

import Foundation

struct HostEditTracker {
    /// How soon after our own edit any change still counts as its echo.
    static let echoGrace: TimeInterval = 0.15
    /// How much of what we typed is remembered: enough that text elsewhere
    /// rarely ends the same way.
    static let tailLength = 16
    /// How many of our recent edits a host may still be catching up on.
    static let historyLength = 8

    /// After each of our recent edits, newest last: the text we expect to end
    /// the host's text before the caret. Empty when it is not known.
    private var tails: [String] = []
    private var lastOwnEdit: TimeInterval = -.infinity
    /// The field our edits and the host's reports were last about.
    private var document: UUID?

    /// We inserted `text` at the caret of `document`.
    mutating func inserted(_ text: String, into document: UUID? = nil, at time: TimeInterval) {
        noteDocument(document)
        lastOwnEdit = time
        var tail = (tails.last ?? "") + text
        // The text before the caret may not reach past a line break.
        if let newline = tail.lastIndex(where: \.isNewline) {
            tail = String(tail[tail.index(after: newline)...])
        }
        remember(String(tail.suffix(Self.tailLength)))
    }

    /// We deleted the character before the caret of `document`.
    mutating func deletedBackward(in document: UUID? = nil, at time: TimeInterval) {
        noteDocument(document)
        lastOwnEdit = time
        remember(String((tails.last ?? "").dropLast()))
    }

    /// Nothing we typed is known to end the host's text any more.
    mutating func forget() {
        tails.removeAll()
        document = nil
    }

    /// Another field means none of what we typed is before its caret.
    private mutating func noteDocument(_ id: UUID?) {
        guard let id else { return }
        if let document, document != id { tails.removeAll() }
        document = id
    }

    private mutating func remember(_ tail: String) {
        tails.append(tail)
        if tails.count > Self.historyLength { tails.removeFirst(tails.count - Self.historyLength) }
    }

    /// Whether a change the host reported — with `contextBefore` and
    /// `contextAfter` now around the caret, in `document` — means the caret
    /// left where we were typing. Records the document, so call it once per
    /// report.
    mutating func caretMoved(contextBefore: String?, contextAfter: String? = nil, document id: UUID? = nil,
                             at time: TimeInterval) -> Bool {
        let otherField = id != nil && document != nil && id != document
        noteDocument(id)
        if otherField { return true }
        if time - lastOwnEdit <= Self.echoGrace { return false }
        // No text on either side: a host that shares none (or an empty
        // field, where the caret has nowhere to go) — only another field
        // counts. Text after but none before is a caret at the start.
        if contextBefore == nil, contextAfter == nil { return false }
        let before = contextBefore ?? ""
        guard let latest = tails.last, !latest.isEmpty else { return true }
        return !tails.contains { !$0.isEmpty && before.hasSuffix($0) }
    }
}
