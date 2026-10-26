// A user dictionary over libjd's C ABI — port of bindings/swift/UserDict.swift:
// the user's own phrases, compiled once into the blob the engine reads in
// place. Where the phrases live is the app's business (userdict/); the text
// handed to `build` is only the interchange format for that one call.
//
// The engine never copies the blob and reads it for a context's whole
// lifetime (see jd_init in core/include/jd.h). A JVM array can move, so the
// blob here is plain data, and every Engine created with it copies it into
// memory of its own, freed after the context (see jd_jni.c). Candidates cross
// JNI as Strings, so unlike on iOS and macOS nothing a session shows points
// into a dictionary.
package com.hronro.imejd.engine

/**
 * Why a user dictionary could not be built: a failure of the call as a
 * whole, mirroring the `JD_USER_DICT_*` statuses in `core/include/jd.h`. A
 * line that does not parse is never one — the build skips it and says so in
 * a [UserDictNote].
 */
class UserDictError(val status: Status, val line: Int) : Exception(describe(status, line)) {
    enum class Status(val code: Int) {
        /** The output buffer was smaller than the bound (a bug in this wrapper). */
        BUFFER_TOO_SMALL(1),
        /** More than [UserDict.MAX_ENTRIES] phrases; `line` is the first excess one. */
        TOO_MANY_ENTRIES(2),
        /** A cached blob built by a different libjd — format or built-in dictionary differ. Rebuild it. */
        STALE(3),
        /** A cached blob that is structurally invalid. Rebuild it. */
        CORRUPT(4),
        /** The buffer was not 4-byte aligned (a bug in this wrapper). */
        MISALIGNED(5),
        /** The text exceeds `JD_USER_DICT_TEXT_MAX`. */
        TEXT_TOO_LONG(6),
        /** A status this wrapper does not know (a newer library). */
        UNKNOWN(-1);

        companion object {
            fun of(code: Int): Status = entries.firstOrNull { it.code == code } ?: UNKNOWN
        }
    }

    override fun equals(other: Any?): Boolean =
        other is UserDictError && other.status == status && other.line == line

    override fun hashCode(): Int = status.hashCode() * 31 + line

    private companion object {
        fun describe(status: Status, line: Int): String {
            val what = when (status) {
                Status.BUFFER_TOO_SMALL -> "output buffer too small"
                Status.TOO_MANY_ENTRIES -> "more than ${UserDict.MAX_ENTRIES} phrases"
                Status.STALE -> "blob was built against a different dictionary"
                Status.CORRUPT -> "blob is corrupt"
                Status.MISALIGNED -> "blob is not 4-byte aligned"
                Status.TEXT_TOO_LONG -> "text is too long"
                Status.UNKNOWN -> "unknown status"
            }
            return if (status == Status.TOO_MANY_ENTRIES) "line $line: $what" else what
        }
    }
}

/**
 * One thing [UserDict.build] has to say about an input line, mirroring
 * `jd_user_dict_note`. A skipped line (it does not parse) carries exactly one
 * of [MALFORMED], [BAD_KEYS] and [BAD_VALUE]. A dropped line (parsed, but not
 * in the dictionary) carries [REPEATS_LINE] or [REPEATS_BUILT_IN]. A kept line
 * whose code is already taken carries [CODE_IN_BUILT_IN] and/or
 * [CODE_IN_LINE]: the phrase works, listed ahead of the built-in word, but the
 * code is shared (重码).
 */
data class UserDictNote(
    /** 1-based input line. */
    val line: Int,
    /** The `JD_USER_DICT_LINE_*` bits below. */
    val flags: Int,
    /**
     * A kept line this one relates to: for a repeat, the line it repeats (0
     * for a built-in word); for a shared code, the first kept line on that
     * code — and for that first line, the second. 0 otherwise.
     */
    val other: Int,
    /** Built-in words on exactly this code; 0 on a skipped line. */
    val builtIn: Int,
    /** Other kept lines on exactly this code; 0 on a dropped or skipped line. */
    val peers: Int,
) {
    fun has(flag: Int): Boolean = (flags and flag) != 0

    /** Skipped because it does not parse. */
    val isInvalid: Boolean get() = has(MALFORMED or BAD_KEYS or BAD_VALUE)

    /** Parsed, but left out of the dictionary as a duplicate. */
    val isDropped: Boolean get() = has(REPEATS_LINE or REPEATS_BUILT_IN)

    /** In the dictionary, on a code something else uses. */
    val isShared: Boolean get() = has(CODE_IN_BUILT_IN or CODE_IN_LINE)

    companion object {
        /** Dropped: same keys and value as the kept line [other]. */
        const val REPEATS_LINE = 0x1
        /** Dropped: same keys and value as a built-in word. */
        const val REPEATS_BUILT_IN = 0x2
        /** Kept: a built-in word sits on exactly this code ([builtIn] says how many). */
        const val CODE_IN_BUILT_IN = 0x4
        /** Kept: kept line [other] sits on this code too ([peers] says how many do). */
        const val CODE_IN_LINE = 0x8
        /** Skipped: neither blank nor a comment, and no TAB. */
        const val MALFORMED = 0x10
        /** Skipped: keys empty, longer than [UserDict.MAX_KEY_LENGTH], or not all a-z. */
        const val BAD_KEYS = 0x20
        /** Skipped: value empty, too long, not UTF-8, or containing control characters. */
        const val BAD_VALUE = 0x40
    }
}

/** What [UserDict.build] did with the input. */
data class UserDictReport(
    /** Phrases that made it into the dictionary. */
    val entries: Int,
    /** Phrases dropped as exact duplicates, of an earlier line or of a built-in word. */
    val dropped: Int,
    /** Kept phrases on a shared code. */
    val shared: Int,
    /** Lines skipped because they do not parse. */
    val invalid: Int,
    /** One note per skipped, dropped or shared line, ascending by line. */
    val notes: List<UserDictNote>,
)

/**
 * A user dictionary: phrases compiled into the blob the engine reads. Build
 * it from text with [build] and hand it to `Engine(userDict)`, keeping the
 * text as the source of truth. [blob] is the bytes to cache, so a slow device
 * builds once rather than at every start; [fromBlob] takes them back.
 *
 * A blob is tied to the build of libjd it was made with (the format, and the
 * built-in dictionary it was deduplicated against): after an app update
 * [fromBlob] throws [UserDictError.Status.STALE], and the phrases are simply
 * rebuilt.
 */
class UserDict private constructor(
    /** The blob as libjd wrote it; each Engine copies it (see the file comment). */
    val blob: ByteArray,
    /** Phrases in the blob. */
    val entries: Int,
    /**
     * The tag [build] was given — a content hash, a revision — stored in the
     * blob and read back by [fromBlob]. The engine never interprets it.
     */
    val sourceTag: Long,
) {
    class Built(val dict: UserDict, val report: UserDictReport)

    companion object {
        // Mirrors of jd.h's limits. JNI_OnLoad refuses to load against a
        // library whose own entry and value caps differ from the header's.
        /** Most phrases one dictionary may hold (`JD_USER_DICT_MAX_ENTRIES`). */
        const val MAX_ENTRIES = 10_000
        /** Longest value in UTF-8 bytes (`JD_USER_DICT_VALUE_MAX`). */
        const val MAX_VALUE_BYTES = 255
        /** Longest code; jd.h states it in prose (keys are 1 to 6 bytes). */
        const val MAX_KEY_LENGTH = 6

        init {
            // The same library Engine loads; loading it again is a no-op.
            System.loadLibrary("jdjni")
        }

        /**
         * Build from lines of `value<TAB>keys`, the format of libjd's own
         * table files: `#` comments, blank lines skipped, spaces around
         * either field trimmed, CRLF accepted. A line that breaks the rules
         * is skipped and noted, never fatal; exact duplicates are dropped and
         * noted; kept phrases on a shared code are noted. [UserDictError] is
         * thrown only for a problem with the call as a whole: too much text,
         * too many phrases.
         */
        fun build(text: String, sourceTag: Long = 0): Built {
            val result = nativeBuild(text.toByteArray(Charsets.UTF_8), sourceTag)
            val blob = result[0] as ByteArray?
            val report = result[1] as IntArray
            if (blob == null) {
                throw UserDictError(UserDictError.Status.of(report[0]), report[1])
            }
            val notes = (6 until report.size step 5).map { i ->
                UserDictNote(report[i], report[i + 1], report[i + 2], report[i + 3], report[i + 4])
            }
            val summary = UserDictReport(
                entries = report[2], dropped = report[3], shared = report[4],
                invalid = report[5], notes = notes,
            )
            return Built(UserDict(blob, report[2], sourceTag), summary)
        }

        /**
         * Take back a blob cached from [UserDict.blob], validated exactly as
         * jd_init would. [UserDictError.Status.STALE] or
         * [UserDictError.Status.CORRUPT] means "rebuild from the phrases";
         * compare [sourceTag] with the phrases' own to tell whether the cache
         * is still theirs.
         */
        fun fromBlob(blob: ByteArray): UserDict {
            val verdict = nativeCheck(blob)
            val status = verdict[0].toInt()
            if (status != 0) throw UserDictError(UserDictError.Status.of(status), 0)
            return UserDict(blob, verdict[1].toInt(), verdict[2])
        }

        @JvmStatic
        private external fun nativeBuild(text: ByteArray, sourceTag: Long): Array<Any?>

        @JvmStatic
        private external fun nativeCheck(blob: ByteArray): LongArray
    }
}
