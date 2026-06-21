import UIKit

/// Colors for the keyboard, resolved from the host's requested appearance (falling
/// back to the trait collection) and the host's return-key type. Values approximate
/// the built-in iOS keyboard in light/dark mode.
struct KeyboardTheme: Equatable {
    var keyboardBackground: UIColor
    var keyBackground: UIColor          // letter/character keys
    var specialKeyBackground: UIColor   // shift / 123 / backspace / globe
    var keyText: UIColor
    var specialKeyText: UIColor
    var keyHighlight: UIColor           // pressed-state background
    var keyShadow: UIColor
    var popupBackground: UIColor
    var popupText: UIColor
    var candidateText: UIColor
    var candidateHint: UIColor
    var composingText: UIColor
    var separator: UIColor
    var returnBackground: UIColor       // already resolved (tinted or special)
    var returnText: UIColor

    static func resolve(
        traits: UITraitCollection,
        appearance: UIKeyboardAppearance,
        returnKeyType: UIReturnKeyType
    ) -> KeyboardTheme {
        let dark: Bool
        switch appearance {
        case .dark: dark = true
        case .light: dark = false
        default: dark = traits.userInterfaceStyle == .dark
        }
        var theme = dark ? KeyboardTheme.dark : KeyboardTheme.light
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

    static let light = KeyboardTheme(
        keyboardBackground: UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1),
        keyBackground: .white,
        specialKeyBackground: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1),
        keyText: .black,
        specialKeyText: .black,
        keyHighlight: UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1),
        keyShadow: UIColor(white: 0.45, alpha: 1),
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
        keyboardBackground: UIColor(white: 0.16, alpha: 1),
        keyBackground: UIColor(white: 0.42, alpha: 1),
        specialKeyBackground: UIColor(white: 0.28, alpha: 1),
        keyText: .white,
        specialKeyText: .white,
        keyHighlight: UIColor(white: 0.55, alpha: 1),
        keyShadow: .black,
        popupBackground: UIColor(white: 0.42, alpha: 1),
        popupText: .white,
        candidateText: .white,
        candidateHint: UIColor(white: 0.65, alpha: 1),
        composingText: UIColor(white: 0.7, alpha: 1),
        separator: UIColor(white: 0.35, alpha: 1),
        returnBackground: UIColor(white: 0.28, alpha: 1),
        returnText: .white
    )
}
