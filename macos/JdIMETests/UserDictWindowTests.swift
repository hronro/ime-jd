import XCTest
@testable import JdIME

/// The window's model operations, driven against a visible window so the
/// table has row views to redraw — the shape of the crash this guards
/// against.
final class UserDictWindowTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private let suite = "com.hronro.ime-jd.tests.user-dict-window"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jdime-userdictwindow-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(UserDictFile.fileName)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func visibleController(text: String) throws -> (UserDictWindowController, UserDictStore) {
        try UserDictFile.write(text, to: fileURL)
        let store = UserDictStore(fileURL: fileURL, defaults: defaults)
        let controller = UserDictWindowController(store: store)
        controller.showWindow(nil)
        controller.loadRows(from: try UserDictFile.read(at: fileURL))
        controller.window?.layoutIfNeeded()
        controller.window?.displayIfNeeded()
        return (controller, store)
    }

    func testDeletingRowsWhileVisibleSavesAndSurvivesTheStoreNotification() throws {
        // Regression: removing rows saves, the store notifies synchronously,
        // and the window used to redraw its status column against the old
        // row count — an out-of-range index that took the IME process down.
        let (controller, store) = try visibleController(text: "键道\tzzzzzz\n不\tb\n测试词\tb\n不\tb\n")
        defer { controller.close() }
        XCTAssertEqual(controller.entries.count, 4)
        XCTAssertEqual(store.report?.droppedLines, [2, 4])

        controller.remove(rowsAt: [1, 3])

        let kept = [UserDictEntry(value: "键道", keys: "zzzzzz"), UserDictEntry(value: "测试词", keys: "b")]
        XCTAssertEqual(controller.entries, kept)
        XCTAssertEqual(try UserDictFile.read(at: fileURL), UserDictFile.serialize(kept))
        XCTAssertEqual(store.dictionary?.entries, 2)
        XCTAssertEqual(store.report?.dropped, 0)
        XCTAssertEqual(controller.window?.isVisible, true)
    }

    func testMovingRowsRewritesTheFileInTableOrder() throws {
        let (controller, store) = try visibleController(text: "一\tzzzzzz\n二\tzzzzzz\n三\tzzzzzz\n")
        defer { controller.close() }

        // Drag the last row above the first.
        controller.move(rowsAt: IndexSet(integer: 2), above: 0)
        XCTAssertEqual(controller.entries.map(\.value), ["三", "一", "二"])
        XCTAssertEqual(UserDictFile.parse(try UserDictFile.read(at: fileURL) ?? "").map(\.entry.value), ["三", "一", "二"])

        // Drag the first two to the end; the engine lists them in that order.
        controller.move(rowsAt: IndexSet([0, 1]), above: 3)
        XCTAssertEqual(controller.entries.map(\.value), ["二", "三", "一"])
        let engine = Engine(userDict: store.dictionary)
        for byte in "zzzzzz".utf8 {
            engine.pressKey(byte)
        }
        XCTAssertEqual(engine.readRange(from: 0, count: 3).map(\.value), ["二", "三", "一"])
    }

    func testTheStatusColumnTellsDuplicatesFromSharedCodes() throws {
        let (controller, store) = try visibleController(
            text: "测试词\tb\n一\tzzzzzz\n二\tzzzzzz\n键道\tzzzzza\n不\tb\n三\tb\n四\tzzzzzz\n"
        )
        defer { controller.close() }
        // The engine's notes drive the column; the built-in count on b is
        // whatever the bundled tables say.
        let wordsOnB = store.report?.notes.first { $0.line == 1 }?.builtIn ?? 0
        XCTAssertGreaterThanOrEqual(wordsOnB, 1)
        XCTAssertEqual(controller.statusText(forRow: 0), "与 \(wordsOnB) 个内置词及第 6 条同码")
        XCTAssertEqual(controller.statusText(forRow: 1), "与第 3 条等 2 条同码")
        XCTAssertEqual(controller.statusText(forRow: 2), "与第 2 条等 2 条同码")
        XCTAssertNil(controller.statusText(forRow: 3))
        XCTAssertEqual(controller.statusText(forRow: 4), "与内置词重复，不生效")
        XCTAssertEqual(controller.statusText(forRow: 5), "与 \(wordsOnB) 个内置词及第 1 条同码")
        XCTAssertEqual(controller.statusText(forRow: 6), "与第 2 条等 2 条同码")

        // Removing the other phrase on b leaves only the built-in words.
        controller.remove(rowsAt: [5])
        XCTAssertEqual(controller.statusText(forRow: 0), "与 \(wordsOnB) 个内置词同码")

        // A repeat of a row names the row it repeats; "zzzzzz" is free in
        // the bundled tables, so only the rows share it.
        try UserDictFile.write("甲\tzzzzzz\n乙\tzzzzzz\n甲\tzzzzzz\n", to: fileURL)
        store.reload()
        XCTAssertEqual(controller.statusText(forRow: 0), "与第 2 条同码")
        XCTAssertEqual(controller.statusText(forRow: 1), "与第 1 条同码")
        XCTAssertEqual(controller.statusText(forRow: 2), "与第 1 条重复，不生效")
    }

    func testAnExternalChangeReloadsAVisibleWindow() throws {
        let (controller, store) = try visibleController(text: "键道\tzzzzzz\n")
        defer { controller.close() }
        XCTAssertEqual(controller.entries.count, 1)

        try UserDictFile.write("键道\tzzzzzz\n键道输入法\tzzzzza\n", to: fileURL)
        store.reload()
        XCTAssertEqual(controller.entries.count, 2)
    }

    func testSkippedRowsAreFlaggedAndCountedButNeverBlockTheCheck() throws {
        // A capital letter in a code: the engine skips the line and the
        // window shows its reason; the rest of the file builds, so the
        // repeat on line 3 is still found.
        let (controller, store) = try visibleController(text: "甲\tzzzzzz\n乙\tZZZZZA\n甲\tzzzzzz\n")
        defer { controller.close() }
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.report?.invalid, 1)
        XCTAssertEqual(controller.statusText(forRow: 1), "编码无效（1 到 6 个 a-z 或 ;），不生效")
        XCTAssertEqual(controller.statusText(forRow: 2), "与第 1 条重复，不生效")
        XCTAssertEqual(controller.duplicateCheck(), .found(duplicates: [2], shared: [], invalid: 1))

        // Fixed in the editor: nothing left to flag but the repeat.
        try UserDictFile.write("甲\tzzzzzz\n乙\tzzzzza\n甲\tzzzzzz\n", to: fileURL)
        store.reload()
        XCTAssertEqual(controller.duplicateCheck(), .found(duplicates: [2], shared: [], invalid: 0))

        controller.remove(rowsAt: [2])
        XCTAssertEqual(controller.duplicateCheck(), .clean(invalid: 0))
    }

    func testTheCheckSaysSoWhileTheFileCannotBeLoaded() throws {
        // Not UTF-8: the engine never saw this version of the file, so there
        // are no notes to sum up and the check must not call the file clean.
        try Data([0xC4, 0xE3, 0x09, 0x61, 0x0A]).write(to: fileURL)
        let store = UserDictStore(fileURL: fileURL, defaults: defaults)
        let controller = UserDictWindowController(store: store)
        controller.showWindow(nil)
        controller.loadRows(from: nil)
        defer { controller.close() }
        let error = try XCTUnwrap(store.lastError)
        XCTAssertEqual(controller.entries.count, 0)
        XCTAssertEqual(controller.duplicateCheck(), .unavailable(reason: error.message))
    }
}
