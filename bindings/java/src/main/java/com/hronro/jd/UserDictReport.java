package com.hronro.jd;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * What {@link UserDict#build} did with its input.
 *
 * @param entries phrases that made it into the dictionary
 * @param dropped phrases dropped as exact duplicates, of an earlier line or
 *     of a built-in word
 * @param shared kept phrases on a shared code
 * @param invalid lines skipped because they do not parse
 * @param notes a note on every skipped, dropped or shared line, ascending by
 *     line
 */
public record UserDictReport(int entries, int dropped, int shared, int invalid, List<UserDictNote> notes) {
    /** Keeps an unmodifiable copy of {@code notes}. */
    public UserDictReport {
        // Not List.copyOf: Android has it only from API 30.
        notes = Collections.unmodifiableList(new ArrayList<>(notes));
    }
}
