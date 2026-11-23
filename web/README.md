# 键道输入法 — Web

A browser 键道 (jd) input method for machines that cannot install one: open the page, type, copy the text out with `⌘⏎` / `Ctrl+⏎` (or **复制到剪贴板**), paste it anywhere. It is built on the shared Zig core engine (`../core`) compiled to WebAssembly, reached through the engine's JavaScript binding (`../bindings/javascript`). It is an installable PWA that works fully offline once loaded. No server-side code: it is a static site.

Features:
- the IME in every text field on the page (the editor, 编码反查, the phrase table, the text editor);
- a caret candidate popup for hardware keyboards and a docked candidate bar above phone keyboards;
- 编码反查;
- the 用户自造词 manager, with libjd's per-row verdicts, 移除重复词条, import/export, and a bundled text editor (CodeMirror 6);
- code hints;
- an auto-saved draft.

## Layout

```
web/
  index.html                # shell; the inline script applies a pinned theme before first paint
  vite.config.ts            # Vite 8 + @solidjs/vite-plugin + vite-plugin-pwa; the jd.wasm alias; dist/_headers
  headers.template          # Cloudflare response headers (CSP, caching) — the build fills in the script hash
  wrangler.jsonc            # Cloudflare Workers static assets: production + preview
  public/icons/             # rendered by ../assets/icon/generate.sh (step 9)
  src/
    main.tsx                # starts the wasm download first, renders, boots the IME
    engine/                 # load.ts (wasm), session.ts (the InputSession), keys.ts (the KeyGate)
    ime/                    # controller.ts (the page's IME), targets, caret popup, ImeLayer
    dict/service.ts         # the user dictionary: text ⇄ libjd build ⇄ engine swaps, other tabs, the linked file
    storage/                # IndexedDB (phrases, blob cache, file handle), localStorage (settings, draft)
    app/                    # the page: editor, toolbar, status bar, dialogs state, PWA state, code hints
    lookup/ userdict/ settings/ help/ mobile/   # lazy: each loads the first time it is used
  test/unit/                # Vitest, against the real jd.wasm
  test/e2e/                 # Playwright, against the production build
```

## Requirements

- Node 24 or newer, npm.
- Zig 0.17.0, to build `jd.wasm` (or set `JD_WASM` to a prebuilt module, e.g. from a release's `libjd-*-wasm.wasm.tar.xz`).

## Build & run

```sh
npm ci
npm run wasm        # zig-builds core/zig-out/bin/jd.wasm (skipped when JD_WASM is set)
npm run dev         # http://localhost:5173 — no service worker in dev
npm run build       # dist/: the static site, service worker included
npm run preview     # serves dist/ on http://localhost:4173
```

`dist/` can be served by any static file server over HTTPS (or `localhost`): the clipboard, the service worker and installation need a secure context.

## User dictionary

It works the same as in every other client:
- The phrases are a text file in libjd's table format (`词<TAB>编码` per line). It is the single source of truth, and libjd is the only judge of a line.
- The feature is off by default (**启用用户自造词**).
- **忽略内置词库**, beside it, works only while it is on: the phrases are built on libjd's empty dictionary (`emptyDict()`) and are all the page types from. With none to be had, the bar and a toast say why and keys reach the page as typed; it never falls back to the built-in dictionary.
- Every change is saved at once, and an import appends a file's rows exactly as they are.

Storage:
- **Browser (default):** the text lives in IndexedDB, together with the compiled blob, which is tagged with libjd's hash of the text (`jd_user_dict_hash`) as on iOS/Android. Boot loads the blob without rebuilding when the tag matches. The page asks for persistent storage once there are phrases.
- **A file on disk (Chromium):** where the File System Access API exists, **关联磁盘文件…** links the dictionary to a file the user picks, new or existing. The file is then the source of truth and IndexedDB keeps only its handle and the blob cache.
  - The file is re-read when the page regains focus and its size or modification time has changed, as the Windows client does.
  - When the browser asks for permission again, the page types with the cached blob until the user grants access.

Views:
- **表格** mirrors the macOS window, with the same wording for every status. On phones it becomes cards with an edit sheet, as in the iOS app.
- **文本** is CodeMirror 6 on the file itself, with libjd's notes as lint marks. Tab inserts a TAB, and after a line's TAB the IME steps aside so the 编码 types as letters.

Other tabs follow changes through a `BroadcastChannel`.

## Code lookup

The magnifier in the header (**编码反查**) opens with the editor's selection, if any. It uses the live engine, so it includes the user's phrases exactly while they are enabled. The wording is a port of `bindings/swift/CodeLookupReport.swift`.

## Updates

- Every release deploys the site.
- The service worker precaches everything, including the 5.4 MB `jd.wasm` (the dictionary is inside it, about 1.4 MB over the wire with brotli) and every lazy chunk. It is registered after the page has loaded, so it never competes with libjd's download.
- When a new version is waiting, the status bar shows **有新版本 · 刷新**. Nothing reloads by itself, so an update never interrupts typing.

## Tests

```sh
npm run typecheck
npm test                                   # unit: session, key gate, file format, wording ports — real jd.wasm
npx playwright install chromium webkit firefox
npm run e2e                                # end to end on the production build (vite preview)
```

The end-to-end suite runs desktop Chromium, WebKit and Firefox plus Pixel- and iPhone-sized touch projects. It covers:
- typing, paging, selection, Enter/Esc and 中/英;
- copy, and clear with undo;
- the draft;
- lazy loading;
- 编码反查;
- the manager (table, verdicts, 移除重复词条, the text view, import/export);
- the touch path (Chromium and WebKit `insertText` go through `beforeinput`, as phone keyboards do);
- offline use.

## Deploy

`wrangler.jsonc` describes two Cloudflare Workers (static assets only):
- `ime-jd-web` at `ime-jd-web.hronro.com`, deployed by `release.yml` on every tag. The release also gets `jd-web-<version>.zip` for self-hosting.
- `ime-jd-web-preview` at `ime-jd-web-preview.hronro.com`, deployed by `build-on-push.yml` on every master push.

Both need the repository secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`; without them the deploy steps are skipped. By hand: `npm run build && npx wrangler deploy [--env preview]`.

## Architecture notes

- **One IME, following focus** (`ime/controller.ts`). A page has no input-method API, so the controller listens on the document (capture phase) and types into whichever field has focus, through an adapter (`ime/target.ts`, `ime/targets/codemirror.ts`).
  - Commits use `execCommand("insertText")`, so native undo keeps working.
  - Fields marked `data-ime="off"` (the 编码 cells) are left alone.
- **Two input paths, one session.**
  - Hardware keys arrive as `keydown` with a real `key` and are mapped as every desktop client maps them (`engine/keys.ts`, a port of `KeyGate.swift`).
  - Phone keyboards send `keydown` 229 / `Unidentified`, then a cancelable `beforeinput` per character. This was verified with Gboard on Android Chrome: with `autocorrect`/`spellcheck` off, Chrome requests `TYPE_TEXT_FLAG_NO_SUGGESTIONS`, so letters arrive as plain `insertText` and Backspace/Enter as real key events.
  - The controller cancels those insertions and routes them the way the iOS/Android apps route taps: digits are literal, and punctuation converts.
- **iOS Safari's keyboard sends real key events.** Each tap arrives as `keydown` `n` / `KeyN` / 78, and its shift key as `ShiftLeft`, exactly like a hardware keyboard; this was verified with an XCUITest driving the simulator. The screen tells them apart: the keyboard shrinks the *visual* viewport (714 → 411 pt on an iPhone) while the layout viewport stays put.
  - When that happens on a touch device, keys are routed as taps: the docked bar is used, digits and `-`/`=` are text, and Shift alone does nothing.
  - An iPad with a hardware keyboard shows no keyboard on screen, so it keeps the popup and the Shift toggle.
- **WebKit fires `beforeinput` for `execCommand`** (Chromium does not). The page's own edits are wrapped in `ime.edit()` so they are not mistaken for typing; without that, a candidate click re-inserted itself forever.
- **Shift alone** toggles 中/英 only once a hardware keyboard has typed with no keyboard on screen: Gboard's and iOS's shift keys send the very same `ShiftLeft` events.
- **Modal dialogs make the page inert**, so each dialog carries its own `ImeLayer` and the candidate UI renders inside the dialog that holds the focused field.
- **The touch candidate bar** is docked to the *visual* viewport. Even with `interactive-widget=resizes-content`, Android Chrome's visual viewport ends above the resized layout viewport, and iOS never resizes the layout viewport.
- **Solid 2.0:** `value={…}` bindings are re-applied whenever the template re-renders, which wipes uncommitted typing, so fields the IME types into are uncontrolled. Attributes such as `spellcheck` are strings: a `false` boolean removes the attribute.

## Known limitations

- Firefox has no File System Access API: **关联磁盘文件…** is hidden there, while import and export work everywhere.
- iOS Safari offers no install prompt; use **Share › Add to Home Screen**.
- In an iOS Safari tab, Safari's own floating address pill and form toolbar (↑ ↓ ✓) sit between the candidate bar and the keyboard. They lie outside the visual viewport and a page cannot cover them. Added to the Home Screen, the address pill is gone.
- Third-party Android keyboards (SwiftKey, Samsung Keyboard) have not been verified yet; only Gboard has.
