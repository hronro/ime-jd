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
 * `index.d.ts`, so there is no build step.
 *
 * Two things are worth knowing about the shape of the ABI:
 *
 *  1. No export returns a struct by value, so there is no wasm sret shim to
 *     work around. Results live in a per-context state block whose address
 *     (`jd_state_ptr`) is fixed for the context's lifetime; we read it once
 *     and then just read fields out of linear memory after each call.
 *  2. Candidates are addressed by flat index, not by page. `readRange` is a
 *     pure read: it never changes what the engine's automatic commits resolve
 *     to, so you can prefetch a candidate strip as far ahead as you like. Tell
 *     the engine what the user actually sees with `setAnchor`.
 *
 * A JS host has no allocator inside linear memory, so `readRange` borrows the
 * context's own scratch buffer (`jd_scratch_ptr`) and decodes out of it in
 * chunks. Everything this module hands back is already an owned JS value.
 *
 * One Engine must not be driven from two things at once (the C contract);
 * distinct engines are fully independent even when they share a module.
 */

// Shared UTF-8 decoder; `fatal: false` mirrors the lossy decode the Rust and
// Swift bindings use for the (always-valid) engine strings.
const decoder = new TextDecoder("utf-8", { fatal: false });

/** The state of a context with nothing in flight. */
export const EMPTY_SNAPSHOT = Object.freeze({
  commit: null,
  optionsCount: 0,
  anchorIndex: 0,
});

const REQUIRED_EXPORTS = [
  "memory",
  "jd_init",
  "jd_deinit",
  "jd_press_key",
  "jd_backspace",
  "jd_reset",
  "jd_set_anchor",
  "jd_state_ptr",
  "jd_scratch_ptr",
  "jd_read_range",
  "jd_abi_layout",
];

// jd_abi_layout queries (see jd.h).
const ABI_SIZEOF_STATE = 0;
const ABI_SIZEOF_OPTION = 1;
const ABI_HINT_CAP = 2;
const ABI_SCRATCH_OPTIONS = 3;

// wasm32 layout of `jd_state`: two 4-byte pointers, a byte, 3 bytes of
// padding, then two u32s. Checked against jd_abi_layout at instantiation.
const STATE_SIZE = 20;
const COMMIT_A_OFF = 0;
const COMMIT_B_OFF = 4;
const COMMIT_LIT_OFF = 8;
const OPTIONS_COUNT_OFF = 12;
const ANCHOR_INDEX_OFF = 16;

// wasm32 layout of `query_option`: a 4-byte pointer then the inline hint.
const OPTION_SIZE = 12;
const OPTION_HINT_OFF = 4;
const HINT_CAP = 8;

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

/** Reads the inline, NUL-padded hint at `ptr`; `null` when empty. */
function readHint(buffer, ptr) {
  const bytes = new Uint8Array(buffer, ptr, HINT_CAP);
  let end = 0;
  while (end < HINT_CAP && bytes[end] !== 0) end++;
  return end === 0 ? null : decoder.decode(bytes.subarray(0, end));
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
  /** Candidate capacity of each context's scratch buffer. */
  #scratchOptions;

  /** @internal — use {@link JdModule.instantiate} or {@link JdModule.fromInstance}. */
  constructor(exports, scratchOptions) {
    this.#exports = exports;
    this.#scratchOptions = scratchOptions;
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

    // The struct offsets above are hand-written, so confirm they match the
    // library before we start reading memory through them.
    const expect = (what, want, label) => {
      const got = exports.jd_abi_layout(what);
      if (got !== want) {
        throw new Error(
          `libjd ABI mismatch: ${label} is ${got} but this binding expects ${want}`,
        );
      }
    };
    expect(ABI_SIZEOF_STATE, STATE_SIZE, "sizeof(jd_state)");
    expect(ABI_SIZEOF_OPTION, OPTION_SIZE, "sizeof(query_option)");
    expect(ABI_HINT_CAP, HINT_CAP, "JD_HINT_CAP");

    return new JdModule(exports, exports.jd_abi_layout(ABI_SCRATCH_OPTIONS));
  }

  /**
   * Create a new input context. Throws if the engine can't allocate its
   * per-context buffer. Release it with {@link Engine#dispose} (or a `using`
   * binding).
   *
   * @returns {Engine}
   */
  createEngine() {
    const ctx = this.#exports.jd_init();
    if (ctx === 0) throw new Error("jd_init failed (allocation failure)");
    return new Engine(this.#exports, ctx, this.#scratchOptions);
  }
}

/**
 * One input context — the JS analog of the Rust `JdContext` / Swift `Engine`.
 * Not safe to call concurrently with itself.
 */
export class Engine {
  #exports;
  /** The `jd_context *`; set to 0 by {@link Engine#dispose} to poison later use. */
  #ctx;
  /** Address of this context's state block — fixed for its lifetime. */
  #statePtr;
  /** Address and capacity of this context's read scratch. */
  #scratchPtr;
  #scratchOptions;

  /** @internal — use {@link JdModule#createEngine}. */
  constructor(exports, ctx, scratchOptions) {
    this.#exports = exports;
    this.#ctx = ctx;
    this.#statePtr = exports.jd_state_ptr(ctx);
    this.#scratchPtr = exports.jd_scratch_ptr(ctx);
    this.#scratchOptions = scratchOptions;
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
    this.#exports.jd_press_key(this.#live(), key & 0xff);
    return this.snapshot();
  }

  /** Undo the most recent trie descent (or close a punctuation window). */
  backspace() {
    this.#exports.jd_backspace(this.#live());
    return this.snapshot();
  }

  /** Drop the in-flight composition and any recorded commit. */
  reset() {
    this.#exports.jd_reset(this.#live());
    return this.snapshot();
  }

  /**
   * Point the anchor at candidate `index`, so the engine's automatic commits
   * follow what the user is looking at. Out-of-range indices are ignored.
   *
   * @param {number} index
   */
  setAnchor(index) {
    this.#exports.jd_set_anchor(this.#live(), index >>> 0);
    return this.snapshot();
  }

  /**
   * The engine's current state: the commit from the last operation (already
   * joined into a string, or null), the total candidate count, and the anchor.
   */
  snapshot() {
    this.#live();
    const buffer = this.#exports.memory.buffer;
    const view = new DataView(buffer);
    const s = this.#statePtr;

    const aPtr = view.getUint32(s + COMMIT_A_OFF, true);
    const bPtr = view.getUint32(s + COMMIT_B_OFF, true);
    const lit = view.getUint8(s + COMMIT_LIT_OFF);

    let commit = null;
    if (aPtr !== 0 || bPtr !== 0 || lit !== 0) {
      commit =
        (aPtr === 0 ? "" : readCString(buffer, aPtr)) +
        (bPtr === 0 ? "" : readCString(buffer, bPtr)) +
        (lit === 0 ? "" : String.fromCharCode(lit));
    }

    return {
      commit,
      optionsCount: view.getUint32(s + OPTIONS_COUNT_OFF, true),
      anchorIndex: view.getUint32(s + ANCHOR_INDEX_OFF, true),
    };
  }

  /**
   * Read the candidates at `[start, start + count)`. Returns fewer than
   * `count` at the end of the list, and an empty array when nothing is in
   * flight. A pure read — it never moves the anchor, so prefetch freely.
   *
   * @param {number} start
   * @param {number} count
   * @returns {{value: string, hint: string | null}[]}
   */
  readRange(start, count) {
    const ctx = this.#live();
    const out = [];
    let at = start >>> 0;
    let left = count >>> 0;

    // The scratch buffer is a fixed size, so a large request is decoded in
    // chunks. Each chunk is fully decoded into JS strings before the next
    // wasm call, so linear memory can't grow (and detach the buffer) mid-copy.
    while (left > 0) {
      const want = Math.min(left, this.#scratchOptions);
      const n = this.#exports.jd_read_range(ctx, at, want, this.#scratchPtr, this.#scratchOptions);
      if (n === 0) break;

      const buffer = this.#exports.memory.buffer;
      const view = new DataView(buffer);
      for (let i = 0; i < n; i++) {
        const base = this.#scratchPtr + i * OPTION_SIZE;
        out.push({
          value: readCString(buffer, view.getUint32(base, true)),
          hint: readHint(buffer, base + OPTION_HINT_OFF),
        });
      }

      at += n;
      left -= n;
      if (n < want) break; // hit the end of the list
    }

    return out;
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
}

// Enable `using` / `await using` where Symbol.dispose exists (Node 20.4+,
// current browsers); kept off the class body so the module still loads on
// runtimes without it, where callers just use dispose() directly.
if (typeof Symbol.dispose !== "undefined") {
  Engine.prototype[Symbol.dispose] = function () {
    this.dispose();
  };
}
