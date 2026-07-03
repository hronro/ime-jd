// Thin FFI wrapper over libjd; pure Foundation + Libjd, no platform UI deps.
// Shared source, compiled into both the macOS (macos/) and iOS (ios/)
// frontends via their project.yml source paths — see bindings/swift/README.md.

import Foundation
import Libjd

final class Engine {
    private let ctx: OpaquePointer
    let pageSize: UInt8

    init(pageSize: UInt8 = 9) {
        guard let raw = jd_init(pageSize) else {
            fatalError("jd_init returned NULL")
        }
        self.ctx = raw
        self.pageSize = pageSize
    }

    deinit {
        jd_deinit(ctx)
    }

    func pressKey(_ byte: UInt8) -> QuerySnapshot {
        let result = jd_press_key(ctx, Int8(bitPattern: byte))
        return QuerySnapshot.copy(result, pageSize: pageSize)
    }

    func backspace() -> QuerySnapshot {
        let result = jd_backspace(ctx)
        return QuerySnapshot.copy(result, pageSize: pageSize)
    }

    func nextPage() -> QuerySnapshot {
        let result = jd_next_page(ctx)
        return QuerySnapshot.copy(result, pageSize: pageSize)
    }

    func prevPage() -> QuerySnapshot {
        let result = jd_prev_page(ctx)
        return QuerySnapshot.copy(result, pageSize: pageSize)
    }

    func jumpToPage(_ page: UInt32) -> QuerySnapshot {
        let result = jd_jump_to_page(ctx, page)
        return QuerySnapshot.copy(result, pageSize: pageSize)
    }

    func reset() {
        jd_reset(ctx)
    }
}
