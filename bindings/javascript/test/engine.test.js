// Drives the real dictionary through the wasm C ABI, end to end. Plain JS, so
// `node --test` runs it directly on any modern Node — no type-stripping, no
// build. `pretest` builds the wasm first (or reuses JD_WASM). Mirrors
// bindings/rust/tests/engine.rs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { JdModule, EMPTY_SNAPSHOT, UserDictError, UserDictNoteFlags } from "../src/index.js";

const wasmPath =
  process.env.JD_WASM ??
  fileURLToPath(new URL("../../../core/zig-out/bin/jd.wasm", import.meta.url));

const wasmBytes = readFileSync(wasmPath);
// Instantiate once; every engine shares this module's read-only tables. This
// also exercises the ABI layout check inside fromInstance.
const mod = await JdModule.instantiate(wasmBytes);

const byte = (ch) => ch.charCodeAt(0);

/** Feed a string key-by-key, returning the final snapshot. */
function pressKeys(engine, keys) {
  let snap = EMPTY_SNAPSHOT;
  for (const ch of keys) snap = engine.pressKey(byte(ch));
  return snap;
}

test("createEngine yields a live engine", () => {
  const e = mod.createEngine();
  try {
    assert.equal(e.disposed, false);
    assert.deepEqual(e.snapshot(), { commit: null, optionsCount: 0, anchorIndex: 0 });
  } finally {
    e.dispose();
  }
});

test("pressKey opens a candidate window against the real dictionary", () => {
  const e = mod.createEngine();
  try {
    const snap = e.pressKey(byte("a"));
    assert.equal(snap.commit, null, "still composing, nothing committed");
    assert.ok(snap.optionsCount > 0, "the dictionary has candidates for 'a'");
    assert.equal(snap.anchorIndex, 0);

    const window = e.readRange(0, 9);
    assert.equal(window.length, 9);
    assert.equal(typeof window[0].value, "string");
    assert.ok(window[0].value.length > 0);
  } finally {
    e.dispose();
  }
});

test("readRange clips at the end of the list and past it", () => {
  const e = mod.createEngine();
  try {
    const snap = e.pressKey(byte("a"));
    const total = snap.optionsCount;

    const all = e.readRange(0, total + 50);
    assert.equal(all.length, total, "a window is clipped, never padded");
    assert.equal(e.readRange(total, 5).length, 0);
    assert.equal(e.readRange(0, 0).length, 0);
  } finally {
    e.dispose();
  }
});

test("readRange decodes windows larger than the scratch buffer", () => {
  // 'j' has ~11.9K candidates, far more than the context scratch holds, so
  // this exercises the chunked decode loop.
  const e = mod.createEngine();
  try {
    const snap = e.pressKey(byte("j"));
    assert.ok(snap.optionsCount > 1000);

    const big = e.readRange(0, 500);
    assert.equal(big.length, 500);
    for (const c of big) assert.ok(c.value.length > 0);

    // Chunked reads agree with the equivalent single-window read.
    const head = e.readRange(0, 200);
    assert.deepEqual(head, big.slice(0, 200));
  } finally {
    e.dispose();
  }
});

test("results are owned data, retained across later engine calls", () => {
  const e = mod.createEngine();
  try {
    e.pressKey(byte("a"));
    const held = e.readRange(0, 4);
    const before = held.map((c) => c.value);

    // Drive many more calls, overwriting the wasm scratch buffer; the retained
    // array must be unchanged — proof we decoded out of linear memory rather
    // than aliasing it.
    for (const ch of "bcde") e.pressKey(byte(ch));
    e.reset();
    pressKeys(e, "xyz");
    e.readRange(0, 60);

    assert.deepEqual(
      held.map((c) => c.value),
      before,
    );
  } finally {
    e.dispose();
  }
});

test("space commits the anchor candidate", () => {
  const e = mod.createEngine();
  try {
    e.pressKey(byte("a"));
    const first = e.readRange(0, 1)[0].value;
    const committed = e.pressKey(byte(" "));
    assert.equal(committed.commit, first);
    assert.equal(committed.optionsCount, 0);
  } finally {
    e.dispose();
  }
});

test("reading ahead does not move the anchor", () => {
  // The property the flat-index ABI exists to guarantee: prefetching a
  // candidate strip must not change what space commits.
  const e = mod.createEngine();
  try {
    const snap = e.pressKey(byte("j"));
    const anchorValue = e.readRange(0, 1)[0].value;

    // Walk deep into the list, as an append-only strip would.
    const strip = [];
    for (let at = 0; at < 300; at += 9) strip.push(...e.readRange(at, 9));
    assert.ok(strip.length >= 300);
    assert.equal(e.snapshot().anchorIndex, 0);
    assert.equal(e.snapshot().optionsCount, snap.optionsCount);

    assert.equal(e.pressKey(byte(" ")).commit, anchorValue);
  } finally {
    e.dispose();
  }
});

test("setAnchor moves what space commits", () => {
  const e = mod.createEngine();
  try {
    e.pressKey(byte("j"));
    const target = e.readRange(5, 1)[0].value;

    const snap = e.setAnchor(5);
    assert.equal(snap.anchorIndex, 5);
    assert.equal(e.pressKey(byte(" ")).commit, target);
  } finally {
    e.dispose();
  }
});

test("setAnchor ignores out-of-range indices", () => {
  const e = mod.createEngine();
  try {
    const snap = e.pressKey(byte("j"));
    e.setAnchor(3);
    e.setAnchor(snap.optionsCount); // one past the end
    assert.equal(e.snapshot().anchorIndex, 3);
    e.setAnchor(0xffffffff);
    assert.equal(e.snapshot().anchorIndex, 3);
  } finally {
    e.dispose();
  }
});

test("punctuation resolves through the punc table ('#' -> fullwidth)", () => {
  const e = mod.createEngine();
  try {
    const snap = e.pressKey(byte("#"));
    assert.equal(snap.commit, "＃");
    assert.equal(snap.optionsCount, 0);
  } finally {
    e.dispose();
  }
});

test("a commit that appends a literal byte joins in the right order", () => {
  const e = mod.createEngine();
  try {
    e.pressKey(byte("a"));
    const first = e.readRange(0, 1)[0].value;
    // A digit is literal input to the engine: commit the anchor, append '2'.
    const snap = e.pressKey(byte("2"));
    assert.equal(snap.commit, first + "2");
  } finally {
    e.dispose();
  }
});

test("hints are inline, bounded, and null when absent", () => {
  const e = mod.createEngine();
  try {
    e.pressKey(byte("j"));
    const window = e.readRange(0, 32);
    for (const c of window) {
      if (c.hint !== null) {
        assert.ok(c.hint.length > 0);
        assert.ok(c.hint.length < 8, `hint ${JSON.stringify(c.hint)} overflows the inline array`);
      }
    }
    assert.ok(
      window.some((c) => c.hint === null),
      "a fully-typed code should have a hintless candidate",
    );
  } finally {
    e.dispose();
  }
});

test("reset drops the composition and the recorded commit", () => {
  const e = mod.createEngine();
  try {
    e.pressKey(byte("a"));
    e.pressKey(byte(" "));
    const snap = e.reset();
    assert.equal(snap.commit, null);
    assert.equal(snap.optionsCount, 0);
    assert.equal(e.readRange(0, 9).length, 0);

    // With nothing in flight, space synthesizes a bare space commit.
    assert.equal(e.pressKey(byte(" ")).commit, " ");
  } finally {
    e.dispose();
  }
});

test("backspace undoes a single descent back to the root", () => {
  const e = mod.createEngine();
  try {
    e.pressKey(byte("a"));
    const snap = e.backspace();
    assert.equal(snap.commit, null);
    assert.equal(snap.optionsCount, 0);
    assert.equal(e.readRange(0, 9).length, 0);
  } finally {
    e.dispose();
  }
});

test("engines from one module have independent state", () => {
  const a = mod.createEngine();
  const b = mod.createEngine();
  try {
    const ra = a.pressKey(byte("a"));
    assert.ok(ra.optionsCount > 0);
    // b is untouched by a's composition: space synthesizes a bare " ".
    assert.equal(b.pressKey(byte(" ")).commit, " ");
    assert.equal(a.snapshot().optionsCount, ra.optionsCount);
  } finally {
    a.dispose();
    b.dispose();
  }
});

test("dispose poisons the engine and is idempotent", () => {
  const e = mod.createEngine();
  e.pressKey(byte("a"));
  e.dispose();
  assert.equal(e.disposed, true);
  assert.throws(() => e.pressKey(byte("a")), /disposed/);
  assert.throws(() => e.reset(), /disposed/);
  assert.throws(() => e.readRange(0, 4), /disposed/);
  e.dispose(); // idempotent — no throw
});

test("Symbol.dispose releases the engine (works with `using`)", () => {
  const e = mod.createEngine();
  e[Symbol.dispose]();
  assert.equal(e.disposed, true);
});

test("fromInstance rejects a module that isn't libjd", async () => {
  // A minimal valid wasm module with none of the jd_* exports.
  const empty = new WebAssembly.Module(
    new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]),
  );
  await assert.rejects(() => JdModule.instantiate(empty), /not a libjd module/);
});

// ---- user dictionary ----------------------------------------------------

test("a user dictionary's phrases lead the built-in candidates on a shared code", () => {
  // 'b' → 不 in the built-in tables; the user adds a word on the same code
  // and repeats a built-in one, which is dropped and reported by line.
  const { dict, report } = mod.buildUserDict("测试词\tb\n不\tb\n", { sourceTag: 42n });
  try {
    assert.equal(report.entries, 1);
    assert.equal(report.dropped, 1);
    assert.equal(report.shared, 1);
    // 测试词 shares b with the built-in words; 不 repeats one of them.
    assert.equal(report.notes.length, 2);
    const wordsOnB = report.notes[0].builtin;
    assert.ok(wordsOnB >= 1);
    assert.deepEqual(report.notes, [
      { line: 1, flags: UserDictNoteFlags.CODE_IN_BUILTIN, other: 0, builtin: wordsOnB, peers: 0 },
      { line: 2, flags: UserDictNoteFlags.REPEATS_BUILTIN, other: 0, builtin: wordsOnB, peers: 0 },
    ]);
    assert.equal(dict.entries, 1);
    assert.equal(dict.sourceTag, 42n);
    assert.ok(dict.byteLength > 0);

    const e = mod.createEngine({ userDict: dict });
    try {
      e.pressKey(byte("b"));
      const window = e.readRange(0, 2);
      assert.equal(window[0].value, "测试词");
      assert.equal(window[1].value, "不");
      assert.equal(e.pressKey(byte(" ")).commit, "测试词");
    } finally {
      e.dispose();
    }

    // A plain engine of the same module is unaffected.
    const plain = mod.createEngine();
    try {
      plain.pressKey(byte("b"));
      assert.equal(plain.readRange(0, 1)[0].value, "不");
    } finally {
      plain.dispose();
    }
  } finally {
    dict.dispose();
  }
});

test("a user-only code composes with hints and auto-commits", () => {
  const { dict } = mod.buildUserDict("键道\tzzzzzz\n键道输入法\tzzzzza\n");
  const e = mod.createEngine({ userDict: dict });
  try {
    const snap = pressKeys(e, "zzzzz");
    assert.equal(snap.commit, null);
    assert.deepEqual(e.readRange(0, 4), [
      { value: "键道输入法", hint: "a" },
      { value: "键道", hint: "z" },
    ]);
    const committed = e.pressKey(byte("z"));
    assert.equal(committed.commit, "键道");
    assert.equal(committed.optionsCount, 0);
  } finally {
    e.dispose();
    dict.dispose();
  }
});

test("bad lines are skipped and noted, never fatal", () => {
  // "zzzzzz" and "zzzzza" are free in the built-in tables, so the only
  // notes are the skipped lines'.
  const { dict, report } = mod.buildUserDict("键道\tzzzzzz\nno tab\n好\tZZZZZA\n\tzzzzza\n");
  try {
    assert.deepEqual(report, {
      entries: 1,
      dropped: 0,
      shared: 0,
      invalid: 3,
      notes: [
        { line: 2, flags: UserDictNoteFlags.MALFORMED, other: 0, builtin: 0, peers: 0 },
        { line: 3, flags: UserDictNoteFlags.BAD_KEYS, other: 0, builtin: 0, peers: 0 },
        { line: 4, flags: UserDictNoteFlags.BAD_VALUE, other: 0, builtin: 0, peers: 0 },
      ],
    });
  } finally {
    dict.dispose();
  }

  // Only a problem with the call as a whole throws: too many phrases.
  let text = "";
  for (let i = 0; i <= 10000; i++) {
    const code = [...String(i).padStart(5, "0")].map((d) => String.fromCharCode(97 + Number(d))).join("");
    text += `w${i}\t${code}\n`;
  }
  assert.throws(
    () => mod.buildUserDict(text),
    (err) =>
      err instanceof UserDictError &&
      err.status === "tooManyEntries" &&
      err.line === 10001 &&
      err.message === "line 10001: more than 10000 phrases",
  );
});

test("cached bytes round-trip, and stale or corrupt bytes are refused", () => {
  const { dict } = mod.buildUserDict("# comment\n键道\tzzzzzz\n", { sourceTag: 7 });
  const bytes = dict.bytes();
  dict.dispose();
  assert.ok(bytes.length > 0);

  const again = mod.loadUserDict(bytes);
  try {
    assert.equal(again.sourceTag, 7n);
    assert.equal(again.entries, 1);
    assert.deepEqual(again.bytes(), bytes);
    // An ArrayBuffer works too.
    const fromBuffer = mod.loadUserDict(bytes.slice().buffer);
    assert.equal(fromBuffer.entries, 1);
    fromBuffer.dispose();
  } finally {
    again.dispose();
  }

  // The built-in dictionary fingerprint lives in the header.
  const stale = bytes.slice();
  stale[12] ^= 0xff;
  assert.throws(() => mod.loadUserDict(stale), { status: "stale", line: 0 });
  assert.throws(() => mod.loadUserDict(bytes.subarray(0, bytes.length - 1)), { status: "corrupt" });
  assert.throws(() => mod.loadUserDict(new Uint8Array(0)), { status: "corrupt" });
});

test("a dictionary outlives the engines that read it", () => {
  const { dict } = mod.buildUserDict("键道\tzzzzzz\n");
  const e = mod.createEngine({ userDict: dict });
  assert.throws(() => dict.dispose(), /dispose them first/);
  assert.equal(dict.disposed, false);
  e.dispose();
  dict.dispose();
  assert.equal(dict.disposed, true);
  dict.dispose(); // idempotent
  assert.throws(() => dict.bytes(), /disposed/);
  assert.throws(() => mod.createEngine({ userDict: dict }), /disposed/);
  // @ts-expect-error — deliberately not a UserDict
  assert.throws(() => mod.createEngine({ userDict: {} }), TypeError);
});

test("an empty dictionary is valid and inert", () => {
  const { dict, report } = mod.buildUserDict("# nothing here\n");
  try {
    assert.deepEqual(report, { entries: 0, dropped: 0, shared: 0, invalid: 0, notes: [] });
    const e = mod.createEngine({ userDict: dict });
    const plain = mod.createEngine();
    try {
      assert.deepEqual(e.pressKey(byte("a")), plain.pressKey(byte("a")));
      assert.deepEqual(e.readRange(0, 9), plain.readRange(0, 9));
    } finally {
      e.dispose();
      plain.dispose();
    }
  } finally {
    dict.dispose();
  }
});

test("Symbol.dispose releases a dictionary (works with `using`)", () => {
  const { dict } = mod.buildUserDict("键道\tzzzzzz\n");
  dict[Symbol.dispose]();
  assert.equal(dict.disposed, true);
});
