#!/usr/bin/env bash
# Generate App Store screenshots for the 键道 keyboard by driving the container
# app's in-app preview (the real KeyboardView) into each state via its QA launch
# args, then capturing with simctl on the two required device sizes.
#
# Screenshots captured on the 6.9" iPhone and 13" iPad simulators come out at
# the exact App Store pixel sizes, so no resizing is needed. Typing uses the
# 键道6 code `jmdzi`, which yields 「键道」.
#
# Requirements: macOS with Xcode, plus `zig` and `xcodegen` on PATH (same as a
# normal iOS build — the build step invokes both).
#
# Usage:
#   ios/scripts/screenshots.sh                # build, both devices, light + dark
#   ios/scripts/screenshots.sh --no-build     # reuse the previous build
#   ios/scripts/screenshots.sh --iphone-only  # or --ipad-only
#   ios/scripts/screenshots.sh --light-only   # or --dark-only
#
# Override the simulators if your Xcode ships different model names:
#   IPHONE_NAME="iPhone 16 Pro Max" IPAD_NAME="iPad Pro 13-inch (M5)" \
#     ios/scripts/screenshots.sh
#
# Output: ios/build/screenshots/<device>/<appearance>/NN-name.png (gitignored).

set -euo pipefail

BUNDLE_ID="com.hronro.ime-jd"          # change if you had to switch the bundle id
TYPE_CODE="jmdzi"                       # 键道6 code that yields 「键道」 (hero shot)
EXPAND_CODE="n"                         # single letter with many candidates (expanded-grid shot)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DD="$IOS_DIR/build/DD-screenshots"
OUT_ROOT="$IOS_DIR/build/screenshots"

IPHONE_NAME="${IPHONE_NAME:-iPhone 17 Pro Max}"   # 6.9" display
IPAD_NAME="${IPAD_NAME:-iPad Pro 13-inch (M5)}"   # 13" display
SETTLE="${SETTLE:-3}"                              # seconds to let the UI render before capture

# Each shot is "filename|launch args". `-type` feeds keys so the candidate bar
# fills; `-popup <key>` floats the key-press bubble over that key; `-expand`
# opens the candidate grid; `-numbers`/`-symbols` switch planes. (See
# ios/README.md → QA launch args.)
SHOTS=(
  "01-candidates|-preview -type ${TYPE_CODE} -popup i"
  "02-expanded|-preview -type ${EXPAND_CODE} -expand"
  "03-numbers|-preview -numbers"
  "04-symbols|-preview -symbols"
)

DO_BUILD=1
DEVICES="iphone ipad"
APPEARANCES="light dark"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build)    DO_BUILD=0 ;;
    --iphone-only) DEVICES="iphone" ;;
    --ipad-only)   DEVICES="ipad" ;;
    --light-only)  APPEARANCES="light" ;;
    --dark-only)   APPEARANCES="dark" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

APP_PATH="${APP_PATH:-$DD/Build/Products/Debug-iphonesimulator/JdIME.app}"

# First available simulator UDID for a device name (name may contain parens,
# e.g. "iPad Pro 13-inch (M5)", so match it as a fixed string, then pull the UUID).
udid_for_name() {
  xcrun simctl list devices available \
    | grep -F "$1 (" \
    | grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
    | head -1
}

resolve_udid() {
  local name="$1" udid
  udid="$(udid_for_name "$name" || true)"
  if [ -z "$udid" ]; then
    echo "error: no available simulator named '$name'." >&2
    echo "set IPHONE_NAME / IPAD_NAME to one of these:" >&2
    xcrun simctl list devices available >&2
    exit 1
  fi
  printf '%s' "$udid"
}

build_app() {
  echo "==> generating project + building for the simulator"
  ( cd "$IOS_DIR" && xcodegen generate >/dev/null )
  xcodebuild -project "$IOS_DIR/JdIME-iOS.xcodeproj" -scheme JdIME-iOS \
    -sdk iphonesimulator -configuration Debug \
    -derivedDataPath "$DD" \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO -quiet build
}

capture() {
  local udid="$1" outfile="$2" args="$3"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086 -- args are space-separated flags; the split is intentional
  xcrun simctl launch "$udid" "$BUNDLE_ID" $args >/dev/null
  sleep "$SETTLE"
  xcrun simctl io "$udid" screenshot "$outfile" >/dev/null
  echo "    ✓ $(basename "$outfile")"
}

shoot_device() {
  local label="$1" name="$2" udid mode dir entry
  udid="$(resolve_udid "$name")"
  echo "==> $label: $name ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true   # "already booted" is fine
  xcrun simctl bootstatus "$udid" >/dev/null       # wait until fully booted
  xcrun simctl install "$udid" "$APP_PATH"
  rm -rf "${OUT_ROOT:?}/$label"
  for mode in $APPEARANCES; do
    xcrun simctl ui "$udid" appearance "$mode" >/dev/null
    dir="$OUT_ROOT/$label/$mode"
    mkdir -p "$dir"
    echo "  -- $mode"
    for entry in "${SHOTS[@]}"; do
      capture "$udid" "$dir/${entry%%|*}.png" "${entry#*|}"
    done
  done
}

[ "$DO_BUILD" -eq 1 ] && build_app

if [ ! -d "$APP_PATH" ]; then
  echo "error: app not found at $APP_PATH (build first, or set APP_PATH)" >&2
  exit 1
fi

for d in $DEVICES; do
  case "$d" in
    iphone) shoot_device "iphone-6.9" "$IPHONE_NAME" ;;
    ipad)   shoot_device "ipad-13"    "$IPAD_NAME" ;;
  esac
done

count="$(find "$OUT_ROOT" -name '*.png' | wc -l | tr -d ' ')"
echo "==> done: $count screenshots in $OUT_ROOT"
command -v open >/dev/null && open "$OUT_ROOT" || true
