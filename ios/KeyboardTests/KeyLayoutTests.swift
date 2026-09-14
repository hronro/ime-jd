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
    /// (core/punctuation-marks/) stays reachable as a key or an alternate,
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
        for primary in ["0", "“", "”", "「", "」", "【", "】", "《", "》",
                        "。", "，", "；", "：", "？", "！", "～", "（", "）",
                        "·", "…", "-", "/", "@", "#", "$", "%", "&", "*",
                        "_", "=", "+", "\\", "|", "{", "}", "`",
                        "℃", "√", "→", "★", "♡", "©"] {
            XCTAssertTrue(mounted.contains(primary), "group on \(primary) is not on any plane")
        }
    }

    // MARK: - Half/full width pairs

    private func group(of primary: String) -> [String] {
        allSpecs.first { $0.cap == .insertLiteral(primary) }?.alternates ?? []
    }

    /// Techy marks are reached for in their ASCII form far more often than in
    /// full-width (emails, hashtags, code, paths), so the HALF-width form is
    /// the key — a short press inserts it — and the full-width twin moved
    /// into the press-and-hold group.
    func testTechMarksDefaultToHalfWidth() {
        for half in ["@", "#", "$", "%", "&", "*", "_", "=", "+",
                     "-", "/", "\\", "|", "{", "}", "`"] {
            guard let full = KeyLayout.fullWidthTwin[half] else {
                XCTFail("\(half) missing from fullWidthTwin"); continue
            }
            XCTAssertTrue(literalKeys.contains(half), "\(half) must be a key")
            XCTAssertFalse(literalKeys.contains(full), "\(full) must no longer be a key")
            XCTAssertTrue(group(of: half).contains(full), "\(full) must be in \(half)'s group")
        }
    }

    /// Chinese-prose marks keep the full-width form on the key, but the ASCII
    /// twin is one hold away (12:30, 3.14, (1), <a>) instead of a keyboard
    /// switch away.
    func testProseMarksCarryHalfWidthAlternates() {
        for (full, half) in [("：", ":"), ("；", ";"), ("？", "?"), ("！", "!"),
                             ("～", "~"), ("（", "("), ("）", ")"), ("，", ","),
                             ("。", "."), ("《", "<"), ("》", ">"),
                             ("【", "["), ("】", "]")] {
            XCTAssertTrue(literalKeys.contains(full), "\(full) must stay a key")
            XCTAssertFalse(literalKeys.contains(half), "\(half) must not be a key")
            XCTAssertTrue(group(of: full).contains(half), "\(half) must be in \(full)'s group")
        }
    }

    /// The popup badges BOTH cells of a co-present width pair (the faces are
    /// near identical) and nothing else.
    func testWidthBadges() {
        XCTAssertEqual(KeyLayout.widthBadge(for: "@", inGroup: ["@", "＠"]), "半")
        XCTAssertEqual(KeyLayout.widthBadge(for: "＠", inGroup: ["@", "＠"]), "全")
        XCTAssertEqual(KeyLayout.widthBadge(for: ".", inGroup: ["。", ".", "°"]), "半")
        XCTAssertEqual(KeyLayout.widthBadge(for: "。", inGroup: ["。", ".", "°"]), "全")
        XCTAssertNil(KeyLayout.widthBadge(for: "°", inGroup: ["。", ".", "°"]))
        XCTAssertNil(KeyLayout.widthBadge(for: "￥", inGroup: ["$", "￥", "€", "£", "＄"]))
        XCTAssertNil(KeyLayout.widthBadge(for: "«", inGroup: ["《", "〈", "＜", "«", "<"]))
        XCTAssertEqual(KeyLayout.widthBadge(for: "＜", inGroup: ["《", "〈", "＜", "«", "<"]), "全")
        XCTAssertNil(KeyLayout.widthBadge(for: "@", inGroup: ["@"]),
                     "no twin in the group → nothing to tell apart → no badge")
    }

    // MARK: - Opening plane per field

    /// Numeric fields open on 123 (digits under the thumb for 验证码 / 手机号 /
    /// 金额); every text-like field — email / URL / ASCII included, which
    /// belong to another keyboard — opens on letters.
    func testNumericFieldsOpenOnNumbers() {
        for type: UIKeyboardType in [.numberPad, .decimalPad, .asciiCapableNumberPad,
                                     .phonePad, .numbersAndPunctuation] {
            XCTAssertEqual(KeyboardLayer.initial(for: type), .numbers, "type \(type.rawValue)")
        }
        for type: UIKeyboardType in [.default, .asciiCapable, .URL, .emailAddress,
                                     .namePhonePad, .twitter, .webSearch] {
            XCTAssertEqual(KeyboardLayer.initial(for: type), .letters, "type \(type.rawValue)")
        }
    }
}
