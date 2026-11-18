// 编码提示: after the user takes a candidate the long way, briefly show a
// better code for it — fewer keys, or as many keys without picking a later
// candidate (engine/hint.ts has the rule). The codes are libjd's
// (`jd_lookup_codes`, the same call 编码反查 makes).

import { createSignal } from "solid-js";
import { betterCode } from "../engine/hint";
import type { CandidateCommit } from "../engine/session";
import { ime } from "../ime/controller";
import { codeHints } from "../storage/settings";

export interface Hint {
  readonly value: string;
  /** The code to use, with its candidate position when not the first. */
  readonly code: string;
}

const [hint, setHint] = createSignal<Hint | null>(null);
export { hint };

let timer: ReturnType<typeof setTimeout> | undefined;

function onCommit(commit: CandidateCommit): void {
  if (!codeHints()) return;
  const engine = ime.session?.engine;
  if (!engine) return;
  const best = betterCode(commit, engine.lookupCodes(commit.value));
  if (!best) return;
  const where = best.index > 0 ? `（第 ${best.index + 1} 个候选）` : "";
  clearTimeout(timer);
  setHint({ value: commit.value, code: best.keys + where });
  timer = setTimeout(() => setHint(null), 6000);
}

export function startHints(): void {
  ime.onCandidateCommit(onCommit);
}
