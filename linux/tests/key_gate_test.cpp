// The key routing, case by case as the macOS client tests it
// (macos/JdIMETests/KeyGateTests.swift), with X keysyms.
#include <string>

#include "check.h"
#include "key_gate.h"

using imejd::KeyAction;
using imejd::KeyInput;

namespace {

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
constexpr uint32_t kKp1 = 0xffb1;

/// A printable key: its keysym is its ASCII code.
KeyInput typed(char c) {
    KeyInput key;
    key.keysym = static_cast<unsigned char>(c);
    key.unicode = static_cast<unsigned char>(c);
    return key;
}

/// A named key, with what the frameworks' keysym tables give for it.
KeyInput named(uint32_t keysym, uint32_t unicode = 0) {
    KeyInput key;
    key.keysym = keysym;
    key.unicode = unicode;
    return key;
}

KeyInput shifted(KeyInput key) {
    key.shift = true;
    return key;
}

std::string describe(const KeyAction &action) {
    using Kind = KeyAction::Kind;
    switch (action.kind) {
    case Kind::Passthrough:
        return "passthrough";
    case Kind::Escape:
        return "escape";
    case Kind::CommitRaw:
        return "commitRaw";
    case Kind::Backspace:
        return "backspace";
    case Kind::PagePrev:
        return "pagePrev";
    case Kind::PageNext:
        return "pageNext";
    case Kind::Select:
        return "select(" + std::to_string(action.index) + ")";
    case Kind::EngineKey:
        return std::string("engineKey(") + action.byte + ")";
    }
    return "?";
}

std::string route(const KeyInput &key, bool composing) { return describe(imejd::keyAction(key, composing)); }

} // namespace

TEST(lowercaseStartsComposition) { CHECK_EQ(route(typed('a'), false), "engineKey(a)"); }

TEST(uppercaseGoesToEngineWhenNotComposing) { CHECK_EQ(route(shifted(typed('K')), false), "engineKey(K)"); }

TEST(digitGoesToEngineWhenNotComposing) { CHECK_EQ(route(typed('1'), false), "engineKey(1)"); }

TEST(superChordPassesThrough) {
    KeyInput key = typed('a');
    key.super = true;
    CHECK_EQ(route(key, false), "passthrough");
    CHECK_EQ(route(key, true), "passthrough");
}

TEST(controlChordPassesThrough) {
    KeyInput key = typed('a');
    key.control = true;
    CHECK_EQ(route(key, false), "passthrough");
    CHECK_EQ(route(key, true), "passthrough");
}

TEST(altChordPassesThrough) {
    KeyInput key = typed('a');
    key.alt = true;
    CHECK_EQ(route(key, false), "passthrough");
    CHECK_EQ(route(key, true), "passthrough");
}

TEST(lowercaseWhileComposing) { CHECK_EQ(route(typed('b'), true), "engineKey(b)"); }

TEST(spaceWhileComposing) { CHECK_EQ(route(typed(' '), true), "engineKey( )"); }

TEST(semicolonWhileComposing) { CHECK_EQ(route(typed(';'), true), "engineKey(;)"); }

TEST(digitSelectsCandidate) {
    CHECK_EQ(route(typed('1'), true), "select(0)");
    CHECK_EQ(route(typed('9'), true), "select(8)");
    // The keypad's digits type the same characters.
    CHECK_EQ(route(named(kKp1, '1'), true), "select(0)");
}

TEST(shiftDigitGoesToEngine) {
    CHECK_EQ(route(shifted(typed('!')), true), "engineKey(!)");
    // A keypad digit with Shift held still types a digit, and is input, not
    // a binding.
    CHECK_EQ(route(shifted(named(kKp1, '1')), true), "engineKey(1)");
}

TEST(periodWhileComposingGoesToEngine) { CHECK_EQ(route(typed('.'), true), "engineKey(.)"); }

TEST(commaWhileComposingGoesToEngine) { CHECK_EQ(route(typed(','), true), "engineKey(,)"); }

TEST(periodWhileNotComposingGoesToEngine) { CHECK_EQ(route(typed('.'), false), "engineKey(.)"); }

TEST(escapeCancels) {
    CHECK_EQ(route(named(kEscape, 0x1b), true), "escape");
    CHECK_EQ(route(named(kEscape, 0x1b), false), "passthrough");
}

TEST(backspaceBackspaces) {
    CHECK_EQ(route(named(kBackSpace, 0x08), true), "backspace");
    CHECK_EQ(route(named(kBackSpace, 0x08), false), "passthrough");
}

TEST(returnCommitsRaw) {
    CHECK_EQ(route(named(kReturn, 0x0d), true), "commitRaw");
    CHECK_EQ(route(named(kKpEnter, 0x0d), true), "commitRaw");
    CHECK_EQ(route(named(kReturn, 0x0d), false), "passthrough");
}

TEST(arrowsAndPageKeysPage) {
    CHECK_EQ(route(named(kLeft), true), "pagePrev");
    CHECK_EQ(route(named(kUp), true), "pagePrev");
    CHECK_EQ(route(named(kPageUp), true), "pagePrev");
    CHECK_EQ(route(named(kRight), true), "pageNext");
    CHECK_EQ(route(named(kDown), true), "pageNext");
    CHECK_EQ(route(named(kPageDown), true), "pageNext");
    CHECK_EQ(route(named(kLeft), false), "passthrough");
}

TEST(minusPagesPrev) { CHECK_EQ(route(typed('-'), true), "pagePrev"); }

TEST(equalsPagesNext) { CHECK_EQ(route(typed('='), true), "pageNext"); }

TEST(shiftEqualsGoesToEngine) { CHECK_EQ(route(shifted(typed('+')), true), "engineKey(+)"); }

TEST(nonAsciiPassesThrough) {
    // A key that types é, on a layout that has one.
    CHECK_EQ(route(named(0xe9, 0xe9), false), "passthrough");
}
