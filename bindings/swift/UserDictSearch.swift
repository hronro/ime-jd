// Searching a phrase list, for the list screens of both the macOS and iOS
// frontends. Shared source; pure Foundation, no engine calls.

import Foundation

/// A phrase list's rows as one case-folded text, so a search box keeps up
/// with hundreds of thousands of rows: each row is its value, a TAB, its
/// keys and a newline, lowercased, and a query is one substring scan of the
/// whole text with every hit mapped back to its row. Build it when the rows
/// change — or at the first query after — and ask it as often as the query
/// changes. Matching is case-insensitive as `lowercased()` folds, and never
/// runs across fields, a query holding no TAB or newline.
struct UserDictSearch {
    private var text: [UInt8] = []
    /// Where row `i` starts in `text` is `starts[i]`; one more at the end.
    private var starts: [Int] = [0]

    init(_ entries: some Sequence<UserDictEntry>) {
        for entry in entries {
            Self.appendFolded(entry.value, to: &text)
            text.append(UInt8(ascii: "\t"))
            Self.appendFolded(entry.keys, to: &text)
            text.append(UInt8(ascii: "\n"))
            starts.append(text.count)
        }
    }

    /// The rows that contain `query`, ascending; every row for an empty
    /// query.
    func matches(_ query: String) -> [Int] {
        let rows = starts.count - 1
        guard !query.isEmpty else { return Array(0..<rows) }
        var needle: [UInt8] = []
        Self.appendFolded(query, to: &needle)
        guard !text.isEmpty, needle.allSatisfy({ $0 != UInt8(ascii: "\t") && $0 != UInt8(ascii: "\n") }) else {
            return []
        }
        var hits: [Int] = []
        text.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { pin in
                let base = haystack.baseAddress!
                var from = 0
                var row = 0
                while from < haystack.count,
                      let found = memmem(base + from, haystack.count - from, pin.baseAddress!, pin.count) {
                    let at = base.distance(to: found)
                    while starts[row + 1] <= at { row += 1 }
                    hits.append(row)
                    // One hit per row: go on from the next one.
                    from = starts[row + 1]
                }
            }
        }
        return hits
    }

    /// `string` lowercased, as UTF-8: byte by byte when it is ASCII, as
    /// every code and much Latin text is; through `lowercased()` otherwise.
    private static func appendFolded(_ string: String, to bytes: inout [UInt8]) {
        if string.utf8.allSatisfy({ $0 < 0x80 }) {
            for byte in string.utf8 {
                bytes.append(byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte)
            }
        } else {
            bytes.append(contentsOf: string.lowercased().utf8)
        }
    }
}
