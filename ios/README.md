# 键道输入法 — iOS

A native iOS **custom keyboard extension** for the 键道 (jd) input method, built on the shared Zig core engine (`../core`, linked as `libjd`). It looks and behaves like the built-in iOS keyboard, is fully offline, and requires **no Full Access**.

## Layout

```
ios/
  project.yml                 # XcodeGen spec (source of truth; .xcodeproj is gitignored)
  App/                        # container app (instructions, in-app keyboard preview, the user-dictionary list)
    UserDict/                 # UserDictStore — the app's side of the user dictionary (no UIKit; tested hostless)
    JdIME.entitlements        # the App Group the user dictionary is handed over through
  Keyboard/
    KeyboardViewController.swift   # the extension's principal class (UIInputViewController)
    Engine/                   # InputSession — the iOS dispatch core; UserDictContainer — the App Group
                              # hand-off (the FFI wrapper itself is shared source at ../bindings/swift)
    UI/                       # KeyboardView, key grid, candidate bar/grid, theme, popups
  KeyboardTests/              # InputSession, theme and user-dictionary logic tests (hostless)
  KeyboardUITests/            # QA-only driver for the real extension (JdKeyboardQA scheme)
  scripts/
    build-libjd.sh              # Xcode prebuild: thin per-platform libjd.a (+ LIBJD_A fast-path)
  fastlane/                     # App Store upload lane (release_appstore); CI-only signing
```

## Requirements

- Xcode 26+ — the liquid-glass style references iOS 26 SDK symbols (`UIGlassEffect`); the deployment target is **iOS 15**, the lowest Xcode 27 accepts (the test bundles target iOS 17, Xcode 27's XCTest floor)
- [`zig`](https://ziglang.org) 0.17.0 — `brew install zig`
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
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

(Simulator names follow the installed runtimes — `xcrun simctl list devices available`; Xcode 27's iOS 27 runtime has no iPhone 17 Pro.)

### Enabling the keyboard

After installing the container app: **Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard ▸ 键道** (on iOS 27 a sheet that lists third-party keyboards below the suggested ones). No "Allow Full Access" needed. The container app also has an **in-app preview** ("在应用内试用键盘") to try the keyboard without enabling it system-wide.

## User dictionary

The user's own phrases (用户自造词) are merged into every candidate list once the feature is switched on in the container app: a phrase on a code of its own composes like a built-in word, hints included, and a phrase on a code it shares with a built-in word is listed first, so adding one is how a user overrides what that code commits by default. The engine side is the same `UserDict` wrapper the macOS client uses (`bindings/swift/UserDict.swift`); what differs is where the phrases live and how they reach the keyboard, because an iOS keyboard extension and its app are two sandboxed processes.

**The hand-off.** Both processes share one App Group container (`group.com.hronro.ime-jd`, entitled in `App/JdIME.entitlements` and `Keyboard/JdKeyboard.entitlements`). The phrases file `用户自造词.txt` in it, in `libjd`'s table format (`bindings/swift/UserDictFile.swift`), is the single source of truth, and the app is its only writer: on every change the app rewrites it and, beside it, `用户自造词.blob`, the dictionary it compiled from that text, tagged with the text's hash. The on/off switch (`JdUserDictEnabled`, off by default) sits in the group's shared `UserDefaults`. The keyboard only reads. At every presentation it checks the switch and the two files' sizes and dates, and when something changed and nothing is composing it loads the blob — sub-millisecond — or, when the blob is missing, corrupt, stale after an app update or tagged for another text, builds the dictionary from the text in memory (a few milliseconds) without writing anything; the app rewrites the blob the next time it runs. A container or file the keyboard cannot read means no user dictionary, never an error.

This split is what the platform allows, verified on an iPhone 16 Pro Max running iOS 18.2 with Full Access off: a keyboard extension can read the App Group's files and shared defaults, and cannot write there (permission denied). The simulator proves nothing here — its extensions run unconfined — so verify such questions on a device. Older iOS versions are unverified; the keyboard treats an unreadable container as "no dictionary". **Full Access is still not required.**

**The list.** 用户自造词 in the container app: the file's phrases in file order, with the switch, a search field, add (+), tap to edit, swipe to delete, and drag to reorder in edit mode (order matters only among phrases on one code). Every row is saved as typed — the screen validates nothing — and the engine's notes from the build that follows every save are each row's status (`bindings/swift/UserDictProblem.swift`, shared with the macOS window): a line the engine skips because it does not parse (red, 不生效), a duplicate it drops (grey, 不生效), a phrase on a code that a built-in word or another row already uses (orange, 同码: it works, listed ahead of the built-in word). The footer counts them. The in-app preview adopts an edited dictionary at once, the way the extension does at its next presentation.

**Importing a file.** 从文件导入… on the same screen opens the Files picker (any file; a text file that reached the device without its extension is typed as plain data) for a phrases file in `libjd`'s format: one 键道 wrote on another device, or any text file laid out the same way. The file is read the way the list's own is (comments and blank lines skipped, every other line a row as typed, nothing judged), must be UTF-8 and hold at least one phrase line, and its rows are appended to the list as they are: the screen compares nothing. What that makes of the list is the engine's verdict, as after typing — a row repeating an earlier row or a built-in word is flagged grey, so importing the same file twice shows a second, grey copy of every phrase. **移除重复词条**, next to the import row, deletes exactly those rows after a confirmation that counts them and says what they repeat (the first of each stays); it is greyed out while the engine flags none, or has no notes because the file did not build at all. The one check before an import is written is the engine's own build of the result: an import that would push the file over the caps changes nothing and says why, unlike a typed row, which is always kept.

**Exporting.** 导出… hands the phrases file itself to the share sheet — AirDrop, 存储到「文件」, or any app that takes a text file — byte for byte what the keyboard reads, so what one device exports another imports as it is. The sheet is given a copy in the app's temporary directory, removed when the sheet is done; the row is greyed out while the list is empty.

**Signing.** The App Group must be enabled on both App IDs (`com.hronro.ime-jd` and `com.hronro.ime-jd.keyboard`) in the developer portal for a signed build to install; the unsigned device builds CI makes are unaffected. A simulator build gets the group only through Xcode's ad-hoc signature, so build it signed as the commands above do: `CODE_SIGNING_ALLOWED=NO` leaves the app and the keyboard with no entitlements at all, after which the app reports 无法加载：无法访问共享容器, the keyboard runs without the dictionary, and the simulator discards the group's container, phrases included, at its next restart.

Implementation: `App/UserDict/UserDictStore.swift` (the writer: file, blob, switch, per-row verdicts, the import's reader and checked save, the export copy, the duplicates' removal), `App/UserDictListViewController.swift` (the screen, the picker and the share sheet), `Keyboard/Engine/UserDictContainer.swift` (paths, the switch, the keyboard's loader and change stamp), `InputSession.init(userDict:)` / `replaceDictionary`, and `KeyboardViewController.syncUserDict`. Tests: `KeyboardTests/UserDictContainerTests.swift`, `UserDictStoreTests.swift` and the user-dictionary cases in `InputSessionTests.swift`.

## Tests

```sh
xcodebuild -project JdIME-iOS.xcodeproj -scheme JdIME-iOS \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

`KeyboardTests` covers the `InputSession` dispatch core (composition never leaks to the host, punctuation commits, candidate selection, backspace semantics, space-commits-top, a user dictionary's phrases and swapping it), `KeyboardTheme` resolution (style gate, appearance, return-key tinting), and the user dictionary's store and hand-off (`UserDictStoreTests`, `UserDictContainerTests`) against a temporary directory standing in for the App Group container.

### QA launch args (in-app preview)

The container app's preview screen takes launch args for screenshot-driven QA (`simctl launch <udid> com.hronro.ime-jd -preview …`):

- `-preview` — open the preview screen directly; `-landscape` — force landscape
- `-type ni` — feed keys into the engine so the candidate bar is populated
- `-numbers` / `-symbols` — show that key plane
- `-expand` — open the expanded candidate grid (combine with `-type`)
- `-popup r` — render the key-press bubble, keyed by the key's label (`-popup ：` works too; it only lives during a touch otherwise; iPhone only — iPad shows no popups, like the system keyboard)
- `-alts ：` — render a grouped key's expanded press-and-hold row (combine with `-numbers`/`-symbols`); `-altsel 1` highlights that group index instead of the primary
- `-classic` — force the pre-iOS-26 style on an iOS 26 simulator
- `-field numbersAndPunctuation` — give the field that `UIKeyboardType` (case name): the preview opens on the plane the type asks for, and under `-system` so does the real extension (for the types iOS reserves for its own pads / keyboard — see the architecture note — `-system` shows what the user gets instead)
- `-return search` — give the field that `UIReturnKeyType` (case name), to see the return key's glyph / label and tint for it (under `-system`, the system keyboard's too)
- `-userdict "词<TAB>编码;词<TAB>编码"` — seed the user dictionary with these phrases (replacing the file) and switch it on, so a known phrase can be typed in the preview (`-type`) or on the real extension without going through the list
- `-system` — use the SYSTEM keyboard instead of the inline preview: with the extension enabled, that is the real 键道 extension in its real hosting context

With `SIMCTL_CHILD_JD_QA_READY=<path>` set for `simctl launch`, the preview creates that file once it has applied these args, so a screenshot loop can wait for it rather than for a fixed delay (`scripts/screenshots.sh` does).

### Extension-context QA (JdKeyboardQA scheme)

`simctl` cannot synthesize taps, and third-party keyboards are trust-gated behind the Settings enable flow (writing `AppleKeyboards` defaults is not enough). The `JdKeyboardQA` scheme runs a UI test that enables 键道 in Settings, switches to it via the globe key inside the preview app (`-preview -system`), then holds the app open and drops a marker file so a host-side loop can take screenshots:

```sh
TEST_RUNNER_JD_QA_MARKER=/tmp/jd-qa-ready \
xcodebuild test -project JdIME-iOS.xcodeproj -scheme JdKeyboardQA \
  -destination "id=$UDID" -derivedDataPath build/DD &
# wait for /tmp/jd-qa-ready, screenshot via `simctl io`, then rm the marker
# (the test exits once the marker disappears)
```

If the test fails with `did not switch to 键道` and the preview field shows no keyboard at all, the simulator has a hardware keyboard attached (DeviceHub's hardware-keyboard simulation; the simulator's `log show` reports `backboardd: Hardware keyboard attached` at boot), which hides every software keyboard: switch it off in DeviceHub first.

`TEST_RUNNER_JD_QA_ARGS="-field numberPad"` forwards extra launch args to the preview app, e.g. to present the extension over a numeric field.

`testImportFromFiles` (run with `-only-testing:JdKeyboardUITests/KeyboardExtensionQA/testImportFromFiles` and `TEST_RUNNER_JD_QA_IMPORT=<file name>`) drives the user dictionary's import through the Files picker: it seeds the list, picks the named file under Browse ▸ On My iPhone, checks the appended rows and the repeat the engine flags, then removes it with 移除重复词条. Plant the file first in the simulator's local file-provider storage, which Files shows as On My iPhone: `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Shared/AppGroup/<the container whose metadata plist names group.com.apple.FileProvider.LocalStorage>/File Provider Storage/`. With `TEST_RUNNER_JD_QA_MARKER` set it holds twice, at `<marker>-imported` and `<marker>-deduped`, for screenshots; `TEST_RUNNER_JD_QA_DUMP=<path>` writes the element tree at each picker step, for when the picker's labels move. `testExportToFiles` (`TEST_RUNNER_JD_QA_EXPORT=1`) is the counterpart: it shares the file through the sheet's Save to Files into the same storage directory, holding at `<marker>-share`, `<marker>-save-sheet` and `<marker>-exported`, so the host can compare the saved file with the group container's.

### iPhone Duo fold states

Xcode has no command for the iPhone Duo simulator's hinge, so `scripts/duo-hinge.sh` sets it: it builds `scripts/duo-hinge.c` for the simulator and runs it inside the device, posting the HID event Device Hub's hinge slider sends.

```sh
scripts/duo-hinge.sh closed   # 0°: outer display
scripts/duo-hinge.sh half     # 90°: partially open (inner display; the stock keyboard splits)
scripts/duo-hinge.sh open     # 180°: inner display
scripts/duo-hinge.sh 127 "$UDID"   # any angle; device defaults to the booted iPhone Duo
```

Screenshot the active display with `simctl io <device> screenshot --display=<port>`: the port whose `Default width` in `simctl io <device> enumerate` is 1398 (outer) or 2007 (inner).

## Architecture notes

- **Two visual styles, one code path.** `KeyboardTheme` carries a `style` axis: **liquid glass** on iOS 26+ (fully transparent over the system keyboard panel's material — painting our own would seam against the panel's top strip and globe/mic chin; the in-app preview supplies a stand-in material since it has no system panel) and **classic** below (the pre-26 look: two-tone keys with a hard 1pt shadow, a light active shift, a text return key — likewise drawn over the system keyboard backdrop, which the preview stands in for with its flat colour). Resolved at runtime in `KeyboardTheme.resolve`; everything downstream is theme-driven. Keys are deliberately NOT per-key `UIGlassEffect` views — ~30 live backdrop layers, rebuilt on every plane switch, would blow the extension's memory/GPU budget, and flat fills over the shared material are what the stock keys are anyway. A live light/dark flip while the keyboard is presented can lag (the system doesn't reliably deliver trait changes to a presented extension); it self-heals on the next keystroke or re-present.
- **Each iOS version gets its own system keyboard's look**, measured off the stock keyboards on the iOS 18.6 / 26.4 / 26.5 / 27.0 simulators (light and dark, portrait and landscape, regular and Pro Max iPhones, held and long-pressed keys via a throwaway UI-test probe). Common to all: candidates in the stock size (20pt on iPhone, 22pt on iPad), and on iPhone the stock grid (`KeyGeometry.stock` / `.stockCompact`) — narrower shift / delete with the letters half a key in, the stock bottom-row widths per orientation, taller rows on the Plus / Pro Max sizes, and the stock key faces: small letters drawn larger and raised, capitals, digits and marks smaller. (iPad keeps its own layout — the stock iPad keyboard is a different, full-size one — but shares the colours, corners and glyphs.)
  - *iOS 26+ (liquid glass):* every key — letters and function keys alike — one flat fill, no shadow, 8pt continuous corners; one pressed fill; an armed shift / caps lock shows `shift.fill` / `capslock.fill` rather than an inverted key; shift / delete / globe are SF Symbols, and return shows the stock glyph for the host's return-key type (`⏎`, `→`, `🔍`, `↑`, `✓`, `›`), blue only on the action types (next / continue stay plain); the space bar is blank but for a faint 键 in its corner, the way the stock keyboards mark theirs (拼); press-and-hold groups open in a panel floating above the row. The grid's spacing: 6pt key gaps, the stock row heights.
  - *iOS 26.x:* the key-press callout is the balloon rising out of the key in one outline (drawn as a masked blur material — masking `UIGlassEffect` disables its blur/lensing, so keys behind it would show as hard silhouettes); the alternates panel selects in iOS 26's blue, with the key at rest beneath it.
  - *iOS 27+* (`KeyboardTheme.detachedCallout`): the callout is a frosted bubble floating above the key, which shows its pressed fill; the alternates panel selects with a grey cell. The bubble rises higher than this extension can draw, so on the top row it slides down over its own key. iOS 27 also applies UIKit's scroll edge effect to the candidate strip right under the panel's top edge — its blur covered every candidate — so the bar and grid turn it off.
  - *iOS 15–18 (classic, matched to iOS 18.6):* the stock colours (function keys 169/175/188 light, 73 dark; the key shadow a black veil), an armed shift / caps lock as a light key with `shift.fill` / `capslock.fill`, SF Symbol shift / delete, light small letters beside regular capitals and digits; the grid's spacing: 3pt margins, 6pt key gaps, 42pt rows (45pt on the Plus / Pro Max sizes). The callout is the tall pre-26 balloon with a long neck. While composing, space and return read 选定 / 确认 (return dropping any action tint), as on the stock Pinyin keyboard.
- **iPhone Duo** (measured on the iOS 27.1 simulator). Folded, the system hosts the keyboard on the outer display 7pt in from each edge, so the stock side margin only makes up the rest (`KeyboardLayoutView.systemSideInset`), and the in-row globe takes the Duo's own bottom row (123 1.5 / globe 1 / space / return 1.5 units). Unfolded, the inner display reports a regular width, which selects `KeyGeometry.wide`: the stock keyboard's 801pt grid — 10pt margins and key gaps, 38.75pt rows — with larger key faces, 22pt candidates and a larger bubble and alternates panel. Partially open, the stock keyboard splits in two around the hinge; this one stays whole, because a keyboard extension gets no hinge information: `UIHingeInteraction` never calls back there and `reservedRegions(kind: .division)` stays empty, while the host app gets both.
- **No inline marked text.** iOS forbids third-party keyboards from showing preedit text in the host app, so the in-flight code and candidates render in the keyboard's own candidate bar; only the final string is sent via `textDocumentProxy.insertText`. This matches the engine, which keeps composition state internally and emits only commits.
- **Selection = tap, pagination = scroll.** No number-key selectors. The 123/#+= layers show punctuation directly and insert the tapped mark themselves, **bypassing libjd's punctuation table** but matching its behavior: while composing, commit the top candidate first, then append the mark; otherwise insert it directly (see `core/docs/integration.md`).
- **Press-and-hold punctuation groups.** Long-press groups (`KeyLayout.alternates`) work like the built-in keyboard: hold expands the callout into a row, sliding moves the selection, release commits it. Each group collects visually similar variants of its key (`“`→`‘`, `【`→`〖`/`［`/`〔`/`[`, `。`→`.`/`°`, `$`→`￥`/`€`/`£`/`＄`, `…`→`⋯`, …), and because groups ride the same engine-bypass path they can carry marks the engine inventory has no key for. Grouping is what frees plane slots, so a grouped mark never also has a dedicated key (test-enforced): retiring the `‘ ’ 『 』 〖 〗 〔 〕 ［ ］ ¦` keys promoted `；` and `·` onto the 123 plane (';' is the desktop 2nd-candidate shortcut, so the engine inventory omits `；`; the key inserts via the bypass, leaving the shortcut intact) and made room for new marks — `× ÷` beside `= +`, and a `※ ℃ √ → ★ ♡ ©` row (with groups of their own: `℉`, `✓`, `←`/`↑`/`↓`, `☆`, `♥`, `®`/`™`).
- **Half/full width pairs.** Both widths of an ASCII mark live in one long-press group, and a short press gives whichever width people actually reach for: half on the techy marks (`@ # $ % & * _ = + - / \ | { }` and the backtick — emails, hashtags, decimals, code), full on the Chinese-prose marks (`： ； ？ ！ ～ （ ） ， 。 《 》 【 】`), whose ASCII twins (`: ; ? ! ~ ( ) , . < > [ ]`) ride along as alternates — so `12:30` and `3.14` no longer need a keyboard switch. The two widths of a mark are near-identical at popup size, so the callout badges co-present twins with a small `半`/`全` tag in the cell's top-left corner (`KeyLayout.widthBadge`).
- **Field-aware opening plane.** A field's `keyboardType` picks the plane the keyboard opens on (`KeyboardLayer.initial(for:)`): numeric traits open on 123 so the digits sit under the thumb, everything else on letters — email / URL / ASCII fields included, because this keyboard is Chinese-only and non-Chinese text belongs to another keyboard. The plane is picked on every presentation and re-picked when a field switch changes the keyboard type; caret moves leave the user's plane alone. In practice iOS keeps most numeric fields away from custom keyboards — verified on the iOS 26 simulator: `numberPad` / `decimalPad` / `asciiCapableNumberPad` / `phonePad` get the system pads, and `asciiCapable` / `namePhonePad` / secure fields get the system keyboard (the extension declares `IsASCIICapable` false), while `numbersAndPunctuation`, `emailAddress`, `URL`, `webSearch` and `twitter` fields are handed to the extension. So `numbersAndPunctuation` is the numeric case this actually serves; the pad types are mapped for completeness.
- **Key sounds, no haptics — still no Full Access.** Clicks are the stock keyboard's three sounds (letter / delete / modifier) played through System Sound Services (`KeyClick.swift`), which works inside the extension sandbox without open access; only haptics genuinely require Full Access, so this keyboard has none. Clicks follow the ring/silent switch and ringer volume like the system keyboard's. The Settings ▸ Sounds ▸ Keyboard Clicks toggle does not apply to third-party keyboards (it only governs `playInputClick()`).
- The engine FFI wrapper (`Engine` / `Candidate` / `KeyAction`) is shared source at `bindings/swift/`, compiled into both this project and `macos/` — one copy, no sync discipline needed. Only the dispatch layers stay per-platform (`InputSession` here, `KeyGate`/`Composition` on macOS) because their semantics deliberately differ.

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

For a hand-driven upload that needs no CI secrets (e.g. a first release, or when the App Store Connect API key can't be shared), see [docs/manual-release.md](docs/manual-release.md).
