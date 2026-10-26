package com.hronro.jd;

import org.jspecify.annotations.Nullable;

// Built by the native side (jd_jni.c), through the canonical constructor:
// META-INF/proguard/jd.pro keeps both through shrinking.

/**
 * What the engine holds after an operation.
 *
 * @param commit the last operation's committed text, already joined from the
 *     ABI's segments, or null when it committed nothing
 * @param optionsCount how many candidates are in flight; read them with
 *     {@link Engine#readRange}
 * @param anchorIndex the candidate the engine's own automatic commits resolve
 *     against: space and the literal-byte fallbacks take it, {@code ;} takes
 *     the next one
 */
public record EngineState(@Nullable String commit, int optionsCount, int anchorIndex) {
    /** No commit, and nothing in flight. */
    public static final EngineState EMPTY = new EngineState(null, 0, 0);

    /** Whether candidates are in flight. */
    public boolean isComposing() {
        return optionsCount > 0;
    }

    /** Whether the operation committed text. */
    public boolean hasCommit() {
        return commit != null;
    }

    /** Neither a commit nor candidates in flight. */
    public boolean isEmpty() {
        return commit == null && optionsCount == 0;
    }
}
