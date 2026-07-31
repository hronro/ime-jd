// Thin FFI wrapper over libjd; pure Foundation + Libjd, no platform UI deps.
// Shared source, compiled into both the macOS (macos/) and iOS (ios/)
// frontends via their project.yml source paths — see bindings/swift/README.md.

import Foundation
import Libjd

final class Engine {
    private let ctx: OpaquePointer
    /// `jd_state_ptr` is fixed for the context's lifetime, so it's read once.
    private let statePtr: UnsafePointer<jd_state>

    init() {
        Engine.checkABI()
        guard let raw = jd_init() else {
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
    /// `jd_state` has 4 such bytes on a 64-bit target (28 used, 32 total).
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
    }()

    private static func checkABI() {
        _ = abiChecked
    }
}
