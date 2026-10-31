// The engine's verdict on one row of the table, for its 状态 column: the
// notes libjd's build leaves, mapped onto the rows by line, with the words
// the column shows. A port of the clients' shared UserDictProblem
// (bindings/swift/UserDictProblem.swift), words and all, so the macOS window
// and this one say the same thing about the same line.

namespace ImeJd {

    public enum ProblemKind {
        /** In the file, but libjd skips it: it does not parse. */
        INVALID,
        /** In the file, but libjd drops it: the same phrase as another row,
         * or as a built-in word. */
        DUPLICATE,
        /** Works, and is listed first — but its code already carries
         * built-in words, other rows, or both. */
        SHARED_CODE
    }

    public class Problem : Object {
        public ProblemKind kind { get; construct; }
        /** INVALID: the note's JD_USER_DICT_LINE_* flags. */
        public uint flags { get; construct; }
        /** DUPLICATE: the row repeated, -1 for a built-in word. SHARED_CODE:
         * the first other row on the code, -1 for none. */
        public int other_row { get; construct; default = -1; }
        /** SHARED_CODE: built-in words on the code. */
        public uint builtin { get; construct; }
        /** SHARED_CODE: rows on the code, the first of them `other_row`. */
        public uint peers { get; construct; }

        public Problem.invalid (uint flags) {
            Object (kind: ProblemKind.INVALID, flags: flags);
        }

        public Problem.duplicate (int other_row) {
            Object (kind: ProblemKind.DUPLICATE, other_row: other_row);
        }

        public Problem.shared_code (uint builtin, int other_row, uint peers) {
            Object (kind: ProblemKind.SHARED_CODE, builtin: builtin, other_row: other_row, peers: peers);
        }

        public string text {
            owned get {
                switch (kind) {
                case ProblemKind.INVALID:
                    if ((flags & Jd.LINE_MALFORMED) != 0) {
                        return "缺少制表符（无编码），不生效";
                    }
                    if ((flags & Jd.LINE_BAD_KEYS) != 0) {
                        return "编码无效（1 到 %d 个 a-z），不生效".printf (MAX_KEY_LENGTH);
                    }
                    return "词无效（不能为空或含控制字符，最长 %u 字节），不生效".printf (Jd.USER_DICT_VALUE_MAX);
                case ProblemKind.DUPLICATE:
                    if (other_row >= 0) {
                        return "与第 %d 条重复，不生效".printf (other_row + 1);
                    }
                    return "与内置词重复，不生效";
                default:
                    // "与 2 个内置词及第 3 条等 2 条同码", or either half alone.
                    string[] parts = {};
                    if (builtin > 0) {
                        parts += " %u 个内置词".printf (builtin);
                    }
                    if (other_row >= 0) {
                        parts += peers > 1
                            ? "第 %d 条等 %u 条".printf (other_row + 1, peers)
                            : "第 %d 条".printf (other_row + 1);
                    }
                    return "与" + string.joinv ("及", parts) + "同码";
                }
            }
        }

        /** One verdict per row, from the build of the text the rows came
         * from. `lines[i]` is row `i`'s 1-based line in that text, 0 for a
         * row that is not in it (added, not yet written). A null `report` —
         * the text could not be built at all — flags nothing: there are no
         * notes on a file the engine could not read. */
        public static Problem?[] for_rows (int[] lines, Report? report) {
            var problems = new Problem?[lines.length];
            if (report == null) {
                return problems;
            }
            var notes = new HashTable<int, int> (direct_hash, direct_equal);
            for (int i = 0; i < report.notes.length; i++) {
                notes[(int) report.notes[i].line] = i + 1;
            }
            var row_by_line = new HashTable<int, int> (direct_hash, direct_equal);
            for (int index = 0; index < lines.length; index++) {
                if (lines[index] > 0) {
                    row_by_line[lines[index]] = index + 1;
                }
            }
            for (int index = 0; index < lines.length; index++) {
                // Both tables hold an index plus one: a missing key reads 0.
                int found = lines[index] > 0 ? notes[lines[index]] : 0;
                if (found == 0) {
                    continue;
                }
                Jd.UserDictNote note = report.notes[found - 1];
                int other = row_by_line[(int) note.other] - 1;
                if ((note.flags & (Jd.LINE_MALFORMED | Jd.LINE_BAD_KEYS | Jd.LINE_BAD_VALUE)) != 0) {
                    problems[index] = new Problem.invalid (note.flags);
                } else if ((note.flags & Jd.LINE_REPEATS_LINE) != 0) {
                    problems[index] = new Problem.duplicate (other);
                } else if ((note.flags & Jd.LINE_REPEATS_BUILTIN) != 0) {
                    problems[index] = new Problem.duplicate (-1);
                } else if ((note.flags & (Jd.LINE_CODE_IN_BUILTIN | Jd.LINE_CODE_IN_LINE)) != 0) {
                    problems[index] = new Problem.shared_code (
                        note.builtin, (note.flags & Jd.LINE_CODE_IN_LINE) != 0 ? other : -1, note.peers);
                }
            }
            return problems;
        }
    }

    /** The longest code libjd takes. jd.h states it in prose, not as a
     * macro; a longer one is skipped with a LINE_BAD_KEYS note. */
    public const int MAX_KEY_LENGTH = 6;
}
