// Thin FFI wrapper over libjd; pure Foundation + Libjd, no platform UI deps.
// Shared source, compiled into both the macOS (macos/) and iOS (ios/)
// frontends via their project.yml source paths — see bindings/swift/README.md.

import Foundation
import Libjd

/// What a frontend types from, by the user's two switches — 启用用户自造词
/// and, while it is on, 忽略内置词库. Shared by the macOS and iOS frontends.
enum UserDictSelection {
    /// The built-in dictionary, merged with the user's phrases when they are
    /// on and load.
    case builtIn(UserDict?)
    /// The user's phrases alone, on the empty dictionary (`Dict.empty`).
    case userOnly(UserDict)
    /// The user's phrases alone were asked for and cannot be had, for the
    /// reason given: the frontend says so and keys type themselves. Never
    /// the built-in dictionary instead.
    case unavailable(String)
}

final class Engine {
    private let ctx: OpaquePointer
    /// `jd_state_ptr` is fixed for the context's lifetime, so it's read once.
    private let statePtr: UnsafePointer<jd_state>
    /// The dictionary this context types from in place of the embedded one,
    /// if any, and the user dictionary it reads, if any. Retained for the
    /// context's whole lifetime: the engine never copies a blob, and every
    /// candidate `value` read from one points into it.
    let dict: Dict?
    let userDict: UserDict?

    /// Why a context could not be created.
    enum InitError: Error, Equatable {
        /// No dictionary was given, and this libjd has none of its own
        /// (libjd-engine).
        case noBuiltinDict
        /// The user dictionary was built on another dictionary than the one
        /// the context types from.
        case staleUserDict
        case outOfMemory
    }

    /// `userDict` is merged into every candidate list — same ordering as the
    /// built-in words, a user phrase first on a code it shares with one — or
    /// nil for the built-in dictionary alone. A context's dictionary is fixed
    /// for its lifetime; to switch, create a new `Engine` (and drop the
    /// candidates read from the old one first — see `Candidate`).
    ///
    /// The user dictionary must have been built on the embedded dictionary
    /// (`UserDict.build` with no `on:`), as every one is that a frontend
    /// loads with no `on:`: anything else is a programming error.
    convenience init(userDict: UserDict? = nil) {
        do {
            try self.init(on: nil, userDict: userDict)
        } catch {
            fatalError("jd_init failed: \(error)")
        }
    }

    /// A context typing from `dict` instead of the embedded dictionary —
    /// `Dict.empty` to type from `userDict` alone — merged with `userDict`,
    /// which must have been built on this same `dict`.
    convenience init(dict: Dict, userDict: UserDict?) throws {
        try self.init(on: dict, userDict: userDict)
    }

    private init(on dict: Dict?, userDict: UserDict?) throws {
        Engine.checkABI()
        self.dict = dict
        self.userDict = userDict
        let base = dict?.bytes
        let user = userDict?.bytes
        let raw = jd_init(base?.baseAddress, base?.count ?? 0, user?.baseAddress, user?.count ?? 0)
        guard let raw else {
            // Both blobs passed their checks when they were wrapped, so the
            // failure is one of these — worked out only now, to spare a
            // start that succeeds a second pass over them.
            if dict == nil && Dict.builtinEntries == 0 { throw InitError.noBuiltinDict }
            if let user, jd_user_dict_check(base?.baseAddress, base?.count ?? 0, user.baseAddress, user.count, nil) != 0 {
                throw InitError.staleUserDict
            }
            throw InitError.outOfMemory
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

    /// An engine on what the user chose to type from; nil when that cannot
    /// be had — `.unavailable`, or a user-only dictionary the engine refuses,
    /// which a frontend shows the same way: keys type themselves.
    static func make(_ selection: UserDictSelection) -> Engine? {
        switch selection {
        case .builtIn(let userDict): return Engine(userDict: userDict)
        case .userOnly(let userDict): return try? Engine(dict: .empty, userDict: userDict)
        case .unavailable: return nil
        }
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

    /// The codes `value` is typed with, from the built-in tables and this
    /// engine's user dictionary, in candidate order: shorter codes first,
    /// ties key by key (a-z, then `;`), a user phrase's code ahead of a
    /// built-in word's on the same keys. `value` is matched exactly, byte for
    /// byte; an unknown or empty one has no codes.
    ///
    /// A pure read: the composition and the anchor are untouched.
    func lookupCodes(_ value: String) -> [Code] {
        var value = value
        return value.withUTF8 { bytes -> [Code] in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return [] }
            let text = UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self)
            // No value in the built-in tables has more than a dozen codes;
            // a longer list is answered with its total, so ask once more.
            var raw = [jd_code](repeating: jd_code(), count: 16)
            var total = 0
            while true {
                total = raw.withUnsafeMutableBufferPointer { out in
                    Int(jd_lookup_codes(ctx, text, bytes.count, out.baseAddress, UInt32(out.count)))
                }
                if total <= raw.count { break }
                raw = [jd_code](repeating: jd_code(), count: total)
            }
            return raw.prefix(total).map(Code.init(raw:))
        }
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
            Int(jd_abi_layout(UInt32(JD_ABI_SIZEOF_CODE))) == MemoryLayout<jd_code>.stride,
            "libjd jd_code layout mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_CODE_CAP))) == Int(JD_CODE_CAP),
            "libjd code capacity mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_USER_DICT_MAX_ENTRIES))) == UserDict.maxEntries,
            "libjd user dictionary entry cap mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_USER_DICT_VALUE_MAX))) == UserDict.maxValueBytes,
            "libjd user dictionary value cap mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_USER_DICT_TEXT_MAX))) == UserDict.maxTextBytes,
            "libjd user dictionary text cap mismatch — core/include/jd.h is out of sync with the library"
        )
        precondition(
            Int(jd_abi_layout(UInt32(JD_ABI_DICT_MAX_ENTRIES))) == Dict.maxEntries
                && Int(jd_abi_layout(UInt32(JD_ABI_DICT_VALUE_MAX))) == Dict.maxValueBytes,
            "libjd dictionary caps mismatch — core/include/jd.h is out of sync with the library"
        )
    }()

    /// Run the one-time layout check. `UserDict` calls it too, since a
    /// dictionary can be built before any engine exists.
    static func checkABI() {
        _ = abiChecked
    }
}
