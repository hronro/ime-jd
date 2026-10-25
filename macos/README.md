# jd — macOS Input Method

Native macOS IME built on Apple's Input Method Kit (IMK), wrapping the same `libjd` C engine used by the `cli/` and `windows/` frontends. Besides the built-in dictionary it carries the user's own phrases — see [User dictionary](#user-dictionary).

## Requirements

- macOS 12 (Monterey) or later
- Xcode 15 or later
- [Zig](https://ziglang.org/) on `PATH` — `brew install zig`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Build

`scripts/build-pkg.sh` generates the Xcode project, builds the app, and assembles the installer in one step:

```sh
# Native arch (default) → build/pkg/jd-ime-macos-<arch>.pkg
scripts/build-pkg.sh

# Universal (arm64 + x86_64) → build/pkg/jd-ime-macos-universal.pkg
scripts/build-pkg.sh --universal
```

## Install

Double-click `jd-ime-macos-<arch>.pkg` and walk through the installer. It copies the bundle into `/Library/Input Methods/` (system-wide, available to all users; admin password required at install time — standard for macOS IMEs).

On a **first-time install**, macOS only re-scans for new input methods at the start of a login session, so you must **log out and back in** (a full restart also works) before enabling it:

1. **Log out and log back in.**
2. Open **System Settings** → **Keyboard**
3. Click **Edit…** next to *Input Sources*
4. Press **+**, find **键道** under *Chinese, Simplified*, and add it
5. Pick **键道** from the input-source menu (or use ⌃Space / ⌃⌥Space)

**Upgrading** an already-installed version is just a double-click of the new `.pkg` — no log out/in needed. The installer overwrites the bundle in place and the postinstall restarts the running `JdIME` process, so the new build is live immediately and the existing input source keeps working. The IME also finds new releases by itself — see [Updates](#updates).

## Updates

While 键道 is the selected input source, the Input menu (the menu-bar input-source dropdown) carries the IME's own items: the version, **检查更新…**, and the **自动检查更新** toggle. With the toggle on (the default), the IME asks GitHub for the latest release at most once a day — at launch and whenever it is activated — and, when that release is newer than the running build, posts one notification per version and adds a **发现新版本 …，下载并安装…** item. Clicking either downloads the `.pkg` for this machine's arch (`arm64` on Apple silicon even when the running build is the Intel slice), verifies it against the SHA-256 GitHub publishes for the asset, and opens it in Installer.app — the same flow as installing by hand, admin prompt included; the postinstall restarts the running IME.

The check sends nothing but the request (a `User-Agent` naming the IME and its version). State lives in the app's defaults — `defaults read com.hronro.ime-jd` shows `JdUpdateAutoCheck`, `JdUpdateLastCheck`, `JdUpdateLatestTag`, and friends; delete `JdUpdateLastCheck` to force a check on the next activation. Plain IDE builds carry version `0.0.0` and never auto-check (the menu's **检查更新…** still works). Implementation: `JdIME/Update/` (`UpdateFeed.swift` is the pure feed model, covered by `JdIMETests/UpdateFeedTests.swift`; `UpdateManager.swift` fetches, notifies, downloads) and `InputController.menu()`.

## User dictionary

The user's own phrases (用户自造词) are merged into every candidate list once the feature is switched on: a phrase on a code of its own composes like a built-in word, hints included, and a phrase on a code it shares with a built-in word is listed first, so adding one is how a user overrides what that code commits by default. Among the user's own phrases on one code, file order decides.

**Where they live.** One text file, `~/Library/Application Support/com.hronro.ime-jd/用户自造词.txt`, in `libjd`'s table format: one `词<TAB>编码` line per phrase, `#` comments, blank lines ignored, UTF-8 (a BOM is tolerated). Codes are 1 to 6 characters from `a`-`z` and `;`; a phrase is at most 255 bytes; at most 10 000 phrases. The file is the source of truth: the IME reads and compiles it at launch and whenever it changes (a dispatch source watches the file and its directory, so a text editor's atomic save counts), and every input session picks the new dictionary up at its next activation or at its first key after a composition ends. There is no compiled cache — a build is a couple of milliseconds. A line that does not parse (no TAB, a capital letter in a code, an over-long phrase) is skipped by the engine and nothing else is lost; the window flags it and the Input menu's status line counts it. Only a file that cannot be loaded at all (not UTF-8, over the engine's caps) keeps the previous dictionary live, with the reason in the status line and in a notification.

**The window.** While 键道 is the selected input source, the Input menu carries **用户自造词…**, which opens a window in the IME process (InputMethodKit does serve the IME's own windows, so phrases are typed there with 键道 like anywhere else):

- A table of the file's phrases in file order, two editable columns (词, 编码) and a status column. Every edit, addition (+), deletion (−, or ⌫ on a selected row) and drag-reorder is saved immediately. Every row is written as it is; the window validates nothing itself. A row the engine skips — empty or malformed code, over-long phrase — is shown in red with the engine's reason and simply does not take effect until fixed. Saving from the window rewrites the file as a header comment plus one line per phrase, so comments and blank lines added in a text editor do not survive a save from the window.
- **Drag rows to reorder.** Only the relative order of phrases on the *same* code is visible in the candidates; dragging is disabled while a search filter is active.
- **The status column** shows `libjd`'s own notes about the file after every save. *Invalid rows* (red, `不生效`) are the lines the engine skipped because they do not parse, with its reason. *Duplicates* (grey, `不生效`) are what the build dropped: a phrase identical to an earlier row (same 词, same 编码), or identical to a built-in word on the same code. *Same-code rows* (orange, `同码`) are phrases whose code already carries built-in words or other rows, with the counts: they do work, listed ahead of the built-in words, so a code that used to auto-commit now opens a candidate window. **移除重复词条** deletes the duplicates after a confirmation that counts them and says what they repeat; the same-code rows, which stay, and the skipped rows are mentioned, and 选中查看 selects every flagged row to look at instead. While the file cannot be loaded at all it says so, since the engine has no notes on a file it could not read.
- **用文本编辑器打开** opens the same file in whatever handles `.txt` (TextEdit by default), for bulk edits or pasting a table; the watcher brings the result back into the window and the engine.
- **启用用户自造词** (also a toggle in the Input menu) is **off by default**: until it is on, input sessions run on the built-in dictionary alone, whatever the file holds, while the window keeps showing and saving the phrases. Turning it off again never touches the file. The setting is `JdUserDictEnabled` in the app's defaults.

Implementation: `JdIME/UserDict/` — `UserDictLocation.swift` (only the file's location: the format — lenient line parsing for display, serialization, hashing — is shared source at `bindings/swift/UserDictFile.swift`, as is `bindings/swift/UserDictProblem.swift`, the engine's per-row verdict with its status text, which the window maps onto its rows by line), `UserDictStore.swift` (load, build, watch, the toggle, last-good fallback) and `UserDictWindowController.swift` (the window, which maps the build's notes onto its rows by line); the engine-side wrapper is `bindings/swift/UserDict.swift`, and `InputController.syncEngine()` is where a session adopts a changed dictionary. Tests: `JdIMETests/UserDictTests.swift` (the wrapper, against the real engine), `UserDictFileTests.swift`, `UserDictStoreTests.swift` (including the file watcher) and `UserDictWindowTests.swift` (the window's model operations against a visible window).

## Uninstall

1. Remove **键道** from the input-source list: **System Settings** → **Keyboard** → **Edit…** next to *Input Sources*, select **键道**, then press **−**.
2. Delete the bundle (it lives in the system-wide folder, so this needs `sudo`):

   ```sh
   sudo rm -rf "/Library/Input Methods/JdIME.app"
   ```

3. (Optional) Forget the installer receipt so the system no longer records the package as installed:

   ```sh
   sudo pkgutil --forget com.hronro.ime-jd.pkg
   ```

Then **log out and back in** (or restart) to release the running `JdIME` process and fully clear the input method.

## Test

```sh
xcodebuild \
    -project JdIME.xcodeproj \
    -scheme JdIME \
    -derivedDataPath build \
    test
```

Tests cover the engine's FFI smoke contract and the user-dictionary wrapper (both mirroring `bindings/rust/tests/engine.rs`), every branch of the `NSEvent → KeyAction` gate, the update feed model, and the user-dictionary file and store. The engine wrapper under test (`Engine` / `Candidate` / `UserDict` / `KeyAction`) is shared source at `bindings/swift/`, compiled into both this project and `ios/`.
