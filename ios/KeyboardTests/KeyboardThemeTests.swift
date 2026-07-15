import XCTest
import UIKit

// The keyboard UI sources are compiled into this test bundle directly
// (see ios/project.yml), so no module import is needed.

final class KeyboardThemeTests: XCTestCase {
    private let lightTraits = UITraitCollection(userInterfaceStyle: .light)
    private let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

    private func resolve(
        traits: UITraitCollection,
        appearance: UIKeyboardAppearance = .default,
        returnKey: UIReturnKeyType = .default,
        forceClassic: Bool = false
    ) -> KeyboardTheme {
        KeyboardTheme.resolve(
            traits: traits, appearance: appearance,
            returnKeyType: returnKey, forceClassic: forceClassic
        )
    }

    /// Liquid glass on iOS 26+, classic below — the entire style gate.
    func testStyleFollowsOSAvailability() {
        let style = resolve(traits: lightTraits).style
        if #available(iOS 26.0, *) {
            XCTAssertEqual(style, .liquidGlass)
        } else {
            XCTAssertEqual(style, .classic)
        }
    }

    /// The QA escape hatch (`-classic`) wins over availability.
    func testForceClassicOverridesGlass() {
        XCTAssertEqual(resolve(traits: lightTraits, forceClassic: true).style, .classic)
        XCTAssertEqual(resolve(traits: darkTraits, forceClassic: true).style, .classic)
    }

    /// An explicit host keyboardAppearance beats the trait collection.
    func testHostAppearanceBeatsTraits() {
        XCTAssertTrue(resolve(traits: lightTraits, appearance: .dark).isDark)
        XCTAssertFalse(resolve(traits: darkTraits, appearance: .light).isDark)
    }

    /// `.default` appearance falls back to the trait collection.
    func testTraitsDecideWhenAppearanceIsDefault() {
        XCTAssertFalse(resolve(traits: lightTraits).isDark)
        XCTAssertTrue(resolve(traits: darkTraits).isDark)
    }

    /// Non-default return key types tint the return key; `.default` keeps the
    /// special-key fill (in every style).
    func testReturnKeyTinting() {
        for forceClassic in [false, true] {
            let tinted = resolve(traits: lightTraits, returnKey: .go, forceClassic: forceClassic)
            XCTAssertEqual(tinted.returnBackground, .systemBlue)
            XCTAssertEqual(tinted.returnText, .white)

            let plain = resolve(traits: lightTraits, forceClassic: forceClassic)
            XCTAssertEqual(plain.returnBackground, plain.specialKeyBackground)
            XCTAssertEqual(plain.returnText, plain.specialKeyText)
        }
    }

    /// Glass palettes let the material show through; classic stays opaque.
    func testKeyboardBackgroundPerStyle() {
        XCTAssertEqual(KeyboardTheme.glassLight.keyboardBackground, .clear)
        XCTAssertEqual(KeyboardTheme.glassDark.keyboardBackground, .clear)
        XCTAssertEqual(KeyboardTheme.light.keyboardBackground.cgColor.alpha, 1)
        XCTAssertEqual(KeyboardTheme.dark.keyboardBackground.cgColor.alpha, 1)
    }

    /// The chrome constants the views derive from the style.
    func testKeyChromePerStyle() {
        XCTAssertEqual(KeyboardTheme.light.keyCornerRadius, 5)
        XCTAssertEqual(KeyboardTheme.light.keyCornerCurve, .circular)
        XCTAssertEqual(KeyboardTheme.glassLight.keyCornerRadius, 9)
        XCTAssertEqual(KeyboardTheme.glassLight.keyCornerCurve, .continuous)
    }
}
