use ime_jd::jd::{JdContext, PAGE_SIZE};

#[test]
fn two_contexts_are_independent() {
    let mut a = JdContext::new(PAGE_SIZE);
    let mut b = JdContext::new(PAGE_SIZE);

    let ra = a.press_key(b'a');
    let rb = b.press_key(b'a');

    assert_eq!(ra.options.len(), rb.options.len());
    assert_eq!(ra.options_count, rb.options_count);
    assert_eq!(ra.total_pages, rb.total_pages);

    a.reset();
    drop(a);

    // After dropping `a`, `b` is still healthy.
    let rb2 = b.press_key(b'b');
    let _ = rb2;
}

#[test]
fn press_key_returns_well_formed_result() {
    let mut ctx = JdContext::new(PAGE_SIZE);

    let r = ctx.press_key(b'a');

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
}

#[test]
fn backspace_after_press_does_not_crash() {
    let mut ctx = JdContext::new(PAGE_SIZE);
    ctx.press_key(b'a');
    let _ = ctx.backspace();
}
