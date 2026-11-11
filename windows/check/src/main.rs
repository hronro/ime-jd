//! Whether the installed IME can be created in a process of this
//! architecture: what register.bat's work comes down to, for each kind of
//! application Windows runs. On x64 Windows those are two, x64 and x86; on
//! ARM64, where x64 applications run too and reach the IME through the
//! forwarder (../forwarder), three. The workflows that build the bundles
//! build this for each kind and run it against the bundle they have just
//! installed (.github/workflows/build-on-push.yml, release.yml).
//!
//!     ime_jd_check                the installed IME, created both ways below
//!     ime_jd_check --uninstalled  that there is none, after unregister.bat
//!     ime_jd_check <dll>          a DLL that is not installed, by its path
//!
//! TSF comes by an IME's objects in two ways, which load its DLL differently:
//!
//!   - through COM, to activate the text service. COM loads the registered
//!     DLL with LOAD_WITH_ALTERED_SEARCH_PATH in a desktop application, and
//!     so it does here;
//!   - by the registered path itself and with no flag, for a text service's
//!     display attributes (msctf's ComLessCreateInstance) — which is also
//!     how COM loads it in a Store app.
//!
//! Each is tried in a process of its own, so that neither finds there what
//! the other loaded.

#[path = "../../src/guids.rs"]
#[allow(dead_code)]
mod guids;

use std::env::consts::ARCH;
use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use windows::Win32::Foundation::{HMODULE, REGDB_E_CLASSNOTREG};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, IClassFactory,
};
use windows::Win32::System::LibraryLoader::{
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    GetModuleFileNameW, GetModuleHandleExW, GetProcAddress, LOAD_LIBRARY_FLAGS, LoadLibraryExW,
};
use windows::Win32::System::Registry::{HKEY_CLASSES_ROOT, RRF_RT_REG_SZ, RegGetValueW};
use windows::Win32::UI::TextServices::ITfTextInputProcessor;
use windows::core::{Error, GUID, HRESULT, Interface, PCWSTR, Result, s};

const THROUGH_COM: &str = "--through-com";
const BY_PATH: &str = "--by-path";

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
    let passed = match arguments[..] {
        [] => installed(),
        ["--uninstalled"] => uninstalled(),
        [THROUGH_COM] => report("through COM, as TSF activates it", through_com()),
        [BY_PATH] => report(
            "by its path, as TSF loads it for its display attributes",
            registered()
                .ok_or_else(|| Error::from(REGDB_E_CLASSNOTREG))
                .and_then(|dll| by_path(&dll)),
        ),
        [dll] if !dll.starts_with('-') => report("by its path", by_path(Path::new(dll))),
        _ => {
            eprintln!("usage: ime_jd_check [--uninstalled | <dll>]");
            return ExitCode::from(2);
        }
    };
    if passed {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// The installed IME, created each way in a process of its own.
fn installed() -> bool {
    let Some(dll) = registered() else {
        println!("ime-jd is not registered for {ARCH} processes.");
        return false;
    };
    println!(
        "ime-jd in an {ARCH} process, registered as {}",
        dll.display()
    );
    let own_process = |way: &str| {
        let started = std::env::current_exe().and_then(|exe| Command::new(exe).arg(way).status());
        match started {
            Ok(status) => status.success(),
            Err(error) => {
                println!("  {way}: not started, {error}");
                false
            }
        }
    };
    // Both, whatever the first one comes to.
    let through_com = own_process(THROUGH_COM);
    let by_path = own_process(BY_PATH);
    through_com && by_path
}

/// That no IME is registered for this kind of process, and COM says so.
fn uninstalled() -> bool {
    let registered = registered();
    match (&registered, through_com()) {
        (None, Err(error)) if error.code() == REGDB_E_CLASSNOTREG => {
            println!("ime-jd is gone from {ARCH} processes: not registered.");
            true
        }
        (_, created) => {
            println!(
                "ime-jd is not gone from {ARCH} processes: registered as {registered:?}, and creating it gave {created:?}"
            );
            false
        }
    }
}

fn report(how: &str, created: Result<PathBuf>) -> bool {
    match &created {
        Ok(dll) => println!("  {how}: created, by {}", dll.display()),
        Err(error) => println!("  {how}: not created, {error}"),
    }
    created.is_ok()
}

/// The DLL registered as the IME's, in the registry this process reads — a
/// 32-bit process has one of its own.
fn registered() -> Option<PathBuf> {
    let clsid = guids::CLSID_JD_IME;
    let [d0, d1, d2, d3, d4, d5, d6, d7] = clsid.data4;
    let key = wide(Path::new(&format!(
        "CLSID\\{{{:08X}-{:04X}-{:04X}-{d0:02X}{d1:02X}-{d2:02X}{d3:02X}{d4:02X}{d5:02X}{d6:02X}{d7:02X}}}\\InprocServer32",
        clsid.data1, clsid.data2, clsid.data3
    )));
    let mut buffer = [0u16; 1024];
    let mut size = size_of_val(&buffer) as u32;
    // SAFETY: the buffer's size goes with it.
    unsafe {
        RegGetValueW(
            HKEY_CLASSES_ROOT,
            PCWSTR(key.as_ptr()),
            PCWSTR::null(),
            RRF_RT_REG_SZ,
            None,
            Some(buffer.as_mut_ptr().cast()),
            Some(&mut size),
        )
    }
    .ok()
    .ok()?;
    let end = buffer.iter().position(|&c| c == 0).unwrap_or(buffer.len());
    Some(PathBuf::from(String::from_utf16_lossy(&buffer[..end])))
}

/// As `TipCreateInstance` in msctf: the class, in process, for the text
/// service's own interface.
fn through_com() -> Result<PathBuf> {
    // SAFETY: COM on this thread, for as long as the process lasts.
    let tip: ITfTextInputProcessor = unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()?;
        CoCreateInstance(&guids::CLSID_JD_IME, None, CLSCTX_INPROC_SERVER)?
    };
    home(&tip)
}

/// As `ComLessCreateInstance` in msctf: the DLL loaded by its path with no
/// flag, and its class factory asked for the object.
fn by_path(dll: &Path) -> Result<PathBuf> {
    type GetClassObject =
        unsafe extern "system" fn(*const GUID, *const GUID, *mut *mut c_void) -> HRESULT;
    let path = wide(&std::path::absolute(dll)?);
    // SAFETY: the DLL's documented entry point, called as COM calls it; the
    // DLL stays loaded for as long as the process lasts.
    let tip: ITfTextInputProcessor = unsafe {
        let module = LoadLibraryExW(PCWSTR(path.as_ptr()), None, LOAD_LIBRARY_FLAGS(0))?;
        let entry =
            GetProcAddress(module, s!("DllGetClassObject")).ok_or_else(Error::from_thread)?;
        let get: GetClassObject = std::mem::transmute(entry);
        let mut factory = std::ptr::null_mut();
        get(&guids::CLSID_JD_IME, &IClassFactory::IID, &mut factory).ok()?;
        IClassFactory::from_raw(factory).CreateInstance(None)?
    };
    home(&tip)
}

/// The DLL an object's code is in: the one its vtable lies in.
fn home(object: &impl Interface) -> Result<PathBuf> {
    let mut module = HMODULE::default();
    let mut buffer = [0u16; 1024];
    // SAFETY: a COM object starts with the pointer to its vtable, and the
    // buffer's length goes with it.
    let length = unsafe {
        let vtable = *(object.as_raw() as *const *const u16);
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            PCWSTR(vtable),
            &mut module,
        )?;
        GetModuleFileNameW(Some(module), &mut buffer) as usize
    };
    if length == 0 {
        return Err(Error::from_thread());
    }
    Ok(PathBuf::from(String::from_utf16_lossy(&buffer[..length])))
}

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain([0]).collect()
}
