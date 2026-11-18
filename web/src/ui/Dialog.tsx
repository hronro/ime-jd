// A modal <dialog>: native focus containment, Esc and back-gesture close,
// focus returned to the opener; light dismiss where `closedby` is supported.
// It carries its own IME layer, since a modal makes the page behind inert.

import { createEffect, createSignal, createUniqueId, Show } from "solid-js";
import type { JSX } from "@solidjs/web";
import { ImeLayer } from "../ime/ImeLayer";
import { CloseIcon } from "./icons";
import "./dialog.css";

export interface DialogProps {
  open: boolean;
  title: string;
  onClose: () => void;
  /** A larger sheet (the phrase manager). */
  size?: "s" | "m" | "l";
  /** Extra content beside the title. */
  headerExtra?: JSX.Element;
  children: JSX.Element;
}

export function Dialog(props: DialogProps) {
  const id = createUniqueId();
  const [el, setEl] = createSignal<HTMLDialogElement | null>(null, { ownedWrite: true });

  createEffect(
    () => ({ dialog: el(), open: props.open }),
    ({ dialog, open }) => {
      if (!dialog) return;
      if (open && !dialog.open) dialog.showModal();
      else if (!open && dialog.open) dialog.close();
    },
  );

  return (
    <dialog
      ref={(node) => setEl(node)}
      class={["dlg", `dlg-${props.size ?? "m"}`]}
      aria-labelledby={id}
      {...({ closedby: "any" } as Record<string, string>)}
      onClose={() => props.onClose()}
    >
      <header class="dlg-head">
        <h2 id={id} class="dlg-title">
          {props.title}
        </h2>
        <Show when={props.headerExtra}>{props.headerExtra}</Show>
        <button type="button" class="btn btn-quiet icon-btn dlg-close" aria-label="关闭" onClick={() => props.onClose()}>
          <CloseIcon />
        </button>
      </header>
      <div class="dlg-body">{props.children}</div>
      <ImeLayer host={el()} />
    </dialog>
  );
}
