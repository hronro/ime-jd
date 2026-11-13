//! `ime_jd_check --hand-over <folder>`: whether the loader (../../loader)
//! hands a thread's IME over from one installation to the next, in a
//! process of the architecture this is built for.
//!
//! `<folder>` is a release's package, or the folder one is installed in. Its
//! loader and its IME are copied to a folder of their own, laid out as
//! register.bat lays an installation out, and what is done to them there is
//! what happens to an application that is running while a newer 键道 is
//! installed: the loader is asked for the IME and the IME activated, a
//! second installation is made beside the first, the IME is told that the
//! thread has the focus again — and the loader is to have the second
//! installation's IME active by the time the messages have been read, with
//! the input mode as it was.
//!
//! No TSF is in it, and nothing is registered or installed. The thread
//! manager the IME is activated with is a stand-in ([`Threads`]) that keeps
//! what the IME hands it — its key sink, its other sinks, the keyboard's
//! open/close switch — which is all that an IME does with a thread manager
//! when it is activated and deactivated, and what the loader carries over.
//! So this runs wherever a process of this architecture runs: on ARM64 it is
//! the one test there is of the loader's x64 side, which is ARM64EC code.
//! What TSF itself makes of a hand-over is not seen here.

use std::cell::{Cell, RefCell};
use std::env::consts::ARCH;
use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{E_INVALIDARG, E_NOTIMPL, HWND, LPARAM, WPARAM};
use windows::Win32::System::Com::{
    COINIT_APARTMENTTHREADED, CoInitializeEx, IClassFactory, IEnumGUID,
};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LOAD_LIBRARY_FLAGS, LoadLibraryExW};
use windows::Win32::System::Ole::CONNECT_E_NOCONNECTION;
use windows::Win32::System::Variant::{VARIANT, VT_I4};
use windows::Win32::UI::TextServices::{
    GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, IEnumTfDocumentMgrs, IEnumTfFunctionProviders,
    ITfCompartment, ITfCompartment_Impl, ITfCompartmentEventSink, ITfCompartmentMgr,
    ITfCompartmentMgr_Impl, ITfContext, ITfDocumentMgr, ITfFunctionProvider, ITfKeyEventSink,
    ITfKeystrokeMgr, ITfKeystrokeMgr_Impl, ITfSource, ITfSource_Impl, ITfTextInputProcessorEx,
    ITfThreadFocusSink, ITfThreadMgr, ITfThreadMgr_Impl, TF_PRESERVEDKEY, TF_TMAE_SECUREMODE,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MSG, PM_REMOVE, PeekMessageW, TranslateMessage,
};
use windows::core::{
    BOOL, BSTR, ComObject, Error, GUID, HRESULT, IUnknown, Interface, PCWSTR, Ref, Result,
    implement, s,
};

use crate::{guids, home, wide};

/// The argument the test's own process is started with.
pub const IN_ITS_FOLDER: &str = "--hand-over-in";

/// What the loader calls an architecture (loader.c).
fn arch() -> &'static str {
    match ARCH {
        "x86_64" => "x64",
        "aarch64" => "arm64",
        other => other,
    }
}

fn loader_name() -> &'static str {
    if ARCH == "x86" {
        "ime_jd_x86.dll"
    } else {
        "ime_jd.dll"
    }
}

fn ime_name(id: &str) -> String {
    format!("jd-{id}-{}.dll", arch())
}

/// The IME for this architecture in `folder`: as it lies in a package, or
/// the one of the installation `current` names.
fn ime_in(folder: &Path) -> Option<PathBuf> {
    let packaged = folder.join(format!("jd-{}.dll", arch()));
    if packaged.is_file() {
        return Some(packaged);
    }
    let id = std::fs::read_to_string(folder.join("current")).ok()?;
    Some(folder.join(ime_name(id.trim()))).filter(|ime| ime.is_file())
}

/// The loader and the IME of `folder`, tried in a folder and a process of
/// their own.
pub fn run(folder: &Path) -> bool {
    let loader = folder.join(loader_name());
    let Some(ime) = ime_in(folder).filter(|_| loader.is_file()) else {
        println!(
            "No loader ({}) with an IME for {ARCH} processes behind it in {}.",
            loader_name(),
            folder.display()
        );
        return false;
    };
    println!(
        "ime-jd's loader in an {ARCH} process: {} in front of {}",
        loader.display(),
        ime.display()
    );
    let scratch = std::env::temp_dir().join(format!("ime_jd_check-{}", std::process::id()));
    let tried = (|| -> std::io::Result<bool> {
        std::fs::create_dir_all(&scratch)?;
        std::fs::copy(&loader, scratch.join(loader_name()))?;
        install(&scratch, "one", &ime)?;
        let status = Command::new(std::env::current_exe()?)
            .arg(IN_ITS_FOLDER)
            .arg(&scratch)
            .arg(&ime)
            .status()?;
        Ok(status.success())
    })();
    // The DLLs are free again once that process has gone.
    let _ = std::fs::remove_dir_all(&scratch);
    match tried {
        Ok(passed) => passed,
        Err(error) => {
            println!("  not tried: {error}");
            false
        }
    }
}

/// An installation as register.bat makes one: the IME copied in under the
/// installation's id, then `current` put in place whole.
fn install(folder: &Path, id: &str, ime: &Path) -> std::io::Result<()> {
    std::fs::copy(ime, folder.join(ime_name(id)))?;
    point_at(folder, id)
}

fn point_at(folder: &Path, id: &str) -> std::io::Result<()> {
    let new = folder.join("current.new");
    std::fs::write(&new, format!("{id}\r\n"))?;
    std::fs::rename(new, folder.join("current"))
}

/// The test itself, in `scratch`, where the loader and the installation
/// "one" lie; `ime` is what further installations are made of.
pub fn in_its_folder(scratch: &Path, ime: &Path) -> bool {
    match hand_over(scratch, ime) {
        Ok(()) => true,
        Err(error) => {
            println!("  FAILED: {error}");
            false
        }
    }
}

fn failed<T>(why: String) -> Result<T> {
    Err(Error::new(HRESULT(0x8000_4005u32 as i32), why))
}

fn hand_over(scratch: &Path, ime: &Path) -> Result<()> {
    type GetClassObject =
        unsafe extern "system" fn(*const GUID, *const GUID, *mut *mut c_void) -> HRESULT;
    let path = wide(&scratch.join(loader_name()));
    // SAFETY: COM on this thread for as long as the process lasts, and the
    // loader's documented entry point, called as COM calls it.
    let tip: ITfTextInputProcessorEx = unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()?;
        let module = LoadLibraryExW(PCWSTR(path.as_ptr()), None, LOAD_LIBRARY_FLAGS(0))?;
        let entry =
            GetProcAddress(module, s!("DllGetClassObject")).ok_or_else(Error::from_thread)?;
        let get: GetClassObject = std::mem::transmute(entry);
        let mut factory = std::ptr::null_mut();
        get(&guids::CLSID_JD_IME, &IClassFactory::IID, &mut factory).ok()?;
        IClassFactory::from_raw(factory).CreateInstance(None)?
    };
    let loader = home(&tip)?;

    let threads = ComObject::new(Threads::default());
    let thread_mgr: ITfThreadMgr = threads.to_interface();
    // The IME behind the object: where the key sink it has handed the
    // thread manager lives.
    let active = || -> Result<PathBuf> {
        match threads.key_sink.borrow().as_ref() {
            Some(sink) => home(sink),
            None => failed("the IME has no key sink with the thread manager".to_owned()),
        }
    };
    let is = |path: &Path, id: &str| {
        path.file_name().and_then(|name| name.to_str()) == Some(ime_name(id).as_str())
    };
    let mode = || match threads.keyboard.value.get() {
        Some(0) => "英",
        Some(_) => "中",
        None => "not set",
    };
    // As TSF tells the IME that the thread has the focus again: the cue
    // for the loader. Then the messages, where the loader acts.
    let focus_back = |until: &dyn Fn() -> bool| -> Result<()> {
        let sink = threads.sink::<ITfThreadFocusSink>();
        match sink {
            // SAFETY: a plain call on the IME's sink.
            Some(sink) => unsafe { sink.OnSetThreadFocus() }?,
            None => return failed("the IME has no ear for the thread's focus".to_owned()),
        }
        read_messages(until);
        Ok(())
    };

    // The secure desktop's flag: an IME activated with it starts nothing —
    // no look for updates over the network, which is no business of a
    // test's.
    // SAFETY: plain calls on the loader's object, here and below.
    unsafe { tip.ActivateEx(&thread_mgr, CLIENT, TF_TMAE_SECUREMODE) }?;
    let first = active()?;
    if first == loader || !is(&first, "one") || mode() != "中" {
        return failed(format!(
            "activated, the IME is {} behind {}, the mode {}",
            first.display(),
            loader.display(),
            mode()
        ));
    }
    println!(
        "  activated: the IME is {}, the mode {}",
        first.display(),
        mode()
    );

    // 英, as Shift or the mode icon would set it: what a hand-over is to
    // leave as it is.
    threads.keyboard.set(0);
    install(scratch, "two", ime)?;
    focus_back(&|| active().is_ok_and(|ime| is(&ime, "two")))?;
    let second = active()?;
    if !is(&second, "two") || mode() != "英" || threads.sinks_of(&first)? != 0 {
        return failed(format!(
            "after a second installation the IME is {}, the mode {}, and {} of the first one's sinks are still with the thread manager",
            second.display(),
            mode(),
            threads.sinks_of(&first)?
        ));
    }
    println!(
        "  a second installation made, the mode 英: handed over to {}, the mode still {}",
        second.display(),
        mode()
    );

    point_at(scratch, "three")?;
    focus_back(&|| false)?;
    let still = active()?;
    if !is(&still, "two") {
        return failed(format!(
            "with an installation named that is not there, the IME is {}",
            still.display()
        ));
    }
    println!(
        "  an installation named that is not there: {} goes on",
        still.display()
    );

    unsafe { tip.Deactivate() }?;
    let left = threads.sinks.borrow().len() + threads.keyboard.sinks.borrow().len();
    if threads.key_sink.borrow().is_some() || left != 0 {
        return failed(format!(
            "deactivated, the IME has left {left} sinks and its key sink with the thread manager"
        ));
    }
    println!("  deactivated: nothing of the IME's is left with the thread manager");

    point_at(scratch, "one")?;
    unsafe { tip.ActivateEx(&thread_mgr, CLIENT, TF_TMAE_SECUREMODE) }?;
    let again = active()?;
    if !is(&again, "one") {
        return failed(format!(
            "activated again with the first installation in use, the IME is {}",
            again.display()
        ));
    }
    println!(
        "  activated again, the first installation in use: {}",
        again.display()
    );
    unsafe { tip.Deactivate() }?;
    Ok(())
}

/// Read this thread's messages until `done`, for two seconds at most.
fn read_messages(done: &dyn Fn() -> bool) {
    let end = Instant::now() + Duration::from_secs(2);
    loop {
        let mut message = MSG::default();
        // SAFETY: this thread's own queue.
        unsafe {
            while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        if done() || Instant::now() >= end {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The client id TSF would give the IME.
const CLIENT: u32 = 7;

/// A thread manager as far as an IME's activation and deactivation go: it
/// keeps what it is handed, and answers nothing else.
#[implement(ITfThreadMgr, ITfKeystrokeMgr, ITfSource, ITfCompartmentMgr)]
struct Threads {
    key_sink: RefCell<Option<ITfKeyEventSink>>,
    /// The sinks advised through ITfSource, by cookie.
    sinks: RefCell<Vec<(u32, IUnknown)>>,
    cookies: Cell<u32>,
    keyboard: ComObject<Switch>,
}

impl Default for Threads {
    fn default() -> Self {
        Self {
            key_sink: RefCell::default(),
            sinks: RefCell::default(),
            cookies: Cell::new(0),
            keyboard: ComObject::new(Switch::default()),
        }
    }
}

impl Threads {
    /// The sink of the IME's for `T`, if it has advised one.
    fn sink<T: Interface>(&self) -> Option<T> {
        self.sinks
            .borrow()
            .iter()
            .find_map(|(_, sink)| sink.cast::<T>().ok())
    }

    /// How many sinks whose code is in `dll` the thread manager, and the
    /// keyboard's switch, still hold.
    fn sinks_of(&self, dll: &Path) -> Result<usize> {
        let mut count = 0;
        for (_, sink) in self.sinks.borrow().iter() {
            count += usize::from(home(sink)? == dll);
        }
        for (_, sink) in self.keyboard.sinks.borrow().iter() {
            count += usize::from(home(sink)? == dll);
        }
        Ok(count)
    }
}

impl ITfThreadMgr_Impl for Threads_Impl {
    fn Activate(&self) -> Result<u32> {
        Err(E_NOTIMPL.into())
    }

    fn Deactivate(&self) -> Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn CreateDocumentMgr(&self) -> Result<ITfDocumentMgr> {
        Err(E_NOTIMPL.into())
    }

    fn EnumDocumentMgrs(&self) -> Result<IEnumTfDocumentMgrs> {
        Err(E_NOTIMPL.into())
    }

    fn GetFocus(&self) -> Result<ITfDocumentMgr> {
        Err(E_NOTIMPL.into())
    }

    fn SetFocus(&self, _focus: Ref<ITfDocumentMgr>) -> Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn AssociateFocus(&self, _window: HWND, _new: Ref<ITfDocumentMgr>) -> Result<ITfDocumentMgr> {
        Err(E_NOTIMPL.into())
    }

    fn IsThreadFocus(&self) -> Result<BOOL> {
        Ok(BOOL(1))
    }

    fn GetFunctionProvider(&self, _clsid: *const GUID) -> Result<ITfFunctionProvider> {
        Err(E_NOTIMPL.into())
    }

    fn EnumFunctionProviders(&self) -> Result<IEnumTfFunctionProviders> {
        Err(E_NOTIMPL.into())
    }

    fn GetGlobalCompartment(&self) -> Result<ITfCompartmentMgr> {
        Err(E_NOTIMPL.into())
    }
}

impl ITfKeystrokeMgr_Impl for Threads_Impl {
    fn AdviseKeyEventSink(
        &self,
        tid: u32,
        sink: Ref<ITfKeyEventSink>,
        _foreground: BOOL,
    ) -> Result<()> {
        if tid != CLIENT {
            return Err(E_INVALIDARG.into());
        }
        *self.key_sink.borrow_mut() = Some(sink.ok()?.clone());
        Ok(())
    }

    fn UnadviseKeyEventSink(&self, tid: u32) -> Result<()> {
        if tid != CLIENT || self.key_sink.borrow_mut().take().is_none() {
            return Err(CONNECT_E_NOCONNECTION.into());
        }
        Ok(())
    }

    fn GetForeground(&self) -> Result<GUID> {
        Err(E_NOTIMPL.into())
    }

    fn TestKeyDown(&self, _wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        Err(E_NOTIMPL.into())
    }

    fn TestKeyUp(&self, _wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        Err(E_NOTIMPL.into())
    }

    fn KeyDown(&self, _wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        Err(E_NOTIMPL.into())
    }

    fn KeyUp(&self, _wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        Err(E_NOTIMPL.into())
    }

    fn GetPreservedKey(
        &self,
        _context: Ref<ITfContext>,
        _key: *const TF_PRESERVEDKEY,
    ) -> Result<GUID> {
        Err(E_NOTIMPL.into())
    }

    fn IsPreservedKey(&self, _guid: *const GUID, _key: *const TF_PRESERVEDKEY) -> Result<BOOL> {
        Err(E_NOTIMPL.into())
    }

    fn PreserveKey(
        &self,
        _tid: u32,
        _guid: *const GUID,
        _key: *const TF_PRESERVEDKEY,
        _description: &PCWSTR,
        _length: u32,
    ) -> Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn UnpreserveKey(&self, _guid: *const GUID, _key: *const TF_PRESERVEDKEY) -> Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn SetPreservedKeyDescription(
        &self,
        _guid: *const GUID,
        _description: &PCWSTR,
        _length: u32,
    ) -> Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn GetPreservedKeyDescription(&self, _guid: *const GUID) -> Result<BSTR> {
        Err(E_NOTIMPL.into())
    }

    fn SimulatePreservedKey(&self, _context: Ref<ITfContext>, _guid: *const GUID) -> Result<BOOL> {
        Err(E_NOTIMPL.into())
    }
}

impl ITfSource_Impl for Threads_Impl {
    fn AdviseSink(&self, iid: *const GUID, sink: Ref<IUnknown>) -> Result<u32> {
        // As TSF: the sink has to be what it is advised as.
        let mut asked = std::ptr::null_mut();
        // SAFETY: the caller passes an interface's id, and the pointer
        // that comes back is released at once.
        unsafe {
            sink.ok()?.query(iid, &mut asked).ok()?;
            drop(IUnknown::from_raw(asked));
        }
        let cookie = self.cookies.get() + 1;
        self.cookies.set(cookie);
        self.sinks.borrow_mut().push((cookie, sink.ok()?.clone()));
        Ok(cookie)
    }

    fn UnadviseSink(&self, cookie: u32) -> Result<()> {
        let mut sinks = self.sinks.borrow_mut();
        let before = sinks.len();
        sinks.retain(|(advised, _)| *advised != cookie);
        if sinks.len() == before {
            return Err(CONNECT_E_NOCONNECTION.into());
        }
        Ok(())
    }
}

impl ITfCompartmentMgr_Impl for Threads_Impl {
    fn GetCompartment(&self, guid: *const GUID) -> Result<ITfCompartment> {
        // SAFETY: the caller passes a compartment's id.
        if unsafe { guid.as_ref() } != Some(&GUID_COMPARTMENT_KEYBOARD_OPENCLOSE) {
            return Err(E_INVALIDARG.into());
        }
        Ok(self.keyboard.to_interface())
    }

    fn ClearCompartment(&self, _tid: u32, _guid: *const GUID) -> Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn EnumCompartments(&self) -> Result<IEnumGUID> {
        Err(E_NOTIMPL.into())
    }
}

/// The keyboard's open/close switch, which is the IME's input mode: a
/// value, and whoever wants to hear of its changes.
#[implement(ITfCompartment, ITfSource)]
#[derive(Default)]
struct Switch {
    value: Cell<Option<i32>>,
    sinks: RefCell<Vec<(u32, ITfCompartmentEventSink)>>,
    cookies: Cell<u32>,
}

impl Switch {
    fn set(&self, value: i32) {
        self.value.set(Some(value));
        // Told outside the borrow: a sink may advise or unadvise in answer.
        let sinks: Vec<ITfCompartmentEventSink> = self
            .sinks
            .borrow()
            .iter()
            .map(|(_, sink)| sink.clone())
            .collect();
        for sink in sinks {
            // SAFETY: a plain call on the IME's sink.
            let _ = unsafe { sink.OnChange(&GUID_COMPARTMENT_KEYBOARD_OPENCLOSE) };
        }
    }
}

impl ITfCompartment_Impl for Switch_Impl {
    fn SetValue(&self, _tid: u32, value: *const VARIANT) -> Result<()> {
        // SAFETY: the caller passes a VARIANT; only a VT_I4 is read.
        let value = unsafe {
            let inner = &value.as_ref().ok_or(E_INVALIDARG)?.Anonymous.Anonymous;
            if inner.vt != VT_I4 {
                return Err(E_INVALIDARG.into());
            }
            inner.Anonymous.lVal
        };
        self.set(value);
        Ok(())
    }

    fn GetValue(&self) -> Result<VARIANT> {
        let mut value = VARIANT::default();
        if let Some(set) = self.value.get() {
            // SAFETY: a VT_I4 VARIANT owns nothing.
            unsafe {
                let inner = &mut *value.Anonymous.Anonymous;
                inner.vt = VT_I4;
                inner.Anonymous.lVal = set;
            }
        }
        Ok(value)
    }
}

impl ITfSource_Impl for Switch_Impl {
    fn AdviseSink(&self, _iid: *const GUID, sink: Ref<IUnknown>) -> Result<u32> {
        let sink: ITfCompartmentEventSink = sink.ok()?.cast()?;
        let cookie = self.cookies.get() + 1;
        self.cookies.set(cookie);
        self.sinks.borrow_mut().push((cookie, sink));
        Ok(cookie)
    }

    fn UnadviseSink(&self, cookie: u32) -> Result<()> {
        let mut sinks = self.sinks.borrow_mut();
        let before = sinks.len();
        sinks.retain(|(advised, _)| *advised != cookie);
        if sinks.len() == before {
            return Err(CONNECT_E_NOCONNECTION.into());
        }
        Ok(())
    }
}
