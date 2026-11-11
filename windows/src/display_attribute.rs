use std::cell::Cell;

use windows::Win32::Foundation::{E_INVALIDARG, E_NOTIMPL, S_FALSE};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::TextServices::{
    CLSID_TF_CategoryMgr, GUID_PROP_ATTRIBUTE, IEnumTfDisplayAttributeInfo,
    IEnumTfDisplayAttributeInfo_Impl, ITfCategoryMgr, ITfContext, ITfDisplayAttributeInfo,
    ITfDisplayAttributeInfo_Impl, ITfRange, TF_ATTR_INPUT, TF_DA_COLOR, TF_DISPLAYATTRIBUTE,
    TF_LS_DOT,
};
use windows::core::{BOOL, BSTR, ComObjectInner, GUID, Result, implement};

use crate::guids::GUID_JD_DISPLAY_ATTRIBUTE;

const ATTRIBUTE_DESCRIPTION: &str = "键道 composition";

fn input_attribute() -> TF_DISPLAYATTRIBUTE {
    // Default-constructed TF_DA_COLOR is {type: TF_CT_NONE, union: zeroed},
    // which tells the host "use the default text/background color". We only
    // override the underline style (dotted, like Microsoft Pinyin) to mark
    // in-flight composition text.
    TF_DISPLAYATTRIBUTE {
        crText: TF_DA_COLOR::default(),
        crBk: TF_DA_COLOR::default(),
        lsStyle: TF_LS_DOT,
        fBoldLine: BOOL(0),
        crLine: TF_DA_COLOR::default(),
        bAttr: TF_ATTR_INPUT,
    }
}

#[implement(ITfDisplayAttributeInfo)]
#[derive(Default)]
pub struct DisplayAttributeInfo;

impl ITfDisplayAttributeInfo_Impl for DisplayAttributeInfo_Impl {
    fn GetGUID(&self) -> Result<GUID> {
        Ok(GUID_JD_DISPLAY_ATTRIBUTE)
    }

    fn GetDescription(&self) -> Result<BSTR> {
        Ok(BSTR::from(ATTRIBUTE_DESCRIPTION))
    }

    fn GetAttributeInfo(&self, pda: *mut TF_DISPLAYATTRIBUTE) -> Result<()> {
        if pda.is_null() {
            return Err(E_INVALIDARG.into());
        }
        unsafe { *pda = input_attribute() };
        Ok(())
    }

    fn SetAttributeInfo(&self, _pda: *const TF_DISPLAYATTRIBUTE) -> Result<()> {
        // We don't expose runtime customization of the display attribute.
        Err(E_NOTIMPL.into())
    }

    fn Reset(&self) -> Result<()> {
        // No persistent state.
        Ok(())
    }
}

#[implement(IEnumTfDisplayAttributeInfo)]
pub struct DisplayAttributeEnum {
    position: Cell<u32>,
}

impl Default for DisplayAttributeEnum {
    fn default() -> Self {
        Self {
            position: Cell::new(0),
        }
    }
}

impl DisplayAttributeEnum {
    fn at(position: u32) -> Self {
        Self {
            position: Cell::new(position),
        }
    }
}

impl IEnumTfDisplayAttributeInfo_Impl for DisplayAttributeEnum_Impl {
    fn Clone(&self) -> Result<IEnumTfDisplayAttributeInfo> {
        Ok(DisplayAttributeEnum::at(self.position.get())
            .into_object()
            .into_interface())
    }

    fn Next(
        &self,
        ulcount: u32,
        rginfo: *mut Option<ITfDisplayAttributeInfo>,
        pcfetched: *mut u32,
    ) -> Result<()> {
        // We expose exactly one display attribute (input/in-flight).
        let want = ulcount.min(1u32.saturating_sub(self.position.get()));
        if want > 0 {
            if rginfo.is_null() {
                return Err(E_INVALIDARG.into());
            }
            let info: ITfDisplayAttributeInfo = DisplayAttributeInfo.into_object().into_interface();
            unsafe { rginfo.write(Some(info)) };
            self.position.set(self.position.get() + 1);
        }
        if !pcfetched.is_null() {
            unsafe { *pcfetched = want };
        }
        // S_FALSE once the list has run out, as every COM enumerator says —
        // and as `Ok(())`, which is S_OK, does not. TSF's display attribute
        // manager walks an enumerator for as long as it hears S_OK: told
        // S_OK for ever, it never stopped, and the host went down with it.
        if want == ulcount {
            Ok(())
        } else {
            Err(S_FALSE.into())
        }
    }

    fn Reset(&self) -> Result<()> {
        self.position.set(0);
        Ok(())
    }

    fn Skip(&self, ulcount: u32) -> Result<()> {
        let left = 1u32.saturating_sub(self.position.get());
        self.position.set(self.position.get() + ulcount.min(left));
        // S_FALSE when there were fewer to skip, as in `Next`.
        if ulcount <= left {
            Ok(())
        } else {
            Err(S_FALSE.into())
        }
    }
}

// ---- Helpers used by composition.rs to apply / clear the attribute ----

thread_local! {
    static ATOM: Cell<Option<u32>> = const { Cell::new(None) };
}

fn atom() -> Result<u32> {
    if let Some(a) = ATOM.with(|c| c.get()) {
        return Ok(a);
    }
    let cat_mgr: ITfCategoryMgr =
        unsafe { CoCreateInstance(&CLSID_TF_CategoryMgr, None, CLSCTX_INPROC_SERVER) }?;
    let a = unsafe { cat_mgr.RegisterGUID(&GUID_JD_DISPLAY_ATTRIBUTE) }?;
    ATOM.with(|c| c.set(Some(a)));
    Ok(a)
}

pub fn apply(ctx: &ITfContext, ec: u32, range: &ITfRange) -> Result<()> {
    let a = atom()?;
    let prop = unsafe { ctx.GetProperty(&GUID_PROP_ATTRIBUTE) }?;
    // GUID_PROP_ATTRIBUTE expects a VT_I4 holding a TfGuidAtom.
    let var = VARIANT::from(a as i32);
    unsafe { prop.SetValue(ec, range, &var) }
}

pub fn clear(ctx: &ITfContext, ec: u32, range: &ITfRange) -> Result<()> {
    let prop = unsafe { ctx.GetProperty(&GUID_PROP_ATTRIBUTE) }?;
    unsafe { prop.Clear(ec, range) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::c_void;
    use windows::Win32::Foundation::S_OK;
    use windows::core::{HRESULT, Interface};

    /// `Next(count)` as a COM caller gets it: the HRESULT itself, how many
    /// elements came, and whether one was written.
    fn next(en: &IEnumTfDisplayAttributeInfo, count: u32) -> (HRESULT, u32, bool) {
        let mut out = [std::ptr::null_mut::<c_void>(); 2];
        let mut fetched = u32::MAX;
        // SAFETY: the enumerator's own method, with room for two elements;
        // an element written is released here.
        unsafe {
            let hr = (Interface::vtable(en).Next)(
                Interface::as_raw(en),
                count,
                out.as_mut_ptr(),
                &mut fetched,
            );
            let written = !out[0].is_null();
            if written {
                drop(ITfDisplayAttributeInfo::from_raw(out[0]));
            }
            (hr, fetched, written)
        }
    }

    #[test]
    fn the_enumerator_says_when_the_list_has_run_out() {
        let en: IEnumTfDisplayAttributeInfo = DisplayAttributeEnum::default()
            .into_object()
            .into_interface();
        assert_eq!(next(&en, 1), (S_OK, 1, true));
        // The end, where a caller that walks on S_OK must stop.
        assert_eq!(next(&en, 1), (S_FALSE, 0, false));
        assert_eq!(next(&en, 1), (S_FALSE, 0, false));

        // Asked for more than there is: what there is, and S_FALSE.
        unsafe { en.Reset() }.unwrap();
        assert_eq!(next(&en, 2), (S_FALSE, 1, true));
        // Asked for nothing: nothing, and S_OK.
        assert_eq!(next(&en, 0), (S_OK, 0, false));

        // Skip answers the same way, and a clone stands where its original
        // does.
        unsafe { en.Reset() }.unwrap();
        // SAFETY: the enumerator's own method.
        let skip = |count| unsafe { (Interface::vtable(&en).Skip)(Interface::as_raw(&en), count) };
        assert_eq!(skip(1), S_OK);
        assert_eq!(skip(1), S_FALSE);
        let clone = unsafe { en.Clone() }.unwrap();
        assert_eq!(next(&clone, 1), (S_FALSE, 0, false));
    }
}
