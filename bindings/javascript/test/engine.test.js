// Drives the real dictionary through the wasm C ABI, end to end. Plain JS, so
// `node --test` runs it directly on any modern Node — no type-stripping, no
// build. `pretest` builds the wasm first (or reuses JD_WASM). Mirrors
// bindings/rust/tests/engine.rs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { JdModule, visibleCount } from "../src/index.js";

const wasmPath =
  process.env.JD_WASM ??
  fileURLToPath(new URL("../../../core/zig-out/bin/jd.wasm", import.meta.url));

const wasmBytes = readFileSync(wasmPath);
// Instantiate once; every engine shares this module's read-only tables.
const mod = await JdModule.instantiate(wasmBytes);

const byte = (ch) => ch.charCodeAt(0);

/** Feed a string key-by-key, returning the final snapshot. */
function pressKeys(engine, keys) {
  let snap = { commit: null, options: [], optionsCount: 0, totalPages: 0, currentPage: 0 };
  for (const ch of keys) snap = engine.pressKey(byte(ch));
  return snap;
}

/** The current page's visible length must always equal the derived count. */
function assertPageConsistent(snap, pageSize) {
  assert.equal(
    snap.options.length,
    visibleCount(snap.optionsCount, snap.currentPage, snap.totalPages, pageSize),
    "options.length must match visibleCount()",
  );
}

test("createEngine: defaults, getters, and pageSize validation", () => {
  const e = mod.createEngine();
  try {
    assert.equal(e.pageSize, 9);
    assert.equal(e.disposed, false);
  } finally {
    e.dispose();
  }
  assert.throws(() => mod.createEngine(0), RangeError);
  assert.throws(() => mod.createEngine(256), RangeError);
  assert.throws(() => mod.createEngine(1.5), RangeError);
});

test("pressKey opens a candidate window against the real dictionary", () => {
  const e = mod.createEngine(9);
  try {
    const snap = e.pressKey(byte("a"));
    assert.equal(snap.commit, null, "still composing, nothing committed");
    assert.ok(snap.optionsCount > 0, "the dictionary has candidates for 'a'");
    assert.equal(snap.currentPage, 1);
    assert.ok(snap.totalPages >= 1);
    assert.ok(snap.options.length > 0);
    assert.equal(typeof snap.options[0].value, "string");
    assert.ok(snap.options[0].value.length > 0);
    assertPageConsistent(snap, e.pageSize);
  } finally {
    e.dispose();
  }
});

test("results are owned data, retained across later engine calls", () => {
  const e = mod.createEngine(9);
  try {
    const composing = e.pressKey(byte("a"));
    const snapshot = {
      firstValue: composing.options[0].value,
      count: composing.optionsCount,
      len: composing.options.length,
    };

    // Drive many more calls (overwriting the wasm page buffer and sret slot);
    // the retained snapshot must be unchanged — proof we copied out of linear
    // memory rather than aliasing it.
    for (const ch of "bcde") e.pressKey(byte(ch));
    e.reset();
    pressKeys(e, "xyz");

    assert.equal(composing.options[0].value, snapshot.firstValue);
    assert.equal(composing.optionsCount, snapshot.count);
    assert.equal(composing.options.length, snapshot.len);
  } finally {
    e.dispose();
  }
});

test("space commits the displayed first candidate", () => {
  const e = mod.createEngine(9);
  try {
    const composing = e.pressKey(byte("a"));
    const firstValue = composing.options[0].value;
    const committed = e.pressKey(byte(" "));
    assert.equal(committed.commit, firstValue, "space commits option[0]");
    assert.equal(committed.options.length, 0);
    assert.equal(committed.optionsCount, 0);
  } finally {
    e.dispose();
  }
});

test("punctuation resolves through the punc table ('#' -> fullwidth)", () => {
  const e = mod.createEngine(9);
  try {
    const snap = e.pressKey(byte("#"));
    assert.equal(snap.commit, "＃");
    assert.equal(snap.options.length, 0);
  } finally {
    e.dispose();
  }
});

test("pagination: next/prev/jump stay page-consistent", () => {
  const e = mod.createEngine(9);
  try {
    const first = e.pressKey(byte("a"));
    assertPageConsistent(first, e.pageSize);

    if (first.totalPages > 1) {
      const p2 = e.nextPage();
      assert.equal(p2.currentPage, 2);
      assertPageConsistent(p2, e.pageSize);

      const back = e.prevPage();
      assert.equal(back.currentPage, 1);

      const last = e.jumpToPage(first.totalPages);
      assert.equal(last.currentPage, first.totalPages);
      assertPageConsistent(last, e.pageSize);

      // Out-of-range jumps are silent no-ops (stay on the last page).
      const huge = e.jumpToPage(9999);
      assert.equal(huge.currentPage, first.totalPages);
    }
  } finally {
    e.dispose();
  }
});

test("reset drops the in-flight composition", () => {
  const e = mod.createEngine(9);
  try {
    e.pressKey(byte("a"));
    e.reset();
    // With nothing in flight, space synthesizes a bare space commit.
    const snap = e.pressKey(byte(" "));
    assert.equal(snap.commit, " ");
  } finally {
    e.dispose();
  }
});

test("backspace undoes a single descent back to the root", () => {
  const e = mod.createEngine(9);
  try {
    e.pressKey(byte("a"));
    const snap = e.backspace();
    assert.equal(snap.commit, null);
    assert.equal(snap.options.length, 0);
    assert.equal(snap.currentPage, 0);
  } finally {
    e.dispose();
  }
});

test("engines from one module have independent state", () => {
  const a = mod.createEngine(9);
  const b = mod.createEngine(9);
  try {
    const ra = a.pressKey(byte("a"));
    assert.ok(ra.options.length > 0);
    // b is untouched by a's composition: space synthesizes a bare " ".
    const rb = b.pressKey(byte(" "));
    assert.equal(rb.commit, " ");
  } finally {
    a.dispose();
    b.dispose();
  }
});

test("dispose poisons the engine and is idempotent", () => {
  const e = mod.createEngine(9);
  e.pressKey(byte("a"));
  e.dispose();
  assert.equal(e.disposed, true);
  assert.throws(() => e.pressKey(byte("a")), /disposed/);
  assert.throws(() => e.reset(), /disposed/);
  e.dispose(); // idempotent — no throw
});

test("Symbol.dispose releases the engine (works with `using`)", () => {
  const e = mod.createEngine(9);
  e[Symbol.dispose]();
  assert.equal(e.disposed, true);
});

test("visibleCount covers all page shapes", () => {
  // Partial last page.
  assert.equal(visibleCount(11, 3, 3, 4), 3);
  // Exact-multiple last page.
  assert.equal(visibleCount(8, 2, 2, 4), 4);
  // Non-last page is always full.
  assert.equal(visibleCount(11, 1, 3, 4), 4);
  // Single page smaller than page_size.
  assert.equal(visibleCount(2, 1, 1, 4), 2);
  // Empty / committed shapes.
  assert.equal(visibleCount(0, 0, 0, 4), 0);
  // Degenerate page size must not divide by zero.
  assert.equal(visibleCount(5, 1, 1, 0), 0);
});
