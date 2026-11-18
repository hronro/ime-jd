// The composition state machine over one libjd `Engine`. It ports the desktop
// dispatch of macos/JdIME/Controller/InputController.swift (paging, anchor,
// commit-and-drill-in) and the mobile entry points of
// ios/Keyboard/Engine/InputSession.swift (literal insertion, lazily loaded
// candidate windows), following the routing table in core/docs/integration.md.
//
// No DOM here: committed text goes to a `SessionHost`, and every state change
// is published as a `SessionView`, so this file is unit-testable in Node.

import type { Candidate, Engine } from "jd";

/** Where committed text goes — the focused field. */
export interface SessionHost {
  insert(text: string): void;
}

/** What the candidate UI draws. */
export interface SessionView {
  /** The letters typed so far — or the punctuation key whose window is open. */
  readonly code: string;
  /** How many candidates are in flight. */
  readonly total: number;
  /** Flat index of the first candidate on the current page (the anchor). */
  readonly pageStart: number;
  /** The current page's candidates. */
  readonly page: readonly Candidate[];
}

/** One commit of a candidate the user chose, for the code-hint feature. */
export interface CandidateCommit {
  /** The candidate's text. */
  readonly value: string;
  /** The letters typed to reach it. */
  readonly code: string;
  /** Its flat index in the candidate list typed with `code`. */
  readonly index: number;
}

export const IDLE: SessionView = Object.freeze({ code: "", total: 0, pageStart: 0, page: [] });

const SPACE = 0x20;
const SEMICOLON = 0x3b;

export class InputSession {
  /** Candidates per page on desktop: `1`–`9` pick them. */
  static readonly PAGE_SIZE = 9;

  #engine: Engine;
  #host: SessionHost | null = null;
  #view: SessionView = IDLE;
  #listeners = new Set<(view: SessionView) => void>();
  #commitListeners = new Set<(commit: CandidateCommit) => void>();

  constructor(engine: Engine) {
    this.#engine = engine;
  }

  get engine(): Engine {
    return this.#engine;
  }

  get view(): SessionView {
    return this.#view;
  }

  get composing(): boolean {
    return this.#view.code !== "";
  }

  /** Point committed text at another field (or none). Composition is dropped. */
  attach(host: SessionHost | null): void {
    if (host === this.#host) return;
    this.cancel();
    this.#host = host;
  }

  /**
   * Adopt a new engine (a rebuilt user dictionary). Whatever was composing is
   * dropped; the caller disposes the old engine afterwards.
   */
  replaceEngine(engine: Engine): void {
    this.#view = IDLE;
    this.#emit();
    this.#engine = engine;
  }

  subscribe(listener: (view: SessionView) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  onCandidateCommit(listener: (commit: CandidateCommit) => void): () => void {
    this.#commitListeners.add(listener);
    return () => this.#commitListeners.delete(listener);
  }

  // MARK: - Keys

  /**
   * Feed one printable ASCII byte to the engine. Returns false when the engine
   * produced nothing, so the caller lets the host handle the key.
   */
  pressKey(byte: number): boolean {
    const before = this.#view;
    const state = this.#engine.pressKey(byte);

    if (state.commit !== null) {
      this.#noteEngineCommit(before, state.commit, byte);
      this.#insert(state.commit);
      if (state.optionsCount === 0) {
        this.#end();
      } else {
        // Committed and drilled in: the key itself starts a new composition.
        this.#refresh(String.fromCharCode(byte), 0);
      }
      return true;
    }

    if (state.optionsCount > 0) {
      this.#refresh(before.code + String.fromCharCode(byte), 0);
      return true;
    }

    return false;
  }

  /** Backspace while composing. Returns false when idle (the host deletes). */
  backspace(): boolean {
    if (!this.composing) return false;
    this.#engine.backspace();
    const code = this.#view.code.slice(0, -1);
    if (code === "") this.#end();
    else this.#refresh(code, 0);
    return true;
  }

  /** Escape: drop the composition without committing. */
  cancel(): void {
    this.#end();
  }

  /** Enter: commit the typed letters as they are. */
  commitRaw(): boolean {
    if (!this.composing) return false;
    this.#insert(this.#view.code);
    this.#end();
    return true;
  }

  /**
   * Commit what space would — the anchor candidate — and end the composition.
   * Used before copying, and before a literal on mobile. No-op when idle.
   */
  commitAnchor(): void {
    if (!this.composing) return;
    const before = this.#view;
    const state = this.#engine.pressKey(SPACE);
    if (state.commit !== null) {
      this.#noteEngineCommit(before, state.commit, SPACE);
      this.#insert(state.commit);
    }
    this.#end();
  }

  /**
   * Pick candidate `slot` (0-based) of the current page. Returns false when the
   * slot is empty — the caller then sends the digit to the engine as a literal,
   * as every desktop client does.
   */
  select(slot: number): boolean {
    const candidate = this.#view.page[slot];
    if (candidate === undefined) return false;
    this.commitCandidate(candidate.value, this.#view.pageStart + slot);
    return true;
  }

  /** Commit a candidate the user clicked or tapped, by flat index. */
  commitCandidate(value: string, index: number): void {
    const code = this.#view.code;
    this.#insert(value);
    this.#end();
    if (/^[a-z]+$/.test(code)) this.#notifyCommit({ value, code, index });
  }

  pageNext(): void {
    const next = this.#view.pageStart + InputSession.PAGE_SIZE;
    if (next < this.#view.total) this.#refresh(this.#view.code, next);
  }

  pagePrev(): void {
    if (this.#view.pageStart === 0) return;
    this.#refresh(this.#view.code, Math.max(0, this.#view.pageStart - InputSession.PAGE_SIZE));
  }

  /**
   * A digit or mark typed on a touch keyboard: commit the anchor the way the
   * engine's space would, then insert the text as it is (ios InputSession's
   * `insertLiteral`).
   */
  insertLiteral(text: string): void {
    this.commitAnchor();
    this.#insert(text);
  }

  /** A pure read for the mobile candidate bar; never moves the anchor. */
  readRange(start: number, count: number): Candidate[] {
    if (this.#view.total === 0) return [];
    return this.#engine.readRange(start, count);
  }

  // MARK: - Internals

  #insert(text: string): void {
    if (text !== "") this.#host?.insert(text);
  }

  /** Re-read the page at `pageStart` and point the engine's anchor at it. */
  #refresh(code: string, pageStart: number): void {
    const total = this.#engine.snapshot().optionsCount;
    if (total === 0) {
      this.#end();
      return;
    }
    const start = pageStart < total ? pageStart : 0;
    this.#engine.setAnchor(start);
    const page = this.#engine.readRange(start, InputSession.PAGE_SIZE);
    this.#view = { code, total, pageStart: start, page };
    this.#emit();
  }

  #end(): void {
    this.#engine.reset();
    if (this.#view === IDLE) return;
    this.#view = IDLE;
    this.#emit();
  }

  #emit(): void {
    for (const listener of this.#listeners) listener(this.#view);
  }

  /**
   * An engine commit (space, a punctuation key, commit-and-jump) resolves
   * against the anchor — the first candidate on the page — so when the commit
   * starts with it, that is the candidate the user took. `;` while composing
   * letters is the engine's own 2nd-candidate selector.
   */
  #noteEngineCommit(before: SessionView, commit: string, byte: number): void {
    if (!/^[a-z]+$/.test(before.code)) return;
    const second = before.page[1];
    if (byte === SEMICOLON && second !== undefined && commit === second.value) {
      this.#notifyCommit({ value: second.value, code: before.code, index: before.pageStart + 1 });
      return;
    }
    const anchor = before.page[0];
    if (anchor === undefined || !commit.startsWith(anchor.value)) return;
    this.#notifyCommit({ value: anchor.value, code: before.code, index: before.pageStart });
  }

  #notifyCommit(commit: CandidateCommit): void {
    for (const listener of this.#commitListeners) listener(commit);
  }
}
