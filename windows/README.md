# 键道输入法 for Windows

Rust implementation of 键道输入法 as a Windows TSF Text Input Processor. Besides the built-in dictionary it carries the user's own phrases, edited in a small window of their own — see [User dictionary](#user-dictionary).

## Requirements

- Windows 10 version 1809 (October 2018) or newer, x64.
- For building: [Rust](https://rustup.rs/), [Zig](https://ziglang.org/) (used to build the `libjd` core).

## Build

From the repo root:

```
cd windows
cargo build --release
```

This builds the workspace's two parts: the DLL at `windows\target\release\ime_jd.dll` and the user-dictionary window at `windows\target\release\ime_jd_userdict.exe`. The build script invokes the Zig core build automatically.

## Install

`register.bat` does the full install:

1. Right-click `register.bat` → **Run as administrator**.
2. The script copies the DLL and the user-dictionary window to `C:\Program Files\ime-jd\`, grants AppContainer read access (so UWP apps can load the DLL), runs `regsvr32`, and adds **键道用户自造词** to the Start menu for all users.
3. Add 键道 to your keyboard list: **Settings → Time & language → Language → Chinese (Simplified) → Options → Add a keyboard → 键道**.

`register.bat` works in two layouts:
- Run from the repo (uses `target\release\` next to itself).
- Bundled for distribution (uses the files in the same directory as the script).

## Uninstall

Right-click `unregister.bat` → **Run as administrator**.

The script unregisters the COM/TSF entries, removes the Start menu entry, and tries to delete `C:\Program Files\ime-jd\` and its contents. If a host process (Explorer, browser, editor, etc.) still has the DLL mapped, or the user-dictionary window is open, the file delete fails for that copy and the directory stays. Sign out and back in (or reboot) to release the DLL, then re-run the script or delete the folder by hand. Each user's phrases, in `%APPDATA%\ime-jd\`, are left alone.

## Updating during development

`cargo build --release` rebuilds the DLL and the window. Re-running `register.bat` handles the rest — it unregisters the old copy, renames the locked files out of the way (Windows allows rename-while-loaded, and rename-while-running for the window), copies the new ones, and re-registers.

If you've selected 键道 in a running app (Notepad, browser, etc.) you'll need to **close that app and reopen it** before the new code takes effect: Windows doesn't reload a DLL inside a process that already mapped it.

## Updates

Whenever 键道 is activated in an application, the IME asks GitHub for the latest release at most once a day — shared across all applications through `HKCU\Software\hronro\ime-jd`, and skipped inside AppContainer (Store) apps. When that release is newer than the running DLL, the candidate window shows one extra line, **键道有新版本 vX.Y.Z，点击下载并安装**, until you click it.

Clicking it downloads that release's zip in the background, verifies it against the SHA-256 the feed reports, extracts it, and runs the bundled `register.bat` **elevated** — so you get one UAC prompt, then the update installs itself (the same in-place DLL swap `register.bat` does for a manual upgrade). Applications you already have open keep running the old DLL until you next launch them (Windows can't reload a DLL a process has already mapped), so the new version takes effect in apps started afterwards, or after you sign out and back in. If any step fails, the click falls back to opening the release page so you can upgrade by hand. The notice is retired for that version once clicked, here and in every other application.

To turn the check off, create a DWORD value `CheckForUpdates` = `0` under `HKCU\Software\hronro\ime-jd`. The other values there are state: `LastUpdateCheck` (QWORD, Unix seconds), `LatestVersion`, `SeenVersion` — delete `LastUpdateCheck` to force a check on the next activation. The request carries no identifying data beyond a `User-Agent` with the IME version. Implementation: `src/update/` (`feed.rs` is the host-independent model — version/asset parsing — with unit tests, `mod.rs` the WinHTTP download + SHA-256 + extract + registry + elevated-launch side); the notice row lives in `candidate_window.rs`.

## User dictionary

The user's own phrases (用户自造词) are merged into every candidate list once the feature is switched on: a phrase on a code of its own composes like a built-in word, hints included, and a phrase on a code it shares with a built-in word is listed first, so adding one is how a user overrides what that code commits by default. Among the user's own phrases on one code, file order decides.

**Where they live.** One text file, `%APPDATA%\ime-jd\用户自造词.txt`, which roams with the user's profile, in `libjd`'s table format: one `词<TAB>编码` line per phrase, `#` comments, blank lines ignored, UTF-8 (a BOM is tolerated). Codes are 1 to 6 letters `a`-`z`; a phrase is at most 255 bytes; at most 10 000 phrases. The switch is the DWORD `UserDictEnabled` under `HKCU\Software\hronro\ime-jd`, **off by default**: while it is off, every application types with the built-in dictionary alone, whatever the file holds.

**How applications pick it up.** The IME is a DLL inside every application the user types in, so each of those processes builds the dictionary itself from the file — about 0.25 ms per 1 000 phrases, 3.4 ms at the 10 000 cap — and writes nothing anywhere; there is no compiled cache. At the first key of every composition it reads the switch and, while that is on, looks at the file's size and time (`src/user_dict.rs`); when either changed, it rebuilds, so a save from the window or from a text editor reaches every running application at its next word. A line the engine cannot parse is skipped and nothing else is lost; a file that cannot be loaded at all (not UTF-8, over the caps) leaves each application on the dictionary it loaded last.

**Sandboxed applications.** Store apps and the Start menu's search box run in an AppContainer, which by default may read neither `%APPDATA%` nor `HKCU\Software`. Each time the window opens it grants read access to the phrases folder (inherited by the file and by every save) and to the registry key, to the same two package groups `register.bat` grants on the install folder — what Microsoft's IME requirements ask of a dictionary kept outside Program Files — so the phrases work there too. The price is that any sandboxed app can read the phrases file, as any desktop app already can. Until the window has been opened once, sandboxed applications type with the built-in dictionary.

**The window.** **键道用户自造词** (`ime_jd_userdict.exe`, beside the DLL; in the Start menu) is a resizable dialog in the style of the system's own list editors, and opening it again brings the open one forward:

- The phrases in file order, with a 状态 column holding `libjd`'s own notes on the file after every save: red for a line the engine skips because it does not parse, grey for a duplicate it drops (the same phrase on the same code as an earlier line, or as a built-in word), orange for a phrase whose code a built-in word or another line already uses — it works, listed first, but the code no longer commits it directly. The status line below counts them.
- **新建…** and **编辑…** open a small dialog with the phrase and its code. The code field lowercases what is typed and keeps input methods out, so a code types as letters even while 键道 is active; **确定** waits until both fields hold something. **删除** asks first. **上移** / **下移** move the selected phrases, which is what orders phrases on one code; they are off while a search narrows the list. Every confirmed change rewrites the whole file at once.
- **移除重复词条…** counts the duplicates and what they repeat and offers to delete them; **选中查看** selects every flagged line instead.
- **用文本编辑器打开** opens the file in the default editor for `.txt`; the window watches the folder and reloads when that save lands. That is also how a whole list of phrases comes in or goes out: the file is plain text in a folder of the user's, to paste into or copy from.
- **启用用户自造词** is the switch.
- Enter or a double-click edits a phrase, Delete deletes, Ctrl+A selects everything, Alt plus an underlined letter presses that button, Esc closes, and the context menu carries the row commands.
- `ime_jd_userdict.exe --file <path>` opens the window on another file, for trying it out: it grants nothing and remembers no placement, but the switch is still the real one.

Implementation: `userdict/` (package `jd-userdict`). Its library is shared with the DLL — `file.rs` (the location, the line format, atomic writes, the change stamp), `switch.rs` (the registry switch) and `access.rs` (the sandbox grants). Its binary is the window, `src/window/`: `mod.rs` (the dialog, from `userdict.rc`), `entry.rs` (the 新建/编辑 dialog), `table.rs` (the phrase list and its operations), `store.rs` (reading, building and writing the file), `problem.rs` (the engine's verdict on a line, in the words every client uses) and `watch.rs` (the folder watcher). On the DLL's side, `src/user_dict.rs` loads and reloads the dictionary, and `jd.rs` swaps a thread's engine for one over the new dictionary when nothing is composing. `cargo test` covers the format, the switch, the grants, the list operations against temporary files, and the DLL's loading.

## Keys (when 键道 is the active IME)

| Key | Action |
|---|---|
| `a`-`z`, `;` | Feed into the engine; starts/extends a composition |
| `.` `,` `?` `!` `[` `]` `"` `'` `(` etc. | Feed into the engine, which may auto-convert to Chinese punctuation (e.g. `.` → `。`, `"` → `“`/`”` alternating) or open a punctuation candidate window (e.g. `[` → `「`/`【`/`〔`/`［`) |
| Digits `1`-`9` | IME-side: commit the candidate at that index from the popup; falls through to literal input if no candidate at that slot |
| Space | Commit candidate #1 (or the raw buffer if no candidates) |
| PgUp / PgDn / `-` / `=` | Navigate candidate pages within the same composition |
| Backspace | Remove the last typed key (shrinks composition + engine) |
| Esc | Cancel the in-flight composition |

In a field where the application has switched input methods off — a password box, the user-dictionary window's 编码 field — keys reach the application as typed.

## Project layout

```
windows/
  Cargo.toml          cdylib, depends on `windows` 0.62, `windows-core`, the
                      shared `jd` bindings crate (../bindings/rust) and
                      userdict/'s library; also the workspace root
  build.rs            generates the .rc (RT_MANIFEST + VERSIONINFO, the
                      version read from core/build.zig.zon); libjd itself is
                      located/linked by the `jd` crate's build script
  app.manifest        embedded Win32 manifest (asInvoker, Win 10/11 supportedOS)
  register.bat        admin installer
  unregister.bat      admin uninstaller
  src/
    lib.rs            DLL entry points (DllMain, DllGetClassObject, DllRegister/UnregisterServer)
    factory.rs        IClassFactory
    tip.rs            TextInputProcessor — ITfTextInputProcessor(Ex), ITfKeyEventSink,
                      ITfCompositionSink, ITfDisplayAttributeProvider
    composition.rs    composition lifecycle (start/update/commit/backspace/cancel)
    edit_session.rs   ITfEditSession wrapper that runs a closure
    display_attribute.rs  ITfDisplayAttributeInfo + IEnumTfDisplayAttributeInfo
                          plus apply/clear helpers via ITfProperty
    candidate_window.rs   D2D + DirectWrite popup showing the engine candidates
    registration.rs   COM + TSF profile/category registration (HKLM)
    guids.rs          CLSID + profile GUID + display attribute GUID
    jd.rs             TSF glue over the shared `jd` crate: UI-thread-local
                      engine context + page arithmetic (engine tests live in
                      bindings/rust/tests)
    user_dict.rs      the user dictionary this process's engines read,
                      rebuilt when the file or the switch changes
    update/           daily release-feed check (WinHTTP), HKCU state, and the
                      "new version" notice the candidate window shows
  userdict/           the user dictionary: a library shared with the DLL (the
                      phrases file, the switch, the sandbox grants) and the
                      键道用户自造词 window (ime_jd_userdict.exe, src/window/,
                      dialogs in userdict.rc)
```
