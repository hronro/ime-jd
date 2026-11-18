// A small modal question (an alert in the desktop clients). Opened on top of
// another modal it stacks natively.

import { createEffect, createSignal, createUniqueId, For, Show } from "solid-js";
import "./confirm.css";

export interface ConfirmButton {
  readonly label: string;
  readonly value: string;
  readonly tone?: "primary" | "danger" | "quiet";
}

export interface ConfirmRequest {
  readonly title: string;
  readonly text?: string;
  readonly buttons: readonly ConfirmButton[];
}

const [request, setRequest] = createSignal<(ConfirmRequest & { resolve: (value: string) => void }) | null>(null);

/** Ask; resolves with the chosen button's value, or "" when dismissed. */
export function ask(req: ConfirmRequest): Promise<string> {
  return new Promise((resolve) => setRequest({ ...req, resolve }));
}

/** Mount once inside each dialog that may ask (so it stacks on top of it). */
export function ConfirmHost() {
  const id = createUniqueId();
  const [el, setEl] = createSignal<HTMLDialogElement | null>(null, { ownedWrite: true });

  createEffect(
    () => ({ dialog: el(), req: request() }),
    ({ dialog, req }) => {
      if (!dialog) return;
      if (req && !dialog.open) dialog.showModal();
      else if (!req && dialog.open) dialog.close();
    },
  );

  const answer = (value: string) => {
    request()?.resolve(value);
    setRequest(null);
  };

  return (
    <dialog
      ref={(node) => setEl(node)}
      class="confirm"
      aria-labelledby={id}
      onClose={() => request() && answer("")}
    >
      <Show when={request()}>
        {(req) => (
          <form method="dialog" class="confirm-body" onSubmit={(e) => e.preventDefault()}>
            <h2 id={id} class="confirm-title">
              {req().title}
            </h2>
            <Show when={req().text}>
              {(text) => (
                <For each={text().split("\n")}>{(line) => <p class="confirm-text">{line}</p>}</For>
              )}
            </Show>
            <div class="confirm-buttons">
              <For each={req().buttons}>
                {(button, i) => (
                  <button
                    type="button"
                    class={[
                      "btn",
                      { "btn-primary": button.tone === "primary", "btn-danger": button.tone === "danger", "btn-quiet": button.tone === "quiet" },
                    ]}
                    autofocus={i() === req().buttons.length - 1}
                    onClick={() => answer(button.value)}
                  >
                    {button.label}
                  </button>
                )}
              </For>
            </div>
          </form>
        )}
      </Show>
    </dialog>
  );
}
