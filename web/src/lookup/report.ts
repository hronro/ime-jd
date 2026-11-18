// 编码反查's wording — a port of bindings/swift/CodeLookupReport.swift, the
// text every client shows (macOS, Linux, Windows, iOS, Android).

import type { Code } from "jd";

export interface LookupLine {
  readonly keys: string;
  /** 第 N 个候选 and/or 自造词, joined by `，`; null when neither applies. */
  readonly note: string | null;
}

export interface LookupReport {
  /** `「着」的编码`, or `没有找到「…」`. */
  readonly title: string;
  /** The codes in libjd's order — shortest first; empty when not found. */
  readonly lines: readonly LookupLine[];
  /** Why nothing was found; null when something was. */
  readonly message: string | null;
}

/**
 * The query as the engine should see it: spaces, TABs, CRs and LFs dropped
 * from the ends (no phrase starts or ends with one); U+3000 stays.
 */
export function lookupQuery(input: string): string {
  return input.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

/** The query as a title quotes it: a long paste is cut short. */
function shown(query: string): string {
  const chars = [...query];
  return chars.length > 20 ? chars.slice(0, 20).join("") + "…" : query;
}

export function lookupReport(query: string, codes: readonly Code[], userDictEnabled: boolean): LookupReport {
  const word = shown(query);
  if (codes.length === 0) {
    return {
      title: `没有找到「${word}」`,
      lines: [],
      message: userDictEnabled
        ? "内置词库和用户自造词中都没有这个词。"
        : "内置词库中没有这个词。用户自造词未启用，不在查询范围内。",
    };
  }
  return {
    title: `「${word}」的编码`,
    lines: codes.map((code) => {
      const notes: string[] = [];
      if (code.index > 0) notes.push(`第 ${code.index + 1} 个候选`);
      if (code.user) notes.push("自造词");
      return { keys: code.keys, note: notes.length > 0 ? notes.join("，") : null };
    }),
    message: null,
  };
}
