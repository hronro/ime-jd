import XCTest

/// QA driver for the REAL keyboard extension (not part of the CI test scheme —
/// see the `JdKeyboardQA` scheme in project.yml).
///
/// `simctl` cannot synthesize touches, and third-party keyboards are
/// trust-gated behind the Settings enable flow (writing `AppleKeyboards` /
/// `KeyboardsCurrentAndNext` defaults registers the keyboard but the system
/// still refuses to present it). This test does the two tap-requiring steps —
/// enable in Settings, switch to 键道 via the globe key — then holds the
/// preview app open (in `-system` mode, so the field uses the real extension)
/// and drops a marker file so a host-side loop can take `simctl` screenshots.
///
///   TEST_RUNNER_JD_QA_MARKER=/path/to/marker \
///   xcodebuild test -project JdIME-iOS.xcodeproj -scheme JdKeyboardQA \
///     -destination "id=$UDID" -derivedDataPath build/DD
final class KeyboardExtensionQA: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnableAndShowExtension() throws {
        enableInSettingsIfNeeded()

        let app = XCUIApplication()
        app.launchArguments = ["-preview", "-system"]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        sleep(2)   // the field auto-focuses; give the keyboard the slide-in

        switchToJdViaGlobe(app)
        sleep(2)

        // Signal the host loop, then keep the scene alive while it screenshots
        // (it toggles light/dark appearance in between). The host removes the
        // marker when done; the timeout backstops a dead host loop.
        let marker = ProcessInfo.processInfo.environment["JD_QA_MARKER"] ?? "/tmp/jd-kb-qa-ready"
        FileManager.default.createFile(atPath: marker, contents: nil)
        for _ in 0..<120 where FileManager.default.fileExists(atPath: marker) { sleep(1) }
    }

    /// Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard ▸ 键道.
    /// Idempotent: skips adding when 键道 is already in the keyboards list.
    @MainActor
    private func enableInSettingsIfNeeded() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        // iOS 26 drops the "…" from the button; match the stable prefix.
        let addRow = settings.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Add New Keyboard")
        ).firstMatch
        // Settings can restore its last screen on relaunch — only navigate
        // when we aren't already sitting on the Keyboards list.
        if !addRow.waitForExistence(timeout: 3) {
            tapFirst(settings, "General")
            tapFirst(settings, "Keyboard")
            // The row is "Keyboards" (with a count); an exact match also exists
            // as the screen's title, so tap the CELL, not any static text.
            let keyboardsCell = settings.cells.containing(
                NSPredicate(format: "label BEGINSWITH %@", "Keyboards")
            ).firstMatch
            XCTAssertTrue(keyboardsCell.waitForExistence(timeout: 5), "Keyboards row not found")
            keyboardsCell.tap()
            XCTAssertTrue(addRow.waitForExistence(timeout: 5), "Keyboards list did not open")
        }

        let jdRow = settings.cells.containing(
            NSPredicate(format: "label CONTAINS %@", "键道")
        ).firstMatch
        if !jdRow.waitForExistence(timeout: 2) {
            addRow.tap()
            // THIRD-PARTY KEYBOARDS section lists the container app's name.
            tapFirst(settings, "键道")
            XCTAssertTrue(jdRow.waitForExistence(timeout: 5), "键道 was not added")
        }
        settings.terminate()
    }

    @MainActor
    private func tapFirst(_ app: XCUIApplication, _ label: String) {
        let el = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(el.waitForExistence(timeout: 8), "'\(label)' not found")
        el.tap()
    }

    /// Switch the current input mode to 键道 via the globe key, verified by
    /// our spacebar label (空格) appearing. Tap first (cycles modes); fall back
    /// to touch-and-hold + picking 键道 from the input-mode list.
    @MainActor
    private func switchToJdViaGlobe(_ app: XCUIApplication) {
        // The first-run "Quickly Change Keyboards" education sheet covers the
        // keyboard and eats the globe tap — dismiss it.
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 2) { cont.tap(); sleep(1) }

        let spacebar = app.staticTexts["空格"]
        // Already the current input mode (persists across runs) — done.
        if spacebar.waitForExistence(timeout: 1) { return }
        for _ in 0..<2 {
            globeCoordinate(app).tap()
            if spacebar.waitForExistence(timeout: 3) { return }
            globeCoordinate(app).press(forDuration: 1.5)
            let jd = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "键道")
            ).firstMatch
            if jd.waitForExistence(timeout: 3) {
                jd.tap()
                if spacebar.waitForExistence(timeout: 3) { return }
            }
        }
        XCTFail("did not switch to 键道")
    }

    /// The globe key: the system chin's button when addressable, else its
    /// fixed spot above the bottom-left corner (iOS 26 chin layout).
    @MainActor
    private func globeCoordinate(_ app: XCUIApplication) -> XCUICoordinate {
        for label in ["Next keyboard", "Next Keyboard", "NextKeyboard"] {
            let b = app.keyboards.buttons[label]
            if b.exists {
                return b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            }
        }
        return app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1))
            .withOffset(CGVector(dx: 42, dy: -41))
    }
}
