// settings.ini, the file the editor shares with the engines: the switch the
// engines read, and the window's own size. Read and written leniently, line
// by line, exactly as the engines do (common/user_dict.cpp), so a line one
// side does not understand is kept as it was rather than refused.

namespace ImeJd.Ini {

    /** The value of `key` in `[group]`, in the format GLib's GKeyFile reads;
     * null when it is not set. */
    public string? get_value (string content, string group, string key) {
        bool in_group = false;
        foreach (unowned string raw in split_lines (content)) {
            string line = trim (raw);
            if (is_group_line (line)) {
                in_group = line.has_suffix ("]") && line.substring (1, line.length - 2) == group;
            } else if (in_group && key_of (line) == key) {
                return trim (line.substring (line.index_of_char ('=') + 1));
            }
        }
        return null;
    }

    /** `content` with `key` in `[group]` set to `value`, every other line as
     * it was. */
    public string set_value (string content, string group, string key, string value) {
        string[] lines = split_lines (content);
        string setting = key + "=" + value;
        string header = "[" + group + "]";

        int group_line = -1;
        for (int i = 0; i < lines.length; i++) {
            if (trim (lines[i]) == header) {
                group_line = i;
                break;
            }
        }
        string[] result = {};
        if (group_line < 0) {
            result = lines;
            if (lines.length > 0 && trim (lines[lines.length - 1]) != "") {
                result += "";
            }
            result += header;
            result += setting;
        } else {
            // The key's line in the group, replaced, or the setting added as
            // the group's first line.
            int end = group_line + 1;
            while (end < lines.length && !is_group_line (trim (lines[end]))) {
                end++;
            }
            int at = -1;
            for (int i = group_line + 1; i < end; i++) {
                if (key_of (trim (lines[i])) == key) {
                    at = i;
                    break;
                }
            }
            for (int i = 0; i < lines.length; i++) {
                result += i == at ? setting : lines[i];
                if (i == group_line && at < 0) {
                    result += setting;
                }
            }
        }

        var text = new StringBuilder ();
        foreach (unowned string line in result) {
            text.append (line);
            text.append_c ('\n');
        }
        return text.str;
    }

    /** The lines of `content`, without their LFs; no empty last line for a
     * final LF. */
    private string[] split_lines (string content) {
        string[] lines = content.split ("\n");
        if (content.has_suffix ("\n")) {
            lines.resize (lines.length - 1);
        }
        return lines;
    }

    private string trim (string text) {
        return UserDictFile.trim (text, " \t\r");
    }

    private bool is_group_line (string line) {
        return line.has_prefix ("[");
    }

    /** The key a `key=value` line sets, or null for any other line. */
    private string? key_of (string line) {
        if (line == "" || line[0] == '#' || line[0] == ';') {
            return null;
        }
        int eq = line.index_of_char ('=');
        return eq < 0 ? null : trim (line.substring (0, eq));
    }
}
