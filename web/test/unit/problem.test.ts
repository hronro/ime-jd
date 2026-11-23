import { describe, expect, test } from "vitest";
import { problemsForRows, problemText } from "../../src/userdict/problem";
import { parse, serialize } from "../../src/userdict/format";
import { jd } from "./wasm";

const verdicts = (entries: { value: string; keys: string }[]) => {
  const text = serialize(entries);
  const { dict, report } = jd.buildUserDict(text);
  dict.dispose();
  return problemsForRows(
    parse(text).map((r) => r.line),
    report,
  ).map((p) => (p ? problemText(p) : null));
};

describe("row verdicts", () => {
  test("invalid rows say why, in the shared wording", () => {
    expect(verdicts([{ value: "缺编码", keys: "" }])[0]).toBe("编码无效（1 到 6 个 a-z，开头可以有 ;），不生效");
    expect(verdicts([{ value: "词", keys: "toolongx" }])[0]).toBe("编码无效（1 到 6 个 a-z，开头可以有 ;），不生效");
    expect(verdicts([{ value: "", keys: "zz" }])[0]).toBe("词无效（不能为空或含控制字符，最长 1023 字节），不生效");
  });

  test("a line with no TAB is malformed", () => {
    const text = "no tab here\n";
    const { dict, report } = jd.buildUserDict(text);
    dict.dispose();
    const [p] = problemsForRows([1], report);
    expect(problemText(p!)).toBe("缺少制表符（无编码），不生效");
  });

  test("a repeat of an earlier row names it; a repeat of a built-in word says so", () => {
    const v = verdicts([
      { value: "键道", keys: "zzzzzz" },
      { value: "键道", keys: "zzzzzz" },
      { value: "不", keys: "b" },
    ]);
    expect(v[1]).toBe("与第 1 条重复，不生效");
    expect(v[2]).toBe("与内置词重复，不生效");
  });

  test("shared codes count built-in words and peers", () => {
    const v = verdicts([
      { value: "测试一", keys: "zzzzzz" },
      { value: "测试二", keys: "zzzzzz" },
      { value: "测试三", keys: "zzzzzz" },
    ]);
    expect(v[0]).toMatch(/^与第 2 条等 2 条同码$/);
    expect(v[1]).toBe("与第 1 条等 2 条同码");
    const b = verdicts([{ value: "测试词", keys: "b" }]);
    expect(b[0]).toMatch(/^与 \d+ 个内置词同码$/);
  });

  test("no report flags nothing", () => {
    expect(problemsForRows([2, 3, null], null)).toEqual([null, null, null]);
  });

  test("rows in line order, rows out of it and rows not yet written get the same verdicts", () => {
    const text = serialize([
      { value: "测试一", keys: "zzzzzz" },
      { value: "缺编码", keys: "" },
      { value: "测试一", keys: "zzzzzz" },
      { value: "不", keys: "b" },
      { value: "测试二", keys: "zzzzzz" },
    ]);
    const { dict, report } = jd.buildUserDict(text);
    dict.dispose();
    const lines = parse(text).map((r) => r.line);
    const inOrder = problemsForRows(lines, report);
    expect(inOrder.map((p) => p?.kind ?? null)).toEqual(["shared", "invalid", "duplicate", "duplicate", "shared"]);
    expect(inOrder[2]).toEqual({ kind: "duplicate", ofRow: 0 });

    // A new row in the middle (no line yet) shifts the rows a note names.
    const withNew = problemsForRows([lines[0]!, null, ...lines.slice(1)], report);
    expect(withNew[1]).toBeNull();
    expect(withNew[3]).toEqual({ kind: "duplicate", ofRow: 0 });
    expect(withNew[5]).toEqual({ ...inOrder[4], otherRow: 0 });

    // Reordered rows (dragged, not yet rewritten): the slow way, same words.
    const reversed = [...lines].reverse();
    const fromReversed = problemsForRows(reversed, report);
    expect(fromReversed[2]).toEqual({ kind: "duplicate", ofRow: 4 });
    expect(fromReversed.map((p) => p?.kind ?? null)).toEqual(inOrder.map((p) => p?.kind ?? null).reverse());
  });
});
