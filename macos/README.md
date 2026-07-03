# jd — macOS Input Method

Native macOS IME built on Apple's Input Method Kit (IMK), wrapping the same `libjd` C engine used by the `cli/` and `windows/` frontends.

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

**Upgrading** an already-installed version is just a double-click of the new `.pkg` — no log out/in needed. The installer overwrites the bundle in place and the postinstall restarts the running `JdIME` process, so the new build is live immediately and the existing input source keeps working.

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

Tests cover the engine's FFI smoke contract (mirroring `bindings/rust/tests/engine.rs`) and every branch of the `NSEvent → KeyAction` gate. The engine wrapper under test (`Engine` / `QuerySnapshot` / `KeyAction`) is shared source at `bindings/swift/`, compiled into both this project and `ios/`.
