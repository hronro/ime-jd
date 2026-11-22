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
use super::search::Search;
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

/// How many rows each kind of verdict flags, for the status line, which is
/// redrawn at every keystroke in the search box.
#[derive(Clone, Copy, Debug, Default)]
struct Counts {
    invalid: usize,
    duplicate: usize,
    shared: usize,
}

pub struct Table {
    store: Store,
    rows: Vec<Row>,
    /// The rows on screen, as indices into `rows`: all of them, or the
    /// search hits.
    shown: Vec<usize>,
    filter: String,
    /// The rows as one searchable text, built at the first query after the
    /// rows change.
    search: Option<Search>,
    counts: Counts,
}

impl Table {
    /// The list over the file at `path`, read now; what it builds goes to
    /// the IME's shared cache in `cache_dir`, if one is given.
    pub fn open(path: PathBuf, cache_dir: Option<PathBuf>) -> Self {
        let mut store = Store::new(path, cache_dir);
        let text = store.reload();
        let mut table = Self {
            store,
            rows: Vec::new(),
            shown: Vec::new(),
            filter: String::new(),
            search: None,
            counts: Counts::default(),
        };
        table.load_rows(text.as_deref());
        table
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    #[cfg(test)]
    pub fn entries(&self) -> Vec<Entry> {
        self.rows.iter().map(|row| row.entry.clone()).collect()
    }

    pub fn shown(&self) -> &[usize] {
        &self.shown
    }

    /// Where `rows` (indices into `rows()`) are on screen: their positions
    /// in `shown()`, in the order given, less those the search hides.
    pub fn view_rows(&self, rows: &[usize]) -> Vec<usize> {
        // `shown` is in list order, so each row is a binary search away: a
        // scan for each made selecting thousands of rows quadratic.
        rows.iter().filter_map(|row| self.shown.binary_search(row).ok()).collect()
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

    /// The file changed on disk. A change that reads back as the text the
    /// window last wrote or read — its own save — costs a read and a hash;
    /// anything else, a text editor's save most likely, reloads the rows.
    /// Returns whether it did.
    pub fn file_changed(&mut self) -> bool {
        let before = self.store.hash();
        let text = self.store.reload();
        if self.store.hash() == before {
            return false;
        }
        self.load_rows(text.as_deref());
        true
    }

    fn load_rows(&mut self, text: Option<&str>) {
        self.rows = file::parse(text.unwrap_or(""))
            .into_iter()
            .map(|row| Row {
                entry: row.entry,
                file_line: Some(row.line),
                problem: None,
            })
            .collect();
        self.search = None;
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
        let result = self.store.save(self.rows.iter().map(|row| &row.entry));
        if result.is_err() {
            self.rows.iter_mut().for_each(|row| row.file_line = None);
        }
        self.recompute_problems();
        result
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
        let mut counts = Counts::default();
        for (row, problem) in self.rows.iter_mut().zip(Problem::for_rows(&lines, report)) {
            match problem {
                Some(Problem::Invalid { .. }) => counts.invalid += 1,
                Some(Problem::Duplicate { .. }) => counts.duplicate += 1,
                Some(Problem::SharedCode { .. }) => counts.shared += 1,
                None => {}
            }
            row.problem = problem;
        }
        self.counts = counts;
    }

    fn refresh_shown(&mut self) {
        if self.filter.is_empty() {
            self.shown = (0..self.rows.len()).collect();
            return;
        }
        let search = self
            .search
            .get_or_insert_with(|| Search::new(self.rows.iter().map(|row| &row.entry)));
        self.shown = search.matches(&self.filter);
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
        self.search = None;
        self.filter.clear();
        self.refresh_shown();
        self.save().map(|()| at)
    }

    /// Put `entry` in place of the row at `index`, saving when that changes
    /// it. Returns whether it saved. The row stays on screen under a search
    /// it no longer matches, until the query changes.
    pub fn replace(&mut self, index: usize, entry: &Entry) -> io::Result<bool> {
        let entry = clean(entry);
        if self.rows[index].entry == entry && self.rows[index].file_line.is_some() {
            return Ok(false);
        }
        self.rows[index].entry = entry;
        self.search = None;
        self.save().map(|()| true)
    }

    /// Remove the rows at `indices`, in one pass over the rows however many
    /// there are, and save.
    pub fn remove(&mut self, indices: &[usize]) -> io::Result<()> {
        let doomed = self.mark(indices);
        let mut index = 0;
        self.rows.retain(|_| {
            index += 1;
            !doomed[index - 1]
        });
        self.search = None;
        self.refresh_shown();
        self.save()
    }

    /// Move `sources` so they sit, in their current order, just above the
    /// row that is now at `target` (`rows().len()` means the end). Order
    /// matters only among phrases on one code: it is the order they are
    /// listed in. Returns where the moved rows are now.
    pub fn move_rows(&mut self, sources: &[usize], target: usize) -> io::Result<Range<usize>> {
        let moving = self.mark(sources);
        let target = target.min(self.rows.len());
        let insert_at = moving[..target].iter().filter(|&&m| !m).count();
        // The rows that stay and the rows that move, each in list order, in
        // one pass, and the moving ones spliced back in at once.
        let (mut rows, mut moved) = (Vec::with_capacity(self.rows.len()), Vec::new());
        for (row, moves) in std::mem::take(&mut self.rows).into_iter().zip(moving) {
            if moves { moved.push(row) } else { rows.push(row) }
        }
        let range = insert_at..insert_at + moved.len();
        rows.splice(insert_at..insert_at, moved);
        self.rows = rows;
        self.search = None;
        self.refresh_shown();
        self.save().map(|()| range)
    }

    /// One flag per row, set for the rows at `indices`.
    fn mark(&self, indices: &[usize]) -> Vec<bool> {
        let mut marked = vec![false; self.rows.len()];
        for &index in indices {
            marked[index] = true;
        }
        marked
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
        let mut parts = vec![format!("共 {} 条", self.rows.len())];
        for (n, what) in [
            (self.counts.invalid, "无效"),
            (self.counts.duplicate, "重复"),
            (self.counts.shared, "同码"),
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
                table: Table::open(path, None),
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

        // An edit under a search: the row stays on screen, and the next
        // query sees what it holds now.
        f.table.replace(0, &Entry::new("键盘", "zzzzzz")).unwrap();
        assert_eq!(f.table.shown(), [0]);
        f.table.set_filter("键道");
        assert_eq!(f.table.shown(), [0usize; 0]);
        f.table.set_filter("键");
        assert_eq!(f.table.shown(), [0]);
        // Removing rows under a search shows what is left of the hits.
        f.table.remove(&[1]).unwrap();
        f.table.set_filter("zzzzz");
        assert_eq!(f.table.shown(), [0, 1]);
        f.table.remove(&[0]).unwrap();
        assert_eq!(f.table.shown(), [0]);

        f.table.add(1, &Entry::new("新", "zzzzzc")).unwrap();
        assert!(!f.table.is_filtering());
        assert_eq!(f.table.shown(), [0, 1]);
    }

    #[test]
    fn rows_are_found_on_screen_by_their_place_in_the_shown_ones() {
        let mut f = Fixture::new("view", Some("键道\tzzzzzz\n输入法\tzzzzza\nABC\tzzzzzb\n键道输入法\tzzzzzc\n".as_bytes()));
        // Unfiltered, a row is where its index says; the order asked is the
        // order answered, and a row that is not there is not found.
        assert_eq!(f.table.view_rows(&[0, 3]), [0, 3]);
        assert_eq!(f.table.view_rows(&[3, 1, 9]), [3, 1]);
        assert_eq!(f.table.view_rows(&[]), [0usize; 0]);

        // Under a search, rows 0 and 3 are the first and second on screen,
        // and the others are not on it.
        f.table.set_filter("键道");
        assert_eq!(f.table.shown(), [0, 3]);
        assert_eq!(f.table.view_rows(&[0, 1, 2, 3]), [0, 1]);
        assert_eq!(f.table.view_rows(&[1, 2]), [0usize; 0]);
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
    fn scattered_rows_move_and_go_as_one_row_at_a_time_would_have_them() {
        // The reference: moving and removing a row at a time, as the list
        // did before it had to keep up with 500 000 rows.
        fn moved(values: &[String], sources: &[usize], target: usize) -> (Vec<String>, Range<usize>) {
            let mut sources = sources.to_vec();
            sources.sort_unstable();
            sources.dedup();
            let target = target.min(values.len());
            let insert_at = target - sources.iter().filter(|&&s| s < target).count();
            let mut rest = values.to_vec();
            let mut moving: Vec<String> = sources.iter().rev().map(|&s| rest.remove(s)).collect();
            moving.reverse();
            rest.splice(insert_at..insert_at, moving);
            (rest, insert_at..insert_at + sources.len())
        }

        let text: String = (0..12).map(|i| format!("词{i}\tzzzzz{}\n", (b'a' + i) as char)).collect();
        let mut f = Fixture::new("scattered", Some(text.as_bytes()));
        let mut seed: u64 = 7;
        let mut next = move |below: usize| {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) as usize % below
        };
        for _ in 0..40 {
            let len = f.table.rows().len();
            let sources: Vec<usize> = (0..1 + next(4)).map(|_| next(len)).collect();
            let target = next(len + 2);
            let (expected, range) = moved(&f.values(), &sources, target);
            assert_eq!(f.table.move_rows(&sources, target).unwrap(), range);
            assert_eq!(f.values(), expected);
        }
        let on_disk: Vec<String> = file::parse(&f.file_text()).into_iter().map(|r| r.entry.value).collect();
        assert_eq!(on_disk, f.values());

        let mut expected = f.values();
        for index in [9, 0, 4, 4, 11] {
            expected[index].clear();
        }
        expected.retain(|value| !value.is_empty());
        f.table.remove(&[9, 0, 4, 4, 11]).unwrap();
        assert_eq!(f.values(), expected);
        let on_disk: Vec<String> = file::parse(&f.file_text()).into_iter().map(|r| r.entry.value).collect();
        assert_eq!(on_disk, expected);
    }

    #[test]
    fn each_text_the_window_builds_goes_to_the_shared_cache() {
        let mut f = Fixture::new("cached", Some("键道\tzzzzzz\n".as_bytes()));
        let cache_dir = f.dir.join("cache");
        let blob_of = |f: &Fixture| UserDict::hash(f.file_text().as_bytes());

        f.table = Table::open(f.path(), Some(cache_dir.clone()));
        let first = blob_of(&f);
        assert_eq!(jd_userdict::cache::open_in(&cache_dir, first).unwrap().entries(), 1);

        // A save: the new text's blob, and the old one gone.
        f.table.add(1, &Entry::new("键道输入法", "zzzzza")).unwrap();
        let second = blob_of(&f);
        assert_eq!(jd_userdict::cache::open_in(&cache_dir, second).unwrap().entries(), 2);
        assert!(!jd_userdict::cache::path_in(&cache_dir, first).exists());

        // A file the window was pointed at (`--file`) writes nothing there.
        let mut trial = Table::open(f.path(), None);
        trial.add(0, &Entry::new("试", "zzzzzb")).unwrap();
        assert!(jd_userdict::cache::open_in(&cache_dir, blob_of(&f)).is_none());
        assert!(jd_userdict::cache::open_in(&cache_dir, second).is_some());
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
