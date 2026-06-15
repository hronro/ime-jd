use std::ffi::CStr;
use std::sync::{Mutex, OnceLock};

mod ffi {
    use std::os::raw::c_char;
    use std::ptr::NonNull;

    #[derive(Debug)]
    #[repr(C)]
    pub struct QueryOption {
        pub value: *const c_char,
        pub hint: Option<NonNull<c_char>>,
    }

    #[derive(Debug)]
    #[repr(C)]
    pub struct QueryResult {
        pub commit: Option<NonNull<c_char>>,
        pub options: Option<NonNull<QueryOption>>,
        pub options_count: u32,
        pub total_pages: u32,
        pub current_page: u32,
    }

    #[allow(dead_code)]
    unsafe extern "C" {
        pub fn jd_init(page_size: u8);
        pub fn jd_press_key(key: u8) -> QueryResult;
        pub fn jd_next_page() -> QueryResult;
        pub fn jd_prev_page() -> QueryResult;
        pub fn jd_jump_to_page(page: u32) -> QueryResult;
        pub fn jd_backspace() -> QueryResult;
        pub fn jd_reset();
        pub fn jd_deinit();
    }
}

#[derive(Debug, Clone)]
pub struct QueryOption {
    pub value: String,
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct QueryResult {
    pub commit: Option<String>,
    pub options: Vec<QueryOption>,
    pub options_count: u32,
    pub total_pages: u32,
    pub current_page: u32,
}

pub struct JdEngine {
    page_size: OnceLock<u8>,
    serialize: Mutex<()>,
}

impl JdEngine {
    const fn new() -> Self {
        Self {
            page_size: OnceLock::new(),
            serialize: Mutex::new(()),
        }
    }

    pub fn init(&self, page_size: u8) {
        let _guard = self.serialize.lock().unwrap();
        if self.page_size.get().is_some() {
            return;
        }
        unsafe { ffi::jd_init(page_size) };
        let _ = self.page_size.set(page_size);
    }

    pub fn press_key(&self, key: u8) -> QueryResult {
        let _guard = self.serialize.lock().unwrap();
        let page_size = *self.page_size.get().expect("JdEngine not initialized");
        unsafe { copy_query_result(ffi::jd_press_key(key), page_size) }
    }

    pub fn next_page(&self) -> QueryResult {
        let _guard = self.serialize.lock().unwrap();
        let page_size = *self.page_size.get().expect("JdEngine not initialized");
        unsafe { copy_query_result(ffi::jd_next_page(), page_size) }
    }

    pub fn prev_page(&self) -> QueryResult {
        let _guard = self.serialize.lock().unwrap();
        let page_size = *self.page_size.get().expect("JdEngine not initialized");
        unsafe { copy_query_result(ffi::jd_prev_page(), page_size) }
    }

    /// Random-access page jump. Out-of-range targets (0, or beyond
    /// `total_pages`) silently no-op on the engine side — match the
    /// behavior of `next_page`/`prev_page` at the boundaries.
    pub fn jump_to_page(&self, page: u32) -> QueryResult {
        let _guard = self.serialize.lock().unwrap();
        let page_size = *self.page_size.get().expect("JdEngine not initialized");
        unsafe { copy_query_result(ffi::jd_jump_to_page(page), page_size) }
    }

    pub fn backspace(&self) -> QueryResult {
        let _guard = self.serialize.lock().unwrap();
        let page_size = *self.page_size.get().expect("JdEngine not initialized");
        unsafe { copy_query_result(ffi::jd_backspace(), page_size) }
    }

    pub fn reset(&self) {
        let _guard = self.serialize.lock().unwrap();
        unsafe { ffi::jd_reset() };
    }
}

unsafe fn copy_query_result(raw: ffi::QueryResult, page_size: u8) -> QueryResult {
    let commit = raw
        .commit
        .map(|c| unsafe { CStr::from_ptr(c.as_ptr()) }.to_string_lossy().into_owned());

    let options = match raw.options {
        None => Vec::new(),
        Some(ptr) => {
            let visible = if raw.current_page == raw.total_pages {
                let last = raw.options_count % (page_size as u32);
                if last == 0 {
                    page_size as usize
                } else {
                    last as usize
                }
            } else {
                page_size as usize
            };
            let slice = unsafe { std::slice::from_raw_parts(ptr.as_ptr(), visible) };
            slice
                .iter()
                .map(|opt| {
                    let value = unsafe { CStr::from_ptr(opt.value) }
                        .to_string_lossy()
                        .into_owned();
                    let hint = opt.hint.map(|h| {
                        unsafe { CStr::from_ptr(h.as_ptr()) }
                            .to_string_lossy()
                            .into_owned()
                    });
                    QueryOption { value, hint }
                })
                .collect()
        }
    };

    QueryResult {
        commit,
        options,
        options_count: raw.options_count,
        total_pages: raw.total_pages,
        current_page: raw.current_page,
    }
}

pub static ENGINE: JdEngine = JdEngine::new();

/// Engine page size for candidate pagination. Hard-coded as the only call
/// site is `Activate`'s `ENGINE.init(8)`. Exposed so other modules (the
/// TSF `ITfCandidateListUIElement` implementation, the candidate window,
/// future installers/configs) can reference the same number.
pub const PAGE_SIZE: u8 = 8;
