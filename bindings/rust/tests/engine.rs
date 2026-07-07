//! Integration tests against the real libjd (linked by build.rs). These run
//! headless, so they double as the CI smoke test for the FFI surface: the
//! trie blob loads, contexts are independent, and results are well-formed
//! owned data.

use jd::JdContext;

const PAGE_SIZE: u8 = 4;

#[test]
fn loads_blob_and_returns_options() {
    let mut ctx = JdContext::new(PAGE_SIZE).expect("jd_init failed");

    // Press 'b' — expect at least one candidate (the dictionary has many
    // entries starting with 'b').
    let r1 = ctx.press_key(b'b');
    assert!(r1.options_count > 0, "no options for 'b'");
    let first = &r1.options[0].value;
    assert!(!first.is_empty(), "first option for 'b' was empty");

    // Press another key to advance — must still be non-empty.
    let r2 = ctx.press_key(b'a');
    assert!(
        r2.options_count > 0 || r2.commit.is_some(),
        "no options and no commit after 'ba'"
    );

    // Backspace returns us up; should not crash.
    let _ = ctx.backspace();
}

#[test]
fn two_contexts_are_independent() {
    let mut a = JdContext::new(PAGE_SIZE).expect("jd_init failed");
    let mut b = JdContext::new(PAGE_SIZE).expect("jd_init failed");

    let ra = a.press_key(b'a');
    let rb = b.press_key(b'a');

    assert_eq!(ra.options.len(), rb.options.len());
    assert_eq!(ra.options_count, rb.options_count);
    assert_eq!(ra.total_pages, rb.total_pages);

    a.reset();
    drop(a);

    // After dropping `a`, `b` is still healthy.
    let _ = b.press_key(b'b');
}

#[test]
fn press_key_returns_well_formed_result() {
    let mut ctx = JdContext::new(PAGE_SIZE).expect("jd_init failed");

    let r = ctx.press_key(b'a');

    // Three valid shapes: candidates, committed, or empty. Size fields must
    // be internally consistent — that's what we verify.
    if !r.options.is_empty() {
        assert!(r.total_pages >= 1);
        assert!(r.current_page >= 1 && r.current_page <= r.total_pages);
        assert!(r.options_count as usize >= r.options.len());
        assert_eq!(
            r.options.len(),
            jd::visible_count(r.options_count, r.current_page, r.total_pages, PAGE_SIZE),
        );
    } else {
        assert_eq!(r.total_pages, 0);
        assert_eq!(r.current_page, 0);
        assert_eq!(r.options_count, 0);
    }
}

#[test]
fn results_are_owned_and_survive_later_calls() {
    // The core's pointers are only valid until the next call on the same
    // context; the wrapper's whole job is to make retention safe. Hold a
    // result across further calls and check it hasn't changed.
    let mut ctx = JdContext::new(PAGE_SIZE).expect("jd_init failed");

    let before = ctx.press_key(b'b');
    let first_before = before.options.first().cloned();

    // Mutate engine state repeatedly (each call invalidates the C pointers
    // the snapshot was copied from).
    let _ = ctx.press_key(b'a');
    let _ = ctx.backspace();
    ctx.reset();
    let _ = ctx.press_key(b'z');

    assert_eq!(before.options.first().cloned(), first_before);
}

#[test]
fn jump_to_page_lands_on_requested_page() {
    let mut ctx = JdContext::new(PAGE_SIZE).expect("jd_init failed");

    let r = ctx.press_key(b'b');
    if r.total_pages < 2 {
        // Dictionary-shape dependent; nothing to paginate.
        return;
    }

    let r2 = ctx.jump_to_page(2);
    assert_eq!(r2.current_page, 2);
    assert_eq!(
        r2.options.len(),
        jd::visible_count(r2.options_count, r2.current_page, r2.total_pages, PAGE_SIZE),
    );

    // Out-of-range jump is a no-op that stays on the current page.
    let r3 = ctx.jump_to_page(r2.total_pages + 1);
    assert_eq!(r3.current_page, 2);
}

#[test]
fn page_size_zero_is_rejected() {
    // A zero page size would divide by zero inside the core's paginators
    // (UB in the ReleaseFast builds that ship); jd_init rejects it with
    // NULL, which this safe constructor must surface as an error.
    assert!(JdContext::new(0).is_err());
}

#[test]
fn backspace_after_press_does_not_crash() {
    let mut ctx = JdContext::new(PAGE_SIZE).expect("jd_init failed");
    ctx.press_key(b'a');
    let _ = ctx.backspace();
}
