# jd (Swift bindings)

Safe Swift wrapper for the libjd core engine, shared by the `macos/` and `ios/` frontends at the **source level**: both `project.yml`s list this directory as a source path (XcodeGen supports relative paths outside the project directory), so the same files compile into each target — no SPM package, no symlinks. These files used to exist as byte-identical copies in the two projects, kept in sync by comment discipline alone.

```yaml
# macos/project.yml / ios/project.yml
sources:
  - path: ../bindings/swift
```

## Usage

```swift
/// Candidates drawn at once — a frontend choice. The engine has no page concept.
let page = 9

func draw(_ window: [Candidate]) {
    for (i, c) in window.enumerated() {
        if let hint = c.hint {
            print("\(i + 1). \(c.value) 〔\(hint)〕")
        } else {
            print("\(i + 1). \(c.value)")
        }
    }
}

let engine = Engine()
var typed = ""

// Feed one ASCII byte at a time. A keystroke may commit text, may open or
// extend a candidate list, or both (when the key restarts from the root).
for byte in "nk".utf8 {
    let state = engine.pressKey(byte)
    if let commit = state.commit { typed += commit }
}
print(engine.state.optionsCount)          // 330

// Read the window you actually draw. Reads are pure — they never change what
// the engine's own commits resolve to — so prefetch freely.
var start: UInt32 = 0
draw(engine.readRange(from: start, count: page))   // 1. 泥   2. 尼 〔a〕   …

// Turning a page: point the anchor at the first visible candidate, so that
// space — and every other commit the engine makes on its own — picks something
// that is on screen.
if start + UInt32(page) < engine.state.optionsCount {
    start += UInt32(page)
    engine.setAnchor(start)
    draw(engine.readRange(from: start, count: page))   // 1. 南柯梦 〔m〕   …
}

// Space commits the anchor candidate and ends the composition.
if let commit = engine.pressKey(0x20).commit { typed += commit }
print(typed)                              // 南柯梦
```

Committing a candidate the user tapped needs no engine call — insert `c.value` and then `engine.reset()`. For an append-only candidate strip, keep your own array and read `[loaded, loaded + window)` as it scrolls; `ios/Keyboard/Engine/InputSession.swift` does exactly this.

## Contents

- **`Engine.swift`** — RAII wrapper around `jd_context` (`deinit` calls `jd_deinit`). Mutating calls return an `EngineState`; candidates come from `readRange(from:count:)`, which fills a Swift array directly. It also verifies `jd.h`'s struct layout against the compiled library once per process.
- **`Candidate.swift`** — `Candidate` and `EngineState`. A `Candidate` wraps the C `query_option` and materializes its `String`s **on access**: values point into libjd's embedded blob and hints are inline bytes, so nothing has to be copied and a long candidate strip pays no String cost for rows nobody scrolls to.
- **`KeyAction.swift`** — the semantic key-action enum shared by each frontend's key gate / dispatch layer.

Candidates are addressed by flat index — there is no page concept in the engine. `readRange` is a pure read that never moves what the engine's automatic commits resolve to; call `setAnchor` when the user's view moves.

The platform-specific parts deliberately live elsewhere: macOS's `KeyGate` / `Composition` / IMK controller in `macos/JdIME/`, iOS's `InputSession` in `ios/Keyboard/Engine/`. Their dispatch semantics differ on purpose (an empty engine result passes the key back to the host on macOS but inserts the literal byte on iOS), so they must not be merged.

## Prerequisites

`import Libjd` relies on each target's `SWIFT_INCLUDE_PATHS` pointing at `core/include` (the module map); both projects' project.yml already configure this.

## Tests

Engine-semantics tests live in each frontend's test target: `macos/JdIMETests/EngineSmokeTests.swift` and `ios/KeyboardTests/InputSessionTests.swift` — both drive the real engine through the shared wrapper in this directory.
