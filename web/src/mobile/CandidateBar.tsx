// The touch candidate bar — a port of ios/Keyboard/UI/CandidateBarView.swift,
// docked above the system keyboard instead of inside one: the typed code on
// the left, a freely scrolling row of `词 〔hint〕` fetched 16 at a time, and a
// chevron that opens the full grid when there are more than 9. No first-
// candidate highlight (the iOS rule: every cell is a peer, a tap picks it).
//
// Idle, it offers what a touch keyboard lacks: the 中/英 switch (a touch
// keyboard sends no lone Shift), the code hint, and ⇥ in the phrases editor.

import { createEffect, createSignal, For, onSettled, Show } from "solid-js";
import type { Candidate } from "jd";
import { hint } from "../app/hints";
import { ime } from "../ime/controller";
import { codeHints } from "../storage/settings";
import { ChevronDown, ChevronUp, TabIcon } from "../ui/icons";
import { dock } from "./dock";
import "./bar.css";

const WINDOW = 16;
const BAR_HEIGHT = 54;

export default function CandidateBar() {
  let bar: HTMLDivElement | undefined;
  let row: HTMLDivElement | undefined;
  // Writable derivations: every new composition (or none) starts over from
  // the first window, scrolled to the start, grid closed.
  const [loaded, setLoaded] = createSignal<readonly Candidate[]>(() =>
    ime.view().total > 0 ? (ime.session?.readRange(0, WINDOW) ?? []) : [],
  );
  const [expanded, setExpanded] = createSignal<boolean>(() => (ime.view(), false));
  createEffect(
    () => ime.view(),
    () => {
      if (row) row.scrollLeft = 0;
    },
  );

  const loadMore = () => {
    const have = loaded().length;
    if (have >= ime.view().total) return;
    const more = ime.session?.readRange(have, WINDOW) ?? [];
    if (more.length > 0) setLoaded((list) => [...list, ...more]);
  };

  const pick = (index: number, candidate: Candidate) => ime.pick(index, candidate.value);

  onSettled(() => {
    const root = document.documentElement;
    root.style.setProperty("--ime-bar", `${BAR_HEIGHT}px`);
    const undock = dock(bar!, BAR_HEIGHT);
    bar!.showPopover();
    return () => {
      undock();
      root.style.removeProperty("--ime-bar");
    };
  });

  const composing = () => ime.view().code !== "";

  return (
    <div
      ref={(el) => (bar = el)}
      popover="manual"
      class={["imebar", { "imebar-open": expanded() }]}
      // Taps must leave focus — and the keyboard — where they are.
      onPointerDown={(e) => e.preventDefault()}
      onMouseDown={(e) => e.preventDefault()}
    >
      <Show when={expanded()}>
        <div class="imegrid" role="listbox" aria-label="全部候选" onScroll={(e) => nearEnd(e.currentTarget, "y") && loadMore()}>
          <For each={loaded()}>
            {(candidate, i) => (
              <button type="button" role="option" class="imegrid-cell" tabindex="-1" onClick={() => pick(i(), candidate)}>
                {candidate.value}
                <Show when={candidate.hint}>
                  <span class="imebar-hint">〔{candidate.hint}〕</span>
                </Show>
              </button>
            )}
          </For>
        </div>
      </Show>

      <div class="imebar-strip">
        <Show
          when={composing()}
          fallback={
            <div class="imebar-idle">
              <button
                type="button"
                tabindex="-1"
                class={["imebar-mode", { "imebar-mode-en": ime.mode() === "en" }]}
                aria-label={`当前${ime.mode() === "zh" ? "中文" : "英文"}，点按切换`}
                onClick={() => ime.toggleMode()}
              >
                {ime.mode() === "zh" ? "中" : "英"}
              </button>
              <Show when={ime.notice()}>{(why) => <span class="imebar-tip imebar-notice">{why()}</span>}</Show>
              <Show when={!ime.notice() && codeHints() && hint()}>
                {(h) => (
                  <span class="imebar-tip">
                    {h().value} → <b>{h().code}</b>
                  </span>
                )}
              </Show>
              <Show when={ime.target()?.wantsTab}>
                <button type="button" tabindex="-1" class="imebar-key" aria-label="制表符" onClick={() => ime.insertLiteral("\t")}>
                  <TabIcon />
                </button>
              </Show>
            </div>
          }
        >
          <span class="imebar-code">{ime.view().code}</span>
          <div
            ref={(el) => (row = el)}
            class="imebar-row"
            role="listbox"
            aria-label="候选"
            onScroll={(e) => nearEnd(e.currentTarget, "x") && loadMore()}
          >
            <For each={loaded()}>
              {(candidate, i) => (
                <button type="button" role="option" class="imebar-cell" tabindex="-1" onClick={() => pick(i(), candidate)}>
                  {candidate.value}
                  <Show when={candidate.hint}>
                    <span class="imebar-hint"> 〔{candidate.hint}〕</span>
                  </Show>
                </button>
              )}
            </For>
          </div>
          <Show when={ime.view().total > 9}>
            <button
              type="button"
              tabindex="-1"
              class="imebar-expand"
              aria-label={expanded() ? "收起候选" : "展开全部候选"}
              aria-expanded={expanded() ? "true" : "false"}
              onClick={() => setExpanded((open) => !open)}
            >
              {expanded() ? <ChevronUp /> : <ChevronDown />}
            </button>
          </Show>
        </Show>
      </div>
    </div>
  );
}

/** Within two screens of the end: time to fetch the next window. */
function nearEnd(el: HTMLElement, axis: "x" | "y"): boolean {
  return axis === "x"
    ? el.scrollLeft + 2 * el.clientWidth >= el.scrollWidth
    : el.scrollTop + 1.5 * el.clientHeight >= el.scrollHeight;
}
