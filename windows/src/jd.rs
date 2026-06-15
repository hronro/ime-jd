use std::cell::RefCell;
use std::ffi::CStr;
use std::ptr::NonNull;

mod ffi {
    use std::os::raw::c_char;
    use std::ptr::NonNull;

    #[repr(C)]
    pub struct JdContext {
        _private: [u8; 0],
    }

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

    unsafe extern "C" {
        pub fn jd_init(page_size: u8) -> *mut JdContext;
        pub fn jd_press_key(ctx: *mut JdContext, key: u8) -> QueryResult;
        pub fn jd_next_page(ctx: *mut JdContext) -> QueryResult;
        pub fn jd_prev_page(ctx: *mut JdContext) -> QueryResult;
        pub fn jd_jump_to_page(ctx: *mut JdContext, page: u32) -> QueryResult;
        pub fn jd_backspace(ctx: *mut JdContext) -> QueryResult;
        pub fn jd_reset(ctx: *mut JdContext);
        pub fn jd_deinit(ctx: *mut JdContext);
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

/// Engine page size. The TIP creates every context with this value at
/// `Activate` time; the UIElement implementation references it to compute
/// page boundaries.
pub const PAGE_SIZE: u8 = 8;

/// RAII wrapper around the core's opaque `*mut jd_context`. `Drop` calls
/// `jd_deinit`, so leaving a `JdContext` is the same as never having
/// created one — useful in tests and matches the `cli` port's shape.
pub struct JdContext {
    handle: NonNull<ffi::JdContext>,
    page_size: u8,
}

impl JdContext {
    pub fn new(page_size: u8) -> Self {
        let raw = unsafe { ffi::jd_init(page_size) };
        let handle = NonNull::new(raw).expect("jd_init returned null");
        Self { handle, page_size }
    }

    pub fn press_key(&mut self, key: u8) -> QueryResult {
        unsafe { copy_query_result(ffi::jd_press_key(self.handle.as_ptr(), key), self.page_size) }
    }

    pub fn next_page(&mut self) -> QueryResult {
        unsafe { copy_query_result(ffi::jd_next_page(self.handle.as_ptr()), self.page_size) }
    }

    pub fn prev_page(&mut self) -> QueryResult {
        unsafe { copy_query_result(ffi::jd_prev_page(self.handle.as_ptr()), self.page_size) }
    }

    pub fn jump_to_page(&mut self, page: u32) -> QueryResult {
        unsafe {
            copy_query_result(
                ffi::jd_jump_to_page(self.handle.as_ptr(), page),
                self.page_size,
            )
        }
    }

    pub fn backspace(&mut self) -> QueryResult {
        unsafe { copy_query_result(ffi::jd_backspace(self.handle.as_ptr()), self.page_size) }
    }

    pub fn reset(&mut self) {
        unsafe { ffi::jd_reset(self.handle.as_ptr()) }
    }
}

impl Drop for JdContext {
    fn drop(&mut self) {
        unsafe { ffi::jd_deinit(self.handle.as_ptr()) }
    }
}

unsafe fn copy_query_result(raw: ffi::QueryResult, page_size: u8) -> QueryResult {
    let commit = raw.commit.map(|c| {
        unsafe { CStr::from_ptr(c.as_ptr()) }
            .to_string_lossy()
            .into_owned()
    });

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

// ---- UI-thread-local engine handle ---------------------------------------
//
// The TIP runs on a single UI thread per host process; every code path that
// touches the engine (key-event sink, composition sink, candidate window
// wnd_proc, UIElement COM callbacks) is dispatched there. Holding the
// context in a thread_local matches the codebase's existing per-thread
// state (composition::STATE, candidate_window::WINDOW, ui_element::ELEMENT)
// and lets the call sites stay as plain `jd::press_key(b)` calls.

thread_local! {
    static CTX: RefCell<Option<JdContext>> = const { RefCell::new(None) };
}

/// Create the per-thread context. Called from `ITfTextInputProcessor::Activate`.
/// Idempotent — repeated Activate without an intervening Deactivate is a
/// no-op.
pub fn activate() {
    CTX.with(|c| {
        let mut c = c.borrow_mut();
        if c.is_none() {
            *c = Some(JdContext::new(PAGE_SIZE));
        }
    });
}

/// Drop the per-thread context. Called from `ITfTextInputProcessor::Deactivate`.
/// The `Drop` impl on `JdContext` calls `jd_deinit`.
pub fn deactivate() {
    CTX.with(|c| *c.borrow_mut() = None);
}

fn with_ctx<R>(f: impl FnOnce(&mut JdContext) -> R) -> R {
    CTX.with(|c| {
        f(c.borrow_mut()
            .as_mut()
            .expect("engine not activated — Activate must precede engine calls"))
    })
}

pub fn press_key(key: u8) -> QueryResult {
    with_ctx(|c| c.press_key(key))
}

pub fn next_page() -> QueryResult {
    with_ctx(|c| c.next_page())
}

pub fn prev_page() -> QueryResult {
    with_ctx(|c| c.prev_page())
}

pub fn jump_to_page(page: u32) -> QueryResult {
    with_ctx(|c| c.jump_to_page(page))
}

pub fn backspace() -> QueryResult {
    with_ctx(|c| c.backspace())
}

pub fn reset() {
    with_ctx(|c| c.reset())
}
