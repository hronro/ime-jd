//! The user's switch: `UserDictEnabled` (DWORD) under
//! `HKCU\Software\hronro\ime-jd`, the key the IME's update check keeps its
//! state in (windows/src/update). Off — absent, or 0 — until the user turns
//! it on in the window. Off means every engine reads the built-in
//! dictionary alone, whatever the file holds; the file is kept either way.

use std::ffi::c_void;

use windows::Win32::Foundation::WIN32_ERROR;
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE, REG_DWORD, REG_OPTION_NON_VOLATILE, RRF_RT_REG_DWORD,
    RegCloseKey, RegCreateKeyExW, RegGetValueW, RegSetValueExW,
};
use windows::core::{HSTRING, PCWSTR, Result, w};

/// The key, under `HKEY_CURRENT_USER`.
pub const KEY: &str = r"Software\hronro\ime-jd";
const VALUE: PCWSTR = w!("UserDictEnabled");

/// Whether the user turned the dictionary on. A registry read, cheap enough
/// for the IME to take before every composition; a key it cannot read (a
/// sandboxed host the window has not granted access) reads as off.
pub fn is_enabled() -> bool {
    is_enabled_at(KEY)
}

/// Turn the dictionary on or off for every engine created from now on.
pub fn set_enabled(on: bool) -> Result<()> {
    set_enabled_at(KEY, on)
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

pub(crate) fn is_enabled_at(key: &str) -> bool {
    let key = HSTRING::from(key);
    let mut data: u32 = 0;
    let mut size = size_of::<u32>() as u32;
    // SAFETY: a DWORD-sized buffer for a value restricted to REG_DWORD.
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            &key,
            VALUE,
            RRF_RT_REG_DWORD,
            None,
            Some(&mut data as *mut u32 as *mut c_void),
            Some(&mut size),
        )
    };
    status.is_ok() && data != 0
}

pub(crate) fn set_enabled_at(key: &str, on: bool) -> Result<()> {
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
        let set: WIN32_ERROR = RegSetValueExW(hkey, VALUE, None, REG_DWORD, Some(&data));
        let _ = RegCloseKey(hkey);
        set.ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::System::Registry::RegDeleteTreeW;

    #[test]
    fn the_switch_is_off_until_turned_on() {
        // A scratch key of our own, so the user's switch is never touched.
        let key = format!(r"{KEY}-test-{}", std::process::id());
        assert!(!is_enabled_at(&key), "an absent key reads as off");
        set_enabled_at(&key, true).unwrap();
        assert!(is_enabled_at(&key));
        set_enabled_at(&key, false).unwrap();
        assert!(!is_enabled_at(&key));
        unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, &HSTRING::from(key)) }
            .ok()
            .unwrap();
    }
}
