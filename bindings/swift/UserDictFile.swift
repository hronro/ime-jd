// The phrases file behind a client's user dictionary — libjd's own table
// format — and how its lines are read and written. Shared source, compiled
// into both the macOS and iOS frontends (see bindings/swift/README.md); where
// the file lives is each frontend's business. Pure Foundation, no engine
// calls, and no rules of its own: libjd is the authority on what a line
// means — it parses the whole file on every build, skips the lines that do
// not parse, and says why, by line number — so a client never validates a
// cell; it writes what the user typed and shows the engine's verdict
// (UserDictProblem). What is mirrored here is only how a line is split into
// cells for display.
//
// One `value<TAB>keys` line per phrase, `#` comments, blank lines ignored.
// A client reads the file leniently — comments and blank lines are skipped,
// a line without a TAB becomes a row with empty keys so it can be fixed in
// place — and writes it back as one header comment plus one line per entry.
// Anything a text editor put between the lines is gone after the first save
// from a client; a phrase list is a table, not an editor.

import Foundation

/// One phrase: the committable text and the code that reaches it.
struct UserDictEntry: Equatable, Hashable {
    var value: String
    var keys: String

    /// Fields as libjd will read them: ASCII spaces trimmed from both ends.
    func normalized() -> UserDictEntry {
        UserDictEntry(
            value: value.trimmingCharacters(in: UserDictFile.fieldTrim),
            keys: keys.trimmingCharacters(in: UserDictFile.fieldTrim)
        )
    }
}

/// A parsed row: the entry plus the 1-based line it came from.
struct UserDictRow: Equatable {
    let line: Int
    var entry: UserDictEntry
}

enum UserDictFileError: Error, Equatable {
    /// The file is not UTF-8. libjd would reject it line by line; a client
    /// says so once.
    case notUTF8
}

enum UserDictFile {
    static let fileName = "用户自造词.txt"

    /// The first line of every file a client writes, for whoever opens it in
    /// a text editor.
    static let header =
        "# 键道用户自造词：每行一条，格式为「词<TAB>编码」，编码由 a-z 和 ; 组成，1 到 \(UserDict.maxKeyLength) 个字符。"

    /// What libjd trims from a raw line, and from each field.
    static let lineTrim = CharacterSet(charactersIn: " \r")
    static let fieldTrim = CharacterSet(charactersIn: " ")

    // MARK: - Reading and writing

    /// The file's text, or nil when there is no file. A UTF-8 BOM is dropped:
    /// libjd would otherwise accept U+FEFF as part of the first value.
    static func read(at url: URL) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> String {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw UserDictFileError.notUTF8
        }
        return text
    }

    /// Atomic replace — a reader, or a sudden termination, never sees a
    /// partial file. Creates the directory when needed.
    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Lines

    /// Split the way libjd does — on `\n`, counting from 1, `\r` and spaces
    /// trimmed from both ends — skipping comments and blank lines. Lenient
    /// on purpose: fields are not validated, and a line without a TAB
    /// becomes a row whose value is the whole line and whose keys are empty.
    static func parse(_ text: String) -> [UserDictRow] {
        var rows: [UserDictRow] = []
        // `components`, not `split`: a Swift `Character` treats "\r\n" as
        // one grapheme, which `split(separator: "\n")` would never match.
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: lineTrim)
            // The first byte, as libjd checks it: `hasPrefix("#")` compares
            // whole `Character`s, and "#" plus a combining mark is one.
            if line.isEmpty || line.utf8.first == UInt8(ascii: "#") { continue }
            let entry: UserDictEntry
            if let tab = line.firstIndex(of: "\t") {
                entry = UserDictEntry(
                    value: String(line[..<tab]).trimmingCharacters(in: fieldTrim),
                    keys: String(line[line.index(after: tab)...]).trimmingCharacters(in: fieldTrim)
                )
            } else {
                entry = UserDictEntry(value: line, keys: "")
            }
            rows.append(UserDictRow(line: index + 1, entry: entry))
        }
        return rows
    }

    /// The header plus one `value<TAB>keys` line per entry, LF-terminated.
    /// Entry `i` lands on line `i + 2`.
    static func serialize(_ entries: [UserDictEntry]) -> String {
        var text = header + "\n"
        for entry in entries {
            text += "\(entry.value)\t\(entry.keys)\n"
        }
        return text
    }

    /// The line an entry at `index` occupies after `serialize`.
    static func line(ofEntryAt index: Int) -> Int {
        index + 2
    }

    // MARK: - Identity

    /// FNV-1a, 64-bit, over the UTF-8 text: the dictionary's source tag, and
    /// how a client tells an unchanged file (or its own write) from an edit.
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0100_0000_01b3
        }
        return hash
    }
}
