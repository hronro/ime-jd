//! 编码反查 (`ime_jd_userdict.exe --lookup`), started from the menu of the
//! IME's mode icon: a small dialog (IDD_LOOKUP in userdict.rc) that asks for
//! a word, and answers 查询 with the codes that type it, in a task dialog
//! over it (report.rs words the answer). They come from what the IME types
//! with right now: the built-in dictionary and, while it is switched on, the
//! user's phrases, read from the file afresh for every query and mapped from
//! the IME's cache when it holds them — so the candidate numbers count the
//! user's phrases that lead a code. Under 忽略内置词库, the phrases alone;
//! with none to be had, the answer says why rather than look in the
//! built-in dictionary.
//!
//! It is an ordinary window of a desktop process, so the word can be typed
//! into it with 键道 itself — Enter and Esc are the IME's while a code is
//! being typed — or pasted. 查询 waits until the field holds more than
//! spaces; closing the answer leaves the word selected, so the next one
//! replaces it. A second start brings the open dialog forward.

mod report;

use jd::{Dict, UserDict};
use jd_userdict::{LoadError, cache, file, switch};
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::Controls::{
    EM_SETCUEBANNER, ICC_STANDARD_CLASSES, INITCOMMONCONTROLSEX, InitCommonControlsEx,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, IsWindowEnabled, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::{
    DialogBoxParamW, EN_CHANGE, EndDialog, FindWindowW, GetDlgItem, GetLastActivePopup, IDCANCEL,
    IDOK, IsIconic, PostMessageW, SW_RESTORE, SendMessageW, SetForegroundWindow, ShowWindow,
    WM_COMMAND, WM_INITDIALOG, WM_NEXTDLGCTL,
};
use windows::core::{HSTRING, PCWSTR, Result, w};

use crate::window::{instance, prompt, register_dialog_class, window_text};
use report::{Report, Scope};

/// The dialog's title, and its answer's.
const TITLE: &str = "编码反查";
/// The window class the template names: it carries the seal for the title
/// bar and the taskbar, and lets a second start find this dialog.
const CLASS: PCWSTR = w!("JdCodeLookupWindow");

// IDs from userdict.rc.
const IDD_LOOKUP: u16 = 102;
const IDC_LOOKUP_WORD: i32 = 1201;

/// Bring an open dialog forward: the answer, while one is up, or else the
/// dialog with its word selected. Returns whether there was one.
pub fn activate_existing() -> bool {
    // SAFETY: plain window calls; the message names a control of the dialog
    // it is posted to.
    unsafe {
        let Ok(hwnd) = FindWindowW(CLASS, PCWSTR::null()) else {
            return false;
        };
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        // An answer that is up disables the dialog under it.
        if IsWindowEnabled(hwnd).as_bool()
            && let Ok(word) = GetDlgItem(Some(hwnd), IDC_LOOKUP_WORD)
        {
            let _ = PostMessageW(
                Some(hwnd),
                WM_NEXTDLGCTL,
                WPARAM(word.0 as usize),
                LPARAM(1),
            );
        }
        let _ = SetForegroundWindow(GetLastActivePopup(hwnd));
        true
    }
}

/// Show the dialog until it is closed.
pub fn run() -> Result<()> {
    // SAFETY: class registration and a modal dialog, all on this thread.
    unsafe {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_STANDARD_CLASSES,
        };
        let _ = InitCommonControlsEx(&controls);
        register_dialog_class(CLASS)?;
        let result = DialogBoxParamW(
            Some(instance()),
            PCWSTR(IDD_LOOKUP as usize as *const u16),
            None,
            Some(lookup_proc),
            LPARAM(0),
        );
        if result == -1 {
            return Err(windows::core::Error::from_thread());
        }
    }
    Ok(())
}

/// Shown when the dialog cannot come up at all.
pub fn report_startup_failure(message: &str) {
    prompt::tell_as(
        TITLE,
        HWND::default(),
        prompt::Icon::Error,
        "无法打开编码反查",
        message,
    );
}

fn word_field(hwnd: HWND) -> HWND {
    // SAFETY: a lookup among this dialog's own controls.
    unsafe { GetDlgItem(Some(hwnd), IDC_LOOKUP_WORD).unwrap_or_default() }
}

/// 查询 only once the field holds a query.
fn update_button(hwnd: HWND) {
    let ready = !report::query(&window_text(word_field(hwnd))).is_empty();
    // SAFETY: a plain window call.
    unsafe {
        let _ = EnableWindow(GetDlgItem(Some(hwnd), IDOK.0).unwrap_or_default(), ready);
    }
}

/// 查询: the codes of the word in the field, in a task dialog over this one.
fn look_up(hwnd: HWND) {
    let word = word_field(hwnd);
    let text = window_text(word);
    let query = report::query(&text);
    if query.is_empty() {
        return;
    }
    let enabled = switch::is_enabled();
    let user_only = enabled && switch::is_user_only();
    let base = jd_userdict::base(user_only);
    let report = if !enabled {
        Report::new(query, &report::codes(query, None, None), Scope::BuiltIn)
    } else {
        match user_dict(base) {
            Ok(dict) => {
                let scope = if user_only { Scope::UserOnly } else { Scope::BuiltInAndUser };
                Report::new(query, &report::codes(query, Some(&dict), base), scope)
            }
            // The phrases alone, and there are none to be had: never the
            // built-in dictionary instead.
            Err(error) if user_only => {
                Report::unavailable(query, &format!("用户自造词未能加载：{}", error.message()))
            }
            Err(_) => Report::new(query, &report::codes(query, None, None), Scope::BuiltInAndUser),
        }
    };
    prompt::tell_as(
        TITLE,
        hwnd,
        prompt::Icon::Information,
        &report.title,
        &report.body,
    );
    // Back to the word, selected, so the next one replaces it.
    // SAFETY: the message names this dialog's own control.
    unsafe {
        SendMessageW(
            hwnd,
            WM_NEXTDLGCTL,
            Some(WPARAM(word.0 as usize)),
            Some(LPARAM(1)),
        );
    }
}

/// The user's phrases on `base`, as the IME loads them: mapped from the
/// shared cache when it holds the file's text, built from the file
/// otherwise. `Err` when there is no file, or none that builds: the
/// 用户自造词 window says why too, and the IME types with the last one that
/// did, which this process never had.
fn user_dict(base: Option<&Dict>) -> std::result::Result<UserDict, LoadError> {
    let path = file::path().ok_or(LoadError::Missing)?;
    Ok(cache::load(&path, cache::dir().as_deref(), base)?.dict)
}

unsafe extern "system" fn lookup_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    _lparam: LPARAM,
) -> isize {
    unsafe {
        match msg {
            WM_INITDIALOG => {
                let word = word_field(hwnd);
                let cue = HSTRING::from("例如：键道");
                SendMessageW(
                    word,
                    EM_SETCUEBANNER,
                    Some(WPARAM(1)),
                    Some(LPARAM(cue.as_ptr() as isize)),
                );
                update_button(hwnd);
                let _ = SetFocus(Some(word));
                // Focus is set.
                0
            }
            WM_COMMAND => {
                let id = (wparam.0 & 0xFFFF) as i32;
                let code = ((wparam.0 >> 16) & 0xFFFF) as u32;
                match id {
                    IDC_LOOKUP_WORD if code == EN_CHANGE => update_button(hwnd),
                    id if id == IDOK.0 => look_up(hwnd),
                    id if id == IDCANCEL.0 => {
                        let _ = EndDialog(hwnd, 0);
                    }
                    _ => return 0,
                }
                1
            }
            _ => 0,
        }
    }
}
