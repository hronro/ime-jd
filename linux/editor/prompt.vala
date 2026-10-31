// A question or a notice over the window, as an alert says it on macOS: a
// message, the detail under it, and a row of buttons. GTK 4.6, the oldest
// GTK the editor runs on, has no AlertDialog (4.10), and its MessageDialog is
// deprecated from 4.10 on; this is the part of either the editor needs.

namespace ImeJd {

    public class Prompt : Gtk.Window {
        /** The answer: a button's index, or `cancel` when the prompt was
         * closed or Escape pressed. */
        private int answer;
        private int cancel;
        private SourceFunc? resume;

        /** `buttons` left to right; `default_index` is the one Return
         * presses, `cancel` the answer when the prompt is dismissed. A
         * `destructive` default is styled as one. */
        public Prompt (Gtk.Window parent, string message, string? detail, string[] buttons,
                       int default_index = 0, int cancel = -1, bool destructive = false) {
            Object (transient_for: parent, modal: true, resizable: false, destroy_with_parent: true);
            this.cancel = cancel;
            answer = cancel;
            add_css_class ("prompt");
            // No title bar: what MessageDialog does in GTK 4.6.
            set_titlebar (new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0));

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            box.margin_top = 24;
            box.margin_bottom = 20;
            box.margin_start = 24;
            box.margin_end = 24;

            var title = new Gtk.Label (message);
            title.add_css_class ("prompt-message");
            title.wrap = true;
            title.max_width_chars = 40;
            title.xalign = 0;
            box.append (title);

            if (detail != null) {
                var text = new Gtk.Label (detail);
                text.wrap = true;
                text.max_width_chars = 50;
                text.xalign = 0;
                text.selectable = true;
                // Selectable text grabs the focus; Return is for the buttons.
                text.can_focus = false;
                box.append (text);
            }

            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            row.halign = Gtk.Align.END;
            row.margin_top = 8;
            for (int i = 0; i < buttons.length; i++) {
                var button = new Gtk.Button.with_label (buttons[i]);
                int index = i;
                button.clicked.connect (() => finish (index));
                if (i == default_index) {
                    button.add_css_class (destructive ? "destructive-action" : "suggested-action");
                    default_widget = button;
                }
                row.append (button);
            }
            box.append (row);
            child = box;

            var escape = new Gtk.ShortcutController ();
            escape.add_shortcut (new Gtk.Shortcut (
                new Gtk.KeyvalTrigger (Gdk.Key.Escape, 0),
                new Gtk.CallbackAction ((widget, args) => {
                    finish (this.cancel);
                    return true;
                })));
            // Gtk.Widget's: a window is a ShortcutManager too, whose
            // add_controller would file it among the managed shortcuts.
            ((Gtk.Widget) this).add_controller (escape);
            close_request.connect (() => {
                finish (this.cancel);
                return true;
            });
        }

        /** Shows the prompt and waits for the answer. */
        public async int choose () {
            resume = choose.callback;
            present ();
            // Once shown: a window that is not yet takes its first button.
            default_widget.grab_focus ();
            yield;
            return answer;
        }

        private void finish (int index) {
            if (resume == null) {
                return;
            }
            answer = index;
            SourceFunc callback = (owned) resume;
            resume = null;
            destroy ();
            callback ();
        }
    }
}
