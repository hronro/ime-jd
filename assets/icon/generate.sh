#!/usr/bin/env bash
# Regenerate every icon asset from the OFL font + geometry in compose.py.
# Runs on macOS only (CoreText for glyph outlining, iconutil for the icns).
#
#   bash assets/icon/generate.sh
#
# Requires: swiftc, iconutil (Xcode CLT), rsvg-convert (brew install librsvg),
# python3, curl.
set -euo pipefail
cd "$(dirname "$0")"

ROOT=../..
CACHE=.cache
mkdir -p "$CACHE"

# ---- 1. font (OFL-1.1; outlines embedded in artwork, font itself not shipped)
FONT="$CACHE/LXGWWenKai-Medium.ttf"
FONT_URL="https://github.com/lxgw/LxgwWenKai/releases/download/v1.522/LXGWWenKai-Medium.ttf"
FONT_SHA256="d4bdeb38a39151d74d084cba5090f8cb7d20bf83eedb78c35939ae70b9f4e3f6"
if [ ! -f "$FONT" ]; then
    echo "fetching LXGW WenKai Medium v1.522 ..."
    curl -fsSL -o "$FONT" "$FONT_URL"
fi
echo "$FONT_SHA256  $FONT" | shasum -a 256 -c - >/dev/null

# ---- 2. glyph extraction tool
if [ ! -x "$CACHE/icontool" ] || [ icontool.swift -nt "$CACHE/icontool" ]; then
    swiftc -O -o "$CACHE/icontool" icontool.swift
fi

# ---- 3. outlines (fits are part of the design; see README)
"$CACHE/icontool" glyph "$FONT" 键 79.5 81 96 96   > "$CACHE/glyph-jian-tile.txt"
"$CACHE/icontool" glyph "$FONT" 键 80 80 124 124   > "$CACHE/glyph-jian-full.txt"
"$CACHE/icontool" glyph "$FONT" 键 54 54 46 46     > "$CACHE/glyph-jian-108.txt"

# ---- 4. SVGs + Android XMLs + iOS catalog JSON
python3 compose.py

render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

# ---- 5. macOS icns (16/32 pt reps use the small cut — that's what the menu
# bar shows; 128+ use the margined-tile-with-shadow app-icon composition)
ICONSET="$CACHE/jd.iconset"
rm -rf "$ICONSET" && mkdir "$ICONSET"
render jd-small.svg          16   "$ICONSET/icon_16x16.png"
render jd-small.svg          32   "$ICONSET/icon_16x16@2x.png"
render jd-small.svg          32   "$ICONSET/icon_32x32.png"
render jd-small.svg          64   "$ICONSET/icon_32x32@2x.png"
render "$CACHE/jd-macos.svg" 128  "$ICONSET/icon_128x128.png"
render "$CACHE/jd-macos.svg" 256  "$ICONSET/icon_128x128@2x.png"
render "$CACHE/jd-macos.svg" 256  "$ICONSET/icon_256x256.png"
render "$CACHE/jd-macos.svg" 512  "$ICONSET/icon_256x256@2x.png"
render "$CACHE/jd-macos.svg" 512  "$ICONSET/icon_512x512.png"
render "$CACHE/jd-macos.svg" 1024 "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$ROOT/macos/JdIME/jd.icns"

# ---- 5b. macOS menu-bar template icon: black+alpha knockout, 16 + 32@2x in
# one TIFF. Referenced by tsInputMethodIconFileKey with TISIconIsTemplate, so
# the system recolors it per menu-bar appearance (the icns stays colored for
# Finder / the installer).
render jd-menu.svg 16 "$CACHE/jd-menu.png"
render jd-menu.svg 32 "$CACHE/jd-menu@2x.png"
tiffutil -cathidpicheck "$CACHE/jd-menu.png" "$CACHE/jd-menu@2x.png" \
    -out "$ROOT/macos/JdIME/jd-menu.tiff" >/dev/null

# ---- 6. iOS 1024 (flatten to RGB: App Store forbids an alpha channel)
render "$CACHE/jd-ios.svg" 1024 "$CACHE/ios-1024-rgba.png"
python3 - "$CACHE/ios-1024-rgba.png" "$ROOT/ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" <<'EOF'
import struct, sys, zlib

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
pos, w, h, ct, idat = 8, 0, 0, None, b""
while pos < len(data):
    ln = struct.unpack(">I", data[pos:pos+4])[0]
    typ = data[pos+4:pos+8]
    chunk = data[pos+8:pos+8+ln]
    pos += 12 + ln
    if typ == b"IHDR":
        w, h, bd, ct = struct.unpack(">IIBB", chunk[:10])
        assert bd == 8 and ct in (2, 6), f"unexpected PNG format {bd}/{ct}"
    elif typ == b"IDAT":
        idat += chunk
if ct == 2:  # already RGB
    open(dst, "wb").write(data)
    raise SystemExit
raw = zlib.decompress(idat)
bpp, stride = 4, w * 4
out, prev, ppos = bytearray(), bytearray(stride), 0
for _ in range(h):
    f = raw[ppos]
    row = bytearray(raw[ppos+1:ppos+1+stride])
    ppos += 1 + stride
    for i in range(stride):
        a = row[i-bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i-bpp] if i >= bpp else 0
        if f == 1: row[i] = (row[i] + a) & 255
        elif f == 2: row[i] = (row[i] + b) & 255
        elif f == 3: row[i] = (row[i] + ((a + b) >> 1)) & 255
        elif f == 4:
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            row[i] = (row[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
    out += row
    prev = row
rgb = bytearray()
for y in range(h):
    rgb += b"\x00"
    base = y * stride
    for x in range(w):
        rgb += out[base + x*4 : base + x*4 + 3]
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
hdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
open(dst, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", hdr)
                      + chunk(b"IDAT", zlib.compress(bytes(rgb), 9)) + chunk(b"IEND", b""))
EOF

# ---- 7. Android legacy density PNGs (minSdk 24 < 26 = pre-adaptive)
declare -a densities=("mdpi 48 jd-small.svg" "hdpi 72 jd-small.svg"
                      "xhdpi 96 jd.svg" "xxhdpi 144 jd.svg" "xxxhdpi 192 jd.svg")
for entry in "${densities[@]}"; do
    set -- $entry
    dir="$ROOT/android/app/src/main/res/mipmap-$1"
    mkdir -p "$dir"
    render "$3" "$2" "$dir/ic_launcher.png"
done

# ---- 8. Windows ico (language bar shows 16-32; Settings uses larger)
render jd-small.svg  16 "$CACHE/win-16.png"
render jd-small.svg  24 "$CACHE/win-24.png"
render jd-small.svg  32 "$CACHE/win-32.png"
render jd-small.svg  48 "$CACHE/win-48.png"
render jd.svg       256 "$CACHE/win-256.png"
"$CACHE/icontool" ico "$ROOT/windows/jd.ico" \
    "$CACHE/win-16.png" "$CACHE/win-24.png" "$CACHE/win-32.png" \
    "$CACHE/win-48.png" "$CACHE/win-256.png"

echo "done."
