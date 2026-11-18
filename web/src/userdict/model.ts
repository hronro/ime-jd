// The phrase table's state. Every change is written at once — there is no
// pending row — and libjd's verdict on the new text comes back as the status
// column (every client's rule: no client-side validation, no implicit clean-up).

import { type Accessor, createEffect, createMemo, createSignal } from "solid-js";
import { dict, MAX_ENTRIES } from "../dict/service";
import { type Entry, parse, type ParsedRow, serialize, trimField } from "./format";
import { type Problem, problemsForRows } from "./problem";

export interface Row extends Entry {
  /** Stable identity for the view (selection, editing, animations). */
  readonly id: number;
  /** The row's 1-based line in the text libjd last built; null when new. */
  readonly line: number | null;
}

let nextId = 1;
const fromParsed = (p: ParsedRow): Row => ({ id: nextId++, value: p.value, keys: p.keys, line: p.line });

export interface Undo {
  readonly text: string;
  readonly rows: readonly Row[];
}

export function createModel() {
  const [rows, setRows] = createSignal<readonly Row[]>(parse(dict.text()).map(fromParsed));
  const [filter, setFilter] = createSignal("");
  const [selected, setSelected] = createSignal<ReadonlySet<number>>(new Set());
  const [saveError, setSaveError] = createSignal<string | null>(null);
  const [undo, setUndo] = createSignal<Undo | null>(null);

  /** The text this table last wrote: its own echo is not an outside change. */
  let written = dict.text();
  let queue: Promise<void> = Promise.resolve();

  // Another tab, the 文本 view or the linked file changed the phrases.
  createEffect(
    () => dict.text(),
    (text) => {
      if (text === written) return;
      written = text;
      setRows(parse(text).map(fromParsed));
      setSelected(new Set<number>());
    },
  );

  const problems: Accessor<(Problem | null)[]> = createMemo(() =>
    problemsForRows(
      rows().map((r) => r.line),
      dict.report(),
    ),
  );

  /** Indices of the rows the search shows (all of them when empty). */
  const shown = createMemo(() => {
    const q = filter().trim().toLowerCase();
    const all = rows();
    const out: number[] = [];
    for (let i = 0; i < all.length; i++) {
      const row = all[i]!;
      if (q === "" || row.value.toLowerCase().includes(q) || row.keys.toLowerCase().includes(q)) out.push(i);
    }
    return out;
  });

  const counts = createMemo(() => {
    let invalid = 0;
    let duplicate = 0;
    let shared = 0;
    for (const p of problems()) {
      if (p?.kind === "invalid") invalid++;
      else if (p?.kind === "duplicate") duplicate++;
      else if (p?.kind === "shared") shared++;
    }
    return { total: rows().length, invalid, duplicate, shared };
  });

  /**
   * Make `next` the phrases: ASCII spaces trimmed from each field (what libjd
   * would trim), written as the header plus one line per row, rebuilt.
   */
  function commit(next: readonly Row[], options: { undoable?: boolean } = {}): void {
    const before = { text: written, rows: rows() };
    const relined = next.map((row, i) => ({ ...row, value: trimField(row.value), keys: trimField(row.keys), line: i + 2 }));
    const text = serialize(relined);
    if (options.undoable) setUndo(before);
    setRows(relined);
    written = text;
    setSaveError(null);
    queue = queue
      .then(() => dict.save(text))
      .catch((e: unknown) => {
        setSaveError(`无法保存用户自造词：${(e as Error).message ?? e}`);
      });
  }

  function updateRow(id: number, change: Partial<Entry>): void {
    const all = rows();
    const index = all.findIndex((r) => r.id === id);
    if (index < 0) return;
    const row = all[index]!;
    const value = change.value ?? row.value;
    const keys = change.keys ?? row.keys;
    // A row added and left empty goes away (as in the Linux editor).
    if (row.line === null && trimField(value) === "" && trimField(keys) === "") {
      commit(all.filter((r) => r.id !== id));
      return;
    }
    if (value === row.value && keys === row.keys && row.line !== null) return;
    commit(all.map((r) => (r.id === id ? { ...r, value, keys } : r)));
  }

  /** A new empty row below `afterId` (or at the end); its id. Not written until edited. */
  function addRow(afterId: number | null): number | null {
    if (rows().length >= MAX_ENTRIES) return null;
    setFilter("");
    const all = [...rows()];
    const at = afterId === null ? all.length : all.findIndex((r) => r.id === afterId) + 1;
    const row: Row = { id: nextId++, value: "", keys: "", line: null };
    all.splice(at, 0, row);
    setRows(all);
    return row.id;
  }

  /** Add a finished entry (the mobile sheet). */
  function appendEntry(entry: Entry, afterId: number | null = null): boolean {
    if (rows().length >= MAX_ENTRIES) return false;
    const all = [...rows()];
    const at = afterId === null ? all.length : all.findIndex((r) => r.id === afterId) + 1;
    all.splice(at, 0, { id: nextId++, ...entry, line: null });
    commit(all);
    return true;
  }

  function removeRows(ids: ReadonlySet<number>): void {
    commit(
      rows().filter((r) => !ids.has(r.id)),
      { undoable: true },
    );
    setSelected(new Set<number>());
  }

  function moveRow(fromIndex: number, toIndex: number): void {
    if (fromIndex === toIndex) return;
    const all = [...rows()];
    const [row] = all.splice(fromIndex, 1);
    all.splice(toIndex, 0, row!);
    commit(all);
  }

  /** Append another file's rows exactly as they are (no de-duplication). */
  function appendRows(parsed: readonly ParsedRow[]): void {
    commit([...rows(), ...parsed.map(fromParsed)], { undoable: true });
  }

  function restore(): void {
    const saved = undo();
    if (!saved) return;
    setUndo(null);
    setRows(saved.rows);
    written = saved.text;
    queue = queue
      .then(() => dict.save(saved.text))
      .catch((e: unknown) => {
        setSaveError(`无法保存用户自造词：${(e as Error).message}`);
      });
  }

  return {
    rows,
    filter,
    setFilter,
    selected,
    setSelected,
    problems,
    shown,
    counts,
    saveError,
    undo,
    setUndo,
    updateRow,
    addRow,
    appendEntry,
    removeRows,
    moveRow,
    appendRows,
    restore,
    entries: () => rows().map(({ value, keys }) => ({ value, keys })),
  };
}

export type Model = ReturnType<typeof createModel>;
