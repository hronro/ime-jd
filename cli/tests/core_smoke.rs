//! Smoke test for the libjd FFI. Bypasses the TUI so we can run it in CI /
//! headless environments — confirms that the trie blob loads, the IME init
//! works, and a couple of keystrokes produce sensible results.
//!
//! Re-declares the FFI inline rather than reaching into the bin's `core`
//! module, which isn't visible to integration tests (the bin is not a lib).

use std::ffi::CStr;
use std::os::raw::c_char;
use std::ptr::NonNull;

#[repr(C)]
struct JdContext {
    _private: [u8; 0],
}

#[repr(C)]
struct QueryOption {
    value: *const c_char,
    hint: Option<NonNull<c_char>>,
}

#[repr(C)]
struct QueryResult {
    commit: Option<NonNull<c_char>>,
    options: Option<NonNull<QueryOption>>,
    options_count: u32,
    total_pages: u32,
    current_page: u32,
}

unsafe extern "C" {
    fn jd_init(page_size: u8) -> *mut JdContext;
    fn jd_press_key(ctx: *mut JdContext, key: u8) -> QueryResult;
    fn jd_backspace(ctx: *mut JdContext) -> QueryResult;
    fn jd_deinit(ctx: *mut JdContext);
}

unsafe fn c_str(ptr: *const c_char) -> Option<String> {
    unsafe {
        if ptr.is_null() {
            None
        } else {
            Some(CStr::from_ptr(ptr).to_string_lossy().into_owned())
        }
    }
}

unsafe fn first_option(r: &QueryResult) -> Option<String> {
    unsafe {
        let opts_ptr = r.options?;
        let opt = &*opts_ptr.as_ptr();
        c_str(opt.value)
    }
}

#[test]
fn loads_blob_and_returns_options() {
    unsafe {
        let ctx = jd_init(4);
        assert!(!ctx.is_null(), "jd_init returned null");

        // Press 'b' — expect at least one candidate (the IME data has
        // many words/chars starting with 'b' in shuangpin).
        let r1 = jd_press_key(ctx, b'b');
        assert!(r1.options_count > 0, "no options for 'b'");
        let first = first_option(&r1).expect("missing first option");
        assert!(!first.is_empty(), "first option for 'b' was empty");

        // Press another key to advance — must still be non-empty.
        let r2 = jd_press_key(ctx, b'a');
        assert!(
            r2.options_count > 0 || r2.commit.is_some(),
            "no options and no commit after 'ba'"
        );

        // Backspace returns us up; should not crash.
        let _ = jd_backspace(ctx);

        jd_deinit(ctx);
    }
}
