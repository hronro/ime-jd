# 键道输入法 for Windows

Rust implementation of 键道输入法 as a Windows TSF Text Input Processor.

## Requirements

- Windows 10 version 1809 (October 2018) or newer, x64.
- For building: [Rust](https://rustup.rs/), [Zig](https://ziglang.org/) (used to build the `libjd` core).

## Build

From the repo root:

```
cd windows
cargo build --release
```

The DLL ends up at `windows\target\release\jd_ime.dll`. The build script invokes the Zig core build automatically.

## Install

`register.bat` does the full install:

1. Right-click `register.bat` → **Run as administrator**.
2. The script copies the DLL to `C:\Program Files\jd-ime\`, grants AppContainer read access (so UWP apps can load it), and runs `regsvr32`.
3. Add 键道 to your keyboard list: **Settings → Time & language → Language → Chinese (Simplified) → Options → Add a keyboard → 键道**.

`register.bat` works in two layouts:
- Run from the repo (uses `target\release\jd_ime.dll` next to itself).
- Bundled for distribution (uses the DLL in the same directory as the script).

## Uninstall

Right-click `unregister.bat` → **Run as administrator**.

The script unregisters the COM/TSF entries and tries to delete `C:\Program Files\jd-ime\` and its contents. If a host process (Explorer, browser, editor, etc.) still has the DLL mapped, the file delete fails for that copy and the directory stays. Sign out and back in (or reboot) to release the DLL, then re-run the script or delete the folder by hand.

## Updating during development

`cargo build --release` rebuilds the DLL. Re-running `register.bat` handles the rest — it unregisters the old copy, renames the locked file out of the way (Windows allows rename-while-loaded), copies the new DLL, and re-registers.

If you've selected 键道 in a running app (Notepad, browser, etc.) you'll need to **close that app and reopen it** before the new code takes effect: Windows doesn't reload a DLL inside a process that already mapped it.

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

## Project layout

```
windows/
  Cargo.toml          cdylib, depends on `windows` 0.62 and `windows-core`
  build.rs            invokes `zig build` for the core, links libjd_static.lib,
                      and generates the .rc (RT_MANIFEST + VERSIONINFO, the
                      version read from core/build.zig.zon)
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
    jd.rs             FFI to libjd (Mutex-guarded global engine)
  tests/
    engine.rs         exercises the FFI layer without TSF
```
