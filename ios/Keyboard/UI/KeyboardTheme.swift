import UIKit

/// Colors for the keyboard, resolved from the host's requested appearance (falling
/// back to the trait collection) and the host's return-key type.
///
/// Two visual styles:
/// - `.classic` approximates the pre-iOS-26 built-in keyboard: an opaque
///   background with solid keys and the hard 1pt bottom key shadow.
/// - `.liquidGlass` matches the iOS 26 redesign: the keyboard draws NO
///   background of its own — the system hosts extensions inside its rounded
///   keyboard panel, whose material also covers the strip above and the
///   globe/mic chin below, so painting our own would show as a seam. Keys are
///   translucent fills over that material, with rounder continuous corners;
///   the key-press bubble is real glass (`UIGlassEffect`). Keys deliberately
///   are NOT per-key `UIGlassEffect` views: ~30 live backdrop layers, rebuilt
///   on every plane switch, blow the extension's memory/GPU budget —
///   translucent fills over the shared material is what the stock keys read
///   as anyway. (The in-app preview, which has no system panel, puts a
///   stand-in material behind the keyboard.)
struct KeyboardTheme: Equatable {
    enum Style { case classic, liquidGlass }

    var style: Style
    /// The appearance the palette was resolved for. The owner mirrors this into
    /// `overrideUserInterfaceStyle` so trait-driven chrome (the glass material,
    /// the popup's glass) follows the HOST's requested appearance, which can
    /// differ from the system style (e.g. `keyboardAppearance = .dark`).
    var isDark: Bool

    var keyboardBackground: UIColor     // .clear in liquid glass (the system panel shows through)
    /// Liquid glass, in-app preview only: the wash over the preview's stand-in
    /// material (the public materials run brighter than the system keyboard
    /// panel, so a faint darkening keeps white keys legible over light
    /// content). The extension itself draws no background at all.
    var materialWash: UIColor
    var keyBackground: UIColor          // letter/character keys
    var specialKeyBackground: UIColor   // shift / 123 / backspace / globe
    var keyText: UIColor
    var specialKeyText: UIColor
    var keyHighlight: UIColor           // pressed-state background
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

    // MARK: - Key chrome (derived from the style, tuned in one place)

    var keyCornerRadius: CGFloat { style == .liquidGlass ? 9 : 5 }
    var keyCornerCurve: CALayerCornerCurve { style == .liquidGlass ? .continuous : .circular }
    /// Classic: the hard 1pt bottom edge of the pre-26 keyboard. Liquid glass:
    /// a faint soft shadow — translucent fills let the shadow bleed through, so
    /// anything stronger muddies the keys.
    var keyShadowOpacity: Float { style == .liquidGlass ? 0.18 : 1 }
    var keyShadowBlur: CGFloat { style == .liquidGlass ? 1.5 : 0 }

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
        if Self.returnIsTinted(returnKeyType) {
            theme.returnBackground = .systemBlue
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

    // MARK: - Classic palettes (pre-iOS-26; values approximate the old built-in keyboard)

    static let light = KeyboardTheme(
        style: .classic,
        isDark: false,
        keyboardBackground: UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1),
        materialWash: .clear,
        keyBackground: .white,
        specialKeyBackground: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1),
        keyText: .black,
        specialKeyText: .black,
        keyHighlight: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1),
        keyShadow: UIColor(white: 0.45, alpha: 1),
        shiftActiveBackground: .white,
        shiftActiveText: .black,
        popupBackground: .white,
        popupText: .black,
        candidateText: .black,
        candidateHint: UIColor(white: 0.5, alpha: 1),
        composingText: UIColor(white: 0.4, alpha: 1),
        separator: UIColor(white: 0.7, alpha: 1),
        returnBackground: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1),
        returnText: .black
    )

    static let dark = KeyboardTheme(
        style: .classic,
        isDark: true,
        keyboardBackground: UIColor(white: 0.16, alpha: 1),
        materialWash: .clear,
        keyBackground: UIColor(white: 0.42, alpha: 1),
        specialKeyBackground: UIColor(white: 0.28, alpha: 1),
        keyText: .white,
        specialKeyText: .white,
        keyHighlight: UIColor(white: 0.55, alpha: 1),
        keyShadow: .black,
        shiftActiveBackground: UIColor(white: 0.42, alpha: 1),
        shiftActiveText: .white,
        popupBackground: UIColor(white: 0.42, alpha: 1),
        popupText: .white,
        candidateText: .white,
        candidateHint: UIColor(white: 0.65, alpha: 1),
        composingText: UIColor(white: 0.7, alpha: 1),
        separator: UIColor(white: 0.35, alpha: 1),
        returnBackground: UIColor(white: 0.28, alpha: 1),
        returnText: .white
    )

    // MARK: - Liquid-glass palettes (iOS 26+; fills composite over the material backdrop)

    static let glassLight = KeyboardTheme(
        style: .liquidGlass,
        isDark: false,
        keyboardBackground: .clear,
        materialWash: UIColor(white: 0, alpha: 0.05),
        keyBackground: UIColor(white: 1, alpha: 0.92),
        specialKeyBackground: UIColor(white: 0, alpha: 0.10),   // darkens the material
        keyText: .black,
        specialKeyText: .black,
        keyHighlight: UIColor(white: 0, alpha: 0.14),
        keyShadow: .black,
        shiftActiveBackground: UIColor(white: 1, alpha: 0.92),
        shiftActiveText: .black,
        popupBackground: .white,                                // unused fallback
        popupText: .black,
        candidateText: .black,
        candidateHint: UIColor(white: 0.45, alpha: 1),
        composingText: UIColor(white: 0.35, alpha: 1),
        separator: UIColor(white: 0, alpha: 0.15),
        returnBackground: UIColor(white: 0, alpha: 0.10),
        returnText: .black
    )

    static let glassDark = KeyboardTheme(
        style: .liquidGlass,
        isDark: true,
        keyboardBackground: .clear,
        materialWash: .clear,
        keyBackground: UIColor(white: 1, alpha: 0.30),
        specialKeyBackground: UIColor(white: 1, alpha: 0.13),
        keyText: .white,
        specialKeyText: .white,
        keyHighlight: UIColor(white: 1, alpha: 0.50),
        keyShadow: .black,
        shiftActiveBackground: .white,                          // stock: solid white, black glyph
        shiftActiveText: .black,
        popupBackground: UIColor(white: 0.35, alpha: 1),        // unused fallback
        popupText: .white,
        candidateText: .white,
        candidateHint: UIColor(white: 0.65, alpha: 1),
        composingText: UIColor(white: 0.7, alpha: 1),
        separator: UIColor(white: 1, alpha: 0.20),
        returnBackground: UIColor(white: 1, alpha: 0.13),
        returnText: .white
    )
}
