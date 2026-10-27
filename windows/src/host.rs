//! What kind of process the IME has been loaded into, where that changes
//! what the IME may do there.

use std::ffi::c_void;
use std::sync::OnceLock;

use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TokenIsAppContainer};
use windows::Win32::System::SystemInformation::IMAGE_FILE_MACHINE;
use windows::Win32::System::Threading::{GetCurrentProcess, IsWow64Process2, OpenProcessToken};

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

/// The machine's own architecture, an `IMAGE_FILE_MACHINE_*` value — not
/// always this process's: on a 64-bit Windows, a 32-bit application runs the
/// IME's 32-bit DLL. `None` if Windows does not say.
pub fn native_machine() -> Option<u16> {
    let mut process = IMAGE_FILE_MACHINE::default();
    let mut native = IMAGE_FILE_MACHINE::default();
    // SAFETY: a query on this process, into two locals.
    unsafe { IsWow64Process2(GetCurrentProcess(), &mut process, Some(&mut native)) }.ok()?;
    Some(native.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knows_the_machine_whatever_this_process_is() {
        // IMAGE_FILE_MACHINE_AMD64 or _ARM64, for a 32-bit (i686) test build
        // as for a 64-bit one.
        assert!(matches!(native_machine(), Some(0x8664 | 0xAA64)));
    }
}
