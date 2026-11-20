// 编码反查: every code a word is typed with, from libjd's tables and — while
// it is on — the user's phrases. Same prompt and wording as the other clients.

import { createEffect, createSignal, For, Show } from "solid-js";
import { lookupSeed } from "../app/dialogs";
import { ime } from "../ime/controller";
import { IME_FIELD_ATTRS } from "../ime/target";
import { userDictEnabled } from "../storage/settings";
import { Dialog } from "../ui/Dialog";
import { SearchIcon } from "../ui/icons";
import { type LookupReport, lookupQuery, lookupReport } from "./report";
import "./lookup.css";

export default function LookupDialog(props: { open: boolean; onClose: () => void }) {
  let input: HTMLInputElement | undefined;
  const [report, setReport] = createSignal<LookupReport | null>(null);
  const [empty, setEmpty] = createSignal(true);

  const run = () => {
    if (!input) return;
    const query = lookupQuery(input.value);
    const engine = ime.session?.engine;
    if (query === "" || !engine) return;
    setReport(lookupReport(query, engine.lookupCodes(query), userDictEnabled()));
    // Leave the word selected for the next query, as macOS does.
    input.select();
  };

  // Opening: take the editor's selection, if any, and answer at once.
  createEffect(
    () => ({ open: props.open, seed: lookupSeed() }),
    ({ open, seed }) => {
      if (!open || !input) return;
      if (seed && seed.text !== "") {
        input.value = seed.text;
        setEmpty(false);
        run();
      }
    },
  );

  // The field, with whatever it holds selected, so typing replaces it.
  const focusField = () => {
    input?.focus();
    input?.select();
  };

  return (
    <Dialog open={props.open} title="编码反查" size="s" onClose={props.onClose} onOpen={focusField}>
      <form
        class="lookup-form"
        onSubmit={(e) => {
          e.preventDefault();
          run();
        }}
      >
        <label class="lookup-label" for="lookup-input">
          输入或粘贴要查询的词：
        </label>
        <div class="lookup-row">
          <input
            ref={(el) => (input = el)}
            id="lookup-input"
            class="field lookup-input"
            type="text"
            placeholder="例如：键道"
            {...IME_FIELD_ATTRS}
            {...({ enterkeyhint: "search" } as Record<string, string>)}
            onInput={(e) => setEmpty(lookupQuery(e.currentTarget.value) === "")}
          />
          <button type="submit" class="btn btn-primary" aria-disabled={empty() ? "true" : "false"}>
            <SearchIcon />
            查询
          </button>
        </div>
      </form>

      <Show when={report()}>
        {(r) => (
          <section class="lookup-result" aria-live="polite">
            <h3 class="lookup-title">{r().title}</h3>
            <Show when={r().lines.length > 0} fallback={<p class="lookup-message">{r().message}</p>}>
              <ol class="lookup-codes">
                <For each={r().lines}>
                  {(line, i) => (
                    <li class={["lookup-code", { "lookup-best": i() === 0 }]}>
                      <code class="lookup-keys">{line.keys}</code>
                      <Show when={line.note}>
                        <span class="lookup-note">{line.note}</span>
                      </Show>
                    </li>
                  )}
                </For>
              </ol>
            </Show>
          </section>
        )}
      </Show>
    </Dialog>
  );
}
