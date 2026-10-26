//! The user's two switches, DWORDs under `HKCU\Software\hronro\ime-jd` — the
//! key the IME's update check keeps its state in (windows/src/update):
//!
//! - `UserDictEnabled`, the user dictionary: off — absent, or 0 — until the
//!   user turns it on, in the window or in the mode icon's menu. Off means
//!   every engine reads the built-in dictionary alone, whatever the file
//!   holds; the file is kept either way.
//! - `CheckForUpdates`, the IME's daily update check: on — absent, or
//!   anything but 0 — until the user turns it off in the menu.
//!
//! The IME reads both in every host process; only this package's binary
//! writes them, since a write from a packaged host lands in a private copy
//! of the key that no other application sees (windows/src/settings.rs).

use std::ffi::c_void;

use windows::Win32::Foundation::WIN32_ERROR;
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE, REG_DWORD, REG_OPTION_NON_VOLATILE, RRF_RT_REG_DWORD,
    RegCloseKey, RegCreateKeyExW, RegGetValueW, RegSetValueExW,
};
use windows::core::{HSTRING, PCWSTR, Result, w};

/// The key, under `HKEY_CURRENT_USER`.
pub const KEY: &str = r"Software\hronro\ime-jd";
const USER_DICT: PCWSTR = w!("UserDictEnabled");
const CHECK_FOR_UPDATES: PCWSTR = w!("CheckForUpdates");

/// Whether the user turned the dictionary on. A registry read, cheap enough
/// for the IME to take before every composition; a key it cannot read (a
/// sandboxed host the window has not granted access) reads as off.
pub fn is_enabled() -> bool {
    read(KEY, USER_DICT).is_some_and(|value| value != 0)
}

/// Turn the dictionary on or off for every engine created from now on.
pub fn set_enabled(on: bool) -> Result<()> {
    write(KEY, USER_DICT, on)
}

/// Whether the IME may check for a new release, once a day.
pub fn checks_for_updates() -> bool {
    read(KEY, CHECK_FOR_UPDATES).is_none_or(|value| value != 0)
}

pub fn set_checks_for_updates(on: bool) -> Result<()> {
    write(KEY, CHECK_FOR_UPDATES, on)
}

/// Make sure the key exists, so access can be granted on it before the
/// switch is first set.
pub fn create_key() -> Result<()> {
    let key = HSTRING::from(KEY);
    let mut hkey = HKEY::default();
    // SAFETY: plain registry calls; the key is closed again.
    unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            &key,
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            None,
            &mut hkey,
            None,
        )
        .ok()?;
        let _ = RegCloseKey(hkey);
    }
    Ok(())
}

/// A DWORD under `key`, or `None` when it cannot be read.
fn read(key: &str, value: PCWSTR) -> Option<u32> {
    let key = HSTRING::from(key);
    let mut data: u32 = 0;
    let mut size = size_of::<u32>() as u32;
    // SAFETY: a DWORD-sized buffer for a value restricted to REG_DWORD.
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            &key,
            value,
            RRF_RT_REG_DWORD,
            None,
            Some(&mut data as *mut u32 as *mut c_void),
            Some(&mut size),
        )
    };
    status.is_ok().then_some(data)
}

fn write(key: &str, value: PCWSTR, on: bool) -> Result<()> {
    let key = HSTRING::from(key);
    let mut hkey = HKEY::default();
    // SAFETY: plain registry calls; the key is closed on every path.
    unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            &key,
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            None,
            &mut hkey,
            None,
        )
        .ok()?;
        let data = u32::from(on).to_le_bytes();
        let set: WIN32_ERROR = RegSetValueExW(hkey, value, None, REG_DWORD, Some(&data));
        let _ = RegCloseKey(hkey);
        set.ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::System::Registry::RegDeleteTreeW;

    #[test]
    fn each_switch_reads_its_default_until_set() {
        // A scratch key of our own, so the user's switches are never touched.
        let key = format!(r"{KEY}-test-{}", std::process::id());
        let on = |value| read(&key, value).is_some_and(|v| v != 0);
        let updates = |value| read(&key, value).is_none_or(|v| v != 0);

        // Absent: the dictionary is off, the update check on.
        assert!(!on(USER_DICT));
        assert!(updates(CHECK_FOR_UPDATES));

        write(&key, USER_DICT, true).unwrap();
        assert!(on(USER_DICT));
        write(&key, CHECK_FOR_UPDATES, false).unwrap();
        assert!(!updates(CHECK_FOR_UPDATES));
        assert!(on(USER_DICT), "the switches are independent");
        write(&key, USER_DICT, false).unwrap();
        assert!(!on(USER_DICT));
        write(&key, CHECK_FOR_UPDATES, true).unwrap();
        assert!(updates(CHECK_FOR_UPDATES));

        unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, &HSTRING::from(key)) }
            .ok()
            .unwrap();
    }
}
