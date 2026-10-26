//! The IME's side of the user dictionary: which dictionary a new engine
//! context reads, for every UI thread in this host process.
//!
//! The phrases file and the switch (jd_userdict, ../userdict) change in
//! another process — the 用户自造词 window, a text editor, regedit — while
//! this DLL sits loaded in every application the user types in. There is
//! nothing to subscribe to from in here, so the IME looks before it uses:
//! [`current`] reads the switch and, while it is on, stats the file — one
//! registry read and one directory lookup — and rebuilds only when either
//! changed. jd.rs asks at activation and at the first key of every
//! composition: the moments nothing is composing, the only ones at which a
//! context may be replaced, since its dictionary is fixed for its lifetime.
//!
//! There is no compiled cache. A build costs about 0.25 ms per 1 000 phrases
//! on a desktop CPU (3.4 ms at the engine's 10 000-phrase cap; see
//! bindings/rust/examples/user_dict_bench.rs), each host process builds its
//! own once per edit, and nothing here ever writes: a host may be a packaged
//! app whose writes the system redirects into its own copy, or a sandbox
//! that may not write at all.
//!
//! A file that cannot be built — not UTF-8, over the engine's caps — keeps
//! this process's last good dictionary; the window says what is wrong. A
//! file that cannot be read means no dictionary, never an error: there is no
//! file yet, or the host is a sandbox the window has not granted access to.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use jd::UserDict;
use jd_userdict::{file, switch};

/// What a load depends on. Equal stamps mean the dictionary in hand is the
/// one a load would produce.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    enabled: bool,
    /// The file's stamp, taken only while the switch is on.
    file: Option<file::Stamp>,
}

struct State {
    /// The stamp `dict` answers to; `None` until the first look.
    stamp: Option<Stamp>,
    dict: Option<Arc<UserDict>>,
}

/// Process-wide: every UI thread's context reads the same dictionary.
static STATE: Mutex<State> = Mutex::new(State {
    stamp: None,
    dict: None,
});

/// Resolved once per process; known folders do not move under a running
/// process.
static PATH: OnceLock<Option<PathBuf>> = OnceLock::new();

/// The dictionary a context created now should read, if any: `None` while
/// the switch is off, or when there is nothing readable to build from.
/// Cheap when nothing changed; see the module docs.
pub fn current() -> Option<Arc<UserDict>> {
    let path = PATH.get_or_init(file::path).as_deref();
    let enabled = switch::is_enabled();
    let stamp = Stamp {
        enabled,
        file: if enabled { path.and_then(file::stamp) } else { None },
    };
    let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
    if state.stamp != Some(stamp) {
        let (dict, settled) = load(stamp, path, state.dict.take());
        state.dict = dict;
        // A read that failed for a reason that may pass — the file locked
        // mid-save — is retried at the next look rather than remembered.
        state.stamp = settled.then_some(stamp);
    }
    state.dict.clone()
}

/// Load for `stamp`, falling back to `previous` — the last good dictionary —
/// when the file is there but cannot be built. Also says whether the outcome
/// is settled for this stamp.
fn load(
    stamp: Stamp,
    path: Option<&Path>,
    previous: Option<Arc<UserDict>>,
) -> (Option<Arc<UserDict>>, bool) {
    let Some(path) = path.filter(|_| stamp.enabled) else {
        return (None, true);
    };
    match file::read(path) {
        Ok(Some(text)) => match UserDict::build(&text, file::hash(text.as_bytes())) {
            Ok((dict, _report)) => (Some(Arc::new(dict)), true),
            Err(_) => (previous, true),
        },
        Ok(None) => (None, true),
        Err(file::ReadError::NotUtf8) => (previous, true),
        // A text editor holding the file mid-save, say: try again next time.
        Err(file::ReadError::Io(_)) => (previous, false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn on(path: &Path) -> Stamp {
        Stamp {
            enabled: true,
            file: file::stamp(path),
        }
    }

    #[test]
    fn loads_follow_the_switch_the_file_and_the_last_good_dictionary() {
        let dir = std::env::temp_dir().join(format!("jd-tip-userdict-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = dir.join(file::FILE_NAME);

        // No file: no dictionary, and that is settled.
        let (dict, settled) = load(on(&path), Some(&path), None);
        assert!(dict.is_none() && settled);

        file::write(&path, "键道\tzzzzzz\n").unwrap();
        let (dict, settled) = load(on(&path), Some(&path), None);
        let good = dict.expect("a buildable file loads");
        assert!(settled);
        assert_eq!(good.entries(), 1);

        // Off: nothing, whatever the file holds.
        let off = Stamp {
            enabled: false,
            file: None,
        };
        assert!(load(off, Some(&path), Some(good.clone())).0.is_none());

        // Not UTF-8: the last good dictionary stays.
        fs::write(&path, [0xC4, 0xE3, 0x09, 0x61, 0x0A]).unwrap();
        let (dict, settled) = load(on(&path), Some(&path), Some(good.clone()));
        assert!(Arc::ptr_eq(&dict.unwrap(), &good));
        assert!(settled);

        // A line the engine skips is no failure: the rest still loads.
        file::write(&path, "键道\tzzzzzz\n好\tZZ\n").unwrap();
        let (dict, _) = load(on(&path), Some(&path), Some(good.clone()));
        let dict = dict.unwrap();
        assert!(!Arc::ptr_eq(&dict, &good));
        assert_eq!(dict.entries(), 1);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn stamps_tell_an_edit_from_no_change() {
        let dir = std::env::temp_dir().join(format!("jd-tip-stamp-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let path = dir.join(file::FILE_NAME);
        file::write(&path, "键道\tzzzzzz\n").unwrap();
        let first = on(&path);
        assert!(first == on(&path), "an untouched file keeps its stamp");
        file::write(&path, "键道\tzzzzzz\n键道输入法\tzzzzza\n").unwrap();
        assert!(first != on(&path));
        fs::remove_dir_all(&dir).unwrap();
    }
}
