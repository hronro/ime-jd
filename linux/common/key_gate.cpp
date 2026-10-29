#include "key_gate.h"

namespace imejd {

namespace {

// The X keysyms of the keys a session owns while composing. Fcitx 5
// (FcitxKey_*) and IBus (IBUS_KEY_*) share these values.
constexpr uint32_t kBackSpace = 0xff08;
constexpr uint32_t kReturn = 0xff0d;
constexpr uint32_t kEscape = 0xff1b;
constexpr uint32_t kLeft = 0xff51;
constexpr uint32_t kUp = 0xff52;
constexpr uint32_t kRight = 0xff53;
constexpr uint32_t kDown = 0xff54;
constexpr uint32_t kPageUp = 0xff55;
constexpr uint32_t kPageDown = 0xff56;
constexpr uint32_t kKpEnter = 0xff8d;
constexpr uint32_t kKpLeft = 0xff96;
constexpr uint32_t kKpUp = 0xff97;
constexpr uint32_t kKpRight = 0xff98;
constexpr uint32_t kKpDown = 0xff99;
constexpr uint32_t kKpPageUp = 0xff9a;
constexpr uint32_t kKpPageDown = 0xff9b;

KeyAction action(KeyAction::Kind kind) {
    KeyAction result;
    result.kind = kind;
    return result;
}

} // namespace

KeyAction keyAction(const KeyInput &key, bool composing) {
    using Kind = KeyAction::Kind;

    // Modifier chords are host shortcuts — never route them to the engine.
    // Shift and Caps Lock are NOT in this set: they are how the user types
    // shifted and uppercase bytes, which the engine wants.
    if (key.control || key.alt || key.super) {
        return action(Kind::Passthrough);
    }

    // Keys we own by keysym while composing, independent of the typed
    // character: cancel, backspace, commit-raw, and page navigation.
    if (composing) {
        switch (key.keysym) {
        case kEscape:
            return action(Kind::Escape);
        case kBackSpace:
            return action(Kind::Backspace);
        case kReturn:
        case kKpEnter:
            return action(Kind::CommitRaw);
        case kLeft:
        case kUp:
        case kPageUp:
        case kKpLeft:
        case kKpUp:
        case kKpPageUp:
            return action(Kind::PagePrev);
        case kRight:
        case kDown:
        case kPageDown:
        case kKpRight:
        case kKpDown:
        case kKpPageDown:
            return action(Kind::PageNext);
        default:
            break;
        }
    }

    // The actually-typed byte. Only printable ASCII (0x20–0x7E) is
    // meaningful; control characters and non-ASCII pass through.
    if (key.unicode < 0x20 || key.unicode > 0x7e) {
        return action(Kind::Passthrough);
    }
    const char b = static_cast<char>(key.unicode);

    if (composing && !key.shift) {
        // Our bindings. Only their UNSHIFTED forms are bindings; shifted
        // ones ('!', '+', '_', a keypad digit with Shift held) are ordinary
        // input and fall through to the engine below.
        if (b == '-') {
            return action(Kind::PagePrev);
        }
        if (b == '=') {
            return action(Kind::PageNext);
        }
        if (b >= '1' && b <= '9') {
            KeyAction select = action(Kind::Select);
            select.index = static_cast<unsigned>(b - '1');
            return select;
        }
    }

    // Everything else printable goes to the engine, composing or not: a-z
    // extend the trie or start a composition; punctuation resolves to its
    // Chinese mark (`.` → `。`, or a candidate window for `[`); every other
    // byte — digits, uppercase, unmapped symbols, space — is committed back
    // literally, so its visible output is unchanged.
    KeyAction engineKey = action(Kind::EngineKey);
    engineKey.byte = b;
    return engineKey;
}

} // namespace imejd
