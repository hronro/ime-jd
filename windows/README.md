# 键道输入法 for Windows

Rust implementation of 键道输入法 as a Windows TSF Text Input Processor. Like Windows' own Chinese IMEs it has a 中 and an 英 mode, switched with Shift — see [中 and 英](#中-and-英). Besides the built-in dictionary it carries the user's own phrases, edited in a small window of their own — see [User dictionary](#user-dictionary) — and keeps its settings in the menu of its mode icon in the taskbar — see [Mode icon](#mode-icon).

## Requirements

- Windows 10 version 1809 (October 2018) or newer, x64 or ARM64. On ARM64 the IME is there for x64 applications too, which Windows 11 runs.
- For building: [Rust](https://rustup.rs/), [Zig](https://ziglang.org/) (used to build the `libjd` core).

## Build

From the repo root:

```
cd windows
cargo build --release
```

This builds the workspace's two parts: the DLL at `windows\target\release\ime_jd.dll` and the user-dictionary window at `windows\target\release\ime_jd_userdict.exe`. The build script invokes the Zig core build automatically.

The 32-bit DLL, for 32-bit applications (see [Install](#install)), is a build of its own, at `windows\target\i686-pc-windows-msvc\release\ime_jd.dll`; the core is built for it too:

```
rustup target add i686-pc-windows-msvc
cargo build --release --target i686-pc-windows-msvc -p jd-windows
```

On an ARM64 machine these two builds are the IME for ARM64 and for 32-bit applications. The ARM64 package of a release carries two files more — an x64 build of the DLL, and the forwarder that goes in front of the two 64-bit ones (see [Install](#install)) — which the release workflow adds (`build-windows-ime` in `.github/workflows/release.yml`), on an ARM64 runner:

```
rustup target add x86_64-pc-windows-msvc
cargo build --release --target x86_64-pc-windows-msvc -p jd-windows
forwarder\build.bat <ime_jd.lib>
```

`forwarder\build.bat` needs Visual Studio's C++ build tools for ARM64 and writes `windows\target\forwarder\ime_jd.dll`. Its argument is the resource file cargo compiled for the IME's own DLL — `ime_jd.lib` in that build's `OUT_DIR`, under `target\…\release\build\jd-windows-*\out\` — which gives the forwarder the IME's manifest, icon and version.

## Install

`register.bat` does the full install:

1. Right-click `register.bat` → **Run as administrator**.
2. The script copies the DLL (three of them from the ARM64 package, see below), the 32-bit DLL (as `ime_jd_x86.dll`), the user-dictionary window and `update.bat` (what the IME's own [update](#updates) runs) to `C:\Program Files\ime-jd\`, grants AppContainer read access (so UWP apps can load the DLLs), registers both DLLs with `regsvr32` — the 32-bit one with SysWOW64's — and adds **键道用户自造词** to the Start menu for all users.
3. Add 键道 to your keyboard list: **Settings → Time & language → Language → Chinese (Simplified) → Options → Add a keyboard → 键道**.

Windows loads an IME into each application in the application's own architecture: 64-bit applications load `ime_jd.dll`, and 32-bit ones — WPS Office, for one — load `ime_jd_x86.dll`, which the 32-bit `regsvr32` registers in the registry they read. Both DLLs register the one input profile, which 32-bit and 64-bit applications share, so 键道 is listed in every application; without the 32-bit DLL, a 32-bit application lists it but cannot switch to it. Started from a 32-bit process (the [update](#updates), clicked in a 32-bit application), the script hands itself over to the 64-bit `cmd`, which sees the real `Program Files` and `System32`.

**ARM64.** ARM64 Windows runs a third kind of application, x64 ones, and they read the registry that ARM64 applications read: the one DLL registered there has to load into both, which neither an ARM64 nor an x64 DLL does. So the ARM64 package installs three 64-bit files. `ime_jd_arm64.dll` and `ime_jd_x64.dll` are the IME for the two kinds of application. `ime_jd.dll`, the one that is registered, is there a *forwarder* (`forwarder/`): an Arm64X DLL — one file with an ARM64 side and an x64 side — whose every entry point passes the call on to the IME beside it that is built for the application at hand. It finds that DLL by its own path. A DLL that only forwards its exports would leave the finding to Windows, which looks in the forwarding DLL's folder only if that DLL was loaded with `LOAD_WITH_ALTERED_SEARCH_PATH` — as COM loads an IME in a desktop application, but not in a Store app, and not TSF where it loads a text service itself, for its display attributes. `regsvr32` is given the forwarder, and the IME behind it registers the path the call came by (`server_path` in `src/registration.rs`). If the forwarder cannot be registered — it does not load, or does not find the IME — `register.bat` says so and registers `ime_jd_arm64.dll` itself, which leaves x64 applications without 键道 and everything else as it is.

`register.bat` works in two layouts:
- Run from the repo (uses `target\release\` next to itself, and `target\i686-pc-windows-msvc\release\` for the 32-bit DLL; without that build it installs for 64-bit applications only — on ARM64, for ARM64 ones only).
- Bundled for distribution (uses the files in the same directory as the script; `ime_jd_arm64.dll` among them makes it the ARM64 package).

**Checking an installation.** `cargo run --release -p jd-check` says whether the installed IME can be created in a process of the architecture it is built for — `--target i686-pc-windows-msvc` for a 32-bit process, `--target x86_64-pc-windows-msvc` on ARM64 for an x64 one — in the two ways TSF comes by it: through COM, and by loading the registered DLL by its path, each in a process of its own. The workflows that build the packages (`build-on-push.yml`, `release.yml`) run it for every kind of process against each package, installed on its own runner by its `register.bat`, and once more with `--uninstalled` after its `unregister.bat`. Given a DLL's path instead, it checks a build that is not installed.

## Uninstall

Right-click `unregister.bat` → **Run as administrator**.

The script unregisters the COM/TSF entries, removes the Start menu entry, and tries to delete `C:\Program Files\ime-jd\` and its contents. If a host process (Explorer, browser, editor, etc.) still has the DLL mapped, or the user-dictionary window is open, the file delete fails for that copy and the directory stays. Sign out and back in (or reboot) to release the DLL, then re-run the script or delete the folder by hand. Each user's phrases, in `%APPDATA%\ime-jd\`, are left alone.

## Updating during development

`cargo build --release` rebuilds the DLL and the window, and the i686 build above rebuilds the 32-bit DLL. Re-running `register.bat` handles the rest — it unregisters the old copy, renames the locked files out of the way (Windows allows rename-while-loaded, and rename-while-running for the window), copies the new ones, and re-registers.

If you've selected 键道 in a running app (Notepad, browser, etc.) you'll need to **close that app and reopen it** before the new code takes effect: Windows doesn't reload a DLL inside a process that already mapped it.

## Updates

Whenever 键道 is activated in an application, the IME asks GitHub for the latest release at most once a day — shared across all applications through `HKCU\Software\hronro\ime-jd`, and skipped inside AppContainer (Store) apps. When that release is newer than the running DLL, the candidate window shows one extra line, **键道有新版本 vX.Y.Z，点击下载并安装**, until you click it.

Clicking it downloads that release's zip for the machine's architecture in the background (the 32-bit DLL picks the same one, and on ARM64 so does the x64 one), verifies it against the SHA-256 the feed reports, and runs the installed `update.bat` **elevated** — so you get one UAC prompt, then the update installs itself: `update.bat` unpacks the zip and runs its `register.bat` (the same in-place DLL swap `register.bat` does for a manual upgrade). Nothing that runs elevated comes from a place the user's own programs can write. The download waits in the temporary folder, where any of them could put another file in its place while the prompt is up; so what is started is `cmd` on the `update.bat` under Program Files and no other, with the SHA-256 of what was downloaded, and that script reads the zip once and unpacks — into a folder beside itself — only what has that SHA-256. Applications you already have open keep running the old DLL until you next launch them (Windows can't reload a DLL a process has already mapped), so the new version takes effect in apps started afterwards, or after you sign out and back in. If any step fails, the click falls back to opening the release page so you can upgrade by hand. The notice is retired for that version once clicked, here and in every other application.

On the secure desktop — the sign-in screen, a UAC prompt — none of this happens: no check, no notice, and the [mode icon](#mode-icon)'s menu is greyed out. Whoever types there has not signed in, and the program they type into runs as SYSTEM, so nothing may be downloaded or started from it. The IME takes TSF's word for where it is (`TF_TMAE_SECUREMODE`), and takes any host that runs as SYSTEM for the secure desktop too.

To turn the check off, untick **自动检查更新** in the [mode icon](#mode-icon)'s menu, which sets the DWORD `CheckForUpdates` under `HKCU\Software\hronro\ime-jd` to `0`. The other update values there are state: `LastUpdateCheck` (QWORD, Unix seconds), `LatestVersion`, `SeenVersion` — delete `LastUpdateCheck` to force a check on the next activation. The request carries no identifying data beyond a `User-Agent` with the IME version. Implementation: `src/update/` (`feed.rs` is the host-independent model — version/asset parsing — with unit tests, `mod.rs` the WinHTTP download + SHA-256 + registry + elevated-launch side), and `update.bat`, the elevated half; the notice row lives in `candidate_window.rs`.

## 中 and 英

Like Windows' own Chinese IMEs, 键道 has two input modes. In **中** the keys go to the engine as described under [Keys in 中](#keys-in-中); in **英** every key reaches the application as typed, ASCII punctuation included, with no candidates. Pressing and releasing **Shift** on its own switches between them, as do a left click on the [mode icon](#mode-icon), whose 中 or 英 shows the mode, and Windows' Ctrl+Space input-method on/off hotkey. Shift counts only when nothing else happened while it was down: with a letter it types a capital, Ctrl+Shift and Alt+Shift belong to Windows, and with a click or the wheel it extends a selection or scrolls, so none of those switch. Shift while a code is being typed puts the letters typed so far into the text as they are, as Enter does, and then switches to 英; with a punctuation window open, the key itself goes in (`[`, not 「). In a field where the application has switched input methods off, Shift does nothing.

Each application keeps its own mode — it is TSF's keyboard open/close switch (`GUID_COMPARTMENT_KEYBOARD_OPENCLOSE`) of the application's thread, so an application that closes the input method switches 键道 to 英 too — and every application starts in 中, as Microsoft's IME guidelines ask. The key is not configurable. Implementation: `src/input_mode.rs`, and the keys themselves in `src/tip.rs`.

## Mode icon

While 键道 is the input method of the window in front, Windows shows the IME's mode icon in the taskbar, left of the input indicator — where Windows' own IMEs show their mode and keep their settings. It shows the [input mode](#中-and-英), 中 or 英, drawn in the taskbar's own glyph colour (white on a dark taskbar, black on a light one, the theme's text colour in high contrast) at the taskbar's scale, and redrawn when the mode, the theme or the scale changes. Its size is the one Microsoft's IME requirements give: 16 pixels at 100% in the taskbar, and 20 on the secure desktop — a UAC prompt, the sign-in screen — whose input indicator takes a larger icon. A left click switches the mode, as Shift does; a right click opens the menu:

- **用户自造词...** opens the [user-dictionary window](#user-dictionary).
- **启用用户自造词** is the user dictionary's switch.
- **自动检查更新** is the [update check](#updates)'s switch.

The menu belongs to the application in front, which keeps the focus, but an application is not always a place to change settings from: a packaged app (the new Notepad, Terminal) has its registry writes redirected into a private copy no other application reads, and a sandboxed one may write nothing. So the IME only reads the settings there. Each item starts `ime_jd_userdict.exe` instead — the window, or `--user-dict on|off` / `--check-updates on|off`, which set one switch and exit — and what a packaged app starts runs outside its package, as an ordinary process of the user's. A sandboxed app (a Store app, the Start menu's search box) is the exception: what it starts stays in its sandbox, and Microsoft's IME requirements treat an IME that gets around that as malware. There the menu does not open — the window in front belongs to another process — and the settings are a click away in any desktop application. Nor does the menu open from the keyboard (Win+B and the arrow keys reach the icon, but leave the taskbar in front); the window, with the user dictionary's switch, is in the Start menu.

Implementation: `src/mode_icon.rs` (the TSF language-bar item under `GUID_LBI_INPUTMODE`, its icon and its menu; the TIP registers `GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT` for it) and `src/settings.rs` (what the menu reads, and how it has the helper change it).

## User dictionary

The user's own phrases (用户自造词) are merged into every candidate list once the feature is switched on: a phrase on a code of its own composes like a built-in word, hints included, and a phrase on a code it shares with a built-in word is listed first, so adding one is how a user overrides what that code commits by default. Among the user's own phrases on one code, file order decides.

**Where they live.** One text file, `%APPDATA%\ime-jd\用户自造词.txt`, which roams with the user's profile, in `libjd`'s table format: one `词<TAB>编码` line per phrase, `#` comments, blank lines ignored, UTF-8 (a BOM is tolerated). Codes are 1 to 6 letters `a`-`z`; a phrase is at most 255 bytes; at most 10 000 phrases. The switch is the DWORD `UserDictEnabled` under `HKCU\Software\hronro\ime-jd`, **off by default** and set in the window or in the mode icon's menu: while it is off, every application types with the built-in dictionary alone, whatever the file holds.

**How applications pick it up.** The IME is a DLL inside every application the user types in, so each of those processes builds the dictionary itself from the file — about 0.25 ms per 1 000 phrases, 3.4 ms at the 10 000 cap — and writes nothing anywhere; there is no compiled cache. At the first key of every composition it reads the switch and, while that is on, looks at the file's size and time (`src/user_dict.rs`); when either changed, it rebuilds, so a save from the window or from a text editor reaches every running application at its next word. A line the engine cannot parse is skipped and nothing else is lost; a file that cannot be loaded at all (not UTF-8, over the caps) leaves each application on the dictionary it loaded last.

**Sandboxed applications.** Store apps and the Start menu's search box run in an AppContainer, which by default may read neither `%APPDATA%` nor `HKCU\Software`. Each time the window opens, and when the menu turns the dictionary on, `ime_jd_userdict.exe` grants read access to the phrases folder (inherited by the file and by every save) and to the registry key, to the same two package groups `register.bat` grants on the install folder — what Microsoft's IME requirements ask of a dictionary kept outside Program Files — so the phrases work there too. The price is that any sandboxed app can read the phrases file, as any desktop app already can. Until then, sandboxed applications type with the built-in dictionary.

**The window.** **键道用户自造词** (`ime_jd_userdict.exe`, beside the DLL; in the Start menu and in the mode icon's menu) is a resizable dialog in the style of the system's own list editors, and opening it again brings the open one forward:

- The phrases in file order, with a 状态 column holding `libjd`'s own notes on the file after every save: red for a line the engine skips because it does not parse, grey for a duplicate it drops (the same phrase on the same code as an earlier line, or as a built-in word), orange for a phrase whose code a built-in word or another line already uses — it works, listed first, but the code no longer commits it directly. The status line below counts them.
- **新建…** and **编辑…** open a small dialog with the phrase and its code. The code field lowercases what is typed and keeps input methods out, so a code types as letters even while 键道 is active; **确定** waits until both fields hold something. **删除** asks first. **上移** / **下移** move the selected phrases, which is what orders phrases on one code; they are off while a search narrows the list. Every confirmed change rewrites the whole file at once.
- **移除重复词条…** counts the duplicates and what they repeat and offers to delete them; **选中查看** selects every flagged line instead.
- **用文本编辑器打开** opens the file in the default editor for `.txt`; the window watches the folder and reloads when that save lands. That is also how a whole list of phrases comes in or goes out: the file is plain text in a folder of the user's, to paste into or copy from.
- **启用用户自造词** is the switch; the window follows a change made in the mode icon's menu.
- Enter or a double-click edits a phrase, Delete deletes, Ctrl+A selects everything, Alt plus an underlined letter presses that button, Esc closes, and the context menu carries the row commands.
- `ime_jd_userdict.exe --file <path>` opens the window on another file, for trying it out: it grants nothing and remembers no placement, but the switch is still the real one.

Implementation: `userdict/` (package `jd-userdict`). Its library is shared with the DLL — `file.rs` (the location, the line format, atomic writes, the change stamp), `switch.rs` (the registry switches, the update check's too) and `access.rs` (the sandbox grants). Its binary is the window, `src/window/`: `mod.rs` (the dialog, from `userdict.rc`), `entry.rs` (the 新建/编辑 dialog), `table.rs` (the phrase list and its operations), `store.rs` (reading, building and writing the file), `problem.rs` (the engine's verdict on a line, in the words every client uses) and `watch.rs` (the watcher on the folder and on the switches). On the DLL's side, `src/user_dict.rs` loads and reloads the dictionary, and `jd.rs` swaps a thread's engine for one over the new dictionary when nothing is composing. `cargo test` covers the format, the switches, the grants, the list operations against temporary files, the DLL's loading, and the mode icon's drawing.

## Keys in 中

| Key | Action |
|---|---|
| `a`-`z`, `;` | Feed into the engine; starts/extends a composition |
| `.` `,` `?` `!` `[` `]` `"` `'` `(` etc. | Feed into the engine, which may auto-convert to Chinese punctuation (e.g. `.` → `。`, `"` → `“`/`”` alternating) or open a punctuation candidate window (e.g. `[` → `「`/`【`/`〔`/`［`) |
| Digits `1`-`9` | IME-side: commit the candidate at that index from the popup; falls through to literal input if no candidate at that slot |
| Space | Commit candidate #1 (or the raw buffer if no candidates) |
| PgUp / PgDn / `-` / `=` | Navigate candidate pages within the same composition |
| Backspace | Remove the last typed key (shrinks composition + engine) |
| Esc | Cancel the in-flight composition |
| Enter | Commit the typed letters as they are |
| Home / End / Insert / Delete | Nothing, while composing: let through, they would move the application's caret out of the composition |
| Shift, alone | Switch to 英 — while composing, after committing the typed letters as they are |

In 英, and in a field where the application has switched input methods off — a password box, the user-dictionary window's 编码 field — keys reach the application as typed.

A composition belongs to the field it was started in. When the focus moves to another field or window of the application — a click, Tab — the letters typed so far go into the text as they are, as with Enter, and the next key starts afresh where the focus is. So they do when the application ends the composition itself — at a click elsewhere in the same text, in most — and when the user switches to another input method: either way they are left as plain text, without the dotted underline of a code in flight. When another application comes to the front, the candidates leave the screen, and they are back when this one is, if it kept the composition open. Implementation: the `ITfThreadMgrEventSink`, `ITfThreadFocusSink` and `ITfCompositionSink` halves of `src/tip.rs`.

The candidates open under the text being typed, their left edge on its own, and over it on the last lines of the screen; either way they stay inside the work area of the monitor the text is on, moved left where the text is near the right edge. They go with the text when the application scrolls or moves it (`ITfTextLayoutSink`). An application that has not laid the new text out yet when asked where it is (`TS_E_NOLAYOUT`) is to say when it has, and the candidates wait for that — for a tenth of a second, after which they open under the system caret or, in a window without one, in the corner of the focus window, as they do at once where the application gives no place at all. Implementation: `position` and `follow` in `src/candidate_window.rs`, `locate` in `src/composition.rs`.

The candidate window takes its colours from the theme: the light or the dark one's, with the user's accent, and in a high-contrast theme the theme's own and no others — the window's colours for the list and all its text, the selection's for the candidate Space commits, an outline in that colour for the one under the pointer, and the link colour for the update notice under it. They are read again every time the candidates come up, so a change of theme shows at the next key.

An application that draws the candidates itself — a full-screen game, for one — reads them from TSF's UI element (`ITfCandidateListUIElement`) instead. It is asked before the candidate window opens, so the window never shows there; it is told when the list changes and when it ends, by a key or by a click; and what it reads is the whole list in pages of eight, any candidate of it, with the page on show as the current one and that page's first candidate, the one Space commits, as the selection. Implementation: `src/ui_element.rs`.

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
  update.bat          installed with the IME: checks and unpacks the release
                      its update downloaded, and runs that release's
                      register.bat
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
    ui_element.rs     ITfCandidateListUIElement: the candidates, for an
                      application that draws them itself
    input_mode.rs     中 and 英: the mode, and Shift pressed alone
    mode_icon.rs      the taskbar's mode icon (a language-bar item) and its menu
    settings.rs       what that menu reads, and the helper that changes it
    host.rs           what kind of process the IME is in (AppContainer or not)
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
                      phrases file, the switches, the sandbox grants) and the
                      键道用户自造词 window (ime_jd_userdict.exe, src/window/,
                      dialogs in userdict.rc), which also sets the switches
                      for the mode icon's menu
  forwarder/          the ARM64 package's ime_jd.dll: an Arm64X DLL in front
                      of the IME's ARM64 and x64 DLLs (forwarder.c, its
                      exports in forwarder.def), built with MSVC by build.bat
  check/              ime_jd_check.exe (package jd-check): creates the
                      installed IME as TSF does, in a process of the
                      architecture it is built for; what the workflows
                      test every package with
```
