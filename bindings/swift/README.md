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

### User dictionary

The user's own phrases are compiled once into a blob the engine reads in place, and merged into every candidate list — same ordering as the built-in words, with a user phrase first on a code it shares with one. The text is the source of truth; a rebuild is a couple of milliseconds for thousands of phrases.

```swift
let text = "键道\tzzzzzz\n不\tb\n"            // value<TAB>keys, the table files' format
let (dict, report) = try UserDict.build(text, sourceTag: contentHash)
print(report.entries, report.dropped, report.shared, report.invalid) // 1 1 1 0
for note in report.notes {                                  // line 1: 键道 is alone on zzzzzz — no note
    print(note.line, note.flags, note.other, note.builtIn, note.peers)
}                                                           // 2 [.repeatsBuiltIn] 0 N 0 — 不/b repeats a built-in word

let engine = Engine(userDict: dict)         // nil (the default) = built-in dictionary alone
```

A line that does not parse never fails the build: the engine skips it, counts it in `invalid`, and notes it. A `UserDictError` is for the call as a whole — too many phrases (`line` names the first one past the cap, `status.isLineError`) or too much text. The report's `notes` are the engine's own: one per line it skipped (`malformed` / `badKeys` / `badValue`), one per line it dropped (`repeatsLine` / `repeatsBuiltIn`, with the line repeated in `other`) and one per kept phrase whose code is already taken (`codeInBuiltIn` / `codeInLine`, with the counts in `builtIn` and `peers`) — the phrase works, listed first, but the code is shared (重码). A context's dictionary is fixed for its lifetime: to adopt an edited dictionary, create a new `Engine` and drop the candidates read from the old one first. `dict.blob` / `UserDict(blob:)` / `UserDict.check` round-trip the bytes for a frontend that caches them; a blob from another build of libjd comes back as `.stale`, which just means "rebuild".

## Contents

- **`Engine.swift`** — RAII wrapper around `jd_context` (`deinit` calls `jd_deinit`), created over the built-in dictionary alone or with a `UserDict`. Mutating calls return an `EngineState`; candidates come from `readRange(from:count:)`, which fills a Swift array directly. It also verifies `jd.h`'s struct layout and limits against the compiled library once per process.
- **`Candidate.swift`** — `Candidate` and `EngineState`. A `Candidate` wraps the C `query_option` and materializes its `String`s **on access**: values point into a dictionary blob (libjd's embedded one, or the user dictionary the engine retains) and hints are inline bytes, so nothing has to be copied and a long candidate strip pays no String cost for rows nobody scrolls to. The one lifetime rule is documented there: a candidate read from an engine with a user dictionary must not outlive that engine.
- **`UserDict.swift`** — the runtime user dictionary: `UserDict.build` compiles `value<TAB>keys` text into the blob and returns the engine's notes (skipped lines, dropped duplicates, shared codes), `Engine(userDict:)` reads it in place, and `blob` / `init(blob:)` / `check` wrap cached bytes. The `UserDict` owns its aligned storage; the `Engine` retains it.
- **`KeyAction.swift`** — the semantic key-action enum shared by each frontend's key gate / dispatch layer.

Candidates are addressed by flat index — there is no page concept in the engine. `readRange` is a pure read that never moves what the engine's automatic commits resolve to; call `setAnchor` when the user's view moves.

The platform-specific parts deliberately live elsewhere: macOS's `KeyGate` / `Composition` / IMK controller in `macos/JdIME/`, iOS's `InputSession` in `ios/Keyboard/Engine/`. Their dispatch semantics differ on purpose (an empty engine result passes the key back to the host on macOS but inserts the literal byte on iOS), so they must not be merged.

## Prerequisites

`import Libjd` relies on each target's `SWIFT_INCLUDE_PATHS` pointing at `core/include` (the module map); both projects' project.yml already configure this.

## Tests

Engine-semantics tests live in each frontend's test target: `macos/JdIMETests/EngineSmokeTests.swift` and `ios/KeyboardTests/InputSessionTests.swift` — both drive the real engine through the shared wrapper in this directory. `macos/JdIMETests/UserDictTests.swift` covers `UserDict` (mirroring `bindings/rust/tests/engine.rs`).
