import XCTest

/// When a change the host reports means the caret left where the keyboard was
/// typing (and the composition must go) — see HostEditTracker.
final class HostEditTrackerTests: XCTestCase {
    private let late = HostEditTracker.echoGrace + 1

    func testOwnEditsEchoIsNotAMove() {
        var t = HostEditTracker()
        t.inserted("那", at: 10)
        // Whatever the host reports right after, it is our echo.
        XCTAssertFalse(t.caretMoved(contextBefore: "something else", at: 10.05))
        XCTAssertFalse(t.caretMoved(contextBefore: nil, at: 10.05))
    }

    func testCompletionAfterTheCaretIsNotAMove() {
        // Safari completes a second later; the text before the caret still
        // ends with what we typed.
        var t = HostEditTracker()
        t.inserted("你好", at: 10)
        XCTAssertFalse(t.caretMoved(contextBefore: "说你好", at: 10 + late))
    }

    func testHostCatchingUpOnEarlierEditsIsNotAMove() {
        var t = HostEditTracker()
        t.inserted("那", at: 10)
        t.inserted("你们", at: 10.1)
        // A late change that does not show our last insert yet.
        XCTAssertFalse(t.caretMoved(contextBefore: "那", at: 10.1 + late))
        XCTAssertFalse(t.caretMoved(contextBefore: "那你们", at: 10.1 + late))
    }

    func testCaretElsewhereIsAMove() {
        var t = HostEditTracker()
        t.inserted("你好", at: 10)
        XCTAssertTrue(t.caretMoved(contextBefore: "别的地方", at: 10 + late))
        XCTAssertTrue(t.caretMoved(contextBefore: "", at: 10 + late))
    }

    func testCaretAtTheStartIsAMove() {
        // iOS reports no text before a caret at the start of the field; the
        // text after it shows the field is not empty.
        var t = HostEditTracker()
        t.inserted("你好", at: 10)
        XCTAssertTrue(t.caretMoved(contextBefore: nil, contextAfter: "那你好", at: 10 + late))
    }

    func testDeletesFollowTheText() {
        var t = HostEditTracker()
        t.inserted("你好吗", at: 10)
        t.deletedBackward(at: 10.1)
        XCTAssertFalse(t.caretMoved(contextBefore: "说你好", at: 10.1 + late))
    }

    func testOnlyTheTailIsCompared() {
        var t = HostEditTracker()
        let long = String(repeating: "字", count: 40)
        t.inserted(long, at: 10)
        // The host's context may be cut short at the front.
        XCTAssertFalse(t.caretMoved(contextBefore: String(long.suffix(20)), at: 10 + late))
    }

    func testUnknownFallsBackToTheEchoWindow() {
        var t = HostEditTracker()
        // Nothing typed yet in this presentation.
        XCTAssertTrue(t.caretMoved(contextBefore: "abc", at: 10))
        // A new line: the text before the caret starts afresh.
        t.inserted("你好\n", at: 20)
        XCTAssertFalse(t.caretMoved(contextBefore: "", at: 20.05))
        XCTAssertTrue(t.caretMoved(contextBefore: "", at: 20 + late))
    }

    func testHostSharingNoTextOnlyMovesOnAnotherField() {
        // Safari's address bar: no text around the caret, and a change
        // reported about a second after each insert.
        let bar = UUID(), page = UUID()
        var t = HostEditTracker()
        t.inserted("好", into: bar, at: 30)
        XCTAssertFalse(t.caretMoved(contextBefore: nil, document: bar, at: 31))
        XCTAssertFalse(t.caretMoved(contextBefore: nil, document: bar, at: 60))
        // Nothing typed yet there either.
        var fresh = HostEditTracker()
        XCTAssertFalse(fresh.caretMoved(contextBefore: nil, document: bar, at: 5))
        // A switch to another field always counts, even right after our edit.
        XCTAssertTrue(t.caretMoved(contextBefore: nil, document: page, at: 60.05))
    }

    func testAnotherFieldForgetsWhatWasTyped() {
        let one = UUID(), two = UUID()
        var t = HostEditTracker()
        t.inserted("你好", into: one, at: 10)
        XCTAssertTrue(t.caretMoved(contextBefore: "你好", document: two, at: 10 + late))
        // In the new field, what was typed in the old one proves nothing.
        XCTAssertTrue(t.caretMoved(contextBefore: "你好", document: two, at: 20 + late))
        t.inserted("吗", into: two, at: 30)
        XCTAssertFalse(t.caretMoved(contextBefore: "你好吗", document: two, at: 30 + late))
    }

    func testForgetting() {
        var t = HostEditTracker()
        t.inserted("你好", at: 10)
        t.forget()
        XCTAssertTrue(t.caretMoved(contextBefore: "你好", at: 10 + late))
        // Typing again starts from what is typed after.
        t.inserted("吗", at: 20)
        XCTAssertFalse(t.caretMoved(contextBefore: "随便吗", at: 20 + late))
    }
}
