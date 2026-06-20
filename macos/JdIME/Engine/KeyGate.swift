import AppKit

enum KeyCode {
    static let escape:   UInt16 = 53
    static let delete:   UInt16 = 51
    static let `return`: UInt16 = 36
    static let enter:    UInt16 = 76
    static let space:    UInt16 = 49
    static let leftArrow:  UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow:  UInt16 = 125
    static let upArrow:    UInt16 = 126
    static let pageUp:     UInt16 = 116
    static let pageDown:   UInt16 = 121
}

// Maps a key event to an action, following the engine's key-routing policy
// (core/docs/integration.md): every printable ASCII byte goes to the engine,
// whether or not a composition is in flight. The engine then either extends
// the trie (a-z, `;`), resolves a Chinese-punctuation mapping (auto-commit,
// or open a punc candidate window), commits the current state and appends the
// byte literally (uppercase / unmapped punctuation), or commits and appends
// nothing (space). The only keys the IME keeps for itself are our chosen
// bindings (digit select, `-`/`=` paging) and the navigation/cancel/commit
// keys — and those only matter while composing.
func keyAction(event: NSEvent, isComposing: Bool) -> KeyAction {
    let flags = event.modifierFlags

    // Modifier chords (Cmd/Ctrl/Option + anything) are host shortcuts — never
    // route them to the engine. Shift and Caps Lock are NOT in this set: they
    // are how the user types shifted/uppercase bytes, which the engine wants.
    if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
        return .passthrough
    }

    let kc = event.keyCode

    // Keys we own by virtual keycode while composing, independent of the typed
    // character: cancel, backspace, commit-raw, and page navigation.
    if isComposing {
        switch kc {
        case KeyCode.escape:
            return .escape
        case KeyCode.delete:
            return .backspace
        case KeyCode.return, KeyCode.enter:
            return .commitRaw
        case KeyCode.leftArrow, KeyCode.upArrow, KeyCode.pageUp:
            return .pagePrev
        case KeyCode.rightArrow, KeyCode.downArrow, KeyCode.pageDown:
            return .pageNext
        default:
            break
        }
    }

    // The actually-typed byte. `characters` honors Shift and Caps Lock (Cmd/
    // Ctrl/Option were already gated out), so e.g. Shift+/ → '?', Shift+1 → '!',
    // Caps+k → 'K' — exactly the byte the engine should append. Only printable
    // ASCII (0x20–0x7E) is meaningful; control chars and non-ASCII pass through.
    guard let chars = event.characters,
          let scalar = chars.unicodeScalars.first,
          scalar.isASCII,
          scalar.value >= 0x20, scalar.value <= 0x7E
    else {
        return .passthrough
    }
    let b = UInt8(scalar.value)
    let shifted = flags.contains(.shift)

    if isComposing {
        // IME-owned bindings (our choice). Only their UNSHIFTED forms are
        // bindings; the shifted variants ('!', '+', '_', …) are ordinary
        // punctuation and fall through to the engine below.
        if !shifted {
            if b == 0x2D { return .pagePrev }                 // '-'
            if b == 0x3D { return .pageNext }                 // '='
            if (0x31...0x39).contains(b) {                    // '1'..'9'
                return .selectIdx(Int(b - 0x31))
            }
        }
        // Everything else printable → engine: a-z extend the trie; space
        // commits the top candidate; punctuation may resolve to Chinese
        // punctuation (auto-commit or open a punc candidate window) or
        // fall through to commit-and-append; uppercase / unmapped bytes
        // commit and append literally.
        return .engineKey(b)
    }

    // Not composing: route every printable byte to the engine, which is the
    // single source of truth for what each byte means. Lowercase letters (a-z)
    // start a trie composition; punctuation resolves to its Chinese equivalent
    // (auto-commit — e.g. `.` → `。` — or open a punc candidate window — e.g.
    // `[` → 「/【/〔/［); every other byte (digits, uppercase, unmapped symbols,
    // space) is echoed back as a literal commit, so the visible output is
    // unchanged. Chinese punctuation therefore works even outside an active
    // composition — pressing `.` yields `。`, not `.`.
    return .engineKey(b)
}
