use windows::Win32::Foundation::{CLASS_E_NOAGGREGATION, E_POINTER};
use windows::Win32::System::Com::{IClassFactory, IClassFactory_Impl};
use windows::core::{BOOL, ComObjectInner, GUID, IUnknown, Interface, Ref, Result, implement};

use crate::tip::TextInputProcessor;

#[implement(IClassFactory)]
#[derive(Default)]
pub struct ClassFactory;

impl IClassFactory_Impl for ClassFactory_Impl {
    fn CreateInstance(
        &self,
        punkouter: Ref<'_, IUnknown>,
        riid: *const GUID,
        ppvobject: *mut *mut core::ffi::c_void,
    ) -> Result<()> {
        if ppvobject.is_null() {
            return Err(E_POINTER.into());
        }
        unsafe { *ppvobject = core::ptr::null_mut() };
        if !punkouter.is_null() {
            return Err(CLASS_E_NOAGGREGATION.into());
        }

        let tip_unknown: IUnknown = TextInputProcessor::default().into_object().into_interface();
        unsafe { tip_unknown.query(riid, ppvobject) }.ok()
    }

    fn LockServer(&self, _flock: BOOL) -> Result<()> {
        Ok(())
    }
}
