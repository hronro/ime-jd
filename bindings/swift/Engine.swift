// Thin FFI wrapper over libjd; pure Foundation + Libjd, no platform UI deps.
// Shared source, compiled into both the macOS (macos/) and iOS (ios/)
// frontends via their project.yml source paths — see bindings/swift/README.md.

import Foundation
import Libjd

final class Engine {
    private let ctx: OpaquePointer
    /// `jd_state_ptr` is fixed for the context's lifetime, so it's read once.
    private let statePtr: UnsafePointer<jd_state>
    /// The user dictionary this context reads in place, if any. Retained for
    /// the context's whole lifetime: the engine never copies the blob, and
    /// every candidate `value` read from a user phrase points into it.
    let userDict: UserDict?

    /// `userDict` is merged into every candidate list — same ordering as the
    /// built-in words, a user phrase first on a code it shares with one — or
    /// nil for the built-in dictionary alone. A context's dictionary is fixed
    /// for its lifetime; to switch, create a new `Engine` (and drop the
    /// candidates read from the old one first — see `Candidate`).
    init(userDict: UserDict? = nil) {
        Engine.checkABI()
        self.userDict = userDict
        let raw: OpaquePointer?
        if let dict = userDict {
            raw = jd_init(dict.bytes.baseAddress, dict.bytes.count)
        } else {
            raw = jd_init(nil, 0)
        }
        // A UserDict is validated when it is created, so NULL here is an
        // allocation failure, not a rejected blob.
        guard let raw else {
            fatalError("jd_init failed (allocation failure)")
        }
        guard let sp = jd_state_ptr(raw) else {
            fatalError("jd_state_ptr returned NULL")
        }
        ctx = raw
        statePtr = sp
    }

    deinit {
        jd_deinit(ctx)
    }

    // MARK: - Mutating operations

    /// Feed one keystroke and return the resulting state.
    @discardableResult
    func pressKey(_ byte: UInt8) -> EngineState {
        jd_press_key(ctx, Int8(bitPattern: byte))
        return state
    }

    /// Undo the most recent trie descent, or close a punctuation window.
    /// Never produces a commit.
    @discardableResult
    func backspace() -> EngineState {
        jd_backspace(ctx)
        return state
    }

    /// Drop the in-flight composition and any recorded commit.
    @discardableResult
    func reset() -> EngineState {
        jd_reset(ctx)
        return state
    }

    /// Point the anchor at candidate `index`, so the engine's automatic commits
    /// follow what the user is looking at. Out-of-range indices are ignored.
    @discardableResult
    func setAnchor(_ index: UInt32) -> EngineState {
        jd_set_anchor(ctx, index)
        return state
    }

    // MARK: - Reads

    /// The engine's current state, without touching it.
    var state: EngineState { EngineState(statePtr.pointee) }

    /// Read the candidates at `[start, start + count)`. Returns fewer than
    /// `count` at the end of the list, and none when nothing is in flight.
    ///
    /// A pure read: it never moves the anchor and never invalidates anything
    /// returned earlier, so a candidate strip can prefetch as far ahead as it
    /// likes with no bookkeeping beyond remembering how far it got.
    func readRange(from start: UInt32, count: Int) -> [Candidate] {
        guard count > 0 else { return [] }
        var raw = [query_option](repeating: query_option(), count: count)
        let written = raw.withUnsafeMutableBufferPointer { buf in
            Int(jd_read_range(ctx, start, UInt32(count), buf.baseAddress, UInt32(count)))
        }
        return raw.prefix(written).map(Candidate.init(raw:))
    }

    // MARK: - ABI guard

    /// `jd.h` declares these structs by hand, so it can drift from the
    /// compiled library with no diagnostic — and a size mismatch would corrupt
    /// memory. One comparison per process; `static let` makes it lazy and
    /// thread-safe.
    ///
    /// Compared against `stride`, not `size`: Swift's `size` excludes tail
    /// padding, while the library reports C's `sizeof`, which includes it.
    /// `jd_state` has 4 such bytes on a 64-bit target (28 used, 32 total), and
    /// `jd_user_dict_info` has 4 (12 used, 16 total).
    private static let abiChecked: Void = {
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_SIZEOF_STATE))) == MemoryLayout<jd_state>.stride,
            "libjd jd_state layout mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_SIZEOF_OPTION))) == MemoryLayout<query_option>.stride,
            "libjd query_option layout mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_HINT_CAP))) == Int(JD_HINT_CAP),
            "libjd hint capacity mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_SIZEOF_USER_DICT_REPORT))) == MemoryLayout<jd_user_dict_report>.stride,
            "libjd jd_user_dict_report layout mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_SIZEOF_USER_DICT_INFO))) == MemoryLayout<jd_user_dict_info>.stride,
            "libjd jd_user_dict_info layout mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_SIZEOF_USER_DICT_NOTE))) == MemoryLayout<jd_user_dict_note>.stride,
            "libjd jd_user_dict_note layout mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_USER_DICT_MAX_ENTRIES))) == UserDict.maxEntries,
            "libjd user dictionary entry cap mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_USER_DICT_VALUE_MAX))) == UserDict.maxValueBytes,
            "libjd user dictionary value cap mismatch — core/include/jd.h is out of sync with the library"
        )
    }()

    /// Run the one-time layout check. `UserDict` calls it too, since a
    /// dictionary can be built before any engine exists.
    static func checkABI() {
        _ = abiChecked
    }
}
