#!/bin/sh
# Provide libjd.a for the macOS IME, matching the arch(es) Xcode is compiling.
# Invoked as an Xcode Run Script Build Phase before "Compile Sources".
#
# Expected env from Xcode:
#   SRCROOT                   -> macos/  (the .xcodeproj location)
#   ARCHS                     -> arch(es) being built (e.g. "arm64" or "arm64 x86_64")
#   DERIVED_FILE_DIR          -> per-target derived-files directory
#   MACOSX_DEPLOYMENT_TARGET  -> minimum macOS version (e.g. 12.0)
#   LIBJD_A                   -> optional path to a prebuilt libjd.a; when set,
#                                it's used directly instead of building with zig
#                                (it must cover every arch in $ARCHS)
#
# Output: $DERIVED_FILE_DIR/libjd-universal/libjd.a

set -eu

OUT_DIR="$DERIVED_FILE_DIR/libjd-universal"
mkdir -p "$OUT_DIR"

# Arch(es) Xcode is compiling (falls back to the host for standalone runs).
ARCHS="${ARCHS:-$(uname -m)}"

# Fast path: a prebuilt libjd.a was supplied (e.g. the CI `build-libs`
# artifact). Use it directly instead of invoking zig — the only requirement is
# that it covers the arch(es) being built.
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

# Always build libjd in Release. Debug mode pulls in Zig runtime symbols
# (___zig_probe_stack, etc.) that aren't satisfied when linked into a Swift
# binary. We don't need Zig-level debugging for the IME — libjd is a vendored
# static dep.
OPT="-Doptimize=ReleaseFast"

# Pin the zig target's minimum macOS version to the app's deployment target so
# the static lib's objects carry the same `minos` and the linker doesn't warn
# about a version mismatch. Falls back to 12.0 for standalone runs.
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not found on PATH. Install with: brew install zig" >&2
    exit 1
fi

slices=""
for arch in $ARCHS; do
    case "$arch" in
        arm64)  zig_target="aarch64-macos.$MIN_MACOS" ;;
        x86_64) zig_target="x86_64-macos.$MIN_MACOS" ;;
        *) echo "error: unsupported arch '$arch'" >&2; exit 1 ;;
    esac
    (cd "$CORE_DIR" && zig build -Dtarget="$zig_target" "$OPT" >&2)
    cp "$CORE_DIR/zig-out/lib/libjd.a" "$OUT_DIR/libjd-$arch.a"
    slices="$slices $OUT_DIR/libjd-$arch.a"
done

# lipo -create accepts one or many inputs; a single slice yields a thin archive.
lipo -create $slices -output "$OUT_DIR/libjd.a"

echo "built libjd ($ARCHS) at $OUT_DIR/libjd.a"
