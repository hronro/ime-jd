//! Read access for sandboxed hosts. An AppContainer process — a Store app,
//! the Start menu's search box — opens a file or a registry key only where an
//! ACE grants its package, or a group of packages, access. The user's AppData
//! folder and the keys under `HKCU\Software` grant none, so the IME in such a
//! host would see neither the phrases nor the switch. The window grants the
//! two package groups register.bat grants on the install folder — ALL
//! APPLICATION PACKAGES (S-1-15-2-1) and ALL RESTRICTED APPLICATION PACKAGES
//! (S-1-15-2-2) — read access to the phrases folder, inherited by the file
//! and by every file a save puts there, and to the switch's registry key.
//!
//! The price is that any sandboxed app can read the phrases, as any desktop
//! app already can. The window grants this on every launch, so a folder or
//! key created some other way is covered too.

use std::ffi::c_void;
use std::path::Path;
use std::ptr;

use windows::Win32::Foundation::{HLOCAL, LocalFree, WIN32_ERROR};
use windows::Win32::Security::Authorization::{
    ConvertStringSidToSidW, EXPLICIT_ACCESS_W, GRANT_ACCESS, GetNamedSecurityInfoW,
    NO_MULTIPLE_TRUSTEE, SE_FILE_OBJECT, SE_OBJECT_TYPE, SE_REGISTRY_KEY, SetEntriesInAclW,
    SetNamedSecurityInfoW, TRUSTEE_IS_SID, TRUSTEE_IS_WELL_KNOWN_GROUP, TRUSTEE_W,
};
use windows::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACE_FLAGS, ACE_HEADER, ACL, ACL_SIZE_INFORMATION, AclSizeInformation,
    DACL_SECURITY_INFORMATION, EqualSid, GetAce, GetAclInformation, NO_INHERITANCE, PSECURITY_DESCRIPTOR,
    PSID, SUB_CONTAINERS_AND_OBJECTS_INHERIT,
};
use windows::Win32::Storage::FileSystem::{FILE_GENERIC_EXECUTE, FILE_GENERIC_READ};
use windows::Win32::System::Registry::KEY_READ;
use windows::core::{HSTRING, PCWSTR, PWSTR, Result, w};

/// ALL APPLICATION PACKAGES and ALL RESTRICTED APPLICATION PACKAGES.
const PACKAGE_GROUPS: [PCWSTR; 2] = [w!("S-1-15-2-1"), w!("S-1-15-2-2")];

/// `ACCESS_ALLOWED_ACE_TYPE` (winnt.h).
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;

/// Everything the IME reads, readable by sandboxed hosts: the phrases
/// folder and the switch's key, each created first if need be.
pub fn grant_all() -> std::io::Result<()> {
    let dir = crate::file::dir().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::NotFound, "no roaming AppData folder")
    })?;
    std::fs::create_dir_all(&dir)?;
    grant_folder(&dir)?;
    crate::switch::create_key()?;
    grant_key(crate::switch::KEY)?;
    Ok(())
}

/// Let sandboxed hosts read `dir` and everything in it: read and execute
/// (traverse), inherited by files and subfolders — what `icacls … /grant
/// *S-1-15-2-1:(OI)(CI)(RX)` grants. Existing children pick it up too.
pub fn grant_folder(dir: &Path) -> Result<()> {
    grant(
        &HSTRING::from(dir.as_os_str()),
        SE_FILE_OBJECT,
        (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE).0,
        SUB_CONTAINERS_AND_OBJECTS_INHERIT,
    )
}

/// Let sandboxed hosts read `subkey` of `HKEY_CURRENT_USER`.
pub fn grant_key(subkey: &str) -> Result<()> {
    grant(
        &HSTRING::from(format!(r"CURRENT_USER\{subkey}")),
        SE_REGISTRY_KEY,
        KEY_READ.0,
        NO_INHERITANCE,
    )
}

/// Whether `dir` grants both package groups what [`grant_folder`] does.
pub fn folder_is_granted(dir: &Path) -> Result<bool> {
    is_granted(
        &HSTRING::from(dir.as_os_str()),
        SE_FILE_OBJECT,
        (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE).0,
        SUB_CONTAINERS_AND_OBJECTS_INHERIT,
    )
}

/// Frees a `LocalAlloc`'d pointer the security APIs hand back.
struct Local(*mut c_void);

impl Drop for Local {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: allocated by the API that returned it, freed once.
            unsafe { LocalFree(Some(HLOCAL(self.0))) };
        }
    }
}

fn package_group_sids() -> Result<Vec<Local>> {
    PACKAGE_GROUPS
        .iter()
        .map(|&text| {
            let mut sid = PSID::default();
            // SAFETY: a NUL-terminated SID string; the SID is LocalFree'd.
            unsafe { ConvertStringSidToSidW(text, &mut sid) }?;
            Ok(Local(sid.0))
        })
        .collect()
}

/// The object's DACL, with the security descriptor that owns it.
fn dacl(name: &HSTRING, kind: SE_OBJECT_TYPE) -> Result<(*mut ACL, Local)> {
    let mut dacl: *mut ACL = ptr::null_mut();
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    // SAFETY: out-pointers to locals; the descriptor is LocalFree'd, and
    // `dacl` points into it.
    unsafe {
        GetNamedSecurityInfoW(
            name,
            kind,
            DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(&mut dacl),
            None,
            &mut descriptor,
        )
    }
    .ok()?;
    Ok((dacl, Local(descriptor.0)))
}

fn is_granted(name: &HSTRING, kind: SE_OBJECT_TYPE, mask: u32, inherit: ACE_FLAGS) -> Result<bool> {
    let (dacl, _descriptor) = dacl(name, kind)?;
    let sids = package_group_sids()?;
    // SAFETY: `dacl` lives as long as `_descriptor`.
    Ok(sids.iter().all(|sid| unsafe { grants(dacl, PSID(sid.0), mask, inherit) }))
}

fn grant(name: &HSTRING, kind: SE_OBJECT_TYPE, mask: u32, inherit: ACE_FLAGS) -> Result<()> {
    let (dacl, _descriptor) = dacl(name, kind)?;
    let sids = package_group_sids()?;
    // SAFETY: `dacl` lives as long as `_descriptor`.
    let missing: Vec<&Local> = sids
        .iter()
        .filter(|sid| !unsafe { grants(dacl, PSID(sid.0), mask, inherit) })
        .collect();
    if missing.is_empty() {
        return Ok(());
    }
    let entries: Vec<EXPLICIT_ACCESS_W> = missing
        .iter()
        .map(|sid| EXPLICIT_ACCESS_W {
            grfAccessPermissions: mask,
            grfAccessMode: GRANT_ACCESS,
            grfInheritance: inherit,
            Trustee: TRUSTEE_W {
                pMultipleTrustee: ptr::null_mut(),
                MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_WELL_KNOWN_GROUP,
                ptstrName: PWSTR(sid.0 as *mut u16),
            },
        })
        .collect();
    let mut updated: *mut ACL = ptr::null_mut();
    // SAFETY: the entries point at SIDs alive for the call; the new ACL is
    // LocalFree'd after it has been written.
    unsafe {
        SetEntriesInAclW(Some(&entries), Some(dacl), &mut updated).ok()?;
        let _updated = Local(updated as *mut c_void);
        let status: WIN32_ERROR = SetNamedSecurityInfoW(
            name,
            kind,
            DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(updated),
            None,
        );
        status.ok()
    }
}

/// Whether an allow ACE for `sid` in `acl` grants at least `mask`, with at
/// least the `inherit` flags.
///
/// # Safety
/// `acl` is null (a NULL DACL, which grants everyone everything) or a valid
/// ACL, and `sid` a valid SID.
unsafe fn grants(acl: *const ACL, sid: PSID, mask: u32, inherit: ACE_FLAGS) -> bool {
    if acl.is_null() {
        return true;
    }
    let mut info = ACL_SIZE_INFORMATION::default();
    unsafe {
        if GetAclInformation(
            acl,
            &mut info as *mut _ as *mut c_void,
            size_of::<ACL_SIZE_INFORMATION>() as u32,
            AclSizeInformation,
        )
        .is_err()
        {
            return false;
        }
        (0..info.AceCount).any(|index| {
            let mut ace: *mut c_void = ptr::null_mut();
            if GetAce(acl, index, &mut ace).is_err() {
                return false;
            }
            let header = &*(ace as *const ACE_HEADER);
            if header.AceType != ACCESS_ALLOWED_ACE_TYPE {
                return false;
            }
            let allowed = &*(ace as *const ACCESS_ALLOWED_ACE);
            let flags = u32::from(header.AceFlags);
            allowed.Mask & mask == mask
                && flags & inherit.0 == inherit.0
                && EqualSid(PSID(&allowed.SidStart as *const u32 as *mut c_void), sid).is_ok()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn a_granted_folder_passes_read_access_to_its_files() {
        let dir = std::env::temp_dir().join(format!("jd-userdict-access-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let before = dir.join("before.txt");
        fs::write(&before, "前").unwrap();

        assert!(!folder_is_granted(&dir).unwrap(), "temp folders grant no packages");
        grant_folder(&dir).unwrap();
        assert!(folder_is_granted(&dir).unwrap());
        // Idempotent: a second grant changes nothing.
        grant_folder(&dir).unwrap();
        assert!(folder_is_granted(&dir).unwrap());

        // A file written afterwards — a save — inherits it, and so does the
        // one that was already there.
        let after = dir.join("after.txt");
        crate::file::write(&after, "后").unwrap();
        for file in [&before, &after] {
            let (dacl, _descriptor) = dacl(&HSTRING::from(file.as_os_str()), SE_FILE_OBJECT).unwrap();
            for sid in package_group_sids().unwrap() {
                let mask = (FILE_GENERIC_READ | FILE_GENERIC_EXECUTE).0;
                assert!(unsafe { grants(dacl, PSID(sid.0), mask, NO_INHERITANCE) });
            }
        }
        fs::remove_dir_all(&dir).unwrap();
    }
}
