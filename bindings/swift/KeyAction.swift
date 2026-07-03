// The semantic actions a frontend's key gate resolves raw input into.
// Shared source, compiled into both the macOS and iOS frontends — see
// bindings/swift/README.md.

import Foundation

enum KeyAction: Equatable {
    case passthrough
    case engineKey(UInt8)
    case backspace
    case escape
    case pageNext
    case pagePrev
    case selectIdx(Int)
    case commitRaw
}
