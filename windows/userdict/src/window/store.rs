//! The window's side of the phrases file: read it and build it — for the
//! engine's verdicts on its rows and its whole-file errors — and write it as
//! the list is edited. The IME reads the same file and switch by itself, in
//! every host process (windows/src/user_dict.rs), so nothing in the window
//! ever talks to it.

use std::io;
use std::path::PathBuf;

use jd::{UserDict, UserDictError, UserDictReport, UserDictStatus};
use jd_userdict::{Entry, file};

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
                UserDictStatus::TextTooLong => "文件超过 8 MB 上限".to_owned(),
                _ => format!("无法编译词库（{error}）"),
            },
        }
    }
}

pub struct Store {
    pub path: PathBuf,
    /// The notes of the build of the file as last read or written; `None`
    /// when there is no file or it could not be built.
    report: Option<UserDictReport>,
    /// Why the file as last read or written could not be loaded at all.
    last_error: Option<LoadError>,
}

impl Store {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
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
    /// says why it does not load. Returns the text written.
    pub fn save(&mut self, entries: &[Entry]) -> io::Result<String> {
        let text = file::serialize(entries);
        file::write(&self.path, &text)?;
        self.adopt(Some(&text));
        Ok(text)
    }

    fn adopt(&mut self, text: Option<&str>) {
        let Some(text) = text else {
            self.report = None;
            self.last_error = None;
            return;
        };
        match UserDict::build(text, file::hash(text.as_bytes())) {
            Ok((_, report)) => {
                self.report = Some(report);
                self.last_error = None;
            }
            Err(error) => self.fail(LoadError::Build(error)),
        }
    }

    fn fail(&mut self, error: LoadError) {
        self.report = None;
        self.last_error = Some(error);
    }
}
