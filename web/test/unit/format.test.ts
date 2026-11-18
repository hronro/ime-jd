// Mirrors macos/JdIMETests/UserDictFileTests.swift.
import { describe, expect, test } from "vitest";
import { fnv1a64, decodeText, NotUtf8Error } from "../../src/storage/userdict";
import { HEADER, lineOfEntryAt, parse, serialize } from "../../src/userdict/format";
import { jd } from "./wasm";

describe("phrases file", () => {
  test("parse skips comments and blanks and keeps line numbers", () => {
    const text = "# header\n\n你好\tnh\r\n  世界 \t sj  \n# tail\n键道\tjd";
    expect(parse(text)).toEqual([
      { line: 3, value: "你好", keys: "nh" },
      { line: 4, value: "世界", keys: "sj" },
      { line: 6, value: "键道", keys: "jd" },
    ]);
  });

  test("parse is lenient about missing tabs; libjd says what is wrong", () => {
    const rows = parse("no tab here\n好\thz\n");
    expect(rows).toHaveLength(2);
    expect(rows[0]).toEqual({ line: 1, value: "no tab here", keys: "" });
    const { dict, report } = jd.buildUserDict("no tab here\n好\thz\n");
    expect(report.notes.filter((n) => n.flags & 16).map((n) => n.line)).toEqual([1]);
    dict.dispose();
  });

  test("a comment is read by its first byte", () => {
    const text = "#́ 注释\tzzzzza\n键道\tzzzzzz\n";
    expect(parse(text)).toEqual([{ line: 2, value: "键道", keys: "zzzzzz" }]);
    const { dict, report } = jd.buildUserDict(text);
    expect(report.entries).toBe(1);
    expect(report.invalid).toBe(0);
    dict.dispose();
  });

  test("only spaces and CR are trimmed — not TAB-adjacent U+3000", () => {
    expect(parse("　好\thz\n")).toEqual([{ line: 1, value: "　好", keys: "hz" }]);
  });

  test("serialize writes the header and round-trips", () => {
    const entries = [
      { value: "你好", keys: "nh" },
      { value: "键道输入法", keys: "jdsrf" },
    ];
    const text = serialize(entries);
    expect(text.startsWith(HEADER + "\n")).toBe(true);
    expect(text.endsWith("\n")).toBe(true);
    expect(text).not.toContain("\r");
    const rows = parse(text);
    expect(rows.map(({ value, keys }) => ({ value, keys }))).toEqual(entries);
    expect(rows.map((r) => r.line)).toEqual([2, 3]);
    expect(rows.map((r) => r.line)).toEqual(entries.map((_, i) => lineOfEntryAt(i)));
    expect(serialize([])).toBe(HEADER + "\n");
  });

  test("the header is a valid comment for the engine", () => {
    const { dict, report } = jd.buildUserDict(serialize([{ value: "键道", keys: "zzzzzz" }]));
    expect(report.entries).toBe(1);
    expect(report.dropped).toBe(0);
    dict.dispose();
  });

  test("decoding drops a BOM and rejects non-UTF-8", () => {
    const bom = [0xef, 0xbb, 0xbf];
    expect(decodeText(new Uint8Array([...bom, ...new TextEncoder().encode("好\thz\n")]))).toBe("好\thz\n");
    expect(decodeText(new Uint8Array())).toBe("");
    expect(() => decodeText(new Uint8Array([0xc4, 0xe3, 0x09, 0x61]))).toThrow(NotUtf8Error);
  });

  test("the hash matches the FNV-1a reference vectors", () => {
    expect(fnv1a64("")).toBe(0xcbf29ce484222325n);
    expect(fnv1a64("a")).toBe(0xaf63dc4c8601ec8cn);
    expect(fnv1a64("好\thz\n")).not.toBe(fnv1a64("好\thz"));
  });
});
