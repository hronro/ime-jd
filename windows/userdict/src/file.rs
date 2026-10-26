//! The phrases file — libjd's own table format — where it lives, and how its
//! lines are read and written. The format, header line included, is the one
//! every client writes, so a file moves between devices as it is. It has no
//! rules of its own: libjd is the authority on what a line means — it parses
//! the whole file on every build, skips the lines that do not parse and says
//! why, by line number — so the window writes what the user typed and shows
//! the engine's verdict. What is mirrored here is only how a line is split
//! into fields for display.
//!
//! One `value<TAB>keys` line per phrase, `#` comments, blank lines ignored.
//! The file is read leniently — comments and blank lines are skipped, a line
//! without a TAB becomes a row with empty keys so it can be fixed — and
//! written back as one header comment plus one line per entry. Anything a
//! text editor put between the lines is gone after the first save from the
//! window; a phrase list is a list, not a document.

use std::ffi::{OsString, c_void};
use std::fs;
use std::io::{self, Write};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::str::Utf8Error;

use windows::Win32::Storage::FileSystem::{
    GetFileAttributesExW, GetFileExInfoStandard, WIN32_FILE_ATTRIBUTE_DATA,
};
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::UI::Shell::{FOLDERID_RoamingAppData, KF_FLAG_DONT_VERIFY, SHGetKnownFolderPath};
use windows::core::PCWSTR;

/// The file, in [`dir`].
pub const FILE_NAME: &str = "用户自造词.txt";
/// The folder under the roaming AppData folder; the install folder under
/// Program Files has the same name.
pub const DIR_NAME: &str = "ime-jd";

/// One phrase: the committable text and the code that reaches it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Entry {
    pub value: String,
    pub keys: String,
}

impl Entry {
    pub fn new(value: impl Into<String>, keys: impl Into<String>) -> Self {
        Self {
            value: value.into(),
            keys: keys.into(),
        }
    }
}

/// A parsed row: the entry plus the 1-based line it came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub line: u32,
    pub entry: Entry,
}

/// `%APPDATA%\ime-jd`: the roaming AppData folder as the shell resolves it
/// (folder redirection included), plus ours. `None` when the shell cannot
/// resolve it.
///
/// Resolved without the shell's check that the folder exists: a sandboxed
/// (AppContainer) host may not look at the roaming folder itself, so the
/// check fails there with access denied, while the folder ours sits in is
/// granted to it ([`crate::access`]).
pub fn dir() -> Option<PathBuf> {
    // SAFETY: on success the shell hands back a NUL-terminated path in
    // CoTaskMem memory, which is copied out and then freed.
    unsafe {
        let raw = SHGetKnownFolderPath(&FOLDERID_RoamingAppData, KF_FLAG_DONT_VERIFY, None).ok()?;
        let roaming = OsString::from_wide(raw.as_wide());
        CoTaskMemFree(Some(raw.0 as *const c_void));
        Some(PathBuf::from(roaming).join(DIR_NAME))
    }
}

/// `%APPDATA%\ime-jd\用户自造词.txt`.
pub fn path() -> Option<PathBuf> {
    dir().map(|dir| dir.join(FILE_NAME))
}

/// Why the file could not be read.
#[derive(Debug)]
pub enum ReadError {
    /// The file is not UTF-8. libjd would reject it line by line; a client
    /// says so once.
    NotUtf8,
    Io(io::Error),
}

/// The file's text, or `None` when there is no file. A UTF-8 BOM is
/// dropped: libjd would otherwise take U+FEFF as part of the first value.
pub fn read(path: &Path) -> Result<Option<String>, ReadError> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(ReadError::Io(e)),
    };
    let mut text = String::from_utf8(bytes).map_err(|_| ReadError::NotUtf8)?;
    if text.starts_with('\u{feff}') {
        text.drain(..'\u{feff}'.len_utf8());
    }
    Ok(Some(text))
}

/// Strict UTF-8, minus a leading byte-order mark — [`read`] on bytes
/// already in hand.
pub fn decode(bytes: &[u8]) -> Result<&str, Utf8Error> {
    let text = std::str::from_utf8(bytes)?;
    Ok(text.strip_prefix('\u{feff}').unwrap_or(text))
}

/// Replace the file with `text`, atomically: it is written beside the file
/// and renamed over it, so a reader — the IME in every host process — never
/// sees half a file. Creates the folder when needed. The new file takes the
/// folder's inheritable ACEs, so sandboxed hosts keep their read access
/// ([`crate::access`]).
pub fn write(path: &Path, text: &str) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no parent folder"))?;
    fs::create_dir_all(dir)?;
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(format!(".{}.tmp", std::process::id()));
    let temp = dir.join(name);
    let result = (|| {
        let mut file = fs::File::create(&temp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

/// Split the way libjd does — on `\n`, counting from 1, `\r` and spaces
/// trimmed from both ends — skipping comments and blank lines. Lenient on
/// purpose: fields are not validated, and a line without a TAB becomes a
/// row whose value is the whole line and whose keys are empty.
pub fn parse(text: &str) -> Vec<Row> {
    let mut rows = Vec::new();
    for (index, raw) in text.split('\n').enumerate() {
        let line = raw.trim_matches(|c| c == ' ' || c == '\r');
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let entry = match line.split_once('\t') {
            Some((value, keys)) => Entry::new(value.trim_matches(' '), keys.trim_matches(' ')),
            None => Entry::new(line, ""),
        };
        rows.push(Row {
            line: index as u32 + 1,
            entry,
        });
    }
    rows
}

/// The first line of every file the window writes, for whoever opens it in
/// a text editor.
pub fn header() -> String {
    format!(
        "# 键道用户自造词：每行一条，格式为「词<TAB>编码」，编码由 a-z 组成，1 到 {} 个字符。",
        jd::UserDict::MAX_KEY_LENGTH
    )
}

/// The header plus one `value<TAB>keys` line per entry, LF-terminated.
/// Entry `i` lands on line [`line_of_entry`]`(i)`.
pub fn serialize(entries: &[Entry]) -> String {
    let mut text = header();
    text.push('\n');
    for entry in entries {
        text.push_str(&entry.value);
        text.push('\t');
        text.push_str(&entry.keys);
        text.push('\n');
    }
    text
}

/// The 1-based line the entry at `index` occupies after [`serialize`].
pub fn line_of_entry(index: usize) -> u32 {
    index as u32 + 2
}

/// FNV-1a, 64-bit — the Swift and Android clients' function — over the
/// file's bytes: the dictionary's source tag.
pub fn hash(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// A file's size and last-write time: what changes whenever anything
/// rewrites it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stamp {
    pub size: u64,
    pub modified: u64,
}

/// The file's [`Stamp`], read from its directory entry without opening it;
/// `None` when there is no file or it cannot be looked at.
pub fn stamp(path: &Path) -> Option<Stamp> {
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain([0]).collect();
    let mut data = WIN32_FILE_ATTRIBUTE_DATA::default();
    // SAFETY: a NUL-terminated path, and a buffer of the struct the
    // standard info level fills.
    unsafe {
        GetFileAttributesExW(
            PCWSTR(wide.as_ptr()),
            GetFileExInfoStandard,
            &mut data as *mut _ as *mut c_void,
        )
    }
    .ok()?;
    let modified = data.ftLastWriteTime;
    Some(Stamp {
        size: (u64::from(data.nFileSizeHigh) << 32) | u64::from(data.nFileSizeLow),
        modified: (u64::from(modified.dwHighDateTime) << 32) | u64::from(modified.dwLowDateTime),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use jd::UserDict;

    fn row(line: u32, value: &str, keys: &str) -> Row {
        Row {
            line,
            entry: Entry::new(value, keys),
        }
    }

    /// A fresh folder under the temp directory, removed on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "jd-userdict-{tag}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn parse_skips_comments_and_blanks_and_keeps_line_numbers() {
        let text = "# header\n\n你好\tnh\r\n  世界 \t sj  \n# tail\n键道\tjd";
        assert_eq!(
            parse(text),
            vec![row(3, "你好", "nh"), row(4, "世界", "sj"), row(6, "键道", "jd")]
        );
    }

    #[test]
    fn parse_is_lenient_about_missing_tabs() {
        // A line without a TAB keeps its text and gets empty keys, so the
        // window can show it and let the user fix it in place. The engine,
        // not the window, says what is wrong with it.
        let text = "no tab here\n好\thz\n";
        let rows = parse(text);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0], row(1, "no tab here", ""));
        let (_, report) = UserDict::build(text, 0).unwrap();
        assert_eq!(report.invalid_lines(), vec![1]);
    }

    #[test]
    fn parse_reads_a_comment_by_its_first_byte() {
        // "#" plus a combining mark is a comment to the engine, which reads
        // bytes, so it is no row here either.
        let text = "#\u{0301} 注释\tzzzzza\n键道\tzzzzzz\n";
        assert_eq!(parse(text), vec![row(2, "键道", "zzzzzz")]);
        let (_, report) = UserDict::build(text, 0).unwrap();
        assert_eq!(report.entries, 1, "a phrase on zzzzza would make two");
        assert_eq!(report.invalid, 0);
    }

    #[test]
    fn serialize_writes_the_header_and_round_trips() {
        let entries = vec![Entry::new("你好", "nh"), Entry::new("键道输入法", "jdsrf")];
        let text = serialize(&entries);
        assert!(text.starts_with(&(header() + "\n")));
        assert!(text.ends_with('\n'));
        assert!(!text.contains('\r'));
        let rows = parse(&text);
        assert_eq!(
            rows.iter().map(|r| r.entry.clone()).collect::<Vec<_>>(),
            entries
        );
        assert_eq!(rows.iter().map(|r| r.line).collect::<Vec<_>>(), vec![2, 3]);
        assert_eq!(
            rows.iter().map(|r| r.line).collect::<Vec<_>>(),
            (0..entries.len()).map(line_of_entry).collect::<Vec<_>>()
        );
        assert_eq!(serialize(&[]), header() + "\n");
    }

    #[test]
    fn the_header_is_a_comment_to_the_engine_and_names_its_key_cap() {
        let (dict, report) =
            UserDict::build(&serialize(&[Entry::new("键道", "zzzzzz")]), 0).unwrap();
        assert_eq!((report.entries, report.dropped, report.invalid), (1, 0, 0));
        assert_eq!(dict.entries(), 1);
        assert!(header().contains(&format!("1 到 {} 个字符", UserDict::MAX_KEY_LENGTH)));
    }

    #[test]
    fn decode_drops_the_bom_and_rejects_non_utf8() {
        assert_eq!(decode("\u{feff}好\thz\n".as_bytes()).unwrap(), "好\thz\n");
        assert_eq!(decode(b"").unwrap(), "");
        assert_eq!(
            decode("好\thz\n\u{feff}".as_bytes()).unwrap(),
            "好\thz\n\u{feff}",
            "only a leading BOM is one"
        );
        assert!(decode(&[0xC4, 0xE3, 0x09, 0x61]).is_err());
    }

    #[test]
    fn read_and_write_through_a_file() {
        let temp = TempDir::new("rw");
        let path = temp.0.join("nested").join(FILE_NAME);

        assert!(read(&path).unwrap().is_none(), "no file reads as None");
        assert!(stamp(&path).is_none());
        write(&path, "好\thz\n").unwrap();
        assert_eq!(read(&path).unwrap().as_deref(), Some("好\thz\n"));
        let first = stamp(&path).unwrap();
        assert_eq!(first.size, "好\thz\n".len() as u64);
        write(&path, "").unwrap();
        assert_eq!(read(&path).unwrap().as_deref(), Some(""));
        assert_ne!(stamp(&path), Some(first));
        // Nothing is left beside the file.
        assert_eq!(fs::read_dir(path.parent().unwrap()).unwrap().count(), 1);

        fs::write(&path, b"\xEF\xBB\xBF\xE5\xA5\xBD\thz\n").unwrap();
        assert_eq!(read(&path).unwrap().as_deref(), Some("好\thz\n"));
        fs::write(&path, [0xC4, 0xE3, 0x09, 0x61]).unwrap();
        assert!(matches!(read(&path), Err(ReadError::NotUtf8)));
    }

    #[test]
    fn the_engine_owns_the_field_rules() {
        // The window mirrors none of libjd's rules: the boundary cases are
        // the engine's to judge, and a bad line costs only itself.
        let (_, ok) = UserDict::build(&format!("{}\tzzzzzz\n", "字".repeat(85)), 0).unwrap();
        assert_eq!(ok.invalid, 0);
        let (_, bad) = UserDict::build(
            &format!("{}\tzzzzzz\n好\tabcdefg\n键道\tzzzzza\n", "字".repeat(86)),
            0,
        )
        .unwrap();
        assert_eq!(bad.entries, 1);
        assert_eq!(bad.invalid_lines(), vec![1, 2]);
    }

    #[test]
    fn hash_matches_the_fnv1a_reference_vectors() {
        assert_eq!(hash(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(hash(b"a"), 0xaf63_dc4c_8601_ec8c);
        assert_ne!(hash("好\thz\n".as_bytes()), hash("好\thz".as_bytes()));
    }

    #[test]
    fn the_file_lives_in_roaming_app_data() {
        let path = path().expect("the shell resolves the roaming AppData folder");
        assert!(path.is_absolute());
        assert!(path.ends_with(Path::new(DIR_NAME).join(FILE_NAME)));
    }
}
