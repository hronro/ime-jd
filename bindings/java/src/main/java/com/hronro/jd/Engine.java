package com.hronro.jd;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * One engine context: keystrokes go in, candidates and committed text come
 * out.
 *
 * <p>Candidates are addressed by flat index, not by page. {@link #readRange}
 * is a pure read: it never changes what the engine's own commits resolve to,
 * so a candidate strip can prefetch as far ahead as it likes. Tell the engine
 * what the user actually sees with {@link #setAnchor}.
 *
 * <p>Like the libjd context it wraps, an engine must not be used from two
 * threads at once; distinct engines are independent. It holds native memory
 * until it is {@linkplain #close closed}.
 */
public final class Engine implements AutoCloseable {
    private static final int READ_CHUNK = Jni.readChunk();

    // The native handle: the context, plus this engine's copy of the user
    // dictionary's blob (jd_jni.c). 0 once closed.
    private long handle;

    /** An engine over the built-in dictionary alone. */
    public Engine() {
        this(null);
    }

    /**
     * An engine whose candidate lists merge in {@code userDict}; null for the
     * built-in dictionary alone. An engine's dictionary is fixed for its
     * lifetime: to adopt another, create another engine.
     *
     * @throws IllegalStateException if the native context cannot be created
     */
    public Engine(@Nullable UserDict userDict) {
        long created = Jni.init(userDict == null ? null : userDict.blob);
        if (created == 0) {
            throw new IllegalStateException("jd_init failed (allocation failure)");
        }
        handle = created;
    }

    /** Feeds one keystroke, an ASCII byte, and returns the resulting state. */
    public EngineState pressKey(byte key) {
        return Jni.pressKey(live(), key);
    }

    /**
     * Undoes the most recent trie descent, or closes a punctuation window.
     * Never produces a commit.
     */
    public EngineState backspace() {
        return Jni.backspace(live());
    }

    /** Drops the in-flight composition and any recorded commit. */
    public EngineState reset() {
        return Jni.reset(live());
    }

    /**
     * Points the anchor at candidate {@code index}, so the engine's automatic
     * commits follow what the user is looking at. An out-of-range index is
     * ignored.
     */
    public EngineState setAnchor(int index) {
        return Jni.setAnchor(live(), index);
    }

    /** The engine's current state, without touching it. */
    public EngineState getState() {
        return Jni.state(live());
    }

    /**
     * The candidates at {@code [start, start + count)}: fewer than
     * {@code count} at the end of the list, and none when nothing is in
     * flight. A pure read: it never moves the anchor.
     */
    public List<Candidate> readRange(int start, int count) {
        if (count <= 0) {
            return Collections.emptyList();
        }
        long live = live();
        List<Candidate> out = new ArrayList<>(Math.min(count, READ_CHUNK));
        int at = start;
        while (out.size() < count) {
            int want = Math.min(count - out.size(), READ_CHUNK);
            List<Candidate> chunk = Jni.readRange(live, at, want);
            out.addAll(chunk);
            at += chunk.size();
            if (chunk.size() < want) {
                break; // the end of the list
            }
        }
        return out;
    }

    /**
     * Frees the native context. Closing twice is harmless; any other call on a
     * closed engine throws {@link IllegalStateException}.
     */
    @Override
    public void close() {
        if (handle != 0) {
            Jni.deinit(handle);
            handle = 0;
        }
    }

    // close() zeroes the handle, and passing that through JNI would hand libjd
    // a NULL context and crash the process. Fail with a clear error instead,
    // as the JS binding's disposed engines do.
    private long live() {
        if (handle == 0) {
            throw new IllegalStateException("Engine is closed");
        }
        return handle;
    }
}
