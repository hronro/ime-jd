// Short status messages for the main page (已复制, 已清空 · 撤销). Never shown
// while a modal dialog is open — dialogs report inline instead.

import { createSignal } from "solid-js";

export interface Toast {
  readonly id: number;
  readonly text: string;
  readonly tone: "ok" | "info" | "error";
  readonly action?: { readonly label: string; readonly run: () => void };
}

const [toasts, setToasts] = createSignal<readonly Toast[]>([]);
export { toasts };

let nextId = 1;
const timers = new Map<number, ReturnType<typeof setTimeout>>();

export function showToast(text: string, options: Omit<Partial<Toast>, "id" | "text"> = {}): number {
  const id = nextId++;
  const toast: Toast = { id, text, tone: options.tone ?? "ok", action: options.action };
  // One at a time reads best for these one-line confirmations.
  for (const t of toasts()) dismissToast(t.id);
  setToasts((list) => [...list.filter((t) => t.id !== id), toast]);
  timers.set(id, setTimeout(() => dismissToast(id), toast.action ? 6000 : 2400));
  return id;
}

export function dismissToast(id: number): void {
  clearTimeout(timers.get(id));
  timers.delete(id);
  setToasts((list) => list.filter((t) => t.id !== id));
}

/** Keep a toast up while the user is on its button. */
export function holdToast(id: number, held: boolean): void {
  clearTimeout(timers.get(id));
  if (!held) timers.set(id, setTimeout(() => dismissToast(id), 3000));
}
