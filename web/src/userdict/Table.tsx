// The desktop phrase table: 词 / 编码 / 状态, edited in place. A cell is a
// plain button until it is edited, so even 10 000 rows stay light; the input
// that replaces it types through the page's IME (the 编码 cell bypasses it).

import { createEffect, createMemo, createSignal, flush, For, Show, untrack } from "solid-js";
import { IME_FIELD_ATTRS } from "../ime/target";
import type { Model, Row } from "./model";
import { type Problem, problemText } from "./problem";

type Field = "value" | "keys";

interface Editing {
  readonly id: number;
  readonly field: Field;
}

export function Table(props: { model: Model; editRequest: number | null; onEditHandled: () => void }) {
  const model = props.model;
  const [editing, setEditing] = createSignal<Editing | null>(null);
  const [drag, setDrag] = createSignal<{ from: number; to: number } | null>(null);

  // A row the dialog just added opens straight into its 词 cell.
  createEffect(
    () => props.editRequest,
    (id) => {
      if (id === null) return;
      setEditing({ id, field: "value" });
      props.onEditHandled();
    },
  );

  const items = createMemo(() => {
    const rows = model.rows();
    const problems = model.problems();
    return model.shown().map((index) => ({ row: rows[index]!, index, problem: problems[index] ?? null }));
  });

  const allSelected = () => items().length > 0 && items().every((it) => model.selected().has(it.row.id));

  const toggle = (id: number, on: boolean) =>
    model.setSelected((set) => {
      const next = new Set(set);
      if (on) next.add(id);
      else next.delete(id);
      return next;
    });

  const commitEdit = (row: Row, field: Field, value: string, next: Editing | null) => {
    setEditing(next);
    model.updateRow(row.id, { [field]: value });
    if (next) {
      // Move focus now, not after the next microtask: keys typed right after
      // Tab must land in the 编码 cell, not on the page.
      flush();
      const input = document.querySelector<HTMLInputElement>(".ud-input");
      input?.focus();
      input?.select();
    }
  };

  const startDrag = (e: PointerEvent, index: number) => {
    if (model.filter() !== "") return;
    e.preventDefault();
    const grip = e.currentTarget as HTMLElement;
    grip.setPointerCapture(e.pointerId);
    setDrag({ from: index, to: index });
    const move = (ev: PointerEvent) => {
      const el = document.elementFromPoint(ev.clientX, ev.clientY)?.closest<HTMLElement>("[data-index]");
      if (el) setDrag((d) => (d ? { ...d, to: Number(el.dataset.index) } : d));
    };
    const end = (commit: boolean) => () => {
      grip.removeEventListener("pointermove", move);
      const d = drag();
      setDrag(null);
      if (commit && d) model.moveRow(d.from, d.to);
    };
    grip.addEventListener("pointermove", move);
    grip.addEventListener("pointerup", end(true), { once: true });
    grip.addEventListener("pointercancel", end(false), { once: true });
  };

  return (
    <div class="ud-table" role="table" aria-label="用户自造词">
      <div class="ud-head" role="row">
        <span class="ud-col-check" role="columnheader">
          <input
            type="checkbox"
            aria-label="全选"
            checked={allSelected()}
            onChange={(e) =>
              model.setSelected(e.currentTarget.checked ? new Set(items().map((it) => it.row.id)) : new Set<number>())
            }
          />
        </span>
        <span role="columnheader">词</span>
        <span role="columnheader">编码</span>
        <span role="columnheader">状态</span>
        <span role="columnheader" class="visually-hidden">
          排序
        </span>
      </div>

      <div class="ud-body" role="rowgroup">
        <For
          each={items()}
          keyed={(it) => it.row.id}
          fallback={
            <p class="ud-empty">
              <Show
                when={model.filter() === ""}
                fallback={<>没有符合「{model.filter()}」的词条</>}
              >
                还没有词条。点「添加」新建一条，或切换到「文本」成批粘贴，也可以从文本文件导入。与内置词同码时，自造词排在内置词之前。
              </Show>
            </p>
          }
        >
          {(item) => (
            <div
              role="row"
              data-index={item().index}
              class={[
                "ud-row",
                {
                  "ud-selected": model.selected().has(item().row.id),
                  "ud-drop-before": drag()?.to === item().index && drag()!.from > item().index,
                  "ud-drop-after": drag()?.to === item().index && drag()!.from < item().index,
                  "ud-dragging": drag()?.from === item().index,
                },
              ]}
            >
              <span class="ud-col-check" role="cell">
                <input
                  type="checkbox"
                  aria-label={`选择「${item().row.value}」`}
                  checked={model.selected().has(item().row.id)}
                  onChange={(e) => toggle(item().row.id, e.currentTarget.checked)}
                />
              </span>
              <Cell
                row={item().row}
                field="value"
                editing={editing()}
                onEdit={setEditing}
                onCommit={commitEdit}
              />
              <Cell row={item().row} field="keys" editing={editing()} onEdit={setEditing} onCommit={commitEdit} />
              <span role="cell" class={["ud-verdict", toneOf(item().problem)]}>
                {item().problem ? problemText(item().problem!) : ""}
              </span>
              <span
                role="cell"
                class={["ud-grip", { "ud-grip-off": model.filter() !== "" }]}
                title={model.filter() === "" ? "拖动调整顺序（同一编码下的词按此顺序排列）" : "搜索时不能拖动排序"}
                onPointerDown={(e) => startDrag(e, item().index)}
              >
                <svg viewBox="0 0 12 16" aria-hidden="true">
                  <circle cx="3" cy="3" r="1.3" />
                  <circle cx="9" cy="3" r="1.3" />
                  <circle cx="3" cy="8" r="1.3" />
                  <circle cx="9" cy="8" r="1.3" />
                  <circle cx="3" cy="13" r="1.3" />
                  <circle cx="9" cy="13" r="1.3" />
                </svg>
              </span>
            </div>
          )}
        </For>
      </div>
    </div>
  );
}

export function toneOf(problem: Problem | null): string {
  switch (problem?.kind) {
    case "invalid":
      return "tone-bad";
    case "shared":
      return "tone-warn";
    case "duplicate":
      return "tone-dup";
    default:
      return "";
  }
}

function Cell(props: {
  row: Row;
  field: Field;
  editing: Editing | null;
  onEdit: (editing: Editing | null) => void;
  onCommit: (row: Row, field: Field, value: string, next: Editing | null) => void;
}) {
  const isEditing = () => props.editing?.id === props.row.id && props.editing.field === props.field;
  const text = () => props.row[props.field];
  const keys = () => props.field === "keys";

  return (
    <span role="cell" class={["ud-cell", { "ud-cell-keys": keys() }]}>
      <Show
        when={isEditing()}
        fallback={
          <button type="button" class="ud-cell-text" onClick={() => props.onEdit({ id: props.row.id, field: props.field })}>
            <Show when={text() !== ""} fallback={<span class="ud-placeholder">{keys() ? "编码" : "词"}</span>}>
              {text()}
            </Show>
          </button>
        }
      >
        <input
          ref={(el) => {
            // Uncontrolled: the typed text lives in the DOM until the edit
            // ends. A `value` binding would be re-applied whenever the row
            // re-renders (its line changes on every save) and wipe it.
            el.value = untrack(text);
            queueMicrotask(() => {
              // Unless Tab already moved focus here (and the user is typing).
              if (document.activeElement === el) return;
              el.focus();
              el.select();
            });
          }}
          class="ud-input"
          placeholder={keys() ? "编码" : "词"}
          aria-label={keys() ? "编码" : "词"}
          {...IME_FIELD_ATTRS}
          {...(keys() ? { "data-ime": "off" } : {})}
          onBlur={(e) => {
            if (isEditing()) props.onCommit(props.row, props.field, e.currentTarget.value, null);
          }}
          onKeyDown={(e) => {
            const value = e.currentTarget.value;
            if (e.key === "Enter") {
              e.preventDefault();
              props.onCommit(props.row, props.field, value, null);
            } else if (e.key === "Escape") {
              // Ends the edit only — not the dialog.
              e.preventDefault();
              props.onEdit(null);
            } else if (e.key === "Tab" && !e.shiftKey && !keys()) {
              e.preventDefault();
              props.onCommit(props.row, props.field, value, { id: props.row.id, field: "keys" });
            }
          }}
        />
      </Show>
    </span>
  );
}
