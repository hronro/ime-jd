//! Watching the phrases folder, so an edit made elsewhere — a text editor,
//! another copy of the file dropped in — shows up in the open window. A
//! thread waits on a change notification for the folder and posts a message
//! to the window per burst of changes; the window debounces them, since one
//! save is several events. The window's own saves come back this way too,
//! and read back as what it wrote.

use std::path::Path;
use std::thread::JoinHandle;

use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM, WAIT_OBJECT_0, WPARAM};
use windows::Win32::Storage::FileSystem::{
    FILE_NOTIFY_CHANGE_FILE_NAME, FILE_NOTIFY_CHANGE_LAST_WRITE, FILE_NOTIFY_CHANGE_SIZE,
    FindCloseChangeNotification, FindFirstChangeNotificationW, FindNextChangeNotification,
};
use windows::Win32::System::Threading::{CreateEventW, INFINITE, SetEvent, WaitForMultipleObjects};
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;
use windows::core::{HSTRING, PCWSTR};

/// Stops and joins the thread when dropped.
pub struct Watcher {
    stop: HANDLE,
    thread: Option<JoinHandle<()>>,
}

impl Watcher {
    /// Post `message` to `window` whenever something in `dir` is created,
    /// renamed, written or resized. `None` when the folder cannot be
    /// watched.
    pub fn start(dir: &Path, window: HWND, message: u32) -> Option<Self> {
        // SAFETY: plain kernel-object calls; both handles are closed by the
        // thread or by `drop`.
        unsafe {
            let change = FindFirstChangeNotificationW(
                &HSTRING::from(dir.as_os_str()),
                false,
                FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE,
            )
            .ok()?;
            let Ok(stop) = CreateEventW(None, true, false, PCWSTR::null()) else {
                let _ = FindCloseChangeNotification(change);
                return None;
            };
            // Handles are pointers to the type system; to the thread they
            // are just numbers it owns.
            let (change_raw, stop_raw, window_raw) =
                (change.0 as usize, stop.0 as usize, window.0 as usize);
            let thread = std::thread::Builder::new()
                .name("jd-userdict-watch".into())
                .spawn(move || {
                    let change = HANDLE(change_raw as *mut _);
                    let stop = HANDLE(stop_raw as *mut _);
                    let window = HWND(window_raw as *mut _);
                    while WaitForMultipleObjects(&[change, stop], false, INFINITE) == WAIT_OBJECT_0 {
                        let _ = PostMessageW(Some(window), message, WPARAM(0), LPARAM(0));
                        if FindNextChangeNotification(change).is_err() {
                            break;
                        }
                    }
                    let _ = FindCloseChangeNotification(change);
                });
            match thread {
                Ok(thread) => Some(Self {
                    stop,
                    thread: Some(thread),
                }),
                Err(_) => {
                    let _ = FindCloseChangeNotification(change);
                    let _ = CloseHandle(stop);
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
