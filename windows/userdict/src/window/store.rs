//! The window's side of the phrases file: read it and build it — for the
//! engine's verdicts on its rows and its whole-file errors — and write it as
//! the list is edited. The IME reads the same file and switch by itself, in
//! every host process (windows/src/user_dict.rs), so nothing in the window
//! ever talks to it; but each build of the user's own file also goes to the
//! IME's shared cache (jd_userdict::cache), so that no application has to
//! build it.

use std::io;
use std::path::PathBuf;

use jd::{UserDict, UserDictError, UserDictReport, UserDictStatus};
use jd_userdict::{Entry, cache, file};

/// Why the file as a whole could not be loaded. A line that does not parse
/// is never this: the engine skips it and the row says why.
#[derive(Debug)]
pub enum LoadError {
    NotUtf8,
    Unreadable(io::Error),
    /// The engine refused the whole file: too many phrases, too much text.
    Build(UserDictError),
}

impl LoadError {
    /// For the user.
    pub fn message(&self) -> String {
        match self {
            LoadError::NotUtf8 => "文件不是 UTF-8 编码".to_owned(),
            LoadError::Unreadable(error) => format!("无法读取文件：{error}"),
            LoadError::Build(error) => match error.status {
                UserDictStatus::TooManyEntries => {
                    format!("第 {} 行起超过 {} 条上限", error.line, UserDict::MAX_ENTRIES)
                }
                UserDictStatus::TextTooLong => {
                    format!("文件超过 {} MB 上限", UserDict::MAX_TEXT_BYTES / (1024 * 1024))
                }
                _ => format!("无法编译词库（{error}）"),
            },
        }
    }
}

pub struct Store {
    pub path: PathBuf,
    /// The IME's shared cache, when `path` is the user's own file; `None`
    /// for another file (`--file`), whose builds no application reads.
    cache_dir: Option<PathBuf>,
    /// libjd's hash of the text as last read or written; `None` when there
    /// is no file or it could not be read. The report and the error are
    /// about that text, so a file that reads back as it — the store's own
    /// write, most often — costs a hash and no build.
    hash: Option<u64>,
    /// The notes of the build of the file as last read or written; `None`
    /// when there is no file or it could not be built.
    report: Option<UserDictReport>,
    /// Why the file as last read or written could not be loaded at all.
    last_error: Option<LoadError>,
}

impl Store {
    pub fn new(path: PathBuf, cache_dir: Option<PathBuf>) -> Self {
        Self {
            path,
            cache_dir,
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

    /// Read the file and build it. Returns the text, `None` when there is no
    /// file — or when it cannot be read, which `last_error` then says.
    pub fn reload(&mut self) -> Option<String> {
        match file::read(&self.path) {
            Ok(text) => {
                self.adopt(text.as_deref());
                text
            }
            Err(file::ReadError::NotUtf8) => {
                self.fail(LoadError::NotUtf8);
                None
            }
            Err(file::ReadError::Io(error)) => {
                self.fail(LoadError::Unreadable(error));
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
        match UserDict::build(text, hash) {
            Ok((dict, report)) => {
                // A failure costs each application a build of its own, as
                // before there was a cache.
                if let Some(dir) = &self.cache_dir {
                    let _ = cache::write_in(dir, &dict);
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
