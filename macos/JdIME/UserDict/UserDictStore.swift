import Foundation
import UserNotifications

/// The macOS client's user dictionary: the phrases file compiled into the
/// blob every controller's engine reads, rebuilt whenever the file changes —
/// from the GUI, from a text editor, from anything — and handed to engines
/// only while the user has switched it on (off by default).
///
/// There is no blob cache. The IME process launches once per login session
/// and a build is a couple of milliseconds, so the file is read and compiled
/// at launch and after every change. A line that does not parse is skipped
/// by the engine and flagged in the window, so a typo in a text editor costs
/// that line and nothing else. When the file cannot be loaded at all — not
/// UTF-8, unreadable, over the engine's caps — the last good dictionary
/// stays in use; the failure is kept in `lastError`, shown in the Input
/// menu, and posted as a notification.
///
/// A context's dictionary is fixed for its lifetime, so the store never
/// touches an engine. It bumps `generation`, and each controller re-creates
/// its engine with `activeDictionary` at the next moment nothing is composing
/// (`InputController.syncEngine`). Everything runs on the main thread.
final class UserDictStore {
    static let shared: UserDictStore = {
        let store = UserDictStore(fileURL: UserDictFile.defaultURL(), defaults: .standard)
        store.startWatching()
        return store
    }()

    /// Posted on the main thread after anything a controller or a window
    /// should react to: a rebuild, a failed rebuild, the file vanishing, or
    /// the toggle.
    static let didChange = Notification.Name("JdUserDictStoreDidChange")

    enum LoadError: Error, CustomStringConvertible {
        case notUTF8
        case unreadable(Error)
        case build(UserDictError)

        /// For the log.
        var description: String {
            switch self {
            case .notUTF8: return "not UTF-8"
            case .unreadable(let error): return "unreadable: \(error)"
            case .build(let error): return "build failed: \(error)"
            }
        }

        /// For the user.
        var message: String {
            switch self {
            case .notUTF8:
                return "文件不是 UTF-8 编码"
            case .unreadable(let error):
                return "无法读取文件：\(error.localizedDescription)"
            case .build(let error):
                switch error.status {
                case .tooManyEntries:
                    return "第 \(error.line) 行起超过 \(UserDict.maxEntries) 条上限"
                case .textTooLong:
                    return "文件超过 8 MB 上限"
                default:
                    return "无法编译词库（\(error)）"
                }
            }
        }
    }

    private enum Key {
        static let enabled = "JdUserDictEnabled"
    }

    let fileURL: URL
    private let defaults: UserDefaults

    /// Bumped whenever `activeDictionary` may differ from what an existing
    /// engine was created with.
    private(set) var generation: UInt64 = 0
    /// The last successfully built dictionary — kept while disabled, and
    /// kept across a failed rebuild.
    private(set) var dictionary: UserDict?
    /// The report of the build that produced `dictionary`.
    private(set) var report: UserDictReport?
    /// Why the most recent reload failed, or nil when `dictionary` matches
    /// the file.
    private(set) var lastError: LoadError?

    /// `UserDictFile.hash` of the text `dictionary` was built from; nil when
    /// there was no file. An unchanged file — or the store's own write —
    /// costs one hash and nothing more.
    private var builtHash: UInt64?
    /// The hash of a file that failed to build, so the same bad content is
    /// reported once; nil when the last reload succeeded.
    private var failedHash: UInt64?

    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        self.defaults = defaults
        reload()
    }

    deinit {
        directoryWatcher?.cancel()
        fileWatcher?.cancel()
        pendingReload?.cancel()
    }

    // MARK: - Settings

    /// The user's switch, off until they turn it on. Off means every new
    /// engine reads the built-in dictionary alone, whatever the file holds;
    /// the file is still loaded and watched, so the window stays live.
    var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? false }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: Key.enabled)
            generation += 1
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// What an engine created right now should read.
    var activeDictionary: UserDict? {
        isEnabled ? dictionary : nil
    }

    /// One line for the Input menu.
    var statusText: String {
        if let error = lastError {
            return "用户自造词：\(error.message)"
        }
        guard let dictionary else {
            return "用户自造词：尚无词条"
        }
        var text = "用户自造词：\(dictionary.entries) 条"
        if let report, report.invalid > 0 {
            text += "，\(report.invalid) 条无效已跳过"
        }
        if let report, report.dropped > 0 {
            text += "，\(report.dropped) 条重复已忽略"
        }
        return text
    }

    // MARK: - Loading

    /// Re-read the file and rebuild when its content changed. Returns whether
    /// `activeDictionary` may now differ from before.
    @discardableResult
    func reload() -> Bool {
        let text: String?
        do {
            text = try UserDictFile.read(at: fileURL)
        } catch let error as UserDictFileError where error == .notUTF8 {
            return fail(.notUTF8, hash: nil)
        } catch {
            return fail(.unreadable(error), hash: nil)
        }

        // nil: no file.
        let hash = text.map(UserDictFile.hash)
        if hash == builtHash, lastError == nil {
            return false
        }
        if let failedHash, hash == failedHash {
            return false
        }

        guard let text, let hash else {
            // The file is gone: so is the dictionary.
            dictionary = nil
            report = nil
            lastError = nil
            builtHash = nil
            failedHash = nil
            return changed()
        }

        do {
            let (dict, report) = try UserDict.build(text, sourceTag: hash)
            dictionary = dict
            self.report = report
            lastError = nil
            builtHash = hash
            failedHash = nil
            NSLog(
                "JdIME: user dict: %u phrases, %u bad lines skipped, %u duplicates dropped",
                dict.entries, report.invalid, report.dropped
            )
            return changed()
        } catch let error as UserDictError {
            return fail(.build(error), hash: hash)
        } catch {
            return fail(.unreadable(error), hash: hash)
        }
    }

    /// Write `entries` as the whole file and adopt them. The directory
    /// watcher fires afterwards and finds the hash already current.
    func save(_ entries: [UserDictEntry]) throws {
        try UserDictFile.write(UserDictFile.serialize(entries), to: fileURL)
        reload()
    }

    private func changed() -> Bool {
        generation += 1
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return true
    }

    private func fail(_ error: LoadError, hash: UInt64?) -> Bool {
        lastError = error
        failedHash = hash
        NSLog("JdIME: user dict: %@", error.description)
        notifyFailure(error)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return false
    }

    // MARK: - Watching

    /// Watch the directory (an editor's atomic save is a rename into it; the
    /// GUI's write is one too) and the file itself (an in-place write).
    /// Events are debounced, since a save is several of them.
    func startWatching() {
        // Make sure there is a directory to watch, and a place to write.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        directoryWatcher = watch(fileURL.deletingLastPathComponent(), for: [.write])
        rearmFileWatcher()
    }

    /// Re-opened after every reload: an atomic save replaces the inode, and
    /// the file may not have existed when the store started.
    private func rearmFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = watch(fileURL, for: [.write, .extend, .delete, .rename])
    }

    private func watch(_ url: URL, for events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: events, queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.reload()
            self.rearmFileWatcher()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Reporting

    /// A failed rebuild after a text-editor save would otherwise go unseen
    /// until the user wonders why a phrase does not come up.
    private func notifyFailure(_ error: LoadError) {
        // Not under XCTest: the test host has no Launch Services record, and
        // UNUserNotificationCenter aborts the process without one.
        guard !UpdateManager.isUnderXCTest else { return }
        let fallback = dictionary == nil ? "当前没有加载用户自造词。" : "已沿用上一次成功加载的词库。"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "用户自造词未能加载"
            content.body = "\(error.message)。\(fallback)"
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "user-dict-error", content: content, trigger: nil))
        }
    }
}
