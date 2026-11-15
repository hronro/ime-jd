//! What 编码反查 answers for one query: libjd's codes for it
//! (`jd_lookup_codes`), worded for the user as every client words them. No
//! window here — the dialog (mod.rs) puts the answer in a task dialog.

use jd::{Code, JdContext, UserDict};

/// Where the answer quotes the query, a longer one is cut to this many
/// characters.
const QUOTED_CHARS: usize = 20;

/// The answer: a task dialog's main instruction and its text.
pub struct Report {
    pub title: String,
    /// One code per line, or why there are none.
    pub body: String,
}

/// The query as the engine should see it. A pasted word may carry spaces or
/// a TAB at its ends; dropping spaces, TABs, CRs and LFs there never loses a
/// match, because no phrase starts or ends with one (the table format trims
/// spaces, and control bytes are not allowed in a phrase). U+3000 and other
/// spaces stay: a phrase may end with one.
pub fn query(input: &str) -> &str {
    input.trim_matches([' ', '\t', '\r', '\n'])
}

/// The codes `query` is typed with, in libjd's order — shortest first — from
/// the built-in dictionary and `user_dict`, on a context made for this one
/// question. A user phrase counts toward the candidate numbers of the
/// built-in words it leads on a code.
pub fn codes(query: &str, user_dict: Option<&UserDict>) -> Vec<Code> {
    let context = match user_dict {
        // SAFETY: `with_user_dict` asks for `'static` because a context
        // reads the dictionary in place and its candidates point into it.
        // This context is gone before the borrow ends — it is dropped below —
        // and a code is a copy, its keys inline.
        Some(dict) => JdContext::with_user_dict(unsafe { &*std::ptr::from_ref(dict) }),
        None => JdContext::new(),
    };
    context
        .map(|context| context.lookup_codes(query))
        .unwrap_or_default()
}

impl Report {
    /// `codes` are libjd's, in its order. On a code where the word is the
    /// first candidate the code stands alone; any other says which candidate
    /// the word is there. Nothing says which key commits it: that is the
    /// engine's business, and it has changed before. A code from the user
    /// dictionary is marked 自造词. `user_dict_enabled` says whether the
    /// user's phrases were looked in too, which shows only when nothing was
    /// found.
    pub fn new(query: &str, codes: &[Code], user_dict_enabled: bool) -> Self {
        let word = quoted(query);
        if codes.is_empty() {
            let body = if user_dict_enabled {
                "内置词库和用户自造词中都没有这个词。"
            } else {
                "内置词库中没有这个词。用户自造词未启用，不在查询范围内。"
            };
            return Self {
                title: format!("没有找到「{word}」"),
                body: body.to_owned(),
            };
        }
        let lines: Vec<String> = codes
            .iter()
            .map(|code| {
                let mut notes = Vec::new();
                if code.index() > 0 {
                    notes.push(format!("第 {} 个候选", code.index() + 1));
                }
                if code.is_user() {
                    notes.push("自造词".to_owned());
                }
                if notes.is_empty() {
                    code.keys().to_owned()
                } else {
                    format!("{}（{}）", code.keys(), notes.join("，"))
                }
            })
            .collect();
        Self {
            title: format!("「{word}」的编码"),
            body: lines.join("\n"),
        }
    }
}

/// The query as a title quotes it: a long paste is cut short.
fn quoted(query: &str) -> String {
    match query.char_indices().nth(QUOTED_CHARS) {
        Some((end, _)) => format!("{}…", &query[..end]),
        None => query.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(query: &str, user_dict: Option<&UserDict>) -> Report {
        Report::new(query, &codes(query, user_dict), user_dict.is_some())
    }

    #[test]
    fn every_code_is_listed_and_a_later_candidate_says_which_it_is() {
        let report = report("着", None);
        assert_eq!(report.title, "「着」的编码");
        let lines: Vec<&str> = report.body.lines().collect();
        assert_eq!(lines[0], "o（第 2 个候选）");
        assert_eq!(
            lines[1..],
            [
                "fe", "qe", "flo", "fzou", "qzou", "feouia", "flouia", "fzouia", "qeouia", "qzouia"
            ]
        );
    }

    #[test]
    fn a_code_where_the_word_comes_first_stands_alone() {
        assert_eq!(report("的", None).body, "d\ndeuiua\ndkuiua");
    }

    #[test]
    fn user_phrases_are_marked_and_count_toward_the_candidate_number() {
        let (dict, _) = UserDict::build("的\tzzzzzz\n测试词\td\n", 0).unwrap();
        assert_eq!(
            report("的", Some(&dict)).body,
            "d（第 2 个候选）\ndeuiua\ndkuiua\nzzzzzz（自造词）"
        );
        assert_eq!(report("测试词", Some(&dict)).body, "d（自造词）");
        // The dictionary outlives every context made over it, and serves
        // the next question as well as the first.
        assert_eq!(report("测试词", Some(&dict)).body, "d（自造词）");
    }

    #[test]
    fn not_found_says_where_it_looked() {
        let enabled = Report::new("不在词库里的词", &[], true);
        assert_eq!(enabled.title, "没有找到「不在词库里的词」");
        assert_eq!(enabled.body, "内置词库和用户自造词中都没有这个词。");
        let disabled = Report::new("词", &[], false);
        assert_eq!(
            disabled.body,
            "内置词库中没有这个词。用户自造词未启用，不在查询范围内。"
        );
        assert!(codes("不在词库里的词", None).is_empty());
    }

    #[test]
    fn a_long_query_is_cut_short_in_the_title() {
        let long = "键".repeat(30);
        let report = Report::new(&long, &[], false);
        assert_eq!(report.title, format!("没有找到「{}…」", "键".repeat(20)));
        let exact = "键".repeat(20);
        assert_eq!(
            Report::new(&exact, &[], false).title,
            format!("没有找到「{exact}」")
        );
    }

    #[test]
    fn the_query_loses_only_line_breaks_spaces_and_tabs_at_its_ends() {
        assert_eq!(query(" 键道\r\n"), "键道");
        assert_eq!(query("\t键 道\n"), "键 道");
        assert_eq!(query("键道\u{3000}"), "键道\u{3000}");
        assert_eq!(query(" \n"), "");
    }
}
