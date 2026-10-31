// The phrases file behind the user dictionary — libjd's own table format —
// and how its lines are read and written: a port of the clients' shared
// UserDictFile (bindings/swift/UserDictFile.swift), so the editor reads and
// writes the file as the macOS one does, and as the engines here read it
// (common/user_dict.cpp). Nothing here judges a phrase: libjd parses the
// whole file on every build and says, by line, what it skips and why
// (problem.vala). What is mirrored is only how a line splits into cells.
//
// One `value<TAB>keys` line per phrase, `#` comments, blank lines ignored. A
// line without a TAB becomes a row with empty keys, so it can be fixed in
// place, and the file is written back as one header comment plus one line
// per row: whatever else a text editor put between the lines is gone after
// the first save here. A phrase list is a table, not an editor.

namespace ImeJd {

    public errordomain UserDictError {
        /** The file is there but cannot be read; the message is the
         * system's reason. */
        UNREADABLE,
        /** Not UTF-8, or holds a NUL: libjd would skip line after line, and
         * the text cannot be shown, or written back, as it is. */
        NOT_UTF8
    }

    /** A phrase as the file has it: the text it commits, the code that
     * reaches it, and the 1-based line it is on. */
    public struct FileRow {
        public int line;
        public string value;
        public string keys;
    }

    namespace UserDictFile {
        public const string NAME = "用户自造词.txt";

        /** The first line of every file the editor writes, for whoever opens
         * it in a text editor. 6: the longest code libjd takes. */
        public const string HEADER =
            "# 键道用户自造词：每行一条，格式为「词<TAB>编码」，编码由 a-z 组成，1 到 6 个字符。";

        /** The file's text, or null when there is no file. Read with
         * read(2), as the engines read it, for the system's own short
         * reason when it cannot be. */
        public string? read (string path) throws UserDictError {
            int fd = Posix.open (path, Posix.O_RDONLY | Posix.O_CLOEXEC);
            if (fd < 0) {
                if (errno == Posix.ENOENT) {
                    return null;
                }
                throw new UserDictError.UNREADABLE (strerror (errno));
            }
            var contents = new StringBuilder ();
            uint8 buffer[65536];
            for (;;) {
                ssize_t n = Posix.read (fd, buffer, buffer.length);
                if (n < 0) {
                    if (errno == Posix.EINTR) {
                        continue;
                    }
                    int error = errno;
                    Posix.close (fd);
                    throw new UserDictError.UNREADABLE (strerror (error));
                }
                if (n == 0) {
                    break;
                }
                contents.append_len ((string) buffer, n);
            }
            Posix.close (fd);
            return decode (contents.str, contents.len);
        }

        /** `length` bytes of `contents` as text: a UTF-8 BOM is dropped,
         * since libjd would take U+FEFF as part of the first value. */
        public string decode (string contents, ssize_t length) throws UserDictError {
            // A NUL would end the string here, and a save would cut the file
            // short at it.
            if (contents.length != length || !contents.validate ()) {
                throw new UserDictError.NOT_UTF8 ("not UTF-8");
            }
            return contents.has_prefix ("\xef\xbb\xbf") ? contents.substring (3) : contents;
        }

        /** Replaces the file in one rename, so a reader never sees half of
         * it, creating its directory when there is none. */
        public void write (string path, string text) throws Error {
            make_directory (Path.get_dirname (path));
            FileUtils.set_contents_full (path, text, -1,
                FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0644);
        }

        /** Creates `path` and its parents; XDG asks for 0700 on directories
         * made on the user's behalf. */
        public void make_directory (string path) throws Error {
            if (DirUtils.create_with_parents (path, 0700) != 0) {
                throw new FileError.FAILED ("%s: %s", path, strerror (errno));
            }
        }

        /** Splits the way libjd does — on LF, counting from 1, spaces and CRs
         * trimmed from both ends — skipping comments and blank lines. Lenient
         * on purpose: fields are not checked, and a line without a TAB
         * becomes a row whose value is the whole line and whose keys are
         * empty. */
        public FileRow[] parse (string text) {
            FileRow[] rows = {};
            string[] lines = text.split ("\n");
            for (int index = 0; index < lines.length; index++) {
                string line = trim (lines[index], " \r");
                if (line == "" || line[0] == '#') {
                    continue;
                }
                int tab = line.index_of_char ('\t');
                FileRow row = { index + 1, line, "" };
                if (tab >= 0) {
                    row.value = trim (line.substring (0, tab), " ");
                    row.keys = trim (line.substring (tab + 1), " ");
                }
                rows += row;
            }
            return rows;
        }

        /** The header and one `value<TAB>keys` line per phrase, each ending in
         * LF: entry `i` is on line `line_of_entry (i)`. `values` and `keys`
         * are the phrases' two halves, in order. */
        public string serialize (string[] values, string[] keys) {
            var text = new StringBuilder (HEADER);
            text.append_c ('\n');
            for (int i = 0; i < values.length; i++) {
                text.append (values[i]);
                text.append_c ('\t');
                text.append (keys[i]);
                text.append_c ('\n');
            }
            return text.str;
        }

        /** The line the entry at `index` is on after serialize(). */
        public int line_of_entry (int index) {
            return index + 2;
        }

        /** `text` without any of `chars`, ASCII each, at either end: libjd
         * trims spaces and CRs from a line and spaces from a field, and no
         * other whitespace. */
        public string trim (string text, string chars) {
            int start = 0;
            int end = text.length;
            while (start < end && chars.index_of_char (text[start]) >= 0) {
                start++;
            }
            while (end > start && chars.index_of_char (text[end - 1]) >= 0) {
                end--;
            }
            return text.substring (start, end - start);
        }

        /** FNV-1a, 64-bit, over the UTF-8 text, as the engines compute it: how
         * the editor tells its own write from an edit made elsewhere. */
        public uint64 hash (string text) {
            uint64 hash = 0xcbf29ce484222325;
            foreach (uint8 byte in text.data) {
                hash ^= byte;
                hash *= 0x100000001b3;
            }
            return hash;
        }
    }
}
