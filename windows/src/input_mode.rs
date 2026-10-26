//! 中 and 英, the IME's two input modes, as Windows' Chinese IMEs have them:
//! in 中 the engine has the keys, in 英 every key goes to the application as
//! typed. The mode is TSF's own keyboard open/close switch
//! (`GUID_COMPARTMENT_KEYBOARD_OPENCLOSE`, open meaning 中), a compartment
//! of each thread's thread manager, so each application keeps its own mode,
//! as with Microsoft Pinyin, and whatever else sets that switch — an
//! application closing the IME, a hotkey — switches 键道 too. The TIP sets
//! it to 中 when it activates on a thread, as Microsoft's IME guidelines ask
//! ("set the default IME mode to on"), and hears every change through a
//! compartment sink (tip.rs), which also redraws the mode icon.
//!
//! The switch is Shift pressed and released alone, or a left click on the
//! mode icon (mode_icon.rs). Shift is everyday for capitals and selections,
//! so a press counts only when nothing else happened before the release: no
//! other key (Shift+A, Ctrl+Shift, Alt+Shift) and no mouse button or wheel
//! (Shift-click extends a selection), which a mouse hook on this thread
//! watches for while Shift is down.

use std::cell::Cell;

use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::System::Variant::{VARIANT, VT_I4, VariantClear};
use windows::Win32::UI::TextServices::{
    GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, ITfCompartment, ITfCompartmentMgr, ITfThreadMgr,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, HHOOK, SetWindowsHookExW, UnhookWindowsHookEx, WH_MOUSE, WM_LBUTTONDBLCLK,
    WM_LBUTTONDOWN, WM_MBUTTONDBLCLK, WM_MBUTTONDOWN, WM_MOUSEHWHEEL, WM_MOUSEWHEEL,
    WM_NCLBUTTONDBLCLK, WM_NCLBUTTONDOWN, WM_NCMBUTTONDBLCLK, WM_NCMBUTTONDOWN, WM_NCRBUTTONDBLCLK,
    WM_NCRBUTTONDOWN, WM_NCXBUTTONDBLCLK, WM_NCXBUTTONDOWN, WM_RBUTTONDBLCLK, WM_RBUTTONDOWN,
    WM_XBUTTONDBLCLK, WM_XBUTTONDOWN,
};
use windows::core::{Interface, Result};

pub const VK_SHIFT: u16 = 0x10;

thread_local! {
    /// This thread's mode as the compartment last said: whether it is 英.
    static ENGLISH: Cell<bool> = const { Cell::new(false) };
    static SHIFT: Cell<ShiftTap> = const { Cell::new(ShiftTap::Idle) };
    /// The mouse hook, while Shift is down.
    static MOUSE_HOOK: Cell<Option<HHOOK>> = const { Cell::new(None) };
}

/// Whether the mode is 英. Cheap: a thread-local, kept by [`sync`].
pub fn is_english() -> bool {
    ENGLISH.with(Cell::get)
}

/// Read the mode from the compartment, after a change; returns whether it
/// is 英. A switch never set, or one that cannot be read, is 中.
pub fn sync(thread_mgr: &ITfThreadMgr) -> bool {
    let english = compartment(thread_mgr).is_ok_and(|compartment| {
        // SAFETY: the VARIANT is ours to read and clear; the switch holds a
        // VT_I4, or nothing when never set.
        unsafe {
            let Ok(mut value) = compartment.GetValue() else {
                return false;
            };
            let inner = &value.Anonymous.Anonymous;
            let closed = inner.vt == VT_I4 && inner.Anonymous.lVal == 0;
            let _ = VariantClear(&mut value);
            closed
        }
    });
    ENGLISH.with(|cell| cell.set(english));
    english
}

/// Switch to 英 or to 中; the compartment sink hears of it.
pub fn set(thread_mgr: &ITfThreadMgr, tid: u32, english: bool) -> Result<()> {
    let mut value = VARIANT::default();
    // SAFETY: a VT_I4 VARIANT owns nothing, so it needs no clearing.
    unsafe {
        let inner = &mut *value.Anonymous.Anonymous;
        inner.vt = VT_I4;
        inner.Anonymous.lVal = i32::from(!english);
        compartment(thread_mgr)?.SetValue(tid, &value)
    }
}

pub fn toggle(thread_mgr: &ITfThreadMgr, tid: u32) {
    let _ = set(thread_mgr, tid, !is_english());
}

/// The switch's compartment on this thread's thread manager.
pub fn compartment(thread_mgr: &ITfThreadMgr) -> Result<ITfCompartment> {
    // SAFETY: plain calls.
    unsafe {
        thread_mgr
            .cast::<ITfCompartmentMgr>()?
            .GetCompartment(&GUID_COMPARTMENT_KEYBOARD_OPENCLOSE)
    }
}

// ---- Shift pressed alone ----------------------------------------------------

/// Where a press of Shift stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ShiftTap {
    /// Shift is up.
    Idle,
    /// Shift is down, and nothing else has happened yet.
    Pending,
    /// Shift is down, and it was used with something else.
    Used,
}

impl ShiftTap {
    /// A key went down; `with_modifier` says whether Ctrl, Alt or the
    /// Windows key was down with it.
    fn key_down(self, vk: u16, with_modifier: bool) -> Self {
        match (vk, self) {
            (VK_SHIFT, ShiftTap::Idle) if with_modifier => ShiftTap::Used,
            (VK_SHIFT, ShiftTap::Idle) => ShiftTap::Pending,
            // Held down: the key repeats.
            (VK_SHIFT, state) => state,
            (_, ShiftTap::Idle) => ShiftTap::Idle,
            (_, _) => ShiftTap::Used,
        }
    }

    fn mouse(self) -> Self {
        match self {
            ShiftTap::Pending => ShiftTap::Used,
            state => state,
        }
    }
}

/// Every key down, from `OnTestKeyDown`.
pub fn key_down(vk: u16, with_modifier: bool) {
    let next = SHIFT.with(Cell::get).key_down(vk, with_modifier);
    SHIFT.with(|state| state.set(next));
    // The mouse matters only while the press is still alone.
    if next == ShiftTap::Pending {
        watch_mouse();
    } else {
        unwatch_mouse();
    }
}

/// Shift went up (`OnTestKeyUp`): whether it was pressed alone. When it was,
/// `OnKeyUp` follows and takes it; when it was not, it is over here.
pub fn shift_up_is_tap() -> bool {
    let tap = SHIFT.with(Cell::get) == ShiftTap::Pending;
    if !tap {
        cancel();
    }
    tap
}

/// Shift went up and `OnKeyUp` acts on it: whether it was a tap.
pub fn take_tap() -> bool {
    let tap = SHIFT.with(Cell::get) == ShiftTap::Pending;
    cancel();
    tap
}

/// Forget a press of Shift: the focus went elsewhere, or the IME is going.
pub fn cancel() {
    SHIFT.with(|state| state.set(ShiftTap::Idle));
    unwatch_mouse();
}

fn watch_mouse() {
    if MOUSE_HOOK.with(Cell::get).is_some() {
        return;
    }
    // SAFETY: a hook on this thread alone, whose procedure lives in this
    // module; it is removed when Shift goes up.
    let hook = unsafe { SetWindowsHookExW(WH_MOUSE, Some(mouse_proc), None, GetCurrentThreadId()) };
    MOUSE_HOOK.with(|cell| cell.set(hook.ok()));
}

fn unwatch_mouse() {
    if let Some(hook) = MOUSE_HOOK.with(Cell::take) {
        // SAFETY: the hook this thread installed.
        unsafe {
            let _ = UnhookWindowsHookEx(hook);
        }
    }
}

/// A button or the wheel while Shift is down: Shift is in use.
unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0
        && matches!(
            wparam.0 as u32,
            WM_LBUTTONDOWN
                | WM_LBUTTONDBLCLK
                | WM_RBUTTONDOWN
                | WM_RBUTTONDBLCLK
                | WM_MBUTTONDOWN
                | WM_MBUTTONDBLCLK
                | WM_XBUTTONDOWN
                | WM_XBUTTONDBLCLK
                | WM_NCLBUTTONDOWN
                | WM_NCLBUTTONDBLCLK
                | WM_NCRBUTTONDOWN
                | WM_NCRBUTTONDBLCLK
                | WM_NCMBUTTONDOWN
                | WM_NCMBUTTONDBLCLK
                | WM_NCXBUTTONDOWN
                | WM_NCXBUTTONDBLCLK
                | WM_MOUSEWHEEL
                | WM_MOUSEHWHEEL
        )
    {
        SHIFT.with(|state| state.set(state.get().mouse()));
    }
    // SAFETY: passing the message on, as every hook must.
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VK_A: u16 = 0x41;
    const VK_CONTROL: u16 = 0x11;

    /// Feed key downs to a fresh press and say whether the release taps.
    fn taps(downs: &[(u16, bool)], mouse_after: Option<usize>) -> bool {
        let mut state = ShiftTap::Idle;
        for (n, &(vk, with_modifier)) in downs.iter().enumerate() {
            state = state.key_down(vk, with_modifier);
            if mouse_after == Some(n) {
                state = state.mouse();
            }
        }
        state == ShiftTap::Pending
    }

    #[test]
    fn only_shift_pressed_alone_switches() {
        assert!(taps(&[(VK_SHIFT, false)], None), "a tap");
        assert!(
            taps(&[(VK_SHIFT, false); 5], None),
            "held a while: the key repeats"
        );
        assert!(
            !taps(&[(VK_SHIFT, false), (VK_A, false)], None),
            "Shift+A types a capital"
        );
        assert!(!taps(
            &[(VK_SHIFT, false), (VK_A, false), (VK_SHIFT, false)],
            None
        ));
        assert!(!taps(&[(VK_SHIFT, true)], None), "Ctrl+Shift, Alt+Shift");
        assert!(
            !taps(&[(VK_SHIFT, false), (VK_CONTROL, false)], None),
            "Shift, then Ctrl"
        );
        assert!(!taps(&[(VK_SHIFT, false)], Some(0)), "Shift-click selects");
        assert!(!taps(&[(VK_A, false)], None), "no Shift at all");
    }
}
