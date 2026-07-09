// Builds core/ for wasm32-freestanding so the tests have a jd.wasm to load,
// mirroring how bindings/rust's build.rs builds core with zig when no prebuilt
// bundle is provided. Skipped when JD_WASM already points at a prebuilt module.
//
// Fast-path precedence:
//   JD_WASM set        -> trust it, build nothing (CI hands us the release wasm).
//   zig on PATH        -> `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseFast`.
//   zig missing + wasm -> warn and reuse the existing zig-out/bin/jd.wasm.
//   zig missing, no wasm -> hard error with instructions.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const coreDir = fileURLToPath(new URL("../../../core", import.meta.url));
const defaultWasm = fileURLToPath(
  new URL("../../../core/zig-out/bin/jd.wasm", import.meta.url),
);

if (process.env.JD_WASM) {
  console.log(`[build-wasm] JD_WASM set (${process.env.JD_WASM}); skipping zig build.`);
  process.exit(0);
}

const zig = spawnSync("zig", ["version"], { stdio: "ignore" });
if (zig.status !== 0 || zig.error) {
  if (existsSync(defaultWasm)) {
    console.warn(`[build-wasm] zig not found; reusing existing ${defaultWasm}.`);
    process.exit(0);
  }
  console.error(
    "[build-wasm] zig not found and no prebuilt wasm. Install Zig 0.16, or set " +
      "JD_WASM to a prebuilt jd.wasm.",
  );
  process.exit(1);
}

console.log("[build-wasm] zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseFast");
const build = spawnSync(
  "zig",
  ["build", "-Dtarget=wasm32-freestanding", "-Doptimize=ReleaseFast"],
  { cwd: coreDir, stdio: "inherit" },
);
process.exit(build.status ?? 1);
