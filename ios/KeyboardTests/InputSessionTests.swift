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
}
