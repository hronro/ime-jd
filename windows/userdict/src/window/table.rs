//! The phrase list behind the window: the file's phrases as rows, in file
//! order, each with the engine's verdict, the search filter over them, and
//! the operations the window offers. Every operation writes the whole file
//! at once, so the list on screen is always what the IME reads. Nothing here
//! judges a phrase: libjd's notes on the build of what was written are the
//! verdicts (problem.rs). No Win32 here, so the operations are tested
//! against a temporary file.

use std::io;
use std::ops::Range;
use std::path::PathBuf;

use jd::UserDict;
use jd_userdict::{Entry, file};

use super::problem::Problem;
use super::store::Store;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Column {
    Value,
    Keys,
    Status,
}

#[derive(Clone, Debug)]
pub struct Row {
    pub entry: Entry,
    /// The row's 1-based line in the file; `None` after a save failed,
    /// until one succeeds.
    pub file_line: Option<u32>,
    pub problem: Option<Problem>,
}

/// What 移除重复词条 has to say, apart from how it says it: the rows libjd
/// drops as duplicates and the rows whose code is already taken — both
/// flagged in the list already — with the skipped rows counted; or that
/// nothing can be done, because the file could not be loaded at all and so
/// there are no notes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DuplicateCheck {
    Unavailable {
        reason: String,
    },
    Clean {
        invalid: usize,
    },
    Found {
        duplicates: Vec<usize>,
        shared: Vec<usize>,
        invalid: usize,
    },
}

pub struct Table {
    store: Store,
    rows: Vec<Row>,
    /// The rows on screen, as indices into `rows`: all of them, or the
    /// search hits.
    shown: Vec<usize>,
    filter: String,
    /// What the last save wrote, or the text last read, so a change on
    /// disk that reads back identical — our own write — reloads nothing.
    last_known_text: Option<String>,
}

impl Table {
    /// The list over the file at `path`, read now.
    pub fn open(path: PathBuf) -> Self {
        let mut store = Store::new(path);
        let text = store.reload();
        let mut table = Self {
            store,
            rows: Vec::new(),
            shown: Vec::new(),
            filter: String::new(),
            last_known_text: None,
        };
        table.load_rows(text);
        table
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    pub fn entries(&self) -> Vec<Entry> {
        self.rows.iter().map(|row| row.entry.clone()).collect()
    }

    pub fn shown(&self) -> &[usize] {
        &self.shown
    }

    pub fn filter(&self) -> &str {
        &self.filter
    }

    pub fn is_filtering(&self) -> bool {
        !self.filter.is_empty()
    }

    /// Narrow the shown rows to those whose phrase or code contains
    /// `filter`, ignoring case; an empty filter shows them all.
    pub fn set_filter(&mut self, filter: &str) {
        self.filter = filter.trim().to_owned();
        self.refresh_shown();
    }

    /// What a cell shows.
    pub fn cell_text(&self, index: usize, column: Column) -> String {
        let row = &self.rows[index];
        match column {
            Column::Value => row.entry.value.clone(),
            Column::Keys => row.entry.keys.clone(),
            Column::Status => row.problem.map(|p| p.text()).unwrap_or_default(),
        }
    }

    /// The file changed on disk. A change that reads back as what the
    /// window last wrote or read — its own save — only refreshes the
    /// verdicts; anything else, a text editor's save most likely, reloads
    /// the rows. Returns whether it did.
    pub fn file_changed(&mut self) -> bool {
        let text = self.store.reload();
        if text != self.last_known_text {
            self.load_rows(text);
            true
        } else {
            self.recompute_problems();
            false
        }
    }

    fn load_rows(&mut self, text: Option<String>) {
        self.rows = file::parse(text.as_deref().unwrap_or(""))
            .into_iter()
            .map(|row| Row {
                entry: row.entry,
                file_line: Some(row.line),
                problem: None,
            })
            .collect();
        self.last_known_text = text;
        self.recompute_problems();
        self.refresh_shown();
    }

    /// Write every row as it is, in list order, and re-derive each row's
    /// line and verdict. On failure the file is as it was, so no row can
    /// claim a line in it until the next save.
    fn save(&mut self) -> io::Result<()> {
        for (index, row) in self.rows.iter_mut().enumerate() {
            row.file_line = Some(file::line_of_entry(index));
        }
        let result = self.store.save(&self.entries());
        match &result {
            Ok(text) => self.last_known_text = Some(text.clone()),
            Err(_) => self.rows.iter_mut().for_each(|row| row.file_line = None),
        }
        self.recompute_problems();
        result.map(|_| ())
    }

    /// libjd's notes about the file as last read or written, mapped onto
    /// rows by line: why a skipped row does not parse, what a dropped row
    /// repeats, and whose code a kept row shares.
    fn recompute_problems(&mut self) {
        let lines: Vec<Option<u32>> = self.rows.iter().map(|row| row.file_line).collect();
        let report = match self.store.last_error() {
            None => self.store.report(),
            Some(_) => None,
        };
        for (row, problem) in self.rows.iter_mut().zip(Problem::for_rows(&lines, report)) {
            row.problem = problem;
        }
    }

    fn refresh_shown(&mut self) {
        if self.filter.is_empty() {
            self.shown = (0..self.rows.len()).collect();
            return;
        }
        let needle = self.filter.to_lowercase();
        self.shown = (0..self.rows.len())
            .filter(|&index| {
                let entry = &self.rows[index].entry;
                entry.value.to_lowercase().contains(&needle)
                    || entry.keys.to_lowercase().contains(&needle)
            })
            .collect();
    }

    /// Whether another row fits under the engine's cap.
    pub fn can_add(&self) -> bool {
        self.rows.len() < UserDict::MAX_ENTRIES as usize
    }

    /// Insert `entry` at `at` (clamped to the end) and save. The search
    /// filter is cleared, so the new row is on screen. Returns its index.
    pub fn add(&mut self, at: usize, entry: &Entry) -> io::Result<usize> {
        let at = at.min(self.rows.len());
        self.rows.insert(
            at,
            Row {
                entry: clean(entry),
                file_line: None,
                problem: None,
            },
        );
        self.filter.clear();
        self.refresh_shown();
        self.save().map(|()| at)
    }

    /// Put `entry` in place of the row at `index`, saving when that changes
    /// it. Returns whether it saved.
    pub fn replace(&mut self, index: usize, entry: &Entry) -> io::Result<bool> {
        let entry = clean(entry);
        if self.rows[index].entry == entry && self.rows[index].file_line.is_some() {
            return Ok(false);
        }
        self.rows[index].entry = entry;
        self.save().map(|()| true)
    }

    pub fn remove(&mut self, indices: &[usize]) -> io::Result<()> {
        let mut doomed = indices.to_vec();
        doomed.sort_unstable();
        doomed.dedup();
        for &index in doomed.iter().rev() {
            self.rows.remove(index);
        }
        self.refresh_shown();
        self.save()
    }

    /// Move `sources` so they sit, in their current order, just above the
    /// row that is now at `target` (`rows().len()` means the end). Order
    /// matters only among phrases on one code: it is the order they are
    /// listed in. Returns where the moved rows are now.
    pub fn move_rows(&mut self, sources: &[usize], target: usize) -> io::Result<Range<usize>> {
        let mut sources = sources.to_vec();
        sources.sort_unstable();
        sources.dedup();
        let target = target.min(self.rows.len());
        let insert_at = target - sources.iter().filter(|&&s| s < target).count();
        let mut moving: Vec<Row> = sources.iter().rev().map(|&s| self.rows.remove(s)).collect();
        moving.reverse();
        let moved = insert_at..insert_at + moving.len();
        self.rows.splice(insert_at..insert_at, moving);
        self.refresh_shown();
        self.save().map(|()| moved)
    }

    pub fn duplicate_check(&self) -> DuplicateCheck {
        if let Some(error) = self.store.last_error() {
            return DuplicateCheck::Unavailable {
                reason: error.message(),
            };
        }
        let flagged = |pick: fn(&Problem) -> bool| -> Vec<usize> {
            (0..self.rows.len())
                .filter(|&index| self.rows[index].problem.as_ref().is_some_and(pick))
                .collect()
        };
        let invalid = flagged(Problem::is_invalid).len();
        let duplicates = flagged(Problem::is_duplicate);
        let shared = flagged(Problem::is_shared_code);
        if duplicates.is_empty() && shared.is_empty() {
            return DuplicateCheck::Clean { invalid };
        }
        DuplicateCheck::Found {
            duplicates,
            shared,
            invalid,
        }
    }

    /// The status line: the counts, why the file does not load if it does
    /// not, and whether the dictionary is switched off.
    pub fn summary(&self, enabled: bool) -> String {
        let count = |pick: fn(&Problem) -> bool| {
            self.rows
                .iter()
                .filter(|row| row.problem.as_ref().is_some_and(pick))
                .count()
        };
        let mut parts = vec![format!("共 {} 条", self.rows.len())];
        for (n, what) in [
            (count(Problem::is_invalid), "无效"),
            (count(Problem::is_duplicate), "重复"),
            (count(Problem::is_shared_code), "同码"),
        ] {
            if n > 0 {
                parts.push(format!("{n} 条{what}"));
            }
        }
        if let Some(error) = self.store.last_error() {
            parts.push(error.message());
        }
        if !enabled {
            parts.push("已停用".to_owned());
        }
        parts.join("，")
    }
}

/// An entry as the file will hold it: each field trimmed of ASCII spaces,
/// the way libjd reads a field. A TAB or a line break, which only a paste
/// can bring into a field, would split the line in the file, so each
/// becomes a space first.
fn clean(entry: &Entry) -> Entry {
    let field = |text: &str| -> String {
        let text: String = text
            .chars()
            .map(|c| if matches!(c, '\t' | '\r' | '\n') { ' ' } else { c })
            .collect();
        text.trim_matches(' ').to_owned()
    };
    Entry::new(field(&entry.value), field(&entry.keys))
}

#[cfg(test)]
mod tests {
    use super::*;
    use jd::JdContext;
    use std::fs;

    /// A list over a temporary file holding `text`, removed on drop.
    struct Fixture {
        dir: PathBuf,
        table: Table,
    }

    impl Fixture {
        fn new(tag: &str, text: Option<&[u8]>) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "jd-userdict-table-{tag}-{}",
                std::process::id()
            ));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            let path = dir.join(file::FILE_NAME);
            if let Some(text) = text {
                fs::write(&path, text).unwrap();
            }
            Self {
                table: Table::open(path),
                dir,
            }
        }

        fn path(&self) -> PathBuf {
            self.dir.join(file::FILE_NAME)
        }

        fn file_text(&self) -> String {
            fs::read_to_string(self.path()).unwrap()
        }

        fn values(&self) -> Vec<String> {
            self.table.rows().iter().map(|r| r.entry.value.clone()).collect()
        }

        fn status(&self, index: usize) -> Option<String> {
            self.table.rows()[index].problem.map(|p| p.text())
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    fn removing_rows_saves_the_rest() {
        let mut f = Fixture::new("remove", Some("键道\tzzzzzz\n不\tb\n测试词\tb\n不\tb\n".as_bytes()));
        assert_eq!(f.table.rows().len(), 4);
        assert_eq!(f.table.store().report().unwrap().dropped_lines(), vec![2, 4]);

        f.table.remove(&[1, 3]).unwrap();

        let kept = vec![Entry::new("键道", "zzzzzz"), Entry::new("测试词", "b")];
        assert_eq!(f.table.entries(), kept);
        assert_eq!(f.file_text(), file::serialize(&kept));
        let report = f.table.store().report().unwrap();
        assert_eq!((report.entries, report.dropped), (2, 0));
    }

    #[test]
    fn moving_rows_rewrites_the_file_in_list_order() {
        let mut f = Fixture::new("move", Some("一\tzzzzzz\n二\tzzzzzz\n三\tzzzzzz\n".as_bytes()));

        // The last row above the first.
        assert_eq!(f.table.move_rows(&[2], 0).unwrap(), 0..1);
        assert_eq!(f.values(), ["三", "一", "二"]);
        let on_disk: Vec<String> = file::parse(&f.file_text())
            .into_iter()
            .map(|r| r.entry.value)
            .collect();
        assert_eq!(on_disk, ["三", "一", "二"]);

        // The first two to the end; the engine lists them in that order.
        assert_eq!(f.table.move_rows(&[0, 1], 3).unwrap(), 1..3);
        assert_eq!(f.values(), ["二", "三", "一"]);
        let (dict, _) = UserDict::build(&f.file_text(), 0).unwrap();
        let mut ctx = JdContext::with_user_dict(dict.leak()).unwrap();
        for byte in *b"zzzzzz" {
            ctx.press_key(byte);
        }
        let listed: Vec<&str> = ctx.candidates(0, 3).iter().map(|c| c.value()).collect();
        assert_eq!(listed, ["二", "三", "一"]);

        // Up and down by one, as the buttons do: up is "above the row before
        // the first", down "above the row after the next".
        assert_eq!(f.table.move_rows(&[2], 1).unwrap(), 1..2);
        assert_eq!(f.values(), ["二", "一", "三"]);
        assert_eq!(f.table.move_rows(&[0], 2).unwrap(), 1..2);
        assert_eq!(f.values(), ["一", "二", "三"]);
        assert_eq!(f.table.move_rows(&[1], 9).unwrap(), 2..3, "past the end is the end");
        assert_eq!(f.values(), ["一", "三", "二"]);
    }

    #[test]
    fn the_status_column_follows_every_save() {
        let mut f = Fixture::new(
            "status",
            Some("测试词\tb\n一\tzzzzzz\n二\tzzzzzz\n键道\tzzzzza\n不\tb\n三\tb\n四\tzzzzzz\n".as_bytes()),
        );
        let on_b = f.table.store().report().unwrap().notes[0].builtin;
        assert_eq!(f.status(0), Some(format!("与 {on_b} 个内置词及第 6 条同码")));
        assert_eq!(f.status(3), None);
        assert_eq!(f.status(4).as_deref(), Some("与内置词重复，不生效"));

        // Removing the other phrase on b leaves only the built-in words.
        f.table.remove(&[5]).unwrap();
        assert_eq!(f.status(0), Some(format!("与 {on_b} 个内置词同码")));
        assert_eq!(f.table.summary(true), "共 6 条，1 条重复，4 条同码");
        assert_eq!(f.table.summary(false), "共 6 条，1 条重复，4 条同码，已停用");
    }

    #[test]
    fn adding_and_replacing_write_cleaned_entries() {
        let mut f = Fixture::new("edit", Some("键道\tzzzzzz\n".as_bytes()));
        let before = f.file_text();

        // Unchanged, after trimming: nothing written.
        assert!(!f.table.replace(0, &Entry::new(" 键道 ", "zzzzzz ")).unwrap());
        assert_eq!(f.file_text(), before);

        let at = f.table.add(9, &Entry::new("键道输入法", "zzzzza\t")).unwrap();
        assert_eq!(at, 1);
        assert_eq!(f.table.rows()[at].entry, Entry::new("键道输入法", "zzzzza"));
        assert_eq!(f.status(at), None);
        assert_eq!(
            f.file_text(),
            file::serialize(&[Entry::new("键道", "zzzzzz"), Entry::new("键道输入法", "zzzzza")])
        );

        // A pasted line break would split the line in the file.
        assert!(f.table.replace(at, &Entry::new("键道\r\n输入法", "zzzzza")).unwrap());
        assert_eq!(f.table.rows()[at].entry.value, "键道  输入法");
        assert_eq!(file::parse(&f.file_text()).len(), 2);

        // A code the engine rejects is written all the same, and flagged.
        assert!(f.table.replace(at, &Entry::new("键道输入法", "ZZ")).unwrap());
        assert_eq!(f.status(at).as_deref(), Some("编码无效（1 到 6 个 a-z），不生效"));
    }

    #[test]
    fn the_filter_narrows_the_shown_rows_and_adding_clears_it() {
        let mut f = Fixture::new("filter", Some("键道\tzzzzzz\n输入法\tzzzzza\nABC\tzzzzzb\n".as_bytes()));
        f.table.set_filter(" ZZZZZA ");
        assert_eq!(f.table.shown(), [1]);
        f.table.set_filter("abc");
        assert_eq!(f.table.shown(), [2]);
        f.table.set_filter("键");
        assert_eq!(f.table.shown(), [0]);
        assert!(f.table.is_filtering());
        f.table.add(1, &Entry::new("新", "zzzzzc")).unwrap();
        assert!(!f.table.is_filtering());
        assert_eq!(f.table.shown(), [0, 1, 2, 3]);
    }

    #[test]
    fn an_external_change_reloads_but_our_own_save_does_not() {
        let mut f = Fixture::new("external", Some("键道\tzzzzzz\n".as_bytes()));
        f.table.replace(0, &Entry::new("键道", "zzzzzy")).unwrap();
        assert!(!f.table.file_changed(), "our own save reads back unchanged");

        file::write(&f.path(), "键道\tzzzzzz\n键道输入法\tzzzzza\n").unwrap();
        assert!(f.table.file_changed());
        assert_eq!(f.values(), ["键道", "键道输入法"]);
    }

    #[test]
    fn skipped_rows_are_flagged_and_counted_but_never_block_the_check() {
        // A capital letter in a code: the engine skips the line and the row
        // says why; the rest of the file builds, so the repeat on line 3 is
        // still found.
        let mut f = Fixture::new("skipped", Some("甲\tzzzzzz\n乙\tZZZZZA\n甲\tzzzzzz\n".as_bytes()));
        assert!(f.table.store().last_error().is_none());
        assert_eq!(f.status(1).as_deref(), Some("编码无效（1 到 6 个 a-z），不生效"));
        assert_eq!(f.status(2).as_deref(), Some("与第 1 条重复，不生效"));
        assert_eq!(
            f.table.duplicate_check(),
            DuplicateCheck::Found {
                duplicates: vec![2],
                shared: vec![],
                invalid: 1
            }
        );

        f.table.replace(1, &Entry::new("乙", "zzzzza")).unwrap();
        assert_eq!(
            f.table.duplicate_check(),
            DuplicateCheck::Found {
                duplicates: vec![2],
                shared: vec![],
                invalid: 0
            }
        );
        f.table.remove(&[2]).unwrap();
        assert_eq!(f.table.duplicate_check(), DuplicateCheck::Clean { invalid: 0 });
    }

    #[test]
    fn the_check_says_so_while_the_file_cannot_be_loaded() {
        // Not UTF-8: the engine never saw this version of the file, so there
        // are no notes to sum up and the check must not call the file clean.
        let f = Fixture::new("unloadable", Some(&[0xC4, 0xE3, 0x09, 0x61, 0x0A]));
        let reason = f.table.store().last_error().unwrap().message();
        assert_eq!(reason, "文件不是 UTF-8 编码");
        assert!(f.table.rows().is_empty());
        assert_eq!(
            f.table.duplicate_check(),
            DuplicateCheck::Unavailable {
                reason: reason.clone()
            }
        );
        assert_eq!(f.table.summary(true), format!("共 0 条，{reason}"));
    }

    #[test]
    fn no_file_is_an_empty_list_and_the_first_save_creates_it() {
        let mut f = Fixture::new("nofile", None);
        assert!(f.table.rows().is_empty());
        assert!(f.table.store().last_error().is_none());
        assert_eq!(f.table.duplicate_check(), DuplicateCheck::Clean { invalid: 0 });
        f.table.add(0, &Entry::new("键道", "zzzzzz")).unwrap();
        assert_eq!(f.file_text(), file::serialize(&[Entry::new("键道", "zzzzzz")]));
    }
}
