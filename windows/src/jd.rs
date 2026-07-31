//! TSF-side engine glue. The FFI itself lives in the shared `jd` crate
//! (bindings/rust). This module owns what is TSF policy rather than binding
//! concern: the UI-thread-local context lifecycle, and **paging**.
//!
//! The engine addresses candidates by flat index and has no notion of a page,
//! so the page arithmetic lives here. `PAGE_START` tracks the first candidate
//! of the visible page, and every read points the engine's anchor at it — that
//! way the engine's own automatic commits (space, the literal-byte fallback)
//! always resolve to a candidate the user can actually see, and reads for other
//! purposes (the UIElement pre-fetch below) can't disturb it.

use std::cell::{Cell, RefCell};

pub use ::jd::JdContext;

/// Candidates shown per page in the TIP's UI. Purely a display choice now.
pub const PAGE_SIZE: u8 = 8;

/// One visible candidate, owned so it can live in the candidate window's state
/// across engine calls.
#[derive(Default, Clone)]
pub struct Candidate {
    pub value: String,
    pub hint: Option<String>,
}

/// What the TSF layer needs after an engine operation: the commit (if any) plus
/// the visible page. Shaped like the flat window the UI draws.
#[derive(Default, Clone)]
pub struct QueryResult {
    pub commit: Option<String>,
    pub options: Vec<Candidate>,
    /// Total candidates across all pages.
    pub options_count: u32,
    /// 1-based, for the UI and the TSF UIElement.
    pub current_page: u32,
    pub total_pages: u32,
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
    /// Flat index of the first candidate on the visible page. Always a
    /// multiple of `PAGE_SIZE`.
    static PAGE_START: Cell<u32> = const { Cell::new(0) };
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
            *c = JdContext::new().ok();
        }
    });
    PAGE_START.with(|p| p.set(0));
}

/// Drop the per-thread context. Called from `ITfTextInputProcessor::Deactivate`.
/// The `Drop` impl on `JdContext` calls `jd_deinit`.
pub fn deactivate() {
    CTX.with(|c| *c.borrow_mut() = None);
    PAGE_START.with(|p| p.set(0));
}

/// Runs `f` against the engine, or returns a default value when no engine
/// exists. The absent case is reachable in normal operation: TSF calls back
/// into the TIP after `Deactivate` — e.g. `OnCompositionTerminated` when
/// the user switches IMEs mid-composition — and a panic here would unwind
/// across the COM boundary and abort the host process.
fn with_ctx<R: Default>(f: impl FnOnce(&mut JdContext) -> R) -> R {
    CTX.with(|c| c.borrow_mut().as_mut().map(f).unwrap_or_default())
}

fn owned(c: &::jd::Candidate) -> Candidate {
    Candidate {
        value: c.value().to_owned(),
        hint: c.hint().map(str::to_owned),
    }
}

/// Materialize the visible page and point the engine's anchor at it.
fn read_page(ctx: &mut JdContext, commit: Option<String>) -> QueryResult {
    let total = ctx.state().options_count;
    if total == 0 {
        PAGE_START.with(|p| p.set(0));
        return QueryResult {
            commit,
            ..Default::default()
        };
    }

    let page_size = PAGE_SIZE as u32;
    let start = PAGE_START.with(|p| {
        let clamped = if p.get() >= total { 0 } else { p.get() };
        p.set(clamped);
        clamped
    });

    // Keep the engine's automatic commits resolving to a visible candidate.
    ctx.set_anchor(start);

    QueryResult {
        commit,
        options: ctx.candidates(start, page_size).iter().map(owned).collect(),
        options_count: total,
        current_page: start / page_size + 1,
        total_pages: total.div_ceil(page_size),
    }
}

pub fn press_key(key: u8) -> QueryResult {
    with_ctx(|c| {
        c.press_key(key);
        let commit = c.commit().map(|m| m.to_string());
        // Any keystroke produces a fresh candidate list.
        PAGE_START.with(|p| p.set(0));
        read_page(c, commit)
    })
}

pub fn backspace() -> QueryResult {
    with_ctx(|c| {
        c.backspace();
        PAGE_START.with(|p| p.set(0));
        read_page(c, None)
    })
}

pub fn next_page() -> QueryResult {
    with_ctx(|c| {
        let total = c.state().options_count;
        PAGE_START.with(|p| {
            let next = p.get() + PAGE_SIZE as u32;
            if next < total {
                p.set(next);
            }
        });
        read_page(c, None)
    })
}

pub fn prev_page() -> QueryResult {
    with_ctx(|c| {
        PAGE_START.with(|p| p.set(p.get().saturating_sub(PAGE_SIZE as u32)));
        read_page(c, None)
    })
}

/// Every candidate across every page, for hosts that draw the list themselves
/// (see `ui_element::should_prefetch_all_pages`).
///
/// A single flat read — the engine walks its enumeration cursor forward once —
/// and the anchor is untouched, so unlike the old page-by-page loop there is
/// nothing to restore afterwards.
pub fn all_candidates() -> Vec<Candidate> {
    with_ctx(|c| {
        let total = c.state().options_count;
        c.candidates(0, total).iter().map(owned).collect()
    })
}

pub fn reset() {
    with_ctx(|c| c.reset());
    PAGE_START.with(|p| p.set(0));
}
