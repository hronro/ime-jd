import XCTest
@testable import JdIME

/// 编码反查's wording as the macOS window shows it — `CodeLookupReport.text`
/// — over codes from the real engine.
final class CodeLookupReportTests: XCTestCase {
    func testEveryCodeIsListedAndALaterCandidateSaysWhichItIs() {
        let report = CodeLookupReport(query: "着", codes: Engine().lookupCodes("着"), scope: .builtIn)
        XCTAssertTrue(report.found)
        XCTAssertEqual(report.title, "「着」的编码")
        let lines = report.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "o（第 2 个候选）")
        XCTAssertEqual(Array(lines[1...]), ["fe", "qe", "flo", "fzou", "qzou", "feouia", "flouia", "fzouia", "qeouia", "qzouia"])
    }

    func testACodeWhereTheWordComesFirstStandsAlone() {
        let report = CodeLookupReport(query: "的", codes: Engine().lookupCodes("的"), scope: .builtIn)
        XCTAssertEqual(report.text, "d\ndeuiua\ndkuiua")
    }

    func testUserPhrasesAreMarkedAndCountTowardTheCandidateNumber() throws {
        let (dict, _) = try UserDict.build("的\tzzzzzz\n测试词\td\n", sourceTag: 0)
        let engine = Engine(userDict: dict)
        let report = CodeLookupReport(query: "的", codes: engine.lookupCodes("的"), scope: .builtInAndUser)
        XCTAssertEqual(
            report.text,
            "d（第 2 个候选）\ndeuiua\ndkuiua\nzzzzzz（自造词）"
        )
        let mine = CodeLookupReport(query: "测试词", codes: engine.lookupCodes("测试词"), scope: .builtInAndUser)
        XCTAssertEqual(mine.text, "d（自造词）")
    }

    func testNotFoundSaysWhereItLooked() {
        let enabled = CodeLookupReport(query: "不在词库里的词", codes: [], scope: .builtInAndUser)
        XCTAssertFalse(enabled.found)
        XCTAssertEqual(enabled.title, "没有找到「不在词库里的词」")
        XCTAssertEqual(enabled.text, "内置词库和用户自造词中都没有这个词。")
        let disabled = CodeLookupReport(query: "词", codes: [], scope: .builtIn)
        XCTAssertEqual(disabled.text, "内置词库中没有这个词。用户自造词未启用，不在查询范围内。")
    }

    func testALongQueryIsCutShortInTheTitle() {
        let long = String(repeating: "键", count: 30)
        let report = CodeLookupReport(query: long, codes: [], scope: .builtIn)
        XCTAssertEqual(report.title, "没有找到「\(String(repeating: "键", count: 20))…」")
    }

    func testTheQueryLosesOnlyLineBreaksSpacesAndTabsAtItsEnds() {
        XCTAssertEqual(CodeLookupReport.query(from: " 键道\r\n"), "键道")
        XCTAssertEqual(CodeLookupReport.query(from: "\t键 道\n"), "键 道")
        XCTAssertEqual(CodeLookupReport.query(from: "键道\u{3000}"), "键道\u{3000}")
        XCTAssertEqual(CodeLookupReport.query(from: " \n"), "")
    }
}
