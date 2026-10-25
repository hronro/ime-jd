import Foundation

/// The container app's side of the user dictionary. The phrases file in the
/// App Group container is the single source of truth; the app rewrites it
/// on every change and, beside it, the blob it compiled from that text, so
/// the keyboard — which only reads (`UserDictContainer`) — loads a
/// dictionary without parsing anything. The user's switch is in the group's
/// shared defaults. No UIKit, so the hostless tests cover it; everything
/// runs on the main thread.
final class UserDictStore {
    static let shared = UserDictStore(container: .shared)

    /// Posted on the main thread after a save, a reload or the switch.
    static let didChange = Notification.Name("JdUserDictStoreDidChange")

    enum LoadError: LocalizedError, Equatable {
        /// The App Group container could not be resolved: an entitlement or
        /// provisioning problem, not something the user can fix.
        case noContainer
        case notUTF8
        case unreadable(String)
        /// A file picked for import has no phrase line at all: whatever it
        /// is, it is not a phrase list.
        case noPhrases
        /// The engine refused the whole file: too many phrases, too much
        /// text. A line that does not parse is never this — it is skipped
        /// and flagged on its row.
        case build(UserDictError)

        /// For the user.
        var message: String {
            switch self {
            case .noContainer:
                return "无法访问共享容器"
            case .notUTF8:
                return "文件不是 UTF-8 编码"
            case .unreadable(let why):
                return "无法读取文件：\(why)"
            case .noPhrases:
                return "文件中没有词条"
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

        /// What `localizedDescription` shows — an alert built from a caught
        /// error gets the same words.
        var errorDescription: String? { message }
    }

    let container: UserDictContainer

    /// The file's rows, in file order.
    private(set) var rows: [UserDictRow] = []
    /// The engine's verdict on each row, from the build of the text the
    /// rows came from; nil where the row is fine.
    private(set) var problems: [UserDictProblem?] = []
    /// The dictionary compiled from the file — what the keyboard's blob
    /// holds — for the in-app preview; nil when there is no file or the
    /// file could not be built.
    private(set) var dictionary: UserDict?
    private(set) var report: UserDictReport?
    private(set) var lastError: LoadError?

    init(container: UserDictContainer) {
        self.container = container
        reload()
    }

    var entries: [UserDictEntry] {
        rows.map(\.entry)
    }

    /// The user's switch. Off means every engine reads the built-in
    /// dictionary alone, whatever the file holds; the file is kept either way.
    var isEnabled: Bool {
        get { container.isEnabled }
        set {
            guard newValue != isEnabled else { return }
            container.defaults?.set(newValue, forKey: UserDictContainer.enabledKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// What the preview's engine should read right now.
    var activeDictionary: UserDict? {
        isEnabled ? dictionary : nil
    }

    /// One line for the list's footer.
    var statusText: String {
        if let lastError {
            return "未能加载：\(lastError.message)"
        }
        guard let dictionary, !rows.isEmpty else {
            return "尚无词条"
        }
        var text = "\(dictionary.entries) 条生效"
        if let report {
            if report.invalid > 0 { text += "，\(report.invalid) 条无效" }
            if report.dropped > 0 { text += "，\(report.dropped) 条重复" }
            if report.shared > 0 { text += "，\(report.shared) 条同码" }
        }
        return text
    }

    // MARK: - Loading and saving

    /// Re-read the file and rebuild. The app is the file's only writer, so
    /// this runs at launch; a save adopts what it wrote without re-reading.
    func reload() {
        guard let textURL = container.textURL else {
            fail(.noContainer)
            return
        }
        do {
            adopt(try UserDictFile.read(at: textURL))
        } catch let error as UserDictFileError where error == .notUTF8 {
            fail(.notUTF8)
        } catch {
            fail(.unreadable(error.localizedDescription))
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Write `entries` as the whole file, as typed, then the blob built from
    /// it. The text goes first: it is the truth, and the keyboard ignores a
    /// blob whose tag is not the text's hash, so a crash between the two
    /// writes costs nothing but a rebuild. A file the engine refuses as a
    /// whole is still written — the rows are the user's — and the blob is
    /// removed, so the keyboard runs on the built-in dictionary alone.
    func save(_ entries: [UserDictEntry]) throws {
        guard let textURL = container.textURL, let blobURL = container.blobURL else {
            throw LoadError.noContainer
        }
        let text = UserDictFile.serialize(entries)
        try UserDictFile.write(text, to: textURL)
        adopt(text)
        if let dictionary {
            try? dictionary.blob.write(to: blobURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: blobURL)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Importing

    /// A phrases file picked for import — one 键道 wrote on another device,
    /// or any text in the same format — read the way the list's own is: comments and
    /// blank lines skipped, every other line a row, as it is. Nothing is
    /// judged here and nothing is written. A file without a single phrase
    /// line is refused (`.noPhrases`): it is not a phrase list.
    static func entries(importedFrom url: URL) throws -> [UserDictEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        guard let text = try? UserDictFile.decode(data) else {
            throw LoadError.notUTF8
        }
        let entries = UserDictFile.parse(text).map(\.entry)
        guard !entries.isEmpty else {
            throw LoadError.noPhrases
        }
        return entries
    }

    /// `save`, but only when the engine accepts the whole file; nothing is
    /// written otherwise, and the refusal is thrown as `LoadError.build`.
    /// A typed row may push the file over the engine's caps — it is the
    /// user's, and they are looking at it — but an import, appended as it
    /// is, must not turn a list that works into one that does not.
    func saveIfBuildable(_ entries: [UserDictEntry]) throws {
        let text = UserDictFile.serialize(entries)
        do {
            _ = try UserDict.build(text)
        } catch let error as UserDictError {
            throw LoadError.build(error)
        }
        try save(entries)
    }

    // MARK: - Exporting

    /// A copy of the phrases file in the temporary directory, named as the
    /// file is, for the share sheet to hand to AirDrop, Files or another
    /// app — byte for byte what the keyboard reads, so what one device
    /// exports another imports as it is. The caller removes the copy once
    /// the sheet is done; a copy left behind is replaced by the next.
    func exportCopy() throws -> URL {
        guard let textURL = container.textURL else {
            throw LoadError.noContainer
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UserDictFile.fileName, isDirectory: false)
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: textURL, to: copy)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        return copy
    }

    // MARK: - Duplicates

    /// The rows libjd dropped as duplicates — of an earlier row, or of a
    /// built-in word — by the notes of the last build, the only judge of
    /// that; empty while the file could not be built, since the engine has
    /// no notes then. The list shows them grey; nothing removes them but
    /// the user.
    var duplicateRows: [Int] {
        problems.indices.filter { problems[$0]?.isDuplicate == true }
    }

    /// Delete `duplicateRows`, keeping the first of each. Returns how many
    /// went.
    @discardableResult
    func removeDuplicates() throws -> Int {
        let doomed = Set(duplicateRows)
        guard !doomed.isEmpty else { return 0 }
        try save(entries.indices.filter { !doomed.contains($0) }.map { entries[$0] })
        return doomed.count
    }

    private func adopt(_ text: String?) {
        guard let text else {
            rows = []
            problems = []
            dictionary = nil
            report = nil
            lastError = nil
            return
        }
        rows = UserDictFile.parse(text)
        do {
            let built = try UserDict.build(text, sourceTag: UserDictFile.hash(text))
            dictionary = built.dict
            report = built.report
            lastError = nil
        } catch let error as UserDictError {
            dictionary = nil
            report = nil
            lastError = .build(error)
        } catch {
            dictionary = nil
            report = nil
            lastError = .unreadable(error.localizedDescription)
        }
        problems = UserDictProblem.forRows(lines: rows.map { Optional($0.line) }, report: report)
    }

    private func fail(_ error: LoadError) {
        rows = []
        problems = []
        dictionary = nil
        report = nil
        lastError = error
    }
}
