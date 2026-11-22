//! The CLI's user dictionary: a `value<TAB>keys` text file compiled into a
//! libjd blob, cached in the OS temp directory and memory-mapped on later
//! runs so the engine reads it in place.
//!
//! The cache file is named after the text file's absolute path and the blob
//! is stamped with the file's modification time (its source tag). On each
//! run the cache is mapped and checked first: a matching tag means the
//! mapping becomes the engine's dictionary, with no copy; anything else — no
//! cache, a changed file, a blob from another libjd, a corrupt file —
//! rebuilds from the text and rewrites the cache. The text file is mapped
//! too; the builder only reads it.

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use memmap2::Mmap;

/// Where this run's dictionary came from.
pub enum Source {
    Cache,
    Rebuilt(&'static str),
}

pub struct Loaded {
    /// Leaked on purpose: the engine reads it for the rest of the process.
    pub dict: &'static jd::UserDict,
    pub source: Source,
    /// The engine's notes — skipped lines, dropped duplicates and phrases on
    /// shared codes, each with the line itself — known only when the
    /// dictionary was rebuilt from the text.
    pub notes: Vec<(jd::UserDictNote, String)>,
    pub invalid: u32,
    pub dropped: u32,
    pub shared: u32,
}

impl Loaded {
    /// One line for the user: where the dictionary came from and what it holds.
    pub fn summary(&self) -> String {
        match self.source {
            Source::Cache => format!("{} phrases (cached)", self.dict.entries()),
            Source::Rebuilt(reason) => format!(
                "{} phrases, {} bad lines skipped, {} duplicates dropped, {} on shared codes (rebuilt: {reason})",
                self.dict.entries(),
                self.invalid,
                self.dropped,
                self.shared
            ),
        }
    }
}

/// FNV-1a, 64-bit: a stable hash for naming cache files after the
/// dictionary's absolute path.
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// `<OS temp dir>/jd-cli/<hash of the absolute path>.jdud`.
fn cache_path(canonical: &Path) -> PathBuf {
    let name = format!(
        "{:016x}.jdud",
        fnv1a64(canonical.as_os_str().as_encoded_bytes())
    );
    env::temp_dir().join("jd-cli").join(name)
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
/// phrases or fail the build; for the cache, the engine validates every byte
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

/// The phrases file's text, minus a leading byte-order mark: libjd reads
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
/// sees a half-written blob.
fn write_cache(cache: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = cache.parent().expect("the cache path has a directory");
    fs::create_dir_all(dir)?;
    let tmp = cache.with_extension(format!("tmp{}", std::process::id()));
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, cache)
}

/// Load the dictionary for `path`, through the cache. Errors are messages
/// ready to print after a `user dict:` prefix.
pub fn load(path: &str) -> Result<Loaded, String> {
    let canonical = fs::canonicalize(path).map_err(|e| format!("{path}: {e}"))?;
    let meta = fs::metadata(&canonical).map_err(|e| format!("{path}: {e}"))?;
    let tag = source_tag(&meta);
    let cache = cache_path(&canonical);

    // Peek before committing: the mapping is only kept (leaked) once it is
    // known to be the dictionary for this run. Dropping it on every other
    // path lets the rebuild below replace the file on platforms that refuse
    // to rename over a mapped file.
    let reason = match map_file(&cache) {
        Ok(Some(map)) => match jd::UserDict::check(&map) {
            Ok(info) if tag != 0 && info.source_tag == tag => {
                let blob: &'static [u8] = Box::leak(Box::new(map));
                let dict = jd::UserDict::from_static_blob(blob)
                    .map_err(|e| format!("{}: {e}", cache.display()))?;
                return Ok(Loaded {
                    dict: dict.leak(),
                    source: Source::Cache,
                    notes: Vec::new(),
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
    let (dict, report) = jd::UserDict::build(text, tag).map_err(|e| format!("{path}: {e}"))?;

    // Best effort: a cache that cannot be written only costs a rebuild next
    // time.
    if let Err(e) = write_cache(&cache, dict.as_bytes()) {
        eprintln!(
            "jd-cli: user dict: could not write the cache at {}: {e}",
            cache.display()
        );
    }

    let notes = with_lines(text, &report.notes);

    Ok(Loaded {
        dict: dict.leak(),
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

    #[test]
    fn fnv1a64_matches_the_reference_vectors() {
        assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
    }

    #[test]
    fn cache_path_is_stable_and_lives_under_the_temp_dir() {
        let a = cache_path(Path::new("/some/where/phrases.txt"));
        assert_eq!(a, cache_path(Path::new("/some/where/phrases.txt")));
        assert_ne!(a, cache_path(Path::new("/some/where/other.txt")));
        assert!(a.starts_with(env::temp_dir().join("jd-cli")));
        assert_eq!(a.extension().and_then(|e| e.to_str()), Some("jdud"));
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
        let dir = env::temp_dir().join(format!("jd-cli-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let empty = dir.join("empty.txt");
        fs::write(&empty, b"").unwrap();
        assert!(map_file(&empty).unwrap().is_none());
        let some = dir.join("some.txt");
        fs::write(&some, b"x").unwrap();
        assert_eq!(&map_file(&some).unwrap().unwrap()[..], b"x");
        fs::remove_dir_all(&dir).unwrap();
    }
}
