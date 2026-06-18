import XCTest
import AppKit
@testable import JdIME

final class KeyGateTests: XCTestCase {

    private func event(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // MARK: - Not composing

    func testLowercaseStartsComposition() {
        let e = event(keyCode: 0, characters: "a")
        XCTAssertEqual(keyAction(event: e, isComposing: false), .engineKey(0x61))
    }

    func testUppercasePassesThroughWhenNotComposing() {
        let e = event(keyCode: 0, characters: "A", modifiers: .shift)
        XCTAssertEqual(keyAction(event: e, isComposing: false), .passthrough)
    }

    func testDigitNotComposingPassesThrough() {
        let e = event(keyCode: 0, characters: "1")
        XCTAssertEqual(keyAction(event: e, isComposing: false), .passthrough)
    }

    func testCommandChordPassesThrough() {
        let e = event(keyCode: 0, characters: "v", modifiers: .command)
        XCTAssertEqual(keyAction(event: e, isComposing: false), .passthrough)
        XCTAssertEqual(keyAction(event: e, isComposing: true), .passthrough)
    }

    func testControlChordPassesThrough() {
        let e = event(keyCode: 0, characters: "a", modifiers: .control)
        XCTAssertEqual(keyAction(event: e, isComposing: true), .passthrough)
    }

    func testOptionChordPassesThrough() {
        let e = event(keyCode: 0, characters: "a", modifiers: .option)
        XCTAssertEqual(keyAction(event: e, isComposing: true), .passthrough)
    }

    // MARK: - Composing

    func testLowercaseWhileComposing() {
        let e = event(keyCode: 0, characters: "a")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .engineKey(0x61))
    }

    func testSpaceWhileComposing() {
        let e = event(keyCode: KeyCode.space, characters: " ")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .engineKey(0x20))
    }

    func testSemicolonWhileComposing() {
        let e = event(keyCode: 0, characters: ";")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .engineKey(0x3B))
    }

    func testDigitSelectsCandidate() {
        let e = event(keyCode: 0, characters: "1")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .selectIdx(0))
        let e9 = event(keyCode: 0, characters: "9")
        XCTAssertEqual(keyAction(event: e9, isComposing: true), .selectIdx(8))
    }

    func testShiftDigitGoesToEngine() {
        // Shift+1 = '!' — NOT a candidate selector; it's punctuation, so it
        // goes to the engine (commits the current candidate, appends '!').
        let e = event(keyCode: 0, characters: "!", modifiers: .shift)
        XCTAssertEqual(keyAction(event: e, isComposing: true), .engineKey(0x21))
    }

    func testPeriodWhileComposingGoesToEngine() {
        // Regression: 'n' then '.' must yield 你. — the '.' must reach the
        // engine to commit-and-append, not pass through as a bare literal.
        let e = event(keyCode: 47, characters: ".")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .engineKey(0x2E))
    }

    func testCommaWhileComposingGoesToEngine() {
        let e = event(keyCode: 43, characters: ",")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .engineKey(0x2C))
    }

    func testPeriodWhileNotComposingPassesThrough() {
        let e = event(keyCode: 47, characters: ".")
        XCTAssertEqual(keyAction(event: e, isComposing: false), .passthrough)
    }

    func testEscapeCancels() {
        let e = event(keyCode: KeyCode.escape, characters: "\u{1b}")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .escape)
    }

    func testDeleteBackspaces() {
        let e = event(keyCode: KeyCode.delete, characters: "\u{7f}")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .backspace)
    }

    func testReturnCommitsRaw() {
        let e = event(keyCode: KeyCode.return, characters: "\r")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .commitRaw)
    }

    func testLeftArrowPagesPrev() {
        let e = event(keyCode: KeyCode.leftArrow, characters: "\u{1c}")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .pagePrev)
    }

    func testRightArrowPagesNext() {
        let e = event(keyCode: KeyCode.rightArrow, characters: "\u{1d}")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .pageNext)
    }

    func testUpArrowPagesPrev() {
        let e = event(keyCode: KeyCode.upArrow, characters: "\u{1e}")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .pagePrev)
    }

    func testDownArrowPagesNext() {
        let e = event(keyCode: KeyCode.downArrow, characters: "\u{1f}")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .pageNext)
    }

    func testMinusPagesPrev() {
        let e = event(keyCode: 0, characters: "-")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .pagePrev)
    }

    func testEqualsPagesNext() {
        let e = event(keyCode: 0, characters: "=")
        XCTAssertEqual(keyAction(event: e, isComposing: true), .pageNext)
    }

    func testShiftEqualsGoesToEngine() {
        // Shift+= = '+' — NOT a page binding; punctuation goes to the engine
        // (commits the current candidate, appends '+').
        let e = event(keyCode: 0, characters: "+", modifiers: .shift)
        XCTAssertEqual(keyAction(event: e, isComposing: true), .engineKey(0x2B))
    }
}
