//! The 用户自造词 window: a dialog-based tool over the phrases file, laid out
//! like the system's own list editors — the phrases on the left, a column of
//! buttons on the right (新建… 编辑… 删除, 上移 下移, …), 关闭 at the bottom —
//! and built from the templates in userdict.rc, so the dialog manager does
//! what it does in every Windows dialog: Tab order, Alt+letter mnemonics,
//! Enter and Escape, keeping the focus across a switch to another window,
//! and rescaling on a monitor with another DPI.
//!
//! Each confirmed change — a phrase added or edited in the entry dialog
//! (entry.rs), rows deleted or moved — rewrites the whole file at once
//! (table.rs), and the IME, which reads the file and the switch by
//! itself in every host process (windows/src/user_dict.rs), adopts it at its
//! next composition. Nothing here judges a phrase: libjd's notes on the
//! build of what was written are the status column — red for a row the
//! engine skips because it does not parse, grey for a duplicate it drops,
//! orange for a row whose code is already taken, by a built-in word or by
//! another row: it works, listed first, and the flag is a warning only.
//! 上移 and 下移 decide the order among phrases on one code; they are off
//! while a search narrows the list.
//!
//! The list also answers the usual way: Enter or a double-click edits a row,
//! Delete deletes, Ctrl+A selects everything, and the context menu carries
//! the row commands. 用文本编辑器打开 hands the file to whatever opens
//! `.txt`, which is also how a whole list of phrases comes in or goes out —
//! the file is plain text the user can reach — and the folder watcher
//! (watch.rs) brings a save made there back here.

mod entry;
mod problem;
mod prompt;
mod store;
mod table;
mod watch;

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::path::PathBuf;
use std::rc::Rc;

use jd::UserDict;
use jd_userdict::{Entry, file, switch};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    COLOR_GRAYTEXT, COLOR_WINDOWTEXT, ClientToScreen, GetSysColor, InvalidateRect,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE, REG_BINARY, REG_OPTION_NON_VOLATILE,
    RRF_RT_REG_BINARY, RegCloseKey, RegCreateKeyExW, RegGetValueW, RegSetValueExW,
};
use windows::Win32::UI::Controls::{
    BST_CHECKED, BST_UNCHECKED, CDDS_ITEMPREPAINT, CDDS_PREPAINT, CDDS_SUBITEM, CDRF_DODEFAULT,
    CDRF_NEWFONT, CDRF_NOTIFYITEMDRAW, CDRF_NOTIFYSUBITEMDRAW, CheckDlgButton, EM_SETCUEBANNER,
    EMF_CENTERED, ICC_LISTVIEW_CLASSES, ICC_STANDARD_CLASSES, INITCOMMONCONTROLSEX,
    InitCommonControlsEx, IsDlgButtonChecked, LIST_VIEW_ITEM_STATE_FLAGS, LVCF_FMT, LVCF_TEXT,
    LVCF_WIDTH, LVCFMT_LEFT, LVCOLUMNW, LVHITTESTINFO, LVIF_TEXT, LVIR_BOUNDS, LVIS_FOCUSED,
    LVIS_SELECTED, LVITEMW, LVM_ENSUREVISIBLE, LVM_GETCOLUMNWIDTH, LVM_GETITEMRECT,
    LVM_GETNEXTITEM, LVM_INSERTCOLUMNW, LVM_SETCOLUMNWIDTH, LVM_SETEXTENDEDLISTVIEWSTYLE,
    LVM_SETITEMCOUNT, LVM_SETITEMSTATE, LVM_SUBITEMHITTEST, LVN_GETDISPINFOW,
    LVN_GETEMPTYMARKUP, LVN_ITEMCHANGED, LVN_KEYDOWN, LVN_ODSTATECHANGED, LVNI_FOCUSED,
    LVNI_SELECTED, LVS_EX_DOUBLEBUFFER, LVS_EX_FULLROWSELECT, LVS_EX_LABELTIP,
    LVSCW_AUTOSIZE_USEHEADER, LVSICF_NOSCROLL, NM_CUSTOMDRAW, NM_DBLCLK, NMHDR, NMITEMACTIVATE,
    NMLVCUSTOMDRAW, NMLVDISPINFOW, NMLVEMPTYMARKUP, NMLVKEYDOWN, SetWindowTheme,
};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetFocus, GetKeyState, IsWindowEnabled, SetFocus, VK_CONTROL, VK_DELETE,
};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, BN_CLICKED, BeginDeferWindowPos, CreatePopupMenu, DLGWINDOWEXTRA, DWLP_MSGRESULT,
    DefDlgProcW, DeferWindowPos, DestroyMenu, DialogBoxParamW, EN_CHANGE, EndDeferWindowPos,
    EndDialog, FindWindowW, GetClientRect, GetDlgItem, GetWindowPlacement, GetWindowRect,
    GetWindowTextLengthW, GetWindowTextW, IDC_ARROW, IsIconic, KillTimer, LoadCursorW,
    LoadIconW, MF_ENABLED, MF_GRAYED, MF_SEPARATOR, MF_STRING, MINMAXINFO, MapDialogRect,
    RegisterClassExW, SW_RESTORE, SW_SHOWMINIMIZED, SW_SHOWNORMAL, SWP_NOACTIVATE, SWP_NOZORDER,
    SendMessageW, SetDlgItemTextW, SetForegroundWindow, SetMenuDefaultItem, SetTimer,
    SetWindowLongPtrW, SetWindowPlacement, SetWindowTextW, ShowWindow, TPM_RETURNCMD,
    TPM_RIGHTBUTTON, TrackPopupMenu, WINDOWPLACEMENT, WM_APP, WM_COMMAND, WM_CONTEXTMENU,
    WM_DESTROY, WM_DPICHANGED, WM_GETMINMAXINFO, WM_INITDIALOG, WM_NOTIFY, WM_SIZE, WM_TIMER,
    WNDCLASSEXW,
};
use windows::Win32::UI::Accessibility::{HCF_HIGHCONTRASTON, HIGHCONTRASTW};
use windows::Win32::UI::WindowsAndMessaging::{
    IDCANCEL, IDOK, SPI_GETHIGHCONTRAST, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
    SystemParametersInfoW, WINDOW_LONG_PTR_INDEX,
};
use windows::core::{HSTRING, PCWSTR, Result, w};

use entry::Field;
use problem::Problem;
use table::{Column, DuplicateCheck, Table};
use watch::Watcher;

/// The window's title, and every message's.
pub const TITLE: &str = "键道用户自造词";
/// The window class the template names: it carries the seal for the title
/// bar and the taskbar, and lets a second launch find this window.
const CLASS: PCWSTR = w!("JdUserDictWindow");

// IDs from userdict.rc.
const IDD_MAIN: u16 = 100;
const IDC_ENABLE: i32 = 1001;
const IDC_SEARCH_LABEL: i32 = 1002;
const IDC_SEARCH: i32 = 1003;
const IDC_LIST: i32 = 1004;
const IDC_STATUS: i32 = 1005;
const IDC_NEW: i32 = 1010;
const IDC_EDIT: i32 = 1011;
const IDC_DELETE: i32 = 1012;
const IDC_UP: i32 = 1013;
const IDC_DOWN: i32 = 1014;
const IDC_DEDUPE: i32 = 1015;
const IDC_OPEN: i32 = 1018;

/// The button column, top to bottom, in its groups.
const BUTTON_GROUPS: [&[i32]; 4] = [
    &[IDC_NEW, IDC_EDIT, IDC_DELETE],
    &[IDC_UP, IDC_DOWN],
    &[IDC_DEDUPE],
    &[IDC_OPEN],
];

/// Answers beyond 好 and 取消.
const ANSWER_DELETE: i32 = 100;
const ANSWER_SELECT: i32 = 101;
const ANSWER_OPEN: i32 = 102;

/// Posted by the watcher: the folder changed, or a switch was set.
const WM_APP_FILE_CHANGED: u32 = WM_APP + 1;
const WM_APP_SWITCH_CHANGED: u32 = WM_APP + 2;
/// One save is a burst of change events; the list reloads once they settle.
const TIMER_RELOAD: usize = 1;
const RELOAD_DELAY_MS: u32 = 300;

/// The window's size and position, kept beside the switch.
const PLACEMENT_VALUE: PCWSTR = w!("UserDictWindowPlacement");

/// The status column's colours: Windows' own critical and caution text;
/// duplicates take the system's grey text.
const INVALID_TEXT: COLORREF = rgb(0xC4, 0x2B, 0x1C);
const SHARED_TEXT: COLORREF = rgb(0x9D, 0x5D, 0x00);

const fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
    COLORREF(r as u32 | (g as u32) << 8 | (b as u32) << 16)
}

/// What `run` hands the dialog procedure for WM_INITDIALOG.
struct Launch {
    path: PathBuf,
    remember_placement: bool,
}

struct Window {
    hwnd: HWND,
    list: HWND,
    search: HWND,
    table: RefCell<Table>,
    watcher: RefCell<Option<Watcher>>,
    /// Whether this is the user's own file, whose window comes back where it
    /// was; a `--file` window opens as the template lays it out.
    remember_placement: bool,
    /// The window's size as the template made it: the smallest it goes.
    min_size: Cell<(i32, i32)>,
    dpi: Cell<u32>,
}

thread_local! {
    static LAUNCH: RefCell<Option<Launch>> = const { RefCell::new(None) };
    static WINDOW: RefCell<Option<Rc<Window>>> = const { RefCell::new(None) };
}

pub(super) fn instance() -> HINSTANCE {
    // SAFETY: the module handle of this executable.
    unsafe { GetModuleHandleW(None) }.map(Into::into).unwrap_or_default()
}

/// Bring an open window forward. Returns whether there was one.
pub fn activate_existing() -> bool {
    // SAFETY: plain window calls.
    unsafe {
        let Ok(hwnd) = FindWindowW(CLASS, PCWSTR::null()) else {
            return false;
        };
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let _ = SetForegroundWindow(hwnd);
        true
    }
}

/// Show the window over the file at `path` until it is closed.
pub fn run(path: PathBuf, remember_placement: bool) -> Result<()> {
    // SAFETY: class registration and a modal dialog, all on this thread.
    unsafe {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_STANDARD_CLASSES | ICC_LISTVIEW_CLASSES,
        };
        let _ = InitCommonControlsEx(&controls);

        // The seal, embedded by build.rs as icon 1.
        let icon = LoadIconW(Some(instance()), PCWSTR(1 as _)).unwrap_or_default();
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(dialog_class_proc),
            cbWndExtra: DLGWINDOWEXTRA as i32,
            hInstance: instance(),
            hIcon: icon,
            hIconSm: icon,
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            lpszClassName: CLASS,
            ..Default::default()
        };
        RegisterClassExW(&class);

        LAUNCH.with(|launch| {
            *launch.borrow_mut() = Some(Launch {
                path,
                remember_placement,
            })
        });
        let result = DialogBoxParamW(
            Some(instance()),
            PCWSTR(IDD_MAIN as usize as *const u16),
            None,
            Some(main_proc),
            LPARAM(0),
        );
        if result == -1 {
            return Err(windows::core::Error::from_thread());
        }
    }
    Ok(())
}

/// A dialog window class's procedure is the dialog manager's own.
unsafe extern "system" fn dialog_class_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    unsafe { DefDlgProcW(hwnd, msg, wparam, lparam) }
}

impl Window {
    fn item(&self, id: i32) -> HWND {
        // SAFETY: a lookup among this dialog's own controls.
        unsafe { GetDlgItem(Some(self.hwnd), id).unwrap_or_default() }
    }

    /// Dialog units to pixels, for this window's font and DPI.
    fn dlu(&self, x: i32, y: i32) -> (i32, i32) {
        let mut rect = RECT {
            left: 0,
            top: 0,
            right: x,
            bottom: y,
        };
        // SAFETY: MapDialogRect converts the RECT in place.
        unsafe {
            let _ = MapDialogRect(self.hwnd, &mut rect);
        }
        (rect.right, rect.bottom)
    }

    /// Set up the controls the template cannot, read the file, and start
    /// watching it.
    fn init(&self) {
        // SAFETY: plain window calls on this dialog's controls.
        unsafe {
            let styles = (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_LABELTIP) as usize;
            SendMessageW(
                self.list,
                LVM_SETEXTENDEDLISTVIEWSTYLE,
                Some(WPARAM(styles)),
                Some(LPARAM(styles as isize)),
            );
            // The selection look of Explorer and the system's own lists.
            let _ = SetWindowTheme(self.list, w!("Explorer"), PCWSTR::null());
            for (index, (title, width)) in [("词", 110), ("编码", 50), ("状态", 120)].into_iter().enumerate() {
                let title: Vec<u16> = title.encode_utf16().chain([0]).collect();
                let column = LVCOLUMNW {
                    mask: LVCF_TEXT | LVCF_WIDTH | LVCF_FMT,
                    fmt: LVCFMT_LEFT,
                    cx: self.dlu(width, 0).0,
                    pszText: windows::core::PWSTR(title.as_ptr() as *mut u16),
                    ..Default::default()
                };
                SendMessageW(
                    self.list,
                    LVM_INSERTCOLUMNW,
                    Some(WPARAM(index)),
                    Some(LPARAM(&column as *const _ as isize)),
                );
            }
            let cue = HSTRING::from("词或编码");
            SendMessageW(
                self.search,
                EM_SETCUEBANNER,
                Some(WPARAM(1)),
                Some(LPARAM(cue.as_ptr() as isize)),
            );
            let check = if switch::is_enabled() { BST_CHECKED } else { BST_UNCHECKED };
            let _ = CheckDlgButton(self.hwnd, IDC_ENABLE, check);

            let mut frame = RECT::default();
            let _ = GetWindowRect(self.hwnd, &mut frame);
            self.min_size.set((frame.right - frame.left, frame.bottom - frame.top));
            if self.remember_placement {
                self.restore_placement();
            }
            self.layout();
            self.refresh_list();
            let _ = SetFocus(Some(self.list));
        }
        let dir = self.table.borrow().store().path.parent().map(|dir| dir.to_path_buf());
        if let Some(dir) = dir {
            let _ = std::fs::create_dir_all(&dir);
            *self.watcher.borrow_mut() =
                Watcher::start(&dir, self.hwnd, WM_APP_FILE_CHANGED, WM_APP_SWITCH_CHANGED);
        }
    }

    /// Lay the controls out for the window's size, in the template's dialog
    /// units: the list takes the room, the button column and the bottom row
    /// keep to the right and the bottom edge.
    fn layout(&self) {
        let mut client = RECT::default();
        // SAFETY: plain window calls.
        if unsafe { GetClientRect(self.hwnd, &mut client) }.is_err()
            || client.right <= 0
            || client.bottom <= 0
        {
            return;
        }
        let (margin_x, margin_y) = self.dlu(7, 7);
        let (gap_x, gap_y) = self.dlu(6, 4);
        let (_, group_gap) = self.dlu(0, 10);
        let (button_w, button_h) = self.dlu(79, 14);
        let (check_w, check_h) = self.dlu(120, 12);
        let (label_w, text_h) = self.dlu(38, 10);
        let (search_w, _) = self.dlu(90, 0);

        let right = client.right - margin_x;
        let column_x = right - button_w;
        let list_right = column_x - gap_x;
        let bottom_y = client.bottom - margin_y - button_h;
        let list_top = margin_y + button_h + gap_y;
        let list_bottom = bottom_y - margin_y;
        let search_x = list_right - search_w;

        let mut places = vec![
            (IDC_ENABLE, margin_x, margin_y + (button_h - check_h) / 2, check_w, check_h),
            (IDC_SEARCH_LABEL, search_x - gap_x - label_w, margin_y + (button_h - text_h) / 2, label_w, text_h),
            (IDC_SEARCH, search_x, margin_y, search_w, button_h),
            (IDC_LIST, margin_x, list_top, list_right - margin_x, (list_bottom - list_top).max(0)),
            (IDC_STATUS, margin_x, bottom_y + (button_h - text_h) / 2, list_right - margin_x, text_h),
            (IDCANCEL.0, column_x, bottom_y, button_w, button_h),
        ];
        let mut y = list_top;
        for group in BUTTON_GROUPS {
            for &id in group {
                places.push((id, column_x, y, button_w, button_h));
                y += button_h + gap_y;
            }
            y += group_gap - gap_y;
        }

        // SAFETY: deferred moves of this dialog's own controls.
        unsafe {
            let Ok(mut batch) = BeginDeferWindowPos(places.len() as i32) else {
                return;
            };
            for (id, x, y, width, height) in places {
                match DeferWindowPos(
                    batch,
                    self.item(id),
                    None,
                    x,
                    y,
                    width,
                    height,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                ) {
                    Ok(next) => batch = next,
                    Err(_) => return,
                }
            }
            let _ = EndDeferWindowPos(batch);
            // The status column takes what the others leave.
            SendMessageW(
                self.list,
                LVM_SETCOLUMNWIDTH,
                Some(WPARAM(2)),
                Some(LPARAM(LVSCW_AUTOSIZE_USEHEADER as isize)),
            );
        }
    }

    // ---- The list --------------------------------------------------------

    /// After any change to the rows: the row count, every visible row, the
    /// buttons and the status line.
    fn refresh_list(&self) {
        let count = self.table.borrow().shown().len();
        // SAFETY: plain messages to this dialog's list.
        unsafe {
            SendMessageW(
                self.list,
                LVM_SETITEMCOUNT,
                Some(WPARAM(count)),
                Some(LPARAM(LVSICF_NOSCROLL as isize)),
            );
            let _ = InvalidateRect(Some(self.list), None, false);
        }
        self.update_buttons();
        self.update_status();
    }

    /// The selected rows, as positions in the list.
    fn selected_view_rows(&self) -> Vec<usize> {
        let mut rows = Vec::new();
        let mut index: isize = -1;
        loop {
            // SAFETY: LVM_GETNEXTITEM walks the selection from `index`.
            index = unsafe {
                SendMessageW(
                    self.list,
                    LVM_GETNEXTITEM,
                    Some(WPARAM(index as usize)),
                    Some(LPARAM(LVNI_SELECTED as isize)),
                )
            }
            .0;
            if index < 0 {
                return rows;
            }
            rows.push(index as usize);
        }
    }

    /// The selected rows, as indices into the table, ascending.
    fn selected_rows(&self) -> Vec<usize> {
        let view_rows = self.selected_view_rows();
        let table = self.table.borrow();
        view_rows
            .into_iter()
            .filter_map(|row| table.shown().get(row).copied())
            .collect()
    }

    fn focused_view_row(&self) -> Option<usize> {
        // SAFETY: LVM_GETNEXTITEM from -1 finds the focused item.
        let index = unsafe {
            SendMessageW(
                self.list,
                LVM_GETNEXTITEM,
                Some(WPARAM(usize::MAX)),
                Some(LPARAM(LVNI_FOCUSED as isize)),
            )
        }
        .0;
        (index >= 0).then_some(index as usize)
    }

    fn set_item_state(
        &self,
        view_row: isize,
        state: LIST_VIEW_ITEM_STATE_FLAGS,
        mask: LIST_VIEW_ITEM_STATE_FLAGS,
    ) {
        let item = LVITEMW {
            state,
            stateMask: mask,
            ..Default::default()
        };
        // SAFETY: the item outlives the call; -1 means every row.
        unsafe {
            SendMessageW(
                self.list,
                LVM_SETITEMSTATE,
                Some(WPARAM(view_row as usize)),
                Some(LPARAM(&item as *const _ as isize)),
            );
        }
    }

    /// Select exactly `rows` (indices into the table) as far as they are
    /// shown, focusing and revealing the first.
    fn select_rows(&self, rows: &[usize]) {
        let view_rows: Vec<usize> = {
            let table = self.table.borrow();
            rows.iter()
                .filter_map(|row| table.shown().iter().position(|shown| shown == row))
                .collect()
        };
        let selected_and_focused = LIST_VIEW_ITEM_STATE_FLAGS(LVIS_SELECTED.0 | LVIS_FOCUSED.0);
        self.set_item_state(-1, LIST_VIEW_ITEM_STATE_FLAGS(0), selected_and_focused);
        for (n, &row) in view_rows.iter().enumerate() {
            let state = if n == 0 { selected_and_focused } else { LVIS_SELECTED };
            self.set_item_state(row as isize, state, state);
        }
        if let Some(&first) = view_rows.first() {
            // SAFETY: a plain message to the list.
            unsafe {
                SendMessageW(self.list, LVM_ENSUREVISIBLE, Some(WPARAM(first)), Some(LPARAM(0)));
            }
        }
        self.update_buttons();
    }

    fn update_buttons(&self) {
        let selected = self.selected_rows();
        let (filtering, len) = {
            let table = self.table.borrow();
            (table.is_filtering(), table.rows().len())
        };
        let states = [
            (IDC_EDIT, selected.len() == 1),
            (IDC_DELETE, !selected.is_empty()),
            (IDC_UP, !filtering && selected.first().is_some_and(|&first| first > 0)),
            (IDC_DOWN, !filtering && selected.last().is_some_and(|&last| last + 1 < len)),
        ];
        // SAFETY: plain window calls.
        unsafe {
            for (id, on) in states {
                let button = self.item(id);
                // A button that goes grey under the keyboard focus would
                // strand it; hand it to the list.
                if !on && GetFocus() == button {
                    let _ = SetFocus(Some(self.list));
                }
                let _ = EnableWindow(button, on);
            }
        }
    }

    fn is_switched_on(&self) -> bool {
        // SAFETY: a plain query of this dialog's check box.
        unsafe { IsDlgButtonChecked(self.hwnd, IDC_ENABLE) == BST_CHECKED.0 }
    }

    fn update_status(&self) {
        let text = self.table.borrow().summary(self.is_switched_on());
        // SAFETY: the control copies the text.
        unsafe {
            let _ = SetDlgItemTextW(self.hwnd, IDC_STATUS, &HSTRING::from(text));
        }
    }

    // ---- Commands ----------------------------------------------------------

    fn save_failed(&self, error: &std::io::Error) {
        prompt::tell(self.hwnd, prompt::Icon::Warning, "无法保存用户自造词", &error.to_string());
    }

    /// 新建…: the entry dialog, and the phrase below the selection (or at
    /// the end).
    fn new_entry(&self) {
        if !self.table.borrow().can_add() {
            prompt::tell(
                self.hwnd,
                prompt::Icon::Information,
                "词条数量已达上限",
                &format!("用户自造词最多 {} 条。", UserDict::MAX_ENTRIES),
            );
            return;
        }
        let Some(entry) = entry::ask(self.hwnd, "新建词条", &Entry::default(), Field::Value, None)
        else {
            return;
        };
        let at = self
            .selected_rows()
            .last()
            .map_or_else(|| self.table.borrow().rows().len(), |&last| last + 1);
        // The search is cleared, so the new phrase is on screen.
        self.clear_search();
        let result = self.table.borrow_mut().add(at, &entry);
        self.refresh_list();
        match result {
            Ok(row) => self.select_rows(&[row]),
            Err(error) => self.save_failed(&error),
        }
    }

    /// 编辑…: the selected phrase in the entry dialog, with the caret in
    /// `field`.
    fn edit_selected(&self, field: Field) {
        let [row] = self.selected_rows()[..] else {
            return;
        };
        let (current, problem) = {
            let table = self.table.borrow();
            let row = &table.rows()[row];
            (row.entry.clone(), row.problem)
        };
        let Some(entry) = entry::ask(self.hwnd, "编辑词条", &current, field, problem) else {
            return;
        };
        let result = self.table.borrow_mut().replace(row, &entry);
        self.refresh_list();
        self.select_rows(&[row]);
        if let Err(error) = result {
            self.save_failed(&error);
        }
    }

    /// 删除, after asking: the change is saved at once and cannot be undone.
    fn delete_selected(&self) {
        let rows = self.selected_rows();
        let instruction = match rows[..] {
            [] => return,
            [row] => format!("删除词条「{}」？", self.table.borrow().rows()[row].entry.value),
            _ => format!("删除选中的 {} 条词条？", rows.len()),
        };
        let answer = prompt::ask(
            self.hwnd,
            prompt::Icon::Warning,
            &instruction,
            "删除后立即生效，无法撤销。",
            &[(ANSWER_DELETE, "删除"), (prompt::CANCEL, "取消")],
        );
        if answer != ANSWER_DELETE {
            return;
        }
        let first_view_row = self.selected_view_rows().first().copied().unwrap_or(0);
        let result = self.table.borrow_mut().remove(&rows);
        self.refresh_list();
        // The keyboard stays where it was: on the row that took the place of
        // the first one deleted.
        let count = self.table.borrow().shown().len();
        let next: Vec<usize> = if count == 0 {
            Vec::new()
        } else {
            let table = self.table.borrow();
            vec![table.shown()[first_view_row.min(count - 1)]]
        };
        self.select_rows(&next);
        if let Err(error) = result {
            self.save_failed(&error);
        }
    }

    fn move_selected(&self, up: bool) {
        let rows = self.selected_rows();
        let (filtering, len) = {
            let table = self.table.borrow();
            (table.is_filtering(), table.rows().len())
        };
        let (Some(&first), Some(&last)) = (rows.first(), rows.last()) else {
            return;
        };
        // Above the row before the first, or above the row after the next.
        let target = match up {
            _ if filtering => return,
            true if first > 0 => first - 1,
            false if last + 1 < len => last + 2,
            _ => return,
        };
        let result = self.table.borrow_mut().move_rows(&rows, target);
        self.refresh_list();
        match result {
            Ok(moved) => self.select_rows(&moved.collect::<Vec<_>>()),
            Err(error) => self.save_failed(&error),
        }
    }

    /// 移除重复词条…: the offer to delete the rows libjd drops as
    /// duplicates, counted and explained. While the file cannot be loaded at
    /// all it says so instead: the engine never built this version of the
    /// file, so there are no notes to act on.
    fn remove_duplicates(&self) {
        let check = self.table.borrow().duplicate_check();
        match check {
            DuplicateCheck::Unavailable { reason } => {
                let text = format!(
                    "用户自造词文件无法读入：{reason}。请用文本编辑器修正文件；文件可读后，状态列才会标出无效、重复与同码的词条。"
                );
                let answer = prompt::ask(
                    self.hwnd,
                    prompt::Icon::Warning,
                    "无法移除重复词条",
                    &text,
                    &[(prompt::OK, "好"), (ANSWER_OPEN, "用文本编辑器打开")],
                );
                if answer == ANSWER_OPEN {
                    self.open_in_editor();
                }
            }
            DuplicateCheck::Clean { invalid } => {
                let mut text = "与前面某条词条完全相同、或与内置词库中同一编码下的词相同的词条，算重复，不会生效。".to_owned();
                if invalid > 0 {
                    text.push('\n');
                    text.push_str(&invalid_note(invalid));
                }
                prompt::tell(self.hwnd, prompt::Icon::Information, "没有重复词条", &text);
            }
            DuplicateCheck::Found {
                duplicates,
                shared,
                invalid,
            } => self.offer_removal(&duplicates, &shared, invalid),
        }
    }

    /// The counts and what they mean, with 移除 for the duplicates when
    /// there are any, and 选中查看 for every flagged row.
    fn offer_removal(&self, duplicates: &[usize], shared: &[usize], invalid: usize) {
        let mut details = Vec::new();
        if !duplicates.is_empty() {
            let of_rows = {
                let table = self.table.borrow();
                duplicates
                    .iter()
                    .filter(|&&row| {
                        matches!(
                            table.rows()[row].problem,
                            Some(Problem::Duplicate { of_row: Some(_) })
                        )
                    })
                    .count()
            };
            details.push(format!(
                "重复：{of_rows} 条与前面的词条相同，{} 条与内置词库相同；这些词条不会出现在候选中。",
                duplicates.len() - of_rows
            ));
        }
        if !shared.is_empty() {
            details.push(format!(
                "同码（保留）：{} 条词条的编码已有内置词或其他自造词；这些词条仍然生效，并排在内置词之前，多条自造词同码时按列表中的顺序排列。",
                shared.len()
            ));
        }
        if invalid > 0 {
            details.push(invalid_note(invalid));
        }
        let answer = if duplicates.is_empty() {
            prompt::ask(
                self.hwnd,
                prompt::Icon::Information,
                "没有重复词条",
                &details.join("\n"),
                &[(prompt::OK, "好"), (ANSWER_SELECT, "选中查看")],
            )
        } else {
            prompt::ask(
                self.hwnd,
                prompt::Icon::Warning,
                &format!("移除 {} 条重复词条？", duplicates.len()),
                &details.join("\n"),
                &[
                    (ANSWER_DELETE, "移除"),
                    (ANSWER_SELECT, "选中查看"),
                    (prompt::CANCEL, "取消"),
                ],
            )
        };
        match answer {
            ANSWER_DELETE => {
                let result = self.table.borrow_mut().remove(duplicates);
                self.refresh_list();
                self.select_rows(&[]);
                if let Err(error) = result {
                    self.save_failed(&error);
                }
            }
            ANSWER_SELECT => {
                self.clear_search();
                let mut flagged = [duplicates, shared].concat();
                flagged.sort_unstable();
                self.select_rows(&flagged);
                // SAFETY: a plain window call.
                unsafe {
                    let _ = SetFocus(Some(self.list));
                }
            }
            _ => {}
        }
    }

    /// The same file, in whatever opens `.txt`.
    fn open_in_editor(&self) {
        let path = self.table.borrow().store().path.clone();
        if !path.exists() {
            let _ = file::write(&path, &file::serialize(&[]));
        }
        // SAFETY: the path string outlives the call.
        let result = unsafe {
            ShellExecuteW(
                Some(self.hwnd),
                w!("open"),
                &HSTRING::from(path.as_os_str()),
                PCWSTR::null(),
                PCWSTR::null(),
                SW_SHOWNORMAL,
            )
        };
        if result.0 as isize <= 32 {
            prompt::tell(
                self.hwnd,
                prompt::Icon::Warning,
                "无法打开文本编辑器",
                &path.display().to_string(),
            );
        }
    }

    fn toggle_switch(&self) {
        let on = self.is_switched_on();
        if let Err(error) = switch::set_enabled(on) {
            // SAFETY: a plain call on this dialog's check box.
            unsafe {
                let _ = CheckDlgButton(self.hwnd, IDC_ENABLE, if on { BST_UNCHECKED } else { BST_CHECKED });
            }
            prompt::tell(self.hwnd, prompt::Icon::Warning, "无法更改设置", &error.message());
        }
        self.update_status();
    }

    /// A switch was set — in the mode icon's menu, from another process.
    fn sync_switch(&self) {
        let on = switch::is_enabled();
        if on != self.is_switched_on() {
            // SAFETY: a plain call on this dialog's check box.
            unsafe {
                let _ = CheckDlgButton(self.hwnd, IDC_ENABLE, if on { BST_CHECKED } else { BST_UNCHECKED });
            }
            self.update_status();
        }
    }

    fn search_changed(&self) {
        let text = window_text(self.search);
        self.table.borrow_mut().set_filter(&text);
        self.select_rows(&[]);
        self.refresh_list();
    }

    fn clear_search(&self) {
        if !window_text(self.search).is_empty() {
            // SAFETY: EN_CHANGE follows synchronously and refilters.
            unsafe {
                let _ = SetWindowTextW(self.search, w!(""));
            }
        }
    }

    /// The file changed on disk; a save from elsewhere replaces the rows.
    fn file_changed(&self) {
        if self.table.borrow_mut().file_changed() {
            self.select_rows(&[]);
        }
        self.refresh_list();
    }

    fn close(&self) {
        if self.remember_placement {
            self.save_placement();
        }
        // SAFETY: ends this modal dialog.
        unsafe {
            let _ = EndDialog(self.hwnd, 0);
        }
    }

    fn command(&self, id: i32, code: u32) {
        match (id, code) {
            (IDC_ENABLE, BN_CLICKED) => self.toggle_switch(),
            (IDC_SEARCH, EN_CHANGE) => self.search_changed(),
            (IDC_NEW, BN_CLICKED) => self.new_entry(),
            (IDC_EDIT, BN_CLICKED) => self.edit_selected(Field::Value),
            (IDC_DELETE, BN_CLICKED) => self.delete_selected(),
            (IDC_UP, BN_CLICKED) => self.move_selected(true),
            (IDC_DOWN, BN_CLICKED) => self.move_selected(false),
            (IDC_DEDUPE, BN_CLICKED) => self.remove_duplicates(),
            (IDC_OPEN, BN_CLICKED) => self.open_in_editor(),
            // Enter: the list's default action, editing; from the search box,
            // on to the results.
            (id, _) if id == IDOK.0 => {
                // SAFETY: plain window calls.
                let focus = unsafe { GetFocus() };
                if focus == self.list {
                    self.edit_selected(Field::Value);
                } else if focus == self.search {
                    unsafe {
                        let _ = SetFocus(Some(self.list));
                    }
                }
            }
            (id, _) if id == IDCANCEL.0 => self.close(),
            _ => {}
        }
    }

    // ---- The list's notifications -----------------------------------------

    /// What the dialog procedure should answer, when the answer matters.
    fn notify(&self, header: &NMHDR, lparam: LPARAM) -> Option<isize> {
        if header.hwndFrom != self.list {
            return None;
        }
        // SAFETY: each notification's lparam is the struct its code names.
        unsafe {
            match header.code {
                LVN_GETDISPINFOW => self.display_info(&mut *(lparam.0 as *mut NMLVDISPINFOW)),
                NM_CUSTOMDRAW => {
                    return Some(self.custom_draw(&mut *(lparam.0 as *mut NMLVCUSTOMDRAW)));
                }
                LVN_GETEMPTYMARKUP => {
                    return Some(self.empty_markup(&mut *(lparam.0 as *mut NMLVEMPTYMARKUP)));
                }
                LVN_ITEMCHANGED | LVN_ODSTATECHANGED => self.update_buttons(),
                NM_DBLCLK => {
                    let activate = &*(lparam.0 as *const NMITEMACTIVATE);
                    let mut hit = LVHITTESTINFO {
                        pt: activate.ptAction,
                        ..Default::default()
                    };
                    SendMessageW(
                        self.list,
                        LVM_SUBITEMHITTEST,
                        None,
                        Some(LPARAM(&mut hit as *mut _ as isize)),
                    );
                    if hit.iItem >= 0 {
                        let field = if hit.iSubItem == 1 { Field::Keys } else { Field::Value };
                        self.edit_selected(field);
                    }
                }
                LVN_KEYDOWN => {
                    let key = (*(lparam.0 as *const NMLVKEYDOWN)).wVKey;
                    if key == VK_DELETE.0 {
                        self.delete_selected();
                    } else if key == u16::from(b'A') && GetKeyState(VK_CONTROL.0 as i32) < 0 {
                        self.set_item_state(-1, LVIS_SELECTED, LVIS_SELECTED);
                    }
                }
                _ => {}
            }
        }
        None
    }

    /// The text of the cell the list is about to draw.
    fn display_info(&self, info: &mut NMLVDISPINFOW) {
        if info.item.mask & LVIF_TEXT != LVIF_TEXT || info.item.pszText.is_null() {
            return;
        }
        let Ok(table) = self.table.try_borrow() else {
            return;
        };
        let column = match info.item.iSubItem {
            0 => Column::Value,
            1 => Column::Keys,
            _ => Column::Status,
        };
        let text = table
            .shown()
            .get(info.item.iItem as usize)
            .map(|&row| table.cell_text(row, column))
            .unwrap_or_default();
        // SAFETY: the list hands a buffer of `cchTextMax` UTF-16 units.
        unsafe {
            copy_into(&text, info.item.pszText.0, info.item.cchTextMax);
        }
    }

    /// The status column in its verdict's colour.
    fn custom_draw(&self, draw: &mut NMLVCUSTOMDRAW) -> isize {
        let stage = draw.nmcd.dwDrawStage;
        if stage == CDDS_PREPAINT {
            return CDRF_NOTIFYITEMDRAW as isize;
        }
        if stage == CDDS_ITEMPREPAINT {
            return CDRF_NOTIFYSUBITEMDRAW as isize;
        }
        if stage.0 != CDDS_ITEMPREPAINT.0 | CDDS_SUBITEM.0 {
            return CDRF_DODEFAULT as isize;
        }
        let problem = (draw.iSubItem == 2)
            .then(|| {
                let table = self.table.try_borrow().ok()?;
                let row = *table.shown().get(draw.nmcd.dwItemSpec)?;
                table.rows()[row].problem
            })
            .flatten();
        let color = match problem {
            Some(problem) => problem_color(&problem),
            // SAFETY: GetSysColor only reads.
            None => Some(COLORREF(unsafe { GetSysColor(COLOR_WINDOWTEXT) })),
        };
        match color {
            Some(color) => {
                draw.clrText = color;
                CDRF_NEWFONT as isize
            }
            None => CDRF_DODEFAULT as isize,
        }
    }

    /// What an empty list says instead of nothing.
    fn empty_markup(&self, markup: &mut NMLVEMPTYMARKUP) -> isize {
        let Ok(table) = self.table.try_borrow() else {
            return 0;
        };
        let text = if table.is_filtering() {
            format!("没有符合「{}」的词条", table.filter())
        } else {
            "还没有词条。点「新建」添加一条，或「用文本编辑器打开」成批粘贴。".to_owned()
        };
        markup.dwFlags = EMF_CENTERED;
        // SAFETY: szMarkup is a fixed buffer of its own length.
        unsafe {
            copy_into(&text, markup.szMarkup.as_mut_ptr(), markup.szMarkup.len() as i32);
        }
        1
    }

    /// The row commands at the pointer, or under the selection for the
    /// keyboard's menu key; 编辑… in bold, as double-click does it.
    fn context_menu(&self, from: HWND, lparam: LPARAM) -> bool {
        if from != self.list {
            return false;
        }
        let mut at = POINT {
            x: (lparam.0 & 0xFFFF) as i16 as i32,
            y: ((lparam.0 >> 16) & 0xFFFF) as i16 as i32,
        };
        // SAFETY: plain menu and window calls on this thread.
        unsafe {
            if at.x == -1 && at.y == -1 {
                // From the keyboard: under the focused row, or the list's corner.
                let mut rect = RECT {
                    left: LVIR_BOUNDS as i32,
                    ..Default::default()
                };
                if let Some(row) = self.focused_view_row() {
                    SendMessageW(
                        self.list,
                        LVM_GETITEMRECT,
                        Some(WPARAM(row)),
                        Some(LPARAM(&mut rect as *mut _ as isize)),
                    );
                }
                at = POINT {
                    x: rect.left,
                    y: rect.bottom,
                };
                let _ = ClientToScreen(self.list, &mut at);
            }
            let Ok(menu) = CreatePopupMenu() else {
                return true;
            };
            let entries: [(i32, Option<&str>); 7] = [
                (IDC_EDIT, Some("编辑(&E)...")),
                (IDC_DELETE, Some("删除(&D)")),
                (0, None),
                (IDC_UP, Some("上移(&U)")),
                (IDC_DOWN, Some("下移(&O)")),
                (0, None),
                (IDC_NEW, Some("新建(&N)...")),
            ];
            for (id, label) in entries {
                let _ = match label {
                    None => AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null()),
                    Some(label) => {
                        let enabled = IsWindowEnabled(self.item(id)).as_bool();
                        AppendMenuW(
                            menu,
                            MF_STRING | if enabled { MF_ENABLED } else { MF_GRAYED },
                            id as usize,
                            &HSTRING::from(label),
                        )
                    }
                };
            }
            let _ = SetMenuDefaultItem(menu, IDC_EDIT as u32, 0);
            let chosen = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_RIGHTBUTTON,
                at.x,
                at.y,
                None,
                self.hwnd,
                None,
            );
            let _ = DestroyMenu(menu);
            if chosen.0 != 0 {
                self.command(chosen.0, BN_CLICKED);
            }
        }
        true
    }

    /// The dialog manager rescales the fonts and controls; the list's own
    /// column widths are this window's to scale.
    fn dpi_changed(&self, dpi: u32) {
        let old = self.dpi.replace(dpi.max(96));
        // SAFETY: plain messages to the list.
        unsafe {
            for column in 0..2 {
                let width = SendMessageW(self.list, LVM_GETCOLUMNWIDTH, Some(WPARAM(column)), None).0;
                SendMessageW(
                    self.list,
                    LVM_SETCOLUMNWIDTH,
                    Some(WPARAM(column)),
                    Some(LPARAM(width * dpi as isize / old as isize)),
                );
            }
        }
    }

    // ---- Placement ---------------------------------------------------------

    fn save_placement(&self) {
        let mut placement = WINDOWPLACEMENT {
            length: size_of::<WINDOWPLACEMENT>() as u32,
            ..Default::default()
        };
        // SAFETY: plain registry and window calls; the key is closed.
        unsafe {
            if GetWindowPlacement(self.hwnd, &mut placement).is_err() {
                return;
            }
            let mut key = HKEY::default();
            if RegCreateKeyExW(
                HKEY_CURRENT_USER,
                &HSTRING::from(switch::KEY),
                None,
                PCWSTR::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_SET_VALUE,
                None,
                &mut key,
                None,
            )
            .is_err()
            {
                return;
            }
            let bytes = std::slice::from_raw_parts(
                &placement as *const WINDOWPLACEMENT as *const u8,
                size_of::<WINDOWPLACEMENT>(),
            );
            let _ = RegSetValueExW(key, PLACEMENT_VALUE, None, REG_BINARY, Some(bytes));
            let _ = RegCloseKey(key);
        }
    }

    /// Put the window back where it was last closed.
    fn restore_placement(&self) {
        let mut placement = WINDOWPLACEMENT::default();
        let mut size = size_of::<WINDOWPLACEMENT>() as u32;
        // SAFETY: the value is read into a buffer of its own size only.
        unsafe {
            let read = RegGetValueW(
                HKEY_CURRENT_USER,
                &HSTRING::from(switch::KEY),
                PLACEMENT_VALUE,
                RRF_RT_REG_BINARY,
                None,
                Some(&mut placement as *mut WINDOWPLACEMENT as *mut c_void),
                Some(&mut size),
            );
            if read.is_err() || size != size_of::<WINDOWPLACEMENT>() as u32 {
                return;
            }
            placement.length = size;
            if placement.showCmd == SW_SHOWMINIMIZED.0 as u32 {
                placement.showCmd = SW_SHOWNORMAL.0 as u32;
            }
            let _ = SetWindowPlacement(self.hwnd, &placement);
        }
    }
}

fn invalid_note(invalid: usize) -> String {
    format!("另有 {invalid} 条无效的词条（标红），输入法已跳过。")
}

/// A verdict's colour — or none under a high-contrast theme, whose colours
/// are the user's to keep.
pub(super) fn problem_color(problem: &Problem) -> Option<COLORREF> {
    if high_contrast() {
        return None;
    }
    Some(match problem {
        Problem::Invalid { .. } => INVALID_TEXT,
        Problem::SharedCode { .. } => SHARED_TEXT,
        // SAFETY: GetSysColor only reads.
        Problem::Duplicate { .. } => COLORREF(unsafe { GetSysColor(COLOR_GRAYTEXT) }),
    })
}

fn high_contrast() -> bool {
    let mut contrast = HIGHCONTRASTW {
        cbSize: size_of::<HIGHCONTRASTW>() as u32,
        ..Default::default()
    };
    // SAFETY: the struct is the size it says it is.
    unsafe {
        SystemParametersInfoW(
            SPI_GETHIGHCONTRAST,
            contrast.cbSize,
            Some(&mut contrast as *mut HIGHCONTRASTW as *mut c_void),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
        .is_ok()
            && contrast.dwFlags & HCF_HIGHCONTRASTON == HCF_HIGHCONTRASTON
    }
}

pub(super) fn window_text(hwnd: HWND) -> String {
    // SAFETY: the buffer's length is passed along with it.
    unsafe {
        let len = GetWindowTextLengthW(hwnd).max(0) as usize;
        let mut buf = vec![0u16; len + 1];
        let copied = GetWindowTextW(hwnd, &mut buf).max(0) as usize;
        String::from_utf16_lossy(&buf[..copied])
    }
}

/// Copy `text` into a UTF-16 buffer of `capacity` units, cut short at a
/// character boundary if need be, NUL-terminated.
///
/// # Safety
/// `buffer` points to at least `capacity` writable units.
unsafe fn copy_into(text: &str, buffer: *mut u16, capacity: i32) {
    if buffer.is_null() || capacity <= 0 {
        return;
    }
    let capacity = capacity as usize;
    let mut written = 0;
    let mut units = [0u16; 2];
    for c in text.chars() {
        let encoded = c.encode_utf16(&mut units);
        if written + encoded.len() >= capacity {
            break;
        }
        for &unit in encoded.iter() {
            // SAFETY: `written` stays below `capacity - 1`.
            unsafe { *buffer.add(written) = unit };
            written += 1;
        }
    }
    // SAFETY: the terminator still fits.
    unsafe { *buffer.add(written) = 0 };
}

unsafe extern "system" fn main_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> isize {
    unsafe {
        if msg == WM_INITDIALOG {
            let Some(launch) = LAUNCH.with(|launch| launch.borrow_mut().take()) else {
                let _ = EndDialog(hwnd, -1);
                return 1;
            };
            let window = Rc::new(Window {
                hwnd,
                list: GetDlgItem(Some(hwnd), IDC_LIST).unwrap_or_default(),
                search: GetDlgItem(Some(hwnd), IDC_SEARCH).unwrap_or_default(),
                table: RefCell::new(Table::open(launch.path)),
                watcher: RefCell::new(None),
                remember_placement: launch.remember_placement,
                min_size: Cell::new((0, 0)),
                dpi: Cell::new(GetDpiForWindow(hwnd).max(96)),
            });
            WINDOW.with(|w| *w.borrow_mut() = Some(window.clone()));
            window.init();
            // The focus is on the list already.
            return 0;
        }
        // A handle on the window for this message, taken out of the cell so
        // a message sent while this one is handled finds it too.
        let Some(window) = WINDOW.with(|w| w.borrow().clone()) else {
            return 0;
        };
        match msg {
            WM_COMMAND => {
                window.command((wparam.0 & 0xFFFF) as i32, ((wparam.0 >> 16) & 0xFFFF) as u32);
                1
            }
            WM_NOTIFY => match window.notify(&*(lparam.0 as *const NMHDR), lparam) {
                Some(result) => {
                    SetWindowLongPtrW(hwnd, WINDOW_LONG_PTR_INDEX(DWLP_MSGRESULT as i32), result);
                    1
                }
                None => 0,
            },
            WM_CONTEXTMENU => isize::from(window.context_menu(HWND(wparam.0 as *mut c_void), lparam)),
            WM_SIZE => {
                window.layout();
                1
            }
            WM_GETMINMAXINFO => {
                let (width, height) = window.min_size.get();
                let info = &mut *(lparam.0 as *mut MINMAXINFO);
                info.ptMinTrackSize = POINT { x: width, y: height };
                1
            }
            // The dialog manager rescales the rest.
            WM_DPICHANGED => {
                window.dpi_changed((wparam.0 & 0xFFFF) as u32);
                0
            }
            WM_APP_FILE_CHANGED => {
                SetTimer(Some(hwnd), TIMER_RELOAD, RELOAD_DELAY_MS, None);
                1
            }
            WM_APP_SWITCH_CHANGED => {
                window.sync_switch();
                1
            }
            // A dialog of ours that is open — 编辑…, a question — disables
            // this window and acts on rows by index when it closes, so the
            // reload waits until it has.
            WM_TIMER if wparam.0 == TIMER_RELOAD => {
                if IsWindowEnabled(hwnd).as_bool() {
                    let _ = KillTimer(Some(hwnd), TIMER_RELOAD);
                    window.file_changed();
                }
                1
            }
            WM_DESTROY => {
                window.watcher.borrow_mut().take();
                WINDOW.with(|w| w.borrow_mut().take());
                0
            }
            _ => 0,
        }
    }
}

/// Shown when the window cannot come up at all.
pub fn report_startup_failure(message: &str) {
    prompt::tell(HWND::default(), prompt::Icon::Error, "无法打开用户自造词", message);
}

/// Shown when a switch the mode icon's menu set could not be written.
pub fn report_setting_failure(message: &str) {
    prompt::tell(HWND::default(), prompt::Icon::Error, "无法更改设置", message);
}
