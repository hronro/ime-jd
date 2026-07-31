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

  /** Create a new input context. Throws on allocation failure. */
  createEngine(): Engine;
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
