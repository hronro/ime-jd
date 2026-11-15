package com.hronro.jd;

// Built on the Java side from the plain arrays Jni.lookupCodes returns, so
// unlike Candidate it needs no shrinker rule.

/**
 * One code a value is typed with — see {@link Engine#lookupCodes}.
 *
 * @param keys the keys: a-z, and {@code ;} in the built-in symbol codes
 * @param index where the value sits in the candidate list after typing exactly
 *     {@code keys} with nothing in flight — 0 is what space commits. It counts
 *     the engine's user phrases on the same code, which lead the built-in
 *     words.
 * @param user whether the code comes from the engine's user dictionary rather
 *     than the built-in tables
 */
public record Code(String keys, int index, boolean user) {}
