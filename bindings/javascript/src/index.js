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
 * chunks. The user-dictionary calls need host buffers inside linear memory,
 * which come from the module's own allocator (`jd_alloc` / `jd_free`); a
 * `UserDict` owns one such block for as long as it lives. Everything this
 * module hands back is already an owned JS value.
 *
 * One Engine must not be driven from two things at once (the C contract);
 * distinct engines are fully independent even when they share a module.
 */

// Shared UTF-8 codec; `fatal: false` mirrors the lossy decode the Rust and
// Swift bindings use for the (always-valid) engine strings.
const decoder = new TextDecoder("utf-8", { fatal: false });
const encoder = new TextEncoder();

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
  "jd_user_dict_blob_bound",
  "jd_user_dict_build",
  "jd_user_dict_check",
  "jd_alloc",
  "jd_free",
];

// jd_abi_layout queries (see jd.h).
const ABI_SIZEOF_STATE = 0;
const ABI_SIZEOF_OPTION = 1;
const ABI_HINT_CAP = 2;
const ABI_SCRATCH_OPTIONS = 3;
const ABI_SIZEOF_USER_DICT_REPORT = 5;
const ABI_USER_DICT_MAX_ENTRIES = 6;
const ABI_USER_DICT_VALUE_MAX = 7;
const ABI_SIZEOF_USER_DICT_INFO = 8;

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

// wasm32 layouts of the user-dictionary structs, also checked at
// instantiation. `jd_user_dict_report` is four u32s; `jd_user_dict_info` is
// a u64 then a u32 (padded to 16); `size_t` is 4 bytes.
const REPORT_SIZE = 16;
const REPORT_LINE_OFF = 4;
const REPORT_ENTRIES_OFF = 8;
const REPORT_DROPPED_OFF = 12;
const INFO_SIZE = 16;
const INFO_ENTRIES_OFF = 8;
const SIZE_T = 4;

/** JD_USER_DICT_* codes, by value. */
const USER_DICT_STATUS = [
  "ok",
  "bufferTooSmall",
  "tooManyEntries",
  "malformedLine",
  "badKeys",
  "badValue",
  "stale",
  "corrupt",
  "misaligned",
  "textTooLong",
];
const USER_DICT_STATUS_CORRUPT = 7;
/** Statuses that refer to a line of the input text. */
const LINE_STATUSES = new Set(["tooManyEntries", "malformedLine", "badKeys", "badValue"]);

/**
 * A user dictionary could not be built or accepted. `status` names the
 * `JD_USER_DICT_*` code (`"malformedLine"`, `"stale"`, …) and `line` is the
 * 1-based input line for the statuses that refer to one, else 0.
 */
export class UserDictError extends Error {
  /**
   * @param {number} code
   * @param {number} line
   * @param {{maxEntries: number, valueMax: number}} limits
   */
  constructor(code, line, limits) {
    const status = USER_DICT_STATUS[code] ?? `unknown(${code})`;
    const detail =
      {
        bufferTooSmall: "output buffer too small",
        tooManyEntries: `more than ${limits.maxEntries} phrases`,
        malformedLine: "expected `value<TAB>keys`",
        badKeys: "keys must be 1 to 6 characters from a-z and `;`",
        badValue: `value must be 1 to ${limits.valueMax} bytes of text without control characters`,
        stale: "blob was built against a different dictionary (rebuild it)",
        corrupt: "blob is corrupt (rebuild it)",
        misaligned: "blob is not 4-byte aligned",
        textTooLong: "text is too long",
      }[status] ?? `unknown status ${code}`;
    const isLine = LINE_STATUSES.has(status);
    super(isLine ? `line ${line}: ${detail}` : detail);
    this.name = "UserDictError";
    this.status = status;
    this.code = code;
    this.line = isLine ? line : 0;
  }
}

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

function countLines(bytes) {
  let lines = 1;
  for (const b of bytes) if (b === 0x0a) lines++;
  return lines;
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
 * Per-instance bookkeeping of a {@link UserDict}, kept out of the class so
 * {@link JdModule} and {@link Engine} can reach it without widening the
 * public surface.
 *
 * @type {WeakMap<UserDict, {module: JdModule, exports: any, ptr: number, allocSize: number, len: number, engines: number}>}
 */
const dictInternals = new WeakMap();

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
  /** User-dictionary limits, for error messages. */
  #limits;

  /** @internal — use {@link JdModule.instantiate} or {@link JdModule.fromInstance}. */
  constructor(exports, scratchOptions, limits) {
    this.#exports = exports;
    this.#scratchOptions = scratchOptions;
    this.#limits = limits;
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
    expect(ABI_SIZEOF_USER_DICT_REPORT, REPORT_SIZE, "sizeof(jd_user_dict_report)");
    expect(ABI_SIZEOF_USER_DICT_INFO, INFO_SIZE, "sizeof(jd_user_dict_info)");

    const limits = {
      maxEntries: exports.jd_abi_layout(ABI_USER_DICT_MAX_ENTRIES),
      valueMax: exports.jd_abi_layout(ABI_USER_DICT_VALUE_MAX),
    };
    return new JdModule(exports, exports.jd_abi_layout(ABI_SCRATCH_OPTIONS), limits);
  }

  /**
   * Create a new input context, over the built-in dictionary alone or, with
   * `userDict`, merged with a {@link UserDict} of this module. Throws if the
   * engine can't allocate its per-context buffer. Release it with
   * {@link Engine#dispose} (or a `using` binding) — before the dictionary.
   *
   * @param {{userDict?: UserDict | null}} [options]
   * @returns {Engine}
   */
  createEngine(options = {}) {
    const dict = options.userDict ?? null;
    let ptr = 0;
    let len = 0;
    let internal = null;
    if (dict !== null) {
      internal = dictInternals.get(dict);
      if (internal === undefined || internal.module !== this) {
        throw new TypeError("userDict must be a UserDict created by this module");
      }
      if (internal.ptr === 0) throw new Error("UserDict has been disposed");
      ptr = internal.ptr;
      len = internal.len;
    }
    const ctx = this.#exports.jd_init(ptr, len);
    if (ctx === 0) throw new Error("jd_init failed (allocation failure)");
    if (internal !== null) internal.engines++;
    return new Engine(this.#exports, ctx, this.#scratchOptions, internal);
  }

  /**
   * Compile `value<TAB>keys` text — the format of libjd's own table files —
   * into a {@link UserDict}. `#` starts a comment line, blank lines are
   * skipped, spaces around either field are trimmed, CRLF is accepted. Keys
   * are one to six characters from `a`-`z` and `;`; values are text without
   * control characters. Exact duplicates, of an earlier line or of a built-in
   * word on the same code, are dropped, counted, and listed by line in the
   * report. Throws a {@link UserDictError} naming the bad line otherwise.
   *
   * `sourceTag` is 64 bits of yours, stored in the blob and never
   * interpreted — a modification time, a content hash, a revision — so a
   * cached blob can be told apart from the phrases it was built from.
   *
   * @param {string} text
   * @param {{sourceTag?: number | bigint}} [options]
   * @returns {{dict: UserDict, report: {entries: number, dropped: number, droppedLines: number[]}}}
   */
  buildUserDict(text, options = {}) {
    const sourceTag = BigInt(options.sourceTag ?? 0);
    const textBytes = encoder.encode(text);
    const lines = countLines(textBytes);

    // Everything the call reads or writes must sit inside linear memory. One
    // scratch block holds the report, the blob length and the dropped-line
    // array; the text and the blob get blocks of their own.
    const scratchSize = REPORT_SIZE + SIZE_T + lines * 4;
    const reportPtr = this.#alloc(scratchSize);
    const blobLenPtr = reportPtr + REPORT_SIZE;
    const droppedPtr = blobLenPtr + SIZE_T;
    const textPtr = textBytes.length === 0 ? 0 : this.#alloc(textBytes.length);
    let blobPtr = 0;
    let bound = 0;
    try {
      if (textPtr !== 0) new Uint8Array(this.#memory(), textPtr, textBytes.length).set(textBytes);
      bound = this.#exports.jd_user_dict_blob_bound(textPtr, textBytes.length);
      blobPtr = this.#alloc(bound);

      const status = this.#exports.jd_user_dict_build(
        textPtr,
        textBytes.length,
        sourceTag,
        blobPtr,
        bound,
        blobLenPtr,
        reportPtr,
        droppedPtr,
        lines,
      );
      const view = new DataView(this.#memory());
      if (status !== 0) {
        throw new UserDictError(status, view.getUint32(reportPtr + REPORT_LINE_OFF, true), this.#limits);
      }
      const entries = view.getUint32(reportPtr + REPORT_ENTRIES_OFF, true);
      const dropped = view.getUint32(reportPtr + REPORT_DROPPED_OFF, true);
      const blobLen = view.getUint32(blobLenPtr, true);
      const droppedLines = Array.from(
        new Uint32Array(this.#memory(), droppedPtr, Math.min(dropped, lines)),
      );

      const dict = new UserDict(entries, sourceTag);
      dictInternals.set(dict, {
        module: this,
        exports: this.#exports,
        ptr: blobPtr,
        allocSize: bound,
        len: blobLen,
        engines: 0,
      });
      blobPtr = 0; // now owned by the dict
      return { dict, report: { entries, dropped, droppedLines } };
    } finally {
      if (blobPtr !== 0) this.#exports.jd_free(blobPtr, bound);
      if (textPtr !== 0) this.#exports.jd_free(textPtr, textBytes.length);
      this.#exports.jd_free(reportPtr, scratchSize);
    }
  }

  /**
   * Wrap a blob cached from an earlier {@link UserDict#bytes}. The bytes are
   * copied into linear memory and validated exactly as `jd_init` would;
   * a `"stale"` (another libjd) or `"corrupt"` {@link UserDictError} means
   * "rebuild from the phrases". Read {@link UserDict#sourceTag} to tell
   * whether the phrases themselves have changed since.
   *
   * @param {Uint8Array | ArrayBuffer} bytes
   * @returns {UserDict}
   */
  loadUserDict(bytes) {
    const src = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (src.length === 0) throw new UserDictError(USER_DICT_STATUS_CORRUPT, 0, this.#limits);

    const infoPtr = this.#alloc(INFO_SIZE);
    let ptr = this.#alloc(src.length);
    try {
      new Uint8Array(this.#memory(), ptr, src.length).set(src);
      const status = this.#exports.jd_user_dict_check(ptr, src.length, infoPtr);
      if (status !== 0) throw new UserDictError(status, 0, this.#limits);
      const view = new DataView(this.#memory());
      const dict = new UserDict(
        view.getUint32(infoPtr + INFO_ENTRIES_OFF, true),
        view.getBigUint64(infoPtr, true),
      );
      dictInternals.set(dict, {
        module: this,
        exports: this.#exports,
        ptr,
        allocSize: src.length,
        len: src.length,
        engines: 0,
      });
      ptr = 0; // now owned by the dict
      return dict;
    } finally {
      if (ptr !== 0) this.#exports.jd_free(ptr, src.length);
      this.#exports.jd_free(infoPtr, INFO_SIZE);
    }
  }

  /** The module's linear memory, re-read after every call that may grow it. */
  #memory() {
    return this.#exports.memory.buffer;
  }

  #alloc(size) {
    const ptr = this.#exports.jd_alloc(size);
    if (ptr === 0) throw new Error(`jd_alloc(${size}) failed (out of linear memory)`);
    return ptr;
  }
}

/**
 * Phrases of the user's own, compiled into the blob the engine reads in
 * place — one block of linear memory this object owns. Build one with
 * {@link JdModule#buildUserDict}, cache {@link UserDict#bytes}, and wrap the
 * cached bytes with {@link JdModule#loadUserDict} on later launches. Pass it
 * to {@link JdModule#createEngine}; the engine merges its phrases into every
 * candidate list, user phrases first on a shared code.
 */
export class UserDict {
  #entries;
  #sourceTag;

  /** @internal — use {@link JdModule#buildUserDict} or {@link JdModule#loadUserDict}. */
  constructor(entries, sourceTag) {
    this.#entries = entries;
    this.#sourceTag = sourceTag;
  }

  /** How many phrases the dictionary holds. */
  get entries() {
    return this.#entries;
  }

  /** The tag it was built with, read back from the blob. */
  get sourceTag() {
    return this.#sourceTag;
  }

  /** The blob's length in bytes. */
  get byteLength() {
    return this.#live().len;
  }

  /** True once {@link UserDict#dispose} has run. */
  get disposed() {
    return dictInternals.get(this).ptr === 0;
  }

  /**
   * A copy of the blob — exactly the bytes to cache (IndexedDB, a file) and
   * hand to {@link JdModule#loadUserDict} next time.
   *
   * @returns {Uint8Array}
   */
  bytes() {
    const internal = this.#live();
    return new Uint8Array(internal.exports.memory.buffer, internal.ptr, internal.len).slice();
  }

  /**
   * Release the blob's linear memory (`jd_free`). Idempotent. Throws while
   * an engine created with this dictionary is still alive, since that engine
   * reads the blob in place: dispose the engines first. Also invoked by
   * `using` / `Symbol.dispose`.
   */
  dispose() {
    const internal = dictInternals.get(this);
    if (internal.ptr === 0) return;
    if (internal.engines > 0) {
      throw new Error(
        `UserDict is still used by ${internal.engines} engine(s); dispose them first`,
      );
    }
    internal.exports.jd_free(internal.ptr, internal.allocSize);
    internal.ptr = 0;
  }

  #live() {
    const internal = dictInternals.get(this);
    if (internal.ptr === 0) throw new Error("UserDict has been disposed");
    return internal;
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
  /** Bookkeeping of the user dictionary this context reads, if any. */
  #dict;

  /** @internal — use {@link JdModule#createEngine}. */
  constructor(exports, ctx, scratchOptions, dict) {
    this.#exports = exports;
    this.#ctx = ctx;
    this.#statePtr = exports.jd_state_ptr(ctx);
    this.#scratchPtr = exports.jd_scratch_ptr(ctx);
    this.#scratchOptions = scratchOptions;
    this.#dict = dict;
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
   * other engines are unaffected, and a user dictionary the engine read can
   * be disposed once its last engine is. Also invoked by `using` /
   * `Symbol.dispose`.
   */
  dispose() {
    if (this.#ctx !== 0) {
      this.#exports.jd_deinit(this.#ctx);
      this.#ctx = 0;
      if (this.#dict !== null) {
        this.#dict.engines--;
        this.#dict = null;
      }
    }
  }

  #live() {
    if (this.#ctx === 0) throw new Error("Engine has been disposed");
    return this.#ctx;
  }
}

// Enable `using` / `await using` where Symbol.dispose exists (Node 20.4+,
// current browsers); kept off the class bodies so the module still loads on
// runtimes without it, where callers just use dispose() directly.
if (typeof Symbol.dispose !== "undefined") {
  Engine.prototype[Symbol.dispose] = function () {
    this.dispose();
  };
  UserDict.prototype[Symbol.dispose] = function () {
    this.dispose();
  };
}
