package com.hronro.jd;

/**
 * One thing {@link UserDict#build} has to say about an input line, mirroring
 * {@code jd_user_dict_note}. A skipped line, one that does not parse, carries
 * exactly one of {@link #MALFORMED}, {@link #BAD_KEYS} and {@link #BAD_VALUE}.
 * A dropped line, parsed but left out of the dictionary, carries
 * {@link #REPEATS_LINE} or {@link #REPEATS_BUILT_IN}. A kept line whose code
 * is already taken carries {@link #CODE_IN_BUILT_IN} and/or
 * {@link #CODE_IN_LINE}: the phrase works, listed ahead of the built-in word,
 * but the code is shared (重码).
 *
 * @param line the 1-based input line
 * @param flags the bits below
 * @param other a kept line this one relates to: for a repeat, the line it
 *     repeats (0 for a built-in word); for a shared code, the first kept line
 *     on that code, and for that first line, the second. 0 otherwise.
 * @param builtIn built-in words on exactly this code; 0 on a skipped line
 * @param peers other kept lines on exactly this code; 0 on a dropped or
 *     skipped line
 */
public record UserDictNote(int line, int flags, int other, int builtIn, int peers) {
    /** Dropped: the same keys and value as the kept line {@code other}. */
    public static final int REPEATS_LINE = 0x1;
    /** Dropped: the same keys and value as a built-in word. */
    public static final int REPEATS_BUILT_IN = 0x2;
    /** Kept: built-in words sit on exactly this code ({@code builtIn} says how many). */
    public static final int CODE_IN_BUILT_IN = 0x4;
    /** Kept: the kept line {@code other} sits on this code too ({@code peers} says how many do). */
    public static final int CODE_IN_LINE = 0x8;
    /** Skipped: neither blank nor a comment, and no TAB. */
    public static final int MALFORMED = 0x10;
    /** Skipped: keys empty, longer than {@link UserDict#MAX_KEY_LENGTH}, or not all a-z. */
    public static final int BAD_KEYS = 0x20;
    /** Skipped: value empty, too long, not UTF-8, or containing control characters. */
    public static final int BAD_VALUE = 0x40;

    /** Whether any of {@code flag}'s bits are set. */
    public boolean has(int flag) {
        return (flags & flag) != 0;
    }

    /** Skipped, because it does not parse. */
    public boolean isInvalid() {
        return has(MALFORMED | BAD_KEYS | BAD_VALUE);
    }

    /** Parsed, but left out of the dictionary as a duplicate. */
    public boolean isDropped() {
        return has(REPEATS_LINE | REPEATS_BUILT_IN);
    }

    /** In the dictionary, on a code something else uses too. */
    public boolean isShared() {
        return has(CODE_IN_BUILT_IN | CODE_IN_LINE);
    }
}
