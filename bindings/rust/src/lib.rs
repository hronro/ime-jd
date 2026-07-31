//! Safe Rust bindings for libjd, the 键道 input-method core engine.
//!
//! Unlike a typical FFI wrapper, this one does not copy anything defensively,
//! because the C ABI has no borrowed data to protect against: a candidate's
//! `value` and a commit's segments all point into the library's embedded
//! dictionary blob — read-only data that lives for the whole process — and a
//! candidate's `hint` is inline bytes. That makes [`Candidate`] `Copy` and its
//! strings `&'static str`, so candidate lists can be kept, moved between
//! threads, and rendered lazily with no allocation.
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

use std::ffi::{CStr, c_char};
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
    /// into the embedded blob.
    value: *const c_char,
    /// NUL-terminated; `hint[0] == 0` means no hint.
    hint: [u8; HINT_CAP],
}

// SAFETY: the only pointer is into the library's embedded, read-only,
// process-lifetime dictionary blob. Nothing is owned and nothing is mutated,
// so a candidate can cross threads freely.
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
        // NUL-terminated, and the blob outlives the process.
        unsafe { CStr::from_ptr(self.value) }.to_bytes()
    }

    /// The committable text. Dictionary values are UTF-8 by construction (the
    /// build-time generator reads UTF-8 source tables), so this only fails on
    /// a corrupt library, in which case it yields `""`.
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InitError;

impl fmt::Display for InitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("jd_init failed (allocation failure)")
    }
}

impl std::error::Error for InitError {}

mod ffi {
    use std::ffi::c_char;

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

    unsafe extern "C" {
        pub fn jd_init() -> *mut JdContext;
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
    }
}

const JD_ABI_SIZEOF_STATE: u32 = 0;
const JD_ABI_SIZEOF_OPTION: u32 = 1;
const JD_ABI_HINT_CAP: u32 = 2;

static ABI_CHECK: Once = Once::new();

/// Guards against this crate's hand-written `#[repr(C)]` declarations drifting
/// from the compiled library — a mismatch would silently corrupt memory, so it
/// is worth one comparison per process.
fn check_abi() {
    ABI_CHECK.call_once(|| {
        let (state, option, hint) = unsafe {
            (
                ffi::jd_abi_layout(JD_ABI_SIZEOF_STATE) as usize,
                ffi::jd_abi_layout(JD_ABI_SIZEOF_OPTION) as usize,
                ffi::jd_abi_layout(JD_ABI_HINT_CAP) as usize,
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
    pub fn new() -> Result<Self, InitError> {
        check_abi();
        let raw = unsafe { ffi::jd_init() };
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
                // SAFETY: non-null commit segments point into the embedded
                // blob, NUL-terminated and immortal.
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
        let n = unsafe {
            ffi::jd_read_range(self.handle.as_ptr(), start, cap, out.as_mut_ptr(), cap)
        };
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
    pub fn extend_candidates(
        &mut self,
        start: u32,
        count: u32,
        out: &mut Vec<Candidate>,
    ) -> usize {
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
