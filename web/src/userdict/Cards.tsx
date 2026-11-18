// Phones: one card per phrase, as in the iOS app — the 词 above, its 编码 and
// libjd's verdict below in the verdict's color. A tap opens the edit sheet.

import { createMemo, For, Show } from "solid-js";
import type { Model, Row } from "./model";
import { problemText } from "./problem";
import { toneOf } from "./Table";

export function Cards(props: { model: Model; onOpen: (row: Row) => void }) {
  const model = props.model;
  const items = createMemo(() => {
    const rows = model.rows();
    const problems = model.problems();
    return model.shown().map((index) => ({ row: rows[index]!, problem: problems[index] ?? null }));
  });

  return (
    <ul class="ud-cards" aria-label="用户自造词">
      <For
        each={items()}
        keyed={(it) => it.row.id}
        fallback={
          <li class="ud-empty">
            <Show when={model.filter() === ""} fallback={<>没有符合「{model.filter()}」的词条</>}>
              尚无词条。轻点「添加」新建一条：一个词和它的编码。与内置词同码时，自造词排在内置词之前。
            </Show>
          </li>
        }
      >
        {(item) => (
          <li>
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
  );
}
