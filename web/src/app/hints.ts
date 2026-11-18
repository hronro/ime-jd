// 编码提示: after the user takes a candidate the long way — a later candidate,
// or a longer code than the word needs — briefly show its best code. The best
// code is libjd's first (`jd_lookup_codes` orders shortest first, ties key by
// key, a user phrase's code ahead of a built-in word's).

import { createSignal } from "solid-js";
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
  const best = engine.lookupCodes(commit.value)[0];
  if (!best) return;
  const shorter = best.keys.length < commit.code.length;
  const earlier = best.keys.length === commit.code.length && best.index < commit.index;
  if (!shorter && !earlier) return;
  const where = best.index > 0 ? `（第 ${best.index + 1} 个候选）` : "";
  clearTimeout(timer);
  setHint({ value: commit.value, code: best.keys + where });
  timer = setTimeout(() => setHint(null), 6000);
}

export function startHints(): void {
  ime.onCandidateCommit(onCommit);
}
