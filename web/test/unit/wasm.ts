// Loads the real libjd module for the unit tests: the one CI hands over
// through JD_WASM, else core's own build output (`npm run wasm`).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { JdModule } from "jd";

const path =
  process.env.JD_WASM ?? fileURLToPath(new URL("../../../core/zig-out/bin/jd.wasm", import.meta.url));

export const jd = await JdModule.instantiate(readFileSync(path));
