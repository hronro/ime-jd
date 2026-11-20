// The add/edit sheet on phones (iOS: 添加词条 / 编辑词条).

import { createEffect, createSignal, Show } from "solid-js";
import { IME_FIELD_ATTRS } from "../ime/target";
import { ask } from "../ui/Confirm";
import { Dialog } from "../ui/Dialog";
import type { Model, Row } from "./model";
import { problemText } from "./problem";

export type SheetState = { readonly mode: "add" } | { readonly mode: "edit"; readonly row: Row };

export function RowSheet(props: { state: SheetState | null; model: Model; onClose: () => void }) {
  let value: HTMLInputElement | undefined;
  let keys: HTMLInputElement | undefined;
  const [empty, setEmpty] = createSignal(true);

  createEffect(
    () => props.state,
    (state) => {
      if (!state || !value || !keys) return;
      value.value = state.mode === "edit" ? state.row.value : "";
      keys.value = state.mode === "edit" ? state.row.keys : "";
      setEmpty(value.value.trim() === "" && keys.value.trim() === "");
    },
  );

  const verdict = () => {
    const state = props.state;
    if (state?.mode !== "edit") return null;
    const index = props.model.rows().findIndex((r) => r.id === state.row.id);
    const problem = props.model.problems()[index];
    return problem ? problemText(problem) : null;
  };

  const save = () => {
    const state = props.state;
    if (!state || !value || !keys || empty()) return;
    const entry = { value: value.value, keys: keys.value };
    if (state.mode === "add") props.model.appendEntry(entry);
    else props.model.updateRow(state.row.id, entry);
    props.onClose();
  };

  const remove = async () => {
    const state = props.state;
    if (state?.mode !== "edit") return;
    const choice = await ask({
      title: `删除词条「${state.row.value}」？`,
      buttons: [
        { label: "取消", value: "", tone: "quiet" },
        { label: "删除", value: "delete", tone: "danger" },
      ],
    });
    if (choice !== "delete") return;
    props.model.removeRows(new Set([state.row.id]));
    props.onClose();
  };

  const onInput = () => setEmpty((value?.value.trim() ?? "") === "" && (keys?.value.trim() ?? "") === "");

  return (
    <Dialog
      open={props.state !== null}
      title={props.state?.mode === "edit" ? "编辑词条" : "添加词条"}
      size="s"
      onClose={props.onClose}
      onOpen={() => value?.focus()}
    >
      <form
        class="ud-sheet"
        onSubmit={(e) => {
          e.preventDefault();
          save();
        }}
      >
        <input ref={(el) => (value = el)} class="field" placeholder="词" aria-label="词" {...IME_FIELD_ATTRS} {...({ enterkeyhint: "next" } as Record<string, string>)} onInput={onInput} />
        <input
          ref={(el) => (keys = el)}
          class="field ud-sheet-keys"
          placeholder="编码（a-z，1 到 6 个）"
          aria-label="编码"
          data-ime="off"
          {...IME_FIELD_ATTRS}
          {...({ enterkeyhint: "done" } as Record<string, string>)}
          onInput={onInput}
        />
        <Show when={verdict()}>{(text) => <p class="ud-sheet-verdict">目前：{text()}</p>}</Show>
        <div class="ud-sheet-buttons">
          <Show when={props.state?.mode === "edit"}>
            <button type="button" class="btn btn-quiet btn-danger" onClick={() => void remove()}>
              删除
            </button>
          </Show>
          <span class="ud-sheet-gap" />
          <button type="button" class="btn btn-quiet" onClick={props.onClose}>
            取消
          </button>
          <button type="submit" class="btn btn-primary" aria-disabled={empty() ? "true" : "false"}>
            保存
          </button>
        </div>
      </form>
    </Dialog>
  );
}
