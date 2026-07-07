// icontool — glyph outline extraction (CoreText) + ICO packing.
//
//   icontool glyph <font.ttf> <char> <cx> <cy> <fitW> <fitH>
//       Prints SVG path data for <char>, uniformly scaled so its ink box
//       fits (fitW x fitH) and is centered on (cx, cy). Ink box reported
//       on stderr. Y axis already flipped for SVG.
//
//   icontool ico <out.ico> <png>...
//       Packs PNGs into an ICO. Entries <= 48 px are stored as classic
//       32-bit BMP DIBs (straight alpha), larger ones as PNG.

import Foundation
import AppKit

func die(_ m: String) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
    exit(1)
}

func note(_ m: String) {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
}

func fmt(_ v: CGFloat) -> String {
    var s = String(format: "%.2f", v)
    while s.contains("."), s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    if s == "-0" { s = "0" }
    return s
}

func svgPathData(_ path: CGPath) -> String {
    var out = ""
    path.applyWithBlock { ep in
        let e = ep.pointee
        switch e.type {
        case .moveToPoint:
            let p = e.points[0]
            out += "M\(fmt(p.x)) \(fmt(p.y))"
        case .addLineToPoint:
            let p = e.points[0]
            out += "L\(fmt(p.x)) \(fmt(p.y))"
        case .addQuadCurveToPoint:
            let c = e.points[0], p = e.points[1]
            out += "Q\(fmt(c.x)) \(fmt(c.y)) \(fmt(p.x)) \(fmt(p.y))"
        case .addCurveToPoint:
            let c1 = e.points[0], c2 = e.points[1], p = e.points[2]
            out += "C\(fmt(c1.x)) \(fmt(c1.y)) \(fmt(c2.x)) \(fmt(c2.y)) \(fmt(p.x)) \(fmt(p.y))"
        case .closeSubpath:
            out += "Z"
        @unknown default:
            break
        }
    }
    return out
}

func cmdGlyph(_ args: [String]) {
    guard args.count == 6 else { die("usage: icontool glyph <font> <char> <cx> <cy> <fitW> <fitH>") }
    let fontURL = URL(fileURLWithPath: args[0])
    guard let descs = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
          let desc = descs.first else { die("cannot read font: \(args[0])") }
    let font = CTFontCreateWithFontDescriptor(desc, 1000, nil)

    var utf16 = Array(args[1].utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    guard CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count), glyphs[0] != 0 else {
        die("font has no glyph for \(args[1])")
    }
    guard let raw = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { die("no outline") }

    var flip = CGAffineTransform(scaleX: 1, y: -1)
    guard let flipped = raw.copy(using: &flip) else { die("flip failed") }
    let bb = flipped.boundingBoxOfPath

    guard let cx = Double(args[2]), let cy = Double(args[3]),
          let fw = Double(args[4]), let fh = Double(args[5]) else { die("bad numbers") }
    let s = min(CGFloat(fw) / bb.width, CGFloat(fh) / bb.height)
    var t = CGAffineTransform.identity
        .translatedBy(x: CGFloat(cx) - bb.midX * s, y: CGFloat(cy) - bb.midY * s)
        .scaledBy(x: s, y: s)
    guard let fitted = flipped.copy(using: &t) else { die("transform failed") }

    let fb = fitted.boundingBoxOfPath
    note("ink box: x=\(fmt(fb.minX)) y=\(fmt(fb.minY)) w=\(fmt(fb.width)) h=\(fmt(fb.height)) scale=\(fmt(s))")
    print(svgPathData(fitted))
}

struct Pixels {
    let w: Int
    let h: Int
    let rgba: [UInt8] // straight (non-premultiplied) alpha
}

func loadPNG(_ path: String) -> Pixels {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let rep = NSBitmapImageRep(data: data),
          let cg = rep.cgImage else { die("cannot read \(path)") }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("no context")
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    // un-premultiply
    for i in stride(from: 0, to: buf.count, by: 4) {
        let a = Int(buf[i + 3])
        if a > 0 && a < 255 {
            buf[i]     = UInt8(min(255, Int(buf[i])     * 255 / a))
            buf[i + 1] = UInt8(min(255, Int(buf[i + 1]) * 255 / a))
            buf[i + 2] = UInt8(min(255, Int(buf[i + 2]) * 255 / a))
        }
    }
    return Pixels(w: w, h: h, rgba: buf)
}

func bmpEntry(_ px: Pixels) -> Data {
    var d = Data()
    func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
    let andRow = ((px.w + 31) / 32) * 4
    u32(40); u32(px.w); u32(px.h * 2)
    u16(1); u16(32)
    u32(0); u32(px.w * px.h * 4 + andRow * px.h)
    u32(0); u32(0); u32(0); u32(0)
    // XOR data: BGRA, rows bottom-up
    for row in stride(from: px.h - 1, through: 0, by: -1) {
        for col in 0..<px.w {
            let i = (row * px.w + col) * 4
            d.append(contentsOf: [px.rgba[i + 2], px.rgba[i + 1], px.rgba[i], px.rgba[i + 3]])
        }
    }
    // AND mask: zeros (alpha channel authoritative)
    d.append(Data(count: andRow * px.h))
    return d
}

func cmdIco(_ args: [String]) {
    guard args.count >= 2 else { die("usage: icontool ico <out.ico> <png>...") }
    let outPath = args[0]
    var entries: [(size: Int, data: Data)] = []
    for p in args.dropFirst() {
        let px = loadPNG(p)
        guard px.w == px.h else { die("\(p) is not square") }
        if px.w <= 48 {
            entries.append((px.w, bmpEntry(px)))
        } else {
            entries.append((px.w, try! Data(contentsOf: URL(fileURLWithPath: p))))
        }
    }
    entries.sort { $0.size < $1.size }

    var d = Data()
    func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
    u16(0); u16(1); u16(entries.count)
    var offset = 6 + 16 * entries.count
    for e in entries {
        let dim = e.size >= 256 ? 0 : e.size
        d.append(UInt8(dim)); d.append(UInt8(dim)); d.append(0); d.append(0)
        u16(1); u16(32)
        u32(e.data.count); u32(offset)
        offset += e.data.count
    }
    for e in entries { d.append(e.data) }
    try! d.write(to: URL(fileURLWithPath: outPath))
    note("wrote \(outPath) (\(entries.count) entries: \(entries.map { String($0.size) }.joined(separator: ", ")))")
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { die("usage: icontool glyph|ico ...") }
switch cmd {
case "glyph": cmdGlyph(Array(argv.dropFirst()))
case "ico":   cmdIco(Array(argv.dropFirst()))
default:      die("unknown command \(cmd)")
}
