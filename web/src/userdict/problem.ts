// libjd's verdict on one row, for the status column: the notes the build
// leaves, mapped onto rows by line, with the text every client shows — a port
// of bindings/swift/UserDictProblem.swift (also linux/editor/problem.vala,
// windows/userdict/src/window/problem.rs, Android's UserDictProblem.kt).

import { type UserDictNote, UserDictNoteFlags, type UserDictReport } from "jd";
import { MAX_KEY_LENGTH, MAX_VALUE_BYTES } from "./format";

export type Problem =
  /** In the file, but libjd skips it: it does not parse. */
  | { readonly kind: "invalid"; readonly flags: number }
  /** In the file, but dropped: the same phrase as row `ofRow`, or (null) a built-in word. */
  | { readonly kind: "duplicate"; readonly ofRow: number | null }
  /** Works, listed first — but the code already carries other words. */
  | { readonly kind: "shared"; readonly builtIn: number; readonly otherRow: number | null; readonly peers: number };

const INVALID = UserDictNoteFlags.MALFORMED | UserDictNoteFlags.BAD_KEYS | UserDictNoteFlags.BAD_VALUE;
const SHARED = UserDictNoteFlags.CODE_IN_BUILTIN | UserDictNoteFlags.CODE_IN_LINE;

/**
 * `unit` names what the numbers count: rows of the table (条), or lines of the
 * text (行) in the text view, where line numbers are what the user sees.
 */
export function problemText(problem: Problem, unit: "条" | "行" = "条"): string {
  switch (problem.kind) {
    case "invalid":
      if (problem.flags & UserDictNoteFlags.MALFORMED) return "缺少制表符（无编码），不生效";
      if (problem.flags & UserDictNoteFlags.BAD_KEYS) return `编码无效（1 到 ${MAX_KEY_LENGTH} 个 a-z），不生效`;
      return `词无效（不能为空或含控制字符，最长 ${MAX_VALUE_BYTES} 字节），不生效`;
    case "duplicate":
      return problem.ofRow === null ? "与内置词重复，不生效" : `与第 ${problem.ofRow + 1} ${unit}重复，不生效`;
    case "shared": {
      // "与 2 个内置词及第 3 条等 2 条同码", or either half alone.
      const parts: string[] = [];
      if (problem.builtIn > 0) parts.push(` ${problem.builtIn} 个内置词`);
      if (problem.otherRow !== null) {
        parts.push(
          problem.peers > 1
            ? `第 ${problem.otherRow + 1} ${unit}等 ${problem.peers} ${unit}`
            : `第 ${problem.otherRow + 1} ${unit}`,
        );
      }
      return "与" + parts.join("及") + "同码";
    }
  }
}

/**
 * One verdict per row, from the notes of the build of the text the rows came
 * from. `lines[i]` is row `i`'s 1-based line in that text, null for a row not
 * in it (added, not yet written). A null report — the text could not be built
 * at all — flags nothing.
 */
export function problemsForRows(lines: readonly (number | null)[], report: UserDictReport | null): (Problem | null)[] {
  const problems = new Array<Problem | null>(lines.length).fill(null);
  if (!report || report.notes.length === 0) return problems;
  // The notes come ascending by line, and so do the rows that have one (a
  // table never reorders without rewriting the file): walk the two together,
  // and find a note's other row by a binary search — no table over hundreds
  // of thousands of rows. Rows out of line order take the slow way.
  const rowAt = new Int32Array(lines.length);
  const lineAt = new Int32Array(lines.length);
  let n = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (line === null) continue;
    if (n > 0 && line <= lineAt[n - 1]!) return problemsForUnorderedRows(lines, report);
    rowAt[n] = i;
    lineAt[n] = line;
    n++;
  }
  const rowOfLine = (line: number): number | null => {
    let lo = 0;
    let hi = n;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (lineAt[mid]! < line) lo = mid + 1;
      else hi = mid;
    }
    return lo < n && lineAt[lo] === line ? rowAt[lo]! : null;
  };
  let k = 0;
  for (const note of report.notes) {
    while (k < n && lineAt[k]! < note.line) k++;
    if (k === n) break;
    if (lineAt[k] !== note.line) continue;
    problems[rowAt[k]!] = problemFor(note, note.other > 0 ? rowOfLine(note.other) : null);
  }
  return problems;
}

function problemsForUnorderedRows(lines: readonly (number | null)[], report: UserDictReport): (Problem | null)[] {
  const notes = new Map<number, UserDictNote>();
  for (const note of report.notes) notes.set(note.line, note);
  const rowByLine = new Map<number, number>();
  lines.forEach((line, index) => {
    if (line !== null) rowByLine.set(line, index);
  });
  return lines.map((line) => {
    if (line === null) return null;
    const note = notes.get(line);
    return note ? problemFor(note, rowByLine.get(note.other) ?? null) : null;
  });
}

/** The verdict a note gives its row; `other` is the row of the line it names, if that is a row. */
function problemFor(note: UserDictNote, other: number | null): Problem | null {
  if (note.flags & INVALID) return { kind: "invalid", flags: note.flags };
  if (note.flags & UserDictNoteFlags.REPEATS_LINE) return { kind: "duplicate", ofRow: other };
  if (note.flags & UserDictNoteFlags.REPEATS_BUILTIN) return { kind: "duplicate", ofRow: null };
  if (note.flags & SHARED) {
    return {
      kind: "shared",
      builtIn: note.builtin,
      otherRow: note.flags & UserDictNoteFlags.CODE_IN_LINE ? other : null,
      peers: note.peers,
    };
  }
  return null;
}

/** One note as a problem whose numbers are line numbers (for the text view). */
export function problemForNote(note: UserDictNote): Problem | null {
  const otherLine = note.other > 0 ? note.other - 1 : null;
  if (note.flags & INVALID) return { kind: "invalid", flags: note.flags };
  if (note.flags & UserDictNoteFlags.REPEATS_LINE) return { kind: "duplicate", ofRow: otherLine };
  if (note.flags & UserDictNoteFlags.REPEATS_BUILTIN) return { kind: "duplicate", ofRow: null };
  if (note.flags & SHARED) {
    return {
      kind: "shared",
      builtIn: note.builtin,
      otherRow: note.flags & UserDictNoteFlags.CODE_IN_LINE ? otherLine : null,
      peers: note.peers,
    };
  }
  return null;
}
