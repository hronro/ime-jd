# jd (Swift bindings)

Safe Swift wrapper for the libjd core engine, shared by the `macos/` and `ios/` frontends at the **source level**: both `project.yml`s list this directory as a source path (XcodeGen supports relative paths outside the project directory), so the same files compile into each target — no SPM package, no symlinks. These three files used to exist as byte-identical copies in the two projects, kept in sync by comment discipline alone.

```yaml
# macos/project.yml / ios/project.yml
sources:
  - path: ../bindings/swift
```

## Contents

- **`Engine.swift`** — RAII wrapper around `jd_context` (`deinit` calls `jd_deinit`); every method returns a deep-copied `QuerySnapshot`.
- **`QuerySnapshot.swift`** — owned result snapshot. `copy` turns all of the C API's borrowed pointers into Swift `String`s before returning (see the pointer-lifetime contract in `core/docs/integration.md`), and implements the "options visible on the current page" remainder math.
- **`KeyAction.swift`** — the semantic key-action enum shared by each frontend's key gate / dispatch layer.

The platform-specific parts deliberately live elsewhere: macOS's `KeyGate` / `Composition` / IMK controller in `macos/JdIME/`, iOS's `InputSession` in `ios/Keyboard/Engine/`. Their dispatch semantics differ on purpose (an empty engine result passes the key back to the host on macOS but inserts the literal byte on iOS), so they must not be merged.

## Prerequisites

`import Libjd` relies on each target's `SWIFT_INCLUDE_PATHS` pointing at `core/include` (the module map); both projects' project.yml already configure this.

## Tests

Engine-semantics tests live in each frontend's test target: `macos/JdIMETests/EngineSmokeTests.swift` and `ios/KeyboardTests/InputSessionTests.swift` — both drive the real engine through the shared wrapper in this directory.
