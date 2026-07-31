//! Integration tests against the real libjd (linked by build.rs). These run
//! headless, so they double as the CI smoke test for the FFI surface: the ABI
//! layout matches, the trie blob loads, contexts are independent, and reads
//! never disturb the commit anchor.

use jd::{Candidate, JdContext};

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
            assert!(hint.len() < jd::HINT_CAP, "hint {hint:?} overflows the inline array");
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
        held.iter().map(|c| c.value().to_owned()).collect::<Vec<_>>()
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
