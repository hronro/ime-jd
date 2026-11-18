import { afterEach, beforeEach, describe, expect, test } from "vitest";
import type { Engine } from "jd";
import { type CandidateCommit, InputSession, type SessionView } from "../../src/engine/session";
import { jd } from "./wasm";

const byte = (ch: string) => ch.charCodeAt(0);

let engine: Engine;
let session: InputSession;
let out: string;
let views: SessionView[];
let commits: CandidateCommit[];

beforeEach(() => {
  engine = jd.createEngine();
  session = new InputSession(engine);
  out = "";
  views = [];
  commits = [];
  session.attach({ insert: (text) => (out += text) });
  session.subscribe((v) => views.push(v));
  session.onCandidateCommit((c) => commits.push(c));
});

afterEach(() => engine.dispose());

const type = (keys: string) => {
  for (const ch of keys) session.pressKey(byte(ch));
};

describe("composition", () => {
  test("letters compose; the page holds 9 candidates and the anchor is its first", () => {
    type("nk");
    expect(session.composing).toBe(true);
    expect(session.view.code).toBe("nk");
    expect(session.view.total).toBeGreaterThan(9);
    expect(session.view.page).toHaveLength(InputSession.PAGE_SIZE);
    expect(session.view.pageStart).toBe(0);
    expect(out).toBe("");
  });

  test("space commits the anchor and ends the composition", () => {
    type("nk");
    const first = session.view.page[0]!.value;
    type(" ");
    expect(out).toBe(first);
    expect(session.composing).toBe(false);
    expect(commits).toEqual([{ value: first, code: "nk", index: 0 }]);
  });

  test("paging moves the anchor, so space commits the first candidate on the page", () => {
    type("nk");
    session.pageNext();
    expect(session.view.pageStart).toBe(9);
    const target = session.view.page[0]!.value;
    type(" ");
    expect(out).toBe(target);
    expect(commits[0]).toMatchObject({ value: target, index: 9 });
  });

  test("pagePrev stops at the first page; pageNext stops at the last", () => {
    type("nk");
    session.pagePrev();
    expect(session.view.pageStart).toBe(0);
    const total = session.view.total;
    for (let i = 0; i < total; i++) session.pageNext();
    expect(session.view.pageStart).toBeLessThan(total);
    expect(session.view.pageStart % 9).toBe(0);
  });

  test("select picks the slot on the current page", () => {
    type("nk");
    const third = session.view.page[2]!.value;
    expect(session.select(2)).toBe(true);
    expect(out).toBe(third);
    expect(commits[0]).toMatchObject({ value: third, index: 2, code: "nk" });
  });

  test("select on an empty slot reports false, leaving the digit to the engine", () => {
    type("[");
    const count = session.view.page.length;
    expect(count).toBeLessThan(9);
    expect(session.select(8)).toBe(false);
  });

  test("backspace shrinks the code and ends the composition when it empties", () => {
    type("nk");
    expect(session.backspace()).toBe(true);
    expect(session.view.code).toBe("n");
    expect(session.backspace()).toBe(true);
    expect(session.composing).toBe(false);
    expect(session.backspace()).toBe(false);
  });

  test("enter commits the typed letters as they are", () => {
    type("nk");
    expect(session.commitRaw()).toBe(true);
    expect(out).toBe("nk");
    expect(session.composing).toBe(false);
    expect(commits).toEqual([]);
  });

  test("escape drops the composition without committing", () => {
    type("nk");
    session.cancel();
    expect(out).toBe("");
    expect(session.composing).toBe(false);
    expect(views.at(-1)!.total).toBe(0);
  });

  test("a punctuation key commits the anchor and the mark together (n. → 你。)", () => {
    type("n.");
    expect(out).toBe("你。");
    expect(session.composing).toBe(false);
    expect(commits[0]).toMatchObject({ value: "你", code: "n" });
  });

  test("bare punctuation converts with nothing composing", () => {
    type("#");
    expect(out).toBe("＃");
  });

  test("a punctuation window composes on its own key", () => {
    type("[");
    expect(session.view.code).toBe("[");
    expect(session.view.page.map((c) => c.value)).toContain("【");
    const second = session.view.page[1]!.value;
    expect(session.select(1)).toBe(true);
    expect(out).toBe(second);
    expect(commits).toEqual([]);
  });

  test("an uppercase letter commits the anchor and appends itself", () => {
    type("n");
    const first = session.view.page[0]!.value;
    type("K");
    expect(out).toBe(first + "K");
  });

  test("commitAnchor commits what space would, and is a no-op when idle", () => {
    session.commitAnchor();
    expect(out).toBe("");
    type("nk");
    const first = session.view.page[0]!.value;
    session.commitAnchor();
    expect(out).toBe(first);
  });

  test("insertLiteral commits the anchor before the literal", () => {
    type("n");
    session.insertLiteral("2");
    expect(out).toBe("你2");
    session.insertLiteral("。");
    expect(out).toBe("你2。");
  });

  test("attaching another host drops the composition", () => {
    type("nk");
    let other = "";
    session.attach({ insert: (t) => (other += t) });
    expect(session.composing).toBe(false);
    type("n ");
    expect(other).toBe("你");
    expect(out).toBe("");
  });

  test("readRange is a pure read for the touch bar", () => {
    type("nk");
    const anchor = session.view.page[0]!.value;
    const ahead = session.readRange(16, 16);
    expect(ahead).toHaveLength(16);
    type(" ");
    expect(out).toBe(anchor);
  });
});
