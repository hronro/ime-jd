// Platform-agnostic dispatch core — a verbatim port of
// ios/Keyboard/Engine/InputSession.swift.
//
// Like iOS, the in-flight raw code is surfaced via `onChange` so the keyboard
// draws it in its OWN candidate bar; only committed text reaches the host. No
// Android-UI imports here on purpose, so this is exercised by instrumented
// tests with a mock host.
package com.hronro.imejd.engine

/**
 * The host text field, abstracted to what the session needs. The IME service
 * implements this by forwarding to the InputConnection; tests use a mock.
 */
interface KeyboardHost {
    fun insertText(text: String)
    fun deleteBackward()
}

/**
 * What the keyboard needs in order to draw: the candidates loaded so far (an
 * append-only prefix of the engine's list), how many exist in total, and the
 * in-flight raw code.
 */
data class SessionSnapshot(
    val candidates: List<Candidate> = emptyList(),
    val optionsCount: Int = 0,
    val rawBuffer: String = "",
) {
    val isComposing: Boolean get() = rawBuffer.isNotEmpty()

    /**
     * Whether the bar should offer the expand-to-grid affordance. Keyed to a
     * fixed count so it doesn't vanish for mid-size candidate sets if the fetch
     * window changes.
     */
    val canExpand: Boolean get() = optionsCount > 9

    companion object {
        @JvmField
        val EMPTY = SessionSnapshot()
    }
}

class InputSession {
    private val engine = Engine()
    var host: KeyboardHost? = null

    /** The in-flight raw code (e.g. "js"), shown in the keyboard's candidate bar. */
    var rawBuffer: String = ""
        private set

    /** Candidates loaded so far, plus the totals the UI needs. */
    var snapshot: SessionSnapshot = SessionSnapshot.EMPTY
        private set

    /** Fired after every state change. UI re-renders the composing label + candidates. */
    var onChange: ((snapshot: SessionSnapshot) -> Unit)? = null

    val isComposing: Boolean get() = rawBuffer.isNotEmpty()

    // MARK: - Single entry point

    fun handle(action: KeyAction) {
        when (action) {
            is KeyAction.Passthrough -> {}
            is KeyAction.EngineKey -> engineKey(action.byte)
            is KeyAction.Backspace -> backspace()
            is KeyAction.Escape -> cancelAndReset()
            is KeyAction.CommitRaw -> commitRaw()
            is KeyAction.SelectIdx -> selectVisible(action.idx)
            // The on-screen keyboard binds no page keys — the candidate bar
            // scrolls instead, pulling more in via `loadMoreCandidates`. These
            // cases exist for the desktop key gate that shares `KeyAction`.
            is KeyAction.PageNext, is KeyAction.PagePrev -> {}
        }
    }

    // MARK: - Engine key

    private fun engineKey(byte: Byte) {
        val state = engine.pressKey(byte)

        val commit = state.commit
        if (commit != null) {
            // Commit goes to the host whether or not a composition was active.
            host?.insertText(commit)
            rawBuffer = ""
            if (state.optionsCount == 0) {
                // Plain commit (and drill-in produced nothing) — end the composition.
                engine.reset()
            } else {
                // Drilled in: committed text + a fresh composition started by `byte`.
                appendToBuffer(byte)
            }
            reload()
            return
        }

        if (state.optionsCount > 0) {
            appendToBuffer(byte)
            reload()
            return
        }

        // Neither commit nor candidates. For printable ASCII this is effectively
        // unreachable (the engine's fallback commits the byte), but insert the
        // literal byte so an on-screen tap is never silently dropped.
        host?.insertText(byteToString(byte))
        rawBuffer = ""
        engine.reset()
        reload()
    }

    // MARK: - Backspace

    private fun backspace() {
        if (!isComposing) {
            // No composition in flight → delete a real character in the host.
            host?.deleteBackward()
            return
        }
        engine.backspace()
        rawBuffer = rawBuffer.dropLast(1)
        if (rawBuffer.isEmpty()) {
            engine.reset()
        }
        reload()
    }

    // MARK: - Commit / cancel

    /** Commit a candidate the user tapped in the bar or grid. */
    private fun selectVisible(idx: Int) {
        if (idx < 0 || idx >= snapshot.candidates.size) return
        commitCandidate(snapshot.candidates[idx].value)
    }

    /** Commit an explicit candidate value (used by the candidate bar/grid). */
    fun commitCandidate(value: String) {
        host?.insertText(value)
        rawBuffer = ""
        engine.reset()
        reload()
    }

    /**
     * Insert a digit or Chinese punctuation directly, bypassing libjd's
     * punctuation table. Matches libjd's behavior: while composing, first commit
     * the top candidate exactly as the engine's space does, then append the
     * literal; otherwise insert it directly.
     */
    fun insertLiteral(s: String) {
        if (isComposing) {
            val state = engine.pressKey(0x20) // space: commit the anchor, append nothing
            state.commit?.let { host?.insertText(it) }
            rawBuffer = ""
            engine.reset()
            reload()
        }
        host?.insertText(s)
    }

    /** Return-key escape hatch: emit the raw typed code literally, drop composition. */
    fun commitRaw() {
        if (rawBuffer.isNotEmpty()) {
            host?.insertText(rawBuffer)
            rawBuffer = ""
        }
        engine.reset()
        reload()
    }

    /** Drop the in-flight composition without committing (focus change / dismiss). */
    fun cancelAndReset() {
        rawBuffer = ""
        engine.reset()
        reload()
    }

    /**
     * For the candidate bar's lazy scrolling: fetch the next window of
     * candidates and return them WITHOUT firing `onChange` (the bar appends them
     * itself, keeping already-shown candidates). Returns null at the end of the
     * list.
     *
     * No bookkeeping beyond remembering how far we've got: engine reads are
     * pure, so fetching ahead cannot change what the engine's automatic commits
     * resolve to. (The page-based ABI this replaced needed a jump-back dance
     * here, and getting it wrong committed a candidate the user wasn't looking
     * at.)
     */
    fun loadMoreCandidates(): List<Candidate>? {
        val loaded = snapshot.candidates.size
        if (loaded >= snapshot.optionsCount) return null
        val more = engine.readRange(loaded, WINDOW_SIZE)
        if (more.isEmpty()) return null
        snapshot = snapshot.copy(candidates = snapshot.candidates + more)
        return more
    }

    /** Release the engine context. */
    fun close() = engine.close()

    // MARK: - Helpers

    private fun appendToBuffer(byte: Byte) {
        rawBuffer += byteToString(byte)
    }

    private fun byteToString(byte: Byte): String = (byte.toInt() and 0xFF).toChar().toString()

    /** Re-read the leading window from the engine and publish it. */
    private fun reload() {
        val state = engine.state
        snapshot = SessionSnapshot(
            candidates = if (state.optionsCount > 0) {
                engine.readRange(0, WINDOW_SIZE)
            } else {
                emptyList()
            },
            optionsCount = state.optionsCount,
            rawBuffer = rawBuffer,
        )
        onChange?.invoke(snapshot)
    }

    companion object {
        /**
         * How many candidates each fetch pulls in. The bar shows a handful and
         * asks for more as it scrolls.
         */
        private const val WINDOW_SIZE = 16
    }
}
