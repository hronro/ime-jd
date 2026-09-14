import UIKit

/// Which key plane is showing.
enum KeyboardLayer: Equatable {
    case letters   // ABC
    case numbers   // 123
    case symbols   // #+=

    /// The plane a field opens on, from its keyboard-type trait. Numeric fields
    /// open on 123 so the digits sit under the thumb instead of one plane
    /// switch away; everything else, email / URL / ASCII fields included, opens
    /// on letters — this keyboard is Chinese-only, and non-Chinese text belongs
    /// to another keyboard (see the README).
    ///
    /// Which fields actually reach the extension (verified on the iOS 26
    /// simulator): iOS presents its own pads for `numberPad`, `decimalPad`,
    /// `asciiCapableNumberPad` and `phonePad`, and — `IsASCIICapable` being
    /// false in Info.plist — the system keyboard for `asciiCapable`,
    /// `namePhonePad` and secure fields; a custom keyboard never appears there.
    /// Of the numeric traits only `numbersAndPunctuation` is ours, so that is
    /// the case this mapping serves; the pad types are mapped for completeness,
    /// should iOS ever hand them over.
    static func initial(for type: UIKeyboardType) -> KeyboardLayer {
        switch type {
        case .numberPad, .decimalPad, .asciiCapableNumberPad, .phonePad, .numbersAndPunctuation:
            return .numbers
        default:
            return .letters
        }
    }
}

/// What a key does. Character keys carry the literal ASCII byte sent to the engine
/// (the engine converts punctuation to its Chinese form and echoes everything else).
enum KeyCap: Equatable {
    case char(UInt8)             // a letter sent to the engine (extends the trie)
    case insertLiteral(String)   // a digit or Chinese punctuation inserted directly (bypasses libjd)
    case backspace
    case shift
    case toLayer(KeyboardLayer)
    case globe
    case space
    case ret
    case spacer   // invisible gap; reserves width to center a row (no button, no tap)

    /// Glyph shown on the key (special keys use SF Symbols, set in KeyButton).
    var label: String {
        switch self {
        case .char(let b):       return String(Character(Unicode.Scalar(b)))
        case .insertLiteral(let s): return s
        case .backspace:         return "⌫"
        case .shift:             return "⇧"
        case .toLayer(.letters): return "ABC"
        case .toLayer(.numbers): return "123"
        case .toLayer(.symbols): return "#+="
        case .globe:             return "🌐"
        case .space:             return "空格"
        case .ret:               return "换行"
        case .spacer:            return ""
        }
    }

    var isCharacter: Bool { if case .char = self { return true }; return false }
}

/// A key plus its relative width within its row (1 = a standard letter key).
struct KeySpec {
    let cap: KeyCap
    let weight: CGFloat
    /// Extra marks reachable by press-and-hold: the callout expands into a row
    /// (primary first) and the finger slides to pick one, like the built-in
    /// keyboard. Inserted via `.insertLiteral`, so they can carry marks the
    /// engine inventory deliberately lacks.
    let alternates: [String]
    init(_ cap: KeyCap, _ weight: CGFloat = 1, alternates: [String] = []) {
        self.cap = cap
        self.weight = weight
        self.alternates = alternates
    }
}

enum KeyboardIdiom { case phone, pad }

/// Builds the row/key model for a layer. Widths are proportional, so the same model
/// lays out across iPhone/iPad and orientations.
enum KeyLayout {
    static func rows(layer: KeyboardLayer, idiom: KeyboardIdiom, showGlobe: Bool) -> [[KeySpec]] {
        switch layer {
        case .letters: return letters(idiom: idiom, showGlobe: showGlobe)
        case .numbers: return numbers(idiom: idiom, showGlobe: showGlobe)
        case .symbols: return symbols(idiom: idiom, showGlobe: showGlobe)
        }
    }

    /// Key height for the plane area (excludes the candidate bar).
    static func keysHeight(idiom: KeyboardIdiom, compactHeight: Bool) -> CGFloat {
        switch idiom {
        case .phone: return compactHeight ? 162 : 216
        case .pad:   return compactHeight ? 352 : 264
        }
    }

    // MARK: - Plane builders

    private static func charRow(_ s: String) -> [KeySpec] {
        s.unicodeScalars.map { KeySpec(.char(UInt8($0.value))) }
    }

    /// A row of direct-insert keys (digits / Chinese punctuation).
    private static func litRow(_ marks: [String]) -> [KeySpec] {
        marks.map { KeySpec(.insertLiteral($0), alternates: alternates[$0] ?? []) }
    }

    /// Press-and-hold groups: each key collects visually similar variants, so
    /// the mark you hold predicts what the row offers. Groups ride the
    /// `.insertLiteral` engine-bypass path and may therefore carry marks the
    /// engine inventory has no key for (¥, °, •, ⋯, 破折号, …). Grouping is
    /// what frees plane slots: a grouped mark deliberately has NO key of its
    /// own (enforced by KeyLayoutTests) — retiring the dedicated ‘ ’ 『 』
    /// 〖 〗 〔 〕 ［ ］ ¦ keys made room for ； · × ÷ ※ ℃ √ → ★ ♡ ©.
    ///
    /// Width pairs (@/＠ …) live in one group and the KEY carries whichever
    /// width people actually reach for: ASCII on the techy marks (emails,
    /// hashtags, code, decimals), full-width on the Chinese-prose marks, whose
    /// ASCII twins ride along as alternates (12:30, 3.14, (1), <a>). The two
    /// faces are near identical, so the popup badges co-present twins 半/全
    /// (`widthBadge`). Within a group, existing marks keep their slide
    /// distance and a newcomer joins at the back, unless frequency clearly
    /// says otherwise (. outranks °, ｜ outranks ¦, ￥ keeps the slot next
    /// to $).
    private static let alternates: [String: [String]] = [
        "0": ["〇"],
        "“": ["‘"],
        "”": ["’"],
        "「": ["『"],
        "」": ["』"],
        "【": ["〖", "［", "〔", "["],
        "】": ["〗", "］", "〕", "]"],
        "《": ["〈", "＜", "«", "<"],
        "》": ["〉", "＞", "»", ">"],
        "。": [".", "°"],
        "，": [","],
        "；": [";"],
        "：": [":"],
        "？": ["?"],
        "！": ["!"],
        "～": ["~"],
        "（": ["("],
        "）": [")"],
        "·": ["•"],
        "…": ["⋯", "……"],
        "-": ["——", "—", "－"],
        "/": ["／"],
        "@": ["＠"],
        "#": ["＃"],
        "$": ["￥", "€", "£", "＄"],
        "%": ["‰", "％"],
        "&": ["＆"],
        "*": ["＊"],
        "_": ["＿"],
        "=": ["≠", "≈", "＝"],
        "+": ["±", "＋"],
        "\\": ["＼"],
        "|": ["｜", "¦"],
        "{": ["｛"],
        "}": ["｝"],
        "`": ["｀"],
        "℃": ["℉"],
        "√": ["✓"],
        "→": ["←", "↑", "↓"],
        "★": ["☆"],
        // ♡ is the key, ♥ the alternate: U+2665 falls to the color-emoji font
        // on Android, so the always-text U+2661 carries the key face — kept
        // identical here so the two keyboards stay in step.
        "♡": ["♥"],
        "©": ["®", "™"],
    ]

    // MARK: - Half/full width pairs

    /// The full-width twin of every ASCII mark the planes deal in (。/. pair
    /// by role rather than shape). Which width a KEY defaults to is the plane
    /// layout's call, not this table's.
    static let fullWidthTwin: [String: String] = [
        "@": "＠", "#": "＃", "$": "＄", "%": "％", "&": "＆", "*": "＊",
        "_": "＿", "=": "＝", "+": "＋", "-": "－", "/": "／", "\\": "＼",
        "|": "｜", "{": "｛", "}": "｝", "`": "｀", "~": "～", ":": "：",
        ";": "；", "?": "？", "!": "！", "(": "（", ")": "）", ",": "，",
        ".": "。", "<": "＜", ">": "＞", "[": "［", "]": "］",
    ]

    private static let halfWidthTwin: [String: String] =
        Dictionary(uniqueKeysWithValues: fullWidthTwin.map { ($1, $0) })

    /// The 半/全 corner badge for one press-and-hold cell: present only when
    /// the group also holds the value's other-width twin — the near-identical
    /// faces are then told apart by the badge alone.
    static func widthBadge(for value: String, inGroup group: [String]) -> String? {
        if let full = fullWidthTwin[value], group.contains(full) { return "半" }
        if let half = halfWidthTwin[value], group.contains(half) { return "全" }
        return nil
    }

    private static func letters(idiom: KeyboardIdiom, showGlobe: Bool) -> [[KeySpec]] {
        var rows: [[KeySpec]] = []
        rows.append(charRow("qwertyuiop"))
        // 9-key home row, centered like the built-in keyboard. ';' is omitted: on
        // desktop it's a shortcut to pick the 2nd candidate, but on mobile you tap
        // the candidate instead. (The engine reserves ';' as that shortcut, so its
        // punctuation inventory has no '；' — the #+= plane carries a '；' key
        // that inserts via the engine-bypass path, leaving the shortcut intact.)
        rows.append([KeySpec(.spacer, 0.5)] + charRow("asdfghjkl") + [KeySpec(.spacer, 0.5)])
        rows.append([KeySpec(.shift, 1.5)] + charRow("zxcvbnm") + [KeySpec(.backspace, 1.5)])
        rows.append(bottomRow(idiom: idiom, showGlobe: showGlobe))
        return rows
    }

    // Digits + punctuation, each key showing the mark it inserts — the more
    // commonly used width where a mark has two (half - / $ @, full ：～（）).
    // The two pages plus their long-press groups cover every mark in
    // core/punctuation-marks/, arranged by frequency like the built-in Pinyin
    // keyboard: the most common marks sit on this page's bottom row within thumb
    // reach, the rare ones live on #+=. Keys insert their mark via the engine-
    // bypass path (see InputSession.insertLiteral); visually similar variants —
    // including marks beyond the engine inventory — hang off `alternates`.
    private static func numbers(idiom: KeyboardIdiom, showGlobe: Bool) -> [[KeySpec]] {
        var rows: [[KeySpec]] = [
            litRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]),
            litRow(["-", "/", "：", "～", "（", "）", "$", "@", "“", "”"]),
            [KeySpec(.toLayer(.symbols), 1.5)]
                + litRow(["。", "，", "、", "；", "？", "！", "…", "·"])
                + [KeySpec(.backspace, 1.5)],
        ]
        rows.append(bottomRow(idiom: idiom, showGlobe: showGlobe, leftLayer: .letters))
        return rows
    }

    private static func symbols(idiom: KeyboardIdiom, showGlobe: Bool) -> [[KeySpec]] {
        var rows: [[KeySpec]] = [
            litRow(["「", "」", "【", "】", "{", "}", "#", "%", "&", "*"]),
            litRow(["_", "=", "+", "×", "÷", "\\", "|", "《", "》", "`"]),
            // Seven keys, no spacers: weights sum to 10, so the grid aligns
            // with the 10-key rows above and the row reads as full.
            [KeySpec(.toLayer(.numbers), 1.5)]
                + litRow(["※", "℃", "√", "→", "★", "♡", "©"])
                + [KeySpec(.backspace, 1.5)],
        ]
        rows.append(bottomRow(idiom: idiom, showGlobe: showGlobe, leftLayer: .letters))
        return rows
    }

    /// `[123/ABC] [🌐] [ space ] [ return ]` — globe omitted when the host hides it.
    private static func bottomRow(
        idiom: KeyboardIdiom,
        showGlobe: Bool,
        leftLayer: KeyboardLayer = .numbers
    ) -> [[KeySpec]].Element {
        var row: [KeySpec] = [KeySpec(.toLayer(leftLayer), 2.0)]
        if showGlobe { row.append(KeySpec(.globe, 1.2)) }
        row.append(KeySpec(.space, 5.0))
        row.append(KeySpec(.ret, 2.0))
        return row
    }
}
