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
        pub fn jd_backspace(ctx: *mut JdContext) -> QueryResult;
        #[allow(dead_code)]
        pub fn jd_reset(ctx: *mut JdContext);
        pub fn jd_deinit(ctx: *mut JdContext);
    }
}

#[derive(Debug)]
pub struct InitOptions {
    pub page_size: u8,
}

#[derive(Debug)]
pub struct QueryOption {
    pub value: &'static str,
    pub hint: Option<&'static str>,
}
impl QueryOption {
    unsafe fn from_raw_query_option(raw_query_option: &ffi::QueryOption) -> Self {
        unsafe {
            let value = CStr::from_ptr(raw_query_option.value).to_str().unwrap();
            let hint = raw_query_option
                .hint
                .map(|hint| CStr::from_ptr(hint.as_ptr()).to_str().unwrap());

            Self { value, hint }
        }
    }
}

#[allow(dead_code)]
#[derive(Debug)]
pub struct QueryResult {
    pub commit: Option<&'static str>,
    pub options: Option<Vec<QueryOption>>,
    pub options_count: u32,
    pub total_pages: u32,
    pub current_page: u32,
}
impl QueryResult {
    unsafe fn from_raw_query_result(raw_query_result: ffi::QueryResult, page_size: u8) -> Self {
        unsafe {
            let raw_options = raw_query_result.options.map(|raw_options_ptr| {
                if raw_query_result.current_page == raw_query_result.total_pages {
                    let last_page_size = raw_query_result.options_count % (page_size as u32);
                    let last_page_size = if last_page_size == 0 {
                        page_size as usize
                    } else {
                        last_page_size as usize
                    };

                    std::slice::from_raw_parts(raw_options_ptr.as_ptr(), last_page_size)
                } else {
                    std::slice::from_raw_parts(raw_options_ptr.as_ptr(), page_size as usize)
                }
            });

            let options = raw_options.map(|ros| {
                ros.iter()
                    .map(|raw_option| QueryOption::from_raw_query_option(raw_option))
                    .collect()
            });

            Self {
                commit: raw_query_result
                    .commit
                    .map(|commit| CStr::from_ptr(commit.as_ptr()).to_str().unwrap()),
                options,
                options_count: raw_query_result.options_count,
                total_pages: raw_query_result.total_pages,
                current_page: raw_query_result.current_page,
            }
        }
    }

    #[allow(dead_code)]
    pub fn has_no_options(&self) -> bool {
        self.options_count == 0
    }
}

pub struct JdContext {
    handle: NonNull<ffi::JdContext>,
    page_size: u8,
}

impl JdContext {
    pub fn new(options: InitOptions) -> Self {
        let raw = unsafe { ffi::jd_init(options.page_size) };
        let handle = NonNull::new(raw).expect("jd_init returned null");
        Self {
            handle,
            page_size: options.page_size,
        }
    }

    pub fn press_key(&mut self, key: u8) -> QueryResult {
        unsafe {
            let raw = ffi::jd_press_key(self.handle.as_ptr(), key);
            QueryResult::from_raw_query_result(raw, self.page_size)
        }
    }

    pub fn next_page(&mut self) -> QueryResult {
        unsafe {
            let raw = ffi::jd_next_page(self.handle.as_ptr());
            QueryResult::from_raw_query_result(raw, self.page_size)
        }
    }

    pub fn prev_page(&mut self) -> QueryResult {
        unsafe {
            let raw = ffi::jd_prev_page(self.handle.as_ptr());
            QueryResult::from_raw_query_result(raw, self.page_size)
        }
    }

    pub fn backspace(&mut self) -> QueryResult {
        unsafe {
            let raw = ffi::jd_backspace(self.handle.as_ptr());
            QueryResult::from_raw_query_result(raw, self.page_size)
        }
    }

    #[allow(dead_code)]
    pub fn reset(&mut self) {
        unsafe { ffi::jd_reset(self.handle.as_ptr()) }
    }
}

impl Drop for JdContext {
    fn drop(&mut self) {
        unsafe { ffi::jd_deinit(self.handle.as_ptr()) }
    }
}
