# 键道输入法 — Android

A native Android **input method (IME)** for the 键道 (jd) input scheme, built on the shared Zig
core engine (`../core`, linked as `libjd`). It draws its own on-screen keyboard, is fully offline,
and requires no special permissions. The architecture mirrors the iOS keyboard extension: a small
JVM layer (the mandatory `InputMethodService` + the keyboard UI in classic Android Views) over the
shared Zig engine, reached through a thin C JNI shim.

## Layout

```
android/
  app/
    build.gradle.kts            # AGP 8.7.3 / Kotlin 2.0.21; abiFilters; the buildLibjd task
    src/main/
      AndroidManifest.xml       # the IME <service> (BIND_INPUT_METHOD + android.view.InputMethod)
      cpp/jd_jni.c              # C JNI shim over libjd's C ABI (marshals query_result → Kotlin)
      java/com/hronro/jdime/
        engine/                 # Engine (JNI), QuerySnapshot, KeyAction, InputSession (dispatch core)
        ime/JdInputMethodService.kt   # the IME service; InputConnection host; lifecycle
        ui/                     # KeyLayout, KeyboardView, key plane, candidate bar/grid, theme
        app/MainActivity.kt     # container app: enable flow + a field to try the keyboard
    src/androidTest/            # InputSession logic tests (instrumented; drive the real engine)
  scripts/build-libjd.sh        # zig core per-ABI + NDK-clang JNI shim → src/main/jniLibs/<abi>/
```

The `engine/` files are ports of `ios/Keyboard/Engine/` — keep them in sync.

## Requirements

- JDK 17+ for Gradle. The **Android Studio JBR (21)** works:
  `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`
- [`zig`](https://ziglang.org) 0.16.0 — `brew install zig`
- Android SDK with **NDK** (e.g. 29.x) — `sdkmanager "ndk;29.0.14206865"`. No CMake needed.
- `local.properties` with `sdk.dir=...` (already present for this machine).

## Build & run

```sh
cd android
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:assembleDebug          # APK at app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:installDebug           # install on a connected device/emulator
```

The `buildLibjd` Gradle task (a `preBuild` dependency) shells out to `scripts/build-libjd.sh`,
which cross-compiles `../core` per ABI with `zig` and links `cpp/jd_jni.c` against the resulting
`libjd.so` using the NDK clang, dropping `libjd.so` + `libjdjni.so` into `src/main/jniLibs/<abi>/`
(both gitignored). MVP ABIs: `arm64-v8a` + `x86_64`.

### Enabling the keyboard

Install the app, then **Settings ▸ System ▸ Languages & input ▸ On-screen keyboard ▸ 键道** (or
tap **在设置中启用键道** in the app). Switch to it from any text field via **切换输入法**. The app
also has a field to try the keyboard immediately.

On an emulator with a hardware keyboard (`hw.keyboard=yes`), Android hides soft keyboards by
default — enable showing them with:
`adb shell settings put secure show_ime_with_hard_keyboard 1`.

## Tests

```sh
./gradlew :app:connectedDebugAndroidTest    # needs a running device/emulator
```

`InputSessionTest` (instrumented, because it drives the real engine through JNI) covers the
`InputSession` dispatch core: composition never leaks to the host, punctuation commits, candidate
selection, backspace semantics, space-commits-top, raw commit, cancel.

## Architecture notes

- **JVM layer is mandatory.** Android has no native IME entry point, so the `InputMethodService`,
  `InputConnection`, and keyboard UI are Kotlin; only the engine is shared (Zig).
- **No host composing region.** Like iOS, the in-flight code + candidates render in the keyboard's
  own candidate bar; only the final string is sent via `InputConnection.commitText`.
- **Selection = tap, pagination = scroll.** No number-key selectors. The 123/#+= layers show
  Chinese punctuation directly and insert the tapped mark themselves, bypassing libjd's punctuation
  table but matching its behavior (see `core/docs/integration.md`).
- **Native packaging.** The shim links the **dynamic** `libjd.so` (not the static `.a`, whose
  local-exec TLS relocations `ld` rejects in a shared object) and ships both `.so`s; `Engine` loads
  only `libjdjni`, whose `DT_NEEDED` pulls in `libjd.so` + `libc.so` as one group so libjd's libc
  references (e.g. `getauxval`) resolve.

## Known limitations (MVP)

- Key-preview popups, in-app embedded preview surface, and `armeabi-v7a` / `x86` ABIs are not yet
  implemented. Release signing / Play packaging and a CI job are follow-ups. APK is ~13 MB
  (the embedded dictionary blob is ~5 MB per ABI).
