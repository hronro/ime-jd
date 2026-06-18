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
