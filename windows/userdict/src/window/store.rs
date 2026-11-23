//! The window's side of the phrases file: read it and build it — for the
//! engine's verdicts on its rows and its whole-file errors — and write it as
//! the list is edited. The IME reads the same file and switches by itself,
//! in every host process (windows/src/user_dict.rs), so nothing in the
//! window ever talks to it; but each build of the user's own file also goes
//! to the IME's shared cache (jd_userdict::cache), so that no application
//! has to build it.
//!
//! The phrases are built on the dictionary 忽略内置词库 chooses
//! (jd_userdict::base) — the built-in one, or the empty one — as the IME
//! builds them: what a row repeats or shares a code with depends on it.

use std::io;
use std::path::PathBuf;

use jd::{UserDict, UserDictReport};
use jd_userdict::{Entry, LoadError, cache, file};

pub struct Store {
    pub path: PathBuf,
    /// The IME's shared cache, when `path` is the user's own file; `None`
    /// for another file (`--file`), whose builds no application reads.
    cache_dir: Option<PathBuf>,
    /// 忽略内置词库: the phrases are built on the empty dictionary.
    user_only: bool,
    /// libjd's hash of the text as last read or written; `None` when there
    /// is no file or it could not be read. The report and the error are
    /// about that text, on the base `user_only` says, so a file that reads
    /// back as it — the store's own write, most often — costs a hash and no
    /// build.
    hash: Option<u64>,
    /// The notes of the build of the file as last read or written; `None`
    /// when there is no file or it could not be built.
    report: Option<UserDictReport>,
    /// Why the file as last read or written could not be loaded at all.
    /// Never [`LoadError::Missing`]: no file is an empty list.
    last_error: Option<LoadError>,
}

impl Store {
    pub fn new(path: PathBuf, cache_dir: Option<PathBuf>, user_only: bool) -> Self {
        Self {
            path,
            cache_dir,
            user_only,
            hash: None,
            report: None,
            last_error: None,
        }
    }

    pub fn report(&self) -> Option<&UserDictReport> {
        self.report.as_ref()
    }

    pub fn last_error(&self) -> Option<&LoadError> {
        self.last_error.as_ref()
    }

    /// libjd's hash of the text as last read or written, which tells one
    /// version of the file from another; `None` while there is no text.
    pub fn hash(&self) -> Option<u64> {
        self.hash
    }

    pub fn user_only(&self) -> bool {
        self.user_only
    }

    /// Build on the other base from now on: the text in hand counts as
    /// unbuilt, so the next [`Self::reload`] builds it again. Returns the
    /// hash of that text, to tell whether the next read is still it.
    pub fn set_user_only(&mut self, on: bool) -> Option<u64> {
        let before = self.hash;
        if on != self.user_only {
            self.user_only = on;
            self.hash = None;
        }
        before
    }

    /// Read the file and build it. Returns the text, `None` when there is no
    /// file — or when it cannot be read, which `last_error` then says.
    pub fn reload(&mut self) -> Option<String> {
        match file::read(&self.path) {
            Ok(text) => {
                self.adopt(text.as_deref());
                text
            }
            Err(error) => {
                self.fail(error.into());
                None
            }
        }
    }

    /// Write `entries` as the whole file, as typed, then adopt what was
    /// written. A file the engine refuses as a whole is still written — the
    /// rows are the user's, and they are looking at them — and the error
    /// says why it does not load.
    pub fn save<'a>(&mut self, entries: impl IntoIterator<Item = &'a Entry>) -> io::Result<()> {
        let text = file::serialize(entries);
        file::write(&self.path, &text)?;
        self.adopt(Some(&text));
        Ok(())
    }

    fn adopt(&mut self, text: Option<&str>) {
        let Some(text) = text else {
            self.hash = None;
            self.report = None;
            self.last_error = None;
            return;
        };
        let hash = UserDict::hash(text.as_bytes());
        // The same text builds the same: the report or the error in hand.
        if self.hash == Some(hash) {
            return;
        }
        self.hash = Some(hash);
        let base = jd_userdict::base(self.user_only);
        match jd_userdict::build(text, base) {
            Ok((dict, report)) => {
                // A failure costs each application a build of its own, as
                // before there was a cache.
                if let Some(dir) = &self.cache_dir {
                    let _ = cache::write_in(dir, &dict, base);
                }
                self.report = Some(report);
                self.last_error = None;
            }
            Err(error) => {
                self.report = None;
                self.last_error = Some(LoadError::Build(error));
            }
        }
    }

    fn fail(&mut self, error: LoadError) {
        self.hash = None;
        self.report = None;
        self.last_error = Some(error);
    }
}
