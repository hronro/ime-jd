// Phones: one card per phrase, as in the iOS app — the 词 above, its 编码 and
// libjd's verdict below in the verdict's color. A tap opens the edit sheet.
// Only the cards on screen are in the DOM (virtual.ts), as in the table.

import { createEffect, createMemo, For, Show } from "solid-js";
import type { Model, Row } from "./model";
import { type Problem, problemText } from "./problem";
import { toneOf } from "./Table";
import { createVirtualList } from "./virtual";

/** A card's height in px, its border included; the cards take it from --ud-card. */
const CARD_HEIGHT = 68;

export function Cards(props: { model: Model; onOpen: (row: Row) => void }) {
  const model = props.model;
  const list = createVirtualList(() => model.shown().length, CARD_HEIGHT);

  // A new search starts at its first hit.
  createEffect(
    () => model.filter(),
    () => list.toTop(),
  );

  const items = createMemo(() => {
    const rows = model.rows();
    const problems = model.problems();
    const shown = model.shown();
    const { first, last } = list.window();
    const out: { row: Row; position: number; problem: Problem | null }[] = [];
    for (let position = first; position < last; position++) {
      const index = shown[position]!;
      out.push({ row: rows[index]!, position, problem: problems[index] ?? null });
    }
    return out;
  });

  return (
    <div class="ud-cards" ref={list.ref} style={{ "--ud-card": `${CARD_HEIGHT}px` }}>
      <Show
        when={model.shown().length > 0}
        fallback={
          <p class="ud-empty">
            <Show when={model.filter() === ""} fallback={<>没有符合「{model.filter()}」的词条</>}>
              尚无词条。轻点「添加」新建一条：一个词和它的编码。与内置词同码时，自造词排在内置词之前。
            </Show>
          </p>
        }
      >
        <div class="ud-spacer" style={{ "block-size": `${list.spacer()}px` }}>
          <ul class="ud-card-list" aria-label="用户自造词" style={{ translate: `0 ${list.window().offset}px` }}>
            <For each={items()} keyed={(it) => it.row.id}>
              {(item) => (
                <li aria-setsize={model.shown().length} aria-posinset={item().position + 1}>
                  <button type="button" class="ud-card" onClick={() => props.onOpen(item().row)}>
                    <span class="ud-card-value">{item().row.value || "（空）"}</span>
                    <span class="ud-card-meta">
                      <code>{item().row.keys || "—"}</code>
                      <Show when={item().problem}>
                        {(p) => <span class={["ud-card-verdict", toneOf(p())]}> · {problemText(p())}</span>}
                      </Show>
                    </span>
                  </button>
                </li>
              )}
            </For>
          </ul>
        </div>
      </Show>
    </div>
  );
}
