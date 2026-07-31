# jd (Rust bindings)

Safe Rust bindings for the libjd core engine, shared by the `cli/` and `windows/` frontends as a plain Cargo path dependency:

```toml
[dependencies]
jd = { path = "../bindings/rust" }
```

## Usage

```rust
use std::fmt::Write;

use jd::{Candidate, JdContext};

/// Candidates drawn at once — a frontend choice. The engine has no page concept.
const PAGE: u32 = 9;

fn draw(window: &[Candidate]) {
    for (i, c) in window.iter().enumerate() {
        match c.hint() {
            Some(hint) => println!("{}. {} 〔{hint}〕", i + 1, c.value()),
            None => println!("{}. {}", i + 1, c.value()),
        }
    }
}

fn main() {
    let mut ctx = JdContext::new().expect("jd_init failed");
    let mut typed = String::new();

    // Feed one ASCII byte at a time. A keystroke may commit text, may open or
    // extend a candidate list, or both (when the key restarts from the root).
    for byte in *b"nk" {
        ctx.press_key(byte);
        if let Some(commit) = ctx.commit() {
            write!(typed, "{commit}").unwrap(); // Display joins the segments
        }
    }
    println!("{} candidates", ctx.state().options_count); // 330

    // Read the window you actually draw. Reads are pure — they never change
    // what the engine's own commits resolve to — so prefetch freely.
    let mut start = 0;
    draw(&ctx.candidates(start, PAGE)); // 1. 泥   2. 尼 〔a〕   …

    // Turning a page: point the anchor at the first visible candidate, so that
    // space — and every other commit the engine makes on its own — picks
    // something that is on screen.
    if start + PAGE < ctx.state().options_count {
        start += PAGE;
        ctx.set_anchor(start);
        draw(&ctx.candidates(start, PAGE)); // 1. 南柯梦 〔m〕   …
    }

    // Space commits the anchor candidate and ends the composition.
    ctx.press_key(b' ');
    write!(typed, "{}", ctx.commit().unwrap()).unwrap();

    println!("typed: {typed}"); // 南柯梦
}
```

Committing a candidate the user clicked needs no engine call at all — `c.value()` is `&'static str`, so insert it and then `ctx.reset()`.

For an append-only candidate strip, use `extend_candidates` instead of `candidates`:

```rust
let mut strip: Vec<Candidate> = Vec::new();
// ... on scroll, pull the next window in:
ctx.extend_candidates(strip.len() as u32, PAGE, &mut strip);
```

## Design

- **Nothing is copied defensively, because nothing can dangle.** A candidate's `value` and a commit's segments point into libjd's embedded dictionary blob — read-only data that lives for the whole process — and a candidate's `hint` is inline bytes. That makes `Candidate` `Copy`, `Send`, and its text `&'static str`, so candidate lists can be kept, moved between threads, and rendered lazily with no allocation.
- **Candidates are addressed by flat index.** `read_range` fills your own buffer and `extend_candidates` appends onto a `Vec` — the natural shape for a candidate strip. Reads are pure: they never change what the engine's automatic commits resolve to, so prefetch freely, and call `set_anchor` when the user's view moves.
- **`&mut self` statically enforces the single-thread contract.** A single `JdContext` must not be called concurrently; distinct contexts are fully independent.
- **`check_abi` runs once per process**, comparing this crate's hand-written `#[repr(C)]` declarations against `jd_abi_layout`. A silent drift would corrupt memory.
- **Linking is owned by this crate's build.rs** (`links = "jd"`): a prebuilt bundle pointed at by `LIBJD_PATH` takes precedence; otherwise it builds `core/` with zig. Dependents' build scripts can read the library directory and chosen linkage from `DEP_JD_LIBDIR` / `DEP_JD_LINKAGE` (the CLI uses these to emit an rpath for dynamically-linked dev builds).

## Tests

```sh
cargo test
```

The integration tests link the real dictionary and cover the FFI smoke contract, context independence, candidate retention across later engine calls, `Send`-ness, window clipping, and the anchor's independence from reads.
