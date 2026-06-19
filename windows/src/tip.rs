use std::cell::RefCell;

use windows::Win32::Foundation::{E_INVALIDARG, LPARAM, WPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, GetKeyboardState, ToUnicode};
use windows::Win32::UI::TextServices::{
    IEnumTfDisplayAttributeInfo, ITfComposition, ITfCompositionSink, ITfCompositionSink_Impl,
    ITfContext, ITfDisplayAttributeInfo, ITfDisplayAttributeProvider,
    ITfDisplayAttributeProvider_Impl, ITfKeyEventSink, ITfKeyEventSink_Impl, ITfKeystrokeMgr,
    ITfTextInputProcessor, ITfTextInputProcessor_Impl, ITfTextInputProcessorEx,
    ITfTextInputProcessorEx_Impl, ITfThreadMgr,
};
use windows::core::{BOOL, ComObjectInner, GUID, IUnknownImpl, Interface, Ref, Result, implement};

use crate::candidate_window::{self, CandidateItem};
use crate::display_attribute::{DisplayAttributeEnum, DisplayAttributeInfo};
use crate::guids::GUID_JD_DISPLAY_ATTRIBUTE;
use crate::{composition, jd, ui_element};

#[implement(
    ITfTextInputProcessorEx,
    ITfTextInputProcessor,
    ITfKeyEventSink,
    ITfCompositionSink,
    ITfDisplayAttributeProvider
)]
#[derive(Default)]
pub struct TextInputProcessor {
    state: RefCell<TipState>,
}

#[derive(Default)]
struct TipState {
    thread_mgr: Option<ITfThreadMgr>,
    client_id: u32,
}

impl ITfTextInputProcessor_Impl for TextInputProcessor_Impl {
    fn Activate(&self, ptim: Ref<'_, ITfThreadMgr>, tid: u32) -> Result<()> {
        ITfTextInputProcessorEx_Impl::ActivateEx(self, ptim, tid, 0)
    }

    fn Deactivate(&self) -> Result<()> {
        let state = self.state.borrow();
        if let Some(thread_mgr) = state.thread_mgr.as_ref() {
            if let Ok(keystroke_mgr) = thread_mgr.cast::<ITfKeystrokeMgr>() {
                let _ = unsafe { keystroke_mgr.UnadviseKeyEventSink(state.client_id) };
            }
        }
        drop(state);
        *self.state.borrow_mut() = TipState::default();
        composition::on_externally_terminated();
        ui_element::destroy();
        candidate_window::destroy();
        jd::deactivate();
        Ok(())
    }
}

impl ITfTextInputProcessorEx_Impl for TextInputProcessor_Impl {
    fn ActivateEx(&self, ptim: Ref<'_, ITfThreadMgr>, tid: u32, _dwflags: u32) -> Result<()> {
        jd::activate();

        let thread_mgr: ITfThreadMgr = ptim
            .cloned()
            .ok_or_else(|| -> windows::core::Error { E_INVALIDARG.into() })?;
        let keystroke_mgr: ITfKeystrokeMgr = thread_mgr.cast()?;
        let key_sink: ITfKeyEventSink = self.to_interface();
        unsafe { keystroke_mgr.AdviseKeyEventSink(tid, &key_sink, true) }?;

        *self.state.borrow_mut() = TipState {
            thread_mgr: Some(thread_mgr),
            client_id: tid,
        };
        Ok(())
    }
}

impl ITfDisplayAttributeProvider_Impl for TextInputProcessor_Impl {
    fn EnumDisplayAttributeInfo(&self) -> Result<IEnumTfDisplayAttributeInfo> {
        Ok(DisplayAttributeEnum::default()
            .into_object()
            .into_interface())
    }

    fn GetDisplayAttributeInfo(&self, guid: *const GUID) -> Result<ITfDisplayAttributeInfo> {
        if guid.is_null() {
            return Err(E_INVALIDARG.into());
        }
        if unsafe { *guid } != GUID_JD_DISPLAY_ATTRIBUTE {
            return Err(E_INVALIDARG.into());
        }
        Ok(DisplayAttributeInfo.into_object().into_interface())
    }
}

impl ITfKeyEventSink_Impl for TextInputProcessor_Impl {
    fn OnSetFocus(&self, _fforeground: BOOL) -> Result<()> {
        Ok(())
    }

    fn OnTestKeyDown(
        &self,
        _pic: Ref<'_, ITfContext>,
        wparam: WPARAM,
        _lparam: LPARAM,
    ) -> Result<BOOL> {
        Ok(BOOL(if should_consume(wparam.0 as u16) {
            1
        } else {
            0
        }))
    }

    fn OnTestKeyUp(
        &self,
        _pic: Ref<'_, ITfContext>,
        _wparam: WPARAM,
        _lparam: LPARAM,
    ) -> Result<BOOL> {
        Ok(BOOL(0))
    }

    fn OnKeyDown(&self, pic: Ref<'_, ITfContext>, wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        let vk = wparam.0 as u16;
        let Some(ctx_ref) = pic.as_ref() else {
            return Ok(BOOL(0));
        };
        let ctx = ctx_ref;
        let tid = self.state.borrow().client_id;
        let sink: ITfCompositionSink = self.to_interface();

        // Modifier chords (Ctrl/Alt/Win + anything) are host shortcuts —
        // never route them to the engine.
        let m = mods();
        if m.ctrl || m.alt || m.win {
            return Ok(BOOL(0));
        }

        // Compute the shift-aware byte once. Used for the digit selector,
        // `-`/`=` page-nav (which want the *unshifted* variants only), and
        // the final engine-byte dispatch.
        let translated = translate(vk);

        // -- While composing: navigate / select / cancel --------------------
        if composition::is_active() {
            // Page navigation. Arrow keys + PgUp/PgDn always paginate.
            // The `-`/`=` shortcut only paginates when *unshifted* — with
            // Shift held, those keys produce `_` / `+`, which fall through
            // to the engine like any other shifted punctuation.
            if matches!(vk, VK_LEFT | VK_UP | VK_PRIOR) || translated == Some(b'-') {
                let result = jd::prev_page();
                self.update_candidates_from_engine(ctx, tid, &result);
                return Ok(BOOL(1));
            }
            if matches!(vk, VK_RIGHT | VK_DOWN | VK_NEXT) || translated == Some(b'=') {
                let result = jd::next_page();
                self.update_candidates_from_engine(ctx, tid, &result);
                return Ok(BOOL(1));
            }
            if vk == VK_ESCAPE {
                jd::reset();
                let _ = composition::commit(ctx, tid);
                candidate_window::hide();
                ui_element::end();
                return Ok(BOOL(1));
            }
            if vk == VK_RETURN {
                // Enter commits the raw in-flight letters as-is — escape
                // hatch for typing English / ASCII without the engine's
                // conversion. composition::commit ends the composition with
                // whatever SetText left in it (the buffer), so we don't
                // ask the engine for a commit string.
                let _ = composition::commit(ctx, tid);
                jd::reset();
                candidate_window::hide();
                ui_element::end();
                return Ok(BOOL(1));
            }
            // Candidate selector: only triggers when the translated byte is
            // an actual `1`-`9` (i.e. unshifted). With Shift the translated
            // byte is `!`/`@`/etc., which falls through to the engine and
            // produces `你!` etc.
            if let Some(b @ b'1'..=b'9') = translated {
                let idx = (b - b'1') as usize;
                let items = candidate_window::current_items();
                if let Some(opt) = items.get(idx).cloned() {
                    let _ = composition::commit_text(ctx, tid, &opt.value);
                    jd::reset();
                    candidate_window::hide();
                    ui_element::end();
                    return Ok(BOOL(1));
                }
                // No candidate at that slot — fall through to the engine
                // with the digit as a literal byte. The engine treats
                // `1`-`9` as ordinary literal input (it does NOT pick from
                // candidates; that's our job — see
                // core/docs/integration.md), so the current top candidate
                // gets committed with the digit appended.
            }
            // Space is no longer special-cased here. It maps to b' ' via
            // translate, falls through to the engine, and the engine's own
            // "space commits the current state" semantics drive the commit.
            if vk == VK_BACK {
                let result = jd::backspace();
                let _ = composition::backspace(ctx, tid);
                if !composition::is_active() {
                    jd::reset();
                    candidate_window::hide();
                    ui_element::end();
                } else {
                    self.update_candidates_from_engine(ctx, tid, &result);
                }
                return Ok(BOOL(1));
            }
        }

        // -- Translated byte drives the engine forward ----------------------
        if let Some(byte) = translated {
            let result = jd::press_key(byte);

            // Engine-driven commit: the engine returned a commit string —
            // common for Chinese-punctuation auto-commit, space-commit, or
            // when the typed key jumped to a different root child (drilled
            // in). Replace the composition with `commit` text, then
            // optionally restart with the just-pressed key if it also
            // triggered new options.
            if let Some(commit) = &result.commit {
                if composition::is_active() {
                    let _ = composition::commit_text(ctx, tid, commit);
                } else {
                    // Engine committed with no in-flight composition — we
                    // don't have a way to type text outside a composition
                    // via TSF without starting one; start + immediately
                    // commit one for this string.
                    let _ = composition::append_key(ctx, tid, &sink, ' ');
                    let _ = composition::commit_text(ctx, tid, commit);
                }
                if result.options.is_empty() {
                    candidate_window::hide();
                    ui_element::end();
                } else {
                    // Drilled-in: start a fresh composition with the typed key.
                    let _ = composition::append_key(ctx, tid, &sink, byte as char);
                    self.show_candidates_from_engine(ctx, tid, &result);
                }
                return Ok(BOOL(1));
            }

            if !result.options.is_empty() {
                let _ = composition::append_key(ctx, tid, &sink, byte as char);
                self.show_candidates_from_engine(ctx, tid, &result);
                return Ok(BOOL(1));
            }

            // Engine returned nothing — letter doesn't match any prefix in
            // the trie. Don't consume; let it through as a literal.
            return Ok(BOOL(0));
        }

        Ok(BOOL(0))
    }

    fn OnKeyUp(&self, _pic: Ref<'_, ITfContext>, _wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        Ok(BOOL(0))
    }

    fn OnPreservedKey(&self, _pic: Ref<'_, ITfContext>, _rguid: *const GUID) -> Result<BOOL> {
        Ok(BOOL(0))
    }
}

impl ITfCompositionSink_Impl for TextInputProcessor_Impl {
    fn OnCompositionTerminated(
        &self,
        _ecwrite: u32,
        _pcomposition: Ref<'_, ITfComposition>,
    ) -> Result<()> {
        composition::on_externally_terminated();
        jd::reset();
        candidate_window::hide();
        ui_element::end();
        Ok(())
    }
}

impl TextInputProcessor_Impl {
    fn update_candidates_from_engine(&self, ctx: &ITfContext, tid: u32, result: &jd::QueryResult) {
        if result.options.is_empty() {
            candidate_window::hide();
            ui_element::end();
        } else {
            self.show_candidates_from_engine(ctx, tid, result);
        }
    }

    fn show_candidates_from_engine(&self, ctx: &ITfContext, tid: u32, result: &jd::QueryResult) {
        let items: Vec<CandidateItem> = result
            .options
            .iter()
            .map(|o| CandidateItem {
                value: o.value.clone(),
                hint: o.hint.clone(),
            })
            .collect();
        let pos = popup_pos();
        candidate_window::show(
            pos,
            items.clone(),
            result.current_page,
            result.total_pages,
            ctx.clone(),
            tid,
        );
        // Mirror the candidate state into the TSF UIElement so UI-less hosts
        // (games, immersive shells) can render the list in their own UI.
        if let Some(tm) = self.state.borrow().thread_mgr.clone() {
            ui_element::sync(
                &tm,
                items,
                result.current_page,
                result.total_pages,
                result.options_count,
            );
        }
    }
}

/// Best position for the candidate popup. Prefers `ITfContextView::GetTextExt`
/// (the TSF-native answer that works in every TSF host — Chromium-based apps,
/// modern Notepad, Word, etc.). Falls back to `GetCaretPos` for Win32 edit
/// controls, which keep a real Win32 caret but may not implement TextExt.
fn popup_pos() -> windows::Win32::Foundation::POINT {
    use windows::Win32::Foundation::POINT;
    if let Some(rect) = composition::last_screen_rect() {
        return POINT {
            x: rect.left,
            y: rect.bottom + 4,
        };
    }
    candidate_window::caret_screen_pos()
}

// ---- VK constants & helpers --------------------------------------------

const VK_BACK: u16 = 0x08;
const VK_RETURN: u16 = 0x0D;
const VK_ESCAPE: u16 = 0x1B;
const VK_PRIOR: u16 = 0x21; // PageUp
const VK_NEXT: u16 = 0x22; // PageDown
const VK_LEFT: u16 = 0x25;
const VK_UP: u16 = 0x26;
const VK_RIGHT: u16 = 0x27;
const VK_DOWN: u16 = 0x28;

fn should_consume(vk: u16) -> bool {
    // Modifier chords always pass through — they're host shortcuts.
    let m = mods();
    if m.ctrl || m.alt || m.win {
        return false;
    }

    let composing = composition::is_active();
    if composing {
        // Nav / cancel / finish keys we own while composing. Arrow keys must
        // be consumed even apart from the page-nav binding — letting them
        // through would move the host's caret out of the composition range.
        if matches!(
            vk,
            VK_RETURN
                | VK_ESCAPE
                | VK_BACK
                | VK_PRIOR
                | VK_NEXT
                | VK_LEFT
                | VK_RIGHT
                | VK_UP
                | VK_DOWN
        ) {
            return true;
        }
        // Any printable byte the engine accepts (letters, digits, punctuation,
        // space, shifted variants).
        return translate(vk).is_some();
    }

    // Not composing: only a LOWERCASE letter starts a composition. Uppercase
    // letters (Shift / Caps Lock), digits, punctuation, and space pass
    // through so the host inserts them literally.
    matches!(translate(vk), Some(b'a'..=b'z'))
}

/// Snapshot of the standalone-modifier state at the moment of the keystroke.
struct Mods {
    ctrl: bool,
    alt: bool,
    win: bool,
}

fn mods() -> Mods {
    fn pressed(vk: i32) -> bool {
        unsafe { GetKeyState(vk) }.is_negative()
    }
    Mods {
        ctrl: pressed(0x11),                 // VK_CONTROL
        alt: pressed(0x12),                  // VK_MENU
        win: pressed(0x5B) || pressed(0x5C), // VK_LWIN / VK_RWIN
    }
}

/// Translate a virtual key to the printable ASCII byte the user actually
/// typed, honoring the current keyboard state (Shift, Caps Lock, active
/// layout). Returns `None` for dead keys, non-ASCII results, keys with no
/// character translation (modifiers, arrows, function keys), and control
/// codes (`ToUnicode` returns `0x08` for `VK_BACK`, `0x0D` for `VK_RETURN`,
/// etc. — we filter those out because they aren't meaningful as engine
/// input and would otherwise insert raw control bytes into the document).
fn translate(vk: u16) -> Option<u8> {
    let mut state = [0u8; 256];
    if unsafe { GetKeyboardState(&mut state) }.is_err() {
        return None;
    }
    let mut buf = [0u16; 8];
    // wFlags bit 2 = preserve dead-key state across the call (Win 10 1607+).
    // Without it, ToUnicode would "consume" any pending dead key as a side
    // effect of every keystroke we inspect.
    let n = unsafe { ToUnicode(vk as u32, 0, Some(&state), &mut buf, 0x4) };
    if n == 1 && (0x20..=0x7E).contains(&buf[0]) {
        Some(buf[0] as u8)
    } else {
        None
    }
}
