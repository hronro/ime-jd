// Where the iOS user dictionary lives and how the keyboard loads it. Shared
// by the container app (which writes it), the keyboard extension (which
// only reads it) and the hostless tests. No UIKit.
//
// The two processes meet in the App Group container. The phrases file
// (`UserDictFile`) is the single source of truth, written by the app; beside
// it the app leaves the blob it compiled from that text, and the user's
// on/off switch sits in the group's shared UserDefaults. Verified on a device
// (iPhone 16 Pro Max, iOS 18.2) with Full Access off: the keyboard can read
// the group's files and defaults but cannot write there (permission
// denied). So the keyboard never writes — and a cache it cannot refresh is
// why the text travels with the blob: after an App Store update the blob is
// stale (built against another libjd), and the keyboard rebuilds from the
// text in memory, a few milliseconds, until the app next runs and rewrites
// the blob. Older iOS versions are unverified: an unreadable container means
// "no user dictionary", never an error.

import Foundation
import os

struct UserDictContainer {
    private static let log = Logger(subsystem: "com.hronro.ime-jd", category: "user-dict")

    static let groupID = "group.com.hronro.ime-jd"
    /// The switch, in the group's defaults: off until the user turns it on.
    static let enabledKey = "JdUserDictEnabled"
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
        return Stamp(enabled: isEnabled, text: file(textURL), blob: file(blobURL))
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

    /// The keyboard's load. Nil while the switch is off, when there is no
    /// file, or when nothing can be read — the keyboard then runs on the
    /// built-in dictionary alone. Reads only; a stale blob stays stale until
    /// the app rewrites it.
    func load() -> Loaded? {
        guard isEnabled, let textURL else { return nil }
        guard let text = (try? UserDictFile.read(at: textURL)) ?? nil else {
            Self.log.notice("user dict: no readable phrases file; running without")
            return nil
        }
        let tag = UserDictFile.hash(text)
        if let blobURL,
           let data = try? Data(contentsOf: blobURL),
           let dict = try? UserDict(blob: data),
           dict.sourceTag == tag {
            Self.log.notice("user dict: \(dict.entries, privacy: .public) phrases from the blob")
            return Loaded(dict: dict, source: .blob)
        }
        guard let built = try? UserDict.build(text, sourceTag: tag) else {
            Self.log.notice("user dict: the phrases file cannot be built; running without")
            return nil
        }
        Self.log.notice("user dict: \(built.dict.entries, privacy: .public) phrases rebuilt from the text (blob missing, stale or mismatched)")
        return Loaded(dict: built.dict, source: .rebuilt)
    }
}
