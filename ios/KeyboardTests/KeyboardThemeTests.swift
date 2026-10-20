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

    /// Action return key types tint the return key — `systemBlue` in classic,
    /// the stock glass keyboard's fixed pre-26 blue in liquid glass; `.default`
    /// keeps the special-key fill (in every style).
    func testReturnKeyTinting() {
        for forceClassic in [false, true] {
            let tinted = resolve(traits: lightTraits, returnKey: .go, forceClassic: forceClassic)
            XCTAssertEqual(tinted.returnBackground, tinted.style == .liquidGlass
                ? UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 1) : .systemBlue)
            XCTAssertEqual(tinted.returnText, .white)

            let plain = resolve(traits: lightTraits, forceClassic: forceClassic)
            XCTAssertEqual(plain.returnBackground, plain.specialKeyBackground)
            XCTAssertEqual(plain.returnText, plain.specialKeyText)
        }
    }

    /// Every palette lets the system backdrop show through; the in-app
    /// preview's classic stand-in for it is opaque.
    func testKeyboardBackgroundPerStyle() {
        for theme in [KeyboardTheme.glassLight, .glassDark, .light, .dark] {
            XCTAssertEqual(theme.keyboardBackground, .clear)
        }
        XCTAssertEqual(KeyboardTheme.light.materialWash.cgColor.alpha, 1)
        XCTAssertEqual(KeyboardTheme.dark.materialWash.cgColor.alpha, 1)
    }

    /// The chrome constants the views derive from the style.
    func testKeyChromePerStyle() {
        XCTAssertEqual(KeyboardTheme.light.keyCornerRadius, 5)
        XCTAssertEqual(KeyboardTheme.light.keyCornerCurve, .circular)
        XCTAssertEqual(KeyboardTheme.light.keyShadowOpacity, 1)
        XCTAssertEqual(KeyboardTheme.glassLight.keyCornerRadius, 8)
        XCTAssertEqual(KeyboardTheme.glassLight.keyCornerCurve, .continuous)
        XCTAssertEqual(KeyboardTheme.glassLight.keyShadowOpacity, 0)
    }

    /// Liquid glass gives every key one fill, like the stock keyboard since
    /// iOS 26 — function keys, armed shift and the plain return key included —
    /// and one pressed fill; classic keeps the pre-26 two-tone keys, where a
    /// pressed function key takes the letter-key fill.
    func testKeyFillsPerStyle() {
        for glass in [KeyboardTheme.glassLight, .glassDark] {
            XCTAssertEqual(glass.specialKeyBackground, glass.keyBackground)
            XCTAssertEqual(glass.shiftActiveBackground, glass.keyBackground)
            XCTAssertEqual(glass.specialKeyHighlight, glass.keyHighlight)
        }
        let plain = resolve(traits: darkTraits)
        if plain.style == .liquidGlass {
            XCTAssertEqual(plain.returnBackground, plain.keyBackground)
        }
        for classic in [KeyboardTheme.light, .dark] {
            XCTAssertNotEqual(classic.specialKeyBackground, classic.keyBackground)
            XCTAssertEqual(classic.specialKeyHighlight, classic.keyBackground)
        }
    }

    /// Each OS gets its own system keyboard's press feedback: the floating
    /// iOS 27 callout only on iOS 27+, never in classic.
    func testDetachedCalloutFollowsOSVersion() {
        let theme = resolve(traits: lightTraits)
        if #available(iOS 27.0, *) {
            XCTAssertTrue(theme.detachedCallout)
        } else {
            XCTAssertFalse(theme.detachedCallout)
        }
        XCTAssertFalse(resolve(traits: lightTraits, forceClassic: true).detachedCallout)
    }

    /// Candidates take the stock Pinyin keyboard's size in every style:
    /// 20pt on iPhone, 22pt on iPad.
    func testCandidateFontSizePerIdiom() {
        let phone = UITraitCollection(traitsFrom: [lightTraits, UITraitCollection(userInterfaceIdiom: .phone)])
        let pad = UITraitCollection(traitsFrom: [lightTraits, UITraitCollection(userInterfaceIdiom: .pad)])
        for forceClassic in [false, true] {
            XCTAssertEqual(resolve(traits: phone, forceClassic: forceClassic).candidateFontSize, 20)
            XCTAssertEqual(resolve(traits: pad, forceClassic: forceClassic).candidateFontSize, 22)
        }
    }

    /// Liquid glass shows the stock glyph per return-key type and tints only
    /// the action types (next and continue stay plain); classic keeps its
    /// text labels and tints every non-default type.
    func testReturnKeyGlyphsAndTint() {
        XCTAssertEqual(KeyboardTheme.returnSymbol(.default), "return.left")
        XCTAssertEqual(KeyboardTheme.returnSymbol(.search), "magnifyingglass")
        XCTAssertEqual(KeyboardTheme.returnSymbol(.send), "arrow.up")
        XCTAssertEqual(KeyboardTheme.returnSymbol(.next), "chevron.right")
        XCTAssertFalse(KeyboardTheme.glassReturnIsTinted(.next))
        XCTAssertFalse(KeyboardTheme.glassReturnIsTinted(.continue))
        XCTAssertTrue(KeyboardTheme.glassReturnIsTinted(.done))
        XCTAssertTrue(KeyboardTheme.returnIsTinted(.next))

        let classic = resolve(traits: lightTraits, returnKey: .next, forceClassic: true)
        XCTAssertNil(classic.returnSymbol)
        XCTAssertEqual(classic.returnBackground, .systemBlue)
        let glass = resolve(traits: lightTraits, returnKey: .next)
        if glass.style == .liquidGlass {
            XCTAssertEqual(glass.returnSymbol, "chevron.right")
            XCTAssertEqual(glass.returnBackground, glass.keyBackground)
        }
    }
}
