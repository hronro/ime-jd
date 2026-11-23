// A dictionary of the host's own in place of the built-in one — the JS
// counterpart of bindings/rust/tests/dict.rs. Runs against libjd and
// libjd-engine alike (JD_WASM picks the module).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { Dict, JdModule, UserDict, UserDictError } from "../src/index.js";

const wasmPath =
  process.env.JD_WASM ?? fileURLToPath(new URL("../../../core/zig-out/bin/jd.wasm", import.meta.url));
const mod = await JdModule.instantiate(readFileSync(wasmPath));

function firstValues(engine, keys, count) {
  engine.reset();
  for (const ch of keys) engine.pressKey(ch.charCodeAt(0));
  return engine.readRange(0, count).map((c) => c.value);
}

test("a host dictionary replaces the built-in one", () => {
  const { dict, report } = mod.buildDict("你\tn\n你好\tnh\n；\t;\n：\t;;\n坏\tn;\n你\tn\n", { sourceTag: 7n });
  assert.ok(dict instanceof Dict);
  assert.deepEqual(
    [report.entries, report.invalid, report.dropped, report.shared, report.notes.length],
    [4, 1, 1, 0, 2],
  );
  assert.equal(dict.sourceTag, 7n);

  const copy = mod.loadDict(dict.bytes());
  assert.equal(copy.entries, 4);
  assert.throws(() => mod.loadDict(dict.bytes().subarray(0, dict.byteLength - 1)), (e) => e instanceof UserDictError && e.status === "corrupt");

  const e = mod.createEngine({ dict: copy });
  try {
    assert.deepEqual(firstValues(e, "n", 1), ["你"]);
    assert.deepEqual(firstValues(e, ";;", 1), ["："]);
    assert.deepEqual(firstValues(e, "b", 1), []);
    assert.deepEqual(e.lookupCodes("你好").map((c) => c.keys), ["nh"]);
    assert.throws(() => copy.dispose(), /still used/);
  } finally {
    e.dispose();
  }
  copy.dispose();
  dict.dispose();
});

test("a user dictionary sits on the dictionary it was built on", () => {
  const dict = mod.buildDict("你\tn\n拟\tn\n").dict;
  const { dict: user, report } = mod.buildUserDict("你\tn\n泥\tn\n", { dict });
  assert.ok(user instanceof UserDict);
  assert.deepEqual([report.entries, report.dropped, report.shared], [1, 1, 1]);
  const e = mod.createEngine({ dict, userDict: user });
  assert.deepEqual(firstValues(e, "n", 3), ["泥", "你", "拟"]);
  e.dispose();

  const other = mod.buildDict("你\tn\n").dict;
  assert.throws(() => mod.loadUserDict(user.bytes(), { dict: other }), (err) => err instanceof UserDictError && err.status === "stale");
  assert.throws(() => mod.createEngine({ dict: other, userDict: user }), /another dictionary/);
  if (mod.dictLimits.builtinEntries > 0) {
    assert.throws(() => mod.loadUserDict(user.bytes()), (err) => err instanceof UserDictError && err.status === "stale");
  }
  // A Dict is not a UserDict, nor the other way round.
  assert.throws(() => mod.createEngine({ dict: user }), TypeError);
  assert.throws(() => mod.createEngine({ dict, userDict: dict }), TypeError);
});

test("an empty dictionary leaves only the user dictionary", () => {
  const empty = mod.emptyDict();
  assert.equal(empty.entries, 0);
  const { dict: user, report } = mod.buildUserDict("不\tb\n测试\tb\n：\t;;\n", { dict: mod.emptyDict() });
  assert.deepEqual([report.entries, report.dropped, report.shared], [3, 0, 2]);
  const e = mod.createEngine({ dict: empty, userDict: user });
  assert.deepEqual(firstValues(e, "b", 3), ["不", "测试"]);
  assert.deepEqual(firstValues(e, ";;", 1), ["："]);
  assert.deepEqual(firstValues(e, "n", 1), []);
  e.dispose();
});

test("the dictionary limits, and the built-in dictionary unless this is libjd-engine", () => {
  const { maxEntries, valueMax, textMax, builtinEntries } = mod.dictLimits;
  assert.deepEqual([maxEntries, valueMax, textMax], [16777215, 1023, 4294967295]);
  if (builtinEntries === 0) {
    assert.throws(() => mod.createEngine(), /no built-in dictionary/);
    assert.throws(() => mod.buildUserDict("x\ta\n"), (err) => err instanceof UserDictError && err.status === "noBuiltinDict");
  } else {
    assert.ok(builtinEntries > 100000);
    mod.createEngine().dispose();
  }
});
