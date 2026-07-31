import XCTest
@testable import JdIME

final class EngineSmokeTests: XCTestCase {
    func testInitAndDeinit() {
        let e = Engine()
        XCTAssertEqual(e.state.optionsCount, 0)
        _ = e  // implicit deinit at scope end
    }

    func testPressKeyProducesCandidates() {
        let engine = Engine()
        let state = engine.pressKey(UInt8(ascii: "b"))
        // 'b' should match prefixes in the embedded dictionary; expect at
        // least one candidate. If this asserts on a freshly trimmed dict,
        // pick another seed letter.
        XCTAssertGreaterThan(state.optionsCount, 0)
        XCTAssertEqual(state.anchorIndex, 0)
        XCTAssertFalse(engine.readRange(from: 0, count: 9).isEmpty)
    }

    func testFollowUpKeyAdvances() {
        let engine = Engine()
        engine.pressKey(UInt8(ascii: "b"))
        let state = engine.pressKey(UInt8(ascii: "a"))
        // Either there are still candidates, or the engine auto-committed.
        XCTAssertTrue(state.isComposing || state.hasCommit)
    }

    func testPunctuationCommitsAndAppends() {
        // 'n' starts a composition; '.' is in the engine's punctuation table
        // (. → 。), so it commits the anchor candidate and appends the Chinese
        // full stop in one step (e.g. 你。), per the engine's commit-and-append
        // rule for punctuation.
        let engine = Engine()
        let started = engine.pressKey(UInt8(ascii: "n"))
        XCTAssertTrue(started.isComposing, "'n' should produce candidates")

        let state = engine.pressKey(UInt8(ascii: "."))
        XCTAssertNotNil(state.commit, "punctuation should commit")
        let commit = state.commit ?? ""
        XCTAssertTrue(commit.hasSuffix("。"), "commit should end with the Chinese full stop: \(commit)")
        XCTAssertGreaterThan(commit.count, 1, "commit should be candidate + 。: \(commit)")
    }

    func testPunctuationCommitsFromRoot() {
        // With no composition in flight, '.' alone resolves to 。 — the
        // behavior the IME relies on so a bare '.' yields 。 rather than '.'.
        let engine = Engine()
        let state = engine.pressKey(UInt8(ascii: "."))
        XCTAssertEqual(state.commit, "。")
        XCTAssertEqual(state.optionsCount, 0)
    }

    func testBackspaceDoesNotCrash() {
        let engine = Engine()
        engine.pressKey(UInt8(ascii: "b"))
        let state = engine.backspace()
        XCTAssertNil(state.commit, "backspace never commits")
    }

    func testResetClearsState() {
        let engine = Engine()
        engine.pressKey(UInt8(ascii: "b"))
        let cleared = engine.reset()
        XCTAssertNil(cleared.commit)
        XCTAssertEqual(cleared.optionsCount, 0)
        // After reset, pressing 'b' again should look like a fresh start.
        XCTAssertGreaterThan(engine.pressKey(UInt8(ascii: "b")).optionsCount, 0)
    }

    func testMultipleContextsAreIndependent() {
        let a = Engine()
        let b = Engine()
        a.pressKey(UInt8(ascii: "b"))
        let bState = b.pressKey(UInt8(ascii: "n"))
        // b's context shouldn't see a's 'b' keystroke.
        XCTAssertTrue(bState.isComposing || bState.hasCommit)
    }

    func testReadRangeClipsAndDoesNotMoveTheAnchor() {
        let engine = Engine()
        let state = engine.pressKey(UInt8(ascii: "j"))
        let total = state.optionsCount
        XCTAssertGreaterThan(total, 100, "expected a long candidate list for 'j'")

        // A window is clipped by the total, never padded.
        XCTAssertEqual(UInt32(engine.readRange(from: 0, count: Int(total) + 50).count), total)
        XCTAssertTrue(engine.readRange(from: total, count: 5).isEmpty)
        XCTAssertTrue(engine.readRange(from: 0, count: 0).isEmpty)

        // Reading is pure: the anchor stays put, so space still commits the
        // candidate the user is looking at.
        let anchorValue = engine.readRange(from: 0, count: 1).first?.value
        _ = engine.readRange(from: total - 8, count: 8)
        XCTAssertEqual(engine.state.anchorIndex, 0)
        XCTAssertEqual(engine.pressKey(UInt8(ascii: " ")).commit, anchorValue)
    }

    func testSetAnchorMovesWhatSpaceCommits() {
        let engine = Engine()
        engine.pressKey(UInt8(ascii: "j"))
        let target = engine.readRange(from: 9, count: 1).first?.value

        let state = engine.setAnchor(9)
        XCTAssertEqual(state.anchorIndex, 9)
        XCTAssertEqual(engine.pressKey(UInt8(ascii: " ")).commit, target)
    }

    func testSetAnchorIgnoresOutOfRange() {
        let engine = Engine()
        let total = engine.pressKey(UInt8(ascii: "j")).optionsCount
        engine.setAnchor(4)
        engine.setAnchor(total) // one past the end
        XCTAssertEqual(engine.state.anchorIndex, 4)
        engine.setAnchor(.max)
        XCTAssertEqual(engine.state.anchorIndex, 4)
    }

    func testCandidatesSurviveLaterCalls() {
        // Candidate values point into libjd's embedded blob, so a list needs no
        // copying and stays readable across any number of later engine calls.
        let engine = Engine()
        engine.pressKey(UInt8(ascii: "b"))
        let held = engine.readRange(from: 0, count: 4)
        let before = held.map(\.value)

        engine.pressKey(UInt8(ascii: "a"))
        engine.backspace()
        engine.reset()
        engine.pressKey(UInt8(ascii: "z"))
        _ = engine.readRange(from: 0, count: 40)

        XCTAssertEqual(held.map(\.value), before)
    }
}
