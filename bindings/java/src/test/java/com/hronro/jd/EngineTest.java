// The Engine wrapper's own contract, against the real engine: libjd and
// jd_jni.c built for the machine running the tests (scripts/build-host.sh).
package com.hronro.jd;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

class EngineTest {
    private static List<String> values(List<Candidate> window) {
        return window.stream().map(Candidate::value).toList();
    }

    /**
     * Regression: close() zeroes the native handle, so without the closed
     * guard any later call would pass NULL to libjd and crash the process.
     * The JS binding throws on use after dispose; this one matches.
     */
    @Test
    void useAfterCloseThrowsInsteadOfCrashing() {
        Engine e = new Engine();
        e.close();
        assertThrows(IllegalStateException.class, () -> e.pressKey((byte) 'n'));
        assertThrows(IllegalStateException.class, e::backspace);
        assertThrows(IllegalStateException.class, e::reset);
        assertThrows(IllegalStateException.class, () -> e.setAnchor(0));
        assertThrows(IllegalStateException.class, e::getState);
        assertThrows(IllegalStateException.class, () -> e.readRange(0, 4));
    }

    @Test
    void doubleCloseIsSafe() {
        Engine e = new Engine();
        e.close();
        e.close();
    }

    /** The guard must not get in the way of a live engine. */
    @Test
    void openEngineStillWorks() {
        try (Engine e = new Engine()) {
            EngineState state = e.pressKey((byte) 'n');
            assertTrue(state.optionsCount() > 0, "expected candidates for 'n'");
            assertFalse(e.readRange(0, 9).isEmpty());
        }
    }

    /**
     * readRange loops over the JNI chunk size, so a window larger than one
     * native call must still come back complete and in order.
     */
    @Test
    void readRangeSpansMultipleNativeChunks() {
        try (Engine e = new Engine()) {
            int total = e.pressKey((byte) 'j').optionsCount();
            assertTrue(total > 200, "expected a long candidate list for 'j'");

            List<Candidate> big = e.readRange(0, 200);
            assertEquals(200, big.size());
            assertTrue(big.stream().noneMatch(c -> c.value().isEmpty()));

            // Chunked reads agree with a smaller single-chunk read.
            assertEquals(values(big.subList(0, 32)), values(e.readRange(0, 32)));

            // A window is clipped by the total, never padded.
            assertEquals(total, e.readRange(0, total + 50).size());
            assertTrue(e.readRange(total, 5).isEmpty());
            assertTrue(e.readRange(0, 0).isEmpty());
        }
    }

    /** Reads are pure: prefetching must not change what space commits. */
    @Test
    void readingAheadDoesNotMoveTheAnchor() {
        try (Engine e = new Engine()) {
            int total = e.pressKey((byte) 'j').optionsCount();
            String anchored = e.readRange(0, 1).get(0).value();

            e.readRange(total - 8, 8);
            assertEquals(0, e.getState().anchorIndex());
            assertEquals(anchored, e.pressKey((byte) ' ').commit());
        }
    }

    @Test
    void setAnchorMovesWhatSpaceCommits() {
        try (Engine e = new Engine()) {
            e.pressKey((byte) 'j');
            String target = e.readRange(7, 1).get(0).value();

            assertEquals(7, e.setAnchor(7).anchorIndex());
            assertEquals(target, e.pressKey((byte) ' ').commit());
        }
    }

    @Test
    void setAnchorIgnoresOutOfRange() {
        try (Engine e = new Engine()) {
            int total = e.pressKey((byte) 'j').optionsCount();
            e.setAnchor(3);
            e.setAnchor(total); // one past the end
            assertEquals(3, e.getState().anchorIndex());
            e.setAnchor(Integer.MAX_VALUE);
            assertEquals(3, e.getState().anchorIndex());
        }
    }

    /** A commit that appends a literal byte must join in the right order. */
    @Test
    void literalAppendJoinsInOrder() {
        try (Engine e = new Engine()) {
            e.pressKey((byte) 'a');
            String first = e.readRange(0, 1).get(0).value();
            // A digit is literal input to the engine: commit the anchor, append '2'.
            assertEquals(first + "2", e.pressKey((byte) '2').commit());
        }
    }

    /** Hints are inline bytes, bounded by the dictionary's longest code. */
    @Test
    void hintsAreBoundedOrAbsent() {
        try (Engine e = new Engine()) {
            e.pressKey((byte) 'j');
            List<Candidate> window = e.readRange(0, 32);
            for (Candidate c : window) {
                String hint = c.hint();
                if (hint != null) {
                    assertTrue(!hint.isEmpty() && hint.length() < 8, "hint '" + hint + "' is too long");
                }
            }
            assertTrue(
                    window.stream().anyMatch(c -> c.hint() == null),
                    "a fully-typed code should have a hintless candidate");
        }
    }

    /** States and candidates are values: what one engine reads, another reads equal. */
    @Test
    void resultsAreValues() {
        try (Engine a = new Engine();
                Engine b = new Engine()) {
            assertEquals(a.pressKey((byte) 'j'), b.pressKey((byte) 'j'));
            assertEquals(a.readRange(0, 9), b.readRange(0, 9));
            assertEquals(EngineState.EMPTY, a.reset());
            assertTrue(a.getState().isEmpty());
            assertTrue(b.getState().isComposing());
        }
    }
}
