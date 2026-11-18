// Where the caret of a <textarea>/<input> sits on screen. Form controls do not
// expose it, so a hidden mirror element copies the control's box and type,
// takes the text up to the caret, and reports where a marker after it lands.

const COPIED = [
  "direction",
  "boxSizing",
  "width",
  "height",
  "overflowX",
  "overflowY",
  "borderTopWidth",
  "borderRightWidth",
  "borderBottomWidth",
  "borderLeftWidth",
  "borderStyle",
  "paddingTop",
  "paddingRight",
  "paddingBottom",
  "paddingLeft",
  "fontStyle",
  "fontVariant",
  "fontWeight",
  "fontStretch",
  "fontSize",
  "fontSizeAdjust",
  "lineHeight",
  "fontFamily",
  "fontFeatureSettings",
  "textAlign",
  "textTransform",
  "textIndent",
  "letterSpacing",
  "wordSpacing",
  "tabSize",
  "wordBreak",
  "overflowWrap",
] as const;

export interface CaretRect {
  /** Viewport coordinates of the caret's left edge. */
  readonly left: number;
  readonly top: number;
  readonly bottom: number;
}

let mirror: HTMLDivElement | null = null;

export function fieldCaretRect(field: HTMLTextAreaElement | HTMLInputElement): CaretRect {
  const box = field.getBoundingClientRect();
  const style = getComputedStyle(field);
  const position = field.selectionEnd ?? field.value.length;

  mirror ??= document.body.appendChild(document.createElement("div"));
  const m = mirror.style;
  for (const prop of COPIED) m[prop] = style[prop];
  m.position = "absolute";
  m.visibility = "hidden";
  m.top = "0";
  m.left = "-9999px";
  m.overflow = "hidden";
  const isInput = field instanceof HTMLInputElement;
  m.whiteSpace = isInput ? "pre" : "pre-wrap";
  if (!isInput) m.overflowWrap = style.overflowWrap || "break-word";

  mirror.textContent = field.value.slice(0, position);
  const marker = mirror.appendChild(document.createElement("span"));
  // A zero-width space keeps the marker on the caret's line even at a wrap.
  marker.textContent = "​";

  const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.3;
  const left = box.left + marker.offsetLeft - field.scrollLeft;
  const top = box.top + marker.offsetTop - field.scrollTop;
  mirror.textContent = "";

  // Keep the result inside the control: a caret scrolled out of view still
  // anchors the popup to the visible edge.
  const clampedTop = Math.min(Math.max(top, box.top), box.bottom - lineHeight);
  const clampedLeft = Math.min(Math.max(left, box.left), box.right);
  return { left: clampedLeft, top: clampedTop, bottom: clampedTop + lineHeight };
}
