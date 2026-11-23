// What 编码反查 answers for one query: libjd's codes for it
// (jd_lookup_codes), worded for the user as every client words them
// (windows/userdict/src/lookup/report.rs, bindings/swift/CodeLookupReport.swift).
// No window here — lookup_window.vala shows the answer.

namespace ImeJd {

    namespace CodeLookup {
        /** Where the answer quotes the query, a longer one is cut to this
         * many characters. */
        private const int QUOTED_CHARS = 20;

        /** The query as the engine should see it. A pasted word may carry
         * spaces or a line break at its ends; dropping spaces, TABs, CRs and
         * LFs there never loses a match, because no phrase starts or ends
         * with one (the table format trims spaces, and control bytes are not
         * allowed in a phrase). U+3000 and other spaces stay: a phrase may
         * end with one. */
        public string query (string input) {
            int start = 0;
            int end = input.length;
            while (start < end && is_trimmed (input[start])) {
                start++;
            }
            while (end > start && is_trimmed (input[end - 1])) {
                end--;
            }
            return input.substring (start, end - start);
        }

        private bool is_trimmed (char c) {
            return c == ' ' || c == '\t' || c == '\r' || c == '\n';
        }

        /** The codes `query` is typed with, in libjd's order — shortest
         * first — from the built-in dictionary and the phrases in
         * `phrases`, on a context made for this one question; with
         * `user_only`, from the phrases alone. A user phrase counts toward
         * the candidate numbers of the built-in words it leads on a code.
         * Phrases that do not build are left out, as the engines leave out a
         * file they cannot load; with `user_only` there is then nothing to
         * look in, and the answer is null. */
        public Jd.Code[]? codes (string query, string? phrases, bool user_only = false) {
            // The blob the context reads in place: it outlives the context,
            // which is gone before this returns.
            uint8[] blob = {};
            size_t blob_length = 0;
            if (phrases != null) {
                size_t bound = Jd.user_dict_blob_bound (phrases, phrases.length);
                // malloc's alignment, past the 4 bytes the engine asks for.
                var buffer = new uint8[bound];
                Jd.UserDictReport report;
                if (Jd.user_dict_build (user_only ? EmptyDict.data () : null, user_only ? EmptyDict.size () : 0,
                                        phrases, phrases.length, UserDictFile.hash (phrases), (void*) buffer,
                                        bound, out blob_length, out report) == Jd.USER_DICT_OK) {
                    blob = (owned) buffer;
                } else {
                    blob_length = 0;
                }
            }
            Jd.Code[] found = {};
            if (user_only && blob_length == 0) {
                // The phrases alone, and there are none to be had: never the
                // built-in dictionary instead.
                return null;
            }
            {
                Jd.Context? context = Jd.Context.init (user_only ? EmptyDict.data () : null,
                                                       user_only ? EmptyDict.size () : 0,
                                                       blob_length > 0 ? (void*) blob : null, blob_length);
                if (context != null) {
                    uint total = context.lookup_codes (query, query.length, null, 0);
                    if (total > 0) {
                        found = new Jd.Code[total];
                        context.lookup_codes (query, query.length, found, total);
                    }
                }
            }
            return found;
        }

        /** A code's keys, which libjd hands over NUL-terminated. */
        public string keys (Jd.Code code) {
            return ((string) code.keys).dup ();
        }

        /** The query as the answer quotes it: a long paste is cut short. */
        private string quoted (string query) {
            if (query.char_count () <= QUOTED_CHARS) {
                return query;
            }
            return query.substring (0, query.index_of_nth_char (QUOTED_CHARS)) + "…";
        }

        /** The answer: the prompt's message, and one code per line, or why
         * there are none. */
        public class Report : Object {
            public string title { get; private set; }
            public string body { get; private set; }

            /** `codes` are libjd's, in its order. On a code where the word
             * is the first candidate the code stands alone; any other says
             * which candidate the word is there. Nothing says which key
             * commits it: that is the engine's business, and it has changed
             * before. A code from the user dictionary is marked 自造词.
             * `user_dict_enabled` says whether the user's phrases were looked
             * in too, and `user_only` whether only they were, which shows
             * only when nothing was found. */
            public Report (string query, Jd.Code[] codes, bool user_dict_enabled, bool user_only = false) {
                string word = quoted (query);
                if (codes.length == 0) {
                    title = "没有找到「%s」".printf (word);
                    if (user_dict_enabled && user_only) {
                        body = "用户自造词中没有这个词。内置词库已忽略，不在查询范围内。";
                    } else {
                        body = user_dict_enabled
                            ? "内置词库和用户自造词中都没有这个词。"
                            : "内置词库中没有这个词。用户自造词未启用，不在查询范围内。";
                    }
                    return;
                }
                string[] lines = {};
                foreach (var code in codes) {
                    string[] notes = {};
                    if (code.index > 0) {
                        notes += "第 %u 个候选".printf (code.index + 1);
                    }
                    if ((code.flags & Jd.CODE_USER) != 0) {
                        notes += "自造词";
                    }
                    lines += notes.length == 0 ? keys (code) : "%s（%s）".printf (keys (code), string.joinv ("，", notes));
                }
                title = "「%s」的编码".printf (word);
                body = string.joinv ("\n", lines);
            }

            /** Nothing could be looked up: the phrases alone were to be
             * searched, and they cannot be had, for the reason `why`. */
            public Report.unavailable (string query, string why) {
                title = "没有找到「%s」".printf (quoted (query));
                body = why;
            }
        }
    }
}
