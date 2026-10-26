package com.hronro.jd;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * A user dictionary: the user's own phrases, compiled into the blob that every
 * {@link Engine} created with it merges into its candidate lists.
 *
 * <p>Build one from text with {@link #build}, and keep the text as the source
 * of truth. {@link #getBlob} gives the bytes to cache, so a slow device builds
 * once rather than at every start, and {@link #fromBlob} takes them back. A
 * blob is tied to the build of libjd that made it, by its format and by the
 * built-in dictionary it was deduplicated against: after a library update,
 * {@code fromBlob} throws {@link UserDictException.Status#STALE}, and the
 * phrases are simply built again.
 */
public final class UserDict {
    // Mirrors of jd.h's limits. JNI_OnLoad refuses a library whose own entry
    // and value caps differ from the header's.

    /** The most phrases one dictionary may hold ({@code JD_USER_DICT_MAX_ENTRIES}). */
    public static final int MAX_ENTRIES = 10_000;

    /** The longest value, in UTF-8 bytes ({@code JD_USER_DICT_VALUE_MAX}). */
    public static final int MAX_VALUE_BYTES = 255;

    /** The longest code. jd.h states it in prose: keys are 1 to 6 letters. */
    public static final int MAX_KEY_LENGTH = 6;

    /**
     * A dictionary, and what its build had to say about the input.
     *
     * @param dict the dictionary
     * @param report the counts, and a note on every line skipped, dropped or
     *     sharing a code
     */
    public record Built(UserDict dict, UserDictReport report) {}

    // The blob as libjd wrote it, and this object's alone: getBlob hands out a
    // copy, and every Engine copies it once more, into native memory, because
    // jd_init reads a blob in place for the context's whole lifetime and a JVM
    // array can move.
    final byte[] blob;
    private final int entries;
    private final long sourceTag;

    private UserDict(byte[] blob, int entries, long sourceTag) {
        this.blob = blob;
        this.entries = entries;
        this.sourceTag = sourceTag;
    }

    /** Builds from {@code text} with a source tag of 0; see {@link #build(String, long)}. */
    public static Built build(String text) throws UserDictException {
        return build(text, 0);
    }

    /**
     * Builds a dictionary from lines of {@code value<TAB>keys}, the line format
     * of libjd's own table files, read exactly as {@code jd.h} describes:
     * blank lines and {@code #} comments are skipped, spaces around either
     * field are trimmed, CRLF is accepted, and keys are one to six letters
     * a-z. A line that breaks the rules is skipped and noted, never fatal;
     * exact duplicates are dropped and noted; kept phrases on a shared code
     * are noted.
     *
     * @param sourceTag 64 bits of the caller's own, such as a content hash or
     *     a revision, stored in the blob and read back by {@link #fromBlob},
     *     so a cache can tell which text it holds. The engine never
     *     interprets it.
     * @throws UserDictException only for a problem with the call as a whole:
     *     too much text, or too many phrases
     */
    public static Built build(String text, long sourceTag) throws UserDictException {
        Object[] result = Jni.userDictBuild(text.getBytes(StandardCharsets.UTF_8), sourceTag);
        byte[] blob = (byte[]) result[0];
        int[] report = (int[]) result[1];
        if (blob == null) {
            throw new UserDictException(UserDictException.Status.of(report[0]), report[1]);
        }
        List<UserDictNote> notes = new ArrayList<>((report.length - 6) / 5);
        for (int i = 6; i + 4 < report.length; i += 5) {
            notes.add(new UserDictNote(report[i], report[i + 1], report[i + 2], report[i + 3], report[i + 4]));
        }
        UserDictReport summary = new UserDictReport(report[2], report[3], report[4], report[5], notes);
        return new Built(new UserDict(blob, report[2], sourceTag), summary);
    }

    /**
     * Takes back a blob cached from {@link #getBlob}, validated exactly as
     * jd_init would. Compare {@link #getSourceTag} with the phrases' own to
     * tell whether the cache is still theirs.
     *
     * @throws UserDictException with {@link UserDictException.Status#STALE} or
     *     {@link UserDictException.Status#CORRUPT}, which mean "build it again
     *     from the phrases"
     */
    public static UserDict fromBlob(byte[] blob) throws UserDictException {
        // The caller's array stays the caller's: check and keep a copy.
        byte[] own = blob.clone();
        long[] verdict = Jni.userDictCheck(own);
        int status = (int) verdict[0];
        if (status != 0) {
            throw new UserDictException(UserDictException.Status.of(status), 0);
        }
        return new UserDict(own, (int) verdict[1], verdict[2]);
    }

    /** The blob, to cache for {@link #fromBlob}: a copy, so changing it changes nothing here. */
    public byte[] getBlob() {
        return blob.clone();
    }

    /** How many phrases the dictionary holds. */
    public int getEntries() {
        return entries;
    }

    /** The tag the dictionary was built with, as stored in the blob. */
    public long getSourceTag() {
        return sourceTag;
    }
}
