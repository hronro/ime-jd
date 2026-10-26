#![windows_subsystem = "windows"]
//! 键道用户自造词 (`ime_jd_userdict.exe`), installed beside the IME's DLL:
//! the window that edits the user dictionary. It is started from the Start
//! menu, and a second start brings the open window forward.
//!
//! `--file <path>` edits that file instead of the user's own, to try the
//! window out — screenshots, QA — without touching the real phrases: such a
//! window grants nothing, remembers no placement and stands beside one
//! already open. The switch is the user's either way.

mod window;

use std::path::PathBuf;

use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE, CoInitializeEx};

fn main() {
    // COM for the shell, on this, the UI thread.
    // SAFETY: once, before any window exists.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    }

    let mut args = std::env::args_os().skip(1);
    let trial = match (args.next(), args.next()) {
        (Some(flag), Some(path)) if flag == "--file" => Some(PathBuf::from(path)),
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
            let _ = jd_userdict::access::grant_all();
            path
        }
    };
    if let Err(error) = window::run(path, trial.is_none()) {
        window::report_startup_failure(&error.message());
    }
}
