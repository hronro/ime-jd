// 键道用户自造词 (ime-jd-userdict): the window that edits the user
// dictionary, started from the desktop's application list or from the input
// method's menu (用户自造词…). One window per session: a second start brings
// the open one forward, as on Windows.
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
        private string? trial_file;
        private Window? window;

        public Application (string? trial_file) {
            Object (application_id: APPLICATION_ID,
                    flags: trial_file != null ? ApplicationFlags.NON_UNIQUE : (ApplicationFlags) 0);
            this.trial_file = trial_file;
        }

        protected override void startup () {
            base.startup ();
            Environment.set_application_name ("键道用户自造词");
            set_accels_for_action ("window.close", { "<Control>w" });

            var css = new Gtk.CssProvider ();
            css.load_from_data (CSS.data);
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        protected override void activate () {
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
    }

    public static int main (string[] args) {
        Intl.setlocale ();
        // Before GTK, which needs a display: --version runs anywhere.
        string? trial_file = null;
        if (args.length == 2 && args[1] == "--version") {
            print ("ime-jd-userdict %s\n", VERSION);
            return 0;
        }
        if (args.length == 3 && args[1] == "--file") {
            trial_file = File.new_for_commandline_arg (args[2]).get_path ();
        } else if (args.length != 1) {
            printerr ("用法：ime-jd-userdict [--file 文件 | --version]\n");
            return 2;
        }
        return new Application (trial_file).run (null);
    }
}
