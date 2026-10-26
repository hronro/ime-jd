//! Watching what others change under the open window: the phrases folder,
//! so an edit made elsewhere — a text editor, another copy of the file
//! dropped in — shows up here, and the switches' registry key, which the
//! menu of the IME's mode icon sets from another process. A thread waits on
//! a change notification for each and posts the window a message per
//! change; the window debounces the folder's, since one save is several
//! events. The window's own saves come back this way too, and read back as
//! what it wrote.

use std::path::Path;
use std::thread::JoinHandle;

use windows::Win32::Foundation::{
    CloseHandle, HANDLE, HWND, LPARAM, WAIT_EVENT, WAIT_OBJECT_0, WPARAM,
};
use windows::Win32::Storage::FileSystem::{
    FILE_NOTIFY_CHANGE_FILE_NAME, FILE_NOTIFY_CHANGE_LAST_WRITE, FILE_NOTIFY_CHANGE_SIZE,
    FindCloseChangeNotification, FindFirstChangeNotificationW, FindNextChangeNotification,
};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_NOTIFY, REG_NOTIFY_CHANGE_LAST_SET, RegCloseKey,
    RegNotifyChangeKeyValue, RegOpenKeyExW,
};
use windows::Win32::System::Threading::{CreateEventW, INFINITE, SetEvent, WaitForMultipleObjects};
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;
use windows::core::{HSTRING, PCWSTR};

use jd_userdict::switch;

/// Stops and joins the thread when dropped.
pub struct Watcher {
    stop: HANDLE,
    thread: Option<JoinHandle<()>>,
}

impl Watcher {
    /// Post `file_message` to `window` whenever something in `dir` is
    /// created, renamed, written or resized, and `switch_message` whenever a
    /// switch is set. `None` when the folder cannot be watched.
    pub fn start(dir: &Path, window: HWND, file_message: u32, switch_message: u32) -> Option<Self> {
        // SAFETY: plain kernel-object calls; every handle is closed by the
        // thread or by `drop`.
        unsafe {
            let change = FindFirstChangeNotificationW(
                &HSTRING::from(dir.as_os_str()),
                false,
                FILE_NOTIFY_CHANGE_FILE_NAME
                    | FILE_NOTIFY_CHANGE_LAST_WRITE
                    | FILE_NOTIFY_CHANGE_SIZE,
            )
            .ok()?;
            let Ok(stop) = CreateEventW(None, true, false, PCWSTR::null()) else {
                let _ = FindCloseChangeNotification(change);
                return None;
            };
            let Ok(set) = CreateEventW(None, false, false, PCWSTR::null()) else {
                let _ = FindCloseChangeNotification(change);
                let _ = CloseHandle(stop);
                return None;
            };
            // Handles are pointers to the type system; to the thread they
            // are just numbers it owns.
            let (change_raw, stop_raw, set_raw, window_raw) = (
                change.0 as usize,
                stop.0 as usize,
                set.0 as usize,
                window.0 as usize,
            );
            let thread = std::thread::Builder::new()
                .name("jd-userdict-watch".into())
                .spawn(move || {
                    let change = HANDLE(change_raw as *mut _);
                    let stop = HANDLE(stop_raw as *mut _);
                    let set = HANDLE(set_raw as *mut _);
                    let window = HWND(window_raw as *mut _);
                    // A notification lasts until it fires and belongs to the
                    // thread that asked, so this thread asks, and again
                    // after each one.
                    let mut key = HKEY::default();
                    let watching_key = RegOpenKeyExW(
                        HKEY_CURRENT_USER,
                        &HSTRING::from(switch::KEY),
                        None,
                        KEY_NOTIFY,
                        &mut key,
                    )
                    .is_ok();
                    let arm = || {
                        watching_key
                            && RegNotifyChangeKeyValue(
                                key,
                                false,
                                REG_NOTIFY_CHANGE_LAST_SET,
                                Some(set),
                                true,
                            )
                            .is_ok()
                    };
                    arm();
                    loop {
                        let signalled =
                            WaitForMultipleObjects(&[change, set, stop], false, INFINITE);
                        if signalled == WAIT_OBJECT_0 {
                            let _ = PostMessageW(Some(window), file_message, WPARAM(0), LPARAM(0));
                            if FindNextChangeNotification(change).is_err() {
                                break;
                            }
                        } else if signalled == WAIT_EVENT(WAIT_OBJECT_0.0 + 1) {
                            let _ =
                                PostMessageW(Some(window), switch_message, WPARAM(0), LPARAM(0));
                            arm();
                        } else {
                            break;
                        }
                    }
                    if watching_key {
                        let _ = RegCloseKey(key);
                    }
                    let _ = FindCloseChangeNotification(change);
                    let _ = CloseHandle(set);
                });
            match thread {
                Ok(thread) => Some(Self {
                    stop,
                    thread: Some(thread),
                }),
                Err(_) => {
                    let _ = FindCloseChangeNotification(change);
                    let _ = CloseHandle(stop);
                    let _ = CloseHandle(set);
                    None
                }
            }
        }
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        // SAFETY: the event outlives the thread, which is joined first.
        unsafe {
            let _ = SetEvent(self.stop);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
            let _ = CloseHandle(self.stop);
        }
    }
}
