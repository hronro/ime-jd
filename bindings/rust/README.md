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

### User dictionary

Phrases of the user's own are compiled into a `UserDict` once and merged into every candidate list, user phrases first on a code they share with a built-in word:

```rust
use jd::{JdContext, UserDict};

// `value<TAB>keys` lines, the format of core/tables/*.txt. Build once, with a
// tag of your choosing that identifies this version of the phrases …
let (dict, report) = UserDict::build("键道输入法\tjdefi\n", phrases_mtime)?;
eprintln!("{} phrases, {} duplicates dropped", report.entries, report.dropped);
for line in &report.dropped_lines {
    eprintln!("line {line} was dropped"); // flag it in a GUI, say
}
std::fs::write(cache_path, dict.as_bytes())?; // … cache the blob …

// … and on later launches wrap the cached bytes instead of re-parsing text.
let dict = match UserDict::from_blob(&std::fs::read(cache_path)?) {
    Ok(dict) if dict.source_tag() == phrases_mtime => dict,
    _ => rebuild_from_phrases()?, // phrases changed, Stale after a library update, or Corrupt
};

// The engine reads the blob in place for the context's lifetime and
// candidates keep pointing into it, so the context takes `&'static UserDict`.
let mut ctx = JdContext::with_user_dict(dict.leak())?;
```

**Performance tip: memory-map the cache.** A file mapping is page-aligned, sits at a fixed address, costs no copy, and its pages are shared with every other process that maps the same file — which is exactly what the engine wants. Peek at the tag first, and only leak the mapping once you know you will use it, so a rebuild can replace the file:

```rust
let file = std::fs::File::open(cache_path)?;
let map = unsafe { memmap2::Mmap::map(&file)? }; // the file must not change while mapped
let dict = match UserDict::check(&map) {
    Ok(info) if info.source_tag == phrases_mtime => {
        UserDict::from_static_blob(Box::leak(Box::new(map)))? // no copy; validated
    }
    _ => rebuild_from_phrases()?, // the mapping is dropped first
};
```

Map the text file too when rebuilding — `build` only reads it, and `std::str::from_utf8(&map)` costs one validation pass and no copy.

To change dictionaries, build the new one and create a new context with it; the old context goes away with the old dictionary.

For an append-only candidate strip, use `extend_candidates` instead of `candidates`:

```rust
let mut strip: Vec<Candidate> = Vec::new();
// ... on scroll, pull the next window in:
ctx.extend_candidates(strip.len() as u32, PAGE, &mut strip);
```

## Design

- **Nothing is copied defensively, because nothing can dangle.** A candidate's `value` and a commit's segments point into a dictionary blob that lives for the rest of the process — libjd's embedded dictionary, or the `&'static UserDict` the context was created with — and a candidate's `hint` is inline bytes. That makes `Candidate` `Copy`, `Send`, and its text `&'static str`, so candidate lists can be kept, moved between threads, and rendered lazily with no allocation.
- **A user dictionary is built once and cached as bytes.** `UserDict::build` runs the engine's builder (validation, sorting, deduplication against the built-in tables) into aligned storage and reports the dropped lines; `from_blob` copies cached bytes into aligned storage and `from_static_blob` takes process-lifetime memory such as a leaked memory map as is. Both validate exactly as `jd_init` would, reporting `Stale` after a library update so the host rebuilds from its persisted phrases; `check` reads a blob's `source_tag` and phrase count first so the host can tell whether the phrases changed before committing to it.
- **Candidates are addressed by flat index.** `read_range` fills your own buffer and `extend_candidates` appends onto a `Vec` — the natural shape for a candidate strip. Reads are pure: they never change what the engine's automatic commits resolve to, so prefetch freely, and call `set_anchor` when the user's view moves.
- **`&mut self` statically enforces the single-thread contract.** A single `JdContext` must not be called concurrently; distinct contexts are fully independent.
- **`check_abi` runs once per process**, comparing this crate's hand-written `#[repr(C)]` declarations against `jd_abi_layout`. A silent drift would corrupt memory.
- **Linking is owned by this crate's build.rs** (`links = "jd"`): a prebuilt bundle pointed at by `LIBJD_PATH` takes precedence; otherwise it builds `core/` with zig. Dependents' build scripts can read the library directory and chosen linkage from `DEP_JD_LIBDIR` / `DEP_JD_LINKAGE` (the CLI uses these to emit an rpath for dynamically-linked dev builds).

## Tests

```sh
cargo test
```

The integration tests link the real dictionary and cover the FFI smoke contract, context independence, candidate retention across later engine calls, `Send`-ness, window clipping, the anchor's independence from reads, and the user dictionary (merge order, user-only codes, build errors, cached-blob round trips).
