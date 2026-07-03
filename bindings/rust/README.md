# jd (Rust bindings)

Safe Rust bindings for the libjd core engine, shared by the `cli/` and `windows/` frontends as a plain Cargo path dependency:

```toml
[dependencies]
jd = { path = "../bindings/rust" }
```

## Design

- **Every returned value is owned data.** The C API's pointers are only valid until the next `jd_*` call on the same context (see the pointer-lifetime contract in `core/docs/integration.md`); the wrapper copies `commit`, every candidate value, and every hint into `String`s before returning, so a `QueryResult` may be retained freely.
- **`&mut self` statically enforces the single-thread contract.** A single `JdContext` must not be called concurrently; distinct contexts are fully independent.
- **`visible_count`** is the one implementation of the "options visible on the current page" remainder math (`options_count` is the total across all pages, not the length of the current array) — frontends must not grow their own copies of this logic.
- **Linking is owned by this crate's build.rs** (`links = "jd"`): a prebuilt bundle pointed at by `LIBJD_PATH` takes precedence; otherwise it builds `core/` with zig. Dependents' build scripts can read the library directory and chosen linkage from `DEP_JD_LIBDIR` / `DEP_JD_LINKAGE` (the CLI uses these to emit an rpath for dynamically-linked dev builds).

## Tests

```sh
cargo test
```

The integration tests link the real dictionary and cover the FFI smoke contract, context independence, result ownership (retention across later engine calls), and pagination consistency.
