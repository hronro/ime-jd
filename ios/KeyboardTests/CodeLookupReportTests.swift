import XCTest

/// 编码反查's wording as the iOS page lists it — `CodeLookupReport.lines`
/// and `message` — over codes from the real engine. (The macOS window's
/// text form is covered in macos/JdIMETests.)
final class CodeLookupReportTests: XCTestCase {
    private typealias Line = CodeLookupReport.Line

    func testEveryCodeIsAListedLineAndALaterCandidateSaysWhichItIs() {
        let report = CodeLookupReport(query: "着", codes: Engine().lookupCodes("着"), userDictEnabled: false)
        XCTAssertTrue(report.found)
        XCTAssertNil(report.message)
        XCTAssertEqual(report.title, "「着」的编码")
        XCTAssertEqual(report.lines.first, Line(keys: "o", note: "第 2 个候选"))
        XCTAssertEqual(report.lines.dropFirst().map(\.keys), ["fe", "qe", "flo", "fzou", "qzou", "feouia", "flouia", "fzouia", "qeouia", "qzouia"])
        XCTAssertTrue(report.lines.dropFirst().allSatisfy { $0.note == nil })
    }

    func testUserPhrasesAreMarkedAndCountTowardTheCandidateNumber() throws {
        let (dict, _) = try UserDict.build("的\tzzzzzz\n测试词\td\n", sourceTag: 0)
        let engine = Engine(userDict: dict)
        XCTAssertEqual(CodeLookupReport(query: "的", codes: engine.lookupCodes("的"), userDictEnabled: true).lines, [
            Line(keys: "d", note: "第 2 个候选"),
            Line(keys: "deuiua", note: nil),
            Line(keys: "dkuiua", note: nil),
            Line(keys: "zzzzzz", note: "自造词"),
        ])
        // A user phrase leads the built-in words on a code it shares, so it
        // is the first candidate there: only 自造词.
        XCTAssertEqual(CodeLookupReport(query: "测试词", codes: engine.lookupCodes("测试词"), userDictEnabled: true).lines, [
            Line(keys: "d", note: "自造词"),
        ])
    }

    func testNotFoundHasAMessageAndNoLines() {
        let enabled = CodeLookupReport(query: "不在词库里的词", codes: [], userDictEnabled: true)
        XCTAssertFalse(enabled.found)
        XCTAssertEqual(enabled.lines, [])
        XCTAssertEqual(enabled.title, "没有找到「不在词库里的词」")
        XCTAssertEqual(enabled.message, "内置词库和用户自造词中都没有这个词。")
        XCTAssertEqual(
            CodeLookupReport(query: "词", codes: [], userDictEnabled: false).message,
            "内置词库中没有这个词。用户自造词未启用，不在查询范围内。"
        )
    }

    func testThePastedQueryLosesOnlyLineBreaksSpacesAndTabsAtItsEnds() {
        XCTAssertEqual(CodeLookupReport.query(from: "键道\n"), "键道")
        XCTAssertEqual(CodeLookupReport.query(from: " 键 道\t"), "键 道")
        XCTAssertEqual(CodeLookupReport.query(from: "\u{3000}键道"), "\u{3000}键道")
    }
}
