//! The Windows client's user dictionary, as both of its processes see it.
//! The IME — the TIP DLL loaded into every application the user types in —
//! only reads it; the 用户自造词 window (`ime_jd_userdict.exe`, this
//! package's binary) edits it, and sets the switches for the menu of the
//! IME's mode icon. They meet in one text file and one registry value:
//!
//! - the phrases file, `%APPDATA%\ime-jd\用户自造词.txt`, in libjd's table
//!   format ([`file`]) — the single source of truth, roaming with the
//!   user's profile;
//! - the switches under `HKCU\Software\hronro\ime-jd` ([`switch`], beside
//!   the IME's update check): `UserDictEnabled`, off until the user turns
//!   it on, and `UserDictOnly`, 忽略内置词库, which while the first is on
//!   types from the phrases alone, built on libjd's empty dictionary
//!   ([`base`]).
//!
//! Beside them is the phrases compiled once for every application to map,
//! in `%LOCALAPPDATA%\ime-jd\userdict-cache` ([`cache`]): written by the
//! window, and by the IME in the first ordinary desktop application that
//! finds none for the phrases as they are.
//!
//! Sandboxed (AppContainer) hosts — the Start menu's search box, Store apps —
//! can read none of them by default, so the window grants them read access
//! ([`access`]) and phrases work there too.

pub mod access;
pub mod cache;
pub mod file;
pub mod switch;

use std::sync::OnceLock;

use jd::{Dict, UserDict, UserDictError, UserDictReport};

pub use file::{Entry, LoadError, Row};

/// libjd's empty dictionary: what the phrases are built on, and typed from,
/// under 忽略内置词库. Built once per process; every empty dictionary is the
/// same one, so a user dictionary built on it works on any.
pub fn empty_dict() -> &'static Dict {
    static EMPTY: OnceLock<Dict> = OnceLock::new();
    EMPTY.get_or_init(Dict::empty)
}

/// The dictionary the phrases are built on: the empty one when `user_only`
/// (忽略内置词库), libjd's built-in one — `None` — otherwise. What a phrase
/// repeats, or shares a code with, depends on it, and a user dictionary
/// built on one works only on that one.
pub fn base(user_only: bool) -> Option<&'static Dict> {
    user_only.then(empty_dict)
}

/// Build the phrases `text` on `base` ([`base`]), tagged with libjd's hash of
/// the text, as every part of the Windows client builds them.
pub fn build(text: &str, base: Option<&Dict>) -> Result<(UserDict, UserDictReport), UserDictError> {
    let tag = UserDict::hash(text.as_bytes());
    match base {
        Some(dict) => UserDict::build_on(dict, text, tag),
        None => UserDict::build(text, tag),
    }
}
