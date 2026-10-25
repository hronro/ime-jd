// The engine's verdict on one row of a phrase list, for a status column: the
// notes `UserDict.build` leaves, mapped onto the rows by line, with the text
// a client shows. Shared source, compiled into both the macOS and iOS
// frontends — one copy of the mapping and of the words, so the two phrase
// lists cannot drift.

import Foundation

enum UserDictProblem: Equatable {
    /// In the file, but libjd skips it: it does not parse.
    case invalid(UserDictNote.Flags)
    /// In the file, but libjd drops it: the same phrase as the row given,
    /// or (nil) as a built-in word.
    case duplicate(ofRow: Int?)
    /// Works, and is listed first — but the code already carries `builtIn`
    /// built-in words and/or `peers` other rows, the first of them
    /// `otherRow`.
    case sharedCode(builtIn: Int, otherRow: Int?, peers: Int)

    var text: String {
        switch self {
        case .invalid(let flags):
            if flags.contains(.malformed) {
                return "缺少制表符（无编码），不生效"
            }
            if flags.contains(.badKeys) {
                return "编码无效（1 到 \(UserDict.maxKeyLength) 个 a-z 或 ;），不生效"
            }
            return "词无效（不能为空或含控制字符，最长 \(UserDict.maxValueBytes) 字节），不生效"
        case .duplicate(let row?):
            return "与第 \(row + 1) 条重复，不生效"
        case .duplicate(nil):
            return "与内置词重复，不生效"
        case .sharedCode(let builtIn, let otherRow, let peers):
            // "与 2 个内置词及第 3 条等 2 条同码", or either half alone.
            var parts: [String] = []
            if builtIn > 0 { parts.append(" \(builtIn) 个内置词") }
            if let otherRow {
                parts.append(peers > 1 ? "第 \(otherRow + 1) 条等 \(peers) 条" : "第 \(otherRow + 1) 条")
            }
            return "与" + parts.joined(separator: "及") + "同码"
        }
    }

    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }

    var isDuplicate: Bool {
        if case .duplicate = self { return true }
        return false
    }

    var isSharedCode: Bool {
        if case .sharedCode = self { return true }
        return false
    }

    /// One verdict per row, from the notes of the build of the text the rows
    /// came from. `lines[i]` is row `i`'s 1-based line in that text, nil for
    /// a row that is not in it (added, not yet written). A nil `report` —
    /// the text could not be built at all — flags nothing: the engine has
    /// no notes on a file it could not read.
    static func forRows(lines: [Int?], report: UserDictReport?) -> [UserDictProblem?] {
        guard let report else {
            return Array(repeating: nil, count: lines.count)
        }
        var notes: [Int: UserDictNote] = [:]
        for note in report.notes {
            notes[Int(note.line)] = note
        }
        var rowByLine: [Int: Int] = [:]
        for (index, line) in lines.enumerated() {
            if let line { rowByLine[line] = index }
        }
        return lines.map { line -> UserDictProblem? in
            guard let line, let note = notes[line] else { return nil }
            let other = rowByLine[Int(note.other)]
            if note.isInvalid {
                return .invalid(note.flags)
            }
            if note.flags.contains(.repeatsLine) {
                return .duplicate(ofRow: other)
            }
            if note.flags.contains(.repeatsBuiltIn) {
                return .duplicate(ofRow: nil)
            }
            if note.isShared {
                return .sharedCode(
                    builtIn: Int(note.builtIn),
                    otherRow: note.flags.contains(.codeInLine) ? other : nil,
                    peers: Int(note.peers)
                )
            }
            return nil
        }
    }
}
