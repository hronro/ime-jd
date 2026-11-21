// The desktop phrase table: 词 / 编码 / 状态, edited in place. Only the rows
// on screen are in the DOM (virtual.ts), so 500 000 rows cost what a
// screenful does; a cell is a plain button until it is edited, and the input
// that replaces it types through the page's IME (the 编码 cell bypasses it).

import { createEffect, createMemo, createSignal, flush, For, Show, untrack } from "solid-js";
import { IME_FIELD_ATTRS } from "../ime/target";
import type { Model, Row } from "./model";
import { type Problem, problemText } from "./problem";
import { createVirtualList, type Window } from "./virtual";

/** A row's height in px, its border included; `.ud-row` takes it from --ud-row. */
const ROW_HEIGHT = 42;

type Field = "value" | "keys";

interface Editing {
  readonly id: number;
  readonly field: Field;
}

export function Table(props: { model: Model; editRequest: number | null; onEditHandled: () => void }) {
  const model = props.model;
  const [editing, setEditing] = createSignal<Editing | null>(null);
  const [drag, setDrag] = createSignal<{ from: number; to: number } | null>(null);

  // A cell's input goes with its row when the row scrolls out of the
  // rendered window: end the edit first, while the input still holds the
  // text, so it is saved as a click elsewhere would save it.
  const endEditLeaving = (next: Window) => {
    const input = document.activeElement;
    if (!(input instanceof HTMLInputElement) || !input.classList.contains("ud-input")) return;
    const position = Number(input.closest("[aria-rowindex]")?.getAttribute("aria-rowindex")) - 2;
    if (!(position >= next.first && position < next.last)) input.blur();
  };

  const list = createVirtualList(() => model.shown().length, ROW_HEIGHT, endEditLeaving);

  // A new search starts at its first hit.
  createEffect(
    () => model.filter(),
    () => list.toTop(),
  );

  // A row the dialog just added opens straight into its 词 cell — once it is
  // on screen, since only the rows there have cells.
  createEffect(
    () => props.editRequest,
    (id) => {
      if (id === null) return;
      const position = untrack(() => positionOf(id));
      if (position >= 0) list.reveal(position);
      setEditing({ id, field: "value" });
      props.onEditHandled();
    },
  );

  /** Where the row `id` is among the shown rows; -1 when it is not shown. */
  const positionOf = (id: number) => {
    const index = model.rows().findIndex((r) => r.id === id);
    // The shown rows are row indices, ascending.
    const shown = model.shown();
    let lo = 0;
    let hi = shown.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (shown[mid]! < index) lo = mid + 1;
      else hi = mid;
    }
    return index >= 0 && shown[lo] === index ? lo : -1;
  };

  /** The rows in the rendered window, each with its row index and its place among the shown. */
  const items = createMemo(() => {
    const rows = model.rows();
    const problems = model.problems();
    const shown = model.shown();
    const { first, last } = list.window();
    const out: { row: Row; index: number; position: number; problem: Problem | null }[] = [];
    for (let position = first; position < last; position++) {
      const index = shown[position]!;
      out.push({ row: rows[index]!, index, position, problem: problems[index] ?? null });
    }
    return out;
  });

  // Every shown row selected: a size check settles it unless it might be so.
  const allSelected = createMemo(() => {
    const shown = model.shown();
    const selected = model.selected();
    if (shown.length === 0 || selected.size < shown.length) return false;
    const rows = model.rows();
    return shown.every((index) => selected.has(rows[index]!.id));
  });

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
    <div
      class="ud-table"
      role="table"
      aria-label="用户自造词"
      aria-rowcount={model.shown().length + 1}
      style={{ "--ud-row": `${ROW_HEIGHT}px` }}
    >
      <div class="ud-head" role="row" aria-rowindex={1}>
        <span class="ud-col-check" role="columnheader">
          <input
            type="checkbox"
            aria-label="全选"
            checked={allSelected()}
            onChange={(e) => {
              const rows = model.rows();
              model.setSelected(
                e.currentTarget.checked ? new Set(model.shown().map((index) => rows[index]!.id)) : new Set<number>(),
              );
            }}
          />
        </span>
        <span role="columnheader">词</span>
        <span role="columnheader">编码</span>
        <span role="columnheader">状态</span>
        <span role="columnheader" class="visually-hidden">
          排序
        </span>
      </div>

      <div class="ud-body" role="rowgroup" ref={list.ref}>
        <Show
          when={model.shown().length > 0}
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
          <div class="ud-spacer" style={{ "block-size": `${list.spacer()}px` }}>
            <div class="ud-window" style={{ translate: `0 ${list.window().offset}px` }}>
              <For each={items()} keyed={(it) => it.row.id}>
                {(item) => (
                  <div
                    role="row"
                    aria-rowindex={item().position + 2}
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
                    <span
                      role="cell"
                      class={["ud-verdict", toneOf(item().problem)]}
                      title={item().problem ? problemText(item().problem!) : undefined}
                    >
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
        </Show>
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
