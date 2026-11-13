//! What this DLL does for the loader in front of it (windows/loader).
//!
//! The DLL registered as the IME is not this one. It is a small one that an
//! update has no need to replace, the loader, which loads this DLL by the
//! name it was installed under — and, once a newer installation's DLL lies
//! beside it, puts that one in this one's place, in an application that is
//! running and that notices nothing. It can do so only where nothing is
//! lost by it: at a moment when this thread's IME is idle. Whether it is,
//! is this DLL's to say:
//!
//!   - [`idle`] is called wherever the IME may just have become idle — a
//!     composition ended, the focus came to this thread, or went to another
//!     of its documents — and posts the loader's message to the loader's
//!     window (`JdTellWhenIdle` in lib.rs gives the two). A message, so that
//!     the loader acts from the application's message loop, after whatever
//!     of TSF's and of the IME's is running now has returned;
//!   - [`is_idle`] is what the loader asks when the message arrives
//!     (`JdIsIdle`): a key may have come first, and started a composition.
//!
//! The loader then deactivates this DLL's IME and activates the other's,
//! as TSF does when the user switches input methods. Registered by itself,
//! with no loader in front, this DLL has no one to tell, and [`idle`] does
//! nothing.

use std::cell::Cell;

use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;

use crate::composition;

thread_local! {
    /// The loader's window on this thread, and the message it waits for
    /// there, while this thread's IME is active behind a loader.
    static LISTENER: Cell<Option<(HWND, u32)>> = const { Cell::new(None) };
    /// How many things are under way that the IME cannot be taken from the
    /// middle of, compositions aside ([`Busy`]).
    static BUSY: Cell<u32> = const { Cell::new(0) };
}

/// `JdTellWhenIdle`: where [`idle`] posts from now on.
pub fn listen(window: HWND, message: u32) {
    LISTENER.with(|listener| listener.set((!window.is_invalid()).then_some((window, message))));
}

/// At deactivation, which may be the loader's: what it activates next gets
/// the word, and this DLL has no more to say.
pub fn forget() {
    LISTENER.with(|listener| listener.set(None));
}

/// The IME may have become idle: tell the loader, if there is one.
pub fn idle() {
    if let Some((window, message)) = LISTENER.with(Cell::get) {
        // SAFETY: a message posted to a window of this thread; if the
        // window is gone, it goes nowhere.
        let _ = unsafe { PostMessageW(Some(window), message, WPARAM(0), LPARAM(0)) };
    }
}

/// `JdIsIdle`: whether this thread's IME can be deactivated now with
/// nothing lost — nothing is being composed, and nothing of the IME's own
/// is open.
pub fn is_idle() -> bool {
    BUSY.with(Cell::get) == 0 && composition::is_idle()
}

/// Something of the IME's that runs a message loop of its own — a menu —
/// in which the loader's message could arrive: the IME is not idle for as
/// long as this lives.
pub struct Busy(());

impl Busy {
    pub fn new() -> Self {
        BUSY.with(|busy| busy.set(busy.get() + 1));
        Busy(())
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        BUSY.with(|busy| busy.set(busy.get().saturating_sub(1)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DestroyWindow, HWND_MESSAGE, MSG, PM_REMOVE, PeekMessageW,
        WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP,
    };
    use windows::core::w;

    /// How many of `message` are waiting for `window`, taken off its queue.
    fn waiting(window: HWND, message: u32) -> usize {
        let mut count = 0;
        let mut msg = MSG::default();
        // SAFETY: this thread's own queue.
        while unsafe { PeekMessageW(&mut msg, Some(window), message, message, PM_REMOVE) }.as_bool()
        {
            count += 1;
        }
        count
    }

    #[test]
    fn the_loader_hears_of_an_idle_moment_while_it_listens() {
        // SAFETY: a message-only window of this thread, destroyed below.
        let window = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("STATIC"),
                None,
                WINDOW_STYLE(0),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                None,
                None,
            )
        }
        .expect("a window");
        let message = WM_APP + 1;

        // No loader in front: no one to tell.
        idle();
        assert_eq!(waiting(window, message), 0);

        listen(window, message);
        idle();
        idle();
        assert_eq!(waiting(window, message), 2);

        // Deactivated: the next IME's to say.
        forget();
        idle();
        assert_eq!(waiting(window, message), 0);

        // SAFETY: the window made above.
        unsafe {
            let _ = DestroyWindow(window);
        }
    }

    #[test]
    fn the_ime_is_not_idle_with_a_menu_open() {
        assert!(is_idle());
        let menu = Busy::new();
        let another = Busy::new();
        assert!(!is_idle());
        drop(menu);
        assert!(!is_idle());
        drop(another);
        assert!(is_idle());
    }
}
