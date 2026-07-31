// Value types over libjd's C ABI. Shared source, compiled into both the macOS
// and iOS frontends — see bindings/swift/README.md.
//
// Nothing here copies defensively, because the ABI has no borrowed data:
// a candidate's `value` and a commit's segments point into libjd's embedded
// dictionary blob (read-only, alive for the whole process), and a candidate's
// `hint` is inline bytes. A `Candidate` is therefore free to keep, and its
// `String`s are built only when something actually asks for them — so a long
// candidate strip costs no String work for the rows nobody scrolls to.

import Foundation
import Libjd

/// One candidate: the committable text plus an optional hint listing the keys
/// still needed to reach it.
struct Candidate: Equatable {
    fileprivate let raw: query_option

    /// Internal, not fileprivate: `Engine.readRange` (a separate file in the
    /// same target) builds these from the buffer libjd wrote into.
    init(raw: query_option) {
        self.raw = raw
    }

    /// The committable text. Materialized on access; see the file comment.
    var value: String {
        guard let p = raw.value else { return "" }
        return String(cString: p)
    }

    /// Keys still needed below this candidate, or nil when it is complete.
    var hint: String? {
        withUnsafeBytes(of: raw.hint) { buf -> String? in
            guard let first = buf.first, first != 0 else { return nil }
            let end = buf.firstIndex(of: 0) ?? buf.count
            return String(decoding: buf[0..<end], as: UTF8.self)
        }
    }

    static func == (lhs: Candidate, rhs: Candidate) -> Bool {
        // Values are interned in the blob, so identical candidates share a
        // pointer — no string comparison needed.
        lhs.raw.value == rhs.raw.value && lhs.hint == rhs.hint
    }
}

/// What the engine holds after an operation.
///
/// `commit` is the last operation's committed text, already joined from the
/// ABI's segments. `optionsCount` is the total number of candidates in flight;
/// read them with `Engine.readRange`. `anchorIndex` is the candidate the
/// engine's own automatic commits resolve against — space and the literal-byte
/// fallbacks take it, `;` takes the next one.
struct EngineState: Equatable {
    let commit: String?
    let optionsCount: UInt32
    let anchorIndex: UInt32

    static let empty = EngineState(commit: nil, optionsCount: 0, anchorIndex: 0)

    var isComposing: Bool { optionsCount > 0 }
    var hasCommit: Bool { commit != nil }
    var isEmpty: Bool { commit == nil && optionsCount == 0 }
}

extension EngineState {
    /// Reads the context's state block, joining the commit segments in the
    /// order the ABI defines: `commit_a ++ commit_b ++ commit_lit`.
    init(_ raw: jd_state) {
        var joined: String? = nil
        if raw.commit_a != nil || raw.commit_b != nil || raw.commit_lit != 0 {
            var text = ""
            if let a = raw.commit_a { text += String(cString: a) }
            if let b = raw.commit_b { text += String(cString: b) }
            if raw.commit_lit != 0, let scalar = Unicode.Scalar(UInt32(UInt8(bitPattern: raw.commit_lit))) {
                text.append(Character(scalar))
            }
            joined = text
        }
        self.init(
            commit: joined,
            optionsCount: raw.options_count,
            anchorIndex: raw.anchor_index
        )
    }
}
