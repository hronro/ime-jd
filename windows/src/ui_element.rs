//! TSF `ITfCandidateListUIElement` implementation for UI-less hosts.
//!
//! When the active host is something like a fullscreen game or an immersive
//! shell that draws its own candidate UI, TSF lets the IME register a
//! "UIElement" that the host can read instead of drawing its own popup. The
//! host calls `BeginUIElement(&our_element, &mut pb_show, &mut id)`:
//!   * `pb_show = TRUE` (the common case — Notepad, Word, Edge, etc.) →
//!     we draw our own popup as usual.
//!   * `pb_show = FALSE` (games, UI-less shells) → the host queries our
//!     element via `ITfCandidateListUIElement::Get*` and renders the list
//!     itself; we suppress our popup.
//!
//! Key handling is unchanged in either mode — `ITfKeyEventSink` still owns
//! every keystroke. The UIElement is a read-only window onto the engine
//! state.

use std::cell::{Cell, RefCell};

use windows::Win32::Foundation::{E_FAIL, E_INVALIDARG};
use windows::Win32::UI::TextServices::{
    ITfCandidateListUIElement, ITfCandidateListUIElement_Impl, ITfDocumentMgr, ITfThreadMgr,
    ITfUIElement, ITfUIElement_Impl, ITfUIElementMgr, TF_CLUIE_COUNT, TF_CLUIE_CURRENTPAGE,
    TF_CLUIE_PAGEINDEX, TF_CLUIE_SELECTION, TF_CLUIE_STRING,
};
use windows::core::{BOOL, BSTR, ComObjectInner, GUID, Interface, Result, implement};

use crate::candidate_window::{self, CandidateItem};
use crate::guids::GUID_JD_UI_ELEMENT;
use crate::jd::{self, PAGE_SIZE};

thread_local! {
    /// The element instance currently registered with the host. `None` when
    /// there are no candidates / no composition.
    static ELEMENT: RefCell<Option<ITfUIElement>> = const { RefCell::new(None) };
    /// The UIElement manager (acquired by QI from the thread manager).
    /// Held so we can call Update/End without re-acquiring on every change.
    static MGR: RefCell<Option<ITfUIElementMgr>> = const { RefCell::new(None) };
    /// Id assigned by the host's `BeginUIElement` call.
    static ID: Cell<Option<u32>> = const { Cell::new(None) };
    /// Current "should the IME draw its own popup?" flag. Set initially from
    /// `pb_show` returned by `BeginUIElement`, then updated by the host
    /// calling `ITfUIElement::Show`. Defaults to `true` when no element is
    /// active — the popup is visible unless a host explicitly tells us off.
    static IS_SHOWN: Cell<bool> = const { Cell::new(true) };
}

#[implement(ITfCandidateListUIElement, ITfUIElement)]
struct CandidateListUIElement {
    state: RefCell<ElementState>,
}

struct ElementState {
    thread_mgr: Option<ITfThreadMgr>,
    /// All candidates across every page, in order. Pre-fetched once per
    /// `sync` so `GetString(i)` is an O(1) slice lookup — modern Win11
    /// Notepad iterates every index on each `UpdateUIElement` callback,
    /// and round-tripping `jd::jump_to_page` per index was visibly
    /// stalling fast typists (O(N²) BFS work per keystroke).
    all_items: Vec<CandidateItem>,
    /// 1-based, as the engine reports.
    current_page: u32,
    total_pages: u32,
    /// `options_count` from the engine — total candidates across all pages.
    total_count: u32,
}

impl ITfUIElement_Impl for CandidateListUIElement_Impl {
    fn GetDescription(&self) -> Result<BSTR> {
        Ok(BSTR::from("键道 candidate list"))
    }

    fn GetGUID(&self) -> Result<GUID> {
        Ok(GUID_JD_UI_ELEMENT)
    }

    fn Show(&self, bshow: BOOL) -> Result<()> {
        let new_shown = bshow.0 != 0;
        let old = IS_SHOWN.with(|c| c.replace(new_shown));
        if old != new_shown {
            candidate_window::sync_visibility();
        }
        Ok(())
    }

    fn IsShown(&self) -> Result<BOOL> {
        Ok(BOOL(IS_SHOWN.with(|c| c.get()) as i32))
    }
}

impl ITfCandidateListUIElement_Impl for CandidateListUIElement_Impl {
    fn GetUpdatedFlags(&self) -> Result<u32> {
        // Conservative: claim every relevant field changed. Cheaper than
        // tracking deltas, and hosts handle "everything is fresh" cleanly.
        Ok(TF_CLUIE_COUNT
            | TF_CLUIE_SELECTION
            | TF_CLUIE_STRING
            | TF_CLUIE_PAGEINDEX
            | TF_CLUIE_CURRENTPAGE)
    }

    fn GetDocumentMgr(&self) -> Result<ITfDocumentMgr> {
        let state = self.state.borrow();
        let tm = state
            .thread_mgr
            .as_ref()
            .ok_or_else(|| windows::core::Error::from_hresult(E_FAIL))?;
        unsafe { tm.GetFocus() }
    }

    fn GetCount(&self) -> Result<u32> {
        Ok(self.state.borrow().total_count)
    }

    fn GetSelection(&self) -> Result<u32> {
        // The engine has no per-candidate selection — candidate #0 is the
        // default and what space commits.
        Ok(0)
    }

    fn GetString(&self, uindex: u32) -> Result<BSTR> {
        let state = self.state.borrow();
        match state.all_items.get(uindex as usize) {
            Some(item) => {
                // TSF has no separate annotation channel on
                // `ITfCandidateListUIElement` — only `GetString`. Concatenate
                // the hint into the displayed string so UI-less hosts (games,
                // immersive shells) can show it, matching the format used by
                // our own popup. Commit is unaffected: selection flows
                // through `ITfKeyEventSink`, which uses the engine's `value`
                // directly.
                let s = match &item.hint {
                    Some(h) if !h.is_empty() => {
                        format!("{}{}", item.value, candidate_window::format_hint(h))
                    }
                    _ => item.value.clone(),
                };
                Ok(BSTR::from(&s))
            }
            None => Err(E_INVALIDARG.into()),
        }
    }

    fn GetPageIndex(&self, pindex: *mut u32, size: u32, pupagecnt: *mut u32) -> Result<()> {
        let state = self.state.borrow();
        if !pupagecnt.is_null() {
            unsafe { *pupagecnt = state.total_pages };
        }
        if !pindex.is_null() && size > 0 {
            let page_size = PAGE_SIZE as u32;
            let to_fill = size.min(state.total_pages);
            for i in 0..to_fill {
                unsafe { *pindex.add(i as usize) = i * page_size };
            }
        }
        Ok(())
    }

    fn SetPageIndex(&self, _pindex: *const u32, _upagecnt: u32) -> Result<()> {
        // No-op — engine has a fixed page size; hosts can't reconfigure it.
        Ok(())
    }

    fn GetCurrentPage(&self) -> Result<u32> {
        // Engine: 1-based. TSF: 0-based.
        Ok(self.state.borrow().current_page.saturating_sub(1))
    }
}

/// Called whenever the candidate list changes — first appearance, page
/// navigation, new keystroke that produced new options. The first call per
/// session creates the element and registers it with the host; subsequent
/// calls just update state and fire `UpdateUIElement`.
///
/// `current_items` is the current page's candidates (already materialized
/// by the caller). Whether we also pre-fetch the other pages is gated by
/// the host: see `should_prefetch_all_pages` for the policy.
pub fn sync(
    thread_mgr: &ITfThreadMgr,
    current_items: Vec<CandidateItem>,
    current_page: u32,
    total_pages: u32,
    total_count: u32,
) {
    let need_begin = ELEMENT.with(|e| e.borrow().is_none());

    let all_items = if should_prefetch_all_pages(need_begin) {
        collect_all_candidates(current_items, current_page, total_pages)
    } else {
        current_items
    };

    if need_begin {
        let _ = begin(
            thread_mgr,
            all_items,
            current_page,
            total_pages,
            total_count,
        );
    } else {
        let _ = update(all_items, current_page, total_pages, total_count);
    }
}

/// Hybrid policy: only pay the pre-fetch cost when we know (or have to
/// guess) that the host will iterate every candidate index.
///
/// * First sync of a session (`need_begin = true`): we haven't called
///   `BeginUIElement` yet, so we don't know `pb_show`. Pre-fetch defensively
///   so the host has full data immediately if it starts iterating during
///   the `BeginUIElement` call.
///
/// * Subsequent syncs: gate on `IS_SHOWN`. `IS_SHOWN == false` means the
///   host opted to draw the candidate list itself (game / immersive shell /
///   accessibility consumer) — it will iterate every index, so pre-fetch.
///   `IS_SHOWN == true` means our overlay popup is doing the rendering;
///   hosts in this mode either don't query UIElement at all, or only query
///   the current page, so we skip the ~`total_pages` engine calls.
///
/// Saves the ~120 µs pre-fetch cost on every keystroke after the first for
/// regular hosts (most of them), while preserving correctness for UI-less
/// consumers.
fn should_prefetch_all_pages(need_begin: bool) -> bool {
    if need_begin {
        return true;
    }
    !IS_SHOWN.with(|c| c.get())
}

/// Materialize every candidate across every page. For single-page results
/// this is just the input; for multi-page results, we walk the engine
/// through the other pages and stitch them in. The engine is restored to
/// `current_page` before returning so subsequent page-nav (`prev`/`next`
/// from the popup or arrow keys) operates from the user-visible page.
fn collect_all_candidates(
    current_items: Vec<CandidateItem>,
    current_page: u32,
    total_pages: u32,
) -> Vec<CandidateItem> {
    if total_pages <= 1 {
        return current_items;
    }

    let page_size = PAGE_SIZE as usize;
    let mut all = Vec::with_capacity(total_pages as usize * page_size);

    for page in 1..=total_pages {
        if page == current_page {
            all.extend(current_items.iter().cloned());
        } else {
            let result = jd::jump_to_page(page);
            for opt in result.options {
                all.push(CandidateItem {
                    value: opt.value,
                    hint: opt.hint,
                });
            }
        }
    }

    // Restore the engine cursor to the page our popup is showing so
    // subsequent next/prev calls navigate relative to it.
    let _ = jd::jump_to_page(current_page);
    all
}

fn begin(
    thread_mgr: &ITfThreadMgr,
    all_items: Vec<CandidateItem>,
    current_page: u32,
    total_pages: u32,
    total_count: u32,
) -> Result<()> {
    let mgr: ITfUIElementMgr = thread_mgr.cast()?;
    let elem = CandidateListUIElement {
        state: RefCell::new(ElementState {
            thread_mgr: Some(thread_mgr.clone()),
            all_items,
            current_page,
            total_pages,
            total_count,
        }),
    };
    let iface: ITfUIElement = elem.into_object().into_interface();
    let mut pb_show = BOOL(1);
    let mut id: u32 = 0;
    unsafe { mgr.BeginUIElement(&iface, &mut pb_show, &mut id) }?;

    let initial_shown = pb_show.0 != 0;
    let previously = IS_SHOWN.with(|c| c.replace(initial_shown));
    if previously != initial_shown {
        candidate_window::sync_visibility();
    }

    // Some hosts (notably LoL's in-game chat) treat `BeginUIElement` as a
    // registration step and only render the candidate list after they
    // receive their first `UpdateUIElement`. Without this nudge, the popup
    // doesn't appear until the user's second keystroke — the first
    // keystroke shows the composition underline but no candidate UI.
    let _ = unsafe { mgr.UpdateUIElement(id) };

    ID.with(|c| c.set(Some(id)));
    MGR.with(|c| *c.borrow_mut() = Some(mgr));
    ELEMENT.with(|c| *c.borrow_mut() = Some(iface));

    Ok(())
}

fn update(
    all_items: Vec<CandidateItem>,
    current_page: u32,
    total_pages: u32,
    total_count: u32,
) -> Result<()> {
    let element = ELEMENT.with(|c| c.borrow().clone());
    let Some(iface) = element else { return Ok(()) };

    let inner = iface.cast_object::<CandidateListUIElement>()?;
    {
        let mut s = inner.state.borrow_mut();
        s.all_items = all_items;
        s.current_page = current_page;
        s.total_pages = total_pages;
        s.total_count = total_count;
    }

    let pair = MGR.with(|m| {
        let m = m.borrow();
        let mgr = m.as_ref().cloned();
        let id = ID.with(|i| i.get());
        mgr.zip(id)
    });
    if let Some((mgr, id)) = pair {
        let _ = unsafe { mgr.UpdateUIElement(id) };
    }
    Ok(())
}

/// Called when the candidate list goes away (composition committed,
/// cancelled, or externally terminated). Releases the element from the
/// host's tracking.
pub fn end() {
    let pair = MGR.with(|m| {
        let m = m.borrow();
        let mgr = m.as_ref().cloned();
        let id = ID.with(|i| i.get());
        mgr.zip(id)
    });
    if let Some((mgr, id)) = pair {
        let _ = unsafe { mgr.EndUIElement(id) };
    }
    ELEMENT.with(|c| *c.borrow_mut() = None);
    MGR.with(|c| *c.borrow_mut() = None);
    ID.with(|c| c.set(None));
    // Reset to "popup is visible by default" so the next composition opens
    // with the normal in-IME UI unless a new host opts out.
    IS_SHOWN.with(|c| c.set(true));
}

/// Tear-down at IME deactivation.
pub fn destroy() {
    end();
}

/// Read by the candidate window to decide whether to render its popup.
pub fn is_shown() -> bool {
    IS_SHOWN.with(|c| c.get())
}
