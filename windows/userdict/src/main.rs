#![windows_subsystem = "windows"]
//! 键道用户自造词 (`ime_jd_userdict.exe`), installed beside the IME's DLL:
//! the window that edits the user dictionary. It is started from the Start
//! menu or from the menu of the IME's mode icon in the taskbar, and a second
//! start brings the open window forward.
//!
//! That menu changes the IME's switches through it too: `--user-dict on|off`
//! and `--check-updates on|off` set one and exit, so the change is made by a
//! desktop process of the user's own, whichever application the menu was
//! opened from (windows/src/settings.rs).
//!
//! `--file <path>` edits that file instead of the user's own, to try the
//! window out — screenshots, QA — without touching the real phrases: such a
//! window grants nothing, remembers no placement and stands beside one
//! already open. The switch is the user's either way.

mod window;

use std::ffi::{OsStr, OsString};
use std::path::PathBuf;

use jd_userdict::{access, switch};
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE, CoInitializeEx};

fn main() {
    // COM for the shell, on this, the UI thread.
    // SAFETY: once, before any window exists.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    }

    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let trial = match args.as_slice() {
        [flag, path] if flag == "--file" => Some(PathBuf::from(path)),
        [flag, state] if flag == "--user-dict" || flag == "--check-updates" => {
            set_switch(flag, state);
            return;
        }
        _ => None,
    };
    let path = match &trial {
        Some(path) => path.clone(),
        None => {
            if window::activate_existing() {
                return;
            }
            let Some(path) = jd_userdict::file::path() else {
                window::report_startup_failure("找不到当前用户的 AppData 文件夹。");
                return;
            };
            // So sandboxed hosts can read what this window writes. A failure
            // costs them the dictionary and nothing else.
            let _ = access::grant_all();
            path
        }
    };
    if let Err(error) = window::run(path, trial.is_none()) {
        window::report_startup_failure(&error.message());
    }
}

/// Set one switch, as the mode icon's menu asks: `flag` names it, `state` is
/// `on` or `off`.
fn set_switch(flag: &OsStr, state: &OsStr) {
    let on = match state.to_str() {
        Some("on") => true,
        Some("off") => false,
        _ => return,
    };
    let result = if flag == "--user-dict" {
        if on {
            // The phrases this turns on, readable in sandboxed hosts too.
            let _ = access::grant_all();
        }
        switch::set_enabled(on)
    } else {
        switch::set_checks_for_updates(on)
    };
    if let Err(error) = result {
        window::report_setting_failure(&error.message());
    }
}
