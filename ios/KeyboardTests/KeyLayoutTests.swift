import XCTest
import UIKit

// The keyboard UI sources are compiled into this test bundle directly
// (see ios/project.yml), so no module import is needed.

final class KeyLayoutTests: XCTestCase {
    private var allSpecs: [KeySpec] {
        let layers: [KeyboardLayer] = [.letters, .numbers, .symbols]
        return layers.flatMap { layer in
            KeyLayout.rows(layer: layer, idiom: .phone, showGlobe: true).flatMap { $0 }
        }
    }

    private var literalKeys: Set<String> {
        Set(allSpecs.compactMap {
            if case .insertLiteral(let s) = $0.cap { return s } else { return nil }
        })
    }

    /// '；' has no engine key (';' is the desktop 2nd-candidate shortcut), so
    /// it must stay reachable as a dedicated engine-bypass key.
    func testSemicolonIsADedicatedKey() {
        XCTAssertTrue(literalKeys.contains("；"), "； must be a key on some plane")
    }

    /// The ellipsis key inserts the single-glyph form; the variants live in
    /// its press-and-hold group.
    func testEllipsisKeyAndGroup() {
        XCTAssertTrue(literalKeys.contains("…"))
        XCTAssertFalse(literalKeys.contains("……"), "…… was replaced by the … key")
        let group = allSpecs.first { $0.cap == .insertLiteral("…") }?.alternates ?? []
        XCTAssertTrue(group.contains("⋯"), "⋯ must be in the … group")
    }

    /// Grouping exists to free plane slots, so a grouped mark must not ALSO
    /// have a dedicated key (e.g. '‘' lives under '“', not on the plane).
    func testAlternatesAreNotAlsoKeys() {
        let keys = literalKeys
        for spec in allSpecs {
            for alt in spec.alternates {
                XCTAssertFalse(keys.contains(alt),
                               "\(alt) is both a key and an alternate")
            }
        }
    }

    /// Alternates only make sense on direct-insert keys, must not repeat the
    /// primary, and must be non-empty marks.
    func testAlternateGroupsAreWellFormed() {
        for spec in allSpecs where !spec.alternates.isEmpty {
            guard case .insertLiteral(let primary) = spec.cap else {
                XCTFail("alternates on non-literal key \(spec.cap)")
                continue
            }
            XCTAssertFalse(spec.alternates.contains(primary),
                           "\(primary) duplicates its own group")
            XCTAssertFalse(spec.alternates.contains { $0.isEmpty })
        }
    }

    /// Every mark in the engine's punctuation inventory
    /// (core/src/punctuation-marks/) stays reachable as a key or an alternate,
    /// however the planes get reshuffled.
    func testEngineInventoryStaysReachable() {
        let inventory = [
            "｀", "～", "！", "＠", "＃", "＄", "％", "……", "＆", "＊", "（", "）",
            "－", "＝", "＿", "＋", "「", "【", "〔", "［", "『", "〖", "｛",
            "」", "】", "〕", "］", "』", "〗", "｝", "、", "·", "｜", "¦", "＼",
            "：", "，", "《", "。", "》", "／", "？", "‘", "’", "“", "”",
        ]
        let reachable = literalKeys.union(allSpecs.flatMap(\.alternates))
        for mark in inventory {
            XCTAssertTrue(reachable.contains(mark), "\(mark) is no longer reachable")
        }
    }

    /// Every configured group is actually mounted on some plane (no orphans
    /// left behind by a layout reshuffle).
    func testAlternateGroupsAllMounted() {
        let mounted = Set(allSpecs.compactMap { spec -> String? in
            guard case .insertLiteral(let s) = spec.cap, !spec.alternates.isEmpty else { return nil }
            return s
        })
        for primary in ["0", "“", "”", "「", "」", "【", "】", "｜", "《", "》",
                        "。", "·", "…", "－", "＄", "℃", "√", "→", "★", "♡", "©"] {
            XCTAssertTrue(mounted.contains(primary), "group on \(primary) is not on any plane")
        }
    }
}
