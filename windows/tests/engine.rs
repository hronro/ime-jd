use jd_ime::jd::ENGINE;

// All tests share one global engine. The internal Mutex serializes
// calls, but state from a previous test can leak into the next, so
// each test resets before doing anything observable.

#[test]
fn init_is_idempotent() {
    ENGINE.init(8);
    ENGINE.init(8);
}

#[test]
fn press_key_returns_well_formed_result() {
    ENGINE.init(8);
    ENGINE.reset();

    let r = ENGINE.press_key(b'a');

    // Three valid shapes: candidates, committed, or empty. Pointer/size
    // fields must be internally consistent — that's what we verify.
    if !r.options.is_empty() {
        assert!(r.total_pages >= 1);
        assert!(r.current_page >= 1 && r.current_page <= r.total_pages);
        assert!(r.options_count as usize >= r.options.len());
    } else {
        assert_eq!(r.total_pages, 0);
        assert_eq!(r.current_page, 0);
        assert_eq!(r.options_count, 0);
    }

    ENGINE.reset();
}

#[test]
fn backspace_after_press_does_not_crash() {
    ENGINE.init(8);
    ENGINE.reset();
    ENGINE.press_key(b'a');
    let _ = ENGINE.backspace();
    ENGINE.reset();
}
