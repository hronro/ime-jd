//! What kind of process the IME has been loaded into, where that changes
//! what the IME may do there.

use std::ffi::c_void;
use std::sync::OnceLock;

use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Security::{
    GetTokenInformation, IsWellKnownSid, TOKEN_QUERY, TOKEN_USER, TokenIsAppContainer, TokenUser,
    WinLocalSystemSid,
};
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

/// Whether this host runs as SYSTEM, as the programs of the secure desktop
/// do — the sign-in screen (LogonUI), a UAC prompt (consent): whoever types
/// there has not signed in, and anything the IME started would run with the
/// system's rights, so it starts nothing there (tip.rs). A process's token
/// never changes, so this is asked once.
pub fn is_system() -> bool {
    static SYSTEM: OnceLock<bool> = OnceLock::new();
    *SYSTEM.get_or_init(|| {
        // SAFETY: plain token calls on this process; the handle is closed.
        // The buffer is aligned for a TOKEN_USER and holds the largest SID.
        unsafe {
            let mut token = HANDLE::default();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).is_err() {
                return false;
            }
            let mut user = [0u64; 16];
            let mut len: u32 = 0;
            let ok = GetTokenInformation(
                token,
                TokenUser,
                Some(user.as_mut_ptr() as *mut c_void),
                size_of_val(&user) as u32,
                &mut len,
            )
            .is_ok();
            let _ = CloseHandle(token);
            ok && IsWellKnownSid(
                (*(user.as_ptr() as *const TOKEN_USER)).User.Sid,
                WinLocalSystemSid,
            )
            .as_bool()
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

    #[test]
    fn a_users_process_is_not_the_systems() {
        // The tests run as whoever started them, in CI too.
        assert!(!is_system());
    }
}
