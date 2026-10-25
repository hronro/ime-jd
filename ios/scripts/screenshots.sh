#!/usr/bin/env bash
# Generate App Store screenshots for the 键道 keyboard by driving the container
# app's in-app preview (the real KeyboardView) into each state via its QA launch
# args, then capturing with simctl on the required device sizes.
#
# Screenshots captured on the 6.9" iPhone, 13" iPad, and iPhone Duo simulators
# come out at the exact App Store pixel sizes, so no resizing is needed. Typing
# uses the 键道6 code `jmdzi`, which yields 「键道」.
#
# iPhone Duo (required from April 2027): both displays are captured. The
# device is folded for the outer display (1398x2034) and unfolded for the
# inner one (2853x2007, landscape) with scripts/duo-hinge.sh, then folded
# again, as it boots.
#
# Requirements: macOS with Xcode, plus `zig` and `xcodegen` on PATH (same as a
# normal iOS build — the build step invokes both).
#
# Usage:
#   ios/scripts/screenshots.sh                # build, all devices, light + dark
#   ios/scripts/screenshots.sh --no-build     # reuse the previous build
#   ios/scripts/screenshots.sh --iphone-only  # or --ipad-only / --duo-only
#   ios/scripts/screenshots.sh --light-only   # or --dark-only
#
# Override the simulators if your Xcode ships different model names:
#   IPHONE_NAME="iPhone 17 Pro Max" IPAD_NAME="iPad Pro 13-inch (M5)" \
#     DUO_NAME="iPhone Duo" ios/scripts/screenshots.sh
#
# Each device runs on the newest iOS runtime that has it; IOS_VERSION pins a
# runtime instead (27.0, or 27 for its newest minor):
#   IOS_VERSION=27.0 ios/scripts/screenshots.sh --ipad-only
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

IPHONE_NAME="${IPHONE_NAME:-iPhone 18 Pro Max}"   # 6.9" display
IPAD_NAME="${IPAD_NAME:-iPad Pro 13-inch (M5)}"   # 13" display
DUO_NAME="${DUO_NAME:-iPhone Duo}"                # both displays (iOS 27.1 runtime)
SETTLE="${SETTLE:-1}"                              # seconds to let the UI settle once the preview is ready

# Each shot is "filename|launch args". `-type` feeds keys so the candidate bar
# fills; `-popup <key>` floats the key-press bubble over that key (iPhone only —
# on iPad the key just highlights, matching the system keyboard); `-expand`
# opens the candidate grid; `-numbers`/`-symbols` switch planes. (See
# ios/README.md → QA launch args.)
SHOTS=(
  "01-candidates|-preview -type ${TYPE_CODE} -popup i"
  "02-expanded|-preview -type ${EXPAND_CODE} -expand"
  "03-numbers|-preview -numbers"
  "04-symbols|-preview -symbols"
)

DO_BUILD=1
DEVICES="iphone ipad duo"
APPEARANCES="light dark"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build)    DO_BUILD=0 ;;
    --iphone-only) DEVICES="iphone" ;;
    --ipad-only)   DEVICES="ipad" ;;
    --duo-only)    DEVICES="duo" ;;
    --light-only)  APPEARANCES="light" ;;
    --dark-only)   APPEARANCES="dark" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

APP_PATH="${APP_PATH:-$DD/Build/Products/Debug-iphonesimulator/JdIME.app}"

# "UDID VERSION" of the simulator with this name on the newest iOS runtime
# that has one, or on IOS_VERSION's. simctl lists runtimes oldest first, so
# the first match would be the oldest. The name may contain parens, e.g.
# "iPad Pro 13-inch (M5)", so it is matched as a fixed string; the UDID follows.
device_for_name() {
  xcrun simctl list devices available | awk -v name="$1" -v want="${IOS_VERSION:-}" '
    /^-- / { ios = ($2 == "iOS"); ver = $3; next }
    ios && index($0, "    " name " (") == 1 && (want == "" || ver == want || index(ver, want ".") == 1) {
      n = split(ver, v, ".")
      key = v[1] * 1000000 + v[2] * 1000 + (n > 2 ? v[3] : 0)
      if (key > best) { best = key; found = substr($0, length(name) + 7, 36) " " ver }
    }
    END { if (found != "") print found }'
}

resolve_device() {
  local name="$1" device
  device="$(device_for_name "$name")"
  if [ -z "$device" ]; then
    echo "error: no available simulator named '$name'${IOS_VERSION:+ on iOS $IOS_VERSION}." >&2
    echo "set IPHONE_NAME / IPAD_NAME / DUO_NAME (or IOS_VERSION) to match one of these:" >&2
    xcrun simctl list devices available >&2
    exit 1
  fi
  printf '%s' "$device"
}

build_app() {
  echo "==> generating project + building for the simulator"
  ( cd "$IOS_DIR" && xcodegen generate >/dev/null )
  xcodebuild -project "$IOS_DIR/JdIME-iOS.xcodeproj" -scheme JdIME-iOS \
    -sdk iphonesimulator -configuration Debug \
    -derivedDataPath "$DD" \
    -destination 'generic/platform=iOS Simulator' -quiet build
}

# Port UUID of the device display with the given pixel width — how a
# multi-display device (iPhone Duo) picks the screen to capture. Port UUIDs
# change on every boot, so look it up after booting.
display_port() {
  xcrun simctl io "$1" enumerate \
    | awk -v w="$2" '/^Port:/ { u = "" } /UUID:/ { u = $2 } $0 ~ "Default width: " w "$" { print u; exit }'
}

# set_pose UDID closed|open — fold or unfold an iPhone Duo (duo-hinge.sh), and
# check the display about to be captured came on.
set_pose() {
  local result
  result="$("$SCRIPT_DIR/duo-hinge.sh" "$2" "$1")"
  echo "  -- $result"
  case "$2:$result" in
    closed:*"inner display active"* | open:*"outer display active"*)
      echo "error: $result after duo-hinge.sh $2" >&2
      exit 1 ;;
  esac
}

capture() {
  local udid="$1" outfile="$2" args="$3" display="$4" ready tries=0
  ready="$(mktemp -u /tmp/jd-screenshot-ready.XXXXXX)"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  # The preview creates $ready once it has applied the launch args, which can
  # take many seconds on a cold launch or a busy machine; wait up to a minute.
  # shellcheck disable=SC2086 # args are space-separated flags; the split is intentional
  SIMCTL_CHILD_JD_QA_READY="$ready" xcrun simctl launch "$udid" "$BUNDLE_ID" $args >/dev/null
  while [ ! -e "$ready" ] && [ "$tries" -lt 120 ]; do
    sleep 0.5
    tries=$((tries + 1))
  done
  [ -e "$ready" ] || echo "    the preview didn't report ready within 60s; capturing anyway" >&2
  rm -f "$ready"
  sleep "$SETTLE"
  xcrun simctl io "$udid" screenshot ${display:+"--display=$display"} "$outfile" >/dev/null
  echo "    ✓ $(basename "$outfile")"
}

# shoot_device LABEL NAME [DISPLAY_WIDTH [POSE]] — the width picks one display
# of a multi-display device (omitted, simctl captures the main one); the pose
# (closed / open) first folds or unfolds an iPhone Duo so that display is on.
shoot_device() {
  local label="$1" name="$2" width="${3:-}" pose="${4:-}" device udid display="" mode dir entry
  device="$(resolve_device "$name")"
  udid="${device% *}"
  echo "==> $label: $name, iOS ${device#* } ($udid)"
  xcrun simctl bootstatus "$udid" -b >/dev/null   # boot if needed, wait until fully up
  xcrun simctl install "$udid" "$APP_PATH"
  if [ -n "$pose" ]; then
    set_pose "$udid" "$pose"
  fi
  if [ -n "$width" ]; then
    display="$(display_port "$udid" "$width")"
    if [ -z "$display" ]; then
      echo "error: $name has no ${width}px-wide display" >&2
      exit 1
    fi
  fi
  rm -rf "${OUT_ROOT:?}/$label"
  for mode in $APPEARANCES; do
    xcrun simctl ui "$udid" appearance "$mode" >/dev/null
    dir="$OUT_ROOT/$label/$mode"
    mkdir -p "$dir"
    echo "  -- $mode"
    for entry in "${SHOTS[@]}"; do
      capture "$udid" "$dir/${entry%%|*}.png" "${entry#*|}" "$display"
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
    duo)    shoot_device "duo-outer"  "$DUO_NAME" 1398 closed
            shoot_device "duo-inner"  "$DUO_NAME" 2007 open
            duo="$(resolve_device "$DUO_NAME")"
            set_pose "${duo% *}" closed ;;
  esac
done

count="$(find "$OUT_ROOT" -name '*.png' | wc -l | tr -d ' ')"
echo "==> done: $count screenshots in $OUT_ROOT"
command -v open >/dev/null && open "$OUT_ROOT" || true
