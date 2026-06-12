use std::ffi::CStr;
use std::sync::OnceLock;

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

        pub fn jd_backspace() -> QueryResult;

        pub fn jd_reset();

        pub fn jd_deinit();
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

static PAGE_SIZE: OnceLock<u8> = OnceLock::new();

pub fn init(options: InitOptions) {
    PAGE_SIZE.set(options.page_size).unwrap();
    unsafe {
        ffi::jd_init(options.page_size);
    }
}

pub fn press_key(key: u8) -> QueryResult {
    unsafe {
        let raw_query_result = ffi::jd_press_key(key);
        QueryResult::from_raw_query_result(raw_query_result, *PAGE_SIZE.get().unwrap())
    }
}

pub fn backspace() -> QueryResult {
    unsafe {
        let raw_query_result = ffi::jd_backspace();
        QueryResult::from_raw_query_result(raw_query_result, *PAGE_SIZE.get().unwrap())
    }
}

pub fn next_page() -> QueryResult {
    unsafe {
        let raw_query_result = ffi::jd_next_page();
        QueryResult::from_raw_query_result(raw_query_result, *PAGE_SIZE.get().unwrap())
    }
}

pub fn prev_page() -> QueryResult {
    unsafe {
        let raw_query_result = ffi::jd_prev_page();
        QueryResult::from_raw_query_result(raw_query_result, *PAGE_SIZE.get().unwrap())
    }
}

pub fn deinit() {
    unsafe {
        ffi::jd_deinit();
    }
}
