/**
 * Java bindings for libjd, the 键道 input engine.
 *
 * <p>An {@link com.hronro.jd.Engine} is one input context: keystrokes go in,
 * candidates and committed text come out. A {@link com.hronro.jd.UserDict}
 * compiles the user's own phrases into a blob that every engine created with
 * it merges into its candidate lists.
 *
 * <p>Nothing in this package is null unless it is marked {@code @Nullable}.
 */
@NullMarked
package com.hronro.jd;

import org.jspecify.annotations.NullMarked;
