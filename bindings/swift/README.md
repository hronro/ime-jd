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

The user's own phrases are compiled once into a blob the engine reads in place, and merged into every candidate list — same ordering as the built-in words, with a user phrase first on a code it shares with one. The text is the source of truth; a rebuild is about 6 ms per 100 000 phrases on a recent Mac, up to the 500 000 cap.

```swift
let text = "键道\tzzzzzz\n不\tb\n"            // value<TAB>keys, the table files' format
let (dict, report) = try UserDict.build(text, sourceTag: UserDict.hash(text))
print(report.entries, report.dropped, report.shared, report.invalid) // 1 1 1 0
for note in report.notes {                                  // line 1: 键道 is alone on zzzzzz — no note
    print(note.line, note.flags, note.other, note.builtIn, note.peers)
}                                                           // 2 [.repeatsBuiltIn] 0 N 0 — 不/b repeats a built-in word

let engine = Engine(userDict: dict)         // nil (the default) = built-in dictionary alone
```

A line that does not parse never fails the build: the engine skips it, counts it in `invalid`, and notes it. A `UserDictError` is for the call as a whole — too many phrases (`line` names the first one past the cap, `status.isLineError`) or too much text. The report's `notes` are the engine's own: one per line it skipped (`malformed` / `badKeys` / `badValue`), one per line it dropped (`repeatsLine` / `repeatsBuiltIn`, with the line repeated in `other`) and one per kept phrase whose code is already taken (`codeInBuiltIn` / `codeInLine`, with the counts in `builtIn` and `peers`) — the phrase works, listed first, but the code is shared (重码). A context's dictionary is fixed for its lifetime: to adopt an edited dictionary, create a new `Engine` and drop the candidates read from the old one first. `dict.blob` / `UserDict(blob:)` / `UserDict.check` round-trip the bytes for a frontend that caches them; a blob from another build of libjd comes back as `.stale`, which just means "rebuild". `UserDict.hash` is libjd's content hash, for the tag that says which text a cached blob was built from.

Where memory is tight — an iOS keyboard extension — read the cache without reading it: `UserDict(mapping: MappedFile.open(url))` maps the file read-only and the engine reads it where it lies, so the blob costs no dirty memory at all, and `UserDict.build(utf8:)` builds from mapped text without copying it into a `String`. A mapped file must be replaced atomically, never rewritten in place.

### Reverse lookup

`lookupCodes` goes the other way — the codes a value is typed with, from the built-in tables and the engine's user dictionary, and where the value sits on each:

```swift
for code in engine.lookupCodes("着") {   // o #1, fe #0, qe #0, …
    print(code.keys, code.index, code.isUser)
}
```

`index` is the value's position in the candidate list after typing exactly `keys` — 0 is what space commits — and `isUser` marks a code from the user dictionary. Codes come in candidate order: shorter first, ties key by key, a user phrase's code ahead of a built-in word's on the same keys. It is a pure read, so it can run mid-composition.

## Contents

- **`Engine.swift`** — RAII wrapper around `jd_context` (`deinit` calls `jd_deinit`), created over the built-in dictionary alone or with a `UserDict`. Mutating calls return an `EngineState`; candidates come from `readRange(from:count:)`, which fills a Swift array directly, and `lookupCodes(_:)` answers the reverse question with `Code`s. It also verifies `jd.h`'s struct layout and limits against the compiled library once per process.
- **`Candidate.swift`** — `Candidate`, `Code` and `EngineState`. A `Candidate` wraps the C `query_option` and materializes its `String`s **on access**: values point into a dictionary blob (libjd's embedded one, or the user dictionary the engine retains) and hints are inline bytes, so nothing has to be copied and a long candidate strip pays no String cost for rows nobody scrolls to. The one lifetime rule is documented there: a candidate read from an engine with a user dictionary must not outlive that engine.
- **`UserDict.swift`** — the runtime user dictionary: `UserDict.build` compiles `value<TAB>keys` text into the blob and returns the engine's notes (skipped lines, dropped duplicates, shared codes), `Engine(userDict:)` reads it in place, and `blob` / `init(blob:)` / `check` wrap cached bytes, `init(mapping:)` a mapped cache file, and `hash` is libjd's content hash for the cache's tag. The `UserDict` owns its aligned storage or its mapping; the `Engine` retains it.
- **`MappedFile.swift`** — a file mapped read-only, for the phrases file and the cached blob: bytes at a fixed address, read without a copy, and clean pages that count against no process memory limit.
- **`KeyAction.swift`** — the semantic key-action enum shared by each frontend's key gate / dispatch layer.
- **`UserDictFile.swift`** — the phrases file in libjd's table format, as a client keeps it: lenient line parsing for display, serialization (a header comment plus one `value<TAB>keys` line per phrase), both byte by byte so a list of hundreds of thousands of phrases reads in a few tens of milliseconds. No rules of its own — libjd judges every line. Where the file lives is each frontend's business.
- **`CodeLookupReport.swift`** — 编码反查's wording for one query, from `Engine.lookupCodes`: each code with what sets it apart (which candidate the word is there, a user phrase), or why nothing was found, and the trimming a pasted word gets. Pure Foundation; the macOS window shows it as text, the iOS page as a list.
- **`UserDictProblem.swift`** — the engine's verdict on one row of a phrase list, mapped from a build's notes onto the rows by line, with the text a status column shows (a skipped line, a dropped duplicate, a shared code). One copy for both phrase lists.
- **`UserDictSearch.swift`** — a phrase list's search box: the rows as one case-folded text, so a query is one substring scan over hundreds of thousands of rows rather than a comparison per row.

Candidates are addressed by flat index — there is no page concept in the engine. `readRange` is a pure read that never moves what the engine's automatic commits resolve to; call `setAnchor` when the user's view moves.

The platform-specific parts deliberately live elsewhere: macOS's `KeyGate` / `Composition` / IMK controller in `macos/JdIME/`, iOS's `InputSession` in `ios/Keyboard/Engine/`. Their dispatch semantics differ on purpose (an empty engine result passes the key back to the host on macOS but inserts the literal byte on iOS), so they must not be merged.

## Prerequisites

`import Libjd` relies on each target's `SWIFT_INCLUDE_PATHS` pointing at `core/include` (the module map); both projects' project.yml already configure this.

## Tests

Engine-semantics tests live in each frontend's test target: `macos/JdIMETests/EngineSmokeTests.swift` and `ios/KeyboardTests/InputSessionTests.swift` — both drive the real engine through the shared wrapper in this directory. `macos/JdIMETests/UserDictTests.swift` covers `UserDict` (mirroring `bindings/rust/tests/engine.rs`). `macos/JdIMETests/UserDictFileTests.swift` and `ios/KeyboardTests/UserDictStoreTests.swift` cover the file format and the per-row verdicts.
