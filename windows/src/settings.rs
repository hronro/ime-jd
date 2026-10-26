//! The IME's settings, as the menu of its mode icon (mode_icon.rs) shows and
//! changes them: the user dictionary — its window and its switch — and the
//! daily update check (jd_userdict::switch keeps both switches).
//!
//! The menu runs in whichever application is in front, and the IME reads the
//! switches there but writes them nowhere: a packaged application (the new
//! Notepad, Terminal) has its registry writes redirected into a private copy
//! of the key that no other application reads. Every item starts
//! `ime_jd_userdict.exe`, beside this DLL, instead — the window, or its
//! command line that sets one switch — and what a packaged application
//! starts runs outside the package, as an ordinary process of the user's.
//!
//! A sandboxed (AppContainer) host is the exception: what it starts stays in
//! its sandbox, which may write nothing, and an IME must not try to get
//! around that — Microsoft's IME requirements treat one that does as
//! malware. There the items are unavailable; the user changes the settings
//! from a desktop application, or in the window from the Start menu.

use std::os::windows::ffi::OsStrExt;
use std::path::PathBuf;

use jd_userdict::switch;
use windows::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::{ASFW_ANY, AllowSetForegroundWindow, SW_SHOWNORMAL};
use windows::core::{HSTRING, PCWSTR, w};

use crate::{dll_hmodule, host};

/// The user dictionary's window, which also sets the switches; installed
/// beside this DLL.
const HELPER_EXE: &str = "ime_jd_userdict.exe";

pub struct Settings {
    /// Whether the user dictionary is on.
    pub user_dict: bool,
    /// Whether the IME checks for a new release once a day.
    pub update_checks: bool,
    /// Whether they can be changed from this host.
    pub changeable: bool,
}

/// The settings as they stand, read afresh: another process sets them.
pub fn current() -> Settings {
    Settings {
        user_dict: switch::is_enabled(),
        update_checks: switch::checks_for_updates(),
        changeable: !host::is_app_container() && helper().is_some(),
    }
}

pub fn open_user_dict_window() {
    start_helper("");
}

pub fn set_user_dict(on: bool) {
    start_helper(&format!("--user-dict {}", on_off(on)));
}

pub fn set_update_checks(on: bool) {
    start_helper(&format!("--check-updates {}", on_off(on)));
}

/// A switch's state as the helper's command line spells it.
fn on_off(on: bool) -> &'static str {
    if on { "on" } else { "off" }
}

fn start_helper(args: &str) {
    let Some(exe) = helper() else {
        return;
    };
    let exe: Vec<u16> = exe.as_os_str().encode_wide().chain([0]).collect();
    // SAFETY: NUL-terminated strings that outlive the calls.
    unsafe {
        // The user just picked a menu item, so this process may bring a
        // window forward, and lets the one it starts do so: the window, or
        // an open one that the second start activates.
        let _ = AllowSetForegroundWindow(ASFW_ANY);
        ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(exe.as_ptr()),
            &HSTRING::from(args),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        );
    }
}

/// `ime_jd_userdict.exe`, when it is there beside this DLL.
fn helper() -> Option<PathBuf> {
    let mut buf = vec![0u16; 260];
    loop {
        // SAFETY: the buffer's length is passed along with it.
        let len = unsafe { GetModuleFileNameW(Some(dll_hmodule()), &mut buf) } as usize;
        if len == 0 {
            return None;
        }
        if len < buf.len() {
            let dll = PathBuf::from(String::from_utf16_lossy(&buf[..len]));
            return Some(dll.parent()?.join(HELPER_EXE)).filter(|exe| exe.is_file());
        }
        buf.resize(buf.len() * 2, 0);
    }
}
