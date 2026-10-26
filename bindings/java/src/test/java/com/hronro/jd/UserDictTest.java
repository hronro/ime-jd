// The UserDict wrapper driven through the real engine: the Java counterpart of
// macos/JdIMETests/UserDictTests.swift, which mirrors
// bindings/rust/tests/engine.rs.
package com.hronro.jd;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class UserDictTest {
    private static void type(Engine e, String keys) {
        for (char key : keys.toCharArray()) {
            e.pressKey((byte) key);
        }
    }

    private static List<String> values(List<Candidate> window) {
        return window.stream().map(Candidate::value).toList();
    }

    /** Phrases 词{@code from} to 词{@code to}, one per line, all on the free code zzzzzz. */
    private static String phrases(int from, int to) {
        StringBuilder text = new StringBuilder();
        for (int i = from; i <= to; i++) {
            text.append('词').append(i).append("\tzzzzzz\n");
        }
        return text.toString();
    }

    @Test
    void userPhrasesLeadTheBuiltInCandidatesOnASharedCode() throws UserDictException {
        // 'b' → 不 in the built-in tables; the user adds a word on the same
        // code and repeats a built-in one, which is dropped.
        UserDict.Built built = UserDict.build("测试词\tb\n不\tb\n");
        UserDictReport report = built.report();
        assertEquals(1, report.entries());
        assertEquals(1, report.dropped());
        assertEquals(
                List.of(2),
                report.notes().stream().filter(UserDictNote::isDropped).map(UserDictNote::line).toList());
        assertEquals(1, built.dict().getEntries());

        try (Engine e = new Engine(built.dict())) {
            type(e, "b");
            assertEquals(List.of("测试词", "不"), values(e.readRange(0, 2)));
            assertEquals("测试词", e.pressKey((byte) ' ').commit(), "the user word is what space commits");
        }
        try (Engine plain = new Engine()) {
            type(plain, "b");
            assertEquals("不", plain.readRange(0, 1).get(0).value(), "a plain context is unaffected");
        }
    }

    @Test
    void aUserOnlyCodeComposesWithHintsAndAutoCommits() throws UserDictException {
        UserDict dict = UserDict.build("键道\tzzzzzz\n键道输入法\tzzzzza\n").dict();
        try (Engine e = new Engine(dict)) {
            type(e, "zzzzz");
            assertNull(e.getState().commit());
            List<Candidate> window = e.readRange(0, 4);
            assertEquals(List.of("键道输入法", "键道"), values(window));
            assertEquals(List.of("a", "z"), window.stream().map(Candidate::hint).toList());
            EngineState state = e.pressKey((byte) 'z');
            assertEquals("键道", state.commit());
            assertEquals(0, state.optionsCount());
        }
    }

    @Test
    void badLinesAreSkippedAndNotedNeverFatal() throws UserDictException {
        // "zzzzzz" and "zzzzza" are free in the built-in tables, so the only
        // notes are the skipped lines'.
        UserDict.Built built = UserDict.build("键道\tzzzzzz\nno tab\n好\tZZZZZA\n\tzzzzza\n");
        UserDictReport report = built.report();
        assertEquals(1, built.dict().getEntries());
        assertEquals(1, report.entries());
        assertEquals(3, report.invalid());
        assertEquals(0, report.dropped());
        assertEquals(
                List.of(
                        new UserDictNote(2, UserDictNote.MALFORMED, 0, 0, 0),
                        new UserDictNote(3, UserDictNote.BAD_KEYS, 0, 0, 0),
                        new UserDictNote(4, UserDictNote.BAD_VALUE, 0, 0, 0)),
                report.notes());
        assertTrue(report.notes().stream().allMatch(n -> n.isInvalid() && !n.isDropped() && !n.isShared()));
    }

    @Test
    void notesSayWhatALineRepeatsAndWhichCodesAreShared() throws UserDictException {
        // 'b' carries built-in words; "zzzzzz" and "zzzzza" are free.
        UserDictReport report = UserDict.build("测试词\tb\n一\tzzzzzz\n二\tzzzzzz\n键道\tzzzzza\n不\tb\n").report();
        assertEquals(4, report.entries());
        assertEquals(1, report.dropped());
        assertEquals(3, report.shared());
        int wordsOnB = report.notes().get(0).builtIn();
        assertTrue(wordsOnB >= 1);
        assertEquals(
                List.of(
                        new UserDictNote(1, UserDictNote.CODE_IN_BUILT_IN, 0, wordsOnB, 0),
                        new UserDictNote(2, UserDictNote.CODE_IN_LINE, 3, 0, 1),
                        new UserDictNote(3, UserDictNote.CODE_IN_LINE, 2, 0, 1),
                        new UserDictNote(5, UserDictNote.REPEATS_BUILT_IN, 0, wordsOnB, 0)),
                report.notes());
        assertTrue(report.notes().get(0).isShared());
        assertFalse(report.notes().get(0).isDropped());
        assertTrue(report.notes().get(3).isDropped());
        assertFalse(report.notes().get(3).isShared());

        assertEquals(List.of(), UserDict.build("键道\tzzzzzz\n").report().notes(), "nothing to say about a clean file");
    }

    @Test
    void anEmptyDictionaryIsValidAndInert() throws UserDictException {
        UserDict dict = UserDict.build("").dict();
        assertEquals(0, dict.getEntries());
        try (Engine withDict = new Engine(dict);
                Engine plain = new Engine()) {
            type(withDict, "a");
            type(plain, "a");
            assertEquals(plain.getState(), withDict.getState());
            assertEquals(plain.readRange(0, 9), withDict.readRange(0, 9));
        }
    }

    /**
     * A dictionary's bytes are its own: fromBlob copies the caller's array and
     * getBlob hands out a copy, so neither changes what an engine reads. (Each
     * engine reads a native copy of its own besides: jd_init reads the blob in
     * place, and a JVM array can move.)
     */
    @Test
    void aDictionaryKeepsItsBytesToItself() throws UserDictException {
        byte[] cached = UserDict.build("键道\tzzzzzz\n").dict().getBlob();
        UserDict dict = UserDict.fromBlob(cached);
        Arrays.fill(cached, (byte) 0);
        Arrays.fill(dict.getBlob(), (byte) 0);
        try (Engine e = new Engine(dict)) {
            type(e, "zzzzz");
            assertEquals(List.of("键道"), values(e.readRange(0, 4)));
        }
    }

    @Test
    void wholeCallFailuresAreThrownWithTheirLine() {
        String tooMany = phrases(0, UserDict.MAX_ENTRIES);
        UserDictException error = assertThrows(UserDictException.class, () -> UserDict.build(tooMany));
        assertEquals(UserDictException.Status.TOO_MANY_ENTRIES, error.getStatus());
        assertEquals(UserDict.MAX_ENTRIES + 1, error.getLine(), "the first excess phrase");

        String tooLong = "#" + "x".repeat(8 * 1024 * 1024); // JD_USER_DICT_TEXT_MAX, plus the '#'
        UserDictException refused = assertThrows(UserDictException.class, () -> UserDict.build(tooLong));
        assertEquals(UserDictException.Status.TEXT_TOO_LONG, refused.getStatus());
        assertEquals(0, refused.getLine());
    }

    @Test
    void cachedBlobsRoundTripAndCorruptionIsCaught() throws UserDictException {
        long tag = 0x0123_4567_89ab_cdefL;
        UserDict dict = UserDict.build("# comment\n键道\tzzzzzz\n", tag).dict();
        assertEquals(1, dict.getEntries());
        assertEquals(tag, dict.getSourceTag());

        // The tag and the count survive the trip through a cache.
        UserDict again = UserDict.fromBlob(dict.getBlob());
        assertEquals(tag, again.getSourceTag());
        assertEquals(1, again.getEntries());
        try (Engine e = new Engine(again)) {
            type(e, "zzzzzz");
            assertEquals("键道", e.getState().commit(), "the engine reads the cached copy like the original");
        }

        byte[] blob = dict.getBlob();
        byte[] truncated = Arrays.copyOf(blob, blob.length - 1);
        assertEquals(
                UserDictException.Status.CORRUPT,
                assertThrows(UserDictException.class, () -> UserDict.fromBlob(truncated)).getStatus());
        // The built-in dictionary's fingerprint lives in the header: another libjd's blob is stale.
        byte[] stale = dict.getBlob();
        stale[12] ^= (byte) 0xFF;
        assertEquals(
                UserDictException.Status.STALE,
                assertThrows(UserDictException.class, () -> UserDict.fromBlob(stale)).getStatus());
        assertEquals(
                UserDictException.Status.CORRUPT,
                assertThrows(UserDictException.class, () -> UserDict.fromBlob(new byte[0])).getStatus());
    }

    @Test
    void theLimitsMatchTheLibrary() throws UserDictException {
        // Exactly at the caps is fine; one past is the engine's to refuse.
        assertEquals(UserDict.MAX_ENTRIES, UserDict.build(phrases(1, UserDict.MAX_ENTRIES)).report().entries());
        String longest = "字".repeat(UserDict.MAX_VALUE_BYTES / 3); // 3 UTF-8 bytes each
        assertEquals(0, UserDict.build(longest + "\tzzzzzz\n").report().invalid());
        assertEquals(1, UserDict.build(longest + "字\tzzzzzz\n").report().invalid());
        assertEquals(1, UserDict.build("长\t" + "z".repeat(UserDict.MAX_KEY_LENGTH + 1) + "\n").report().invalid());
    }
}
