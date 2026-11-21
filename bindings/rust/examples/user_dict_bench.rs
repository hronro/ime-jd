//! Cost model of the user dictionary against the real libjd: building a blob
//! from text (what re-generating on every launch would cost) versus
//! validating a cached blob (what `jd_init` costs), at sizes up to the cap —
//! plus hashing the text for the cache's tag, and what a dictionary that
//! size costs a reverse lookup.
//!
//!     cargo run --release --example user_dict_bench
//!
//! Phrases are synthetic but shaped like real ones: 2–4 CJK characters on a
//! 4–6 key code. Codes collide with built-in codes about as often as real
//! user phrases do; values never duplicate built-in words, so nothing is
//! dropped and every phrase is a trie walk plus a sort key.

use std::hint::black_box;
use std::time::{Duration, Instant};

use jd::{JdContext, UserDict};

fn lcg(state: &mut u64) -> u64 {
    *state = state
        .wrapping_mul(6364136223846793005)
        .wrapping_add(1442695040888963407);
    *state >> 33
}

fn phrases(n: usize, seed: u64) -> String {
    let mut s = seed;
    let mut out = String::new();
    for _ in 0..n {
        let chars = 2 + (lcg(&mut s) % 3) as usize;
        for _ in 0..chars {
            let cp = 0x4E00 + (lcg(&mut s) % (0x9FA5 - 0x4E00)) as u32;
            out.push(char::from_u32(cp).unwrap());
        }
        out.push('\t');
        let keys = 4 + (lcg(&mut s) % 3) as usize;
        for _ in 0..keys {
            out.push((b'a' + (lcg(&mut s) % 26) as u8) as char);
        }
        out.push('\n');
    }
    out
}

/// Median of `iters` timed runs.
fn median<T>(iters: usize, mut f: impl FnMut() -> T) -> Duration {
    let mut times: Vec<Duration> = (0..iters)
        .map(|_| {
            let t = Instant::now();
            black_box(f());
            t.elapsed()
        })
        .collect();
    times.sort();
    times[times.len() / 2]
}

fn us(d: Duration) -> f64 {
    d.as_secs_f64() * 1e6
}

fn main() {
    println!(
        "{:>7} {:>8} {:>8} | {:>9} {:>10} {:>11} {:>9} | {:>10} {:>10} | {:>9}",
        "phrases",
        "text",
        "blob",
        "hash",
        "build",
        "from_blob",
        "copy",
        "init+dict",
        "init plain",
        "lookup"
    );
    println!(
        "{:>7} {:>8} {:>8} | {:>9} {:>10} {:>11} {:>9} | {:>10} {:>10} | {:>9}",
        "", "KiB", "KiB", "µs", "µs", "µs", "µs", "µs", "µs", "µs"
    );
    for &n in &[1_000usize, 10_000, 100_000, UserDict::MAX_ENTRIES as usize] {
        let iters = if n > 100_000 { 21 } else { 101 };
        let text = phrases(n, 0x5EED + n as u64);
        let (dict, report) = UserDict::build(&text, 0).expect("build");
        assert_eq!(report.entries as usize, n, "unexpected drops");
        let bytes = dict.as_bytes().to_vec();

        let hash = median(iters, || UserDict::hash(text.as_bytes()));
        let build = median(iters, || UserDict::build(&text, 0).unwrap());
        let from_blob = median(iters, || UserDict::from_blob(&bytes).unwrap());
        let copy = median(iters, || bytes.clone());

        let leaked: &'static UserDict = dict.leak();
        let init_dict = median(iters, || JdContext::with_user_dict(leaked).unwrap());
        let init_plain = median(iters, || JdContext::new().unwrap());
        // A two-character word no phrase holds: the user half of a reverse
        // lookup scans every phrase of that length.
        let ctx = JdContext::with_user_dict(leaked).unwrap();
        let lookup = median(iters, || ctx.lookup_codes("龘龘"));

        println!(
            "{:>7} {:>8.1} {:>8.1} | {:>9.1} {:>10.1} {:>11.1} {:>9.1} | {:>10.1} {:>10.1} | {:>9.1}",
            n,
            text.len() as f64 / 1024.0,
            bytes.len() as f64 / 1024.0,
            us(hash),
            us(build),
            us(from_blob),
            us(copy),
            us(init_dict),
            us(init_plain),
            us(lookup),
        );
    }
    println!();
    println!("hash       = jd_user_dict_hash over the text (the cache's source tag)");
    println!(
        "build      = jd_user_dict_blob_bound + jd_user_dict_build (parse, sort, dedupe against the built-in trie)"
    );
    println!(
        "from_blob  = copy into aligned storage + jd_user_dict_check (the full validation jd_init runs)"
    );
    println!("copy       = the memcpy alone, so from_blob - copy ≈ validation");
    println!("init+dict  = jd_init with the blob (validation + the one per-context allocation)");
    println!("init plain = jd_init without a user dictionary");
    println!("lookup     = jd_lookup_codes of a two-character word no phrase holds");
}
