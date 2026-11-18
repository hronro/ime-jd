// Which dialog is open. Each feature's code is fetched the first time its
// dialog opens and stays mounted afterwards, so reopening is instant.

import { createSignal } from "solid-js";

export type DialogName = "lookup" | "userdict" | "settings" | "help";

const [openDialogName, setOpen] = createSignal<DialogName | null>(null);
const [mounted, setMounted] = createSignal<ReadonlySet<DialogName>>(new Set());
/** What 编码反查 opens with: the editor's selection, if any. */
const [lookupSeed, setLookupSeed] = createSignal<{ text: string } | null>(null);

export { lookupSeed, mounted, openDialogName };

export function openDialog(name: DialogName): void {
  if (!mounted().has(name)) setMounted((set) => new Set([...set, name]));
  setOpen(name);
}

export function openLookup(text: string): void {
  setLookupSeed({ text });
  openDialog("lookup");
}

export function closeDialog(name: DialogName): void {
  setOpen((current) => (current === name ? null : current));
}
