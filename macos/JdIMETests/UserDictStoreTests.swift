import XCTest
@testable import JdIME

final class UserDictStoreTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private let suite = "com.hronro.ime-jd.tests.user-dict-store"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jdime-userdictstore-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(UserDictFile.fileName)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> UserDictStore {
        UserDictStore(fileURL: fileURL, defaults: defaults)
    }

    func testNoFileMeansNoDictionary() {
        let store = makeStore()
        XCTAssertNil(store.dictionary)
        XCTAssertNil(store.activeDictionary)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.generation, 0)
        XCTAssertFalse(store.isEnabled, "off until the user turns it on")
        XCTAssertFalse(store.reload(), "nothing to do")
        XCTAssertEqual(store.generation, 0)
        XCTAssertEqual(store.statusText, "用户自造词：尚无词条")
    }

    func testTheFileIsBuiltAtInitAndOnlyRebuiltWhenItChanges() throws {
        try UserDictFile.write("键道\tzzzzzz\n不\tb\n", to: fileURL)
        let store = makeStore()
        XCTAssertEqual(store.dictionary?.entries, 1)
        XCTAssertEqual(store.report?.dropped, 1)
        XCTAssertEqual(store.report?.droppedLines, [2])
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.generation, 1)
        XCTAssertEqual(store.statusText, "用户自造词：1 条，1 条重复已忽略")

        // Same content: nothing happens.
        XCTAssertFalse(store.reload())
        XCTAssertEqual(store.generation, 1)
        try UserDictFile.write("键道\tzzzzzz\n不\tb\n", to: fileURL)
        XCTAssertFalse(store.reload())
        XCTAssertEqual(store.generation, 1)

        // New content: a new dictionary.
        try UserDictFile.write("键道\tzzzzzz\n键道输入法\tzzzzza\n", to: fileURL)
        XCTAssertTrue(store.reload())
        XCTAssertEqual(store.dictionary?.entries, 2)
        XCTAssertEqual(store.generation, 2)

        // Gone: no dictionary.
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertTrue(store.reload())
        XCTAssertNil(store.dictionary)
        XCTAssertEqual(store.generation, 3)
    }

    func testABadLineIsSkippedAndCounted() throws {
        try UserDictFile.write("键道\tzzzzzz\n", to: fileURL)
        let store = makeStore()
        XCTAssertEqual(store.generation, 1)

        // A typo costs its line and nothing else: the file still builds.
        try UserDictFile.write("键道\tzzzzzz\nno tab\n", to: fileURL)
        XCTAssertTrue(store.reload())
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.dictionary?.entries, 1)
        XCTAssertEqual(store.report?.invalid, 1)
        XCTAssertEqual(store.report?.invalidLines, [2])
        XCTAssertEqual(store.generation, 2)
        XCTAssertEqual(store.statusText, "用户自造词：1 条，1 条无效已跳过")

        // Fixed: back to normal.
        try UserDictFile.write("键道\tzzzzzz\n好\tzzzzza\n", to: fileURL)
        XCTAssertTrue(store.reload())
        XCTAssertEqual(store.report?.invalid, 0)
        XCTAssertEqual(store.dictionary?.entries, 2)
        XCTAssertEqual(store.generation, 3)
    }

    func testAFileThatIsNotUTF8IsReportedOnce() throws {
        try Data([0xC4, 0xE3, 0x09, 0x61, 0x0A]).write(to: fileURL)
        let store = makeStore()
        XCTAssertNil(store.dictionary)
        guard case .notUTF8? = store.lastError else {
            return XCTFail("expected notUTF8, got \(String(describing: store.lastError))")
        }
        XCTAssertEqual(store.statusText, "用户自造词：文件不是 UTF-8 编码")
    }

    func testTheToggleSwitchesTheActiveDictionaryWithoutTouchingTheFile() throws {
        try UserDictFile.write("键道\tzzzzzz\n", to: fileURL)
        let store = makeStore()
        // Off by default: the file is loaded for the window, but engines get nothing.
        XCTAssertFalse(store.isEnabled)
        XCTAssertNotNil(store.dictionary, "loaded for the window")
        XCTAssertNil(store.activeDictionary)
        XCTAssertEqual(store.generation, 1)
        store.isEnabled = false
        XCTAssertEqual(store.generation, 1, "no change, no bump")

        store.isEnabled = true
        XCTAssertTrue(store.isEnabled)
        XCTAssertNotNil(store.activeDictionary)
        XCTAssertEqual(store.generation, 2)
        XCTAssertEqual(defaults.object(forKey: "JdUserDictEnabled") as? Bool, true)

        store.isEnabled = false
        XCTAssertNil(store.activeDictionary)
        XCTAssertNotNil(store.dictionary, "still loaded for the window")
        XCTAssertEqual(store.generation, 3)
        XCTAssertEqual(defaults.object(forKey: "JdUserDictEnabled") as? Bool, false)
    }

    func testSaveWritesTheFileAndAdoptsIt() throws {
        let store = makeStore()
        let entries = [
            UserDictEntry(value: "键道", keys: "zzzzzz"),
            UserDictEntry(value: "键道输入法", keys: "zzzzza"),
        ]
        try store.save(entries)
        XCTAssertEqual(try UserDictFile.read(at: fileURL), UserDictFile.serialize(entries))
        XCTAssertEqual(store.dictionary?.entries, 2)
        XCTAssertEqual(store.generation, 1)
        XCTAssertFalse(store.reload(), "the file the store wrote is already current")
    }

    func testTheWatcherPicksUpAnExternalSave() throws {
        let store = makeStore()
        store.startWatching()
        XCTAssertNil(store.dictionary)

        let changed = expectation(forNotification: UserDictStore.didChange, object: store)
        try UserDictFile.write("键道\tzzzzzz\n", to: fileURL)
        wait(for: [changed], timeout: 5)
        XCTAssertEqual(store.dictionary?.entries, 1)

        // An in-place write to the (new) file is seen too.
        let changedAgain = expectation(forNotification: UserDictStore.didChange, object: store)
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(Data("键道输入法\tzzzzza\n".utf8))
        try handle.close()
        wait(for: [changedAgain], timeout: 5)
        XCTAssertEqual(store.dictionary?.entries, 2)
    }
}
