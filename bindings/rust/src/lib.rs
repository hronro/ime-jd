//! Safe Rust bindings for libjd, the 键道 input-method core engine.
//!
//! The C API (`core/include/jd.h`) returns borrowed pointers that are valid
//! only until the next `jd_*` call on the same context. This crate never
//! exposes them: every result is copied into owned `String`s before a
//! wrapper method returns, so a [`QueryResult`] may be retained across
//! later engine calls, sent between threads, etc.
//!
//! One [`JdContext`] must not be used from multiple threads concurrently
//! (the C contract); taking `&mut self` on every method enforces that
//! statically. Distinct contexts are fully independent.

use std::ffi::CStr;
use std::fmt;
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

/// One candidate: the committed text plus an optional remaining-keys hint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueryOption {
    pub value: String,
    pub hint: Option<String>,
}

/// Owned snapshot of one engine result. See `core/include/jd.h` for the
/// four state shapes (candidates / committed / committed-and-drilled-in /
/// empty); `options` holds the *current page* only, while `options_count`
/// is the total across all pages.
#[derive(Debug, Clone, Default)]
pub struct QueryResult {
    pub commit: Option<String>,
    pub options: Vec<QueryOption>,
    pub options_count: u32,
    pub total_pages: u32,
    pub current_page: u32,
}

/// `jd_init` failed — the engine couldn't allocate its per-context buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InitError;

impl fmt::Display for InitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("jd_init failed (allocation failure)")
    }
}

impl std::error::Error for InitError {}

/// RAII wrapper around the core's opaque `*mut jd_context`; `Drop` calls
/// `jd_deinit`. Every method deep-copies the engine's borrowed result
/// before returning — see the crate docs.
pub struct JdContext {
    handle: NonNull<ffi::JdContext>,
    page_size: u8,
}

impl JdContext {
    pub fn new(page_size: u8) -> Result<Self, InitError> {
        let raw = unsafe { ffi::jd_init(page_size) };
        NonNull::new(raw)
            .map(|handle| Self { handle, page_size })
            .ok_or(InitError)
    }

    pub fn page_size(&self) -> u8 {
        self.page_size
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

/// Number of options materialized in the current page's `options` array.
///
/// The C API's `options_count` is the total across all pages; the visible
/// array length must be derived (see "Reading `query_result`" in
/// core/docs/integration.md): every non-last page is exactly `page_size`
/// long, and the last page holds the remainder. Returns 0 for the empty /
/// committed shapes (`options_count == 0`) and for a degenerate
/// `page_size` of 0.
pub fn visible_count(options_count: u32, current_page: u32, total_pages: u32, page_size: u8) -> usize {
    if options_count == 0 || page_size == 0 {
        return 0;
    }
    if current_page == total_pages {
        match options_count % page_size as u32 {
            0 => page_size as usize,
            last => last as usize,
        }
    } else {
        page_size as usize
    }
}

unsafe fn copy_query_result(raw: ffi::QueryResult, page_size: u8) -> QueryResult {
    let commit = raw.commit.map(|c| {
        unsafe { CStr::from_ptr(c.as_ptr()) }
            .to_string_lossy()
            .into_owned()
    });

    let visible = visible_count(
        raw.options_count,
        raw.current_page,
        raw.total_pages,
        page_size,
    );
    let options = match raw.options {
        // `visible == 0` guards the `options_count == 0` shapes so a stray
        // non-null pointer can never make us over-read.
        None => Vec::new(),
        Some(_) if visible == 0 => Vec::new(),
        Some(ptr) => {
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

#[cfg(test)]
mod tests {
    use super::visible_count;

    #[test]
    fn visible_count_covers_all_page_shapes() {
        // Partial last page.
        assert_eq!(visible_count(11, 3, 3, 4), 3);
        // Exact-multiple last page.
        assert_eq!(visible_count(8, 2, 2, 4), 4);
        // Non-last page is always full.
        assert_eq!(visible_count(11, 1, 3, 4), 4);
        // Single page smaller than page_size.
        assert_eq!(visible_count(2, 1, 1, 4), 2);
        // Empty / committed shapes.
        assert_eq!(visible_count(0, 0, 0, 4), 0);
        // Degenerate page size must not divide by zero.
        assert_eq!(visible_count(5, 1, 1, 0), 0);
    }
}
