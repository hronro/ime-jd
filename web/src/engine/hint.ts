// 编码提示's rule: given a word the user just committed — the letters typed
// and where the word sat — and libjd's codes for that word, is there a better
// way to type it? Pure, so it is tested against the real engine.
//
// Cost is counted in keys the way 键道 is typed. The first candidate on a
// page needs no key of its own: the next code's first letter, or a mark,
// commits it (commit-and-jump; after paging the engine's anchor is the first
// candidate on that page). Any other candidate takes a selection key (1-9, or
// `;` for the second), and reaching page N takes N-1 page keys.

import type { Code } from "jd";
import type { CandidateCommit } from "./session";

/** Candidates per page — what 1-9 and the page keys work in. */
const PAGE = 9;

export interface CodeHint {
  /** The better code. */
  readonly keys: string;
  /** Where the word is on it; 0 means first candidate. */
  readonly index: number;
}

/** Keys spent typing `keys` and committing the candidate at `index`. */
export function keyCost(keys: string, index: number): number {
  return keys.length + Math.floor(index / PAGE) + (index % PAGE === 0 ? 0 : 1);
}

/**
 * The code to suggest, or null when the user already took the best way. A
 * code is better when it costs fewer keys, or as many keys with the word
 * further up the list (no hunting for its number). Among equals libjd's order
 * decides: shorter first, ties key by key, a user phrase ahead of a built-in.
 */
export function betterCode(commit: CandidateCommit, codes: readonly Code[]): CodeHint | null {
  const spent = keyCost(commit.code, commit.index);
  let best: Code | null = null;
  let bestCost = Infinity;
  for (const code of codes) {
    const cost = keyCost(code.keys, code.index);
    if (cost < bestCost || (cost === bestCost && best !== null && code.index < best.index)) {
      best = code;
      bestCost = cost;
    }
  }
  if (!best) return null;
  if (bestCost < spent || (bestCost === spent && best.index < commit.index)) {
    return { keys: best.keys, index: best.index };
  }
  return null;
}
