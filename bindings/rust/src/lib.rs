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
//! The dictionary a context types from is libjd's embedded one unless you
//! give it your own: a [`Dict`], built from text of the same format with no
//! cap short of millions of entries, and passed to [`JdContext::with_dict`].
//! A user dictionary then sits on top of it — build and check it against
//! that dictionary with the `_on` functions ([`UserDict::build_on`] and
//! friends). libjd-engine, the library built without an embedded
//! dictionary, types from nothing else ([`Dict::builtin_entries`] is 0
//! there). To type from a user dictionary alone, put it on
//! [`Dict::empty`].
//!
//! Candidates are addressed by flat index, not by page. Read a window with
//! [`JdContext::read_range`] (into your own buffer) or
//! [`JdContext::extend_candidates`] (appending onto a `Vec`, the natural shape
//! for a candidate strip). Reads are pure: they never change what the engine's
//! automatic commits resolve to, so you can prefetch as far ahead as you like.
//! Tell the engine what the user is actually looking at with
//! [`JdContext::set_anchor`].
//!
//! The other direction — the codes a value is typed with, and the candidate
//! index it has on each — is [`JdContext::lookup_codes`].
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

/// Inline code capacity, including the NUL terminator. Mirrors `JD_CODE_CAP`
/// in `core/include/jd.h`; verified against the library at startup.
pub const CODE_CAP: usize = 8;

/// One code a value is typed with — see [`JdContext::lookup_codes`].
#[repr(C)]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct Code {
    /// NUL-terminated ASCII.
    keys: [u8; CODE_CAP],
    index: u32,
    flags: u32,
}

impl Code {
    /// `JD_CODE_USER`.
    const USER: u32 = 0x1;

    /// The keys: a-z, and `;` in the built-in symbol codes.
    pub fn keys(&self) -> &str {
        let end = self.keys.iter().position(|&b| b == 0).unwrap_or(CODE_CAP);
        std::str::from_utf8(&self.keys[..end]).unwrap_or("")
    }

    /// Where the value sits in the candidate list after typing exactly
    /// [`Self::keys`] with nothing in flight — 0 is what space commits. It
    /// counts the context's user phrases on the same code, which lead the
    /// built-in words.
    pub fn index(&self) -> u32 {
        self.index
    }

    /// Whether the code comes from the context's user dictionary rather than
    /// the built-in tables.
    pub fn is_user(&self) -> bool {
        self.flags & Self::USER != 0
    }
}

impl fmt::Debug for Code {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Code")
            .field("keys", &self.keys())
            .field("index", &self.index)
            .field("user", &self.is_user())
            .finish()
    }
}

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
/// (A [`Dict`] and a [`UserDict`] are validated when they are constructed,
/// so a corrupt blob never gets this far.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum InitError {
    /// No dictionary was given, and this libjd has none of its own
    /// (libjd-engine): use [`JdContext::with_dict`].
    NoBuiltinDict,
    /// The user dictionary was built on another dictionary than the one the
    /// context types from: rebuild it on this one.
    StaleUserDict,
    /// The context could not be allocated.
    OutOfMemory,
}

impl fmt::Display for InitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::NoBuiltinDict => "this libjd has no built-in dictionary; pass one of your own",
            Self::StaleUserDict => {
                "the user dictionary was built on another dictionary (rebuild it)"
            }
            Self::OutOfMemory => "jd_init failed (allocation failure)",
        })
    }
}

impl std::error::Error for InitError {}

/// Why a dictionary or user dictionary could not be built or accepted.
/// Mirrors the `JD_USER_DICT_*` codes in `core/include/jd.h`. These are
/// failures of a call as a whole; a line that does not parse is not one —
/// the build skips it and says so in a [`UserDictNote`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserDictStatus {
    /// The output buffer was smaller than the bound (a bug in this crate).
    BufferTooSmall,
    /// More entries than the cap: [`UserDict::MAX_ENTRIES`] phrases, or
    /// [`Dict::MAX_ENTRIES`] in a dictionary.
    TooManyEntries,
    /// The blob was built by another libjd (format or byte order differ),
    /// or — a user dictionary — on another dictionary: rebuild it.
    Stale,
    /// The blob is structurally invalid: rebuild it from the phrases.
    Corrupt,
    /// The blob pointer was not 4-byte aligned (a bug in this crate).
    Misaligned,
    /// The text exceeds the cap: [`UserDict::MAX_TEXT_BYTES`], or
    /// [`Dict::MAX_TEXT_BYTES`] for a dictionary.
    TextTooLong,
    /// No dictionary was given for the user dictionary to sit on, and this
    /// libjd has none of its own (libjd-engine).
    NoBuiltinDict,
    /// A status this crate does not know (a newer library).
    Unknown(u32),
}

impl UserDictStatus {
    fn from_code(code: u32) -> Self {
        match code {
            1 => Self::BufferTooSmall,
            2 => Self::TooManyEntries,
            3 => Self::Stale,
            4 => Self::Corrupt,
            5 => Self::Misaligned,
            6 => Self::TextTooLong,
            7 => Self::NoBuiltinDict,
            other => Self::Unknown(other),
        }
    }

    /// Whether `line` points at an input line — the first phrase past the
    /// cap — rather than the status describing a cached blob or the call
    /// itself.
    pub fn is_line_error(self) -> bool {
        matches!(self, Self::TooManyEntries)
    }
}

impl fmt::Display for UserDictStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BufferTooSmall => f.write_str("output buffer too small"),
            Self::TooManyEntries => f.write_str("too many entries"),
            Self::Stale => {
                f.write_str("blob was built against a different dictionary (rebuild it)")
            }
            Self::Corrupt => f.write_str("blob is corrupt (rebuild it)"),
            Self::Misaligned => f.write_str("blob is not 4-byte aligned"),
            Self::TextTooLong => f.write_str("text is too long"),
            Self::NoBuiltinDict => f.write_str("this libjd has no built-in dictionary"),
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

/// One thing [`UserDict::build`] has to say about an input line. Mirrors
/// `jd_user_dict_note` in `core/include/jd.h`.
///
/// A skipped line (it does not parse) carries exactly one of
/// [`Self::MALFORMED`], [`Self::BAD_KEYS`] and [`Self::BAD_VALUE`], and
/// nothing else. A dropped line (parsed, but not in the dictionary) carries
/// [`Self::REPEATS_LINE`] or [`Self::REPEATS_BUILTIN`]. A kept line whose
/// code is already taken carries [`Self::CODE_IN_BUILTIN`] and/or
/// [`Self::CODE_IN_LINE`]: the phrase works, listed ahead of the built-in
/// word, but the code is shared (重码), which is what a user wants to know
/// before relying on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UserDictNote {
    /// 1-based input line.
    pub line: u32,
    /// `MALFORMED` / `BAD_*` / `REPEATS_*` / `CODE_IN_*` bits.
    pub flags: u32,
    /// A kept line this one relates to: for a repeat, the line it repeats (0
    /// for a built-in word); for a shared code, the first kept line on that
    /// code — and for that first line, the second. 0 otherwise.
    pub other: u32,
    /// Built-in words on exactly this code; 0 on a skipped line.
    pub builtin: u32,
    /// Other kept lines on exactly this code; 0 on a dropped or skipped line.
    pub peers: u32,
}

impl UserDictNote {
    /// Dropped: same keys and value as the kept line `other`.
    pub const REPEATS_LINE: u32 = 0x1;
    /// Dropped: same keys and value as a word of the dictionary beneath —
    /// the built-in one, or the [`Dict`] it was built on.
    pub const REPEATS_BUILTIN: u32 = 0x2;
    /// Kept: a word of the dictionary beneath sits on exactly this code
    /// (`builtin` says how many).
    pub const CODE_IN_BUILTIN: u32 = 0x4;
    /// Kept: kept line `other` sits on this code too (`peers` says how many do).
    pub const CODE_IN_LINE: u32 = 0x8;
    /// Skipped: neither blank nor a comment, and no TAB.
    pub const MALFORMED: u32 = 0x10;
    /// Skipped: keys empty, longer than [`UserDict::MAX_KEY_LENGTH`], not
    /// all `a`-`z` and `;`, or a `;` after a letter.
    pub const BAD_KEYS: u32 = 0x20;
    /// Skipped: value empty, longer than [`UserDict::VALUE_MAX`] bytes, not
    /// UTF-8, or containing control characters.
    pub const BAD_VALUE: u32 = 0x40;

    /// Whether the line was skipped because it does not parse.
    pub fn is_invalid(&self) -> bool {
        self.flags & (Self::MALFORMED | Self::BAD_KEYS | Self::BAD_VALUE) != 0
    }

    /// Whether the line parsed but was left out of the dictionary as a
    /// duplicate.
    pub fn is_dropped(&self) -> bool {
        self.flags & (Self::REPEATS_LINE | Self::REPEATS_BUILTIN) != 0
    }

    /// Whether the line is in the dictionary on a code something else uses.
    pub fn is_shared(&self) -> bool {
        self.flags & (Self::CODE_IN_BUILTIN | Self::CODE_IN_LINE) != 0
    }
}

impl fmt::Display for UserDictNote {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: ", self.line)?;
        if self.flags & Self::MALFORMED != 0 {
            return f.write_str("skipped, expected `value<TAB>keys`");
        }
        if self.flags & Self::BAD_KEYS != 0 {
            return f.write_str(
                "skipped, keys must be 1 to 6 of a-z and `;`, with no `;` after a letter",
            );
        }
        if self.flags & Self::BAD_VALUE != 0 {
            return write!(
                f,
                "skipped, value must be 1 to {} bytes of text without control characters",
                UserDict::VALUE_MAX
            );
        }
        if self.flags & Self::REPEATS_LINE != 0 {
            return write!(f, "dropped, repeats line {}", self.other);
        }
        if self.flags & Self::REPEATS_BUILTIN != 0 {
            return f.write_str("dropped, repeats a dictionary word");
        }
        f.write_str("shares its code with")?;
        if self.flags & Self::CODE_IN_BUILTIN != 0 {
            write!(
                f,
                " {} dictionary word{}",
                self.builtin,
                plural(self.builtin)
            )?;
            if self.flags & Self::CODE_IN_LINE != 0 {
                f.write_str(" and")?;
            }
        }
        if self.flags & Self::CODE_IN_LINE != 0 {
            write!(
                f,
                " {} other line{} (line {})",
                self.peers,
                plural(self.peers),
                self.other
            )?;
        }
        Ok(())
    }
}

fn plural(n: u32) -> &'static str {
    if n == 1 { "" } else { "s" }
}

/// What [`UserDict::build`] did with the input.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct UserDictReport {
    /// Phrases that made it into the dictionary.
    pub entries: u32,
    /// Phrases dropped as exact duplicates — of an earlier line with the same
    /// keys and value, or of a built-in word on the same code.
    pub dropped: u32,
    /// Kept phrases on a shared code: a built-in word, another kept phrase,
    /// or both already sit on it.
    pub shared: u32,
    /// Lines skipped because they do not parse: no TAB, bad keys, or a bad
    /// value.
    pub invalid: u32,
    /// One note per skipped, dropped or shared line — `invalid + dropped +
    /// shared` of them — ascending by line.
    pub notes: Vec<UserDictNote>,
}

impl UserDictReport {
    /// The 1-based input lines of every dropped phrase, ascending.
    pub fn dropped_lines(&self) -> Vec<u32> {
        self.lines_where(UserDictNote::is_dropped)
    }

    /// The 1-based input lines of every skipped line, ascending.
    pub fn invalid_lines(&self) -> Vec<u32> {
        self.lines_where(UserDictNote::is_invalid)
    }

    fn lines_where(&self, pick: fn(&UserDictNote) -> bool) -> Vec<u32> {
        self.notes
            .iter()
            .filter(|n| pick(n))
            .map(|n| n.line)
            .collect()
    }
}

/// A user dictionary: phrases compiled into the blob the engine reads in
/// place. Build it from text once, cache [`Self::as_bytes`], and wrap the
/// cached bytes on later launches — [`Self::from_blob`] copies them into
/// aligned storage; [`Self::from_static_blob`] takes memory you keep alive
/// for the rest of the process, such as a leaked memory map of the cache
/// file, and [`Self::from_mapped_blob`] a memory map it unmaps when it is
/// dropped, both with no copy at all. The [`Self::source_tag`] you gave `build` comes
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

/// The blob's backing memory: this crate's own aligned storage, a `'static`
/// slice the host owns and keeps alive, such as a leaked memory map of the
/// cache file, or a map the dictionary owns and drops with itself.
enum Blob {
    Owned {
        /// 4-byte-aligned, as the engine requires.
        storage: Vec<u32>,
        /// Blob length in bytes; the storage may be a little longer.
        len: usize,
    },
    Static(&'static [u8]),
    Mapped(Box<dyn AsRef<[u8]> + Send + Sync>),
}

impl Blob {
    fn bytes(&self) -> &[u8] {
        match self {
            // SAFETY: the storage holds at least `len` initialized bytes.
            Blob::Owned { storage, len } => unsafe {
                std::slice::from_raw_parts(storage.as_ptr().cast::<u8>(), *len)
            },
            Blob::Static(bytes) => bytes,
            Blob::Mapped(map) => (**map).as_ref(),
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

/// The `(dict, dict_len)` pair the C calls take: the dictionary's blob, or
/// NULL for the embedded one.
fn dict_arg(dict: Option<&Dict>) -> (*const c_void, usize) {
    match dict {
        Some(d) => {
            let bytes = d.blob.bytes();
            (bytes.as_ptr().cast(), bytes.len())
        }
        None => (ptr::null(), 0),
    }
}

/// `jd_user_dict_check` on `bytes` exactly where they are, on `dict`.
fn check_in_place(dict: Option<&Dict>, bytes: &[u8]) -> Result<UserDictInfo, UserDictError> {
    check_abi();
    let (dict_ptr, dict_len) = dict_arg(dict);
    let mut info = ffi::JdUserDictInfo::default();
    // SAFETY: the pointers and lengths describe live memory.
    let status = unsafe {
        ffi::jd_user_dict_check(
            dict_ptr,
            dict_len,
            bytes.as_ptr().cast(),
            bytes.len(),
            &mut info,
        )
    };
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
    pub const MAX_ENTRIES: u32 = 500_000;
    /// Longest phrase value in bytes (`JD_USER_DICT_VALUE_MAX`), the same
    /// as a dictionary's.
    pub const VALUE_MAX: u32 = 1023;
    /// Most text one build reads, in bytes (`JD_USER_DICT_TEXT_MAX`); more
    /// fails with [`UserDictStatus::TextTooLong`].
    pub const MAX_TEXT_BYTES: u32 = 16 * 1024 * 1024;
    /// Longest code. `jd.h` states it in prose — keys are 1 to 6 of `a`-`z`
    /// and `;` — rather than as a macro; the builder skips a longer code
    /// with a [`UserDictNote::BAD_KEYS`] note.
    pub const MAX_KEY_LENGTH: u32 = 6;

    /// Build from lines of `value<TAB>keys` — the format of libjd's own
    /// table files. `#` starts a comment line, blank lines are skipped,
    /// spaces around either field are trimmed, CRLF is accepted. Keys are
    /// one to six of `a`-`z` and `;`, with no `;` after a letter; values are
    /// UTF-8 without control characters. Exact duplicates, of an earlier
    /// line or of a built-in word on the same code, are dropped and
    /// counted; the report's notes say which lines, and which kept phrases
    /// sit on a code that a built-in word or another phrase already uses.
    ///
    /// `source_tag` is stored in the blob, uninterpreted: a modification
    /// time, a content hash, a revision — whatever identifies the phrases
    /// this dictionary was built from.
    ///
    /// The phrases sit on libjd's embedded dictionary; [`Self::build_on`]
    /// puts them on another.
    pub fn build(phrases: &str, source_tag: u64) -> Result<(Self, UserDictReport), UserDictError> {
        Self::build_with(None, phrases, source_tag)
    }

    /// [`Self::build`] on `dict` instead of the embedded dictionary: the
    /// phrases that repeat its words are dropped, the notes name its words
    /// on a shared code, and the result works only on a context typing from
    /// `dict` ([`JdContext::with_dict`]).
    pub fn build_on(
        dict: &Dict,
        phrases: &str,
        source_tag: u64,
    ) -> Result<(Self, UserDictReport), UserDictError> {
        Self::build_with(Some(dict), phrases, source_tag)
    }

    fn build_with(
        dict: Option<&Dict>,
        phrases: &str,
        source_tag: u64,
    ) -> Result<(Self, UserDictReport), UserDictError> {
        check_abi();
        let text = phrases.as_bytes();
        let bound = unsafe { ffi::jd_user_dict_blob_bound(text.as_ptr().cast(), text.len()) };
        let (dict_ptr, dict_len) = dict_arg(dict);
        let built = build_blob(bound, |buf, cap, len, report| {
            // SAFETY: every pointer is to live memory of the stated length,
            // and the output buffer is 4-byte aligned and at least the bound
            // long.
            unsafe {
                ffi::jd_user_dict_build(
                    dict_ptr,
                    dict_len,
                    text.as_ptr().cast(),
                    text.len(),
                    source_tag,
                    buf,
                    cap,
                    len,
                    report,
                )
            }
        })?;
        Ok((
            Self {
                entries: built.report.entries,
                blob: built.blob,
                source_tag,
            },
            built.report,
        ))
    }

    /// Wrap a blob cached from an earlier [`Self::as_bytes`]. The bytes are
    /// copied into aligned storage and validated exactly as `jd_init` would;
    /// a [`UserDictStatus::Stale`] or [`UserDictStatus::Corrupt`] result
    /// means "rebuild from the phrases".
    pub fn from_blob(bytes: &[u8]) -> Result<Self, UserDictError> {
        Self::from_blob_with(None, bytes)
    }

    /// [`Self::from_blob`] for a blob built on `dict` ([`Self::build_on`]).
    pub fn from_blob_on(dict: &Dict, bytes: &[u8]) -> Result<Self, UserDictError> {
        Self::from_blob_with(Some(dict), bytes)
    }

    fn from_blob_with(dict: Option<&Dict>, bytes: &[u8]) -> Result<Self, UserDictError> {
        let storage = aligned_copy(bytes);
        let blob = Blob::Owned {
            storage,
            len: bytes.len(),
        };
        let info = check_in_place(dict, blob.bytes())?;
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
        Self::from_static_blob_with(None, bytes)
    }

    /// [`Self::from_static_blob`] for a blob built on `dict`
    /// ([`Self::build_on`]).
    pub fn from_static_blob_on(dict: &Dict, bytes: &'static [u8]) -> Result<Self, UserDictError> {
        Self::from_static_blob_with(Some(dict), bytes)
    }

    fn from_static_blob_with(
        dict: Option<&Dict>,
        bytes: &'static [u8],
    ) -> Result<Self, UserDictError> {
        let info = check_in_place(dict, bytes)?;
        Ok(Self {
            blob: Blob::Static(bytes),
            entries: info.entries,
            source_tag: info.source_tag,
        })
    }

    /// Wrap a cached blob in memory that `map` owns — a memory map of the
    /// cache file, typically — without copying it, and keep `map` for as
    /// long as the dictionary lives: the engine reads the bytes where they
    /// lie, and the file is unmapped when the dictionary is dropped, so a
    /// host that changes dictionaries does not pile up old maps. The bytes
    /// must be 4-byte aligned (a file mapping is page-aligned); otherwise
    /// [`UserDictStatus::Misaligned`]. Validated exactly as `jd_init` would.
    ///
    /// # Safety
    ///
    /// The bytes `map.as_ref()` returns must stay at the same address, and
    /// unchanged, until `map` is dropped. A file mapping keeps its address;
    /// keeping its bytes is up to how the file is opened and replaced —
    /// shared for reading only while it is mapped, and replaced by writing
    /// a new file rather than rewriting this one.
    pub unsafe fn from_mapped_blob(
        map: impl AsRef<[u8]> + Send + Sync + 'static,
    ) -> Result<Self, UserDictError> {
        // SAFETY: the caller's promise, passed on.
        unsafe { Self::from_mapped_blob_with(None, map) }
    }

    /// [`Self::from_mapped_blob`] for a blob built on `dict`
    /// ([`Self::build_on`]).
    ///
    /// # Safety
    ///
    /// As for [`Self::from_mapped_blob`].
    pub unsafe fn from_mapped_blob_on(
        dict: &Dict,
        map: impl AsRef<[u8]> + Send + Sync + 'static,
    ) -> Result<Self, UserDictError> {
        // SAFETY: the caller's promise, passed on.
        unsafe { Self::from_mapped_blob_with(Some(dict), map) }
    }

    unsafe fn from_mapped_blob_with(
        dict: Option<&Dict>,
        map: impl AsRef<[u8]> + Send + Sync + 'static,
    ) -> Result<Self, UserDictError> {
        let blob = Blob::Mapped(Box::new(map));
        let info = check_in_place(dict, blob.bytes())?;
        Ok(Self {
            blob,
            entries: info.entries,
            source_tag: info.source_tag,
        })
    }

    /// Validate a cached blob and read its tag and phrase count without
    /// taking it over — the way to decide between [`Self::from_static_blob`]
    /// and a rebuild before committing to a memory map. Works on any slice;
    /// a misaligned one is checked through a temporary aligned copy.
    pub fn check(bytes: &[u8]) -> Result<UserDictInfo, UserDictError> {
        check_anywhere(bytes, |b| check_in_place(None, b))
    }

    /// [`Self::check`] for a blob built on `dict` ([`Self::build_on`]).
    pub fn check_on(dict: &Dict, bytes: &[u8]) -> Result<UserDictInfo, UserDictError> {
        check_anywhere(bytes, |b| check_in_place(Some(dict), b))
    }

    /// libjd's hash of `bytes` (`jd_user_dict_hash`), for the `source_tag`
    /// of a dictionary built from a text you keep: hash the text when you
    /// build and again at launch, and a cached blob whose tag differs was
    /// built from something else. Gigabytes a second, so hashing a whole
    /// phrases file at every launch is cheap. Stable across platforms and
    /// releases; not cryptographic.
    pub fn hash(bytes: &[u8]) -> u64 {
        // SAFETY: the library reads exactly `len` bytes and keeps nothing.
        unsafe { ffi::jd_user_dict_hash(bytes.as_ptr().cast(), bytes.len()) }
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

/// Run `check` on `bytes` where they are when they are 4-byte aligned,
/// otherwise on a temporary aligned copy.
fn check_anywhere(
    bytes: &[u8],
    check: impl FnOnce(&[u8]) -> Result<UserDictInfo, UserDictError>,
) -> Result<UserDictInfo, UserDictError> {
    if bytes.as_ptr().addr().is_multiple_of(4) {
        check(bytes)
    } else {
        let storage = aligned_copy(bytes);
        let blob = Blob::Owned {
            storage,
            len: bytes.len(),
        };
        check(blob.bytes())
    }
}

/// A blob a build call left in a buffer of ours, trimmed to the blob, and
/// what the call reported.
struct Built {
    blob: Blob,
    report: UserDictReport,
}

/// Run a `jd_*_build` call — `build(buf, cap, &mut len, &mut report)` —
/// into a 4-byte-aligned buffer of `bound` bytes, then copy the notes out
/// and keep only the blob.
fn build_blob(
    bound: usize,
    build: impl FnOnce(*mut c_void, usize, &mut usize, &mut ffi::JdUserDictReport) -> u32,
) -> Result<Built, UserDictError> {
    let mut storage = vec![0u32; bound.div_ceil(4)];
    let mut len: usize = 0;
    let mut report = ffi::JdUserDictReport::default();
    let cap = storage.len() * 4;
    let status = build(storage.as_mut_ptr().cast(), cap, &mut len, &mut report);
    if status != 0 {
        return Err(UserDictError {
            status: UserDictStatus::from_code(status),
            line: report.line,
        });
    }
    // The notes sit past the blob in the same buffer; copy them out
    // before it is trimmed to the blob.
    let notes = {
        let start = report.notes_offset as usize;
        let count = report.notes as usize;
        let end = start + count * size_of::<ffi::JdUserDictNote>();
        assert!(
            start.is_multiple_of(4) && end <= cap,
            "libjd placed the notes outside the buffer it was given"
        );
        // SAFETY: the library wrote `count` notes at a 4-aligned offset
        // inside the buffer, which the assertion above re-checks.
        let raw = unsafe {
            std::slice::from_raw_parts(
                storage
                    .as_ptr()
                    .cast::<u8>()
                    .add(start)
                    .cast::<ffi::JdUserDictNote>(),
                count,
            )
        };
        raw.iter()
            .map(|n| UserDictNote {
                line: n.line,
                flags: n.flags,
                other: n.other,
                builtin: n.builtin,
                peers: n.peers,
            })
            .collect()
    };
    // The bound leaves room for the build's working space and every line's
    // note, a few times the blob: keep only the blob.
    storage.truncate(len.div_ceil(4));
    storage.shrink_to_fit();
    Ok(Built {
        blob: Blob::Owned { storage, len },
        report: UserDictReport {
            entries: report.entries,
            dropped: report.dropped,
            shared: report.shared,
            invalid: report.invalid,
            notes,
        },
    })
}

/// A dictionary to type from in place of libjd's embedded one: every code
/// and the words on it, built from `value<TAB>keys` text by the same code
/// that builds the embedded dictionary, so it types the same way and as
/// fast, at any size up to [`Self::MAX_ENTRIES`].
///
/// Like a [`UserDict`], build it once, cache [`Self::as_bytes`], and wrap
/// the cached bytes on later launches — a memory map of the cache file is
/// best ([`Self::from_mapped_blob`]), since the engine reads the blob in
/// place and a large one is many megabytes. A build is the slow part,
/// about 0.3 s per million entries on a laptop; checking a blob, which
/// every constructor does exactly as `jd_init` would, a few tens of
/// milliseconds per million.
///
/// Hand it to [`JdContext::with_dict`], which takes `&'static Dict` for the
/// same reason [`JdContext::with_user_dict`] takes a `'static` user
/// dictionary. A user dictionary for it is built and checked with
/// [`UserDict::build_on`] and friends.
pub struct Dict {
    blob: Blob,
    entries: u32,
    source_tag: u64,
}

impl Dict {
    /// Most entries one dictionary may hold (`JD_DICT_MAX_ENTRIES`).
    pub const MAX_ENTRIES: u32 = 16_777_215;
    /// Longest value in bytes (`JD_DICT_VALUE_MAX`).
    pub const VALUE_MAX: u32 = 1023;
    /// Most text one build reads, in bytes (`JD_DICT_TEXT_MAX`).
    pub const MAX_TEXT_BYTES: u32 = u32::MAX;

    /// Build from lines of `value<TAB>keys`, by the rules of
    /// [`UserDict::build`]: lines that do not parse are skipped and exact
    /// repeats dropped, each with a note in the report (whose `shared` is
    /// always 0). The words on one code are its candidates in the order of
    /// their lines. `source_tag` is stored in the blob, uninterpreted.
    pub fn build(text: &str, source_tag: u64) -> Result<(Self, UserDictReport), UserDictError> {
        check_abi();
        let bytes = text.as_bytes();
        // SAFETY: the library reads exactly `len` bytes.
        let bound = unsafe { ffi::jd_dict_blob_bound(bytes.as_ptr().cast(), bytes.len()) };
        let built = build_blob(bound, |buf, cap, len, report| {
            // SAFETY: every pointer is to live memory of the stated length,
            // and the output buffer is 4-byte aligned and at least the bound
            // long.
            unsafe {
                ffi::jd_dict_build(
                    bytes.as_ptr().cast(),
                    bytes.len(),
                    source_tag,
                    buf,
                    cap,
                    len,
                    report,
                )
            }
        })?;
        Ok((
            Self {
                entries: built.report.entries,
                blob: built.blob,
                source_tag,
            },
            built.report,
        ))
    }

    /// The empty dictionary: no codes at all. A context on it types from
    /// its user dictionary alone — build that with [`UserDict::build_on`]
    /// on the same empty dictionary. Every empty dictionary is the same
    /// dictionary, so a user dictionary built on one works on any.
    pub fn empty() -> Self {
        Self::build("", 0)
            .expect("libjd builds an empty dictionary")
            .0
    }

    /// How many entries libjd's embedded dictionary holds: 0 in
    /// libjd-engine, which has none.
    pub fn builtin_entries() -> u32 {
        // SAFETY: a pure query of a constant.
        unsafe { ffi::jd_abi_layout(JD_ABI_BUILTIN_DICT_ENTRIES) }
    }

    /// Wrap a blob cached from an earlier [`Self::as_bytes`], copied into
    /// aligned storage and validated exactly as `jd_init` would.
    pub fn from_blob(bytes: &[u8]) -> Result<Self, UserDictError> {
        let blob = Blob::Owned {
            storage: aligned_copy(bytes),
            len: bytes.len(),
        };
        Self::wrap(blob)
    }

    /// Wrap a cached blob without copying it: memory you keep alive for the
    /// rest of the process, 4-byte aligned, never moved or changed. See
    /// [`UserDict::from_static_blob`].
    pub fn from_static_blob(bytes: &'static [u8]) -> Result<Self, UserDictError> {
        Self::wrap(Blob::Static(bytes))
    }

    /// Wrap a cached blob in memory that `map` owns — a memory map of the
    /// cache file, typically — without copying it. See
    /// [`UserDict::from_mapped_blob`].
    ///
    /// # Safety
    ///
    /// As for [`UserDict::from_mapped_blob`].
    pub unsafe fn from_mapped_blob(
        map: impl AsRef<[u8]> + Send + Sync + 'static,
    ) -> Result<Self, UserDictError> {
        Self::wrap(Blob::Mapped(Box::new(map)))
    }

    fn wrap(blob: Blob) -> Result<Self, UserDictError> {
        let info = dict_check_in_place(blob.bytes())?;
        Ok(Self {
            blob,
            entries: info.entries,
            source_tag: info.source_tag,
        })
    }

    /// Validate a cached blob and read its tag and entry count without
    /// taking it over. Works on any slice; a misaligned one is checked
    /// through a temporary aligned copy.
    pub fn check(bytes: &[u8]) -> Result<UserDictInfo, UserDictError> {
        check_anywhere(bytes, dict_check_in_place)
    }

    /// How many entries the dictionary holds.
    pub fn entries(&self) -> u32 {
        self.entries
    }

    /// The tag [`Self::build`] was given, read back from the blob.
    pub fn source_tag(&self) -> u64 {
        self.source_tag
    }

    /// The blob — exactly the bytes to cache.
    pub fn as_bytes(&self) -> &[u8] {
        self.blob.bytes()
    }

    /// Give the dictionary the `'static` lifetime [`JdContext::with_dict`]
    /// needs, at the cost of never freeing it.
    pub fn leak(self) -> &'static Dict {
        Box::leak(Box::new(self))
    }
}

impl fmt::Debug for Dict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Dict")
            .field("entries", &self.entries)
            .field("source_tag", &self.source_tag)
            .field("len", &self.blob.bytes().len())
            .finish()
    }
}

/// `jd_dict_check` on `bytes` exactly where they are.
fn dict_check_in_place(bytes: &[u8]) -> Result<UserDictInfo, UserDictError> {
    check_abi();
    let mut info = ffi::JdUserDictInfo::default();
    // SAFETY: the pointer and length describe live memory.
    let status = unsafe { ffi::jd_dict_check(bytes.as_ptr().cast(), bytes.len(), &mut info) };
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
        pub shared: u32,
        pub invalid: u32,
        pub notes: u32,
        pub notes_offset: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct JdUserDictNote {
        pub line: u32,
        pub flags: u32,
        pub other: u32,
        pub builtin: u32,
        pub peers: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct JdUserDictInfo {
        pub source_tag: u64,
        pub entries: u32,
    }

    unsafe extern "C" {
        pub fn jd_init(
            dict: *const c_void,
            dict_len: usize,
            user_dict: *const c_void,
            user_dict_len: usize,
        ) -> *mut JdContext;
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
        pub fn jd_lookup_codes(
            ctx: *mut JdContext,
            value: *const c_char,
            value_len: usize,
            out: *mut super::Code,
            out_cap: u32,
        ) -> u32;
        pub fn jd_abi_layout(what: u32) -> u32;
        pub fn jd_user_dict_blob_bound(phrases: *const c_char, phrases_len: usize) -> usize;
        pub fn jd_dict_blob_bound(text: *const c_char, text_len: usize) -> usize;
        pub fn jd_dict_build(
            text: *const c_char,
            text_len: usize,
            source_tag: u64,
            buf: *mut c_void,
            buf_cap: usize,
            blob_len: *mut usize,
            report: *mut JdUserDictReport,
        ) -> u32;
        pub fn jd_dict_check(
            blob: *const c_void,
            blob_len: usize,
            info: *mut JdUserDictInfo,
        ) -> u32;
        pub fn jd_user_dict_build(
            dict: *const c_void,
            dict_len: usize,
            phrases: *const c_char,
            phrases_len: usize,
            source_tag: u64,
            buf: *mut c_void,
            buf_cap: usize,
            blob_len: *mut usize,
            report: *mut JdUserDictReport,
        ) -> u32;
        pub fn jd_user_dict_check(
            dict: *const c_void,
            dict_len: usize,
            blob: *const c_void,
            blob_len: usize,
            info: *mut JdUserDictInfo,
        ) -> u32;
        pub fn jd_user_dict_hash(bytes: *const c_void, len: usize) -> u64;
    }
}

const JD_ABI_SIZEOF_STATE: u32 = 0;
const JD_ABI_SIZEOF_OPTION: u32 = 1;
const JD_ABI_HINT_CAP: u32 = 2;
const JD_ABI_SIZEOF_USER_DICT_REPORT: u32 = 5;
const JD_ABI_USER_DICT_MAX_ENTRIES: u32 = 6;
const JD_ABI_USER_DICT_VALUE_MAX: u32 = 7;
const JD_ABI_SIZEOF_USER_DICT_INFO: u32 = 8;
const JD_ABI_SIZEOF_USER_DICT_NOTE: u32 = 9;
const JD_ABI_SIZEOF_CODE: u32 = 10;
const JD_ABI_CODE_CAP: u32 = 11;
const JD_ABI_USER_DICT_TEXT_MAX: u32 = 12;
const JD_ABI_DICT_MAX_ENTRIES: u32 = 13;
const JD_ABI_DICT_VALUE_MAX: u32 = 14;
const JD_ABI_DICT_TEXT_MAX: u32 = 15;
const JD_ABI_BUILTIN_DICT_ENTRIES: u32 = 16;

static ABI_CHECK: Once = Once::new();

/// Guards against this crate's hand-written `#[repr(C)]` declarations drifting
/// from the compiled library — a mismatch would silently corrupt memory, so it
/// is worth one comparison per process.
fn check_abi() {
    ABI_CHECK.call_once(|| {
        let (state, option, hint, report, max_entries, value_max, info, note, code, code_cap) = unsafe {
            (
                ffi::jd_abi_layout(JD_ABI_SIZEOF_STATE) as usize,
                ffi::jd_abi_layout(JD_ABI_SIZEOF_OPTION) as usize,
                ffi::jd_abi_layout(JD_ABI_HINT_CAP) as usize,
                ffi::jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_REPORT) as usize,
                ffi::jd_abi_layout(JD_ABI_USER_DICT_MAX_ENTRIES),
                ffi::jd_abi_layout(JD_ABI_USER_DICT_VALUE_MAX),
                ffi::jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_INFO) as usize,
                ffi::jd_abi_layout(JD_ABI_SIZEOF_USER_DICT_NOTE) as usize,
                ffi::jd_abi_layout(JD_ABI_SIZEOF_CODE) as usize,
                ffi::jd_abi_layout(JD_ABI_CODE_CAP) as usize,
            )
        };
        // SAFETY: pure queries of constants.
        let (text_max, dict_entries, dict_value, dict_text) = unsafe {
            (
                ffi::jd_abi_layout(JD_ABI_USER_DICT_TEXT_MAX),
                ffi::jd_abi_layout(JD_ABI_DICT_MAX_ENTRIES),
                ffi::jd_abi_layout(JD_ABI_DICT_VALUE_MAX),
                ffi::jd_abi_layout(JD_ABI_DICT_TEXT_MAX),
            )
        };
        assert_eq!(
            (dict_entries, dict_value, dict_text),
            (Dict::MAX_ENTRIES, Dict::VALUE_MAX, Dict::MAX_TEXT_BYTES),
            "libjd dictionary caps mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            text_max,
            UserDict::MAX_TEXT_BYTES,
            "libjd user dictionary text cap mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            code,
            size_of::<Code>(),
            "libjd jd_code layout mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            code_cap, CODE_CAP,
            "libjd code capacity mismatch — bindings/rust is out of sync with core"
        );
        assert_eq!(
            note,
            size_of::<ffi::JdUserDictNote>(),
            "libjd jd_user_dict_note layout mismatch — bindings/rust is out of sync with core"
        );
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
    /// A context over the built-in dictionary alone. Fails with
    /// [`InitError::NoBuiltinDict`] in libjd-engine.
    pub fn new() -> Result<Self, InitError> {
        Self::init(None, None)
    }

    /// A context over the built-in dictionary plus `dict`. The engine reads
    /// the dictionary in place for the context's lifetime and candidates
    /// keep pointing into it, hence `'static` — see [`UserDict::leak`].
    pub fn with_user_dict(dict: &'static UserDict) -> Result<Self, InitError> {
        Self::init(None, Some(dict))
    }

    /// A context typing from `dict` instead of the built-in dictionary,
    /// plus `user_dict` on top of it — which must have been built on this
    /// same `dict` ([`UserDict::build_on`]), or the context fails with
    /// [`InitError::StaleUserDict`]. Both are read in place for the
    /// context's lifetime, hence `'static` — see [`Dict::leak`].
    pub fn with_dict(
        dict: &'static Dict,
        user_dict: Option<&'static UserDict>,
    ) -> Result<Self, InitError> {
        Self::init(Some(dict), user_dict)
    }

    fn init(
        dict: Option<&'static Dict>,
        user_dict: Option<&'static UserDict>,
    ) -> Result<Self, InitError> {
        check_abi();
        let (dict_ptr, dict_len) = dict_arg(dict);
        let (user_ptr, user_len) = match user_dict {
            Some(d) => {
                let bytes = d.blob.bytes();
                (bytes.as_ptr().cast::<c_void>(), bytes.len())
            }
            None => (ptr::null(), 0),
        };
        // SAFETY: the blobs, if any, are aligned, validated at construction,
        // and live for the rest of the process.
        let raw = unsafe { ffi::jd_init(dict_ptr, dict_len, user_ptr, user_len) };
        let Some(handle) = NonNull::new(raw) else {
            // Both blobs passed their checks when they were wrapped, so the
            // failure is one of these — worked out only now, to spare a
            // launch that succeeds a second pass over them.
            if dict.is_none() && Dict::builtin_entries() == 0 {
                return Err(InitError::NoBuiltinDict);
            }
            if let Some(u) = user_dict
                && check_in_place(dict, u.blob.bytes()).is_err()
            {
                return Err(InitError::StaleUserDict);
            }
            return Err(InitError::OutOfMemory);
        };
        let state = NonNull::new(unsafe { ffi::jd_state_ptr(raw) }.cast_mut())
            .ok_or(InitError::OutOfMemory)?;
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

    /// Write the codes `value` is typed with into `out` and return how many
    /// there are in all — which may be more than `out.len()`; only the first
    /// `out.len()` are written, so an empty slice counts them. Candidate
    /// order: shorter codes first, ties key by key (a-z, then `;`), a user
    /// phrase's code ahead of a built-in word's on the same keys. `value` is
    /// matched exactly, byte for byte.
    ///
    /// A pure read: the composition and the anchor are untouched, and
    /// nothing is allocated.
    pub fn lookup_codes_into(&self, value: &str, out: &mut [Code]) -> usize {
        let cap: u32 = out.len().try_into().unwrap_or(u32::MAX);
        // SAFETY: the value is read for `len` bytes only; `out` has room for
        // `cap` entries. The library writes nothing else.
        let n = unsafe {
            ffi::jd_lookup_codes(
                self.handle.as_ptr(),
                value.as_ptr().cast::<c_char>(),
                value.len(),
                out.as_mut_ptr(),
                cap,
            )
        };
        n as usize
    }

    /// The codes `value` is typed with, from the built-in tables and this
    /// context's user dictionary, in candidate order — see
    /// [`Self::lookup_codes_into`]. Empty for a value neither holds.
    pub fn lookup_codes(&self, value: &str) -> Vec<Code> {
        let mut out = vec![Code::default(); 16];
        let n = self.lookup_codes_into(value, &mut out);
        if n > out.len() {
            out.resize(n, Code::default());
            self.lookup_codes_into(value, &mut out);
        }
        out.truncate(n);
        out
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
