//! Searching the phrase list. A port of bindings/swift/UserDictSearch.swift,
//! as android's userdict/UserDictSearch.kt is: the same rows match the same
//! query on every client.

use jd_userdict::Entry;

/// The rows as one case-folded text, so the search box keeps up with
/// hundreds of thousands of them: each row is its value, a TAB, its keys
/// and a newline, lowercased, and a query is one substring scan of the whole
/// text with every hit mapped back to its row. Build it when the rows change
/// — or at the first query after — and ask it as often as the query
/// changes. Never matches across fields, a query holding no TAB or newline.
pub struct Search {
    text: String,
    /// Where row `i` starts in `text` is `starts[i]`; one more at the end.
    starts: Vec<usize>,
}

impl Search {
    pub fn new<'a>(entries: impl IntoIterator<Item = &'a Entry>) -> Self {
        let mut text = String::new();
        let mut starts = vec![0];
        for entry in entries {
            push_folded(&entry.value, &mut text);
            text.push('\t');
            push_folded(&entry.keys, &mut text);
            text.push('\n');
            starts.push(text.len());
        }
        Self { text, starts }
    }

    /// The rows that contain `query`, ascending; every row for an empty
    /// query.
    pub fn matches(&self, query: &str) -> Vec<usize> {
        let rows = self.starts.len() - 1;
        if query.is_empty() {
            return (0..rows).collect();
        }
        let mut needle = String::new();
        push_folded(query, &mut needle);
        if needle.contains(['\t', '\n']) {
            return Vec::new();
        }
        let mut hits = Vec::new();
        let mut from = 0;
        let mut row = 0;
        // `from` is always a row's start, so a character's too.
        while let Some(found) = self.text[from..].find(&needle) {
            let at = from + found;
            while self.starts[row + 1] <= at {
                row += 1;
            }
            hits.push(row);
            // One hit per row: go on from the next one.
            from = self.starts[row + 1];
        }
        hits
    }
}

/// `text` lowercased onto `out`, a character at a time — as the old
/// per-row `to_lowercase` did but for a final Σ, which folds to σ here
/// wherever it stands, in the rows and the query alike.
fn push_folded(text: &str, out: &mut String) {
    if text.is_ascii() {
        out.extend(text.bytes().map(|byte| char::from(byte.to_ascii_lowercase())));
    } else {
        out.extend(text.chars().flat_map(char::to_lowercase));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn search(rows: &[(&str, &str)]) -> Search {
        let entries: Vec<Entry> = rows.iter().map(|&(value, keys)| Entry::new(value, keys)).collect();
        Search::new(&entries)
    }

    #[test]
    fn a_query_finds_each_row_once_in_either_field_ignoring_case() {
        let s = search(&[("键道", "zzzzzz"), ("ABC", "abca"), ("输入法", "zzzzza"), ("Ab", "zz")]);
        assert_eq!(s.matches(""), [0, 1, 2, 3]);
        assert_eq!(s.matches("ZZ"), [0, 2, 3]);
        assert_eq!(s.matches("ab"), [1, 3], "a row matching twice is listed once");
        assert_eq!(s.matches("键"), [0]);
        assert_eq!(s.matches("zzzzzza"), [0usize; 0]);
        assert_eq!(s.matches("ÄB"), [0usize; 0]);
        assert_eq!(search(&[]).matches("a"), [0usize; 0]);
        assert_eq!(search(&[]).matches(""), [0usize; 0]);
    }

    #[test]
    fn a_match_never_runs_across_fields_or_rows() {
        let s = search(&[("ab", "cd"), ("ef", "gh")]);
        // "b" then "c" are the end of one field and the start of the next.
        assert_eq!(s.matches("bc"), [0usize; 0]);
        assert_eq!(s.matches("de"), [0usize; 0]);
        assert_eq!(s.matches("b\tc"), [0usize; 0]);
        assert_eq!(s.matches("d\ne"), [0usize; 0]);
    }

    #[test]
    fn letters_beyond_ascii_fold_too() {
        let s = search(&[("Ärger", "a"), ("ΣΟΦΙΑ", "b"), ("İstanbul", "c")]);
        assert_eq!(s.matches("ärg"), [0]);
        assert_eq!(s.matches("ÄRG"), [0]);
        assert_eq!(s.matches("σοφ"), [1]);
        assert_eq!(s.matches("i̇st"), [2]);
    }
}
