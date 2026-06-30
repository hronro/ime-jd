// Port of ios/Keyboard/Engine/KeyAction.swift — the dispatch tagged union.
package com.hronro.imejd.engine

sealed interface KeyAction {
    data object Passthrough : KeyAction
    data class EngineKey(val byte: Byte) : KeyAction
    data object Backspace : KeyAction
    data object Escape : KeyAction
    data object PageNext : KeyAction
    data object PagePrev : KeyAction
    data class SelectIdx(val idx: Int) : KeyAction
    data object CommitRaw : KeyAction
}
