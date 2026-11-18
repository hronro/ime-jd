import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import solid from "@solidjs/vite-plugin";
import { defineConfig, type Plugin } from "vite";
import { VitePWA } from "vite-plugin-pwa";

// CI hands the build a prebuilt module through JD_WASM (the same variable
// bindings/javascript/scripts/build-wasm.mjs honors); locally it is core's
// own build output.
const wasmPath =
  process.env.JD_WASM ?? fileURLToPath(new URL("../core/zig-out/bin/jd.wasm", import.meta.url));

// Every client reads its version from core/build.zig.zon.
const zon = readFileSync(new URL("../core/build.zig.zon", import.meta.url), "utf8");
const version = /\.version\s*=\s*"([^"]+)"/.exec(zon)?.[1] ?? "0.0.0";

/**
 * dist/_headers for Cloudflare, its CSP allowing exactly the inline scripts
 * index.html carries (the pre-paint theme snippet), by hash.
 */
function cloudflareHeaders(): Plugin {
  return {
    name: "jd-cloudflare-headers",
    apply: "build",
    enforce: "post",
    generateBundle(_, bundle) {
      const html = bundle["index.html"];
      if (!html || html.type !== "asset") return;
      const source = typeof html.source === "string" ? html.source : new TextDecoder().decode(html.source);
      const hashes = [...source.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(
        (m) => `'sha256-${createHash("sha256").update(m[1]!).digest("base64")}'`,
      );
      const template = readFileSync(new URL("./headers.template", import.meta.url), "utf8");
      this.emitFile({
        type: "asset",
        fileName: "_headers",
        source: template.replaceAll("%INLINE_SCRIPTS%", hashes.join(" ")),
      });
    },
  };
}

export default defineConfig({
  plugins: [
    solid(),
    cloudflareHeaders(),
    VitePWA({
      // The page shows 有新版本 · 刷新 and swaps only when the user agrees —
      // never mid-sentence.
      registerType: "prompt",
      injectRegister: false,
      manifest: {
        id: "/",
        name: "键道输入法",
        short_name: "键道",
        description: "无需安装的键道输入法：打开网页即可用键道打字，离线可用。",
        lang: "zh-Hans",
        start_url: "/",
        scope: "/",
        display: "standalone",
        theme_color: "#ae3522",
        background_color: "#f7f0e5",
        categories: ["productivity", "utilities"],
        icons: [
          { src: "icons/icon-192.png", sizes: "192x192", type: "image/png" },
          { src: "icons/icon-512.png", sizes: "512x512", type: "image/png" },
          { src: "icons/maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
          { src: "icons/jd.svg", sizes: "any", type: "image/svg+xml" },
        ],
      },
      workbox: {
        // Everything, lazy chunks included: a feature never opened online
        // still works offline. libjd (~5.4 MB, the dictionary inside) too.
        globPatterns: ["**/*.{js,css,html,svg,png,wasm,webmanifest}"],
        maximumFileSizeToCacheInBytes: 8 * 1024 * 1024,
        navigateFallback: "index.html",
        cleanupOutdatedCaches: true,
      },
    }),
  ],
  resolve: {
    // `import url from "jd-wasm?url"` — a regex, since a string alias only
    // matches a bare specifier or a `/` subpath, not one with a query.
    alias: [{ find: /^jd-wasm(?=\?|$)/, replacement: wasmPath }],
  },
  define: {
    __JD_VERSION__: JSON.stringify(version),
  },
  server: {
    fs: { allow: [".", "../bindings/javascript", dirname(wasmPath)] },
  },
  build: {
    target: "es2022",
  },
});
