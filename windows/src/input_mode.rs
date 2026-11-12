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
    /// A key went down: `pressed_now`, or held and repeating; `with_modifier`
    /// says whether Ctrl, Alt or the Windows key was down with it. Told of
    /// the same key down a second time it stays as it is: TSF brings some
    /// keys twice, to `OnTestKeyDown` and to `OnKeyDown`, and others once,
    /// to either.
    fn key_down(self, vk: u16, pressed_now: bool, with_modifier: bool) -> Self {
        match (vk, self) {
            // A new press starts afresh, whatever became of the last one,
            // whose release is not always told (tip.rs, `shift_goes_up`).
            (VK_SHIFT, _) if pressed_now && with_modifier => ShiftTap::Used,
            (VK_SHIFT, _) if pressed_now => ShiftTap::Pending,
            // Held down, the key repeats — also a Shift that was pressed
            // before the focus came here, which is not this thread's to
            // count.
            (VK_SHIFT, state) => state,
            (_, ShiftTap::Idle) => ShiftTap::Idle,
            (_, _) => ShiftTap::Used,
        }
    }

    /// Something else happened while Shift was down: a mouse button, the
    /// wheel, or a key of which only the release was told.
    fn used(self) -> Self {
        match self {
            ShiftTap::Pending => ShiftTap::Used,
            state => state,
        }
    }
}

/// Every key down, from `OnTestKeyDown` and from `OnKeyDown`: an
/// application gets a key to one of them, or to both (tip.rs,
/// `key_goes_down`). `pressed_now` is false for a key that is held and
/// repeats.
pub fn key_down(vk: u16, pressed_now: bool, with_modifier: bool) {
    let next = SHIFT
        .with(Cell::get)
        .key_down(vk, pressed_now, with_modifier);
    SHIFT.with(|state| state.set(next));
    // The mouse matters only while the press is still alone.
    if next == ShiftTap::Pending {
        watch_mouse();
    } else {
        unwatch_mouse();
    }
}

/// Alt, Ctrl or the Windows key went up while Shift may be down: Shift was
/// not pressed alone, though nothing may have been told of that key going
/// down (tip.rs, `shift_goes_up`).
pub fn used_with_another_key() {
    SHIFT.with(|state| state.set(state.get().used()));
    if SHIFT.with(Cell::get) != ShiftTap::Pending {
        unwatch_mouse();
    }
}

/// Shift went up, and the application asks first (`OnTestKeyUp`): whether
/// it was pressed alone. When it was, `OnKeyUp` follows and takes it; when
/// it was not, it is over here.
pub fn shift_up_is_tap() -> bool {
    let tap = SHIFT.with(Cell::get) == ShiftTap::Pending;
    if !tap {
        cancel();
    }
    tap
}

/// Shift went up and `OnKeyUp` acts on it — asked first or not: whether it
/// was a tap.
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
        SHIFT.with(|state| state.set(state.get().used()));
    }
    // SAFETY: passing the message on, as every hook must.
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VK_A: u16 = 0x41;
    const VK_CONTROL: u16 = 0x11;

    /// What a thread hears of while Shift may be down.
    #[derive(Clone, Copy)]
    enum Told {
        /// A key pressed, and whether Ctrl, Alt or the Windows key was down
        /// with it.
        Press(u16, bool),
        /// A key held down, repeating.
        Repeat(u16),
        /// A mouse button or the wheel, or a modifier let go.
        Other,
    }
    use Told::{Other, Press, Repeat};

    /// Whether Shift, let go after all of `told`, switches the mode.
    fn taps(told: &[Told]) -> bool {
        let mut state = ShiftTap::Idle;
        for event in told {
            state = match *event {
                Press(vk, with_modifier) => state.key_down(vk, true, with_modifier),
                Repeat(vk) => state.key_down(vk, false, false),
                Other => state.used(),
            };
        }
        state == ShiftTap::Pending
    }

    #[test]
    fn only_shift_pressed_alone_switches() {
        assert!(taps(&[Press(VK_SHIFT, false)]), "a tap");
        assert!(
            taps(&[Press(VK_SHIFT, false), Repeat(VK_SHIFT), Repeat(VK_SHIFT)]),
            "held a while: the key repeats"
        );
        assert!(
            !taps(&[Press(VK_SHIFT, false), Press(VK_A, false)]),
            "Shift+A types a capital"
        );
        assert!(!taps(&[
            Press(VK_SHIFT, false),
            Press(VK_A, false),
            Repeat(VK_A),
            Repeat(VK_SHIFT)
        ]));
        assert!(!taps(&[Press(VK_SHIFT, true)]), "Ctrl+Shift, Alt+Shift");
        assert!(
            !taps(&[Press(VK_SHIFT, false), Press(VK_CONTROL, false)]),
            "Shift, then Ctrl"
        );
        assert!(
            !taps(&[Press(VK_SHIFT, false), Other]),
            "Shift-click selects; Shift, Alt+F, Alt let go"
        );
        assert!(!taps(&[Press(VK_A, false)]), "no Shift at all");
    }

    #[test]
    fn a_new_press_of_shift_starts_afresh() {
        // Shift let go while Alt is down is told to no text service where
        // the system feeds the keys: the press after it is judged on its
        // own, not on what became of that one.
        assert!(taps(&[
            Press(VK_SHIFT, false),
            Other,
            Press(VK_SHIFT, false)
        ]));
        assert!(taps(&[Press(VK_SHIFT, true), Press(VK_SHIFT, false)]));
        assert!(!taps(&[Press(VK_SHIFT, false), Press(VK_SHIFT, true)]));
        // And a Shift that was down before the focus came here — the click
        // that brought it was a Shift-click — is none of this thread's.
        assert!(!taps(&[Repeat(VK_SHIFT), Repeat(VK_SHIFT)]));
    }

    #[test]
    fn a_key_down_told_twice_counts_once() {
        // An application that feeds TSF its keys brings a key that is taken
        // to `OnTestKeyDown` and then to `OnKeyDown`; one that leaves them
        // to the system brings every key to `OnKeyDown` alone. Either way
        // the press stands where one telling leaves it.
        for state in [ShiftTap::Idle, ShiftTap::Pending, ShiftTap::Used] {
            for vk in [VK_SHIFT, VK_A, VK_CONTROL] {
                for pressed_now in [false, true] {
                    for with_modifier in [false, true] {
                        let once = state.key_down(vk, pressed_now, with_modifier);
                        assert_eq!(
                            once.key_down(vk, pressed_now, with_modifier),
                            once,
                            "{state:?}, key {vk:#x}, pressed now {pressed_now}, modifier {with_modifier}"
                        );
                    }
                }
            }
        }
        let twice = |told: &[Told]| {
            let doubled: Vec<_> = told.iter().flat_map(|&event| [event, event]).collect();
            taps(&doubled)
        };
        assert!(twice(&[Press(VK_SHIFT, false)]));
        assert!(!twice(&[Press(VK_SHIFT, false), Press(VK_A, false)]));
        assert!(!twice(&[Press(VK_SHIFT, true)]));
        assert!(!twice(&[Press(VK_SHIFT, false), Other]));
    }
}
