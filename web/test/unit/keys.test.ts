// The hardware key gate — mirrors macos/JdIMETests/KeyGateTests.swift.
import { describe, expect, test } from "vitest";
import { keyAction, type KeyInput } from "../../src/engine/keys";

const key = (k: string, mods: Partial<KeyInput> = {}): KeyInput => ({
  key: k,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  shiftKey: false,
  ...mods,
});

describe("key gate", () => {
  test("modifier chords are host shortcuts", () => {
    expect(keyAction(key("a", { metaKey: true }), true)).toEqual({ kind: "pass" });
    expect(keyAction(key("c", { ctrlKey: true }), false)).toEqual({ kind: "pass" });
    expect(keyAction(key("x", { altKey: true }), true)).toEqual({ kind: "pass" });
  });

  test("another input method's composition passes", () => {
    expect(keyAction(key("a", { isComposing: true }), false)).toEqual({ kind: "pass" });
    expect(keyAction(key("Unidentified", { keyCode: 229 }), true)).toEqual({ kind: "pass" });
  });

  test("every printable byte goes to the engine, composing or not", () => {
    expect(keyAction(key("n"), false)).toEqual({ kind: "engine", byte: 0x6e });
    expect(keyAction(key("."), false)).toEqual({ kind: "engine", byte: 0x2e });
    expect(keyAction(key(" "), true)).toEqual({ kind: "engine", byte: 0x20 });
    expect(keyAction(key("K", { shiftKey: true }), true)).toEqual({ kind: "engine", byte: 0x4b });
    expect(keyAction(key("1"), false)).toEqual({ kind: "engine", byte: 0x31 });
  });

  test("while composing: unshifted digits select, - and = page", () => {
    expect(keyAction(key("1"), true)).toEqual({ kind: "select", slot: 0 });
    expect(keyAction(key("9"), true)).toEqual({ kind: "select", slot: 8 });
    expect(keyAction(key("-"), true)).toEqual({ kind: "pagePrev" });
    expect(keyAction(key("="), true)).toEqual({ kind: "pageNext" });
    // Their shifted forms are punctuation.
    expect(keyAction(key("!", { shiftKey: true }), true)).toEqual({ kind: "engine", byte: 0x21 });
    expect(keyAction(key("+", { shiftKey: true }), true)).toEqual({ kind: "engine", byte: 0x2b });
    expect(keyAction(key("0"), true)).toEqual({ kind: "engine", byte: 0x30 });
  });

  test("while composing the IME owns cancel, backspace, enter, paging and navigation", () => {
    expect(keyAction(key("Escape"), true)).toEqual({ kind: "escape" });
    expect(keyAction(key("Backspace"), true)).toEqual({ kind: "backspace" });
    expect(keyAction(key("Enter"), true)).toEqual({ kind: "commitRaw" });
    expect(keyAction(key("ArrowLeft"), true)).toEqual({ kind: "pagePrev" });
    expect(keyAction(key("PageDown"), true)).toEqual({ kind: "pageNext" });
    expect(keyAction(key("Home"), true)).toEqual({ kind: "consume" });
    expect(keyAction(key("Tab"), true)).toEqual({ kind: "consume" });
  });

  test("from an on-screen keyboard, digits and -/= are text even while composing", () => {
    const touch = { touch: true };
    expect(keyAction(key("1"), true, touch)).toEqual({ kind: "engine", byte: 0x31 });
    expect(keyAction(key("-"), true, touch)).toEqual({ kind: "engine", byte: 0x2d });
    expect(keyAction(key("="), true, touch)).toEqual({ kind: "engine", byte: 0x3d });
    expect(keyAction(key("Backspace"), true, touch)).toEqual({ kind: "backspace" });
    expect(keyAction(key("Enter"), true, touch)).toEqual({ kind: "commitRaw" });
  });

  test("idle, those keys belong to the field", () => {
    for (const k of ["Escape", "Backspace", "Enter", "ArrowLeft", "Home", "Tab", "F5"]) {
      expect(keyAction(key(k), false)).toEqual({ kind: "pass" });
    }
  });
});
