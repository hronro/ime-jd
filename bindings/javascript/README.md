# jd (WebAssembly / JavaScript bindings)

Ergonomic JavaScript wrapper for the libjd core engine, driving the `wasm32-freestanding` reactor module the core builds (`core/zig-out/bin/jd.wasm`). It exposes the same engine as the Rust (`bindings/rust`) and Swift (`bindings/swift`) wrappers — you work with strings and plain objects, never pointers.

```js
import { JdModule } from "jd";

// Node: read the bytes; browser: pass a fetch() Response for streaming compile.
const wasm = await fetch(new URL("./jd.wasm", import.meta.url));
const jd = await JdModule.instantiate(wasm);

// Candidates drawn at once — a frontend choice. The engine has no page concept.
const PAGE = 9;

const draw = (window) =>
  window.forEach((c, i) =>
    console.log(c.hint ? `${i + 1}. ${c.value} 〔${c.hint}〕` : `${i + 1}. ${c.value}`),
  );

const engine = jd.createEngine();
try {
  let typed = "";

  // Feed one ASCII byte at a time. A keystroke may commit text, may open or
  // extend a candidate list, or both (when the key restarts from the root).
  for (const ch of "nk") {
    const state = engine.pressKey(ch.charCodeAt(0));
    if (state.commit) typed += state.commit;
  }
  console.log(engine.snapshot().optionsCount); // 330

  // Read the window you actually draw. Reads are pure — they never change what
  // the engine's own commits resolve to — so prefetch freely.
  let start = 0;
  draw(engine.readRange(start, PAGE)); // 1. 泥   2. 尼 〔a〕   …

  // Turning a page: point the anchor at the first visible candidate, so that
  // space — and every other commit the engine makes on its own — picks
  // something that is on screen.
  if (start + PAGE < engine.snapshot().optionsCount) {
    start += PAGE;
    engine.setAnchor(start);
    draw(engine.readRange(start, PAGE)); // 1. 南柯梦 〔m〕   …
  }

  // Space commits the anchor candidate and ends the composition.
  typed += engine.pressKey(" ".charCodeAt(0)).commit;
  console.log(typed); // 南柯梦
} finally {
  engine.dispose(); // or: using engine = jd.createEngine()
}
```

Committing a candidate the user clicked needs no engine call — insert `c.value` and then `engine.reset()`. For an append-only candidate strip, keep your own array and read `[loaded, loaded + PAGE)` as it scrolls.

## User dictionary

Phrases of the user's own are compiled into a `UserDict` once and merged into every candidate list, user phrases first on a code they share with a built-in word:

```js
// `value<TAB>keys` lines, the format of core/tables/*.txt. Build once, with a
// tag of your choosing that identifies this version of the phrases …
const { dict, report } = jd.buildUserDict("键道输入法\tjdefi\n", { sourceTag: phrasesRevision });
console.log(`${report.entries} phrases, ${report.dropped} duplicates dropped`);
for (const line of report.droppedLines) console.log(`line ${line} was dropped`);
await cache.put("user-dict", dict.bytes()); // … cache the blob (IndexedDB, say) …

// … and on later launches wrap the cached bytes instead of re-parsing text.
let dict;
try {
  dict = jd.loadUserDict(await cache.get("user-dict"));
  if (dict.sourceTag !== BigInt(phrasesRevision)) dict = rebuildFromPhrases(); // phrases changed
} catch (e) {
  dict = rebuildFromPhrases(); // UserDictError: stale after a library update, or corrupt
}

const engine = jd.createEngine({ userDict: dict });
// … dispose the engine before the dictionary; the engine reads the blob in place.
```

The blob is one block of the module's linear memory that the `UserDict` owns (`jd_alloc` / `jd_free` in the C ABI); a JS host cannot allocate inside linear memory itself, so the wrapper does it for you. `dispose()` refuses while an engine created with the dictionary is alive.

## Getting the `jd.wasm`

The wrapper does not embed the module — you provide it, exactly like `bindings/rust` links a prebuilt-or-zig-built libjd. Build it with

```sh
zig build -Dtarget=wasm32-freestanding -Doptimize=fast   # in core/
```

or download the `libjd-<ver>-wasm.wasm.tar.xz` release asset. `JdModule.instantiate` accepts wasm bytes (`BufferSource`), a compiled `WebAssembly.Module`, or a `fetch` `Response` (streaming, with an `arrayBuffer()` fallback).

## Design

- **Everything returned is an owned JS value.** JS strings have to be decoded out of linear memory regardless, so `Engine` does it eagerly for the commit and for each candidate in the window you asked for. Ask for the window you draw: `readRange(start, count)` is a pure read that never changes what the engine's automatic commits resolve to, so a candidate strip can prefetch freely and call `setAnchor` when the user's view moves.
- **Candidates are addressed by flat index**, not by page — there is no `pageSize`, and no remainder math to get wrong. `readRange` returns fewer than asked at the end of the list.
- **The wasm plumbing is hidden.** No export returns a struct by value, so there is no sret shim; state lives at the fixed address `jd_state_ptr(ctx)` returns, and larger `readRange` windows are decoded in chunks through the context's own scratch buffer (a JS host cannot allocate inside linear memory). The user-dictionary calls need host buffers in linear memory, which the wrapper takes from the module's own allocator (`jd_alloc` / `jd_free`). `JdModule.fromInstance` verifies the module's struct layout against this binding's hand-written offsets via `jd_abi_layout` and throws on a mismatch.
- **One module, many engines.** The embedded trie/punctuation tables are parsed once and shared read-only across every `Engine` of a `JdModule`; distinct engines have independent composition state. A single `Engine` must not be driven concurrently with itself.
- **`dispose()` / `Symbol.dispose`** release the context (`jd_deinit`); idempotent, and poisons the engine so later calls throw. JS has no deterministic destructor, so release is explicit (a `using` binding works).

The package is plain ES-module JavaScript (`src/index.js`) with hand-written TypeScript declarations (`src/index.d.ts`) — **no build step**; Node and bundlers consume the sources as-is, and TypeScript consumers get full types. The `0.0.0` version is a placeholder — the real project version lives in `core/build.zig.zon`.

## Tests

```sh
npm test              # pretest builds core to wasm, then `node --test`
npm run typecheck     # tsc validates index.d.ts against the test (dev dep)
```

`node --test` runs the plain-JS tests directly. They link the real dictionary and cover the FFI smoke contract, result ownership (retention across later calls), chunked reads larger than the scratch buffer, window clipping, the anchor's independence from reads, punctuation, context independence, the dispose lifecycle, and the user dictionary (merge order, user-only codes, build errors, cached-blob round trips, the dictionary-outlives-engines rule). Set `JD_WASM` to a prebuilt module to skip the zig build.
