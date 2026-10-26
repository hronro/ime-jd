package com.hronro.jd;

/**
 * Why a user dictionary could not be built or taken back: a failure of the
 * call as a whole, mirroring the {@code JD_USER_DICT_*} statuses in
 * {@code jd.h}. A line that does not parse is never one; the build skips it
 * and says so in a {@link UserDictNote}.
 */
public final class UserDictException extends Exception {
    private static final long serialVersionUID = 1L;

    /** A {@code JD_USER_DICT_*} status. */
    public enum Status {
        /** The output buffer was smaller than the bound (a bug in this binding). */
        BUFFER_TOO_SMALL(1),
        /** More than {@link UserDict#MAX_ENTRIES} phrases; the line is the first one past the cap. */
        TOO_MANY_ENTRIES(2),
        /** A cached blob built by a different libjd: the format or the built-in dictionary differ. */
        STALE(3),
        /** A cached blob that is structurally invalid. */
        CORRUPT(4),
        /** The buffer was not 4-byte aligned (a bug in this binding). */
        MISALIGNED(5),
        /** The text exceeds {@code JD_USER_DICT_TEXT_MAX}. */
        TEXT_TOO_LONG(6),
        /** A status this binding does not know, from a newer library. */
        UNKNOWN(-1);

        private final int code;

        Status(int code) {
            this.code = code;
        }

        /** The {@code JD_USER_DICT_*} value; -1 for {@link #UNKNOWN}. */
        public int getCode() {
            return code;
        }

        static Status of(int code) {
            for (Status status : values()) {
                if (status.code == code) {
                    return status;
                }
            }
            return UNKNOWN;
        }
    }

    private final Status status;
    private final int line;

    /**
     * @param status what went wrong
     * @param line the 1-based line {@code status} is about, or 0
     */
    public UserDictException(Status status, int line) {
        super(describe(status, line));
        this.status = status;
        this.line = line;
    }

    /** What went wrong. */
    public Status getStatus() {
        return status;
    }

    /** For {@link Status#TOO_MANY_ENTRIES}, the first line past the cap; 0 otherwise. */
    public int getLine() {
        return line;
    }

    private static String describe(Status status, int line) {
        String what = switch (status) {
            case BUFFER_TOO_SMALL -> "output buffer too small";
            case TOO_MANY_ENTRIES -> "more than " + UserDict.MAX_ENTRIES + " phrases";
            case STALE -> "blob was built against a different dictionary";
            case CORRUPT -> "blob is corrupt";
            case MISALIGNED -> "blob is not 4-byte aligned";
            case TEXT_TOO_LONG -> "text is too long";
            case UNKNOWN -> "unknown status";
        };
        return status == Status.TOO_MANY_ENTRIES ? "line " + line + ": " + what : what;
    }
}
