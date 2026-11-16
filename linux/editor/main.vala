// 键道用户自造词 (ime-jd-userdict): the window that edits the user
// dictionary, started from the desktop's application list or from the input
// method's menu (用户自造词…). One window per session: a second start brings
// the open one forward, as on Windows.
//
// `--lookup` opens 编码反查 instead (lookup_window.vala), the menu's other
// window, as Windows' ime_jd_userdict.exe does; the same process serves
// both, and a second start brings the open one forward too.
//
// `--file <path>` edits that file instead of the user's own, to try the
// window out — screenshots, tests — without touching the real phrases: such
// a window remembers no size and stands beside one already open. The switch
// is the user's either way.

namespace ImeJd {

    /** The release, from core/build.zig.zon; meson.build passes it in. */
    [CCode (cname = "IMEJD_VERSION")]
    extern const string VERSION;

    public const string APPLICATION_ID = "io.github.hronro.ImeJd.UserDict";

    private const string CSS = """
        .problem-invalid { color: @error_color; }
        .problem-shared { color: @warning_color; }
        .status-line { font-size: smaller; }
        editablelabel.keys { font-family: monospace; }
        .prompt-message { font-weight: bold; font-size: larger; }
        columnview > listview > row.drop-above { box-shadow: inset 0 2px @theme_selected_bg_color; }
        columnview > listview > row.drop-below { box-shadow: inset 0 -2px @theme_selected_bg_color; }
        /* The row's line says where a drop goes, not the cell's box. */
        columnview > listview > row > cell > *:drop(active) { box-shadow: none; outline: none; }
    """;

    public class Application : Gtk.Application {
        /** The action a start with --lookup asks the running instance for. */
        public const string LOOKUP_ACTION = "lookup";

        private string? trial_file;
        /** Started with --lookup: the first activation opens 编码反查. */
        private bool lookup_first;
        private Window? window;
        private LookupWindow? lookup_window;

        public Application (string? trial_file, bool lookup = false) {
            Object (application_id: APPLICATION_ID,
                    flags: trial_file != null ? ApplicationFlags.NON_UNIQUE : (ApplicationFlags) 0);
            this.trial_file = trial_file;
            lookup_first = lookup;
        }

        protected override void startup () {
            base.startup ();
            Environment.set_application_name ("键道用户自造词");
            set_accels_for_action ("window.close", { "<Control>w" });

            var lookup = new SimpleAction (LOOKUP_ACTION, null);
            lookup.activate.connect (() => show_lookup ());
            add_action (lookup);

            var css = new Gtk.CssProvider ();
            css.load_from_data (CSS.data);
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        protected override void activate () {
            if (lookup_first) {
                lookup_first = false;
                show_lookup ();
                return;
            }
            if (window == null) {
                Store store;
                if (trial_file != null) {
                    store = Store.open_file (trial_file);
                } else {
                    store = Store.open_default ();
                }
                store.watch ();
                window = new Window (this, store, trial_file == null);
            }
            window.present ();
        }

        private void show_lookup () {
            if (lookup_window == null) {
                lookup_window = new LookupWindow (this);
                lookup_window.close_request.connect (() => {
                    lookup_window = null;
                    return false;
                });
            }
            lookup_window.bring_forward ();
        }
    }

    public static int main (string[] args) {
        Intl.setlocale ();
        // Before GTK, which needs a display: --version runs anywhere.
        string? trial_file = null;
        if (args.length == 2 && args[1] == "--version") {
            print ("ime-jd-userdict %s\n", VERSION);
            return 0;
        }
        if (args.length == 2 && args[1] == "--lookup") {
            return run_lookup ();
        }
        if (args.length == 3 && args[1] == "--file") {
            trial_file = File.new_for_commandline_arg (args[2]).get_path ();
        } else if (args.length != 1) {
            printerr ("用法：ime-jd-userdict [--lookup | --file 文件 | --version]\n");
            return 2;
        }
        return new Application (trial_file).run (null);
    }

    /** 编码反查: in the instance already running, if there is one — which
     * then opens it, or brings it forward — or else in this one. */
    private int run_lookup () {
        var application = new Application (null, true);
        try {
            application.register (null);
        } catch (Error error) {
            printerr ("%s\n", error.message);
            return 1;
        }
        if (!application.is_remote) {
            return application.run (null);
        }
        application.activate_action (Application.LOOKUP_ACTION, null);
        // Sent before this process goes: the call does not wait for it.
        var bus = application.get_dbus_connection ();
        if (bus != null) {
            try {
                bus.flush_sync ();
            } catch (Error error) {
                printerr ("%s\n", error.message);
            }
        }
        return 0;
    }
}
