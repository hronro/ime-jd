// Where the iOS user dictionary lives and how the keyboard loads it. Shared
// by the container app (which writes it), the keyboard extension (which
// only reads it) and the hostless tests. No UIKit.
//
// The two processes meet in the App Group container. The phrases file
// (`UserDictFile`) is the single source of truth, written by the app; beside
// it the app leaves the blob it compiled from that text, and the user's
// switches sit in the group's shared UserDefaults: the user dictionary on or
// off, and — while it is on — whether it is all the keyboard types from, the
// built-in dictionary turned off. Verified on a device
// (iPhone 16 Pro Max, iOS 18.2) with Full Access off: the keyboard can read
// the group's files and defaults but cannot write there (permission
// denied). So the keyboard never writes — and a cache it cannot refresh is
// why the text travels with the blob: after an App Store update the blob is
// stale (built against another libjd), and the keyboard rebuilds from the
// text in memory until the app next runs and rewrites the blob. Older iOS
// versions are unverified: an unreadable container means "no user
// dictionary", never an error.
//
// Memory is what bounds a keyboard extension, so the keyboard maps both
// files rather than reading them (`MappedFile`): the blob is used where it
// lies, the text is hashed — and, when the blob will not do, built from —
// where it lies, and file-backed pages count against no limit. A load from
// the blob allocates nothing in proportion to the dictionary; a rebuild
// holds the build's buffer for a moment and keeps the blob. The app replaces
// both files atomically, which is what makes mapping them safe.

import Foundation
import os

struct UserDictContainer {
    private static let log = Logger(subsystem: "com.hronro.ime-jd", category: "user-dict")

    static let groupID = "group.com.hronro.ime-jd"
    /// The switch, in the group's defaults: off until the user turns it on.
    static let enabledKey = "JdUserDictEnabled"
    /// The second switch: type from the user dictionary alone, without the
    /// built-in dictionary. Off until the user turns it on, and only heeded
    /// while `enabledKey` is on — so there is always a dictionary.
    static let userOnlyKey = "JdUserDictOnly"
    /// The blob the app compiled from the phrases file, tagged with the
    /// file's hash so a blob that does not match the text is never used.
    static let blobFileName = "用户自造词.blob"

    /// The process's view of the real group container.
    static let shared = UserDictContainer(
        directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID),
        defaults: UserDefaults(suiteName: groupID)
    )

    /// The group container, or nil when it cannot be resolved (no
    /// entitlement, or a sandbox that hides it).
    let directory: URL?
    /// The group's shared defaults, or nil when the suite cannot be opened.
    let defaults: UserDefaults?

    var textURL: URL? {
        directory?.appendingPathComponent(UserDictFile.fileName, isDirectory: false)
    }

    var blobURL: URL? {
        directory?.appendingPathComponent(Self.blobFileName, isDirectory: false)
    }

    var isEnabled: Bool {
        defaults?.bool(forKey: Self.enabledKey) ?? false
    }

    /// The second switch as set, whether or not the first is on.
    var isUserOnly: Bool {
        defaults?.bool(forKey: Self.userOnlyKey) ?? false
    }

    /// The dictionary the phrases are built on: the empty one when they are
    /// to be typed alone, the built-in one (nil) otherwise. A blob built on
    /// one is stale on the other, so the app rewrites its blob when the
    /// second switch flips.
    var base: Dict? {
        isUserOnly ? .empty : nil
    }

    // MARK: - Change detection

    struct FileStamp: Equatable {
        var size: Int
        var modified: Date
    }

    /// What `load` would read, cheaply: the switch and each file's size and
    /// modification date. Two stats, no reads — taken at every presentation
    /// of the keyboard, so an edit in the app in between is adopted.
    struct Stamp: Equatable {
        var enabled: Bool
        var userOnly: Bool
        var text: FileStamp?
        var blob: FileStamp?
    }

    func stamp() -> Stamp {
        func file(_ url: URL?) -> FileStamp? {
            guard let url,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            return FileStamp(size: size, modified: modified)
        }
        return Stamp(enabled: isEnabled, userOnly: isUserOnly, text: file(textURL), blob: file(blobURL))
    }

    // MARK: - Loading

    enum Source: Equatable {
        /// The app's blob, as it was.
        case blob
        /// Built from the text here: the blob was missing, corrupt, stale
        /// after a library update, or tagged for another text.
        case rebuilt
    }

    struct Loaded {
        let dict: UserDict
        let source: Source
    }

    /// Why the phrases could not be loaded — what the keyboard shows when
    /// it was to type from them alone.
    enum LoadFailure: Error, Equatable {
        case noContainer
        case noFile
        case unreadable
        case build(UserDictError)

        /// For the keyboard's candidate bar: short.
        var message: String {
            switch self {
            case .noContainer: return "无法访问共享容器"
            case .noFile: return "没有词条文件"
            case .unreadable: return "无法读取词条文件"
            case .build(let error):
                switch error.status {
                case .tooManyEntries: return "超过 \(UserDict.maxEntries) 条上限"
                case .textTooLong: return "文件超过 \(UserDict.maxTextBytes / (1024 * 1024)) MB 上限"
                default: return "无法编译词库"
                }
            }
        }
    }

    /// What a session types from (see `UserDictSelection`).
    typealias Selection = UserDictSelection

    /// What the keyboard types from, by the switches: the built-in
    /// dictionary, with the phrases if they load — a file that does not
    /// costs only the phrases — or, the built-in dictionary turned off, the
    /// phrases alone, or why they cannot be had.
    func selection() -> Selection {
        guard let result = loadResult() else { return .builtIn(nil) }
        switch result {
        case .success(let loaded):
            return isUserOnly ? .userOnly(loaded.dict) : .builtIn(loaded.dict)
        case .failure(let failure):
            return isUserOnly ? .unavailable("用户自造词未能加载：\(failure.message)") : .builtIn(nil)
        }
    }

    /// The keyboard's load. Nil while the switch is off, when there is no
    /// file, or when nothing can be read. Reads only; a stale blob stays
    /// stale until the app rewrites it.
    func load() -> Loaded? {
        try? loadResult()?.get()
    }

    /// `load`, with the reason when it fails; nil while the switch is off.
    func loadResult() -> Result<Loaded, LoadFailure>? {
        guard isEnabled else { return nil }
        guard let textURL else { return .failure(.noContainer) }
        let file: MappedFile
        do {
            guard let opened = try MappedFile.open(textURL) else {
                Self.log.notice("user dict: no phrases file")
                return .failure(.noFile)
            }
            file = opened
        } catch {
            Self.log.notice("user dict: the phrases file cannot be read")
            return .failure(.unreadable)
        }
        let base = self.base
        // The text's bytes are the mapping's: keep it until the last use.
        return withExtendedLifetime(file) {
            let text = UserDictFile.withoutBOM(file.bytes)
            let tag = UserDict.hash(text)
            if let blobURL,
               let blob = (try? MappedFile.open(blobURL)) ?? nil,
               let dict = try? UserDict(mapping: blob, on: base),
               dict.sourceTag == tag {
                Self.log.notice("user dict: \(dict.entries, privacy: .public) phrases from the blob")
                return .success(Loaded(dict: dict, source: .blob))
            }
            do {
                let built = try UserDict.build(utf8: text, on: base, sourceTag: tag)
                Self.log.notice("user dict: \(built.dict.entries, privacy: .public) phrases rebuilt from the text (blob missing, stale or mismatched)")
                return .success(Loaded(dict: built.dict, source: .rebuilt))
            } catch let error as UserDictError {
                Self.log.notice("user dict: the phrases file cannot be built")
                return .failure(.build(error))
            } catch {
                return .failure(.unreadable)
            }
        }
    }
}
