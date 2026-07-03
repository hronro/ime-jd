# 键道输入法 — iOS

A native iOS **custom keyboard extension** for the 键道 (jd) input method, built on the shared Zig core engine (`../core`, linked as `libjd`). It looks and behaves like the built-in iOS keyboard, is fully offline, and requires **no Full Access**.

## Layout

```
ios/
  project.yml                 # XcodeGen spec (source of truth; .xcodeproj is gitignored)
  App/                        # container app (instructions + in-app keyboard preview)
  Keyboard/
    KeyboardViewController.swift   # the extension's principal class (UIInputViewController)
    Engine/                   # InputSession — the iOS dispatch core (the FFI wrapper itself
                              # is shared source at ../bindings/swift, listed in project.yml)
    UI/                       # KeyboardView, key grid, candidate bar/grid, theme, popups
  KeyboardTests/              # InputSession logic tests (hostless)
  scripts/
    build-libjd.sh              # Xcode prebuild: thin per-platform libjd.a (+ LIBJD_A fast-path)
```

## Requirements

- Xcode 15+ (deployment target **iOS 13**)
- [`zig`](https://ziglang.org) 0.16.0 — `brew install zig`
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Build & run

```sh
cd ios
xcodegen generate                 # regenerate JdIME-iOS.xcodeproj from project.yml
open JdIME-iOS.xcodeproj          # then ⌘R the "JdIME-iOS" scheme
```

The "Build libjd" prebuild phase compiles `../core` for the platform being built (via `zig`) and links it — no manual step. From the CLI:

```sh
xcodebuild -project JdIME-iOS.xcodeproj -scheme JdIME-iOS \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO build
```

### Enabling the keyboard

After installing the container app: **Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard… ▸ 键道**. No "Allow Full Access" needed. The container app also has an **in-app preview** ("在应用内试用键盘") to try the keyboard without enabling it system-wide.

## Tests

```sh
xcodebuild -project JdIME-iOS.xcodeproj -scheme JdIME-iOS \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO test
```

`KeyboardTests` covers the `InputSession` dispatch core (composition never leaks to the host, punctuation commits, candidate selection, backspace semantics, space-commits-top).

## Architecture notes

- **No inline marked text.** iOS forbids third-party keyboards from showing preedit text in the host app, so the in-flight code and candidates render in the keyboard's own candidate bar; only the final string is sent via `textDocumentProxy.insertText`. This matches the engine, which keeps composition state internally and emits only commits.
- **Selection = tap, pagination = scroll.** No number-key selectors. The 123/#+= layers show Chinese punctuation directly and insert the tapped mark themselves, **bypassing libjd's punctuation table** but matching its behavior: while composing, commit the top candidate first, then append the mark; otherwise insert it directly (see `core/docs/integration.md`).
- **No sound / haptics.** Both require Full Access on iOS, which this keyboard never requests.
- The engine FFI wrapper (`Engine` / `QuerySnapshot` / `KeyAction`) is shared source at `bindings/swift/`, compiled into both this project and `macos/` — one copy, no sync discipline needed. Only the dispatch layers stay per-platform (`InputSession` here, `KeyGate`/`Composition` on macOS) because their semantics deliberately differ.

## libjd linking

A from-source Xcode build targets one platform at a time, so `build-libjd.sh` produces a thin `libjd.a` for that platform via `zig` (mirroring the macOS build). To reuse a prebuilt slice instead of rebuilding, set `LIBJD_A=/path/to/libjd.a` — the prebuild script copies it directly (it must match the platform being built, device vs simulator; `lipo` can't tell the two arm64 slices apart). CI relies on this: `build-libs` cross-compiles the iOS `libjd.a` slices and `build-ios` links them via `LIBJD_A`, exactly like the macOS / Windows IME jobs.

## Distribution

On tagged releases, CI's `build-ios` job builds an **unsigned `.ipa`** (reusing the prebuilt device `libjd.a`) and uploads it to the GitHub Release. It's unsigned because public CI has no Apple signing credentials, so install it with a sideloading tool (AltStore / Sideloadly / TrollStore) that re-signs with your own Apple ID — it won't install by double-clicking. (A properly signed build / TestFlight upload would need an Apple Developer account and signing secrets.) On every push, CI also builds and uploads an unsigned `.ipa` as a workflow artifact.
