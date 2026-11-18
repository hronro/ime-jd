// Starts fetching and compiling libjd the moment this module is evaluated —
// the page's critical path — so the download overlaps everything else boot
// does. Streaming compile; the binding falls back to arrayBuffer() when a
// server sends the wrong MIME type.
import { JdModule } from "jd";
import wasmUrl from "jd-wasm?url";

export const jdModule: Promise<JdModule> = JdModule.instantiate(fetch(wasmUrl));
