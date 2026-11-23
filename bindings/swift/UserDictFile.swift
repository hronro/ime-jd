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
        "# 键道用户自造词：每行一条，格式为「词<TAB>编码」，编码由 a-z 组成，开头可以有分号（;），1 到 \(UserDict.maxKeyLength) 个字符。"

    /// What libjd trims from each field.
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

    /// The file's bytes as libjd should read them: a UTF-8 BOM dropped, as
    /// `decode` drops it, so a mapped file hashes and builds the same as its
    /// decoded text.
    static func withoutBOM(_ bytes: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        guard bytes.starts(with: [0xEF, 0xBB, 0xBF]) else { return bytes }
        return UnsafeRawBufferPointer(rebasing: bytes[3...])
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
    ///
    /// Byte by byte, as libjd reads it: every byte it splits or trims on is
    /// ASCII, which no byte of a multi-byte character can equal, so cutting
    /// the UTF-8 there is cutting between characters — and a byte loop keeps
    /// a list of hundreds of thousands of phrases quick to read.
    static func parse(_ text: String) -> [UserDictRow] {
        var text = text
        return text.withUTF8 { parse(utf8: $0) }
    }

    private static func parse(utf8 bytes: UnsafeBufferPointer<UInt8>) -> [UserDictRow] {
        let newline = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r"), space = UInt8(ascii: " ")
        let tab = UInt8(ascii: "\t"), hash = UInt8(ascii: "#")
        func string(_ range: Range<Int>) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
        }
        func trimmed(_ range: Range<Int>, _ isTrim: (UInt8) -> Bool) -> Range<Int> {
            var lo = range.lowerBound, hi = range.upperBound
            while lo < hi, isTrim(bytes[lo]) { lo += 1 }
            while hi > lo, isTrim(bytes[hi - 1]) { hi -= 1 }
            return lo..<hi
        }
        var rows: [UserDictRow] = []
        var line = 0
        var start = 0
        while start <= bytes.count {
            line += 1
            var end = start
            while end < bytes.count, bytes[end] != newline { end += 1 }
            defer { start = end + 1 }
            let raw = trimmed(start..<end) { $0 == space || $0 == cr }
            if raw.isEmpty || bytes[raw.lowerBound] == hash { continue }
            let entry: UserDictEntry
            if let split = raw.first(where: { bytes[$0] == tab }) {
                entry = UserDictEntry(
                    value: string(trimmed(raw.lowerBound..<split) { $0 == space }),
                    keys: string(trimmed(split + 1..<raw.upperBound) { $0 == space })
                )
            } else {
                entry = UserDictEntry(value: string(raw), keys: "")
            }
            rows.append(UserDictRow(line: line, entry: entry))
        }
        return rows
    }

    /// The header plus one `value<TAB>keys` line per entry, LF-terminated.
    /// Entry `i` lands on line `i + 2`.
    static func serialize(_ entries: [UserDictEntry]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(header.utf8.count + 1 + entries.count * 20)
        bytes.append(contentsOf: header.utf8)
        bytes.append(UInt8(ascii: "\n"))
        for entry in entries {
            bytes.append(contentsOf: entry.value.utf8)
            bytes.append(UInt8(ascii: "\t"))
            bytes.append(contentsOf: entry.keys.utf8)
            bytes.append(UInt8(ascii: "\n"))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The line an entry at `index` occupies after `serialize`.
    static func line(ofEntryAt index: Int) -> Int {
        index + 2
    }
}
