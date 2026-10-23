//! Integration tests against the real libjd (linked by build.rs). These run
//! headless, so they double as the CI smoke test for the FFI surface: the ABI
//! layout matches, the trie blob loads, contexts are independent, and reads
//! never disturb the commit anchor.

use jd::{Candidate, JdContext, UserDict, UserDictStatus};

#[test]
fn loads_blob_and_returns_candidates() {
    let mut ctx = JdContext::new().expect("jd_init failed");

    // Press 'b' — the dictionary has thousands of entries starting with 'b'.
    ctx.press_key(b'b');
    let state = ctx.state();
    assert!(state.options_count > 0, "no candidates for 'b'");
    assert_eq!(state.anchor_index, 0);

    let window = ctx.candidates(0, 9);
    assert_eq!(window.len(), 9);
    assert!(!window[0].value().is_empty(), "first candidate was empty");

    // Press another key to advance — must still be non-empty.
    ctx.press_key(b'a');
    assert!(
        ctx.state().options_count > 0 || ctx.commit().is_some(),
        "no candidates and no commit after 'ba'"
    );

    ctx.backspace();
}

#[test]
fn two_contexts_are_independent() {
    let mut a = JdContext::new().expect("jd_init failed");
    let mut b = JdContext::new().expect("jd_init failed");

    a.press_key(b'a');
    b.press_key(b'a');
    assert_eq!(a.state(), b.state());
    assert_eq!(a.candidates(0, 4), b.candidates(0, 4));

    a.reset();
    drop(a);

    // After dropping `a`, `b` is still healthy.
    b.press_key(b'b');
    assert!(b.state().options_count > 0);
}

#[test]
fn state_shapes_are_internally_consistent() {
    let mut ctx = JdContext::new().expect("jd_init failed");
    ctx.press_key(b'a');

    let state = ctx.state();
    if state.options_count > 0 {
        assert!(state.anchor_index < state.options_count);
        // A window is clipped by the total, never padded.
        let all = ctx.candidates(0, state.options_count + 50);
        assert_eq!(all.len() as u32, state.options_count);
    } else {
        assert!(ctx.commit().is_some(), "neither candidates nor a commit");
    }
}

#[test]
fn candidates_survive_later_calls() {
    // The core's candidate values point into the embedded blob, so unlike a
    // typical FFI result they need no copying. Hold a list across further
    // calls — including ones that used to invalidate everything — and check
    // it still reads back identically.
    let mut ctx = JdContext::new().expect("jd_init failed");

    ctx.press_key(b'b');
    let held = ctx.candidates(0, 4);
    let snapshot: Vec<String> = held.iter().map(|c| c.value().to_owned()).collect();

    ctx.press_key(b'a');
    ctx.backspace();
    ctx.reset();
    ctx.press_key(b'z');
    let _ = ctx.candidates(0, 20);

    let after: Vec<String> = held.iter().map(|c| c.value().to_owned()).collect();
    assert_eq!(snapshot, after);
}

#[test]
fn reading_ahead_does_not_move_the_anchor() {
    // The property the flat-index ABI exists to guarantee: prefetching a
    // candidate strip must not change what space commits.
    let mut ctx = JdContext::new().expect("jd_init failed");

    ctx.press_key(b'j');
    let total = ctx.state().options_count;
    assert!(total > 100, "expected a long candidate list for 'j'");

    let anchor_value = ctx.candidates(0, 1)[0].value();

    // Walk deep into the list, exactly as an append-only strip would.
    let mut strip = Vec::new();
    let mut start = 0;
    while start < 200 {
        let n = ctx.extend_candidates(start, 9, &mut strip) as u32;
        if n == 0 {
            break;
        }
        start += n;
    }
    assert!(strip.len() >= 200);
    assert_eq!(strip.len(), start as usize);
    assert_eq!(ctx.state().anchor_index, 0);

    // Space still commits the candidate the user is looking at.
    ctx.press_key(b' ');
    assert_eq!(ctx.commit().unwrap().to_string(), anchor_value);
}

#[test]
fn set_anchor_moves_what_space_commits() {
    let mut ctx = JdContext::new().expect("jd_init failed");

    ctx.press_key(b'j');
    let target = ctx.candidates(5, 1)[0].value();

    ctx.set_anchor(5);
    assert_eq!(ctx.state().anchor_index, 5);

    ctx.press_key(b' ');
    assert_eq!(ctx.commit().unwrap().to_string(), target);
}

#[test]
fn set_anchor_ignores_out_of_range() {
    let mut ctx = JdContext::new().expect("jd_init failed");

    ctx.press_key(b'j');
    let total = ctx.state().options_count;

    ctx.set_anchor(3);
    ctx.set_anchor(total); // == total is one past the end
    assert_eq!(ctx.state().anchor_index, 3);
    ctx.set_anchor(u32::MAX);
    assert_eq!(ctx.state().anchor_index, 3);
}

#[test]
fn read_range_clips_to_the_buffer() {
    let mut ctx = JdContext::new().expect("jd_init failed");
    ctx.press_key(b'j');

    let mut buf = [Candidate::default(); 3];
    assert_eq!(ctx.read_range(0, &mut buf), 3);
    assert!(!buf[2].value().is_empty());

    // Past the end yields nothing and leaves the buffer alone.
    let total = ctx.state().options_count;
    assert_eq!(ctx.read_range(total, &mut buf), 0);
    assert_eq!(ctx.read_range(0, &mut []), 0);
}

#[test]
fn reads_return_nothing_without_a_composition() {
    let mut ctx = JdContext::new().expect("jd_init failed");
    assert_eq!(ctx.state().options_count, 0);
    assert!(ctx.candidates(0, 9).is_empty());

    ctx.press_key(b'a');
    ctx.press_key(b' '); // commits, ending the composition
    assert_eq!(ctx.state().options_count, 0);
    assert!(ctx.candidates(0, 9).is_empty());
}

#[test]
fn punctuation_auto_commits() {
    let mut ctx = JdContext::new().expect("jd_init failed");

    // '.' is a single-candidate normal mapping: straight to 。
    ctx.press_key(b'.');
    assert_eq!(ctx.commit().unwrap().to_string(), "。");
    assert_eq!(ctx.state().options_count, 0);
}

#[test]
fn hints_are_inline_and_bounded() {
    let mut ctx = JdContext::new().expect("jd_init failed");
    ctx.press_key(b'j');

    let window = ctx.candidates(0, 32);
    for c in &window {
        if let Some(hint) = c.hint() {
            assert!(!hint.is_empty());
            assert!(
                hint.len() < jd::HINT_CAP,
                "hint {hint:?} overflows the inline array"
            );
        }
    }
    // The first candidate of a fully-typed code needs no further keys.
    assert!(window.iter().any(|c| c.hint().is_none()));
}

#[test]
fn candidates_are_send() {
    // Values point at immortal read-only data, so a list can cross threads.
    let mut ctx = JdContext::new().expect("jd_init failed");
    ctx.press_key(b'b');
    let held = ctx.candidates(0, 4);
    let expected: Vec<String> = held.iter().map(|c| c.value().to_owned()).collect();

    let joined = std::thread::spawn(move || {
        held.iter()
            .map(|c| c.value().to_owned())
            .collect::<Vec<_>>()
    })
    .join()
    .unwrap();

    assert_eq!(joined, expected);
}

#[test]
fn backspace_after_press_does_not_crash() {
    let mut ctx = JdContext::new().expect("jd_init failed");
    ctx.press_key(b'a');
    ctx.backspace();
    assert!(ctx.commit().is_none());
}

// ---- user dictionary --------------------------------------------------------

fn phrase_dict(text: &str) -> (&'static UserDict, jd::UserDictReport) {
    let (dict, report) = UserDict::build(text, 0).expect("build user dict");
    (dict.leak(), report)
}

#[test]
fn user_phrases_lead_the_built_in_candidates_on_a_shared_code() {
    // 'b' → 不 in the built-in tables; the user adds a word on the same code
    // and repeats a built-in one, which is dropped.
    let (dict, report) = phrase_dict("测试词\tb\n不\tb\n");
    assert_eq!(report.entries, 1);
    assert_eq!(report.dropped, 1);
    assert_eq!(report.dropped_lines, vec![2]);
    assert_eq!(dict.entries(), 1);

    let mut ctx = JdContext::with_user_dict(dict).expect("jd_init failed");
    ctx.press_key(b'b');
    let window = ctx.candidates(0, 2);
    assert_eq!(window[0].value(), "测试词");
    assert_eq!(window[1].value(), "不");

    // The user word is what space commits, and the pointer it hands back
    // stays valid across later calls (the dictionary is 'static).
    ctx.press_key(b' ');
    let commit = ctx.commit().unwrap();
    ctx.press_key(b'z');
    ctx.reset();
    assert_eq!(commit.to_string(), "测试词");

    // A plain context is unaffected.
    let mut plain = JdContext::new().expect("jd_init failed");
    plain.press_key(b'b');
    assert_eq!(plain.candidates(0, 1)[0].value(), "不");
}

#[test]
fn a_user_only_code_composes_with_hints_and_auto_commits() {
    let (dict, _) = phrase_dict("键道\tzzzzzz\n键道输入法\tzzzzza\n");
    let mut ctx = JdContext::with_user_dict(dict).expect("jd_init failed");

    for byte in *b"zzzzz" {
        ctx.press_key(byte);
    }
    assert!(ctx.commit().is_none());
    let window = ctx.candidates(0, 4);
    assert_eq!(window.len(), 2);
    assert_eq!(
        (window[0].value(), window[0].hint()),
        ("键道输入法", Some("a"))
    );
    assert_eq!((window[1].value(), window[1].hint()), ("键道", Some("z")));

    ctx.press_key(b'z');
    assert_eq!(ctx.commit().unwrap().to_string(), "键道");
    assert_eq!(ctx.state().options_count, 0);
}

#[test]
fn build_errors_name_the_line() {
    let err = UserDict::build("好\thz\nno tab\n", 0).unwrap_err();
    assert_eq!(err.status, UserDictStatus::MalformedLine);
    assert_eq!(err.line, 2);
    assert_eq!(err.to_string(), "line 2: expected `value<TAB>keys`");

    let err = UserDict::build("好\tHZ\n", 0).unwrap_err();
    assert_eq!(err.status, UserDictStatus::BadKeys);
    assert_eq!(err.line, 1);

    let err = UserDict::build("\thz\n", 0).unwrap_err();
    assert_eq!(err.status, UserDictStatus::BadValue);
}

#[test]
fn dropped_lines_are_listed_in_order() {
    // Lines 1 and 5 repeat built-in words; line 4 repeats line 3 exactly.
    let (_, report) = UserDict::build(
        "不\tb\n# comment\n测试词\tb\n测试词\tb\n好\thz\n键道\tzzzzzz\n",
        0,
    )
    .expect("build");
    assert_eq!(report.entries, 2);
    assert_eq!(report.dropped, 3);
    assert_eq!(report.dropped_lines, vec![1, 4, 5]);
}

#[test]
fn cached_blobs_round_trip_and_corruption_is_caught() {
    // "zzzzzz" is free in the built-in tables, so the phrase is kept.
    let tag = 0x0123_4567_89ab_cdef_u64;
    let (dict, report) = UserDict::build("# comment\n键道\tzzzzzz\n", tag).expect("build");
    assert_eq!(report.entries, 1);
    assert_eq!(dict.entries(), 1);
    assert_eq!(dict.source_tag(), tag);
    let bytes = dict.as_bytes().to_vec();
    assert!(!bytes.is_empty());

    // The tag and the count survive the trip through the cache.
    let again = UserDict::from_blob(&bytes).expect("from_blob");
    assert_eq!(again.as_bytes(), &bytes[..]);
    assert_eq!(again.source_tag(), tag);
    assert_eq!(again.entries(), 1);

    // The ABI copies into aligned storage, so an unaligned source is fine.
    let mut shifted = vec![0u8];
    shifted.extend_from_slice(&bytes);
    assert!(UserDict::from_blob(&shifted[1..]).is_ok());

    let err = UserDict::from_blob(&bytes[..bytes.len() - 1]).unwrap_err();
    assert_eq!(err.status, UserDictStatus::Corrupt);
    assert!(!err.status.is_line_error());

    // The built-in dictionary fingerprint lives in the header.
    let mut stale = bytes.clone();
    stale[12] ^= 0xFF;
    let err = UserDict::from_blob(&stale).unwrap_err();
    assert_eq!(err.status, UserDictStatus::Stale);

    assert_eq!(
        UserDict::from_blob(b"").unwrap_err().status,
        UserDictStatus::Corrupt
    );
}

#[test]
fn an_empty_dictionary_is_valid_and_inert() {
    let (dict, report) = phrase_dict("");
    assert_eq!(report.entries, 0);
    let mut ctx = JdContext::with_user_dict(dict).expect("jd_init failed");
    let mut plain = JdContext::new().expect("jd_init failed");
    ctx.press_key(b'a');
    plain.press_key(b'a');
    assert_eq!(ctx.state(), plain.state());
    assert_eq!(ctx.candidates(0, 9), plain.candidates(0, 9));
}

#[test]
fn a_static_blob_is_used_in_place_and_check_peeks_without_taking_over() {
    let tag = 0xfeed_u64;
    let (dict, _) = UserDict::build("键道\tzzzzzz\n", tag).expect("build");
    let cached = dict.as_bytes().to_vec();

    // Peek: the tag and count come back from any slice, aligned or not.
    let info = UserDict::check(&cached).expect("check");
    assert_eq!((info.source_tag, info.entries), (tag, 1));
    let mut shifted = vec![0u8];
    shifted.extend_from_slice(&cached);
    assert_eq!(
        UserDict::check(&shifted[1..]).expect("check unaligned"),
        info
    );

    // Host-owned, aligned, process-lifetime memory — what a leaked memory
    // map of the cache file is — is handed to the engine without a copy.
    let storage: &'static mut [u32] =
        Box::leak(vec![0u32; cached.len().div_ceil(4)].into_boxed_slice());
    let bytes: &'static mut [u8] =
        unsafe { std::slice::from_raw_parts_mut(storage.as_mut_ptr().cast::<u8>(), cached.len()) };
    bytes.copy_from_slice(&cached);
    let bytes: &'static [u8] = bytes;
    let dict = UserDict::from_static_blob(bytes).expect("from_static_blob");
    assert_eq!(dict.as_bytes().as_ptr(), bytes.as_ptr(), "no copy");
    assert_eq!(dict.source_tag(), tag);

    let mut ctx = JdContext::with_user_dict(dict.leak()).expect("jd_init failed");
    for byte in *b"zzzzzz" {
        ctx.press_key(byte);
    }
    assert_eq!(ctx.commit().unwrap().to_string(), "键道");

    // A misaligned static slice is refused rather than read in place.
    let leaked: &'static [u8] = Box::leak(shifted.into_boxed_slice());
    let err = UserDict::from_static_blob(&leaked[1..]).unwrap_err();
    assert_eq!(err.status, UserDictStatus::Misaligned);
}
