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
eprintln!("{} phrases, {} bad lines skipped, {} duplicates dropped, {} on shared codes", report.entries, report.invalid, report.dropped, report.shared);
for note in &report.notes {
    eprintln!("{note}"); // "line 7: dropped, repeats line 3", "line 9: skipped, expected `value<TAB>keys`" — flag the row in a GUI, say
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

**Performance tip: memory-map the cache.** A file mapping is page-aligned, sits at a fixed address, costs no copy, and its pages are shared with every other process that maps the same file — which is exactly what the engine wants. Peek at the tag first, so a mapping you will not use is dropped and a rebuild can replace the file:

```rust
let file = std::fs::File::open(cache_path)?;
let map = unsafe { memmap2::Mmap::map(&file)? }; // the file must not change while mapped
let dict = match UserDict::check(&map) {
    Ok(info) if info.source_tag == phrases_mtime => {
        unsafe { UserDict::from_mapped_blob(map)? } // no copy; validated
    }
    _ => rebuild_from_phrases()?, // the mapping is dropped first
};
```

`from_mapped_blob` keeps the map and unmaps it when the dictionary is dropped, which is what a host that changes dictionaries wants; `from_static_blob` takes a map leaked for the rest of the process.

Map the text file too when rebuilding — `build` only reads it, and `std::str::from_utf8(&map)` costs one validation pass and no copy.

To change dictionaries, build the new one and create a new context with it; the old context goes away with the old dictionary.

### Your own dictionary

The context types from libjd's embedded 键道 dictionary unless you give it your own: a `Dict`, built from text of the same `value<TAB>keys` format by the same code that builds the embedded one, so it types the same way and as fast, at up to 16 777 215 entries. A user dictionary then sits on top of it — build it, wrap it and check it with the `_on` functions:

```rust
use jd::{Dict, JdContext, UserDict};

let (dict, report) = Dict::build(&std::fs::read_to_string("my-tables.txt")?, tables_hash)?;
std::fs::write(dict_cache, dict.as_bytes())?; // a build is about 0.3 s per million entries: cache it
let dict = dict.leak();
let (phrases, _) = UserDict::build_on(dict, "键道输入法\tjdefi\n", phrases_hash)?;
let mut ctx = JdContext::with_dict(dict, Some(phrases.leak()))?;
```

Wrap a cached dictionary with `Dict::from_mapped_blob` (or `from_blob` / `from_static_blob`): a large one is many megabytes, read in place. `Dict::empty()` has no codes at all, for typing from a user dictionary alone. A user dictionary built on one dictionary is `Stale` on any other, embedded one included, and `JdContext::with_dict` refuses the pair (`InitError::StaleUserDict`).

**libjd-engine.** `default-features = false` drops the `builtin-dict` feature, and the crate builds and links libjd without its embedded dictionary — over 95% smaller. Every context then needs a `Dict`: `JdContext::new()` fails with `InitError::NoBuiltinDict`, and `Dict::builtin_entries()` is 0. With `LIBJD_PATH`, it is whichever library that folder holds.

### Reverse lookup

`lookup_codes` goes the other way — the codes a value is typed with, from the built-in tables and the context's user dictionary, and where the value sits on each:

```rust
for code in ctx.lookup_codes("着") {
    // "o" #1 — 着 is the second candidate on `o` — then "fe" #0, "qe" #0, …
    println!("{} #{}{}", code.keys(), code.index(), if code.is_user() { " (mine)" } else { "" });
}
```

It is a pure read, so it can run mid-composition. `lookup_codes_into` writes into your own `&mut [Code]` instead and returns the total, which may exceed the buffer.

For an append-only candidate strip, use `extend_candidates` instead of `candidates`:

```rust
let mut strip: Vec<Candidate> = Vec::new();
// ... on scroll, pull the next window in:
ctx.extend_candidates(strip.len() as u32, PAGE, &mut strip);
```

## Design

- **Nothing is copied defensively, because nothing can dangle.** A candidate's `value` and a commit's segments point into a dictionary blob that lives for the rest of the process — libjd's embedded dictionary, or the `&'static UserDict` the context was created with — and a candidate's `hint` is inline bytes. That makes `Candidate` `Copy`, `Send`, and its text `&'static str`, so candidate lists can be kept, moved between threads, and rendered lazily with no allocation.
- **A user dictionary is built once and cached as bytes.** `UserDict::build` runs the engine's builder (validation, sorting, deduplication against the dictionary beneath) into aligned storage and returns the engine's notes — which lines were skipped because they do not parse (one typo never fails the build), which were dropped and what they repeat, and which kept phrases sit on a code a built-in word or another phrase already uses (重码); `from_blob` copies cached bytes into aligned storage and `from_static_blob` takes process-lifetime memory such as a leaked memory map as is. Both validate exactly as `jd_init` would, reporting `Stale` after a library update so the host rebuilds from its persisted phrases; `check` reads a blob's `source_tag` and phrase count first so the host can tell whether the phrases changed before committing to it. `UserDict::hash` is libjd's content hash (`jd_user_dict_hash`), for a `source_tag` that follows the text: the same bytes hash the same on every platform and in every release.
- **Candidates are addressed by flat index.** `read_range` fills your own buffer and `extend_candidates` appends onto a `Vec` — the natural shape for a candidate strip. Reads are pure: they never change what the engine's automatic commits resolve to, so prefetch freely, and call `set_anchor` when the user's view moves.
- **`&mut self` statically enforces the single-thread contract.** A single `JdContext` must not be called concurrently; distinct contexts are fully independent.
- **`check_abi` runs once per process**, comparing this crate's hand-written `#[repr(C)]` declarations against `jd_abi_layout`. A silent drift would corrupt memory.
- **Linking is owned by this crate's build.rs** (`links = "jd"`): a prebuilt bundle pointed at by `LIBJD_PATH` takes precedence; otherwise it builds `core/` with zig. Either way a changed library is linked again at the next build: the script watches the core's sources when it builds them, and the `LIBJD_PATH` folder when it is given one — the folder rather than the files in it, since zig installs a build it has cached with the time that build was first made. Dependents' build scripts can read the library directory and chosen linkage from `DEP_JD_LIBDIR` / `DEP_JD_LINKAGE` (the CLI uses these to emit an rpath for dynamically-linked dev builds).

## Tests

```sh
cargo test
cargo test --no-default-features   # libjd-engine: tests/dict.rs alone
```

The integration tests link the real dictionary and cover the FFI smoke contract, context independence, candidate retention across later engine calls, `Send`-ness, window clipping, the anchor's independence from reads, reverse lookup (order, indices, short buffers, user phrases), and the user dictionary (merge order, user-only codes, build errors, cached-blob round trips).
