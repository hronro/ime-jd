//! The IME's side of the user dictionary: what a new engine context types
//! from, for every UI thread in this host process.
//!
//! The phrases file and the switches (jd_userdict, ../userdict) change in
//! another process — the 用户自造词 window, a text editor, regedit — while
//! this DLL sits loaded in every application the user types in. There is
//! nothing to subscribe to from in here, so the IME looks before it uses:
//! [`current`] reads the switches and, while the dictionary is on, stats the
//! file — two registry reads and one directory lookup — and loads again only
//! when any of it changed. jd.rs asks at activation and at a key that may
//! start a composition: the moments nothing is composing, the only ones at
//! which a context may be replaced, since its dictionaries are fixed for its
//! lifetime.
//!
//! The second switch, 忽略内置词库, turns the built-in dictionary off while
//! the first is on: the phrases are then built on libjd's empty dictionary
//! (jd_userdict::base) and are all there is to type from. With none to be
//! had — no file, or one that never built — the IME lets every key through
//! as typed ([`Selection::Unavailable`]), and the mode icon's menu says why;
//! it never falls back to the built-in dictionary.
//!
//! A load maps the dictionary compiled once for every application
//! (jd_userdict::cache): it reads and hashes the file and maps the blob of
//! that text on that base, whose pages every application that maps it
//! shares. When the cache holds none — the phrases were edited in a text
//! editor, the IME was updated, the base changed — this process builds the
//! dictionary itself, as each did before there was a cache: 70 ms at the
//! engine's 500 000-phrase cap on a Ryzen 7 5800X, and 13 MB of its own. In
//! an ordinary desktop application it then writes the blob to the cache, on
//! a thread of its own, for the others; and every process that built its own
//! looks for the blob at each look after, a stat, and moves to it once it is
//! there, freeing its copy. Nothing is written from a sandboxed
//! (AppContainer) application, which may not write there and must not be
//! able to — every application reads what lies there; nor from a packaged
//! one, the files it creates under AppData landing in a private copy of its
//! package's that no other application reads (jd_userdict::cache says more);
//! nor on the secure desktop.
//!
//! A file that cannot be built — not UTF-8, over the engine's caps — keeps
//! this process's last good dictionary on the same base; the window says
//! what is wrong. No file means no phrases, never an error: there is no file
//! yet, or the host is a sandbox the window has not granted access to.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use jd::{Dict, UserDict};
use jd_userdict::{LoadError, cache, file, switch};

use crate::host;

/// What a context created now types from, by the two switches.
#[derive(Clone)]
pub enum Selection {
    /// The built-in dictionary, with the user's phrases merged in while they
    /// are on and to be had.
    BuiltIn(Option<Arc<UserDict>>),
    /// The phrases alone, on the empty dictionary: 忽略内置词库.
    UserOnly(Arc<UserDict>),
    /// The phrases alone were asked for and cannot be had, for the reason
    /// given (`用户自造词未能加载：…`): every key reaches the application as
    /// typed. Never the built-in dictionary instead.
    Unavailable(String),
}

impl Selection {
    /// Whether a context made from `self` would be the one made from
    /// `other`: the same dictionaries, at the same addresses. Every
    /// `Unavailable` is the same: its reason is for the user, and the engine
    /// is the same idle one.
    pub fn same_as(&self, other: &Selection) -> bool {
        match (self, other) {
            (Selection::BuiltIn(a), Selection::BuiltIn(b)) => match (a, b) {
                (Some(a), Some(b)) => Arc::ptr_eq(a, b),
                (None, None) => true,
                _ => false,
            },
            (Selection::UserOnly(a), Selection::UserOnly(b)) => Arc::ptr_eq(a, b),
            (Selection::Unavailable(_), Selection::Unavailable(_)) => true,
            _ => false,
        }
    }
}

/// What a load depends on. Equal stamps mean the dictionary in hand is the
/// one a load would produce.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    enabled: bool,
    /// 忽略内置词库, taken only while the dictionary is on.
    user_only: bool,
    /// The file's stamp, taken only while the dictionary is on.
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
    /// The last good dictionary, built on the base `user_only` says.
    dict: Option<Arc<UserDict>>,
    user_only: bool,
    /// While `dict` was built here rather than mapped from the cache.
    awaited: Option<Awaited>,
    /// Why the last load found no dictionary, for the user.
    why: Option<String>,
}

impl State {
    const fn new() -> Self {
        Self {
            stamp: None,
            dict: None,
            user_only: false,
            awaited: None,
            why: None,
        }
    }
}

/// Process-wide: every UI thread's context reads the same dictionary.
static STATE: Mutex<State> = Mutex::new(State::new());

/// Resolved once per process; known folders do not move under a running
/// process.
static PATH: OnceLock<Option<PathBuf>> = OnceLock::new();
static CACHE: OnceLock<Option<PathBuf>> = OnceLock::new();

/// What a context created now should type from. Cheap when nothing changed;
/// see the module docs.
pub fn current() -> Selection {
    let path = PATH.get_or_init(file::path).as_deref();
    let cache = CACHE.get_or_init(cache::dir).as_deref();
    let enabled = switch::is_enabled();
    let stamp = Stamp {
        enabled,
        user_only: enabled && switch::is_user_only(),
        file: if enabled { path.and_then(file::stamp) } else { None },
    };
    let mut state = STATE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(built) = state.look(stamp, path, cache)
        && let Some(dir) = cache
        && may_write_cache()
    {
        write_in_background(dir.to_path_buf(), built, jd_userdict::base(stamp.user_only));
    }
    state.selection(stamp)
}

impl State {
    /// Bring `dict` up to date for `stamp`. Returns the dictionary if it was
    /// just built here — the one the cache lacks.
    fn look(&mut self, stamp: Stamp, path: Option<&Path>, cache: Option<&Path>) -> Option<Arc<UserDict>> {
        if self.stamp != Some(stamp) {
            // The last good dictionary stands in only on its own base: one
            // built on the other does not load on this one.
            let previous = self.dict.take().filter(|_| self.user_only == stamp.user_only);
            let loaded = load(stamp, path, cache, previous);
            self.dict = loaded.dict;
            self.user_only = stamp.user_only;
            self.why = loaded.why;
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
        if let Some(dict) = cache::open_in(dir, text_hash, jd_userdict::base(self.user_only)) {
            self.dict = Some(Arc::new(dict));
            self.awaited = None;
        }
        None
    }

    fn selection(&self, stamp: Stamp) -> Selection {
        if !stamp.enabled {
            return Selection::BuiltIn(None);
        }
        if !stamp.user_only {
            return Selection::BuiltIn(self.dict.clone());
        }
        match &self.dict {
            Some(dict) => Selection::UserOnly(dict.clone()),
            None => Selection::Unavailable(format!(
                "用户自造词未能加载：{}",
                self.why.as_deref().unwrap_or("没有词条文件")
            )),
        }
    }
}

/// What a load came to.
struct Loaded {
    dict: Option<Arc<UserDict>>,
    /// Whether the outcome holds for the stamp it was loaded for.
    settled: bool,
    /// Set when the dictionary was built here.
    awaited: Option<Awaited>,
    /// Why the load found no dictionary, when it did not.
    why: Option<String>,
}

/// Load for `stamp`: on the base it chooses, from the cache in `cache` when
/// it holds the text's blob, built here otherwise; falling back to
/// `previous` — the last good dictionary, on the same base — when the file
/// is there but cannot be built.
fn load(stamp: Stamp, path: Option<&Path>, cache: Option<&Path>, previous: Option<Arc<UserDict>>) -> Loaded {
    if !stamp.enabled {
        return Loaded {
            dict: None,
            settled: true,
            awaited: None,
            why: None,
        };
    }
    let base = jd_userdict::base(stamp.user_only);
    let loaded = match path {
        Some(path) => cache::load(path, cache, base),
        None => Err(LoadError::Missing),
    };
    match loaded {
        Ok(loaded) => {
            let text_hash = loaded.dict.source_tag();
            let awaited = cache.filter(|_| !loaded.mapped).map(|dir| {
                let blob = cache::path_in(dir, text_hash, base);
                Awaited {
                    text_hash,
                    then: file::stamp(&blob),
                    blob,
                }
            });
            Loaded {
                dict: Some(Arc::new(loaded.dict)),
                settled: true,
                awaited,
                why: None,
            }
        }
        Err(error) => Loaded {
            // No file: no phrases. Otherwise the last good dictionary.
            dict: if matches!(error, LoadError::Missing) { None } else { previous },
            // A text editor holding the file mid-save, say: try again next
            // time.
            settled: !matches!(error, LoadError::Unreadable(_)),
            awaited: None,
            why: Some(error.message()),
        },
    }
}

/// Whether this host may write the cache: an ordinary desktop application.
/// See the module docs.
fn may_write_cache() -> bool {
    !host::is_app_container() && !host::is_packaged() && !host::is_system()
}

/// Write the blob of `dict`, just built here on `base`, to the cache for the
/// other applications, on a thread of its own: 13 MB at the cap, which the
/// key that asked does not wait for. A failure costs them a build of their
/// own, as before there was a cache. The thread may outlive nothing it
/// needs: no DLL of the IME's is ever unloaded (windows/loader).
fn write_in_background(dir: PathBuf, dict: Arc<UserDict>, base: Option<&'static Dict>) {
    let _ = std::thread::Builder::new()
        .name("jd-user-dict-cache".into())
        .spawn(move || {
            let _ = cache::write_in(&dir, &dict, base);
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn on(path: &Path) -> Stamp {
        Stamp {
            enabled: true,
            user_only: false,
            file: file::stamp(path),
        }
    }

    fn alone(path: &Path) -> Stamp {
        Stamp {
            user_only: true,
            ..on(path)
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
        assert_eq!(loaded.why.as_deref(), Some("没有词条文件"));

        file::write(&path, "键道\tzzzzzz\n").unwrap();
        let loaded = load(on(&path), None);
        let good = loaded.dict.expect("a buildable file loads");
        assert!(loaded.settled);
        assert_eq!(good.entries(), 1);
        assert_eq!(good.source_tag(), UserDict::hash("键道\tzzzzzz\n".as_bytes()));

        // Off: nothing, whatever the file holds.
        let off = Stamp {
            enabled: false,
            user_only: false,
            file: None,
        };
        assert!(load(off, Some(good.clone())).dict.is_none());

        // Not UTF-8: the last good dictionary stays.
        fs::write(&path, [0xC4, 0xE3, 0x09, 0x61, 0x0A]).unwrap();
        let loaded = load(on(&path), Some(good.clone()));
        assert!(Arc::ptr_eq(&loaded.dict.unwrap(), &good));
        assert!(loaded.settled);
        assert_eq!(loaded.why.as_deref(), Some("文件不是 UTF-8 编码"));

        // A line the engine skips is no failure: the rest still loads.
        file::write(&path, "键道\tzzzzzz\n好\tZZ\n").unwrap();
        let dict = load(on(&path), Some(good.clone())).dict.unwrap();
        assert!(!Arc::ptr_eq(&dict, &good));
        assert_eq!(dict.entries(), 1);
    }

    #[test]
    fn ignoring_the_built_in_dictionary_types_the_phrases_alone_or_nothing() {
        let temp = TempDir::new("userdict-alone");
        let path = temp.0.join(file::FILE_NAME);
        let cache = temp.0.join(cache::DIR_NAME);
        let mut state = State::new();
        let mut select = |stamp| {
            state.look(stamp, Some(&path), Some(&cache));
            state.selection(stamp)
        };

        // No phrases to be had: nothing at all, and the reason.
        let Selection::Unavailable(why) = select(alone(&path)) else {
            panic!("no file: nothing to type from");
        };
        assert_eq!(why, "用户自造词未能加载：没有词条文件");

        // "不" on b repeats a built-in word: kept on the empty dictionary.
        file::write(&path, "不\tb\n键道\tzzzzzz\n").unwrap();
        let Selection::BuiltIn(Some(merged)) = select(on(&path)) else {
            panic!("the phrases on the built-in dictionary");
        };
        assert_eq!(merged.entries(), 1);
        let Selection::UserOnly(only) = select(alone(&path)) else {
            panic!("the phrases alone");
        };
        assert_eq!(only.entries(), 2);

        // A file that stops building keeps the last good phrases — of this
        // base only.
        fs::write(&path, [0xC4, 0xE3, 0x09, 0x61, 0x0A]).unwrap();
        let Selection::UserOnly(kept) = select(alone(&path)) else {
            panic!("the last good phrases");
        };
        assert!(Arc::ptr_eq(&kept, &only));
        assert!(matches!(select(on(&path)), Selection::BuiltIn(None)));
        let Selection::Unavailable(why) = select(alone(&path)) else {
            panic!("nothing good on this base any more");
        };
        assert_eq!(why, "用户自造词未能加载：文件不是 UTF-8 编码");

        // The dictionary off: the built-in one, whatever the second switch.
        let off = Stamp {
            enabled: false,
            user_only: false,
            file: None,
        };
        assert!(matches!(select(off), Selection::BuiltIn(None)));
    }

    #[test]
    fn selections_are_the_same_when_their_dictionaries_are() {
        let (dict, _) = jd_userdict::build("键道\tzzzzzz\n", None).unwrap();
        let dict = Arc::new(dict);
        let other = Arc::new(jd_userdict::build("键道\tzzzzzz\n", None).unwrap().0);
        let builtin = Selection::BuiltIn(Some(dict.clone()));
        assert!(builtin.same_as(&Selection::BuiltIn(Some(dict.clone()))));
        assert!(!builtin.same_as(&Selection::BuiltIn(Some(other))));
        assert!(!builtin.same_as(&Selection::BuiltIn(None)));
        assert!(!builtin.same_as(&Selection::UserOnly(dict.clone())));
        assert!(Selection::Unavailable("a".into()).same_as(&Selection::Unavailable("b".into())));
    }

    #[test]
    fn a_dictionary_built_here_moves_to_the_shared_copy_once_it_is_there() {
        let temp = TempDir::new("userdict-cache");
        let path = temp.0.join(file::FILE_NAME);
        let cache = temp.0.join(cache::DIR_NAME);
        file::write(&path, "\u{feff}键道\tzzzzzz\n").unwrap();
        let mut state = State::new();

        // Nothing cached: built here, and handed out for the cache.
        let built = state.look(on(&path), Some(&path), Some(&cache)).expect("built here");
        assert!(Arc::ptr_eq(state.dict.as_ref().unwrap(), &built));
        // Looking again changes nothing while the cache is empty.
        assert!(state.look(on(&path), Some(&path), Some(&cache)).is_none());
        assert!(Arc::ptr_eq(state.dict.as_ref().unwrap(), &built));

        // Once it holds the blob, the next look maps it.
        cache::write_in(&cache, &built, None).unwrap();
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
        let (edited, _) = jd_userdict::build(&text, None).unwrap();
        cache::write_in(&cache, &edited, None).unwrap();
        assert!(state.look(on(&path), Some(&path), Some(&cache)).is_none());
        assert_eq!(state.dict.as_ref().unwrap().entries(), 2);
        assert!(state.awaited.is_none());

        // The other base is another blob: built here, then shared the same
        // way.
        let built = state.look(alone(&path), Some(&path), Some(&cache)).expect("built here");
        let empty = Some(jd_userdict::empty_dict());
        cache::write_in(&cache, &built, empty).unwrap();
        state.look(alone(&path), Some(&path), Some(&cache));
        assert!(state.awaited.is_none());
        assert_eq!(state.dict.as_ref().unwrap().as_bytes(), built.as_bytes());
    }

    #[test]
    fn a_refused_blob_is_not_looked_at_again_until_it_changes() {
        let temp = TempDir::new("userdict-refused");
        let path = temp.0.join(file::FILE_NAME);
        let cache = temp.0.join(cache::DIR_NAME);
        file::write(&path, "键道\tzzzzzz\n").unwrap();
        let hash = UserDict::hash("键道\tzzzzzz\n".as_bytes());
        fs::create_dir_all(&cache).unwrap();
        fs::write(cache::path_in(&cache, hash, None), b"not a blob").unwrap();
        let mut state = State::new();

        let built = state.look(on(&path), Some(&path), Some(&cache)).expect("built here");
        assert!(state.look(on(&path), Some(&path), Some(&cache)).is_none());
        assert!(Arc::ptr_eq(state.dict.as_ref().unwrap(), &built));

        // The writer replaces it.
        cache::write_in(&cache, &built, None).unwrap();
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
