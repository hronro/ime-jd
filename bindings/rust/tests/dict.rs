//! A dictionary of the host's own in place of the embedded one — tests that
//! hold in both libjd and libjd-engine (`--no-default-features`).

use jd::{Code, Dict, InitError, JdContext, UserDict, UserDictNote, UserDictStatus};

fn keys(codes: &[Code]) -> Vec<&str> {
    codes.iter().map(Code::keys).collect()
}

fn first_candidate(ctx: &mut JdContext, keys: &str) -> Option<String> {
    ctx.reset();
    for &k in keys.as_bytes() {
        ctx.press_key(k);
    }
    ctx.candidates(0, 1).first().map(|c| c.value().to_string())
}

#[test]
fn a_host_dictionary_replaces_the_builtin_one() {
    let (dict, report) =
        Dict::build("你\tn\n你好\tnh\n；\t;\n：\t;;\n坏\tn;\n你\tn\n", 7).expect("build");
    assert_eq!(
        (
            report.entries,
            report.invalid,
            report.dropped,
            report.shared
        ),
        (4, 1, 1, 0)
    );
    assert_eq!(report.notes.len(), 2);
    assert_eq!(dict.entries(), 4);
    assert_eq!(dict.source_tag(), 7);

    // A cached copy wraps back with the same tag.
    let copy = Dict::from_blob(dict.as_bytes()).expect("from_blob");
    assert_eq!((copy.entries(), copy.source_tag()), (4, 7));
    assert_eq!(Dict::check(dict.as_bytes()).expect("check").entries, 4);
    assert_eq!(
        Dict::check(&dict.as_bytes()[..dict.as_bytes().len() - 1])
            .unwrap_err()
            .status,
        UserDictStatus::Corrupt
    );

    let mut ctx = JdContext::with_dict(dict.leak(), None).expect("jd_init failed");
    assert_eq!(first_candidate(&mut ctx, "n").as_deref(), Some("你"));
    assert_eq!(first_candidate(&mut ctx, "nh").as_deref(), Some("你好"));
    assert_eq!(first_candidate(&mut ctx, ";;").as_deref(), Some("："));
    assert_eq!(first_candidate(&mut ctx, "b"), None);
    assert_eq!(keys(&ctx.lookup_codes("你好")), ["nh"]);
}

#[test]
fn a_user_dictionary_sits_on_the_dictionary_it_was_built_on() {
    let dict = Dict::build("你\tn\n拟\tn\n", 0).expect("build").0.leak();
    let (user, report) = UserDict::build_on(dict, "你\tn\n泥\tn\n", 0).expect("build_on");
    assert_eq!((report.entries, report.dropped, report.shared), (1, 1, 1));
    assert_eq!(report.notes[0].builtin, 2);
    assert!(UserDict::check_on(dict, user.as_bytes()).is_ok());
    let user = user.leak();

    let mut ctx = JdContext::with_dict(dict, Some(user)).expect("jd_init failed");
    ctx.press_key(b'n');
    let values: Vec<_> = ctx.candidates(0, 3).iter().map(|c| c.value()).collect();
    assert_eq!(values, ["泥", "你", "拟"]);

    // On another dictionary it is stale.
    let other = Dict::build("你\tn\n", 0).expect("build").0.leak();
    assert_eq!(
        UserDict::check_on(other, user.as_bytes())
            .unwrap_err()
            .status,
        UserDictStatus::Stale
    );
    assert_eq!(
        UserDict::from_blob_on(other, user.as_bytes())
            .unwrap_err()
            .status,
        UserDictStatus::Stale
    );
    assert_eq!(
        JdContext::with_dict(other, Some(user)).err(),
        Some(InitError::StaleUserDict)
    );
    if Dict::builtin_entries() > 0 {
        assert_eq!(
            UserDict::check(user.as_bytes()).unwrap_err().status,
            UserDictStatus::Stale
        );
        assert_eq!(
            JdContext::with_user_dict(user).err(),
            Some(InitError::StaleUserDict)
        );
    }
}

#[test]
fn an_empty_dictionary_leaves_only_the_user_dictionary() {
    let empty = Dict::empty().leak();
    assert_eq!(empty.entries(), 0);
    // Every empty dictionary is the same one: a user dictionary built on
    // one works on another.
    let (user, report) =
        UserDict::build_on(&Dict::empty(), "不\tb\n测试\tb\n：\t;;\n", 0).expect("build_on");
    assert_eq!((report.entries, report.dropped, report.shared), (3, 0, 2));
    let mut ctx = JdContext::with_dict(empty, Some(user.leak())).expect("jd_init failed");
    ctx.press_key(b'b');
    let values: Vec<_> = ctx.candidates(0, 3).iter().map(|c| c.value()).collect();
    assert_eq!(values, ["不", "测试"]);
    assert_eq!(first_candidate(&mut ctx, ";;").as_deref(), Some("："));
    assert_eq!(first_candidate(&mut ctx, "n"), None);
}

#[test]
fn user_phrases_may_start_with_semicolons() {
    let (_, report) = UserDict::build_on(&Dict::empty(), "＠\t;h\n坏\th;\n", 0).expect("build");
    assert_eq!((report.entries, report.invalid), (1, 1));
    assert_eq!(report.notes[0].line, 2);
    assert_eq!(report.notes[0].flags, UserDictNote::BAD_KEYS);
}

#[test]
fn the_builtin_dictionary_is_there_unless_this_is_libjd_engine() {
    if Dict::builtin_entries() == 0 {
        assert_eq!(JdContext::new().err(), Some(InitError::NoBuiltinDict));
        assert_eq!(
            UserDict::build("x\ta\n", 0).unwrap_err().status,
            UserDictStatus::NoBuiltinDict
        );
    } else {
        assert!(Dict::builtin_entries() > 100_000);
        assert!(JdContext::new().is_ok());
    }
}
