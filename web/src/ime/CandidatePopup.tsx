// The desktop candidate window: one row of 9 at the caret, like the system
// panels on macOS/Linux and the Windows client's — the typed code above, the
// first candidate (what space commits) gently marked, 1-9 picks, −/= pages.

import { createEffect, For, Show } from "solid-js";
import { InputSession } from "../engine/session";
import { ChevronLeft, ChevronRight } from "../ui/icons";
import type { CaretRect } from "./caret";
import { ime } from "./controller";
import "./candidates.css";

const PAGE = InputSession.PAGE_SIZE;
const MARGIN = 8;

function place(el: HTMLElement, caret: CaretRect | null): void {
  const vv = window.visualViewport;
  const viewW = vv?.width ?? document.documentElement.clientWidth;
  const viewH = vv?.height ?? innerHeight;
  const offX = vv?.offsetLeft ?? 0;
  const offY = vv?.offsetTop ?? 0;
  const w = el.offsetWidth;
  const h = el.offsetHeight;
  let left = caret ? caret.left - 18 : (viewW - w) / 2;
  let top = caret ? caret.bottom + 8 : viewH - h - MARGIN;
  // Flip above the line when there is no room below it.
  if (caret && top + h > offY + viewH - MARGIN) top = caret.top - h - 8;
  left = Math.min(Math.max(left, offX + MARGIN), offX + viewW - w - MARGIN);
  top = Math.min(Math.max(top, offY + MARGIN), offY + viewH - h - MARGIN);
  el.style.translate = `${Math.round(left)}px ${Math.round(top)}px`;
}

export function CandidatePopup() {
  let el: HTMLDivElement | undefined;

  createEffect(
    () => ({ view: ime.view(), caret: ime.caret() }),
    ({ view, caret }) => {
      if (!el) return;
      if (view.code === "") {
        if (el.matches(":popover-open")) el.hidePopover();
        return;
      }
      if (!el.matches(":popover-open")) el.showPopover();
      place(el, caret);
    },
  );

  const pages = () => Math.ceil(ime.view().total / PAGE);
  const page = () => Math.floor(ime.view().pageStart / PAGE) + 1;

  return (
    <div
      ref={(node) => (el = node)}
      popover="manual"
      class="cand-popup"
      // Clicking a candidate must not take focus from the field.
      onPointerDown={(e) => e.preventDefault()}
      onMouseDown={(e) => e.preventDefault()}
    >
      <div class="cand-head">
        <span class="cand-code">{ime.view().code}</span>
        <Show when={ime.view().total > PAGE}>
          <span class="cand-pager">
            <button
              type="button"
              tabindex="-1"
              class="cand-step"
              aria-label="上一页"
              disabled={page() === 1}
              onClick={() => ime.pagePrev()}
            >
              <ChevronLeft />
            </button>
            <span class="cand-page">
              {page()}
              <span class="cand-of">/{pages()}</span>
            </span>
            <button
              type="button"
              tabindex="-1"
              class="cand-step"
              aria-label="下一页"
              disabled={page() === pages()}
              onClick={() => ime.pageNext()}
            >
              <ChevronRight />
            </button>
          </span>
        </Show>
      </div>
      <ol class="cand-list" role="listbox" aria-label="候选">
        <For each={ime.view().page} keyed={false}>
          {(candidate, i) => (
            <li
              role="option"
              aria-selected={i === 0 ? "true" : "false"}
              class={["cand", { "cand-anchor": i === 0 }]}
              onClick={() => ime.pick(ime.view().pageStart + i, candidate().value)}
            >
              <span class="cand-num">{i + 1}</span>
              <span class="cand-value">{candidate().value}</span>
              <Show when={candidate().hint}>
                {(hint) => <span class="cand-hint">〔{hint()}〕</span>}
              </Show>
            </li>
          )}
        </For>
      </ol>
    </div>
  );
}
