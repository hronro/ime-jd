//! TSF-side engine glue. The FFI itself lives in the shared `jd` crate
//! (bindings/rust) — every result it returns is owned data, safe to retain.
//! This module owns what is TSF policy rather than binding concern: the
//! page size and the UI-thread-local context lifecycle.

use std::cell::RefCell;

pub use ::jd::{JdContext, QueryOption, QueryResult};

/// Engine page size. The TIP creates every context with this value at
/// `Activate` time; the UIElement implementation references it to compute
/// page boundaries.
pub const PAGE_SIZE: u8 = 8;

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
/// no-op. On allocation failure the engine stays absent and the module
/// functions below degrade to no-ops; panicking would abort the host
/// process (release builds set `panic = "abort"`).
pub fn activate() {
    CTX.with(|c| {
        let mut c = c.borrow_mut();
        if c.is_none() {
            *c = JdContext::new(PAGE_SIZE).ok();
        }
    });
}

/// Drop the per-thread context. Called from `ITfTextInputProcessor::Deactivate`.
/// The `Drop` impl on `JdContext` calls `jd_deinit`.
pub fn deactivate() {
    CTX.with(|c| *c.borrow_mut() = None);
}

/// Runs `f` against the engine, or returns a default value when no engine
/// exists. The absent case is reachable in normal operation: TSF calls back
/// into the TIP after `Deactivate` — e.g. `OnCompositionTerminated` when
/// the user switches IMEs mid-composition — and a panic here would unwind
/// across the COM boundary and abort the host process.
fn with_ctx<R: Default>(f: impl FnOnce(&mut JdContext) -> R) -> R {
    CTX.with(|c| c.borrow_mut().as_mut().map(f).unwrap_or_default())
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
