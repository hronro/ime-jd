//! The engine's verdict on one row of the list: the notes `UserDict::build`
//! leaves, mapped onto the rows by line, with the words the status column
//! shows. The words are the ones every client's phrase list uses
//! (bindings/swift/UserDictProblem.swift, android's
//! userdict/UserDictProblem.kt), so a phrase reads the same everywhere.

use jd::{UserDict, UserDictNote, UserDictReport};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Problem {
    /// In the file, but libjd skips it: it does not parse. `flags` say why.
    Invalid { flags: u32 },
    /// In the file, but libjd drops it: the same phrase as row `of_row`, or
    /// (`None`) as a built-in word.
    Duplicate { of_row: Option<usize> },
    /// Works, and is listed first — but the code already carries `built_in`
    /// built-in words and/or `peers` other rows, the first of them
    /// `other_row`.
    SharedCode {
        built_in: u32,
        other_row: Option<usize>,
        peers: u32,
    },
}

impl Problem {
    pub fn text(&self) -> String {
        match *self {
            Problem::Invalid { flags } => {
                if flags & UserDictNote::MALFORMED != 0 {
                    "缺少制表符（无编码），不生效".to_owned()
                } else if flags & UserDictNote::BAD_KEYS != 0 {
                    format!(
                        "编码无效（1 到 {} 个 a-z），不生效",
                        UserDict::MAX_KEY_LENGTH
                    )
                } else {
                    format!(
                        "词无效（不能为空或含控制字符，最长 {} 字节），不生效",
                        UserDict::VALUE_MAX
                    )
                }
            }
            Problem::Duplicate { of_row: Some(row) } => format!("与第 {} 条重复，不生效", row + 1),
            Problem::Duplicate { of_row: None } => "与内置词重复，不生效".to_owned(),
            Problem::SharedCode {
                built_in,
                other_row,
                peers,
            } => {
                // "与 2 个内置词及第 3 条等 2 条同码", or either half alone.
                let mut parts = Vec::with_capacity(2);
                if built_in > 0 {
                    parts.push(format!(" {built_in} 个内置词"));
                }
                if let Some(row) = other_row {
                    parts.push(if peers > 1 {
                        format!("第 {} 条等 {peers} 条", row + 1)
                    } else {
                        format!("第 {} 条", row + 1)
                    });
                }
                format!("与{}同码", parts.join("及"))
            }
        }
    }

    pub fn is_invalid(&self) -> bool {
        matches!(self, Problem::Invalid { .. })
    }

    pub fn is_duplicate(&self) -> bool {
        matches!(self, Problem::Duplicate { .. })
    }

    pub fn is_shared_code(&self) -> bool {
        matches!(self, Problem::SharedCode { .. })
    }

    /// One verdict per row, from the notes of the build of the text the rows
    /// came from. `lines[i]` is row `i`'s 1-based line in that text, `None`
    /// for a row that is not in it (added, not yet written). A `None`
    /// report — the text could not be built at all — flags nothing: the
    /// engine has no notes on a file it could not read.
    pub fn for_rows(lines: &[Option<u32>], report: Option<&UserDictReport>) -> Vec<Option<Problem>> {
        let Some(report) = report else {
            return vec![None; lines.len()];
        };
        let notes: std::collections::HashMap<u32, &UserDictNote> =
            report.notes.iter().map(|note| (note.line, note)).collect();
        let row_by_line: std::collections::HashMap<u32, usize> = lines
            .iter()
            .enumerate()
            .filter_map(|(index, line)| line.map(|line| (line, index)))
            .collect();
        lines
            .iter()
            .map(|line| {
                let note = notes.get(&(*line)?)?;
                let other = row_by_line.get(&note.other).copied();
                if note.is_invalid() {
                    Some(Problem::Invalid { flags: note.flags })
                } else if note.flags & UserDictNote::REPEATS_LINE != 0 {
                    Some(Problem::Duplicate { of_row: other })
                } else if note.flags & UserDictNote::REPEATS_BUILTIN != 0 {
                    Some(Problem::Duplicate { of_row: None })
                } else if note.is_shared() {
                    Some(Problem::SharedCode {
                        built_in: note.builtin,
                        other_row: if note.flags & UserDictNote::CODE_IN_LINE != 0 {
                            other
                        } else {
                            None
                        },
                        peers: note.peers,
                    })
                } else {
                    None
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verdicts(text: &str) -> Vec<Option<String>> {
        let (_, report) = UserDict::build(text, 0).unwrap();
        let lines: Vec<Option<u32>> = jd_userdict::file::parse(text)
            .iter()
            .map(|row| Some(row.line))
            .collect();
        Problem::for_rows(&lines, Some(&report))
            .iter()
            .map(|p| p.map(|p| p.text()))
            .collect()
    }

    #[test]
    fn duplicates_and_shared_codes_get_the_other_clients_words() {
        // Same rows as the macOS window test: "zzzzzz" and "zzzzza" are free
        // in the bundled tables, "b" is a built-in code, and "不" is a
        // built-in word on it.
        let text = "测试词\tb\n一\tzzzzzz\n二\tzzzzzz\n键道\tzzzzza\n不\tb\n三\tb\n四\tzzzzzz\n";
        let (_, report) = UserDict::build(text, 0).unwrap();
        let on_b = report.notes.iter().find(|n| n.line == 1).unwrap().builtin;
        assert!(on_b >= 1);
        assert_eq!(
            verdicts(text),
            vec![
                Some(format!("与 {on_b} 个内置词及第 6 条同码")),
                Some("与第 3 条等 2 条同码".to_owned()),
                Some("与第 2 条等 2 条同码".to_owned()),
                None,
                Some("与内置词重复，不生效".to_owned()),
                Some(format!("与 {on_b} 个内置词及第 1 条同码")),
                Some("与第 2 条等 2 条同码".to_owned()),
            ]
        );
        assert_eq!(
            verdicts("甲\tzzzzzz\n乙\tzzzzzz\n甲\tzzzzzz\n"),
            vec![
                Some("与第 2 条同码".to_owned()),
                Some("与第 1 条同码".to_owned()),
                Some("与第 1 条重复，不生效".to_owned()),
            ]
        );
    }

    #[test]
    fn skipped_rows_say_why() {
        assert_eq!(
            verdicts("no tab\n好\tZZ\n\tzzzzza\n"),
            vec![
                Some("缺少制表符（无编码），不生效".to_owned()),
                Some("编码无效（1 到 6 个 a-z），不生效".to_owned()),
                Some("词无效（不能为空或含控制字符，最长 255 字节），不生效".to_owned()),
            ]
        );
    }

    #[test]
    fn rows_outside_the_build_and_unbuilt_files_are_not_flagged() {
        let (_, report) = UserDict::build("甲\tzzzzzz\n甲\tzzzzzz\n", 0).unwrap();
        // A row added and not yet written has no line to match.
        let problems = Problem::for_rows(&[Some(1), Some(2), None], Some(&report));
        assert_eq!(problems[1], Some(Problem::Duplicate { of_row: Some(0) }));
        assert_eq!(problems[2], None);
        assert_eq!(Problem::for_rows(&[Some(1), Some(2)], None), vec![None, None]);
    }
}
