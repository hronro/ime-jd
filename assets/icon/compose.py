#!/usr/bin/env python3
"""Compose all text-based icon artifacts from the extracted glyph outlines.

Run via generate.sh (which extracts the glyph paths into .cache first).
Emits:
  jd.svg                 白文 master — full-bleed cinnabar tile, carved frame, white 键
  jd-small.svg           16/32 px cut — no frame, flat red, heavier glyph
  jd-mono.svg            朱文 line cut — single-color frame ring + glyph
  .cache/jd-macos.svg    macOS app-icon wrapper (tile at 824/1024 + shadow)
  .cache/jd-ios.svg      iOS full-bleed square (no transparent corners)
  ../../ios/App/Assets.xcassets/...            AppIcon Contents.json
  ../../android/app/src/main/res/...           adaptive icon XMLs
"""

import json
import pathlib

here = pathlib.Path(__file__).parent
cache = here / ".cache"
root = here / ".." / ".."

# ---- palette ----
RED_HI = "#C7452F"      # cinnabar, lit center
RED_LO = "#9C2C1C"      # cinnabar, deep edge
RED_FLAT = "#AE3522"    # flat red: small sizes, adaptive-icon background
PAPER = "#F9F1E4"       # glyph on red
PAPER_DIM = "#F6EDE0"   # carved frame on red
MONO = "#B93A2B"        # 朱文 single color

glyph_tile = (cache / "glyph-jian-tile.txt").read_text().strip()
glyph_full = (cache / "glyph-jian-full.txt").read_text().strip()
glyph_108 = (cache / "glyph-jian-108.txt").read_text().strip()

# Shared 白文 tile content, 160x160 space. `rx` differs between the rounded
# master (macOS/Android legacy keep their own corners) and the square iOS
# export (the system applies the mask itself).
def tile(rx):
    corner = f' rx="{rx}"' if rx else ""
    return f'''<defs>
    <radialGradient id="seal" cx="0.34" cy="0.28" r="1.1">
      <stop offset="0" stop-color="{RED_HI}"/>
      <stop offset="1" stop-color="{RED_LO}"/>
    </radialGradient>
  </defs>
  <rect width="160" height="160"{corner} fill="url(#seal)"/>
  <rect x="14" y="14" width="132" height="132" rx="23" fill="none" stroke="{PAPER_DIM}" stroke-opacity="0.92" stroke-width="3"/>
  <path d="{glyph_tile}" fill="{PAPER}" stroke="{PAPER}" stroke-width="1.6" stroke-linejoin="round"/>'''

def svg(body, viewbox="0 0 160 160"):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}">\n  {body}\n</svg>\n'

# ---- committed SVGs ----
(here / "jd.svg").write_text(svg(tile(36)))

(here / "jd-small.svg").write_text(svg(
    f'''<rect width="160" height="160" rx="36" fill="{RED_FLAT}"/>
  <path d="{glyph_full}" fill="{PAPER}" stroke="{PAPER}" stroke-width="3.4" stroke-linejoin="round"/>'''))

(here / "jd-mono.svg").write_text(svg(
    f'''<rect x="8" y="8" width="144" height="144" rx="30" fill="none" stroke="{MONO}" stroke-width="8"/>
  <path d="{glyph_tile}" fill="{MONO}" stroke="{MONO}" stroke-width="1.6" stroke-linejoin="round"/>'''))

# ---- menu-bar template cut: pure black + alpha, glyph knocked out.
# macOS renders it via TISIconIsTemplate (black in light menu bars, white in
# dark ones). Same grammar as Apple's own tiles (see AinuIM's Ainu.tiff):
# full-bleed rounded tile, glyph transparent. Corner radius matches Apple's
# tiles (~25%) rather than the app tile's 22.5% so it sits natively beside
# 拼 / 注 / 仓.
(here / "jd-menu.svg").write_text(svg(
    f'''<defs>
    <mask id="ko">
      <rect width="160" height="160" fill="#FFFFFF"/>
      <path d="{glyph_full}" fill="#000000" stroke="#000000" stroke-width="3.8" stroke-linejoin="round"/>
    </mask>
  </defs>
  <rect width="160" height="160" rx="40" fill="#000000" mask="url(#ko)"/>'''))

# ---- intermediates ----
cache.mkdir(exist_ok=True)

# macOS: Big Sur+ grid puts the tile at 824/1024 with a soft drop shadow.
(cache / "jd-macos.svg").write_text(svg(
    f'''<defs>
    <filter id="sh" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000000" flood-opacity="0.3"/>
    </filter>
  </defs>
  <g filter="url(#sh)">
    <g transform="translate(100,100) scale(5.15)">
      {tile(36)}
    </g>
  </g>''', viewbox="0 0 1024 1024"))

# iOS: full-bleed square, no alpha anywhere (masking is the system's job).
(cache / "jd-ios.svg").write_text(svg(tile(0)))

# ---- iOS asset catalog ----
appiconset = root / "ios" / "App" / "Assets.xcassets" / "AppIcon.appiconset"
appiconset.mkdir(parents=True, exist_ok=True)
(appiconset / "Contents.json").write_text(json.dumps({
    "images": [{
        "filename": "AppIcon-1024.png",
        "idiom": "universal",
        "platform": "ios",
        "size": "1024x1024",
    }],
    "info": {"author": "xcode", "version": 1},
}, indent=2) + "\n")
(root / "ios" / "App" / "Assets.xcassets" / "Contents.json").write_text(
    json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

# ---- Android adaptive icon ----
res = root / "android" / "app" / "src" / "main" / "res"

# Foreground/monochrome: glyph only — the mask supplies the seal's shape.
# Ink box is 46x46 centered in the 108 viewport (safe zone is a 66dp circle;
# the ink diagonal 46*sqrt(2) = 65 stays inside it).
def vector(color):
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:pathData="{glyph_108}"
        android:fillColor="{color}"
        android:strokeColor="{color}"
        android:strokeWidth="1.26"
        android:strokeLineJoin="round"/>
</vector>
'''

drawable = res / "drawable"
drawable.mkdir(parents=True, exist_ok=True)
(drawable / "ic_launcher_foreground.xml").write_text(vector(PAPER))
(drawable / "ic_launcher_monochrome.xml").write_text(vector("#FFFFFF"))

values = res / "values"
values.mkdir(parents=True, exist_ok=True)
(values / "ic_launcher_background.xml").write_text(
    f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{RED_FLAT}</color>
</resources>
''')

anydpi = res / "mipmap-anydpi-v26"
anydpi.mkdir(parents=True, exist_ok=True)
(anydpi / "ic_launcher.xml").write_text(
    '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>
</adaptive-icon>
''')

print("composed SVGs, iOS catalog JSON, Android XMLs")
