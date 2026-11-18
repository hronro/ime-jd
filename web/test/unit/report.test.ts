import { expect, test } from "vitest";
import { lookupQuery, lookupReport } from "../../src/lookup/report";
import { jd } from "./wasm";

test("trims spaces, TABs and line breaks but not U+3000", () => {
  expect(lookupQuery(" \t着\r\n")).toBe("着");
  expect(lookupQuery("　着")).toBe("　着");
});

test("found: a line per code, with the candidate position when not first", () => {
  const e = jd.createEngine();
  const report = lookupReport("着", e.lookupCodes("着"), false);
  expect(report.title).toBe("「着」的编码");
  expect(report.lines.length).toBeGreaterThan(1);
  expect(report.lines.some((l) => l.note?.startsWith("第 "))).toBe(true);
  e.dispose();
});

test("not found, with and without the user dictionary", () => {
  expect(lookupReport("𠀀𠀀", [], true)).toEqual({
    title: "没有找到「𠀀𠀀」",
    lines: [],
    message: "内置词库和用户自造词中都没有这个词。",
  });
  expect(lookupReport("x", [], false).message).toBe("内置词库中没有这个词。用户自造词未启用，不在查询范围内。");
});

test("a long query is cut to 20 characters in the title", () => {
  const long = "一二三四五六七八九十一二三四五六七八九十多";
  expect(lookupReport(long, [], true).title).toBe("没有找到「一二三四五六七八九十一二三四五六七八九十…」");
});

test("a user phrase's code says 自造词", () => {
  const { dict } = jd.buildUserDict("键道网页\tzzzzzz\n");
  const e = jd.createEngine({ userDict: dict });
  const report = lookupReport("键道网页", e.lookupCodes("键道网页"), true);
  expect(report.lines[0]).toEqual({ keys: "zzzzzz", note: "自造词" });
  e.dispose();
  dict.dispose();
});
