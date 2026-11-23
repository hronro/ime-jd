package com.hronro.jd;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import org.jspecify.annotations.Nullable;

/**
 * A dictionary to type from in place of libjd's embedded one: every code and
 * the words on it, built from {@code value<TAB>keys} text by the same code
 * that builds the embedded dictionary, so it types the same way and as fast,
 * at any size up to {@link #MAX_ENTRIES}.
 *
 * <p>Build it once and keep the text as the source of truth: {@link #getBlob}
 * gives the bytes to cache, and {@link #fromBuffer} takes back a cache file
 * mapped into memory, which no engine then copies — the way to load a large
 * dictionary, since an engine reads it in place and it is many megabytes. A
 * build is the slow part, about 0.3 s per million entries on a laptop;
 * checking a blob, which every constructor does exactly as jd_init would, a
 * few tens of milliseconds per million.
 *
 * <p>Pass it to {@link Engine#Engine(Dict, UserDict)}. A user dictionary for
 * it is built and taken back with the {@link UserDict} methods that take a
 * {@code Dict}. libjd-engine, the library built without an embedded
 * dictionary, types from nothing else ({@link #builtinEntries} is 0 there);
 * to type from a user dictionary alone, put it on {@link #empty}.
 */
public final class Dict {
    // Mirrors of jd.h's limits, checked against the library by JNI_OnLoad.

    /** The most entries one dictionary may hold ({@code JD_DICT_MAX_ENTRIES}). */
    public static final int MAX_ENTRIES = 16_777_215;

    /** The longest value, in UTF-8 bytes ({@code JD_DICT_VALUE_MAX}). */
    public static final int MAX_VALUE_BYTES = 1023;

    /** The most text one build reads, in UTF-8 bytes ({@code JD_DICT_TEXT_MAX}). */
    public static final long MAX_TEXT_BYTES = 4_294_967_295L;

    /**
     * A dictionary, and what its build had to say about the input.
     *
     * @param dict the dictionary
     * @param report the counts, and a note on every line skipped or dropped
     *     ({@code shared} is always 0)
     */
    public record Built(Dict dict, UserDictReport report) {}

    // The blob, in exactly one of two places, as for UserDict: an array of
    // this object's own, which every Engine copies into native memory, or a
    // direct buffer, which every Engine reads where it is.
    private final byte @Nullable [] blob;
    private final @Nullable ByteBuffer buffer;
    private final int entries;
    private final long sourceTag;

    private Dict(byte @Nullable [] blob, @Nullable ByteBuffer buffer, int entries, long sourceTag) {
        this.blob = blob;
        this.buffer = buffer;
        this.entries = entries;
        this.sourceTag = sourceTag;
    }

    /** The blob as libjd's calls take it: the array, or the direct buffer. */
    Object nativeBlob() {
        return buffer != null ? buffer : blob;
    }

    /** How many entries libjd's embedded dictionary holds: 0 in libjd-engine. */
    public static int builtinEntries() {
        return Jni.builtinEntries();
    }

    /**
     * The empty dictionary: no codes at all. An engine on it types from its
     * user dictionary alone, which is built on the same empty dictionary.
     * Every empty dictionary is the same dictionary, so a user dictionary
     * built on one works on any.
     */
    public static Dict empty() {
        try {
            return build(new byte[0], 0).dict();
        } catch (UserDictException e) {
            throw new IllegalStateException("libjd failed to build an empty dictionary", e);
        }
    }

    /** Builds from {@code text} with a source tag of 0; see {@link #build(String, long)}. */
    public static Built build(String text) throws UserDictException {
        return build(text, 0);
    }

    /**
     * Builds a dictionary from lines of {@code value<TAB>keys}, by the rules
     * of {@link UserDict#build(String, long)}: lines that do not parse are
     * skipped and exact repeats dropped, each with a note. The words on one
     * code are its candidates in the order of their lines.
     *
     * @param sourceTag 64 bits of the caller's own, stored in the blob and
     *     read back by {@link #fromBlob}, never interpreted
     * @throws UserDictException only for a problem with the call as a whole:
     *     too much text, or too many entries
     */
    public static Built build(String text, long sourceTag) throws UserDictException {
        return build(text.getBytes(StandardCharsets.UTF_8), sourceTag);
    }

    /** {@link #build(String, long)} from UTF-8 bytes as they are; a byte-order mark is not skipped. */
    public static Built build(byte[] utf8, long sourceTag) throws UserDictException {
        UserDict.Result result = UserDict.result(Jni.dictBuild(utf8, sourceTag));
        return new Built(new Dict(result.blob(), null, result.report().entries(), sourceTag), result.report());
    }

    /**
     * Takes back a blob cached from {@link #getBlob}, validated exactly as
     * jd_init would. An engine copies it again into native memory: prefer
     * {@link #fromBuffer} for a large dictionary.
     *
     * @throws UserDictException with {@link UserDictException.Status#STALE}
     *     or {@link UserDictException.Status#CORRUPT}, which mean "build it
     *     again from the text"
     */
    public static Dict fromBlob(byte[] blob) throws UserDictException {
        byte[] own = blob.clone();
        long[] verdict = UserDict.verdict(Jni.dictCheck(own));
        return new Dict(own, null, (int) verdict[1], verdict[2]);
    }

    /**
     * A cached blob in a direct buffer, between its position and its limit,
     * used where it is — typically a {@link java.nio.MappedByteBuffer} of the
     * cache file. Validated exactly as jd_init would. The bytes must not
     * change while the dictionary, or an engine created with it, is in use.
     *
     * @throws IllegalArgumentException if the buffer is not direct
     * @throws UserDictException with {@link UserDictException.Status#STALE},
     *     {@link UserDictException.Status#CORRUPT} or
     *     {@link UserDictException.Status#MISALIGNED}
     */
    public static Dict fromBuffer(ByteBuffer blob) throws UserDictException {
        ByteBuffer own = UserDict.direct(blob);
        long[] verdict = UserDict.verdict(Jni.dictCheck(own));
        return new Dict(null, own, (int) verdict[1], verdict[2]);
    }

    /** The blob, to cache for {@link #fromBlob}: a copy. */
    public byte[] getBlob() {
        return UserDict.copyOf(blob, buffer);
    }

    /** How many entries the dictionary holds. */
    public int getEntries() {
        return entries;
    }

    /** The tag the dictionary was built with, as stored in the blob. */
    public long getSourceTag() {
        return sourceTag;
    }
}
