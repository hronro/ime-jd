//! The 新建词条 / 编辑词条 dialog (IDD_ENTRY in userdict.rc): a phrase and
//! its code, typed into two fields and confirmed with 确定.
//!
//! The dialog constrains the code the way an edit control can — letters
//! come out lowercase, at most `UserDict::MAX_KEY_LENGTH` of them, and no IME
//! composes there, so a code is never turned into Chinese — and 确定 waits
//! until both fields hold something. Everything else is the engine's to
//! judge after the save: when editing a row it already flagged, the dialog
//! repeats the verdict under the fields.

use std::ffi::c_void;

use jd::UserDict;
use jd_userdict::Entry;
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::Graphics::Gdi::{
    COLOR_BTNFACE, GetSysColorBrush, HDC, SetBkMode, SetTextColor, TRANSPARENT,
};
use windows::Win32::UI::Controls::EM_LIMITTEXT;
use windows::Win32::UI::Input::Ime::{HIMC, ImmAssociateContextEx};
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::{
    DialogBoxParamW, EN_CHANGE, EndDialog, GWLP_USERDATA, GetDlgCtrlID, GetDlgItem,
    GetWindowLongPtrW, IDCANCEL, IDOK, SendMessageW, SetDlgItemTextW, SetWindowLongPtrW,
    SetWindowTextW, WM_COMMAND, WM_CTLCOLORSTATIC, WM_INITDIALOG,
};
use windows::core::{HSTRING, PCWSTR};

use super::problem::Problem;
use super::{instance, problem_color, window_text};

// IDs from userdict.rc.
const IDD_ENTRY: u16 = 101;
const IDC_ENTRY_VALUE: i32 = 1101;
const IDC_ENTRY_KEYS: i32 = 1102;
const IDC_ENTRY_HINT: i32 = 1103;
const IDC_ENTRY_NOTE: i32 = 1104;

/// Which field has the caret when the dialog opens.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Field {
    Value,
    Keys,
}

struct State<'a> {
    title: &'a str,
    entry: Entry,
    focus: Field,
    /// The engine's verdict on the row being edited, if it flagged one.
    problem: Option<Problem>,
    /// Filled in by 确定.
    result: Option<Entry>,
}

/// Ask for a phrase: a new one (`entry` empty) or a change to `entry`.
/// `None` when the user cancels.
pub fn ask(
    owner: HWND,
    title: &str,
    entry: &Entry,
    focus: Field,
    problem: Option<Problem>,
) -> Option<Entry> {
    let mut state = State {
        title,
        entry: entry.clone(),
        focus,
        problem,
        result: None,
    };
    // SAFETY: the dialog is modal, so `state` outlives it; the procedure
    // reaches it through the dialog's user data.
    unsafe {
        DialogBoxParamW(
            Some(instance()),
            PCWSTR(IDD_ENTRY as usize as *const u16),
            Some(owner),
            Some(entry_proc),
            LPARAM(&mut state as *mut State as isize),
        );
    }
    state.result
}

/// # Safety
/// Only after WM_INITDIALOG stored the state, while `ask` is running.
unsafe fn state<'a>(hwnd: HWND) -> Option<&'a mut State<'a>> {
    unsafe { (GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut State).as_mut() }
}

fn field(hwnd: HWND, id: i32) -> HWND {
    // SAFETY: a lookup among this dialog's own controls.
    unsafe { GetDlgItem(Some(hwnd), id).unwrap_or_default() }
}

/// 确定 only once both fields hold more than spaces.
fn update_ok(hwnd: HWND) {
    let filled = |id| !window_text(field(hwnd, id)).trim_matches(' ').is_empty();
    let ready = filled(IDC_ENTRY_VALUE) && filled(IDC_ENTRY_KEYS);
    // SAFETY: a plain window call.
    unsafe {
        let _ = EnableWindow(field(hwnd, IDOK.0), ready);
    }
}

unsafe extern "system" fn entry_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> isize {
    unsafe {
        match msg {
            WM_INITDIALOG => {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, lparam.0);
                let Some(state) = state(hwnd) else {
                    return 1;
                };
                let _ = SetWindowTextW(hwnd, &HSTRING::from(state.title));
                let _ = SetDlgItemTextW(hwnd, IDC_ENTRY_VALUE, &HSTRING::from(&state.entry.value));
                let _ = SetDlgItemTextW(hwnd, IDC_ENTRY_KEYS, &HSTRING::from(&state.entry.keys));
                let hint = format!("1 到 {} 个小写字母", UserDict::MAX_KEY_LENGTH);
                let _ = SetDlgItemTextW(hwnd, IDC_ENTRY_HINT, &HSTRING::from(hint));
                if let Some(problem) = state.problem {
                    let note = format!("目前：{}", problem.text());
                    let _ = SetDlgItemTextW(hwnd, IDC_ENTRY_NOTE, &HSTRING::from(note));
                }
                let keys = field(hwnd, IDC_ENTRY_KEYS);
                // Codes are letters: no IME composes in this field.
                let _ = ImmAssociateContextEx(keys, HIMC::default(), 0);
                SendMessageW(
                    keys,
                    EM_LIMITTEXT,
                    Some(WPARAM(UserDict::MAX_KEY_LENGTH as usize)),
                    None,
                );
                update_ok(hwnd);
                let focus = match state.focus {
                    Field::Value => IDC_ENTRY_VALUE,
                    Field::Keys => IDC_ENTRY_KEYS,
                };
                let _ = SetFocus(Some(field(hwnd, focus)));
                // Focus is set.
                0
            }
            WM_COMMAND => {
                let id = (wparam.0 & 0xFFFF) as i32;
                let code = ((wparam.0 >> 16) & 0xFFFF) as u32;
                match id {
                    IDC_ENTRY_VALUE | IDC_ENTRY_KEYS if code == EN_CHANGE => update_ok(hwnd),
                    id if id == IDOK.0 => {
                        if let Some(state) = state(hwnd) {
                            state.result = Some(Entry::new(
                                window_text(field(hwnd, IDC_ENTRY_VALUE)),
                                window_text(field(hwnd, IDC_ENTRY_KEYS)),
                            ));
                        }
                        let _ = EndDialog(hwnd, IDOK.0 as isize);
                    }
                    id if id == IDCANCEL.0 => {
                        let _ = EndDialog(hwnd, IDCANCEL.0 as isize);
                    }
                    _ => return 0,
                }
                1
            }
            // The verdict under the fields, in the list's colour for it.
            WM_CTLCOLORSTATIC if GetDlgCtrlID(HWND(lparam.0 as *mut c_void)) == IDC_ENTRY_NOTE => {
                let Some(color) = state(hwnd)
                    .and_then(|state| state.problem)
                    .and_then(|problem| problem_color(&problem))
                else {
                    return 0;
                };
                let dc = HDC(wparam.0 as *mut c_void);
                SetTextColor(dc, color);
                SetBkMode(dc, TRANSPARENT);
                GetSysColorBrush(COLOR_BTNFACE).0 as isize
            }
            _ => 0,
        }
    }
}
