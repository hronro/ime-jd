#!/bin/sh
# Provide libjd.a for the iOS app + keyboard extension, matching the platform +
# arch(es) Xcode is compiling. Invoked as an Xcode Run Script Build Phase before
# "Compile Sources". Mirrors macos/scripts/build-libjd.sh: a build targets exactly
# one platform ($PLATFORM_NAME), so a thin per-platform libjd.a is all that's
# needed.
#
# Expected env from Xcode:
#   SRCROOT                    -> ios/  (the .xcodeproj location)
#   PLATFORM_NAME              -> iphoneos | iphonesimulator
#   ARCHS                      -> arch(es) being built (e.g. "arm64" or "arm64 x86_64")
#   DERIVED_FILE_DIR           -> per-target derived-files directory
#   IPHONEOS_DEPLOYMENT_TARGET -> minimum iOS version (e.g. 13.0)
#   LIBJD_A                    -> optional path to a prebuilt libjd.a; when set it's
#                                 used directly instead of invoking zig (the CI
#                                 fast-path, like macOS). It must cover every arch
#                                 in $ARCHS AND match the platform being built
#                                 (device vs simulator) — lipo can't tell the two
#                                 arm64 slices apart, so the caller picks the right one.
#
# Output: $DERIVED_FILE_DIR/libjd-thin/libjd.a

set -eu

OUT_DIR="$DERIVED_FILE_DIR/libjd-thin"
mkdir -p "$OUT_DIR"

PLATFORM_NAME="${PLATFORM_NAME:-iphonesimulator}"
ARCHS="${ARCHS:-$(uname -m)}"
MIN_IOS="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}"

# Fast path: a prebuilt libjd.a was supplied (e.g. the CI `build-libs` artifact).
# Use it directly instead of invoking zig — the only requirement is that it covers
# the arch(es) being built (the caller is responsible for device-vs-simulator).
if [ -n "${LIBJD_A:-}" ]; then
    if [ ! -f "$LIBJD_A" ]; then
        echo "error: LIBJD_A=$LIBJD_A does not exist" >&2
        exit 1
    fi
    have="$(lipo -archs "$LIBJD_A" 2>/dev/null || true)"
    for arch in $ARCHS; do
        case " $have " in
            *" $arch "*) ;;
            *) echo "error: prebuilt $LIBJD_A has archs [$have] but the build needs '$arch'" >&2; exit 1 ;;
        esac
    done
    cp "$LIBJD_A" "$OUT_DIR/libjd.a"
    echo "using prebuilt libjd [$have] from $LIBJD_A"
    exit 0
fi

# Otherwise build libjd from source with zig.
CORE_DIR="$SRCROOT/../core"

# Always Release: Debug pulls in Zig runtime symbols (___zig_probe_stack, etc.)
# that aren't satisfied when linked into a Swift binary. (Same as macOS.)
OPT="-Doptimize=ReleaseFast"

if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not found on PATH. Install with: brew install zig" >&2
    exit 1
fi

slices=""
for arch in $ARCHS; do
    case "$PLATFORM_NAME:$arch" in
        iphoneos:arm64)         zig_target="aarch64-ios.$MIN_IOS" ;;
        iphonesimulator:arm64)  zig_target="aarch64-ios.$MIN_IOS-simulator" ;;
        iphonesimulator:x86_64) zig_target="x86_64-ios.$MIN_IOS-simulator" ;;
        *) echo "error: unsupported PLATFORM_NAME:arch '$PLATFORM_NAME:$arch'" >&2; exit 1 ;;
    esac
    (cd "$CORE_DIR" && zig build -Dtarget="$zig_target" "$OPT" >&2)
    cp "$CORE_DIR/zig-out/lib/libjd.a" "$OUT_DIR/libjd-$arch.a"
    slices="$slices $OUT_DIR/libjd-$arch.a"
done

# lipo -create accepts one or many inputs; a single slice yields a thin archive.
lipo -create $slices -output "$OUT_DIR/libjd.a"

echo "built libjd ($PLATFORM_NAME $ARCHS) at $OUT_DIR/libjd.a"
