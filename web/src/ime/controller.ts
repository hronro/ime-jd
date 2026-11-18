// The page's input method. A page cannot install a system IME, so this one
// follows focus: whichever text field the user is in — the editor, a dialog's
// search box, a table cell, the CodeMirror editor — its keys go through libjd.
//
// Two input paths feed the same InputSession:
//  - hardware keys arrive as `keydown` with a real `key` (desktop, tablets with
//    a keyboard); engine/keys.ts maps them as every desktop client does;
//  - touch keyboards send `keydown` 229 / "Unidentified" and then a cancelable
//    `beforeinput` per character (verified with Gboard on Android Chrome, the
//    phase-0 spike); those are mapped the way the iOS/Android apps map taps.

import { createSignal } from "solid-js";
import type { Engine } from "jd";
import { keyAction, type KeyAction, typedByte } from "../engine/keys";
import { type CandidateCommit, IDLE, InputSession, type SessionView } from "../engine/session";
import type { CaretRect } from "./caret";
import { fieldTarget, type ImeTarget, isTextField } from "./target";

export type Mode = "zh" | "en";
/** Which candidate UI fits the user's input: a caret popup, or a docked bar. */
export type Surface = "popup" | "bar";

const coarse = () => typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
const fine = () => typeof matchMedia === "function" && matchMedia("(pointer: fine)").matches;

/**
 * A keyboard is drawn on screen. iOS Safari's sends real key events (key "n",
 * keyCode 78, even ShiftLeft for its shift key — verified in the simulator), so
 * the events cannot tell it from a hardware keyboard; the screen can: the
 * visual viewport shrinks by the keyboard (714 → 411pt on an iPhone) while
 * the layout viewport does not. Android Chrome resizes both, but its keyboards
 * are recognized by their 229 key events instead.
 */
function keyboardOnScreen(): boolean {
  const vv = typeof window !== "undefined" ? window.visualViewport : null;
  if (!vv || !coarse()) return false;
  return innerHeight - vv.height * vv.scale > 120;
}

export class ImeController {
  readonly view;
  readonly mode;
  readonly target;
  /** The open modal dialog the target sits in, or null for the page itself. */
  readonly host;
  readonly surface;
  readonly caret;

  #setView;
  #setMode;
  #setTarget;
  #setHost;
  #setSurface;
  #setCaret;

  #session: InputSession | null = null;
  #current: ImeTarget | null = null;
  #fields = new WeakMap<HTMLElement, ImeTarget>();
  #custom = new Map<HTMLElement, ImeTarget>();
  /** A hardware keyboard has typed here (always assumed on a fine pointer). */
  #hardware = fine();
  #shiftAlone = false;
  /** A real (non-229) keydown is being processed; its beforeinput is native. */
  #realKey = false;
  /**
   * The page is editing a field itself (a commit, 清空, 撤销). WebKit fires
   * `beforeinput` for execCommand — Chromium does not — and taking those for
   * touch-keyboard input would re-insert every commit forever.
   */
  #ownEdit = 0;
  #pendingEngine: { engine: Engine; release: () => void } | null = null;

  constructor() {
    [this.view, this.#setView] = createSignal<SessionView>(IDLE);
    [this.mode, this.#setMode] = createSignal<Mode>("zh");
    [this.target, this.#setTarget] = createSignal<ImeTarget | null>(null);
    [this.host, this.#setHost] = createSignal<HTMLDialogElement | null>(null);
    [this.surface, this.#setSurface] = createSignal<Surface>(this.#hardware || !coarse() ? "popup" : "bar");
    [this.caret, this.#setCaret] = createSignal<CaretRect | null>(null);
  }

  get session(): InputSession | null {
    return this.#session;
  }

  get composing(): boolean {
    return this.#session?.composing ?? false;
  }

  /** Begin serving the page with `engine`. */
  start(engine: Engine): void {
    const session = new InputSession(engine);
    this.#session = session;
    session.subscribe((view) => {
      const wasIdle = this.view().code === "";
      this.#setView(view);
      if (view.code !== "" && wasIdle) this.#updateCaret();
      if (view.code === "") this.#applyPendingEngine();
    });

    document.addEventListener("focusin", this.#onFocusIn, true);
    document.addEventListener("focusout", this.#onFocusOut, true);
    document.addEventListener("keydown", this.#onKeyDown, true);
    document.addEventListener("keyup", this.#onKeyUp, true);
    document.addEventListener("beforeinput", this.#onBeforeInput, true);
    document.addEventListener("pointerdown", this.#onPointerDown, true);
    document.addEventListener("scroll", this.#onViewportChange, { capture: true, passive: true });
    window.addEventListener("resize", this.#onViewportChange, { passive: true });
    // An on-screen keyboard coming up or going away changes which candidate
    // UI fits: the bar above it, or the popup at the caret.
    window.visualViewport?.addEventListener("resize", this.#onKeyboardChange, { passive: true });

    if (document.activeElement) this.#focus(document.activeElement);
  }

  /** Called with every candidate the user commits (for 编码提示). */
  onCandidateCommit(listener: (commit: CandidateCommit) => void): () => void {
    if (!this.#session) throw new Error("IME not started");
    return this.#session.onCandidateCommit(listener);
  }

  /**
   * Serve an editor that is not a plain form field (CodeMirror): focus inside
   * `root` types into `target`. Returns the unregister function.
   */
  register(root: HTMLElement, target: ImeTarget): () => void {
    this.#custom.set(root, target);
    if (root.contains(document.activeElement)) this.#focus(document.activeElement!);
    return () => {
      this.#custom.delete(root);
      if (this.#current === target) this.#adopt(null, null);
    };
  }

  /**
   * Adopt a rebuilt dictionary's engine. A composition in flight finishes on
   * the old engine first; `release` then disposes the old engine (and the
   * dictionary it read), as macOS does in `syncEngine`.
   */
  swapEngine(engine: Engine, release: () => void): void {
    this.#pendingEngine?.release();
    this.#pendingEngine = { engine, release };
    if (!this.composing) this.#applyPendingEngine();
  }

  // MARK: - Actions the UI calls

  toggleMode(): void {
    const next = this.mode() === "zh" ? "en" : "zh";
    // Switching while composing keeps what was typed, as the letters.
    if (next === "en") this.#session?.commitRaw();
    this.#setMode(next);
  }

  /** A candidate clicked in the popup or tapped in the bar, by flat index. */
  pick(index: number, value: string): void {
    this.#session?.commitCandidate(value, index);
  }

  pageNext(): void {
    this.#session?.pageNext();
  }

  pagePrev(): void {
    this.#session?.pagePrev();
  }

  /** Finish the composition the way space would — before copying out. */
  commitAnchor(): void {
    this.#session?.commitAnchor();
  }

  cancel(): void {
    this.#session?.cancel();
  }

  /** Run an edit the page makes itself; the IME lets its input events through. */
  edit<T>(fn: () => T): T {
    this.#ownEdit++;
    try {
      return fn();
    } finally {
      this.#ownEdit--;
    }
  }

  /** Insert text into the current field as if typed (the ⇥ key on mobile). */
  insertLiteral(text: string): void {
    this.#session?.insertLiteral(text);
  }

  // MARK: - Focus

  #onFocusIn = (e: FocusEvent) => this.#focus(e.target);

  #onFocusOut = (e: FocusEvent) => {
    const next = e.relatedTarget;
    const current = this.#current;
    if (!current) return;
    if (next instanceof Node && current.element.contains(next)) return;
    // Focus left for something that is not a field (a button, the page):
    // nothing to type into, so the composition goes.
    if (!(next instanceof Element) || this.#resolve(next) === null) this.#adopt(null, null);
  };

  #focus(el: EventTarget | null): void {
    if (!(el instanceof Element)) return;
    const target = this.#resolve(el);
    if (target === this.#current) return;
    const dialog = el.closest("dialog");
    this.#adopt(target, dialog?.matches(":modal") ? dialog : null);
  }

  #resolve(el: Element): ImeTarget | null {
    if (el.closest('[data-ime="off"]')) return null;
    for (const [root, target] of this.#custom) if (root.contains(el)) return target;
    if (!(el instanceof HTMLElement) || !isTextField(el)) return null;
    let target = this.#fields.get(el);
    if (!target) {
      target = fieldTarget(el);
      this.#fields.set(el, target);
    }
    return target;
  }

  #adopt(target: ImeTarget | null, host: HTMLDialogElement | null): void {
    this.#current = target;
    this.#session?.attach(target ? { insert: (text) => this.edit(() => target.insert(text)) } : null);
    this.#setTarget(target);
    this.#setHost(host);
    if (target && coarse() && (!this.#hardware || keyboardOnScreen())) this.#setSurface("bar");
  }

  // MARK: - Hardware keys

  #onKeyDown = (e: KeyboardEvent) => {
    const target = this.#current;
    const session = this.#session;
    if (!target || !session || !target.element.contains(e.target as Node)) return;

    if (e.key === "Shift") {
      this.#shiftAlone = !e.repeat;
      return;
    }
    this.#shiftAlone = false;

    this.#realKey = e.keyCode !== 229 && e.key !== "Unidentified";
    const onScreen = keyboardOnScreen();
    if (this.#realKey && typedByte(e.key) !== null && !e.ctrlKey && !e.metaKey && !e.altKey) {
      if (onScreen) {
        this.#setSurface("bar");
      } else {
        this.#hardware = true;
        this.#setSurface("popup");
      }
    }

    if (this.mode() === "en" || (!session.composing && target.imeOff?.())) return;
    if (this.#perform(keyAction(e, session.composing, { touch: onScreen }))) {
      e.preventDefault();
      e.stopPropagation();
    }
  };

  #onKeyUp = (e: KeyboardEvent) => {
    this.#realKey = false;
    if (e.key !== "Shift") return;
    // Shift pressed and released alone toggles 中/英, as on Windows and IBus.
    // A touch keyboard's shift key sends the very same events, so this only
    // counts once a hardware keyboard has typed here.
    if (this.#shiftAlone && this.#hardware && !keyboardOnScreen() && this.#current) this.toggleMode();
    this.#shiftAlone = false;
  };

  #perform(action: KeyAction): boolean {
    const session = this.#session!;
    switch (action.kind) {
      case "pass":
        return false;
      case "consume":
        return true;
      case "engine":
        return session.pressKey(action.byte);
      case "select":
        // An empty slot sends the digit to the engine as a literal.
        return session.select(action.slot) || session.pressKey(0x31 + action.slot);
      case "backspace":
        return session.backspace();
      case "escape":
        session.cancel();
        return true;
      case "commitRaw":
        return session.commitRaw();
      case "pagePrev":
        session.pagePrev();
        return true;
      case "pageNext":
        session.pageNext();
        return true;
    }
  }

  // MARK: - Touch keyboards

  #onBeforeInput = (e: InputEvent) => {
    const target = this.#current;
    const session = this.#session;
    if (!target || !session || !target.element.contains(e.target as Node)) return;
    // Another input method's own composition, or a key the hardware path
    // already looked at and let through.
    if (e.isComposing || this.#realKey || this.#ownEdit > 0) return;
    if (this.mode() === "en" || (!session.composing && target.imeOff?.())) return;

    switch (e.inputType) {
      case "insertText": {
        const data = e.data ?? "";
        if (data === "") return;
        if (!this.#hardware) this.#setSurface("bar");
        e.preventDefault();
        // Editors with their own input handling (CodeMirror) must not act on it.
        e.stopPropagation();
        // Act after the event: inserting text from inside beforeinput would
        // nest a second edit in the one being cancelled.
        queueMicrotask(() => this.#typeSoft(data));
        return;
      }
      case "deleteContentBackward":
        if (!session.composing) return;
        e.preventDefault();
        e.stopPropagation();
        queueMicrotask(() => session.backspace());
        return;
      case "insertLineBreak":
      case "insertParagraph":
        if (!session.composing) return;
        e.preventDefault();
        e.stopPropagation();
        queueMicrotask(() => session.commitRaw());
        return;
      default:
        // An edit the IME did not make — paste, cut, drop, autocorrect: the
        // composition no longer matches the field, so it goes (as on iOS).
        if (session.composing) session.cancel();
    }
  };

  /** One touch-keyboard insertion, routed as the mobile apps route taps. */
  #typeSoft(data: string): void {
    const session = this.#session!;
    const code = data.length === 1 ? data.charCodeAt(0) : -1;
    if (code < 0x20 || code > 0x7e) {
      // A word from the keyboard's suggestions, an emoji, another script.
      session.insertLiteral(data);
      return;
    }
    // Digits are text on a touch keyboard: candidates are tapped, not numbered.
    if (code >= 0x30 && code <= 0x39) {
      session.insertLiteral(data);
      return;
    }
    if (!session.pressKey(code)) session.insertLiteral(data);
  }

  // MARK: - Pointer and viewport

  #onPointerDown = (e: PointerEvent) => {
    this.#shiftAlone = false;
    const target = this.#current;
    // A tap or click in the field moves its caret away from where the
    // composition would land: drop it, as the iOS keyboard does.
    if (target && this.composing && target.element.contains(e.target as Node)) this.cancel();
  };

  #onViewportChange = () => {
    if (this.composing) this.#updateCaret();
  };

  #onKeyboardChange = () => {
    if (!this.#current || !coarse()) return;
    if (keyboardOnScreen()) this.#setSurface("bar");
    else if (this.#hardware) this.#setSurface("popup");
  };

  #updateCaret(): void {
    this.#setCaret(this.#current?.caretRect() ?? null);
  }

  #applyPendingEngine(): void {
    const pending = this.#pendingEngine;
    if (!pending || !this.#session) return;
    this.#pendingEngine = null;
    this.#session.replaceEngine(pending.engine);
    pending.release();
  }
}

/** The page's one input method. */
export const ime = new ImeController();
