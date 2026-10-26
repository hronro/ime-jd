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
///
/// `TEST_RUNNER_JD_QA_ARGS="-field numberPad"` forwards extra launch args
/// (space-separated) to the preview app, e.g. to present the extension over a
/// numeric field.
final class KeyboardExtensionQA: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnableAndShowExtension() throws {
        enableInSettingsIfNeeded()

        let app = XCUIApplication()
        app.launchArguments = ["-preview", "-system"] + extraLaunchArguments()
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

    /// Audio QA (opt-in): real touches over letter / delete / modifier keys
    /// and a candidate cell, so key-click playback can be verified from the
    /// extension sandbox (host greps a `log stream` of the audio daemons, or
    /// listens on a device). Skipped unless JD_QA_AUDIO=1 so the screenshot
    /// loop's plain scheme run is unaffected:
    ///
    ///   TEST_RUNNER_JD_QA_AUDIO=1 xcodebuild test … -scheme JdKeyboardQA \
    ///     -only-testing:JdKeyboardUITests/KeyboardExtensionQA/testTypeKeysForAudioQA
    @MainActor
    func testTypeKeysForAudioQA() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JD_QA_AUDIO"] == "1")
        enableInSettingsIfNeeded()

        let app = XCUIApplication()
        app.launchArguments = ["-preview", "-system"]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        switchToJdViaGlobe(app)
        sleep(1)

        // Ordered so key labels stay unambiguous: the candidate bar's
        // composing label also reads "a", but it's only on screen between
        // typing a letter and the commit/delete that follows.
        tapKey(app, "a")    // input click; composes "a"
        tapKey(app, "⌫")    // delete click; bar empties
        tapKey(app, "a")    // input click; candidates reappear
        let cand = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "那")).firstMatch
        if cand.waitForExistence(timeout: 2) {   // input click via select()
            cand.tap()
            Thread.sleep(forTimeInterval: 0.4)
        }
        tapKey(app, "123")   // modifier click; plane switch
        tapKey(app, "ABC")   // modifier click; back to letters
        tapKey(app, "空格")  // modifier click
        sleep(1)
    }

    /// User-dictionary QA (opt-in): seed a phrase through the `-userdict`
    /// launch arg, check the list screen shows it with the engine's verdict
    /// on a bad row, then type its code on the REAL extension and expect the
    /// phrase in the extension's candidate bar and, on the last key, in the
    /// field — the App Group hand-off end to end. The simulator is
    /// unconfined, so this proves the plumbing, not the sandbox policy
    /// (see README, User dictionary).
    ///
    ///   TEST_RUNNER_JD_QA_USERDICT=1 xcodebuild test … -scheme JdKeyboardQA \
    ///     -only-testing:JdKeyboardUITests/KeyboardExtensionQA/testUserDictReachesTheExtension
    @MainActor
    func testUserDictReachesTheExtension() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JD_QA_USERDICT"] == "1")
        enableInSettingsIfNeeded()
        let seed = "键道\tzzzzzz;乙\tZZZZZA"

        // The list: the seeded rows, the bad one flagged, the switch on.
        let app = XCUIApplication()
        app.launchArguments = ["-userdict", seed]
        app.launch()
        tapFirst(app, "用户自造词")
        XCTAssertTrue(app.staticTexts["键道"].waitForExistence(timeout: 5), "seeded row")
        XCTAssertTrue(app.staticTexts["zzzzzz"].exists, "its code")
        XCTAssertTrue(app.staticTexts["ZZZZZA  ·  编码无效（1 到 6 个 a-z），不生效"].exists, "the engine's verdict")
        XCTAssertEqual(app.switches.firstMatch.value as? String, "1", "switched on")

        // The real extension over the preview's field: the code composes the
        // phrase, and the sixth key auto-commits it.
        app.launchArguments = ["-preview", "-system", "-userdict", seed]
        app.launch()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        switchToJdViaGlobe(app)
        sleep(1)
        for _ in 0..<5 { tapKey(app, "z") }
        // Hold for the host's screenshot before judging, so a failure leaves
        // a picture of the bar behind.
        let marker = ProcessInfo.processInfo.environment["JD_QA_MARKER"] ?? "/tmp/jd-kb-qa-ready"
        FileManager.default.createFile(atPath: marker, contents: nil)
        for _ in 0..<60 where FileManager.default.fileExists(atPath: marker) { sleep(1) }
        let candidate = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "键道")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 3), "the user phrase is not in the extension's candidate bar")
        tapKey(app, "z")
        XCTAssertTrue(((app.textViews.firstMatch.value as? String) ?? "").contains("键道"), "not committed")
    }

    /// The import: a phrases file the host planted in Files' "On My iPhone"
    /// (the simulator's local file-provider storage — see README) is picked
    /// through the list's Files picker and appended to the seeded list; the
    /// repeat that makes is flagged by the engine and removed with
    /// 移除重复词条.
    ///
    ///     TEST_RUNNER_JD_QA_IMPORT=用户自造词.txt xcodebuild test … \
    ///         -only-testing:JdKeyboardUITests/KeyboardExtensionQA/testImportFromFiles
    ///
    /// With TEST_RUNNER_JD_QA_DUMP=<path>, the app's element tree is written
    /// there at each step of the picker, for when the picker's labels move;
    /// with TEST_RUNNER_JD_QA_MARKER=<path> it holds at `<path>-imported` and
    /// `<path>-deduped` for the host's screenshots.
    @MainActor
    func testImportFromFiles() throws {
        guard let fileName = ProcessInfo.processInfo.environment["JD_QA_IMPORT"], !fileName.isEmpty else {
            throw XCTSkip("set JD_QA_IMPORT to the planted file's name")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-userdict", "键道\tzzzzzz;乙\tZZZZZA"]
        app.launch()
        tapFirst(app, "用户自造词")
        XCTAssertTrue(app.staticTexts["键道"].waitForExistence(timeout: 5), "seeded row")
        tapFirst(app, "从文件导入…")

        // The picker (a remote view, but its elements are in our tree):
        // Browse ▸ On My iPhone ▸ the file. It opens where it was last —
        // Recents, Browse's locations, or inside On My iPhone — so take
        // whichever step is on screen until the file is. The file's cell
        // carries its name, type, date and size as its own label
        // ("用户自造词, txt, 12:38 PM, 154 bytes"); match the cell's label,
        // not a descendant's, since the list's cells under the sheet hold
        // texts that contain the same name.
        let stem = (fileName as NSString).deletingPathExtension
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", stem + ",")).firstMatch
        let location = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "On My iPhone")).firstMatch
        // Inside a location the back button is named "Browse" too; the tab
        // is the lowest on screen.
        let browseButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Browse"))
        for step in 1...4 where !file.waitForExistence(timeout: 4) {
            dump(app, "picker-\(step)")
            if location.exists {
                location.tap()
            } else if let tab = browseButtons.allElementsBoundByIndex.max(by: { $0.frame.minY < $1.frame.minY }) {
                tab.tap()
            }
        }
        XCTAssertTrue(file.exists, "'\(fileName)' not in the picker")
        file.tap()

        // Appended as it is, nothing asked: the file's 键道 repeats the
        // seeded one and the engine flags it; 导入词 is new.
        XCTAssertTrue(app.staticTexts["导入词"].waitForExistence(timeout: 10), "the imported row")
        XCTAssertTrue(app.staticTexts["zzzzzb"].exists, "its code")
        XCTAssertTrue(app.staticTexts["zzzzzz  ·  与第 1 条重复，不生效"].exists, "the repeat, flagged by the engine")
        XCTAssertTrue(app.staticTexts["2 条生效，1 条无效，1 条重复"].exists, "the footer")
        dump(app, "imported")
        hold("imported")

        // 移除重复词条: the confirmation counts it, and only it goes.
        tapFirst(app, "移除重复词条")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no confirmation")
        XCTAssertTrue(alert.staticTexts["移除 1 条重复词条？"].exists, "the confirmation's count")
        XCTAssertTrue(alert.staticTexts["1 条与前面的词条相同，0 条与内置词相同；这些词条不会出现在候选中。"].exists, "what it repeats")
        alert.buttons["移除"].tap()
        XCTAssertTrue(app.staticTexts["2 条生效，1 条无效"].waitForExistence(timeout: 5), "the footer after")
        XCTAssertFalse(app.staticTexts["zzzzzz  ·  与第 1 条重复，不生效"].exists, "the repeat is gone")
        XCTAssertTrue(app.staticTexts["zzzzzz"].exists, "the first 键道 stays")
        XCTAssertTrue(app.staticTexts["导入词"].exists, "so does the imported row")
        XCTAssertTrue(app.staticTexts["ZZZZZA  ·  编码无效（1 到 6 个 a-z），不生效"].exists, "and the invalid one")
        dump(app, "deduped")
        hold("deduped")
    }

    /// The export: 导出… hands the phrases file to the share sheet, and
    /// 存储到「文件」 (Save to Files) puts it where the import test reads
    /// from. The host then compares the saved file with the group's.
    ///
    ///     TEST_RUNNER_JD_QA_EXPORT=1 xcodebuild test … \
    ///         -only-testing:JdKeyboardUITests/KeyboardExtensionQA/testExportToFiles
    ///
    /// Holds (TEST_RUNNER_JD_QA_MARKER) at `<path>-share`, `<path>-save-sheet`
    /// and `<path>-exported`; dumps (TEST_RUNNER_JD_QA_DUMP) at each step.
    @MainActor
    func testExportToFiles() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JD_QA_EXPORT"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-userdict", "键道\tzzzzzz;乙\tZZZZZA"]
        app.launch()
        tapFirst(app, "用户自造词")
        XCTAssertTrue(app.staticTexts["键道"].waitForExistence(timeout: 5), "seeded row")
        tapFirst(app, "导出…")

        // The share sheet (remote, in our tree) names the file; Save to
        // Files is one of its actions.
        let save = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "no Save to Files in the share sheet")
        dump(app, "share")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "用户自造词")).count > 1,
            "the sheet should name the file"
        )
        hold("share")
        save.tap()

        // The Files save sheet opens where it was last; Save takes it.
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10), "no Save button")
        dump(app, "save-sheet")
        hold("save-sheet")
        saveButton.tap()
        // A file of the same name may already be there.
        let replace = app.buttons["Replace"]
        if replace.waitForExistence(timeout: 3) {
            replace.tap()
        }
        XCTAssertTrue(app.staticTexts["导出…"].waitForExistence(timeout: 10), "back on the list")
        dump(app, "exported")
        hold("exported")
    }

    /// With JD_QA_MARKER set, create `<marker>-<step>` and wait (up to a
    /// minute) for the host to remove it after its screenshot.
    private func hold(_ step: String) {
        guard let marker = ProcessInfo.processInfo.environment["JD_QA_MARKER"] else { return }
        let path = "\(marker)-\(step)"
        FileManager.default.createFile(atPath: path, contents: nil)
        for _ in 0..<60 where FileManager.default.fileExists(atPath: path) { sleep(1) }
    }

    private func dump(_ app: XCUIApplication, _ step: String) {
        guard let path = ProcessInfo.processInfo.environment["JD_QA_DUMP"] else { return }
        try? app.debugDescription.write(toFile: "\(path)-\(step).txt", atomically: true, encoding: .utf8)
    }

    /// Extra preview launch args from JD_QA_ARGS (space-separated).
    private func extraLaunchArguments() -> [String] {
        (ProcessInfo.processInfo.environment["JD_QA_ARGS"] ?? "")
            .split(separator: " ").map(String.init)
    }

    @MainActor
    private func tapKey(_ app: XCUIApplication, _ label: String) {
        // Text keys are static texts; symbol keys (the globe, and shift /
        // delete wherever they're SF Symbols) are images labeled with their
        // text glyph. While a code is in flight the candidate bar's composing
        // label can read the same as a letter key, so of several matches take
        // the lowest on screen: the key grid sits under the bar.
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), "key '\(label)' not found")
        let key = matches.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY } ?? matches.firstMatch
        key.tap()
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard ▸ 键道.
    /// Idempotent: skips adding when 键道 is already in the keyboards list.
    @MainActor
    private func enableInSettingsIfNeeded() {
        // Xcode 27 installs the app under test only when a test first
        // launches it, and Settings offers no keyboard for an app that isn't
        // installed — so on a fresh simulator, launch before looking.
        let host = XCUIApplication()
        host.launch()
        host.terminate()

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
            // THIRD-PARTY KEYBOARDS section lists the container app's name
            // (iOS 27: below the suggested keyboards; the tap scrolls to it).
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
        // Already the current input mode (persists across runs) — done. A
        // just-installed extension takes several seconds to present the
        // first time, and a globe tap before it shows switches AWAY from it,
        // so give it a real chance first.
        if spacebar.waitForExistence(timeout: 8) { return }
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
