//! The CLI's dictionaries, each a `value<TAB>keys` text file compiled into
//! a libjd blob: `--dict`, typed from in place of the built-in dictionary
//! (`jd_dict_build`), and `--user-dict`, whose phrases go on top of
//! whichever dictionary that is (`jd_user_dict_build`). Each blob is cached
//! in the OS temp directory and memory-mapped on later runs, so the engine
//! reads it in place.
//!
//! A cache file is named after the text file's absolute path — a user
//! dictionary's after the dictionary's too, since it is built against that
//! one — and the blob is stamped with the file's modification time (its
//! source tag). On each run the cache is mapped and checked first: a
//! matching tag means the mapping becomes the engine's dictionary, with no
//! copy; anything else — no cache, a changed file, a blob from another
//! libjd or for another dictionary, a corrupt file — rebuilds from the text
//! and rewrites the cache. The text file is mapped too; the builder only
//! reads it.

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use memmap2::Mmap;

/// Where a dictionary came from this run.
pub enum Source {
    Cache,
    Rebuilt(&'static str),
}

/// One dictionary file, compiled.
pub struct Loaded<T: 'static> {
    /// Leaked on purpose: the engine reads it for the rest of the process.
    pub dict: &'static T,
    /// The text file's absolute path.
    pub path: PathBuf,
    pub source: Source,
    /// The engine's notes — skipped lines, dropped repeats and, for a user
    /// dictionary, phrases on shared codes — each with the line itself;
    /// known only when the dictionary was rebuilt from the text.
    pub notes: Vec<(jd::UserDictNote, String)>,
    pub entries: u32,
    pub invalid: u32,
    pub dropped: u32,
    pub shared: u32,
}

impl<T> Loaded<T> {
    fn describe(&self, noun: &str, shared: bool) -> String {
        match self.source {
            Source::Cache => format!("{} {noun} (cached)", self.entries),
            Source::Rebuilt(reason) => {
                let mut line = format!(
                    "{} {noun}, {} bad lines skipped, {} duplicates dropped",
                    self.entries, self.invalid, self.dropped
                );
                if shared {
                    line += &format!(", {} on shared codes", self.shared);
                }
                line + &format!(" (rebuilt: {reason})")
            }
        }
    }
}

impl Loaded<jd::Dict> {
    /// One line for the user: where the dictionary came from and what it holds.
    pub fn summary(&self) -> String {
        self.describe("entries", false)
    }
}

impl Loaded<jd::UserDict> {
    /// One line for the user: where the dictionary came from and what it holds.
    pub fn summary(&self) -> String {
        self.describe("phrases", true)
    }
}

/// What the engine types from: `--dict` in place of the built-in
/// dictionary, when given, and `--user-dict` on top of it.
#[derive(Default)]
pub struct Dicts {
    pub dict: Option<Loaded<jd::Dict>>,
    pub user: Option<Loaded<jd::UserDict>>,
}

impl Dicts {
    /// Load the files given, the user dictionary on the dictionary. Errors
    /// are messages ready to print after a `jd-cli: ` prefix.
    pub fn load(dict: Option<&str>, user_dict: Option<&str>) -> Result<Self, String> {
        let dict = dict
            .map(|path| load::<jd::Dict>(path, &()).map_err(|e| format!("dict: {e}")))
            .transpose()?;
        let base = dict.as_ref().map(|d| (d.dict, d.path.clone()));
        let user = user_dict
            .map(|path| load::<jd::UserDict>(path, &base).map_err(|e| format!("user dict: {e}")))
            .transpose()?;
        Ok(Self { dict, user })
    }

    /// A context over them.
    pub fn context(&self) -> Result<jd::JdContext, jd::InitError> {
        let user = self.user.as_ref().map(|u| u.dict);
        match (&self.dict, user) {
            (Some(dict), user) => jd::JdContext::with_dict(dict.dict, user),
            (None, Some(user)) => jd::JdContext::with_user_dict(user),
            (None, None) => jd::JdContext::new(),
        }
    }
}

/// A kind of dictionary blob, as this module caches it.
trait Blob: Sized + 'static {
    /// The cache file's extension.
    const EXT: &'static str;
    /// What the blob is built on, and the path that names it in the cache.
    type Base;
    fn base_path(base: &Self::Base) -> Option<&Path>;
    /// Wrap a mapped cache file, validated exactly as `jd_init` would.
    ///
    /// # Safety
    ///
    /// As for `jd::Dict::from_mapped_blob`.
    unsafe fn from_map(base: &Self::Base, map: Mmap) -> Result<Self, jd::UserDictError>;
    fn build(
        base: &Self::Base,
        text: &str,
        tag: u64,
    ) -> Result<(Self, jd::UserDictReport), jd::UserDictError>;
    fn bytes(&self) -> &[u8];
    fn entries(&self) -> u32;
    fn source_tag(&self) -> u64;
}

impl Blob for jd::Dict {
    const EXT: &'static str = "jddt";
    type Base = ();
    fn base_path(_: &()) -> Option<&Path> {
        None
    }
    unsafe fn from_map(_: &(), map: Mmap) -> Result<Self, jd::UserDictError> {
        // SAFETY: the caller's promise, passed on.
        unsafe { jd::Dict::from_mapped_blob(map) }
    }
    fn build(
        _: &(),
        text: &str,
        tag: u64,
    ) -> Result<(Self, jd::UserDictReport), jd::UserDictError> {
        jd::Dict::build(text, tag)
    }
    fn bytes(&self) -> &[u8] {
        self.as_bytes()
    }
    fn entries(&self) -> u32 {
        jd::Dict::entries(self)
    }
    fn source_tag(&self) -> u64 {
        jd::Dict::source_tag(self)
    }
}

impl Blob for jd::UserDict {
    const EXT: &'static str = "jdud";
    /// `--dict` and its path, or the built-in dictionary.
    type Base = Option<(&'static jd::Dict, PathBuf)>;
    fn base_path(base: &Self::Base) -> Option<&Path> {
        base.as_ref().map(|(_, path)| path.as_path())
    }
    unsafe fn from_map(base: &Self::Base, map: Mmap) -> Result<Self, jd::UserDictError> {
        // SAFETY: the caller's promise, passed on.
        unsafe {
            match base {
                Some((dict, _)) => jd::UserDict::from_mapped_blob_on(dict, map),
                None => jd::UserDict::from_mapped_blob(map),
            }
        }
    }
    fn build(
        base: &Self::Base,
        text: &str,
        tag: u64,
    ) -> Result<(Self, jd::UserDictReport), jd::UserDictError> {
        match base {
            Some((dict, _)) => jd::UserDict::build_on(dict, text, tag),
            None => jd::UserDict::build(text, tag),
        }
    }
    fn bytes(&self) -> &[u8] {
        self.as_bytes()
    }
    fn entries(&self) -> u32 {
        jd::UserDict::entries(self)
    }
    fn source_tag(&self) -> u64 {
        jd::UserDict::source_tag(self)
    }
}

/// FNV-1a, 64-bit: a stable hash for naming cache files after paths.
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// `<OS temp dir>/jd-cli/<hash>.<ext>`, the hash of the absolute path and,
/// for a blob built on a dictionary file, that file's absolute path too: a
/// user dictionary run with and without `--dict` keeps a cache for each.
fn cache_path(canonical: &Path, base: Option<&Path>, ext: &str) -> PathBuf {
    let mut key = canonical.as_os_str().as_encoded_bytes().to_vec();
    if let Some(base) = base {
        key.push(0);
        key.extend_from_slice(base.as_os_str().as_encoded_bytes());
    }
    env::temp_dir()
        .join("jd-cli")
        .join(format!("{:016x}.{ext}", fnv1a64(&key)))
}

/// The file's modification time in nanoseconds since the Unix epoch, used as
/// the blob's source tag. 0 when the filesystem reports none, which also
/// disables the cache: a tag of 0 never matches.
fn source_tag(meta: &fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

/// Map a file read-only. `None` for an empty file, which cannot be mapped.
///
/// The mapping assumes the file does not change while mapped (the reason
/// `Mmap::map` is unsafe). For the text that would at worst build wrong
/// entries or fail the build; a cache file is only ever replaced, never
/// rewritten (`write_cache`), and the engine validates every byte of it
/// before trusting it.
fn map_file(path: &Path) -> io::Result<Option<Mmap>> {
    let file = fs::File::open(path)?;
    if file.metadata()?.len() == 0 {
        return Ok(None);
    }
    // SAFETY: see above; the mapping is read-only.
    let map = unsafe { Mmap::map(&file)? };
    Ok(Some(map))
}

/// A dictionary file's text, minus a leading byte-order mark: libjd reads
/// the text as given, so a BOM would become part of line 1 (see `jd.h`).
fn decode(bytes: &[u8]) -> Result<&str, std::str::Utf8Error> {
    let text = std::str::from_utf8(bytes)?;
    Ok(text.strip_prefix('\u{feff}').unwrap_or(text))
}

/// Each note with the line it is about. Line numbers are libjd's — lines
/// split on `\n`, counted from 1 — and the notes come ascending by line, so
/// one pass over the text finds them all: looking each one up from the start
/// would make a file of hundreds of thousands of lines take minutes.
fn with_lines(text: &str, notes: &[jd::UserDictNote]) -> Vec<(jd::UserDictNote, String)> {
    let mut lines = text.split('\n');
    let mut read = 0;
    let mut current = "";
    notes
        .iter()
        .map(|&note| {
            while read < note.line as usize {
                current = lines.next().unwrap_or("");
                read += 1;
            }
            (note, current.trim_end_matches('\r').to_string())
        })
        .collect()
}

/// Write via a sibling temp file and a rename, so a concurrent reader never
/// sees a half-written blob, and a mapped one never changes under it.
fn write_cache(cache: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = cache.parent().expect("the cache path has a directory");
    fs::create_dir_all(dir)?;
    let tmp = cache.with_extension(format!("tmp{}", std::process::id()));
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, cache)
}

/// Load the dictionary file at `path`, on `base`, through the cache. Errors
/// are messages ready to print after a `dict: ` or `user dict: ` prefix.
fn load<T: Blob>(path: &str, base: &T::Base) -> Result<Loaded<T>, String> {
    let canonical = fs::canonicalize(path).map_err(|e| format!("{path}: {e}"))?;
    let meta = fs::metadata(&canonical).map_err(|e| format!("{path}: {e}"))?;
    let tag = source_tag(&meta);
    let cache = cache_path(&canonical, T::base_path(base), T::EXT);

    // The mapping is kept (leaked, inside the dictionary) only once it is
    // known to be the dictionary for this run. Dropping it on every other
    // path lets the rebuild below replace the file on platforms that refuse
    // to rename over a mapped file.
    let reason = match map_file(&cache) {
        // SAFETY: the cache is replaced, never rewritten (see `map_file`).
        Ok(Some(map)) => match unsafe { T::from_map(base, map) } {
            Ok(dict) if tag != 0 && dict.source_tag() == tag => {
                let entries = dict.entries();
                return Ok(Loaded {
                    dict: Box::leak(Box::new(dict)),
                    path: canonical,
                    source: Source::Cache,
                    notes: Vec::new(),
                    entries,
                    invalid: 0,
                    dropped: 0,
                    shared: 0,
                });
            }
            Ok(_) => "source changed",
            Err(e) if e.status == jd::UserDictStatus::Stale => "cache stale",
            Err(_) => "cache corrupt",
        },
        Ok(None) => "cache corrupt",
        Err(_) => "no cache",
    };

    let text_map = map_file(&canonical).map_err(|e| format!("{path}: {e}"))?;
    let text: &str = match &text_map {
        Some(map) => decode(map).map_err(|_| format!("{path}: not valid UTF-8"))?,
        None => "",
    };
    let (dict, report) = T::build(base, text, tag).map_err(|e| format!("{path}: {e}"))?;

    // Best effort: a cache that cannot be written only costs a rebuild next
    // time.
    if let Err(e) = write_cache(&cache, dict.bytes()) {
        eprintln!(
            "jd-cli: could not write the cache for {path} at {}: {e}",
            cache.display()
        );
    }

    let notes = with_lines(text, &report.notes);
    Ok(Loaded {
        entries: dict.entries(),
        dict: Box::leak(Box::new(dict)),
        path: canonical,
        source: Source::Rebuilt(reason),
        notes,
        invalid: report.invalid,
        dropped: report.dropped,
        shared: report.shared,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::time::{Duration, SystemTime};

    /// A folder of its own under the temp dir, removed with the caches its
    /// files left when the test ends.
    struct Scratch {
        dir: PathBuf,
        caches: Vec<PathBuf>,
    }

    impl Scratch {
        fn new(name: &str) -> Self {
            let dir = env::temp_dir().join(format!("jd-cli-test-{name}-{}", std::process::id()));
            fs::create_dir_all(&dir).unwrap();
            Self {
                dir: fs::canonicalize(dir).unwrap(),
                caches: Vec::new(),
            }
        }

        /// Write `text` at `name`, stamped `secs` after the epoch: a run that
        /// rewrites a file within the filesystem's clock tick still changes
        /// its tag.
        fn write(&mut self, name: &str, text: &str, secs: u64) -> String {
            let path = self.dir.join(name);
            fs::write(&path, text).unwrap();
            let file = fs::File::options().write(true).open(&path).unwrap();
            file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(secs))
                .unwrap();
            path.to_str().unwrap().to_string()
        }

        fn track<T>(&mut self, loaded: &Loaded<T>, base: Option<&Path>, ext: &str) {
            self.caches.push(cache_path(&loaded.path, base, ext));
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            for cache in &self.caches {
                let _ = fs::remove_file(cache);
            }
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    fn reason<T>(loaded: &Loaded<T>) -> &'static str {
        match loaded.source {
            Source::Cache => "cache",
            Source::Rebuilt(reason) => reason,
        }
    }

    #[test]
    fn fnv1a64_matches_the_reference_vectors() {
        assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
    }

    #[test]
    fn cache_path_is_stable_and_lives_under_the_temp_dir() {
        let phrases = Path::new("/some/where/phrases.txt");
        let a = cache_path(phrases, None, "jdud");
        assert_eq!(a, cache_path(phrases, None, "jdud"));
        assert_ne!(
            a,
            cache_path(Path::new("/some/where/other.txt"), None, "jdud")
        );
        assert!(a.starts_with(env::temp_dir().join("jd-cli")));
        assert_eq!(a.extension().and_then(|e| e.to_str()), Some("jdud"));
        // On a dictionary file, a cache of its own, one for each such file.
        let on = cache_path(phrases, Some(Path::new("/some/where/dict.txt")), "jdud");
        assert_ne!(on, a);
        assert_ne!(
            on,
            cache_path(phrases, Some(Path::new("/some/where/other.txt")), "jdud")
        );
    }

    #[test]
    fn decode_drops_a_leading_byte_order_mark_only() {
        assert_eq!(decode("\u{feff}甲\ta\n".as_bytes()).unwrap(), "甲\ta\n");
        assert_eq!(decode("甲\ta\n".as_bytes()).unwrap(), "甲\ta\n");
        assert_eq!(
            decode("甲\ta\n\u{feff}".as_bytes()).unwrap(),
            "甲\ta\n\u{feff}"
        );
        assert!(decode(b"\xff\ta\n").is_err());
    }

    #[test]
    fn notes_are_paired_with_their_lines_in_one_pass() {
        // A skipped line (with its CR), a repeat, bad keys, and whatever
        // the built-in words make of the rest: each note gets its own line,
        // as looking it up from the start would.
        let text = "# 键道\n甲\ta\nno tab\r\n\n甲\ta\n乙\tA";
        let (_, report) = jd::UserDict::build(text, 0).unwrap();
        let paired = with_lines(text, &report.notes);
        assert!(paired.len() >= 3);
        for (note, line) in &paired {
            let looked_up = text.split('\n').nth(note.line as usize - 1).unwrap();
            assert_eq!(line, looked_up.trim_end_matches('\r'));
        }
        assert!(
            paired
                .iter()
                .any(|(note, line)| note.line == 3 && line == "no tab")
        );
        // Lines the text does not have read as empty, not as a panic.
        let past = jd::UserDictNote {
            line: 9,
            ..report.notes[0]
        };
        assert_eq!(with_lines(text, &[past])[0].1, "");
    }

    #[test]
    fn an_empty_file_maps_to_none() {
        let mut scratch = Scratch::new("map");
        let empty = scratch.write("empty.txt", "", 1);
        assert!(map_file(Path::new(&empty)).unwrap().is_none());
        let some = scratch.write("some.txt", "x", 1);
        assert_eq!(&map_file(Path::new(&some)).unwrap().unwrap()[..], b"x");
    }

    #[test]
    fn a_dictionary_file_is_built_once_then_read_from_its_cache() {
        let mut scratch = Scratch::new("dict");
        let path = scratch.write("dict.txt", "甲\ta\n乙\ta\nno tab\n甲\ta\n", 1);

        let first = Dicts::load(Some(&path), None).unwrap();
        let dict = first.dict.as_ref().unwrap();
        scratch.track(dict, None, "jddt");
        assert_eq!(reason(dict), "no cache");
        assert_eq!((dict.entries, dict.invalid, dict.dropped), (2, 1, 1));
        let lines: Vec<&str> = dict.notes.iter().map(|(_, line)| line.as_str()).collect();
        assert_eq!(lines, ["no tab", "甲\ta"]);
        assert!(
            dict.summary()
                .contains("2 entries, 1 bad lines skipped, 1 duplicates dropped")
        );

        // The built-in dictionary is out: only these two words type.
        let mut ctx = first.context().unwrap();
        ctx.press_key(b'a');
        let values: Vec<&str> = ctx.candidates(0, 8).iter().map(|c| c.value()).collect();
        assert_eq!(values, ["甲", "乙"]);
        assert!(ctx.lookup_codes("的").is_empty());

        let again = Dicts::load(Some(&path), None).unwrap();
        let dict = again.dict.as_ref().unwrap();
        assert_eq!(reason(dict), "cache");
        assert_eq!(dict.entries, 2);
        assert!(dict.summary().ends_with("2 entries (cached)"));

        scratch.write("dict.txt", "丙\tb\n", 2);
        let changed = Dicts::load(Some(&path), None).unwrap();
        assert_eq!(reason(changed.dict.as_ref().unwrap()), "source changed");
        assert_eq!(changed.dict.as_ref().unwrap().entries, 1);
    }

    #[test]
    fn a_user_dictionary_sits_on_the_dictionary_file() {
        let mut scratch = Scratch::new("user");
        let dict_path = scratch.write("dict.txt", "甲\ta\n", 1);
        let user_path = scratch.write("phrases.txt", "乙\ta\n甲\ta\n", 1);

        let dicts = Dicts::load(Some(&dict_path), Some(&user_path)).unwrap();
        let dict = dicts.dict.as_ref().unwrap();
        let user = dicts.user.as_ref().unwrap();
        scratch.track(dict, None, "jddt");
        scratch.track(user, Some(&dict.path), "jdud");
        assert_eq!(
            (reason(user), user.entries, user.dropped, user.shared),
            ("no cache", 1, 1, 1)
        );
        assert_eq!(
            user.notes[0].0.to_string(),
            "line 1: shares its code with 1 dictionary word"
        );
        assert_eq!(
            user.notes[1].0.to_string(),
            "line 2: dropped, repeats a dictionary word"
        );

        // The phrase comes first on its code, ahead of the dictionary's word.
        let mut ctx = dicts.context().unwrap();
        ctx.press_key(b'a');
        let values: Vec<&str> = ctx.candidates(0, 8).iter().map(|c| c.value()).collect();
        assert_eq!(values, ["乙", "甲"]);

        // Its cache is for this dictionary: on the built-in one the same
        // file has a cache of its own, and this one is still there after.
        let builtin = Dicts::load(None, Some(&user_path)).unwrap();
        let on_builtin = builtin.user.as_ref().unwrap();
        scratch.track(on_builtin, None, "jdud");
        assert_eq!(reason(on_builtin), "no cache");
        let again = Dicts::load(Some(&dict_path), Some(&user_path)).unwrap();
        assert_eq!(reason(again.user.as_ref().unwrap()), "cache");

        // A changed dictionary leaves the user dictionary's cache stale.
        scratch.write("dict.txt", "甲\ta\n丙\tb\n", 2);
        let changed = Dicts::load(Some(&dict_path), Some(&user_path)).unwrap();
        assert_eq!(reason(changed.user.as_ref().unwrap()), "cache stale");
    }

    #[test]
    fn an_empty_dictionary_file_leaves_the_user_dictionary_alone() {
        let mut scratch = Scratch::new("empty");
        let dict_path = scratch.write("empty.txt", "", 1);
        let user_path = scratch.write("phrases.txt", "测试\td\n", 1);
        let dicts = Dicts::load(Some(&dict_path), Some(&user_path)).unwrap();
        scratch.track(dicts.dict.as_ref().unwrap(), None, "jddt");
        scratch.track(
            dicts.user.as_ref().unwrap(),
            Some(&dicts.dict.as_ref().unwrap().path),
            "jdud",
        );
        assert_eq!(dicts.dict.as_ref().unwrap().entries, 0);
        let mut ctx = dicts.context().unwrap();
        ctx.press_key(b'd');
        let values: Vec<&str> = ctx.candidates(0, 8).iter().map(|c| c.value()).collect();
        assert_eq!(values, ["测试"]);
    }

    #[test]
    fn a_missing_or_unreadable_file_is_an_error_naming_it() {
        let scratch = Scratch::new("missing");
        let missing = scratch.dir.join("nope.txt");
        let missing = missing.to_str().unwrap();
        let error = Dicts::load(Some(missing), None).err().unwrap();
        assert!(error.starts_with(&format!("dict: {missing}: ")), "{error}");
        let error = Dicts::load(None, Some(missing)).err().unwrap();
        assert!(
            error.starts_with(&format!("user dict: {missing}: ")),
            "{error}"
        );

        let bad = scratch.dir.join("bad.txt");
        fs::write(&bad, b"\xff\ta\n").unwrap();
        let error = Dicts::load(Some(bad.to_str().unwrap()), None)
            .err()
            .unwrap();
        assert!(error.ends_with("not valid UTF-8"), "{error}");
    }

    /// core/tables joined, as the build joins them for the embedded
    /// dictionary: every file in name order, each ending in a line break.
    fn tables_text() -> String {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../core/tables");
        let mut paths: Vec<PathBuf> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "txt"))
            .collect();
        paths.sort();
        let mut text = String::new();
        for path in paths {
            text += &fs::read_to_string(path).unwrap();
            if !text.ends_with('\n') {
                text.push('\n');
            }
        }
        text
    }

    #[test]
    fn the_tables_built_by_jd_dict_build_type_as_the_built_in_dictionary() {
        let text = tables_text();
        let (dict, report) = jd::Dict::build(&text, 0).unwrap();
        assert!(report.notes.is_empty(), "{:?}", report.notes.first());
        assert_eq!(dict.entries(), jd::Dict::builtin_entries());

        let dict = dict.leak();
        let mine = jd::JdContext::with_dict(dict, None).unwrap();
        let builtin = jd::JdContext::new().unwrap();
        // Every code of a sample of the words — which candidate it is on
        // each one included — and the candidates of each such code.
        let codes = |ctx: &jd::JdContext, value: &str| -> Vec<(String, u32)> {
            ctx.lookup_codes(value)
                .iter()
                .map(|code| (code.keys().to_string(), code.index()))
                .collect()
        };
        let mut checked = 0;
        for line in text.lines().step_by(97) {
            let Some((value, _)) = line.split_once('\t') else {
                continue;
            };
            if value.starts_with('#') {
                continue;
            }
            assert_eq!(codes(&mine, value), codes(&builtin, value), "{value}");
            checked += 1;
        }
        assert!(checked > 1000, "{checked}");

        let typed = |ctx: &mut jd::JdContext, keys: &str| -> Vec<String> {
            ctx.reset();
            keys.bytes().for_each(|key| ctx.press_key(key));
            ctx.candidates(0, 64)
                .iter()
                .map(|c| c.value().to_string())
                .collect()
        };
        let (mut mine, mut builtin) = (mine, builtin);
        for keys in ["d", "o", "jmdzi", "deuiua", ";", ";;", "a", "zz"] {
            assert_eq!(typed(&mut mine, keys), typed(&mut builtin, keys), "{keys}");
        }
    }
}
