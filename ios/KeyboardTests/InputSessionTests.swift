import XCTest

// The engine + session sources are compiled into this test bundle directly
// (see ios/project.yml), so no module import is needed.

private final class MockHost: KeyboardHost {
    var inserted: [String] = []
    var deletes = 0
    func insertText(_ text: String) { inserted.append(text) }
    func deleteBackward() { deletes += 1 }
    var joined: String { inserted.joined() }
}

final class InputSessionTests: XCTestCase {
    private func makeSession() -> (InputSession, MockHost) {
        let s = InputSession(pageSize: 9)
        let h = MockHost()
        s.host = h
        return (s, h)
    }

    /// A letter starts a composition shown in the keyboard's own bar — nothing
    /// must leak to the host until commit (the cardinal iOS rule).
    func testLetterStartsCompositionWithoutInserting() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "n")))
        XCTAssertTrue(s.isComposing)
        XCTAssertFalse(s.snapshot.options.isEmpty)
        XCTAssertEqual(h.inserted, [], "composition must not leak to the host")
        XCTAssertEqual(s.rawBuffer, "n")
    }

    /// Bare '.' resolves to the Chinese full stop via the engine's punctuation table.
    func testBarePunctuationCommitsToHost() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: ".")))
        XCTAssertEqual(h.joined, "。")
        XCTAssertFalse(s.isComposing)
    }

    /// 'n' then '.' commits the top candidate AND appends 。 in one step.
    func testPunctuationCommitsAndAppendsAfterComposition() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "n")))
        s.handle(.engineKey(UInt8(ascii: ".")))
        XCTAssertTrue(h.joined.hasSuffix("。"), "got \(h.joined)")
        XCTAssertGreaterThan(h.joined.count, 1)
        XCTAssertFalse(s.isComposing)
    }

    func testSelectVisibleCommitsCandidate() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        let first = s.snapshot.options.first!.value
        s.handle(.selectIdx(0))
        XCTAssertEqual(h.joined, first)
        XCTAssertFalse(s.isComposing)
    }

    func testBackspaceWhileComposingDoesNotTouchHost() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        XCTAssertTrue(s.isComposing)
        s.handle(.backspace)
        XCTAssertEqual(h.deletes, 0, "deleting composition must not delete host text")
        XCTAssertFalse(s.isComposing)
    }

    func testBackspaceWithoutCompositionDeletesHostChar() {
        let (s, h) = makeSession()
        s.handle(.backspace)
        XCTAssertEqual(h.deletes, 1)
        XCTAssertEqual(h.inserted, [])
    }

    func testCommitRawEmitsRawBuffer() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        s.handle(.commitRaw)
        XCTAssertEqual(h.joined, "b")
        XCTAssertFalse(s.isComposing)
    }

    func testCancelResetClearsWithoutInserting() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        s.cancelAndReset()
        XCTAssertFalse(s.isComposing)
        XCTAssertEqual(h.inserted, [])
    }

    func testOnChangeFiresOnKey() {
        let (s, _) = makeSession()
        var calls = 0
        s.onChange = { _, _ in calls += 1 }
        s.handle(.engineKey(UInt8(ascii: "b")))
        XCTAssertGreaterThan(calls, 0)
    }

    func testInsertLiteralWhenNotComposingInsertsDirectly() {
        let (s, h) = makeSession()
        s.insertLiteral("。")
        XCTAssertEqual(h.joined, "。")
        XCTAssertFalse(s.isComposing)
    }

    func testInsertLiteralWhileComposingCommitsTopThenAppends() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "n")))
        let top = s.snapshot.options.first!.value
        s.insertLiteral("。")
        // Matches libjd: top candidate committed, then the punctuation appended.
        XCTAssertEqual(h.joined, top + "。")
        XCTAssertFalse(s.isComposing)
    }

    func testSpaceCommitsTopCandidate() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "n")))
        XCTAssertTrue(s.isComposing)
        s.handle(.engineKey(0x20))   // space → engine commits top candidate, appends nothing
        XCTAssertFalse(h.joined.isEmpty, "space should commit the top candidate")
        XCTAssertFalse(s.isComposing)
    }

    // MARK: - Lazy pagination (prefetch must not move the engine's page)

    /// Regression: engine auto-commits (space, drill-in, punctuation fallback)
    /// act on the first option of the engine's CURRENT page. Prefetching pages
    /// for the strip must park the engine back on the visible page, or space
    /// commits a candidate the user isn't looking at.
    func testSpaceCommitsFirstVisibleCandidateAfterPrefetch() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "a")))   // 'a' has > 9 candidates → multi-page
        XCTAssertGreaterThan(s.snapshot.totalPages, 1, "test needs a multi-page code")
        let firstVisible = s.snapshot.options.first!.value
        XCTAssertNotNil(s.loadMoreCandidates(), "prefetch should return a page")
        s.handle(.engineKey(0x20))
        XCTAssertEqual(h.joined, firstVisible)
    }

    /// Same property for the punctuation bypass (insertLiteral presses space).
    func testInsertLiteralCommitsFirstVisibleCandidateAfterPrefetch() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "a")))
        let firstVisible = s.snapshot.options.first!.value
        _ = s.loadMoreCandidates()
        s.insertLiteral("。")
        XCTAssertEqual(h.joined, firstVisible + "。")
    }

    /// Prefetch feeds an append-only strip whose first page stays on screen, so
    /// it must not touch the published snapshot.
    func testPrefetchLeavesSnapshotUntouched() {
        let (s, _) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "a")))
        let before = s.snapshot
        _ = s.loadMoreCandidates()
        XCTAssertEqual(s.snapshot, before)
    }

    /// Consecutive prefetches walk each remaining page exactly once, then stop.
    func testLoadMoreWalksAllPagesThenStops() {
        let (s, _) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "a")))
        let total = Int(s.snapshot.optionsCount)
        let totalPages = Int(s.snapshot.totalPages)
        var seen = s.snapshot.options.count
        var fetches = 0
        while let more = s.loadMoreCandidates() {
            seen += more.count
            fetches += 1
            XCTAssertLessThanOrEqual(fetches, totalPages, "prefetch ran past the page count")
        }
        XCTAssertEqual(fetches, totalPages - 1, "each remaining page should be fetched exactly once")
        XCTAssertEqual(seen, total, "prefetch should surface every candidate exactly once")
    }
}
