// A window onto a long list: the rows on screen and a few either side, out of
// however many there are. A phrase list holds up to 500 000 phrases; the DOM
// holds a screenful of them, so opening, scrolling and every edit cost the
// same at any size.
//
// Every row is one fixed height (the CSS sets it from the same number). The
// scroll box holds a spacer as tall as all the rows, and the rendered rows sit
// in one block moved to where the first of them belongs — in DOM order, which
// is the order they are seen, tabbed through and read. Browsers cap how tall
// an element may be (Firefox near 17.9 million px; 500 000 rows of 42 px are
// 21 million), so past CAP the spacer stops growing and scrolling is scaled:
// a pixel of scrollbar is then a little more than a pixel of rows.

import { type Accessor, createMemo, createSignal, onSettled, untrack } from "solid-js";

const CAP = 8_000_000;
/** Rows rendered beyond each edge: keyboard focus can step into them. */
const OVERSCAN = 6;

/** The rendered rows, `[first, last)`, and where the block of them starts. */
export interface Window {
  readonly first: number;
  readonly last: number;
  /** The block's top, in the spacer's coordinates. */
  readonly offset: number;
}

function windowAt(count: number, rowHeight: number, top: number, height: number): Window {
  const total = count * rowHeight;
  const spacer = Math.min(total, CAP);
  // The real scroll position, in rows' pixels, clamped: a list that just got
  // shorter may still report the old position until the browser clamps it.
  const scaled = total > spacer && spacer > height;
  let real = scaled ? (top * (total - height)) / (spacer - height) : top;
  real = Math.max(0, Math.min(real, total - height));
  const first = Math.max(0, Math.floor(real / rowHeight) - OVERSCAN);
  const last = Math.min(count, Math.ceil((real + height) / rowHeight) + OVERSCAN);
  // Row `first` belongs `first * rowHeight - real` below the box's top edge.
  return { first, last, offset: top + first * rowHeight - real };
}

export interface VirtualList {
  /** For the scroll box's `ref`. */
  readonly ref: (el: HTMLElement) => void;
  readonly window: Accessor<Window>;
  /** The spacer's height, in px. */
  readonly spacer: Accessor<number>;
  /** Scroll as little as it takes to bring row `index` into view. */
  reveal(index: number): void;
  /** Back to the first row. */
  toTop(): void;
}

/**
 * The window over `count()` rows of `rowHeight` px each. `beforeShift` hears
 * of each new window before it renders — the moment to end an edit in a row
 * about to leave the DOM, while its input can still say what it holds.
 */
export function createVirtualList(
  count: Accessor<number>,
  rowHeight: number,
  beforeShift?: (next: Window) => void,
): VirtualList {
  const [top, setTop] = createSignal(0);
  const [height, setHeight] = createSignal(0);
  let box: HTMLElement | undefined;

  const window = createMemo(() => windowAt(count(), rowHeight, top(), height()));
  const spacer = createMemo(() => Math.min(count() * rowHeight, CAP));

  const sync = () => {
    if (!box) return;
    beforeShift?.(windowAt(untrack(count), rowHeight, box.scrollTop, box.clientHeight));
    setTop(box.scrollTop);
    setHeight(box.clientHeight);
  };

  onSettled(() => {
    const el = box;
    if (!el) return;
    el.addEventListener("scroll", sync, { passive: true });
    const observer = new ResizeObserver(sync);
    observer.observe(el);
    sync();
    return () => {
      el.removeEventListener("scroll", sync);
      observer.disconnect();
    };
  });

  const scrollTo = (position: number, retry: () => void) => {
    if (!box) return;
    box.scrollTop = position;
    sync();
    // A row just added may lie past the spacer's end until the spacer has
    // grown to hold it, which is the next render: try again after it.
    if (Math.abs(box.scrollTop - position) > 1) requestAnimationFrame(retry);
  };

  function reveal(index: number, again = true): void {
    if (!box) return;
    const n = untrack(count);
    const h = box.clientHeight;
    const total = n * rowHeight;
    const spacerHeight = Math.min(total, CAP);
    const scaled = total > spacerHeight && spacerHeight > h;
    const toReal = (y: number) => (scaled ? (y * (total - h)) / (spacerHeight - h) : y);
    const fromReal = (y: number) => (scaled ? (y * (spacerHeight - h)) / (total - h) : y);
    const real = toReal(box.scrollTop);
    let target = real;
    if (index * rowHeight < real) target = index * rowHeight;
    else if ((index + 1) * rowHeight > real + h) target = (index + 1) * rowHeight - h;
    if (target === real) return;
    scrollTo(fromReal(target), () => again && reveal(index, false));
  }

  return {
    ref: (el) => (box = el),
    window,
    spacer,
    reveal: (index) => reveal(index),
    toTop: () => scrollTo(0, () => {}),
  };
}
