import XCTest
@testable import JdIME

final class UserDictFileTests: XCTestCase {
    func testParseSkipsCommentsAndBlanksAndKeepsLineNumbers() {
        let text = "# header\n\n你好\tnh\r\n  世界 \t sj  \n# tail\n键道\tjd"
        let rows = UserDictFile.parse(text)
        XCTAssertEqual(rows, [
            UserDictRow(line: 3, entry: UserDictEntry(value: "你好", keys: "nh")),
            UserDictRow(line: 4, entry: UserDictEntry(value: "世界", keys: "sj")),
            UserDictRow(line: 6, entry: UserDictEntry(value: "键道", keys: "jd")),
        ])
    }

    func testParseIsLenientAboutMissingTabs() throws {
        // A line without a TAB keeps its text and gets empty keys, so the
        // GUI can show it and let the user fix it in place. The engine, not
        // the GUI, says what is wrong with it.
        let rows = UserDictFile.parse("no tab here\n好\thz\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], UserDictRow(line: 1, entry: UserDictEntry(value: "no tab here", keys: "")))
        let (_, report) = try UserDict.build("no tab here\n好\thz\n")
        XCTAssertEqual(report.invalidLines, [1])
    }

    func testParseReadsACommentByItsFirstByte() throws {
        // "#" plus a combining mark is one Swift Character, but libjd reads
        // bytes: the line is a comment to the engine, so it is no row here.
        let text = "#\u{0301} 注释\tzzzzza\n键道\tzzzzzz\n"
        XCTAssertEqual(UserDictFile.parse(text), [
            UserDictRow(line: 2, entry: UserDictEntry(value: "键道", keys: "zzzzzz")),
        ])
        let (_, report) = try UserDict.build(text)
        XCTAssertEqual(report.entries, 1, "a phrase on zzzzza would make two")
        XCTAssertEqual(report.invalid, 0)
    }

    func testSerializeWritesHeaderAndRoundTrips() {
        let entries = [
            UserDictEntry(value: "你好", keys: "nh"),
            UserDictEntry(value: "键道输入法", keys: "jdsrf"),
        ]
        let text = UserDictFile.serialize(entries)
        XCTAssertTrue(text.hasPrefix(UserDictFile.header + "\n"))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("\r"))
        let rows = UserDictFile.parse(text)
        XCTAssertEqual(rows.map(\.entry), entries)
        XCTAssertEqual(rows.map(\.line), [2, 3])
        XCTAssertEqual(rows.map(\.line), entries.indices.map(UserDictFile.line(ofEntryAt:)))
        XCTAssertEqual(UserDictFile.serialize([]), UserDictFile.header + "\n")
    }

    func testTheHeaderIsAValidCommentForTheEngine() throws {
        let (dict, report) = try UserDict.build(UserDictFile.serialize([UserDictEntry(value: "键道", keys: "zzzzzz")]))
        XCTAssertEqual(report.entries, 1)
        XCTAssertEqual(report.dropped, 0)
        XCTAssertEqual(dict.entries, 1)
    }

    func testDecodeDropsTheBOMAndRejectsNonUTF8() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        XCTAssertEqual(try UserDictFile.decode(Data(bom + Array("好\thz\n".utf8))), "好\thz\n")
        XCTAssertEqual(try UserDictFile.decode(Data()), "")
        XCTAssertThrowsError(try UserDictFile.decode(Data([0xC4, 0xE3, 0x09, 0x61]))) { error in
            XCTAssertEqual(error as? UserDictFileError, .notUTF8)
        }
    }

    func testReadAndWriteThroughAFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jdime-userdictfile-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested").appendingPathComponent(UserDictFile.fileName)

        XCTAssertNil(try UserDictFile.read(at: url), "no file reads as nil")
        try UserDictFile.write("好\thz\n", to: url)
        XCTAssertEqual(try UserDictFile.read(at: url), "好\thz\n")
        try UserDictFile.write("", to: url)
        XCTAssertEqual(try UserDictFile.read(at: url), "")
    }

    func testTheEngineOwnsTheFieldRules() throws {
        // The GUI mirrors none of libjd's rules: the boundary cases are the
        // engine's to judge, and a bad line costs only itself.
        let (_, ok) = try UserDict.build("\(String(repeating: "字", count: 85))\tzzzzzz\n")
        XCTAssertEqual(ok.invalid, 0)
        let (_, bad) = try UserDict.build(
            "\(String(repeating: "字", count: 86))\tzzzzzz\n好\tabcdefg\n键道\tzzzzza\n"
        )
        XCTAssertEqual(bad.entries, 1)
        XCTAssertEqual(bad.invalidLines, [1, 2])
    }

    func testNormalizedTrimsAsciiSpacesOnly() {
        let entry = UserDictEntry(value: "  你 好 ", keys: " nh ")
        XCTAssertEqual(entry.normalized(), UserDictEntry(value: "你 好", keys: "nh"))
        XCTAssertEqual(UserDictEntry(value: "\u{3000}好", keys: "hz").normalized().value, "\u{3000}好")
    }

    func testHashMatchesTheFNV1aReferenceVectors() {
        XCTAssertEqual(UserDictFile.hash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(UserDictFile.hash("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertNotEqual(UserDictFile.hash("好\thz\n"), UserDictFile.hash("好\thz"))
    }
}
