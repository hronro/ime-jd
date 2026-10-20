#!/usr/bin/env bash
# Fold or unfold the iPhone Duo simulator from the command line.
#
# Xcode 27.1 has no simctl / devicectl / XCTest control for the Duo's hinge —
# only Device Hub's pose buttons and hidden hinge slider. This builds the tiny
# helper in duo-hinge.c for the simulator (cached under ios/build) and runs it
# inside the device with `simctl spawn`, posting the event the slider sends.
#
# Usage:
#   ios/scripts/duo-hinge.sh <closed|half|open|degrees> [device]
#
#   closed = 0° (outer display), half = 90° (partially open: the system
#   keyboard splits), open = 180°; any angle 0-180 works. `device` is a UDID
#   or name; it defaults to the booted iPhone Duo.
#
# Prints which display is active afterwards (outer 1398x2034 / inner
# 2007x2853 pixels).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$SCRIPT_DIR/duo-hinge.c"
CACHE="$IOS_DIR/build/duo-hinge"

die() { echo "duo-hinge: $*" >&2; exit 1; }

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: duo-hinge.sh <closed|half|open|degrees> [device]"
case "$1" in
  closed) DEG=0 ;;
  half)   DEG=90 ;;
  open)   DEG=180 ;;
  *)      [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "not an angle: $1"; DEG="$1" ;;
esac

# The device: a UDID, a booted device's name, or the booted iPhone Duo.
BOOTED="$(xcrun simctl list devices booted | grep -E '\(Booted\)' || true)"
WANT="${2:-iPhone Duo}"
if [[ "$WANT" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  UDID="$WANT"
else
  LINE="$(echo "$BOOTED" | grep -F "    $WANT (" | head -1 || true)"
  [ -n "$LINE" ] || die "no booted simulator named \"$WANT\""
  UDID="$(echo "$LINE" | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
fi

# Build once per source and Xcode.
KEY="$( (cat "$SRC"; xcode-select -p) | shasum | cut -c1-12)"
BIN="$CACHE/duo-hinge-$KEY"
if [ ! -x "$BIN" ]; then
  mkdir -p "$CACHE"
  xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -O2 \
    -o "$BIN.tmp" "$SRC" -framework IOKit -framework CoreFoundation
  codesign -f -s - "$BIN.tmp" >/dev/null 2>&1
  mv "$BIN.tmp" "$BIN"
fi

xcrun simctl spawn "$UDID" "$BIN" "$DEG"

# Report the panel the device switched to (the fold animates; give it a moment).
sleep 3
ACTIVE="$(xcrun devicectl device info displays --device "$UDID" 2>/dev/null \
  | grep -E 'nativeSize|active:' | paste - - | grep 'active: true' || true)"
case "$ACTIVE" in
  *1398.0*) echo "hinge ${DEG}°: outer display active" ;;
  *2007.0*) echo "hinge ${DEG}°: inner display active" ;;
  *)        echo "hinge ${DEG}° (active display unknown)" ;;
esac
