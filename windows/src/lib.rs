#![allow(non_snake_case)]

pub mod jd;

mod candidate_window;
mod composition;
mod display_attribute;
mod edit_session;
mod factory;
mod guids;
mod registration;
mod tip;

use std::ffi::c_void;
use std::sync::atomic::{AtomicIsize, Ordering};
use windows::Win32::Foundation::{
    CLASS_E_CLASSNOTAVAILABLE, E_POINTER, HINSTANCE, HMODULE, S_FALSE, S_OK,
};
use windows::Win32::System::Com::IClassFactory;
use windows::Win32::System::SystemServices::DLL_PROCESS_ATTACH;
use windows::core::{BOOL, ComObjectInner, GUID, HRESULT, Interface};

static DLL_INSTANCE: AtomicIsize = AtomicIsize::new(0);

pub(crate) fn dll_hmodule() -> HMODULE {
    HMODULE(DLL_INSTANCE.load(Ordering::Relaxed) as *mut _)
}

#[unsafe(no_mangle)]
extern "system" fn DllMain(hinst: HINSTANCE, reason: u32, _reserved: *mut c_void) -> BOOL {
    if reason == DLL_PROCESS_ATTACH {
        DLL_INSTANCE.store(hinst.0 as isize, Ordering::Relaxed);
    }
    BOOL(1)
}

#[unsafe(no_mangle)]
extern "system" fn DllGetClassObject(
    rclsid: *const GUID,
    riid: *const GUID,
    ppv: *mut *mut c_void,
) -> HRESULT {
    if rclsid.is_null() || riid.is_null() || ppv.is_null() {
        return E_POINTER;
    }
    if unsafe { *rclsid } != guids::CLSID_JD_IME {
        return CLASS_E_CLASSNOTAVAILABLE;
    }

    let factory: IClassFactory = factory::ClassFactory.into_object().into_interface();
    unsafe { factory.query(riid, ppv) }
}

#[unsafe(no_mangle)]
extern "system" fn DllCanUnloadNow() -> HRESULT {
    // TIPs should never request DLL unload — TSF keeps a reference for the
    // life of the host process. Returning S_FALSE here is the standard pattern.
    S_FALSE
}

#[unsafe(no_mangle)]
extern "system" fn DllRegisterServer() -> HRESULT {
    match registration::register() {
        Ok(()) => S_OK,
        Err(e) => e.code(),
    }
}

#[unsafe(no_mangle)]
extern "system" fn DllUnregisterServer() -> HRESULT {
    match registration::unregister() {
        Ok(()) => S_OK,
        Err(e) => e.code(),
    }
}
