// The editor's view of the user dictionary: the phrases file, libjd's build
// of it, and the switch — the same files the engines read, in the same
// directory, watched the same way (common/user_dict.cpp). The editor builds
// the file itself only for the notes the build leaves on its lines; the
// engines rebuild it on their own when it changes.

namespace ImeJd {

    /** What libjd's build of the file says: the counts, and one note per
     * line it skipped, dropped, or found sharing a code. */
    public class Report : Object {
        public uint entries;
        public uint dropped;
        public uint shared;
        public uint invalid;
        public Jd.UserDictNote[] notes;

        /** Builds `text`, tagged with `tag`. Returns null when the build
         * fails as a whole; `status` and `line` then say why. */
        public static Report? build (string text, uint64 tag, out uint status, out uint line) {
            size_t bound = Jd.user_dict_blob_bound (text, text.length);
            // malloc's alignment, past the 4 bytes the engine asks for.
            var buffer = new uint8[bound];
            size_t blob_length;
            Jd.UserDictReport raw;
            status = Jd.user_dict_build (text, text.length, tag, (void*) buffer, bound, out blob_length, out raw);
            line = raw.line;
            if (status != Jd.USER_DICT_OK) {
                return null;
            }
            var report = new Report ();
            report.entries = raw.entries;
            report.dropped = raw.dropped;
            report.shared = raw.shared;
            report.invalid = raw.invalid;
            // The notes sit in the buffer past the blob.
            var notes = (Jd.UserDictNote*) ((uint8*) buffer + raw.notes_offset);
            report.notes = new Jd.UserDictNote[raw.notes];
            for (uint i = 0; i < raw.notes; i++) {
                report.notes[i] = notes[i];
            }
            return report;
        }
    }

    /** Why the file cannot be used, in the engines' words: they put the
     * same text in the input method's menu. */
    public class LoadError : Object {
        public enum Kind {
            NOT_UTF8,
            UNREADABLE,
            BUILD
        }

        public Kind kind;
        /** UNREADABLE: what the system said. */
        public string reason = "";
        /** BUILD: jd_user_dict_build's status, and the line it refers to. */
        public uint status;
        public uint line;

        public string message {
            owned get {
                switch (kind) {
                case Kind.NOT_UTF8:
                    return "文件不是 UTF-8 编码";
                case Kind.UNREADABLE:
                    return "无法读取文件：" + reason;
                default:
                    if (status == Jd.USER_DICT_TOO_MANY_ENTRIES) {
                        return "第 %u 行起超过 %u 条上限".printf (line, Jd.USER_DICT_MAX_ENTRIES);
                    }
                    if (status == Jd.USER_DICT_TEXT_TOO_LONG) {
                        return "文件超过 8 MB 上限";
                    }
                    return "无法编译词库（状态 %u）".printf (status);
                }
            }
        }
    }

    public class Store : Object {
        private const string SETTINGS_NAME = "settings.ini";
        private const string SWITCH_GROUP = "UserDict";
        private const string SWITCH_KEY = "Enabled";
        private const string WINDOW_GROUP = "UserDictWindow";
        /** One save is several events. */
        private const uint DEBOUNCE_MS = 300;

        public string file_path { get; construct; }
        public string settings_path { get; construct; }

        /** The user's switch, as settings.ini has it: off until turned on. */
        public bool enabled { get; private set; }
        /** The file's text; null when there is no file, or it cannot be
         * read. */
        public string? text { get; private set; }
        /** libjd's build of `text`; null when there is no text, or the build
         * failed. */
        public Report? report { get; private set; }
        /** Why the file cannot be read, or built; null when it can. */
        public LoadError? error { get; private set; }

        /** Whether the file is there but cannot be read: the table cannot
         * show it, so the table must not replace it either. A file that
         * reads but does not build is shown, and can be fixed in place. */
        public bool read_only {
            get { return error != null && error.kind != LoadError.Kind.BUILD; }
        }

        /** The switch or the file changed, from here or from anywhere. */
        public signal void changed ();

        private FileMonitor[] monitors = {};
        private uint pending_reload;

        /** The store for the phrases at `file_path`, with the switch in
         * `settings_path`, loaded once. */
        public Store (string file_path, string settings_path) {
            Object (file_path: file_path, settings_path: settings_path);
            reload ();
        }

        /** $XDG_CONFIG_HOME/ime-jd, as the engines find it: XDG_CONFIG_HOME
         * when it is an absolute path, ~/.config otherwise. */
        public static string default_directory () {
            unowned string? config = Environment.get_variable ("XDG_CONFIG_HOME");
            string base_dir = config != null && config.has_prefix ("/")
                ? config
                : Path.build_filename (Environment.get_home_dir (), ".config");
            return Path.build_filename (base_dir, "ime-jd");
        }

        /** The default store: the files the engines read. */
        public static Store open_default () {
            string directory = default_directory ();
            // A place to write, and a directory to watch.
            try {
                UserDictFile.make_directory (directory);
            } catch (Error error) {
                warning ("%s", error.message);
            }
            return new Store (Path.build_filename (directory, UserDictFile.NAME),
                Path.build_filename (directory, SETTINGS_NAME));
        }

        /** The settings that go with phrases kept in `file_path`: the user's
         * own, wherever the phrases are. */
        public static Store open_file (string file_path) {
            return new Store (file_path, Path.build_filename (default_directory (), SETTINGS_NAME));
        }

        /** Re-reads the switch and the file. */
        public void reload () {
            // Off when settings.ini cannot be read, as the engines see it.
            try {
                enabled = Ini.get_value (read_settings (), SWITCH_GROUP, SWITCH_KEY) in new string[] { "true", "1" };
            } catch (UserDictError failure) {
                enabled = false;
            }

            string? text = null;
            LoadError? error = null;
            Report? report = null;
            try {
                text = UserDictFile.read (file_path);
            } catch (UserDictError failure) {
                error = new LoadError ();
                if (failure is UserDictError.NOT_UTF8) {
                    error.kind = LoadError.Kind.NOT_UTF8;
                } else {
                    error.kind = LoadError.Kind.UNREADABLE;
                    error.reason = failure.message;
                }
            }
            if (text != null) {
                uint status, line;
                report = Report.build (text, UserDictFile.hash (text), out status, out line);
                if (report == null) {
                    error = new LoadError ();
                    error.kind = LoadError.Kind.BUILD;
                    error.status = status;
                    error.line = line;
                }
            }
            this.text = text;
            this.report = report;
            this.error = error;
        }

        /** Replaces the file with `text`, and re-reads it. */
        public void save (string text) throws Error {
            UserDictFile.write (file_path, text);
            reload ();
        }

        /** Turns the switch on or off, keeping every other setting. */
        public void save_switch (bool on) throws Error {
            write_settings (Ini.set_value (read_settings (), SWITCH_GROUP, SWITCH_KEY, on ? "true" : "false"));
            enabled = on;
        }

        /** The window's size when it was last closed; false when there is
         * none. */
        public bool window_size (out int width, out int height, out bool maximized) {
            string settings;
            try {
                settings = read_settings ();
            } catch (UserDictError error) {
                settings = "";
            }
            width = int.parse (Ini.get_value (settings, WINDOW_GROUP, "Width") ?? "0");
            height = int.parse (Ini.get_value (settings, WINDOW_GROUP, "Height") ?? "0");
            maximized = Ini.get_value (settings, WINDOW_GROUP, "Maximized") == "true";
            return width > 0 && height > 0;
        }

        public void save_window_size (int width, int height, bool maximized) {
            try {
                // Last first: a key new to the group goes in as its first line.
                string settings = read_settings ();
                settings = Ini.set_value (settings, WINDOW_GROUP, "Maximized", maximized ? "true" : "false");
                settings = Ini.set_value (settings, WINDOW_GROUP, "Height", height.to_string ());
                settings = Ini.set_value (settings, WINDOW_GROUP, "Width", width.to_string ());
                write_settings (settings);
            } catch (Error error) {
                warning ("%s", error.message);
            }
        }

        /** Watches the files' directories: a save is a write closed in place,
         * or — a text editor's atomic save, or ours — a rename into the
         * directory. */
        public void watch () {
            string[] names = { Path.get_basename (file_path), Path.get_basename (settings_path) };
            string[] directories = { Path.get_dirname (file_path) };
            if (Path.get_dirname (settings_path) != directories[0]) {
                directories += Path.get_dirname (settings_path);
            }
            foreach (unowned string directory in directories) {
                try {
                    var monitor = File.new_for_path (directory).monitor_directory (FileMonitorFlags.WATCH_MOVES);
                    monitor.changed.connect ((file, other, event) => {
                        if (file.get_basename () in names || (other != null && other.get_basename () in names)) {
                            schedule_reload ();
                        }
                    });
                    monitors += monitor;
                } catch (Error error) {
                    warning ("cannot watch %s: %s", directory, error.message);
                }
            }
        }

        private void schedule_reload () {
            if (pending_reload != 0) {
                Source.remove (pending_reload);
            }
            pending_reload = Timeout.add (DEBOUNCE_MS, () => {
                pending_reload = 0;
                reload ();
                changed ();
                return Source.REMOVE;
            });
        }

        /** settings.ini's text; empty when there is none. One that cannot
         * be read is not written over either: it holds more than the
         * switch. */
        private string read_settings () throws UserDictError {
            return UserDictFile.read (settings_path) ?? "";
        }

        private void write_settings (string settings) throws Error {
            UserDictFile.write (settings_path, settings);
        }
    }
}
