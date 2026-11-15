import Foundation

/// What 编码反查 shows for one query: libjd's codes for it (`jd_lookup_codes`),
/// worded for the user. Pure — the window controller puts it in an alert.
struct CodeLookupReport: Equatable {
    /// The alert's bold line.
    let title: String
    /// The alert's text: one code per line, or why there are none.
    let body: String
    let found: Bool

    /// The query as the engine should see it. A pasted word often carries a
    /// line break or spaces at its ends; dropping spaces, TABs, CRs and LFs
    /// there never loses a match, because no phrase starts or ends with one
    /// (the table format trims spaces, and control bytes are not allowed in
    /// a phrase). U+3000 and other spaces stay: a phrase may end with one.
    static func query(from input: String) -> String {
        input.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
    }

    /// `codes` are libjd's, in its order: shortest first. On a code where
    /// the word is the first candidate the code stands alone; any other says
    /// which candidate the word is there. Nothing says which key commits
    /// it: that is the engine's business, and it has changed before.
    /// `userDictEnabled` says whether the user's phrases were looked up too,
    /// which only changes the wording when nothing was found.
    init(query: String, codes: [Code], userDictEnabled: Bool) {
        let word = Self.shown(query)
        guard !codes.isEmpty else {
            title = "没有找到「\(word)」"
            body = userDictEnabled
                ? "内置词库和用户自造词中都没有这个词。"
                : "内置词库中没有这个词。用户自造词未启用，不在查询范围内。"
            found = false
            return
        }
        let lines = codes.map { code -> String in
            var notes: [String] = []
            if code.index > 0 { notes.append("第 \(code.index + 1) 个候选") }
            if code.isUser { notes.append("自造词") }
            return notes.isEmpty ? code.keys : "\(code.keys)（\(notes.joined(separator: "，"))）"
        }
        title = "「\(word)」的编码"
        body = lines.joined(separator: "\n")
        found = true
    }

    /// The query as a title quotes it: a long paste is cut short.
    private static func shown(_ query: String) -> String {
        let limit = 20
        return query.count > limit ? String(query.prefix(limit)) + "…" : query
    }
}
