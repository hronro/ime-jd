// Maps a key press to what a session does with it, following the engine's
// key-routing policy (core/docs/integration.md) the way the macOS client does
// (macos/JdIME/Engine/KeyGate.swift): every printable ASCII byte goes to the
// engine, whether or not a composition is in flight. The engine then either
// extends the trie (a-z, `;`), resolves a Chinese-punctuation mapping, commits
// the current state and appends the byte literally (uppercase, unmapped
// punctuation), or commits and appends nothing (space). The only keys the
// session keeps for itself are its own bindings (digit select, `-`/`=`
// paging) and the navigation, cancel and commit keys — and those only matter
// while composing.
#pragma once

#include <cstdint>

namespace imejd {

/// A key press as Fcitx 5 and IBus both deliver it.
struct KeyInput {
    /// The X keysym, already shifted by the keyboard layout: Shift+1 is
    /// `exclam`, Shift+a and Caps Lock+a are `A`.
    uint32_t keysym = 0;
    /// The character the key types, from the framework's keysym table; 0 for
    /// none.
    uint32_t unicode = 0;
    bool shift = false;
    bool control = false;
    bool alt = false;
    /// Super, Hyper or Meta.
    bool super = false;
};

struct KeyAction {
    enum class Kind {
        Passthrough,
        Escape,
        CommitRaw,
        Backspace,
        PagePrev,
        PageNext,
        Select,
        EngineKey,
    };

    Kind kind = Kind::Passthrough;
    /// Select: the slot on the visible page, 0-based.
    unsigned index = 0;
    /// EngineKey: the typed byte.
    char byte = 0;
};

KeyAction keyAction(const KeyInput &key, bool composing);

} // namespace imejd
