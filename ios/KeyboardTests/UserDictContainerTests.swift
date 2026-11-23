import XCTest

/// The hand-off between the container app and the keyboard, against a
/// temporary directory standing in for the App Group container: the app
/// (`UserDictStore`) writes, the keyboard (`UserDictContainer.load`) reads.
final class UserDictContainerTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private let suite = "com.hronro.ime-jd.tests.user-dict-container"
    private var container: UserDictContainer!
    private var store: UserDictStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jd-userdict-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
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

    private var textURL: URL { container.textURL! }
    private var blobURL: URL { container.blobURL! }

    func testOffByDefaultAndNothingToLoadMeansNoDictionary() throws {
        XCTAssertNil(container.load(), "no file")
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        XCTAssertNil(container.load(), "off by default, whatever the file holds")
        store.isEnabled = true
        XCTAssertEqual(container.load()?.source, .blob)
        XCTAssertNil(UserDictContainer(directory: nil, defaults: defaults).load(), "no container at all")
    }

    func testTheAppWritesTextAndBlobAndTheKeyboardReadsTheBlob() throws {
        store.isEnabled = true
        let entries = [UserDictEntry(value: "键道", keys: "zzzzzz"), UserDictEntry(value: "不", keys: "b")]
        try store.save(entries)

        let text = try XCTUnwrap(try UserDictFile.read(at: textURL))
        XCTAssertEqual(text, UserDictFile.serialize(entries), "the file is the rows, as typed")
        let blob = try Data(contentsOf: blobURL)
        XCTAssertEqual(try UserDict.check(blob).sourceTag, UserDict.hash(text), "the blob is tagged with the text")

        let loaded = try XCTUnwrap(container.load())
        XCTAssertEqual(loaded.source, .blob)
        XCTAssertEqual(loaded.dict.entries, 1, "不/b repeats a built-in word and is dropped")
        XCTAssertEqual(store.report?.dropped, 1)

        // The phrase reaches an engine created with it.
        let engine = Engine(userDict: loaded.dict)
        for byte in "zzzzzz".utf8 {
            _ = engine.pressKey(byte)
        }
        XCTAssertEqual(engine.readRange(from: 0, count: 1).map(\.value), ["键道"])
    }

    func testAMissingStaleOrCorruptBlobIsRebuiltFromTheTextWithoutWriting() throws {
        store.isEnabled = true
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        let text = try XCTUnwrap(try UserDictFile.read(at: textURL))

        try FileManager.default.removeItem(at: blobURL)
        var loaded = try XCTUnwrap(container.load())
        XCTAssertEqual(loaded.source, .rebuilt)
        XCTAssertEqual(loaded.dict.sourceTag, UserDict.hash(text))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL.path), "the keyboard never writes")

        // A blob of another text — what an app that died between its two
        // writes leaves behind: the tag disagrees, the text wins.
        let other = try UserDict.build("甲\tzzzzza\n", sourceTag: 1).dict
        try other.blob.write(to: blobURL)
        loaded = try XCTUnwrap(container.load())
        XCTAssertEqual(loaded.source, .rebuilt)
        XCTAssertEqual(loaded.dict.entries, 1)
        let engine = Engine(userDict: loaded.dict)
        for byte in "zzzzz".utf8 {
            _ = engine.pressKey(byte)
        }
        XCTAssertEqual(engine.readRange(from: 0, count: 1).map(\.value), ["键道"])

        // Garbage, as a damaged file or another libjd's format would be.
        let garbage = Data([1, 2, 3, 4, 5, 6, 7, 8])
        try garbage.write(to: blobURL)
        XCTAssertEqual(container.load()?.source, .rebuilt)
        XCTAssertEqual(try Data(contentsOf: blobURL), garbage, "stale stays stale until the app rewrites it")

        // The app's next save rewrites it.
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        XCTAssertEqual(container.load()?.source, .blob)
    }

    func testATextNotInUTF8IsTheEnginesToJudgeAndNoTextMeansNoDictionary() throws {
        store.isEnabled = true
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        try Data([0xC4, 0xE3, 0x09, 0x61, 0x0A]).write(to: textURL)
        let loaded = try XCTUnwrap(container.load())
        XCTAssertEqual(loaded.source, .rebuilt, "the blob is another text's: not trusted")
        XCTAssertEqual(loaded.dict.entries, 0, "libjd skips a line that is not UTF-8, as it skips any bad line")
        try FileManager.default.removeItem(at: textURL)
        XCTAssertNil(container.load(), "no text, no dictionary, whatever blob is left")
    }

    func testATextWithAByteOrderMarkStillMatchesItsBlob() throws {
        store.isEnabled = true
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        let text = try Data(contentsOf: textURL)
        try (Data([0xEF, 0xBB, 0xBF]) + text).write(to: textURL)
        let loaded = try XCTUnwrap(container.load())
        XCTAssertEqual(loaded.source, .blob, "the mark is dropped before hashing, as decoding drops it")
        XCTAssertEqual(loaded.dict.entries, 1)
    }

    func testTheStampTracksTheSwitchAndBothFiles() throws {
        let off = container.stamp()
        XCTAssertEqual(off, UserDictContainer.Stamp(enabled: false, userOnly: false, text: nil, blob: nil))
        store.isEnabled = true
        let on = container.stamp()
        XCTAssertEqual(on, UserDictContainer.Stamp(enabled: true, userOnly: false, text: nil, blob: nil))

        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        let saved = container.stamp()
        XCTAssertNotNil(saved.text)
        XCTAssertNotNil(saved.blob)
        XCTAssertEqual(container.stamp(), saved, "unchanged files, unchanged stamp")

        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz"), UserDictEntry(value: "键道输入法", keys: "zzzzza")])
        XCTAssertNotEqual(container.stamp(), saved)
    }

    // MARK: - Only the user's phrases

    func testUserOnlyBuildsOnTheEmptyDictionaryAndKeepsWhatTheBuiltInWouldDrop() throws {
        store.isEnabled = true
        store.isUserOnly = true
        XCTAssertTrue(defaults.bool(forKey: UserDictContainer.userOnlyKey))
        let entries = [UserDictEntry(value: "键道", keys: "zzzzzz"), UserDictEntry(value: "不", keys: "b")]
        try store.save(entries)
        XCTAssertEqual(store.report?.dropped, 0, "nothing to repeat: the built-in dictionary is off")

        let blob = try Data(contentsOf: blobURL)
        XCTAssertNoThrow(try UserDict.check(blob, on: .empty), "the blob is built on the empty dictionary")
        XCTAssertThrowsError(try UserDict.check(blob))

        guard case .userOnly(let dict) = container.selection() else { return XCTFail("\(container.selection())") }
        XCTAssertEqual(dict.entries, 2)
        let engine = try Engine(dict: .empty, userDict: dict)
        _ = engine.pressKey(UInt8(ascii: "b"))
        XCTAssertEqual(engine.readRange(from: 0, count: 2).map(\.value), ["不"], "the user's phrase, and nothing built in")
    }

    func testFlippingUserOnlyRewritesTheBlobForTheOtherBase() throws {
        store.isEnabled = true
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        XCTAssertNoThrow(try UserDict.check(Data(contentsOf: blobURL)))
        store.isUserOnly = true
        XCTAssertNoThrow(try UserDict.check(Data(contentsOf: blobURL), on: .empty))
        XCTAssertEqual(container.load()?.source, .blob)
        store.isUserOnly = false
        XCTAssertNoThrow(try UserDict.check(Data(contentsOf: blobURL)))
        XCTAssertEqual(container.load()?.source, .blob)
    }

    func testAKeyboardOnAnotherBaseRebuildsRatherThanUsingTheBlob() throws {
        store.isEnabled = true
        try store.save([UserDictEntry(value: "键道", keys: "zzzzzz")])
        // The switch flips behind the app's back (another process): the blob
        // is for the built-in dictionary, the keyboard rebuilds on the empty one.
        defaults.set(true, forKey: UserDictContainer.userOnlyKey)
        XCTAssertEqual(container.load()?.source, .rebuilt)
        guard case .userOnly = container.selection() else { return XCTFail("\(container.selection())") }
    }

    func testUserOnlyWithoutPhrasesIsUnavailableNeverTheBuiltInDictionary() throws {
        store.isEnabled = true
        store.isUserOnly = true
        guard case .unavailable(let why) = container.selection() else { return XCTFail("\(container.selection())") }
        XCTAssertEqual(why, "用户自造词未能加载：没有词条文件")
        guard case .unavailable = store.selection else { return XCTFail("\(store.selection)") }
        XCTAssertNil(store.makeEngine())

        // Too many phrases: unavailable too, saying why.
        let tooMany = String(repeating: "x\ta\n", count: UserDict.maxEntries + 1)
        try UserDictFile.write(tooMany, to: textURL)
        guard case .unavailable(let over) = container.selection() else { return XCTFail("\(container.selection())") }
        XCTAssertEqual(over, "用户自造词未能加载：超过 \(UserDict.maxEntries) 条上限")

        // The second switch means nothing while the first is off.
        store.isEnabled = false
        guard case .builtIn(nil) = container.selection() else { return XCTFail("\(container.selection())") }
    }

    func testTheStampSeesTheSecondSwitch() {
        let before = container.stamp()
        store.isUserOnly = true
        XCTAssertNotEqual(container.stamp(), before)
    }
}
