import XCTest
@testable import JdIME

/// The shared `UserDict` wrapper driven through the real engine, mirroring
/// `bindings/rust/tests/engine.rs`.
final class UserDictTests: XCTestCase {
    private func build(_ text: String, tag: UInt64 = 0) throws -> (dict: UserDict, report: UserDictReport) {
        try UserDict.build(text, sourceTag: tag)
    }

    func testUserPhrasesLeadTheBuiltInCandidatesOnASharedCode() throws {
        // 'b' → 不 in the built-in tables; the user adds a word on the same
        // code and repeats a built-in one, which is dropped.
        let (dict, report) = try build("测试词\tb\n不\tb\n")
        XCTAssertEqual(report.entries, 1)
        XCTAssertEqual(report.dropped, 1)
        XCTAssertEqual(report.droppedLines, [2])
        XCTAssertEqual(dict.entries, 1)

        let engine = Engine(userDict: dict)
        engine.pressKey(UInt8(ascii: "b"))
        let window = engine.readRange(from: 0, count: 2)
        XCTAssertEqual(window.map(\.value), ["测试词", "不"])

        // The user word is what space commits.
        XCTAssertEqual(engine.pressKey(UInt8(ascii: " ")).commit, "测试词")

        // A plain context is unaffected.
        let plain = Engine()
        plain.pressKey(UInt8(ascii: "b"))
        XCTAssertEqual(plain.readRange(from: 0, count: 1).first?.value, "不")
    }

    func testAUserOnlyCodeComposesWithHintsAndAutoCommits() throws {
        let (dict, _) = try build("键道\tzzzzzz\n键道输入法\tzzzzza\n")
        let engine = Engine(userDict: dict)
        for byte in "zzzzz".utf8 {
            engine.pressKey(byte)
        }
        XCTAssertNil(engine.state.commit)
        let window = engine.readRange(from: 0, count: 4)
        XCTAssertEqual(window.count, 2)
        XCTAssertEqual(window[0].value, "键道输入法")
        XCTAssertEqual(window[0].hint, "a")
        XCTAssertEqual(window[1].value, "键道")
        XCTAssertEqual(window[1].hint, "z")

        let state = engine.pressKey(UInt8(ascii: "z"))
        XCTAssertEqual(state.commit, "键道")
        XCTAssertEqual(state.optionsCount, 0)
    }

    func testBadLinesAreSkippedAndNotedNeverFatal() throws {
        // "zzzzzz" and "zzzzza" are free in the built-in tables, so the only
        // notes are the skipped lines'.
        let (dict, report) = try build("键道\tzzzzzz\nno tab\n好\tZZZZZA\n\tzzzzza\n")
        XCTAssertEqual(dict.entries, 1)
        XCTAssertEqual(report.entries, 1)
        XCTAssertEqual(report.invalid, 3)
        XCTAssertEqual(report.dropped, 0)
        XCTAssertEqual(report.invalidLines, [2, 3, 4])
        XCTAssertEqual(report.notes, [
            UserDictNote(line: 2, flags: .malformed, other: 0, builtIn: 0, peers: 0),
            UserDictNote(line: 3, flags: .badKeys, other: 0, builtIn: 0, peers: 0),
            UserDictNote(line: 4, flags: .badValue, other: 0, builtIn: 0, peers: 0),
        ])
        XCTAssertTrue(report.notes.allSatisfy { $0.isInvalid && !$0.isDropped && !$0.isShared })
    }

    func testDroppedLinesAreListedInOrder() throws {
        // Lines 1 and 5 repeat built-in words; line 4 repeats line 3 exactly.
        let (_, report) = try build("不\tb\n# comment\n测试词\tb\n测试词\tb\n好\thz\n键道\tzzzzzz\n")
        XCTAssertEqual(report.entries, 2)
        XCTAssertEqual(report.dropped, 3)
        XCTAssertEqual(report.droppedLines, [1, 4, 5])
    }

    func testCachedBlobsRoundTripAndCorruptionIsCaught() throws {
        // "zzzzzz" is free in the built-in tables, so the phrase is kept.
        let tag: UInt64 = 0x0123_4567_89ab_cdef
        let (dict, report) = try build("# comment\n键道\tzzzzzz\n", tag: tag)
        XCTAssertEqual(report.entries, 1)
        XCTAssertEqual(dict.entries, 1)
        XCTAssertEqual(dict.sourceTag, tag)
        let bytes = dict.blob
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertEqual(bytes.count, dict.byteCount)

        // The tag and the count survive the trip through the cache, and
        // `check` peeks at them without constructing anything.
        let again = try UserDict(blob: bytes)
        XCTAssertEqual(again.blob, bytes)
        XCTAssertEqual(again.sourceTag, tag)
        XCTAssertEqual(again.entries, 1)
        XCTAssertEqual(try UserDict.check(bytes), UserDictInfo(sourceTag: tag, entries: 1))

        // The engine reads the cached copy exactly like the original.
        let engine = Engine(userDict: again)
        for byte in "zzzzzz".utf8 {
            engine.pressKey(byte)
        }
        XCTAssertEqual(engine.state.commit, "键道")

        XCTAssertThrowsError(try UserDict(blob: bytes.dropLast())) { error in
            let error = error as? UserDictError
            XCTAssertEqual(error?.status, .corrupt)
            XCTAssertEqual(error?.status.isLineError, false)
        }

        // The built-in dictionary fingerprint lives in the header.
        var stale = bytes
        stale[12] ^= 0xFF
        XCTAssertThrowsError(try UserDict(blob: stale)) { error in
            XCTAssertEqual((error as? UserDictError)?.status, .stale)
        }

        XCTAssertThrowsError(try UserDict.check(Data())) { error in
            XCTAssertEqual((error as? UserDictError)?.status, .corrupt)
        }
    }

    func testNotesSayWhatALineRepeatsAndWhichCodesAreShared() throws {
        // 'b' carries built-in words; "zzzzzz" and "zzzzza" are free.
        let (_, report) = try build("测试词\tb\n一\tzzzzzz\n二\tzzzzzz\n键道\tzzzzza\n不\tb\n")
        XCTAssertEqual(report.entries, 4)
        XCTAssertEqual(report.dropped, 1)
        XCTAssertEqual(report.shared, 3)
        let wordsOnB = report.notes.first?.builtIn ?? 0
        XCTAssertGreaterThanOrEqual(wordsOnB, 1)
        XCTAssertEqual(report.notes, [
            UserDictNote(line: 1, flags: .codeInBuiltIn, other: 0, builtIn: wordsOnB, peers: 0),
            UserDictNote(line: 2, flags: .codeInLine, other: 3, builtIn: 0, peers: 1),
            UserDictNote(line: 3, flags: .codeInLine, other: 2, builtIn: 0, peers: 1),
            UserDictNote(line: 5, flags: .repeatsBuiltIn, other: 0, builtIn: wordsOnB, peers: 0),
        ])
        XCTAssertEqual(report.droppedLines, [5])
        XCTAssertTrue(report.notes[0].isShared)
        XCTAssertFalse(report.notes[0].isDropped)
        XCTAssertTrue(report.notes[3].isDropped)
        XCTAssertFalse(report.notes[3].isShared)

        // Nothing to say about a clean file.
        let (_, clean) = try build("键道\tzzzzzz\n")
        XCTAssertEqual(clean.shared, 0)
        XCTAssertEqual(clean.notes, [])
    }

    func testAnEmptyDictionaryIsValidAndInert() throws {
        let (dict, report) = try build("")
        XCTAssertEqual(report.entries, 0)
        XCTAssertEqual(dict.entries, 0)
        let withDict = Engine(userDict: dict)
        let plain = Engine()
        withDict.pressKey(UInt8(ascii: "a"))
        plain.pressKey(UInt8(ascii: "a"))
        XCTAssertEqual(withDict.state, plain.state)
        XCTAssertEqual(withDict.readRange(from: 0, count: 9), plain.readRange(from: 0, count: 9))
    }

    func testTheEngineKeepsItsDictionaryAlive() throws {
        // The engine reads the blob in place, so the dictionary must live as
        // long as the context — ARC, through the engine's strong reference.
        weak var observed: UserDict?
        var engine: Engine? = nil
        do {
            let (dict, _) = try build("键道\tzzzzzz\n")
            observed = dict
            engine = Engine(userDict: dict)
        }
        XCTAssertNotNil(observed, "the engine retains the dictionary")
        XCTAssertNotNil(engine?.userDict)
        engine = nil
        XCTAssertNil(observed, "nothing else holds it once the engine is gone")
    }

    func testLimitsMatchTheHeader() {
        XCTAssertEqual(UserDict.maxEntries, 10_000)
        XCTAssertEqual(UserDict.maxValueBytes, 255)
        XCTAssertEqual(UserDict.maxKeyLength, 6)
        XCTAssertEqual(UserDict.keyAlphabet.count, 26)
    }
}
