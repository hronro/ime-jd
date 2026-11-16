// 编码反查 (ime-jd-userdict --lookup), started from the input method's menu:
// a small window that asks for a word, and answers 查询 with the codes that
// type it, in a prompt over it (lookup.vala words the answer) — the Windows
// client's dialog (windows/userdict/src/lookup/mod.rs) in GTK. The codes come
// from what the engines type with right now: the built-in dictionary and,
// while it is switched on, the user's phrases, read from the file afresh for
// every query — so the candidate numbers count the user's phrases that lead
// a code.
//
// It is an ordinary window, so the word can be typed into it with 键道 itself
// — Enter and Escape are the input method's while a code is being typed — or
// pasted. 查询 waits until the field holds more than spaces; closing the
// answer leaves the word selected, so the next one replaces it. A second
// start brings the window forward, or its answer while one is up.

namespace ImeJd {

    public class LookupWindow : Gtk.ApplicationWindow {
        private const string TITLE = "编码反查";
        /** How long after the window first becomes active the field takes
         * the focus again (see the constructor). */
        private const uint SETTLE_MS = 300;

        private Gtk.Entry word;
        private Gtk.Button look_up_button;
        /** The answer, while one is up. */
        private Prompt? answer;
        /** A code is being typed in the field. */
        private bool composing;

        public LookupWindow (Gtk.Application application) {
            Object (application: application, title: TITLE, resizable: false);

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            box.margin_top = 20;
            box.margin_bottom = 20;
            box.margin_start = 24;
            box.margin_end = 24;

            // The macOS window's words (macos/JdIME/Lookup/).
            var label = new Gtk.Label ("输入或粘贴要查询的词：");
            label.xalign = 0;
            box.append (label);

            word = new Gtk.Entry ();
            word.placeholder_text = "例如：键道";
            word.width_chars = 28;
            word.activates_default = true;
            word.changed.connect (update_button);
            box.append (word);

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            buttons.halign = Gtk.Align.END;
            buttons.margin_top = 4;
            var close_button = new Gtk.Button.with_label ("关闭");
            close_button.clicked.connect (() => close ());
            buttons.append (close_button);
            look_up_button = new Gtk.Button.with_label ("查询");
            look_up_button.add_css_class ("suggested-action");
            look_up_button.clicked.connect (() => look_up.begin ());
            buttons.append (look_up_button);
            box.append (buttons);
            default_widget = look_up_button;

            child = box;

            // Escape closes it, as it closes a dialog — once the input method
            // has had it: while a code is being typed, Escape drops the code.
            var escape = new Gtk.ShortcutController ();
            escape.add_shortcut (new Gtk.Shortcut (
                new Gtk.KeyvalTrigger (Gdk.Key.Escape, 0),
                new Gtk.CallbackAction ((widget, args) => {
                    close ();
                    return true;
                })));
            ((Gtk.Widget) this).add_controller (escape);

            // A field that has the focus as its window first becomes active
            // can be left without the input method: on GNOME 42 the
            // compositor sometimes takes text input away from it again a few
            // milliseconds after giving it, and what is typed then goes in as
            // it is until the focus moves. So, once the window has settled,
            // the field takes the focus again — unless typing has begun.
            ((Gtk.Text) word.get_delegate ()).preedit_changed.connect ((preedit) => {
                composing = preedit != "";
            });
            ulong activated = 0;
            activated = notify["is-active"].connect (() => {
                if (!is_active) {
                    return;
                }
                disconnect (activated);
                Timeout.add (SETTLE_MS, () => {
                    if (is_active && word.text == "" && !composing) {
                        set_focus (null);
                        select_word ();
                    }
                    return Source.REMOVE;
                });
            });

            update_button ();
        }

        /** Brings the window forward: the answer, while one is up, or else
         * the window, with its word selected. */
        public void bring_forward () {
            if (answer != null) {
                answer.present ();
                return;
            }
            present ();
            select_word ();
        }

        /** 查询 only once the field holds a query. */
        private void update_button () {
            look_up_button.sensitive = CodeLookup.query (word.text) != "";
        }

        private void select_word () {
            word.grab_focus ();
            word.select_region (0, -1);
        }

        /** 查询: the codes of the word in the field, in a prompt over the
         * window. */
        private async void look_up () {
            string query = CodeLookup.query (word.text);
            if (query == "" || answer != null) {
                return;
            }
            var store = Store.open_default ();
            // A file that cannot be loaded at all is left out: the engines
            // type with the last one that loaded, which this process never
            // had, and the 用户自造词 window says why.
            string? phrases = store.enabled && store.report != null ? store.text : null;
            var report = new CodeLookup.Report (query, CodeLookup.codes (query, phrases), store.enabled);

            answer = new Prompt (this, report.title, report.body, { "好" });
            yield answer.choose ();
            answer = null;
            // Back to the word, selected, so the next one replaces it.
            select_word ();
        }
    }
}
