import Foundation
import Libjd

struct Candidate: Equatable {
    let value: String
    let hint: String?
}

struct QuerySnapshot: Equatable {
    let commit: String?
    let options: [Candidate]
    let optionsCount: UInt32
    let totalPages: UInt32
    let currentPage: UInt32

    static let empty = QuerySnapshot(
        commit: nil, options: [], optionsCount: 0, totalPages: 0, currentPage: 0
    )

    var hasCandidates: Bool { !options.isEmpty }
    var hasCommit: Bool { commit != nil }
    var isEmpty: Bool { commit == nil && options.isEmpty }
}

extension QuerySnapshot {
    static func copy(_ raw: query_result, pageSize: UInt8) -> QuerySnapshot {
        let commit: String? = raw.commit.map { String(cString: $0) }

        var options: [Candidate] = []
        if let optsPtr = raw.options, raw.options_count > 0 {
            let visible: Int
            if raw.current_page == raw.total_pages {
                let rem = Int(raw.options_count % UInt32(pageSize))
                visible = rem == 0 ? Int(pageSize) : rem
            } else {
                visible = Int(pageSize)
            }
            options.reserveCapacity(visible)
            for i in 0..<visible {
                let opt = optsPtr[i]
                let value = String(cString: opt.value)
                let hint: String? = opt.hint.map { String(cString: $0) }
                options.append(Candidate(value: value, hint: hint))
            }
        }

        return QuerySnapshot(
            commit: commit,
            options: options,
            optionsCount: raw.options_count,
            totalPages: raw.total_pages,
            currentPage: raw.current_page
        )
    }
}
