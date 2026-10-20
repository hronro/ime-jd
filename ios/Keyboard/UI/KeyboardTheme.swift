import UIKit

/// Colors for the keyboard, resolved from the host's requested appearance (falling
/// back to the trait collection) and the host's return-key type.
///
/// Two visual styles:
/// - `.classic` matches the pre-iOS-26 built-in keyboard (measured on the
///   iOS 18.6 simulator): solid keys with the hard 1pt bottom key shadow over
///   the system keyboard backdrop, which shows through — the keyboard draws
///   no background of its own, so it blends into the backdrop's globe/mic
///   strip below, as the stock keyboard does.
/// - `.liquidGlass` matches the iOS 26 redesign: the keyboard draws NO
///   background of its own — the system hosts extensions inside its rounded
///   keyboard panel, whose material also covers the strip above and the
///   globe/mic chin below, so painting our own would show as a seam. Like the
///   stock keyboard's, every key — letters and function keys alike — shares
///   one flat fill over that material (no shadow, rounder continuous
///   corners), an armed shift shows a filled glyph instead of an inverted
///   key, and the key-press callout is a masked blur material (see
///   `KeyPopupView`).
///   Keys deliberately are NOT per-key `UIGlassEffect` views: ~30 live
///   backdrop layers, rebuilt on every plane switch, blow the extension's
///   memory/GPU budget — flat fills over the shared material are what the
///   stock keys are anyway. (The in-app preview, which has no system
///   panel, puts a stand-in material behind the keyboard.)
struct KeyboardTheme: Equatable {
    enum Style { case classic, liquidGlass }

    var style: Style
    /// The appearance the palette was resolved for. The owner mirrors this into
    /// `overrideUserInterfaceStyle` so trait-driven chrome (the glass material,
    /// the popup's glass) follows the HOST's requested appearance, which can
    /// differ from the system style (e.g. `keyboardAppearance = .dark`).
    var isDark: Bool
    /// iOS 27's press feedback (liquid glass only): a key press floats a
    /// bubble above the key, which stays visible in its pressed fill, where
    /// iOS 26 grows a balloon out of the key itself.
    var detachedCallout = false

    var keyboardBackground: UIColor     // .clear: the system backdrop / panel shows through
    /// In-app preview only, which has no system backdrop: liquid glass's wash
    /// over the preview's stand-in material (the public materials run brighter
    /// than the system keyboard panel, so a faint darkening keeps white keys
    /// legible over light content); classic's whole stand-in, the stock
    /// backdrop's colour. The extension itself draws no background at all.
    var materialWash: UIColor
    var keyBackground: UIColor          // letter/character keys
    var specialKeyBackground: UIColor   // shift / 123 / backspace / globe (glass: = keyBackground)
    var keyText: UIColor
    var specialKeyText: UIColor
    var keyHighlight: UIColor           // pressed-state background (glass: every key)
    var keyShadow: UIColor
    var shiftActiveBackground: UIColor  // shift key while armed/locked
    var shiftActiveText: UIColor
    var popupBackground: UIColor        // classic bubble only (glass draws itself)
    var popupText: UIColor
    var candidateText: UIColor
    var candidateHint: UIColor
    var composingText: UIColor
    var separator: UIColor
    var returnBackground: UIColor       // already resolved (tinted or special)
    var returnText: UIColor
    /// Liquid glass: the SF Symbol the return key shows for the host's return
    /// key type — the stock keyboard swapped its text labels for glyphs in
    /// iOS 26. Nil in classic, which keeps the text.
    var returnSymbol: String? = nil
    /// Candidate glyph size, bar and expanded grid alike (see
    /// `candidateFontSize(idiom:)`).
    var candidateFontSize: CGFloat = 20

    // MARK: - Key chrome (derived from the style, tuned in one place)

    var keyCornerRadius: CGFloat { style == .liquidGlass ? 8 : 5 }
    var keyCornerCurve: CALayerCornerCurve { style == .liquidGlass ? .continuous : .circular }
    /// Classic: the hard 1pt bottom edge of the pre-26 keyboard. Liquid glass:
    /// none — the stock keys sit flat on the material (measured: no darkening
    /// below them).
    var keyShadowOpacity: Float { style == .liquidGlass ? 0 : 1 }

    /// Pressed fill of the function keys. Classic swaps them to the letter-key
    /// fill (the pre-26 keyboard's press feedback); liquid glass presses every
    /// key to the same highlight, as the stock keyboard does.
    var specialKeyHighlight: UIColor { style == .liquidGlass ? keyHighlight : keyBackground }

    /// Pressed fill of a character key. iOS 27 leaves it visible under the
    /// floating bubble and lightens it less than a pressed function key
    /// (measured 222 light / 105 dark); elsewhere the callout's stem covers it.
    var letterKeyHighlight: UIColor {
        guard detachedCallout else { return keyHighlight }
        return isDark ? UIColor(white: 1, alpha: 0.32) : UIColor(white: 222 / 255, alpha: 1)
    }

    /// The press-and-hold row's selection: blue with white text in classic and
    /// on iOS 26 (whose stock row uses its own, lighter blue), a grey cell
    /// under the normal glyph colour on iOS 27.
    var alternatesHighlight: UIColor {
        switch (style, detachedCallout) {
        case (.classic, _):
            return .systemBlue
        case (.liquidGlass, false):
            return UIColor(red: 0, green: (isDark ? 145 : 136) / 255, blue: 1, alpha: 1)
        case (.liquidGlass, true):
            return isDark ? UIColor(white: 1, alpha: 0.11) : UIColor(red: 228 / 255, green: 228 / 255, blue: 230 / 255, alpha: 1)
        }
    }
    var alternatesHighlightText: UIColor { detachedCallout ? popupText : .white }

    static func resolve(
        traits: UITraitCollection,
        appearance: UIKeyboardAppearance,
        returnKeyType: UIReturnKeyType,
        forceClassic: Bool = false
    ) -> KeyboardTheme {
        let dark: Bool
        switch appearance {
        case .dark: dark = true
        case .light: dark = false
        default: dark = traits.userInterfaceStyle == .dark
        }
        let glass: Bool
        if #available(iOS 26.0, *), !forceClassic { glass = true } else { glass = false }
        var theme: KeyboardTheme
        switch (glass, dark) {
        case (true, true):   theme = .glassDark
        case (true, false):  theme = .glassLight
        case (false, true):  theme = .dark
        case (false, false): theme = .light
        }
        if glass {
            if #available(iOS 27.0, *) { theme.detachedCallout = true }
            theme.returnSymbol = Self.returnSymbol(returnKeyType)
        }
        theme.candidateFontSize = Self.candidateFontSize(idiom: traits.userInterfaceIdiom)
        if glass ? Self.glassReturnIsTinted(returnKeyType) : Self.returnIsTinted(returnKeyType) {
            // The stock glass keyboard keeps the pre-26 blue in both
            // appearances, not the lighter iOS 26 `systemBlue`.
            theme.returnBackground = glass ? UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 1) : .systemBlue
            theme.returnText = .white
        } else {
            theme.returnBackground = theme.specialKeyBackground
            theme.returnText = theme.specialKeyText
        }
        return theme
    }

    static func returnIsTinted(_ t: UIReturnKeyType) -> Bool {
        switch t {
        case .default: return false
        default: return true
        }
    }

    /// The stock glass keyboard (iOS 26.5 and 27) tints the action types only:
    /// next and continue stay on the normal key fill, like plain return.
    static func glassReturnIsTinted(_ t: UIReturnKeyType) -> Bool {
        switch t {
        case .default, .next, .continue: return false
        default: return true
        }
    }

    /// The stock glass keyboard's return-key glyph for each type.
    static func returnSymbol(_ t: UIReturnKeyType) -> String {
        switch t {
        case .go, .join, .route: return "arrow.right"
        case .google, .search, .yahoo: return "magnifyingglass"
        case .send: return "arrow.up"
        case .done: return "checkmark"
        case .next, .continue: return "chevron.right"
        case .emergencyCall: return "phone"
        default: return "return.left"
        }
    }

    /// The stock Pinyin keyboard's candidate size, bar and expanded grid
    /// alike, in both styles (measured on iOS 18.6, 26.5 and 27): 20pt on
    /// iPhone, 22pt on iPad.
    static func candidateFontSize(idiom: UIUserInterfaceIdiom) -> CGFloat {
        idiom == .pad ? 22 : 20
    }

    /// Localized return-key label for the host's return key type (built-in wording).
    static func returnLabel(_ t: UIReturnKeyType) -> String {
        switch t {
        case .go: return "前往"
        case .google, .search, .yahoo: return "搜索"
        case .send: return "发送"
        case .join: return "加入"
        case .next: return "下一项"
        case .route: return "路线"
        case .done: return "完成"
        case .continue: return "继续"
        default: return "换行"
        }
    }

    // MARK: - Classic palettes (pre-iOS-26; measured on the iOS 18.6 simulator)
    //
    // Function keys 169/175/188 light, 73 dark; letters white / 110; the key
    // shadow a black veil over the backdrop (135/137/142 over 208/211/218
    // light, 28 over 49 dark). An armed or locked shift turns light in both
    // appearances (white / 213) under a black glyph. The backdrop itself is
    // the system's (`keyboardBackground` is clear); `materialWash` is the
    // in-app preview's stand-in for it.

    private static let classicLightFunction = UIColor(red: 169 / 255, green: 175 / 255, blue: 188 / 255, alpha: 1)
    private static let classicDarkLetter = UIColor(red: 110 / 255, green: 110 / 255, blue: 111 / 255, alpha: 1)
    private static let classicDarkFunction = UIColor(red: 73 / 255, green: 73 / 255, blue: 74 / 255, alpha: 1)

    static let light = KeyboardTheme(
        style: .classic,
        isDark: false,
        keyboardBackground: .clear,
        materialWash: UIColor(red: 208 / 255, green: 211 / 255, blue: 218 / 255, alpha: 1),
        keyBackground: .white,
        specialKeyBackground: classicLightFunction,
        keyText: .black,
        specialKeyText: .black,
        keyHighlight: classicLightFunction,
        keyShadow: UIColor(white: 0, alpha: 0.35),
        shiftActiveBackground: .white,
        shiftActiveText: .black,
        popupBackground: .white,
        popupText: .black,
        candidateText: .black,
        candidateHint: UIColor(white: 0.5, alpha: 1),
        composingText: UIColor(white: 0.4, alpha: 1),
        separator: UIColor(white: 0.7, alpha: 1),
        returnBackground: classicLightFunction,
        returnText: .black
    )

    static let dark = KeyboardTheme(
        style: .classic,
        isDark: true,
        keyboardBackground: .clear,
        materialWash: UIColor(white: 47 / 255, alpha: 1),
        keyBackground: classicDarkLetter,
        specialKeyBackground: classicDarkFunction,
        keyText: .white,
        specialKeyText: .white,
        keyHighlight: classicDarkFunction,
        keyShadow: UIColor(white: 0, alpha: 0.43),
        shiftActiveBackground: UIColor(white: 213 / 255, alpha: 1),
        shiftActiveText: .black,
        popupBackground: classicDarkLetter,
        popupText: .white,
        candidateText: .white,
        candidateHint: UIColor(white: 0.65, alpha: 1),
        composingText: UIColor(white: 0.7, alpha: 1),
        separator: UIColor(white: 0.35, alpha: 1),
        returnBackground: classicDarkFunction,
        returnText: .white
    )

    // MARK: - Liquid-glass palettes (iOS 26+; fills composite over the material backdrop)
    //
    // One fill for every key, measured off the stock keyboard on the iOS 26.4,
    // 26.5 and 27.0 simulators (letters, shift, delete, 123 and return alike):
    // light keys are opaque white (255 over a 224 panel); dark keys read 64
    // over 26.x's 27 panel and 70 over 27.0's 34 — both a 0.163 white veil. A
    // held function key goes to 195 light / 131 dark over the 27.0 panel.

    static let glassLight = KeyboardTheme(
        style: .liquidGlass,
        isDark: false,
        keyboardBackground: .clear,
        materialWash: UIColor(white: 0, alpha: 0.05),
        keyBackground: .white,
        specialKeyBackground: .white,
        keyText: .black,
        specialKeyText: .black,
        keyHighlight: UIColor(white: 0, alpha: 0.13),
        keyShadow: .black,
        shiftActiveBackground: .white,                          // armed = filled glyph, same fill
        shiftActiveText: .black,
        popupBackground: .white,                                // unused fallback
        popupText: .black,
        candidateText: .black,
        candidateHint: UIColor(white: 0.45, alpha: 1),
        composingText: UIColor(white: 0.35, alpha: 1),
        separator: UIColor(white: 0, alpha: 0.15),
        returnBackground: .white,
        returnText: .black
    )

    static let glassDark = KeyboardTheme(
        style: .liquidGlass,
        isDark: true,
        keyboardBackground: .clear,
        materialWash: .clear,
        keyBackground: UIColor(white: 1, alpha: 0.163),
        specialKeyBackground: UIColor(white: 1, alpha: 0.163),
        keyText: .white,
        specialKeyText: .white,
        keyHighlight: UIColor(white: 1, alpha: 0.44),
        keyShadow: .black,
        shiftActiveBackground: UIColor(white: 1, alpha: 0.163), // armed = filled glyph, same fill
        shiftActiveText: .white,
        popupBackground: UIColor(white: 0.35, alpha: 1),        // unused fallback
        popupText: .white,
        candidateText: .white,
        candidateHint: UIColor(white: 0.65, alpha: 1),
        composingText: UIColor(white: 0.7, alpha: 1),
        separator: UIColor(white: 1, alpha: 0.20),
        returnBackground: UIColor(white: 1, alpha: 0.163),
        returnText: .white
    )
}
