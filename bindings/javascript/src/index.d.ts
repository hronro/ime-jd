// Hand-written type declarations for the plain-JS bindings in ./index.js.
// The authoritative behavior lives in index.js; this file only describes the
// public surface for TypeScript consumers. No build step produces it.

/** One candidate: the text to commit plus an optional remaining-keys hint. */
export interface Candidate {
  readonly value: string;
  readonly hint: string | null;
}

/**
 * Owned snapshot of one engine result. See `core/include/jd.h` for the four
 * state shapes (candidates / committed / committed-and-drilled-in / empty).
 * `options` holds the current page only; `optionsCount` is the total across
 * all pages.
 */
export interface QuerySnapshot {
  readonly commit: string | null;
  readonly options: readonly Candidate[];
  readonly optionsCount: number;
  readonly totalPages: number;
  readonly currentPage: number;
}

/** The empty / no-composition result. */
export const EMPTY_SNAPSHOT: QuerySnapshot;

/**
 * Number of candidates materialized in the current page's `options` array.
 * `optionsCount` is the total across all pages, not the length of the current
 * array; every non-last page is `pageSize` long and the last holds the
 * remainder. Returns 0 for the empty / committed shapes and for `pageSize` 0.
 */
export function visibleCount(
  optionsCount: number,
  currentPage: number,
  totalPages: number,
  pageSize: number,
): number;

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
   * imports nothing, so `imports` defaults to `{}`.
   */
  static instantiate(source: WasmSource, imports?: WebAssembly.Imports): Promise<JdModule>;

  /** Wrap an already-instantiated libjd instance. */
  static fromInstance(instance: WebAssembly.Instance): JdModule;

  /**
   * Create a new input context. `pageSize` is the candidate page length
   * (1..=255; defaults to 9). Throws on a bad `pageSize` or allocation failure.
   */
  createEngine(pageSize?: number): Engine;
}

/**
 * One input context — the JS analog of the Rust `JdContext` / Swift `Engine`.
 * Every method returns a deep-copied {@link QuerySnapshot} that is safe to keep.
 * Not safe to call concurrently with itself.
 */
export class Engine {
  private constructor();

  /** The candidate page length this engine was created with. */
  get pageSize(): number;

  /** True once {@link Engine.dispose} has run; every other call then throws. */
  get disposed(): boolean;

  /**
   * Feed one keystroke. `key` is a raw ASCII byte (0..=255) — e.g.
   * `"a".charCodeAt(0)`; higher bits are masked to match the C `char`.
   */
  pressKey(key: number): QuerySnapshot;

  /** Advance the active candidate paginator by one page (no-op at the last). */
  nextPage(): QuerySnapshot;

  /** Step the active candidate paginator back one page (no-op at the first). */
  prevPage(): QuerySnapshot;

  /** Set the paginator's current page directly (1-based; out-of-range ignored). */
  jumpToPage(page: number): QuerySnapshot;

  /** Undo the most recent trie descent (or close a punctuation window). */
  backspace(): QuerySnapshot;

  /** Drop the in-flight composition without committing. Keeps the engine alive. */
  reset(): void;

  /**
   * Release the engine's context (`jd_deinit`). Idempotent; poisons the engine
   * so every other method then throws. Other engines are unaffected.
   */
  dispose(): void;

  /** Enables `using` bindings; equivalent to {@link Engine.dispose}. */
  [Symbol.dispose](): void;
}
