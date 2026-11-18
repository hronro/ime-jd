import { afterAll, describe, expect, test } from "vitest";
import { betterCode, keyCost } from "../../src/engine/hint";
import { jd } from "./wasm";

const engine = jd.createEngine();
afterAll(() => engine.dispose());

/** Where `value` sits after typing `keys`. */
function indexOn(keys: string, value: string): number {
  for (const ch of keys) engine.pressKey(ch.charCodeAt(0));
  const total = engine.snapshot().optionsCount;
  const index = engine.readRange(0, total).findIndex((c) => c.value === value);
  engine.reset();
  return index;
}

describe("key cost", () => {
  test("the first candidate on a page costs no key of its own", () => {
    expect(keyCost("nk", 0)).toBe(2);
    expect(keyCost("nk", 1)).toBe(3);
    expect(keyCost("nk", 8)).toBe(3);
    // Page 2: one page key; its first candidate is the anchor again.
    expect(keyCost("nk", 9)).toBe(3);
    expect(keyCost("nk", 10)).toBe(4);
  });
});

describe("better code", () => {
  test("a later candidate gets the code that puts it first, at no more keys", () => {
    const index = indexOn("nk", "拿快递");
    expect(index).toBeGreaterThan(0);
    const hint = betterCode({ value: "拿快递", code: "nk", index }, engine.lookupCodes("拿快递"));
    expect(hint).not.toBeNull();
    expect(hint!.index).toBe(0);
    expect(keyCost(hint!.keys, hint!.index)).toBeLessThanOrEqual(keyCost("nk", index));
  });

  test("a longer code than needed gets the short one", () => {
    const index = indexOn("deuiua", "的");
    expect(index).toBeGreaterThanOrEqual(0);
    const hint = betterCode({ value: "的", code: "deuiua", index }, engine.lookupCodes("的"));
    expect(hint).toEqual({ keys: "d", index: indexOn("d", "的") });
  });

  test("the best way already taken: no hint", () => {
    for (const value of ["的", "拿快递", "你们"]) {
      const codes = engine.lookupCodes(value);
      const best = betterCode({ value, code: "zzzzzz", index: 30 }, codes)!;
      expect(betterCode({ value, code: best.keys, index: best.index }, codes)).toBeNull();
    }
  });

  test("never a code that costs more keys", () => {
    const codes = engine.lookupCodes("的");
    // `d` and the first candidate: two keys cannot be beaten.
    expect(betterCode({ value: "的", code: "d", index: indexOn("d", "的") }, codes)).toBeNull();
  });

  test("a word found on a later page", () => {
    const total = (() => {
      engine.pressKey("a".charCodeAt(0));
      const n = engine.snapshot().optionsCount;
      engine.reset();
      return n;
    })();
    expect(total).toBeGreaterThan(20);
    engine.pressKey("a".charCodeAt(0));
    const deep = engine.readRange(20, 1)[0]!;
    engine.reset();
    const hint = betterCode({ value: deep.value, code: "a", index: 20 }, engine.lookupCodes(deep.value));
    if (hint) expect(keyCost(hint.keys, hint.index)).toBeLessThanOrEqual(keyCost("a", 20));
  });
});
