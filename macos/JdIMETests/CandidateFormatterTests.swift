import AppKit
import XCTest
@testable import JdIME

final class CandidateFormatterTests: XCTestCase {
    func testValueOnlyWhenNoHint() {
        let c = Candidate(value: "你", hint: nil)
        XCTAssertEqual(CandidateFormatter.display(c).string, "你")
    }

    func testValueWithHint() {
        let c = Candidate(value: "你", hint: "abc")
        XCTAssertEqual(CandidateFormatter.display(c).string, "你 〔abc〕")
    }

    func testEmptyHintTreatedAsNone() {
        let c = Candidate(value: "你", hint: "")
        XCTAssertEqual(CandidateFormatter.display(c).string, "你")
    }

    func testHintRunIsDimmed() {
        let c = Candidate(value: "你", hint: "abc")
        let s = CandidateFormatter.display(c)
        var sawSecondary = false
        s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if (value as? NSColor) == .secondaryLabelColor { sawSecondary = true }
        }
        XCTAssertTrue(sawSecondary, "the hint run should be dimmed with secondaryLabelColor")
    }

    // Confirms the bundled dictionary actually carries hints for some
    // candidates — otherwise surfacing them would be a no-op.
    func testEngineEmitsHintsForSomeCandidate() {
        let engine = Engine(pageSize: 9)
        var sawHint = false
        for ch in "abcdefghijklmnopqrstuvwxyz".unicodeScalars {
            let r = engine.pressKey(UInt8(ch.value))
            if r.options.contains(where: { ($0.hint?.isEmpty == false) }) {
                sawHint = true
                break
            }
            engine.reset()
        }
        XCTAssertTrue(sawHint, "expected at least one candidate with a non-empty hint")
    }
}
