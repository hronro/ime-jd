//! TSF-side engine glue. The FFI itself lives in the shared `jd` crate
//! (bindings/rust). This module owns what is TSF policy rather than binding
//! concern: the UI-thread-local context lifecycle — including when it adopts
//! an edited user dictionary (`sync_user_dict`, over user_dict.rs) — and
//! **paging**.
//!
//! The engine addresses candidates by flat index and has no notion of a page,
//! so the page arithmetic lives here. `PAGE_START` tracks the first candidate
//! of the visible page, and every read points the engine's anchor at it — that
//! way the engine's own automatic commits (space, the literal-byte fallback)
//! always resolve to a candidate the user can actually see, and reads for other
//! purposes (the UIElement pre-fetch below) can't disturb it.

use std::cell::{Cell, RefCell};
use std::sync::Arc;

use ::jd::JdContext;

use crate::user_dict::{self, Selection};

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

/// A context and what it was made from — the user dictionary it reads, if
/// any. The context reads the dictionary's blob in place for its whole
/// lifetime, so the two travel together — and `ctx` is declared first, so it
/// is dropped first.
struct Engine {
    ctx: JdContext,
    made_from: Selection,
}

impl Engine {
    /// `None` on allocation failure.
    fn new(made_from: Selection) -> Option<Self> {
        // SAFETY: a context asks for `'static` because it reads the blob in
        // place and the candidates it hands out point into it. This blob
        // lives as long as that requires: its `Arc` sits beside the context,
        // in `made_from`, and is dropped after it (field order), and nothing
        // read from the context outlives the `Engine` — this module copies
        // every candidate and commit into owned `String`s (`owned`,
        // `Commit::to_string`) before handing it on. The empty dictionary is
        // the process's for good.
        let ctx = match &made_from {
            Selection::BuiltIn(None) => JdContext::new(),
            Selection::BuiltIn(Some(dict)) => JdContext::with_user_dict(unsafe { &*Arc::as_ptr(dict) }),
            Selection::UserOnly(dict) => JdContext::with_dict(
                jd_userdict::empty_dict(),
                Some(unsafe { &*Arc::as_ptr(dict) }),
            ),
            // Nothing to type from: an engine on the empty dictionary that
            // nothing consults — every key passes through (`passes_keys`).
            Selection::Unavailable(_) => JdContext::with_dict(jd_userdict::empty_dict(), None),
        };
        Some(Self {
            ctx: ctx.ok()?,
            made_from,
        })
    }
}

thread_local! {
    static ENGINE: RefCell<Option<Engine>> = const { RefCell::new(None) };
    /// Flat index of the first candidate on the visible page. Always a
    /// multiple of `PAGE_SIZE`.
    static PAGE_START: Cell<u32> = const { Cell::new(0) };
}

/// Create the per-thread engine, over the user dictionary while it is
/// switched on. Called from `ITfTextInputProcessor::Activate`. Idempotent —
/// repeated Activate without an intervening Deactivate is a no-op. On
/// allocation failure the engine stays absent and the module functions below
/// degrade to no-ops; panicking would abort the host process (release builds
/// set `panic = "abort"`).
pub fn activate() {
    ENGINE.with(|e| {
        let mut e = e.borrow_mut();
        if e.is_none() {
            *e = Engine::new(user_dict::current());
        }
    });
    PAGE_START.with(|p| p.set(0));
}

/// `activate`, over the built-in dictionary alone, whatever the user's
/// switch and phrases are: what a test wants to read candidates from.
#[cfg(test)]
pub fn activate_builtin() {
    ENGINE.with(|e| *e.borrow_mut() = Engine::new(Selection::BuiltIn(None)));
    PAGE_START.with(|p| p.set(0));
}

/// Drop the per-thread engine. Called from `ITfTextInputProcessor::Deactivate`.
/// The `Drop` impl on `JdContext` calls `jd_deinit`; the dictionary goes with
/// it unless another thread's engine still reads it.
pub fn deactivate() {
    ENGINE.with(|e| *e.borrow_mut() = None);
    PAGE_START.with(|p| p.set(0));
}

/// Adopt the user dictionary if it changed since this thread's engine was
/// created — the window saved, a text editor saved, the switch flipped.
/// Call it only while nothing is composing: the engine is replaced, which
/// drops any in-flight state (and the paired-punctuation toggles). A no-op
/// while nothing changed; `user_dict::current` says what looking costs.
pub fn sync_user_dict() {
    let selection = user_dict::current();
    ENGINE.with(|e| {
        let mut e = e.borrow_mut();
        let Some(engine) = e.as_ref() else {
            return;
        };
        if engine.made_from.same_as(&selection) {
            return;
        }
        // On allocation failure the engine in hand carries on.
        if let Some(engine) = Engine::new(selection) {
            *e = Some(engine);
            PAGE_START.with(|p| p.set(0));
        }
    });
}

/// Whether this thread has nothing to type from — 忽略内置词库, with no
/// phrases to be had — so every key goes to the application as typed. Read
/// it after `sync_user_dict`, while nothing is composing.
pub fn passes_keys() -> bool {
    ENGINE.with(|e| {
        e.borrow()
            .as_ref()
            .is_some_and(|engine| matches!(engine.made_from, Selection::Unavailable(_)))
    })
}

/// Runs `f` against the engine, or returns a default value when no engine
/// exists. The absent case is reachable in normal operation: TSF calls back
/// into the TIP after `Deactivate` — e.g. `OnCompositionTerminated` when
/// the user switches IMEs mid-composition — and a panic here would unwind
/// across the COM boundary and abort the host process.
fn with_ctx<R: Default>(f: impl FnOnce(&mut JdContext) -> R) -> R {
    ENGINE.with(|e| {
        e.borrow_mut()
            .as_mut()
            .map(|engine| f(&mut engine.ctx))
            .unwrap_or_default()
    })
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

/// The candidate at flat index `index`, for a host that asks for one this
/// side has not materialized (`ui_element`'s `GetString`). As pure a read as
/// `all_candidates`; it costs the engine a walk from the start of its list
/// only when `index` is behind the last one read.
pub fn candidate_at(index: u32) -> Option<Candidate> {
    with_ctx(|c| c.candidates(index, 1).first().map(owned))
}

pub fn reset() {
    with_ctx(|c| c.reset());
    PAGE_START.with(|p| p.set(0));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidates(made_from: Selection, keys: &[u8]) -> Vec<String> {
        let mut engine = Engine::new(made_from).expect("an engine");
        for &key in keys {
            engine.ctx.press_key(key);
        }
        engine.ctx.candidates(0, 9).iter().map(|c| c.value().to_owned()).collect()
    }

    #[test]
    fn an_engine_types_from_what_it_was_made_from() {
        let text = "测试词\tb\n";
        let (merged, _) = jd_userdict::build(text, None).unwrap();
        let (alone, _) = jd_userdict::build(text, Some(jd_userdict::empty_dict())).unwrap();

        let builtin = candidates(Selection::BuiltIn(None), b"b");
        assert!(builtin.iter().any(|word| word == "不"));
        let both = candidates(Selection::BuiltIn(Some(Arc::new(merged))), b"b");
        assert_eq!(both[0], "测试词");
        assert!(both.iter().any(|word| word == "不"));
        // 忽略内置词库: the phrase, and no built-in word.
        assert_eq!(candidates(Selection::UserOnly(Arc::new(alone)), b"b"), ["测试词"]);
        // Nothing to type from: nothing offered, whatever the keys.
        assert!(candidates(Selection::Unavailable(String::new()), b"b").is_empty());

        // A file with no phrases yet: letters find nothing, punctuation is
        // still 键道's.
        let (none, _) = jd_userdict::build("", Some(jd_userdict::empty_dict())).unwrap();
        let mut engine = Engine::new(Selection::UserOnly(Arc::new(none))).unwrap();
        engine.ctx.press_key(b'b');
        assert_eq!(engine.ctx.state().options_count, 0);
        engine.ctx.reset();
        engine.ctx.press_key(b'.');
        assert_eq!(engine.ctx.commit().map(|c| c.to_string()).as_deref(), Some("。"));
    }

    #[test]
    fn keys_pass_only_with_nothing_to_type_from() {
        activate_builtin();
        assert!(!passes_keys());
        ENGINE.with(|e| *e.borrow_mut() = Engine::new(Selection::Unavailable(String::new())));
        assert!(passes_keys());
        deactivate();
        assert!(!passes_keys(), "no engine: nothing to pass for");
    }
}
