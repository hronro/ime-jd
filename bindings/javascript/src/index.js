/**
 * JavaScript bindings for libjd, the 键道 (jiàndào) input-method core.
 *
 * The core builds to a self-contained `wasm32-freestanding` reactor module
 * (`core/zig-out/bin/jd.wasm`, or the `libjd-<ver>-wasm.wasm.tar.xz` release
 * asset) that exports the same C ABI as the native libraries — see
 * `core/include/jd.h` and `core/docs/integration.md`. This module wraps that
 * ABI so callers work with strings and plain objects instead of pointers.
 *
 * This is plain ES-module JavaScript; the public types live in the sibling
 * `index.d.ts`, so there is no build step. Two ABI details are hidden here so
 * no consumer has to know them:
 *
 *  1. Struct returns. `query_result` has five fields, so the wasm32 C ABI
 *     returns it through an implicit struct-return pointer (sret): each
 *     result-returning `jd_*` export is `fn(sret_ptr, ...args) void`. The
 *     module exports `jd_wasm_result_ptr()` — the address of one static result
 *     buffer — which we pass as that pointer on every call and read the five
 *     u32 fields back out of linear memory.
 *  2. Borrowed pointers. Every pointer a result carries (`commit`, each
 *     candidate `value`/`hint`) is valid only until the next `jd_*` call on the
 *     same context. `#readSnapshot` copies them all into JS strings before
 *     returning, so a snapshot may be retained across later calls (load-bearing
 *     for candidate pagination), exactly like the Rust and Swift bindings.
 *
 * One Engine must not be driven from two things at once (the C contract);
 * distinct engines are fully independent even when they share a module. This
 * mirrors `bindings/rust` and `bindings/swift`.
 */

// Shared UTF-8 decoder; `fatal: false` mirrors the lossy decode the Rust/Swift
// bindings use for the (always-valid) engine strings.
const decoder = new TextDecoder("utf-8", { fatal: false });

/** The empty / no-composition result (all `jd_*` calls with nothing in flight). */
export const EMPTY_SNAPSHOT = Object.freeze({
  commit: null,
  options: Object.freeze([]),
  optionsCount: 0,
  totalPages: 0,
  currentPage: 0,
});

/**
 * Number of candidates materialized in the current page's `options` array.
 *
 * The C ABI's `optionsCount` is the total across all pages, not the length of
 * the current array (see "Reading `query_result`" in
 * `core/docs/integration.md`): every non-last page is exactly `pageSize` long,
 * and the last page holds the remainder. Returns 0 for the empty / committed
 * shapes (`optionsCount === 0`) and for a degenerate `pageSize` of 0. This is
 * the single source of that remainder math — do not reimplement it.
 *
 * @param {number} optionsCount
 * @param {number} currentPage
 * @param {number} totalPages
 * @param {number} pageSize
 * @returns {number}
 */
export function visibleCount(optionsCount, currentPage, totalPages, pageSize) {
  if (optionsCount === 0 || pageSize === 0) return 0;
  if (currentPage === totalPages) {
    const rem = optionsCount % pageSize;
    return rem === 0 ? pageSize : rem;
  }
  return pageSize;
}

const REQUIRED_EXPORTS = [
  "memory",
  "jd_wasm_result_ptr",
  "jd_init",
  "jd_press_key",
  "jd_next_page",
  "jd_prev_page",
  "jd_jump_to_page",
  "jd_backspace",
  "jd_reset",
  "jd_deinit",
];

// query_result is 5 × u32 = 20 bytes; query_option is 2 pointers = 8 bytes.
// wasm32 pointers are 32-bit, so every field is a little-endian u32.
const COMMIT_OFF = 0;
const OPTIONS_OFF = 4;
const OPTIONS_COUNT_OFF = 8;
const TOTAL_PAGES_OFF = 12;
const CURRENT_PAGE_OFF = 16;
const OPTION_SIZE = 8;
const OPTION_HINT_OFF = 4;

function isResponseLike(source) {
  return (
    (typeof Response !== "undefined" && source instanceof Response) ||
    typeof source?.then === "function"
  );
}

/** Reads a NUL-terminated UTF-8 string out of `buffer` starting at `ptr`. */
function readCString(buffer, ptr) {
  const bytes = new Uint8Array(buffer);
  let end = ptr;
  // The engine always NUL-terminates; the length cap only guards against a
  // malformed module so a bad pointer can't spin off the end of memory.
  while (end < bytes.length && bytes[end] !== 0) end++;
  return decoder.decode(bytes.subarray(ptr, end));
}

async function instantiateResponse(source, imports) {
  const response = await source;
  if (typeof WebAssembly.instantiateStreaming === "function") {
    try {
      const result = await WebAssembly.instantiateStreaming(response, imports);
      return result.instance;
    } catch {
      // Some servers mislabel the MIME type, which makes instantiateStreaming
      // reject before it touches the body. Fall back to buffering the bytes.
    }
  }
  const bytes = await response.arrayBuffer();
  const result = await WebAssembly.instantiate(bytes, imports);
  return result.instance;
}

/**
 * A loaded libjd wasm module. Wraps one WebAssembly instance and mints Engine
 * contexts from it; the embedded trie and punctuation tables are parsed once on
 * first use and shared read-only across every engine of this module, so create
 * as many engines as you have independent input fields.
 */
export class JdModule {
  #exports;
  /** Address of the shared static `query_result` sret buffer (see file docs). */
  #resultPtr;

  /** @internal — use {@link JdModule.instantiate} or {@link JdModule.fromInstance}. */
  constructor(exports, resultPtr) {
    this.#exports = exports;
    this.#resultPtr = resultPtr;
  }

  /**
   * Instantiate from wasm bytes, a compiled module, or a `fetch` Response
   * (streaming, with an automatic `arrayBuffer()` fallback when the server
   * doesn't send `Content-Type: application/wasm`). The reactor imports
   * nothing, so `imports` is only for exotic hosts and defaults to `{}`.
   */
  static async instantiate(source, imports = {}) {
    let instance;
    if (source instanceof WebAssembly.Module) {
      instance = await WebAssembly.instantiate(source, imports);
    } else if (isResponseLike(source)) {
      instance = await instantiateResponse(source, imports);
    } else {
      const result = await WebAssembly.instantiate(source, imports);
      instance = result.instance;
    }
    return JdModule.fromInstance(instance);
  }

  /** Wrap an already-instantiated libjd instance. */
  static fromInstance(instance) {
    const exports = instance.exports;
    for (const name of REQUIRED_EXPORTS) {
      if (!(name in exports)) {
        throw new Error(
          `not a libjd module: missing export "${name}" (did you load the right jd.wasm?)`,
        );
      }
    }
    return new JdModule(exports, exports.jd_wasm_result_ptr());
  }

  /**
   * Create a new input context. `pageSize` is the candidate page length (the
   * engine's paginators divide by it, so it must be 1..=255; defaults to 9).
   * Throws on a bad `pageSize` or if the engine can't allocate its per-context
   * buffer. Release it with {@link Engine#dispose} (or a `using` binding).
   *
   * @param {number} [pageSize]
   * @returns {Engine}
   */
  createEngine(pageSize = 9) {
    if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 255) {
      throw new RangeError(`pageSize must be an integer in 1..=255, got ${pageSize}`);
    }
    const ctx = this.#exports.jd_init(pageSize);
    if (ctx === 0) throw new Error("jd_init failed (allocation failure)");
    return new Engine(this.#exports, this.#resultPtr, ctx, pageSize);
  }
}

/**
 * One input context — the JS analog of the Rust `JdContext` / Swift `Engine`.
 * Every method returns a deep-copied snapshot that is safe to keep. Not safe to
 * call concurrently with itself.
 */
export class Engine {
  #exports;
  #resultPtr;
  #pageSize;
  /** The `jd_context *`; set to 0 by {@link Engine#dispose} to poison later use. */
  #ctx;

  /** @internal — use {@link JdModule#createEngine}. */
  constructor(exports, resultPtr, ctx, pageSize) {
    this.#exports = exports;
    this.#resultPtr = resultPtr;
    this.#ctx = ctx;
    this.#pageSize = pageSize;
  }

  /** The candidate page length this engine was created with. */
  get pageSize() {
    return this.#pageSize;
  }

  /** True once {@link Engine#dispose} has run; every other call then throws. */
  get disposed() {
    return this.#ctx === 0;
  }

  /**
   * Feed one keystroke. `key` is a raw ASCII byte (0..=255) — e.g.
   * `"a".charCodeAt(0)`; higher bits are masked off to match the C `char`.
   *
   * @param {number} key
   */
  pressKey(key) {
    const ctx = this.#live();
    this.#exports.jd_press_key(this.#resultPtr, ctx, key & 0xff);
    return this.#readSnapshot();
  }

  /** Advance the active candidate paginator by one page (no-op at the last). */
  nextPage() {
    const ctx = this.#live();
    this.#exports.jd_next_page(this.#resultPtr, ctx);
    return this.#readSnapshot();
  }

  /** Step the active candidate paginator back one page (no-op at the first). */
  prevPage() {
    const ctx = this.#live();
    this.#exports.jd_prev_page(this.#resultPtr, ctx);
    return this.#readSnapshot();
  }

  /**
   * Set the paginator's current page directly (1-based; out-of-range ignored).
   *
   * @param {number} page
   */
  jumpToPage(page) {
    const ctx = this.#live();
    this.#exports.jd_jump_to_page(this.#resultPtr, ctx, page >>> 0);
    return this.#readSnapshot();
  }

  /** Undo the most recent trie descent (or close a punctuation window). */
  backspace() {
    const ctx = this.#live();
    this.#exports.jd_backspace(this.#resultPtr, ctx);
    return this.#readSnapshot();
  }

  /** Drop the in-flight composition without committing. Keeps the engine alive. */
  reset() {
    this.#exports.jd_reset(this.#live());
  }

  /**
   * Release the engine's context (`jd_deinit`). Idempotent. After this the
   * engine is poisoned — every other method throws. The shared module and its
   * other engines are unaffected. Also invoked by `using` / `Symbol.dispose`.
   */
  dispose() {
    if (this.#ctx !== 0) {
      this.#exports.jd_deinit(this.#ctx);
      this.#ctx = 0;
    }
  }

  #live() {
    if (this.#ctx === 0) throw new Error("Engine has been disposed");
    return this.#ctx;
  }

  /**
   * Read the sret buffer and deep-copy every borrowed pointer into JS strings.
   * A single `buffer` snapshot is taken up front: no wasm call runs during a
   * read, so linear memory can't grow (and detach the buffer) mid-copy.
   */
  #readSnapshot() {
    const buffer = this.#exports.memory.buffer;
    const view = new DataView(buffer);
    const ret = this.#resultPtr;

    const commitPtr = view.getUint32(ret + COMMIT_OFF, true);
    const optionsPtr = view.getUint32(ret + OPTIONS_OFF, true);
    const optionsCount = view.getUint32(ret + OPTIONS_COUNT_OFF, true);
    const totalPages = view.getUint32(ret + TOTAL_PAGES_OFF, true);
    const currentPage = view.getUint32(ret + CURRENT_PAGE_OFF, true);

    const commit = commitPtr === 0 ? null : readCString(buffer, commitPtr);

    const visible = visibleCount(optionsCount, currentPage, totalPages, this.#pageSize);
    const options = [];
    // `visible === 0` guards the committed / empty shapes so a stray non-null
    // pointer can never make us over-read.
    if (optionsPtr !== 0 && visible > 0) {
      for (let i = 0; i < visible; i++) {
        const base = optionsPtr + i * OPTION_SIZE;
        const valuePtr = view.getUint32(base, true);
        const hintPtr = view.getUint32(base + OPTION_HINT_OFF, true);
        options.push({
          value: readCString(buffer, valuePtr),
          hint: hintPtr === 0 ? null : readCString(buffer, hintPtr),
        });
      }
    }

    return { commit, options, optionsCount, totalPages, currentPage };
  }
}

// Enable `using` / `await using` where Symbol.dispose exists (Node 20.4+,
// current browsers); kept off the class body so the module still loads on
// runtimes without it, where callers just use dispose() directly.
if (typeof Symbol.dispose !== "undefined") {
  Engine.prototype[Symbol.dispose] = function () {
    this.dispose();
  };
}
