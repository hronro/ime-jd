// Where the IME draws its candidates. A modal <dialog> makes everything
// outside it inert (verified in the phase-0 spike), so each dialog carries its
// own layer and only the one hosting the focused field renders.

import { lazy, Loading, Show } from "solid-js";
import { CandidatePopup } from "./CandidatePopup";
import { ime } from "./controller";

const CandidateBar = lazy(() => import("../mobile/CandidateBar"));

export function ImeLayer(props: { host: HTMLDialogElement | null }) {
  const active = () => ime.target() !== null && ime.host() === props.host;
  // Idle, the bar only offers what the page lacks: inside a dialog the 中/英
  // switch (the page's own is in its footer), and ⇥ in the phrases editor.
  const showBar = () =>
    ime.surface() === "bar" &&
    (ime.view().code !== "" || props.host !== null || ime.target()?.wantsTab === true);
  return (
    <>
      <Show when={active() && ime.surface() === "popup"}>
        <CandidatePopup />
      </Show>
      <Show when={active() && showBar()}>
        <Loading fallback={null}>
          <CandidateBar />
        </Loading>
      </Show>
    </>
  );
}
