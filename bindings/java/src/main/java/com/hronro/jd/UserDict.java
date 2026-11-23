package com.hronro.jd;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * A user dictionary: the user's own phrases, compiled into the blob that every
 * {@link Engine} created with it merges into its candidate lists.
 *
 * <p>Build one from text with {@link #build}, and keep the text as the source
 * of truth. {@link #getBlob} gives the bytes to cache, so a slow device builds
 * once rather than at every start, and {@link #fromBlob} takes them back — or
 * {@link #fromBuffer}, for a cache file mapped into memory, which no engine
 * then copies. {@link #hash} tags a build with the text it came from. A
 * blob is tied to the build of libjd that made it, by its format and by the
 * dictionary it was deduplicated against: after a library update, {@code
 * fromBlob} throws {@link UserDictException.Status#STALE}, and the phrases
 * are simply built again.
 *
 * <p>The phrases sit on libjd's embedded dictionary, or on a {@link Dict} of
 * your own: the methods that take a {@code Dict} build and take back a user
 * dictionary for an {@link Engine#Engine(Dict, UserDict)} on it.
 */
public final class UserDict {
    // Mirrors of jd.h's limits. JNI_OnLoad refuses a library whose own entry,
    // value and text caps differ from the header's.

    /** The most phrases one dictionary may hold ({@code JD_USER_DICT_MAX_ENTRIES}). */
    public static final int MAX_ENTRIES = 500_000;

    /** The longest value, in UTF-8 bytes ({@code JD_USER_DICT_VALUE_MAX}), as a dictionary's. */
    public static final int MAX_VALUE_BYTES = 1023;

    /** The most text one build reads, in UTF-8 bytes ({@code JD_USER_DICT_TEXT_MAX}). */
    public static final int MAX_TEXT_BYTES = 16 * 1024 * 1024;

    /** The longest code. jd.h states it in prose: 1 to 6 of a-z and {@code ;}. */
    public static final int MAX_KEY_LENGTH = 6;

    /**
     * A dictionary, and what its build had to say about the input.
     *
     * @param dict the dictionary
     * @param report the counts, and a note on every line skipped, dropped or
     *     sharing a code
     */
    public record Built(UserDict dict, UserDictReport report) {}

    // The blob, in exactly one of two places. As libjd wrote it, in an array
    // this object's alone: getBlob hands out a copy, and every Engine copies
    // it once more, into native memory, because jd_init reads a blob in place
    // for the context's whole lifetime and a JVM array can move. Or in a
    // direct buffer — a mapped file — which does not move: every Engine reads
    // it where it is, and holds this object, and so the buffer, until closed.
    final byte @Nullable [] blob;
    final @Nullable ByteBuffer buffer;
    private final int entries;
    private final long sourceTag;

    private UserDict(byte @Nullable [] blob, @Nullable ByteBuffer buffer, int entries, long sourceTag) {
        this.blob = blob;
        this.buffer = buffer;
        this.entries = entries;
        this.sourceTag = sourceTag;
    }

    /**
     * libjd's content hash ({@code jd_user_dict_hash}) of {@code bytes}, for a
     * {@code sourceTag}: hash the text a dictionary is built from, hash it
     * again before trusting a cached blob, and a blob whose tag differs was
     * built from something else. Gigabytes a second, so a whole phrases file
     * costs well under a millisecond. The same bytes hash the same on every
     * platform and in every release.
     */
    public static long hash(byte[] bytes) {
        return Jni.userDictHash(bytes);
    }

    /**
     * {@link #hash(byte[])} of the bytes between a direct buffer's position and
     * its limit — a mapped file, hashed without reading it into the heap.
     *
     * @throws IllegalArgumentException if the buffer is not direct
     */
    public static long hash(ByteBuffer bytes) {
        return Jni.userDictHashDirect(direct(bytes));
    }

    /** The bytes from position to limit as a buffer of their own, which must be direct. */
    static ByteBuffer direct(ByteBuffer bytes) {
        if (!bytes.isDirect()) {
            throw new IllegalArgumentException("not a direct buffer");
        }
        return bytes.slice();
    }

    /** Builds from {@code text} with a source tag of 0; see {@link #build(String, long)}. */
    public static Built build(String text) throws UserDictException {
        return build(text, 0);
    }

    /**
     * Builds a dictionary from lines of {@code value<TAB>keys}, the line format
     * of libjd's own table files, read exactly as {@code jd.h} describes:
     * blank lines and {@code #} comments are skipped, spaces around either
     * field are trimmed, CRLF is accepted, and keys are one to six of a-z
     * and {@code ;}, with no {@code ;} after a letter. A line that breaks the
     * rules is skipped and noted, never fatal; exact duplicates, of an
     * earlier line or of a word on the same code in the embedded dictionary,
     * are dropped and noted; kept phrases on a shared code are noted.
     *
     * @param sourceTag 64 bits of the caller's own, such as a content hash or
     *     a revision, stored in the blob and read back by {@link #fromBlob},
     *     so a cache can tell which text it holds. The engine never
     *     interprets it.
     * @throws UserDictException only for a problem with the call as a whole:
     *     too much text, or too many phrases
     */
    public static Built build(String text, long sourceTag) throws UserDictException {
        return build(text.getBytes(StandardCharsets.UTF_8), sourceTag);
    }

    /**
     * {@link #build(String, long)} from UTF-8 bytes as they are — a file as
     * read, say, so the text is never decoded or encoded. A byte-order mark is
     * not skipped (libjd would take U+FEFF as part of line 1): drop one first.
     */
    public static Built build(byte[] utf8, long sourceTag) throws UserDictException {
        return built(Jni.userDictBuild(null, utf8, sourceTag), sourceTag);
    }

    /**
     * {@link #build(String, long)} on {@code dict} instead of the embedded
     * dictionary: phrases that repeat its words are dropped, the notes name
     * its words on a shared code, and the result works only with an engine
     * on {@code dict}.
     */
    public static Built build(Dict dict, String text, long sourceTag) throws UserDictException {
        return build(dict, text.getBytes(StandardCharsets.UTF_8), sourceTag);
    }

    /** {@link #build(Dict, String, long)} from UTF-8 bytes as they are. */
    public static Built build(Dict dict, byte[] utf8, long sourceTag) throws UserDictException {
        return built(Jni.userDictBuild(dict.nativeBlob(), utf8, sourceTag), sourceTag);
    }

    private static Built built(@Nullable Object[] raw, long sourceTag) throws UserDictException {
        Result result = result(raw);
        return new Built(new UserDict(result.blob(), null, result.report().entries(), sourceTag), result.report());
    }

    /** A build's blob and report, from the {blob, int[] report} pair Jni returns. */
    record Result(byte[] blob, UserDictReport report) {}

    static Result result(@Nullable Object[] raw) throws UserDictException {
        if (raw == null) {
            throw new OutOfMemoryError("dictionary build");
        }
        byte[] blob = (byte[]) raw[0];
        int[] report = (int[]) raw[1];
        if (blob == null) {
            throw new UserDictException(UserDictException.Status.of(report[0]), report[1]);
        }
        List<UserDictNote> notes = new ArrayList<>((report.length - 6) / 5);
        for (int i = 6; i + 4 < report.length; i += 5) {
            notes.add(new UserDictNote(report[i], report[i + 1], report[i + 2], report[i + 3], report[i + 4]));
        }
        return new Result(blob, new UserDictReport(report[2], report[3], report[4], report[5], notes));
    }

    /** A check's {status, entries, source tag}, or the exception its status means. */
    static long[] verdict(long[] verdict) throws UserDictException {
        int status = (int) verdict[0];
        if (status != 0) {
            throw new UserDictException(UserDictException.Status.of(status), 0);
        }
        return verdict;
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
        return fromBlob(null, blob);
    }

    /** {@link #fromBlob(byte[])} for a blob built on {@code dict}. */
    public static UserDict fromBlob(@Nullable Dict dict, byte[] blob) throws UserDictException {
        // The caller's array stays the caller's: check and keep a copy.
        byte[] own = blob.clone();
        long[] verdict = verdict(Jni.userDictCheck(dict == null ? null : dict.nativeBlob(), own));
        return new UserDict(own, null, (int) verdict[1], verdict[2]);
    }

    /**
     * A cached blob in a direct buffer, between its position and its limit,
     * used where it is: typically a {@link java.nio.MappedByteBuffer} of the
     * cache file, which then never enters the heap and no engine copies.
     * Validated exactly as jd_init would. The bytes must not change while the
     * dictionary, or an engine created with it, is in use — replace a mapped
     * file atomically, never rewrite it in place.
     *
     * @throws IllegalArgumentException if the buffer is not direct
     * @throws UserDictException with {@link UserDictException.Status#STALE},
     *     {@link UserDictException.Status#CORRUPT} or
     *     {@link UserDictException.Status#MISALIGNED}, which mean "build it
     *     again from the phrases"
     */
    public static UserDict fromBuffer(ByteBuffer blob) throws UserDictException {
        return fromBuffer(null, blob);
    }

    /** {@link #fromBuffer(ByteBuffer)} for a blob built on {@code dict}. */
    public static UserDict fromBuffer(@Nullable Dict dict, ByteBuffer blob) throws UserDictException {
        ByteBuffer own = direct(blob);
        long[] verdict = verdict(Jni.userDictCheck(dict == null ? null : dict.nativeBlob(), own));
        return new UserDict(null, own, (int) verdict[1], verdict[2]);
    }

    /** The blob as libjd's calls take it: the array, or the direct buffer. */
    Object nativeBlob() {
        return buffer != null ? buffer : blob;
    }

    /** The blob, to cache for {@link #fromBlob}: a copy, so changing it changes nothing here. */
    public byte[] getBlob() {
        return copyOf(blob, buffer);
    }

    /** A copy of a blob held in an array or a buffer. */
    static byte[] copyOf(byte @Nullable [] blob, @Nullable ByteBuffer buffer) {
        if (blob != null) {
            return blob.clone();
        }
        ByteBuffer view = buffer.duplicate();
        byte[] copy = new byte[view.remaining()];
        view.get(copy);
        return copy;
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
