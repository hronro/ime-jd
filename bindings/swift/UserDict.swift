// A user dictionary over libjd's C ABI: the user's own phrases, compiled once
// into the blob the engine reads in place. Shared source, compiled into both
// the macOS and iOS frontends — see bindings/swift/README.md.
//
// The engine never copies the blob (see jd_init in core/include/jd.h): it must
// be 4-byte aligned and must outlive every context created with it and every
// candidate `value` that points into it. A `UserDict` owns aligned storage and
// frees it in `deinit`; an `Engine` created with one retains it for as long as
// the context lives. What remains for a frontend is documented on `Candidate`:
// a candidate read from such an engine must not outlive the engine.
//
// Where the phrases live — a text file, a table behind a GUI — is each
// frontend's business; the text handed to `build` is only the interchange
// format for that one call.

import Foundation
import Libjd

/// Why a user dictionary could not be built or accepted. Mirrors the
/// `JD_USER_DICT_*` status codes in `core/include/jd.h`. These are failures
/// of a call as a whole; a line that does not parse is not one — the build
/// skips it and says so in a `UserDictNote`.
struct UserDictError: Error, Equatable, CustomStringConvertible {
    enum Status: Equatable {
        /// `build`: the output buffer was smaller than the bound (a bug in this wrapper).
        case bufferTooSmall
        /// `build`: more than `UserDict.maxEntries` phrases; `line` is the first excess one.
        case tooManyEntries
        /// A cached blob built by a different libjd — format or built-in
        /// dictionary differ. Rebuild it from the phrases.
        case stale
        /// A cached blob that is structurally invalid. Rebuild it from the phrases.
        case corrupt
        /// The blob pointer was not 4-byte aligned (a bug in this wrapper).
        case misaligned
        /// `build`: the text exceeds `JD_USER_DICT_TEXT_MAX`.
        case textTooLong
        /// A status this wrapper does not know (a newer library).
        case unknown(UInt32)

        init(code: UInt32) {
            switch code {
            case UInt32(JD_USER_DICT_BUFFER_TOO_SMALL): self = .bufferTooSmall
            case UInt32(JD_USER_DICT_TOO_MANY_ENTRIES): self = .tooManyEntries
            case UInt32(JD_USER_DICT_STALE): self = .stale
            case UInt32(JD_USER_DICT_CORRUPT): self = .corrupt
            case UInt32(JD_USER_DICT_MISALIGNED): self = .misaligned
            case UInt32(JD_USER_DICT_TEXT_TOO_LONG): self = .textTooLong
            default: self = .unknown(code)
            }
        }

        /// Whether `line` points at an input line — the first phrase past
        /// the cap — rather than the status describing a cached blob or the
        /// call itself.
        var isLineError: Bool {
            self == .tooManyEntries
        }
    }

    let status: Status
    /// The 1-based input line for a `status.isLineError` status, otherwise 0.
    let line: UInt32

    var description: String {
        let what: String
        switch status {
        case .bufferTooSmall: what = "output buffer too small"
        case .tooManyEntries: what = "more than \(UserDict.maxEntries) phrases"
        case .stale: what = "blob was built against a different dictionary (rebuild it)"
        case .corrupt: what = "blob is corrupt (rebuild it)"
        case .misaligned: what = "blob is not 4-byte aligned"
        case .textTooLong: what = "text is too long"
        case .unknown(let code): what = "unknown status \(code)"
        }
        return status.isLineError ? "line \(line): \(what)" : what
    }
}

/// One thing `UserDict.build` has to say about an input line. Mirrors
/// `jd_user_dict_note` in `core/include/jd.h`.
///
/// A skipped line (it does not parse) carries exactly one of `malformed`,
/// `badKeys` and `badValue`, and nothing else. A dropped line (parsed, but
/// not in the dictionary) carries `repeatsLine` or `repeatsBuiltIn`. A kept
/// line whose code is already taken carries `codeInBuiltIn` and/or
/// `codeInLine`: the phrase works, listed ahead of the built-in word, but
/// the code is shared (重码), which is what a user wants to know before
/// relying on it.
struct UserDictNote: Equatable {
    struct Flags: OptionSet {
        let rawValue: UInt32
        /// Dropped: same keys and value as the kept line `other`.
        static let repeatsLine = Flags(rawValue: UInt32(JD_USER_DICT_LINE_REPEATS_LINE))
        /// Dropped: same keys and value as a built-in word.
        static let repeatsBuiltIn = Flags(rawValue: UInt32(JD_USER_DICT_LINE_REPEATS_BUILTIN))
        /// Kept: a built-in word sits on exactly this code (`builtIn` says how many).
        static let codeInBuiltIn = Flags(rawValue: UInt32(JD_USER_DICT_LINE_CODE_IN_BUILTIN))
        /// Kept: kept line `other` sits on this code too (`peers` says how many do).
        static let codeInLine = Flags(rawValue: UInt32(JD_USER_DICT_LINE_CODE_IN_LINE))
        /// Skipped: neither blank nor a comment, and no TAB.
        static let malformed = Flags(rawValue: UInt32(JD_USER_DICT_LINE_MALFORMED))
        /// Skipped: keys empty, longer than `UserDict.maxKeyLength`, or not all `a`-`z`.
        static let badKeys = Flags(rawValue: UInt32(JD_USER_DICT_LINE_BAD_KEYS))
        /// Skipped: value empty, longer than `UserDict.maxValueBytes`, not UTF-8,
        /// or containing control characters.
        static let badValue = Flags(rawValue: UInt32(JD_USER_DICT_LINE_BAD_VALUE))
    }

    /// 1-based input line.
    let line: UInt32
    let flags: Flags
    /// A kept line this one relates to: for a repeat, the line it repeats (0
    /// for a built-in word); for a shared code, the first kept line on that
    /// code — and for that first line, the second. 0 otherwise.
    let other: UInt32
    /// Built-in words on exactly this code; 0 on a skipped line.
    let builtIn: UInt32
    /// Other kept lines on exactly this code; 0 on a dropped or skipped line.
    let peers: UInt32

    init(line: UInt32, flags: Flags, other: UInt32, builtIn: UInt32, peers: UInt32) {
        self.line = line
        self.flags = flags
        self.other = other
        self.builtIn = builtIn
        self.peers = peers
    }

    init(raw: jd_user_dict_note) {
        self.init(line: raw.line, flags: Flags(rawValue: raw.flags), other: raw.other, builtIn: raw.builtin, peers: raw.peers)
    }

    /// Whether the line was skipped because it does not parse.
    var isInvalid: Bool {
        !flags.isDisjoint(with: [.malformed, .badKeys, .badValue])
    }

    /// Whether the line parsed but was left out of the dictionary as a
    /// duplicate.
    var isDropped: Bool {
        !flags.isDisjoint(with: [.repeatsLine, .repeatsBuiltIn])
    }

    /// Whether the line is in the dictionary on a code something else uses.
    var isShared: Bool {
        !flags.isDisjoint(with: [.codeInBuiltIn, .codeInLine])
    }
}

/// What `UserDict.build` did with the input.
struct UserDictReport: Equatable {
    /// Phrases that made it into the dictionary.
    let entries: UInt32
    /// Phrases dropped as exact duplicates — of an earlier line with the same
    /// keys and value, or of a built-in word on the same code.
    let dropped: UInt32
    /// Kept phrases on a shared code: a built-in word, another kept phrase,
    /// or both already sit on it.
    let shared: UInt32
    /// Lines skipped because they do not parse: no TAB, bad keys, or a bad
    /// value.
    let invalid: UInt32
    /// One note per skipped, dropped or shared line — `invalid + dropped +
    /// shared` of them — ascending by line.
    let notes: [UserDictNote]

    /// The 1-based input lines of every dropped phrase, ascending.
    var droppedLines: [UInt32] {
        notes.filter(\.isDropped).map(\.line)
    }

    /// The 1-based input lines of every skipped line, ascending.
    var invalidLines: [UInt32] {
        notes.filter(\.isInvalid).map(\.line)
    }
}

/// What a cached blob says about itself, from `UserDict.check`.
struct UserDictInfo: Equatable {
    let sourceTag: UInt64
    let entries: UInt32
}

/// A user dictionary: phrases compiled into the blob the engine reads in
/// place. Build it from text with `build` and hand it to `Engine(userDict:)`,
/// keeping the text as the source of truth — a rebuild costs a couple of
/// milliseconds for thousands of phrases. `blob` is the bytes to cache if a
/// frontend wants to skip even that; `init(blob:)` takes them back and
/// `check` reads a cached blob's tag and count without constructing one.
///
/// A blob is tied to the build of libjd it was made with (the format, and the
/// built-in dictionary it was deduplicated against): after a library update
/// `init(blob:)` throws `.stale`, and the phrases are simply rebuilt.
final class UserDict {
    /// Most phrases one dictionary may hold (`JD_USER_DICT_MAX_ENTRIES`).
    static let maxEntries = Int(JD_USER_DICT_MAX_ENTRIES)
    /// Longest value in UTF-8 bytes (`JD_USER_DICT_VALUE_MAX`).
    static let maxValueBytes = Int(JD_USER_DICT_VALUE_MAX)
    /// Longest code in keys. `jd.h` states the cap in prose (keys are 1 to 6
    /// bytes) rather than as a macro; the library skips a longer code with a
    /// `badKeys` note.
    static let maxKeyLength = 6
    /// The characters a code is made of.
    static let keyAlphabet = Set("abcdefghijklmnopqrstuvwxyz")

    /// 16-byte aligned; the engine requires 4.
    private let storage: UnsafeMutableRawPointer
    /// The blob's length in bytes. The storage may be longer.
    let byteCount: Int
    /// Phrases in the blob.
    let entries: UInt32
    /// The tag `build` was given — a content hash, a modification time, a
    /// revision. The engine never interprets it.
    let sourceTag: UInt64

    private init(storage: UnsafeMutableRawPointer, byteCount: Int, entries: UInt32, sourceTag: UInt64) {
        self.storage = storage
        self.byteCount = byteCount
        self.entries = entries
        self.sourceTag = sourceTag
    }

    deinit {
        storage.deallocate()
    }

    /// The blob as the engine reads it. Valid for as long as `self` is.
    var bytes: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: storage, count: byteCount)
    }

    /// A copy of the blob, for caching.
    var blob: Data {
        Data(bytes: storage, count: byteCount)
    }

    /// Build from lines of `value<TAB>keys` — the format of libjd's own table
    /// files. `#` starts a comment line, blank lines are skipped, spaces
    /// around either field are trimmed, CRLF is accepted. A line that breaks
    /// the rules is skipped and counted, never fatal. Exact duplicates — of
    /// an earlier line, or of a built-in word on the same code — are dropped
    /// and counted; the report's notes say which lines were skipped and why,
    /// which were dropped, and which kept phrases sit on a code a built-in
    /// word or another phrase already uses. A `UserDictError` is thrown only
    /// for a problem with the call as a whole: too much text, too many
    /// phrases.
    ///
    /// `sourceTag` is stored in the blob, uninterpreted.
    static func build(_ text: String, sourceTag: UInt64 = 0) throws -> (dict: UserDict, report: UserDictReport) {
        Engine.checkABI()
        // NUL-terminated, so the buffer is never empty and its base address
        // never nil; the NUL itself is not passed to the library.
        let cString = text.utf8CString
        let length = cString.count - 1
        return try cString.withUnsafeBufferPointer { buffer -> (dict: UserDict, report: UserDictReport) in
            let phrases = buffer.baseAddress!
            let bound = jd_user_dict_blob_bound(phrases, length)
            let storage = UnsafeMutableRawPointer.allocate(byteCount: bound, alignment: 16)
            var blobLength = 0
            var report = jd_user_dict_report()
            let status = jd_user_dict_build(phrases, length, sourceTag, storage, bound, &blobLength, &report)
            guard status == UInt32(JD_USER_DICT_OK) else {
                storage.deallocate()
                throw UserDictError(status: .init(code: status), line: report.line)
            }
            // The notes sit past the blob in the same storage, which the
            // dictionary keeps; copy them into Swift values anyway, so the
            // report stands on its own.
            var notes: [UserDictNote] = []
            if report.notes > 0 {
                precondition(
                    report.notes_offset % 4 == 0
                        && Int(report.notes_offset) + Int(report.notes) * MemoryLayout<jd_user_dict_note>.stride <= bound,
                    "libjd placed the notes outside the buffer it was given"
                )
                let raw = storage.advanced(by: Int(report.notes_offset))
                    .assumingMemoryBound(to: jd_user_dict_note.self)
                notes = UnsafeBufferPointer(start: raw, count: Int(report.notes)).map(UserDictNote.init(raw:))
            }
            let dict = UserDict(
                storage: storage, byteCount: blobLength,
                entries: report.entries, sourceTag: sourceTag
            )
            let summary = UserDictReport(
                entries: report.entries, dropped: report.dropped, shared: report.shared,
                invalid: report.invalid, notes: notes
            )
            return (dict, summary)
        }
    }

    /// Wrap a blob cached from `blob`. The bytes are copied into aligned
    /// storage and validated exactly as `jd_init` would; `.stale` or
    /// `.corrupt` means "rebuild from the phrases".
    convenience init(blob: Data) throws {
        Engine.checkABI()
        let storage = UserDict.alignedCopy(blob)
        var info = jd_user_dict_info()
        let status = jd_user_dict_check(storage, blob.count, &info)
        guard status == UInt32(JD_USER_DICT_OK) else {
            storage.deallocate()
            throw UserDictError(status: .init(code: status), line: 0)
        }
        self.init(storage: storage, byteCount: blob.count, entries: info.entries, sourceTag: info.source_tag)
    }

    /// Validate a cached blob and read its tag and phrase count without
    /// constructing a dictionary.
    static func check(_ blob: Data) throws -> UserDictInfo {
        Engine.checkABI()
        let storage = alignedCopy(blob)
        defer { storage.deallocate() }
        var info = jd_user_dict_info()
        let status = jd_user_dict_check(storage, blob.count, &info)
        guard status == UInt32(JD_USER_DICT_OK) else {
            throw UserDictError(status: .init(code: status), line: 0)
        }
        return UserDictInfo(sourceTag: info.source_tag, entries: info.entries)
    }

    /// `Data` promises no alignment, so cached bytes are copied into storage
    /// the engine can read.
    private static func alignedCopy(_ data: Data) -> UnsafeMutableRawPointer {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
        data.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: data.count)
        return storage
    }
}
