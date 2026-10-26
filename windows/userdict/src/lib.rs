//! The Windows client's user dictionary, as both of its processes see it.
//! The IME — the TIP DLL loaded into every application the user types in —
//! only reads it; the 用户自造词 window (`ime_jd_userdict.exe`, this
//! package's binary) edits it, and sets the switches for the menu of the
//! IME's mode icon. They meet in one text file and one registry value:
//!
//! - the phrases file, `%APPDATA%\ime-jd\用户自造词.txt`, in libjd's table
//!   format ([`file`]) — the single source of truth, roaming with the
//!   user's profile;
//! - the switch, `UserDictEnabled` under `HKCU\Software\hronro\ime-jd`
//!   ([`switch`], beside the IME's other switch, the update check), off
//!   until the user turns it on.
//!
//! Sandboxed (AppContainer) hosts — the Start menu's search box, Store apps —
//! can read neither by default, so the window grants them read access
//! ([`access`]) and phrases work there too.

pub mod access;
pub mod file;
pub mod switch;

pub use file::{Entry, Row};
