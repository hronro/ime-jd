import XCTest
@testable import JdIME

final class EngineSmokeTests: XCTestCase {
    func testInitAndDeinit() {
        let e = Engine(pageSize: 9)
        XCTAssertEqual(e.pageSize, 9)
        _ = e  // implicit deinit at scope end
    }

    func testPressKeyProducesOptions() {
        let engine = Engine(pageSize: 9)
        let r = engine.pressKey(UInt8(ascii: "b"))
        // 'b' should match prefixes in the embedded dictionary; expect at
        // least one candidate. If this asserts on a freshly trimmed dict,
        // pick another seed letter.
        XCTAssertGreaterThan(r.optionsCount, 0)
        XCTAssertFalse(r.options.isEmpty)
    }

    func testFollowUpKeyAdvances() {
        let engine = Engine(pageSize: 9)
        _ = engine.pressKey(UInt8(ascii: "b"))
        let r = engine.pressKey(UInt8(ascii: "a"))
        // Either there are still candidates, or the engine auto-committed.
        XCTAssertTrue(r.hasCandidates || r.hasCommit)
    }

    func testPunctuationCommitsAndAppends() {
        // 'n' starts a composition; '.' is in the engine's punctuation table
        // (. → 。), so it commits the top candidate and appends the Chinese
        // full stop in one step (e.g. 你。), per the engine's commit-and-append
        // rule for punctuation.
        let engine = Engine(pageSize: 9)
        let started = engine.pressKey(UInt8(ascii: "n"))
        XCTAssertTrue(started.hasCandidates, "'n' should produce candidates")

        let r = engine.pressKey(UInt8(ascii: "."))
        XCTAssertNotNil(r.commit, "punctuation should commit")
        let commit = r.commit ?? ""
        XCTAssertTrue(commit.hasSuffix("。"), "commit should end with the Chinese full stop: \(commit)")
        XCTAssertGreaterThan(commit.count, 1, "commit should be candidate + 。: \(commit)")
    }

    func testPunctuationCommitsFromRoot() {
        // With no composition in flight, '.' alone resolves to 。 — the
        // behavior the IME relies on so a bare '.' yields 。 rather than '.'.
        let engine = Engine(pageSize: 9)
        let r = engine.pressKey(UInt8(ascii: "."))
        XCTAssertEqual(r.commit, "。")
        XCTAssertTrue(r.options.isEmpty)
    }

    func testBackspaceDoesNotCrash() {
        let engine = Engine(pageSize: 9)
        _ = engine.pressKey(UInt8(ascii: "b"))
        let r = engine.backspace()
        _ = r  // just observe no crash
    }

    func testResetClearsState() {
        let engine = Engine(pageSize: 9)
        _ = engine.pressKey(UInt8(ascii: "b"))
        engine.reset()
        // After reset, the engine should be back to an empty state; pressing
        // 'b' again should look like a fresh start.
        let r = engine.pressKey(UInt8(ascii: "b"))
        XCTAssertGreaterThan(r.optionsCount, 0)
    }

    func testMultipleContextsAreIndependent() {
        let a = Engine(pageSize: 9)
        let b = Engine(pageSize: 9)
        _ = a.pressKey(UInt8(ascii: "b"))
        let bResult = b.pressKey(UInt8(ascii: "n"))
        // b's context shouldn't see a's 'b' keystroke
        XCTAssertTrue(bResult.hasCandidates || bResult.hasCommit)
    }

    func testPaginationBoundaries() {
        let engine = Engine(pageSize: 9)
        let r1 = engine.pressKey(UInt8(ascii: "b"))
        if r1.totalPages > 1 {
            let r2 = engine.nextPage()
            XCTAssertEqual(r2.currentPage, 2)
            let r3 = engine.prevPage()
            XCTAssertEqual(r3.currentPage, 1)
        }
    }
}
