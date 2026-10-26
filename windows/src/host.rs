//! What kind of process the IME has been loaded into, where that changes
//! what the IME may do there.

use std::ffi::c_void;
use std::sync::OnceLock;

use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TokenIsAppContainer};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

/// Whether this host runs in an AppContainer — a Store app, the Start menu's
/// search box: a sandbox in which the IME can neither reach the network nor
/// write the user's registry, and in which anything it starts stays. A
/// process's token never changes, so this is asked once.
pub fn is_app_container() -> bool {
    static APP_CONTAINER: OnceLock<bool> = OnceLock::new();
    *APP_CONTAINER.get_or_init(|| {
        // SAFETY: plain token calls on this process; the handle is closed.
        unsafe {
            let mut token = HANDLE::default();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).is_err() {
                return false;
            }
            let mut flag: u32 = 0;
            let mut len: u32 = 0;
            let ok = GetTokenInformation(
                token,
                TokenIsAppContainer,
                Some(&mut flag as *mut u32 as *mut c_void),
                size_of::<u32>() as u32,
                &mut len,
            )
            .is_ok();
            let _ = CloseHandle(token);
            ok && flag != 0
        }
    })
}
