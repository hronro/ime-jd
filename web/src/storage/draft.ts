// The editor's text survives a reload, a crash or a closed tab. Kept in
// localStorage — synchronous, so the write on `pagehide` always lands.

import { readLocal, writeLocal } from "./local";

const KEY = "jd.draft";
const DELAY = 500;

let timer: ReturnType<typeof setTimeout> | undefined;
let pending: string | null = null;

export function loadDraft(): string {
  return readLocal(KEY) ?? "";
}

export function saveDraft(text: string): void {
  pending = text;
  clearTimeout(timer);
  timer = setTimeout(flushDraft, DELAY);
}

export function flushDraft(): void {
  clearTimeout(timer);
  if (pending === null) return;
  writeLocal(KEY, pending === "" ? null : pending);
  pending = null;
}

addEventListener("pagehide", flushDraft);
addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") flushDraft();
});
