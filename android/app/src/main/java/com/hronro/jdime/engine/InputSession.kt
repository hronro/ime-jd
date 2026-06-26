// Platform-agnostic dispatch core — a verbatim port of
// ios/Keyboard/Engine/InputSession.swift.
//
// Like iOS, the in-flight raw code is surfaced via `onChange` so the keyboard
// draws it in its OWN candidate bar; only committed text reaches the host. No
// Android-UI imports here on purpose, so this is exercised by instrumented
// tests with a mock host.
package com.hronro.jdime.engine

/**
 * The host text field, abstracted to what the session needs. The IME service
 * implements this by forwarding to the InputConnection; tests use a mock.
 */
interface KeyboardHost {
    fun insertText(text: String)
    fun deleteBackward()
}

class InputSession(pageSize: Byte = 9) {
    private val engine = Engine(pageSize)
    var host: KeyboardHost? = null

    /** The in-flight raw code (e.g. "js"), shown in the keyboard's candidate bar. */
    var rawBuffer: String = ""
        private set

    /** Candidates/commit for the current page. `options` is this page only. */
    var snapshot: QuerySnapshot = QuerySnapshot.EMPTY
        private set

    /** Fired after every state change. UI re-renders the composing label + candidates. */
    var onChange: ((snapshot: QuerySnapshot, rawBuffer: String) -> Unit)? = null

    val isComposing: Boolean get() = rawBuffer.isNotEmpty()

    // MARK: - Single entry point

    fun handle(action: KeyAction) {
        when (action) {
            is KeyAction.Passthrough -> {}
            is KeyAction.EngineKey -> engineKey(action.byte)
            is KeyAction.Backspace -> backspace()
            is KeyAction.Escape -> cancelAndReset()
            is KeyAction.CommitRaw -> commitRaw()
            is KeyAction.PageNext -> applyEngineResult(engine.nextPage())
            is KeyAction.PagePrev -> applyEngineResult(engine.prevPage())
            is KeyAction.SelectIdx -> selectVisible(action.idx)
        }
    }

    // MARK: - Engine key

    private fun engineKey(byte: Byte) {
        val snap = engine.pressKey(byte)

        val commit = snap.commit
        if (commit != null) {
            // Commit goes to the host whether or not a composition was active.
            host?.insertText(commit)
            rawBuffer = ""
            if (snap.options.isEmpty()) {
                // Plain commit (and drill-in produced nothing) — end the composition.
                engine.reset()
                setSnapshot(QuerySnapshot.EMPTY)
            } else {
                // Drilled-in: committed text + a fresh composition started by `byte`.
                appendToBuffer(byte)
                setSnapshot(snap)
            }
            return
        }

        if (snap.options.isNotEmpty()) {
            appendToBuffer(byte)
            setSnapshot(snap)
            return
        }

        // Neither commit nor options. For printable ASCII this is effectively
        // unreachable (the engine's fallback commits the byte), but insert the
        // literal byte so an on-screen tap is never silently dropped.
        host?.insertText(byteToString(byte))
        rawBuffer = ""
        engine.reset()
        setSnapshot(QuerySnapshot.EMPTY)
    }

    // MARK: - Backspace

    private fun backspace() {
        if (!isComposing) {
            // No composition in flight → delete a real character in the host.
            host?.deleteBackward()
            return
        }
        val snap = engine.backspace()
        rawBuffer = rawBuffer.dropLast(1)
        if (rawBuffer.isEmpty()) {
            engine.reset()
            setSnapshot(QuerySnapshot.EMPTY)
        } else {
            applyEngineResult(snap)
        }
    }

    // MARK: - Commit / cancel

    /** Commit a candidate the user tapped on the current page. */
    private fun selectVisible(idx: Int) {
        if (idx < 0 || idx >= snapshot.options.size) return
        commitCandidate(snapshot.options[idx].value)
    }

    /** Commit an explicit candidate value (used by the paginated candidate bar/grid). */
    fun commitCandidate(value: String) {
        host?.insertText(value)
        rawBuffer = ""
        engine.reset()
        setSnapshot(QuerySnapshot.EMPTY)
    }

    /**
     * Insert a digit or Chinese punctuation directly, bypassing libjd's
     * punctuation table. Matches libjd's behavior: while composing, first commit
     * the top candidate exactly as the engine's space does (option 0), then
     * append the literal; otherwise insert it directly.
     */
    fun insertLiteral(s: String) {
        if (isComposing) {
            val snap = engine.pressKey(0x20) // space: commit option 0, append nothing
            snap.commit?.let { host?.insertText(it) }
            rawBuffer = ""
            engine.reset()
            setSnapshot(QuerySnapshot.EMPTY)
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
        setSnapshot(QuerySnapshot.EMPTY)
    }

    /** Drop the in-flight composition without committing (focus change / dismiss). */
    fun cancelAndReset() {
        rawBuffer = ""
        engine.reset()
        setSnapshot(QuerySnapshot.EMPTY)
    }

    /**
     * For the candidate bar's lazy pagination: advance one page and return its
     * candidates WITHOUT firing `onChange` (the bar appends them itself, keeping
     * already-shown candidates). Returns null at the last page.
     */
    fun loadMoreCandidates(): List<Candidate>? {
        if (snapshot.currentPage >= snapshot.totalPages) return null
        val snap = engine.nextPage()
        snapshot = snap
        return snap.options
    }

    /** Release the engine context. */
    fun close() = engine.close()

    // MARK: - Helpers

    private fun applyEngineResult(snap: QuerySnapshot) = setSnapshot(snap)

    private fun appendToBuffer(byte: Byte) {
        rawBuffer += byteToString(byte)
    }

    private fun byteToString(byte: Byte): String = (byte.toInt() and 0xFF).toChar().toString()

    private fun setSnapshot(snap: QuerySnapshot) {
        snapshot = snap
        onChange?.invoke(snap, rawBuffer)
    }
}
