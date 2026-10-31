// The user-dictionary window: a table over the phrases file, saved as it is
// edited — a port of the macOS window (macos/JdIME/UserDict/
// UserDictWindowController.swift), which says what it does and why.
//
// The table *is* the file. Rows are loaded from 用户自造词.txt (comments and
// blank lines skipped), and after every edit, addition, deletion or drag
// every row is written back as it is, in table order. The window validates
// nothing itself: libjd's notes on the file, mapped onto the rows by line
// after every save, are the 状态 column — red for a row the engine skips,
// grey for one it drops as a duplicate, orange for one whose code is
// already taken. 移除重复词条 offers to delete the duplicates.
//
// Two departures from macOS. A row added and left empty is dropped rather
// than written. And a file that cannot be read — not UTF-8, unreadable — is
// shown as an empty table that cannot be edited, where macOS would let the
// first edit replace the file: here the text editor is the way to fix it.

namespace ImeJd {

    public class Window : Gtk.ApplicationWindow {
        /** Rows in table order: the file's order. */
        private GLib.ListStore rows = new GLib.ListStore (typeof (Row));
        private Gtk.CustomFilter filter;
        /** The rows on screen: all of them, or the search hits. */
        private Gtk.FilterListModel shown;
        private Gtk.MultiSelection selection;
        /** The search, case-folded; empty when not searching. */
        private string query = "";

        private Store store;
        /** Whether the window's size is the user's to keep: not when it is
         * trying out a file of its own (--file). */
        private bool keeps_size;
        /** What the last save wrote, or the text last loaded, so a change
         * that reads back identical — our own write — keeps the table. */
        private string? last_known_text;

        private TextCell? editing_cell;
        /** The row a double-click is on, for the activation that follows,
         * and whether on its 编码 cell. */
        private Row? click_row;
        private bool click_keys;
        /** That row, to edit once the click's button is up. */
        private Row? click_edit;
        /** A row to edit as soon as it is on screen, and which cell. */
        private Row? pending_edit;
        private bool pending_edit_keys;
        /** The rows a drag is moving. */
        private Row[] dragged = {};
        private Gtk.Widget? drop_mark;
        private bool updating_check;

        private Gtk.CheckButton enable_check;
        private Gtk.SearchEntry search_entry;
        private Gtk.ColumnView view;
        private Gtk.Button add_button;
        private Gtk.Button remove_button;
        private Gtk.Label status_label;

        public bool read_only {
            get { return store.read_only; }
        }

        public Window (Gtk.Application application, Store store, bool keeps_size) {
            Object (application: application, title: "用户自造词");
            this.store = store;
            this.keeps_size = keeps_size;

            int width = 0, height = 0;
            bool maximized = false;
            if (keeps_size && store.window_size (out width, out height, out maximized)) {
                set_default_size (width, height);
                this.maximized = maximized;
            } else {
                set_default_size (620, 440);
            }
            set_size_request (480, 300);

            build_content ();

            store.changed.connect (store_changed);
            close_request.connect (() => {
                // An edit in progress is kept, as a click elsewhere keeps it.
                end_editing ();
                if (this.keeps_size) {
                    int w, h;
                    get_default_size (out w, out h);
                    this.store.save_window_size (w, h, this.maximized);
                }
                return false;
            });

            load_rows ();
            sync_check ();
            update_status ();
            update_controls ();
        }

        private void build_content () {
            enable_check = new Gtk.CheckButton.with_label ("启用用户自造词");
            enable_check.hexpand = true;
            enable_check.halign = Gtk.Align.START;
            enable_check.toggled.connect (toggle_enabled);

            search_entry = new Gtk.SearchEntry ();
            search_entry.placeholder_text = "搜索词或编码";
            search_entry.width_request = 200;
            search_entry.search_changed.connect (() => {
                query = search_entry.text.strip ().casefold ();
                refilter ();
            });
            search_entry.stop_search.connect (() => search_entry.text = "");

            var top = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            top.append (enable_check);
            top.append (search_entry);

            // The table.
            filter = new Gtk.CustomFilter ((item) => matches ((Row) item));
            shown = new Gtk.FilterListModel (rows, filter);
            selection = new Gtk.MultiSelection (shown);
            selection.selection_changed.connect (() => update_controls ());

            view = new Gtk.ColumnView (selection);
            view.add_css_class ("data-table");
            view.show_row_separators = true;
            view.append_column (column ("词", 220, true, () => new TextCell (this, true)));
            view.append_column (column ("编码", 110, false, () => new TextCell (this, false)));
            view.append_column (column ("状态", 220, true, () => new StatusCell (this)));
            // A double-click edits the cell clicked; Return, the cell with
            // the focus; 词 when it is neither.
            view.activate.connect ((position) => {
                var row = (Row) shown.get_item (position);
                if (row == click_row) {
                    click_row = null;
                    click_edit = row;
                    return;
                }
                var focused = get_focus ();
                var cell = focused == null ? null : focused.get_first_child () as TextCell;
                edit_row (row, cell != null && !cell.is_value);
            });
            // A double-click's edit starts once its button is up. The row
            // takes the focus as the click ends (GTK 4.12 on), so an edit
            // started before then would lose it, and taking it back costs
            // IBus's GTK 4 module, on X11, the next key.
            var click_end = new Gtk.EventControllerLegacy ();
            click_end.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            click_end.event.connect ((event) => {
                switch (event.get_event_type ()) {
                case Gdk.EventType.BUTTON_PRESS:
                case Gdk.EventType.TOUCH_BEGIN:
                    click_row = null;
                    click_edit = null;
                    break;
                case Gdk.EventType.BUTTON_RELEASE:
                case Gdk.EventType.TOUCH_END:
                    if (click_edit != null) {
                        var row = click_edit;
                        bool keys = click_keys;
                        click_edit = null;
                        Idle.add (() => {
                            if (index_of (row) >= 0) {
                                edit_row (row, keys);
                            }
                            return Source.REMOVE;
                        });
                    }
                    break;
                default:
                    break;
                }
                return false;
            });
            // Gtk.Widget's add_controller: a window is a ShortcutManager too,
            // whose add_controller files a controller among the window's
            // managed shortcuts.
            ((Gtk.Widget) this).add_controller (click_end);

            var delete_key = new Gtk.ShortcutController ();
            var delete_action = new Gtk.CallbackAction ((widget, args) => {
                remove_selected.begin ();
                return true;
            });
            foreach (uint keyval in new uint[] { Gdk.Key.Delete, Gdk.Key.KP_Delete }) {
                delete_key.add_shortcut (new Gtk.Shortcut (new Gtk.KeyvalTrigger (keyval, 0), delete_action));
            }
            view.add_controller (delete_key);

            // Dropped below the last row, a drag goes to the end.
            var drop = new Gtk.DropTarget (typeof (Row), Gdk.DragAction.MOVE);
            drop.enter.connect ((x, y) => view_drop_motion (x, y));
            drop.motion.connect ((x, y) => view_drop_motion (x, y));
            drop.leave.connect (() => clear_drop_mark ());
            drop.on_drop.connect ((dropped, x, y) => view_drop_on (x, y));
            view.add_controller (drop);

            var scroll = new Gtk.ScrolledWindow ();
            scroll.child = view;
            scroll.has_frame = true;
            scroll.vexpand = true;

            // The bottom bar.
            add_button = new Gtk.Button.from_icon_name ("list-add-symbolic");
            add_button.tooltip_text = "添加词条";
            add_button.clicked.connect (() => add_row ());
            remove_button = new Gtk.Button.from_icon_name ("list-remove-symbolic");
            remove_button.tooltip_text = "删除选中的词条";
            remove_button.clicked.connect (() => remove_selected.begin ());
            var add_remove = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            add_remove.add_css_class ("linked");
            add_remove.append (add_button);
            add_remove.append (remove_button);

            var duplicates_button = new Gtk.Button.with_label ("移除重复词条");
            duplicates_button.clicked.connect (() => remove_duplicates.begin ());
            var editor_button = new Gtk.Button.with_label ("用文本编辑器打开");
            editor_button.clicked.connect (() => {
                end_editing ();
                open_in_editor ();
            });

            status_label = new Gtk.Label (null);
            status_label.add_css_class ("dim-label");
            status_label.add_css_class ("status-line");
            status_label.hexpand = true;
            status_label.xalign = 1;
            status_label.ellipsize = Pango.EllipsizeMode.END;

            var bottom = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            bottom.append (add_remove);
            bottom.append (duplicates_button);
            bottom.append (editor_button);
            bottom.append (status_label);

            // A click on a button leaves an edit's focus where it is: the
            // button ends the edit itself, at once.
            foreach (var button in new Gtk.Button[] { add_button, remove_button, duplicates_button, editor_button }) {
                button.focus_on_click = false;
            }

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 10);
            content.margin_top = 14;
            content.margin_bottom = 14;
            content.margin_start = 16;
            content.margin_end = 16;
            content.append (top);
            content.append (scroll);
            content.append (bottom);
            child = content;

            var find = new Gtk.ShortcutController ();
            find.add_shortcut (new Gtk.Shortcut (
                Gtk.ShortcutTrigger.parse_string ("<Control>f"),
                new Gtk.CallbackAction ((widget, args) => search_entry.grab_focus ())));
            // Gtk.Widget's, as above.
            ((Gtk.Widget) this).add_controller (find);
        }

        private delegate Cell CellMaker ();

        private Gtk.ColumnViewColumn column (string title, int width, bool expand, owned CellMaker make) {
            var factory = new Gtk.SignalListItemFactory ();
            // GObject, not ListItem: GTK 4.12 widened the signals' argument
            // to it, and either GTK passes a ListItem.
            factory.setup.connect ((item) => ((Gtk.ListItem) item).child = make ());
            factory.bind.connect ((item) => {
                var list_item = (Gtk.ListItem) item;
                ((Cell) list_item.child).bind ((Row) list_item.item);
            });
            factory.unbind.connect ((item) => ((Cell) ((Gtk.ListItem) item).child).unbind ());
            var column = new Gtk.ColumnViewColumn (title, factory);
            column.fixed_width = width;
            column.expand = expand;
            column.resizable = true;
            return column;
        }

        // MARK: - Model

        /** The table from the file as the store last read it. */
        private void load_rows () {
            end_editing (false);
            pending_edit = null;
            last_known_text = store.text;
            var parsed = UserDictFile.parse (store.text ?? "");
            var items = new Object[parsed.length];
            for (int i = 0; i < parsed.length; i++) {
                items[i] = new Row (parsed[i].value, parsed[i].keys, parsed[i].line);
            }
            selection.unselect_all ();
            rows.splice (0, rows.get_n_items (), items);
            recompute_problems ();
        }

        private Row row_at (uint index) {
            return (Row) rows.get_item (index);
        }

        private int index_of (Row row) {
            uint index;
            return rows.find (row, out index) ? (int) index : -1;
        }

        /** Writes every row as it is, in table order, and re-derives each
         * row's line; the engine, not the window, decides what is valid. A
         * row added and left empty is dropped instead. */
        private void save_rows () {
            for (int i = (int) rows.get_n_items () - 1; i >= 0; i--) {
                if (row_at (i).abandoned) {
                    rows.remove (i);
                }
            }
            uint count = rows.get_n_items ();
            var values = new string[count];
            var keys = new string[count];
            for (uint i = 0; i < count; i++) {
                var row = row_at (i);
                row.line = UserDictFile.line_of_entry ((int) i);
                values[i] = row.value;
                keys[i] = row.keys;
            }
            last_known_text = UserDictFile.serialize (values, keys);
            try {
                store.save (last_known_text);
            } catch (Error error) {
                warning ("save failed: %s", error.message);
                inform.begin ("无法保存用户自造词", error.message);
            }
            recompute_problems ();
        }

        /** libjd's notes on the file the rows were last written to, or read
         * from, mapped onto the rows by line. */
        private void recompute_problems () {
            uint count = rows.get_n_items ();
            var lines = new int[count];
            for (uint i = 0; i < count; i++) {
                lines[i] = row_at (i).line;
            }
            var problems = Problem.for_rows (lines, store.error == null ? store.report : null);
            for (uint i = 0; i < count; i++) {
                row_at (i).problem = problems[i];
            }
        }

        /** After a change to the rows: save, and bring the rest in line. */
        private void commit_rows () {
            save_rows ();
            if (query != "") {
                refilter ();
            }
            update_status ();
            update_controls ();
        }

        private bool matches (Row row) {
            return query == "" || query in row.value.casefold () || query in row.keys.casefold ();
        }

        private void refilter () {
            filter.changed (Gtk.FilterChange.DIFFERENT);
            update_controls ();
        }

        private void clear_search () {
            if (query != "" || search_entry.text != "") {
                query = "";
                search_entry.text = "";
                refilter ();
            }
        }

        private void update_status () {
            uint invalid = 0, duplicates = 0, shared = 0;
            for (uint i = 0; i < rows.get_n_items (); i++) {
                Problem? problem = row_at (i).problem;
                if (problem == null) {
                    continue;
                }
                switch (problem.kind) {
                case ProblemKind.INVALID:
                    invalid++;
                    break;
                case ProblemKind.DUPLICATE:
                    duplicates++;
                    break;
                default:
                    shared++;
                    break;
                }
            }
            string[] parts = { "共 %u 条".printf (rows.get_n_items ()) };
            if (invalid > 0) {
                parts += "%u 条无效".printf (invalid);
            }
            if (duplicates > 0) {
                parts += "%u 条重复".printf (duplicates);
            }
            if (shared > 0) {
                parts += "%u 条同码".printf (shared);
            }
            if (store.error != null) {
                parts += store.error.message;
            }
            if (!store.enabled) {
                parts += "已停用";
            }
            status_label.label = string.joinv ("，", parts);
            status_label.tooltip_text = status_label.label;
        }

        private void update_controls () {
            add_button.sensitive = !read_only;
            remove_button.sensitive = !read_only && !selection.get_selection ().is_empty ();
        }

        private void sync_check () {
            updating_check = true;
            enable_check.active = store.enabled;
            updating_check = false;
        }

        private void store_changed () {
            sync_check ();
            if (store.text != last_known_text) {
                // Changed from outside: a text editor, most likely.
                load_rows ();
            } else {
                recompute_problems ();
            }
            update_status ();
            update_controls ();
        }

        /** The selected rows, in table order. */
        private Row[] selected_rows () {
            Row[] selected = {};
            for (uint i = 0; i < shown.get_n_items (); i++) {
                if (selection.is_selected (i)) {
                    selected += (Row) shown.get_item (i);
                }
            }
            return selected;
        }

        /** Selects `chosen`, and nothing else, in one go. */
        private void select_rows (Row[] chosen) {
            var wanted = set_of (chosen);
            var positions = new Gtk.Bitset.empty ();
            uint count = shown.get_n_items ();
            for (uint i = 0; i < count; i++) {
                if (wanted.contains ((Row) shown.get_item (i))) {
                    positions.add (i);
                }
            }
            selection.set_selection (positions, new Gtk.Bitset.range (0, count));
            if (!positions.is_empty ()) {
                scroll_to (positions.get_minimum ());
            }
        }

        private static GenericSet<Row> set_of (Row[] chosen) {
            var set = new GenericSet<Row> (direct_hash, direct_equal);
            foreach (var row in chosen) {
                set.add (row);
            }
            return set;
        }

        private bool find_shown (Row row, out uint position) {
            for (position = 0; position < shown.get_n_items (); position++) {
                if (shown.get_item (position) == row) {
                    return true;
                }
            }
            return false;
        }

        /** Brings the row at `position` on screen. GTK 4.6 has no
         * gtk_column_view_scroll_to (4.12); the list inside the view has the
         * action its own keyboard navigation uses. */
        private void scroll_to (uint position) {
            var list = view.get_last_child ();
            if (list != null && list.activate_action ("list.scroll-to-item", "u", position)) {
                return;
            }
            var adjustment = view.vadjustment;
            uint count = shown.get_n_items ();
            if (adjustment == null || count == 0) {
                return;
            }
            double row_height = adjustment.upper / count;
            adjustment.value = position * row_height - (adjustment.page_size - row_height) / 2;
        }

        // MARK: - Editing

        /** Ends the edit in progress, keeping it unless told otherwise. Every
         * action starts here, so nothing runs under a half-made edit. */
        private void end_editing (bool commit = true) {
            if (editing_cell != null) {
                editing_cell.stop_editing (commit);
            }
        }

        /** A double-click on `cell`, before the row's activation. */
        public void double_clicked (Cell cell) {
            click_row = cell.row;
            var text_cell = cell as TextCell;
            click_keys = text_cell != null && !text_cell.is_value;
        }

        /** Selects `row` and edits its 词 cell, or its 编码 cell. */
        public void edit_row (Row row, bool keys) {
            if (read_only) {
                return;
            }
            uint position;
            if (find_shown (row, out position)) {
                selection.select_item (position, true);
                scroll_to (position);
            }
            var cell = keys ? row.keys_cell : row.value_cell;
            if (cell != null) {
                cell.start_editing ();
            } else {
                // Off screen: edited once it is bound.
                pending_edit = row;
                pending_edit_keys = keys;
            }
        }

        public void cell_bound (TextCell cell) {
            if (pending_edit == null || cell.row != pending_edit || cell.is_value == pending_edit_keys) {
                return;
            }
            pending_edit = null;
            Idle.add (() => {
                if (cell.row != null && cell.get_root () == this) {
                    cell.start_editing ();
                }
                return Source.REMOVE;
            });
        }

        public void editing_started (TextCell cell) {
            if (editing_cell != null && editing_cell != cell) {
                editing_cell.stop_editing (true, editing_cell.row == cell.row);
            }
            editing_cell = cell;
        }

        /** A cell edit ended: save when it changed anything. Only the 状态
         * column changes on screen; the cells already show the text. */
        public void editing_stopped (TextCell cell, bool changed, bool moving_on) {
            if (editing_cell == cell) {
                editing_cell = null;
            }
            var row = cell.row;
            if (row == null || index_of (row) < 0) {
                return;
            }
            if (row.line == 0 && row.value == "" && row.keys == "") {
                // Added and left empty: dropped, unless the edit is moving on
                // to the row's other cell.
                if (!moving_on) {
                    Idle.add (() => {
                        int index = index_of (row);
                        if (index >= 0 && row.abandoned) {
                            rows.remove (index);
                            update_status ();
                            update_controls ();
                        }
                        return Source.REMOVE;
                    });
                }
                return;
            }
            // A row never written yet is written even when the edit changed
            // nothing, so the engine's verdict on it shows.
            if (changed || row.line == 0) {
                save_rows ();
                update_status ();
            }
        }

        /** Tab in an edited cell: on to the next cell — 词, 编码, then the
         * next row's 词 — or back with Shift. */
        public void tab_from (TextCell cell, bool backwards) {
            var row = cell.row;
            if (row == null) {
                return;
            }
            Row? target = row;
            bool keys = cell.is_value;
            if (!backwards && !cell.is_value || backwards && cell.is_value) {
                uint position;
                target = null;
                if (find_shown (row, out position)) {
                    int next = (int) position + (backwards ? -1 : 1);
                    if (next >= 0 && next < shown.get_n_items ()) {
                        target = (Row) shown.get_item (next);
                    }
                }
            }
            cell.stop_editing (true, target == row);
            if (target != null && index_of (target) >= 0) {
                edit_row (target, keys);
            }
        }

        // MARK: - Actions

        private void toggle_enabled () {
            if (updating_check) {
                return;
            }
            end_editing ();
            try {
                store.save_switch (enable_check.active);
            } catch (Error error) {
                warning ("cannot save the switch: %s", error.message);
                sync_check ();
                inform.begin ("无法保存设置", error.message);
            }
            update_status ();
        }

        /** A new, empty row below the selection (or at the end), its 词 cell
         * already being edited. It is written, like every row, when the edit
         * ends; the engine then says what it thinks of it. */
        private void add_row () {
            end_editing ();
            if (rows.get_n_items () >= Jd.USER_DICT_MAX_ENTRIES) {
                inform.begin ("词条数量已达上限", "用户自造词最多 %u 条。".printf (Jd.USER_DICT_MAX_ENTRIES));
                return;
            }
            // The search is cleared, so the new row is on screen.
            var selected = selected_rows ();
            int insert_at = selected.length > 0 ? index_of (selected[selected.length - 1]) + 1 : (int) rows.get_n_items ();
            clear_search ();
            var row = new Row ("", "", 0);
            rows.insert (insert_at, row);
            update_status ();
            edit_row (row, false);
        }

        private async void remove_selected () {
            end_editing ();
            var selected = selected_rows ();
            if (selected.length == 0 || read_only) {
                return;
            }
            if (selected.length > 1) {
                var prompt = new Prompt (this, "删除选中的 %d 条词条？".printf (selected.length),
                    "删除后立即生效，无法撤销。", { "取消", "删除" }, 1, 0, true);
                if ((yield prompt.choose ()) != 1) {
                    return;
                }
            }
            remove_rows (selected);
        }

        private void remove_rows (Row[] doomed) {
            var set = set_of (doomed);
            bool removed = false;
            for (int i = (int) rows.get_n_items () - 1; i >= 0; i--) {
                if (set.contains (row_at (i))) {
                    rows.remove (i);
                    removed = true;
                }
            }
            // None left to remove: the file changed under a prompt, and the
            // table was read again.
            if (!removed) {
                return;
            }
            selection.unselect_all ();
            commit_rows ();
        }

        /** Moves `moving` so the rows sit, in table order, just above the row
         * now at `target` (the row count: the end). */
        private void move_rows (Row[] moving, int target) {
            var set = set_of (moving);
            // In table order, wherever they were picked from; the rows above
            // the target that go shift it up.
            Object[] ordered = {};
            int insert_at = target;
            for (uint i = 0; i < rows.get_n_items (); i++) {
                if (set.contains (row_at (i))) {
                    ordered += row_at (i);
                    if (i < target) {
                        insert_at--;
                    }
                }
            }
            // One row at a time, not the whole table: the view keeps its
            // place.
            for (int i = (int) rows.get_n_items () - 1; i >= 0; i--) {
                if (set.contains (row_at (i))) {
                    rows.remove (i);
                }
            }
            rows.splice (insert_at, 0, ordered);
            commit_rows ();
            selection.select_range (insert_at, ordered.length, true);
        }

        /** What 移除重复词条 finds: the rows libjd drops as duplicates and
         * the rows whose code is already taken, with the rows it skipped
         * counted; or, while the file cannot be loaded at all, nothing. */
        private async void remove_duplicates () {
            end_editing ();
            if (store.error != null) {
                var prompt = new Prompt (this, "无法移除重复词条",
                    "用户自造词文件无法读入：%s。请用文本编辑器修正文件；文件可读后，状态列才会标出无效、重复与同码的词条。"
                        .printf (store.error.message),
                    { "用文本编辑器打开", "好" }, 1, 1);
                if ((yield prompt.choose ()) == 0) {
                    open_in_editor ();
                }
                return;
            }
            Row[] duplicates = {}, shared = {};
            int invalid = 0, of_rows = 0;
            for (uint i = 0; i < rows.get_n_items (); i++) {
                var row = row_at (i);
                if (row.problem == null) {
                    continue;
                }
                switch (row.problem.kind) {
                case ProblemKind.INVALID:
                    invalid++;
                    break;
                case ProblemKind.DUPLICATE:
                    duplicates += row;
                    if (row.problem.other_row >= 0) {
                        of_rows++;
                    }
                    break;
                default:
                    shared += row;
                    break;
                }
            }
            string invalid_note = "另有 %d 条无效的词条（标红），输入法已跳过。".printf (invalid);
            if (duplicates.length == 0 && shared.length == 0) {
                string text = "与前面某条词条完全相同、或与内置词库中同一编码下的词相同的词条，算重复，不会生效。";
                if (invalid > 0) {
                    text += "\n" + invalid_note;
                }
                yield new Prompt (this, "没有重复词条", text, { "好" }, 0, 0).choose ();
                return;
            }

            string[] details = {};
            if (duplicates.length > 0) {
                details += "重复：%d 条与前面的词条相同，%d 条与内置词库相同；这些词条不会出现在候选中。"
                    .printf (of_rows, duplicates.length - of_rows);
            }
            if (shared.length > 0) {
                details += "同码（保留）：%d 条词条的编码已有内置词或其他自造词；这些词条仍然生效，并排在内置词之前，多条自造词同码时按表中顺序排列。"
                    .printf (shared.length);
            }
            if (invalid > 0) {
                details += invalid_note;
            }
            string detail = string.joinv ("\n", details);
            // 选中查看 selects every flagged row to look at instead.
            bool look;
            if (duplicates.length > 0) {
                var prompt = new Prompt (this, "移除 %d 条重复词条？".printf (duplicates.length), detail,
                    { "取消", "选中查看", "移除" }, 2, 0);
                int answer = yield prompt.choose ();
                if (answer == 2) {
                    remove_rows (duplicates);
                    return;
                }
                look = answer == 1;
            } else {
                var prompt = new Prompt (this, "没有重复词条", detail, { "选中查看", "好" }, 1, 1);
                look = (yield prompt.choose ()) == 0;
            }
            if (look) {
                clear_search ();
                Row[] flagged = duplicates;
                foreach (var row in shared) {
                    flagged += row;
                }
                select_rows (flagged);
            }
        }

        /** The same file, in the desktop's text editor. The store watches
         * the file, so a save there shows up here, and in the engines. */
        private void open_in_editor () {
            if (!FileUtils.test (store.file_path, FileTest.EXISTS)) {
                try {
                    UserDictFile.write (store.file_path, UserDictFile.serialize ({}, {}));
                } catch (Error error) {
                    inform.begin ("无法创建用户自造词文件", error.message);
                    return;
                }
            }
            var uri = File.new_for_path (store.file_path).get_uri ();
            AppInfo.launch_default_for_uri_async.begin (uri, get_display ().get_app_launch_context (), null,
                (obj, result) => {
                    try {
                        AppInfo.launch_default_for_uri_async.end (result);
                    } catch (Error error) {
                        warning ("cannot open %s: %s", uri, error.message);
                        inform.begin ("无法用文本编辑器打开", error.message);
                    }
                });
        }

        private async void inform (string message, string detail) {
            yield new Prompt (this, message, detail, { "好" }, 0, 0).choose ();
        }

        // MARK: - Drag to reorder (file order; not while searching)

        public Gdk.ContentProvider? drag_prepare (Cell cell, Gtk.DragSource source, double x, double y) {
            var row = cell.row;
            if (row == null || query != "" || read_only) {
                return null;
            }
            end_editing ();
            click_edit = null;
            uint position;
            dragged = find_shown (row, out position) && selection.is_selected (position)
                ? selected_rows ()
                : new Row[] { row };
            // The phrase under the pointer, as the row is dragged.
            Gtk.Widget icon = row.value_cell != null ? (Gtk.Widget) row.value_cell : cell;
            source.set_icon (new Gtk.WidgetPaintable (icon), icon == cell ? (int) x : 0, (int) y);
            var value = Value (typeof (Row));
            value.set_object (row);
            return new Gdk.ContentProvider.for_value (value);
        }

        public void drag_end () {
            dragged = {};
            clear_drop_mark ();
        }

        /** A drag over a row's cell, at `y` in it: above or below the row,
         * by the half it is over. */
        public Gdk.DragAction drop_motion (Cell cell, double y) {
            int target;
            bool above;
            if (!cell_drop (cell, y, out target, out above)) {
                clear_drop_mark_of (row_widget (cell));
                return 0;
            }
            mark_drop (row_widget (cell), above);
            return Gdk.DragAction.MOVE;
        }

        /** The drag left a cell: its row's mark goes, unless the next row's
         * has taken its place already. */
        public void drop_leave (Cell cell) {
            clear_drop_mark_of (row_widget (cell));
        }

        public bool drop_on (Cell cell, double y) {
            int target;
            bool above;
            clear_drop_mark ();
            if (!cell_drop (cell, y, out target, out above)) {
                return false;
            }
            move_rows (dragged, target);
            dragged = {};
            return true;
        }

        /** Where a drop at `y` in `cell` lands: above the row now at
         * `target`, which is the cell's row when `above`, the next when
         * not. */
        private bool cell_drop (Cell cell, double y, out int target, out bool above) {
            above = y < cell.get_height () / 2.0;
            int index = dragged.length == 0 || query != "" || cell.row == null ? -1 : index_of (cell.row);
            target = index + (above ? 0 : 1);
            return index >= 0;
        }

        /** A drag over the view. Its target sees every motion over it, its
         * cells' too, so it leaves those to the cells' own targets and marks
         * only what lies outside their content — a row's edge, or the space
         * below the last row — and refuses the header. */
        private Gdk.DragAction view_drop_motion (double x, double y) {
            int target;
            Gtk.Widget? mark;
            bool above, in_cell;
            if (!view_drop (x, y, out target, out mark, out above, out in_cell)) {
                clear_drop_mark ();
                return 0;
            }
            if (!in_cell) {
                mark_drop (mark, above);
            }
            return Gdk.DragAction.MOVE;
        }

        private bool view_drop_on (double x, double y) {
            int target;
            Gtk.Widget? mark;
            bool above, in_cell;
            bool valid = view_drop (x, y, out target, out mark, out above, out in_cell);
            clear_drop_mark ();
            if (!valid) {
                return false;
            }
            move_rows (dragged, target);
            dragged = {};
            return true;
        }

        /** Where a drop at the view's `x`, `y` lands, as the cell of the row
         * there would place it, or after the last row; false in the header.
         * `in_cell`: within a cell's content, which its own target marks. */
        private bool view_drop (double x, double y, out int target, out Gtk.Widget? mark, out bool above,
                                out bool in_cell) {
            target = 0;
            mark = null;
            above = false;
            in_cell = false;
            if (dragged.length == 0 || query != "") {
                return false;
            }
            var header = view.get_first_child ();
            if (header != null && y < header.get_height ()) {
                return false;
            }
            Cell? cell = null;
            for (var widget = view.pick (x, y, Gtk.PickFlags.DEFAULT); widget != null && widget != view;
                 widget = widget.get_parent ()) {
                if (widget is Cell) {
                    cell = (Cell) widget;
                    in_cell = true;
                    break;
                }
                // A cell's padding, or a row's separator: one of the row's
                // cells, each holding one of ours.
                var child = widget.get_first_child ();
                if (child is Cell) {
                    cell = (Cell) child;
                    break;
                }
                if (child != null && child.get_first_child () is Cell) {
                    cell = (Cell) child.get_first_child ();
                    break;
                }
            }
            if (cell == null) {
                uint count = rows.get_n_items ();
                target = (int) count;
                if (count > 0) {
                    mark = row_widget (row_at (count - 1).value_cell);
                }
                return true;
            }
            double cell_x, cell_y;
            view.translate_coordinates (cell, x, y, out cell_x, out cell_y);
            mark = row_widget (cell);
            return cell_drop (cell, cell_y, out target, out above);
        }

        /** Shows where a drop goes: a line on the top or bottom edge of
         * `row`, the row widget. */
        private void mark_drop (Gtk.Widget? row, bool above) {
            if (row != drop_mark) {
                clear_drop_mark ();
                drop_mark = row;
            }
            if (drop_mark != null) {
                drop_mark.add_css_class (above ? "drop-above" : "drop-below");
                drop_mark.remove_css_class (above ? "drop-below" : "drop-above");
            }
        }

        private void clear_drop_mark () {
            if (drop_mark != null) {
                drop_mark.remove_css_class ("drop-above");
                drop_mark.remove_css_class ("drop-below");
                drop_mark = null;
            }
        }

        /** Clears the mark if `row` has it. */
        private void clear_drop_mark_of (Gtk.Widget? row) {
            if (row != null && row == drop_mark) {
                clear_drop_mark ();
            }
        }

        /** The row widget a cell is in: cell, column view cell, row. */
        private static Gtk.Widget? row_widget (Cell? cell) {
            return cell?.get_parent ()?.get_parent ();
        }
    }
}
