/*
 * libjd's calls (core/include/jd.h), the part the editor uses: building the
 * phrases file, for the notes the build leaves on its lines and for its
 * verdict on the file as a whole, and 编码反查's lookup, on a context of its
 * own over the built-in dictionary and, built here, the user's.
 */
[CCode (cheader_filename = "jd.h")]
namespace Jd {
    [CCode (cname = "JD_USER_DICT_MAX_ENTRIES")]
    public const uint USER_DICT_MAX_ENTRIES;
    [CCode (cname = "JD_USER_DICT_VALUE_MAX")]
    public const uint USER_DICT_VALUE_MAX;

    [CCode (cname = "JD_USER_DICT_OK")]
    public const uint USER_DICT_OK;
    [CCode (cname = "JD_USER_DICT_TOO_MANY_ENTRIES")]
    public const uint USER_DICT_TOO_MANY_ENTRIES;
    [CCode (cname = "JD_USER_DICT_TEXT_TOO_LONG")]
    public const uint USER_DICT_TEXT_TOO_LONG;

    [CCode (cname = "JD_USER_DICT_LINE_REPEATS_LINE")]
    public const uint LINE_REPEATS_LINE;
    [CCode (cname = "JD_USER_DICT_LINE_REPEATS_BUILTIN")]
    public const uint LINE_REPEATS_BUILTIN;
    [CCode (cname = "JD_USER_DICT_LINE_CODE_IN_BUILTIN")]
    public const uint LINE_CODE_IN_BUILTIN;
    [CCode (cname = "JD_USER_DICT_LINE_CODE_IN_LINE")]
    public const uint LINE_CODE_IN_LINE;
    [CCode (cname = "JD_USER_DICT_LINE_MALFORMED")]
    public const uint LINE_MALFORMED;
    [CCode (cname = "JD_USER_DICT_LINE_BAD_KEYS")]
    public const uint LINE_BAD_KEYS;
    [CCode (cname = "JD_USER_DICT_LINE_BAD_VALUE")]
    public const uint LINE_BAD_VALUE;

    [CCode (cname = "jd_user_dict_note", has_type_id = false, has_copy_function = false, has_destroy_function = false)]
    public struct UserDictNote {
        public uint line;
        public uint flags;
        public uint other;
        public uint builtin;
        public uint peers;
    }

    [CCode (cname = "jd_user_dict_report", has_type_id = false, has_copy_function = false, has_destroy_function = false)]
    public struct UserDictReport {
        public uint status;
        public uint line;
        public uint entries;
        public uint dropped;
        public uint shared;
        public uint invalid;
        public uint notes;
        public uint notes_offset;
    }

    [CCode (cname = "jd_user_dict_blob_bound")]
    public size_t user_dict_blob_bound (string phrases, size_t phrases_len);

    [CCode (cname = "jd_user_dict_build")]
    public uint user_dict_build (string phrases, size_t phrases_len, uint64 source_tag,
                                 void *buf, size_t buf_cap, out size_t blob_len,
                                 out UserDictReport report);

    [CCode (cname = "JD_CODE_USER")]
    public const uint CODE_USER;

    /** One code a value is typed with: `keys` NUL-terminated, `index` the
     * value's place among the candidates there, 0 the first. */
    [CCode (cname = "jd_code", has_type_id = false, has_copy_function = false, has_destroy_function = false)]
    public struct Code {
        public char keys[8];
        public uint index;
        public uint flags;
    }

    /** An engine context. The user-dictionary blob it is made over must
     * outlive it. */
    [Compact]
    [CCode (cname = "jd_context", free_function = "jd_deinit")]
    public class Context {
        /** Null when the blob fails validation. */
        [CCode (cname = "jd_init")]
        public static Context? init (void *user_dict, size_t user_dict_len);

        /** Writes up to `out_cap` codes of `value` to `out`, and returns how
         * many there are in all. */
        [CCode (cname = "jd_lookup_codes")]
        public uint lookup_codes (string value, size_t value_len,
                                  [CCode (array_length = false)] Code[]? out, uint out_cap);
    }
}
