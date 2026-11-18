import { For, Show } from "solid-js";
import { CheckIcon, WarnIcon } from "./icons";
import { dismissToast, holdToast, toasts } from "./toast";

export function Toasts() {
  return (
    <div class="toasts" role="region" aria-label="通知">
      <div class="visually-hidden" aria-live="polite">
        {toasts()
          .map((t) => t.text)
          .join("，")}
      </div>
      <For each={toasts()}>
        {(toast) => (
          <div
            class={["toast", `toast-${toast.tone}`]}
            onFocusIn={() => holdToast(toast.id, true)}
            onFocusOut={() => holdToast(toast.id, false)}
          >
            <span class="toast-icon">{toast.tone === "error" ? <WarnIcon /> : <CheckIcon />}</span>
            <span class="toast-text">{toast.text}</span>
            <Show when={toast.action}>
              {(action) => (
                <button
                  type="button"
                  class="toast-action"
                  onClick={() => {
                    action().run();
                    dismissToast(toast.id);
                  }}
                >
                  {action().label}
                </button>
              )}
            </Show>
          </div>
        )}
      </For>
    </div>
  );
}
