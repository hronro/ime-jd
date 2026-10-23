//! Safe Rust bindings for libjd, the 键道 input-method core engine.
//!
//! Unlike a typical FFI wrapper, this one does not copy anything defensively,
//! because the C ABI has no borrowed data to protect against: a candidate's
//! `value` and a commit's segments all point into a dictionary blob that
//! outlives every context — the library's embedded dictionary, read-only
//! data that lives for the whole process, or a [`UserDict`] the context was
//! created with, which this crate only accepts as `&'static` — and a
//! candidate's `hint` is inline bytes. That makes [`Candidate`] `Copy` and
//! its strings `&'static str`, so candidate lists can be kept, moved between
//! threads, and rendered lazily with no allocation.
//!
//! A user dictionary is built once from `value<TAB>keys` text with
//! [`UserDict::build`], cached as bytes ([`UserDict::as_bytes`]) and wrapped
//! again on the next launch — copied with [`UserDict::from_blob`], or, faster,
//! memory-mapped and handed over in place with [`UserDict::from_static_blob`]
//! — so no text is parsed on a hot path. A `source_tag` of your choosing
//! travels in the blob ([`UserDict::source_tag`], peekable with
//! [`UserDict::check`]), so you can tell whether a cached blob still matches
//! your phrases. Hand it to [`JdContext::with_user_dict`]; the engine merges
//! its phrases into every candidate list, user phrases first on a shared
//! code.
//!
//! Candidates are addressed by flat index, not by page. Read a window with
//! [`JdContext::read_range`] (into your own buffer) or
//! [`JdContext::extend_candidates`] (appending onto a `Vec`, the natural shape
//! for a candidate strip). Reads are pure: they never change what the engine's
//! automatic commits resolve to, so you can prefetch as far ahead as you like.
//! Tell the engine what the user is actually looking at with
//! [`JdContext::set_anchor`].
//!
//! One [`JdContext`] must not be used from multiple threads concurrently
//! (the C contract); taking `&mut self` on every method enforces that
//! statically. Distinct contexts are fully independent.

use std::ffi::{CStr, c_char, c_void};
use std::fmt;
use std::ptr::{self, NonNull};
use std::sync::Once;

/// Inline hint capacity, including the NUL terminator. Mirrors `JD_HINT_CAP`
/// in `core/include/jd.h`; verified against the library at startup.
pub const HINT_CAP: usize = 8;

/// One candidate: the committable text plus an optional hint listing the keys
/// still needed to reach it.
///
/// Cheap to copy and free to keep — see the crate docs for why nothing here
/// can dangle. Obtain these from [`JdContext::read_range`] and friends.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Candidate {
    /// Always either null (a default-constructed placeholder) or a pointer
    /// into a dictionary blob that lives for the rest of the process.
    value: *const c_char,
    /// NUL-terminated; `hint[0] == 0` means no hint.
    hint: [u8; HINT_CAP],
}

// SAFETY: the only pointer is into a read-only, process-lifetime dictionary
// blob (embedded, or a `&'static UserDict`). Nothing is owned and nothing is
// mutated, so a candidate can cross threads freely.
unsafe impl Send for Candidate {}
unsafe impl Sync for Candidate {}

impl Default for Candidate {
    fn default() -> Self {
        Self {
            value: ptr::null(),
            hint: [0; HINT_CAP],
        }
    }
}

impl Candidate {
    /// The committable text as raw bytes. Empty for a placeholder that no
    /// read has filled in yet.
    pub fn value_bytes(&self) -> &'static [u8] {
        if self.value.is_null() {
            return &[];
        }
        // SAFETY: non-null blob pointers from the engine are always
        // NUL-terminated, and the blob lives for the rest of the process
        // (embedded data, or a `&'static UserDict`).
        unsafe { CStr::from_ptr(self.value) }.to_bytes()
    }

    /// The committable text. Dictionary values are UTF-8 by construction (the
    /// build-time generator reads UTF-8 source tables, and the user-dictionary
    /// builder validates its input), so this only fails on a corrupt library,
    /// in which case it yields `""`.
    pub fn value(&self) -> &'static str {
        std::str::from_utf8(self.value_bytes()).unwrap_or("")
    }

    /// Keys still needed below this candidate, or `None` when it is complete.
    /// Borrowed from the inline bytes, so it lives as long as `self`.
    pub fn hint(&self) -> Option<&str> {
        if self.hint[0] == 0 {
            return None;
        }
        let end = self.hint.iter().position(|&b| b == 0).unwrap_or(HINT_CAP);
        std::str::from_utf8(&self.hint[..end]).ok()
    }
}

impl fmt::Debug for Candidate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Candidate")
            .field("value", &self.value())
            .field("hint", &self.hint())
            .finish()
    }
}

impl PartialEq for Candidate {
    fn eq(&self, other: &Self) -> bool {
        self.value_bytes() == other.value_bytes() && self.hint == other.hint
    }
}

impl Eq for Candidate {}

/// A commit, delivered as up to three pieces so the library needs no buffer of
/// its own: two immortal strings and one literal byte, concatenated in field
/// order. Use the [`fmt::Display`] impl to join them — `write!` straight into
/// an existing buffer to stay allocation-free, or `.to_string()` when you need
/// an owned `String`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Commit {
    pub a: Option<&'static str>,
    pub b: Option<&'static str>,
    pub lit: Option<u8>,
}

impl Commit {
    /// Joined length in bytes.
    pub fn len(&self) -> usize {
        self.a.map_or(0, str::len) + self.b.map_or(0, str::len) + usize::from(self.lit.is_some())
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl fmt::Display for Commit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(a) = self.a {
            f.write_str(a)?;
        }
        if let Some(b) = self.b {
            f.write_str(b)?;
        }
        if let Some(lit) = self.lit {
            f.write_str(std::str::from_utf8(&[lit]).unwrap_or(""))?;
        }
        Ok(())
    }
}

/// What the engine currently holds. Read it after any mutating call.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct State {
    /// Total candidates for the in-flight composition; 0 when none.
    pub options_count: u32,
    /// Flat index the engine's automatic commits resolve against — space and
    /// the literal-byte fallbacks take this one, `;` takes the next.
    pub anchor_index: u32,
}

/// `jd_init` failed — the engine couldn't allocate its per-context buffer.
/// (A [`UserDict`] is validated when it is constructed, so a rejected blob
/// never gets this far.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InitError;

impl fmt::Display for InitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("jd_init failed (allocation failure)")
    }
}

impl std::error::Error for InitError {}

/// Why a user dictionary could not be built or accepted. Mirrors the
/// `JD_USER_DICT_*` codes in `core/include/jd.h`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserDictStatus {
    /// The output buffer was smaller than the bound (a bug in this crate).
    BufferTooSmall,
    /// More than [`UserDict::MAX_ENTRIES`] phrases.
    TooManyEntries,
    /// A non-comment line without a TAB.
    MalformedLine,
    /// Keys empty, longer than six, or outside `a`-`z` and `;`.
    BadKeys,
    /// Value empty, longer than [`UserDict::VALUE_MAX`] bytes, or containing
    /// control characters.
    BadValue,
    /// The blob was built by another libjd (format or built-in dictionary
    /// differ): rebuild it from the phrases.
    Stale,
    /// The blob is structurally invalid: rebuild it from the phrases.
    Corrupt,
    /// The blob pointer was not 4-byte aligned (a bug in this crate).
    Misaligned,
    /// The text exceeds the library's input cap.
    TextTooLong,
    /// A status this crate does not know (a newer library).
    Unknown(u32),
}

impl UserDictStatus {
    fn from_code(code: u32) -> Self {
        match code {
            1 => Self::BufferTooSmall,
            2 => Self::TooManyEntries,
            3 => Self::MalformedLine,
            4 => Self::BadKeys,
            5 => Self::BadValue,
            6 => Self::Stale,
            7 => Self::Corrupt,
            8 => Self::Misaligned,
            9 => Self::TextTooLong,
            other => Self::Unknown(other),
        }
    }

    /// Whether the problem is in the input text (and `line` points at it)
    /// rather than in a cached blob or the call itself.
    pub fn is_line_error(self) -> bool {
        matches!(
            self,
            Self::TooManyEntries | Self::MalformedLine | Self::BadKeys | Self::BadValue
        )
    }
}

impl fmt::Display for UserDictStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BufferTooSmall => f.write_str("output buffer too small"),
            Self::TooManyEntries => write!(f, "more than {} phrases", UserDict::MAX_ENTRIES),
            Self::MalformedLine => f.write_str("expected `value<TAB>keys`"),
            Self::BadKeys => f.write_str("keys must be 1 to 6 characters from a-z and `;`"),
            Self::BadValue => write!(
                f,
                "value must be 1 to {} bytes of text without control characters",
                UserDict::VALUE_MAX
            ),
            Self::Stale => {
                f.write_str("blob was built against a different dictionary (rebuild it)")
            }
            Self::Corrupt => f.write_str("blob is corrupt (rebuild it)"),
            Self::Misaligned => f.write_str("blob is not 4-byte aligned"),
            Self::TextTooLong => f.write_str("text is too long"),
            Self::Unknown(code) => write!(f, "unknown status {code}"),
        }
    }
}

/// A rejected user dictionary: the status plus, for problems in the input
/// text, the 1-based line it refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UserDictError {
    pub status: UserDictStatus,
    /// 1-based input line for [`UserDictStatus::is_line_error`] statuses,
    /// otherwise 0.
    pub line: u32,
}

impl fmt::Display for UserDictError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.status.is_line_error() {
            write!(f, "line {}: {}", self.line, self.status)
        } else {
            fmt::Display::fmt(&self.status, f)
        }
    }
}

impl std::error::Error for UserDictError {}

/// What a blob says about itself: the tag it was built with and how many
/// phrases it holds. From [`UserDict::check`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct UserDictInfo {
    pub source_tag: u64,
    pub entries: u32,
}

/// What [`UserDict::build`] did with the input.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct UserDictReport {
    /// Phrases that made it into the dictionary.
    pub entries: u32,
    /// Phrases dropped as exact duplicates — of an earlier line with the same
    /// keys and value, or of a built-in word on the same code.
    pub dropped: u32,
    /// The 1-based input lines of every dropped phrase, ascending.
    pub dropped_lines: Vec<u32>,
}

/// A user dictionary: phrases compiled into the blob the engine reads in
/// place. Build it from text once, cache [`Self::as_bytes`], and wrap the
/// cached bytes on later launches — [`Self::from_blob`] copies them into
/// aligned storage; [`Self::from_static_blob`] takes memory you keep alive
/// for the rest of the process, such as a leaked memory map of the cache
/// file, with no copy at all. The [`Self::source_tag`] you gave `build` comes
/// back from the cached blob ([`Self::check`] reads it without taking the
/// blob over), so comparing it against the phrases' current tag tells you
/// whether to rebuild.
///
/// A memory-mapped cache file is the ideal blob: page-aligned, at a fixed
/// address, read without copying, and shared with every other process that
/// maps the same file. Map the text file too when rebuilding; the builder
/// only reads it.
///
/// The blob is tied to the build of libjd it was made with (the format, and
/// the built-in dictionary it was deduplicated against). After updating the
/// library, `from_blob` reports [`UserDictStatus::Stale`]; rebuild from the
/// phrases you persisted.
///
/// A context reads its dictionary in place for its whole lifetime, and
/// candidates keep pointing into it afterwards, which is why
/// [`JdContext::with_user_dict`] takes `&'static UserDict`: leak the
/// dictionary ([`Self::leak`]) or keep it in a `static`. Changing
/// dictionaries means creating a new context with the new one.
pub struct UserDict {
    blob: Blob,
    entries: u32,
    source_tag: u64,
}

/// The blob's backing memory: this crate's own aligned storage, or a
/// `'static` slice the host owns and keeps alive, such as a leaked memory
/// map of the cache file.
enum Blob {
    Owned {
        /// 4-byte-aligned, as the engine requires.
        storage: Vec<u32>,
        /// Blob length in bytes; the storage may be a little longer.
        len: usize,
    },
    Static(&'static [u8]),
}

impl Blob {
    fn bytes(&self) -> &[u8] {
        match self {
            // SAFETY: the storage holds at least `len` initialized bytes.
            Blob::Owned { storage, len } => unsafe {
                std::slice::from_raw_parts(storage.as_ptr().cast::<u8>(), *len)
            },
            Blob::Static(bytes) => bytes,
        }
    }
}

/// Copy `bytes` into 4-byte-aligned storage.
fn aligned_copy(bytes: &[u8]) -> Vec<u32> {
    let mut storage = vec![0u32; bytes.len().div_ceil(4)];
    // SAFETY: the destination holds at least `bytes.len()` bytes.
    unsafe {
        ptr::copy_nonoverlapping(
            bytes.as_ptr(),
            storage.as_mut_ptr().cast::<u8>(),
            bytes.len(),
        );
    }
    storage
}

/// `jd_user_dict_check` on `bytes` exactly where they are.
fn check_in_place(bytes: &[u8]) -> Result<UserDictInfo, UserDictError> {
    check_abi();
    let mut info = ffi::JdUserDictInfo::default();
    // SAFETY: the pointer and length describe live memory.
    let status = unsafe { ffi::jd_user_dict_check(bytes.as_ptr().cast(), bytes.len(), &mut info) };
    if status != 0 {
        return Err(UserDictError {
            status: UserDictStatus::from_code(status),
            line: 0,
        });
    }
    Ok(UserDictInfo {
        source_tag: info.source_tag,
        entries: info.entries,
    })
}

impl UserDict {
    /// Most phrases one dictionary may hold (`JD_USER_DICT_MAX_ENTRIES`).
    pub const MAX_ENTRIES: u32 = 10_000;
    /// Longest phrase value in bytes (`JD_USER_DICT_VALUE_MAX`).
    pub const VALUE_MAX: u32 = 255;

    /// Build from lines of `value<TAB>keys` — the format of libjd's own
    /// table files. `#` starts a comment line, blank lines are skipped,
    /// spaces around either field are trimmed, CRLF is accepted. Keys are
    /// one to six characters from `a`-`z` and `;`; values are UTF-8 without
    /// control characters. Exact duplicates, of an earlier line or of a
    /// built-in word on the same code, are dropped, counted, and listed by
    /// line in the report.
    ///
    /// `source_tag` is stored in the blob, uninterpreted: a modification
    /// time, a content hash, a revision — whatever identifies the phrases
    /// this dictionary was built from.
    pub fn build(phrases: &str, source_tag: u64) -> Result<(Self, UserDictReport), UserDictError> {
        check_abi();
        let text = phrases.as_bytes();
        let bound = unsafe { ffi::jd_user_dict_blob_bound(text.as_ptr().cast(), text.len()) };
        let mut storage = vec![0u32; bound.div_ceil(4)];
        let mut len: usize = 0;
        let mut report = ffi::JdUserDictReport::default();
        // One slot per input line is enough to receive every dropped line.
        let line_count = text.iter().filter(|&&b| b == b'\n').count() + 1;
        let mut dropped_lines = vec![0u32; line_count];
        // SAFETY: every pointer is to live memory of the stated length, and
        // the output buffer is 4-byte aligned (a Vec<u32>) and at least the
        // bound long.
        let status = unsafe {
            ffi::jd_user_dict_build(
                text.as_ptr().cast(),
                text.len(),
                source_tag,
                storage.as_mut_ptr().cast(),
                storage.len() * 4,
                &mut len,
                &mut report,
                dropped_lines.as_mut_ptr(),
                dropped_lines.len().try_into().unwrap_or(u32::MAX),
            )
        };
        if status != 0 {
            return Err(UserDictError {
                status: UserDictStatus::from_code(status),
                line: report.line,
            });
        }
        storage.truncate(len.div_ceil(4));
        dropped_lines.truncate(report.dropped as usize);
        Ok((
            Self {
                blob: Blob::Owned { storage, len },
                entries: report.entries,
                source_tag,
            },
            UserDictReport {
                entries: report.entries,
                dropped: report.dropped,
                dropped_lines,
            },
        ))
    }

    /// Wrap a blob cached from an earlier [`Self::as_bytes`]. The bytes are
    /// copied into aligned storage and validated exactly as `jd_init` would;
    /// a [`UserDictStatus::Stale`] or [`UserDictStatus::Corrupt`] result
    /// means "rebuild from the phrases".
    pub fn from_blob(bytes: &[u8]) -> Result<Self, UserDictError> {
        let storage = aligned_copy(bytes);
        let blob = Blob::Owned {
            storage,
            len: bytes.len(),
        };
        let info = check_in_place(blob.bytes())?;
        Ok(Self {
            blob,
            entries: info.entries,
            source_tag: info.source_tag,
        })
    }

    /// Wrap a cached blob without copying it. `bytes` is memory you keep
    /// alive for the rest of the process — typically a memory map of the
    /// cache file that you leak (`Box::leak`) once you have decided to use
    /// it. The engine reads it in place, so it must be 4-byte aligned (a file
    /// mapping is page-aligned) and must never move or change; a misaligned
    /// slice fails with [`UserDictStatus::Misaligned`]. Validated exactly as
    /// `jd_init` would.
    pub fn from_static_blob(bytes: &'static [u8]) -> Result<Self, UserDictError> {
        let info = check_in_place(bytes)?;
        Ok(Self {
            blob: Blob::Static(bytes),
            entries: info.entries,
            source_tag: info.source_tag,
        })
    }

    /// Validate a cached blob and read its tag and phrase count without
    /// taking it over — the way to decide between [`Self::from_static_blob`]
    /// and a rebuild before committing to a memory map. Works on any slice;
    /// a misaligned one is checked through a temporary aligned copy.
    pub fn check(bytes: &[u8]) -> Result<UserDictInfo, UserDictError> {
        if bytes.as_ptr().addr().is_multiple_of(4) {
            check_in_place(bytes)
        } else {
            let storage = aligned_copy(bytes);
            let blob = Blob::Owned {
                storage,
                len: bytes.len(),
            };
            check_in_place(blob.bytes())
        }
    }

    /// How many phrases the dictionary holds.
    pub fn entries(&self) -> u32 {
        self.entries
    }

    /// The tag [`Self::build`] was given — read back from the blob, so it
    /// survives a round trip through the cache.
    pub fn source_tag(&self) -> u64 {
        self.source_tag
    }

    /// The blob — exactly the bytes to cache.
    pub fn as_bytes(&self) -> &[u8] {
        self.blob.bytes()
    }

    /// Give the dictionary the `'static` lifetime [`JdContext::with_user_dict`]
    /// needs, at the cost of never freeing it. Fine for a process that loads
    /// one dictionary (a CLI, or a frontend that reloads rarely).
    pub fn leak(self) -> &'static UserDict {
        Box::leak(Box::new(self))
    }
}

impl fmt::Debug for UserDict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UserDict")
            .field("entries", &self.entries)
            .field("source_tag", &self.source_tag)
            .field("len", &self.blob.bytes().len())
            .finish()
    }
}

mod ffi {
    use std::ffi::{c_char, c_void};

    #[repr(C)]
    pub struct JdContext {
        _private: [u8; 0],
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct JdState {
        pub commit_a: *const c_char,
        pub commit_b: *const c_char,
        pub commit_lit: u8,
        pub options_count: u32,
        pub anchor_index: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct JdUserDictReport {
        pub status: u32,
        pub line: u32,
        pub entries: u32,
        pub dropped: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct JdUserDictInfo {
        pub source_tag: u64,
        pub entries: u32,
    }

    unsafe extern "C" {
        pub fn jd_init(user_dict: *const c_void, user_dict_len: usize) -> *mut JdContext;
        pub fn jd_deinit(ctx: *mut JdContext);
        pub fn jd_press_key(ctx: *mut JdContext, key: u8);
        pub fn jd_backspace(ctx: *mut JdContext);
        pub fn jd_reset(ctx: *mut JdContext);
        pub fn jd_set_anchor(ctx: *mut JdContext, index: u32);
        pub fn jd_state_ptr(ctx: *mut JdContext) -> *const JdState;
        pub fn jd_read_range(
            ctx: *mut JdContext,
            start: u32,
            count: u32,
            out: *mut super::Candidate,
            out_cap: u32,
        ) -> u32;
        pub fn jd_abi_layout(what: u32) -> u32;
        pub fn jd_user_dict_blob_bound(phrases: *const c_char, phrases_len: usize) -> usize;
        pub fn jd_user_dict_build(
            phrases: *const c_char,
            phrases_len: usize,
            source_tag: u64,
            blob: *mut c_void,
            blob_cap: usize,
            blob_len: *mut usize,
            report: *mut JdUserDictReport,
            dropped_lines: *mut u32,
            dropped_cap: u32,
        ) -> u32;
        pub fn jd_user_dict_check(
            blob: *const c_void,
            blob_len: usize,
            info: *mut JdUserDictInfo,
        ) -> u32;
    }
}

const JD_ABI_SIZEOF_STATE: u32 = 0;
const JD_ABI_SIZEOF_OPTION: u32 = 1;
const JD_ABI_HINT_CAP: u32 = 2;
const JD_ABI_SIZEOF_USER_DICT_REPORT: u32 = 5;
const JD_ABI_USER_DICT_MAX_ENTRIES: u32 = 6;
const JD_ABI_USER_DICT_VALUE_MAX: u32 = 7;
const JD_ABI_SIZEOF_USER_DICT_INFO: u32 = 8;

static ABI_CHECK: Once = Once::new();

/// Guards against this crate's hand-written `#[repr(C)]` declarations drifting
/// from the compiled library — a mismatch would silently corrupt memory, so it
/// is worth one comparison per process.
fn check_abi() {
    ABI_CHECK.call_once(|| {
        let (state, option, hint, report, max_entries, value_max, info) = unsafe {
            (
                ffi::jd_abi_layout(JD_ABI_SIZEOF_STATE) as usize,
                ffi::jd_abi_layout(JD_ABI_SIZEOF_OPTION) as usize,
                ffi::jd_abi_layout(JD_ABI_HINT_CAP) as usize,
                ffi::jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_REPORT) as usize,
                ffi::jd_abi_layout(JD_ABI_USER_DICT_MAX_ENTRIES),
                ffi::jd_abi_layout(JD_ABI_USER_DICT_VALUE_MAX),
                ffi::jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_INFO) as usize,
            )
        };
        assert_eq!(
            state,
            size_of::<ffi::JdState>(),
            "libjd jd_state layout mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            option,
            size_of::<Candidate>(),
            "libjd query_option layout mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            hint, HINT_CAP,
            "libjd hint capacity mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            report,
            size_of::<ffi::JdUserDictReport>(),
            "libjd jd_user_dict_report layout mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            max_entries,
            UserDict::MAX_ENTRIES,
            "libjd user dictionary entry cap mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            value_max,
            UserDict::VALUE_MAX,
            "libjd user dictionary value cap mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            info,
            size_of::<ffi::JdUserDictInfo>(),
            "libjd jd_user_dict_info layout mismatch — bindings/rust is out of sync with core"
        );
    });
}

/// RAII wrapper around the core's opaque `*mut jd_context`; `Drop` calls
/// `jd_deinit`.
pub struct JdContext {
    handle: NonNull<ffi::JdContext>,
    /// `jd_state_ptr` is stable for the context's lifetime, so it's read once.
    state: NonNull<ffi::JdState>,
}

impl JdContext {
    /// A context over the built-in dictionary alone.
    pub fn new() -> Result<Self, InitError> {
        Self::init(None)
    }

    /// A context over the built-in dictionary plus `dict`. The engine reads
    /// the dictionary in place for the context's lifetime and candidates
    /// keep pointing into it, hence `'static` — see [`UserDict::leak`].
    pub fn with_user_dict(dict: &'static UserDict) -> Result<Self, InitError> {
        Self::init(Some(dict))
    }

    fn init(dict: Option<&'static UserDict>) -> Result<Self, InitError> {
        check_abi();
        let (blob, len) = match dict {
            Some(d) => {
                let bytes = d.blob.bytes();
                (bytes.as_ptr().cast::<c_void>(), bytes.len())
            }
            None => (ptr::null(), 0),
        };
        // SAFETY: the blob, if any, is aligned, validated at construction,
        // and lives for the rest of the process.
        let raw = unsafe { ffi::jd_init(blob, len) };
        let handle = NonNull::new(raw).ok_or(InitError)?;
        let state = NonNull::new(unsafe { ffi::jd_state_ptr(raw) }.cast_mut()).ok_or(InitError)?;
        Ok(Self { handle, state })
    }

    // ---- mutating operations -------------------------------------------

    /// Feed one keystroke. Read the outcome with [`Self::state`] and
    /// [`Self::commit`].
    pub fn press_key(&mut self, key: u8) {
        unsafe { ffi::jd_press_key(self.handle.as_ptr(), key) }
    }

    /// Undo the most recent trie descent, or close a punctuation window.
    /// Never produces a commit.
    pub fn backspace(&mut self) {
        unsafe { ffi::jd_backspace(self.handle.as_ptr()) }
    }

    /// Drop the in-flight composition and any recorded commit.
    pub fn reset(&mut self) {
        unsafe { ffi::jd_reset(self.handle.as_ptr()) }
    }

    /// Point the anchor at candidate `index`, so the engine's automatic
    /// commits follow what the user is looking at. Out-of-range indices are
    /// silently ignored.
    pub fn set_anchor(&mut self, index: u32) {
        unsafe { ffi::jd_set_anchor(self.handle.as_ptr(), index) }
    }

    // ---- reads ---------------------------------------------------------

    fn raw_state(&self) -> &ffi::JdState {
        // SAFETY: the pointer was obtained from jd_state_ptr on a live
        // context and is valid for that context's whole lifetime.
        unsafe { self.state.as_ref() }
    }

    pub fn state(&self) -> State {
        let s = self.raw_state();
        State {
            options_count: s.options_count,
            anchor_index: s.anchor_index,
        }
    }

    /// The commit produced by the last operation, if any.
    pub fn commit(&self) -> Option<Commit> {
        let s = self.raw_state();
        let seg = |p: *const c_char| -> Option<&'static str> {
            if p.is_null() {
                None
            } else {
                // SAFETY: non-null commit segments point into a dictionary
                // blob, NUL-terminated and alive for the rest of the process.
                std::str::from_utf8(unsafe { CStr::from_ptr(p) }.to_bytes()).ok()
            }
        };
        let commit = Commit {
            a: seg(s.commit_a),
            b: seg(s.commit_b),
            lit: (s.commit_lit != 0).then_some(s.commit_lit),
        };
        (!commit.is_empty()).then_some(commit)
    }

    /// Copy the candidates at `[start, start + out.len())` into `out`,
    /// returning how many were written. Nothing is allocated; a short buffer
    /// or an out-of-range window simply yields fewer entries.
    ///
    /// This is a pure read — it never moves the anchor.
    pub fn read_range(&mut self, start: u32, out: &mut [Candidate]) -> usize {
        let cap: u32 = out.len().try_into().unwrap_or(u32::MAX);
        let n =
            unsafe { ffi::jd_read_range(self.handle.as_ptr(), start, cap, out.as_mut_ptr(), cap) };
        n as usize
    }

    /// Collect a window of candidates into a fresh `Vec`.
    pub fn candidates(&mut self, start: u32, count: u32) -> Vec<Candidate> {
        let mut out = Vec::new();
        self.extend_candidates(start, count, &mut out);
        out
    }

    /// Append a window of candidates onto `out` — the natural shape for an
    /// append-only candidate strip, since reads never disturb the anchor.
    /// Returns how many were appended.
    pub fn extend_candidates(&mut self, start: u32, count: u32, out: &mut Vec<Candidate>) -> usize {
        let base = out.len();
        out.resize(base + count as usize, Candidate::default());
        let n = self.read_range(start, &mut out[base..]);
        out.truncate(base + n);
        n
    }
}

impl Drop for JdContext {
    fn drop(&mut self) {
        unsafe { ffi::jd_deinit(self.handle.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commit_display_joins_segments_in_order() {
        let c = Commit {
            a: Some("你"),
            b: Some("好"),
            lit: None,
        };
        assert_eq!(c.to_string(), "你好");
        assert_eq!(c.len(), "你好".len());

        let c = Commit {
            a: Some("你"),
            b: None,
            lit: Some(b'1'),
        };
        assert_eq!(c.to_string(), "你1");

        let c = Commit {
            a: None,
            b: None,
            lit: Some(b' '),
        };
        assert_eq!(c.to_string(), " ");
        assert_eq!(c.len(), 1);

        let empty = Commit {
            a: None,
            b: None,
            lit: None,
        };
        assert!(empty.is_empty());
        assert_eq!(empty.to_string(), "");
    }

    #[test]
    fn default_candidate_is_inert() {
        let c = Candidate::default();
        assert_eq!(c.value(), "");
        assert_eq!(c.value_bytes(), b"");
        assert_eq!(c.hint(), None);
    }
}
