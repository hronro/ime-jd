// A text field the IME types into. The browser has no input-method API for a
// page, so each kind of editable surface gets an adapter that knows how to
// insert committed text (keeping the field's own undo history) and where its
// caret is on screen.

import { type CaretRect, fieldCaretRect } from "./caret";

export interface ImeTarget {
  /** The focusable element key events arrive on. */
  readonly element: HTMLElement;
  /** Whether Enter (when nothing is composing) inserts a line break. */
  readonly multiline: boolean;
  /** Insert committed text at the caret, replacing any selection. */
  insert(text: string): void;
  /** Where the caret is, in viewport coordinates. */
  caretRect(): CaretRect | null;
  /** Text the user has selected, if any — 编码反查 prefills with it. */
  selectedText(): string;
  /** A TAB means something here (the phrases editor): offer a ⇥ key on touch. */
  readonly wantsTab?: boolean;
  /** Where the caret is, keys are plain letters (the 编码 after a phrase's TAB). */
  imeOff?(): boolean;
}

type Field = HTMLTextAreaElement | HTMLInputElement;

/** Single-line input types that take free text. */
const TEXT_INPUTS = new Set(["text", "search", ""]);

export function isTextField(el: Element): el is Field {
  if (el instanceof HTMLTextAreaElement) return !el.readOnly && !el.disabled;
  if (el instanceof HTMLInputElement) {
    return TEXT_INPUTS.has(el.type) && !el.readOnly && !el.disabled;
  }
  return false;
}

export function fieldTarget(field: Field): ImeTarget {
  return {
    element: field,
    multiline: field instanceof HTMLTextAreaElement,
    insert(text) {
      if (document.activeElement !== field) field.focus();
      // execCommand keeps the insertion on the field's native undo stack and
      // fires the input events a framework listens for. It is deprecated but
      // still the only way to do either; setRangeText is the fallback.
      if (document.execCommand("insertText", false, text)) return;
      const start = field.selectionStart ?? field.value.length;
      const end = field.selectionEnd ?? start;
      field.setRangeText(text, start, end, "end");
      field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
    },
    caretRect: () => fieldCaretRect(field),
    selectedText() {
      const start = field.selectionStart ?? 0;
      const end = field.selectionEnd ?? 0;
      return field.value.slice(start, end);
    },
  };
}

/**
 * The attributes that keep a touch keyboard from second-guessing the IME:
 * Chrome on Android then asks for TYPE_TEXT_FLAG_NO_SUGGESTIONS, and Gboard
 * sends plain per-key insertions (phase-0 probe). Strings, not booleans: a
 * `false` boolean attribute is removed, which would turn spellcheck back on.
 */
export const IME_FIELD_ATTRS = {
  autocomplete: "off",
  autocorrect: "off",
  autocapitalize: "off",
  spellcheck: "false",
} as const;
