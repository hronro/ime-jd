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
        let s = InputSession()
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
        XCTAssertFalse(s.snapshot.candidates.isEmpty)
        XCTAssertGreaterThan(s.snapshot.optionsCount, 0)
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
        let first = s.snapshot.candidates.first!.value
        s.handle(.selectIdx(0))
        XCTAssertEqual(h.joined, first)
        XCTAssertFalse(s.isComposing)
    }

    /// The session tracks everything the bar has loaded, so a tap on a
    /// scrolled-in candidate resolves too — not just the first window.
    func testSelectVisibleReachesScrolledInCandidates() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        let firstWindow = s.snapshot.candidates.count
        XCTAssertNotNil(s.loadMoreCandidates())
        XCTAssertGreaterThan(s.snapshot.candidates.count, firstWindow)

        let scrolledIn = s.snapshot.candidates[firstWindow]
        s.handle(.selectIdx(firstWindow))
        XCTAssertEqual(h.joined, scrolledIn.value)
    }

    func testBackspaceWhileComposingDoesNotTouchHost() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        XCTAssertTrue(s.isComposing)
        s.handle(.backspace)
        XCTAssertEqual(h.deletes, 0, "deleting composition must not delete host text")
        XCTAssertFalse(s.isComposing)
        XCTAssertEqual(s.snapshot.optionsCount, 0)
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
        XCTAssertEqual(s.snapshot, .empty)
        XCTAssertEqual(h.inserted, [])
    }

    func testOnChangeFiresOnKey() {
        let (s, _) = makeSession()
        var calls = 0
        s.onChange = { _ in calls += 1 }
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
        let top = s.snapshot.candidates.first!.value
        s.insertLiteral("。")
        // Matches libjd: top candidate committed, then the punctuation appended.
        XCTAssertEqual(h.joined, top + "。")
        XCTAssertFalse(s.isComposing)
    }

    func testSpaceCommitsTopCandidate() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "n")))
        XCTAssertTrue(s.isComposing)
        s.handle(.engineKey(0x20))   // space → engine commits the anchor, appends nothing
        XCTAssertEqual(h.joined, "你", "space should commit the top candidate for 'n'")
        XCTAssertFalse(s.isComposing)
    }

    // MARK: - Lazy loading
    //
    // Under the old page-based ABI, prefetching moved the engine's only cursor,
    // which doubled as the commit anchor — so the strip had to jump the engine
    // back or space would commit a candidate the user wasn't looking at. Reads
    // are pure now, but the *property* is what matters, so these stay.

    func testSpaceCommitsFirstVisibleCandidateAfterPrefetch() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        let firstVisible = s.snapshot.candidates.first!.value
        XCTAssertNotNil(s.loadMoreCandidates(), "prefetch should return candidates")
        XCTAssertNotNil(s.loadMoreCandidates())
        s.handle(.engineKey(0x20))
        XCTAssertEqual(h.joined, firstVisible)
    }

    /// Same property for the punctuation bypass (insertLiteral presses space).
    func testInsertLiteralCommitsFirstVisibleCandidateAfterPrefetch() {
        let (s, h) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        let firstVisible = s.snapshot.candidates.first!.value
        _ = s.loadMoreCandidates()
        s.insertLiteral("。")
        XCTAssertEqual(h.joined, firstVisible + "。")
    }

    /// The bar appends prefetched candidates itself and keeps what's on screen,
    /// so a prefetch must extend the loaded list without re-rendering it.
    func testPrefetchAppendsWithoutFiringOnChange() {
        let (s, _) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        let before = s.snapshot.candidates

        var calls = 0
        s.onChange = { _ in calls += 1 }
        let more = s.loadMoreCandidates()

        XCTAssertEqual(calls, 0, "prefetch must not re-render the bar")
        XCTAssertNotNil(more)
        // The already-shown prefix is unchanged; the new candidates are appended.
        XCTAssertEqual(Array(s.snapshot.candidates.prefix(before.count)), before)
        XCTAssertEqual(s.snapshot.candidates.count, before.count + more!.count)
    }

    /// Consecutive prefetches surface each remaining candidate exactly once,
    /// then stop. 'a' is small enough (29 candidates) to walk exhaustively.
    func testLoadMoreWalksEveryCandidateThenStops() {
        let (s, _) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "a")))
        let total = Int(s.snapshot.optionsCount)
        XCTAssertGreaterThan(total, Int(s.snapshot.candidates.count),
                             "test needs a code with more candidates than one window")

        var fetches = 0
        while let more = s.loadMoreCandidates() {
            XCTAssertFalse(more.isEmpty)
            fetches += 1
            XCTAssertLessThanOrEqual(fetches, total, "prefetch ran past the candidate count")
        }
        XCTAssertGreaterThan(fetches, 0)
        XCTAssertEqual(s.snapshot.candidates.count, total,
                       "prefetch should surface every candidate exactly once")

        // Values must be distinct positions in the engine's list, in order.
        let reread = InputSession()
        reread.handle(.engineKey(UInt8(ascii: "a")))
        while reread.loadMoreCandidates() != nil {}
        XCTAssertEqual(s.snapshot.candidates.map(\.value),
                       reread.snapshot.candidates.map(\.value))
    }

    /// A new keystroke resets the loaded list — the strip starts over.
    func testNewKeystrokeResetsTheLoadedList() {
        let (s, _) = makeSession()
        s.handle(.engineKey(UInt8(ascii: "b")))
        _ = s.loadMoreCandidates()
        let grown = s.snapshot.candidates.count

        s.handle(.engineKey(UInt8(ascii: "a")))
        XCTAssertLessThan(s.snapshot.candidates.count, grown)
        XCTAssertEqual(s.rawBuffer, "ba")
    }
}
