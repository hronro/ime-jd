// The phrases file — libjd's own table format — and how a client splits it
// into rows: a port of bindings/swift/UserDictFile.swift. The format is a
// documented contract (core/include/jd.h, core/docs/integration.md), so this
// mirrors only how a line becomes two cells for display; libjd alone says
// what a line means (UserDictProblem / problem.ts).
//
// One `value<TAB>keys` line per phrase, `#` comments, blank lines ignored.
// Rows are read leniently — a line without a TAB becomes a row with empty
// keys, to be fixed in place — and written back as one header comment plus
// one line per entry.

/** One phrase: the committable text and the code that reaches it. */
export interface Entry {
  readonly value: string;
  readonly keys: string;
}

/** A parsed row: the entry plus the 1-based line it came from. */
export interface ParsedRow extends Entry {
  readonly line: number;
}

/** libjd's caps (core/include/jd.h). */
export const MAX_KEY_LENGTH = 6;
export const MAX_VALUE_BYTES = 255;

export const FILE_NAME = "用户自造词.txt";

/** The first line of every file a client writes. */
export const HEADER = `# 键道用户自造词：每行一条，格式为「词<TAB>编码」，编码由 a-z 组成，1 到 ${MAX_KEY_LENGTH} 个字符。`;

/** libjd trims a line of spaces and CRs, and nothing else (not TAB, not U+3000). */
const trimLine = (s: string) => s.replace(/^[ \r]+|[ \r]+$/g, "");
/** …and each field of spaces only. */
export const trimField = (s: string) => s.replace(/^ +| +$/g, "");

export function parse(text: string): ParsedRow[] {
  const rows: ParsedRow[] = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = trimLine(lines[i]!);
    // The first byte, as libjd checks it ("#" + a combining mark is a comment too).
    if (line === "" || line.charCodeAt(0) === 0x23) continue;
    const tab = line.indexOf("\t");
    rows.push(
      tab < 0
        ? { line: i + 1, value: line, keys: "" }
        : { line: i + 1, value: trimField(line.slice(0, tab)), keys: trimField(line.slice(tab + 1)) },
    );
  }
  return rows;
}

/** The header plus one `value<TAB>keys` line per entry, LF-terminated. */
export function serialize(entries: readonly Entry[]): string {
  let text = HEADER + "\n";
  for (const entry of entries) text += `${entry.value}\t${entry.keys}\n`;
  return text;
}

/** The line an entry at `index` occupies after `serialize`. */
export const lineOfEntryAt = (index: number) => index + 2;
