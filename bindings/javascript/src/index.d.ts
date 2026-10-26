// Hand-written type declarations for the plain-JS bindings in ./index.js.
// The authoritative behavior lives in index.js; this file only describes the
// public surface for TypeScript consumers. No build step produces it.

/** One candidate: the text to commit plus an optional remaining-keys hint. */
export interface Candidate {
  readonly value: string;
  readonly hint: string | null;
}

/**
 * The engine's state after an operation. See `core/include/jd.h` for the four
 * shapes it can encode (candidates / committed / committed-and-drilled-in /
 * empty).
 *
 * `commit` is the last operation's committed text, already joined from the
 * ABI's segments. `optionsCount` is the total number of candidates in flight —
 * read them with {@link Engine.readRange}. `anchorIndex` is the candidate the
 * engine's own automatic commits resolve against.
 */
export interface QuerySnapshot {
  readonly commit: string | null;
  readonly optionsCount: number;
  readonly anchorIndex: number;
}

/** The empty / no-composition state. */
export const EMPTY_SNAPSHOT: QuerySnapshot;

/** Anything {@link JdModule.instantiate} can turn into an instance. */
export type WasmSource =
  | WebAssembly.Module
  | BufferSource
  | Response
  | PromiseLike<Response>;

/** The `JD_USER_DICT_*` status codes, by name. */
export type UserDictStatus =
  | "bufferTooSmall"
  | "tooManyEntries"
  | "stale"
  | "corrupt"
  | "misaligned"
  | "textTooLong"
  | (string & {});

/**
 * A user dictionary could not be built or accepted: a problem with the call
 * as a whole, never with one line (a line that does not parse is skipped and
 * noted). For `tooManyEntries` `line` is the 1-based line of the first phrase
 * past the cap; otherwise 0.
 */
export class UserDictError extends Error {
  readonly status: UserDictStatus;
  /** The raw `JD_USER_DICT_*` code. */
  readonly code: number;
  readonly line: number;
}

/**
 * One thing {@link JdModule.buildUserDict} has to say about an input line.
 * A skipped line (it does not parse) carries exactly one of `MALFORMED`,
 * `BAD_KEYS` and `BAD_VALUE`, and nothing else. A dropped line (parsed, but
 * not in the dictionary) carries `REPEATS_LINE` or `REPEATS_BUILTIN`. A kept
 * line whose code is already taken carries `CODE_IN_BUILTIN` and/or
 * `CODE_IN_LINE`: the phrase works, listed ahead of the built-in word, but
 * the code is shared (重码), which is what a user wants to know before
 * relying on it.
 */
export interface UserDictNote {
  /** 1-based input line. */
  readonly line: number;
  /** {@link UserDictNoteFlags} bits. */
  readonly flags: number;
  /**
   * A kept line this one relates to: for a repeat, the line it repeats (0 for
   * a built-in word); for a shared code, the first kept line on that code —
   * and for that first line, the second. 0 otherwise.
   */
  readonly other: number;
  /** Built-in words on exactly this code; 0 on a skipped line. */
  readonly builtin: number;
  /** Other kept lines on exactly this code; 0 on a dropped or skipped line. */
  readonly peers: number;
}

/** The `JD_USER_DICT_LINE_*` flags a {@link UserDictNote} carries. */
export const UserDictNoteFlags: {
  /** Dropped: same keys and value as the kept line `other`. */
  readonly REPEATS_LINE: 1;
  /** Dropped: same keys and value as a built-in word. */
  readonly REPEATS_BUILTIN: 2;
  /** Kept: a built-in word sits on exactly this code (`builtin` says how many). */
  readonly CODE_IN_BUILTIN: 4;
  /** Kept: kept line `other` sits on this code too (`peers` says how many do). */
  readonly CODE_IN_LINE: 8;
  /** Skipped: neither blank nor a comment, and no TAB. */
  readonly MALFORMED: 16;
  /** Skipped: keys empty, longer than 6, or not all a-z. */
  readonly BAD_KEYS: 32;
  /** Skipped: value empty, too long, not UTF-8, or containing control characters. */
  readonly BAD_VALUE: 64;
};

/** What {@link JdModule.buildUserDict} did with the input. */
export interface UserDictReport {
  /** Phrases that made it into the dictionary. */
  readonly entries: number;
  /**
   * Phrases dropped as exact duplicates — of an earlier line with the same
   * keys and value, or of a built-in word on the same code.
   */
  readonly dropped: number;
  /**
   * Kept phrases on a shared code: a built-in word, another kept phrase, or
   * both already sit on it.
   */
  readonly shared: number;
  /** Lines skipped because they do not parse: no TAB, bad keys, or a bad value. */
  readonly invalid: number;
  /** One note per skipped, dropped or shared line — `invalid + dropped + shared` of them — ascending by line. */
  readonly notes: UserDictNote[];
}

/** Options for {@link JdModule.buildUserDict}. */
export interface BuildUserDictOptions {
  /**
   * 64 bits of yours, stored in the blob and never interpreted — a
   * modification time, a content hash, a revision — so a cached blob can be
   * told apart from the phrases it was built from. Defaults to 0.
   */
  sourceTag?: number | bigint;
}

/** Options for {@link JdModule.createEngine}. */
export interface CreateEngineOptions {
  /** A dictionary of this module whose phrases the engine merges in. */
  userDict?: UserDict | null;
}

/**
 * A loaded libjd wasm module. Wraps one WebAssembly instance and mints
 * {@link Engine} contexts from it; the embedded trie and punctuation tables are
 * parsed once and shared read-only across every engine of this module.
 */
export class JdModule {
  private constructor();

  /**
   * Instantiate from wasm bytes, a compiled `WebAssembly.Module`, or a `fetch`
   * `Response` (streaming, with an `arrayBuffer()` fallback). The reactor
   * imports nothing, so `imports` defaults to `{}`. Throws if the module's ABI
   * layout doesn't match this binding.
   */
  static instantiate(source: WasmSource, imports?: WebAssembly.Imports): Promise<JdModule>;

  /** Wrap an already-instantiated libjd instance. */
  static fromInstance(instance: WebAssembly.Instance): JdModule;

  /**
   * Create a new input context, over the built-in dictionary alone or merged
   * with a {@link UserDict} of this module. Throws on allocation failure.
   * Dispose engines before the dictionary they read.
   */
  createEngine(options?: CreateEngineOptions): Engine;

  /**
   * Compile `value<TAB>keys` text (the format of libjd's own table files)
   * into a dictionary. A line that does not parse is skipped and counted,
   * never fatal; exact duplicates of an earlier line or of a built-in word
   * on the same code are dropped and counted; the report's notes say which
   * lines were skipped and why, which were dropped, and which kept phrases
   * sit on a code a built-in word or another phrase already uses. Throws a
   * {@link UserDictError} only for a problem with the call as a whole: too
   * much text, too many phrases.
   */
  buildUserDict(
    text: string,
    options?: BuildUserDictOptions,
  ): { dict: UserDict; report: UserDictReport };

  /**
   * Wrap a blob cached from an earlier {@link UserDict.bytes}, validated
   * exactly as `jd_init` would. A `stale` (another libjd) or `corrupt` error
   * means "rebuild from the phrases".
   */
  loadUserDict(bytes: Uint8Array | ArrayBufferLike): UserDict;
}

/**
 * Phrases of the user's own, compiled into the blob the engine reads in place
 * — one block of linear memory this object owns until {@link UserDict.dispose}.
 */
export class UserDict {
  private constructor();

  /** How many phrases the dictionary holds. */
  get entries(): number;

  /** The tag it was built with, read back from the blob. */
  get sourceTag(): bigint;

  /** The blob's length in bytes. */
  get byteLength(): number;

  /** True once {@link UserDict.dispose} has run. */
  get disposed(): boolean;

  /** A copy of the blob — exactly the bytes to cache for {@link JdModule.loadUserDict}. */
  bytes(): Uint8Array;

  /**
   * Release the blob's linear memory. Idempotent. Throws while an engine
   * created with this dictionary is still alive: dispose the engines first.
   */
  dispose(): void;

  /** Enables `using` bindings; equivalent to {@link UserDict.dispose}. */
  [Symbol.dispose](): void;
}

/**
 * One input context — the JS analog of the Rust `JdContext` / Swift `Engine`.
 * Everything it returns is an owned JS value. Not safe to call concurrently
 * with itself.
 */
export class Engine {
  private constructor();

  /** True once {@link Engine.dispose} has run; every other call then throws. */
  get disposed(): boolean;

  /**
   * Feed one keystroke. `key` is a raw ASCII byte (0..=255) — e.g.
   * `"a".charCodeAt(0)`; higher bits are masked to match the C `char`.
   */
  pressKey(key: number): QuerySnapshot;

  /** Undo the most recent trie descent (or close a punctuation window). */
  backspace(): QuerySnapshot;

  /** Drop the in-flight composition and any recorded commit. */
  reset(): QuerySnapshot;

  /**
   * Point the anchor at candidate `index`, so the engine's automatic commits
   * follow what the user is looking at. Out-of-range indices are ignored.
   */
  setAnchor(index: number): QuerySnapshot;

  /** The current state, without touching the engine. */
  snapshot(): QuerySnapshot;

  /**
   * Read the candidates at `[start, start + count)`, returning fewer at the end
   * of the list and none when nothing is in flight. A pure read: it never moves
   * the anchor, so a candidate strip can prefetch freely.
   */
  readRange(start: number, count: number): Candidate[];

  /**
   * Release the engine's context (`jd_deinit`). Idempotent; poisons the engine
   * so every other method then throws. Other engines are unaffected.
   */
  dispose(): void;

  /** Enables `using` bindings; equivalent to {@link Engine.dispose}. */
  [Symbol.dispose](): void;
}
