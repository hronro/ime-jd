import UIKit

/// Which key plane is showing.
enum KeyboardLayer: Equatable {
    case letters   // ABC
    case numbers   // 123
    case symbols   // #+=
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
    init(_ cap: KeyCap, _ weight: CGFloat = 1) {
        self.cap = cap
        self.weight = weight
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
        marks.map { KeySpec(.insertLiteral($0)) }
    }

    private static func letters(idiom: KeyboardIdiom, showGlobe: Bool) -> [[KeySpec]] {
        var rows: [[KeySpec]] = []
        rows.append(charRow("qwertyuiop"))
        // 9-key home row, centered like the built-in keyboard. ';' is omitted: on
        // desktop it's a shortcut to pick the 2nd candidate, but on mobile you tap
        // the candidate instead. (The engine reserves ';' as that shortcut, so the
        // punctuation inventory has no '；' either — no plane carries one.)
        rows.append([KeySpec(.spacer, 0.5)] + charRow("asdfghjkl") + [KeySpec(.spacer, 0.5)])
        rows.append([KeySpec(.shift, 1.5)] + charRow("zxcvbnm") + [KeySpec(.backspace, 1.5)])
        rows.append(bottomRow(idiom: idiom, showGlobe: showGlobe))
        return rows
    }

    // Digits + Chinese punctuation, shown directly (not the ASCII forms). The two
    // pages together cover every mark in core/src/punctuation-marks/, arranged by
    // frequency like the built-in Pinyin keyboard: the most common marks sit on
    // this page's bottom row within thumb reach, the rare ones live on #+=. Keys
    // insert their mark via the engine-bypass path (see InputSession.insertLiteral).
    private static func numbers(idiom: KeyboardIdiom, showGlobe: Bool) -> [[KeySpec]] {
        var rows: [[KeySpec]] = [
            litRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]),
            litRow(["－", "／", "：", "～", "（", "）", "＄", "＠", "“", "”"]),
            [KeySpec(.toLayer(.symbols), 1.5)]
                + litRow(["。", "，", "、", "？", "！", "……", "‘", "’"])
                + [KeySpec(.backspace, 1.5)],
        ]
        rows.append(bottomRow(idiom: idiom, showGlobe: showGlobe, leftLayer: .letters))
        return rows
    }

    private static func symbols(idiom: KeyboardIdiom, showGlobe: Bool) -> [[KeySpec]] {
        var rows: [[KeySpec]] = [
            litRow(["「", "」", "【", "】", "｛", "｝", "＃", "％", "＆", "＊"]),
            litRow(["＿", "＝", "＋", "＼", "｜", "¦", "《", "》", "·", "｀"]),
            [KeySpec(.toLayer(.numbers), 1.5)]
                + litRow(["『", "』", "〖", "〗", "〔", "〕", "［", "］"])
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
