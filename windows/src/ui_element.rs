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
    ITfUIElement, ITfUIElementMgr, ITfUIElement_Impl, TF_CLUIE_COUNT, TF_CLUIE_CURRENTPAGE,
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
    items: Vec<CandidateItem>,
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
        let page_size = PAGE_SIZE as u32;

        // Read the snapshot fields and drop the borrow before any engine
        // call — `jd::ENGINE` calls don't reenter us today, but releasing
        // the borrow keeps future refactors safe and removes an aliasing
        // hazard if `GetString` is ever called recursively.
        let (current_page, total_count, local_idx, target_page, fast_path_item) = {
            let state = self.state.borrow();
            if uindex >= state.total_count {
                return Err(E_INVALIDARG.into());
            }
            let target = uindex / page_size + 1;
            let local = (uindex % page_size) as usize;
            let fast = if target == state.current_page {
                state.items.get(local).cloned()
            } else {
                None
            };
            (state.current_page, state.total_count, local, target, fast)
        };

        if let Some(item) = fast_path_item {
            return Ok(BSTR::from(&item.value));
        }

        let _ = total_count;

        // Cross-page query — jump the engine to the target page, snapshot
        // the string, then jump back so the engine's notion of "current
        // page" stays in sync with what our popup is showing. Each jump is
        // one BFS rewind + materialization in the worst case; cheap.
        let target_result = jd::ENGINE.jump_to_page(target_page);
        let snapshot = target_result.options.get(local_idx).map(|o| o.value.clone());
        // Always restore, even if the lookup failed.
        let _ = jd::ENGINE.jump_to_page(current_page);

        match snapshot {
            Some(s) => Ok(BSTR::from(&s)),
            None => Err(E_INVALIDARG.into()),
        }
    }

    fn GetPageIndex(
        &self,
        pindex: *mut u32,
        size: u32,
        pupagecnt: *mut u32,
    ) -> Result<()> {
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
pub fn sync(
    thread_mgr: &ITfThreadMgr,
    items: Vec<CandidateItem>,
    current_page: u32,
    total_pages: u32,
    total_count: u32,
) {
    let need_begin = ELEMENT.with(|e| e.borrow().is_none());

    if need_begin {
        let _ = begin(thread_mgr, items, current_page, total_pages, total_count);
    } else {
        let _ = update(items, current_page, total_pages, total_count);
    }
}

fn begin(
    thread_mgr: &ITfThreadMgr,
    items: Vec<CandidateItem>,
    current_page: u32,
    total_pages: u32,
    total_count: u32,
) -> Result<()> {
    let mgr: ITfUIElementMgr = thread_mgr.cast()?;
    let elem = CandidateListUIElement {
        state: RefCell::new(ElementState {
            thread_mgr: Some(thread_mgr.clone()),
            items,
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

    ID.with(|c| c.set(Some(id)));
    MGR.with(|c| *c.borrow_mut() = Some(mgr));
    ELEMENT.with(|c| *c.borrow_mut() = Some(iface));

    Ok(())
}

fn update(
    items: Vec<CandidateItem>,
    current_page: u32,
    total_pages: u32,
    total_count: u32,
) -> Result<()> {
    let element = ELEMENT.with(|c| c.borrow().clone());
    let Some(iface) = element else { return Ok(()) };

    let inner = iface.cast_object::<CandidateListUIElement>()?;
    {
        let mut s = inner.state.borrow_mut();
        s.items = items;
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
