# jd (WebAssembly / JavaScript bindings)

Ergonomic JavaScript wrapper for the libjd core engine, driving the `wasm32-freestanding` reactor module the core builds (`core/zig-out/bin/jd.wasm`). It exposes the same engine as the Rust (`bindings/rust`) and Swift (`bindings/swift`) wrappers — you work with strings and plain objects, never pointers.

```js
import { JdModule } from "jd";

// Node: read the bytes; browser: pass a fetch() Response for streaming compile.
const wasm = await fetch(new URL("./jd.wasm", import.meta.url));
const jd = await JdModule.instantiate(wasm);

const engine = jd.createEngine(9); // page size (candidates per page)
try {
  engine.pressKey("a".charCodeAt(0)); // -> { options: [...], currentPage: 1, ... }
  const committed = engine.pressKey(" ".charCodeAt(0)); // -> { commit: "那", ... }
  console.log(committed.commit);
} finally {
  engine.dispose(); // or: using engine = jd.createEngine()
}
```

## Getting the `jd.wasm`

The wrapper does not embed the module — you provide it, exactly like `bindings/rust` links a prebuilt-or-zig-built libjd. Build it with

```sh
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseFast   # in core/
```

or download the `libjd-<ver>-wasm.wasm.tar.xz` release asset. `JdModule.instantiate` accepts wasm bytes (`BufferSource`), a compiled `WebAssembly.Module`, or a `fetch` `Response` (streaming, with an `arrayBuffer()` fallback).

## Design

- **Every returned value is owned data.** The C ABI's pointers are valid only until the next `jd_*` call on the same context (see the pointer-lifetime contract in `core/docs/integration.md`); `Engine` copies `commit` and every candidate `value`/`hint` into JS strings before returning, so a `QuerySnapshot` may be retained freely (load-bearing for pagination).
- **The wasm32 struct-return (sret) ABI is hidden.** `query_result` is a five-field struct, so the module returns it through a pointer argument; the wrapper passes the core's static `jd_wasm_result_ptr()` buffer and reads the fields back out of linear `memory`. Callers never see this.
- **`visibleCount`** is the one implementation of the "candidates visible on the current page" remainder math (`optionsCount` is the total across all pages, not the length of the current array) — don't reimplement it.
- **One module, many engines.** The embedded trie/punctuation tables are parsed once and shared read-only across every `Engine` of a `JdModule`; distinct engines have independent composition state. A single `Engine` must not be driven concurrently with itself.
- **`dispose()` / `Symbol.dispose`** release the context (`jd_deinit`); idempotent, and poisons the engine so later calls throw. JS has no deterministic destructor, so release is explicit (a `using` binding works).

The package is plain ES-module JavaScript (`src/index.js`) with hand-written TypeScript declarations (`src/index.d.ts`) — **no build step**; Node and bundlers consume the sources as-is, and TypeScript consumers get full types. The `0.0.0` version is a placeholder — the real project version lives in `core/build.zig.zon`.

## Tests

```sh
npm test              # pretest builds core to wasm, then `node --test`
npm run typecheck     # tsc validates index.d.ts against the test (dev dep)
```

`node --test` runs the plain-JS tests directly. They link the real dictionary and cover the FFI smoke contract, result ownership (retention across later calls), pagination consistency, punctuation, context independence, and the dispose lifecycle. Set `JD_WASM` to a prebuilt module to skip the zig build.
