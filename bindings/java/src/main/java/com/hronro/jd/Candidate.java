package com.hronro.jd;

import org.jspecify.annotations.Nullable;

// Built by the native side (jd_jni.c), which makes Strings for exactly the
// window Engine.readRange asks for. META-INF/proguard/jd.pro keeps the class
// and its canonical constructor through shrinking.

/**
 * One candidate: the committable text, and the keys still needed to reach it.
 *
 * @param value the committable text
 * @param hint the keys still needed below this candidate, or null when its
 *     code is complete
 */
public record Candidate(String value, @Nullable String hint) {}
