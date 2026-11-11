use std::cell::{Cell, RefCell};
use std::mem::ManuallyDrop;

use windows::Win32::Foundation::RECT;

use windows::Win32::Foundation::E_FAIL;
use windows::Win32::UI::TextServices::{
    ITfComposition, ITfCompositionSink, ITfContext, ITfContextComposition, ITfDocumentMgr,
    ITfEditSession, TF_AE_NONE, TF_ANCHOR_END, TF_DEFAULT_SELECTION, TF_ES_ASYNCDONTCARE,
    TF_ES_READ, TF_ES_READWRITE, TF_ES_SYNC, TF_SELECTION, TF_SELECTIONSTYLE, TS_E_NOLAYOUT,
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
    /// Where the composition is on the screen, as `ITfContextView::GetTextExt`
    /// last told — inside the edit session that wrote the text, or in
    /// `locate`'s. Read by the candidate window to position the popup. A
    /// new composition starts from `Unknown`: where the last one was says
    /// nothing of where this one is.
    static LOCATION: Cell<Location> = const { Cell::new(Location::Unknown) };
    /// Whether `locate` has a question out to the application.
    static LOCATING: Cell<bool> = const { Cell::new(false) };
}

/// Where the composition is on the screen, as far as the application has
/// said since it started.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Location {
    /// The rect of its text — the last one given, if the application has
    /// stopped giving one since.
    At(RECT),
    /// The application has not laid the new text out yet (TS_E_NOLAYOUT),
    /// and is to say when it has: `locate`'s cue.
    Pending,
    /// The application will not say.
    Unknown,
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
                LOCATION.with(|c| c.set(Location::Unknown));
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

/// The engine's commit-and-jump: commit `text` and go on composing `ch`, the
/// key that began the next code — on the same composition, in one edit
/// session. The committed text leaves the composition from the front
/// (`ShiftStart` past it), so the host sees text committed while the
/// composition carries on, never a composition ending and another starting
/// in the same keystroke: Excel's cell editor finalizes, as typed, a
/// composition started right after one ended, so `nkhze` put `你好e` in the
/// cell and left nothing composing. Starts the composition if none is in
/// flight.
pub fn commit_and_continue(
    ctx: &ITfContext,
    tid: u32,
    sink: &ITfCompositionSink,
    text: &str,
    ch: char,
) -> Result<()> {
    let ctx_for_session = ctx.clone();
    let sink_for_session = sink.clone();
    let text_owned = text.to_string();
    let session = EditSession::new(move |ec| {
        STATE.with(|s| -> Result<()> {
            let mut state = s.borrow_mut();
            if state.composition.is_none() {
                state.composition =
                    Some(start_composition(&ctx_for_session, ec, &sink_for_session)?);
                LOCATION.with(|c| c.set(Location::Unknown));
            }
            state.buffer.clear();
            state.buffer.push(ch);
            let comp = state.composition.as_ref().unwrap();
            let range = unsafe { comp.GetRange() }?;
            let wide: Vec<u16> = text_owned.encode_utf16().collect();
            unsafe { range.SetText(ec, 0, &wide) }?;
            let _ = display_attribute::clear(&ctx_for_session, ec, &range);
            // The composition now starts where the committed text ends, and
            // is empty until the typed key goes in.
            unsafe { range.Collapse(ec, TF_ANCHOR_END) }?;
            unsafe { comp.ShiftStart(ec, &range) }?;
            update_composition(&ctx_for_session, comp, ec, &state.buffer)?;
            refresh_screen_rect(&ctx_for_session, ec, comp);
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
    request_session(ctx, tid, commit_session(ctx.clone()))
}

/// `commit`, for an end that came from outside a key event — a switch to 英
/// by the mode icon, an application or a hotkey, or the focus gone to
/// another document — and so names no context: the composition's own is
/// used, and TSF runs the edit at once if it can, or as soon as the document
/// is free. The composition leaves this thread's state here and now,
/// whenever the edit runs, so the next key starts afresh. No-op if there's
/// no composition.
pub fn commit_as_typed(tid: u32) -> Result<()> {
    let comp = STATE.with(|s| {
        // Called from TSF's sinks: never while an edit of ours holds the
        // state.
        let mut state = s.try_borrow_mut().ok()?;
        state.buffer.clear();
        state.composition.take()
    });
    let Some(comp) = comp else {
        return Ok(());
    };
    let ctx = unsafe { comp.GetRange().and_then(|range| range.GetContext()) }?;
    let ctx_for_session = ctx.clone();
    let session = EditSession::new(move |ec| {
        // As in `commit_session`: the text stops rendering as in-flight.
        let range = unsafe { comp.GetRange() }?;
        let _ = display_attribute::clear(&ctx_for_session, ec, &range);
        unsafe { comp.EndComposition(ec) }
    });
    let iface: ITfEditSession = session.into_object().into_interface();
    let _ = unsafe { ctx.RequestEditSession(tid, &iface, TF_ES_ASYNCDONTCARE | TF_ES_READWRITE) }?;
    Ok(())
}

/// End the composition, leaving its text — the letters as typed — in the
/// document.
fn commit_session(ctx: ITfContext) -> EditSession {
    EditSession::new(move |ec| {
        STATE.with(|s| -> Result<()> {
            let mut state = s.borrow_mut();
            if let Some(comp) = state.composition.take() {
                // Strip the display attribute from the now-committed text so
                // it stops rendering as in-flight. SampleIME does the same in
                // `_ClearCompositionDisplayAttributes`.
                let range = unsafe { comp.GetRange() }?;
                let _ = display_attribute::clear(&ctx, ec, &range);
                unsafe { comp.EndComposition(ec) }?;
            }
            state.buffer.clear();
            Ok(())
        })
    })
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
/// external (focus loss, app rejection, etc.) ended `comp`. The composition
/// is already gone in TSF's eyes and its text stays in the document; `ec`
/// is the write access TSF lends the sink to finish with that text, and
/// what is left on it is the display attribute — taken off here, as every
/// end of our own takes it off, or the letters stay underlined as in flight
/// for as long as they are there.
///
/// Returns whether that was the end of what this thread was composing, and
/// drops our handles if so. It was not if `comp` is one `commit_as_typed`
/// let go of and another has been started since.
pub fn on_externally_terminated(ec: u32, comp: Option<&ITfComposition>) -> bool {
    if let Some(comp) = comp
        // SAFETY: plain calls on the composition TSF handed over.
        && let Ok(range) = unsafe { comp.GetRange() }
        && let Ok(ctx) = unsafe { range.GetContext() }
    {
        let _ = display_attribute::clear(&ctx, ec, &range);
    }
    let in_flight = STATE.with(|s| {
        // Called from TSF's sink: never while an edit of ours holds the
        // state.
        let Ok(mut state) = s.try_borrow_mut() else {
            return false;
        };
        if let (Some(own), Some(comp)) = (state.composition.as_ref(), comp)
            && own != comp
        {
            return false;
        }
        state.composition = None;
        state.buffer.clear();
        true
    });
    if in_flight {
        LOCATION.with(|c| c.set(Location::Unknown));
    }
    in_flight
}

/// Drop this thread's handles on a composition without a word to the
/// document: for `Deactivate`, which has no access to it. TSF ends what is
/// still open there and says so through `on_externally_terminated`.
pub fn forget() {
    STATE.with(|s| {
        let mut state = s.borrow_mut();
        state.composition = None;
        state.buffer.clear();
    });
    LOCATION.with(|c| c.set(Location::Unknown));
}

/// Whether there is currently an in-flight composition.
pub fn is_active() -> bool {
    STATE.with(|s| s.borrow().composition.is_some())
}

/// Whether a composition is in flight in a context other than `ctx`. A
/// composition stays in the context it was started in: a key that arrives
/// for another one is not its to take.
pub fn is_elsewhere(ctx: &ITfContext) -> bool {
    context().is_some_and(|own| own != *ctx)
}

/// Whether a composition is in flight in a document other than `focus`, the
/// one the focus is in now — if it is in any.
pub fn is_outside(focus: Option<&ITfDocumentMgr>) -> bool {
    context().is_some_and(|own| {
        // SAFETY: a plain call on the composition's own context.
        let document = unsafe { own.GetDocumentMgr() }.ok();
        document.as_ref() != focus
    })
}

/// The context of the composition in flight.
fn context() -> Option<ITfContext> {
    STATE.with(|s| {
        // Asked from TSF's sinks too: never while an edit of ours holds the
        // state.
        let state = s.try_borrow().ok()?;
        let comp = state.composition.as_ref()?;
        // SAFETY: plain calls on the composition's own range.
        unsafe { comp.GetRange().and_then(|range| range.GetContext()) }.ok()
    })
}

/// Where the composition is on the screen: the rect of its text, for the
/// popups (candidate window, etc.) to hang under, if the host has supplied
/// one since the composition started (Settings UI / classic edit controls
/// usually return a rect on first try; Chromium-based hosts may need a
/// second composition update).
pub fn location() -> Location {
    LOCATION.with(|c| c.get())
}

/// The application's layout changed — it scrolled, its window moved, or the
/// layout it had not got to when the composition was written (TS_E_NOLAYOUT)
/// is ready: ask where the composition is now, and hand the answer to
/// `found`. Asking takes an edit session of its own, which TSF runs at once
/// if the document is free and as soon as it is otherwise — a layout change
/// is often announced from inside the very edit that caused it. One question
/// is out at a time: a change announced before it is answered is covered by
/// the answer.
pub fn locate(tid: u32, found: impl FnOnce(RECT) + 'static) {
    let Some(ctx) = context() else {
        return;
    };
    let Some(asking) = Locating::begin() else {
        return;
    };
    let ctx_for_session = ctx.clone();
    let session = EditSession::new(move |ec| {
        let _asking = asking;
        let rect = STATE.with(|s| {
            // TSF's call, at a time of its choosing: never while an edit of
            // ours holds the state — that edit reads the rect itself.
            let state = s.try_borrow().ok()?;
            let comp = state.composition.as_ref()?;
            refresh_screen_rect(&ctx_for_session, ec, comp)
        });
        if let Some(rect) = rect {
            found(rect);
        }
        Ok(())
    });
    let iface: ITfEditSession = session.into_object().into_interface();
    let _ = unsafe { ctx.RequestEditSession(tid, &iface, TF_ES_ASYNCDONTCARE | TF_ES_READ) };
}

/// `locate`'s question, out to the application for as long as this lives:
/// it goes with the edit session that asks, whether TSF runs that or drops
/// it.
struct Locating;

impl Locating {
    /// `None` while another question is out.
    fn begin() -> Option<Self> {
        if LOCATING.with(|c| c.replace(true)) {
            None
        } else {
            Some(Self)
        }
    }
}

impl Drop for Locating {
    fn drop(&mut self) {
        LOCATING.with(|c| c.set(false));
    }
}

/// Ask the application where the composition is on the screen, and keep the
/// answer for `location`. Returns the rect if it gave one.
fn refresh_screen_rect(ctx: &ITfContext, ec: u32, comp: &ITfComposition) -> Option<RECT> {
    let answer = (|| -> Result<RECT> {
        let view = unsafe { ctx.GetActiveView() }?;
        let range = unsafe { comp.GetRange() }?;
        let mut rect = RECT::default();
        let mut clipped = BOOL::default();
        unsafe { view.GetTextExt(ec, &range, &mut rect, &mut clipped) }?;
        Ok(rect)
    })();
    let rect = answer.as_ref().ok().copied();
    LOCATION.with(|c| c.set(located(c.get(), answer)));
    rect
}

/// What an answer to "where is the composition" makes of what was known.
fn located(known: Location, answer: Result<RECT>) -> Location {
    match answer {
        Ok(rect) => Location::At(rect),
        // If GetTextExt failed (TS_E_NOLAYOUT, etc.), an earlier rect of
        // this composition is still our best guess; the popup won't jump.
        Err(_) if matches!(known, Location::At(_)) => known,
        Err(e) if e.code() == TS_E_NOLAYOUT => Location::Pending,
        Err(_) => Location::Unknown,
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::Foundation::E_NOTIMPL;
    use windows::Win32::UI::TextServices::{ITfComposition_Impl, ITfRange};
    use windows::core::{Ref, implement};

    /// A composition as far as telling one from another goes: it is in no
    /// document, so there is no text to reach through it.
    #[implement(ITfComposition)]
    struct Stub;

    impl ITfComposition_Impl for Stub_Impl {
        fn GetRange(&self) -> Result<ITfRange> {
            Err(E_NOTIMPL.into())
        }

        fn ShiftStart(&self, _ecwrite: u32, _pnewstart: Ref<'_, ITfRange>) -> Result<()> {
            Err(E_NOTIMPL.into())
        }

        fn ShiftEnd(&self, _ecwrite: u32, _pnewend: Ref<'_, ITfRange>) -> Result<()> {
            Err(E_NOTIMPL.into())
        }

        fn EndComposition(&self, _ecwrite: u32) -> Result<()> {
            Err(E_NOTIMPL.into())
        }
    }

    fn stub() -> ITfComposition {
        Stub.into_object().into_interface()
    }

    /// This thread composing `buffer` in `comp`.
    fn compose(comp: &ITfComposition, buffer: &str) {
        STATE.with(|s| {
            let mut state = s.borrow_mut();
            state.composition = Some(comp.clone());
            state.buffer = buffer.to_owned();
        });
    }

    #[test]
    fn only_the_composition_in_flight_ends_with_its_termination() {
        let (ours, another) = (stub(), stub());
        compose(&ours, "nk");
        // One let go of earlier, ended at last: nothing of what is being
        // typed now goes with it.
        assert!(!on_externally_terminated(0, Some(&another)));
        assert!(is_active());
        STATE.with(|s| assert_eq!(s.borrow().buffer, "nk"));

        // The one in flight.
        assert!(on_externally_terminated(0, Some(&ours)));
        assert!(!is_active());
        STATE.with(|s| assert!(s.borrow().buffer.is_empty()));

        // With none in flight — after `Deactivate`, which TSF follows with
        // this call — there is nothing to keep.
        assert!(on_externally_terminated(0, Some(&another)));
        assert!(on_externally_terminated(0, None));
        assert!(!is_active());
    }

    #[test]
    fn a_composition_is_where_the_application_last_said() {
        use Location::{At, Pending, Unknown};
        let rect = |left| RECT {
            left,
            top: 10,
            right: left + 20,
            bottom: 34,
        };
        let no_layout = || Err(TS_E_NOLAYOUT.into());
        let failed = || Err(E_FAIL.into());

        // Nothing known: the application's word, and what it promises.
        assert_eq!(located(Unknown, Ok(rect(1))), At(rect(1)));
        assert_eq!(located(Unknown, no_layout()), Pending);
        assert_eq!(located(Unknown, failed()), Unknown);
        // Waited for: the layout, when it is ready — or no more waiting.
        assert_eq!(located(Pending, Ok(rect(2))), At(rect(2)));
        assert_eq!(located(Pending, no_layout()), Pending);
        assert_eq!(located(Pending, failed()), Unknown);
        // Known: the newer rect, or the one in hand for want of one.
        assert_eq!(located(At(rect(3)), Ok(rect(4))), At(rect(4)));
        assert_eq!(located(At(rect(3)), no_layout()), At(rect(3)));
        assert_eq!(located(At(rect(3)), failed()), At(rect(3)));
    }

    #[test]
    fn one_question_about_the_layout_is_out_at_a_time() {
        let asking = Locating::begin();
        assert!(asking.is_some());
        assert!(Locating::begin().is_none());
        assert!(Locating::begin().is_none());
        // Answered, or dropped unasked: the next one may go out.
        drop(asking);
        assert!(Locating::begin().is_some());
        assert!(Locating::begin().is_some());
    }
}
