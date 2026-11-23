// 编码反查's wording, shared by the macOS window and the iOS page. Pure
// Foundation; each frontend lays it out its own way.

import Foundation

/// What 编码反查 shows for one query: libjd's codes for it
/// (`jd_lookup_codes`), worded for the user.
struct CodeLookupReport: Equatable {
    /// One code: the keys, and what sets it apart, if anything.
    struct Line: Equatable {
        let keys: String
        /// Which candidate the word is on this code when it is not the
        /// first, and whether the code is the user's (`自造词`); nil when
        /// neither applies.
        let note: String?
    }

    /// `「着」的编码`, or `没有找到「…」`.
    let title: String
    /// The codes, in libjd's order — shortest first; empty when not found.
    let lines: [Line]
    /// Why nothing was found; nil when something was.
    let message: String?

    var found: Bool { !lines.isEmpty }

    /// One block of text: a line per code with its note in brackets, or
    /// the message — for a frontend that shows the report as prose.
    var text: String {
        guard found else { return message ?? "" }
        return lines.map { line in
            line.note.map { "\(line.keys)（\($0)）" } ?? line.keys
        }.joined(separator: "\n")
    }

    /// The query as the engine should see it. A pasted word often carries a
    /// line break or spaces at its ends; dropping spaces, TABs, CRs and LFs
    /// there never loses a match, because no phrase starts or ends with one
    /// (the table format trims spaces, and control bytes are not allowed in
    /// a phrase). U+3000 and other spaces stay: a phrase may end with one.
    static func query(from input: String) -> String {
        input.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
    }

    /// Which dictionaries a lookup searched — what the keyboard types from.
    enum Scope: Equatable {
        /// The built-in dictionary alone: the user's phrases are off.
        case builtIn
        /// The built-in dictionary and the user's phrases.
        case builtInAndUser
        /// The user's phrases alone: the built-in dictionary is off.
        case userOnly
    }

    /// `codes` are libjd's, in its order. On a code where the word is the
    /// first candidate the code stands alone; any other says which
    /// candidate the word is there. Nothing says which key commits it: that
    /// is the engine's business, and it has changed before. `scope` says
    /// which dictionaries were looked up, which only changes the wording
    /// when nothing was found.
    init(query: String, codes: [Code], scope: Scope) {
        let word = Self.shown(query)
        guard !codes.isEmpty else {
            title = "没有找到「\(word)」"
            lines = []
            switch scope {
            case .builtIn: message = "内置词库中没有这个词。用户自造词未启用，不在查询范围内。"
            case .builtInAndUser: message = "内置词库和用户自造词中都没有这个词。"
            case .userOnly: message = "用户自造词中没有这个词。内置词库已忽略，不在查询范围内。"
            }
            return
        }
        title = "「\(word)」的编码"
        lines = codes.map { code in
            var notes: [String] = []
            if code.index > 0 { notes.append("第 \(code.index + 1) 个候选") }
            if code.isUser { notes.append("自造词") }
            return Line(keys: code.keys, note: notes.isEmpty ? nil : notes.joined(separator: "，"))
        }
        message = nil
    }

    /// Nothing could be looked up: the user's phrases alone were to be
    /// searched, and they cannot be had, for the reason `why` gives.
    init(query: String, unavailable why: String) {
        title = "没有找到「\(Self.shown(query))」"
        lines = []
        message = why
    }

    /// The query as a title quotes it: a long paste is cut short.
    private static func shown(_ query: String) -> String {
        let limit = 20
        return query.count > limit ? String(query.prefix(limit)) + "…" : query
    }
}
