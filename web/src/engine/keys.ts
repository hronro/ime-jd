// Maps a hardware key event to what the IME does with it — a port of
// macos/JdIME/Engine/KeyGate.swift, following the routing table in
// core/docs/integration.md: every printable ASCII byte goes to the engine,
// whether or not a composition is in flight; the IME keeps only its own
// bindings (digit select, `-`/`=` and arrow paging) and the navigation /
// cancel / commit keys, and those only while composing.

export type KeyAction =
  | { readonly kind: "pass" }
  | { readonly kind: "consume" }
  | { readonly kind: "engine"; readonly byte: number }
  | { readonly kind: "select"; readonly slot: number }
  | { readonly kind: "backspace" }
  | { readonly kind: "escape" }
  | { readonly kind: "commitRaw" }
  | { readonly kind: "pagePrev" }
  | { readonly kind: "pageNext" };

/** The parts of a `KeyboardEvent` the gate reads. */
export interface KeyInput {
  readonly key: string;
  readonly ctrlKey: boolean;
  readonly metaKey: boolean;
  readonly altKey: boolean;
  readonly shiftKey: boolean;
  readonly isComposing?: boolean;
  readonly keyCode?: number;
}

const PASS: KeyAction = { kind: "pass" };
const CONSUME: KeyAction = { kind: "consume" };

/** Keys that would move the host's caret out of the composition. */
const NAVIGATION = new Set(["Home", "End", "Insert", "Delete", "Tab"]);

/**
 * The printable ASCII byte (0x20–0x7E) a key event types, honoring Shift and
 * Caps Lock — `KeyboardEvent.key` already is the actually-typed character
 * (Shift+/ → `?`, Caps+k → `K`) — or null for anything else.
 */
export function typedByte(key: string): number | null {
  if (key.length !== 1) return null;
  const code = key.charCodeAt(0);
  return code >= 0x20 && code <= 0x7e ? code : null;
}

export interface KeyOptions {
  /**
   * The keys come from a keyboard drawn on screen (iOS sends those as real
   * key events too): candidates are tapped there, so digits and `-`/`=` are
   * text, as in the iOS/Android apps — not selectors or page keys.
   */
  readonly touch?: boolean;
}

export function keyAction(event: KeyInput, composing: boolean, options: KeyOptions = {}): KeyAction {
  // Another input method (or a touch keyboard) is composing in the browser:
  // its keys are not ours. Touch keyboards are handled through `beforeinput`.
  if (event.isComposing || event.keyCode === 229) return PASS;

  // Modifier chords are host shortcuts. Shift and Caps Lock are not: they are
  // how the user types shifted bytes, which the engine wants.
  if (event.ctrlKey || event.metaKey || event.altKey) return PASS;

  if (composing) {
    switch (event.key) {
      case "Escape":
        return { kind: "escape" };
      case "Backspace":
        return { kind: "backspace" };
      case "Enter":
        return { kind: "commitRaw" };
      case "ArrowLeft":
      case "ArrowUp":
      case "PageUp":
        return { kind: "pagePrev" };
      case "ArrowRight":
      case "ArrowDown":
      case "PageDown":
        return { kind: "pageNext" };
    }
    if (NAVIGATION.has(event.key)) return CONSUME;
  }

  const byte = typedByte(event.key);
  if (byte === null) return PASS;

  if (composing && !event.shiftKey && !options.touch) {
    // Our bindings — only their unshifted forms; `!`, `+`, `_`, … are
    // ordinary punctuation for the engine.
    if (byte === 0x2d) return { kind: "pagePrev" }; // '-'
    if (byte === 0x3d) return { kind: "pageNext" }; // '='
    if (byte >= 0x31 && byte <= 0x39) return { kind: "select", slot: byte - 0x31 };
  }

  return { kind: "engine", byte };
}
