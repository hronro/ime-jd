//! The compiled user dictionary, kept for every application to share. The
//! IME is a DLL inside each application the user types in, and each would
//! otherwise build the dictionary from the phrases file itself: at 500 000
//! phrases, 70-80 ms and 13 MB apiece. Instead, the first to build it writes
//! the blob here, and every application memory-maps that file: one copy of
//! the pages for all of them, and about 10 ms at the cap to read and hash
//! the phrases file and check the blob, with nothing to build.
//!
//! A blob is named for what it is: libjd's hash of the text it was built
//! from — the phrases file with its BOM dropped, its source tag too — and
//! [`library`], what tells one libjd's blobs, on one dictionary, from
//! another's: the phrases are built on the built-in dictionary, or under
//! 忽略内置词库 on the empty one, and a blob built on one does not load on
//! the other. A name is therefore written once and never replaced: a new
//! text, a new version of the IME or the other base is a new name, so no one
//! rewrites a file an application has mapped, and two versions of the IME
//! running side by side during an update never fight over one file. Every
//! write sweeps away the other blobs. Deleting a mapped file works — its
//! name goes, and whoever mapped it keeps reading what it held.
//!
//! An application maps a blob with the file open for reading and shared
//! with no writer, for as long as it reads the blob, so no one can change
//! the bytes under it; and libjd checks a blob as `jd_init` does before it
//! is used. What writes here are the 用户自造词 window, when it reads or
//! saves the phrases, and the IME in an ordinary desktop application that
//! found no blob and built its own (windows/src/user_dict.rs) — never in a
//! sandboxed application, which may not write here and must not be given
//! the right: every application reads what lies here. Nor in a packaged
//! one (MSIX): Windows puts the files it creates under AppData in a private
//! copy of the package's — and before Windows 10 1903 every change it
//! makes — while from 1903 on its deletions reach the real folder, so its
//! blob would reach no other application and its sweep would take theirs.
//! It reads the real folder wherever its private copy holds nothing, so it
//! maps the blobs here like any other.
//!
//! The folder is `%LOCALAPPDATA%\ime-jd\userdict-cache`: local, not
//! roaming — a cache is no part of the profile — and readable by sandboxed
//! applications ([`crate::access`]).

use std::fs;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use jd::{Dict, UserDict};
use windows::Win32::Foundation::{CloseHandle, GENERIC_READ, HANDLE};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_DELETE, FILE_SHARE_READ, GetFileSizeEx,
    MOVE_FILE_FLAGS, MoveFileExW, OPEN_EXISTING,
};
use windows::Win32::System::Memory::{
    CreateFileMappingW, FILE_MAP_READ, MEMORY_MAPPED_VIEW_ADDRESS, MapViewOfFile, PAGE_READONLY,
    UnmapViewOfFile,
};
use windows::Win32::UI::Shell::FOLDERID_LocalAppData;
use windows::core::PCWSTR;

use crate::file::{self, LoadError};

/// The folder under `%LOCALAPPDATA%\ime-jd`.
pub const DIR_NAME: &str = "userdict-cache";

/// More than any blob libjd builds — the 16 MiB text cap plus 16 bytes a
/// phrase — so a stray file is never mapped whole into a 32-bit host.
const MAX_BLOB: i64 = 64 * 1024 * 1024;

/// How old a temporary file must be before a sweep takes it for one left
/// behind: a write takes a fraction of a second.
const STALE_TEMP: Duration = Duration::from_secs(600);

/// `%LOCALAPPDATA%\ime-jd\userdict-cache`; `None` when the shell cannot
/// resolve the folder.
pub fn dir() -> Option<PathBuf> {
    Some(file::known_folder(&FOLDERID_LocalAppData)?.join(file::DIR_NAME).join(DIR_NAME))
}

/// What tells this libjd's blobs on `base` ([`crate::base`]) from any
/// other's: the hash of the blob of no phrases built on `base`, which is
/// only its header — the format version and the fingerprint of the
/// dictionary beneath, the things that decide whether a blob loads. Two
/// versions of the IME whose blobs would load in each other share the files;
/// two whose blobs would not, and the two bases, name theirs apart. A few
/// microseconds: an empty build.
pub fn library(base: Option<&Dict>) -> u64 {
    let empty = match base {
        Some(dict) => UserDict::build_on(dict, "", 0),
        None => UserDict::build("", 0),
    };
    empty.map(|(dict, _)| UserDict::hash(dict.as_bytes())).unwrap_or(0)
}

/// Where the blob of the text whose hash is `text_hash`, built on `base`,
/// lies in `dir`.
pub fn path_in(dir: &Path, text_hash: u64, base: Option<&Dict>) -> PathBuf {
    dir.join(format!("{text_hash:016x}-{:016x}.blob", library(base)))
}

/// The dictionary of the text whose hash is `text_hash`, on `base`, mapped
/// from its blob in `dir`: `None` when there is none, or none that libjd
/// accepts as that text's.
pub fn open_in(dir: &Path, text_hash: u64, base: Option<&Dict>) -> Option<UserDict> {
    let map = Map::open(&path_in(dir, text_hash, base))?;
    // SAFETY: the map keeps the file open, shared with no writer, until it
    // is dropped with the dictionary: its bytes neither move nor change.
    let dict = unsafe {
        match base {
            Some(base) => UserDict::from_mapped_blob_on(base, map),
            None => UserDict::from_mapped_blob(map),
        }
    }
    .ok()?;
    (dict.source_tag() == text_hash).then_some(dict)
}

/// A dictionary of the phrases file, and where it came from.
pub struct Loaded {
    pub dict: UserDict,
    /// Mapped from the cache; built from the file otherwise.
    pub mapped: bool,
}

/// The phrases file at `phrases` as a dictionary on `base`: mapped from the
/// blob of its text in `dir` when there is one, built from it otherwise. The
/// cache holds blobs only of texts that were UTF-8, so a blob of these
/// bytes needs no check of them. `Err` says why there is no dictionary.
pub fn load(phrases: &Path, dir: Option<&Path>, base: Option<&Dict>) -> Result<Loaded, LoadError> {
    let bytes = file::read_bytes(phrases)
        .map_err(LoadError::Unreadable)?
        .ok_or(LoadError::Missing)?;
    let text_hash = UserDict::hash(&bytes);
    if let Some(dict) = dir.and_then(|dir| open_in(dir, text_hash, base)) {
        return Ok(Loaded { dict, mapped: true });
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| LoadError::NotUtf8)?;
    let (dict, _) = crate::build(text, base).map_err(LoadError::Build)?;
    Ok(Loaded {
        dict,
        mapped: false,
    })
}

/// Put `dict`, built on `base` from the text whose hash is its source tag,
/// in `dir` for every application to map — unless a blob of that text is
/// there already — and sweep away every other blob. Creates the folder,
/// readable by sandboxed applications, when need be.
pub fn write_in(dir: &Path, dict: &UserDict, base: Option<&Dict>) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    // Sandboxed applications read what lies here; a failure costs them the
    // shared copy and nothing else.
    let _ = crate::access::grant_folder(dir);
    let text_hash = dict.source_tag();
    let path = path_in(dir, text_hash, base);
    if open_in(dir, text_hash, base).is_none() {
        let mut temp = path.clone().into_os_string();
        temp.push(format!(".{}-{:?}.tmp", std::process::id(), std::thread::current().id()));
        let temp = PathBuf::from(temp);
        let placed = (|| {
            fs::write(&temp, dict.as_bytes())?;
            // A blob that is there but unusable — cut short by a crash, say
            // — goes. No one has it mapped: it would have been refused.
            if path.exists() {
                let _ = fs::remove_file(&path);
            }
            place(&temp, &path)
        })();
        if placed.is_err() {
            let _ = fs::remove_file(&temp);
        }
        match placed {
            // Another application put the same blob there first.
            Err(error) if open_in(dir, text_hash, base).is_some() => drop(error),
            other => other?,
        }
    }
    sweep(dir, &path);
    Ok(())
}

/// Make sure `dir` holds the blob of the phrases file at `phrases` on
/// `base`, building it if need be: what turning a switch on does, so
/// applications map it at once rather than each build its own first. `Err`
/// says why there is no dictionary to share; a blob that cannot be written
/// costs each application a build of its own, and is no error.
pub fn prime(phrases: &Path, dir: &Path, base: Option<&Dict>) -> Result<(), LoadError> {
    let loaded = load(phrases, Some(dir), base)?;
    if !loaded.mapped {
        let _ = write_in(dir, &loaded.dict, base);
    }
    Ok(())
}

/// Rename `temp` to `path`, which must not exist: a name, once there, is
/// never replaced (no `MOVEFILE_REPLACE_EXISTING`).
fn place(temp: &Path, path: &Path) -> io::Result<()> {
    let (from, to) = (wide(temp), wide(path));
    // SAFETY: NUL-terminated paths that outlive the call.
    unsafe { MoveFileExW(PCWSTR(from.as_ptr()), PCWSTR(to.as_ptr()), MOVE_FILE_FLAGS(0)) }
        .map_err(io::Error::from)
}

/// Delete every blob in `dir` but `keep`, and temporary files left behind.
/// One that an application still has mapped goes too: it keeps reading
/// what the file held.
fn sweep(dir: &Path, keep: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path == keep {
            continue;
        }
        let stale = match path.extension().and_then(|extension| extension.to_str()) {
            Some("blob") => true,
            Some("tmp") => entry
                .metadata()
                .and_then(|metadata| metadata.modified())
                .is_ok_and(|modified| {
                    SystemTime::now().duration_since(modified).unwrap_or_default() > STALE_TEMP
                }),
            _ => false,
        };
        if stale {
            let _ = fs::remove_file(&path);
        }
    }
}

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain([0]).collect()
}

/// A blob file mapped for reading. The file stays open — for reading,
/// shared with readers and with deletion but with no writer — until the map
/// is dropped, so the mapped bytes cannot change under the engine.
struct Map {
    file: HANDLE,
    view: MEMORY_MAPPED_VIEW_ADDRESS,
    len: usize,
}

// SAFETY: read-only memory of this process, valid until dropped; reading it
// from any thread is fine.
unsafe impl Send for Map {}
unsafe impl Sync for Map {}

impl Map {
    /// `None` when there is no file, it cannot be opened as described — a
    /// writer has it — or it is empty or larger than any blob.
    fn open(path: &Path) -> Option<Map> {
        let name = wide(path);
        // SAFETY: a NUL-terminated path; every handle is closed on every
        // path out, the file's by the Map once there is one.
        unsafe {
            let file = CreateFileW(
                PCWSTR(name.as_ptr()),
                GENERIC_READ.0,
                FILE_SHARE_READ | FILE_SHARE_DELETE,
                None,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
            .ok()?;
            let mut size = 0i64;
            if GetFileSizeEx(file, &mut size).is_err() || size <= 0 || size > MAX_BLOB {
                let _ = CloseHandle(file);
                return None;
            }
            let Ok(mapping) = CreateFileMappingW(file, None, PAGE_READONLY, 0, 0, PCWSTR::null()) else {
                let _ = CloseHandle(file);
                return None;
            };
            let view = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
            // The view keeps the mapping alive.
            let _ = CloseHandle(mapping);
            if view.Value.is_null() {
                let _ = CloseHandle(file);
                return None;
            }
            Some(Map {
                file,
                view,
                len: size as usize,
            })
        }
    }
}

impl AsRef<[u8]> for Map {
    fn as_ref(&self) -> &[u8] {
        // SAFETY: the view maps `len` bytes until the Map is dropped.
        unsafe { std::slice::from_raw_parts(self.view.Value as *const u8, self.len) }
    }
}

impl Drop for Map {
    fn drop(&mut self) {
        // SAFETY: the view and the handle are this Map's, released once.
        unsafe {
            let _ = UnmapViewOfFile(self.view);
            let _ = CloseHandle(self.file);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh folder under the temp directory, removed on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "jd-userdict-cache-{tag}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = fs::remove_dir_all(&dir);
            Self(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn built(text: &str) -> UserDict {
        crate::build(text, None).unwrap().0
    }

    fn blobs(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn a_written_blob_is_mapped_by_its_texts_hash() {
        let temp = TempDir::new("roundtrip");
        let dir = temp.0.join("nested");
        let text = "键道\tzzzzzz\n";
        let hash = UserDict::hash(text.as_bytes());
        assert!(open_in(&dir, hash, None).is_none(), "no folder yet");

        let dict = built(text);
        write_in(&dir, &dict, None).unwrap();
        let mapped = open_in(&dir, hash, None).expect("mapped");
        assert_eq!(mapped.as_bytes(), dict.as_bytes());
        assert_eq!((mapped.entries(), mapped.source_tag()), (1, hash));
        assert_eq!(blobs(&dir), [format!("{hash:016x}-{:016x}.blob", library(None))]);
        // Another text's hash finds nothing.
        assert!(open_in(&dir, hash ^ 1, None).is_none());
        // Sandboxed applications can read the folder and what is in it.
        assert!(crate::access::folder_is_granted(&dir).unwrap());

        // Written again: the blob there is kept, mapped as it is.
        write_in(&dir, &dict, None).unwrap();
        assert_eq!(blobs(&dir).len(), 1);
        drop(mapped);
    }

    #[test]
    fn each_base_names_and_maps_blobs_of_its_own() {
        let temp = TempDir::new("bases");
        let dir = &temp.0;
        let empty = crate::empty_dict();
        assert_ne!(library(None), library(Some(empty)));
        // "不" on b repeats a built-in word: dropped on the built-in
        // dictionary, a phrase of its own on the empty one.
        let text = "不\tb\n键道\tzzzzzz\n";
        let hash = UserDict::hash(text.as_bytes());
        let on_builtin = built(text);
        let (on_empty, _) = crate::build(text, Some(empty)).unwrap();
        assert_eq!((on_builtin.entries(), on_empty.entries()), (1, 2));

        write_in(dir, &on_builtin, None).unwrap();
        assert!(open_in(dir, hash, Some(empty)).is_none(), "not the other base's");
        // The other base's write sweeps this one away.
        write_in(dir, &on_empty, Some(empty)).unwrap();
        assert!(open_in(dir, hash, None).is_none());
        let mapped = open_in(dir, hash, Some(empty)).expect("mapped");
        assert_eq!(blobs(dir).len(), 1);

        // It types the phrases alone.
        let mut ctx = jd::JdContext::with_dict(empty, Some(mapped.leak())).unwrap();
        ctx.press_key(b'b');
        let listed: Vec<&str> = ctx.candidates(0, 9).iter().map(|c| c.value()).collect();
        assert_eq!(listed, ["不"]);
    }

    #[test]
    fn a_mapped_blob_cannot_be_changed_but_can_be_swept() {
        let temp = TempDir::new("mapped");
        let dir = &temp.0;
        let first = built("键道\tzzzzzz\n");
        write_in(dir, &first, None).unwrap();
        let mapped = open_in(dir, first.source_tag(), None).unwrap();
        let path = path_in(dir, first.source_tag(), None);
        assert!(
            fs::OpenOptions::new().write(true).open(&path).is_err(),
            "no writer while it is mapped"
        );

        // A new text: its blob goes in, the mapped one goes away, and what
        // was mapped still reads.
        let second = built("键道\tzzzzzz\n键道输入法\tzzzzza\n");
        write_in(dir, &second, None).unwrap();
        assert!(!path.exists());
        let second_name = path_in(dir, second.source_tag(), None).file_name().unwrap().to_string_lossy().into_owned();
        assert_eq!(blobs(dir), [second_name]);
        assert_eq!(mapped.as_bytes(), first.as_bytes());
        let mut ctx = jd::JdContext::with_user_dict(mapped.leak()).unwrap();
        for key in *b"zzzzzz " {
            ctx.press_key(key);
        }
        assert_eq!(ctx.commit().unwrap().to_string(), "键道");
    }

    #[test]
    fn a_damaged_or_misnamed_blob_is_refused_and_replaced() {
        let temp = TempDir::new("damaged");
        let dir = &temp.0;
        let dict = built("键道\tzzzzzz\n");
        let path = path_in(dir, dict.source_tag(), None);
        fs::create_dir_all(dir).unwrap();

        fs::write(&path, &dict.as_bytes()[..dict.as_bytes().len() - 4]).unwrap();
        assert!(open_in(dir, dict.source_tag(), None).is_none(), "cut short");
        fs::write(&path, b"").unwrap();
        assert!(open_in(dir, dict.source_tag(), None).is_none(), "empty");
        // Another text's blob under this text's name.
        fs::write(&path, built("别的\tzzzzza\n").as_bytes()).unwrap();
        assert!(open_in(dir, dict.source_tag(), None).is_none(), "another text's");

        write_in(dir, &dict, None).unwrap();
        assert_eq!(open_in(dir, dict.source_tag(), None).unwrap().as_bytes(), dict.as_bytes());
    }

    #[test]
    fn a_sweep_leaves_fresh_temporary_files_and_other_files_alone() {
        let temp = TempDir::new("sweep");
        let dir = &temp.0;
        fs::create_dir_all(dir).unwrap();
        // Another version's blob of the same text, and a stranger.
        let dict = built("键道\tzzzzzz\n");
        let other_version = dir.join(format!("{:016x}-{:016x}.blob", dict.source_tag(), library(None) ^ 1));
        fs::write(&other_version, b"x").unwrap();
        fs::write(dir.join("readme.txt"), b"x").unwrap();
        // A write in progress, by another application.
        let in_progress = dir.join("0000000000000000-0000000000000000.blob.1-ThreadId(1).tmp");
        fs::write(&in_progress, b"x").unwrap();

        write_in(dir, &dict, None).unwrap();
        assert!(!other_version.exists());
        assert!(dir.join("readme.txt").exists());
        assert!(in_progress.exists());
    }

    #[test]
    fn a_load_maps_the_cached_blob_or_builds_and_says_why_there_is_none() {
        let temp = TempDir::new("load");
        let phrases = temp.0.join(file::FILE_NAME);
        let dir = temp.0.join(DIR_NAME);
        assert!(matches!(load(&phrases, Some(&dir), None), Err(LoadError::Missing)));

        fs::create_dir_all(&temp.0).unwrap();
        fs::write(&phrases, "键道\tzzzzzz\n").unwrap();
        let loaded = load(&phrases, Some(&dir), None).unwrap();
        assert!(!loaded.mapped);
        write_in(&dir, &loaded.dict, None).unwrap();
        assert!(load(&phrases, Some(&dir), None).unwrap().mapped);
        assert!(!load(&phrases, None, None).unwrap().mapped, "no cache to look in");

        fs::write(&phrases, [0xC4, 0xE3, 0x09, 0x61, 0x0A]).unwrap();
        assert!(matches!(load(&phrases, Some(&dir), None), Err(LoadError::NotUtf8)));
    }

    #[test]
    fn priming_builds_the_phrases_files_blob_once() {
        let temp = TempDir::new("prime");
        let phrases = temp.0.join(file::FILE_NAME);
        let dir = temp.0.join(DIR_NAME);
        assert!(matches!(prime(&phrases, &dir, None), Err(LoadError::Missing)));
        assert!(!dir.exists(), "no file, nothing to prime");

        // A BOM is no part of the text the blob is named for.
        fs::create_dir_all(&temp.0).unwrap();
        fs::write(&phrases, "\u{feff}键道\tzzzzzz\n").unwrap();
        prime(&phrases, &dir, None).unwrap();
        let hash = UserDict::hash("键道\tzzzzzz\n".as_bytes());
        assert_eq!(open_in(&dir, hash, None).unwrap().entries(), 1);
        let written = fs::metadata(path_in(&dir, hash, None)).unwrap().modified().unwrap();
        prime(&phrases, &dir, None).unwrap();
        assert_eq!(fs::metadata(path_in(&dir, hash, None)).unwrap().modified().unwrap(), written);

        // On the empty dictionary: a blob of its own, in place of that one.
        let empty = Some(crate::empty_dict());
        prime(&phrases, &dir, empty).unwrap();
        assert!(open_in(&dir, hash, empty).is_some());
        assert_eq!(blobs(&dir).len(), 1);

        // Not UTF-8: nothing to share.
        fs::write(&phrases, [0xC4, 0xE3, 0x09, 0x61, 0x0A]).unwrap();
        assert!(matches!(prime(&phrases, &dir, None), Err(LoadError::NotUtf8)));
        assert_eq!(blobs(&dir).len(), 1);
    }

    #[test]
    fn the_library_is_named_by_its_empty_blob() {
        let (empty, _) = UserDict::build("", 0).unwrap();
        assert_eq!(library(None), UserDict::hash(empty.as_bytes()));
        assert_ne!(library(None), 0);
        let dir = dir().expect("the shell resolves the local AppData folder");
        assert!(dir.ends_with(Path::new(file::DIR_NAME).join(DIR_NAME)));
    }
}
