use std::cell::{Cell, RefCell};
use std::mem::ManuallyDrop;

use windows::Win32::Foundation::RECT;

use windows::Win32::Foundation::E_FAIL;
use windows::Win32::UI::TextServices::{
    ITfComposition, ITfCompositionSink, ITfContext, ITfContextComposition, ITfEditSession,
    TF_AE_NONE, TF_ANCHOR_END, TF_DEFAULT_SELECTION, TF_ES_READWRITE, TF_ES_SYNC, TF_SELECTION,
    TF_SELECTIONSTYLE,
};
use windows::core::{BOOL, ComObjectInner, Interface, Result};

use crate::display_attribute;
use crate::edit_session::EditSession;

// One composition can be active per UI thread. TSF gives each UI thread its
// own TextInputProcessor instance, so per-thread state matches the model.
// Using thread_local lets the EditSession closures access state without
// threading a handle to the TextInputProcessor through every call site.
thread_local! {
    static STATE: RefCell<CompositionState> = const { RefCell::new(CompositionState::new()) };
    /// Screen rect of the most recent composition range, as reported by
    /// `ITfContextView::GetTextExt` inside the same edit session that wrote
    /// the text. Read by the candidate window to position the popup.
    /// `None` if the host hasn't laid out the new text yet (TF_E_NOLAYOUT)
    /// or if no composition has run on this thread.
    static LAST_SCREEN_RECT: Cell<Option<RECT>> = const { Cell::new(None) };
}

struct CompositionState {
    buffer: String,
    composition: Option<ITfComposition>,
}

impl CompositionState {
    const fn new() -> Self {
        Self {
            buffer: String::new(),
            composition: None,
        }
    }
}

/// Called from OnKeyDown for each consumable letter. Starts a composition on
/// the first key, then extends the buffer + replaces the composition's text
/// on every subsequent key.
pub fn append_key(ctx: &ITfContext, tid: u32, sink: &ITfCompositionSink, ch: char) -> Result<()> {
    let ctx_for_session = ctx.clone();
    let sink_for_session = sink.clone();
    let session = EditSession::new(move |ec| {
        STATE.with(|s| -> Result<()> {
            let mut state = s.borrow_mut();
            if state.composition.is_none() {
                state.composition =
                    Some(start_composition(&ctx_for_session, ec, &sink_for_session)?);
            }
            state.buffer.push(ch);
            let comp = state.composition.as_ref().unwrap();
            update_composition(&ctx_for_session, comp, ec, &state.buffer)?;
            refresh_screen_rect(&ctx_for_session, ec, comp);
            Ok(())
        })
    });
    request_session(ctx, tid, session)
}

/// Called on space (or any other commit trigger). Ends the current composition
/// — the in-flight text becomes plain text in the document — and clears the
/// buffer. No-op if there's no composition.
/// Commit the composition with a specific text value (replaces whatever was
/// being displayed). Use this when a candidate is selected — the IME's choice
/// of text differs from the raw buffer the user typed.
pub fn commit_text(ctx: &ITfContext, tid: u32, text: &str) -> Result<()> {
    let ctx_for_session = ctx.clone();
    let text_owned = text.to_string();
    let session = EditSession::new(move |ec| {
        STATE.with(|s| -> Result<()> {
            let mut state = s.borrow_mut();
            if let Some(comp) = state.composition.take() {
                let range = unsafe { comp.GetRange() }?;
                let wide: Vec<u16> = text_owned.encode_utf16().collect();
                unsafe { range.SetText(ec, 0, &wide) }?;
                let _ = display_attribute::clear(&ctx_for_session, ec, &range);
                unsafe { range.Collapse(ec, TF_ANCHOR_END) }?;
                let mut sel = [TF_SELECTION {
                    range: ManuallyDrop::new(Some(range)),
                    style: TF_SELECTIONSTYLE {
                        ase: TF_AE_NONE,
                        fInterimChar: BOOL(0),
                    },
                }];
                unsafe { ctx_for_session.SetSelection(ec, &sel) }?;
                unsafe { ManuallyDrop::drop(&mut sel[0].range) };
                unsafe { comp.EndComposition(ec) }?;
            }
            state.buffer.clear();
            Ok(())
        })
    });
    request_session(ctx, tid, session)
}

/// Drop the last char from the composition buffer and re-paint. If the buffer
/// becomes empty, end the composition entirely. Caller is responsible for
/// keeping the engine in sync (see tip.rs's VK_BACK handler).
pub fn backspace(ctx: &ITfContext, tid: u32) -> Result<()> {
    let ctx_for_session = ctx.clone();
    let session = EditSession::new(move |ec| {
        STATE.with(|s| -> Result<()> {
            let mut state = s.borrow_mut();
            state.buffer.pop();
            let buffer = state.buffer.clone();
            if buffer.is_empty() {
                if let Some(comp) = state.composition.take() {
                    let range = unsafe { comp.GetRange() }?;
                    let empty: Vec<u16> = Vec::new();
                    unsafe { range.SetText(ec, 0, &empty) }?;
                    let _ = display_attribute::clear(&ctx_for_session, ec, &range);
                    unsafe { comp.EndComposition(ec) }?;
                }
            } else if let Some(comp) = state.composition.as_ref() {
                update_composition(&ctx_for_session, comp, ec, &buffer)?;
            }
            Ok(())
        })
    });
    request_session(ctx, tid, session)
}

pub fn commit(ctx: &ITfContext, tid: u32) -> Result<()> {
    let ctx_for_session = ctx.clone();
    let session = EditSession::new(move |ec| {
        STATE.with(|s| -> Result<()> {
            let mut state = s.borrow_mut();
            if let Some(comp) = state.composition.take() {
                // Strip the display attribute from the now-committed text so
                // it stops rendering as in-flight. SampleIME does the same in
                // `_ClearCompositionDisplayAttributes`.
                let range = unsafe { comp.GetRange() }?;
                let _ = display_attribute::clear(&ctx_for_session, ec, &range);
                unsafe { comp.EndComposition(ec) }?;
            }
            state.buffer.clear();
            Ok(())
        })
    });
    request_session(ctx, tid, session)
}

/// Tear down the composition WITHOUT committing (Escape): the in-flight text
/// is removed from the document entirely, matching integration.md's "Escape /
/// Cancel → tear down the composition without committing" and the macOS
/// frontend's `Composition.cancel`. Same teardown as the backspace-to-empty
/// path above; `commit` differs only in leaving the text in place. No-op if
/// there's no composition.
pub fn cancel(ctx: &ITfContext, tid: u32) -> Result<()> {
    let ctx_for_session = ctx.clone();
    let session = EditSession::new(move |ec| {
        STATE.with(|s| -> Result<()> {
            let mut state = s.borrow_mut();
            if let Some(comp) = state.composition.take() {
                let range = unsafe { comp.GetRange() }?;
                let empty: Vec<u16> = Vec::new();
                unsafe { range.SetText(ec, 0, &empty) }?;
                let _ = display_attribute::clear(&ctx_for_session, ec, &range);
                unsafe { comp.EndComposition(ec) }?;
            }
            state.buffer.clear();
            Ok(())
        })
    });
    request_session(ctx, tid, session)
}

/// Called by ITfCompositionSink::OnCompositionTerminated when something
/// external (focus loss, app rejection, etc.) ended our composition. Just
/// drop our handles; the composition is already gone in TSF's eyes.
pub fn on_externally_terminated() {
    STATE.with(|s| {
        let mut state = s.borrow_mut();
        state.composition = None;
        state.buffer.clear();
    });
    LAST_SCREEN_RECT.with(|c| c.set(None));
}

/// Whether there is currently an in-flight composition.
pub fn is_active() -> bool {
    STATE.with(|s| s.borrow().composition.is_some())
}

/// Screen rect of the most recently-rendered composition range, if the host
/// supplied one. Use the bottom-left as the anchor for popups (candidate
/// window, etc.). Returns `None` if the host returned TF_E_NOLAYOUT for the
/// last query (Settings UI / classic edit controls usually return a rect on
/// first try; Chromium-based hosts may need a second composition update).
pub fn last_screen_rect() -> Option<RECT> {
    LAST_SCREEN_RECT.with(|c| c.get())
}

fn refresh_screen_rect(ctx: &ITfContext, ec: u32, comp: &ITfComposition) {
    use windows::core::BOOL;
    let Ok(view) = (unsafe { ctx.GetActiveView() }) else {
        return;
    };
    let Ok(range) = (unsafe { comp.GetRange() }) else {
        return;
    };
    let mut rect = RECT::default();
    let mut clipped = BOOL::default();
    let r = unsafe { view.GetTextExt(ec, &range, &mut rect, &mut clipped) };
    if r.is_ok() {
        LAST_SCREEN_RECT.with(|c| c.set(Some(rect)));
    }
    // If GetTextExt failed (TF_E_NOLAYOUT, etc.) leave the cache as-is.
    // The previous rect is still our best guess; the popup won't jump.
}

fn request_session(ctx: &ITfContext, tid: u32, session: EditSession) -> Result<()> {
    let iface: ITfEditSession = session.into_object().into_interface();
    let _ = unsafe { ctx.RequestEditSession(tid, &iface, TF_ES_SYNC | TF_ES_READWRITE) }?;
    Ok(())
}

fn start_composition(
    ctx: &ITfContext,
    ec: u32,
    sink: &ITfCompositionSink,
) -> Result<ITfComposition> {
    let ctx_comp: ITfContextComposition = ctx.cast()?;
    let mut selection: [TF_SELECTION; 1] = unsafe { std::mem::zeroed() };
    let mut fetched: u32 = 0;
    unsafe {
        ctx.GetSelection(ec, TF_DEFAULT_SELECTION, &mut selection, &mut fetched)?;
    }
    if fetched == 0 {
        return Err(E_FAIL.into());
    }
    let range = unsafe { ManuallyDrop::take(&mut selection[0].range) }
        .ok_or_else(|| -> windows::core::Error { E_FAIL.into() })?;
    unsafe { ctx_comp.StartComposition(ec, &range, sink) }
}

/// Set the composition's text, paint the display attribute over it, and
/// move the document caret to the end — all in one shot on one ITfRange so
/// the host sees a consistent view.
fn update_composition(ctx: &ITfContext, comp: &ITfComposition, ec: u32, text: &str) -> Result<()> {
    let range = unsafe { comp.GetRange() }?;
    let wide: Vec<u16> = text.encode_utf16().collect();
    unsafe { range.SetText(ec, 0, &wide) }?;
    // Underline the composition while it's in flight.
    let _ = display_attribute::apply(ctx, ec, &range);
    // After SetText the range covers the new text; collapse to the end and
    // SetSelection so the caret follows. Matches Microsoft SampleIME's
    // `_SetInputString` and Weasel's `CInsertTextEditSession`.
    unsafe { range.Collapse(ec, TF_ANCHOR_END) }?;
    let mut sel = [TF_SELECTION {
        range: ManuallyDrop::new(Some(range)),
        style: TF_SELECTIONSTYLE {
            ase: TF_AE_NONE,
            fInterimChar: BOOL(0),
        },
    }];
    unsafe { ctx.SetSelection(ec, &sel) }?;
    unsafe { ManuallyDrop::drop(&mut sel[0].range) };
    Ok(())
}
