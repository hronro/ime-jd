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
  "jd_lookup_codes",
  "jd_abi_layout",
  "jd_dict_blob_bound",
  "jd_dict_build",
  "jd_dict_check",
  "jd_user_dict_blob_bound",
  "jd_user_dict_build",
  "jd_user_dict_check",
  "jd_user_dict_hash",
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
const ABI_SIZEOF_USER_DICT_NOTE = 9;
const ABI_SIZEOF_CODE = 10;
const ABI_CODE_CAP = 11;
const ABI_USER_DICT_TEXT_MAX = 12;
const ABI_DICT_MAX_ENTRIES = 13;
const ABI_DICT_VALUE_MAX = 14;
const ABI_DICT_TEXT_MAX = 15;
const ABI_BUILTIN_DICT_ENTRIES = 16;

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

// `jd_code`: the inline NUL-padded keys, then two u32s — the same 16 bytes
// on every target.
const CODE_SIZE = 16;
const CODE_CAP = 8;
const CODE_INDEX_OFF = 8;
const CODE_FLAGS_OFF = 12;
/** `JD_CODE_USER`. */
const CODE_USER = 1;
/** Codes `lookupCodes` makes room for before asking again with the total. */
const LOOKUP_CODES_FIRST_CAP = 16;

// wasm32 layouts of the user-dictionary structs, also checked at
// instantiation. `jd_user_dict_report` is eight u32s; `jd_user_dict_info` is
// a u64 then a u32 (padded to 16); `size_t` is 4 bytes. jd_user_dict_note:
// five u32s, laid out by the build past the blob, inside the buffer the host
// gave it.
const REPORT_SIZE = 32;
const REPORT_LINE_OFF = 4;
const REPORT_ENTRIES_OFF = 8;
const REPORT_DROPPED_OFF = 12;
const REPORT_SHARED_OFF = 16;
const REPORT_INVALID_OFF = 20;
const REPORT_NOTES_OFF = 24;
const REPORT_NOTES_OFFSET_OFF = 28;
const NOTE_SIZE = 20;
const INFO_SIZE = 16;
const INFO_ENTRIES_OFF = 8;
const SIZE_T = 4;

/**
 * JD_USER_DICT_* codes, by value. These are failures of a call as a whole; a
 * line that does not parse is skipped and noted instead.
 */
const USER_DICT_STATUS = [
  "ok",
  "bufferTooSmall",
  "tooManyEntries",
  "stale",
  "corrupt",
  "misaligned",
  "textTooLong",
  "noBuiltinDict",
];
const USER_DICT_STATUS_CORRUPT = 4;
/** Statuses that refer to a line of the input text. */
const LINE_STATUSES = new Set(["tooManyEntries"]);

/** The `JD_USER_DICT_LINE_*` flags a report note carries. */
export const UserDictNoteFlags = Object.freeze({
  /** Dropped: same keys and value as the kept line `other`. */
  REPEATS_LINE: 1,
  /** Dropped: same keys and value as a built-in word. */
  REPEATS_BUILTIN: 2,
  /** Kept: a built-in word sits on exactly this code (`builtin` says how many). */
  CODE_IN_BUILTIN: 4,
  /** Kept: kept line `other` sits on this code too (`peers` says how many do). */
  CODE_IN_LINE: 8,
  /** Skipped: neither blank nor a comment, and no TAB. */
  MALFORMED: 16,
  /** Skipped: keys empty, longer than 6, not all a-z and `;`, or a `;` after a letter. */
  BAD_KEYS: 32,
  /** Skipped: value empty, too long, not UTF-8, or containing control characters. */
  BAD_VALUE: 64,
});

/**
 * A dictionary or user dictionary could not be built or accepted: a problem
 * with the call as a whole, never with one line. `status` names the `JD_USER_DICT_*` code
 * (`"tooManyEntries"`, `"stale"`, …) and `line` is the 1-based input line for
 * the statuses that refer to one, else 0.
 */
export class UserDictError extends Error {
  /**
   * @param {number} code
   * @param {number} line
   */
  constructor(code, line) {
    const status = USER_DICT_STATUS[code] ?? `unknown(${code})`;
    const detail =
      {
        bufferTooSmall: "output buffer too small",
        tooManyEntries: "too many entries",
        stale: "blob was built against a different dictionary (rebuild it)",
        corrupt: "blob is corrupt (rebuild it)",
        misaligned: "blob is not 4-byte aligned",
        textTooLong: "text is too long",
        noBuiltinDict: "this libjd has no built-in dictionary",
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

/** Reads `cap` inline, NUL-padded bytes at `ptr` as a string. */
function readInline(buffer, ptr, cap) {
  const bytes = new Uint8Array(buffer, ptr, cap);
  let end = 0;
  while (end < cap && bytes[end] !== 0) end++;
  return decoder.decode(bytes.subarray(0, end));
}

/** Reads the inline, NUL-padded hint at `ptr`; `null` when empty. */
function readHint(buffer, ptr) {
  return readInline(buffer, ptr, HINT_CAP) || null;
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
 * Per-instance bookkeeping of a {@link Dict} or {@link UserDict}, kept out of
 * the classes so {@link JdModule} and {@link Engine} can reach it without
 * widening the public surface.
 *
 * @type {WeakMap<Dict | UserDict, {module: JdModule, exports: any, ptr: number, allocSize: number, len: number, engines: number}>}
 */
const dictInternals = new WeakMap();

/** The two kinds of blob a module builds and loads. */
const KIND_DICT = {
  name: "Dict",
  bound: "jd_dict_blob_bound",
  make: (entries, sourceTag) => new Dict(entries, sourceTag),
};
const KIND_USER_DICT = {
  name: "UserDict",
  bound: "jd_user_dict_blob_bound",
  make: (entries, sourceTag) => new UserDict(entries, sourceTag),
};

/**
 * A loaded libjd wasm module. Wraps one WebAssembly instance and mints Engine
 * contexts from it; the embedded dictionary and punctuation tables are parsed
 * once on first use and shared read-only across every engine of this module,
 * so create as many engines as you have independent input fields.
 */
export class JdModule {
  #exports;
  /** Candidate capacity of each context's scratch buffer. */
  #scratchOptions;
  /** User-dictionary limits. */
  #limits;
  /** Dictionary limits. */
  #dictLimits;

  /** @internal — use {@link JdModule.instantiate} or {@link JdModule.fromInstance}. */
  constructor(exports, scratchOptions, limits, dictLimits) {
    this.#exports = exports;
    this.#scratchOptions = scratchOptions;
    this.#limits = limits;
    this.#dictLimits = dictLimits;
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
    expect(ABI_SIZEOF_USER_DICT_NOTE, NOTE_SIZE, "sizeof(jd_user_dict_note)");
    expect(ABI_SIZEOF_CODE, CODE_SIZE, "sizeof(jd_code)");
    expect(ABI_CODE_CAP, CODE_CAP, "JD_CODE_CAP");

    const limits = Object.freeze({
      maxEntries: exports.jd_abi_layout(ABI_USER_DICT_MAX_ENTRIES),
      valueMax: exports.jd_abi_layout(ABI_USER_DICT_VALUE_MAX),
      textMax: exports.jd_abi_layout(ABI_USER_DICT_TEXT_MAX),
    });
    // jd_abi_layout returns a u32, which wasm hands JS as a signed i32.
    const u32 = (what) => exports.jd_abi_layout(what) >>> 0;
    const dictLimits = Object.freeze({
      maxEntries: u32(ABI_DICT_MAX_ENTRIES),
      valueMax: u32(ABI_DICT_VALUE_MAX),
      textMax: u32(ABI_DICT_TEXT_MAX),
      builtinEntries: u32(ABI_BUILTIN_DICT_ENTRIES),
    });
    return new JdModule(exports, exports.jd_abi_layout(ABI_SCRATCH_OPTIONS), limits, dictLimits);
  }

  /**
   * Create a new input context. It types from `dict`, a {@link Dict} of this
   * module, or without one from the built-in dictionary — which a module
   * built without one (libjd-engine) does not have; and it merges in
   * `userDict`, a {@link UserDict} of this module built on that same
   * dictionary. Release it with {@link Engine#dispose} (or a `using`
   * binding) — before the dictionaries, which it reads in place.
   *
   * Throws when there is no dictionary to type from, when the user
   * dictionary was built on another dictionary, or when the engine cannot
   * allocate its per-context buffer.
   *
   * @param {{dict?: Dict | null, userDict?: UserDict | null}} [options]
   * @returns {Engine}
   */
  createEngine(options = {}) {
    const dict = this.#internalOf(options.dict ?? null, "dict", Dict);
    const userDict = this.#internalOf(options.userDict ?? null, "userDict", UserDict);
    const ctx = this.#exports.jd_init(
      dict?.ptr ?? 0,
      dict?.len ?? 0,
      userDict?.ptr ?? 0,
      userDict?.len ?? 0,
    );
    if (ctx === 0) throw new Error(this.#whyNot(dict, userDict));
    const internals = [dict, userDict].filter((d) => d !== null);
    for (const d of internals) d.engines++;
    return new Engine(this.#exports, ctx, this.#scratchOptions, internals);
  }

  /** Why jd_init refused, worked out only once it has. */
  #whyNot(dict, userDict) {
    if (dict === null && this.#dictLimits.builtinEntries === 0) {
      return "jd_init failed: this libjd has no built-in dictionary; pass a Dict";
    }
    if (userDict !== null) {
      const infoPtr = this.#alloc(INFO_SIZE);
      try {
        const status = this.#exports.jd_user_dict_check(
          dict?.ptr ?? 0,
          dict?.len ?? 0,
          userDict.ptr,
          userDict.len,
          infoPtr,
        );
        if (status !== 0) return "jd_init failed: the user dictionary was built on another dictionary";
      } finally {
        this.#exports.jd_free(infoPtr, INFO_SIZE);
      }
    }
    return "jd_init failed (allocation failure)";
  }

  /** The bookkeeping of `value`, a live `type` of this module, or null. */
  #internalOf(value, name, type) {
    if (value === null) return null;
    const internal = value instanceof type ? dictInternals.get(value) : undefined;
    if (internal === undefined || internal.module !== this) {
      throw new TypeError(`${name} must be a ${type.name} created by this module`);
    }
    if (internal.ptr === 0) throw new Error(`${type.name} has been disposed`);
    return internal;
  }

  /**
   * Compile `value<TAB>keys` text — the format of libjd's own table files —
   * into a {@link UserDict}. `#` starts a comment line, blank lines are
   * skipped, spaces around either field are trimmed, CRLF is accepted. Keys
   * are one to six of `a`-`z` and `;`, with no `;` after a letter; values are
   * text without control characters. A line that breaks these rules is
   * skipped and counted, never fatal. Exact duplicates, of an earlier line
   * or of a word on the same code in the dictionary beneath, are dropped and
   * counted; the report's notes say which lines were skipped and why, which
   * were dropped, and which kept phrases sit on a code a dictionary word or
   * another phrase already uses. Throws a {@link UserDictError} only for a
   * problem with the call as a whole: too much text, too many phrases.
   *
   * The phrases sit on the built-in dictionary, or on `dict`: the result then
   * works only in an engine typing from that `dict`.
   *
   * `sourceTag` is 64 bits of yours, stored in the blob and never
   * interpreted — a modification time, a content hash, a revision — so a
   * cached blob can be told apart from the phrases it was built from.
   *
   * The text may be given as its UTF-8 bytes — a file as read — so it is not
   * encoded again. A byte-order mark is not skipped: drop one first.
   *
   * @param {string | Uint8Array} text
   * @param {{sourceTag?: number | bigint, dict?: Dict | null}} [options]
   * @returns {{dict: UserDict, report: import("./index.d.ts").UserDictReport}}
   */
  buildUserDict(text, options = {}) {
    const base = this.#internalOf(options.dict ?? null, "dict", Dict);
    return this.#build(KIND_USER_DICT, text, options, (textPtr, textLen, tag, blobPtr, bound, lenPtr, reportPtr) =>
      this.#exports.jd_user_dict_build(
        base?.ptr ?? 0,
        base?.len ?? 0,
        textPtr,
        textLen,
        tag,
        blobPtr,
        bound,
        lenPtr,
        reportPtr,
      ),
    );
  }

  /**
   * Compile `value<TAB>keys` text into a {@link Dict}, to type from in place
   * of the built-in dictionary — by the rules of {@link JdModule#buildUserDict}:
   * lines that do not parse are skipped and exact repeats dropped, each with
   * a note (`shared` is always 0). The words on one code are its candidates
   * in the order of their lines. A large dictionary is many megabytes of
   * linear memory; cache {@link Dict#bytes} rather than building it at every
   * start.
   *
   * @param {string | Uint8Array} text
   * @param {{sourceTag?: number | bigint}} [options]
   * @returns {{dict: Dict, report: import("./index.d.ts").UserDictReport}}
   */
  buildDict(text, options = {}) {
    return this.#build(KIND_DICT, text, options, (textPtr, textLen, tag, blobPtr, bound, lenPtr, reportPtr) =>
      this.#exports.jd_dict_build(textPtr, textLen, tag, blobPtr, bound, lenPtr, reportPtr),
    );
  }

  /**
   * The empty dictionary: no codes at all. An engine on it types from its
   * user dictionary alone, built on the same empty dictionary. Every empty
   * dictionary is the same dictionary, so a user dictionary built on one
   * works on any.
   *
   * @returns {Dict}
   */
  emptyDict() {
    return this.buildDict("").dict;
  }

  #build(kind, text, options, call) {
    const sourceTag = BigInt(options.sourceTag ?? 0);
    const textBytes = typeof text === "string" ? encoder.encode(text) : text;

    // Everything the call reads or writes must sit inside linear memory. One
    // scratch block holds the report and the blob length; the text and the
    // blob get blocks of their own. The notes land in the blob's block, past
    // the blob — the bound covers them.
    const scratchSize = REPORT_SIZE + SIZE_T;
    const reportPtr = this.#alloc(scratchSize);
    const blobLenPtr = reportPtr + REPORT_SIZE;
    const textPtr = textBytes.length === 0 ? 0 : this.#alloc(textBytes.length);
    let blobPtr = 0;
    let bound = 0;
    try {
      if (textPtr !== 0) new Uint8Array(this.#memory(), textPtr, textBytes.length).set(textBytes);
      bound = this.#exports[kind.bound](textPtr, textBytes.length) >>> 0;
      blobPtr = this.#alloc(bound);

      const status = call(textPtr, textBytes.length, sourceTag, blobPtr, bound, blobLenPtr, reportPtr);
      const view = new DataView(this.#memory());
      if (status !== 0) {
        throw new UserDictError(status, view.getUint32(reportPtr + REPORT_LINE_OFF, true));
      }
      const entries = view.getUint32(reportPtr + REPORT_ENTRIES_OFF, true);
      const dropped = view.getUint32(reportPtr + REPORT_DROPPED_OFF, true);
      const shared = view.getUint32(reportPtr + REPORT_SHARED_OFF, true);
      const invalid = view.getUint32(reportPtr + REPORT_INVALID_OFF, true);
      const noteCount = view.getUint32(reportPtr + REPORT_NOTES_OFF, true);
      const notesOffset = view.getUint32(reportPtr + REPORT_NOTES_OFFSET_OFF, true);
      const blobLen = view.getUint32(blobLenPtr, true);
      if (notesOffset % 4 !== 0 || notesOffset + noteCount * NOTE_SIZE > bound) {
        throw new Error("libjd placed the notes outside the buffer it was given");
      }
      const notes = [];
      for (let i = 0; i < noteCount; i++) {
        const at = blobPtr + notesOffset + i * NOTE_SIZE;
        notes.push({
          line: view.getUint32(at, true),
          flags: view.getUint32(at + 4, true),
          other: view.getUint32(at + 8, true),
          builtin: view.getUint32(at + 12, true),
          peers: view.getUint32(at + 16, true),
        });
      }

      // The bound leaves room for the build's working space and every
      // line's note, a few times the blob: keep a block the blob's size, and
      // give the rest back to the module's allocator.
      let ptr = blobPtr;
      let allocSize = bound;
      if (bound - blobLen > 64 * 1024) {
        ptr = this.#alloc(Math.max(blobLen, 1));
        allocSize = Math.max(blobLen, 1);
        new Uint8Array(this.#memory()).copyWithin(ptr, blobPtr, blobPtr + blobLen);
      }
      const dict = kind.make(entries, sourceTag);
      dictInternals.set(dict, {
        module: this,
        exports: this.#exports,
        ptr,
        allocSize,
        len: blobLen,
        engines: 0,
      });
      if (ptr === blobPtr) blobPtr = 0; // now owned by the dict
      return { dict, report: { entries, dropped, shared, invalid, notes } };
    } finally {
      if (blobPtr !== 0) this.#exports.jd_free(blobPtr, bound);
      if (textPtr !== 0) this.#exports.jd_free(textPtr, textBytes.length);
      this.#exports.jd_free(reportPtr, scratchSize);
    }
  }

  /**
   * Wrap a blob cached from an earlier {@link UserDict#bytes}. The bytes are
   * copied into linear memory and validated exactly as `jd_init` would, on
   * the built-in dictionary or on `dict`; a `"stale"` (another libjd, or
   * another dictionary) or `"corrupt"` {@link UserDictError} means "rebuild
   * from the phrases". Read {@link UserDict#sourceTag} to tell whether the
   * phrases themselves have changed since.
   *
   * @param {Uint8Array | ArrayBuffer} bytes
   * @param {{dict?: Dict | null}} [options]
   * @returns {UserDict}
   */
  loadUserDict(bytes, options = {}) {
    const base = this.#internalOf(options.dict ?? null, "dict", Dict);
    return this.#load(KIND_USER_DICT, bytes, (ptr, len, infoPtr) =>
      this.#exports.jd_user_dict_check(base?.ptr ?? 0, base?.len ?? 0, ptr, len, infoPtr),
    );
  }

  /**
   * Wrap a blob cached from an earlier {@link Dict#bytes}, copied into linear
   * memory and validated exactly as `jd_init` would.
   *
   * @param {Uint8Array | ArrayBuffer} bytes
   * @returns {Dict}
   */
  loadDict(bytes) {
    return this.#load(KIND_DICT, bytes, (ptr, len, infoPtr) => this.#exports.jd_dict_check(ptr, len, infoPtr));
  }

  #load(kind, bytes, check) {
    const src = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (src.length === 0) throw new UserDictError(USER_DICT_STATUS_CORRUPT, 0);

    const infoPtr = this.#alloc(INFO_SIZE);
    let ptr = this.#alloc(src.length);
    try {
      new Uint8Array(this.#memory(), ptr, src.length).set(src);
      const status = check(ptr, src.length, infoPtr);
      if (status !== 0) throw new UserDictError(status, 0);
      const view = new DataView(this.#memory());
      const dict = kind.make(view.getUint32(infoPtr + INFO_ENTRIES_OFF, true), view.getBigUint64(infoPtr, true));
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

  /**
   * The library's dictionary limits (`JD_DICT_*`), and how many entries its
   * built-in dictionary holds — 0 in libjd-engine.
   */
  get dictLimits() {
    return this.#dictLimits;
  }

  /** The library's user-dictionary limits (`JD_USER_DICT_*`). */
  get userDictLimits() {
    return this.#limits;
  }

  /**
   * libjd's content hash (`jd_user_dict_hash`) of `text` — a string, hashed
   * as UTF-8, or its bytes — for `sourceTag`: hash the text a dictionary is
   * built from, hash it again before trusting a cached blob, and a blob whose
   * tag differs was built from something else. The same bytes hash the same
   * on every platform and in every release.
   *
   * @param {string | Uint8Array} text
   * @returns {bigint}
   */
  hashUserDictText(text) {
    const bytes = typeof text === "string" ? encoder.encode(text) : text;
    if (bytes.length === 0) return BigInt.asUintN(64, this.#exports.jd_user_dict_hash(0, 0));
    const ptr = this.#alloc(bytes.length);
    try {
      new Uint8Array(this.#memory(), ptr, bytes.length).set(bytes);
      return BigInt.asUintN(64, this.#exports.jd_user_dict_hash(ptr, bytes.length));
    } finally {
      this.#exports.jd_free(ptr, bytes.length);
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

/** What a {@link Dict} and a {@link UserDict} share: a blob in linear memory. */
class Blob {
  #entries;
  #sourceTag;

  /** @internal */
  constructor(entries, sourceTag) {
    this.#entries = entries;
    this.#sourceTag = sourceTag;
  }

  /** How many entries the dictionary holds. */
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

  /** True once `dispose` has run. */
  get disposed() {
    return dictInternals.get(this).ptr === 0;
  }

  /**
   * A copy of the blob — exactly the bytes to cache (IndexedDB, a file) and
   * load next time.
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
        `${this.constructor.name} is still used by ${internal.engines} engine(s); dispose them first`,
      );
    }
    internal.exports.jd_free(internal.ptr, internal.allocSize);
    internal.ptr = 0;
  }

  #live() {
    const internal = dictInternals.get(this);
    if (internal.ptr === 0) throw new Error(`${this.constructor.name} has been disposed`);
    return internal;
  }
}

/**
 * A dictionary to type from in place of the built-in one: every code and the
 * words on it, compiled into the blob the engine reads in place — one block
 * of linear memory this object owns. Build one with
 * {@link JdModule#buildDict}, cache {@link Dict#bytes}, and wrap the cached
 * bytes with {@link JdModule#loadDict} on later launches. Pass it to
 * {@link JdModule#createEngine} as `dict`, and to the user-dictionary calls
 * for a user dictionary on top of it.
 */
export class Dict extends Blob {}

/**
 * Phrases of the user's own, compiled into the blob the engine reads in
 * place — one block of linear memory this object owns. Build one with
 * {@link JdModule#buildUserDict}, cache {@link UserDict#bytes}, and wrap the
 * cached bytes with {@link JdModule#loadUserDict} on later launches. Pass it
 * to {@link JdModule#createEngine}; the engine merges its phrases into every
 * candidate list, user phrases first on a shared code.
 */
export class UserDict extends Blob {}

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
  /** Bookkeeping of the dictionaries this context reads. */
  #dicts;

  /** @internal — use {@link JdModule#createEngine}. */
  constructor(exports, ctx, scratchOptions, dicts) {
    this.#exports = exports;
    this.#ctx = ctx;
    this.#statePtr = exports.jd_state_ptr(ctx);
    this.#scratchPtr = exports.jd_scratch_ptr(ctx);
    this.#scratchOptions = scratchOptions;
    this.#dicts = dicts;
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
   * The codes `value` is typed with, from the built-in tables and this
   * engine's user dictionary, in candidate order: shorter codes first, ties
   * key by key (a-z, then `;`), a user phrase's code ahead of a built-in
   * word's on the same keys. `index` is where the value sits in the
   * candidate list after typing exactly `keys` — 0 is what space commits.
   * `value` is matched exactly; an unknown or empty one has no codes.
   *
   * A pure read: the composition and the anchor are untouched.
   *
   * @param {string} value
   * @returns {{keys: string, index: number, user: boolean}[]}
   */
  lookupCodes(value) {
    const ctx = this.#live();
    const bytes = encoder.encode(String(value));
    if (bytes.length === 0) return [];
    // One jd_alloc block (16-aligned): the value, then 4-aligned room for the
    // codes. Too small a guess is answered with the total, so ask once more.
    const valueSize = (bytes.length + 3) & ~3;
    let cap = LOOKUP_CODES_FIRST_CAP;
    for (;;) {
      const size = valueSize + cap * CODE_SIZE;
      const ptr = this.#exports.jd_alloc(size);
      if (ptr === 0) throw new Error(`jd_alloc(${size}) failed (out of linear memory)`);
      try {
        new Uint8Array(this.#exports.memory.buffer, ptr, bytes.length).set(bytes);
        const outPtr = ptr + valueSize;
        const n = this.#exports.jd_lookup_codes(ctx, ptr, bytes.length, outPtr, cap);
        if (n > cap) {
          cap = n;
          continue;
        }
        const buffer = this.#exports.memory.buffer;
        const view = new DataView(buffer);
        const out = [];
        for (let i = 0; i < n; i++) {
          const base = outPtr + i * CODE_SIZE;
          out.push({
            keys: readInline(buffer, base, CODE_CAP),
            index: view.getUint32(base + CODE_INDEX_OFF, true),
            user: (view.getUint32(base + CODE_FLAGS_OFF, true) & CODE_USER) !== 0,
          });
        }
        return out;
      } finally {
        this.#exports.jd_free(ptr, size);
      }
    }
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
      for (const d of this.#dicts) d.engines--;
      this.#dicts = [];
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
  Blob.prototype[Symbol.dispose] = function () {
    this.dispose();
  };
}
