// A user dictionary over libjd's C ABI: the user's own phrases, compiled once
// into the blob the engine reads in place. Shared source, compiled into both
// the macOS and iOS frontends — see bindings/swift/README.md.
//
// The engine never copies the blob (see jd_init in core/include/jd.h): it must
// be 4-byte aligned and must outlive every context created with it and every
// candidate `value` that points into it. A `UserDict` owns aligned storage,
// or a read-only mapping of a cached file, and lets it go in `deinit`; an
// `Engine` created with one retains it for as long as the context lives. What remains for a frontend is documented on `Candidate`:
// a candidate read from such an engine must not outlive the engine.
//
// Where the phrases live — a text file, a table behind a GUI — is each
// frontend's business; the text handed to `build` is only the interchange
// format for that one call.

import Foundation
import Libjd

/// Why a dictionary or user dictionary could not be built or accepted.
/// Mirrors the `JD_USER_DICT_*` status codes in `core/include/jd.h`. These
/// are failures of a call as a whole; a line that does not parse is not one —
/// the build skips it and says so in a `UserDictNote`.
struct UserDictError: Error, Equatable, CustomStringConvertible {
    enum Status: Equatable {
        /// `build`: the output buffer was smaller than the bound (a bug in this wrapper).
        case bufferTooSmall
        /// `build`: more entries than the cap — `UserDict.maxEntries`, or
        /// `Dict.maxEntries`; `line` is the first excess one.
        case tooManyEntries
        /// A cached blob built by a different libjd, or a user dictionary
        /// built on another dictionary. Rebuild it from the phrases.
        case stale
        /// A cached blob that is structurally invalid. Rebuild it from the phrases.
        case corrupt
        /// The blob pointer was not 4-byte aligned (a bug in this wrapper).
        case misaligned
        /// `build`: the text exceeds the cap.
        case textTooLong
        /// No dictionary was given, and this libjd has none of its own
        /// (libjd-engine).
        case noBuiltinDict
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
            case UInt32(JD_USER_DICT_NO_BUILTIN): self = .noBuiltinDict
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
        case .tooManyEntries: what = "too many entries"
        case .stale: what = "blob was built against a different dictionary (rebuild it)"
        case .corrupt: what = "blob is corrupt (rebuild it)"
        case .misaligned: what = "blob is not 4-byte aligned"
        case .textTooLong: what = "text is too long"
        case .noBuiltinDict: what = "this libjd has no built-in dictionary"
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
        /// Skipped: keys empty, longer than `UserDict.maxKeyLength`, not all
        /// `a`-`z` and `;`, or a `;` after a letter.
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

/// A blob's bytes, wherever they live: memory of its own, 16-byte aligned
/// (the engine requires 4), or a cached file's pages. Let go in `deinit`.
final class BlobStorage {
    private enum Backing {
        case allocated(UnsafeMutableRawPointer)
        case mapped(MappedFile)
    }

    private let backing: Backing
    /// The blob as the engine reads it. Valid for as long as `self` is.
    let bytes: UnsafeRawBufferPointer

    private init(backing: Backing, bytes: UnsafeRawBufferPointer) {
        self.backing = backing
        self.bytes = bytes
    }

    deinit {
        if case .allocated(let storage) = backing {
            storage.deallocate()
        }
    }

    /// `count` bytes of `storage`, which this takes over.
    static func adopting(_ storage: UnsafeMutableRawPointer, count: Int) -> BlobStorage {
        BlobStorage(backing: .allocated(storage), bytes: UnsafeRawBufferPointer(start: storage, count: count))
    }

    /// A mapped file's bytes, in place.
    static func mapping(_ file: MappedFile) -> BlobStorage {
        BlobStorage(backing: .mapped(file), bytes: file.bytes)
    }

    /// `Data` promises no alignment, so cached bytes are copied into storage
    /// the engine can read.
    static func copying(_ data: Data) -> BlobStorage {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
        data.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: data.count)
        return adopting(storage, count: data.count)
    }

    /// Run a `jd_*_build` call — `call(buffer, capacity, &length, &report)`
    /// — into storage of `bound` bytes, keeping only the blob, and return it
    /// with the report; throws for a failed call.
    static func build(
        bound: Int,
        _ call: (UnsafeMutableRawPointer, Int, inout Int, inout jd_user_dict_report) -> UInt32
    ) throws -> (BlobStorage, UserDictReport) {
        var storage = UnsafeMutableRawPointer.allocate(byteCount: max(bound, 1), alignment: 16)
        var blobLength = 0
        var report = jd_user_dict_report()
        let status = call(storage, bound, &blobLength, &report)
        guard status == UInt32(JD_USER_DICT_OK) else {
            storage.deallocate()
            throw UserDictError(status: .init(code: status), line: report.line)
        }
        // The notes sit past the blob in the same storage; copy them into
        // Swift values so the report stands on its own.
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
        // The bound leaves room for the build's working space and every
        // line's note, a few times the blob: keep only the blob.
        if bound - blobLength > 64 * 1024 {
            let exact = UnsafeMutableRawPointer.allocate(byteCount: max(blobLength, 1), alignment: 16)
            exact.copyMemory(from: storage, byteCount: blobLength)
            storage.deallocate()
            storage = exact
        }
        let summary = UserDictReport(
            entries: report.entries, dropped: report.dropped, shared: report.shared,
            invalid: report.invalid, notes: notes
        )
        return (adopting(storage, count: blobLength), summary)
    }

    /// The verdict of a `jd_*_check` call — `call(&info)` — or the error it
    /// means.
    static func check(_ call: (inout jd_user_dict_info) -> UInt32) throws -> UserDictInfo {
        var info = jd_user_dict_info()
        let status = call(&info)
        guard status == UInt32(JD_USER_DICT_OK) else {
            throw UserDictError(status: .init(code: status), line: 0)
        }
        return UserDictInfo(sourceTag: info.source_tag, entries: info.entries)
    }
}

/// A dictionary to type from in place of libjd's embedded one: every code
/// and the words on it, built from `value<TAB>keys` text by the same code
/// that builds the embedded dictionary, so it types the same way and as
/// fast. Pass it to `Engine(dict:userDict:)`; a user dictionary for it is
/// built and checked with `on: dict`.
///
/// The frontends use one only to turn the embedded dictionary off: `empty`
/// has no codes at all, and an engine on it types from its user dictionary
/// alone.
final class Dict {
    /// Most entries one dictionary may hold (`JD_DICT_MAX_ENTRIES`).
    static let maxEntries = Int(JD_DICT_MAX_ENTRIES)
    /// Longest value in UTF-8 bytes (`JD_DICT_VALUE_MAX`).
    static let maxValueBytes = Int(JD_DICT_VALUE_MAX)

    private let storage: BlobStorage
    /// Entries in the blob.
    let entries: UInt32
    /// The tag `build` was given.
    let sourceTag: UInt64

    private init(storage: BlobStorage, entries: UInt32, sourceTag: UInt64) {
        self.storage = storage
        self.entries = entries
        self.sourceTag = sourceTag
    }

    /// The blob as the engine reads it. Valid for as long as `self` is.
    var bytes: UnsafeRawBufferPointer {
        storage.bytes
    }

    /// A copy of the blob, for caching.
    var blob: Data {
        Data(bytes)
    }

    /// How many entries libjd's embedded dictionary holds: 0 in libjd-engine.
    static var builtinEntries: Int {
        Int(jd_abi_layout(UInt32(JD_ABI_BUILTIN_DICT_ENTRIES)))
    }

    /// The empty dictionary: no codes at all. Every empty dictionary is the
    /// same dictionary, so one built on any of them suits a user dictionary
    /// built on another; built once per process.
    static let empty: Dict = {
        do {
            return try build("").dict
        } catch {
            fatalError("libjd failed to build an empty dictionary: \(error)")
        }
    }()

    /// Build from lines of `value<TAB>keys`, by the rules of
    /// `UserDict.build`: lines that do not parse are skipped and exact
    /// repeats dropped, each with a note (`shared` is always 0). The words
    /// on one code are its candidates in the order of their lines.
    static func build(_ text: String, sourceTag: UInt64 = 0) throws -> (dict: Dict, report: UserDictReport) {
        var text = text
        return try text.withUTF8 { try build(utf8: UnsafeRawBufferPointer($0), sourceTag: sourceTag) }
    }

    /// `build` from UTF-8 bytes as they are.
    static func build(utf8 text: UnsafeRawBufferPointer, sourceTag: UInt64 = 0) throws -> (dict: Dict, report: UserDictReport) {
        Engine.checkABI()
        let chars = text.baseAddress?.assumingMemoryBound(to: CChar.self)
        let (storage, report) = try BlobStorage.build(bound: jd_dict_blob_bound(chars, text.count)) { buf, cap, length, report in
            jd_dict_build(chars, text.count, sourceTag, buf, cap, &length, &report)
        }
        return (Dict(storage: storage, entries: report.entries, sourceTag: sourceTag), report)
    }

    /// A blob cached in a file, mapped and used in place; validated exactly
    /// as `jd_init` would.
    convenience init(mapping file: MappedFile) throws {
        Engine.checkABI()
        let info = try BlobStorage.check { jd_dict_check(file.bytes.baseAddress, file.bytes.count, &$0) }
        self.init(storage: .mapping(file), entries: info.entries, sourceTag: info.sourceTag)
    }

    /// Wrap a blob cached from `blob`, copied into aligned storage and
    /// validated exactly as `jd_init` would.
    convenience init(blob: Data) throws {
        Engine.checkABI()
        let storage = BlobStorage.copying(blob)
        let info = try BlobStorage.check { jd_dict_check(storage.bytes.baseAddress, storage.bytes.count, &$0) }
        self.init(storage: storage, entries: info.entries, sourceTag: info.sourceTag)
    }
}

/// A user dictionary: phrases compiled into the blob the engine reads in
/// place. Build it from text with `build` and hand it to `Engine(userDict:)`,
/// keeping the text as the source of truth — a rebuild costs about 6 ms per
/// 100 000 phrases on a recent Mac. `blob` is the bytes to cache if a
/// frontend wants to skip even that; `init(mapping:)` reads a cached file in
/// place, `init(blob:)` takes the bytes back as a copy, and `check` reads a
/// cached blob's tag and count without constructing one.
///
/// The phrases sit on a dictionary: libjd's embedded one by default, or the
/// `Dict` passed as `on:` — `Dict.empty` to type from the phrases alone. A
/// blob is tied to that dictionary and to the build of libjd it was made
/// with: after a library update, or on another dictionary, `init(blob:)`
/// throws `.stale`, and the phrases are simply rebuilt.
final class UserDict {
    /// Most phrases one dictionary may hold (`JD_USER_DICT_MAX_ENTRIES`).
    static let maxEntries = Int(JD_USER_DICT_MAX_ENTRIES)
    /// Longest value in UTF-8 bytes (`JD_USER_DICT_VALUE_MAX`).
    static let maxValueBytes = Int(JD_USER_DICT_VALUE_MAX)
    /// Most text one build may read, in bytes (`JD_USER_DICT_TEXT_MAX`, an
    /// expression Swift does not import; checked against the library's).
    static let maxTextBytes = 16 * 1024 * 1024
    /// Longest code in keys. `jd.h` states the cap in prose (keys are 1 to 6
    /// bytes) rather than as a macro; the library skips a longer code with a
    /// `badKeys` note.
    static let maxKeyLength = 6
    /// The characters a code is made of: the letters, and `;` before the
    /// first of them.
    static let keyAlphabet = Set("abcdefghijklmnopqrstuvwxyz;")

    private let storage: BlobStorage
    /// Phrases in the blob.
    let entries: UInt32
    /// The tag `build` was given — a content hash, a modification time, a
    /// revision. The engine never interprets it.
    let sourceTag: UInt64

    private init(storage: BlobStorage, entries: UInt32, sourceTag: UInt64) {
        self.storage = storage
        self.entries = entries
        self.sourceTag = sourceTag
    }

    /// The blob as the engine reads it. Valid for as long as `self` is.
    var bytes: UnsafeRawBufferPointer {
        storage.bytes
    }

    /// The blob's length in bytes.
    var byteCount: Int {
        storage.bytes.count
    }

    /// A copy of the blob, for caching.
    var blob: Data {
        Data(bytes)
    }

    /// libjd's content hash (`jd_user_dict_hash`), for `sourceTag`: hash the
    /// text a dictionary is built from, hash it again before trusting a
    /// cached blob, and a blob whose tag differs was built from something
    /// else. Gigabytes a second, so a whole phrases file costs well under a
    /// millisecond. The same bytes hash the same on every platform and in
    /// every release.
    static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        jd_user_dict_hash(bytes.baseAddress, bytes.count)
    }

    /// `hash` over the text's UTF-8.
    static func hash(_ text: String) -> UInt64 {
        var text = text
        return text.withUTF8 { hash(UnsafeRawBufferPointer($0)) }
    }

    /// Build from lines of `value<TAB>keys` — the format of libjd's own table
    /// files. `#` starts a comment line, blank lines are skipped, spaces
    /// around either field are trimmed, CRLF is accepted. Keys are 1 to 6 of
    /// `a`-`z` and `;`, with no `;` after a letter. A line that breaks the
    /// rules is skipped and counted, never fatal. Exact duplicates — of an
    /// earlier line, or of a word on the same code in the dictionary
    /// beneath — are dropped and counted; the report's notes say which lines
    /// were skipped and why, which were dropped, and which kept phrases sit
    /// on a code a dictionary word or another phrase already uses. A
    /// `UserDictError` is thrown only for a problem with the call as a
    /// whole: too much text, too many phrases.
    ///
    /// The phrases sit on `dict`, or the embedded dictionary for nil.
    /// `sourceTag` is stored in the blob, uninterpreted.
    static func build(_ text: String, on dict: Dict? = nil, sourceTag: UInt64 = 0) throws -> (dict: UserDict, report: UserDictReport) {
        // A native String is contiguous UTF-8 already: read in place.
        var text = text
        return try text.withUTF8 { try build(utf8: UnsafeRawBufferPointer($0), on: dict, sourceTag: sourceTag) }
    }

    /// `build` from UTF-8 bytes as they are — a mapped file, say, so the
    /// text is never copied. A byte-order mark is not skipped (libjd would
    /// take U+FEFF as part of line 1): drop one first.
    static func build(utf8 phrases: UnsafeRawBufferPointer, on dict: Dict? = nil, sourceTag: UInt64 = 0) throws -> (dict: UserDict, report: UserDictReport) {
        Engine.checkABI()
        let text = phrases.baseAddress?.assumingMemoryBound(to: CChar.self)
        let base = dict?.bytes
        let (storage, report) = try BlobStorage.build(bound: jd_user_dict_blob_bound(text, phrases.count)) { buf, cap, length, report in
            jd_user_dict_build(
                base?.baseAddress, base?.count ?? 0, text, phrases.count, sourceTag,
                buf, cap, &length, &report
            )
        }
        return (UserDict(storage: storage, entries: report.entries, sourceTag: sourceTag), report)
    }

    /// A blob cached in a file, mapped rather than read (`MappedFile`) and
    /// used where it lies: no copy, and pages a file backs count against no
    /// memory limit — what an iOS keyboard extension needs at hundreds of
    /// thousands of phrases. Validated exactly as `jd_init` would, on `dict`
    /// (nil for the embedded dictionary); `.stale` or `.corrupt` means
    /// "rebuild from the phrases". The mapping lives as long as the
    /// dictionary.
    convenience init(mapping file: MappedFile, on dict: Dict? = nil) throws {
        Engine.checkABI()
        let base = dict?.bytes
        let info = try BlobStorage.check {
            jd_user_dict_check(base?.baseAddress, base?.count ?? 0, file.bytes.baseAddress, file.bytes.count, &$0)
        }
        self.init(storage: .mapping(file), entries: info.entries, sourceTag: info.sourceTag)
    }

    /// Wrap a blob cached from `blob`. The bytes are copied into aligned
    /// storage and validated exactly as `jd_init` would, on `dict` (nil for
    /// the embedded dictionary); `.stale` or `.corrupt` means "rebuild from
    /// the phrases".
    convenience init(blob: Data, on dict: Dict? = nil) throws {
        Engine.checkABI()
        let storage = BlobStorage.copying(blob)
        let info = try UserDict.check(storage.bytes, on: dict)
        self.init(storage: storage, entries: info.entries, sourceTag: info.sourceTag)
    }

    /// Validate a cached blob and read its tag and phrase count without
    /// constructing a dictionary.
    static func check(_ blob: Data, on dict: Dict? = nil) throws -> UserDictInfo {
        Engine.checkABI()
        let storage = BlobStorage.copying(blob)
        return try withExtendedLifetime(storage) { try check(storage.bytes, on: dict) }
    }

    private static func check(_ bytes: UnsafeRawBufferPointer, on dict: Dict?) throws -> UserDictInfo {
        let base = dict?.bytes
        return try BlobStorage.check {
            jd_user_dict_check(base?.baseAddress, base?.count ?? 0, bytes.baseAddress, bytes.count, &$0)
        }
    }
}
