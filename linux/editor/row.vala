// A row of the table — one phrase — and the cells that show it. Cells are
// recycled as the table scrolls: a cell shows whichever row it is bound to,
// and a row knows its 词 and 编码 cells only while it is on screen.

namespace ImeJd {

    public class Row : Object {
        public string value { get; set; }
        public string keys { get; set; }
        /** The row's 1-based line in the file; 0 for a row added and not
         * yet written. */
        public int line { get; set; }
        /** What the engine says about the row; null when nothing is wrong. */
        public Problem? problem { get; set; }

        /** The row's cells, while it is on screen. */
        public unowned TextCell? value_cell;
        public unowned TextCell? keys_cell;

        public Row (string value, string keys, int line) {
            Object (value: value, keys: keys, line: line);
        }

        /** Whether either of the row's cells is being edited. */
        public bool editing {
            get {
                return (value_cell != null && value_cell.editing) || (keys_cell != null && keys_cell.editing);
            }
        }

        /** Added, never written, and still empty: a row the user started
         * and left. */
        public bool abandoned {
            get { return line == 0 && value == "" && keys == "" && !editing; }
        }
    }

    /** A cell of the table: the row it shows, and a handle to drag the row
     * by — any cell of it, as on macOS. */
    public abstract class Cell : Gtk.Widget {
        public Row? row { get; private set; }

        protected unowned Window window;

        static construct {
            set_layout_manager_type (typeof (Gtk.BinLayout));
        }

        protected Cell (Window window) {
            this.window = window;

            var drag = new Gtk.DragSource ();
            drag.actions = Gdk.DragAction.MOVE;
            unowned Gtk.DragSource source = drag;
            drag.prepare.connect ((x, y) => window.drag_prepare (this, source, x, y));
            drag.drag_end.connect ((drag_, delete_data) => window.drag_end ());
            add_controller (drag);

            // A double-click edits the cell clicked: the row activates on it,
            // and asks which cell that was — the focus says nothing by then,
            // as the row moves it to its first cell. The click is left to the
            // row.
            var clicks = new Gtk.GestureClick ();
            clicks.pressed.connect ((n_press, x, y) => {
                if (n_press == 2) {
                    window.double_clicked (this);
                }
            });
            add_controller (clicks);

            var drop = new Gtk.DropTarget (typeof (Row), Gdk.DragAction.MOVE);
            drop.enter.connect ((x, y) => window.drop_motion (this, y));
            drop.motion.connect ((x, y) => window.drop_motion (this, y));
            drop.leave.connect (() => window.drop_leave (this));
            drop.on_drop.connect ((dropped, x, y) => window.drop_on (this, y));
            add_controller (drop);
        }

        public override void dispose () {
            Gtk.Widget? child;
            while ((child = get_first_child ()) != null) {
                child.unparent ();
            }
            base.dispose ();
        }

        public virtual void bind (Row row) {
            this.row = row;
        }

        public virtual void unbind () {
            row = null;
        }
    }

    /** A 词 or 编码 cell, edited in place as on macOS: Return or a
     * double-click starts, Return or a click elsewhere keeps, Escape drops,
     * Tab moves on to the next cell. GTK's own EditableLabel is not used:
     * in GTK 4.6 its focus-out timeout outlives the label, and a table's
     * cells come and go. */
    public class TextCell : Cell {
        public bool is_value { get; private set; }

        public bool editing {
            get { return text.visible; }
        }

        private Gtk.Label label;
        private Gtk.Text text;
        private Gtk.EventControllerFocus text_focus;
        private uint pending_commit;

        static construct {
            set_layout_manager_type (typeof (Gtk.BinLayout));
            // The theme's rules for editable cells (GTK 4.6's .data-table).
            set_css_name ("editablelabel");
        }

        public TextCell (Window window, bool is_value) {
            base (window);
            this.is_value = is_value;
            if (!is_value) {
                add_css_class ("keys");
            }

            label = new Gtk.Label (null);
            label.xalign = 0;
            label.ellipsize = Pango.EllipsizeMode.END;
            text = new Gtk.Text ();
            text.placeholder_text = is_value ? "词" : "编码";
            text.visible = false;
            // The text goes over the label, in a widget named as
            // EditableLabel's is, for the theme.
            var stack = new EditStack ();
            label.set_parent (stack);
            text.set_parent (stack);
            stack.set_parent (this);
            // Only while editing: the hidden text must never take the focus.
            can_focus = false;

            text.activate.connect (() => stop_editing (true));
            text_focus = new Gtk.EventControllerFocus ();
            text_focus.leave.connect (() => {
                // As EditableLabel does: a moment's grace, so that the focus
                // passing through a popup of the text's own does not end it.
                if (editing && pending_commit == 0) {
                    pending_commit = Timeout.add (100, () => {
                        pending_commit = 0;
                        if (!text_focus.contains_focus) {
                            stop_editing (true);
                        }
                        return Source.REMOVE;
                    });
                }
            });
            text.add_controller (text_focus);

            // On the cell, not the text: a key reaches it only when neither
            // the text nor its input method wanted it.
            var keys = new Gtk.EventControllerKey ();
            keys.key_pressed.connect ((keyval, keycode, state) => {
                if (!editing) {
                    return false;
                }
                switch (keyval) {
                case Gdk.Key.Escape:
                    stop_editing (false);
                    return true;
                case Gdk.Key.Tab:
                case Gdk.Key.KP_Tab:
                case Gdk.Key.ISO_Left_Tab:
                    bool backwards = keyval == Gdk.Key.ISO_Left_Tab || (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                    window.tab_from (this, backwards);
                    return true;
                default:
                    return false;
                }
            });
            add_controller (keys);
        }

        public override void dispose () {
            if (pending_commit != 0) {
                Source.remove (pending_commit);
                pending_commit = 0;
            }
            base.dispose ();
        }

        public override void bind (Row row) {
            base.bind (row);
            if (is_value) {
                row.value_cell = this;
            } else {
                row.keys_cell = this;
            }
            show_text ();
            window.cell_bound (this);
        }

        public override void unbind () {
            // Kept, as a click elsewhere keeps it: the row may be scrolled far
            // away, or about to leave the table, which the window checks.
            stop_editing (true);
            if (row != null && is_value && row.value_cell == this) {
                row.value_cell = null;
            } else if (row != null && !is_value && row.keys_cell == this) {
                row.keys_cell = null;
            }
            base.unbind ();
        }

        public void start_editing () {
            if (editing || row == null || window.read_only) {
                return;
            }
            text.text = is_value ? row.value : row.keys;
            can_focus = true;
            text.visible = true;
            label.opacity = 0;
            add_css_class ("editing");
            // Which selects the text, as macOS does.
            text.grab_focus ();
            window.editing_started (this);
        }

        /** Ends the edit, keeping the text when `commit`; `moving_on` when
         * the edit moves to another cell of the table straight after. */
        public void stop_editing (bool commit, bool moving_on = false) {
            if (!editing) {
                return;
            }
            if (pending_commit != 0) {
                Source.remove (pending_commit);
                pending_commit = 0;
            }
            string edited = UserDictFile.trim (text.text, " ");
            // The text is about to be hidden: the focus goes back to the
            // table, where the keys that move about it work.
            if (text.is_focus ()) {
                get_parent ().grab_focus ();
            }
            text.visible = false;
            label.opacity = 1;
            remove_css_class ("editing");
            can_focus = false;
            bool changed = false;
            if (commit && row != null) {
                changed = edited != (is_value ? row.value : row.keys);
                if (is_value) {
                    row.value = edited;
                } else {
                    row.keys = edited;
                }
            }
            show_text ();
            window.editing_stopped (this, changed, moving_on);
        }

        /** The row's text, or a dim placeholder for an empty cell. */
        private void show_text () {
            string shown = row == null ? "" : is_value ? row.value : row.keys;
            if (shown == "") {
                label.label = is_value ? "词" : "编码";
                label.add_css_class ("dim-label");
            } else {
                label.label = shown;
                label.remove_css_class ("dim-label");
            }
        }
    }

    /** A text cell's label and, over it while editing, its text: the nodes
     * GTK's EditableLabel has (editablelabel > stack > text), which the
     * theme styles as an entry while editing. */
    private class EditStack : Gtk.Widget {
        static construct {
            set_layout_manager_type (typeof (Gtk.BinLayout));
            set_css_name ("stack");
        }

        public override void dispose () {
            Gtk.Widget? child;
            while ((child = get_first_child ()) != null) {
                child.unparent ();
            }
            base.dispose ();
        }
    }

    /** A 状态 cell: the engine's verdict on the row, red when the engine
     * skips the row, orange when its code is shared, grey for a duplicate,
     * as on macOS. */
    public class StatusCell : Cell {
        private Gtk.Label label;
        private ulong handler;

        static construct {
            set_layout_manager_type (typeof (Gtk.BinLayout));
        }

        public StatusCell (Window window) {
            base (window);
            label = new Gtk.Label (null);
            label.xalign = 0;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.add_css_class ("problem");
            label.set_parent (this);
        }

        public override void bind (Row row) {
            base.bind (row);
            handler = row.notify["problem"].connect (show_problem);
            show_problem ();
        }

        public override void unbind () {
            if (row != null && handler != 0) {
                row.disconnect (handler);
            }
            handler = 0;
            base.unbind ();
        }

        private void show_problem () {
            Problem? problem = row?.problem;
            label.label = problem?.text ?? "";
            label.tooltip_text = problem?.text;
            set_class ("problem-invalid", problem != null && problem.kind == ProblemKind.INVALID);
            set_class ("problem-shared", problem != null && problem.kind == ProblemKind.SHARED_CODE);
            set_class ("dim-label", problem != null && problem.kind == ProblemKind.DUPLICATE);
        }

        private void set_class (string name, bool on) {
            if (on) {
                label.add_css_class (name);
            } else {
                label.remove_css_class (name);
            }
        }
    }
}
