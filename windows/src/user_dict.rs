//! The IME's side of the user dictionary: which dictionary a new engine
//! context reads, for every UI thread in this host process.
//!
//! The phrases file and the switch (jd_userdict, ../userdict) change in
//! another process — the 用户自造词 window, a text editor, regedit — while
//! this DLL sits loaded in every application the user types in. There is
//! nothing to subscribe to from in here, so the IME looks before it uses:
//! [`current`] reads the switch and, while it is on, stats the file — one
//! registry read and one directory lookup — and loads again only when either
//! changed. jd.rs asks at activation and at the first key of every
//! composition: the moments nothing is composing, the only ones at which a
//! context may be replaced, since its dictionary is fixed for its lifetime.
//!
//! A load maps the dictionary compiled once for every application
//! (jd_userdict::cache): it reads and hashes the file and maps the blob of
//! that text, whose pages every application that maps it shares. When the
//! cache holds none — the phrases were edited in a text editor, or the IME
//! was updated — this process builds the dictionary itself, as each did
//! before there was a cache: 70 ms at the engine's 500 000-phrase cap on a
//! Ryzen 7 5800X, and 13 MB of its own. In an ordinary desktop application
//! it then writes the blob to the cache, on a thread of its own, for the
//! others; and every process that built its own looks for the blob at each
//! look after, a stat, and moves to it once it is there, freeing its copy.
//! Nothing is written from a sandboxed (AppContainer) application, which may
//! not write there and must not be able to — every application reads what
//! lies there; nor from a packaged one, the files it creates under AppData
//! landing in a private copy of its package's that no other application
//! reads (jd_userdict::cache says more); nor on the secure desktop.
//!
//! A file that cannot be built — not UTF-8, over the engine's caps — keeps
//! this process's last good dictionary; the window says what is wrong. A
//! file that cannot be read means no dictionary, never an error: there is no
//! file yet, or the host is a sandbox the window has not granted access to.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use jd::UserDict;
use jd_userdict::{cache, file, switch};

use crate::host;

/// What a load depends on. Equal stamps mean the dictionary in hand is the
/// one a load would produce.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    enabled: bool,
    /// The file's stamp, taken only while the switch is on.
    file: Option<file::Stamp>,
}

/// A dictionary built here, because the cache held no blob of its text: the
/// blob that was looked for, and its stamp when it was.
struct Awaited {
    text_hash: u64,
    blob: PathBuf,
    then: Option<file::Stamp>,
}

struct State {
    /// The stamp `dict` answers to; `None` until the first look.
    stamp: Option<Stamp>,
    dict: Option<Arc<UserDict>>,
    /// While `dict` was built here rather than mapped from the cache.
    awaited: Option<Awaited>,
}

/// Process-wide: every UI thread's context reads the same dictionary.
static STATE: Mutex<State> = Mutex::new(State {
    stamp: None,
    dict: None,
    awaited: None,
});

/// Resolved once per process; known folders do not move under a running
/// process.
static PATH: OnceLock<Option<PathBuf>> = OnceLock::new();
static CACHE: OnceLock<Option<PathBuf>> = OnceLock::new();

/// The dictionary a context created now should read, if any: `None` while
/// the switch is off, or when there is nothing readable to build from.
/// Cheap when nothing changed; see the module docs.
pub fn current() -> Option<Arc<UserDict>> {
    let path = PATH.get_or_init(file::path).as_deref();
    let cache = CACHE.get_or_init(cache::dir).as_deref();
    let enabled = switch::is_enabled();
    let stamp = Stamp {
        enabled,
        file: if enabled { path.and_then(file::stamp) } else { None },
    };
    let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(built) = state.look(stamp, path, cache)
        && let Some(dir) = cache
        && may_write_cache()
    {
        write_in_background(dir.to_path_buf(), built);
    }
    state.dict.clone()
}

impl State {
    /// Bring `dict` up to date for `stamp`. Returns the dictionary if it was
    /// just built here — the one the cache lacks.
    fn look(&mut self, stamp: Stamp, path: Option<&Path>, cache: Option<&Path>) -> Option<Arc<UserDict>> {
        if self.stamp != Some(stamp) {
            let loaded = load(stamp, path, cache, self.dict.take());
            self.dict = loaded.dict;
            // A read that failed for a reason that may pass — the file locked
            // mid-save — is retried at the next look rather than remembered.
            self.stamp = loaded.settled.then_some(stamp);
            self.awaited = loaded.awaited;
            return self.awaited.as_ref().and(self.dict.clone());
        }
        // Nothing changed, but the dictionary was built here: move to the
        // shared copy once the cache holds it — or, should it hold one that
        // is refused, once that blob changes.
        let dir = cache?;
        let awaited = self.awaited.as_mut()?;
        let now = file::stamp(&awaited.blob);
        if now == awaited.then {
            return None;
        }
        awaited.then = now;
        let text_hash = awaited.text_hash;
        if let Some(dict) = cache::open_in(dir, text_hash) {
            self.dict = Some(Arc::new(dict));
            self.awaited = None;
        }
        None
    }
}

/// What a load came to.
struct Loaded {
    dict: Option<Arc<UserDict>>,
    /// Whether the outcome holds for the stamp it was loaded for.
    settled: bool,
    /// Set when the dictionary was built here.
    awaited: Option<Awaited>,
}

/// Load for `stamp`: from the cache in `cache` when it holds the text's
/// blob, built here otherwise; falling back to `previous` — the last good
/// dictionary — when the file is there but cannot be built.
fn load(stamp: Stamp, path: Option<&Path>, cache: Option<&Path>, previous: Option<Arc<UserDict>>) -> Loaded {
    let kept = |dict, settled| Loaded {
        dict,
        settled,
        awaited: None,
    };
    let Some(path) = path.filter(|_| stamp.enabled) else {
        return kept(None, true);
    };
    let bytes = match file::read_bytes(path) {
        Ok(Some(bytes)) => bytes,
        Ok(None) => return kept(None, true),
        // A text editor holding the file mid-save, say: try again next time.
        Err(_) => return kept(previous, false),
    };
    // The cache holds a blob only of a text that was UTF-8, so a blob of
    // these bytes needs no check of them.
    let text_hash = UserDict::hash(&bytes);
    if let Some(dict) = cache.and_then(|dir| cache::open_in(dir, text_hash)) {
        return kept(Some(Arc::new(dict)), true);
    }
    let Ok(text) = std::str::from_utf8(&bytes) else {
        return kept(previous, true);
    };
    match UserDict::build(text, text_hash) {
        Ok((dict, _report)) => Loaded {
            dict: Some(Arc::new(dict)),
            settled: true,
            awaited: cache.map(|dir| {
                let blob = cache::path_in(dir, text_hash);
                Awaited {
                    text_hash,
                    then: file::stamp(&blob),
                    blob,
                }
            }),
        },
        Err(_) => kept(previous, true),
    }
}

/// Whether this host may write the cache: an ordinary desktop application.
/// See the module docs.
fn may_write_cache() -> bool {
    !host::is_app_container() && !host::is_packaged() && !host::is_system()
}

/// Write the blob of `dict`, just built here, to the cache for the other
/// applications, on a thread of its own: 13 MB at the cap, which the key
/// that asked does not wait for. A failure costs them a build of their own,
/// as before there was a cache. The thread may outlive nothing it needs: no
/// DLL of the IME's is ever unloaded (windows/loader).
fn write_in_background(dir: PathBuf, dict: Arc<UserDict>) {
    let _ = std::thread::Builder::new()
        .name("jd-user-dict-cache".into())
        .spawn(move || {
            let _ = cache::write_in(&dir, &dict);
        });
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

    /// A fresh folder under the temp directory, removed on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("jd-tip-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            Self(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn loads_follow_the_switch_the_file_and_the_last_good_dictionary() {
        let temp = TempDir::new("userdict");
        let path = temp.0.join(file::FILE_NAME);
        let cache = temp.0.join(cache::DIR_NAME);
        let load = |stamp, previous| load(stamp, Some(&path), Some(&cache), previous);

        // No file: no dictionary, and that is settled.
        let loaded = load(on(&path), None);
        assert!(loaded.dict.is_none() && loaded.settled);

        file::write(&path, "键道\tzzzzzz\n").unwrap();
        let loaded = load(on(&path), None);
        let good = loaded.dict.expect("a buildable file loads");
        assert!(loaded.settled);
        assert_eq!(good.entries(), 1);
        assert_eq!(good.source_tag(), UserDict::hash("键道\tzzzzzz\n".as_bytes()));

        // Off: nothing, whatever the file holds.
        let off = Stamp {
            enabled: false,
            file: None,
        };
        assert!(load(off, Some(good.clone())).dict.is_none());

        // Not UTF-8: the last good dictionary stays.
        fs::write(&path, [0xC4, 0xE3, 0x09, 0x61, 0x0A]).unwrap();
        let loaded = load(on(&path), Some(good.clone()));
        assert!(Arc::ptr_eq(&loaded.dict.unwrap(), &good));
        assert!(loaded.settled);

        // A line the engine skips is no failure: the rest still loads.
        file::write(&path, "键道\tzzzzzz\n好\tZZ\n").unwrap();
        let dict = load(on(&path), Some(good.clone())).dict.unwrap();
        assert!(!Arc::ptr_eq(&dict, &good));
        assert_eq!(dict.entries(), 1);
    }

    #[test]
    fn a_dictionary_built_here_moves_to_the_shared_copy_once_it_is_there() {
        let temp = TempDir::new("userdict-cache");
        let path = temp.0.join(file::FILE_NAME);
        let cache = temp.0.join(cache::DIR_NAME);
        file::write(&path, "\u{feff}键道\tzzzzzz\n").unwrap();
        let mut state = State {
            stamp: None,
            dict: None,
            awaited: None,
        };

        // Nothing cached: built here, and handed out for the cache.
        let built = state.look(on(&path), Some(&path), Some(&cache)).expect("built here");
        assert!(Arc::ptr_eq(state.dict.as_ref().unwrap(), &built));
        // Looking again changes nothing while the cache is empty.
        assert!(state.look(on(&path), Some(&path), Some(&cache)).is_none());
        assert!(Arc::ptr_eq(state.dict.as_ref().unwrap(), &built));

        // Once it holds the blob, the next look maps it.
        cache::write_in(&cache, &built).unwrap();
        assert!(state.look(on(&path), Some(&path), Some(&cache)).is_none());
        let mapped = state.dict.clone().unwrap();
        assert!(!Arc::ptr_eq(&mapped, &built));
        assert_eq!(mapped.as_bytes(), built.as_bytes());
        assert!(state.awaited.is_none());
        assert!(state.look(on(&path), Some(&path), Some(&cache)).is_none());
        assert!(Arc::ptr_eq(state.dict.as_ref().unwrap(), &mapped));

        // An edit with the blob there already — the window wrote it: mapped
        // straight away, nothing built.
        file::write(&path, "键道\tzzzzzz\n键道输入法\tzzzzza\n").unwrap();
        let text = fs::read_to_string(&path).unwrap();
        let (edited, _) = UserDict::build(&text, UserDict::hash(text.as_bytes())).unwrap();
        cache::write_in(&cache, &edited).unwrap();
        assert!(state.look(on(&path), Some(&path), Some(&cache)).is_none());
        assert_eq!(state.dict.as_ref().unwrap().entries(), 2);
        assert!(state.awaited.is_none());
    }

    #[test]
    fn a_refused_blob_is_not_looked_at_again_until_it_changes() {
        let temp = TempDir::new("userdict-refused");
        let path = temp.0.join(file::FILE_NAME);
        let cache = temp.0.join(cache::DIR_NAME);
        file::write(&path, "键道\tzzzzzz\n").unwrap();
        let hash = UserDict::hash("键道\tzzzzzz\n".as_bytes());
        fs::create_dir_all(&cache).unwrap();
        fs::write(cache::path_in(&cache, hash), b"not a blob").unwrap();
        let mut state = State {
            stamp: None,
            dict: None,
            awaited: None,
        };

        let built = state.look(on(&path), Some(&path), Some(&cache)).expect("built here");
        assert!(state.look(on(&path), Some(&path), Some(&cache)).is_none());
        assert!(Arc::ptr_eq(state.dict.as_ref().unwrap(), &built));

        // The writer replaces it.
        cache::write_in(&cache, &built).unwrap();
        state.look(on(&path), Some(&path), Some(&cache));
        assert!(!Arc::ptr_eq(state.dict.as_ref().unwrap(), &built));
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
