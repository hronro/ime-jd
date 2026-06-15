use windows::Win32::Foundation::{MAX_PATH, S_OK};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
    CoUninitialize,
};
use windows::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows::Win32::System::Registry::{
    HKEY, HKEY_LOCAL_MACHINE, KEY_WRITE, REG_OPTION_NON_VOLATILE, REG_SZ, RegCloseKey,
    RegCreateKeyExW, RegDeleteTreeW, RegSetValueExW,
};
use windows::Win32::UI::Input::KeyboardAndMouse::HKL;
use windows::Win32::UI::TextServices::{
    CLSID_TF_CategoryMgr, CLSID_TF_InputProcessorProfiles, GUID_TFCAT_CATEGORY_OF_TIP,
    GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER, GUID_TFCAT_TIP_KEYBOARD,
    GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT, GUID_TFCAT_TIPCAP_UIELEMENTENABLED, ITfCategoryMgr,
    ITfInputProcessorProfileMgr,
};

// Categories we declare. Each one corresponds to a feature we actually
// implement:
//   TIP_KEYBOARD             — keyboard TIP
//   CATEGORY_OF_TIP          — generic "this CLSID is a TIP"
//   IMMERSIVESUPPORT         — works in UWP/Store apps
//   UIELEMENTENABLED         — supports the UIElement API (candidate list)
//   DISPLAYATTRIBUTEPROVIDER — provides the composition underline
const REGISTERED_CATEGORIES: &[windows::core::GUID] = &[
    GUID_TFCAT_TIP_KEYBOARD,
    GUID_TFCAT_CATEGORY_OF_TIP,
    GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
    GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
];
use windows::core::{Error, PCWSTR, Result};

use crate::{dll_hmodule, guids};

pub fn register() -> Result<()> {
    let dll_path = dll_path()?;
    write_clsid_registry(&dll_path)?;

    let _com = ComScope::init()?;

    let profile_mgr: ITfInputProcessorProfileMgr =
        unsafe { CoCreateInstance(&CLSID_TF_InputProcessorProfiles, None, CLSCTX_INPROC_SERVER) }?;
    let category_mgr: ITfCategoryMgr =
        unsafe { CoCreateInstance(&CLSID_TF_CategoryMgr, None, CLSCTX_INPROC_SERVER) }?;

    let desc: Vec<u16> = guids::IME_DESCRIPTION.encode_utf16().collect();

    unsafe {
        profile_mgr.RegisterProfile(
            &guids::CLSID_JD_IME,
            guids::LANGID_ZH_CN,
            &guids::GUID_JD_PROFILE,
            &desc,
            &dll_path,
            0,
            HKL::default(),
            0,
            // bEnabledByDefault=false to match Microsoft Pinyin's registry shape
            // (Enable=0). enabled-by-default may cause Windows' "Add a keyboard"
            // UI to filter the IME out as already-installed-and-broken.
            false,
            0,
        )?;
        for cat in REGISTERED_CATEGORIES {
            // Third arg (rguid) is the *item* GUID. Microsoft's IMEs and
            // Rime/Weasel both pass the CLSID here; passing the profile GUID
            // (as the API docs ambiguously suggest) makes Settings reject the
            // IME for immersive use and tag it "(desktop only)".
            category_mgr.RegisterCategory(&guids::CLSID_JD_IME, cat, &guids::CLSID_JD_IME)?;
        }
    }

    Ok(())
}

pub fn unregister() -> Result<()> {
    // Best-effort: keep going even if individual steps fail (e.g. the entry was
    // already missing). Registry deletion happens last so the COM lookup still
    // works while TSF unregisters.
    let com_result = ComScope::init();
    if let Ok(_com) = com_result {
        if let Ok(category_mgr) = unsafe {
            CoCreateInstance::<_, ITfCategoryMgr>(
                &CLSID_TF_CategoryMgr,
                None,
                CLSCTX_INPROC_SERVER,
            )
        } {
            for cat in REGISTERED_CATEGORIES {
                let _ = unsafe {
                    category_mgr.UnregisterCategory(
                        &guids::CLSID_JD_IME,
                        cat,
                        &guids::CLSID_JD_IME,
                    )
                };
            }
        }
        if let Ok(profile_mgr) = unsafe {
            CoCreateInstance::<_, ITfInputProcessorProfileMgr>(
                &CLSID_TF_InputProcessorProfiles,
                None,
                CLSCTX_INPROC_SERVER,
            )
        } {
            let _ = unsafe {
                profile_mgr.UnregisterProfile(
                    &guids::CLSID_JD_IME,
                    guids::LANGID_ZH_CN,
                    &guids::GUID_JD_PROFILE,
                    0,
                )
            };
        }
    }

    let _ = delete_clsid_registry();
    Ok(())
}

fn dll_path() -> Result<Vec<u16>> {
    let hmod = dll_hmodule();
    let mut buf = vec![0u16; MAX_PATH as usize];
    loop {
        let len = unsafe { GetModuleFileNameW(Some(hmod), &mut buf) };
        if len == 0 {
            return Err(Error::from_thread());
        }
        if (len as usize) < buf.len() {
            buf.truncate(len as usize);
            return Ok(buf);
        }
        buf.resize(buf.len() * 2, 0);
    }
}

struct ComScope {
    needs_uninit: bool,
}

impl ComScope {
    fn init() -> Result<Self> {
        let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        if hr.is_ok() {
            // S_OK = we initialized; S_FALSE = caller already initialized
            // (regsvr32 sets up STA, so usually S_FALSE here).
            Ok(ComScope {
                needs_uninit: hr == S_OK,
            })
        } else {
            Err(hr.into())
        }
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        if self.needs_uninit {
            unsafe { CoUninitialize() };
        }
    }
}

fn clsid_registry_path() -> String {
    let g = &guids::CLSID_JD_IME;
    format!(
        "SOFTWARE\\Classes\\CLSID\\{{{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}}}",
        g.data1, g.data2, g.data3,
        g.data4[0], g.data4[1], g.data4[2], g.data4[3],
        g.data4[4], g.data4[5], g.data4[6], g.data4[7]
    )
}

fn inproc_registry_path() -> String {
    format!("{}\\InprocServer32", clsid_registry_path())
}

fn write_clsid_registry(dll_path_wide: &[u16]) -> Result<()> {
    write_default_str(&clsid_registry_path(), guids::IME_DESCRIPTION)?;
    write_default_wide(&inproc_registry_path(), dll_path_wide)?;
    write_named_str(&inproc_registry_path(), "ThreadingModel", "Apartment")?;
    Ok(())
}

fn delete_clsid_registry() -> Result<()> {
    let path_w = wide_z(&clsid_registry_path());
    // Best-effort: clear any stale per-user entry left by older installs that
    // wrote to HKCU. The HKLM delete below is the one we care about.
    unsafe {
        let _ = RegDeleteTreeW(
            windows::Win32::System::Registry::HKEY_CURRENT_USER,
            PCWSTR(path_w.as_ptr()),
        );
    }
    unsafe { RegDeleteTreeW(HKEY_LOCAL_MACHINE, PCWSTR(path_w.as_ptr())) }.ok()
}

fn wide_z(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn write_default_str(path: &str, value: &str) -> Result<()> {
    let value_w = wide_z(value);
    write_value(path, PCWSTR::null(), &value_w)
}

fn write_default_wide(path: &str, value_wide: &[u16]) -> Result<()> {
    let mut value_z: Vec<u16> = value_wide.to_vec();
    if value_z.last() != Some(&0) {
        value_z.push(0);
    }
    write_value(path, PCWSTR::null(), &value_z)
}

fn write_named_str(path: &str, name: &str, value: &str) -> Result<()> {
    let name_w = wide_z(name);
    let value_w = wide_z(value);
    write_value(path, PCWSTR(name_w.as_ptr()), &value_w)
}

fn write_value(path: &str, value_name: PCWSTR, value_wide_z: &[u16]) -> Result<()> {
    let path_w = wide_z(path);
    let mut hkey = HKEY::default();
    unsafe {
        RegCreateKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(path_w.as_ptr()),
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut hkey,
            None,
        )
        .ok()?;

        let bytes = std::slice::from_raw_parts(
            value_wide_z.as_ptr() as *const u8,
            value_wide_z.len() * 2,
        );
        let set_err = RegSetValueExW(hkey, value_name, None, REG_SZ, Some(bytes)).ok();
        let close_err = RegCloseKey(hkey).ok();
        set_err?;
        close_err?;
    }
    Ok(())
}
