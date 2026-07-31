import AppKit
import XCTest
@testable import JdIME

final class CandidateFormatterTests: XCTestCase {
    func testValueOnlyWhenNoHint() {
        XCTAssertEqual(CandidateFormatter.display(value: "你", hint: nil).string, "你")
    }

    func testValueWithHint() {
        XCTAssertEqual(CandidateFormatter.display(value: "你", hint: "abc").string, "你 〔abc〕")
    }

    func testEmptyHintTreatedAsNone() {
        XCTAssertEqual(CandidateFormatter.display(value: "你", hint: "").string, "你")
    }

    func testHintRunIsDimmed() {
        let s = CandidateFormatter.display(value: "你", hint: "abc")
        var sawSecondary = false
        s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if (value as? NSColor) == .secondaryLabelColor { sawSecondary = true }
        }
        XCTAssertTrue(sawSecondary, "the hint run should be dimmed with secondaryLabelColor")
    }

    // Confirms the bundled dictionary actually carries hints for some
    // candidates — otherwise surfacing them would be a no-op.
    func testEngineEmitsHintsForSomeCandidate() {
        let engine = Engine()
        var sawHint = false
        for ch in "abcdefghijklmnopqrstuvwxyz".unicodeScalars {
            engine.pressKey(UInt8(ch.value))
            let window = engine.readRange(from: 0, count: 16)
            if window.contains(where: { ($0.hint?.isEmpty == false) }) {
                sawHint = true
                break
            }
            engine.reset()
        }
        XCTAssertTrue(sawHint, "expected at least one candidate with a non-empty hint")
    }

    // The formatter round-trip InputController.candidateSelected relies on:
    // a displayed string maps back to exactly one committable value.
    func testDisplayRoundTripsToValue() {
        let engine = Engine()
        engine.pressKey(UInt8(ascii: "j"))
        let window = engine.readRange(from: 0, count: 9)
        XCTAssertFalse(window.isEmpty)

        for candidate in window {
            let shown = CandidateFormatter.display(candidate).string
            let matched = window.first { CandidateFormatter.display($0).string == shown }
            XCTAssertEqual(matched?.value, candidate.value, "display string \(shown) mapped to the wrong value")
        }
    }
}
