//! `--lookup`: print the codes a candidate is typed with and exit, instead
//! of running the interactive prompt.

use std::io::{self, Write};
use std::process::ExitCode;

/// The exit status when no dictionary holds the candidate — 1, as grep
/// reports no match; 2 stays the status of a usage or dictionary error.
const NOT_FOUND: u8 = 1;

/// Look `candidate` up in what `jd` types from — the built-in dictionary or
/// `--dict`, and `--user-dict` when given — and write the report to `w`.
pub fn run<W>(
    w: &mut W,
    jd: &jd::JdContext,
    candidate: &str,
    no_newline: bool,
) -> io::Result<ExitCode>
where
    W: Write,
{
    let codes = jd.lookup_codes(candidate);
    let report = render(candidate, &codes);
    if no_newline {
        write!(w, "{report}")?;
    } else {
        writeln!(w, "{report}")?;
    }
    w.flush()?;

    Ok(if codes.is_empty() {
        ExitCode::from(NOT_FOUND)
    } else {
        ExitCode::SUCCESS
    })
}

/// The report, without a trailing newline. One code per line, in libjd's
/// order — shortest first. A code on which the candidate comes first stands
/// alone; any other is followed by a TAB and what sets it apart: which
/// candidate it is there, and whether the code is the user dictionary's.
/// Nothing says which key commits it: that is the engine's business. The TAB keeps the codes, at most 6 keys, in one column, and
/// lets `cut -f1` take them alone.
fn render(candidate: &str, codes: &[jd::Code]) -> String {
    if codes.is_empty() {
        return format!("{candidate}: not found");
    }
    codes
        .iter()
        .map(|code| {
            let mut notes = Vec::new();
            if code.index() > 0 {
                notes.push(format!("candidate {}", code.index() + 1));
            }
            if code.is_user() {
                notes.push("user dict".to_string());
            }
            if notes.is_empty() {
                code.keys().to_string()
            } else {
                format!("{}\t{}", code.keys(), notes.join(", "))
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(ctx: &jd::JdContext, candidate: &str) -> String {
        render(candidate, &ctx.lookup_codes(candidate))
    }

    #[test]
    fn lists_every_code_and_marks_a_later_candidate() {
        let ctx = jd::JdContext::new().unwrap();
        assert_eq!(report(&ctx, "的"), "d\ndeuiua\ndkuiua");
        // 着 is the second candidate on `o`, and first on its other ten codes.
        let lines: Vec<String> = report(&ctx, "着").lines().map(str::to_string).collect();
        assert_eq!(lines.len(), 11);
        assert_eq!(lines[0], "o\tcandidate 2");
        assert!(lines[1..].iter().all(|line| !line.contains('\t')));
    }

    #[test]
    fn says_when_nothing_types_the_candidate() {
        let ctx = jd::JdContext::new().unwrap();
        assert_eq!(report(&ctx, "不在词库里的词"), "不在词库里的词: not found");
    }

    #[test]
    fn marks_the_user_dictionary_codes() {
        let (dict, _) = jd::UserDict::build("的\tzzzzzz\n测试词\td\n", 0).unwrap();
        let ctx = jd::JdContext::with_user_dict(dict.leak()).unwrap();
        // 测试词 leads `d` now, so 的 is its second candidate there.
        assert_eq!(
            report(&ctx, "的"),
            "d\tcandidate 2\ndeuiua\ndkuiua\nzzzzzz\tuser dict"
        );
        assert_eq!(report(&ctx, "测试词"), "d\tuser dict");
    }

    #[test]
    fn a_dictionary_of_ones_own_replaces_the_built_in_one() {
        let (dict, _) = jd::Dict::build("甲\ta\n乙\ta\n乙\tbb\n", 0).unwrap();
        let dict = dict.leak();
        let ctx = jd::JdContext::with_dict(dict, None).unwrap();
        assert_eq!(report(&ctx, "乙"), "a\tcandidate 2\nbb");
        assert_eq!(report(&ctx, "的"), "的: not found");

        let (user, _) = jd::UserDict::build_on(dict, "丙\ta\n", 0).unwrap();
        let ctx = jd::JdContext::with_dict(dict, Some(user.leak())).unwrap();
        assert_eq!(report(&ctx, "甲"), "a\tcandidate 2");
        assert_eq!(report(&ctx, "丙"), "a\tuser dict");
    }

    #[test]
    fn run_writes_the_report_and_exits_by_whether_it_was_found() {
        let jd = jd::JdContext::new().unwrap();
        let mut out = Vec::new();
        let status = run(&mut out, &jd, "的", false).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "d\ndeuiua\ndkuiua\n");
        assert_eq!(status, ExitCode::SUCCESS);

        let mut out = Vec::new();
        let status = run(&mut out, &jd, "键道", true).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "jmdzi");
        assert_eq!(status, ExitCode::SUCCESS);

        let mut out = Vec::new();
        let status = run(&mut out, &jd, "不在词库里的词", false).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "不在词库里的词: not found\n"
        );
        assert_eq!(status, ExitCode::from(NOT_FOUND));
    }
}
