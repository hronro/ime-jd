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
  KeyboardTests/              # InputSession + theme logic tests (hostless)
  KeyboardUITests/            # QA-only driver for the real extension (JdKeyboardQA scheme)
  scripts/
    build-libjd.sh              # Xcode prebuild: thin per-platform libjd.a (+ LIBJD_A fast-path)
  fastlane/                     # App Store upload lane (release_appstore); CI-only signing
```

## Requirements

- Xcode 26+ — the liquid-glass style references iOS 26 SDK symbols (`UIGlassEffect`); the deployment target stays **iOS 13**
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
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build
```

### Enabling the keyboard

After installing the container app: **Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard… ▸ 键道**. No "Allow Full Access" needed. The container app also has an **in-app preview** ("在应用内试用键盘") to try the keyboard without enabling it system-wide.

## Tests

```sh
xcodebuild -project JdIME-iOS.xcodeproj -scheme JdIME-iOS \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

`KeyboardTests` covers the `InputSession` dispatch core (composition never leaks to the host, punctuation commits, candidate selection, backspace semantics, space-commits-top) and `KeyboardTheme` resolution (style gate, appearance, return-key tinting).

### QA launch args (in-app preview)

The container app's preview screen takes launch args for screenshot-driven QA (`simctl launch <udid> com.hronro.ime-jd -preview …`):

- `-preview` — open the preview screen directly; `-landscape` — force landscape
- `-type ni` — feed keys into the engine so the candidate bar is populated
- `-numbers` / `-symbols` — show that key plane
- `-expand` — open the expanded candidate grid (combine with `-type`)
- `-popup r` — render the key-press bubble (it only lives during a touch otherwise; iPhone only — iPad shows no popups, like the system keyboard)
- `-classic` — force the pre-iOS-26 style on an iOS 26 simulator
- `-system` — use the SYSTEM keyboard instead of the inline preview: with the extension enabled, that is the real 键道 extension in its real hosting context

### Extension-context QA (JdKeyboardQA scheme)

`simctl` cannot synthesize taps, and third-party keyboards are trust-gated behind the Settings enable flow (writing `AppleKeyboards` defaults is not enough). The `JdKeyboardQA` scheme runs a UI test that enables 键道 in Settings, switches to it via the globe key inside the preview app (`-preview -system`), then holds the app open and drops a marker file so a host-side loop can take screenshots:

```sh
TEST_RUNNER_JD_QA_MARKER=/tmp/jd-qa-ready \
xcodebuild test -project JdIME-iOS.xcodeproj -scheme JdKeyboardQA \
  -destination "id=$UDID" -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO &
# wait for /tmp/jd-qa-ready, screenshot via `simctl io`, then rm the marker
# (the test exits once the marker disappears)
```

## Architecture notes

- **Two visual styles, one code path.** `KeyboardTheme` carries a `style` axis: **liquid glass** on iOS 26+ (fully transparent over the system keyboard panel's material — painting our own would seam against the panel's top strip and globe/mic chin; translucent key fills with continuous corners; a real `UIGlassEffect` key-press bubble; the in-app preview supplies a stand-in material since it has no system panel) and **classic** below (the opaque pre-26 look, byte-for-byte the old palette). Resolved at runtime in `KeyboardTheme.resolve`; everything downstream is theme-driven. Keys are deliberately NOT per-key `UIGlassEffect` views — ~30 live backdrop layers, rebuilt on every plane switch, would blow the extension's memory/GPU budget, and translucent fills over the shared material are what the stock keys read as anyway. A live light/dark flip while the keyboard is presented can lag (the system doesn't reliably deliver trait changes to a presented extension); it self-heals on the next keystroke or re-present.
- **No inline marked text.** iOS forbids third-party keyboards from showing preedit text in the host app, so the in-flight code and candidates render in the keyboard's own candidate bar; only the final string is sent via `textDocumentProxy.insertText`. This matches the engine, which keeps composition state internally and emits only commits.
- **Selection = tap, pagination = scroll.** No number-key selectors. The 123/#+= layers show Chinese punctuation directly and insert the tapped mark themselves, **bypassing libjd's punctuation table** but matching its behavior: while composing, commit the top candidate first, then append the mark; otherwise insert it directly (see `core/docs/integration.md`).
- **No sound / haptics.** Both require Full Access on iOS, which this keyboard never requests.
- The engine FFI wrapper (`Engine` / `QuerySnapshot` / `KeyAction`) is shared source at `bindings/swift/`, compiled into both this project and `macos/` — one copy, no sync discipline needed. Only the dispatch layers stay per-platform (`InputSession` here, `KeyGate`/`Composition` on macOS) because their semantics deliberately differ.

## libjd linking

A from-source Xcode build targets one platform at a time, so `build-libjd.sh` produces a thin `libjd.a` for that platform via `zig` (mirroring the macOS build). To reuse a prebuilt slice instead of rebuilding, set `LIBJD_A=/path/to/libjd.a` — the prebuild script copies it directly (it must match the platform being built, device vs simulator; `lipo` can't tell the two arm64 slices apart). CI relies on this: `build-libs` cross-compiles the iOS `libjd.a` slices and `build-ios` links them via `LIBJD_A`, exactly like the macOS / Windows IME jobs.

## Distribution

On tagged releases, CI's `build-ios` job builds an **unsigned `.ipa`** (reusing the prebuilt device `libjd.a`) and uploads it to the GitHub Release. It's unsigned because public CI has no Apple signing credentials, so install it with a sideloading tool (AltStore / Sideloadly / TrollStore) that re-signs with your own Apple ID — it won't install by double-clicking. On every push, CI also builds and uploads an unsigned `.ipa` as a workflow artifact.

### App Store (signed, tags only)

`release.yml`'s `upload-ios-appstore` job builds a **signed** archive and uploads the binary to App Store Connect through the `ios/fastlane` `release_appstore` lane. It runs **only on version tags**, **alongside** the unsigned `.ipa` (which is left untouched — sideloaders still get it), and **skips itself** when the signing secrets are absent (forks / credential-less runs stay green).

Signing is injected onto the *ephemeral* xcodegen project at CI time (per-target manual signing via fastlane), so `project.yml` carries no account-specific values and local `xcodegen generate` + ⌘R keeps using your own automatic/personal-team signing.

Configure these repo **Secrets** (base64-encode the binary blobs, e.g. `base64 -i dist.p12 | pbcopy`):

| Secret | What |
| --- | --- |
| `IOS_DIST_CERT_P12` | Apple Distribution certificate exported as `.p12`, base64 |
| `IOS_DIST_CERT_PASSWORD` | the `.p12` export password |
| `IOS_PROFILE_APP` | App Store provisioning profile for `com.hronro.ime-jd`, base64 |
| `IOS_PROFILE_KEYBOARD` | App Store provisioning profile for `com.hronro.ime-jd.keyboard`, base64 |
| `IOS_TEAM_ID` | 10-character Apple Developer Team ID |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` | App Store Connect API key ID + issuer ID |
| `ASC_KEY_P8` | the App Store Connect API key `.p8`, base64 |

One-time prerequisites on Apple's side: a paid **Apple Developer Program** membership; the **App record** created in App Store Connect for `com.hronro.ime-jd` (metadata, screenshots, privacy-policy URL, App Privacy = *Data Not Collected*); and the Distribution certificate + both App Store profiles generated. The lane uploads the binary only (`skip_metadata`, `skip_screenshots`, `submit_for_review: false`) — once it lands, attach the build to your App Store version and submit for review from the ASC website (the "direct to store" flow, no TestFlight distribution). Re-uploading the **same** marketing version needs a higher build number (bump the tag's patch).

> This lane can only be validated by running it on macOS — it can't be exercised from the Linux dev box, so expect to shake out signing specifics (profile names, keychain) on the first real tag.
