import XCTest

/// The container app's store: the file as typed, the engine's verdict per
/// row, the whole-file failures, the switch.
final class UserDictStoreTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private let suite = "com.hronro.ime-jd.tests.user-dict-store"
    private var container: UserDictContainer!
    private var store: UserDictStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jd-userdictstore-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        container = UserDictContainer(directory: dir, defaults: defaults)
        store = UserDictStore(container: container)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    func testEveryRowIsSavedAsTypedWithTheEnginesVerdict() throws {
        XCTAssertEqual(store.rows, [])
        XCTAssertEqual(store.statusText, "尚无词条")
        let entries = [
            UserDictEntry(value: "甲", keys: "zzzzzz"),
            UserDictEntry(value: "乙", keys: "ZZZZZA"),   // bad keys: skipped
            UserDictEntry(value: "甲", keys: "zzzzzz"),   // repeats row 1: dropped
            UserDictEntry(value: "不", keys: "b"),        // repeats a built-in word: dropped
            UserDictEntry(value: "测试词", keys: "b"),    // shares b with built-in words: kept
        ]
        try store.save(entries)

        XCTAssertEqual(store.rows.map(\.entry), entries)
        XCTAssertEqual(store.rows.map(\.line), [2, 3, 4, 5, 6])
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.dictionary?.entries, 2)
        XCTAssertEqual(store.problems.count, 5)
        XCTAssertNil(store.problems[0])
        XCTAssertEqual(store.problems[1], .invalid(.badKeys))
        XCTAssertEqual(store.problems[2], .duplicate(ofRow: 0))
        XCTAssertEqual(store.problems[3], .duplicate(ofRow: nil))
        guard case .sharedCode(let builtIn, nil, 0)? = store.problems[4] else {
            return XCTFail("expected a shared-code verdict, got \(String(describing: store.problems[4]))")
        }
        XCTAssertGreaterThanOrEqual(builtIn, 1)
        XCTAssertEqual(store.problems[1]?.text, "编码无效（1 到 6 个 a-z），不生效")
        XCTAssertEqual(store.problems[2]?.text, "与第 1 条重复，不生效")
        XCTAssertEqual(store.problems[3]?.text, "与内置词重复，不生效")
        XCTAssertEqual(store.problems[4]?.text, "与 \(builtIn) 个内置词同码")
        XCTAssertEqual(store.statusText, "2 条生效，1 条无效，2 条重复，1 条同码")
        // A fresh store reads the same rows back, in order, with the same verdicts.
        let again = UserDictStore(container: container)
        XCTAssertEqual(again.rows, store.rows)
        XCTAssertEqual(again.problems, store.problems)
    }

    func testAFileTheEngineRefusesIsKeptAndItsBlobDropped() throws {
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.blobURL!.path))

        // One phrase past the cap: the engine refuses the file as a whole.
        let tooMany = (0...UserDict.maxEntries).map { UserDictEntry(value: "词\($0)", keys: "zzzzzz") }
        try store.save(tooMany)
        XCTAssertEqual(store.lastError, .build(UserDictError(status: .tooManyEntries, line: UInt32(UserDict.maxEntries + 2))))
        XCTAssertEqual(store.rows.count, UserDict.maxEntries + 1, "the rows are the user's: still written")
        XCTAssertNil(store.dictionary)
        XCTAssertEqual(store.problems, Array(repeating: nil, count: UserDict.maxEntries + 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.blobURL!.path))
        XCTAssertTrue(store.statusText.hasPrefix("未能加载："))
        store.isEnabled = true
        XCTAssertNil(container.load(), "the keyboard fails the same build and runs without")

        // Fixed: back to normal.
        try store.save(Array(tooMany.prefix(2)))
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.dictionary?.entries, 2, "two phrases on one code are both kept")
        XCTAssertEqual(store.report?.shared, 2)
        XCTAssertEqual(container.load()?.source, .blob)
    }

    func testTheSwitchLivesInTheSharedDefaults() throws {
        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.activeDictionary)
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        XCTAssertNil(store.activeDictionary, "off: the preview runs on the built-in dictionary")

        var notified = 0
        let observer = NotificationCenter.default.addObserver(
            forName: UserDictStore.didChange, object: store, queue: nil
        ) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.isEnabled = true
        XCTAssertEqual(notified, 1)
        store.isEnabled = true
        XCTAssertEqual(notified, 1, "no change, no notice")
        XCTAssertTrue(defaults.bool(forKey: UserDictContainer.enabledKey))
        XCTAssertTrue(container.isEnabled)
        XCTAssertNotNil(store.activeDictionary)
    }

    // MARK: - Importing

    func testAnImportedFileIsReadTheWayTheListsOwnIs() throws {
        let file = dir.appendingPathComponent("import.txt")
        // A BOM, CRLF line ends, a comment, a blank line, spaces around the
        // fields, a line without a TAB: every phrase line becomes a row, as
        // typed, in file order; nothing is judged.
        let text = "\u{FEFF}# 键道用户自造词\r\n键道\tzzzzzz\r\n\r\n 乙 \t ZZZZZA \r\n没有编码\r\n"
        try Data(text.utf8).write(to: file)
        XCTAssertEqual(try UserDictStore.entries(importedFrom: file), [
            UserDictEntry(value: "键道", keys: "zzzzzz"),
            UserDictEntry(value: "乙", keys: "ZZZZZA"),
            UserDictEntry(value: "没有编码", keys: ""),
        ])
        XCTAssertEqual(store.rows, [], "nothing written")

        try Data([0xFF, 0xFE, 0x41]).write(to: file)
        XCTAssertThrowsError(try UserDictStore.entries(importedFrom: file)) { error in
            XCTAssertEqual(error as? UserDictStore.LoadError, .notUTF8)
            XCTAssertEqual(error.localizedDescription, "文件不是 UTF-8 编码")
        }
        try Data("# only a comment\n\n".utf8).write(to: file)
        XCTAssertThrowsError(try UserDictStore.entries(importedFrom: file)) { error in
            XCTAssertEqual(error as? UserDictStore.LoadError, .noPhrases)
            XCTAssertEqual(error.localizedDescription, "文件中没有词条")
        }
        XCTAssertThrowsError(try UserDictStore.entries(importedFrom: dir.appendingPathComponent("missing.txt"))) { error in
            guard case .unreadable? = error as? UserDictStore.LoadError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    func testDuplicatesAreTheEnginesToNameAndTheUsersToRemove() throws {
        let entries = [
            UserDictEntry(value: "甲", keys: "zzzzzz"),
            UserDictEntry(value: "乙", keys: "ZZZZZA"),   // invalid: stays
            UserDictEntry(value: "甲", keys: "zzzzzz"),   // repeats row 0
            UserDictEntry(value: "不", keys: "b"),        // repeats a built-in word
            UserDictEntry(value: "丙", keys: "zzzzzz"),   // shares the code: works, stays
        ]
        try store.saveIfBuildable(entries)   // an import: appended as it is
        XCTAssertEqual(store.rows.count, 5, "nothing is dropped on the way in")
        XCTAssertEqual(store.duplicateRows, [2, 3])
        XCTAssertEqual(store.statusText, "2 条生效，1 条无效，2 条重复，2 条同码", "甲 and 丙 share the code with each other")
        XCTAssertEqual(try store.removeDuplicates(), 2)
        XCTAssertEqual(store.entries, [entries[0], entries[1], entries[4]], "the first of each stays")
        XCTAssertEqual(store.duplicateRows, [])
        XCTAssertEqual(try store.removeDuplicates(), 0)

        // A file the engine refuses as a whole has no notes: nothing to remove.
        try store.save((0...UserDict.maxEntries).map { _ in entries[0] })
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.duplicateRows, [])
        XCTAssertEqual(try store.removeDuplicates(), 0)
    }

    func testAnImportTheEngineRefusesWritesNothing() throws {
        store.isEnabled = true
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        let textBefore = try String(contentsOf: container.textURL!, encoding: .utf8)
        let tooMany = (0...UserDict.maxEntries).map { UserDictEntry(value: "词\($0)", keys: "zzzzzz") }
        XCTAssertThrowsError(try store.saveIfBuildable(tooMany)) { error in
            XCTAssertEqual(
                error as? UserDictStore.LoadError,
                .build(UserDictError(status: .tooManyEntries, line: UInt32(UserDict.maxEntries + 2)))
            )
            XCTAssertEqual(error.localizedDescription, "第 \(UserDict.maxEntries + 2) 行起超过 \(UserDict.maxEntries) 条上限")
        }
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(try String(contentsOf: container.textURL!, encoding: .utf8), textBefore)
        XCTAssertEqual(container.load()?.source, .blob, "the blob is still the one phrase's")

        // Within the caps: written like any save.
        try store.saveIfBuildable(Array(tooMany.prefix(3)))
        XCTAssertEqual(store.rows.count, 3)
        XCTAssertEqual(store.dictionary?.entries, 3)
    }

    func testTheExportIsTheFileItself() throws {
        let entries = [UserDictEntry(value: "键道", keys: "zzzzzz"), UserDictEntry(value: "乙", keys: "ZZZZZA")]
        try store.save(entries)
        let copy = try store.exportCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        XCTAssertEqual(copy.lastPathComponent, "用户自造词.txt")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: container.textURL!), "byte for byte")
        XCTAssertEqual(try UserDictStore.entries(importedFrom: copy), entries, "and it imports as it is")

        // A second export replaces a copy left behind.
        try store.save(Array(entries.prefix(1)))
        XCTAssertEqual(try UserDictStore.entries(importedFrom: try store.exportCopy()), Array(entries.prefix(1)))

        let orphan = UserDictStore(container: UserDictContainer(directory: nil, defaults: nil))
        XCTAssertThrowsError(try orphan.exportCopy()) { error in
            XCTAssertEqual(error as? UserDictStore.LoadError, .noContainer)
        }
    }

    func testNoContainerIsReportedNotCrashed() {
        let orphan = UserDictStore(container: UserDictContainer(directory: nil, defaults: nil))
        XCTAssertEqual(orphan.lastError, .noContainer)
        XCTAssertEqual(orphan.statusText, "未能加载：无法访问共享容器")
        XCTAssertThrowsError(try orphan.save([UserDictEntry(value: "键道", keys: "zzzzzz")]))
        XCTAssertFalse(orphan.isEnabled)
        orphan.isEnabled = true
        XCTAssertFalse(orphan.isEnabled, "nowhere to keep it")
    }
}
